import Foundation

/// Schema 1 is additive only when this reader knows the additions. Unknown editing fields
/// are rejected so an older reader cannot open/save a newer document and silently drop effects.
enum DocumentCompatibility {
    static func validate(_ data: Data, recovery: Bool = false) throws {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else { throw ProjectError("프로젝트 JSON 객체가 올바르지 않습니다.") }
        if recovery {
            try keys(object, allowed: "project documentURL mediaBaseURL savedAt", path: "복구본")
            if let project = object["project"] as? [String: Any] { try inspect(project, kind: "Project", path: "복구본.project") }
        } else { try inspect(object, kind: "Project", path: "Project") }
    }
    private static func keys(_ object: [String: Any], allowed: String, path: String) throws {
        let known = Set(allowed.split(separator: " ").map(String.init))
        let unknown = Set(object.keys).subtracting(known).sorted()
        guard unknown.isEmpty else { throw ProjectError("더 새로운 편집 정보가 있어 이 버전에서는 열 수 없습니다: \(path).\(unknown.joined(separator: ", ")). 문서를 만든 버전에서 여세요.") }
    }
    private static func inspect(_ object: [String: Any], kind: String, path: String) throws {
        if kind == "Project", let version = object["schemaVersion"] as? Int, version != 1 { throw ProjectError("지원하지 않는 프로젝트 버전입니다: \(version)") }
        let allowed: String
        switch kind {
        case "Project": allowed = "schemaVersion id name assets sequence derivedSequences glossary"
        case "Sequence": allowed = "id name width height frameRate colorSpace tracks markers speakers"
        case "MediaAsset": allowed = "id name path relativePath bookmark kind duration width height hasAudio codec colorInfo supported issue provenance contentHash"
        case "Track": allowed = "id name kind clips isMuted isHidden isLocked syncLocked transitionContext"
        case "Clip": allowed = "id name assetID start sourceStart duration volume transform title playbackRate visual fadeIn fadeOut audioFadeIn audioFadeOut keyframes connection lineageID ducking captionMetadata captionRole captionGroupID captionHidden stabilization transition titleAnimation transitionAudioFades blendMode"
        case "CaptionMetadata": allowed = "language originalLanguage originalText translatedFrom generatedText clipLanguage languageOrigin languageEvidence languageConfidence languageManual languageNeedsReview speaker speakerStatus speakerManual translationStyle styleApplied glossaryApplied glossaryFailed translationRevision reviewDigest"
        case "TranslationRevision": allowed = "version sourceCaptionID sourceDigest recipeDigest"
        case "SourceLanguageObservation": allowed = "sourceStart sourceEnd language candidateLanguage confidence measuredSpeechSeconds method state reason"
        case "CubeLUT": allowed = "name size values"
        case "ClipConnection": allowed = "parentID sourceStart sourceDuration generatedText"
        case "GainPoint": allowed = "time gain"
        case "TimelineMarker": allowed = "id time name"
        case "SpeakerProfile": allowed = "id name colorHex"
        case "ClipTransition": allowed = "kind direction duration offset independentFade"
        case "TransitionContext": allowed = "originTrackID outgoingFamilyID effect"
        case "TransitionAudioFade": allowed = "ownerID start duration incoming points"
        case "TitleAnimation": allowed = "inKind outKind inSeconds outSeconds referenceDuration timeOffset timeScale"
        case "StabilizationData": allowed = "enabled strength smoothing step analyzedStart frameWidth frameHeight x y angle rejectedSteps confidence analyzedEnd"
        case "GlossaryEntry": allowed = "id source target sourceLanguage targetLanguage caseSensitive protected"
        case "Title": allowed = "text fontName fontSize colorHex x y style"
        case "TextStyle": allowed = "strokeHex strokeWidth backgroundHex backgroundOpacity padding alignment shadow maxLines lineSpacing wrapWidthFraction"
        case "ClipTransform": allowed = "x y scale rotation opacity fill"
        case "VisualAdjustments": allowed = "exposure contrast saturation cropLeft cropRight cropTop cropBottom temperature tint shadows highlights lut ellipseMask greenScreen shapeMask chromaKey"
        case "ChromaKey": allowed = "version keyRed keyGreen keyBlue similarity softness spillReduction"
        case "ShapeMask": allowed = "version kind centerX centerY width height rotation feather"
        case "TransformKeyframe": allowed = "time transform volume interpolation"
        case "MediaTime": allowed = "value timescale"
        case "FrameRate", "PlaybackRate": allowed = "numerator denominator"
        case "AssetProvenance": allowed = "sourceURL author license licenseURL sha256"
        default: return
        }
        try keys(object, allowed: allowed, path: path)
        let childTypes: [String: String] = ["translationRevision":"TranslationRevision", "languageEvidence":"SourceLanguageObservation", "captionMetadata":"CaptionMetadata", "lut":"CubeLUT", "connection":"ClipConnection", "ducking":"GainPoint", "markers":"TimelineMarker", "speakers":"SpeakerProfile", "glossary":"GlossaryEntry", "stabilization":"StabilizationData", "transition":"ClipTransition", "titleAnimation":"TitleAnimation", "analyzedStart":"MediaTime", "analyzedEnd":"MediaTime", "sourceDuration":"MediaTime", "sequence":"Sequence", "derivedSequences":"Sequence", "assets":"MediaAsset", "tracks":"Track", "clips":"Clip", "title":"Title", "style":"TextStyle", "transform":"ClipTransform", "visual":"VisualAdjustments", "keyframes":"TransformKeyframe", "frameRate":"FrameRate", "playbackRate":"PlaybackRate", "provenance":"AssetProvenance", "start":"MediaTime", "sourceStart":"MediaTime", "duration":"MediaTime", "fadeIn":"MediaTime", "fadeOut":"MediaTime", "audioFadeIn":"MediaTime", "audioFadeOut":"MediaTime", "time":"MediaTime"]
        let newTypes = ["chromaKey": "ChromaKey", "shapeMask": "ShapeMask", "transitionContext": "TransitionContext", "effect": "ClipTransition", "transitionAudioFades": "TransitionAudioFade", "points": "GainPoint", "offset": "MediaTime"]
        for (key, type) in childTypes.merging(newTypes, uniquingKeysWith: { _, new in new }) {
            if let child = object[key] as? [String: Any] { try inspect(child, kind: type, path: path + "." + key) }
            if let children = object[key] as? [[String: Any]] {
                for (index, child) in children.enumerated() { try inspect(child, kind: type, path: path + ".\(key)[\(index)]") }
            }
        }
    }
}

extension DocumentCompatibility {
    /// Keys first written by 0.7. A 0.6 app rejects documents that contain them (strict allowlist),
    /// so the first save that adds one keeps a copy of the older file (see ProjectStore.save).
    public static let keysIntroducedIn07: Set<String> = ["transitionContext", "transitionAudioFades", "glossary", "speakers", "stabilization", "transition", "titleAnimation", "clipLanguage", "languageConfidence", "languageManual", "languageNeedsReview", "languageOrigin", "languageEvidence",
                                                         "speaker", "speakerStatus", "speakerManual", "translationStyle", "styleApplied", "glossaryApplied", "glossaryFailed", "translationRevision"]
    public static func usesKeysIntroducedIn07(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dict = value as? [String: Any] { return dict.keys.contains { keysIntroducedIn07.contains($0) } || dict.values.contains { scan($0) } }
            if let array = value as? [Any] { return array.contains { scan($0) } }
            return false
        }
        return scan(object)
    }
}


extension DocumentCompatibility {
    public static let captionRoleKeys: Set<String> = ["captionRole", "captionGroupID", "captionHidden"]
    public static func usesCaptionRoles(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dict = value as? [String: Any] { return !captionRoleKeys.isDisjoint(with: dict.keys) || dict.values.contains { scan($0) } }
            if let array = value as? [Any] { return array.contains { scan($0) } }
            return false
        }
        return scan(object)
    }
}


extension DocumentCompatibility {
    static func usesLanguageEvidence(_ data:Data) -> Bool {
        guard let object=try? JSONSerialization.jsonObject(with:data) else {return false}
        func scan(_ value:Any) -> Bool {
            if let dict=value as? [String:Any] {return dict["languageOrigin"] != nil || dict["languageEvidence"] != nil || dict.values.contains {scan($0)}}
            if let array=value as? [Any] {return array.contains {scan($0)}}
            return false
        }
        return scan(object)
    }
}

extension DocumentCompatibility {
    static func usesTranslationRevision(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dict = value as? [String: Any] { return dict["translationRevision"] != nil || dict.values.contains { scan($0) } }
            if let array = value as? [Any] { return array.contains { scan($0) } }; return false
        }
        return scan(object)
    }
}


extension DocumentCompatibility {
    static func usesSpeakerIdentity(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dict = value as? [String: Any] {
                if dict["speakerManual"] != nil { return true }
                for key in ["speaker", "id"] { if let id = dict[key] as? String, SpeakerIdentity.sourceID(id) != nil { return true } }
                return dict.values.contains { scan($0) }
            }
            if let array = value as? [Any] { return array.contains { scan($0) } }; return false
        }; return scan(object)
    }
}

extension DocumentCompatibility {
    static func usesCaptionReviewLayout(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dict = value as? [String: Any] { return dict["reviewDigest"] != nil || dict["wrapWidthFraction"] != nil || dict.values.contains { scan($0) } }
            if let array = value as? [Any] { return array.contains { scan($0) } }
            return false
        }
        return scan(object)
    }
}

extension DocumentCompatibility {
    static func usesBlendModes(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary["blendMode"] != nil || dictionary.values.contains { scan($0) }
            }
            if let array = value as? [Any] { return array.contains { scan($0) } }
            return false
        }
        return scan(object)
    }
}

extension DocumentCompatibility {
    static func usesShapeMasks(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary["shapeMask"] != nil || dictionary.values.contains { scan($0) }
            }
            if let array = value as? [Any] { return array.contains { scan($0) } }
            return false
        }
        return scan(object)
    }
}


extension DocumentCompatibility {
    static func usesChromaKey(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        func scan(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary["chromaKey"] != nil || dictionary.values.contains { scan($0) }
            }
            if let array = value as? [Any] { return array.contains { scan($0) } }
            return false
        }
        return scan(object)
    }
}

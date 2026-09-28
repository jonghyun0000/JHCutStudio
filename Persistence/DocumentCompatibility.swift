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
        case "Track": allowed = "id name kind clips isMuted isHidden isLocked syncLocked"
        case "Clip": allowed = "id name assetID start sourceStart duration volume transform title playbackRate visual fadeIn fadeOut audioFadeIn audioFadeOut keyframes connection lineageID ducking captionMetadata"
        case "CaptionMetadata": allowed = "language originalLanguage originalText translatedFrom generatedText clipLanguage languageConfidence languageManual languageNeedsReview speaker speakerStatus translationStyle styleApplied glossaryApplied glossaryFailed"
        case "CubeLUT": allowed = "name size values"
        case "ClipConnection": allowed = "parentID sourceStart sourceDuration generatedText"
        case "GainPoint": allowed = "time gain"
        case "TimelineMarker": allowed = "id time name"
        case "SpeakerProfile": allowed = "id name colorHex"
        case "GlossaryEntry": allowed = "id source target sourceLanguage targetLanguage caseSensitive protected"
        case "Title": allowed = "text fontName fontSize colorHex x y style"
        case "TextStyle": allowed = "strokeHex strokeWidth backgroundHex backgroundOpacity padding alignment shadow maxLines lineSpacing"
        case "ClipTransform": allowed = "x y scale rotation opacity fill"
        case "VisualAdjustments": allowed = "exposure contrast saturation cropLeft cropRight cropTop cropBottom temperature tint shadows highlights lut ellipseMask greenScreen"
        case "TransformKeyframe": allowed = "time transform volume interpolation"
        case "MediaTime": allowed = "value timescale"
        case "FrameRate", "PlaybackRate": allowed = "numerator denominator"
        case "AssetProvenance": allowed = "sourceURL author license licenseURL sha256"
        default: return
        }
        try keys(object, allowed: allowed, path: path)
        let childTypes: [String: String] = ["captionMetadata":"CaptionMetadata", "lut":"CubeLUT", "connection":"ClipConnection", "ducking":"GainPoint", "markers":"TimelineMarker", "speakers":"SpeakerProfile", "glossary":"GlossaryEntry", "sourceDuration":"MediaTime", "sequence":"Sequence", "derivedSequences":"Sequence", "assets":"MediaAsset", "tracks":"Track", "clips":"Clip", "title":"Title", "style":"TextStyle", "transform":"ClipTransform", "visual":"VisualAdjustments", "keyframes":"TransformKeyframe", "frameRate":"FrameRate", "playbackRate":"PlaybackRate", "provenance":"AssetProvenance", "start":"MediaTime", "sourceStart":"MediaTime", "duration":"MediaTime", "fadeIn":"MediaTime", "fadeOut":"MediaTime", "audioFadeIn":"MediaTime", "audioFadeOut":"MediaTime", "time":"MediaTime"]
        for (key, type) in childTypes {
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
    public static let keysIntroducedIn07: Set<String> = ["glossary", "speakers", "clipLanguage", "languageConfidence", "languageManual", "languageNeedsReview",
                                                         "speaker", "speakerStatus", "translationStyle", "styleApplied", "glossaryApplied", "glossaryFailed"]
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

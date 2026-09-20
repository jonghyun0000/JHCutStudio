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
        case "Project": allowed = "schemaVersion id name assets sequence derivedSequences"
        case "Sequence": allowed = "id name width height frameRate colorSpace tracks"
        case "MediaAsset": allowed = "id name path relativePath bookmark kind duration width height hasAudio codec colorInfo supported issue provenance"
        case "Track": allowed = "id name kind clips isMuted isHidden isLocked"
        case "Clip": allowed = "id name assetID start sourceStart duration volume transform title playbackRate visual fadeIn fadeOut audioFadeIn audioFadeOut keyframes"
        case "Title": allowed = "text fontName fontSize colorHex x y style"
        case "TextStyle": allowed = "strokeHex strokeWidth backgroundHex backgroundOpacity padding alignment shadow maxLines lineSpacing"
        case "ClipTransform": allowed = "x y scale rotation opacity fill"
        case "VisualAdjustments": allowed = "exposure contrast saturation cropLeft cropRight cropTop cropBottom"
        case "TransformKeyframe": allowed = "time transform volume interpolation"
        case "MediaTime": allowed = "value timescale"
        case "FrameRate", "PlaybackRate": allowed = "numerator denominator"
        case "AssetProvenance": allowed = "sourceURL author license licenseURL sha256"
        default: return
        }
        try keys(object, allowed: allowed, path: path)
        let childTypes: [String: String] = ["sequence":"Sequence", "derivedSequences":"Sequence", "assets":"MediaAsset", "tracks":"Track", "clips":"Clip", "title":"Title", "style":"TextStyle", "transform":"ClipTransform", "visual":"VisualAdjustments", "keyframes":"TransformKeyframe", "frameRate":"FrameRate", "playbackRate":"PlaybackRate", "provenance":"AssetProvenance", "start":"MediaTime", "sourceStart":"MediaTime", "duration":"MediaTime", "fadeIn":"MediaTime", "fadeOut":"MediaTime", "audioFadeIn":"MediaTime", "audioFadeOut":"MediaTime", "time":"MediaTime"]
        for (key, type) in childTypes {
            if let child = object[key] as? [String: Any] { try inspect(child, kind: type, path: path + "." + key) }
            if let children = object[key] as? [[String: Any]] {
                for (index, child) in children.enumerated() { try inspect(child, kind: type, path: path + ".\(key)[\(index)]") }
            }
        }
    }
}

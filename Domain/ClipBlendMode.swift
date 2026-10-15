import Foundation

/// Scene-referred RGB blending in the compositor's extended linear sRGB working space.
/// Missing values in older documents mean normal source-over. Unknown raw values fail decoding.
public enum ClipBlendMode: String, Codable, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, darken, lighten
    public var label: String {
        switch self {
        case .normal: return "일반"
        case .multiply: return "곱하기"
        case .screen: return "스크린"
        case .overlay: return "오버레이"
        case .darken: return "어둡게"
        case .lighten: return "밝게"
        }
    }
}

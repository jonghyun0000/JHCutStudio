import Foundation

public enum ShapeMaskKind: String, Codable, CaseIterable, Sendable {
    case ellipse, rectangle
    public var label: String { self == .ellipse ? "타원" : "사각형" }
}

/// Source-attached mask in the CROPPED, oriented source coordinates, before clip transforms.
/// Center is normalized from the lower-left; width/height are fractions of the cropped source.
/// Rotation is counterclockwise in source pixels. Feather is the inward fraction of the
/// shape's unit radius: 0 is a hard edge; 0.2 softens the outer 20% of each half-axis.
public struct ShapeMask: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: ShapeMaskKind
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var rotation: Double
    public var feather: Double
    public init(kind: ShapeMaskKind = .ellipse, centerX: Double = 0.5, centerY: Double = 0.5,
                width: Double = 1, height: Double = 1, rotation: Double = 0, feather: Double = 0.05) {
        version = 1; self.kind = kind; self.centerX = centerX; self.centerY = centerY
        self.width = width; self.height = height; self.rotation = rotation; self.feather = feather
    }
    public var validationProblem: String? {
        guard version == 1 else { return "지원하지 않는 도형 마스크 버전입니다." }
        guard [centerX, centerY, width, height, rotation, feather].allSatisfy(\.isFinite) else { return "마스크 값은 유한한 숫자여야 합니다." }
        guard (-1...2).contains(centerX), (-1...2).contains(centerY) else { return "마스크 중심은 원본 크기의 -100~200% 범위여야 합니다." }
        guard (0.01...2).contains(width), (0.01...2).contains(height) else { return "마스크 가로·세로는 원본 크기의 1~200% 범위여야 합니다." }
        guard (-180...180).contains(rotation), (0...0.5).contains(feather) else { return "마스크 회전은 -180~180도, 테두리 부드러움은 0~50% 범위여야 합니다." }
        return nil
    }
}

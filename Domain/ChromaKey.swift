import Foundation

/// Stored key channels are gamma-encoded sRGB, not the compositor's linear working RGB.
/// Chromatic keys compare RGB proportions; neutral keys compare absolute linear RGB.
public struct ChromaKey: Codable, Equatable, Sendable {
    public var version: Int
    public var keyRed: Double
    public var keyGreen: Double
    public var keyBlue: Double
    public var similarity: Double
    public var softness: Double
    public var spillReduction: Double
    public init(keyRed: Double = 0, keyGreen: Double = 1, keyBlue: Double = 0,
                similarity: Double = 0.08, softness: Double = 0.12, spillReduction: Double = 0.5) {
        version = 1; self.keyRed = keyRed; self.keyGreen = keyGreen; self.keyBlue = keyBlue
        self.similarity = similarity; self.softness = softness; self.spillReduction = spillReduction
    }
    public var validationProblem: String? {
        guard version == 1 else { return "지원하지 않는 크로마키 버전입니다." }
        let values = [keyRed, keyGreen, keyBlue, similarity, softness, spillReduction]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }), similarity + softness <= 1 else {
            return "크로마키 값은 0~1의 유한한 값이며 유사도와 부드러움의 합은 1 이하여야 합니다."
        }
        return nil
    }
    public static func linearChannel(_ sRGB: Double) -> Double {
        sRGB <= 0.04045 ? sRGB / 12.92 : pow((sRGB + 0.055) / 1.055, 2.4)
    }
    public var linearRGB: [Double] { [keyRed, keyGreen, keyBlue].map(Self.linearChannel) }
    public var isChromatic: Bool {
        let values = linearRGB, high = values.max()!, low = values.min()!
        return high > 0.000001 && (high - low) / high > 0.05
    }
}

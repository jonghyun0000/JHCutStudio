import Foundation

public enum TimeArithmeticError: LocalizedError {
    case invalidTimescale, nonRepresentable
    public var errorDescription: String? {
        switch self {
        case .invalidTimescale: return "시간 기준값은 양수여야 합니다."
        case .nonRepresentable: return "시간 계산 결과가 저장 가능한 유리수 범위를 벗어났습니다."
        }
    }
}

/// Exact rational seconds. Ranges throughout the editor include their start and exclude their end.
public struct MediaTime: Codable, Hashable, Comparable, Sendable {
    public let value: Int64
    public let timescale: Int32
    public static let zero = MediaTime(0)

    public init(_ value: Int64, _ timescale: Int32 = 600) {
        precondition(timescale > 0, "MediaTime requires a positive timescale")
        let divisor = Self.gcd(value.magnitude, UInt64(timescale))
        self.value = value / Int64(divisor)
        self.timescale = timescale / Int32(divisor)
    }
    /// UI boundary conversion only; editing and frame calculations use rational arithmetic.
    public init(seconds: Double) {
        precondition(seconds.isFinite && abs(seconds) < Double(Int64.max) / 60_000, "Nonfinite or out-of-range time")
        self.init(Int64((seconds * 60_000).rounded()), 60_000)
    }
    public var seconds: Double { Double(value) / Double(timescale) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.value.multipliedFullWidth(by: Int64(rhs.timescale))
        let right = rhs.value.multipliedFullWidth(by: Int64(lhs.timescale))
        return left.high == right.high ? left.low < right.low : left.high < right.high
    }
    public func adding(_ other: Self) throws -> Self { try combining(other, subtract: false) }
    public func subtracting(_ other: Self) throws -> Self { try combining(other, subtract: true) }
    public func scaled(numerator: Int32, denominator: Int32) throws -> Self {
        guard numerator > 0, denominator > 0 else { throw TimeArithmeticError.invalidTimescale }
        let fractionGCD = Self.gcd(UInt64(numerator), UInt64(denominator))
        let n = UInt64(numerator) / fractionGCD, d = UInt64(denominator) / fractionGCD
        let cancelValue = Self.gcd(value.magnitude, d)
        let cancelScale = Self.gcd(UInt64(timescale), n)
        let product = (value / Int64(cancelValue)).multipliedReportingOverflow(by: Int64(n / cancelScale))
        let scale = (UInt64(timescale) / cancelScale).multipliedReportingOverflow(by: d / cancelValue)
        guard !product.overflow, !scale.overflow, let resultScale = Int32(exactly: scale.partialValue) else { throw TimeArithmeticError.nonRepresentable }
        return MediaTime(product.partialValue, resultScale)
    }
    private func combining(_ other: Self, subtract: Bool) throws -> Self {
        // Full-width products avoid overflowing before cancellation/normalization.
        // These operations are supported on macOS 14; Swift's Int128 requires macOS 15.
        let left = value.magnitude.multipliedFullWidth(by: UInt64(other.timescale))
        let right = other.value.magnitude.multipliedFullWidth(by: UInt64(timescale))
        let leftNegative = value < 0, rightNegative = (other.value < 0) != subtract
        let magnitude: (high: UInt64, low: UInt64)
        let negative: Bool
        if leftNegative == rightNegative {
            let sum = left.low.addingReportingOverflow(right.low)
            magnitude = (left.high + right.high + (sum.overflow ? 1 : 0), sum.partialValue)
            negative = leftNegative
        } else {
            let leftLarger = left.high > right.high || (left.high == right.high && left.low >= right.low)
            let large = leftLarger ? left : right, small = leftLarger ? right : left
            let difference = large.low.subtractingReportingOverflow(small.low)
            magnitude = (large.high - small.high - (difference.overflow ? 1 : 0), difference.partialValue)
            negative = leftLarger ? leftNegative : rightNegative
        }
        let denominator = UInt64(timescale) * UInt64(other.timescale)
        let remainder = denominator.dividingFullWidth((high: magnitude.high % denominator, low: magnitude.low)).remainder
        let divisor = Self.gcd(remainder, denominator)
        guard let resultScale = Int32(exactly: denominator / divisor), magnitude.high < divisor else { throw TimeArithmeticError.nonRepresentable }
        let quotient = divisor.dividingFullWidth(magnitude).quotient
        let resultValue: Int64
        if negative, quotient == UInt64(Int64.max) + 1 { resultValue = Int64.min }
        else {
            guard let signed = Int64(exactly: quotient) else { throw TimeArithmeticError.nonRepresentable }
            resultValue = negative ? -signed : signed
        }
        return MediaTime(resultValue, resultScale)
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        // Validation uses the throwing API. A programming error must never silently round or saturate time.
        do { return try lhs.adding(rhs) } catch { preconditionFailure(error.localizedDescription) }
    }
    public static func - (lhs: Self, rhs: Self) -> Self {
        do { return try lhs.subtracting(rhs) } catch { preconditionFailure(error.localizedDescription) }
    }
    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a, y = b
        while y != 0 { let remainder = x % y; x = y; y = remainder }
        return x == 0 ? 1 : x
    }
    private enum CodingKeys: String, CodingKey { case value, timescale }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scale = try container.decode(Int32.self, forKey: .timescale)
        guard scale > 0 else { throw DecodingError.dataCorruptedError(forKey: .timescale, in: container, debugDescription: "Timescale must be positive") }
        self.init(try container.decode(Int64.self, forKey: .value), scale)
    }
}

public struct FrameRate: Codable, Hashable, Sendable {
    public let numerator: Int32
    public let denominator: Int32
    public init(numerator: Int32 = 30, denominator: Int32 = 1) {
        precondition(numerator > 0 && denominator > 0, "Frame rate must be positive")
        self.numerator = numerator; self.denominator = denominator
    }
    public func time(forFrame frame: Int64) -> MediaTime {
        let product = frame.multipliedReportingOverflow(by: Int64(denominator))
        precondition(!product.overflow, "Frame index out of range")
        return MediaTime(product.partialValue, numerator)
    }
    private enum CodingKeys: String, CodingKey { case numerator, denominator }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int32.self, forKey: .numerator)
        let denominator = try container.decode(Int32.self, forKey: .denominator)
        guard numerator > 0, denominator > 0 else { throw DecodingError.dataCorruptedError(forKey: .numerator, in: container, debugDescription: "Frame rate must be positive") }
        self.init(numerator: numerator, denominator: denominator)
    }

    public var fps: Double { Double(numerator) / Double(denominator) }
    /// True for exact NTSC pulldown rates, whose frame duration is not a round number of seconds.
    public var isDrop: Bool { denominator == 1001 }

    /// Rates the renderer and exporter are verified against. Anything else is refused rather than
    /// silently re-timed, because a wrong frame duration desynchronises audio over a long timeline.
    public static let supportedRenderRates: [FrameRate] = [
        FrameRate(numerator: 24000, denominator: 1001),
        FrameRate(numerator: 24, denominator: 1),
        FrameRate(numerator: 25, denominator: 1),
        FrameRate(numerator: 30000, denominator: 1001),
        FrameRate(numerator: 30, denominator: 1),
        FrameRate(numerator: 50, denominator: 1),
        FrameRate(numerator: 60000, denominator: 1001),
        FrameRate(numerator: 60, denominator: 1)
    ]
    public var isSupportedRenderRate: Bool { Self.supportedRenderRates.contains(self) }

    /// "23.976" / "30" — the form editors print, not the raw rational.
    public var label: String {
        isDrop ? String(format: "%.3f", fps) : String(numerator / denominator)
    }
}

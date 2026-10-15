import Foundation

// MARK: - Speed ramp (priority 3 after the Final Cut comparison)

/// A speed ramp is built from ordinary clips: the source range is cut into equal pieces and each
/// piece gets its own constant speed. Every other tool (trim, split, captions, save) keeps working
/// because the result is nothing but normal clips with a `playbackRate`.
public enum SpeedRampPreset: String, CaseIterable, Sendable {
    case slowDown, speedUp, slowAndBack, fastAndBack
    public var label: String {
        switch self {
        case .slowDown: return "서서히 느리게 (1배 → 0.3배)"
        case .speedUp: return "서서히 빠르게 (1배 → 3배)"
        case .slowAndBack: return "느려졌다가 돌아오기 (1 → 0.3 → 1배)"
        case .fastAndBack: return "빨라졌다가 돌아오기 (1 → 3 → 1배)"
        }
    }
    /// Speed at a position `f` (0…1) along the source range, interpolated in log-speed so that
    /// “twice as fast” and “half as fast” are equally far from 1×.
    public func speed(at f: Double) -> Double {
        let e = Easing.inOut(f)
        switch self {
        case .slowDown: return exp(log(1.0) + (log(0.3) - log(1.0)) * e)
        case .speedUp: return exp(log(3.0) * e)
        case .slowAndBack: return exp(log(0.3) * sin(.pi * f))
        case .fastAndBack: return exp(log(3.0) * sin(.pi * f))
        }
    }
}

public enum SpeedRampPlan {
    public static let allowedPieces = 2...24
    /// Shortest piece (in the clip's current timeline length) a ramp may be cut into.
    public static let minimumPieceSeconds = 0.1
    public static let speedRange = 0.25...4.0
    /// Speeds a ramp may use: fractions a/b with a ≤ 8. A piece of speed a/b lasts (length × b/a), so every piece
    /// length has a denominator that divides 840; arbitrary speeds such as 89/100 and 61/100 would make the sum of
    /// the piece lengths overflow the stored 32-bit denominator after a few pieces.
    static let grid: [(speed: Double, rate: PlaybackRate)] = {
        var seen = Set<String>(), result: [(Double, PlaybackRate)] = []
        func gcd(_ a: Int32, _ b: Int32) -> Int32 { b == 0 ? a : gcd(b, a % b) }
        for a in Int32(1)...8 { for b in Int32(1)...32 {
            let speed = Double(a) / Double(b)
            guard speedRange.contains(speed) else { continue }
            let g = gcd(a, b), key = "\(a / g)/\(b / g)"
            if seen.insert(key).inserted { result.append((speed, PlaybackRate(numerator: a / g, denominator: b / g))) }
        } }
        return result.sorted { $0.0 < $1.0 }
    }()
    /// The allowed speed closest to `speed` (compared in log-speed), clamped to the supported range.
    public static func rate(_ speed: Double) -> PlaybackRate {
        let clamped = min(speedRange.upperBound, max(speedRange.lowerBound, speed))
        return grid.min { abs(log($0.speed / clamped)) < abs(log($1.speed / clamped)) }!.rate
    }
    /// Speed of each piece, sampled in the middle of the piece.
    public static func rates(_ preset: SpeedRampPreset, pieces: Int) -> [PlaybackRate] {
        (0..<pieces).map { rate(preset.speed(at: (Double($0) + 0.5) / Double(pieces))) }
    }
    /// Straight ramp between two speeds (custom), eased.
    public static func rates(from start: Double, to end: Double, pieces: Int) -> [PlaybackRate] {
        (0..<pieces).map { i in
            let e = Easing.inOut((Double(i) + 0.5) / Double(pieces))
            return rate(exp(log(start) + (log(end) - log(start)) * e))
        }
    }
    /// How many pieces suit a clip: about 8 per second of timeline, within the allowed range and piece length.
    public static func suggestedPieces(timelineSeconds: Double) -> Int {
        let wanted = Int((timelineSeconds * 8).rounded())
        let possible = Int(timelineSeconds / minimumPieceSeconds)
        return max(allowedPieces.lowerBound, min(allowedPieces.upperBound, wanted, possible))
    }
}

// MARK: - Freeze frame

public enum FreezeFrame {
    public static let secondsRange = 0.5...10.0
    /// Source time shown at timeline time `time` inside `clip` (rate and trim applied).
    public static func sourceTime(of clip: Clip, at time: MediaTime) throws -> MediaTime {
        let rate = clip.playbackRate ?? PlaybackRate()
        return try clip.sourceStart.adding(try time.subtracting(clip.start).scaled(numerator: rate.numerator, denominator: rate.denominator))
    }
}

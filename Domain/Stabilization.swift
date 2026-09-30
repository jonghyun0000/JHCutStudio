import Foundation

/// Camera path estimated from the source video, stored with the clip so that preview, export and
/// re-opening a project all use the same numbers. The path is measured once (analysis); how much
/// of it is removed is decided at render time by `strength` and `smoothing`, so those can be
/// changed without analysing again.
///
/// Axes follow Core Image, in the frame as decoded (before the track's rotation is applied):
/// x to the right, y UP, angle counter-clockwise. `x`/`y` are the cumulative displacement of the
/// picture content relative to the first analysed frame, as a fraction of frame width/height.
public struct StabilizationData: Codable, Equatable, Sendable {
    public static let maximumSamples = 60_000
    public static let strengthRange = 0.0...1.0
    public static let smoothingRange = 0.1...3.0
    public var enabled: Bool
    /// 0 = off, 1 = the whole difference between the measured and the smoothed path is removed.
    public var strength: Double
    /// Gaussian sigma in seconds. Larger = steadier, but slow intentional moves are followed later.
    public var smoothing: Double
    /// Seconds between samples.
    public var step: Double
    /// Source time of sample 0.
    public var analyzedStart: MediaTime
    /// Decoded frame size the fractions refer to (aspect ratio matters for rotation).
    public var frameWidth: Int
    public var frameHeight: Int
    public var x: [Float]
    public var y: [Float]
    public var angle: [Float]
    /// Frame pairs whose estimate was implausible (scene change, fast whip pan) and treated as no motion.
    public var rejectedSteps: Int
    public init(enabled: Bool = true, strength: Double = 1, smoothing: Double = 0.8, step: Double, analyzedStart: MediaTime, frameWidth: Int, frameHeight: Int,
                x: [Float], y: [Float], angle: [Float], rejectedSteps: Int = 0) {
        self.enabled = enabled; self.strength = strength; self.smoothing = smoothing; self.step = step; self.analyzedStart = analyzedStart
        self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.x = x; self.y = y; self.angle = angle; self.rejectedSteps = rejectedSteps
    }
    public var count: Int { x.count }
    public var analyzedDuration: Double { Double(max(0, count - 1)) * step }
    public var analyzedRange: ClosedRange<Double> { analyzedStart.seconds...(analyzedStart.seconds + analyzedDuration) }
    public func covers(_ sourceStart: MediaTime, duration: MediaTime) -> Bool {
        count >= 2 && sourceStart.seconds >= analyzedStart.seconds - 0.001 && (sourceStart + duration).seconds <= analyzedStart.seconds + analyzedDuration + step
    }
    /// Structural checks used by the project validator; a damaged block must be refused, not rendered.
    public var validationProblem: String? {
        guard x.count == y.count, y.count == angle.count, x.count <= Self.maximumSamples else { return "안정화 경로의 길이가 올바르지 않습니다." }
        guard step.isFinite, step > 0.001, step < 1, frameWidth > 0, frameHeight > 0, frameWidth <= 16_384, frameHeight <= 16_384 else { return "안정화 분석 정보가 올바르지 않습니다." }
        guard strength.isFinite, Self.strengthRange.contains(strength), smoothing.isFinite, Self.smoothingRange.contains(smoothing) else { return "안정화 강도·부드러움 값이 범위를 벗어났습니다." }
        guard x.allSatisfy({ $0.isFinite && abs($0) < 50 }), y.allSatisfy({ $0.isFinite && abs($0) < 50 }), angle.allSatisfy({ $0.isFinite && abs($0) < 200 }) else { return "안정화 경로에 유효하지 않은 값이 있습니다." }
        return nil
    }
}

/// Per-frame corrections derived from `StabilizationData`: smoothed path minus measured path,
/// limited so the picture never shows outside its edges after one constant zoom.
public final class StabilizationPlan: @unchecked Sendable {
    public struct Correction: Equatable, Sendable {
        public var x: Double      // fraction of frame width, CI axes
        public var y: Double      // fraction of frame height
        public var angle: Double  // radians, counter-clockwise
    }
    public static let maximumZoom = 1.25
    /// Share of frames whose full correction must fit inside the zoom (the rest are scaled down).
    public static let coverageQuantile = 0.9

    public let zoom: Double
    /// Frames whose correction was cut by more than 10 % because the shake needed more than the maximum zoom (parts of the shake remain there).
    public let limitedSamples: Int
    private let start: Double
    private let step: Double
    private let values: [Correction]

    /// `unlimited` skips the zoom/limit step; used only to MEASURE how far a path is from its smoothed version.
    public init?(_ data: StabilizationData, unlimited: Bool = false) {
        guard data.enabled, data.strength > 0, data.count >= 2, data.validationProblem == nil else { return nil }
        let n = data.count
        // Gaussian-smoothed path (edges replicated), computed with a sliding kernel.
        let sigma = max(data.smoothing / data.step, 0.5)
        let radius = min(Int((sigma * 3).rounded(.up)), n)
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let norm = kernel.reduce(0, +); kernel = kernel.map { $0 / norm }
        func smooth(_ path: [Float]) -> [Double] {
            (0..<n).map { i in
                var sum = 0.0
                for (k, w) in kernel.enumerated() { sum += w * Double(path[min(n - 1, max(0, i + k - radius))]) }
                return sum
            }
        }
        let sx = smooth(data.x), sy = smooth(data.y), sa = smooth(data.angle)
        var wanted = (0..<n).map { i in
            Correction(x: (sx[i] - Double(data.x[i])) * data.strength, y: (sy[i] - Double(data.y[i])) * data.strength, angle: (sa[i] - Double(data.angle[i])) * data.strength)
        }
        if unlimited { zoom = 1; limitedSamples = 0; values = wanted; start = data.analyzedStart.seconds; step = data.step; return }
        let aspect = Double(data.frameWidth) / Double(data.frameHeight)
        let required = wanted.map { Self.requiredZoom($0, aspect: aspect) }.sorted()
        let z = min(Self.maximumZoom, max(1, required[min(required.count - 1, Int(Double(required.count - 1) * Self.coverageQuantile))]))
        var limited = 0
        for i in wanted.indices where Self.requiredZoom(wanted[i], aspect: aspect) > z + 1e-9 {
            // Keep the direction of the correction and shrink it until the zoom covers it.
            var lo = 0.0, hi = 1.0
            for _ in 0..<14 {
                let mid = (lo + hi) / 2
                let c = Correction(x: wanted[i].x * mid, y: wanted[i].y * mid, angle: wanted[i].angle * mid)
                if Self.requiredZoom(c, aspect: aspect) <= z { lo = mid } else { hi = mid }
            }
            wanted[i] = Correction(x: wanted[i].x * lo, y: wanted[i].y * lo, angle: wanted[i].angle * lo)
            // Reported only when the zoom cap itself is reached: below it the trim of the strongest 10 % of frames is by design and invisible.
            if z >= Self.maximumZoom - 1e-9, lo < 0.9 { limited += 1 }
        }
        zoom = z; limitedSamples = limited; values = wanted; start = data.analyzedStart.seconds; step = data.step
    }

    /// Correction at a source time (linear between samples, held outside the analysed range).
    public func correction(atSource time: Double) -> Correction {
        let position = (time - start) / step
        guard position > 0 else { return values[0] }
        let i = Int(position)
        guard i < values.count - 1 else { return values[values.count - 1] }
        let f = position - Double(i), a = values[i], b = values[i + 1]
        return Correction(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, angle: a.angle + (b.angle - a.angle) * f)
    }

    /// Smallest uniform zoom about the centre for which a picture translated by (x·W, y·H) and
    /// rotated by `angle` still covers the whole frame. Exact (all four corners).
    public static func requiredZoom(_ c: Correction, aspect: Double) -> Double {
        // Work in units where the frame is 2·aspect wide and 2 tall (half extents a, 1).
        let a = aspect, b = 1.0
        let tx = c.x * 2 * a, ty = c.y * 2 * b
        let cosA = cos(-c.angle), sinA = sin(-c.angle)
        var zoom = 1.0
        for (px, py) in [(-a, -b), (a, -b), (-a, b), (a, b)] {
            let qx = px - tx, qy = py - ty                       // undo the translation
            let ux = qx * cosA - qy * sinA, uy = qx * sinA + qy * cosA   // undo the rotation
            zoom = max(zoom, abs(ux) / a, abs(uy) / b)
        }
        return zoom
    }
}

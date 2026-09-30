import Foundation
import Accelerate

/// Camera motion between two frames, robust to moving subjects.
///
/// The frame is cut into 64×64 tiles. Each tile's translation comes from phase correlation
/// (sub-pixel, via FFT); tiles without texture or without a clear peak are dropped. A similarity
/// model (translation + small rotation about the centre) is then fitted to the tile translations
/// with iteratively re-weighted least squares (Tukey weights), so tiles that follow a moving
/// subject rather than the camera become outliers instead of pulling the estimate.
///
/// Axes are Core Image's: x to the right, y UP, angle counter-clockwise. Units are pixels of the
/// analysed frame until the caller normalises them.
public struct MotionEstimate: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var angle: Double
    /// Tiles that agreed with the fitted camera motion / tiles that had usable texture.
    public var inliers: Int
    public var usable: Int
}

public final class MotionEstimator {
    public static let tile = 64
    /// Normalised phase-correlation peak below this is treated as "no clear match".
    static let minimumPeak: Float = 0.10
    /// Luma standard deviation below this (0…1) means a flat tile (sky, blank wall).
    static let minimumTexture: Float = 0.015
    static let minimumInliers = 5

    public let width: Int
    public let height: Int
    private let columns: Int, rows: Int
    private let originX: Int, originY: Int
    private let setup: FFTSetup
    private let window: [Float]
    private var a: ([Float], [Float]), b: ([Float], [Float]), scratch: [Float]

    public init?(width: Int, height: Int) {
        guard width >= 2 * Self.tile, height >= 2 * Self.tile,
              let setup = vDSP_create_fftsetup(6, FFTRadix(kFFTRadix2)) else { return nil }
        self.width = width; self.height = height; self.setup = setup
        columns = width / Self.tile; rows = height / Self.tile
        originX = (width - columns * Self.tile) / 2; originY = (height - rows * Self.tile) / 2
        // 2-D Hann window: keeps the tile edges from creating fake correlation.
        let n = Self.tile
        let hann = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
        window = (0..<n * n).map { hann[$0 / n] * hann[$0 % n] }
        let zero = [Float](repeating: 0, count: n * n)
        a = (zero, zero); b = (zero, zero); scratch = zero
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// `previous` and `current` are luma planes (0…1), row-major, top row first, `width × height`.
    /// Returns nil when too few tiles agree (blank frames, scene change, extreme blur).
    public func estimate(previous: [Float], current: [Float]) -> MotionEstimate? {
        guard previous.count == width * height, current.count == width * height else { return nil }
        struct Sample { var x: Double; var y: Double; var dx: Double; var dy: Double }
        var samples: [Sample] = []
        let n = Self.tile
        for r in 0..<rows {
            for c in 0..<columns {
                let x0 = originX + c * n, y0 = originY + r * n
                guard let shift = shift(previous, current, x0, y0) else { continue }
                // Tile centre relative to the frame centre, y up.
                samples.append(Sample(x: Double(x0 + n / 2) - Double(width) / 2, y: Double(height) / 2 - Double(y0 + n / 2), dx: shift.0, dy: -shift.1))
            }
        }
        guard samples.count >= Self.minimumInliers else { return nil }
        // Start from the per-axis median (robust), then refine T and θ with Tukey-weighted least squares.
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        var tx = median(samples.map(\.dx)), ty = median(samples.map(\.dy)), theta = 0.0
        var weights = [Double](repeating: 1, count: samples.count)
        for _ in 0..<8 {
            let residuals = samples.map { s in hypot(s.dx - (tx - theta * s.y), s.dy - (ty + theta * s.x)) }
            let scale = max(1.4826 * median(residuals), 0.05)
            let cutoff = 4.685 * scale
            weights = residuals.map { $0 < cutoff ? pow(1 - pow($0 / cutoff, 2), 2) : 0 }
            // Normal equations of  dx = Tx − θ·y ,  dy = Ty + θ·x  (3 unknowns).
            var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3), rhs = [Double](repeating: 0, count: 3)
            for (s, w) in zip(samples, weights) where w > 0 {
                let rowX = [1.0, 0.0, -s.y], rowY = [0.0, 1.0, s.x]
                for i in 0..<3 {
                    for j in 0..<3 { m[i][j] += w * (rowX[i] * rowX[j] + rowY[i] * rowY[j]) }
                    rhs[i] += w * (rowX[i] * s.dx + rowY[i] * s.dy)
                }
            }
            guard let solved = Self.solve3(m, rhs) else { break }
            tx = solved[0]; ty = solved[1]; theta = solved[2]
        }
        let inliers = weights.filter { $0 > 0.3 }.count
        guard inliers >= Self.minimumInliers, tx.isFinite, ty.isFinite, theta.isFinite else { return nil }
        return MotionEstimate(dx: tx, dy: ty, angle: theta, inliers: inliers, usable: samples.count)
    }

    static func solve3(_ m: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { k in
            var t = m
            for i in 0..<3 { t[i][k] = b[i] }
            return det(t) / d
        }
    }

    /// Translation (pixels, x right, y DOWN in buffer rows) of `current` relative to `previous` inside one tile.
    private func shift(_ previous: [Float], _ current: [Float], _ x0: Int, _ y0: Int) -> (Double, Double)? {
        let n = Self.tile
        func load(_ image: [Float], into target: inout ([Float], [Float])) -> Float? {
            var sum: Float = 0, sumSquares: Float = 0
            for y in 0..<n { let row = (y0 + y) * width + x0; for x in 0..<n { let v = image[row + x]; sum += v; sumSquares += v * v } }
            let count = Float(n * n), mean = sum / count, variance = sumSquares / count - mean * mean
            let deviation = variance > 0 ? variance.squareRoot() : 0
            guard deviation >= Self.minimumTexture else { return nil }
            for y in 0..<n { let row = (y0 + y) * width + x0; for x in 0..<n { target.0[y * n + x] = (image[row + x] - mean) * window[y * n + x] } }
            for i in 0..<(n * n) { target.1[i] = 0 }
            return deviation
        }
        var ta = a, tb = b   // local copies: the FFT closures must not touch self's storage
        guard load(previous, into: &ta) != nil, load(current, into: &tb) != nil else { return nil }
        let count = n * n, fftSetup = setup
        var ar = ta.0, ai = ta.1, br = tb.0, bi = tb.1
        ar.withUnsafeMutableBufferPointer { arp in ai.withUnsafeMutableBufferPointer { aip in
            br.withUnsafeMutableBufferPointer { brp in bi.withUnsafeMutableBufferPointer { bip in
                var fa = DSPSplitComplex(realp: arp.baseAddress!, imagp: aip.baseAddress!), fb = DSPSplitComplex(realp: brp.baseAddress!, imagp: bip.baseAddress!)
                vDSP_fft2d_zip(fftSetup, &fa, 1, 0, 6, 6, FFTDirection(kFFTDirection_Forward))
                vDSP_fft2d_zip(fftSetup, &fb, 1, 0, 6, 6, FFTDirection(kFFTDirection_Forward))
                // Cross-power spectrum  F(current) · conj(F(previous))  normalised to unit magnitude.
                for i in 0..<count {
                    let re = brp[i] * arp[i] + bip[i] * aip[i], im = bip[i] * arp[i] - brp[i] * aip[i]
                    let magnitude = max((re * re + im * im).squareRoot(), 1e-9)
                    arp[i] = re / magnitude; aip[i] = im / magnitude
                }
                vDSP_fft2d_zip(fftSetup, &fa, 1, 0, 6, 6, FFTDirection(kFFTDirection_Inverse))
            } }
        } }
        let surface = ar
        // `surface` is the correlation surface (scaled by n²). Find its peak.
        var peak: Float = -Float.infinity, peakIndex = 0
        for i in 0..<count where surface[i] > peak { peak = surface[i]; peakIndex = i }
        let scaled = peak / Float(count)
        guard scaled >= Self.minimumPeak else { return nil }
        let py = peakIndex / n, px = peakIndex % n
        func at(_ x: Int, _ y: Int) -> Float { surface[((y + n) % n) * n + ((x + n) % n)] }
        // Parabolic sub-pixel refinement on each axis.
        func refine(_ minus: Float, _ centre: Float, _ plus: Float) -> Double {
            let d = minus - 2 * centre + plus
            return d < 0 ? Double(0.5 * (minus - plus) / d) : 0
        }
        let sx = refine(at(px - 1, py), at(px, py), at(px + 1, py)), sy = refine(at(px, py - 1), at(px, py), at(px, py + 1))
        var dx = Double(px) + sx, dy = Double(py) + sy
        if dx > Double(n) / 2 { dx -= Double(n) }
        if dy > Double(n) / 2 { dy -= Double(n) }
        return (dx, dy)
    }
}

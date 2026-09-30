import Foundation
@preconcurrency import AVFoundation
import Accelerate

public struct StabilizationError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Measures camera motion between successive frames on downscaled copies of the decoded frames
/// with `MotionEstimator` (tile-wise phase correlation + robust similarity fit, so a large moving
/// subject does not read as camera shake). Read-only: the source file is only decoded.
public enum StabilizationAnalyzer {
    /// Longest clip analysed in one go (keeps the stored path a few hundred KB).
    public static let maximumSeconds = 600.0
    public static let sampleStep = 1.0 / 30.0
    /// Longest side of the frames handed to the estimator.
    public static let analysisSize = 480.0
    /// Plausibility limits for one step between samples; beyond them the step counts as no motion.
    static let maximumStepTranslation = 0.15
    static let maximumStepAngle = 8.0 * Double.pi / 180

    public static func analyze(url: URL, sourceStart: MediaTime, duration: MediaTime,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> StabilizationData {
        guard url.isFileURL, duration > .zero else { throw StabilizationError("분석할 영상 구간을 확인하세요.") }
        guard duration.seconds <= maximumSeconds else {
            throw StabilizationError("손떨림 분석은 클립당 \(Int(maximumSeconds / 60))분까지 가능합니다. 클립을 나눈 뒤 각각 분석하세요.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StabilizationError("이 미디어에는 영상 트랙이 없습니다.") }
        let natural = try await track.load(.naturalSize)
        guard natural.width > 0, natural.height > 0 else { throw StabilizationError("영상 크기를 읽지 못했습니다.") }
        let assetDuration = try await asset.load(.duration).seconds
        guard sourceStart.seconds >= 0, sourceStart.seconds + duration.seconds <= assetDuration + 0.05 else { throw StabilizationError("분석 구간이 원본 길이를 벗어납니다.") }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: sourceStart.cmTime, duration: duration.cmTime)
        let scale = analysisSize / max(natural.width, natural.height)
        let width = max(64, Int((natural.width * scale).rounded())), height = max(64, Int((natural.height * scale).rounded()))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StabilizationError("영상 디코더를 구성하지 못했습니다.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? StabilizationError("영상 읽기를 시작하지 못했습니다.") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let total = duration.seconds
        var x: [Float] = [0], y: [Float] = [0], angle: [Float] = [0]
        var cumulative = (x: 0.0, y: 0.0, a: 0.0), lastIndex = 0, rejected = 0
        var previous: [Float]?
        var firstTime: Double?
        guard let estimator = MotionEstimator(width: width, height: height) else { throw StabilizationError("분석 프레임이 너무 작습니다.") }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if firstTime == nil { firstTime = time }
                let index = Int(((time - (firstTime ?? time)) / sampleStep).rounded())
                if previous == nil { previous = Self.luma(buffer, width: width, height: height); lastIndex = 0; return }
                guard index > lastIndex else { return }   // keep one frame per 1/30 s
                let current = Self.luma(buffer, width: width, height: height)
                var delta = (x: 0.0, y: 0.0, a: 0.0)
                if let m = estimator.estimate(previous: previous!, current: current) {
                    let dx = m.dx / Double(width), dy = m.dy / Double(height)
                    if abs(dx) <= maximumStepTranslation, abs(dy) <= maximumStepTranslation, abs(m.angle) <= maximumStepAngle { delta = (dx, dy, m.angle) } else { rejected += 1 }
                } else { rejected += 1 }
                // Frames the reader skipped are filled by holding the same velocity.
                let gap = index - lastIndex
                for k in 1...gap {
                    let f = Double(k) / Double(gap)
                    x.append(Float(cumulative.x + delta.x * f)); y.append(Float(cumulative.y + delta.y * f)); angle.append(Float(cumulative.a + delta.a * f))
                }
                cumulative = (cumulative.x + delta.x, cumulative.y + delta.y, cumulative.a + delta.a); lastIndex = index; previous = current
                if x.count > StabilizationData.maximumSamples { throw StabilizationError("분석 구간이 너무 깁니다.") }
                if index % 30 == 0 { progress?(min(1, Double(index) * sampleStep / total)) }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? StabilizationError("영상 디코딩이 완료되지 않았습니다.") }
        guard x.count >= 3 else { throw StabilizationError("분석할 프레임이 충분하지 않습니다(최소 0.1초).") }
        progress?(1)
        func rounded(_ v: [Float]) -> [Float] { v.map { ($0 * 100_000).rounded() / 100_000 } }
        return StabilizationData(step: sampleStep, analyzedStart: sourceStart, frameWidth: Int(natural.width), frameHeight: Int(natural.height),
                                 x: rounded(x), y: rounded(y), angle: rounded(angle), rejectedSteps: rejected)
    }

    /// BGRA pixel buffer → luma plane (0…1), row-major, top row first.
    static func luma(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var out = [Float](repeating: 0, count: width * height)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return out }
        let stride = CVPixelBufferGetBytesPerRow(buffer), w = min(width, CVPixelBufferGetWidth(buffer)), h = min(height, CVPixelBufferGetHeight(buffer))
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { out[y * width + x] = (0.114 * Float(row[x * 4]) + 0.587 * Float(row[x * 4 + 1]) + 0.299 * Float(row[x * 4 + 2])) / 255 }
        }
        return out
    }
}

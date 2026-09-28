import Foundation
import AVFoundation
import AudioToolbox

/// A single-use export job. Only one encoder runs within a job; cancellation is safe from any thread.
public final class ExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private let minimumFreeSpaceOverride: Int64?
    public enum Codec: String, CaseIterable, Codable, Sendable { case h264, hevc, proRes422
        public var label: String { switch self { case .h264: return "H.264 · 호환성"; case .hevc: return "HEVC · 고효율"; case .proRes422: return "ProRes 422 · 편집용" } }
        public var fileExtension: String { self == .proRes422 ? "mov" : "mp4" }
        var avCodec: AVVideoCodecType { switch self { case .h264: return .h264; case .hevc: return .hevc; case .proRes422: return .proRes422 } }
    }
    private let codec: Codec
    private let videoBitRate: Int
    /// Tiers, not a free-form number: the encoder is validated at these rates only. The upper tiers
    /// exist for 4K, where 8Mbps is not a usable picture.
    public static let supportedVideoBitRates = [4_000_000, 8_000_000, 16_000_000, 24_000_000, 40_000_000, 64_000_000]

    /// Quality relative to the canvas, since a fixed Mbps means something different at 1080 and 4K.
    public enum Quality: String, CaseIterable, Sendable { case small, standard, high }

    /// Nearest supported tier for a canvas, from bits-per-pixel-per-frame targets that hold across
    /// resolutions. Rounds to a tier so the exporter's validation stays a closed set.
    public static func recommendedBitRate(width: Int, height: Int, fps: Double, quality: Quality = .standard) -> Int {
        let bitsPerPixel: Double
        switch quality {
        case .small: return supportedVideoBitRates.first ?? 4_000_000
        case .standard: bitsPerPixel = 0.10
        case .high: bitsPerPixel = 0.20
        }
        let target = Double(max(1, width * height)) * max(1, fps) * bitsPerPixel
        return supportedVideoBitRates.min { abs(Double($0) - target) < abs(Double($1) - target) } ?? 8_000_000
    }
    /// Raises the preflight threshold for controlled low-space tests; it never bypasses the normal minimum.
    public init(minimumFreeSpaceOverride: Int64? = nil, videoBitRate: Int = 8_000_000, codec: Codec = .h264) { self.codec = codec; self.minimumFreeSpaceOverride = minimumFreeSpaceOverride; self.videoBitRate = videoBitRate }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw MediaEngineError.cancelled }
        guard !started else { throw MediaEngineError.invalid("새 출력을 위해 새 작업을 만드세요.") }
        started = true
    }
    public func export(plan: RenderPlan, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard Self.supportedVideoBitRates.contains(videoBitRate) else {
            throw MediaEngineError.invalid("지원 출력 비트레이트는 4, 8, 16, 24, 40, 64Mbps입니다.")
        }
        guard !plan.usesProxyMedia else { throw MediaEngineError.invalid("프록시 미리보기는 출력할 수 없습니다. 원본 미디어로 출력 계획을 만드세요.") }
        try begin()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue(label: "studio.jhcut.export", qos: .userInitiated).async {
                    do { try self.run(plan: plan, to: destination, progress: progress); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func run(plan: RenderPlan, to destination: URL, progress: @escaping (Double) -> Void) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        guard destination.isFileURL, destination.pathExtension.lowercased() == codec.fileExtension else { throw MediaEngineError.invalid("선택한 형식의 출력 확장자는 .\(codec.fileExtension)입니다.") }
        guard !fileManager.fileExists(atPath: destination.path) else { throw MediaEngineError.failed("기존 파일은 덮어쓰지 않습니다: \(destination.lastPathComponent)") }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isWritableFile(atPath: directory.path) else { throw MediaEngineError.failed("출력 폴더에 쓸 수 없습니다: \(directory.path)") }
        let resources = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // External ExFAT volumes can report zero for the APFS-specific important-usage key.
        let filesystem = try fileManager.attributesOfFileSystem(forPath: directory.path)
        let filesystemFree = (filesystem[.systemFreeSize] as? NSNumber)?.int64Value
        let importantFree = resources?.volumeAvailableCapacityForImportantUsage
        let availableFree = (importantFree ?? 0) > 0 ? importantFree : filesystemFree
        let estimatedRate = codec == .proRes422 ? max(videoBitRate, Int(plan.videoComposition.renderSize.width * plan.videoComposition.renderSize.height * 4 / plan.frameDuration.seconds)) : videoBitRate
        let estimate = max(Int64(plan.duration.seconds * Double(estimatedRate + 192_000) / 8 * 1.2) + 64 * 1_024 * 1_024, minimumFreeSpaceOverride ?? 0)
        if let available = availableFree, available < estimate {
            throw MediaEngineError.failed("출력 공간이 부족합니다. 최소 예상 필요 공간: \(estimate / 1_048_576)MB, 사용 가능: \(available / 1_048_576)MB")
        }
        if isCancelled { throw MediaEngineError.cancelled }
        // Keep AVAssetWriter's asynchronous .sb-* sidecars inside this job's private scratch directory.
        let scratch = directory.appendingPathComponent(".JHCut-export-\(UUID().uuidString).partial", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: false)
        let temporary = scratch.appendingPathComponent("render.partial." + codec.fileExtension)
        defer { try? fileManager.removeItem(at: scratch) }
        let reader = try AVAssetReader(asset: plan.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: plan.duration)
        let videoTracks = plan.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        videoOutput.videoComposition = plan.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw MediaEngineError.failed("영상 합성 디코더를 만들 수 없습니다.") }
        reader.add(videoOutput)
        let audioTracks = plan.composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
            output.audioMix = plan.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaEngineError.failed("오디오 믹서 생성에 실패했습니다.") }
            reader.add(output); audioOutput = output
        }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: codec == .proRes422 ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let frameRate = 1.0 / plan.frameDuration.seconds
        var videoSettings: [String: Any] = [AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(plan.videoComposition.renderSize.width), AVVideoHeightKey: Int(plan.videoComposition.renderSize.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        if codec != .proRes422 {
            var compression: [String: Any] = [AVVideoAverageBitRateKey: videoBitRate, AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate), AVVideoAllowFrameReorderingKey: false]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw MediaEngineError.failed("선택한 영상 인코더를 만들 수 없습니다.") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MediaEngineError.failed("AAC 인코더를 만들 수 없습니다.") }
            writer.add(input); audioInput = input
        }
        var committed = false
        defer {
            if !committed { reader.cancelReading(); writer.cancelWriting() }
        }
        guard writer.startWriting() else { throw writer.error ?? MediaEngineError.failed("출력 파일 생성에 실패했습니다.") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? MediaEngineError.failed("미디어 읽기를 시작할 수 없습니다.") }
        var videoDone = false, audioDone = audioOutput == nil
        var frames = 0
        var lastProgress = -1.0
        var lastActivity = Date()
        progress(0)
        while !videoDone || !audioDone {
            if isCancelled { throw MediaEngineError.cancelled }
            if reader.status == .failed { throw reader.error ?? MediaEngineError.failed("미디어 읽기 오류") }
            if writer.status == .failed { throw writer.error ?? MediaEngineError.failed("출력 쓰기 오류: 디스크 공간과 권한을 확인하세요.") }
            var advanced = false
            if !videoDone && videoInput.isReadyForMoreMediaData {
                try autoreleasepool {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else { throw writer.error ?? MediaEngineError.failed("영상 프레임 쓰기 실패") }
                        frames += 1
                        let fraction = min(0.99, (CMSampleBufferGetPresentationTimeStamp(sample).seconds + plan.frameDuration.seconds) / plan.duration.seconds)
                        if fraction - lastProgress >= 0.01 { progress(fraction); lastProgress = fraction }
                    } else { videoInput.markAsFinished(); videoDone = true }
                }
                advanced = true
            }
            if !audioDone, let input = audioInput, let output = audioOutput, input.isReadyForMoreMediaData {
                try autoreleasepool {
                    if let sample = output.copyNextSampleBuffer() {
                        guard input.append(sample) else { throw writer.error ?? MediaEngineError.failed("오디오 샘플 쓰기 실패") }
                    } else { input.markAsFinished(); audioDone = true }
                }
                advanced = true
            }
            if advanced { lastActivity = Date() }
            else {
                guard Date().timeIntervalSince(lastActivity) < 60 else { throw MediaEngineError.failed("출력이 60초 동안 진행되지 않아 중단했습니다.") }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? MediaEngineError.failed("모든 미디어 샘플을 읽지 못했습니다.") }
        let expectedFrames = Int(ceil(plan.duration.seconds / plan.frameDuration.seconds - 0.000_001))
        guard frames == expectedFrames else { throw MediaEngineError.failed("프레임 수가 예상과 다릅니다: \(frames) / \(expectedFrames)") }
        writer.endSession(atSourceTime: plan.duration)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if isCancelled { writer.cancelWriting(); throw MediaEngineError.cancelled }
        }
        if isCancelled { throw MediaEngineError.cancelled }
        guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("MP4 마무리에 실패했습니다.") }
        // The private scratch directory is on the destination volume, so this final rename is atomic.
        // moveItem also rejects a destination created during encoding.
        try fileManager.moveItem(at: temporary, to: destination)
        committed = true
        progress(1)
    }
}

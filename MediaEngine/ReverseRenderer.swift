import Foundation
@preconcurrency import AVFoundation
import CoreVideo

/// Writes a reversed copy (picture and sound) of part of a video file. AVFoundation cannot play a
/// track backwards, so reverse playback needs a real file. The source is only read.
///
/// Memory stays bounded: frames are decoded a short chunk at a time, starting from the END of the
/// range, and written out in reverse order. Frame timing is mirrored, so variable frame rates and
/// the track's rotation are kept.
public enum ReverseRenderer {
    public static let maximumSeconds = 120.0
    /// Upper bound for decoded frames held at once.
    static let chunkBytes = 256 * 1024 * 1024
    /// The MP4 writer interleaves in chunks of about a second: with less sound queued ahead of the picture it
    /// reports the picture input as "not ready" and both wait for each other.
    static let audioLead = 3.0
    static let writerStallSeconds = 30.0

    /// Shared by both inputs: readiness must never hide a failed or stalled encoder.
    static func checkWriter(status: AVAssetWriter.Status, error: Error?, idleSeconds: Double) throws {
        guard status == .writing else { throw error ?? MediaEngineError.failed("역재생 기록기가 중단되었습니다.") }
        guard idleSeconds < writerStallSeconds else { throw MediaEngineError.failed("역재생 기록기가 30초 동안 진행되지 않아 중단했습니다.") }
    }

    static func checkFrameCount(written: Int, expected: Int) throws {
        guard written == expected else { throw MediaEngineError.failed("역재생 프레임 중 일부를 디코딩하지 못했습니다(\(written)/\(expected)).") }
    }

    public static func render(url: URL, sourceStart: MediaTime, duration: MediaTime, destination: URL,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> MediaAsset {
        guard url.isFileURL, duration > .zero, sourceStart >= .zero else { throw MediaEngineError.invalid("역재생할 구간을 확인하세요.") }
        guard duration.seconds <= maximumSeconds else { throw MediaEngineError.invalid("역재생 사본은 클립당 \(Int(maximumSeconds))초까지 만들 수 있습니다. 클립을 나눈 뒤 각각 만드세요.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MediaEngineError.failed("기존 파일을 보호하기 위해 새 이름을 선택하세요.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let sourceInfo = try await MediaImporter.inspect(url: url)
        guard sourceInfo.supported, sourceInfo.kind == .video else { throw MediaEngineError.unsupported(sourceInfo.issue ?? "지원하는 SDR 영상이 필요합니다.") }
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw MediaEngineError.unsupported("이 미디어에는 영상 트랙이 없습니다.") }
        let natural = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
        let dataRate = try await video.load(.estimatedDataRate)
        let available = try await video.load(.timeRange)
        let range = CMTimeRange(start: sourceStart.cmTime, duration: duration.cmTime)
        guard range.start >= available.start, range.end <= available.end else { throw MediaEngineError.invalid("역재생 범위가 원본 밖입니다.") }
        let width = Int(natural.width), height = Int(natural.height)
        guard width > 0, height > 0 else { throw MediaEngineError.invalid("영상 크기를 읽지 못했습니다.") }

        // 1. Presentation times of the frames in the range (compressed read only: cheap).
        var times: [CMTime] = []
        do {
            // Read the presentation index, including the frame held across a non-frame-aligned
            // trim boundary. Compressed reads do not retain decoded pictures.
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            guard reader.canAdd(output) else { throw MediaEngineError.failed("영상 구조를 읽지 못했습니다.") }
            reader.add(output); guard reader.startReading() else { throw reader.error ?? MediaEngineError.failed("영상 읽기를 시작하지 못했습니다.") }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], attachments.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isNumeric, CMSampleBufferGetTotalSampleSize(sample) > 0 { times.append(pts) }
            }
            guard reader.status == .completed else { throw reader.error ?? MediaEngineError.failed("영상 프레임 목록 읽기가 완료되지 않았습니다.") }
        }
        times.sort()
        // Repeated presentation times (edit lists, duplicated samples) would give two output frames the same time,
        // which the encoder rejects at the end of the file.
        times = times.enumerated().filter { $0.offset == 0 || $0.element > times[$0.offset - 1] }.map(\.element)
        let intervals = times.enumerated().compactMap { index, pts -> (source: CMTime, end: CMTime, output: CMTime, duration: CMTime)? in
            let end = index + 1 < times.count ? min(times[index + 1], available.end) : available.end
            let begin = max(pts, range.start), clippedEnd = min(end, range.end)
            guard clippedEnd > begin else { return nil }
            return (pts, end, range.end - clippedEnd, clippedEnd - begin)
        }
        guard !intervals.isEmpty else { throw MediaEngineError.invalid("역재생할 프레임이 충분하지 않습니다.") }
        times = intervals.map(\.source)

        // 2. Writer.
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".jhcut-reverse-\(UUID().uuidString)." + destination.pathExtension)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: staging) } }
        let writer = try AVAssetWriter(outputURL: staging, fileType: .mp4)
        let bitRate = Int(min(80_000_000, max(6_000_000, Double(dataRate) * 1.3)))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoMaxKeyFrameIntervalKey: 30, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        var clock: Int64 = Int64(duration.timescale)
        for value in intervals {
            for scale in [value.output.timescale, value.duration.timescale] {
                var a = clock, b = Int64(scale)
                while b != 0 { let remainder = a % b; a = b; b = remainder }
                clock = clock / a * Int64(scale)
                guard clock <= Int64(Int32.max) else { throw MediaEngineError.unsupported("원본 영상의 시간 단위를 정확히 보존할 수 없습니다.") }
            }
        }
        videoInput.mediaTimeScale = Int32(clock)
        writer.movieTimeScale = Int32(clock)
        videoInput.transform = transform; videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(videoInput) else { throw MediaEngineError.failed("역재생 영상 기록기를 구성하지 못했습니다.") }
        writer.add(videoInput)

        // 3. Sound: reversed through a temporary file, fed to the writer in step with the picture.
        var audioFeed: AudioFeed?
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("JHCutReverse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }
        if try await !asset.loadTracks(withMediaType: .audio).isEmpty {
            audioFeed = try await AudioFeed.make(url: url, sourceStart: sourceStart, duration: duration, temp: tempFolder.appendingPathComponent("reversed.caf"), writer: writer)
        }
        guard writer.startWriting() else { throw writer.error ?? MediaEngineError.failed("역재생 파일을 시작하지 못했습니다.") }
        writer.startSession(atSourceTime: .zero)
        defer { if !finished, writer.status == .writing { writer.cancelWriting() } }
        defer { audioFeed?.reader.cancelReading() }
        var lastVideoProgress = ProcessInfo.processInfo.systemUptime

        // 4. Chunks from the end of the range to the start.
        let framesPerChunk = max(6, min(60, chunkBytes / max(1, width * height * 3 / 2)))
        var hi = times.count - 1
        var written = 0
        while hi >= 0 {
            try Task.checkCancellation()
            let lo = max(0, hi - framesPerChunk + 1)
            let chunk = try decode(asset: asset, track: video, from: times[lo], until: intervals[hi].end, wanted: Array(times[lo...hi]), width: width, height: height)
            try checkFrameCount(written: chunk.count, expected: hi - lo + 1)
            for (pts, buffer) in chunk.sorted(by: { $0.0 > $1.0 }) {
                let timing = intervals.first { $0.source == pts }!
                while !videoInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try checkWriter(status: writer.status, error: writer.error,
                                    idleSeconds: ProcessInfo.processInfo.systemUptime - max(lastVideoProgress, audioFeed?.lastProgress ?? 0))
                    try await audioFeed?.pump(upTo: timing.output.seconds + audioLead)
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard let pool = adaptor.pixelBufferPool, let pooled = poolCopy(buffer, pool: pool) else { throw MediaEngineError.failed("역재생 프레임 버퍼를 만들지 못했습니다.") }
                var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
                var sampleTiming = CMSampleTimingInfo(duration: timing.duration, presentationTimeStamp: timing.output, decodeTimeStamp: .invalid)
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pooled, formatDescriptionOut: &format) == noErr,
                      CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pooled, formatDescription: format!, sampleTiming: &sampleTiming, sampleBufferOut: &sample) == noErr,
                      videoInput.append(sample!) else { throw writer.error ?? MediaEngineError.failed("역재생 프레임을 기록하지 못했습니다.") }
                written += 1
                lastVideoProgress = ProcessInfo.processInfo.systemUptime
            }
            try await audioFeed?.pump(upTo: intervals[lo].output.seconds + audioLead)
            progress?(min(1, Double(times.count - lo) / Double(times.count)))
            hi = lo - 1
        }
        try checkFrameCount(written: written, expected: times.count)
        videoInput.markAsFinished()
        try await audioFeed?.finish()
        writer.endSession(atSourceTime: duration.cmTime)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("역재생 파일을 완성하지 못했습니다.") }
        try FileManager.default.moveItem(at: staging, to: destination); finished = true
        progress?(1)
        let result = try await MediaImporter.inspect(url: destination)
        guard result.supported else { try? FileManager.default.removeItem(at: destination); throw MediaEngineError.failed(result.issue ?? "역재생 사본을 검사하지 못했습니다.") }
        return result
    }

    /// Decodes the frames whose presentation times are in `wanted`, copying each into its own buffer so the
    /// reader's buffer pool is never held up.
    private static func decode(asset: AVAsset, track: AVAssetTrack, from first: CMTime, until end: CMTime, wanted: [CMTime], width: Int, height: Int) throws -> [(CMTime, CVPixelBuffer)] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: first, duration: end - first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaEngineError.failed("영상 디코더를 구성하지 못했습니다.") }
        reader.add(output); guard reader.startReading() else { throw reader.error ?? MediaEngineError.failed("영상 읽기를 시작하지 못했습니다.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var result: [(CMTime, CVPixelBuffer)] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let match = wanted.first(where: { $0 == pts }), !result.contains(where: { $0.0 == match }),
                  let source = CMSampleBufferGetImageBuffer(sample), let copy = copyBuffer(source, width: width, height: height) else { continue }
            result.append((match, copy))
        }
        guard reader.status == .completed else { throw reader.error ?? MediaEngineError.failed("영상 디코딩이 완료되지 않았습니다.") }
        return result
    }

    /// Copies a held frame into a buffer from the writer's own pool (the encoder is picky about foreign buffers).
    private static func poolCopy(_ source: CVPixelBuffer, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(target, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane), let to = CVPixelBufferGetBaseAddressOfPlane(target, plane) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane), a = CVPixelBufferGetBytesPerRowOfPlane(source, plane), b = CVPixelBufferGetBytesPerRowOfPlane(target, plane)
            for row in 0..<rows { memcpy(to.advanced(by: row * b), from.advanced(by: row * a), min(a, b)) }
        }
        CVBufferPropagateAttachments(source, target)
        return target
    }

    private static func copyBuffer(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var target: CVPixelBuffer?
        let format = CVPixelBufferGetPixelFormatType(source)
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), format, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()] as CFDictionary, &target)
        guard let target else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(target, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane), let to = CVPixelBufferGetBaseAddressOfPlane(target, plane) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane), a = CVPixelBufferGetBytesPerRowOfPlane(source, plane), b = CVPixelBufferGetBytesPerRowOfPlane(target, plane)
            for row in 0..<rows { memcpy(to.advanced(by: row * b), from.advanced(by: row * a), min(a, b)) }
        }
        CVBufferPropagateAttachments(source, target)
        return target
    }

    /// Reversed audio read back as sample buffers and appended to the writer in time order.
    final class AudioFeed {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        var pending: CMSampleBuffer?
        var done = false
        var finished = false
        var lastProgress = ProcessInfo.processInfo.systemUptime
        init(writer: AVAssetWriter, input: AVAssetWriterInput, reader: AVAssetReader, output: AVAssetReaderTrackOutput) { self.writer = writer; self.input = input; self.reader = reader; self.output = output }

        static func make(url: URL, sourceStart: MediaTime, duration: MediaTime, temp: URL, writer: AVAssetWriter) async throws -> AudioFeed {
            var channels = 2, rate = 48_000.0
            var interleaved: [Float] = []
            _ = try await SourcePCM.readStable(url: url, sourceStart: sourceStart, duration: duration) { chunk in
                channels = min(2, chunk.channels); rate = chunk.sampleRate
                let frames = chunk.values.count / chunk.channels
                for f in 0..<frames { for c in 0..<channels { interleaved.append(chunk.values[f * chunk.channels + c]) } }
            }
            guard !interleaved.isEmpty else { throw MediaEngineError.failed("역재생할 소리를 읽지 못했습니다.") }
            let frames = interleaved.count / channels
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false) else { throw MediaEngineError.failed("역재생 소리 형식을 만들지 못했습니다.") }
            do {
                let file = try AVAudioFile(forWriting: temp, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
                var position = frames
                while position > 0 {
                    try Task.checkCancellation()
                    let count = min(16_384, position)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw MediaEngineError.failed("소리 버퍼를 만들지 못했습니다.") }
                    buffer.frameLength = AVAudioFrameCount(count)
                    for i in 0..<count {
                        let src = position - 1 - i   // last frame first
                        for c in 0..<channels { buffer.floatChannelData![c][i] = interleaved[src * channels + c] }
                    }
                    try file.write(from: buffer); position -= count
                }
            }
            let asset = AVURLAsset(url: temp)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaEngineError.failed("역재생 소리 파일을 읽지 못했습니다.") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(output); guard reader.startReading() else { throw reader.error ?? MediaEngineError.failed("역재생 소리 읽기를 시작하지 못했습니다.") }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MediaEngineError.failed("역재생 소리 기록기를 구성하지 못했습니다.") }
            writer.add(input)
            return AudioFeed(writer: writer, input: input, reader: reader, output: output)
        }

        /// Appends audio up to `seconds` on the output timeline.
        func pump(upTo seconds: Double) async throws {
            while !done {
                try Task.checkCancellation()
                try ReverseRenderer.checkWriter(status: writer.status, error: writer.error,
                    idleSeconds: ProcessInfo.processInfo.systemUptime - lastProgress)
                if pending == nil {
                    pending = output.copyNextSampleBuffer()
                    if pending == nil {
                        guard reader.status == .completed else { throw reader.error ?? MediaEngineError.failed("역재생 소리 읽기가 중간에 중단되었습니다.") }
                        done = true; break
                    }
                }
                guard let sample = pending else { break }
                if CMSampleBufferGetPresentationTimeStamp(sample).seconds > seconds || !input.isReadyForMoreMediaData { break }
                guard input.append(sample) else { throw writer.error ?? MediaEngineError.failed("역재생 소리를 기록하지 못했습니다.") }
                pending = nil; lastProgress = ProcessInfo.processInfo.systemUptime
            }
            if done { close() }
        }
        /// An exhausted audio input must be closed right away: the writer holds back video while it waits for more audio.
        private func close() {
            guard !finished else { return }
            finished = true; input.markAsFinished()
        }
        func finish() async throws {
            while !done {
                try Task.checkCancellation()
                try await pump(upTo: .infinity)
                if !done { try await Task.sleep(nanoseconds: 2_000_000) }
            }
            close()
        }
    }
}

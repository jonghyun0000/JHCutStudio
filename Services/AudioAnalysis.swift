import Foundation
import AVFoundation

public struct AudioAnalysisOptions: Codable, Equatable, Sendable {
    public var silenceThresholdDBFS: Double
    public var minimumSilenceDuration: Double
    public var windowDuration: Double
    public var normalizationTargetDBFS: Double
    public var maximumBoostDB: Double
    public init(silenceThresholdDBFS: Double = -45, minimumSilenceDuration: Double = 0.35,
                windowDuration: Double = 0.02, normalizationTargetDBFS: Double = -1, maximumBoostDB: Double = 12) {
        self.silenceThresholdDBFS = silenceThresholdDBFS; self.minimumSilenceDuration = minimumSilenceDuration
        self.windowDuration = windowDuration; self.normalizationTargetDBFS = normalizationTargetDBFS; self.maximumBoostDB = maximumBoostDB
    }
}
public struct AudioSilenceRegion: Codable, Equatable, Sendable {
    /// Absolute source timestamps, before clip playback-rate/time mapping.
    public let start: MediaTime
    public let duration: MediaTime
}
public struct AudioAnalysisResult: Codable, Equatable, Sendable {
    public let sourceStart: MediaTime
    public let duration: MediaTime
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int64
    public let decodedDuration: Double
    public let peak: Double
    public let rms: Double
    /// nil means digital silence (-infinity dBFS), not an unknown or fabricated floor.
    public let peakDBFS: Double?
    public let rmsDBFS: Double?
    /// Channel samples at or above 32767/32768 full scale; this is a clipping warning, not proof of distortion.
    public let clippingSampleCount: Int64
    public let clippingThreshold: Double
    /// Peak normalization of the source, before clip volume/fades/mix. Never a LUFS measurement.
    public let normalizationGainDB: Double?
    public let normalizationGain: Double?
    public let normalizationBoostLimited: Bool
    public let options: AudioAnalysisOptions
    public let silenceRegions: [AudioSilenceRegion]
}
public struct AudioAnalysisError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Reads one decoded chunk at a time. Preserves all native channels/rate for measurement.
/// Shared by analysis and local transcription extraction; no originals are modified.
enum SourcePCM {
    struct Range: Sendable { let start: Double; let duration: Double }
    struct Chunk { let values: [Float]; let sampleRate: Double; let channels: Int; let start: Double }
    static func read(url: URL, sourceStart: MediaTime, duration: MediaTime?, sampleRate: Double? = nil,
                     channels: Int? = nil, consume: (Chunk) throws -> Void) async throws -> Range {
        guard url.isFileURL, sourceStart >= .zero, duration == nil || duration! > .zero else {
            throw AudioAnalysisError("로컬 파일과 0 이상 시작·양수 길이를 지정하세요.")
        }
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw AudioAnalysisError("오디오 원본을 읽을 수 없습니다: \(url.lastPathComponent)") }
        let asset = AVURLAsset(url: url)
        let assetDuration = try await asset.load(.duration).seconds
        guard assetDuration.isFinite, assetDuration > 0, sourceStart.seconds < assetDuration else { throw AudioAnalysisError("분석 시작이 유효한 원본 길이 밖에 있습니다.") }
        let length = duration?.seconds ?? (assetDuration - sourceStart.seconds)
        guard length.isFinite, length > 0, sourceStart.seconds + length <= assetDuration + 0.0001 else { throw AudioAnalysisError("분석 범위가 원본 길이를 초과합니다.") }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioAnalysisError("이 미디어에는 분석할 오디오 트랙이 없습니다.") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: sourceStart.seconds, preferredTimescale: 600_000), duration: CMTime(seconds: length, preferredTimescale: 600_000))
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        if let sampleRate { settings[AVSampleRateKey] = sampleRate }
        if let channels { settings[AVNumberOfChannelsKey] = channels }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioAnalysisError("PCM 디코더를 구성할 수 없습니다.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioAnalysisError("오디오 읽기를 시작하지 못했습니다.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample), let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0, format.mSampleRate.isFinite, format.mSampleRate > 0,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw AudioAnalysisError("PCM 형식이 올바르지 않습니다.") }
                let channelCount = Int(format.mChannelsPerFrame), size = CMBlockBufferGetDataLength(block)
                guard size % (MemoryLayout<Float>.size * channelCount) == 0 else { throw AudioAnalysisError("PCM 버퍼 크기가 올바르지 않습니다.") }
                guard size > 0 else { return }
                var values = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
                let copied = values.withUnsafeMutableBytes { bytes in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: bytes.baseAddress!) }
                guard copied == kCMBlockBufferNoErr else { throw AudioAnalysisError("PCM 데이터를 읽지 못했습니다.") }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard pts.isFinite, values.allSatisfy(\.isFinite) else { throw AudioAnalysisError("오디오에 유효하지 않은 시간 또는 샘플이 있습니다.") }
                // Some decoders return packets spanning the requested range. Trim by timestamp, not packet boundary.
                let frameCount = values.count / channelCount
                let first = max(0, min(frameCount, Int(ceil((sourceStart.seconds - pts) * format.mSampleRate - 0.00001))))
                let last = max(first, min(frameCount, Int(ceil((sourceStart.seconds + length - pts) * format.mSampleRate - 0.00001))))
                if last > first {
                    let selected = first == 0 && last == frameCount ? values : Array(values[(first * channelCount)..<(last * channelCount)])
                    try consume(Chunk(values: selected, sampleRate: format.mSampleRate, channels: channelCount, start: pts + Double(first) / format.mSampleRate))
                }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? AudioAnalysisError("오디오 디코딩이 완료되지 않았습니다.") }
        return Range(start: sourceStart.seconds, duration: length)
    }
}

extension SourcePCM {
    /// Same contract as `read`, but bit-exact from run to run when possible.
    ///
    /// Measured: AVAssetReader's AAC decode differs by up to 3e-7 between runs on ~30% of samples
    /// (it depends on how the reader partitions buffers), which flipped ~65 of 480,000 16-bit
    /// samples per 30 s and occasionally moved a Whisper timestamp. ExtAudioFile (AVAudioFile)
    /// decoded the same files identically on every run and sample-aligned with the reader (lag 0).
    /// It is used only when the file has one audio track and its first second matches the reader;
    /// otherwise this falls back to `read`.
    static func readStable(url: URL, sourceStart: MediaTime, duration: MediaTime?, consume: (Chunk) throws -> Void) async throws -> Range {
        guard url.isFileURL, sourceStart >= .zero, duration == nil || duration! > .zero else { throw AudioAnalysisError("로컬 파일과 0 이상 시작·양수 길이를 지정하세요.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.count == 1,
              let assetDuration = try? await asset.load(.duration).seconds, assetDuration.isFinite, sourceStart.seconds < assetDuration,
              let file = try? AVAudioFile(forReading: url), file.processingFormat.commonFormat == .pcmFormatFloat32 else {
            return try await read(url: url, sourceStart: sourceStart, duration: duration, consume: consume)
        }
        let length = duration?.seconds ?? (assetDuration - sourceStart.seconds)
        guard length.isFinite, length > 0, sourceStart.seconds + length <= assetDuration + 0.0001 else { throw AudioAnalysisError("분석 범위가 원본 길이를 초과합니다.") }
        let format = file.processingFormat, rate = format.sampleRate, channels = Int(format.channelCount)
        let firstFrame = AVAudioFramePosition((sourceStart.seconds * rate).rounded())
        let endFrame = min(file.length, AVAudioFramePosition(((sourceStart.seconds + length) * rate).rounded()))
        guard channels > 0, firstFrame < endFrame else { return try await read(url: url, sourceStart: sourceStart, duration: duration, consume: consume) }
        func block(_ at: AVAudioFramePosition, _ count: AVAudioFrameCount) throws -> [Float] {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw AudioAnalysisError("PCM 버퍼를 만들지 못했습니다.") }
            file.framePosition = at
            try file.read(into: buffer, frameCount: count)
            let n = Int(buffer.frameLength), data = buffer.floatChannelData!
            var values = [Float](repeating: 0, count: n * channels)
            for c in 0..<channels { let src = data[c]; for i in 0..<n { values[i * channels + c] = src[i] } }
            return values
        }
        // Alignment check against the reader on the first second before anything is consumed.
        let probeFrames = AVAudioFrameCount(min(Double(endFrame - firstFrame), rate))
        let fileProbe = try block(firstFrame, probeFrames)
        var readerProbe: [Float] = []
        _ = try await read(url: url, sourceStart: sourceStart, duration: MediaTime(seconds: Double(probeFrames) / rate)) { chunk in
            guard chunk.channels == channels else { throw AudioAnalysisError("채널 수 불일치") }
            readerProbe += chunk.values
        }
        let compared = min(fileProbe.count, readerProbe.count)
        var worst: Float = 0
        for i in 0..<compared { worst = max(worst, abs(fileProbe[i] - readerProbe[i])) }
        guard compared > 0, abs(fileProbe.count - readerProbe.count) <= channels * 2, worst <= 1e-4 else {
            return try await read(url: url, sourceStart: sourceStart, duration: duration, consume: consume)
        }
        var at = firstFrame
        while at < endFrame {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(16_384, endFrame - at))
            // One pool per block: decoder and consumer buffers must not accumulate over a 2-hour read.
            let read = try autoreleasepool { () throws -> Int in
                let values = try block(at, count)
                guard !values.isEmpty else { return 0 }
                guard values.allSatisfy(\.isFinite) else { throw AudioAnalysisError("오디오에 유효하지 않은 샘플이 있습니다.") }
                try consume(Chunk(values: values, sampleRate: rate, channels: channels, start: Double(at) / rate))
                return values.count / channels
            }
            guard read > 0 else { break }
            at += AVAudioFramePosition(read)
        }
        return Range(start: sourceStart.seconds, duration: length)
    }
}

public enum AudioAnalysis {
    public static func analyze(url: URL, sourceStart: MediaTime = .zero, duration: MediaTime? = nil,
                               options: AudioAnalysisOptions = .init()) async throws -> AudioAnalysisResult {
        guard options.silenceThresholdDBFS.isFinite, (-120...0).contains(options.silenceThresholdDBFS),
              options.minimumSilenceDuration.isFinite, (0.01...60).contains(options.minimumSilenceDuration),
              options.windowDuration.isFinite, (0.005...1).contains(options.windowDuration),
              options.normalizationTargetDBFS.isFinite, (-24...0).contains(options.normalizationTargetDBFS),
              options.maximumBoostDB.isFinite, (0...24).contains(options.maximumBoostDB) else { throw AudioAnalysisError("분석 임계값·구간 길이·정규화 설정을 확인하세요.") }
        let accumulator = Measurement(start: sourceStart.seconds, options: options)
        let range = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration) { try accumulator.append($0) }
        return try accumulator.finish(range: range)
    }
    private final class Measurement {
        let start: Double, options: AudioAnalysisOptions
        let clippingThreshold = 32767.0 / 32768.0
        var sampleRate = 0.0, channels = 0, frameCount: Int64 = 0, samples: Int64 = 0, clipped: Int64 = 0
        var peak = 0.0, sumSquares = 0.0
        var windowID = -1, windowStart = 0.0, windowEnd = 0.0, windowSquares = 0.0, windowSamples = 0
        var silenceStart: Double?, silenceEnd = 0.0, silence: [AudioSilenceRegion] = []
        init(start: Double, options: AudioAnalysisOptions) { self.start = start; self.options = options }
        func append(_ chunk: SourcePCM.Chunk) throws {
            if channels == 0 { channels = chunk.channels; sampleRate = chunk.sampleRate }
            guard channels == chunk.channels, sampleRate == chunk.sampleRate else { throw AudioAnalysisError("분석 중 오디오 형식이 변경되었습니다.") }
            for frame in 0..<(chunk.values.count / channels) {
                let time = chunk.start + Double(frame) / sampleRate
                let id = max(0, Int(floor((time - start) / options.windowDuration + 0.000001)))
                if id != windowID {
                    try finishWindow()
                    if windowID >= 0, id > windowID + 1 { try finishSilence() }
                    windowID = id; windowStart = time
                }
                for channel in 0..<channels {
                    let value = Double(chunk.values[frame * channels + channel]), magnitude = abs(value)
                    peak = max(peak, magnitude); sumSquares += value * value; samples += 1
                    if magnitude >= clippingThreshold { clipped += 1 }
                    windowSquares += value * value; windowSamples += 1
                }
                windowEnd = time + 1 / sampleRate; frameCount += 1
            }
        }
        func finishWindow() throws {
            guard windowSamples > 0 else { return }
            let rms = sqrt(windowSquares / Double(windowSamples)), threshold = pow(10, options.silenceThresholdDBFS / 20)
            if rms <= threshold {
                if let _ = silenceStart, windowStart > silenceEnd + 1.5 / sampleRate { try finishSilence() }
                if silenceStart == nil { silenceStart = windowStart }
                silenceEnd = windowEnd
            } else { try finishSilence() }
            windowSquares = 0; windowSamples = 0
        }
        func finishSilence() throws {
            if let begin = silenceStart, silenceEnd - begin + 0.000001 >= options.minimumSilenceDuration {
                guard silence.count < 100_000 else { throw AudioAnalysisError("무음 후보가 너무 많습니다. 분석 범위를 나누세요.") }
                silence.append(AudioSilenceRegion(start: MediaTime(seconds: begin), duration: MediaTime(seconds: silenceEnd - begin)))
            }
            silenceStart = nil
        }
        func finish(range: SourcePCM.Range) throws -> AudioAnalysisResult {
            try finishWindow(); try finishSilence()
            guard frameCount > 0, samples > 0 else { throw AudioAnalysisError("선택 범위에 디코딩 가능한 오디오 샘플이 없습니다.") }
            let rms = sqrt(sumSquares / Double(samples)), peakDB = peak > 0 ? 20 * log10(peak) : nil
            let wanted = peakDB.map { options.normalizationTargetDBFS - $0 }
            let gainDB = wanted.map { min($0, options.maximumBoostDB) }
            return AudioAnalysisResult(sourceStart: MediaTime(seconds: range.start), duration: MediaTime(seconds: range.duration),
                sampleRate: sampleRate, channelCount: channels, frameCount: frameCount, decodedDuration: Double(frameCount) / sampleRate,
                peak: peak, rms: rms, peakDBFS: peakDB, rmsDBFS: rms > 0 ? 20 * log10(rms) : nil,
                clippingSampleCount: clipped, clippingThreshold: clippingThreshold, normalizationGainDB: gainDB,
                normalizationGain: gainDB.map { pow(10, $0 / 20) }, normalizationBoostLimited: (wanted ?? 0) > options.maximumBoostDB,
                options: options, silenceRegions: silence)
        }
    }
}

import Foundation
import AVFoundation
import CoreImage
import ImageIO

/// Built once, then shared read-only. Do not mutate the AVFoundation objects after publication.
public final class RenderPlan: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix
    public let duration: CMTime
    public let frameDuration: CMTime
    public let usesProxyMedia: Bool
    private let scopedURLs: [URL]
    init(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, audioMix: AVMutableAudioMix,
         duration: CMTime, frameDuration: CMTime, scopedURLs: [URL], usesProxyMedia: Bool = false) {
        self.composition = composition; self.videoComposition = videoComposition; self.audioMix = audioMix
        self.duration = duration; self.frameDuration = frameDuration; self.scopedURLs = scopedURLs; self.usesProxyMedia = usesProxyMedia
    }
    /// The black carrier is a shared cached file owned by `BlackCarrier`, so a plan never deletes it.
    deinit {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
    }
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

public enum TimelineRenderer {
    public static func build(project: Project, documentURL: URL? = nil, mediaURLOverrides: [UUID: URL] = [:]) async throws -> RenderPlan {
        try ProjectValidator.validate(project)
        let sequence = project.sequence
        guard sequence.duration > .zero else { throw MediaEngineError.invalid("타임라인에 클립을 추가하세요.") }
        // 4096 per axis covers UHD 3840×2160 and DCI 4096×2160. The area bound keeps a pathological
        // 4096×4096 canvas (16.8MP) out of the CPU compositor, which renders every frame in software.
        guard sequence.width > 0, sequence.height > 0, sequence.width % 2 == 0, sequence.height % 2 == 0,
              sequence.width <= 4096, sequence.height <= 4096, sequence.width * sequence.height <= 4096 * 2304 else {
            throw MediaEngineError.unsupported("캔버스는 축당 최대 4096픽셀, 총 9.4메가픽셀 이하의 짝수 크기여야 합니다.")
        }
        guard sequence.frameRate.isSupportedRenderRate else {
            throw MediaEngineError.unsupported("지원 프레임레이트는 23.976/24/25/29.97/30/50/59.94/60입니다.")
        }
        guard sequence.colorSpace == "Rec.709" else { throw MediaEngineError.unsupported("G0 색공간은 SDR Rec.709입니다.") }
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        let audioMix = AVMutableAudioMix()
        let canvas = CGSize(width: sequence.width, height: sequence.height)
        let duration = sequence.duration.cmTime
        let frameDuration = sequence.frameRate.time(forFrame: 1).cmTime
        var scopedURLs: [URL] = []
        var pool = CompositionTrackPool()
        var sourceAssets: [UUID: AVURLAsset] = [:]
        var proxyVideoAssets: [UUID: AVURLAsset] = [:]
        var sourceImages: [UUID: CIImage] = [:]
        var inspected: [UUID: MediaAsset] = [:]
        let referenced = Set(sequence.tracks.filter { !$0.isHidden }.flatMap(\.clips).compactMap(\.assetID))
        do {
            for asset in project.assets where referenced.contains(asset.id) {
                try Task.checkCancellation()
                let url = asset.resolvedURL(relativeTo: documentURL)
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                let actual = try await MediaImporter.inspect(url: url)
                guard actual.supported else { throw MediaEngineError.unsupported("\(asset.name): \(actual.issue ?? "지원하지 않는 미디어")") }
                guard actual.kind == asset.kind else { throw MediaEngineError.invalid("미디어 종류가 바뀌었습니다: \(asset.name)") }
                inspected[asset.id] = actual
                if actual.kind == .image {
                    sourceImages[asset.id] = CIImage(cgImage: try MediaImporter.loadImage(url: url))
                } else {
                    sourceAssets[asset.id] = AVURLAsset(url: url)
                    if actual.kind == .video, let proxyURL = mediaURLOverrides[asset.id] {
                        if proxyURL.startAccessingSecurityScopedResource() { scopedURLs.append(proxyURL) }
                        let proxyInfo = try await MediaImporter.inspect(url: proxyURL)
                        guard proxyInfo.kind == .video, proxyInfo.supported,
                              abs(Double(proxyInfo.width) / Double(max(1, proxyInfo.height)) - Double(actual.width) / Double(max(1, actual.height))) < 0.01 else {
                            throw MediaEngineError.invalid("프록시의 영상 비율이 원본과 다릅니다: \(asset.name)")
                        }
                        let proxyAsset = AVURLAsset(url: proxyURL)
                        guard let proxyTrack = try await proxyAsset.loadTracks(withMediaType: .video).first,
                              let originalTrack = try await sourceAssets[asset.id]!.loadTracks(withMediaType: .video).first else {
                            throw MediaEngineError.invalid("프록시 영상 트랙을 읽지 못했습니다.")
                        }
                        let proxyRange = try await proxyTrack.load(.timeRange)
                        let originalRange = try await originalTrack.load(.timeRange)
                        guard abs((proxyRange.start - originalRange.start).seconds) < 0.0001,
                              abs((proxyRange.end - originalRange.end).seconds) < 0.0001 else {
                            throw MediaEngineError.invalid("프록시 영상 시간 범위가 원본과 다릅니다: \(asset.name)")
                        }
                        proxyVideoAssets[asset.id] = proxyAsset
                    }
                }
            }
            // One tiny all-keyframe black clip is encoded once per frame rate and cached on disk, then
            // repeated to cover the timeline. Rebuilds after an edit reuse it instead of re-encoding.
            let carrierSource = try await BlackCarrier.shared.track(frameDuration: frameDuration)
            guard let carrierTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaEngineError.failed("배경 영상 트랙 생성에 실패했습니다.")
            }
            let unit = carrierSource.timeRange.duration
            guard unit > .zero else { throw MediaEngineError.failed("배경 영상 길이가 올바르지 않습니다.") }
            var filled = CMTime.zero
            while filled < duration {
                try Task.checkCancellation()
                let chunk = CMTimeMinimum(unit, duration - filled)
                guard chunk > .zero else { break }
                try carrierTrack.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: carrierSource.track, at: filled)
                filled = filled + chunk
            }
            var layers: [RenderLayer] = []
            var boundaries: [CMTime] = [.zero, duration]
            for track in sequence.tracks where !track.isHidden {
                for clip in track.clips {
                    try Task.checkCancellation()
                    let start = clip.start.cmTime
                    let end = (clip.start + clip.duration).cmTime
                    boundaries.append(start); boundaries.append(end)
                    if let title = clip.title {
                        layers.append(RenderLayer(clip: clip, trackID: nil, image: try TitleRasterizer.image(title: title, size: canvas), orientation: .identity))
                        continue
                    }
                    guard let assetID = clip.assetID, let info = inspected[assetID] else { throw MediaEngineError.invalid("클립의 원본 연결이 없습니다: \(clip.name)") }
                    if info.kind == .image {
                        layers.append(RenderLayer(clip: clip, trackID: nil, image: sourceImages[assetID], orientation: .identity))
                        continue
                    }
                    guard let asset = sourceAssets[assetID] else { throw MediaEngineError.missing("원본을 열 수 없습니다: \(clip.name)") }
                    guard clip.sourceStart + clip.sourceDuration <= info.duration else { throw MediaEngineError.invalid("원본 길이가 변경되었거나 트림 범위를 초과했습니다: \(clip.name)") }
                    let sourceRange = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.sourceDuration.cmTime)
                    let rate = clip.playbackRate ?? PlaybackRate()
                    if info.kind == .video && track.kind != .audio {
                        let visualAsset = proxyVideoAssets[assetID] ?? asset
                        guard let source = try await visualAsset.loadTracks(withMediaType: .video).first,
                              let target = pool.videoTrack(in: composition, from: start, until: end) else {
                            throw MediaEngineError.failed("영상 트랙을 만들 수 없습니다: \(clip.name)")
                        }
                        let availableVideo = try await source.load(.timeRange)
                        guard sourceRange.start >= availableVideo.start, sourceRange.end <= availableVideo.end else {
                            throw MediaEngineError.invalid("영상 또는 프록시가 요청한 원본 프레임 범위를 포함하지 않습니다: \(clip.name)")
                        }
                        try target.insertTimeRange(sourceRange, of: source, at: start)
                        if clip.sourceDuration != clip.duration {
                            target.scaleTimeRange(CMTimeRange(start: start, duration: clip.sourceDuration.cmTime), toDuration: clip.duration.cmTime)
                        }
                        let size = try await source.load(.naturalSize)
                        let preferred = try await source.load(.preferredTransform)
                        let display = CGRect(origin: .zero, size: size).applying(preferred)
                        // Convert AVFoundation's top-left transform into Core Image's bottom-left coordinates.
                        let orientation = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                            .concatenating(preferred)
                            .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
                            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height))
                        layers.append(RenderLayer(clip: clip, trackID: target.trackID, image: nil, orientation: orientation))
                    }
                    if !track.isMuted, let source = try await asset.loadTracks(withMediaType: .audio).first {
                        let available = try await source.load(.timeRange)
                        let requested = CMTimeRangeGetIntersection(sourceRange, otherRange: available)
                        if requested.duration > .zero {
                            let audioStart = start + rate.timelineDuration(for: MediaTime(requested.start - sourceRange.start)).cmTime
                            let audioDuration = rate.timelineDuration(for: MediaTime(requested.duration)).cmTime
                            // Reserved only once the clip is known to contribute audio, so a clip whose
                            // trim falls outside the source no longer leaves an empty track behind.
                            guard let lane = pool.audioLane(in: composition, from: audioStart, until: audioStart + audioDuration) else {
                                throw MediaEngineError.failed("오디오 트랙 생성에 실패했습니다.")
                            }
                            try lane.track.insertTimeRange(requested, of: source, at: audioStart)
                            if requested.duration != audioDuration {
                                lane.track.scaleTimeRange(CMTimeRange(start: audioStart, duration: requested.duration), toDuration: audioDuration)
                            }
                            // Ramps are written in absolute composition time and the lane's segments never
                            // overlap, so several clips share one input-parameters object safely.
                            ClipEnvelopes.applyAudio(clip: clip, to: lane.parameters)
                        }
                    }
                }
            }
            var sorted: [CMTime] = []
            for point in boundaries.sorted(by: { $0 < $1 }) {
                if sorted.last != point { sorted.append(point) }
            }
            videoComposition.instructions = zip(sorted, sorted.dropFirst()).compactMap { start, end in
                guard end > start else { return nil }
                let active = layers.filter { $0.clip.start.cmTime <= start && ($0.clip.start + $0.clip.duration).cmTime > start }
                return TimelineInstruction(range: CMTimeRange(start: start, end: end), layers: active, carrier: carrierTrack.trackID, canvas: canvas)
            }
            videoComposition.customVideoCompositorClass = TimelineCompositor.self
            videoComposition.renderSize = canvas
            videoComposition.frameDuration = frameDuration
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            audioMix.inputParameters = pool.audioParameters
            return RenderPlan(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                              duration: duration, frameDuration: frameDuration, scopedURLs: scopedURLs, usesProxyMedia: !proxyVideoAssets.isEmpty)
        } catch {
            for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
}

/// Composition tracks are a scarce resource: AVFoundation degrades sharply once a composition holds
/// hundreds of them. Clips are packed onto the fewest lanes that keep every lane's segments disjoint,
/// so the track count follows the timeline's maximum overlap depth rather than its clip count.
private struct CompositionTrackPool {
    struct AudioLane {
        let track: AVMutableCompositionTrack
        let parameters: AVMutableAudioMixInputParameters
    }
    private var videoLanes: [(track: AVMutableCompositionTrack, end: CMTime)] = []
    private var audioLanes: [(lane: AudioLane, end: CMTime)] = []
    /// Input parameters in lane order; one object per audio track, as AVAudioMix requires.
    var audioParameters: [AVMutableAudioMixInputParameters] { audioLanes.map(\.lane.parameters) }

    /// A lane is reusable only when it is already free at `start`, which keeps every lane's inserts
    /// strictly ascending. That ordering is what makes `scaleTimeRange` safe: it can never shift a
    /// segment that was written earlier.
    mutating func videoTrack(in composition: AVMutableComposition, from start: CMTime, until end: CMTime) -> AVMutableCompositionTrack? {
        if let index = videoLanes.firstIndex(where: { $0.end <= start }) {
            videoLanes[index].end = end
            return videoLanes[index].track
        }
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        videoLanes.append((track, end))
        return track
    }
    mutating func audioLane(in composition: AVMutableComposition, from start: CMTime, until end: CMTime) -> AudioLane? {
        if let index = audioLanes.firstIndex(where: { $0.end <= start }) {
            audioLanes[index].end = end
            return audioLanes[index].lane
        }
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let lane = AudioLane(track: track, parameters: AVMutableAudioMixInputParameters(track: track))
        audioLanes.append((lane, end))
        return lane
    }
}

/// AVFoundation only drives a custom compositor across times covered by a source track, so every plan
/// needs a black track spanning the timeline. Encoding one per build made each edit cost a full-length
/// encode, so a short all-keyframe clip is encoded once per frame rate, cached on disk, and repeated.
private actor BlackCarrier {
    static let shared = BlackCarrier()
    /// Every frame is a keyframe, so the trailing partial repeat cuts exactly on a frame boundary.
    private static let unitFrames = 300
    private static let version = 2
    struct Source {
        /// `AVAssetTrack.asset` is weak, so the cache must keep the asset alive alongside the track.
        let asset: AVURLAsset
        let track: AVAssetTrack
        let timeRange: CMTimeRange
    }
    private var loaded: [String: Source] = [:]

    /// Keyed on the exact rational frame duration, never on rounded fps: 30000/1001 and 30/1 both round
    /// to 30 and would otherwise share a carrier whose frames sit on the wrong grid.
    private static func key(for frameDuration: CMTime) -> String {
        let value = frameDuration.value, scale = Int64(frameDuration.timescale)
        let divisor = max(1, gcd(abs(value), scale))
        return "\(value / divisor)-\(scale / divisor)"
    }
    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    func track(frameDuration: CMTime) async throws -> Source {
        let seconds = frameDuration.seconds
        guard frameDuration > .zero, seconds.isFinite, seconds > 0 else { throw MediaEngineError.invalid("프레임 길이가 올바르지 않습니다.") }
        let key = Self.key(for: frameDuration)
        if let cached = loaded[key] { return cached }
        let url = try Self.cachedFile(key: key, frameDuration: frameDuration)
        let asset = AVURLAsset(url: url)
        if let track = (try? await asset.loadTracks(withMediaType: .video))?.first {
            let source = Source(asset: asset, track: track, timeRange: try await track.load(.timeRange))
            loaded[key] = source
            return source
        }
        // A truncated or stale cache entry is discarded and re-encoded rather than failing the build.
        try? FileManager.default.removeItem(at: url)
        let retryURL = try Self.cachedFile(key: key, frameDuration: frameDuration)
        let retryAsset = AVURLAsset(url: retryURL)
        guard let track = try await retryAsset.loadTracks(withMediaType: .video).first else {
            throw MediaEngineError.failed("배경 영상 트랙을 읽지 못했습니다.")
        }
        let source = Source(asset: retryAsset, track: track, timeRange: try await track.load(.timeRange))
        loaded[key] = source
        return source
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let carrier = base.appendingPathComponent("JHCutStudio/Carrier", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: carrier, withIntermediateDirectories: true)) != nil { return carrier }
        return FileManager.default.temporaryDirectory
    }

    /// Returns an existing cache entry, otherwise encodes one and publishes it with an atomic rename so
    /// a second process can never observe a partial file.
    private static func cachedFile(key: String, frameDuration: CMTime) throws -> URL {
        let url = directory().appendingPathComponent("carrier-v\(version)-\(key)-\(unitFrames)f.mp4")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 0 {
            return url
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("JHCut-carrier-\(UUID().uuidString).mp4")
        try encode(to: staging, frameDuration: frameDuration)
        do { try FileManager.default.moveItem(at: staging, to: url) }
        catch {
            try? FileManager.default.removeItem(at: staging)
            // Another process published the same entry first; its file is equivalent.
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
        }
        return url
    }

    private static func encode(to url: URL, frameDuration: CMTime) throws {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAllowFrameReorderingKey: false],
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
            guard writer.canAdd(input) else { throw MediaEngineError.failed("배경 인코더를 만들 수 없습니다.") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? MediaEngineError.failed("배경 쓰기 시작 실패") }
            writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { throw MediaEngineError.failed("배경 버퍼 생성 실패") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * 16)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for frame in 0..<unitFrames {
                while !input.isReadyForMoreMediaData && writer.status == .writing { Thread.sleep(forTimeInterval: 0.001) }
                guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))) else { throw writer.error ?? MediaEngineError.failed("배경 프레임 쓰기 실패") }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(unitFrames)))
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("배경 생성 실패") }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

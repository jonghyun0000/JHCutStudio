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
    /// One build owns these descriptors. Original/proxy AVURLAsset instances stay distinct,
    /// and no track metadata survives into a later build after a file has changed.
    private struct VideoProperties {
        let track: AVAssetTrack
        let range: CMTimeRange
        let size: CGSize
        let preferred: CGAffineTransform
    }
    /// Each request owns a distinct read-only file asset; children only invoke its async
    /// loader. Native tracks return to the parent before mutable composition assembly.
    private struct VideoTrackRequest: @unchecked Sendable {
        let assetID: UUID
        let asset: AVURLAsset
        let isProxy: Bool
    }
    private struct VideoTrackLoad: @unchecked Sendable {
        let request: VideoTrackRequest
        let track: AVAssetTrack?
        let begin: TimeInterval
        let end: TimeInterval
    }
    private struct AudioProperties {
        let track: AVAssetTrack?
        let range: CMTimeRange
        let formats: [CMFormatDescription]
    }

    /// A transparent background is used when baking one editable layer into a PNG.
    /// Preview and movie output retain the default opaque sequence background.
    public static func build(project: Project, documentURL: URL? = nil, mediaURLOverrides: [UUID: URL] = [:], cacheInspection: Bool = false, transparentBackground: Bool = false, phaseObserver: (@Sendable (String, TimeInterval) -> Void)? = nil) async throws -> RenderPlan {
        func phase(_ name: String, id: UUID? = nil) {
            guard let phaseObserver else { return }
            let label = id.map { name + "." + $0.uuidString } ?? name
            phaseObserver(label, ProcessInfo.processInfo.systemUptime)
        }
        phase("validation.begin")
        try ProjectValidator.validate(project)
        phase("validation.end")
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
        var usedProxyMedia = false
        var sourceImages: [UUID: CIImage] = [:]
        var inspected: [UUID: MediaAsset] = [:]
        var videoProperties: [ObjectIdentifier: VideoProperties] = [:]
        var audioProperties: [UUID: AudioProperties] = [:]
        let referenced = Set(sequence.tracks.filter { !$0.isHidden }.flatMap(\.clips).compactMap(\.assetID))
        do {
            phase("assets.begin")
            for asset in project.assets where referenced.contains(asset.id) {
                phase("asset.setup.begin", id: asset.id)
                try Task.checkCancellation()
                let url = asset.resolvedURL(relativeTo: documentURL)
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                phase("asset.inspect.begin", id: asset.id)
                let actual = try await (cacheInspection ? InspectionCache.shared.inspect(url) : MediaImporter.inspect(url: url))
                phase("asset.inspect.end", id: asset.id)
                guard actual.supported else { throw MediaEngineError.unsupported("\(asset.name): \(actual.issue ?? "지원하지 않는 미디어")") }
                guard actual.kind == asset.kind else { throw MediaEngineError.invalid("미디어 종류가 바뀌었습니다: \(asset.name)") }
                inspected[asset.id] = actual
                if actual.kind == .image {
                    sourceImages[asset.id] = CIImage(cgImage: try MediaImporter.loadImage(url: url))
                } else {
                    sourceAssets[asset.id] = AVURLAsset(url: url)
                    if actual.kind == .video, let proxyURL = mediaURLOverrides[asset.id] {
                        if proxyURL.startAccessingSecurityScopedResource() { scopedURLs.append(proxyURL) }
                        phase("proxy.inspect.begin", id: asset.id)
                        let proxyInfo = try await MediaImporter.inspect(url: proxyURL)
                        phase("proxy.inspect.end", id: asset.id)
                        guard proxyInfo.kind == .video, proxyInfo.supported,
                              abs(Double(proxyInfo.width) / Double(max(1, proxyInfo.height)) - Double(actual.width) / Double(max(1, actual.height))) < 0.01 else {
                            throw MediaEngineError.invalid("프록시의 영상 비율이 원본과 다릅니다: \(asset.name)")
                        }
                        phase("proxy.nativeAsset.begin", id: asset.id)
                        let proxyAsset = AVURLAsset(url: proxyURL)
                        phase("proxy.nativeAsset.end", id: asset.id)
                        phase("proxy.validationTracks.begin", id: asset.id)
                        let loadedProxyTracks = try await proxyAsset.loadTracks(withMediaType: .video)
                        phase("proxy.validationTracks.end", id: asset.id)
                        guard let proxyTrack = loadedProxyTracks.first else {
                            throw MediaEngineError.invalid("프록시 영상 트랙을 읽지 못했습니다.")
                        }
                        phase("proxy.originalTracks.begin", id: asset.id)
                        let loadedOriginalTracks = try await sourceAssets[asset.id]!.loadTracks(withMediaType: .video)
                        phase("proxy.originalTracks.end", id: asset.id)
                        guard let originalTrack = loadedOriginalTracks.first else {
                            throw MediaEngineError.invalid("프록시 영상 트랙을 읽지 못했습니다.")
                        }
                        phase("proxy.validationRange.begin", id: asset.id)
                        let proxyRange = try await proxyTrack.load(.timeRange)
                        phase("proxy.validationRange.end", id: asset.id)
                        phase("proxy.originalRange.begin", id: asset.id)
                        let originalRange = try await originalTrack.load(.timeRange)
                        phase("proxy.originalRange.end", id: asset.id)
                        guard abs((proxyRange.start - originalRange.start).seconds) < 0.0001,
                              abs((proxyRange.end - originalRange.end).seconds) < 0.0001 else {
                            throw MediaEngineError.invalid("프록시 영상 시간 범위가 원본과 다릅니다: \(asset.name)")
                        }
                        proxyVideoAssets[asset.id] = proxyAsset
                    }
                }
                phase("asset.setup.end", id: asset.id)
            }
            phase("assets.end")
            // One tiny all-keyframe black clip is encoded once per frame rate and cached on disk, then
            // repeated to cover the timeline. Rebuilds after an edit reuse it instead of re-encoding.
            phase("carrier.lookup.begin")
            let carrierSource = try await BlackCarrier.shared.track(frameDuration: frameDuration)
            phase("carrier.lookup.end")
            guard let carrierTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaEngineError.failed("배경 영상 트랙 생성에 실패했습니다.")
            }
            let unit = carrierSource.timeRange.duration
            guard unit > .zero else { throw MediaEngineError.failed("배경 영상 길이가 올바르지 않습니다.") }
            var filled = CMTime.zero
            phase("carrier.fill.begin")
            while filled < duration {
                try Task.checkCancellation()
                let chunk = CMTimeMinimum(unit, duration - filled)
                guard chunk > .zero else { break }
                try carrierTrack.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: carrierSource.track, at: filled)
                filled = filled + chunk
            }
            phase("carrier.fill.end")
            phase("layers.begin")
            var layers: [RenderLayer] = []
            var boundaries: [CMTime] = [.zero, duration]
            // Transition lanes belong to their main storyline's visual plane. Keep ordinary
            // overlays above that plane even after the outgoing scene has stopped being active.
            let contexts = Dictionary(uniqueKeysWithValues: sequence.tracks.compactMap { track in
                TransitionEditing.context(of: track, in: sequence).map { (track.id, $0) }
            })
            var renderTracks: [Track] = []
            for track in sequence.tracks where contexts[track.id] == nil {
                renderTracks.append(track)
                if track.kind == .video { renderTracks += sequence.tracks.filter { contexts[$0.id]?.originTrackID == track.id } }
            }
            // Load independent visual sources together, bounded to four requests. The
            // source/proxy choice matches the clip path below; no cross-build cache is kept.
            var requests: [ObjectIdentifier: VideoTrackRequest] = [:]
            for track in renderTracks where !track.isHidden && track.kind != .audio {
                for clip in track.clips where clip.captionHidden != true && clip.title == nil {
                    guard let id = clip.assetID, inspected[id]?.kind == .video,
                          let original = sourceAssets[id] else { continue }
                    let corrected = clip.stabilization.map { $0.covers(clip.sourceStart, duration: clip.sourceDuration) } ?? false
                    let proxy = corrected ? nil : proxyVideoAssets[id]
                    let asset = proxy ?? original
                    requests[ObjectIdentifier(asset)] = VideoTrackRequest(assetID: id, asset: asset, isProxy: proxy != nil)
                }
            }
            var loadedVideoTracks: [ObjectIdentifier: VideoTrackLoad] = [:]
            phase("video.prefetch.begin")
            try await withThrowingTaskGroup(of: VideoTrackLoad.self) { group in
                var remaining = Array(requests.values).makeIterator()
                func enqueue(_ request: VideoTrackRequest) {
                    group.addTask {
                        try Task.checkCancellation()
                        let begin = ProcessInfo.processInfo.systemUptime
                        let track = try await request.asset.loadTracks(withMediaType: .video).first
                        return VideoTrackLoad(request: request, track: track, begin: begin, end: ProcessInfo.processInfo.systemUptime)
                    }
                }
                for _ in 0..<min(4, requests.count) { if let request = remaining.next() { enqueue(request) } }
                while let loaded = try await group.next() {
                    try Task.checkCancellation()
                    loadedVideoTracks[ObjectIdentifier(loaded.request.asset)] = loaded
                    if let phaseObserver {
                        let label = "video.prefetch." + (loaded.request.isProxy ? "proxy" : "original") + ".tracks."
                        phaseObserver(label + "begin." + loaded.request.assetID.uuidString, loaded.begin)
                        phaseObserver(label + "end." + loaded.request.assetID.uuidString, loaded.end)
                    }
                    if let request = remaining.next() { enqueue(request) }
                }
            }
            phase("video.prefetch.end")
            let blendedFamilies = Set(sequence.tracks.filter { !$0.isHidden }.flatMap(\.clips).filter { $0.captionHidden != true && ($0.blendMode ?? .normal) != .normal }.map(TransitionEditing.family))
            for track in renderTracks where !track.isHidden {
                let transitionContext = TransitionEditing.context(of: track, in: sequence)
                let outgoingFamily = transitionContext?.outgoingFamilyID
                let blendedTransition = outgoingFamily.map { blendedFamilies.contains($0) } == true || track.clips.contains { blendedFamilies.contains(TransitionEditing.family($0)) }
                for original in track.clips where original.captionHidden != true {
                    var clip = original
                    // Legacy dissolve stored its transition weight in fadeIn. A newly selected
                    // blend needs scene-pair semantics as well; normalize only the render snapshot,
                    // and only a blended pair. Old all-normal documents keep their original pixels.
                    if blendedTransition, let context = transitionContext, context.effect.kind == .dissolve,
                       clip.transition?.independentFade != true, clip.fadeIn != nil {
                        var effect = clip.transition ?? context.effect
                        effect.independentFade = true
                        if effect.offset == nil, let start = track.clips.map(\.start).min() { effect.offset = clip.start - start }
                        clip.transition = effect
                        // Only the envelope equal to the old transition duration was its baked
                        // dissolve weight. A different user-authored clip fade remains independent.
                        if clip.fadeIn == context.effect.duration { clip.fadeIn = nil }
                    }
                    try Task.checkCancellation()
                    let start = clip.start.cmTime
                    let end = (clip.start + clip.duration).cmTime
                    boundaries.append(start); boundaries.append(end)
                    if let title = clip.title {
                        phase("title.raster.begin", id: clip.id)
                        var titleLayer = RenderLayer(clip: clip, trackID: nil, image: try TitleRasterizer.image(title: title, size: canvas), orientation: .identity)
                        phase("title.raster.end", id: clip.id)
                        if let animation = clip.titleAnimation, animation.inKind == .typewriter || animation.outKind == .typewriter {
                            titleLayer.titleBounds = try CaptionLayout.bounds(of: title, width: Int(canvas.width), height: Int(canvas.height))
                        }
                        layers.append(titleLayer)
                        continue
                    }
                    guard let assetID = clip.assetID, let info = inspected[assetID] else { throw MediaEngineError.invalid("클립의 원본 연결이 없습니다: \(clip.name)") }
                    if info.kind == .image {
                        var layer = RenderLayer(clip: clip, trackID: nil, image: sourceImages[assetID], orientation: .identity)
                        layer.outgoingFamily = outgoingFamily; layers.append(layer)
                        continue
                    }
                    phase("clip.assembly.begin", id: clip.id)
                    guard let asset = sourceAssets[assetID] else { throw MediaEngineError.missing("원본을 열 수 없습니다: \(clip.name)") }
                    guard clip.sourceStart + clip.sourceDuration <= info.duration else { throw MediaEngineError.invalid("원본 길이가 변경되었거나 트림 범위를 초과했습니다: \(clip.name)") }
                    let sourceRange = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.sourceDuration.cmTime)
                    let rate = clip.playbackRate ?? PlaybackRate()
                    if info.kind == .video && track.kind != .audio {
                        // Proxies bake track rotation into pixels. A path measured in the original's
                        // decoded axes must use those same axes in preview as in export.
                        let correction = clip.stabilization.flatMap { data in
                            data.covers(clip.sourceStart, duration: clip.sourceDuration) ? StabilizationPlan(data) : nil
                        }
                        let proxy = correction == nil ? proxyVideoAssets[assetID] : nil
                        let visualAsset = proxy ?? asset
                        if proxy != nil { usedProxyMedia = true }
                        let visualKey = ObjectIdentifier(visualAsset)
                        let properties: VideoProperties
                        if let cached = videoProperties[visualKey] { properties = cached }
                        else {
                            phase("video.properties.begin", id: assetID)
                            phase("video.tracks.begin", id: assetID)
                            guard let source = loadedVideoTracks[visualKey]?.track else {
                                throw MediaEngineError.failed("영상 트랙을 만들 수 없습니다: \(clip.name)")
                            }
                            phase("video.tracks.end", id: assetID)
                            phase("video.range.begin", id: assetID)
                            let loadedRange = try await source.load(.timeRange)
                            phase("video.range.end", id: assetID)
                            phase("video.size.begin", id: assetID)
                            let loadedSize = try await source.load(.naturalSize)
                            phase("video.size.end", id: assetID)
                            phase("video.transform.begin", id: assetID)
                            let loadedTransform = try await source.load(.preferredTransform)
                            phase("video.transform.end", id: assetID)
                            properties = VideoProperties(track: source, range: loadedRange,
                                                         size: loadedSize, preferred: loadedTransform)
                            videoProperties[visualKey] = properties
                            phase("video.properties.end", id: assetID)
                        }
                        let source = properties.track
                        guard let target = pool.videoTrack(in: composition, from: start, until: end) else {
                            throw MediaEngineError.failed("영상 트랙을 만들 수 없습니다: \(clip.name)")
                        }
                        let availableVideo = properties.range
                        // Containers often end the video track a few microseconds before the audio,
                        // and the asset (hence a full-length clip) takes the longer one. A shortfall
                        // under one frame is absorbed by stretching the available video over the clip;
                        // anything longer is still refused.
                        var videoRange = sourceRange
                        if sourceRange.start >= availableVideo.start, sourceRange.end > availableVideo.end,
                           sourceRange.end - availableVideo.end < frameDuration, availableVideo.end > sourceRange.start {
                            videoRange = CMTimeRange(start: sourceRange.start, end: availableVideo.end)
                        }
                        guard videoRange.start >= availableVideo.start, videoRange.end <= availableVideo.end else {
                            throw MediaEngineError.invalid("영상 또는 프록시가 요청한 원본 프레임 범위를 포함하지 않습니다: \(clip.name)")
                        }
                        try target.insertTimeRange(videoRange, of: source, at: start)
                        if videoRange.duration != clip.duration.cmTime {
                            target.scaleTimeRange(CMTimeRange(start: start, duration: videoRange.duration), toDuration: clip.duration.cmTime)
                        }
                        let size = properties.size
                        let preferred = properties.preferred
                        let display = CGRect(origin: .zero, size: size).applying(preferred)
                        // Convert AVFoundation's top-left transform into Core Image's bottom-left coordinates.
                        let orientation = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                            .concatenating(preferred)
                            .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
                            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height))
                        var layer = RenderLayer(clip: clip, trackID: target.trackID, image: nil, orientation: orientation)
                        layer.outgoingFamily = outgoingFamily
                        // Only where the stored path covers the clip's source range; otherwise the
                        // clip renders unstabilised rather than with a partly held correction.
                        layer.stabilization = correction
                        layers.append(layer)
                    }
                    if !track.isMuted {
                        let properties: AudioProperties
                        if let cached = audioProperties[assetID] { properties = cached }
                        else {
                            phase("audio.properties.begin", id: assetID)
                            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                                properties = AudioProperties(track: source, range: try await source.load(.timeRange),
                                                             formats: try await source.load(.formatDescriptions))
                            } else { properties = AudioProperties(track: nil, range: .zero, formats: []) }
                            audioProperties[assetID] = properties
                            phase("audio.properties.end", id: assetID)
                        }
                        if let source = properties.track {
                        let formats = properties.formats
                        let available = properties.range
                        let requested = CMTimeRangeGetIntersection(sourceRange, otherRange: available)
                        if requested.duration > .zero {
                            let audioStart = start + rate.timelineDuration(for: MediaTime(requested.start - sourceRange.start)).cmTime
                            let audioDuration = rate.timelineDuration(for: MediaTime(requested.duration)).cmTime
                            // Reserved only once the clip is known to contribute audio, so a clip whose
                            // trim falls outside the source no longer leaves an empty track behind.
                            guard let lane = pool.audioLane(in: composition, from: audioStart, until: audioStart + audioDuration, formats: formats) else {
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
                    phase("clip.assembly.end", id: clip.id)
                }
            }
            var sorted: [CMTime] = []
            phase("layers.end")
            phase("finalize.begin")
            for point in boundaries.sorted(by: { $0 < $1 }) {
                if sorted.last != point { sorted.append(point) }
            }
            videoComposition.instructions = zip(sorted, sorted.dropFirst()).compactMap { start, end in
                guard end > start else { return nil }
                let active = layers.filter { $0.clip.start.cmTime <= start && ($0.clip.start + $0.clip.duration).cmTime > start }
                return TimelineInstruction(range: CMTimeRange(start: start, end: end), layers: active, carrier: carrierTrack.trackID, canvas: canvas, transparentBackground: transparentBackground)
            }
            videoComposition.customVideoCompositorClass = TimelineCompositor.self
            videoComposition.renderSize = canvas
            videoComposition.frameDuration = frameDuration
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            audioMix.inputParameters = pool.finalizedAudioParameters()
            phase("finalize.end")
            return RenderPlan(composition: composition, videoComposition: videoComposition, audioMix: audioMix,
                              duration: duration, frameDuration: frameDuration, scopedURLs: scopedURLs, usesProxyMedia: usedProxyMedia)
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
    private var audioLanes: [(lane: AudioLane, end: CMTime, formats: [CMFormatDescription])] = []
    /// Input parameters in lane order; one object per audio track, as AVAudioMix requires.
    func finalizedAudioParameters() -> [AVMutableAudioMixInputParameters] {
        audioLanes.map { entry in
            // Decide only after every insert/scale on this packed lane is complete. A later
            // unity clip must never remove pitch correction from an earlier scaled segment.
            let segments = entry.lane.track.segments.filter { !$0.isEmpty }
            let unity = !segments.isEmpty && segments.allSatisfy { segment in
                let source = segment.timeMapping.source.duration, target = segment.timeMapping.target.duration
                return source.isNumeric && target.isNumeric && source > .zero && target > .zero
                    && CMTimeCompare(source, target) == 0
            }
            // At unchanged speed there is no pitch to correct. Avoid the spectral processor's
            // startup buffering; retain spectral whenever any segment needs rate correction.
            entry.lane.parameters.audioTimePitchAlgorithm = unity ? .varispeed : .spectral
            return entry.lane.parameters
        }
    }

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
    mutating func audioLane(in composition: AVMutableComposition, from start: CMTime, until end: CMTime, formats: [CMFormatDescription]) -> AudioLane? {
        // A post-effects tap is prepared for a lane's audio format. Switching48k/44.1k (or channel
        // layout/cookie) inside that lane can leave AVPlayer stuck after a seek into the next source.
        // Keep bounded packing within compatible formats rather than assigning a track per clip.
        if let index = audioLanes.firstIndex(where: { $0.end <= start && $0.formats.count == formats.count && zip($0.formats, formats).allSatisfy { CFEqual($0.0, $0.1) } }) {
            audioLanes[index].end = end
            return audioLanes[index].lane
        }
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let lane = AudioLane(track: track, parameters: AVMutableAudioMixInputParameters(track: track))
        audioLanes.append((lane, end, formats))
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
            defer { if writer.status == .writing { writer.cancelWriting() } }
            for frame in 0..<unitFrames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData && writer.status == .writing { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.001) }
                guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))) else { throw writer.error ?? MediaEngineError.failed("배경 프레임 쓰기 실패") }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(unitFrames)))
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            while done.wait(timeout: .now() + 0.05) == .timedOut { try Task.checkCancellation() }
            guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("배경 생성 실패") }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

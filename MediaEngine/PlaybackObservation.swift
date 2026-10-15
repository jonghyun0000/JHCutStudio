import Foundation
import AVFoundation
import MediaToolbox
import Darwin


public enum PlaybackObservationMode: String, Sendable {
    /// Video/transport observation that leaves the item's audio processing unchanged.
    case transport
    /// Explicit per-track post-effects taps. Inserting taps can add playback startup latency.
    case trackPostEffects
}

/// First128 callbacks per track, including invalid/prefill source ranges. No audio samples are retained.
/// Every callback reserves a unique preallocated slot, fills it, then atomically publishes it.
private final class PlaybackAudioProvenance {
    static let capacity = 128, stride = 15
    let trackID: CMPersistentTrackID
    private let callbackCount: UnsafeMutablePointer<Int64>
    private let storage: UnsafeMutablePointer<Int64>
    init(trackID: CMPersistentTrackID) {
        self.trackID = trackID
        callbackCount = .allocate(capacity: 1); callbackCount.initialize(to: 0)
        storage = .allocate(capacity: Self.capacity * Self.stride)
        storage.initialize(repeating: 0, count: Self.capacity * Self.stride)
    }
    deinit {
        callbackCount.deinitialize(count: 1); callbackCount.deallocate()
        storage.deinitialize(count: Self.capacity * Self.stride); storage.deallocate()
    }
    func record(requested: CMItemCount, delivered: CMItemCount, flags: UInt32, status: OSStatus,
                sourceRange: CMTimeRange, signal: Bool, sourceReadTicks: UInt64) {
        let index = OSAtomicIncrement64Barrier(callbackCount) - 1
        guard index >= 0 && index < Int64(Self.capacity) else { return }
        let row = storage.advanced(by: Int(index) * Self.stride)
        row[0] = Int64(requested); row[1] = Int64(delivered); row[2] = Int64(flags); row[3] = Int64(status)
        row[4] = sourceRange.start.value; row[5] = Int64(sourceRange.start.timescale); row[6] = Int64(sourceRange.start.flags.rawValue); row[7] = sourceRange.start.epoch
        row[8] = sourceRange.duration.value; row[9] = Int64(sourceRange.duration.timescale); row[10] = Int64(sourceRange.duration.flags.rawValue); row[11] = sourceRange.duration.epoch
        row[12] = signal ? 1 : 0; row[13] = Int64(bitPattern: sourceReadTicks)
        _ = OSAtomicCompareAndSwap64Barrier(0, 1, row.advanced(by: 14))
    }
    func report() -> [String: Any] {
        var callbacks: [[String: Any]] = []
        for index in 0..<Self.capacity {
            let row = storage.advanced(by: index * Self.stride)
            guard OSAtomicAdd64Barrier(0, row.advanced(by: 14)) == 1 else { continue }
            callbacks.append(["index": index, "requestedFrames": row[0], "deliveredFrames": row[1], "sourceFlags": row[2], "status": row[3],
                "sourceStartValue": row[4], "sourceStartTimescale": row[5], "sourceStartFlags": row[6], "sourceStartEpoch": row[7],
                "sourceDurationValue": row[8], "sourceDurationTimescale": row[9], "sourceDurationFlags": row[10], "sourceDurationEpoch": row[11],
                "hasSignal": row[12] == 1, "sourceReadHostTicks": row[13]])
        }
        let count = OSAtomicAdd64Barrier(0, callbackCount)
        return ["trackID": trackID, "capacity": Self.capacity, "callbacksObserved": count,
                "callbacksOmitted": max(0, count - Int64(Self.capacity)), "callbacks": callbacks]
    }
}

// Preallocated atomic counters; the real-time callback performs no locks, I/O or allocation.
private final class PlaybackAudioCounters {
    let values: UnsafeMutablePointer<Int64>
    init() { values = .allocate(capacity: 5); values.initialize(repeating: 0, count: 5) }
    deinit { values.deinitialize(count: 5); values.deallocate() }
    func read(_ i: Int) -> Int64 { OSAtomicAdd64Barrier(0, values.advanced(by: i)) }
    func add(_ n: Int64, _ i: Int) { OSAtomicAdd64Barrier(n, values.advanced(by: i)) }
}
private final class PlaybackTapState {
    let counters: PlaybackAudioCounters
    var float32 = false
    let provenance: PlaybackAudioProvenance
    init(_ counters: PlaybackAudioCounters, provenance: PlaybackAudioProvenance) { self.counters = counters; self.provenance = provenance }
}

/// Transport-only diagnostics by default; per-track audio taps require an explicit mode.
/// Taps observe each track after its effects, not the final summed output mix.
/// Does not record audio or prove sound emitted by physical speakers.
@MainActor public final class PlaybackObservation {
    public let mode: PlaybackObservationMode
    private var audioProvenance: [PlaybackAudioProvenance] = []
    private var stoppedAudioProvenance: [[String: Any]]?
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var originalMix: AVAudioMix?
    private var installedMix: AVAudioMix?
    private var video: AVPlayerItemVideoOutput?
    private let counters = PlaybackAudioCounters()
    private var timer: Timer?
    private var rows: [[String: Any]] = []
    private let started = ProcessInfo.processInfo.systemUptime
    private var stopped = false
    private var videoAttached = false
    private var videoFrames = 0
    private var lastFrameTime: Double?
    public private(set) var attachedAudioTaps = 0
    /// True only while this observation still owns the installed audio graph. Historical tap
    /// counts remain available in a finished report after stop() restores the original mix.
    public var hasActiveAudioTaps: Bool {
        guard !stopped, attachedAudioTaps > 0, let item, let installedMix else { return false }
        return item.audioMix === installedMix
    }
    public init(player: AVPlayer, mode: PlaybackObservationMode = .transport) throws {
        self.mode = mode
        guard let item = player.currentItem, item.status == .readyToPlay else { throw MediaEngineError.failed("미리보기가 준비된 뒤 진단을 시작하세요.") }
        self.player = player; self.item = item; originalMix = item.audioMix
        let video = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        self.video = video
        let mix = AVMutableAudioMix()
        for parameter in (mode == .trackPostEffects ? item.audioMix?.inputParameters ?? [] : []) {
            guard parameter.audioTapProcessor == nil, let copy = parameter.mutableCopy() as? AVMutableAudioMixInputParameters else {
                throw MediaEngineError.failed("이미 오디오 처리기가 연결돼 있어 재생 진단을 시작할 수 없습니다.")
            }
            let provenance = PlaybackAudioProvenance(trackID: parameter.trackID); audioProvenance.append(provenance)
            let storage = Unmanaged.passRetained(PlaybackTapState(counters, provenance: provenance)).toOpaque()
            var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: storage,
                init: { _, info, out in out.pointee = info },
                finalize: { tap in Unmanaged<PlaybackTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
                prepare: { tap, _, format in
                    let state = Unmanaged<PlaybackTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    state.float32 = format.pointee.mBitsPerChannel == 32 && format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    if !state.float32 { state.counters.add(1, 4) }
                }, unprepare: { _ in },
                process: { tap, frames, _, buffers, count, flags in
                    let state = Unmanaged<PlaybackTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    var sourceRange = CMTimeRange.invalid
                    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &sourceRange, count)
                    let sourceReadTicks = mach_absolute_time()
                    if status != noErr {
                        count.pointee = 0; state.counters.add(1, 3)
                        state.provenance.record(requested: frames, delivered: 0, flags: 0, status: status, sourceRange: sourceRange, signal: false, sourceReadTicks: sourceReadTicks)
                        return
                    }
                    var signal = false
                    state.counters.add(1, 0); state.counters.add(Int64(count.pointee), 1)
                    if state.float32 {
                        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                            if let data = buffer.mData {
                                let samples = data.assumingMemoryBound(to: Float.self)
                                for i in 0..<(Int(buffer.mDataByteSize)/4) where abs(samples[i]) > 0.0001 {
                                    state.counters.add(1, 2); signal = true; break
                                }
                            }
                        }
                    }
                    state.provenance.record(requested: frames, delivered: count.pointee, flags: flags.pointee, status: status, sourceRange: sourceRange, signal: signal, sourceReadTicks: sourceReadTicks)
                })
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            guard status == noErr, let tap else {
                Unmanaged<PlaybackTapState>.fromOpaque(storage).release()
                throw MediaEngineError.failed("오디오 진단 연결 실패: \(status)")
            }
            copy.audioTapProcessor = tap; mix.inputParameters.append(copy); attachedAudioTaps += 1
        }
        item.add(video); videoAttached = true
        if attachedAudioTaps > 0 { item.audioMix = mix; installedMix = item.audioMix }
        sample("started")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample("tick") }
        }
    }
    public func sample(_ event: String, displayedTime: Double? = nil) {
        guard !stopped, let player, let item, let video else { return }
        let time = player.currentTime()
        if video.hasNewPixelBuffer(forItemTime: time) {
            var frameTime = CMTime.invalid
            if video.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &frameTime) != nil {
                videoFrames += 1; lastFrameTime = frameTime.seconds.isFinite ? frameTime.seconds : nil
            }
        }
        var row: [String: Any] = ["event": event, "uptime": ProcessInfo.processInfo.systemUptime, "elapsed": ProcessInfo.processInfo.systemUptime-started,
            "playerTime": time.seconds.isFinite ? time.seconds : 0, "rate": player.rate,
            "timeControlStatus": player.timeControlStatus.rawValue, "sameItem": player.currentItem === item,
            "audioMeasurement": attachedAudioTaps > 0 ? "perTrackPostEffects" : "notMeasured", "videoFrames": videoFrames]
        for (index, name) in ["audioCallbacks", "audioFrames", "nonSilentBuffers", "audioErrors", "unsupportedAudioFormats"].enumerated() {
            row[name] = attachedAudioTaps > 0 ? counters.read(index) as Any : NSNull()
        }
        if let displayedTime { row["displayedTime"] = displayedTime }
        if let lastFrameTime { row["lastFrameTime"] = lastFrameTime }
        if rows.count >= 2_000 { rows.removeFirst(1_000) }
        rows.append(row)
    }
    public var currentSample: [String: Any]? { rows.last }
    public func finish() throws -> Data {
        sample("finished"); stop()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "mode": mode.rawValue, "sampleIntervalSeconds": 0.05, "audioTaps": attachedAudioTaps,
            "audioMeasurement": attachedAudioTaps > 0 ? "perTrackPostEffects" : "notMeasured", "audioGraphModified": attachedAudioTaps > 0,
            "sourceProvenance": stoppedAudioProvenance ?? audioProvenance.map { $0.report() }, "hostTimeNumerator": timebase.numer, "hostTimeDenominator": timebase.denom,
            "scope": "Transport mode leaves audioMix untouched and does not measure audio. Explicit trackPostEffects taps can add startup latency; they measure separate tracks, not the final summed mix or physical speakers. Raw signal counters include prefill/source ranges before the requested playback position; sourceProvenance records the first128 callbacks per track and does not establish audio/video synchronization. Float32 signal threshold is amplitude>0.0001.", "rows": rows], options: [.prettyPrinted, .sortedKeys])
    }
    public func saveReport(to url: URL) throws {
        try DocumentAtomicWrite.preserve(try finish(), at: url)
    }
    public func stop() {
        guard !stopped, let item, let video else { return }; stopped = true; timer?.invalidate(); timer = nil
        stoppedAudioProvenance = audioProvenance.map { $0.report() }
        audioProvenance.removeAll()
        if videoAttached { item.remove(video) }; videoAttached = false
        if attachedAudioTaps > 0, item.audioMix === installedMix { item.audioMix = originalMix }
        self.player = nil; self.item = nil; self.video = nil; originalMix = nil; installedMix = nil
    }
    deinit {
        timer?.invalidate()
        guard let cleanupItem = item, let cleanupVideo = video else { return }
        let cleanupMix = originalMix, expectedMix = installedMix
        let restore = attachedAudioTaps > 0, detachVideo = videoAttached
        Task { @MainActor in
            if detachVideo { cleanupItem.remove(cleanupVideo) }
            if restore, cleanupItem.audioMix === expectedMix { cleanupItem.audioMix = cleanupMix }
        }
    }
}

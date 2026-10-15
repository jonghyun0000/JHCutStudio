import Foundation
@preconcurrency import AVFoundation
import SoundAnalysis

/// What a stretch of audio most likely contains. Only candidates: the app uses them to decide
/// what Whisper does not need to hear and to warn about captions over silence, never to edit audio.
public enum VoiceActivityKind: String, Codable, Sendable, CaseIterable {
    case speech, silence, music, noise
    /// Neither confidently speech nor confidently something else. Treated as speech (never skipped).
    case uncertain
    public var label: String {
        switch self { case .speech: return "말소리"; case .silence: return "무음"; case .music: return "음악"; case .noise: return "강한 소음"; case .uncertain: return "불확실" }
    }
}

/// Conservative skips energy-confirmed silence only; fast additionally skips classifier-
/// labelled music/noise. Neither deletes a candidate merely because it is shorter than 4s.
public enum VoiceActivityPolicy: String, Codable, Sendable, CaseIterable {
    case conservative, fast
    public var label: String { self == .conservative ? "누락 최소화" : "빠른 인식" }
    public var detail: String { self == .conservative ? "무음만 줄이고 음악·소음 속 짧은 말도 인식합니다." : "음악·소음도 줄입니다. 섞인 대사가 누락될 수 있어 원음 검토가 필요합니다." }
}

public struct VoiceActivitySegment: Codable, Equatable, Sendable {
    public var kind: VoiceActivityKind
    /// Absolute source seconds.
    public var start: Double
    public var end: Double
    /// Mean classifier confidence for `kind` (energy-only silence: 1).
    public var confidence: Double
    public var duration: Double { end - start }
}

public struct VoiceActivityReport: Codable, Equatable, Sendable {
    public static let version = 3
    public var version = VoiceActivityReport.version
    public var sourceStart: Double
    public var duration: Double
    public var segments: [VoiceActivitySegment]
    /// Regions Whisper must hear under the chosen policy, padded and merged. Absolute seconds.
    public var speechRegions: [ClosedRange<Double>]
    /// False when the system sound classifier could not run; then only silence is detected.
    public var classifierAvailable: Bool
    public var analysisSeconds: Double
    public var policy: VoiceActivityPolicy
    public var requestedChannel: Int
    public var channelSelection: AudioChannelSelection?

    public func seconds(of kind: VoiceActivityKind) -> Double { segments.filter { $0.kind == kind }.reduce(0) { $0 + $1.duration } }
    public var speechRegionSeconds: Double { speechRegions.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    /// Share of the analysed range that does not need recognition.
    /// Confidently classified speech (absolute seconds): what coverage repair looks for.
    public var confidentSpeech: [ClosedRange<Double>] { segments.filter { $0.kind == .speech && $0.confidence.isFinite && $0.confidence >= CoverageRepair.evidenceConfidence && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.map { $0.start...$0.end } }
    public var skippableShare: Double { duration > 0 ? max(0, 1 - speechRegionSeconds / duration) : 0 }

    enum CodingKeys: String, CodingKey { case version, sourceStart, duration, segments, regions, classifierAvailable, analysisSeconds, policy, requestedChannel, channelSelection }
    struct Region: Codable { var start: Double; var end: Double }
    public init(sourceStart: Double, duration: Double, segments: [VoiceActivitySegment], speechRegions: [ClosedRange<Double>], classifierAvailable: Bool, analysisSeconds: Double, policy: VoiceActivityPolicy = .conservative, requestedChannel: Int = -1, channelSelection: AudioChannelSelection? = nil) {
        self.sourceStart = sourceStart; self.duration = duration; self.segments = segments; self.speechRegions = speechRegions
        self.classifierAvailable = classifierAvailable; self.analysisSeconds = analysisSeconds
        self.policy = policy; self.requestedChannel = requestedChannel; self.channelSelection = channelSelection
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); sourceStart = try c.decode(Double.self, forKey: .sourceStart)
        duration = try c.decode(Double.self, forKey: .duration); segments = try RecognitionCacheSafety.array(VoiceActivitySegment.self, key:"segments", decoder:decoder, maximum:RecognitionCacheSafety.maximumSegments)
        let regions = try RecognitionCacheSafety.array(Region.self, key:"regions", decoder:decoder, maximum:RecognitionCacheSafety.maximumRegions)
        guard regions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start <= $0.end }) else { throw DecodingError.dataCorruptedError(forKey: .regions, in: c, debugDescription: "Invalid VAD region") }
        speechRegions = regions.map { $0.start...$0.end }
        policy = try c.decodeIfPresent(VoiceActivityPolicy.self, forKey: .policy) ?? .fast
        requestedChannel = try c.decodeIfPresent(Int.self, forKey: .requestedChannel) ?? -1
        channelSelection = try c.decodeIfPresent(AudioChannelSelection.self, forKey: .channelSelection)
        classifierAvailable = try c.decode(Bool.self, forKey: .classifierAvailable); analysisSeconds = try c.decode(Double.self, forKey: .analysisSeconds)
        guard isValid else { throw ProjectError("말소리 분석 캐시의 범위·정렬·채널·숫자가 올바르지 않습니다.") }
    }
    public var estimatedBytes: Int { 256 + segments.count * 80 + speechRegions.count * 32 }
    public var isValid: Bool {
        guard (1...Self.version).contains(version), sourceStart.isFinite, sourceStart >= 0, sourceStart <= RecognitionCacheSafety.maximumStart,
              duration.isFinite, duration > 0, duration <= RecognitionCacheSafety.maximumDuration,
              analysisSeconds.isFinite, analysisSeconds >= 0, analysisSeconds <= 604_800,
              (-1...31).contains(requestedChannel), segments.count <= RecognitionCacheSafety.maximumSegments, speechRegions.count <= RecognitionCacheSafety.maximumRegions,
              version < 3 || channelSelection?.matches(requestedChannel:requestedChannel) == true else { return false }
        let end = sourceStart + duration
        var previous = sourceStart
        for s in segments {
            guard s.start.isFinite, s.end.isFinite, s.confidence.isFinite, (0...1).contains(s.confidence), s.start >= previous - 0.0001,
                  s.start >= sourceStart - 0.0001, s.end > s.start, s.end <= end + 0.0001 else { return false }
            previous = s.end
        }
        previous = sourceStart
        for r in speechRegions {
            guard r.lowerBound.isFinite, r.upperBound.isFinite, r.lowerBound >= previous - 0.0001,
                  r.lowerBound >= sourceStart - 0.0001, r.upperBound > r.lowerBound, r.upperBound <= end + 0.0001 else { return false }
            previous = r.upperBound
        }
        return !segments.isEmpty
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(sourceStart, forKey: .sourceStart); try c.encode(duration, forKey: .duration)
        try c.encode(segments, forKey: .segments); try c.encode(speechRegions.map { Region(start: $0.lowerBound, end: $0.upperBound) }, forKey: .regions)
        try c.encode(classifierAvailable, forKey: .classifierAvailable); try c.encode(analysisSeconds, forKey: .analysisSeconds)
        try c.encode(policy, forKey: .policy); try c.encode(requestedChannel, forKey: .requestedChannel)
        try c.encodeIfPresent(channelSelection, forKey: .channelSelection)
    }
}

/// A caption whose time range has (almost) no speech under it.
public struct SilentCaptionWarning: Equatable, Sendable {
    public var index: Int
    public var kind: VoiceActivityKind
    public var speechShare: Double
}

/// Voice-activity analysis with the classifier built into macOS (SoundAnalysis `version1`, part of
/// the OS — nothing is downloaded) plus a signal-level silence detector. Two read-only streaming
/// passes select native channels, then classify exactly the same mono signal ASR hears.
public enum VoiceActivity {
    public static let windowSeconds = 1.5
    public static let hopSeconds = 0.75
    /// Fast-mode lower silence threshold: recording floor + 8 dB, clamped to [−50, −35].
    /// Conservative uses −60 dBFS. Every 50 ms block in a slot must be below the threshold.
    public static let silenceDBFS = -50.0
    /// Non-speech shorter than this stays inside the speech regions (pauses between sentences).
    public static let minimumSkipSeconds = 3.0
    /// Padding kept around every speech region so word edges are never clipped.
    public static let paddingSeconds = 0.5
    /// Singing is music for captioning purposes: lyrics are not dialogue and Whisper garbles them.
    static let singingLabels: Set<String> = ["singing", "choir_singing", "humming", "rapping", "yodeling", "chant", "whistling"]
    static let speechLabels: Set<String> = ["speech", "shout", "yell", "whispering", "children_shouting", "battle_cry", "screaming", "laughter"]
    static let noiseLabels: Set<String> = ["wind", "wind_noise_microphone", "wind_rustling_leaves", "traffic_noise", "rail_transport", "train", "train_wheels_squealing",
                                           "engine", "engine_idling", "engine_accelerating_revving", "vehicle", "aircraft", "rain", "water", "stream_burbling", "waterfall",
                                           "applause", "cheering", "crowd", "babble", "vacuum_cleaner", "hair_dryer", "blender", "power_tool", "drill", "air_conditioner", "mechanical_fan"]
    /// Zero-crossing rate above which loud audio without speech/music evidence counts as broadband noise.
    static let noiseZeroCrossingRate = 0.3

    struct Window { var start: Double; var end: Double; var speech: Double; var singing: Double; var music: Double; var noise: Double; var silenceLabel: Double; var dbfs: Double; var zcr: Double }

    public static func analyze(url: URL, sourceStart: MediaTime, duration: MediaTime,
                               useClassifier: Bool = true, preferredChannel: Int = -1, policy: VoiceActivityPolicy = .conservative, progress: (@Sendable (Double) -> Void)? = nil) async throws -> VoiceActivityReport {
        guard duration > .zero, duration.seconds <= RecognitionCacheSafety.maximumDuration, sourceStart >= .zero, sourceStart.seconds <= RecognitionCacheSafety.maximumStart else { throw AudioAnalysisError("음성 구간 분석은 24시간 이내의 유효한 원본 범위를 선택하세요.") }
        let begun = Date()
        progress?(0)
        let selection = try await AudioChannelSelection.resolve(url: url, sourceStart: sourceStart, duration: duration, preferredChannel: preferredChannel) { progress?($0 * 0.15) }
        var lastProgress = 0.15
        final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
            var results: [(start: Double, end: Double, labels: [String: Double])] = []
            var failure: Error?
            func request(_ request: SNRequest, didProduce result: SNResult) {
                guard let r = result as? SNClassificationResult else { return }
                var labels: [String: Double] = [:]
                for c in r.classifications where c.confidence > 0.01 { labels[c.identifier] = c.confidence }
                results.append((r.timeRange.start.seconds, (r.timeRange.start + r.timeRange.duration).seconds, labels))
            }
            func request(_ request: SNRequest, didFailWithError error: Error) { failure = error }
        }
        let collector = Collector()
        var analyzer: SNAudioStreamAnalyzer?, format: AVAudioFormat?, classifierOK = useClassifier
        var position: AVAudioFramePosition = 0
        // Energy per 50 ms block of the same phase-safe signal that ASR hears.
        var blockEnergy: [Double] = [], blockCrossings: [Int] = [], blockSum = 0.0, blockCount = 0, blockCross = 0, blockSize = 0, rate = 0.0, previous: Float = 0
        let total = duration.seconds
        _ = try await SourcePCM.readStable(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            try Task.checkCancellation()
            let n = chunk.values.count / chunk.channels
            if format == nil {
                rate = chunk.sampleRate; blockSize = max(1, Int(rate * 0.05))
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
                if classifierOK, let format {
                    do {
                        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                        request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 1000)
                        request.overlapFactor = 1 - hopSeconds / windowSeconds
                        let made = SNAudioStreamAnalyzer(format: format)
                        try made.add(request, withObserver: collector); analyzer = made
                    } catch { classifierOK = false }
                }
            }
            guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
            buffer.frameLength = AVAudioFrameCount(n)
            let out = buffer.floatChannelData![0], mono = try selection.mono(chunk)
            for i in 0..<n {
                let s = mono[i]; out[i] = s
                blockSum += Double(s * s); blockCount += 1
                if (s >= 0) != (previous >= 0) { blockCross += 1 }
                previous = s
                if blockCount == blockSize { blockEnergy.append(blockSum / Double(blockCount)); blockCrossings.append(blockCross); blockSum = 0; blockCount = 0; blockCross = 0 }
            }
            analyzer?.analyze(buffer, atAudioFramePosition: position); position += AVAudioFramePosition(n)
            let fraction = AudioAnalysisProgress.fraction(elapsed: chunk.start - sourceStart.seconds + Double(n) / rate, total: total)
            lastProgress = max(lastProgress, min(0.99, 0.15 + 0.85 * fraction)); progress?(lastProgress)
        }
        if blockCount > 0 { blockEnergy.append(blockSum / Double(blockCount)); blockCrossings.append(blockCross) }
        analyzer?.completeAnalysis()
        if collector.failure != nil || (classifierOK && collector.results.isEmpty) { classifierOK = false }
        func dbfs(_ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(from / 0.05)), b = min(blockEnergy.count, max(a + 1, Int((to / 0.05).rounded(.up))))
            guard a < b else { return -120 }
            let mean = blockEnergy[a..<b].reduce(0, +) / Double(b - a)
            return mean > 0 ? 10 * log10(mean) : -120
        }
        /// Loudest 50 ms block in the range: silence requires every block to be quiet.
        func peakDBFS(_ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(from / 0.05)), b = min(blockEnergy.count, max(a + 1, Int((to / 0.05).rounded(.up))))
            guard a < b, let m = blockEnergy[a..<b].max(), m > 0 else { return -120 }
            return 10 * log10(m)
        }
        func zcr(_ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(from / 0.05)), b = min(blockCrossings.count, max(a + 1, Int((to / 0.05).rounded(.up))))
            guard a < b, blockSize > 0 else { return 0 }
            return Double(blockCrossings[a..<b].reduce(0, +)) / Double((b - a) * blockSize)
        }
        // Fast mode adapts to room tone; conservative keeps quiet speech down to −60 dBFS.
        let sortedDB = blockEnergy.map { $0 > 0 ? 10 * log10($0) : -120 }.sorted()
        let floorDB = sortedDB.isEmpty ? -120 : sortedDB[Int(Double(sortedDB.count - 1) * 0.1)]
        let silenceThreshold = policy == .conservative ? -60 : min(-35, max(silenceDBFS, floorDB + 8))
        // Windows in relative seconds.
        var windows: [Window] = []
        if classifierOK {
            for r in collector.results.sorted(by: { $0.start < $1.start }) {
                let speech = min(1, r.labels.filter { speechLabels.contains($0.key) }.values.reduce(0, +))
                let noise = min(1, r.labels.filter { noiseLabels.contains($0.key) }.values.reduce(0, +))
                let singing = min(1, r.labels.filter { singingLabels.contains($0.key) }.values.reduce(0, +))
                windows.append(Window(start: r.start, end: min(total, r.end), speech: speech, singing: singing, music: max(r.labels["music"] ?? 0, singing), noise: noise,
                                      silenceLabel: r.labels["silence"] ?? 0, dbfs: dbfs(r.start, r.end), zcr: zcr(r.start, r.end)))
            }
        } else {
            var t = 0.0
            while t < total { let e = min(total, t + windowSeconds); windows.append(Window(start: t, end: e, speech: 0, singing: 0, music: 0, noise: 0, silenceLabel: 0, dbfs: dbfs(t, e), zcr: zcr(t, e))); t += hopSeconds }
        }
        // Classify each hop-sized slot by the windows covering it.
        var kinds: [(kind: VoiceActivityKind, confidence: Double, start: Double, end: Double)] = []
        for w in windows {
            let slotEnd = min(w.end, w.start + hopSeconds)
            let kind: VoiceActivityKind, confidence: Double
            // Silence is judged on this slot's own energy: a quiet word tail at the start of a
            // mostly silent 1.5 s window must not be called silence.
            let slotDB = peakDBFS(w.start, slotEnd)
            if slotDB < silenceThreshold { kind = .silence; confidence = 1 }
            else if !classifierOK { kind = .uncertain; confidence = 0 }
            // A singing voice also scores as speech; it counts as speech only when speech wins.
            else if w.speech >= 0.3 && w.speech >= w.singing { kind = .speech; confidence = w.speech }
            else if w.music >= 0.4 && w.speech < 0.3 || (w.singing > w.speech && w.music >= 0.4) { kind = .music; confidence = w.music }
            else if w.dbfs > -35 && w.speech < 0.1 && (w.noise >= 0.5 || (w.zcr >= noiseZeroCrossingRate && w.music < 0.3)) { kind = .noise; confidence = max(w.noise, min(1, w.zcr / 0.5)) }
            else { kind = .uncertain; confidence = max(w.speech, w.music, w.noise) }
            kinds.append((kind, confidence, w.start, slotEnd))
        }
        // Merge consecutive slots into segments; confidence is the mean over the merged slots.
        var segments: [VoiceActivitySegment] = [], sums: [(Double, Int)] = []
        for k in kinds {
            if let last = segments.last, last.kind == k.kind, k.start <= last.end + 0.01 {
                segments[segments.count - 1].end = k.end; sums[sums.count - 1].0 += k.confidence; sums[sums.count - 1].1 += 1
            } else { segments.append(VoiceActivitySegment(kind: k.kind, start: k.start, end: k.end, confidence: k.confidence)); sums.append((k.confidence, 1)) }
        }
        for i in segments.indices { segments[i].confidence = sums[i].0 / Double(sums[i].1) }
        // The classifier only reports complete windows, so the last < 1.5 s of audio may be
        // uncovered: judge it by energy (speech continues, or silence). Past the end of the audio
        // track itself there is nothing to hear: silence.
        let audioEnd = min(total, Double(blockEnergy.count) * 0.05)
        if let last = segments.last, last.end < audioEnd - 0.01 {
            if peakDBFS(last.end, audioEnd) < silenceThreshold {
                if last.kind == .silence { segments[segments.count - 1].end = audioEnd }
                else { segments.append(VoiceActivitySegment(kind: .silence, start: last.end, end: audioEnd, confidence: 1)) }
            } else if last.kind == .speech || last.kind == .uncertain { segments[segments.count - 1].end = audioEnd }
            else { segments.append(VoiceActivitySegment(kind: .uncertain, start: last.end, end: audioEnd, confidence: 0)) }
        }
        if let last = segments.last, last.end < total - 0.001 {
            if last.kind == .silence { segments[segments.count - 1].end = total }
            else { segments.append(VoiceActivitySegment(kind: .silence, start: last.end, end: total, confidence: 1)) }
        }
        if segments.isEmpty { segments = [VoiceActivitySegment(kind: .silence, start: 0, end: total, confidence: 1)] }
        // Conservative skips silence only. Fast may skip music/noise, but never bridges
        // over speech/uncertain slots; one short reply is enough to keep a candidate.
        func skippable(_ kind: VoiceActivityKind) -> Bool { Self.skippable(kind, policy: policy) }
        var regions = candidateRegions(segments: segments, duration: total, policy: policy)
        // Extend region edges while the signal is above the silence floor (50 ms steps, ≤ 1.5 s),
        // so soft onsets and word endings are never cut off.
        // Only into audio labelled silence: loud music or noise next to speech is not a word tail.
        let floor = pow(10, silenceThreshold / 10)
        func inSilence(_ block: Int) -> Bool {
            let t = (Double(block) + 0.5) * 0.05
            return segments.contains { $0.kind == .silence && $0.start <= t && t < $0.end }
        }
        func audible(_ block: Int) -> Bool { block >= 0 && block < blockEnergy.count && blockEnergy[block] > floor && inSilence(block) }
        regions = regions.map { region in
            var a = Int(region.lowerBound / 0.05), b = Int((region.upperBound / 0.05).rounded(.up))
            var steps = 0
            while a > 0, steps < 30, audible(a - 1) { a -= 1; steps += 1 }
            steps = 0
            while b < blockEnergy.count, steps < 30, audible(b) { b += 1; steps += 1 }
            return max(0, Double(a) * 0.05)...min(total, Double(b) * 0.05)
        }
        var merged: [ClosedRange<Double>] = []
        for r in regions { if let last = merged.last, r.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound) } else { merged.append(r) } }
        regions = merged
        // Drop regions that are only padding (non-speech runs back to back).
        regions = regions.filter { region in
            segments.contains { !skippable($0.kind) && $0.end > region.lowerBound && $0.start < region.upperBound }
        }
        // Even one hop of speech/uncertain audio is kept, including short responses in music.
        try Task.checkCancellation()
        progress?(1)
        let offset = sourceStart.seconds
        return VoiceActivityReport(sourceStart: offset, duration: total,
                                   segments: segments.map { var s = $0; s.start += offset; s.end += offset; return s },
                                   speechRegions: regions.map { ($0.lowerBound + offset)...($0.upperBound + offset) },
                                   classifierAvailable: classifierOK, analysisSeconds: Date().timeIntervalSince(begun), policy: policy, requestedChannel: preferredChannel, channelSelection: selection)
    }

    private static func skippable(_ kind: VoiceActivityKind, policy: VoiceActivityPolicy) -> Bool {
        kind == .silence || (policy == .fast && (kind == .music || kind == .noise))
    }

    /// Region planning is separate from classification so brief speech/uncertain evidence can
    /// be verified independently of macOS classifier probabilities. Times are recording-local.
    static func candidateRegions(segments: [VoiceActivitySegment], duration: Double, policy: VoiceActivityPolicy) -> [ClosedRange<Double>] {
        var runs: [(start: Double, end: Double)] = []
        for s in segments where skippable(s.kind, policy: policy) {
            if let last = runs.last, s.start <= last.end + 0.001 { runs[runs.count - 1].end = s.end }
            else { runs.append((s.start, s.end)) }
        }
        var regions: [ClosedRange<Double>] = [], cursor = 0.0
        for run in runs where run.end - run.start >= minimumSkipSeconds {
            let b = min(duration, run.start + paddingSeconds)
            if b > cursor + 0.05 { regions.append(cursor...b) }
            cursor = max(cursor, run.end - paddingSeconds)
        }
        if cursor < duration - 0.05 { regions.append(cursor...duration) }
        return regions.filter { r in segments.contains { !skippable($0.kind, policy: policy) && $0.end > r.lowerBound && $0.start < r.upperBound } }
    }

    /// Captions (absolute source seconds) with less than `minimumSpeechShare` of their time over
    /// speech or uncertain audio. The dominant non-speech kind under the caption is reported.
    public static func silentCaptions(_ captions: [ClosedRange<Double>], report: VoiceActivityReport, minimumSpeechShare: Double = 0.2) -> [SilentCaptionWarning] {
        var warnings: [SilentCaptionWarning] = []
        for (index, caption) in captions.enumerated() {
            let length = caption.upperBound - caption.lowerBound
            guard length > 0, caption.upperBound > report.sourceStart, caption.lowerBound < report.sourceStart + report.duration else { continue }
            var byKind: [VoiceActivityKind: Double] = [:]
            for s in report.segments {
                let overlap = min(s.end, caption.upperBound) - max(s.start, caption.lowerBound)
                if overlap > 0 { byKind[s.kind, default: 0] += overlap }
            }
            let covered = byKind.values.reduce(0, +)
            guard covered > 0 else { continue }
            let speech = (byKind[.speech] ?? 0) + (byKind[.uncertain] ?? 0)
            let share = speech / covered
            if share < minimumSpeechShare, let dominant = byKind.filter({ $0.key != .speech && $0.key != .uncertain }).max(by: { $0.value < $1.value })?.key {
                warnings.append(SilentCaptionWarning(index: index, kind: dominant, speechShare: share))
            }
        }
        return warnings
    }
}

extension VoiceActivity {
    /// Whisper often stretches a caption over the silence that follows (or precedes) the words.
    /// Pulls a cue edge that lies inside a detected silence back to the silence boundary, keeping
    /// `margin` seconds, and never below `minimumDuration`. Times are absolute source seconds.
    public static func tightened(_ cues: [CaptionCue], report: VoiceActivityReport, margin: Double = 0.2, minimumDuration: Double = 0.4) -> (cues: [CaptionCue], changed: Int) {
        let silences = report.segments.filter { $0.kind == .silence }
        var changed = 0
        let result = cues.map { cue -> CaptionCue in
            var start = cue.start.seconds, end = start + cue.duration.seconds
            if let s = silences.first(where: { $0.start < end && end <= $0.end && $0.start > start }) { end = min(end, s.start + margin) }
            if let s = silences.first(where: { $0.start <= start && start < $0.end && $0.end < end }) { start = max(start, s.end - margin) }
            guard end - start >= minimumDuration, abs(start - cue.start.seconds) > 0.001 || abs(end - (cue.start.seconds + cue.duration.seconds)) > 0.001 else { return cue }
            changed += 1
            var copy = cue; copy.start = MediaTime(seconds: start); copy.duration = MediaTime(seconds: end - start); return copy
        }
        return (result, changed)
    }
}

/// Maps recognition time in a compacted recording (speech regions only, joined by short silence)
/// back to source time. Whisper then spends no time on long silence or music.
public struct CompactedTimeline: Equatable, Sendable {
    public struct Piece: Equatable, Sendable { public var compactStart: Double; public var sourceStart: Double; public var length: Double }
    public static let joinSilence = 0.6
    public var pieces: [Piece]
    public var compactDuration: Double { (pieces.last.map { $0.compactStart + $0.length }) ?? 0 }

    /// `regions` are relative to the recording start and must be sorted.
    public init(regions: [ClosedRange<Double>], recordingDuration: Double) {
        var pieces: [Piece] = [], at = 0.0
        for region in regions {
            let a = max(0, region.lowerBound), b = min(recordingDuration, region.upperBound)
            guard b - a > 0.01 else { continue }
            pieces.append(Piece(compactStart: at, sourceStart: a, length: b - a)); at += b - a + CompactedTimeline.joinSilence
        }
        self.pieces = pieces
    }

    private func piece(containing t: Double) -> (index: Int, inside: Bool) {
        for (i, p) in pieces.enumerated() {
            if t < p.compactStart { return (i, false) } // in the join before piece i
            if t <= p.compactStart + p.length { return (i, true) }
        }
        return (pieces.count - 1, false)
    }

    /// Source (recording-relative) range for a recognised cue, or nil when it lies entirely in a join.
    public func sourceRange(compactStart: Double, compactEnd: Double) -> ClosedRange<Double>? {
        guard !pieces.isEmpty else { return nil }
        let (si, sInside) = piece(containing: compactStart), (ei, eInside) = piece(containing: compactEnd)
        // Start in a join → the next piece's start; end in a join → the previous piece's end.
        let startPiece = sInside || compactStart < pieces[si].compactStart ? si : min(si + 1, pieces.count - 1)
        let endPiece = eInside ? ei : (compactEnd < pieces[ei].compactStart ? ei - 1 : ei)
        guard endPiece >= startPiece else { return nil } // entirely inside one join
        let sp = pieces[startPiece], ep = pieces[endPiece]
        var start = sp.sourceStart + max(0, min(sp.length, compactStart - sp.compactStart))
        var end = ep.sourceStart + max(0, min(ep.length, compactEnd - ep.compactStart))
        if startPiece != endPiece {
            // A cue joined across skipped audio: keep it on the side that holds most of it rather
            // than stretching it over the music or silence in between.
            let firstPart = sp.compactStart + sp.length - max(compactStart, sp.compactStart)
            let lastPart = min(compactEnd, ep.compactStart + ep.length) - ep.compactStart
            if firstPart >= lastPart { end = sp.sourceStart + sp.length } else { start = ep.sourceStart }
        }
        guard end > start + 0.01 else { return nil }
        return start...end
    }
}

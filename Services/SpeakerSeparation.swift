import Foundation

/// Native-channel energy candidates only. Independent microphones may identify a recording
/// channel; energy/correlation cannot prove speech or distinguish people from music. The editor
/// requires recording-specific microphone confirmation before attaching these candidates.
/// Mono, equal-energy overlap and insufficient separation remain unknown. No diarization model.
public struct SpeakerAssignment: Equatable, Sendable {
    /// "A", "B", … by channel order, or nil when this sentence is not clearly separated.
    public var speaker: String?
    /// Native zero-based channel, separate from display label and recognition order.
    public var channelIndex: Int? = nil
    /// Loudest minus second-loudest channel, in dB.
    public var marginDB: Double
}

public struct SpeakerSeparationResult: Equatable, Sendable {
    public enum Status: String, Sendable { case separated, uncertain, unavailable }
    public var status: Status
    public var message: String
    public var channels: Int
    /// Same order as the input sentences.
    public var assignments: [SpeakerAssignment]
}

/// Signal independence only. It cannot distinguish speech, music or human identity.
public struct ChannelLayout: Equatable, Sendable {
    public var channels: Int
    /// Channels carrying signal within 10 dB of the loudest, loudest first.
    public var activeChannels: [Int]
    /// Highest absolute correlation between any two active channels (1 = identical signal).
    public var maxCorrelation: Double
    /// Independent signal is necessary, not proof of one microphone/person per channel.
    public var isSeparated: Bool { channels <= 32 && activeChannels.count >= 2 && maxCorrelation < 0.5 }
    public var recognitionChannels: [SpeakerChannel] {
        activeChannels.enumerated().map { SpeakerChannel(index: $0.element, ordinal: $0.offset, label: SpeakerSeparation.label(for: $0.element)) }
    }
}

public struct SpeakerChannel: Equatable, Sendable {
    public let index: Int
    public let ordinal: Int
    public let label: String
}

public enum SpeakerSeparation {
    public static let maximumChannels = 32
    /// Spreadsheet-style labels A…Z, AA…AF; no fixed array indexed by a native channel.
    public static func label(for channel: Int) -> String {
        guard channel >= 0, channel < maximumChannels else { return "채널 범위 밖" }
        var n = channel + 1, value = ""
        while n > 0 { n -= 1; value = String(UnicodeScalar(65 + n % 26)!) + value; n /= 26 }
        return value
    }
    public static func channelLayout(url: URL, sourceStart: MediaTime, duration: MediaTime) async throws -> ChannelLayout {
        var energy: [Double] = [], cross: [[Double]] = []
        _ = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            let n = chunk.channels
            guard n <= maximumChannels else { throw AudioAnalysisError("화자 채널 분석은 최대 32채널까지 지원합니다.") }
            if energy.isEmpty { energy = [Double](repeating: 0, count: n); cross = [[Double]](repeating: [Double](repeating: 0, count: n), count: n) }
            guard energy.count == n else { throw AudioAnalysisError("화자 분석 중 채널 수가 변경되었습니다.") }
            for frame in 0..<(chunk.values.count / n) {
                if frame % 1024 == 0 { try Task.checkCancellation() }
                for a in 0..<n {
                    let x = Double(chunk.values[frame * n + a]); energy[a] += x * x
                    for b in (a + 1)..<max(a + 1, n) { cross[a][b] += x * Double(chunk.values[frame * n + b]) }
                }
            }
        }
        let loud = energy.max() ?? 0
        let active = energy.indices.filter { loud > 0 && energy[$0] >= loud * 0.1 }.sorted { energy[$0] == energy[$1] ? $0 < $1 : energy[$0] > energy[$1] }
        var worst = 0.0
        for (i, a) in active.enumerated() { for b in active.dropFirst(i + 1) {
            let (x, y) = (min(a, b), max(a, b))
            if energy[x] > 0 && energy[y] > 0 { worst = max(worst, abs(cross[x][y]) / (energy[x] * energy[y]).squareRoot()) }
        } }
        return ChannelLayout(channels: energy.count, activeChannels: active, maxCorrelation: worst)
    }

    /// A sentence counts as one channel's speaker only when that channel is at least this much louder.
    public static let minimumMarginDB = 6.0
    /// Share of sentences that must be clearly separated before any label is shown.
    public static let minimumSeparatedShare = 0.6
    public static let labels = ["A", "B", "C", "D", "E", "F", "G", "H"]

    /// `ranges` are source-time spans of the sentences (seconds). Reads the source once, read-only.
    public static func analyze(url: URL, sourceStart: MediaTime, duration: MediaTime, ranges: [ClosedRange<Double>]) async throws -> SpeakerSeparationResult {
        guard !ranges.isEmpty else { return SpeakerSeparationResult(status: .uncertain, message: "자막 문장이 없습니다.", channels: 0, assignments: []) }
        guard ranges.allSatisfy({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= sourceStart.seconds && $0.upperBound <= sourceStart.seconds + duration.seconds + 0.0001 && $0.upperBound > $0.lowerBound }) else { throw AudioAnalysisError("자막 분석 구간이 유효한 원본 범위를 벗어났습니다.") }
        let order = ranges.indices.sorted { ranges[$0].lowerBound < ranges[$1].lowerBound }
        var energy = [[Double]](repeating: [], count: ranges.count)
        var channels = 0
        var cursor = 0 // first range (in `order`) that may still receive samples
        _ = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            guard chunk.channels <= maximumChannels else { throw AudioAnalysisError("화자 채널 분석은 최대 32채널까지 지원합니다.") }
            if channels == 0 { channels = chunk.channels; energy = energy.map { _ in [Double](repeating: 0, count: chunk.channels) } }
            guard chunk.channels == channels else { throw AudioAnalysisError("화자 분석 중 채널 수가 변경되었습니다.") }
            let frames = chunk.values.count / channels
            for frame in 0..<frames {
                if frame % 1024 == 0 { try Task.checkCancellation() }
                let t = chunk.start + Double(frame) / chunk.sampleRate
                while cursor < order.count && ranges[order[cursor]].upperBound < t { cursor += 1 }
                var k = cursor
                while k < order.count && ranges[order[k]].lowerBound <= t {
                    if t <= ranges[order[k]].upperBound {
                        for c in 0..<channels { let v = Double(chunk.values[frame * channels + c]); energy[order[k]][c] += v * v }
                    }
                    k += 1
                }
            }
        }
        guard channels > 1 else {
            return SpeakerSeparationResult(status: .unavailable, message: "모노 음성이라 화자 구분을 할 수 없습니다. 화자별로 채널이 나뉜 녹음(예: 2채널 무선 마이크)에서 사용할 수 있습니다.", channels: channels, assignments: ranges.map { _ in SpeakerAssignment(speaker: nil, marginDB: 0) })
        }
        var assignments: [SpeakerAssignment] = []
        for e in energy {
            let sorted = e.indices.sorted { e[$0] > e[$1] }
            let loud = e[sorted[0]], second = e[sorted[1]]
            let margin = loud <= 0 ? 0 : (second <= 0 ? 120 : 10 * log10(loud / second))
            assignments.append(SpeakerAssignment(speaker: margin >= minimumMarginDB ? label(for: sorted[0]) : nil, channelIndex: margin >= minimumMarginDB ? sorted[0] : nil, marginDB: margin))
        }
        let separated = assignments.filter { $0.speaker != nil }
        let distinct = Set(separated.compactMap(\.speaker))
        let share = Double(separated.count) / Double(assignments.count)
        guard share >= minimumSeparatedShare, distinct.count >= 2 else {
            let reason = distinct.count < 2 && !separated.isEmpty ? "한 채널만 우세해 여러 화자인지 알 수 없습니다" : String(format: "채널 차이가 %.0fdB 이상인 문장이 %.0f%%뿐입니다", minimumMarginDB, share * 100)
            return SpeakerSeparationResult(status: .uncertain, message: "화자 구분 불확실 · \(reason). 추측으로 화자를 붙이지 않았습니다.", channels: channels,
                                           assignments: assignments.map { SpeakerAssignment(speaker: nil, marginDB: $0.marginDB) })
        }
        return SpeakerSeparationResult(status: .separated, message: "채널 분리 후보 \(distinct.count)개 · 문장 \(separated.count)/\(assignments.count)개 구분 · 나머지는 불확실로 표시",
                                       channels: channels, assignments: assignments)
    }
}

extension SpeakerSeparation {
    /// Tighten only the silent edges of a cue on its recognised native channel. This is signal
    /// presence, not speech/person detection: noise/music remain active and a wholly quiet cue is
    /// retained for review. Internal pauses and source timing are never redistributed by text length.
    public static func tightenedToChannelSignal(_ cues: [CaptionCue], url: URL, channel: Int, sourceStart: MediaTime, duration: MediaTime) async throws -> [CaptionCue] {
        guard !cues.isEmpty else { return cues }
        var intervals: [ClosedRange<Double>] = [], energy = 0.0, frames = 0, windowStart = 0.0, windowEnd = 0.0
        func flush() throws {
            defer { energy = 0; frames = 0 }
            guard frames > 0, energy / Double(frames) > 0.000001 else { return } // RMS > -60 dBFS
            if let last = intervals.last, windowStart <= last.upperBound + 0.001 { intervals[intervals.count-1] = last.lowerBound...windowEnd }
            else {
                guard intervals.count < RecognitionCacheSafety.maximumRegions else { throw AudioAnalysisError("채널 신호 구간이 너무 많아 자막 시간을 변경하지 않았습니다.") }
                intervals.append(windowStart...windowEnd)
            }
        }
        _ = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            guard (0..<chunk.channels).contains(channel) else { throw AudioAnalysisError("자막 시간 보정의 원본 채널이 없습니다.") }
            let limit = max(1, Int(chunk.sampleRate * 0.02))
            for i in 0..<(chunk.values.count/chunk.channels) {
                if i % 1024 == 0 { try Task.checkCancellation() }
                let t = chunk.start + Double(i)/chunk.sampleRate
                if frames == 0 { windowStart = t }
                let v = Double(chunk.values[i*chunk.channels+channel]); energy += v*v; frames += 1; windowEnd = t + 1/chunk.sampleRate
                if frames >= limit { try flush() }
            }
        }
        try flush(); try Task.checkCancellation()
        return try cues.map { cue in
            try Task.checkCancellation()
            let a = cue.start.seconds, b = a + cue.duration.seconds
            // Sorted disjoint intervals: O(log N) lookup per cue, not a full-hour scan per word.
            var low = 0, high = intervals.count
            while low < high { let mid = (low+high)/2; if intervals[mid].upperBound <= a { low = mid+1 } else { high = mid } }
            let firstIndex = low
            low = firstIndex; high = intervals.count
            while low < high { let mid = (low+high)/2; if intervals[mid].lowerBound < b { low = mid+1 } else { high = mid } }
            guard firstIndex < low else { return cue }
            let first = intervals[firstIndex], last = intervals[low-1]
            let start = max(a,first.lowerBound-0.15), end = min(b,last.upperBound+0.15)
            guard end-start >= 0.08, start > a+0.001 || end < b-0.001 else { return cue }
            var result = cue; result.start = MediaTime(seconds:start); result.duration = MediaTime(seconds:end-start); return result
        }
    }
}

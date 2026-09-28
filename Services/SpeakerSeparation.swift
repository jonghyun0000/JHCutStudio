import Foundation

/// Speaker labels from channel separation only — the same principle as whisper.cpp `--diarize`.
///
/// When each person has their own microphone on their own channel, the channel that is clearly
/// loudest during a sentence identifies the speaker. Without that physical separation (mono, or a
/// single device capturing everyone on both channels) there is no reliable signal, and this
/// returns “uncertain” instead of inventing speakers. No model is used or downloaded.
public struct SpeakerAssignment: Equatable, Sendable {
    /// "A", "B", … by channel order, or nil when this sentence is not clearly separated.
    public var speaker: String?
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

/// Whether a recording has one voice per channel. Used before recognising each channel separately.
public struct ChannelLayout: Equatable, Sendable {
    public var channels: Int
    /// Channels carrying signal within 10 dB of the loudest, loudest first.
    public var activeChannels: [Int]
    /// Highest absolute correlation between any two active channels (1 = identical signal).
    public var maxCorrelation: Double
    /// True when at least two active channels are largely independent, i.e. separate microphones.
    public var isSeparated: Bool { activeChannels.count >= 2 && maxCorrelation < 0.5 }
}

public enum SpeakerSeparation {
    public static func channelLayout(url: URL, sourceStart: MediaTime, duration: MediaTime) async throws -> ChannelLayout {
        var energy: [Double] = [], cross: [[Double]] = []
        _ = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            let n = chunk.channels
            if energy.isEmpty { energy = [Double](repeating: 0, count: n); cross = [[Double]](repeating: [Double](repeating: 0, count: n), count: n) }
            for frame in 0..<(chunk.values.count / n) {
                for a in 0..<n {
                    let x = Double(chunk.values[frame * n + a]); energy[a] += x * x
                    for b in (a + 1)..<max(a + 1, n) { cross[a][b] += x * Double(chunk.values[frame * n + b]) }
                }
            }
        }
        let loud = energy.max() ?? 0
        let active = energy.indices.filter { loud > 0 && energy[$0] >= loud * 0.1 }.sorted { energy[$0] > energy[$1] }
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
        let order = ranges.indices.sorted { ranges[$0].lowerBound < ranges[$1].lowerBound }
        var energy = [[Double]](repeating: [], count: ranges.count)
        var channels = 0
        var cursor = 0 // first range (in `order`) that may still receive samples
        _ = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            if channels == 0 { channels = chunk.channels; energy = energy.map { _ in [Double](repeating: 0, count: chunk.channels) } }
            guard chunk.channels == channels else { throw AudioAnalysisError("화자 분석 중 채널 수가 변경되었습니다.") }
            let frames = chunk.values.count / channels
            for frame in 0..<frames {
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
            assignments.append(SpeakerAssignment(speaker: margin >= minimumMarginDB ? labels[min(sorted[0], labels.count - 1)] : nil, marginDB: margin))
        }
        let separated = assignments.filter { $0.speaker != nil }
        let distinct = Set(separated.compactMap(\.speaker))
        let share = Double(separated.count) / Double(assignments.count)
        guard share >= minimumSeparatedShare, distinct.count >= 2 else {
            let reason = distinct.count < 2 && !separated.isEmpty ? "한 채널만 우세해 여러 화자인지 알 수 없습니다" : String(format: "채널 차이가 %.0fdB 이상인 문장이 %.0f%%뿐입니다", minimumMarginDB, share * 100)
            return SpeakerSeparationResult(status: .uncertain, message: "화자 구분 불확실 · \(reason). 추측으로 화자를 붙이지 않았습니다.", channels: channels,
                                           assignments: assignments.map { SpeakerAssignment(speaker: nil, marginDB: $0.marginDB) })
        }
        return SpeakerSeparationResult(status: .separated, message: "채널 분리로 화자 \(distinct.count)명 · 문장 \(separated.count)/\(assignments.count)개 구분 · 나머지는 불확실로 표시",
                                       channels: channels, assignments: assignments)
    }
}

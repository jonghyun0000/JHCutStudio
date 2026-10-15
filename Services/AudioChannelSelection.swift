import Foundation

/// One phase-safe native-channel plan shared by VAD, audition and every ASR window.
/// Auto keeps both independently audible stereo channels, including a quiet brief reply;
/// negatively correlated channels use one channel instead of cancelling in an average.
public struct AudioChannelSelection: Codable, Equatable, Sendable {
    public let primary: Int
    public let secondary: Int?
    public let channelCount: Int
    public var channels: [Int] { [primary] + (secondary.map { [$0] } ?? []) }
    public var isValid: Bool {
        (1...32).contains(channelCount) && primary >= 0 && primary < channelCount && (secondary == nil || (secondary! >= 0 && secondary! < channelCount && secondary != primary))
    }
    public func matches(requestedChannel: Int) -> Bool { isValid && (requestedChannel == -1 || (primary == requestedChannel && secondary == nil)) }
    enum CodingKeys: String, CodingKey { case primary, secondary, channelCount }
    init(primary: Int, secondary: Int?, channelCount: Int) { self.primary=primary; self.secondary=secondary; self.channelCount=channelCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        primary = try c.decode(Int.self,forKey:.primary); secondary = try c.decodeIfPresent(Int.self,forKey:.secondary); channelCount = try c.decode(Int.self,forKey:.channelCount)
        guard isValid else { throw ProjectError("인식 캐시의 오디오 채널이 올바르지 않습니다.") }
    }

    func mono(_ chunk: SourcePCM.Chunk) throws -> [Float] {
        guard isValid, chunk.channels == channelCount else {
            throw AudioAnalysisError("오디오 채널 선택과 원본 형식이 다릅니다.")
        }
        return (0..<(chunk.values.count / channelCount)).map { frame in
            let a = chunk.values[frame * channelCount + primary]
            return secondary.map { (a + chunk.values[frame * channelCount + $0]) * 0.5 } ?? a
        }
    }

    public static func resolve(url: URL, sourceStart: MediaTime, duration: MediaTime?, preferredChannel: Int = -1,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> AudioChannelSelection {
        guard (-1...31).contains(preferredChannel) else { throw AudioAnalysisError("인식 채널은 자동 또는 1~32번을 선택하세요.") }
        var energy: [Double] = [], cross: [[Double]] = [], frames = 0
        _ = try await SourcePCM.readStable(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            let n = chunk.channels
            guard n > 0, n <= 32 else { throw AudioAnalysisError("음성 분석은 최대 32채널 원본을 지원합니다.") }
            if energy.isEmpty { energy = [Double](repeating: 0, count: n); cross = [[Double]](repeating: [Double](repeating: 0, count: n), count: n) }
            guard energy.count == n else { throw AudioAnalysisError("음성 추출 중 채널 수가 변경되었습니다.") }
            frames += chunk.values.count / n
            for frame in 0..<(chunk.values.count / n) {
                for a in 0..<n {
                    let x = Double(chunk.values[frame * n + a]); energy[a] += x * x
                    for b in (a + 1)..<n { cross[a][b] += x * Double(chunk.values[frame * n + b]) }
                }
            }
            if let duration { progress?(AudioAnalysisProgress.fraction(elapsed: chunk.start - sourceStart.seconds + Double(chunk.values.count / n) / chunk.sampleRate, total: duration.seconds)) }
        }
        let ranked = energy.indices.sorted { energy[$0] == energy[$1] ? $0 < $1 : energy[$0] > energy[$1] }
        let selected = preferredChannel >= 0 ? preferredChannel : (ranked.first ?? 0)
        guard energy.indices.contains(selected) else { throw AudioAnalysisError("선택한 채널이 없습니다. 자동 선택 또는 실제 채널 번호를 선택하세요.") }
        var secondary: Int?
        if preferredChannel < 0, ranked.count > 1 {
            let a = ranked[0], b = ranked[1], ea = energy[a], eb = energy[b]
            let correlation = ea > 0 && eb > 0 ? cross[min(a, b)][max(a, b)] / (ea * eb).squareRoot() : 0
            if eb / Double(max(1, frames)) > 1e-12, correlation >= -0.5 { secondary = b }
        }
        return AudioChannelSelection(primary: selected, secondary: secondary, channelCount: energy.count)
    }
}

enum AudioAnalysisProgress {
    static func fraction(elapsed: Double, total: Double) -> Double {
        guard elapsed.isFinite, total.isFinite, total > 0 else { return 0 }
        return min(1, max(0, elapsed / total))
    }
}

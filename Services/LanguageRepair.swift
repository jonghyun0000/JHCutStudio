import Foundation

public struct LanguageRepairCost: Codable, Equatable, Sendable {
    public var probes = 0
    public var probeAudioSeconds = 0.0
    public var retries = 0
    public var retryAudioSeconds = 0.0
    public var wallSeconds = 0.0
    public init() {}
    public var isValid: Bool {
        (0...LanguageRepairPolicy.maximumProbes).contains(probes) && (0...LanguageRepairPolicy.maximumRetries).contains(retries) &&
        probeAudioSeconds.isFinite && (0...LanguageRepairPolicy.maximumProbeAudio+0.001).contains(probeAudioSeconds) &&
        retryAudioSeconds.isFinite && (0...LanguageRepairPolicy.maximumRetryAudio+0.001).contains(retryAudioSeconds) &&
        wallSeconds.isFinite && (0...604_800).contains(wallSeconds)
    }
}
public struct LanguageRepairAttempt: Codable, Equatable, Sendable {
    public var sourceStart: Double
    public var sourceEnd: Double
    public var language: String
    public var outcome: String
    public init(start:Double,end:Double,language:String,outcome:String) {sourceStart=start;sourceEnd=end;self.language=language;self.outcome=outcome}
    public var isValid: Bool {
        sourceStart.isFinite && sourceEnd.isFinite && sourceStart >= 0 && sourceEnd > sourceStart && CaptionLanguage(rawValue:language) != nil &&
        ["accepted","empty","boundaryHeld","languageHeld","coverageHeld","failed","budgetHeld"].contains(outcome)
    }
}
public enum LanguageRepairPolicy {
    public static let version = 2
    public static let minimumAudio = 6.0
    public static let stride = 8.0
    public static let probeLength = 10.0
    public static let minimumSpeech = 2.0
    public static let minimumProbability = 0.80
    public static let maximumProbes = 24
    public static let maximumProbeAudio = 240.0
    public static let maximumRetries = 8
    public static let maximumRetryAudio = 120.0
    public static let maximumRetryPiece = 20.0
    public static let maximumWall = 60.0
}

/// Shared by all windows of ONE request. Cached costs are charged before any new work.
final class LanguageRepairBudget: @unchecked Sendable {
    private(set) var used = LanguageRepairCost()
    var remainingWall: Double { max(0,LanguageRepairPolicy.maximumWall-used.wallSeconds) }
    func charge(_ cost: LanguageRepairCost) {
        guard cost.isValid else { used.wallSeconds = LanguageRepairPolicy.maximumWall; return }
        used.probes += cost.probes; used.probeAudioSeconds += cost.probeAudioSeconds
        used.retries += cost.retries; used.retryAudioSeconds += cost.retryAudioSeconds; used.wallSeconds += cost.wallSeconds
    }
    func reserveProbe(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= LanguageRepairPolicy.minimumAudio,
              used.probes < LanguageRepairPolicy.maximumProbes,
              used.probeAudioSeconds+seconds <= LanguageRepairPolicy.maximumProbeAudio+0.001, remainingWall > 0.05 else { return false }
        used.probes += 1; used.probeAudioSeconds += seconds; return true
    }
    func reserveRetry(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= LanguageRepairPolicy.minimumAudio, seconds <= LanguageRepairPolicy.maximumRetryPiece,
              used.retries < LanguageRepairPolicy.maximumRetries,
              used.retryAudioSeconds+seconds <= LanguageRepairPolicy.maximumRetryAudio+0.001, remainingWall > 0.05 else {return false}
        used.retries += 1; used.retryAudioSeconds += seconds; return true
    }
    func elapsed(_ seconds: Double) { if seconds.isFinite, seconds > 0 {used.wallSeconds += seconds} }
    func difference(from before: LanguageRepairCost) -> LanguageRepairCost {
        var result=LanguageRepairCost(); result.probes=used.probes-before.probes;result.probeAudioSeconds=used.probeAudioSeconds-before.probeAudioSeconds
        result.retries=used.retries-before.retries;result.retryAudioSeconds=used.retryAudioSeconds-before.retryAudioSeconds;result.wallSeconds=used.wallSeconds-before.wallSeconds
        return result
    }
}

public struct SourceLanguageDecision: Sendable {
    public var language: String
    public var confidence: Double?
    public var needsReview: Bool
    public var origin: SourceLanguageObservation.Method
    public var evidence: [SourceLanguageObservation]
}
public enum SourceLanguageAnalysis {
    /// Only the version-pinned runtime's explicit acoustic log line is accepted; JSON's window
    /// language without the posterior is not fabricated into an acoustic probability.
    public static func acousticResult(log: String) -> (language:String,probability:Double)? {
        let pattern = #"auto-detected language: ([a-z]{2,3}) \(p = ([0-9]+(?:\.[0-9]+)?)\)"#
        guard let regex=try? NSRegularExpression(pattern:pattern),let match=regex.matches(in:log,range:NSRange(log.startIndex...,in:log)).last,
              let a=Range(match.range(at:1),in:log),let b=Range(match.range(at:2),in:log),let p=Double(log[b]),p.isFinite,(0...1).contains(p) else {return nil}
        return (String(log[a]),p)
    }
    public static func decision(text:String,start:Double,end:Double,clipLanguage:String,requestedLanguage:String = "auto",observations:[SourceLanguageObservation]) -> SourceLanguageDecision {
        let fallback=CaptionLanguage(rawValue:clipLanguage) == nil ? "ko":clipLanguage
        var evidence=observations.filter {$0.isValid && $0.sourceStart < end && $0.sourceEnd > start && $0.method != .manual && $0.method != .text}.prefix(6).map {$0}
        let textual=SentenceLanguage.detect(text,clipLanguage:fallback)
        evidence.append(SourceLanguageObservation(start:start,end:end,language:textual.needsReview ? nil:textual.language,candidate:textual.language,confidence:textual.confidence,method:.text,state:textual.needsReview ? .uncertain:.supported,reason:textual.method))
        if CaptionLanguage(rawValue:requestedLanguage) != nil {
            evidence.append(SourceLanguageObservation(start:start,end:end,language:requestedLanguage,method:.manual,state:.specified,reason:"userForcedLanguage"))
            return SourceLanguageDecision(language:requestedLanguage,confidence:nil,needsReview:false,origin:.manual,evidence:evidence)
        }
        let audio=observations.filter {$0.isValid && $0.method == .audioProbe && $0.state == .supported && $0.language != nil && min(end,$0.sourceEnd)-max(start,$0.sourceStart) >= (end-start)*0.5}
        let languages=Set(audio.compactMap(\.language))
        if !textual.needsReview, languages.count == 1, languages.first == textual.language {
            return SourceLanguageDecision(language:textual.language,confidence:audio.compactMap(\.confidence).min(),needsReview:false,origin:.audioProbe,evidence:evidence)
        }
        // A short response stays unresolved even if surrounding audio's language is confident.
        let weakConflict = observations.contains {$0.isValid && $0.method == .audioProbe && $0.state == .uncertain && $0.candidateLanguage != nil && $0.candidateLanguage != textual.language && $0.sourceStart < end && $0.sourceEnd > start}
        let conflict = weakConflict || !languages.isEmpty && (languages.count > 1 || languages.first != textual.language)
        return SourceLanguageDecision(language:textual.language,confidence:textual.needsReview ? nil:textual.confidence,needsReview:textual.needsReview || conflict,origin:textual.needsReview ? .recognizerWindow:.text,evidence:evidence)
    }
}

enum LanguageRepair {
    /// Fixed request-wide shares keep early windows from consuming every acoustic probe.
    static func probeAllowance(window: Int, count: Int) -> Int {
        guard count > 0, window >= 0, window < count else { return 0 }
        let total = LanguageRepairPolicy.maximumProbes
        if count <= total { return total / count + (window < total % count ? 1 : 0) }
        let selected = Set((0..<total).map { Int((Double($0) * Double(count - 1) / Double(total - 1)).rounded()) })
        return selected.contains(window) ? 1 : 0
    }
    /// Retain some text-conflict priority while distributing the rest over the whole window.
    static func sampledRanges(_ ranges: [ClosedRange<Double>], priority: Set<Int>, limit: Int) -> [ClosedRange<Double>] {
        guard limit > 0, !ranges.isEmpty else { return [] }
        if ranges.count <= limit { return ranges }
        let priorityCount = min(priority.count, max(1, limit / 3))
        var indices = Set(priority.sorted().prefix(priorityCount))
        let uniformCount = limit - indices.count
        if uniformCount == 1 { indices.insert(ranges.count / 2) }
        else if uniformCount > 1 {
            for n in 0..<uniformCount { indices.insert(Int((Double(n) * Double(ranges.count - 1) / Double(uniformCount - 1)).rounded())) }
        }
        // Fill collisions from another uniform grid, without favoring the start of the audio.
        for n in 0..<limit where indices.count < limit {
            indices.insert(Int((Double(n) * Double(ranges.count - 1) / Double(max(1, limit - 1))).rounded()))
        }
        return indices.filter { ranges.indices.contains($0) }.sorted().prefix(limit).map { ranges[$0] }
    }
    /// Sample original contiguous audio, including gaps the first pass missed, never VAD joins.
    /// The caller prioritizes text conflicts; measured speech independently gates every probe.
    static func ranges(cues:[CaptionCue],start:Double,end:Double) -> [ClosedRange<Double>] {
        guard end-start >= LanguageRepairPolicy.minimumAudio else {return []}
        var ranges:[ClosedRange<Double>]=[]
        var cursor=start
        while cursor < end, ranges.count < 512 {
            let b=min(end,cursor+LanguageRepairPolicy.probeLength)
            if b-cursor >= LanguageRepairPolicy.minimumAudio {ranges.append(cursor...b)}
            cursor += LanguageRepairPolicy.stride
        }
        return ranges
    }
    /// Keep any old cue crossing the probe edge intact. A free gap or fully owned cue span
    /// can be retried; a too-small fragment is held instead of clipping its text.
    static func coreRange(cues:[CaptionCue],probe:ClosedRange<Double>) -> ClosedRange<Double>? {
        let blocked=cues.filter {$0.start.seconds < probe.upperBound && $0.start.seconds+$0.duration.seconds > probe.lowerBound &&
            ($0.start.seconds < probe.lowerBound-0.001 || $0.start.seconds+$0.duration.seconds > probe.upperBound+0.001)}
            .map {max(probe.lowerBound,$0.start.seconds)...min(probe.upperBound,$0.start.seconds+$0.duration.seconds)}.sorted {$0.lowerBound < $1.lowerBound}
        var cursor=probe.lowerBound,free:[ClosedRange<Double>]=[]
        for b in blocked {if b.lowerBound > cursor {free.append(cursor...b.lowerBound)};cursor=max(cursor,b.upperBound)}
        if cursor < probe.upperBound {free.append(cursor...probe.upperBound)}
        return free.filter {$0.upperBound-$0.lowerBound >= LanguageRepairPolicy.minimumAudio}.max {($0.upperBound-$0.lowerBound)<($1.upperBound-$1.lowerBound)}
    }
    static func observation(range:ClosedRange<Double>,result:(language:String,probability:Double)?,speechSeconds:Double,reason:String? = nil) -> SourceLanguageObservation {
        let supported = range.upperBound-range.lowerBound >= LanguageRepairPolicy.minimumAudio && speechSeconds >= LanguageRepairPolicy.minimumSpeech &&
            (result.map {CaptionLanguage(rawValue:$0.language) != nil && $0.probability >= LanguageRepairPolicy.minimumProbability} ?? false)
        return SourceLanguageObservation(start:range.lowerBound,end:range.upperBound,language:supported ? result?.language:nil,candidate:result?.language,confidence:result?.probability,method:.audioProbe,state:supported ? .supported:.uncertain,
                                         reason:reason ?? (speechSeconds < LanguageRepairPolicy.minimumSpeech ? "insufficientSpeechEvidence":supported ? "acousticPosterior":"weakOrUnsupportedLanguage"),measuredSpeechSeconds:speechSeconds)
    }
    /// The retry owns whole original cues. Audio context is separate and must never be inserted
    /// into neighbouring captions. Empty/partial/foreign-script results leave every old cue intact.
    static func merge(original:[CaptionCue],replacement:[CaptionCue],range:ClosedRange<Double>,language:String) -> (cues:[CaptionCue],outcome:String) {
        let owned=original.filter {$0.start.seconds < range.upperBound && $0.start.seconds+$0.duration.seconds > range.lowerBound}
        guard !replacement.isEmpty else {return (original,"empty")}
        guard range.lowerBound.isFinite,range.upperBound.isFinite,range.upperBound>range.lowerBound,CaptionLanguage(rawValue:language) != nil else {return (original,"boundaryHeld")}
        guard owned.allSatisfy({$0.start.seconds >= range.lowerBound-0.001 && $0.start.seconds+$0.duration.seconds <= range.upperBound+0.001}) else {return (original,"boundaryHeld")}
        let inside=replacement.filter {$0.start.seconds >= range.lowerBound-0.001 && $0.start.seconds+$0.duration.seconds <= range.upperBound+0.001 && !CoverageRepair.isMarker($0.text)}
        guard !inside.isEmpty else {return (original,"boundaryHeld")}
        guard inside.allSatisfy({let d=SentenceLanguage.detect($0.text,clipLanguage:language);return !d.needsReview && d.language == language}) else {return (original,"languageHeld")}
        guard owned.allSatisfy({old in inside.contains {min(old.start.seconds+old.duration.seconds,$0.start.seconds+$0.duration.seconds)-max(old.start.seconds,$0.start.seconds) >= min(0.5,old.duration.seconds*0.5)}}) else {return (original,"coverageHeld")}
        let ids=Set(owned.map(\.id));let combined=original.filter {!ids.contains($0.id)}+inside
        return (combined.enumerated().sorted {$0.element.start == $1.element.start ? $0.offset < $1.offset:$0.element.start < $1.element.start}.map(\.element),"accepted")
    }
}

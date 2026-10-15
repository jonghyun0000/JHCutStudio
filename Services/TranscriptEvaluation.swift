import Foundation
import NaturalLanguage
import Darwin

/// A human-made transcript to score captions against. `.srt` carries source times; `.txt` does not.
public struct TranscriptReference: Sendable, Equatable {
    public struct Unit: Sendable, Equatable {
        public var text: String
        /// Source-media times. nil for a plain-text transcript.
        public var start: Double?
        public var end: Double?
        public init(text: String, start: Double?, end: Double?) { self.text = text; self.start = start; self.end = end }
    }
    public var url: URL
    public var units: [Unit]
    public init(url: URL, units: [Unit]) { self.url = url; self.units = units }
    public var isTimed: Bool { units.allSatisfy { $0.start != nil && $0.end != nil } && !units.isEmpty }

    /// `<media>.srt` is preferred over `<media>.txt`. Only files beside the media are considered;
    /// nothing is written there.
    public static func locate(besideMedia media: URL) -> URL? {
        let base = media.deletingPathExtension()
        for ext in ["srt", "txt", "SRT", "TXT"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func load(_ url: URL) throws -> TranscriptReference {
        try Task.checkCancellation()
        let data = try RecognitionCacheSafety.read(url,maximum:20_000_000)
        try Task.checkCancellation()
        let text = try SubtitleTextDecoder.decode(data)
        if url.pathExtension.lowercased() == "srt" {
            var lines=0
            for (i,c) in text.unicodeScalars.enumerated() { if i & 4095 == 0 { try Task.checkCancellation() }; if c == "\n" { lines+=1 }; guard lines <= 100_000 else { throw ProjectError("대본의 줄 수가 허용 한도를 넘습니다.") } }
            let cues = try SRTCodec.parse(text)
            try Task.checkCancellation()
            guard cues.count <= 20_000 else { throw ProjectError("대본은 20,000개 문장 이내로 나눠 평가하세요.") }
            let units = try cues.map { Unit(text: $0.text, start: $0.start.seconds, end: try $0.start.adding($0.duration).seconds) }
            guard !units.isEmpty else { throw ProjectError("대본 SRT에 자막이 없습니다.") }
            return TranscriptReference(url: url, units: units)
        }
        let sentences = try TranscriptEvaluation.checkedSentences(text)
        guard !sentences.isEmpty else { throw ProjectError("대본 텍스트가 비어 있습니다.") }
        return TranscriptReference(url: url, units: sentences.map { Unit(text: $0, start: nil, end: nil) })
    }
}

/// One recognised caption, in SOURCE media time (the same clock as an `.srt` transcript of the file).
public struct EvaluatedCaption: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct EditCounts: Codable, Sendable, Equatable {
    public var substitutions = 0, deletions = 0, insertions = 0, referenceLength = 0
    public var errorRate: Double? { referenceLength > 0 ? Double(substitutions + deletions + insertions) / Double(referenceLength) : nil }
}

public struct TimingError: Codable, Sendable, Equatable {
    public var matchedPairs: Int
    public var meanAbsoluteStart: Double
    public var medianAbsoluteStart: Double
    public var maxAbsoluteStart: Double
    public var meanAbsoluteEnd: Double
    public var medianAbsoluteEnd: Double
    public var maxAbsoluteEnd: Double
    /// Share of matched pairs whose start is within 0.5 s of the transcript.
    public var startWithinHalfSecond: Double
    public var p95AbsoluteStart: Double? = nil
    public var p95AbsoluteEnd: Double? = nil
}

public struct SentenceIssue: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double?
    public var similarity: Double?
}

/// Result of scoring captions against a transcript. Every number is nil when `status` is
/// `unscored`; the UI and reports must then say “평가 불가” instead of showing a value.
public struct TranscriptEvaluationReport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case scored, unscored }
    public var status: Status
    public var reason: String?
    public var language: String
    public var referencePath: String?
    public var referenceTimed: Bool
    public var sourceRange: [Double]
    public var normalization: String
    public var cer: Double?
    public var wer: Double?
    public var characters: EditCounts?
    public var words: EditCounts?
    public var wordUnit: String?
    public var referenceSentences: Int
    public var captionSentences: Int
    public var matchedSentences: Int
    public var missing: [SentenceIssue]
    public var extra: [SentenceIssue]
    public var mismatched: [SentenceIssue]
    public var timing: TimingError?
    public var createdAt: Date
    public var algorithm: String? = nil
    public var alignmentMethod: String? = nil
    public var alignmentApproximate: Bool? = nil
    /// Present only for bounded human-reference JSON evaluation, never ordinary SRT/TXT comparison.
    public var humanReference: HumanReferenceAssessment? = nil

    public static func unscored(_ reason: String, language: String, captions: Int, range: ClosedRange<Double>, reference: URL? = nil) -> TranscriptEvaluationReport {
        TranscriptEvaluationReport(status: .unscored, reason: reason, language: language, referencePath: reference?.path, referenceTimed: false,
                                   sourceRange: [range.lowerBound.isFinite ? range.lowerBound : 0, range.upperBound.isFinite ? range.upperBound : 0], normalization: TranscriptEvaluation.normalizationDescription(language),
                                   cer: nil, wer: nil, characters: nil, words: nil, wordUnit: nil, referenceSentences: 0, captionSentences: captions,
                                   matchedSentences: 0, missing: [], extra: [], mismatched: [], timing: nil, createdAt: Date())
    }
}

public enum TranscriptEvaluation {
    /// Sentence-level similarity at or above this counts as the same sentence.
    public static let matchThreshold = 0.5
    /// An untimed transcript only describes the whole file, so a clip using less than this share
    /// of it cannot be scored without inflating “missing”.
    public static let untimedMinimumCoverage = 0.98

    // MARK: Normalisation

    public static func normalizationDescription(_ language: String) -> String {
        switch language {
        case "ko": return "NFKC·소문자·문장부호/기호 제거. CER은 공백 제외 글자, WER은 띄어쓰기(어절) 단위"
        case "ja": return "NFKC·소문자·문장부호/기호 제거. CER은 공백 제외 글자, WER은 NLTokenizer 단어 분할 단위(분할기 의존)"
        case "en": return "NFKC·소문자·문장부호/기호 제거(어포스트로피 포함). CER은 공백 제외 글자, WER은 공백 단어 단위"
        default: return "NFKC·소문자·문장부호/기호 제거. CER은 공백 제외 글자, WER은 NLTokenizer 단어 단위"
        }
    }

    /// Keeps letters, digits and marks (Hangul/kana combining forms), maps everything else to a space.
    public static func normalized(_ text: String, language: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                result.append(scalar)
            } else { result.append(" ") }
        }
        return String(result).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func characters(_ text: String, language: String) -> [Character] {
        Array(normalized(text, language: language).filter { !$0.isWhitespace })
    }

    public static func words(_ text: String, language: String) -> [String] {
        let value = normalized(text, language: language)
        switch language {
        case "ko", "en": return value.split(separator: " ").map(String.init)
        default:
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = value
            if language == "ja" { tokenizer.setLanguage(.japanese) }
            var tokens: [String] = []
            tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
                let token = value[range].trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { tokens.append(token) }
                return true
            }
            return tokens
        }
    }

    public static func wordUnitDescription(_ language: String) -> String {
        switch language { case "ko": return "어절"; case "en": return "단어"; case "ja": return "형태 단위(NLTokenizer)"; default: return "단어(NLTokenizer)" }
    }

    /// Plain-text transcripts: one unit per sentence-final mark or line break.
    public static func sentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        func flush() { let v = current.trimmingCharacters(in: .whitespacesAndNewlines); if !v.isEmpty { result.append(v) }; current = "" }
        for character in text {
            if character.isNewline { flush(); continue }
            current.append(character)
            if ".!?。！？".contains(character) { flush() }
        }
        flush()
        return result
    }

    static func checkedSentences(_ text: String) throws -> [String] {
        var result:[String]=[], current=""
        func flush() throws { let v=current.trimmingCharacters(in:.whitespacesAndNewlines); if !v.isEmpty { result.append(v) }; current=""; guard result.count <= 20_000 else { throw ProjectError("대본은 20,000개 문장 이내로 나눠 평가하세요.") } }
        for (i,c) in text.enumerated() { if i & 1023 == 0 { try Task.checkCancellation() }; if c.isNewline { try flush();continue }; current.append(c); if ".!?。！？".contains(c) { try flush() } }
        try flush(); return result
    }

    static func checkedNormalized(_ text:String,language:String) throws -> String {
        try Task.checkCancellation()
        let folded=text.precomposedStringWithCompatibilityMapping.lowercased()
        try Task.checkCancellation()
        var result=String.UnicodeScalarView()
        for (i,scalar) in folded.unicodeScalars.enumerated() {
            if i & 2047 == 0 { try Task.checkCancellation() }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) { result.append(scalar) } else { result.append(" ") }
        }
        try Task.checkCancellation()
        return String(result).split(whereSeparator: \.isWhitespace).joined(separator:" ")
    }
    static func checkedCharacters(_ text:String,language:String) throws -> [Character] {
        let value=try checkedNormalized(text,language:language)
        var result=""
        for (i,c) in value.enumerated() { if i & 2047 == 0 { try Task.checkCancellation() };if !c.isWhitespace { result.append(c) } }
        return Array(result)
    }
    static func checkedWords(_ text:String,language:String) throws -> [String] {
        let value=try checkedNormalized(text,language:language)
        if language == "ko" || language == "en" { return value.split(separator:" ").map(String.init) }
        let tokenizer=NLTokenizer(unit:.word);tokenizer.string=value;tokenizer.setLanguage(.japanese)
        var result:[String]=[]
        tokenizer.enumerateTokens(in:value.startIndex..<value.endIndex) { range,_ in
            if Task.isCancelled { return false };let word=value[range].trimmingCharacters(in:.whitespaces);if !word.isEmpty { result.append(word) };return true
        }
        try Task.checkCancellation();return result
    }

    // MARK: Exact edit distance and bounded sentence alignment
    enum Step: Equatable { case match(Int, Int, Int, Int), missing(Int), extra(Int) }
    public static func editCounts<T: Equatable>(reference: [T], hypothesis: [T], limits: EvaluationLimits = .init()) throws -> EditCounts {
        try countedDistance(reference:reference,hypothesis:hypothesis,work:EvaluationWork(limits))
    }
    static func similarity(_ a: String, _ b: String, language: String, work: EvaluationWork) throws -> Double {
        let x=try checkedCharacters(a,language:language),y=try checkedCharacters(b,language:language)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        let counts=try countedDistance(reference:x,hypothesis:y,work:work)
        return max(0,1-Double(counts.substitutions+counts.deletions+counts.insertions)/Double(max(x.count,y.count)))
    }

    // MARK: Scoring

    /// Scores captions (source-time) against a transcript. `sourceRange` is the part of the media
    /// the clip actually uses; timed transcript units outside it are ignored, and an untimed
    /// transcript is refused for a partial clip rather than producing an inflated “missing” count.
    public static func evaluate(captions: [EvaluatedCaption], reference: TranscriptReference?, language: String,
                                sourceRange: ClosedRange<Double>, mediaDuration: Double, limits: EvaluationLimits = .init(),
                                progress: (@Sendable (EvaluationProgress) -> Void)? = nil) throws -> TranscriptEvaluationReport {
        try Task.checkCancellation()
        do {
        let work=try EvaluationWork(limits,progress:progress)
        try work.report(0,"평가 준비 중",force:true)
        guard ["ko","en","ja"].contains(language),sourceRange.lowerBound.isFinite,sourceRange.upperBound.isFinite,sourceRange.lowerBound >= 0,sourceRange.upperBound > sourceRange.lowerBound,
              mediaDuration.isFinite,mediaDuration > 0,sourceRange.upperBound <= mediaDuration+0.001 else {
            return .unscored("원본 언어·시간 범위를 확인하세요.",language:language,captions:captions.count,range:sourceRange,reference:reference?.url)
        }
        guard let reference else {
            return .unscored("대본 없음 · 영상과 같은 이름의 .srt 또는 .txt가 없어 정확도를 계산하지 않았습니다.", language: language, captions: captions.count, range: sourceRange)
        }
        guard reference.units.count <= limits.maximumUnits,captions.count <= limits.maximumUnits else { throw EvaluationWorkLimit(detail:"문장 수") }
        var bytes=0
        for text in reference.units.map(\.text) + captions.map(\.text) {
            try Task.checkCancellation(); let amount=text.utf8.count
            guard amount <= 65_536,amount <= limits.maximumTextBytes-bytes else { throw EvaluationWorkLimit(detail:"대본 크기") };bytes+=amount
        }
        let anyTimed=reference.units.contains { $0.start != nil || $0.end != nil }
        if anyTimed && !reference.isTimed { return .unscored("대본의 시간 정보가 일부만 있습니다.",language:language,captions:captions.count,range:sourceRange,reference:reference.url) }
        guard reference.units.allSatisfy({ u in u.start == nil || (u.start!.isFinite && u.end!.isFinite && u.start! >= 0 && u.end! > u.start! && u.end! <= mediaDuration+0.001) }),
              captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= sourceRange.lowerBound-0.001 && $0.end > $0.start && $0.end <= sourceRange.upperBound+0.001 }) else {
            return .unscored("대본·자막의 시간이 유효하지 않습니다.",language:language,captions:captions.count,range:sourceRange,reference:reference.url)
        }
        let sortedReference=reference.units.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        let coverage = mediaDuration > 0 ? (sourceRange.upperBound - sourceRange.lowerBound) / mediaDuration : 0
        if !reference.isTimed && coverage < untimedMinimumCoverage {
            return .unscored(String(format: "시간 정보가 없는 .txt 대본은 영상 전체 기준입니다. 클립이 원본의 %.0f%%만 사용해 누락이 과대 계산되므로 평가하지 않았습니다. 시간이 있는 .srt 대본을 사용하세요.", coverage * 100),
                             language: language, captions: captions.count, range: sourceRange, reference: reference.url)
        }
        let units = reference.isTimed
            ? sortedReference.filter { unit in
                guard let s = unit.start, let e = unit.end else { return false }
                // A transcript line counts when most of it lies inside the clip's source range.
                let overlap = min(e, sourceRange.upperBound) - max(s, sourceRange.lowerBound)
                return overlap > 0.5 * max(0.001, e - s)
            }
            : reference.units
        var usable:[TranscriptReference.Unit]=[]
        for unit in units { try Task.checkCancellation(); if try !checkedCharacters(unit.text,language:language).isEmpty { usable.append(unit) } }
        guard !usable.isEmpty else {
            return .unscored("클립 구간에 해당하는 대본 문장이 없습니다.", language: language, captions: captions.count, range: sourceRange, reference: reference.url)
        }
        var hyps:[EvaluatedCaption]=[]
        for caption in captions.sorted(by:{ $0.start < $1.start }) { try Task.checkCancellation(); if try !checkedCharacters(caption.text,language:language).isEmpty { hyps.append(caption) } }
        try work.report(0.05,"글자 비교 중",force:true)
        let refText = usable.map(\.text).joined(separator: " "), hypText = hyps.map(\.text).joined(separator: " ")
        let rc=try checkedCharacters(refText,language:language),hc=try checkedCharacters(hypText,language:language)
        guard rc.count <= limits.maximumCharacters,hc.count <= limits.maximumCharacters else { throw EvaluationWorkLimit(detail:"정규화 글자 수") }
        let chars = try countedDistance(reference:rc,hypothesis:hc,work:work) { try work.report(0.05+0.50*$0,"글자 비교 중") }
        try work.report(0.55,"단어 비교 중",force:true)
        let rw=try checkedWords(refText,language:language),hw=try checkedWords(hypText,language:language)
        guard rw.count <= limits.maximumWords,hw.count <= limits.maximumWords else { throw EvaluationWorkLimit(detail:"단어 수") }
        let wordCounts = try countedDistance(reference:rw,hypothesis:hw,work:work) { try work.report(0.55+0.15*$0,"단어 비교 중") }
        try work.report(0.70,"문장과 시간 비교 중",force:true)
        let alignment=try aligned(reference:usable.map(\.text),hypothesis:hyps.map(\.text),language:language,work:work)
        var missing: [SentenceIssue] = [], extra: [SentenceIssue] = [], mismatched: [SentenceIssue] = []
        var matched = 0
        var startErrors: [Double] = [], endErrors: [Double] = []
        for step in alignment.steps {
            try Task.checkCancellation()
            switch step {
            case .missing(let i): missing.append(SentenceIssue(text: usable[i].text, start: usable[i].start, similarity: nil))
            case .extra(let j): extra.append(SentenceIssue(text: hyps[j].text, start: hyps[j].start, similarity: nil))
            case .match(let i, let a, let j, let b):
                let refs = usable[i..<(i + a)], caps = hyps[j..<(j + b)]
                let sim = try similarity(refs.map(\.text).joined(separator: " "), caps.map(\.text).joined(separator: " "), language: language, work:work)
                if sim >= matchThreshold {
                    matched += a
                    if reference.isTimed, let rs = refs.first?.start, let re = refs.last?.end, let cs = caps.first?.start, let ce = caps.last?.end {
                        startErrors.append(cs - rs); endErrors.append(ce - re)
                    }
                } else {
                    mismatched.append(SentenceIssue(text: refs.map(\.text).joined(separator: " ") + " ⇄ " + caps.map(\.text).joined(separator: " "), start: refs.first?.start, similarity: sim))
                }
            }
        }
        var timing: TimingError? = nil
        if !startErrors.isEmpty {
            func stats(_ values: [Double]) -> (Double, Double, Double) {
                let a = values.map(abs).sorted()
                let median = a.count % 2 == 1 ? a[a.count / 2] : (a[a.count / 2 - 1] + a[a.count / 2]) / 2
                return (a.reduce(0, +) / Double(a.count), median, a.last ?? 0)
            }
            let s = stats(startErrors), e = stats(endErrors)
            timing = TimingError(matchedPairs: startErrors.count, meanAbsoluteStart: s.0, medianAbsoluteStart: s.1, maxAbsoluteStart: s.2,
                                 meanAbsoluteEnd: e.0, medianAbsoluteEnd: e.1, maxAbsoluteEnd: e.2,
                                 startWithinHalfSecond: Double(startErrors.filter { abs($0) <= 0.5 }.count) / Double(startErrors.count))
            // Nearest-rank p95; p50 retains the previous even-sample median convention.
            timing?.p95AbsoluteStart=startErrors.map(abs).sorted()[max(0,Int(ceil(0.95*Double(startErrors.count)))-1)]
            timing?.p95AbsoluteEnd=endErrors.map(abs).sorted()[max(0,Int(ceil(0.95*Double(endErrors.count)))-1)]
        }
        try work.report(0.98,"비교 완료",force:true)
        var report=TranscriptEvaluationReport(status: .scored, reason: reference.isTimed ? nil : "시간 없는 대본 · 시간 오차는 계산하지 않음", language: language,
                                          referencePath: reference.url.path, referenceTimed: reference.isTimed, sourceRange: [sourceRange.lowerBound, sourceRange.upperBound],
                                          normalization: normalizationDescription(language), cer: chars.errorRate, wer: wordCounts.errorRate,
                                          characters: chars, words: wordCounts, wordUnit: wordUnitDescription(language),
                                          referenceSentences: usable.count, captionSentences: hyps.count, matchedSentences: matched,
                                          missing: missing, extra: extra, mismatched: mismatched, timing: timing, createdAt: Date())
        report.algorithm="exact-adaptive-band-v1"; report.alignmentMethod=alignment.method;report.alignmentApproximate=alignment.approximate
        return report
        } catch let error as EvaluationWorkLimit {
            try Task.checkCancellation()
            return .unscored(error.localizedDescription,language:language,captions:captions.count,range:sourceRange,reference:reference?.url)
        }
    }

    // MARK: Reports

    /// Writes `<name>.json` and a human-readable `<name>.md`. Never called with a folder beside an
    /// original: the editor passes its own reports directory.
    public static func write(_ report: TranscriptEvaluationReport, title: String, to folder: URL, name: String) throws -> EvaluationReportFiles {
        try write(report,title:title,to:folder,name:name,beforeCommit:nil)
    }
    static func write(_ report: TranscriptEvaluationReport, title: String, to folder: URL, name: String, beforeCommit: (() throws -> Void)?) throws -> EvaluationReportFiles {
        try Task.checkCancellation()
        guard folder.isFileURL,!name.isEmpty,name.utf8.count <= 128,!name.contains("/"),!name.contains("\0"),name != ".",name != "..",title.utf8.count <= 4096 else { throw ProjectError("평가 보고서 경로·이름이 올바르지 않습니다.") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        guard RecognitionCacheSafety.directoryIsSafe(folder) else { throw ProjectError("평가 보고서 폴더의 링크는 사용할 수 없습니다.") }
        let id=UUID().uuidString,temp=folder.appendingPathComponent(".pending-evaluation-"+id,isDirectory:true),finished=folder.appendingPathComponent(name+"-"+id+".report",isDirectory:true)
        var ownsTemporary=false,ownsFinished=false,success=false
        defer {
            if ownsTemporary { try? FileManager.default.removeItem(at:temp) }
            if ownsFinished && !success { try? FileManager.default.removeItem(at:finished) }
        }
        // Exclusive creation and ownership flags protect another completed bundle on collision.
        guard mkdir(temp.path,0o700) == 0 else { throw ProjectError("새 평가 보고서 임시 폴더를 만들 수 없습니다.") }
        ownsTemporary=true
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        try Task.checkCancellation();try encoder.encode(report).write(to:temp.appendingPathComponent(name+".json"),options:.atomic)
        try Task.checkCancellation();try markdown(report,title:title).write(to:temp.appendingPathComponent(name+".md"),atomically:true,encoding:.utf8)
        try beforeCommit?();try Task.checkCancellation()
        try FileManager.default.moveItem(at:temp,to:finished)
        ownsFinished=true;ownsTemporary=false
        try Task.checkCancellation();success=true
        return EvaluationReportFiles(json:finished.appendingPathComponent(name+".json"),text:finished.appendingPathComponent(name+".md"),directory:finished)
    }

    public static func markdown(_ r: TranscriptEvaluationReport, title: String) -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "평가 불가" }
        func sec(_ v: Double) -> String { String(format: "%.2f초", v) }
        var lines = ["# 자막 정확도 평가 — \(title)", ""]
        let humanState=r.humanReference?.state
        let stateLabel=humanState == "pending" ? "사람 검수 대기" : humanState == "nonspeech_control" ? "비발화 대조군" : r.status == .scored ? "평가함" : humanState == nil ? "평가 불가" : "평가 보류"
        lines.append("- 상태: \(stateLabel)" + (r.reason.map { " · \($0)" } ?? ""))
        lines.append("- 언어: \(CaptionLanguage(rawValue: r.language)?.label ?? r.language)")
        lines.append("- 대본: \(r.referencePath ?? "없음")\(r.referenceTimed ? " (시간 포함)" : "")")
        lines.append(String(format: "- 원본 구간: %.2f~%.2f초", r.sourceRange.first ?? 0, r.sourceRange.last ?? 0))
        lines.append("- 정규화: \(r.normalization)")
        if let human = r.humanReference {
            lines.append("- 평가 방식: 사람 검수 JSON")
            lines.append("- 검수 상태: \(human.state) · \(human.metrics.reason ?? r.reason ?? "")")
            lines.append("- 정답 revision: \(human.metrics.referenceRevision?.uuidString ?? "없음") · SHA-256: \(human.referenceSHA256)")
            lines.append("- 원본 SHA-256: \(human.sourceSHA256)")
            lines.append("- 검수자 선언: \(human.reviewer ?? "미검수") · 소프트웨어가 실제 청취를 인증하지 않음")
            lines.append("- 시간 검수: \(human.timingReason)")
            if let count = human.metrics.falsePositiveCaptions { lines.append("- 검수된 비발화 구간의 과잉 자막: \(count)개") }
        } else { lines.append("- 평가 방식: 일반 대본 비교 · 사람 검수 provenance 미검증") }
        guard r.status == .scored else { lines.append(""); lines.append("대본이 없거나 비교 조건이 맞지 않아 CER/WER을 계산하지 않았습니다."); return lines.joined(separator: "\n") + "\n" }
        lines.append("")
        lines.append("| 지표 | 값 | 치환 | 삭제 | 삽입 | 기준 길이 |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        if let c = r.characters { lines.append("| CER | \(pct(r.cer)) | \(c.substitutions) | \(c.deletions) | \(c.insertions) | \(c.referenceLength)자 |") }
        if let w = r.words { lines.append("| WER (\(r.wordUnit ?? "")) | \(pct(r.wer)) | \(w.substitutions) | \(w.deletions) | \(w.insertions) | \(w.referenceLength) |") }
        lines.append("")
        if r.alignmentApproximate == true { lines.append("- 문장 대응: 제한된 탐색으로 계산했습니다. 누락 문장과 시간 오차는 원문과 함께 확인하세요.") }
        lines.append("- 문장: 대본 \(r.referenceSentences)개 · 자막 \(r.captionSentences)개 · 일치 \(r.matchedSentences)개 · 누락 \(r.missing.count)개 · 과잉 \(r.extra.count)개 · 불일치 \(r.mismatched.count)개")
        if let t = r.timing {
            lines.append("- 시작 시각 오차(\(t.matchedPairs)쌍): 평균 \(sec(t.meanAbsoluteStart)) · 중앙값 \(sec(t.medianAbsoluteStart)) · 최대 \(sec(t.maxAbsoluteStart)) · 0.5초 이내 \(pct(t.startWithinHalfSecond))")
            lines.append("- 끝 시각 오차: 평균 \(sec(t.meanAbsoluteEnd)) · 중앙값 \(sec(t.medianAbsoluteEnd)) · 최대 \(sec(t.maxAbsoluteEnd))")
            if let start=t.p95AbsoluteStart,let end=t.p95AbsoluteEnd {lines.append("- 시간 오차 p95(최근접 순위): 시작 \(sec(start)) · 끝 \(sec(end))")}
        } else { lines.append("- 시간 오차: 계산하지 않음(\(r.humanReference?.timingReason ?? "대본에 시간 없음"))") }
        func list(_ title: String, _ items: [SentenceIssue]) {
            guard !items.isEmpty else { return }
            lines.append(""); lines.append("## \(title)")
            for item in items.prefix(50) { lines.append("- " + (item.start.map { String(format: "[%.2f초] ", $0) } ?? "") + item.text) }
            if items.count > 50 { lines.append("- … 외 \(items.count - 50)개") }
        }
        list("누락 문장 (대본에만 있음)", r.missing); list("과잉 문장 (자막에만 있음)", r.extra); list("불일치 문장", r.mismatched)
        lines.append(""); lines.append("CER/WER은 이 대본과 이 정규화 규칙 기준이며, 다른 조건의 수치와 직접 비교할 수 없습니다.")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Only the report writer creates this handle; cancel may discard its own newly committed bundle.
public struct EvaluationReportFiles: Sendable {
    public let json: URL
    public let text: URL
    let directory: URL
    public func discard() { try? FileManager.default.removeItem(at:directory) }
}

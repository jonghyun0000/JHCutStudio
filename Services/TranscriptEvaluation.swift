import Foundation
import NaturalLanguage

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
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw ProjectError("대본 파일은 20MB 이하여야 합니다.") }
        let text = try SubtitleTextDecoder.decode(data)
        if url.pathExtension.lowercased() == "srt" {
            let cues = try SRTCodec.parse(text)
            let units = cues.map { Unit(text: $0.text, start: $0.start.seconds, end: ($0.start + $0.duration).seconds) }
            guard !units.isEmpty else { throw ProjectError("대본 SRT에 자막이 없습니다.") }
            return TranscriptReference(url: url, units: units)
        }
        let sentences = TranscriptEvaluation.sentences(text)
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

    public static func unscored(_ reason: String, language: String, captions: Int, range: ClosedRange<Double>, reference: URL? = nil) -> TranscriptEvaluationReport {
        TranscriptEvaluationReport(status: .unscored, reason: reason, language: language, referencePath: reference?.path, referenceTimed: false,
                                   sourceRange: [range.lowerBound, range.upperBound], normalization: TranscriptEvaluation.normalizationDescription(language),
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

    // MARK: Edit distance

    /// Levenshtein with S/D/I counts, O(min) memory. Ties prefer substitution, then deletion, so
    /// counts are deterministic for the same input.
    private struct EditCell { var cost: Int; var s: Int; var d: Int; var i: Int }
    public static func editCounts<T: Equatable>(reference: [T], hypothesis: [T]) -> EditCounts {
        typealias Cell = EditCell
        let m = hypothesis.count
        var previous = (0...m).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        var current = previous
        for (row, ref) in reference.enumerated() {
            current[0] = Cell(cost: row + 1, s: 0, d: row + 1, i: 0)
            for column in 1...max(1, m) where m > 0 {
                if hypothesis[column - 1] == ref { current[column] = previous[column - 1]; continue }
                let sub = previous[column - 1], del = previous[column], ins = current[column - 1]
                let best = min(sub.cost, del.cost, ins.cost)
                if sub.cost == best { current[column] = Cell(cost: best + 1, s: sub.s + 1, d: sub.d, i: sub.i) }
                else if del.cost == best { current[column] = Cell(cost: best + 1, s: del.s, d: del.d + 1, i: del.i) }
                else { current[column] = Cell(cost: best + 1, s: ins.s, d: ins.d, i: ins.i + 1) }
            }
            swap(&previous, &current)
        }
        let final = previous[m]
        return EditCounts(substitutions: final.s, deletions: final.d, insertions: final.i, referenceLength: reference.count)
    }

    static func similarity(_ a: String, _ b: String, language: String) -> Double {
        let x = characters(a, language: language), y = characters(b, language: language)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        let counts = editCounts(reference: x, hypothesis: y)
        return max(0, 1 - Double(counts.substitutions + counts.deletions + counts.insertions) / Double(max(x.count, y.count)))
    }

    // MARK: Sentence alignment

    enum Step { case match(Int, Int, Int, Int), missing(Int), extra(Int) }

    /// Monotonic alignment allowing 1:1, 1:2, 2:1, 1:3 and 3:1 groupings, so one transcript sentence split
    /// across two captions (or the reverse) is not reported as a missing plus an extra sentence.
    static func align(reference: [String], hypothesis: [String], language: String) -> [Step] {
        let n = reference.count, m = hypothesis.count
        // Long transcripts: stay within a band around the diagonal (sentence pairs are compared
        // with an O(len²) edit distance). Widen to the full table if the band cannot reach the end.
        let band = max(30, max(n, m) / 8)
        if n > 60 || m > 60, let banded = align(reference: reference, hypothesis: hypothesis, language: language, band: band) { return banded }
        return align(reference: reference, hypothesis: hypothesis, language: language, band: nil) ?? []
    }
    private static func align(reference: [String], hypothesis: [String], language: String, band: Int?) -> [Step]? {
        let n = reference.count, m = hypothesis.count
        // A pairing earns (similarity − threshold): below the threshold it costs more than
        // leaving both sides unpaired, so poor pairs are reported as missing + extra.
        let gap = 0.0
        var score = [[Double]](repeating: [Double](repeating: -.infinity, count: m + 1), count: n + 1)
        var back = [[Step?]](repeating: [Step?](repeating: nil, count: m + 1), count: n + 1)
        score[0][0] = 0
        let ratio = n > 0 ? Double(m) / Double(n) : 1
        func joined(_ list: [String], _ from: Int, _ count: Int) -> String { list[from..<(from + count)].joined(separator: " ") }
        for i in 0...n {
            for j in 0...m where score[i][j] > -.infinity {
                if let band, abs(Double(j) - Double(i) * ratio) > Double(band) { continue }
                let base = score[i][j]
                func relax(_ ni: Int, _ nj: Int, _ value: Double, _ step: Step) {
                    guard ni <= n, nj <= m, value > score[ni][nj] else { return }
                    score[ni][nj] = value; back[ni][nj] = step
                }
                if i < n { relax(i + 1, j, base - gap, .missing(i)) }
                if j < m { relax(i, j + 1, base - gap, .extra(j)) }
                for (a, b) in [(1, 1), (1, 2), (2, 1), (1, 3), (3, 1)] where i + a <= n && j + b <= m {
                    let sim = similarity(joined(reference, i, a), joined(hypothesis, j, b), language: language)
                    // Groupings must earn their place: a merge is scored like one pair plus a small
                    // penalty, so 1:1 wins when both explanations fit equally well.
                    relax(i + a, j + b, base + (sim - matchThreshold) - Double(a + b - 2) * 0.02, .match(i, a, j, b))
                }
            }
        }
        guard score[n][m] > -.infinity else { return nil }
        var steps: [Step] = [], i = n, j = m
        while i > 0 || j > 0 {
            guard let step = back[i][j] else { return nil }
            steps.append(step)
            switch step {
            case .match(let ri, _, let hj, _): i = ri; j = hj
            case .missing(let ri): i = ri
            case .extra(let hj): j = hj
            }
        }
        return steps.reversed()
    }

    // MARK: Scoring

    /// Scores captions (source-time) against a transcript. `sourceRange` is the part of the media
    /// the clip actually uses; timed transcript units outside it are ignored, and an untimed
    /// transcript is refused for a partial clip rather than producing an inflated “missing” count.
    public static func evaluate(captions: [EvaluatedCaption], reference: TranscriptReference?, language: String,
                                sourceRange: ClosedRange<Double>, mediaDuration: Double) -> TranscriptEvaluationReport {
        guard let reference else {
            return .unscored("대본 없음 · 영상과 같은 이름의 .srt 또는 .txt가 없어 정확도를 계산하지 않았습니다.", language: language, captions: captions.count, range: sourceRange)
        }
        let coverage = mediaDuration > 0 ? (sourceRange.upperBound - sourceRange.lowerBound) / mediaDuration : 0
        if !reference.isTimed && coverage < untimedMinimumCoverage {
            return .unscored(String(format: "시간 정보가 없는 .txt 대본은 영상 전체 기준입니다. 클립이 원본의 %.0f%%만 사용해 누락이 과대 계산되므로 평가하지 않았습니다. 시간이 있는 .srt 대본을 사용하세요.", coverage * 100),
                             language: language, captions: captions.count, range: sourceRange, reference: reference.url)
        }
        let units = reference.isTimed
            ? reference.units.filter { unit in
                guard let s = unit.start, let e = unit.end else { return false }
                // A transcript line counts when most of it lies inside the clip's source range.
                let overlap = min(e, sourceRange.upperBound) - max(s, sourceRange.lowerBound)
                return overlap > 0.5 * max(0.001, e - s)
            }
            : reference.units
        let usable = units.filter { !characters($0.text, language: language).isEmpty }
        guard !usable.isEmpty else {
            return .unscored("클립 구간에 해당하는 대본 문장이 없습니다.", language: language, captions: captions.count, range: sourceRange, reference: reference.url)
        }
        let hyps = captions.sorted { $0.start < $1.start }.filter { !characters($0.text, language: language).isEmpty }
        let refText = usable.map(\.text).joined(separator: " "), hypText = hyps.map(\.text).joined(separator: " ")
        let chars = editCounts(reference: characters(refText, language: language), hypothesis: characters(hypText, language: language))
        let wordCounts = editCounts(reference: words(refText, language: language), hypothesis: words(hypText, language: language))
        var missing: [SentenceIssue] = [], extra: [SentenceIssue] = [], mismatched: [SentenceIssue] = []
        var matched = 0
        var startErrors: [Double] = [], endErrors: [Double] = []
        for step in align(reference: usable.map(\.text), hypothesis: hyps.map(\.text), language: language) {
            switch step {
            case .missing(let i): missing.append(SentenceIssue(text: usable[i].text, start: usable[i].start, similarity: nil))
            case .extra(let j): extra.append(SentenceIssue(text: hyps[j].text, start: hyps[j].start, similarity: nil))
            case .match(let i, let a, let j, let b):
                let refs = usable[i..<(i + a)], caps = hyps[j..<(j + b)]
                let sim = similarity(refs.map(\.text).joined(separator: " "), caps.map(\.text).joined(separator: " "), language: language)
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
        }
        return TranscriptEvaluationReport(status: .scored, reason: reference.isTimed ? nil : "시간 없는 대본 · 시간 오차는 계산하지 않음", language: language,
                                          referencePath: reference.url.path, referenceTimed: reference.isTimed, sourceRange: [sourceRange.lowerBound, sourceRange.upperBound],
                                          normalization: normalizationDescription(language), cer: chars.errorRate, wer: wordCounts.errorRate,
                                          characters: chars, words: wordCounts, wordUnit: wordUnitDescription(language),
                                          referenceSentences: usable.count, captionSentences: hyps.count, matchedSentences: matched,
                                          missing: missing, extra: extra, mismatched: mismatched, timing: timing, createdAt: Date())
    }

    // MARK: Reports

    /// Writes `<name>.json` and a human-readable `<name>.md`. Never called with a folder beside an
    /// original: the editor passes its own reports directory.
    public static func write(_ report: TranscriptEvaluationReport, title: String, to folder: URL, name: String) throws -> (json: URL, text: URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let json = folder.appendingPathComponent(name + ".json"), text = folder.appendingPathComponent(name + ".md")
        try encoder.encode(report).write(to: json, options: .atomic)
        try markdown(report, title: title).write(to: text, atomically: true, encoding: .utf8)
        return (json, text)
    }

    public static func markdown(_ r: TranscriptEvaluationReport, title: String) -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "평가 불가" }
        func sec(_ v: Double) -> String { String(format: "%.2f초", v) }
        var lines = ["# 자막 정확도 평가 — \(title)", ""]
        lines.append("- 상태: \(r.status == .scored ? "평가함" : "평가 불가")" + (r.reason.map { " · \($0)" } ?? ""))
        lines.append("- 언어: \(CaptionLanguage(rawValue: r.language)?.label ?? r.language)")
        lines.append("- 대본: \(r.referencePath ?? "없음")\(r.referenceTimed ? " (시간 포함)" : "")")
        lines.append(String(format: "- 원본 구간: %.2f~%.2f초", r.sourceRange.first ?? 0, r.sourceRange.last ?? 0))
        lines.append("- 정규화: \(r.normalization)")
        guard r.status == .scored else { lines.append(""); lines.append("대본이 없거나 비교 조건이 맞지 않아 CER/WER을 계산하지 않았습니다."); return lines.joined(separator: "\n") + "\n" }
        lines.append("")
        lines.append("| 지표 | 값 | 치환 | 삭제 | 삽입 | 기준 길이 |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        if let c = r.characters { lines.append("| CER | \(pct(r.cer)) | \(c.substitutions) | \(c.deletions) | \(c.insertions) | \(c.referenceLength)자 |") }
        if let w = r.words { lines.append("| WER (\(r.wordUnit ?? "")) | \(pct(r.wer)) | \(w.substitutions) | \(w.deletions) | \(w.insertions) | \(w.referenceLength) |") }
        lines.append("")
        lines.append("- 문장: 대본 \(r.referenceSentences)개 · 자막 \(r.captionSentences)개 · 일치 \(r.matchedSentences)개 · 누락 \(r.missing.count)개 · 과잉 \(r.extra.count)개 · 불일치 \(r.mismatched.count)개")
        if let t = r.timing {
            lines.append("- 시작 시각 오차(\(t.matchedPairs)쌍): 평균 \(sec(t.meanAbsoluteStart)) · 중앙값 \(sec(t.medianAbsoluteStart)) · 최대 \(sec(t.maxAbsoluteStart)) · 0.5초 이내 \(pct(t.startWithinHalfSecond))")
            lines.append("- 끝 시각 오차: 평균 \(sec(t.meanAbsoluteEnd)) · 중앙값 \(sec(t.medianAbsoluteEnd)) · 최대 \(sec(t.maxAbsoluteEnd))")
        } else { lines.append("- 시간 오차: 계산하지 않음(대본에 시간 없음)") }
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

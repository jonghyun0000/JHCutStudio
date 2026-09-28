import Foundation

public struct CaptionCue: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: MediaTime
    public var duration: MediaTime
    public var text: String
    public init(id: UUID = UUID(), start: MediaTime, duration: MediaTime, text: String) {
        self.id = id; self.start = start; self.duration = duration; self.text = text
    }
}
public enum SRTCodec {
    public static func parse(_ text: String) throws -> [CaptionCue] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = try NSRegularExpression(pattern: #"\n[ \t]*\n+"#)
        let blocks = separator.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\u{001E}").components(separatedBy: "\u{001E}")
        return try blocks.enumerated().map { index, block in
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3, let number = Int(lines[0].trimmingCharacters(in: .whitespaces)), number > 0 else { throw ProjectError("SRT \(index + 1)번 구간의 번호 또는 본문이 올바르지 않습니다.") }
            let times = lines[1].components(separatedBy: "-->")
            guard times.count == 2 else { throw ProjectError("SRT \(number)번 구간의 시간 형식이 올바르지 않습니다.") }
            let start = try parseTime(times[0]), end = try parseTime(times[1])
            guard end > start else { throw ProjectError("SRT \(number)번 구간의 끝은 시작보다 뒤여야 합니다.") }
            let body = lines.dropFirst(2).joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("SRT \(number)번 구간의 본문이 비어 있습니다.") }
            return CaptionCue(start: start, duration: try end.subtracting(start), text: body)
        }
    }
    /// For recogniser output only (user files keep the strict `parse`). whisper.cpp can emit a
    /// cue whose end equals its start; failing the whole recognition for that lost every caption.
    /// A zero-length cue's text is appended to the previous cue (or given 0.3 s when first);
    /// blocks with unreadable numbering/time or no text are skipped and counted.
    public static func parseRecognizerOutput(_ text: String) -> (cues: [CaptionCue], repaired: Int, skipped: Int) {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let separator = try? NSRegularExpression(pattern: #"\n[ \t]*\n+"#) else { return ([], 0, 0) }
        let blocks = separator.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\u{001E}").components(separatedBy: "\u{001E}")
        var cues: [CaptionCue] = [], repaired = 0, skipped = 0
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            let times = lines.count >= 3 ? lines[1].components(separatedBy: "-->") : []
            guard times.count == 2, let start = try? parseTime(times[0]), let end = try? parseTime(times[1]) else { skipped += 1; continue }
            let body = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { skipped += 1; continue }
            if end > start, let duration = try? end.subtracting(start) { cues.append(CaptionCue(start: start, duration: duration, text: body)); continue }
            repaired += 1
            if !cues.isEmpty { cues[cues.count - 1].text += (body.first?.isPunctuation == true ? "" : " ") + body }
            else { cues.append(CaptionCue(start: start, duration: MediaTime(3, 10), text: body)) }
        }
        return (cues, repaired, skipped)
    }
    public static func serialize(_ cues: [CaptionCue]) throws -> String {
        try cues.enumerated().map { index, cue in
            guard cue.start >= .zero, cue.duration > .zero, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("자막의 시작·길이·본문을 확인하세요.") }
            let begin = try milliseconds(cue.start), end = try milliseconds(cue.start.adding(cue.duration))
            guard end > begin else { throw ProjectError("SRT는 1밀리초보다 짧은 자막을 저장할 수 없습니다.") }
            let body = cue.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            guard !body.contains("\n\n") else { throw ProjectError("SRT 자막 본문에는 빈 줄을 넣을 수 없습니다.") }
            return "\(index + 1)\n\(format(begin)) --> \(format(end))\n\(body)\n"
        }.joined(separator: "\n")
    }
    public static func clips(from cues: [CaptionCue], style: Title) -> [Clip] {
        cues.map { cue in var title = style; title.text = cue.text; return Clip(id: cue.id, name: "자막", start: cue.start, duration: cue.duration, title: title) }
    }
    private static func parseTime(_ value: String) throws -> MediaTime {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let components = trimmed.replacingOccurrences(of: ".", with: ",").components(separatedBy: CharacterSet(charactersIn: ":,"))
        guard components.count == 4, components[0].count >= 2, components[1].count == 2, components[2].count == 2, components[3].count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }), let hours = Int64(components[0]), let minutes = Int64(components[1]), let seconds = Int64(components[2]), let ms = Int64(components[3]), minutes < 60, seconds < 60 else { throw ProjectError("SRT 시간은 HH:MM:SS,mmm 형식이어야 합니다: \(trimmed)") }
        let hoursMS = hours.multipliedReportingOverflow(by: 3_600_000)
        let total = hoursMS.partialValue.addingReportingOverflow(minutes * 60_000 + seconds * 1_000 + ms)
        guard !hoursMS.overflow, !total.overflow else { throw ProjectError("SRT 시간이 허용 범위를 초과합니다.") }
        return MediaTime(total.partialValue, 1_000)
    }
    private static func milliseconds(_ time: MediaTime) throws -> Int64 {
        guard time >= .zero else { throw ProjectError("자막 시간은 음수일 수 없습니다.") }
        let product = UInt64(time.value).multipliedFullWidth(by: 1_000)
        let scale = UInt64(time.timescale)
        guard product.high < scale else { throw TimeArithmeticError.nonRepresentable }
        let result = scale.dividingFullWidth(product)
        let rounded = result.quotient.addingReportingOverflow(result.remainder >= (scale + 1) / 2 ? 1 : 0)
        guard !rounded.overflow, let value = Int64(exactly: rounded.partialValue) else { throw TimeArithmeticError.nonRepresentable }
        return value
    }
    private static func format(_ ms: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1_000) % 60, ms % 1_000)
    }
}

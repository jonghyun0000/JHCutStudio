import Foundation
import CoreFoundation

public enum CaptionEditing {
    /// Turns engine segments into readable subtitle sentences while preserving source timing.
    /// A cue is split only at whitespace/punctuation boundaries; timing is distributed by
    /// character weight so a long sentence does not display too quickly.
    public static func sentenceCues(_ cues: [CaptionCue], maxCharacters: Int = 42, maxDuration: Double = 7.0) -> [CaptionCue] {
        guard maxCharacters >= 8, maxDuration > 0 else { return cues }
        return cues.flatMap { cue -> [CaptionCue] in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper sometimes emits a segment that is only a quote mark or dash.
            guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return [] }
            let units = splitSentence(text, maxCharacters: maxCharacters)
            guard units.count > 1 || cue.duration.seconds <= maxDuration else {
                return [cue]
            }
            let weights = units.map { max(1, normalizedLength($0)) }
            let total = max(1, weights.reduce(0, +))
            var cursor = cue.start
            return units.enumerated().compactMap { index, unit -> CaptionCue? in
                let remaining = (cue.start + cue.duration) - cursor
                guard remaining > .zero else { return nil }
                let fraction = Double(weights[index]) / Double(total)
                let proposed = index == units.count - 1 ? remaining : MediaTime(seconds: cue.duration.seconds * fraction)
                let duration = proposed > .zero ? proposed : .zero
                defer { cursor = cursor + duration }
                return duration > .zero ? CaptionCue(id: index == 0 ? cue.id : UUID(), start: cursor, duration: duration, text: unit) : nil
            }
        }
    }

    private static func splitSentence(_ text: String, maxCharacters: Int) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            // A fragment with no letter or digit (a stray quote or dash) is not a readable caption.
            if value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { result.append(value) }
            else if let last = result.popLast() { result.append(last + value) }
            current = ""
        }
        for character in text.replacingOccurrences(of: "\n", with: " ") {
            current.append(character)
            let punctuation = ".!?。！？、,".contains(character)
            if punctuation || current.count >= maxCharacters {
                // Prefer a punctuation boundary. For long Japanese text without spaces,
                // split at the configured character limit while retaining the character.
                if punctuation || current.count >= maxCharacters { flush() }
            }
        }
        flush()
        return result.isEmpty ? [text] : result
    }

    private static func normalizedLength(_ text: String) -> Int {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// Recognition timestamps are absolute source positions. Clamp before mapping through trim/rate.
    public static func automaticClips(cues: [CaptionCue], source: Clip, style: Title) -> [Clip] {
        let rate = source.playbackRate ?? PlaybackRate()
        let sourceEnd = source.sourceStart + source.sourceDuration
        return sentenceCues(cues).sorted { $0.start < $1.start }.compactMap { cue in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let begin = max(source.sourceStart, cue.start)
            let end = min(sourceEnd, cue.start + cue.duration)
            guard !text.isEmpty, end > begin else { return nil }
            var title = style; title.text = text
            var clip = Clip(name: "자동 자막", start: source.start + rate.timelineDuration(for: begin - source.sourceStart),
                        duration: rate.timelineDuration(for: end - begin), title: title)
            clip.connection = ClipConnection(parentID: source.id, sourceStart: begin, sourceDuration: end - begin, generatedText: text)
            return clip
        }
    }
    /// Caller supplies adjacent title clips in timeline order. A gap is intentionally covered
    /// by the merged caption. Animated titles must be kept separate because concatenating text
    /// cannot faithfully preserve two independent motion/fade histories with one static title.
    public static func merged(first: Clip, second: Clip) throws -> Clip {
        guard first.id != second.id, let firstTitle = first.title, let secondTitle = second.title, first.assetID == nil, second.assetID == nil, first.sourceStart == .zero, second.sourceStart == .zero, first.start >= .zero, first.duration > .zero, second.duration > .zero else { throw ProjectError("서로 다른 두 제목·자막 클립을 선택하세요.") }
        guard try first.start.adding(first.duration) <= second.start else { throw ProjectError("자막 합치기는 시간 순서대로 겹치지 않는 두 클립에 사용할 수 있습니다.") }
        var firstStyle = firstTitle, secondStyle = secondTitle
        firstStyle.text = ""; secondStyle.text = ""
        guard firstStyle == secondStyle, first.transform == second.transform, first.visual == second.visual, first.volume == second.volume, first.playbackRate == second.playbackRate else { throw ProjectError("자막의 글꼴·스타일·위치·효과가 다릅니다. 먼저 같은 스타일로 맞추세요.") }
        guard (first.keyframes ?? []).isEmpty, (second.keyframes ?? []).isEmpty, [first.fadeIn, first.fadeOut, first.audioFadeIn, first.audioFadeOut, second.fadeIn, second.fadeOut, second.audioFadeIn, second.audioFadeOut].allSatisfy({ ($0 ?? .zero) == .zero }) else { throw ProjectError("움직임·페이드가 있는 자막은 효과 손실을 방지하기 위해 합칠 수 없습니다.") }
        var result = first
        result.duration = try second.start.adding(second.duration).subtracting(first.start)
        result.title?.text = firstTitle.text + "\n" + secondTitle.text
        result.name = "합친 자막"
        return result
    }
    public static func shifted(_ clips: [Clip], by offset: MediaTime) throws -> [Clip] {
        try clips.map { original in
            guard original.title != nil, original.assetID == nil, original.sourceStart == .zero, original.start >= .zero, original.duration > .zero else { throw ProjectError("자막 시간 이동에는 유효한 제목·자막 클립만 선택하세요.") }
            var clip = original; clip.start = try original.start.adding(offset)
            guard clip.start >= .zero else { throw ProjectError("자막을 이동하면 시작이 0보다 작아집니다.") }
            _ = try clip.start.adding(clip.duration)
            return clip
        }
    }
}

/// One set of edits applied to many captions at once. nil fields are left unchanged.
public struct CaptionBatchChange: Equatable, Sendable {
    public var x: Double?, y: Double?, fontSize: Double?
    public var colorHex: String?, strokeHex: String?, strokeWidth: Double?
    public var backgroundHex: String?, backgroundOpacity: Double?, maxLines: Int?
    /// Moves the start while keeping the end (positive = later).
    public var startOffset: MediaTime?
    /// Moves the end while keeping the start (positive = later).
    public var endOffset: MediaTime?
    public init() {}
    public var isEmpty: Bool { self == CaptionBatchChange() }
}

public enum CaptionBatchEditing {
    public static let minimumDuration = MediaTime(1, 10)
    private static func hex(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard v.count == 6, v.allSatisfy(\.isHexDigit) else { throw ProjectError("색상은 6자리 RRGGBB로 입력하세요: \(value)") }
        return v
    }
    /// Applies `change` to one caption. Timing edits keep the other edge fixed and refuse a
    /// result shorter than 0.1 s or starting before zero rather than clamping it silently.
    public static func applied(_ change: CaptionBatchChange, to original: Clip) throws -> Clip {
        guard original.title != nil else { throw ProjectError("자막 클립만 일괄 편집할 수 있습니다.") }
        var clip = original
        if let x = change.x { guard (0...1).contains(x) else { throw ProjectError("가로 위치는 0~1입니다.") }; clip.title?.x = x }
        if let y = change.y { guard (0...1).contains(y) else { throw ProjectError("세로 위치는 0~1입니다.") }; clip.title?.y = y }
        if let size = change.fontSize { guard size >= 8, size <= 400 else { throw ProjectError("글자 크기는 8~400입니다.") }; clip.title?.fontSize = size }
        if let color = try hex(change.colorHex) { clip.title?.colorHex = color }
        let touchesStyle = change.strokeHex != nil || change.strokeWidth != nil || change.backgroundHex != nil || change.backgroundOpacity != nil || change.maxLines != nil
        if touchesStyle {
            var style = clip.title?.style ?? TextStyle()
            if let v = try hex(change.strokeHex) { style.strokeHex = v }
            if let v = change.strokeWidth { guard (0...50).contains(v) else { throw ProjectError("외곽선은 0~50입니다.") }; style.strokeWidth = v }
            if let v = try hex(change.backgroundHex) { style.backgroundHex = v }
            if let v = change.backgroundOpacity { guard (0...1).contains(v) else { throw ProjectError("배경 불투명도는 0~1입니다.") }; style.backgroundOpacity = v }
            if let v = change.maxLines { guard (0...20).contains(v) else { throw ProjectError("최대 줄 수는 0~20입니다.") }; style.maxLines = v }
            clip.title?.style = style
        }
        let end = try original.start.adding(original.duration)
        var start = original.start, newEnd = end
        if let offset = change.startOffset { start = try original.start.adding(offset) }
        if let offset = change.endOffset { newEnd = try end.adding(offset) }
        guard start >= .zero else { throw ProjectError("자막 시작이 0초보다 앞설 수 없습니다: \(original.title?.text.prefix(20) ?? "")") }
        let duration = try newEnd.subtracting(start)
        guard duration >= minimumDuration else { throw ProjectError("자막 길이가 0.1초보다 짧아집니다: \(original.title?.text.prefix(20) ?? "")") }
        clip.start = start; clip.duration = duration
        return clip
    }
}

public enum SubtitleTextEncoding: String, Codable, CaseIterable, Sendable {
    case utf8, utf16LittleEndian, utf16BigEndian, cp949
    fileprivate var foundation: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .cp949: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        }
    }
}
public enum SubtitleTextDecoder {
    /// BOM-marked UTF-8/UTF-16 and strict UTF-8 are deterministic. The CP949 fallback requires
    /// a lossless byte-for-byte encode/decode round trip; unmarked UTF-16 needs explicit choice.
    public static func decode(_ data: Data, encoding: SubtitleTextEncoding? = nil) throws -> String {
        let bytes = [UInt8](data.prefix(3))
        let detected: SubtitleTextEncoding?
        let prefix: Int
        if bytes.starts(with: [0xEF,0xBB,0xBF]) { detected = .utf8; prefix = 3 }
        else if bytes.starts(with: [0xFF,0xFE]) { detected = .utf16LittleEndian; prefix = 2 }
        else if bytes.starts(with: [0xFE,0xFF]) { detected = .utf16BigEndian; prefix = 2 }
        else { detected = nil; prefix = 0 }
        if let encoding, let detected, encoding != detected { throw ProjectError("선택한 자막 인코딩이 파일의 BOM 표시와 다릅니다.") }
        let payload = prefix > 0 ? data.dropFirst(prefix) : data
        func decoded(_ candidate: SubtitleTextEncoding) -> String? {
            guard let text = String(data: payload, encoding: candidate.foundation), !text.contains("\u{0000}"), let encoded = text.data(using: candidate.foundation, allowLossyConversion: false), encoded == payload else { return nil }
            return text
        }
        if let chosen = encoding ?? detected {
            guard let text = decoded(chosen) else { throw ProjectError("자막을 \(chosen.rawValue) 인코딩으로 손실 없이 읽을 수 없습니다.") }
            return text
        }
        if let text = decoded(.utf8) { return text }
        if let text = decoded(.cp949) { return text }
        throw ProjectError("자막 문자 인코딩을 확인하세요. UTF-8, BOM이 있는 UTF-16, CP949를 지원합니다.")
    }
}

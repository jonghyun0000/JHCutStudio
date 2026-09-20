import Foundation
import CoreFoundation

public enum CaptionEditing {
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

import Foundation
import CoreGraphics

public struct CaptionReadingRate: Sendable {
    public let language: String
    public let characters: Int
    public let charactersPerSecond: Double
    public let limit: Double
    public var tooFast: Bool { charactersPerSecond > limit }
}

public struct CaptionReadabilityReport: Sendable {
    public let language: String
    public let characters: Int
    public let charactersPerSecond: Double
    public let limit: Double
    public let lines: Int
    public let exceedsLineLimit: Bool
    public let fullBounds: CGRect?
    public let outsideCanvas: Bool
    public let outsideSafeArea: Bool
    public let fallbackFont: String?
    public let shortCue: Bool
    public var tooFast: Bool { charactersPerSecond > limit }
    public var warnings: [String] {
        var result: [String] = []
        if exceedsLineLimit { result.append("목표 줄 수 초과 · 실제 \(lines)줄 · 문구 전체 표시") }
        if outsideCanvas { result.append("전체 문구가 화면 밖에서 잘립니다 · 안전 영역 맞춤 또는 문구/시간 분할이 필요합니다") }
        else if outsideSafeArea { result.append("안전 영역 밖 · 화면 가장자리를 확인하세요") }
        if tooFast { result.append(String(format: "읽기 빠름 · %.1f자/초 (검수 기준 %.0f)", charactersPerSecond, limit)) }
        if shortCue { result.append("0.4초 미만의 짧은 자막 · 원음을 듣고 시간을 검토하세요") }
        if let font = fallbackFont { result.append("미설치 글꼴 · \(font)(으)로 대체 표시/출력") }
        return result
    }
}

public enum CaptionReadability {
    /// Shared by the editor and finished-export QA. No text or timing is changed.
    public static func reading(text: String, language specified: String?, seconds: Double) -> CaptionReadingRate {
        let scalars = text.unicodeScalars
        let language: String
        if let specified, CaptionLanguage(rawValue: specified) != nil { language = specified }
        else if scalars.contains(where: { (0x3040...0x30ff).contains($0.value) }) { language = "ja" }
        else if scalars.contains(where: { (0xac00...0xd7af).contains($0.value) }) { language = "ko" }
        else { language = "en" }
        let limit = language == "ja" ? 10.0 : language == "ko" ? 12.0 : 17.0
        let count = text.filter { !$0.isWhitespace }.count
        return CaptionReadingRate(language: language, characters: count, charactersPerSecond: Double(count) / max(0.001, seconds), limit: limit)
    }
    /// Product review heuristics, not a certified subtitle standard or an accuracy score.
    public static func assess(_ clip: Clip, width: Int, height: Int) throws -> CaptionReadabilityReport? {
        guard let title = clip.title else { return nil }
        let rate = reading(text: title.text, language: clip.captionMetadata?.language, seconds: clip.duration.seconds)
        let info = try TitlePreviewRenderer.layout(title: title, canvasWidth: Double(width))
        let bounds = TitlePreviewRenderer.fullBounds(title: title, size: CGSize(width: width, height: height))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: -1, dy: -1)
        let safe = CaptionLayout.safeArea(width: width, height: height).insetBy(dx: -1, dy: -1)
        return CaptionReadabilityReport(language: rate.language, characters: rate.characters,
            charactersPerSecond: rate.charactersPerSecond, limit: rate.limit,
            lines: info.totalLines, exceedsLineLimit: info.exceedsLineLimit, fullBounds: bounds,
            outsideCanvas: bounds.map { !canvas.contains($0) } ?? false,
            outsideSafeArea: bounds.map { !safe.contains($0) } ?? false,
            fallbackFont: info.usesFallbackFont ? info.effectiveFontName : nil, shortCue: clip.duration.seconds < 0.4)
    }
}

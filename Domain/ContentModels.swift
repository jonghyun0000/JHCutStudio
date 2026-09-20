import Foundation

public struct AssetProvenance: Codable, Equatable, Sendable {
    public var sourceURL: String
    public var author: String
    public var license: String
    public var licenseURL: String
    public var sha256: String
    public init(sourceURL: String = "", author: String = "", license: String = "", licenseURL: String = "", sha256: String = "") {
        self.sourceURL = sourceURL; self.author = author; self.license = license; self.licenseURL = licenseURL; self.sha256 = sha256
    }
}

public enum TextAlignment: String, Codable, Sendable { case left, center, right }
public struct TextStyle: Codable, Equatable, Sendable {
    public var strokeHex: String
    public var strokeWidth: Double
    public var backgroundHex: String
    public var backgroundOpacity: Double
    public var padding: Double
    public var alignment: TextAlignment
    public var shadow: Bool
    public var maxLines: Int
    public var lineSpacing: Double
    public init(strokeHex: String = "000000", strokeWidth: Double = 0, backgroundHex: String = "000000", backgroundOpacity: Double = 0, padding: Double = 20, alignment: TextAlignment = .center, shadow: Bool = true, maxLines: Int = 0, lineSpacing: Double = 8) {
        self.strokeHex = strokeHex; self.strokeWidth = strokeWidth; self.backgroundHex = backgroundHex; self.backgroundOpacity = backgroundOpacity; self.padding = padding; self.alignment = alignment; self.shadow = shadow; self.maxLines = maxLines; self.lineSpacing = lineSpacing
    }
}
public struct PlaybackRate: Codable, Equatable, Sendable {
    public var numerator: Int32
    public var denominator: Int32
    public init(numerator: Int32 = 1, denominator: Int32 = 1) { self.numerator = numerator; self.denominator = denominator }
    public var multiplier: Double { Double(numerator) / Double(denominator) }
    public func sourceDuration(for timelineDuration: MediaTime) -> MediaTime { exact(timelineDuration, numerator, denominator) }
    public func timelineDuration(for sourceDuration: MediaTime) -> MediaTime { exact(sourceDuration, denominator, numerator) }
    private func exact(_ time: MediaTime, _ numerator: Int32, _ denominator: Int32) -> MediaTime {
        do { return try time.scaled(numerator: numerator, denominator: denominator) }
        catch { preconditionFailure(error.localizedDescription) }
    }
}
public struct VisualAdjustments: Codable, Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var cropLeft: Double
    public var cropRight: Double
    public var cropTop: Double
    public var cropBottom: Double
    public init(exposure: Double = 0, contrast: Double = 1, saturation: Double = 1, cropLeft: Double = 0, cropRight: Double = 0, cropTop: Double = 0, cropBottom: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.saturation = saturation; self.cropLeft = cropLeft; self.cropRight = cropRight; self.cropTop = cropTop; self.cropBottom = cropBottom
    }
}
public enum KeyframeInterpolation: String, Codable, Sendable { case linear, hold, ease }
public struct TransformKeyframe: Codable, Equatable, Sendable {
    public var time: MediaTime
    public var transform: ClipTransform
    public var volume: Double
    public var interpolation: KeyframeInterpolation
    public init(time: MediaTime, transform: ClipTransform, volume: Double = 1, interpolation: KeyframeInterpolation = .linear) {
        self.time = time; self.transform = transform; self.volume = volume; self.interpolation = interpolation
    }
}

extension Clip {
    public var sourceDuration: MediaTime { (playbackRate ?? PlaybackRate()).sourceDuration(for: duration) }
    /// Keyframe times are local timeline times. The implicit frame at zero uses the clip's base values.
    /// Each frame's interpolation mode controls its outgoing segment; values hold after the final frame.
    public func evaluatedTransform(at localTime: MediaTime) -> ClipTransform { evaluatedKeyframe(at: localTime).transform }
    public func evaluatedVolume(at localTime: MediaTime) -> Double { evaluatedKeyframe(at: localTime).volume }
    public func evaluatedKeyframe(at time: MediaTime) -> TransformKeyframe {
        let localTime = max(.zero, min(duration, time))
        let baseline = TransformKeyframe(time: .zero, transform: transform, volume: volume)
        guard let frames = keyframes, !frames.isEmpty else { return baseline }
        // ProjectValidator requires ordered, unique times. Binary search keeps baked frame
        // tracks practical: evaluation does not scan tens of thousands of earlier keys.
        var lower = 0, upper = frames.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frames[middle].time <= localTime { lower = middle + 1 } else { upper = middle }
        }
        let previous = lower == 0 ? baseline : frames[lower - 1]
        guard lower < frames.count else { return previous }
        let frame = frames[lower]
        guard localTime > previous.time, frame.time > previous.time else { return previous }
        var amount = (localTime - previous.time).seconds / (frame.time - previous.time).seconds
        switch previous.interpolation {
        case .hold: amount = 0
        case .ease: amount = amount * amount * (3 - 2 * amount)
        case .linear: break
        }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        let a = previous.transform, b = frame.transform
        return TransformKeyframe(time: localTime, transform: ClipTransform(x: mix(a.x,b.x), y: mix(a.y,b.y), scale: mix(a.scale,b.scale), rotation: mix(a.rotation,b.rotation), opacity: mix(a.opacity,b.opacity), fill: a.fill), volume: mix(previous.volume,frame.volume), interpolation: previous.interpolation)
    }
}

public struct TitlePreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var title: Title
    public init(id: String, name: String, category: String, title: Title) { self.id = id; self.name = name; self.category = category; self.title = title }
    public static let builtIns: [TitlePreset] = [
        preset("clean-caption", "기본 자막", "자막", "여기에 자막을 입력하세요", size: 58, y: 0.15, stroke: 3),
        preset("bold-caption", "강조 자막", "자막", "꼭 기억할 한마디", size: 72, color: "FFE55B", y: 0.18, stroke: 5),
        preset("soft-caption", "차분한 설명", "자막", "천천히 이야기를 시작합니다", size: 52, y: 0.14, bg: "18212B", alpha: 0.75),
        preset("interview-name", "인터뷰 이름", "인터뷰", "이름을 입력하세요", size: 60, x: 0.12, y: 0.25, alignment: .left, bg: "102334", alpha: 0.85),
        preset("interview-role", "인터뷰 소개", "인터뷰", "소개 · 역할을 입력하세요", size: 40, color: "BBDAD4", x: 0.12, y: 0.18, alignment: .left),
        preset("quote", "인용문", "다큐", "“기억하고 싶은 이야기”", size: 70, y: 0.52, bg: "000000", alpha: 0.48, padding: 36),
        preset("chapter", "장 제목", "다큐", "첫 번째 이야기", size: 92, x: 0.12, y: 0.68, alignment: .left),
        preset("location", "장소 기록", "다큐", "장소 · 날짜", size: 40, x: 0.12, y: 0.84, alignment: .left, bg: "111111", alpha: 0.65),
        preset("question", "질문 카드", "소셜", "어떤 이야기를 만들까요?", size: 82, color: "E1FF84", y: 0.55, stroke: 3),
        preset("headline", "큰 헤드라인", "광고", "새로운 시작", size: 116, y: 0.65, stroke: 2),
        preset("mint", "민트 포인트", "광고", "오늘의 발견", size: 96, color: "70F2D2", y: 0.60, bg: "062E29", alpha: 0.7),
        preset("action", "행동 안내", "광고", "자세히 알아보세요", size: 60, y: 0.22, bg: "214ADC", alpha: 0.95, padding: 30),
        preset("end-card", "엔드카드", "광고", "함께 만들어 가는 이야기", size: 84, y: 0.55, bg: "10182C", alpha: 0.8, padding: 42),
        preset("number", "숫자 강조", "소셜", "3가지 포인트", size: 106, color: "FFC66B", y: 0.67, stroke: 4),
        preset("tip", "짧은 팁", "소셜", "알아두면 좋은 팁", size: 62, color: "111111", x: 0.12, y: 0.78, alignment: .left, bg: "FFE46B", alpha: 0.95),
        preset("check", "확인 문구", "설명", "확인할 내용을 입력하세요", size: 58, color: "C5F8DC", y: 0.29, bg: "113729", alpha: 0.9),
        preset("warning", "주의 안내", "설명", "이 부분을 확인하세요", size: 64, color: "FFD1CA", y: 0.32, bg: "6C2220", alpha: 0.88),
        preset("step", "단계 안내", "설명", "STEP 01 · 시작하기", size: 60, x: 0.12, y: 0.82, alignment: .left, bg: "222B3F", alpha: 0.9),
        preset("quiet", "작은 여운", "다큐", "이야기는 계속됩니다", size: 46, color: "DBD9D3", y: 0.36, shadow: false),
        preset("festival", "따뜻한 초대", "광고", "우리의 이야기에 초대합니다", size: 72, color: "FFE3CA", y: 0.57, bg: "4C2B26", alpha: 0.74),
        preset("side-note", "오른쪽 메모", "설명", "작은 메모를 남겨보세요", size: 46, x: 0.88, y: 0.73, alignment: .right, bg: "20252D", alpha: 0.8),
        preset("top-banner", "상단 배너", "소셜", "오늘의 주제", size: 68, color: "F0EDFF", y: 0.88, bg: "42346B", alpha: 0.92),
        preset("minimal", "미니멀 타이틀", "다큐", "시간의 기록", size: 100, y: 0.55, shadow: false),
        preset("closing", "마지막 인사", "소셜", "시청해 주셔서 감사합니다", size: 68, color: "D8EAFF", y: 0.48, stroke: 2)
    ]
    private static func preset(_ id: String, _ name: String, _ category: String, _ text: String, size: Double, color: String = "FFFFFF", x: Double = 0.5, y: Double, alignment: TextAlignment = .center, stroke: Double = 0, bg: String = "000000", alpha: Double = 0, padding: Double = 20, shadow: Bool = true) -> TitlePreset {
        TitlePreset(id: id, name: name, category: category, title: Title(text: text, fontName: "AppleSDGothicNeo-Bold", fontSize: size, colorHex: color, x: x, y: y, style: TextStyle(strokeWidth: stroke, backgroundHex: bg, backgroundOpacity: alpha, padding: padding, alignment: alignment, shadow: shadow)))
    }
}

import Foundation

// MARK: - Transitions between clips

public enum TransitionKind: String, Codable, CaseIterable, Sendable {
    case dissolve, dipToBlack, wipe, slide, push, zoom
    public var label: String {
        switch self {
        case .dissolve: return "디졸브"
        case .dipToBlack: return "검정을 거쳐 전환"
        case .wipe: return "와이프"
        case .slide: return "슬라이드"
        case .push: return "밀어내기"
        case .zoom: return "확대 디졸브"
        }
    }
    /// Kinds that come from a side and therefore have a direction.
    public var usesDirection: Bool { self == .wipe || self == .slide || self == .push }
}

/// The side the incoming picture comes from.
public enum TransitionDirection: String, Codable, CaseIterable, Sendable {
    case fromLeft, fromRight, fromTop, fromBottom
    public var label: String {
        switch self { case .fromLeft: return "왼쪽에서"; case .fromRight: return "오른쪽에서"; case .fromTop: return "위에서"; case .fromBottom: return "아래에서" }
    }
    /// Unit vector pointing from the picture centre towards the side it comes from (Core Image axes: y up).
    public var vector: (x: Double, y: Double) {
        switch self { case .fromLeft: return (-1, 0); case .fromRight: return (1, 0); case .fromTop: return (0, 1); case .fromBottom: return (0, -1) }
    }
}

/// Stored on the INCOMING clip. The clip starts `duration` before the outgoing clip ends and the
/// renderer draws the overlap according to `kind`. Clips written by 0.6 have only a fade-in and no
/// `transition`; they keep rendering as dissolves.
public struct ClipTransition: Codable, Equatable, Sendable {
    public var kind: TransitionKind
    public var direction: TransitionDirection
    public var duration: MediaTime
    public init(kind: TransitionKind, direction: TransitionDirection = .fromRight, duration: MediaTime) {
        self.kind = kind; self.direction = direction; self.duration = duration
    }
}

public enum Easing {
    /// Smoothstep: starts and ends gently.
    public static func inOut(_ p: Double) -> Double { let x = min(1, max(0, p)); return x * x * (3 - 2 * x) }
    /// Overshoots 1 slightly before settling (the “pop”).
    public static func backOut(_ p: Double) -> Double { let x = min(1, max(0, p)) - 1, c = 1.70158; return x * x * ((c + 1) * x + c) + 1 }
}

// MARK: - Title animation

public enum TitleAnimationKind: String, Codable, CaseIterable, Sendable {
    case fade, slideUp, slideDown, slideLeft, pop, zoom, typewriter
    public var label: String {
        switch self {
        case .fade: return "페이드"
        case .slideUp: return "아래에서 올라오기"
        case .slideDown: return "위에서 내려오기"
        case .slideLeft: return "왼쪽에서 밀기"
        case .pop: return "팝"
        case .zoom: return "확대"
        case .typewriter: return "글자 나타나기"
        }
    }
}

/// Entrance and exit of a title or caption. The exit is the entrance played backwards.
public struct TitleAnimation: Codable, Equatable, Sendable {
    public static let secondsRange = 0.05...3.0
    public var inKind: TitleAnimationKind?
    public var outKind: TitleAnimationKind?
    public var inSeconds: Double
    public var outSeconds: Double
    public init(inKind: TitleAnimationKind? = nil, outKind: TitleAnimationKind? = nil, inSeconds: Double = 0.3, outSeconds: Double = 0.3) {
        self.inKind = inKind; self.outKind = outKind; self.inSeconds = inSeconds; self.outSeconds = outSeconds
    }
    public var isEmpty: Bool { inKind == nil && outKind == nil }
    public func validationProblem(clipDuration: MediaTime) -> String? {
        guard inSeconds.isFinite, outSeconds.isFinite, Self.secondsRange.contains(inSeconds), Self.secondsRange.contains(outSeconds) else { return "글자 애니메이션 길이는 0.05~3초여야 합니다." }
        let total = (inKind == nil ? 0 : inSeconds) + (outKind == nil ? 0 : outSeconds)
        guard total <= clipDuration.seconds + 1e-6 else { return "글자 애니메이션(등장+퇴장)이 자막 길이보다 깁니다." }
        return nil
    }

    /// How the title looks at `time` seconds into the clip. Offsets are fractions of the canvas
    /// (x of width, y of height, Core Image axes: y up).
    public struct State: Equatable, Sendable {
        public var opacity = 1.0
        public var scale = 1.0
        public var offsetX = 0.0
        public var offsetY = 0.0
        /// Share of the text revealed from the left (1 = all). Only `typewriter` changes it.
        public var reveal = 1.0
        public static let rest = State()
    }
    public func state(at time: Double, clipDuration: Double) -> State {
        var state = State.rest
        if let kind = inKind, time < inSeconds { state = Self.apply(kind, progress: max(0, time) / inSeconds, to: state) }
        if let kind = outKind {
            let remaining = clipDuration - time
            if remaining < outSeconds { state = Self.apply(kind, progress: max(0, remaining) / outSeconds, to: state) }
        }
        return state
    }
    /// `progress` 0 = hidden/away, 1 = at rest.
    static func apply(_ kind: TitleAnimationKind, progress p: Double, to base: State) -> State {
        var s = base
        let e = Easing.inOut(p)
        switch kind {
        case .fade: s.opacity *= p
        case .slideUp: s.offsetY -= (1 - e) * 0.08; s.opacity *= min(1, p * 1.5)
        case .slideDown: s.offsetY += (1 - e) * 0.08; s.opacity *= min(1, p * 1.5)
        case .slideLeft: s.offsetX -= (1 - e) * 0.12; s.opacity *= min(1, p * 1.5)
        case .pop: s.scale *= 0.6 + 0.4 * Easing.backOut(p); s.opacity *= min(1, p * 3)
        case .zoom: s.scale *= 1.5 - 0.5 * e; s.opacity *= p
        case .typewriter: s.reveal = min(s.reveal, p)
        }
        return s
    }
}

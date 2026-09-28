import Foundation

public enum MediaKind: String, Codable, Sendable { case video, image, audio }
public enum TrackKind: String, Codable, Sendable { case video, overlay, title, audio }

public struct MediaAsset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var relativePath: String?
    public var bookmark: Data?
    public var kind: MediaKind
    public var duration: MediaTime
    public var width: Int
    public var height: Int
    public var hasAudio: Bool
    public var codec: String
    public var colorInfo: String
    public var supported: Bool
    public var issue: String?
    public var contentHash: String?
    public var provenance: AssetProvenance?
    public init(id: UUID = UUID(), name: String, path: String, relativePath: String? = nil, bookmark: Data? = nil, kind: MediaKind, duration: MediaTime = .zero, width: Int = 0, height: Int = 0, hasAudio: Bool = false, codec: String = "", colorInfo: String = "", supported: Bool = true, issue: String? = nil, provenance: AssetProvenance? = nil) {
        self.id = id; self.name = name; self.path = path; self.relativePath = relativePath; self.bookmark = bookmark; self.kind = kind; self.duration = duration; self.width = width; self.height = height; self.hasAudio = hasAudio; self.codec = codec; self.colorInfo = colorInfo; self.supported = supported; self.issue = issue
        self.provenance = provenance
    }
    /// The argument is the project document URL, not its containing directory.
    public func resolvedURL(relativeTo documentURL: URL? = nil) -> URL {
        if let documentURL, let relativePath {
            let candidate = documentURL.deletingLastPathComponent().appendingPathComponent(relativePath).standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let bookmark {
            var stale = false
            if let candidate = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: path)
    }
}

public struct ClipTransform: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotation: Double
    public var opacity: Double
    public var fill: Bool
    public init(x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0, opacity: Double = 1, fill: Bool = false) {
        self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.opacity = opacity; self.fill = fill
    }
}

public struct Title: Codable, Equatable, Sendable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var colorHex: String
    public var x: Double
    public var y: Double
    public var style: TextStyle?
    public init(text: String, fontName: String = "AppleSDGothicNeo-Bold", fontSize: Double = 76, colorHex: String = "FFFFFF", x: Double = 0.5, y: Double = 0.8, style: TextStyle? = nil) {
        self.text = text; self.fontName = fontName; self.fontSize = fontSize; self.colorHex = colorHex; self.x = x; self.y = y; self.style = style
    }
}

public struct Clip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var assetID: UUID?
    public var start: MediaTime
    public var sourceStart: MediaTime
    public var duration: MediaTime
    public var volume: Double
    public var transform: ClipTransform
    public var title: Title?
    public var playbackRate: PlaybackRate?
    public var visual: VisualAdjustments?
    public var fadeIn: MediaTime?
    public var fadeOut: MediaTime?
    public var audioFadeIn: MediaTime?
    public var audioFadeOut: MediaTime?
    public var keyframes: [TransformKeyframe]?
    public var connection: ClipConnection?
    public var lineageID: UUID?
    public var ducking: [GainPoint]?
    public var captionMetadata: CaptionMetadata?
    public var end: MediaTime { start + duration }
    public init(id: UUID = UUID(), name: String = "클립", assetID: UUID? = nil, start: MediaTime = .zero, sourceStart: MediaTime = .zero, duration: MediaTime = MediaTime(seconds: 3), volume: Double = 1, transform: ClipTransform = ClipTransform(), title: Title? = nil, playbackRate: PlaybackRate? = nil, visual: VisualAdjustments? = nil, fadeIn: MediaTime? = nil, fadeOut: MediaTime? = nil, audioFadeIn: MediaTime? = nil, audioFadeOut: MediaTime? = nil, keyframes: [TransformKeyframe]? = nil) {
        self.id = id; self.name = name; self.assetID = assetID; self.start = start; self.sourceStart = sourceStart; self.duration = duration; self.volume = volume; self.transform = transform; self.title = title
        self.playbackRate = playbackRate; self.visual = visual; self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.audioFadeIn = audioFadeIn; self.audioFadeOut = audioFadeOut; self.keyframes = keyframes
    }
    public func contains(_ time: MediaTime) -> Bool { time >= start && time < end }
}

public struct Track: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var clips: [Clip]
    public var isMuted: Bool
    public var isHidden: Bool
    public var isLocked: Bool
    public var syncLocked: Bool?
    public init(id: UUID = UUID(), name: String, kind: TrackKind, clips: [Clip] = [], isMuted: Bool = false, isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.clips = clips; self.isMuted = isMuted; self.isHidden = isHidden; self.isLocked = isLocked
    }
}

public struct Sequence: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var colorSpace: String
    public var tracks: [Track]
    public var markers: [TimelineMarker]?
    public var speakers: [SpeakerProfile]?
    public var duration: MediaTime { tracks.flatMap(\.clips).map(\.end).max() ?? .zero }
    public init(id: UUID = UUID(), name: String = "시퀀스 1", width: Int = 1080, height: Int = 1920, frameRate: FrameRate = FrameRate(), colorSpace: String = "Rec.709", tracks: [Track] = [Track(name: "메인 영상", kind: .video), Track(name: "오버레이", kind: .overlay), Track(name: "제목 · 자막", kind: .title), Track(name: "오디오", kind: .audio)]) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.frameRate = frameRate; self.colorSpace = colorSpace; self.tracks = tracks
    }
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var assets: [MediaAsset]
    public var sequence: Sequence
    public var derivedSequences: [Sequence]?
    /// Project glossary for caption translation.
    public var glossary: [GlossaryEntry]?
    public init(name: String = "새 프로젝트") {
        schemaVersion = 1; id = UUID(); self.name = name; assets = []; sequence = Sequence(); derivedSequences = nil
    }
}

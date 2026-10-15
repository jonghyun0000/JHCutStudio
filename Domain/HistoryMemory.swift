import Foundation

/// Limits apply to historical states together, excluding the live document and external media.
public struct HistoryBudget: Equatable, Sendable {
    public var snapshotLimit: Int
    public var estimatedByteLimit: Int
    public init(snapshotLimit: Int = 100, estimatedByteLimit: Int = 64 * 1_024 * 1_024) {
        self.snapshotLimit = max(0, snapshotLimit)
        self.estimatedByteLimit = max(0, estimatedByteLimit)
    }
}

public struct HistoryMemoryUsage: Equatable, Sendable {
    public var undoCount = 0
    public var redoCount = 0
    /// Standalone estimates deliberately include shared payloads in each snapshot.
    public var undoLogicalBytes = 0
    public var redoLogicalBytes = 0
    public var currentLogicalBytes = 0
    /// Additional storage kept by history after subtracting storage already held by current.
    public var retainedEstimatedBytes = 0
    public var trimmedSnapshots = 0
}

/// An ephemeral traversal of simultaneously live Swift value graphs. Native array buffers are
/// charged once by address, element type and count. No pointer is dereferenced or persisted.
/// Strings/Data are conservatively charged when their enclosing buffer is first visited.
/// This is an estimate, not allocator capacity, RSS, or the cost of render/job snapshots.
struct HistoryMemoryCounter {
    private struct Buffer: Hashable {
        let address: UInt
        let type: ObjectIdentifier
        let count: Int
    }
    private var buffers: Set<Buffer> = []
    private(set) var bytes = 0
    mutating func string(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        bytes += value.utf8.count + 32
    }
    private mutating func charge<T>(_ values: [T]) -> Bool {
        guard !values.isEmpty else { return false }
        let key = values.withUnsafeBufferPointer {
            Buffer(address: UInt(bitPattern: $0.baseAddress!), type: ObjectIdentifier(T.self), count: $0.count)
        }
        guard buffers.insert(key).inserted else { return false }
        // A modest reserve allowance; Swift's true capacity and allocator overhead are opaque.
        bytes += values.count * MemoryLayout<T>.stride * 5 / 4 + 64
        return true
    }
    private mutating func array<T>(_ values: [T], visit: (inout Self, T) -> Void) {
        guard charge(values) else { return }
        for value in values { visit(&self, value) }
    }
    private mutating func plain<T>(_ values: [T]?) {
        if let values { _ = charge(values) }
    }
    private mutating func strings(_ values: [String]?) {
        if let values { array(values) { $0.string($1) } }
    }
    mutating func project(_ value: Project) {
        bytes += MemoryLayout<Project>.stride
        string(value.name)
        array(value.assets) { counter, asset in
            counter.string(asset.name); counter.string(asset.path); counter.string(asset.relativePath)
            counter.string(asset.codec); counter.string(asset.colorInfo); counter.string(asset.issue); counter.string(asset.contentHash)
            if let data = asset.bookmark { counter.bytes += data.count + 32 }
            if let p = asset.provenance {
                counter.string(p.sourceURL); counter.string(p.author); counter.string(p.license)
                counter.string(p.licenseURL); counter.string(p.sha256)
            }
        }
        sequence(value.sequence)
        if let derived = value.derivedSequences { array(derived) { $0.sequence($1) } }
        if let glossary = value.glossary {
            array(glossary) { c, g in
                c.string(g.source); c.string(g.target); c.string(g.sourceLanguage); c.string(g.targetLanguage)
            }
        }
    }
    private mutating func sequence(_ value: Sequence) {
        string(value.name); string(value.colorSpace)
        array(value.tracks) { c, track in
            c.string(track.name)
            c.array(track.clips) { $0.clip($1) }
        }
        if let markers = value.markers { array(markers) { $0.string($1.name) } }
        if let speakers = value.speakers {
            array(speakers) { c, s in c.string(s.id); c.string(s.name); c.string(s.colorHex) }
        }
    }
    private mutating func clip(_ value: Clip) {
        string(value.name); string(value.connection?.generatedText)
        if let title = value.title {
            string(title.text); string(title.fontName); string(title.colorHex)
            string(title.style?.strokeHex); string(title.style?.backgroundHex)
        }
        plain(value.keyframes); plain(value.ducking)
        if let fades = value.transitionAudioFades { array(fades) { $0.plain($1.points) } }
        if let lut = value.visual?.lut { string(lut.name); plain(lut.values) }
        if let s = value.stabilization { plain(s.x); plain(s.y); plain(s.angle) }
        if let m = value.captionMetadata {
            string(m.language); string(m.originalLanguage); string(m.originalText); string(m.generatedText)
            string(m.clipLanguage); string(m.speaker); string(m.speakerStatus); string(m.translationStyle); string(m.reviewDigest)
            strings(m.glossaryApplied); strings(m.glossaryFailed)
            if let r = m.translationRevision { string(r.sourceDigest); string(r.recipeDigest) }
            if let observations = m.languageEvidence {
                array(observations) { c, o in c.string(o.language); c.string(o.candidateLanguage); c.string(o.reason) }
            }
        }
    }
    static func standalone(_ value: Project) -> Int {
        var counter = Self(); counter.project(value); return counter.bytes
    }
}

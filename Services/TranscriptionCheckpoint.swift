import Foundation
import CryptoKit

/// Everything that can change what Whisper returns for a window. Two runs share completed windows
/// only when every field matches, so a checkpoint can never leak results from another project,
/// another file, another trim, or another recognition setting into this one.
public struct TranscriptionCheckpointKey: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public var format: Int = TranscriptionCheckpointKey.formatVersion
    public var projectID: UUID
    public var clipID: UUID
    /// Full SHA-256 of the media file as it exists when the run starts.
    public var mediaSHA256: String
    public var sourceStart: MediaTime
    public var duration: MediaTime
    public var windowSeconds: Double
    public var language: String
    public var channel: Int
    public var glossary: String
    public var accurate: Bool
    public var modelSHA256: String
    public var engine: String
    /// Voice-activity skipping changes which windows reach Whisper, so it is part of the identity.
    public var skipsSilence: Bool

    public init(projectID: UUID, clipID: UUID, mediaSHA256: String, sourceStart: MediaTime, duration: MediaTime,
                windowSeconds: Double, options: SpeechOptions, modelSHA256: String, engine: String = LocalTranscription.pipelineVersion,
                skipsSilence: Bool = false) {
        self.projectID = projectID; self.clipID = clipID; self.mediaSHA256 = mediaSHA256
        self.sourceStart = sourceStart; self.duration = duration; self.windowSeconds = windowSeconds
        self.language = options.language; self.channel = options.channel; self.glossary = options.glossary; self.accurate = options.accurate
        self.modelSHA256 = modelSHA256; self.engine = engine; self.skipsSilence = skipsSilence
    }

    /// Stable directory name. Sorted-key JSON makes the digest independent of property order.
    public var identifier: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public var windowCount: Int { max(1, Int((duration.seconds / windowSeconds).rounded(.up))) }
}

/// One completed recognition window. Cue times are absolute source times, exactly as returned by
/// `LocalTranscription.transcribe`.
public struct TranscriptionWindowResult: Codable, Equatable, Sendable {
    public var index: Int
    public var sourceStart: MediaTime
    public var duration: MediaTime
    public var cues: [CaptionCue]
    public var language: String
    public var channel: Int
    public var elapsedSeconds: Double
    /// True when voice-activity analysis found no speech and Whisper was not run for this window.
    public var skippedWithoutSpeech: Bool
    public var completedAt: Date
    /// Repetition-guard results for this window (absent in checkpoints written before the guard).
    public var repeatedCuesRemoved: Int?
    public var repetitionSuspects: [Double]?
    /// Coverage-repair results for this window (absent in older checkpoints).
    public var coverageRepairs: Int?
    public var recoveredCues: Int?
    public init(index: Int, sourceStart: MediaTime, duration: MediaTime, cues: [CaptionCue], language: String, channel: Int,
                elapsedSeconds: Double, skippedWithoutSpeech: Bool = false, completedAt: Date = Date()) {
        self.index = index; self.sourceStart = sourceStart; self.duration = duration; self.cues = cues; self.language = language
        self.channel = channel; self.elapsedSeconds = elapsedSeconds; self.skippedWithoutSpeech = skippedWithoutSpeech; self.completedAt = completedAt
    }
}

public struct TranscriptionCheckpointSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var key: TranscriptionCheckpointKey
    public var completedWindows: Int
    public var totalWindows: Int
    public var bytes: Int64
    public var updatedAt: Date
}

/// Disk store for completed windows. It never reads or writes a project document, so a checkpoint
/// cannot overwrite editing: results reach the timeline only through the editor's own
/// snapshot-guarded batch command.
public struct TranscriptionCheckpointStore: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("JHCutStudio/Checkpoints", isDirectory: true)
    }

    public func directory(for key: TranscriptionCheckpointKey) -> URL { root.appendingPathComponent(key.identifier, isDirectory: true) }
    private func manifestURL(_ key: TranscriptionCheckpointKey) -> URL { directory(for: key).appendingPathComponent("manifest.json") }
    private func windowURL(_ key: TranscriptionCheckpointKey, _ index: Int) -> URL {
        directory(for: key).appendingPathComponent(String(format: "window-%05d.json", index))
    }

    /// Completed windows whose manifest matches `key` exactly. A mismatched manifest (hash
    /// collision, hand-edited folder) or an unreadable window file is treated as absent and the
    /// window is recognised again; a damaged file is removed so it cannot shadow a fresh result.
    public func completedWindows(for key: TranscriptionCheckpointKey) -> [Int: TranscriptionWindowResult] {
        // Must mirror save(): windows are written with ISO-8601 dates.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: manifestURL(key)), let stored = try? decoder.decode(TranscriptionCheckpointKey.self, from: data), stored == key else { return [:] }
        var result: [Int: TranscriptionWindowResult] = [:]
        for index in 0..<key.windowCount {
            let url = windowURL(key, index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let bytes = try? Data(contentsOf: url), let window = try? decoder.decode(TranscriptionWindowResult.self, from: bytes),
                  window.index == index, window.cues.allSatisfy({ $0.duration > .zero && $0.start >= key.sourceStart && $0.start + $0.duration <= key.sourceStart + key.duration + MediaTime(1, 1) })
            else { try? FileManager.default.removeItem(at: url); continue }
            result[index] = window
        }
        return result
    }

    /// Atomic per window: a crash mid-write leaves either the previous state or the new file, never
    /// a truncated JSON that would later decode as a partial result.
    public func save(_ window: TranscriptionWindowResult, for key: TranscriptionCheckpointKey) throws {
        let folder = directory(for: key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if !FileManager.default.fileExists(atPath: manifestURL(key).path) {
            try encoder.encode(key).write(to: manifestURL(key), options: .atomic)
        }
        try encoder.encode(window).write(to: windowURL(key, window.index), options: .atomic)
    }

    /// The voice-activity analysis a run used, so a resumed run skips exactly the same audio.
    public func voiceActivity(for key: TranscriptionCheckpointKey) -> VoiceActivityReport? {
        let url = directory(for: key).appendingPathComponent("voice-activity.json")
        guard let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(VoiceActivityReport.self, from: data),
              report.version == VoiceActivityReport.version else { return nil }
        return report
    }
    public func saveVoiceActivity(_ report: VoiceActivityReport, for key: TranscriptionCheckpointKey) throws {
        let folder = directory(for: key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The manifest makes the folder visible to summaries and deletion even before any window finishes.
        if !FileManager.default.fileExists(atPath: manifestURL(key).path) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(key).write(to: manifestURL(key), options: .atomic)
        }
        try JSONEncoder().encode(report).write(to: folder.appendingPathComponent("voice-activity.json"), options: .atomic)
    }
    public func remove(_ key: TranscriptionCheckpointKey) throws {
        let folder = directory(for: key)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// Every stored checkpoint, newest first. Unreadable folders are skipped rather than reported
    /// as resumable.
    public func summaries(projectID: UUID? = nil, clipIDs: Set<UUID>? = nil) -> [TranscriptionCheckpointSummary] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return folders.compactMap { folder -> TranscriptionCheckpointSummary? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let key = try? decoder.decode(TranscriptionCheckpointKey.self, from: data), key.identifier == folder.lastPathComponent else { return nil }
            if let projectID, key.projectID != projectID { return nil }
            if let clipIDs, !clipIDs.contains(key.clipID) { return nil }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            let windows = files.filter { $0.lastPathComponent.hasPrefix("window-") }
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let updated = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
            return TranscriptionCheckpointSummary(id: key.identifier, key: key, completedWindows: min(windows.count, key.windowCount),
                                                  totalWindows: key.windowCount, bytes: bytes, updatedAt: updated)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func removeAll(projectID: UUID? = nil, clipIDs: Set<UUID>? = nil) throws -> Int {
        var removed = 0
        for summary in summaries(projectID: projectID, clipIDs: clipIDs) { try remove(summary.key); removed += 1 }
        return removed
    }
}

/// Resume bookkeeping handed to `transcribeLong`. `onWindowSaved` lets the editor surface a
/// failed checkpoint write without failing recognition: a checkpoint is a speed-up, never a
/// precondition for producing captions.
public struct TranscriptionCheckpointSession: Sendable {
    public let store: TranscriptionCheckpointStore
    public let key: TranscriptionCheckpointKey
    public init(store: TranscriptionCheckpointStore, key: TranscriptionCheckpointKey) { self.store = store; self.key = key }
}

/// Stat-validated media digest. The full SHA-256 is recomputed only when size, modification
/// date, inode, or the first/last 64KB change, so repeated runs on a multi-gigabyte original do
/// not re-hash it every time while a swapped file at the same path is still caught.
public actor MediaFingerprintCache {
    public static let shared = MediaFingerprintCache()
    private struct Entry: Codable { var stat: String; var sha256: String }
    private var entries: [String: Entry] = [:]
    private let persistURL: URL?
    public init(persistURL: URL? = nil) {
        self.persistURL = persistURL
        if let persistURL, let data = try? Data(contentsOf: persistURL), let stored = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = stored }
    }
    public func sha256(of url: URL) async throws -> String {
        let path = url.standardizedFileURL.path
        let stat = try Self.stat(url)
        if let cached = entries[path], cached.stat == stat { return cached.sha256 }
        let digest = try await FileIdentity.sha256(url)
        guard try Self.stat(url) == stat else { throw ProjectError("해시 계산 중 원본 파일이 바뀌었습니다. 파일 복사가 끝난 뒤 다시 실행하세요.") }
        entries[path] = Entry(stat: stat, sha256: digest)
        if entries.count > 512 { entries = entries.filter { $0.key == path } }
        if let persistURL {
            try? FileManager.default.createDirectory(at: persistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: persistURL, options: .atomic)
        }
        return digest
    }
    static func stat(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); hash.update(data: try file.read(upToCount: 65_536) ?? Data())
        try file.seek(toOffset: size > 65_536 ? size - 65_536 : 0); hash.update(data: try file.read(upToCount: 65_536) ?? Data())
        let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(a[.systemFileNumber] ?? "")|\(size)|\(modified)|\(hash.finalize().map { String(format: "%02x", $0) }.joined())"
    }
}

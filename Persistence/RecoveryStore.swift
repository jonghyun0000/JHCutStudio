import Foundation

public struct RecoverySnapshot: Codable, Equatable, Sendable {
    public var project: Project
    public var documentURL: URL?
    public var mediaBaseURL: URL?
    public var savedAt: Date
    public init(project: Project, documentURL: URL?, mediaBaseURL: URL?, savedAt: Date = Date()) {
        self.project = project; self.documentURL = documentURL; self.mediaBaseURL = mediaBaseURL; self.savedAt = savedAt
    }
}

/// One active recovery slot with a retained snapshot for each deferred project.
/// Saving it never writes the actual document or any source media.
public struct RecoveryStore {
    public let directory: URL
    public var snapshotURL: URL { directory.appendingPathComponent("current.json") }
    public var backupURL: URL { directory.appendingPathComponent("previous.json") }
    public var archiveDirectory: URL { directory.appendingPathComponent("Projects", isDirectory: true) }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/Recovery", isDirectory: true)
    }
    public func save(project: Project, documentURL: URL?, mediaBaseURL: URL?) throws {
        try ProjectValidator.validate(project)
        let snapshot = RecoverySnapshot(project: project, documentURL: documentURL, mediaBaseURL: mediaBaseURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            let previous = try Data(contentsOf: snapshotURL)
            do { try DocumentCompatibility.validate(previous, recovery: true) }
            catch let incompatible as ProjectError { throw incompatible }
            catch { /* A corrupt slot is handled below without replacing its last good backup. */ }
            // Preserve a good backup if the current autosave was externally damaged.
            if let decoded = try? JSONDecoder().decode(RecoverySnapshot.self, from: previous), (try? ProjectValidator.validate(decoded.project)) != nil {
                // An earlier damaged active slot may have left another project's only good
                // snapshot in previous.json. Retain that before rolling the backup forward.
                if let backupBytes = try? Data(contentsOf: backupURL), let backup = try? read(backupURL), backup.project.id != project.id {
                    try archive(backupBytes, snapshot: backup)
                }
                if decoded.project.id != project.id {
                    try archive(previous, snapshot: decoded)
                }
                try previous.write(to: backupURL, options: .atomic)
            }
        }
        try bytes.write(to: snapshotURL, options: .atomic)
    }
    public func load() throws -> RecoverySnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try read(snapshotURL)
    }
    /// The caller must explicitly choose the previous autosave; load() never hides corruption.
    public func loadPrevious() throws -> RecoverySnapshot? {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return nil }
        return try read(backupURL)
    }
    /// Discovery for an explicit recovery picker. Invalid files are not offered; if no valid
    /// snapshot exists but stored files are damaged, an error is reported instead of "empty".
    /// load() remains strict and never silently replaces the active snapshot with a backup.
    public func availableSnapshots() throws -> [RecoverySnapshot] {
        let urls = try snapshotURLs()
        var newest: [UUID: RecoverySnapshot] = [:]
        var failed = false
        for url in urls {
            do {
                let snapshot = try read(url)
                if let current = newest[snapshot.project.id], current.savedAt >= snapshot.savedAt { continue }
                newest[snapshot.project.id] = snapshot
            } catch { failed = true }
        }
        if newest.isEmpty, failed { throw ProjectError("저장된 복구본이 손상되어 읽을 수 없습니다.") }
        return newest.values.sorted { $0.savedAt > $1.savedAt }
    }
    public func clear(projectID: UUID) throws {
        for url in try snapshotURLs() {
            if let snapshot = try? read(url), snapshot.project.id == projectID {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func clear() throws {
        for url in try snapshotURLs() { try FileManager.default.removeItem(at: url) }
    }
    private func snapshotURLs() throws -> [URL] {
        var result = [snapshotURL, backupURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        if FileManager.default.fileExists(atPath: archiveDirectory.path) {
            result += try FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        }
        return result
    }
    private func archive(_ bytes: Data, snapshot: RecoverySnapshot) throws {
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let url = archiveDirectory.appendingPathComponent(snapshot.project.id.uuidString + ".json")
        // Preserve a newer retained snapshot if clocks changed or a stale slot was restored.
        if let archived = try? read(url), archived.savedAt > snapshot.savedAt { return }
        try bytes.write(to: url, options: .atomic)
    }
    private func read(_ url: URL) throws -> RecoverySnapshot {
        let bytes = try Data(contentsOf: url)
        try DocumentCompatibility.validate(bytes, recovery: true)
        let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: bytes)
        try ProjectValidator.validate(snapshot.project)
        return snapshot
    }
}

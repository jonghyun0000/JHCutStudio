import Foundation
import Darwin

public enum ProjectSavePhase: String, Sendable { case backupStaged, backupCommitted, legacyStaged, documentStaged, documentCommitted }
public enum RecoverySavePhase: String, Sendable { case previousStaged, previousCommitted, currentStaged, currentCommitted }

/// Complete staged bytes replace one document leaf through rename. A crash before rename leaves
/// the old leaf and an ignored private directory. This does not promise power-loss durability.
enum DocumentAtomicWrite {
    static func preserve(_ bytes: Data, at destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let workspace = try ExportWorkspace(parent: destination.deletingLastPathComponent(), id: UUID())
        defer { workspace.cleanup() }
        let staged = workspace.url.appendingPathComponent("original.json")
        try bytes.write(to: staged, options: .withoutOverwriting)
        try beforeCommit?()
        try ExclusivePublication.file(from: staged, to: destination)
    }
    static func replace(_ bytes: Data, at destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let workspace = try ExportWorkspace(parent: destination.deletingLastPathComponent(), id: UUID())
        defer { workspace.cleanup() }
        let staged = workspace.url.appendingPathComponent("document.json")
        try bytes.write(to: staged, options: .withoutOverwriting)
        let fd = open(staged.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ExclusivePublication.error(staged) }
        let synced = fsync(fd); let failure = errno; close(fd)
        guard synced == 0 else { throw ExclusivePublication.error(staged, failure) }
        try beforeCommit?()
        guard rename(staged.path, destination.path) == 0 else { throw ExclusivePublication.error(destination) }
        let parent = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }
}

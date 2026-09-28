import Foundation
import CryptoKit

/// User-initiated backups of a project document. A backup is a folder with the document, its
/// automatic `.backup` if present, and a manifest. Restoring never overwrites anything: it returns
/// the validated project, and the editor opens it as a new, unsaved document.
public enum ProjectBackup {
    public struct Manifest: Codable, Equatable, Sendable {
        public var documentName: String
        public var originalPath: String
        public var createdAt: Date
        public var appVersion: String
        public var sha256: String
        public var assetCount: Int
        /// Media are referenced, not copied; these paths must still exist when restoring.
        public var mediaPaths: [String]
    }
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { folder.path }
        public var folder: URL
        public var manifest: Manifest
    }

    public static var defaultRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
         ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio/ProjectBackups")
    }

    /// Copies the saved document (validated first) into a new timestamped folder under `root`.
    public static func create(documentURL: URL, root: URL = defaultRoot, appVersion: String) throws -> URL {
        let bytes = try Data(contentsOf: documentURL)
        try DocumentCompatibility.validate(bytes)
        let project = try JSONDecoder().decode(Project.self, from: bytes)
        try ProjectValidator.validate(project)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = documentURL.deletingPathExtension().lastPathComponent
        var folder = root.appendingPathComponent("\(name)-\(stamp)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = root.appendingPathComponent("\(name)-\(stamp)-\(n)", isDirectory: true); n += 1 }
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try bytes.write(to: staging.appendingPathComponent(documentURL.lastPathComponent))
            let automatic = ProjectStore.backupURL(for: documentURL)
            if FileManager.default.fileExists(atPath: automatic.path) { try FileManager.default.copyItem(at: automatic, to: staging.appendingPathComponent(automatic.lastPathComponent)) }
            let manifest = Manifest(documentName: documentURL.lastPathComponent, originalPath: documentURL.path, createdAt: Date(), appVersion: appVersion,
                                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), assetCount: project.assets.count,
                                    mediaPaths: project.assets.map { $0.resolvedURL(relativeTo: documentURL).path })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
            // The folder appears complete or not at all.
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
        return folder
    }

    public static func list(root: URL = defaultRoot) -> [Entry] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")), let manifest = try? decoder.decode(Manifest.self, from: data) else { return nil }
            return Entry(folder: folder, manifest: manifest)
        }.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Validates the backed-up document (digest, format, contents) and returns it with media paths
    /// resolved against the ORIGINAL location, so relative media references keep working.
    public static func restore(_ entry: Entry) throws -> Project {
        let document = entry.folder.appendingPathComponent(entry.manifest.documentName)
        let bytes = try Data(contentsOf: document)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == entry.manifest.sha256 else {
            throw ProjectError("백업 파일이 손상됐습니다(해시 불일치). 다른 백업을 선택하세요.")
        }
        try DocumentCompatibility.validate(bytes)
        var project = try JSONDecoder().decode(Project.self, from: bytes)
        try ProjectValidator.validate(project)
        let original = URL(fileURLWithPath: entry.manifest.originalPath)
        for index in project.assets.indices { project.assets[index].path = project.assets[index].resolvedURL(relativeTo: original).path }
        return project
    }

    /// Media referenced by a backup that no longer exist (media are never copied into backups).
    public static func missingMedia(_ entry: Entry) -> [String] { entry.manifest.mediaPaths.filter { !FileManager.default.fileExists(atPath: $0) } }
}

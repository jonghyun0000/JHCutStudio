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
        /// Optional numeric epoch retains subsecond precision without changing legacy ISO8601 decoding.
        public var createdAtEpoch: Double? = nil
        public var preciseCreatedAt: Date { createdAtEpoch.map(Date.init(timeIntervalSince1970:)) ?? createdAt }
        public var appVersion: String
        public var sha256: String
        public var assetCount: Int
        /// Media are referenced, not copied; these paths must still exist when restoring.
        public var mediaPaths: [String]
        public var contents: String?
        public var unsavedChangesPresent: Bool?
        public var mediaIncluded: Bool?
        public var automaticBackupSHA256: String?
        public var scopeSummary: String {
            "마지막 저장본 · " + (unsavedChangesPresent == true ? "미저장 변경 제외" : unsavedChangesPresent == false ? "미저장 변경 없음" : "미저장 변경 여부 기록 없음") + " · 원본 미디어 미포함"
        }
    }
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { folder.path }
        public var folder: URL
        public var manifest: Manifest
        public var pickerLabel: String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let identity = String(folder.lastPathComponent.suffix(8))
            return manifest.documentName + " · " + formatter.string(from: manifest.preciseCreatedAt) + " · " + identity + " · " + manifest.scopeSummary
        }
    }

    public static var defaultRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
         ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio/ProjectBackups")
    }

    /// Copies the saved document (validated first) into a new timestamped folder under `root`.
    public static func create(documentURL: URL, root: URL = defaultRoot, appVersion: String, unsavedChangesPresent: Bool? = nil) throws -> URL {
        let bytes = try Data(contentsOf: documentURL)
        try DocumentCompatibility.validate(bytes)
        let project = try JSONDecoder().decode(Project.self, from: bytes)
        try ProjectValidator.validate(project)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let publicationID = UUID(), workspace = try ExportWorkspace(parent: root, id: UUID()), createdAt = Date()
        defer { workspace.cleanup() }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = documentURL.deletingPathExtension().lastPathComponent
        let folder = root.appendingPathComponent("\(name) \(formatter.string(from: createdAt)) \(publicationID.uuidString)", isDirectory: true)
        try bytes.write(to: workspace.url.appendingPathComponent(documentURL.lastPathComponent), options: .withoutOverwriting)
        let automatic = ProjectStore.backupURL(for: documentURL)
        var automaticSHA: String?
        if FileManager.default.fileExists(atPath: automatic.path) {
            let prior = try Data(contentsOf: automatic)
            try DocumentCompatibility.validate(prior)
            try ProjectValidator.validate(JSONDecoder().decode(Project.self, from: prior))
            try prior.write(to: workspace.url.appendingPathComponent(automatic.lastPathComponent), options: .withoutOverwriting)
            automaticSHA = ExportDeliveryReceipt.digest(prior)
        }
        let manifest = Manifest(documentName: documentURL.lastPathComponent, originalPath: documentURL.path, createdAt: createdAt, createdAtEpoch: createdAt.timeIntervalSince1970, appVersion: appVersion,
                                sha256: ExportDeliveryReceipt.digest(bytes), assetCount: project.assets.count,
                                mediaPaths: project.assets.map { $0.resolvedURL(relativeTo: documentURL).path },
                                contents: "lastSavedDocument", unsavedChangesPresent: unsavedChangesPresent, mediaIncluded: false, automaticBackupSHA256: automaticSHA)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: workspace.url.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try ExclusivePublication.directory(from: workspace.url, to: folder, manifest: "manifest.json")
        return folder
    }

    public static func list(root: URL = defaultRoot) -> [Entry] { scan(root: root).entries }

    /// Damaged/incomplete visible bundles are counted, never advertised as valid recovery choices.
    public static func scan(root: URL = defaultRoot) -> (entries: [Entry], rejected: Int) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var entries: [Entry] = [], rejected = 0
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do {
                let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                let entry = Entry(folder: folder, manifest: manifest)
                _ = try restore(entry)
                entries.append(entry)
            } catch { rejected += 1 }
        }
        return (entries.sorted {
            if $0.manifest.preciseCreatedAt != $1.manifest.preciseCreatedAt { return $0.manifest.preciseCreatedAt > $1.manifest.preciseCreatedAt }
            return $0.id < $1.id
        }, rejected)
    }

    /// Validates the backed-up document (digest, format, contents) and returns it with media paths
    /// resolved against the ORIGINAL location, so relative media references keep working.
    public static func restore(_ entry: Entry) throws -> Project {
        guard entry.manifest.createdAtEpoch.map({ $0.isFinite }) ?? true else { throw ProjectError("백업 시각이 올바르지 않습니다.") }
        let leaf = entry.manifest.documentName
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/"), !leaf.contains("\\"), entry.manifest.mediaIncluded != true,
              entry.manifest.contents == nil || entry.manifest.contents == "lastSavedDocument" else { throw ProjectError("지원하지 않는 백업 형식입니다.") }
        let document = entry.folder.appendingPathComponent(leaf)
        let bytes = try Data(contentsOf: document)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == entry.manifest.sha256 else {
            throw ProjectError("백업 파일이 손상됐습니다(해시 불일치). 다른 백업을 선택하세요.")
        }
        if let expected = entry.manifest.automaticBackupSHA256 {
            let prior = try Data(contentsOf: entry.folder.appendingPathComponent(leaf + ".backup"))
            guard ExportDeliveryReceipt.digest(prior) == expected else { throw ProjectError("이전 저장본 백업이 손상되었습니다.") }
            try DocumentCompatibility.validate(prior)
            try ProjectValidator.validate(JSONDecoder().decode(Project.self, from: prior))
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

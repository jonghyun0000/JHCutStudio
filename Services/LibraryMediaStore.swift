import Foundation

/// Durable originals for inserted catalog items. Unlike the installed app or proxy cache,
/// this store is not replaced on upgrade and has no automatic eviction policy.
public actor LibraryMediaStore {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JHCutStudio/LibraryMedia", isDirectory: true)
    }

    public func retain(source: URL, item: LibraryAsset) async throws -> URL {
        try Task.checkCancellation()
        let digest = item.sha256.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw ProjectError("소재 검증값이 올바르지 않습니다.") }
        let ext = source.pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 12, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ProjectError("소재 파일 형식을 확인할 수 없습니다.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(digest + "." + ext)
        if fm.fileExists(atPath: destination.path) {
            try await verify(destination, sha256: item.sha256, fileBytes: item.fileBytes)
            return destination
        }
        let workspace = try ExportWorkspace(parent: directory, id: UUID())
        defer { workspace.cleanup() }
        let staged = workspace.url.appendingPathComponent("source." + ext)
        try fm.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        try await verify(staged, sha256: item.sha256, fileBytes: item.fileBytes)
        do { try ExclusivePublication.file(from: staged, to: destination) }
        catch {
            // A second importer may have published the same content while hashing suspended.
            guard fm.fileExists(atPath: destination.path) else { throw error }
            try await verify(destination, sha256: item.sha256, fileBytes: item.fileBytes)
        }
        try Task.checkCancellation()
        try await verify(destination, sha256: item.sha256, fileBytes: item.fileBytes)
        return destination
    }

    /// A prior catalog item may disappear from a newer app while its durable original remains.
    public func existing(sha256: String, fileExtension: String) async throws -> URL? {
        let digest = sha256.lowercased(), ext = fileExtension.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }), !ext.isEmpty, ext.count <= 12,
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw ProjectError("보관 소재의 검증값이나 형식이 올바르지 않습니다.") }
        let url = directory.appendingPathComponent(digest + "." + ext)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try await verify(url, sha256: digest)
        return url
    }

    private func verify(_ url: URL, sha256: String, fileBytes: Int64? = nil) async throws {
        let before = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard before.isRegularFile == true, before.isSymbolicLink != true,
              fileBytes.map({ $0 == Int64(before.fileSize ?? -1) }) ?? true else {
            throw ProjectError("보관한 소재 파일의 상태가 올바르지 않습니다. 기존 파일은 변경하지 않았습니다.")
        }
        let digest = try await FileIdentity.sha256(url)
        let after = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard digest == sha256.lowercased(), after.isRegularFile == true, after.isSymbolicLink != true,
              before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw ProjectError("보관한 소재가 원본 검증값과 다릅니다. 기존 파일은 변경하지 않았습니다.")
        }
    }
}

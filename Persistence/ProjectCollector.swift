import Foundation
import CryptoKit
import Darwin

public struct CollectedMediaRecord: Codable, Equatable, Sendable {
    public var assetID: UUID
    public var name: String
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int64
}
public struct ProjectCollectionManifest: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var projectID: UUID
    public var createdAt: Date
    public var media: [CollectedMediaRecord]
}

public enum ProjectCollector {
    /// `destination` must not exist. All project assets, including assets used only by derived
    /// sequences, are copied. A sibling staging directory is committed with an exclusive move
    /// where supported. ExFAT instead reserves a new directory and publishes Project.jhcut last;
    /// that folder can be visible while publishing, but no existing destination is overwritten.
    /// No originals, existing destination, or unrelated temporary files are ever overwritten.
    public static func collect(project: Project, documentURL: URL? = nil, to destination: URL) throws -> URL {
        try Task.checkCancellation()
        try ProjectValidator.validate(project)
        guard destination.isFileURL else { throw ProjectError("수집 위치는 로컬 폴더여야 합니다.") }
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { throw ProjectError("수집할 상위 폴더가 존재하지 않습니다.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProjectError("기존 폴더를 보호하기 위해 새 수집 폴더 이름을 선택하세요.") }
        let staging = parent.appendingPathComponent(".jhcut-collect-" + UUID().uuidString, isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: staging.path]) }
        defer { try? FileManager.default.removeItem(at: staging) }
        let mediaDirectory = staging.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: false)
        var portable = project
        var pathsByHash: [String: String] = [:]
        var records: [CollectedMediaRecord] = []
        for index in project.assets.indices {
            try Task.checkCancellation()
            let asset = project.assets[index]
            let referencedURL = asset.resolvedURL(relativeTo: documentURL)
            let scoped = referencedURL.startAccessingSecurityScopedResource()
            defer { if scoped { referencedURL.stopAccessingSecurityScopedResource() } }
            let source = referencedURL.resolvingSymlinksInPath()
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ProjectError("원본 미디어 파일을 읽을 수 없습니다: \(asset.name)") }
            let digest = try hash(source)
            if let provenance = asset.provenance, provenance.sha256.count == 64, provenance.sha256.lowercased() != digest {
                throw ProjectError("출처 체크섬과 실제 원본이 다릅니다: \(asset.name). 재연결 정보를 확인하세요.")
            }
            let relativePath: String
            if let existing = pathsByHash[digest] { relativePath = existing }
            else {
                let ext = source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                let filename = digest + (ext.isEmpty ? "" : "." + String(ext.prefix(12)))
                relativePath = "Media/" + filename
                let copy = staging.appendingPathComponent(relativePath)
                try copyFile(from: source, to: copy)
                guard try hash(copy) == digest else { throw ProjectError("복사 검증 중 파일 내용이 달라졌습니다: \(asset.name)") }
                pathsByHash[digest] = relativePath
            }
            portable.assets[index].path = destination.appendingPathComponent(relativePath).path
            portable.assets[index].relativePath = relativePath
            portable.assets[index].bookmark = nil
            records.append(CollectedMediaRecord(assetID: asset.id, name: asset.name, relativePath: relativePath, sha256: digest, byteCount: Int64(values.fileSize ?? 0)))
        }
        // Do not use ProjectStore.save here: it resolves live sources and would rebase against
        // staging. The document deliberately records its final folder and relative media paths.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(portable).write(to: staging.appendingPathComponent("Project.jhcut"), options: .atomic)
        let manifest = ProjectCollectionManifest(projectID: project.id, createdAt: Date(), media: records)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("Collection.json"), options: .atomic)
        try "JH CUT Studio collected project\nOpen Project.jhcut. Media contains full original files; Collection.json records verified SHA-256 values.\n".write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try ProjectValidator.validate(portable)
        try Task.checkCancellation()
        try publish(staging: staging, destination: destination)
        return destination.appendingPathComponent("Project.jhcut")
    }
    private static func hash(_ url: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hasher.update(data: bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func copyFile(from source: URL, to destination: URL) throws {
        let descriptor = open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError(destination.path) }
        defer { close(descriptor) }
        try copyFile(from: source, descriptor: descriptor)
    }
    /// Caller owns descriptor. Never reopen a just-created path: another process could
    /// replace it between exclusive creation and the subsequent open.
    private static func copyFile(from source: URL, descriptor: Int32) throws {
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var sourceHash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            sourceHash.update(data: bytes)
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        try output.seek(toOffset: 0)
        var copiedHash = SHA256()
        while let bytes = try output.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            copiedHash.update(data: bytes)
        }
        guard sourceHash.finalize() == copiedHash.finalize() else { throw ProjectError("복사한 파일의 SHA-256 검증에 실패했습니다: \(source.lastPathComponent)") }
    }
    private static func posixError(_ path: String, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    private static func publish(staging: URL, destination: URL) throws {
        if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let renameError = errno
        guard renameError == ENOTSUP else { throw posixError(destination.path, code: renameError) }
        try publishByExclusiveCopy(staging: staging, destination: destination)
    }

    /// ExFAT has neither RENAME_EXCL nor hard links. Reserve the destination with mkdirat;
    /// an exists-check followed by ordinary rename/moveItem would have a clobber race.
    /// All children are created exclusively through held directory descriptors. On failure,
    /// unlink only the exact entries we created, then rmdir (never recursive removal) so
    /// unrelated files added by another process survive. A crash may leave an incomplete folder.
    private static func publishByExclusiveCopy(staging: URL, destination: URL) throws {
        try Task.checkCancellation()
        let parentFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard parentFD >= 0 else { throw posixError(destination.path) }
        defer { close(parentFD) }
        let name = destination.lastPathComponent
        guard mkdirat(parentFD, name, 0o700) == 0 else { throw posixError(destination.path) }
        var rootIdentity = stat()
        guard fstatat(parentFD, name, &rootIdentity, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(destination.path) }
        let rootFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else {
            let failure = posixError(destination.path)
            if sameEntry(parentFD, name, identity: rootIdentity) { _ = unlinkat(parentFD, name, AT_REMOVEDIR) }
            throw failure
        }
        var directoryFDs: [Int32] = [rootFD]
        var entries: [(directory: Int32, name: String, identity: stat, flags: Int32)] = []
        var committed = false
        defer {
            if !committed {
                for entry in entries.reversed() where sameEntry(entry.directory, entry.name, identity: entry.identity) {
                    _ = unlinkat(entry.directory, entry.name, entry.flags)
                }
                if sameEntry(parentFD, name, identity: rootIdentity) { _ = unlinkat(parentFD, name, AT_REMOVEDIR) }
            }
            for descriptor in directoryFDs.reversed() { close(descriptor) }
        }
        guard mkdirat(rootFD, "Media", 0o700) == 0 else { throw posixError(destination.path + "/Media") }
        var mediaIdentity = stat()
        guard fstatat(rootFD, "Media", &mediaIdentity, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(destination.path + "/Media") }
        entries.append((rootFD, "Media", mediaIdentity, AT_REMOVEDIR))
        let mediaFD = openat(rootFD, "Media", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard mediaFD >= 0 else { throw posixError(destination.path + "/Media") }
        directoryFDs.append(mediaFD)
        let media = staging.appendingPathComponent("Media")
        let mediaNames = try FileManager.default.contentsOfDirectory(atPath: media.path).sorted()
        let files = mediaNames.map { (directory: mediaFD, name: $0, source: media.appendingPathComponent($0)) }
            + ["Collection.json", "README.txt", "Project.jhcut"].map { (directory: rootFD, name: $0, source: staging.appendingPathComponent($0)) }
        for file in files {
            try Task.checkCancellation()
            let descriptor = openat(file.directory, file.name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw posixError(destination.path + "/" + file.name) }
            var identity = stat()
            guard fstat(descriptor, &identity) == 0 else {
                let failure = posixError(destination.path + "/" + file.name)
                close(descriptor)
                throw failure
            }
            entries.append((file.directory, file.name, identity, 0))
            let entryIndex = entries.count - 1
            defer {
                // ExFAT assigns a temporary inode to empty files and changes it on first
                // allocation, visible only after sync/close. Sync then refresh through our
                // held fd even when copying is cancelled, before cleanup compares identities.
                _ = fsync(descriptor)
                var finalIdentity = stat()
                if fstat(descriptor, &finalIdentity) == 0 { entries[entryIndex].identity = finalIdentity }
                close(descriptor)
            }
            try copyFile(from: file.source, descriptor: descriptor)
        }
        try Task.checkCancellation()
        // Detect a renamed/replaced reservation instead of returning a path to unrelated data.
        guard sameEntry(parentFD, name, identity: rootIdentity), entries.allSatisfy({ sameEntry($0.directory, $0.name, identity: $0.identity) }) else { throw ProjectError("수집 중 목적지 폴더가 변경되었습니다.") }
        committed = true
    }
    private static func sameEntry(_ directory: Int32, _ name: String, identity: stat) -> Bool {
        var current = stat()
        return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0 && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
    }
}

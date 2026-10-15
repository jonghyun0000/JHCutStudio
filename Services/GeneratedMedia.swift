import Foundation
import Darwin

// MARK: - Generated media lifetime (step 16)
//
// Files the app writes from the user's media (freeze-frame stills, reversed copies, SDR copies, extracted
// audio, mixes) live in one folder next to nothing the user owns. Each gets a hidden sidecar that says what it
// is, which project and source made it, and its SHA-256. Cleanup is a *plan* the user confirms: only files that
// this project made, that match their record, and that no known document state refers to are offered, and they
// go to the Trash. Anything the app cannot vouch for (older files without a sidecar, other projects' files,
// changed bytes, unreadable references) is shown as uncertain and is never touched.

public enum GeneratedMediaPurpose: String, Codable, CaseIterable, Sendable {
    case freezeFrame, reversed, sdrCopy, audioExtract, mix
    public var label: String {
        switch self {
        case .freezeFrame: return "정지 화면"
        case .reversed: return "거꾸로 사본"
        case .sdrCopy: return "SDR 변환 사본"
        case .audioExtract: return "추출한 오디오"
        case .mix: return "완성 믹스"
        }
    }
}

public struct GeneratedMediaRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 2
    /// Monotonic retention flag: saved documents can be copied outside the app. Never clear automatically.
    public var publishedToDocument: Bool? = false
    public var fileName: String
    public var sha256: String
    public var byteCount: Int64
    public var purpose: GeneratedMediaPurpose
    public var projectID: UUID
    public var jobID: UUID
    public var sourceName: String?
    public var sourceSHA256: String?
    /// Source range the file was made from (seconds), when the purpose has one.
    public var sourceStart: Double?
    public var sourceDuration: Double?
    public var createdAt: Date
}

public enum GeneratedMediaRegistry {
    public static func sidecarURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".jhcut-generated.json")
    }

    /// Records a finished generated file. Call after the file is complete and before it is applied to the document.
    @discardableResult
    public static func register(file: URL, purpose: GeneratedMediaPurpose, projectID: UUID, jobID: UUID = UUID(),
                                sourceName: String? = nil, sourceSHA256: String? = nil,
                                sourceStart: Double? = nil, sourceDuration: Double? = nil) async throws -> GeneratedMediaRecord {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ProjectError("생성 파일을 기록할 수 없습니다: \(file.lastPathComponent)") }
        let digest = try await FileIdentity.sha256(file)
        let record = GeneratedMediaRecord(fileName: file.lastPathComponent, sha256: digest, byteCount: Int64(values.fileSize ?? 0), purpose: purpose,
                                          projectID: projectID, jobID: jobID, sourceName: sourceName, sourceSHA256: sourceSHA256,
                                          sourceStart: sourceStart, sourceDuration: sourceDuration, createdAt: Date())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: sidecarURL(for: file), options: .atomic)
        return record
    }

    public static func record(for file: URL) -> GeneratedMediaRecord? {
        guard let data = try? Data(contentsOf: sidecarURL(for: file)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(GeneratedMediaRecord.self, from: data), (record.schemaVersion == 1 || record.schemaVersion == 2), record.fileName == file.lastPathComponent else { return nil }
        return record
    }

    /// Must succeed before publishing any document that references a generated file.
    /// Legacy records remain uncertain; only the current format can advertise never-published files.
    public static func protectForSavedDocument(_ file: URL) throws {
        guard var record = record(for: file), record.schemaVersion == 2, record.publishedToDocument == false else { return }
        record.publishedToDocument = true
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try DocumentAtomicWrite.replace(try encoder.encode(record), at: sidecarURL(for: file))
    }

    /// Removes a file this process just made and its sidecar (failed or cancelled job). Never used on applied files.
    public static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: sidecarURL(for: file))
    }
}

/// Everything known to refer to files. `gaps` lists sources that could not be read; with any gap the answer
/// "unreferenced" is not trustworthy, so nothing becomes removable.
public struct GeneratedMediaReferences: Sendable {
    public var paths: Set<String> = []
    public var gaps: [String] = []
    public init() {}
    public static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    public mutating func add(_ url: URL) { paths.insert(Self.canonical(url)) }
    public mutating func add(assets: [MediaAsset], documentURL: URL?) {
        for asset in assets {
            add(asset.resolvedURL(relativeTo: documentURL))
            if !asset.path.isEmpty { add(URL(fileURLWithPath: asset.path)) }
        }
    }
    /// Reads asset paths straight from a saved document's JSON, so a schema this build does not know still counts.
    public mutating func add(documentAt url: URL, label: String, mediaBaseURL: URL? = nil) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { gaps.append("\(label)을(를) 읽을 수 없습니다."); return }
        for asset in assets {
            let hasRelative = (asset["relativePath"] as? String).map { !$0.isEmpty } ?? false
            let hasAbsolute = (asset["path"] as? String).map { $0.hasPrefix("/") } ?? false
            guard hasRelative || hasAbsolute else { gaps.append("\(label)의 미디어 경로를 확인할 수 없습니다."); continue }
            if let relative = asset["relativePath"] as? String, !relative.isEmpty {
                add((mediaBaseURL ?? url).deletingLastPathComponent().appendingPathComponent(relative))
            }
            if let path = asset["path"] as? String, !path.isEmpty { add(URL(fileURLWithPath: path)) }
        }
    }
}

public enum GeneratedMediaState: Equatable, Sendable {
    /// Used by the open document, Undo/Redo, the saved file, a recovery copy or a backup.
    case inUse(String)
    /// Made by this project, bytes unchanged, referenced by nothing known. Offered for the Trash after confirmation.
    case removable
    /// The app cannot vouch for it (no record, other project, changed bytes, unreadable references).
    case uncertain(String)
}

public struct GeneratedMediaItem: Equatable, Sendable {
    public var url: URL
    public var byteCount: Int64
    public var record: GeneratedMediaRecord?
    public var state: GeneratedMediaState
}

public struct GeneratedMediaReport: Sendable {
    public var folder: URL
    public var items: [GeneratedMediaItem]
    public var inUse: [GeneratedMediaItem] { items.filter { if case .inUse = $0.state { return true }; return false } }
    public var removable: [GeneratedMediaItem] { items.filter { $0.state == .removable } }
    public var uncertain: [GeneratedMediaItem] { items.filter { if case .uncertain = $0.state { return true }; return false } }
    public func bytes(of items: [GeneratedMediaItem]) -> Int64 { items.reduce(0) { $0 + $1.byteCount } }
    public var summary: String {
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return "사용 중 \(inUse.count)개 · 정리 가능 \(removable.count)개(\(size(bytes(of: removable)))) · 확인 불가 \(uncertain.count)개(\(size(bytes(of: uncertain))))"
    }
}

public enum GeneratedMediaCleanup {
    private struct FileSnapshot: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }
    private static func snapshot(_ url: URL) -> FileSnapshot? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return FileSnapshot(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
    public static func scan(folder: URL, projectID: UUID, references: GeneratedMediaReferences) async throws -> GeneratedMediaReport {
        guard FileManager.default.fileExists(atPath: folder.path) else { return GeneratedMediaReport(folder: folder, items: []) }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        var items: [GeneratedMediaItem] = []
        for name in names {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let record = GeneratedMediaRegistry.record(for: url)
            if references.paths.contains(GeneratedMediaReferences.canonical(url)) {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .inUse("문서 또는 되돌리기·복구·백업이 사용 중")))
                continue
            }
            guard let record else {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: nil, state: .uncertain("만든 기록이 없는 파일(이전 버전 또는 다른 앱)")))
                continue
            }
            guard record.projectID == projectID else {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .uncertain("다른 프로젝트에서 만든 파일")))
                continue
            }
            guard record.schemaVersion == 2, let published = record.publishedToDocument else {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .uncertain("이전 버전의 저장 이력을 확인할 수 없는 파일")))
                continue
            }
            if published {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .inUse("저장 문서에 포함된 파일 · 다른 복사본을 위해 보호")))
                continue
            }
            guard references.gaps.isEmpty else {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .uncertain("참조를 모두 확인하지 못함: " + references.gaps.joined(separator: " "))))
                continue
            }
            let digest = try await FileIdentity.sha256(url)
            guard digest == record.sha256, size == record.byteCount else {
                items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .uncertain("만든 뒤 내용이 바뀐 파일")))
                continue
            }
            items.append(GeneratedMediaItem(url: url, byteCount: size, record: record, state: .removable))
        }
        return GeneratedMediaReport(folder: folder, items: items)
    }

    public struct Removal: Sendable {
        public var removed: [URL] = []
        public var skipped: [(URL, String)] = []
        public var freedBytes: Int64 = 0
    }

    /// Rechecks content and then live references immediately before each Trash mutation.
    /// The references closure can reject a stale document/job. No suspension occurs between that
    /// final check and Trash. The async barrier and Trash function support isolated race probes.
    @MainActor
    public static func remove(_ requested: [GeneratedMediaItem], folder: URL, projectID: UUID,
                              references: @MainActor () throws -> GeneratedMediaReferences,
                              beforeRevalidation: (@MainActor () async throws -> Void)? = nil,
                              trash: @MainActor (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async throws -> Removal {
        let fresh = try await scan(folder: folder, projectID: projectID, references: references())
        let allowed = Dictionary(uniqueKeysWithValues: fresh.removable.map { ($0.url.path, $0) })
        var result = Removal()
        for item in requested {
            try Task.checkCancellation()
            guard let current = allowed[item.url.path] else { result.skipped.append((item.url, "그 사이 다시 사용 중이거나 확인할 수 없게 되어 건너뜀")); continue }
            guard let initialFile = snapshot(current.url) else {
                result.skipped.append((item.url, "삭제 직전 파일 상태를 확인할 수 없어 건너뜀")); continue
            }
            try await beforeRevalidation?()
            try Task.checkCancellation()
            // A folder-wide scan may finish long before this item. Verify its bytes again,
            // and reject replacement, symlink substitution, or writes while verification suspends.
            guard snapshot(current.url) == initialFile else {
                result.skipped.append((item.url, "확인 중 파일 상태가 바뀌어 건너뜀")); continue
            }
            let finalDigest: String
            do { finalDigest = try await FileIdentity.sha256(current.url) }
            catch is CancellationError { throw CancellationError() }
            catch { result.skipped.append((item.url, "삭제 직전 파일을 읽을 수 없어 건너뜀")); continue }
            guard snapshot(current.url) == initialFile, initialFile.size == current.byteCount,
                  finalDigest == current.record?.sha256 else {
                result.skipped.append((item.url, "확인 중 파일 내용이나 위치가 바뀌어 건너뜀")); continue
            }
            // Hashing suspends. Read live references only after that work, then keep the final
            // reference decision and synchronous Trash mutation in the same MainActor turn.
            let latest = try references()
            guard latest.gaps.isEmpty, !latest.paths.contains(GeneratedMediaReferences.canonical(current.url)) else {
                result.skipped.append((item.url, "삭제 직전 다시 사용 중이거나 참조를 확인할 수 없어 건너뜀")); continue
            }
            try Task.checkCancellation()
            guard let finalRecord = GeneratedMediaRegistry.record(for: current.url), finalRecord == current.record,
                  finalRecord.schemaVersion == 2, finalRecord.publishedToDocument == false,
                  snapshot(current.url) == initialFile else {
                result.skipped.append((item.url, "삭제 직전 저장 이력 또는 생성 기록이 바뀌어 건너뜀")); continue
            }
            do {
                try trash(current.url)
                let sidecar = GeneratedMediaRegistry.sidecarURL(for: current.url)
                if FileManager.default.fileExists(atPath: sidecar.path) { try? trash(sidecar) }
                result.removed.append(current.url); result.freedBytes += current.byteCount
            } catch { result.skipped.append((item.url, error.localizedDescription)) }
        }
        return result
    }
}

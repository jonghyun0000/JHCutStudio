import Foundation

public enum FolderRelinking {
    /// Automatic matches require identical bytes. Old projects without a fingerprint stay manual.
    public static func replacements(for assets: [MediaAsset], folder: URL) async throws -> [MediaAsset] {
        let worker = Task.detached(priority: .utility) { () throws -> [String: [URL]] in
            var files: [String: [URL]] = [:]
            guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw ProjectError("선택한 폴더를 읽을 수 없습니다.") }
            for case let url as URL in entries {
                try Task.checkCancellation()
                let flags = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if flags.isRegularFile == true, flags.isSymbolicLink != true { files[url.lastPathComponent, default: []].append(url) }
            }
            return files
        }
        let files = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        var hashes: [URL: String] = [:], replacements: [MediaAsset] = []
        for original in assets {
            try Task.checkCancellation()
            guard let expected = original.contentHash ?? original.provenance?.sha256, !expected.isEmpty else { continue }
            for url in files[URL(fileURLWithPath: original.path).lastPathComponent] ?? [] {
                let hash: String
                if let cached = hashes[url] { hash = cached } else { hash = try await FileIdentity.sha256(url); hashes[url] = hash }
                guard hash == expected.lowercased() else { continue }
                var replacement = try await MediaImporter.inspect(url: url)
                guard replacement.kind == original.kind, replacement.supported else { continue }
                replacement.id = original.id; replacement.contentHash = hash; replacement.relativePath = nil
                replacement.name = original.name; replacement.provenance = original.provenance
                replacements.append(replacement); break
            }
        }
        return replacements
    }
}

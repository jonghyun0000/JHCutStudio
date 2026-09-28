import Foundation
import CryptoKit

/// Preview-only metadata cache. Export defaults to fresh inspection, and files are re-statted each lookup.
public actor InspectionCache {
    public static let shared = InspectionCache()
    private struct Cached { let key: String; let asset: MediaAsset }
    private var entries: [String: Cached] = [:]
    public func inspect(_ url: URL) async throws -> MediaAsset {
        let key = try fingerprint(url), path = url.standardizedFileURL.path
        if let cached = entries[path], cached.key == key { return cached.asset }
        let asset = try await MediaImporter.inspect(url: url)
        guard key == (try fingerprint(url)) else { throw MediaEngineError.failed("검사 중 원본 파일이 바뀌었습니다.") }
        if entries.count >= 256 { entries.removeAll(keepingCapacity: true) }
        entries[path] = Cached(key: key, asset: asset)
        return asset
    }
    public func removeAll() { entries.removeAll() }
    private func fingerprint(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        var hash = SHA256(); hash.update(data: try file.read(upToCount: 4096) ?? Data())
        try file.seek(toOffset: size > 4096 ? size - 4096 : 0); hash.update(data: try file.read(upToCount: 4096) ?? Data())
        return "\(a[.systemFileNumber] ?? "")|\(size)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((a[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(hash.finalize())"
    }
}

import Foundation
import CryptoKit
public enum FileIdentity {
    public static func sha256(_ url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) { () throws -> String in
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            var hash = SHA256()
            // Each read returns an autoreleased buffer; without a pool per chunk they pile up until
            // the task ends (measured: 2.4 GB peak while hashing a 2.8 GB iPhone video).
            while true {
                try Task.checkCancellation()
                let more = try autoreleasepool { () throws -> Bool in
                    guard let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty else { return false }
                    hash.update(data: bytes); return true
                }
                if !more { break }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

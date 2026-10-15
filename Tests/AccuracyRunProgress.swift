import Foundation

/// A local receipt for the helper's outcome, including errors before the final summary.
/// It contains no transcript text; partial summary/caption files remain separate.
final class AccuracyRunProgress {
    struct Receipt: Codable {
        var schemaVersion = 1
        var status = "running"
        var phase = "workspace"
        var segmentID: String?
        var mode: String?
        var trial: Int?
        var plannedRecords = 24
        var completedRecords = 0
        var assertionCount = 0
        var assertionFailures = 0
        var errorDomain: String?
        var errorCode: Int?
        var errorDescription: String?
        var updatedAt = Date()
    }

    private(set) var receipt = Receipt()
    private(set) var root: URL?

    func attach(_ root: URL) throws {
        // The folder can hold real speech/reference evidence; only this user may read it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        self.root = root
        try persist()
    }

    func advance(_ phase: String, segmentID: String? = nil, mode: String? = nil,
                 trial: Int? = nil, completedRecords: Int? = nil,
                 assertionCount: Int? = nil, assertionFailures: Int? = nil) throws {
        receipt.phase = phase
        receipt.segmentID = segmentID
        receipt.mode = mode
        receipt.trial = trial
        if let completedRecords { receipt.completedRecords = completedRecords }
        if let assertionCount { receipt.assertionCount = assertionCount }
        if let assertionFailures { receipt.assertionFailures = assertionFailures }
        try persist()
    }

    func finish(assertionCount: Int, assertionFailures: Int, completedRecords: Int) throws {
        receipt.assertionCount = assertionCount
        receipt.assertionFailures = assertionFailures
        receipt.completedRecords = completedRecords
        // A short/partial run must not become successful merely because no assertion failed.
        receipt.status = assertionFailures == 0 && completedRecords == receipt.plannedRecords ? "completed" : "failed"
        receipt.phase = "finished"
        receipt.segmentID = nil; receipt.mode = nil; receipt.trial = nil
        try persist()
    }

    func updateCounts(completedRecords: Int? = nil, assertionCount: Int, assertionFailures: Int) {
        if let completedRecords { receipt.completedRecords = completedRecords }
        receipt.assertionCount = assertionCount
        receipt.assertionFailures = assertionFailures
    }

    func fail(_ error: Error) throws {
        let detail = error as NSError
        receipt.status = error is CancellationError ? "cancelled" : "failed"
        receipt.errorDomain = detail.domain
        receipt.errorCode = detail.code
        // Error text is bounded and remains in this private output folder, not stdout.
        receipt.errorDescription = String(detail.localizedDescription.prefix(4096))
        try persist()
    }

    private func persist() throws {
        guard let root else { return } // Workspace rejection must never modify the rejected path.
        receipt.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent("run-status.json")
        try encoder.encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

import Foundation
import Darwin

@main struct AccuracyFailureProbe {
    static func main() async throws {
        let root = try ProbeWorkspace.prepare(defaultPath: "AccuracyFailure")
        // Permission behavior must be tested on the user's POSIX temporary volume,
        // even when the repository and archived evidence live on ExFAT.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("JHCut-AccuracyFailure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var rows: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) {
            rows.append(["name": name, "passed": value])
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func receipt(_ folder: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("run-status.json"))) as! [String: Any]
        }
        func folder(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let partial = try folder("partial-trial")
        let summary = Data("[{\"synthetic\":true,\"completedTrial\":1}]\n".utf8)
        try summary.write(to: partial.appendingPathComponent("summary.json"))
        let state = AccuracyRunProgress()
        try state.attach(partial)
        try state.advance("recognizing", segmentID: "synthetic-segment", mode: "full", trial: 2,
                          completedRecords: 3, assertionCount: 11, assertionFailures: 0)
        try state.fail(NSError(domain: "SyntheticMissingOutput", code: 260,
                               userInfo: [NSLocalizedDescriptionKey: String(repeating: "x", count: 5000)]))
        let saved = try receipt(partial)
        check("Missing output remains failed despite zero failed assertions", saved["status"] as? String == "failed" && saved["assertionFailures"] as? Int == 0)
        check("Failure identifies exact segment mode and trial", saved["phase"] as? String == "recognizing" && saved["segmentID"] as? String == "synthetic-segment" && saved["mode"] as? String == "full" && saved["trial"] as? Int == 2)
        check("Partial completion retains 3 of 24 records", saved["completedRecords"] as? Int == 3 && saved["plannedRecords"] as? Int == 24)
        check("Structured failure retains domain and code", saved["errorDomain"] as? String == "SyntheticMissingOutput" && saved["errorCode"] as? Int == 260)
        check("Local failure description is bounded", (saved["errorDescription"] as? String)?.count == 4096)
        check("Previous successful trial bytes survive failure", try Data(contentsOf: partial.appendingPathComponent("summary.json")) == summary)
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: partial.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: partial.appendingPathComponent("run-status.json").path)[.posixPermissions] as? NSNumber)?.intValue
        check("Private trial directory and receipt permissions on POSIX scratch", directoryMode == 0o700 && fileMode == 0o600)
        let permissionEvidence: [String: Any] = [
            "scope": "Original scratch files before copying to evidence volume; copied modes are not a permission guarantee",
            "volumeFormat": (try scratch.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey])).volumeLocalizedFormatDescription ?? "unknown",
            "directoryMode": directoryMode ?? -1, "receiptMode": fileMode ?? -1
        ]
        try JSONSerialization.data(withJSONObject: permissionEvidence, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("permission-evidence.json"))

        let incomplete = AccuracyRunProgress(); try incomplete.attach(folder("incomplete"))
        try incomplete.finish(assertionCount: 11, assertionFailures: 0, completedRecords: 3)
        check("A partial clean assertion set cannot become completed", incomplete.receipt.status == "failed")
        let cancelled = AccuracyRunProgress(); try cancelled.attach(folder("cancelled"))
        try cancelled.advance("recognizing", segmentID: "synthetic", mode: "full", trial: 1)
        try cancelled.fail(CancellationError())
        check("Cancellation is distinct from successful completion", cancelled.receipt.status == "cancelled" && cancelled.receipt.phase == "recognizing")
        let complete = AccuracyRunProgress(); try complete.attach(folder("complete"))
        try complete.finish(assertionCount: 101, assertionFailures: 0, completedRecords: 24)
        check("Full successful run has explicit completion", complete.receipt.status == "completed")
        let assertions = AccuracyRunProgress(); try assertions.attach(folder("failed-assertion"))
        try assertions.finish(assertionCount: 101, assertionFailures: 1, completedRecords: 24)
        check("Full run with a failed assertion remains failed", assertions.receipt.status == "failed")

        let build = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JHCUT_BUILD_DIR"] ?? "Build")
        let executable = build.appendingPathComponent("RealAccuracyProbe")
        func launch(_ output: URL, name: String) async throws -> (Int32, Process.TerminationReason, String, Bool) {
            let log = root.appendingPathComponent(name + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process(); process.executableURL = executable; process.arguments = [output.path]
            var env = ProcessInfo.processInfo.environment
            env["JHCUT_ACCURACY_LANGUAGE"] = "unsupported-test-language"
            env["JHCUT_ACCURACY_CHANNEL"] = "-1"
            env.removeValue(forKey: "JHCUT_ACCURACY_BASELINE")
            process.environment = env; process.standardOutput = handle; process.standardError = handle
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                try await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try handle.synchronize()
            return (process.terminationStatus, process.terminationReason, try String(contentsOf: log), timedOut)
        }
        let invalid = root.appendingPathComponent("real-helper-invalid-config")
        let run = try await launch(invalid, name: "invalid-config")
        check("Actual real helper exits 1 normally instead of SIGTRAP", !run.3 && run.0 == 1 && run.1 == .exit)
        let actual = try receipt(invalid)
        check("Actual helper stores configuration failure before model or ASR work", actual["status"] as? String == "failed" && actual["phase"] as? String == "configuration" && actual["completedRecords"] as? Int == 0)
        check("Actual failure emits no successful summary or fatal runtime trap", run.2.contains("REAL_ACCURACY_FAILED") && !run.2.contains("REAL_ACCURACY_RESULT") && !run.2.contains("Fatal error"))
        let protected = try folder("protected-existing-output")
        let sentinel = Data("keep existing evidence".utf8)
        try sentinel.write(to: protected.appendingPathComponent("sentinel"))
        let rejected = try await launch(protected, name: "rejected-workspace")
        check("Rejected workspace also exits without a fatal trap", !rejected.3 && rejected.0 == 1 && rejected.1 == .exit)
        check("Rejected workspace is untouched by failure receipt", try Data(contentsOf: protected.appendingPathComponent("sentinel")) == sentinel && FileManager.default.contentsOfDirectory(atPath: protected.path) == ["sentinel"])

        // These are synthetic receipts and sentinels, never private recordings.
        try FileManager.default.copyItem(at: scratch, to: root.appendingPathComponent("SyntheticReceipts"))
        try FileManager.default.removeItem(at: scratch)
        check("Owned temporary scratch is removed", !FileManager.default.fileExists(atPath: scratch.path))
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
        print("ACCURACY_FAILURE_RESULT checks=\(rows.count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

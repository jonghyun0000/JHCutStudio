import Foundation
import AVFoundation
import CryptoKit
import Darwin
@testable import JHCutCore

/// Controlled subprocess failures exercise the production output contract without a model,
/// network request, private recording, or a real Whisper invocation.
@main struct TranscriptionOutputProbe {
    static func main() async {
        setbuf(stdout, nil)
        var rows: [[String: Any]] = []
        var root: URL?
        func check(_ name: String, _ passed: Bool) {
            rows.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        do {
            let outputRoot = try ProbeWorkspace.prepare(defaultPath: "Artifacts/TranscriptionOutput")
            root = outputRoot
            let fm = FileManager.default
            // Run FIFO and permissions checks on the user's native temporary filesystem. An
            // external ExFAT result directory cannot represent these POSIX contracts.
            let temporaryRoot = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let workspace = temporaryRoot.appendingPathComponent("JHCutTranscriptionOutput-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer {
                do {
                    guard workspace.deletingLastPathComponent() == temporaryRoot,
                          workspace.lastPathComponent.hasPrefix("JHCutTranscriptionOutput-") else { throw NSError(domain: "UnsafeProbeCleanup", code: 1) }
                    try fm.removeItem(at: workspace)
                    check("Owned temporary fixtures including FIFO are removed", !fm.fileExists(atPath: workspace.path))
                } catch { check("Owned temporary fixtures including FIFO are removed", false) }
            }
            let fixtures = workspace.appendingPathComponent("Fixtures"), diagnostics = workspace.appendingPathComponent("Diagnostics")
            try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
            let secret = "SYNTHETIC_PRIVATE_CAPTION_8127"
            let ordinary = "1\n00:00:00,000 --> 00:00:01,000\n\(secret)\n"
            func write(_ name: String, _ srt: Data, _ segments: [[String: Any]]) throws {
                try srt.write(to: fixtures.appendingPathComponent(name + ".srt"))
                let json: [String: Any] = ["result": ["language": "en"], "transcription": segments]
                try JSONSerialization.data(withJSONObject: json).write(to: fixtures.appendingPathComponent(name + ".json"))
            }
            func segment(_ from: Int, _ to: Int, _ text: String) -> [String: Any] { ["offsets": ["from": from, "to": to], "text": text] }
            try write("valid", Data(ordinary.utf8), [segment(0, 1_000, secret)])
            try write("empty", Data(), [])
            try write("zero", Data((ordinary + "\n2\n00:00:01,000 --> 00:00:01,000\nsecond\n").utf8), [segment(0, 1_000, secret), segment(1_000, 1_000, "second")])
            try write("short", Data("1\n00:00:00,000 --> 00:00:00,100\nHello\n".utf8), [segment(0, 100, "Hello")])
            var brokenSRT = Data("1\n00:00:00,000 --> 00:00:01,000\nHello ".utf8); brokenSRT.append(contentsOf: [0xED, 0x95]); brokenSRT.append(Data("\n".utf8))
            try brokenSRT.write(to: fixtures.appendingPathComponent("utf8.srt"))
            var brokenJSON = Data(#"{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":1000},"text":"Hello "#.utf8)
            brokenJSON.append(contentsOf: [0xED, 0x95]); brokenJSON.append(Data(#""}]}"#.utf8))
            try brokenJSON.write(to: fixtures.appendingPathComponent("utf8.json"))
            let runtime = workspace.appendingPathComponent("fake-whisper.sh")
            try #"""
            #!/bin/bash
            set -eu
            fixture_root="$(cd "$(dirname "$0")" && pwd)/Fixtures"
            mode="$1"
            if [[ "$mode" == '-m' ]]; then
              mode=short
              while [[ $# -gt 0 ]]; do
                case "$1" in -of) prefix="$2";; --prompt) mode="$2";; esac
                shift
              done
              pwd > "$fixture_root/last-workspace.txt"
            else prefix="$2"; fi
            printf '%s\n' 'SYNTHETIC_PRIVATE_CAPTION_8127 /private/source.mov --prompt private-words' >&2
            printf '%s\n' 'error: failed to read audio file /private/source.mov' >&2
            printf '%s\n' 'open: failed to open /private/transcript.srt for writing' >&2
            case "$mode" in
              valid|empty|zero|utf8|short)
                cp "$fixture_root/$mode.srt" "$prefix.srt"
                cp "$fixture_root/$mode.json" "$prefix.json";;
              srtMissing) cp "$fixture_root/valid.json" "$prefix.json";;
              jsonMissing) cp "$fixture_root/valid.srt" "$prefix.srt";;
              jsonCorrupt)
                cp "$fixture_root/valid.srt" "$prefix.srt"
                printf '%s' '{"result":{"language":"en"},broken' > "$prefix.json";;
              jsonShape)
                cp "$fixture_root/valid.srt" "$prefix.srt"
                printf '%s' '{"result":{"language":"en"}}' > "$prefix.json";;
              invalidOffsets)
                cp "$fixture_root/valid.srt" "$prefix.srt"
                printf '%s' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":true,"to":1000},"text":"SYNTHETIC_PRIVATE_CAPTION_8127"}]}' > "$prefix.json";;
              srtCorrupt)
                cp "$fixture_root/valid.json" "$prefix.json"
                printf '%s' 'not a subtitle' > "$prefix.srt";;
              truncated)
                cp "$fixture_root/valid.srt" "$prefix.srt"
                cp "$fixture_root/zero.json" "$prefix.json";;
              emptyMismatch)
                : > "$prefix.srt"
                cp "$fixture_root/valid.json" "$prefix.json";;
              reversed)
                cp "$fixture_root/valid.json" "$prefix.json"
                printf '1\n00:00:02,000 --> 00:00:01,000\ntext\n' > "$prefix.srt";;
              symlink)
                ln -s "$fixture_root/valid.srt" "$prefix.srt"
                cp "$fixture_root/valid.json" "$prefix.json";;
              fifo)
                mkfifo "$prefix.srt"
                cp "$fixture_root/valid.json" "$prefix.json";;
              directory)
                cp "$fixture_root/valid.srt" "$prefix.srt"
                mkdir "$prefix.json";;
              oversized)
                cp "$fixture_root/valid.srt" "$prefix.srt"
                /usr/sbin/mkfile -n 16777217 "$prefix.json";;
              exit7) exit 7;;
              signal) kill -KILL $$;;
              sleep) printf '%s' "$$" > "$prefix.ready"; exec /bin/sleep 20;;
              *) exit 99;;
            esac
            """#.write(to: runtime, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

            func recognize(_ mode: String, timeout: Double? = nil, diagnosticRoot: URL? = nil) async throws -> WhisperOutputContract.Output {
                let dir = workspace.appendingPathComponent(mode + "-" + UUID().uuidString)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return try await WhisperOutputContract.recognize(executable: runtime,
                    arguments: [mode, dir.appendingPathComponent("output").path, secret], directory: dir,
                    prefix: dir.appendingPathComponent("output"), timeout: timeout,
                    diagnosticDirectory: diagnosticRoot ?? diagnostics, progress: nil)
            }
            let valid = try await recognize("valid")
            check("Valid complete outputs return exact caption and language", valid.language == "en" && valid.cues.count == 1 && valid.cues[0].text == secret && valid.cues[0].duration == MediaTime(1, 1))
            let empty = try await recognize("empty")
            check("Existing empty SRT and valid zero-segment JSON succeed", empty.cues.isEmpty && empty.language == "en")
            let zero = try await recognize("zero")
            check("Matching zero-duration segment keeps established text folding", zero.cues.count == 1 && zero.cues[0].text == secret + " second")
            let utf8 = try await recognize("utf8")
            check("Matching incomplete UTF8 remains repairable", utf8.cues.count == 1 && utf8.cues[0].text == "Hello")

            var savedErrors: [WhisperTranscriptionError] = []
            for (mode, expected) in [("srtMissing", WhisperTranscriptionError.Code.srtMissing), ("jsonMissing", .jsonMissing),
                ("jsonCorrupt", .jsonInvalid), ("jsonShape", .jsonInvalid), ("invalidOffsets", .jsonInvalid),
                ("srtCorrupt", .srtInvalid), ("truncated", .outputMismatch), ("emptyMismatch", .outputMismatch),
                ("reversed", .srtInvalid), ("symlink", .srtUnreadable), ("fifo", .srtUnreadable),
                ("directory", .jsonUnreadable), ("oversized", .jsonUnreadable), ("exit7", .processFailed), ("signal", .processFailed)] {
                let started = Date()
                do { _ = try await recognize(mode); check("\(mode) rejects incomplete recognition", false) }
                catch let issue as WhisperTranscriptionError {
                    check("\(mode) rejects incomplete recognition", issue.code == expected && issue.diagnosticSaved && Date().timeIntervalSince(started) < 5)
                    check("\(mode) public error contains no private text or path", !issue.localizedDescription.contains(secret) && !String(describing: issue).contains("/private/") && !String(describing: issue).contains(workspace.path))
                    savedErrors.append(issue)
                }
            }
            do {
                _ = try await WhisperOutputContract.recognize(executable: workspace.appendingPathComponent("missing-runtime"), arguments: [secret], directory: workspace,
                    prefix: workspace.appendingPathComponent("missing"), diagnosticDirectory: diagnostics, progress: nil)
                check("Launch failure remains structured", false)
            } catch let issue as WhisperTranscriptionError { check("Launch failure remains structured", issue.code == .launchFailed && issue.diagnosticSaved); savedErrors.append(issue) }
            let timeoutStarted = Date()
            do { _ = try await recognize("sleep", timeout: 0.1); check("Timeout rejects instead of returning empty", false) }
            catch let issue as WhisperTranscriptionError { check("Timeout rejects instead of returning empty", issue.code == .timedOut && Date().timeIntervalSince(timeoutStarted) < 3); savedErrors.append(issue) }

            let cancelDirectory = workspace.appendingPathComponent("Cancel")
            try fm.createDirectory(at: cancelDirectory, withIntermediateDirectories: true)
            let cancelPrefix = cancelDirectory.appendingPathComponent("output")
            let task = Task { try await WhisperOutputContract.recognize(executable: runtime, arguments: ["sleep", cancelPrefix.path], directory: cancelDirectory,
                prefix: cancelPrefix, diagnosticDirectory: diagnostics, progress: nil) }
            for _ in 0..<100 { if fm.fileExists(atPath: cancelPrefix.appendingPathExtension("ready").path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let pid = Int32((try String(contentsOf: cancelPrefix.appendingPathExtension("ready"))).trimmingCharacters(in: .whitespacesAndNewlines))!
            task.cancel()
            do { _ = try await task.value; check("Cancellation propagates without partial success", false) }
            catch is CancellationError { check("Cancellation propagates without partial success", true) }
            check("Cancelled owned subprocess has terminated", kill(pid, 0) == -1 && errno == ESRCH)

            // Full service integration: an extracted WAV reaches the same contract; a failure
            // receipt survives the production workspace cleanup. The input is synthetic silence.
            let audio = workspace.appendingPathComponent("synthetic.wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            do { let file = try AVAudioFile(forWriting: audio, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!; buffer.frameLength = 8_000
                memset(buffer.floatChannelData![0], 0, 8_000 * MemoryLayout<Float>.size); try file.write(from: buffer) }
            let model = workspace.appendingPathComponent("fixture-model.bin"), modelBytes = Data([1])
            try modelBytes.write(to: model)
            let sha = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
            let spec = WhisperModelSpec(name: "controlled fixture", fileName: "fixture-model.bin", downloadURL: URL(string: "https://example.invalid/unused")!, byteCount: 1,
                sha256: sha, license: "test fixture", licenseURL: URL(string: "https://example.invalid/unused")!, recommendedFreeBytes: 1)
            var options = SpeechOptions(); options.language = "en"; options.languageRepairEnabled = false
            let config = WhisperConfiguration(runtimeURL: runtime, modelURL: model, modelSpec: spec)
            let before = try Data(contentsOf: audio)
            let success = try await LocalTranscription.transcribe(url: audio, sourceStart: MediaTime(1, 10), duration: MediaTime(2, 10), configuration: config,
                options: options, verifyModel: true, diagnosticDirectory: diagnostics, progress: nil)
            check("Production extraction maps validated output to source time", success.cues.count == 1 && success.cues[0].start == MediaTime(1, 10) && success.cues[0].duration == MediaTime(1, 10))
            options.glossary = "srtMissing"
            do {
                _ = try await LocalTranscription.transcribe(url: audio, sourceStart: .zero, duration: MediaTime(2, 10), configuration: config,
                    options: options, verifyModel: true, diagnosticDirectory: diagnostics, progress: nil)
                check("Production service reports missing output", false)
            } catch let issue as WhisperTranscriptionError { check("Production service reports missing output", issue.code == .srtMissing && issue.diagnosticSaved); savedErrors.append(issue) }
            let removedWorkspace = try String(contentsOf: fixtures.appendingPathComponent("last-workspace.txt")).trimmingCharacters(in: .whitespacesAndNewlines)
            check("Production temporary audio workspace is removed after failure", !fm.fileExists(atPath: removedWorkspace))
            check("Synthetic original is unchanged after success and failure", try Data(contentsOf: audio) == before)

            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var receipts: [WhisperOutputContract.Diagnostic] = []
            let evidence = outputRoot.appendingPathComponent("DiagnosticEvidence")
            try fm.createDirectory(at: evidence, withIntermediateDirectories: false)
            var provenance: [[String: Any]] = []
            for issue in savedErrors {
                let file = diagnostics.appendingPathComponent("transcription-\(issue.diagnosticID.uuidString).json")
                let data = try Data(contentsOf: file), text = String(decoding: data, as: UTF8.self)
                let receipt = try decoder.decode(WhisperOutputContract.Diagnostic.self, from: data); receipts.append(receipt)
                let permissions = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                check("Private diagnostic keeps status and redacts all supplied private content", receipt.code == issue.code && !receipt.rawStderrRetained && !text.contains(secret) && !text.contains("/private/") && !text.contains(workspace.path) && !text.contains("private-words") && permissions?.intValue == 0o600)
                // Only JSON bytes are copied, never a recursive copy of runtime fixtures,
                // symlinks or FIFO outputs. The destination volume's mode is not evidence of
                // the original file's permissions; capture the verified mode before cleanup.
                let destination = evidence.appendingPathComponent(file.lastPathComponent)
                try data.write(to: destination, options: .withoutOverwriting)
                provenance.append(["file": file.lastPathComponent, "diagnosticID": issue.diagnosticID.uuidString,
                    "sourcePermissions": permissions?.intValue ?? -1,
                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    "copyMatches": try Data(contentsOf: destination) == data])
            }
            let directoryMode = try fm.attributesOfItem(atPath: diagnostics.path)[.posixPermissions] as? NSNumber
            check("Diagnostic directory is owner only", directoryMode?.intValue == 0o700)
            let volume = try workspace.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription ?? "unavailable"
            let modeEvidence: [String: Any] = ["schemaVersion": 1, "scratchLocation": "ownedUserTemporaryDirectory", "sourceFilesystem": volume,
                "sourceDirectoryPermissions": directoryMode?.intValue ?? -1, "copiedFileModesAreNotSourceEvidence": true, "files": provenance]
            try JSONSerialization.data(withJSONObject: modeEvidence, options: [.prettyPrinted, .sortedKeys]).write(to: outputRoot.appendingPathComponent("diagnostic-mode-provenance.json"), options: .withoutOverwriting)
            check("Exit zero with missing SRT retains real process status", receipts.contains { $0.code == .srtMissing && $0.processStatus == 0 && $0.terminationReason == .exit && $0.srt?.kind == "missing" && $0.json?.kind == "regular" })
            check("Diagnostic tail retains known input and output failure categories", receipts.contains { $0.stderrTail.contains("inputAudioReadFailed") && $0.stderrTail.contains("outputOpenFailed") })
            check("Nonzero status and signal reason remain distinct", receipts.contains { $0.processStatus == 7 && $0.terminationReason == .exit } && receipts.contains { $0.terminationReason == .uncaughtSignal })
            check("Timeout receipt remains distinct from ordinary nonzero exit", receipts.contains { $0.timedOut && $0.code == .timedOut })
            check("Failure receipt captured extracted WAV metadata before cleanup", receipts.contains { $0.code == .srtMissing && $0.extractedAudio.kind == "regular" && ($0.extractedAudio.bytes ?? 0) > 44 })
            check("Diagnostic text is bounded without retaining raw content", WhisperOutputContract.diagnosticTail(String(repeating: secret + "\n", count: 100_000)).count < 2_048)
            let blocked = workspace.appendingPathComponent("blocked-diagnostics"); try Data([1]).write(to: blocked)
            do { _ = try await recognize("srtMissing", diagnosticRoot: blocked); check("Diagnostic write failure preserves recognition failure", false) }
            catch let issue as WhisperTranscriptionError { check("Diagnostic write failure preserves recognition failure", issue.code == .srtMissing && !issue.diagnosticSaved) }
            // Discover, rather than assume, whether the result volume enforces exact Unix file
            // modes. ExFAT must fail diagnostic persistence without claiming private storage.
            let capabilityFile = outputRoot.appendingPathComponent("permission-capability-" + UUID().uuidString)
            let capabilityFD = open(capabilityFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard capabilityFD >= 0 else { throw NSError(domain: "PermissionCapabilityProbe", code: 1) }
            var capabilityInfo = stat()
            let permissionSupported = fchmod(capabilityFD, 0o600) == 0 && fstat(capabilityFD, &capabilityInfo) == 0 && capabilityInfo.st_mode & 0o777 == 0o600
            close(capabilityFD); try fm.removeItem(at: capabilityFile)
            let volumeDiagnostics = outputRoot.appendingPathComponent("VolumeDiagnosticCheck")
            do { _ = try await recognize("srtMissing", diagnosticRoot: volumeDiagnostics); check("Diagnostic persistence obeys actual volume permissions", false) }
            catch let issue as WhisperTranscriptionError {
                let entries = try fm.contentsOfDirectory(at: volumeDiagnostics, includingPropertiesForKeys: nil)
                check("Diagnostic persistence obeys actual volume permissions", issue.code == .srtMissing && issue.diagnosticSaved == permissionSupported && (permissionSupported ? entries.count == 1 : entries.isEmpty))
                let capability: [String: Any] = ["schemaVersion": 1, "exactFileMode0600Supported": permissionSupported,
                    "diagnosticSaved": issue.diagnosticSaved, "remainingReceiptFiles": entries.count,
                    "failedPermissionLeavesNoReceipt": permissionSupported || entries.isEmpty]
                try JSONSerialization.data(withJSONObject: capability, options: [.prettyPrinted, .sortedKeys]).write(to: outputRoot.appendingPathComponent("output-volume-permission-check.json"), options: .withoutOverwriting)
            }
            check("Old output-validation checkpoints are invalidated", LocalTranscription.pipelineVersion.hasSuffix("pipeline 9"))

            // Persist a valid current-policy window and a legacy native-runtime window. The
            // latter has a valid key-bound envelope, so rejection cannot be a checksum accident.
            let runtimeCache = TranscriptionCheckpointStore(root: workspace.appendingPathComponent("RuntimePolicyCache"))
            let currentRuntimeKey = TranscriptionCheckpointKey(projectID: UUID(), clipID: UUID(),
                mediaSHA256: String(repeating: "a", count: 64), sourceStart: .zero, duration: MediaTime(seconds: 30),
                windowSeconds: 30, options: SpeechOptions(), modelSHA256: String(repeating: "b", count: 64), skipsSilence: true)
            var completedRuntimeWindow = TranscriptionWindowResult(index: 0, sourceStart: .zero,
                duration: MediaTime(seconds: 30), cues: [], language: "", channel: 0, elapsedSeconds: 0, skippedWithoutSpeech: true)
            completedRuntimeWindow.inputSignature = String(repeating: "c", count: 64)
            try runtimeCache.save(completedRuntimeWindow, for: currentRuntimeKey)
            check("Current runtime policy checkpoint remains reusable", currentRuntimeKey.isReusable && runtimeCache.completedWindows(for: currentRuntimeKey).count == 1)
            var legacyRuntimeKey = currentRuntimeKey
            legacyRuntimeKey.engine = "whisper.cpp v1.9.4 · pipeline 9"
            let legacyDirectory = runtimeCache.directory(for: legacyRuntimeKey)
            try fm.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            let legacyManifest = legacyDirectory.appendingPathComponent("manifest.json")
            let legacyWindow = legacyDirectory.appendingPathComponent("window-00000.json")
            let legacyManifestBytes = try RecognitionCacheSafety.encoder().encode(legacyRuntimeKey)
            let legacyWindowBytes = try RecognitionCacheEnvelope.encode(completedRuntimeWindow, key: legacyRuntimeKey, maximum: RecognitionCacheSafety.windowBytes)
            try legacyManifestBytes.write(to: legacyManifest)
            try legacyWindowBytes.write(to: legacyWindow)
            check("Legacy native runtime identity is valid but cannot be reused", legacyRuntimeKey.isValid && !legacyRuntimeKey.isReusable && legacyRuntimeKey.identifier != currentRuntimeKey.identifier)
            check("Persisted legacy runtime windows are ignored while current windows survive", runtimeCache.completedWindows(for: legacyRuntimeKey).isEmpty && runtimeCache.completedWindows(for: currentRuntimeKey).count == 1)
            do {
                let legacyLease = try runtimeCache.beginSession(for: legacyRuntimeKey)
                check("Legacy runtime checkpoint cannot acquire a recognition lease", false)
                _ = legacyLease
            } catch { check("Legacy runtime checkpoint cannot acquire a recognition lease", true) }
            let retainedLegacyManifest = try Data(contentsOf: legacyManifest)
            let retainedLegacyWindow = try Data(contentsOf: legacyWindow)
            check("Refusing a legacy runtime checkpoint preserves its original files", retainedLegacyManifest == legacyManifestBytes && retainedLegacyWindow == legacyWindowBytes)

        } catch {
            // NSError descriptions from arbitrary I/O may contain private paths; publish type only.
            check("Unexpected probe error: \(String(reflecting: type(of: error)))", false)
        }
        if let root { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let failed = rows.filter { $0["passed"] as? Bool == false }.count
        print("TRANSCRIPTION_OUTPUT_RESULT checks=\(rows.count) failures=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

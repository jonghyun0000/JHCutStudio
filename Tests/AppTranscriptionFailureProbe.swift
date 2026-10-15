import Foundation
import AppKit
import AVFoundation
import Darwin
import JHCutCore

/// Calls the production editor command with a controlled child process. This verifies editor
/// state recovery, not recognition accuracy or native pointer/keyboard interactions.
@main struct AppTranscriptionFailureProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let output = try ProbeWorkspace.prepare(defaultPath: "Artifacts/AppTranscriptionFailure")
        let fm = FileManager.default
        let previousDirectory = fm.currentDirectoryPath
        let scratch = fm.temporaryDirectory.appendingPathComponent("JHCut-AppTranscription-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { _ = fm.changeCurrentDirectoryPath(previousDirectory); try? fm.removeItem(at: scratch) }
        let runtimeDirectory = scratch.appendingPathComponent("Resources/Whisper", isDirectory: true)
        try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let runtime = runtimeDirectory.appendingPathComponent("whisper-cli")
        let script = #"""
        #!/bin/bash
        set -eu
        control="$(cd "$(dirname "$0")/../.." && pwd)"
        mode="$(cat "$control/mode")"
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == -of ]]; then prefix="$2"; fi
          shift
        done
        pwd > "$control/last-workspace"
        printf '%s\n' 'SYNTHETIC_PRIVATE_EDITOR_TEXT /private/fixture.mov --prompt private-editor-words' >&2
        if [[ "$mode" == batch ]]; then
          if [[ -f "$control/first-finished" ]]; then mode=missing; else mode=valid; : > "$control/first-finished"; fi
        fi
        if [[ "$mode" == nonzero ]]; then exit 7; fi
        if [[ "$mode" == missing ]]; then exit 0; fi
        printf '1\n00:00:00,000 --> 00:00:00,300\n새 테스트 자막\n' > "$prefix.srt"
        if [[ "$mode" == corrupt ]]; then
          printf '%s' '{invalid' > "$prefix.json"
        else
          printf '%s' '{"result":{"language":"ko"},"transcription":[{"offsets":{"from":0,"to":300},"text":"새 테스트 자막"}]}' > "$prefix.json"
        fi
        """#
        try script.write(to: runtime, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        guard fm.changeCurrentDirectoryPath(scratch.path), WhisperConfiguration().runtimeURL.standardizedFileURL == runtime.standardizedFileURL else {
            throw ProjectError("Controlled editor runtime was not selected; real recognition was not started.")
        }
        let audio = scratch.appendingPathComponent("generated-silence.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            memset(buffer.floatChannelData![0], 0, 16_000 * MemoryLayout<Float>.size)
            try file.write(from: buffer)
        }
        let asset = try await MediaImporter.inspect(url: audio)
        let audioBytes = try Data(contentsOf: audio)
        var project = Project(name: "자막 실패 시 편집 보존")
        project.assets = [asset]
        let first = Clip(name: "첫 대사", assetID: asset.id, start: MediaTime(1, 1), duration: MediaTime(1, 2))
        let second = Clip(name: "둘째 대사", assetID: asset.id, start: MediaTime(2, 1), duration: MediaTime(1, 2))
        let audioIndex = project.sequence.tracks.firstIndex { $0.kind == .audio }!
        let titleIndex = project.sequence.tracks.firstIndex { $0.kind == .title }!
        project.sequence.tracks[audioIndex].clips = [first, second]
        var title = TitlePreset.builtIns[0].title
        title.text = "수정해 둔 기존 자막"
        var original = CaptionEditing.automaticClips(cues: [CaptionCue(start: .zero, duration: MediaTime(3, 10), text: title.text)], source: first, style: title)[0]
        original.captionRole = .original; original.captionGroupID = UUID()
        original.captionMetadata = CaptionMetadata(language: "ko", originalLanguage: "ko", originalText: title.text, generatedText: "이전 자동 인식")
        let translated = try CaptionTranslationEditing.translated(original, text: "An existing translation", sourceLanguage: "ko", targetLanguage: "en", bilingual: false)
        project.sequence.tracks[titleIndex].clips = [original, translated]
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            rows.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        func makeModel(_ name: String) -> EditorModel {
            let model = EditorModel(recoveryStore: RecoveryStore(directory: output.appendingPathComponent(name + "-recovery")),
                                    exportHistoryURL: output.appendingPathComponent(name + "-journal.json"),
                                    proxyCache: ProxyCache(directory: output.appendingPathComponent(name + "-proxy")))
            model.history = EditorHistory(project: project)
            model.selectedClipID = first.id; model.selectedClipIDs = [first.id, second.id]
            model.skipNonSpeech = false; model.useSpeechCheckpoints = false
            model.translateAfterTranscription = false; model.replaceAutomaticCaptions = true
            model.speechOptions.language = "ko"; model.speechOptions.languageRepairEnabled = false
            model.checkpointStore = TranscriptionCheckpointStore(root: output.appendingPathComponent(name + "-checkpoints"))
            return model
        }
        var failedEditor: EditorModel?
        for mode in ["missing", "corrupt", "nonzero", "batch"] {
            try mode.write(to: scratch.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let model = makeModel(mode)
            check("\(mode): installed model and controlled runtime are ready", model.transcriptionReady)
            model.transcribeSelection()
            check("\(mode): production editor command starts", model.transcriptionActive && model.productivityBusy)
            await model.productivityTask?.value
            check("\(mode): existing original translation and document remain exact", model.project == project)
            check("\(mode): failed batch adds no undo history", !model.history.canUndo && !model.history.canRedo)
            check("\(mode): busy flags and job identity recover", !model.productivityBusy && !model.transcriptionActive && model.transcriptionJobID == nil && model.transcriptionDetail == nil && model.productivityJobID == nil)
            check("\(mode): failure is visible and not marked complete", model.error != nil && model.transcriptionProgress == nil && model.productivityStatus.contains("실패"))
            let error = model.error ?? ""
            check("\(mode): public error redacts stderr and private paths", !error.contains("SYNTHETIC_PRIVATE_EDITOR_TEXT") && !error.contains("/private/") && !error.contains("private-editor-words") && !error.contains(scratch.path))
            let workspace = try String(contentsOf: scratch.appendingPathComponent("last-workspace")).trimmingCharacters(in: .whitespacesAndNewlines)
            check("\(mode): recognition audio workspace was cleaned", !fm.fileExists(atPath: workspace))
            if mode == "batch" {
                check("A successful first source followed by failure is not partially applied", fm.fileExists(atPath: scratch.appendingPathComponent("first-finished").path) && model.project == project)
                failedEditor = model
            }
        }
        try "valid".write(to: scratch.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let retry = failedEditor!
        retry.transcribeSelection(); await retry.productivityTask?.value
        for _ in 0..<1000 { if !retry.isBuilding { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check("A new attempt after failure completes normally", retry.error == nil && retry.transcriptionProgress == 1 && !retry.productivityBusy && !retry.transcriptionActive)
        let after = retry.project
        check("Successful retry preserves the manually corrected caption", after.sequence.tracks.flatMap(\.clips).contains { $0.id == original.id && $0.title?.text == title.text })
        retry.undo(); check("Successful retry is one undo back to the exact original document", retry.project == project)
        retry.redo(); check("Redo restores the successful retry", retry.project == after)
        for _ in 0..<1000 { if !retry.isBuilding { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check("Editor rebuild after retry and undo redo settles", !retry.isBuilding)
        retry.pausePlayback(); retry.player.replaceCurrentItem(with: nil)
        check("Controlled tests leave the generated source unchanged", try Data(contentsOf: audio) == audioBytes)
        _ = fm.changeCurrentDirectoryPath(previousDirectory)
        try fm.removeItem(at: scratch)
        check("Owned controlled runtime and fixtures are removed", !fm.fileExists(atPath: scratch.path))
        let failures = rows.filter { $0["passed"] as? Bool == false }.count
        try JSONSerialization.data(withJSONObject: ["scope": "Actual EditorModel command and LocalTranscription service; controlled subprocess outputs, generated silence and installed model identity; no real speech accuracy or native UI claim", "checks": rows], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("checks.json"))
        print("APP_TRANSCRIPTION_FAILURE_RESULT checks=\(rows.count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

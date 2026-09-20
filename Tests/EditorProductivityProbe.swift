#if PRODUCTIVITY_APP_PROBE
import Foundation
import AppKit
import JHCutCore

@main struct EditorProductivityProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Productivity-App-0.3", isDirectory: true)
        var results: [[String: Any]] = []
        func check(_ name: String, _ value: Bool, _ detail: String = "") { results.append(["name": name, "passed": value, "detail": detail]); print("\(value ? "PASS" : "FAIL") \(name) \(detail)") }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Artifacts/Productivity-0.3/오디오 분석 원본.wav")
        do {
            guard FileManager.default.isReadableFile(atPath: fixture.path) else { throw ProjectError("Run test-productivity.sh first") }
            let model = EditorModel()
            var project = Project(name: "Headless productivity probe")
            let asset = MediaAsset(name: "PCM fixture", path: fixture.path, kind: .audio, duration: MediaTime(seconds: 6), hasAudio: true)
            let clip = Clip(name: "Trim at 2x", assetID: asset.id, start: MediaTime(seconds: 5), sourceStart: MediaTime(seconds: 0.75), duration: MediaTime(seconds: 0.625), playbackRate: PlaybackRate(numerator: 2))
            project.assets = [asset]; project.sequence.tracks[3].clips = [clip]
            model.history = EditorHistory(project: project); model.selectedClipID = clip.id
            check("Selected audio resolved", model.selectedSound?.2.id == asset.id)
            model.analyzeSound(); await model.productivityTask?.value
            check("Editor passes actual source offset and rate-adjusted duration", model.audioResult?.frameCount == 60_000 && model.audioResult?.sourceStart == clip.sourceStart && model.audioResult?.duration == MediaTime(seconds: 1.25))
            check("Completed analysis matches selection snapshot", model.analysisMatchesSelection && !model.productivityBusy && model.productivityTask == nil)
            if let region = model.audioResult?.silenceRegions.first {
                model.seekSilence(region)
                let expected = ((clip.start.seconds + (region.start.seconds - clip.sourceStart.seconds) / 2) * 30).rounded() / 30
                check("Silence seek remaps source offset and 2x rate", abs(model.playhead - expected) < 0.00001, "\(model.playhead)")
            } else { check("Silence seek remaps source offset and 2x rate", false, "No silence returned") }
            var edited = project; edited.sequence.tracks[3].clips[0].volume = 0.5
            model.history = EditorHistory(project: edited)
            check("Clip mutation invalidates stale analysis", !model.analysisMatchesSelection)
            edited = project; edited.assets[0].path += ".changed"
            model.history = EditorHistory(project: edited)
            check("Relink invalidates stale analysis", !model.analysisMatchesSelection)
            edited = project; edited.id = UUID(); model.history = EditorHistory(project: edited)
            check("Another project invalidates stale analysis", !model.analysisMatchesSelection)
            model.history = EditorHistory(project: project); model.analyzeSound(); model.cancelProductivity(); await model.productivityTask?.value
            check("Editor cancellation clears busy state and result", !model.productivityBusy && model.audioResult == nil && model.productivityTask == nil)
            let snapshot = model.project; model.transcriptionReady = false; model.transcribeSelection()
            check("Unavailable transcription does not mutate project", model.project == snapshot && !model.productivityBusy)
            // No perform/undo/save calls: this probe never schedules or modifies the user's recovery store.
        } catch { check("Probe execution", false, error.localizedDescription) }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("editor-checks.json"))
        } catch { print(error); exit(2) }
        exit(results.allSatisfy { ($0["passed"] as? Bool) == true } ? 0 : 1)
    }
}
#endif

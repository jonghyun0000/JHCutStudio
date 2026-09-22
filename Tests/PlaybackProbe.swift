#if PLAYBACK_PROBE
import Foundation
import AppKit
import AVFoundation
import JHCutCore

@main struct PlaybackProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Playback-Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("playback-source.mp4")
        if !FileManager.default.fileExists(atPath: source.path) {
            try await Fixtures.video(to: source, scene: 2, color: CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1), frames: 180)
        }
        let asset = try await MediaImporter.inspect(url: source)
        var project = Project(name: "Playback regression")
        project.assets = [asset]
        project.sequence.tracks[0].clips = [Clip(name: "Playback", assetID: asset.id, start: .zero, duration: MediaTime(seconds: 6))]
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("probe-recovery")))
        model.history = EditorHistory(project: project)
        model.savedData = nil
        model.rebuild()
        for _ in 0..<1000 {
            if !model.isBuilding && model.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var rows: [[String: Any]] = []
        func check(_ name: String, _ result: Bool, _ detail: String = "") {
            rows.append(["name": name, "passed": result, "detail": detail]); print("\(result ? "PASS" : "FAIL") \(name) \(detail)")
        }
        check("Playable composition ready", model.plan != nil && model.player.currentItem?.status == .readyToPlay)
        check("Dirty cache notices document replacement", model.dirty)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 900_000_000)
        check("Native player advances", model.player.currentTime().seconds > 0.2, "time=\(model.player.currentTime().seconds)")
        model.togglePlay()
        let paused = model.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 500_000_000)
        check("Mid-video pause holds position", !model.playing && model.player.rate == 0 && abs(model.player.currentTime().seconds - paused) < 0.04 && paused > 0.2)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 500_000_000)
        check("Resume continues at paused position", model.playing && model.player.currentTime().seconds > paused + 0.15)
        model.pausePlayback()
        // Model a pending play request with a zero instantaneous rate, as occurs during buffering.
        model.playing = true
        try await Task.sleep(nanoseconds: 150_000_000)
        check("Clock does not erase pending play intent", model.playing)
        model.togglePlay()
        check("Toggle cancels pending playback at zero rate", !model.playing && model.player.rate == 0)
        model.playing = true; model.isBuilding = true
        model.togglePlay()
        check("Pause has priority over build guard", !model.playing && model.player.rate == 0)
        model.isBuilding = false
        model.seek(5.7); model.togglePlay()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        check("End of media clears play intent", !model.playing && model.player.rate == 0)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 500_000_000)
        check("Replay after end starts from beginning", model.playing && model.player.currentTime().seconds < 2)
        model.pausePlayback()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        model.savedData = try encoder.encode(model.project)
        check("Saved document cache is clean", !model.dirty)
        var edited = project; edited.name = "Changed"
        model.history = EditorHistory(project: edited)
        check("Dirty cache invalidates after edit", model.dirty)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: root.appendingPathComponent("playback-checks.json"))
        if rows.contains(where: { ($0["passed"] as? Bool) != true }) { exit(1) }
    }
}
#endif

import Foundation
import AppKit
import AVFoundation
import Darwin
import JHCutCore

@main struct PlaybackObservationGuardProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/PlaybackObservationGuard")
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            rows.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)")
        }
        // Deterministic policy inputs cover waiting independently from requested-play and rate.
        // These are not a claim that the generated local file entered real buffering.
        let states: [(String, Bool, Float, AVPlayer.TimeControlStatus)] = [
            ("paused", false, 0, .paused), ("pending", true, 0, .paused),
            ("forward-rate", false, 1, .playing), ("reverse-rate", false, -1, .playing),
            ("waiting-with-zero-rate-and-no-model-intent", false, 0, .waitingToPlayAtSpecifiedRate)
        ]
        for mode in [PlaybackObservationMode.transport, .trackPostEffects] {
            for hasTaps in [false, true] {
                for (state, requested, rate, status) in states {
                    let expected: Bool
                    if state == "paused" { expected = false }
                    else if mode == .transport && !hasTaps { expected = false }
                    else { expected = true }
                    check("Policy \(mode.rawValue) taps=\(hasTaps) \(state)",
                          EditorModel.playbackObservationChangeRequiresPause(mode: mode, hasActiveAudioTaps: hasTaps,
                              playRequested: requested, rate: rate, timeControlStatus: status) == expected)
                }
            }
        }
        let video = root.appendingPathComponent("generated-video.mp4")
        let audio = root.appendingPathComponent("generated-tone.wav")
        try await Fixtures.video(to: video, scene: 2, color: CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1), frames: 180)
        try Fixtures.audio(to: audio, seconds: 6)
        let videoAsset = try await MediaImporter.inspect(url: video)
        let audioAsset = try await MediaImporter.inspect(url: audio)
        var project = Project(name: "Observation mode guard")
        project.assets = [videoAsset, audioAsset]
        project.sequence.tracks[0].clips = [Clip(name: "Video", assetID: videoAsset.id, duration: MediaTime(seconds: 6))]
        project.sequence.tracks[3].clips = [Clip(name: "Tone", assetID: audioAsset.id, duration: MediaTime(seconds: 6))]
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("recovery")),
                                exportHistoryURL: root.appendingPathComponent("journal.json"),
                                proxyCache: ProxyCache(directory: root.appendingPathComponent("proxy")))
        model.history = EditorHistory(project: project); model.rebuild()
        for _ in 0..<1000 {
            if !model.isBuilding && model.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let item = model.player.currentItem, item.status == .readyToPlay, model.plan != nil else {
            throw ProjectError("Generated guard fixture did not become ready")
        }
        defer { model.pausePlayback(); model.playbackObservation?.stop(); model.player.replaceCurrentItem(with: nil) }
        let originalMix = item.audioMix
        model.startPlaybackObservation()
        check("Default transport leaves original audio mix", model.playbackObservation?.mode == .transport && item.audioMix === originalMix)
        let transport = model.playbackObservation
        model.playing = true // Deterministic zero-rate pending play intent.
        check("Menu policy permits harmless transport replacement during pending playback", !model.playbackObservationChangeRequiresPause())
        model.startPlaybackObservation()
        check("Pending transport replacement preserves play intent and mix", model.playing && model.player.rate == 0 && model.playbackObservation !== transport && item.audioMix === originalMix)
        let pendingTransport = model.playbackObservation
        model.error = nil; model.startPlaybackObservation(mode: .trackPostEffects)
        check("Pending transport cannot insert audio taps", model.playbackObservation === pendingTransport && model.playing && item.audioMix === originalMix && model.error?.contains("재생을 멈춘 뒤") == true)
        model.pausePlayback(); model.error = nil; model.startPlaybackObservation(mode: .trackPostEffects)
        let detailed = model.playbackObservation, detailedMix = item.audioMix
        check("Paused detailed mode installs and owns taps", detailed?.hasActiveAudioTaps == true && (detailed?.attachedAudioTaps ?? 0) > 0 && detailedMix !== originalMix)
        model.playing = true
        check("Menu policy blocks pending detailed to transport teardown", model.playbackObservationChangeRequiresPause())
        model.error = nil; model.startPlaybackObservation()
        check("Pending detailed to transport keeps observation mix and intent", model.playbackObservation === detailed && item.audioMix === detailedMix && model.playing && model.player.rate == 0 && model.error?.contains("재생을 멈춘 뒤") == true)
        model.error = nil; model.startPlaybackObservation(mode: .trackPostEffects)
        check("Pending detailed replacement keeps existing graph", model.playbackObservation === detailed && item.audioMix === detailedMix && model.playing && model.error != nil)
        model.pausePlayback(); model.error = nil
        model.player.playImmediately(atRate: 1)
        model.playing = false // Isolate AVPlayer rate from the model's requested-play flag.
        check("Actual rate-only branch is established", model.player.rate != 0)
        model.startPlaybackObservation()
        check("Actual rate-only replacement is refused without pausing player", model.playbackObservation === detailed && item.audioMix === detailedMix && model.player.rate != 0 && model.error != nil)
        model.pausePlayback(); model.error = nil
        model.startPlaybackObservation()
        check("Paused replacement restores original mix and starts transport", model.playbackObservation?.mode == .transport && model.playbackObservation?.attachedAudioTaps == 0 && item.audioMix === originalMix && !model.playing && model.player.rate == 0)
        check("Stopped detailed report keeps count but no active graph ownership", (detailed?.attachedAudioTaps ?? 0) > 0 && detailed?.hasActiveAudioTaps == false)
        model.playbackObservation?.stop()
        model.playbackObservation = detailed // Save-cancel can retain a finished observation.
        model.playing = true; model.error = nil
        check("Finished detailed report does not disable default transport while pending", !model.playbackObservationChangeRequiresPause())
        model.startPlaybackObservation()
        check("Finished report replacement leaves restored mix and pending intent", model.playbackObservation?.mode == .transport && item.audioMix === originalMix && model.playing && model.error == nil)
        let failures = rows.filter { $0["passed"] as? Bool == false }.count
        try JSONSerialization.data(withJSONObject: ["scope": "Generated media and actual EditorModel/AVPlayer graph identity; deterministic pending/waiting policy inputs; no native menu UI, physical audio, or startup latency measurement", "checks": rows], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        print("PLAYBACK_OBSERVATION_GUARD_RESULT checks=\(rows.count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

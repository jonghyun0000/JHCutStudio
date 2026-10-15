#if PLAYBACK_PROBE
import Foundation
import AppKit
import AVFoundation
import JHCutCore

@main struct PlaybackProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Playback")
        let source = root.appendingPathComponent("playback-source.mp4")
        if !FileManager.default.fileExists(atPath: source.path) {
            try await Fixtures.video(to: source, scene: 2, color: CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1), frames: 180)
        }
        let sound = root.appendingPathComponent("tone.wav")
        try Fixtures.audio(to: sound, seconds: 6)
        let audioAsset = try await MediaImporter.inspect(url: sound)
        let asset = try await MediaImporter.inspect(url: source)
        var project = Project(name: "Playback regression")
        project.assets = [asset, audioAsset]
        project.sequence.tracks[3].clips = [Clip(name: "Tone", assetID: audioAsset.id, duration: MediaTime(seconds: 6))]
        project.sequence.tracks[0].clips = [Clip(name: "Playback", assetID: asset.id, start: .zero, duration: MediaTime(seconds: 6))]
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("probe-recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: root.appendingPathComponent("ProxyCache")))
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
        let observedItem = model.player.currentItem!
        let observation = try PlaybackObservation(player: model.player, mode: .trackPostEffects)
        model.playbackObservation = observation
        check("Explicit per-track post-effects audio observation attached", observation.attachedAudioTaps > 0)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 900_000_000)
        observation.sample("playing", displayedTime: model.playhead)
        let running = observation.currentSample!
        check("Actual audio delivery includes non-silent samples", (running["audioFrames"] as? Int64 ?? 0) > 0 && (running["nonSilentBuffers"] as? Int64 ?? 0) > 0)
        check("Actual player video output delivers frames", (running["videoFrames"] as? Int ?? 0) > 0)
        check("Native player advances", model.player.currentTime().seconds > 0.2, "time=\(model.player.currentTime().seconds)")
        model.togglePlay()
        let paused = model.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 500_000_000)
        observation.sample("paused-settled", displayedTime: model.playhead)
        let quiet = observation.currentSample!
        try await Task.sleep(nanoseconds: 350_000_000)
        observation.sample("paused-held", displayedTime: model.playhead)
        let held = observation.currentSample!
        check("Paused per-track post-effects buffers remain silent after drain", (quiet["nonSilentBuffers"] as? Int64) == (held["nonSilentBuffers"] as? Int64) && (held["unsupportedAudioFormats"] as? Int64 ?? 0) == 0 && (held["audioErrors"] as? Int64 ?? 0) == 0)
        check("Paused decoded video frame timestamp holds", (quiet["lastFrameTime"] as? Double) == (held["lastFrameTime"] as? Double))
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
        // This isolates the UI/model export-busy policy with real AVPlayer output. The separate
        // long-session export workload measures encoder contention; this is not that load test.
        model.isExporting = true
        let exportBusyStart=model.player.currentTime().seconds
        model.togglePlay();try await Task.sleep(nanoseconds:900_000_000)
        observation.sample("export-busy-preview",displayedTime:model.playhead)
        check("Export-busy policy permits actual preview clock and decoded frame advance",model.playing && model.player.currentTime().seconds>exportBusyStart+0.1 && (observation.currentSample?["lastFrameTime"] as? Double ?? -1)>exportBusyStart+0.1)
        model.togglePlay();let exportBusyPaused=model.player.currentTime().seconds
        try await Task.sleep(nanoseconds:200_000_000)
        check("Export-busy policy still permits pause",!model.playing && abs(model.player.currentTime().seconds-exportBusyPaused)<model.frameStep)
        model.isExporting = false
        model.seek(5.7); model.togglePlay()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        check("End of media clears play intent", !model.playing && model.player.rate == 0)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 500_000_000)
        check("Replay after end starts from beginning", model.playing && model.player.currentTime().seconds < 2)
        model.pausePlayback()
        model.seek(0)
        try await Task.sleep(nanoseconds: 150_000_000)
        model.seek(4.0); model.pausePlayback()
        try await Task.sleep(nanoseconds: 250_000_000)
        check("Seek immediately followed by pause keeps display and actual time aligned", abs(model.playhead-4)<model.frameStep*1.1 && abs(model.player.currentTime().seconds-4)<model.frameStep*1.1, "display=\(model.playhead) player=\(model.player.currentTime().seconds)")
        for i in 0..<12 { model.seek(0.2 + Double(i)*0.3) }
        model.pausePlayback()
        try await Task.sleep(nanoseconds:300_000_000)
        check("Overlapping seek completions cannot replace newest paused target", !model.playing && model.player.rate == 0 && abs(model.playhead-3.5)<model.frameStep && abs(model.player.currentTime().seconds-3.5)<model.frameStep)
        var pauseTimes: [Double] = []; var heldAll = true; var seekTimes: [Double] = []
        for cycle in 0..<20 {
            let target = Double(cycle % 5) + 0.2
            let begin = ProcessInfo.processInfo.systemUptime
            model.seek(target)
            for _ in 0..<200 { if abs(model.player.currentTime().seconds-target)<model.frameStep { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            seekTimes.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
            model.togglePlay(); try await Task.sleep(nanoseconds: 100_000_000)
            let start = ProcessInfo.processInfo.systemUptime; model.pausePlayback()
            pauseTimes.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            let t = model.player.currentTime().seconds
            try await Task.sleep(nanoseconds: 150_000_000)
            heldAll = heldAll && !model.playing && model.player.rate==0 && abs(model.player.currentTime().seconds-t)<model.frameStep
        }
        check("20 repeated seek/play/pause cycles hold time and state", heldAll)
        func percentile(_ values: [Double], _ p: Double) -> Double { values.sorted()[min(values.count-1, Int((Double(values.count)-1)*p))] }
        let timing: [String:Any] = ["pauseCallMilliseconds":pauseTimes,"pauseCallP50":percentile(pauseTimes,0.5),"pauseCallP95":percentile(pauseTimes,0.95),"seekClockMilliseconds":seekTimes,"seekClockP50":percentile(seekTimes,0.5),"seekClockP95":percentile(seekTimes,0.95),"scope":"pause call duration/seek clock acceptance; not decoded-frame seek latency or physical speaker delay"]
        try JSONSerialization.data(withJSONObject:timing,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("timing.json"))
        var immediateStops = true
        for _ in 0..<20 {
            model.togglePlay(); model.pausePlayback()
            try await Task.sleep(nanoseconds: 50_000_000)
            immediateStops = immediateStops && !model.playing && model.player.rate == 0
        }
        check("20 immediate start/stop requests never resume later", immediateStops)
        model.togglePlay(); model.rebuild(); model.pausePlayback()
        for _ in 0..<2000 { if !model.isBuilding && model.player.currentItem?.status == .readyToPlay { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 150_000_000)
        check("Actual asynchronous rebuild remains paused after stop", !model.isBuilding && !model.playing && model.player.rate == 0 && model.player.currentItem?.status == .readyToPlay)
        let diagnosticURL = root.appendingPathComponent("playback-observation.json")
        try observation.saveReport(to: diagnosticURL)
        let protectedReport = try Data(contentsOf: diagnosticURL)
        let audioReport = try JSONSerialization.jsonObject(with: protectedReport) as! [String:Any]
        let provenance = audioReport["sourceProvenance"] as? [[String:Any]] ?? []
        let sourceCallbacks = provenance.flatMap { $0["callbacks"] as? [[String:Any]] ?? [] }
        check("Explicit audio diagnostic reports per-track scope and source ranges", audioReport["mode"] as? String == "trackPostEffects" && audioReport["audioMeasurement"] as? String == "perTrackPostEffects" && !sourceCallbacks.isEmpty && sourceCallbacks.contains { ($0["sourceStartTimescale"] as? Int ?? 0)>0 && ($0["deliveredFrames"] as? Int ?? 0)>0 })
        check("Per-track source provenance remains bounded", !provenance.isEmpty && provenance.allSatisfy { ($0["callbacks"] as? [[String:Any]] ?? []).count <= 128 && ($0["capacity"] as? Int)==128 })
        do { try observation.saveReport(to: diagnosticURL); check("Diagnostic report refuses existing destination", false) }
        catch { check("Diagnostic report refuses existing destination", try Data(contentsOf: diagnosticURL) == protectedReport) }
        check("Diagnostic stop restores original audio processing", observedItem.audioMix?.inputParameters.allSatisfy { $0.audioTapProcessor == nil } == true)
        model.playbackObservation = nil
        var previousObservation: PlaybackObservation? = try PlaybackObservation(player: model.player, mode: .trackPostEffects)
        previousObservation!.stop(); previousObservation = nil
        let replacementObservation = try PlaybackObservation(player: model.player, mode: .trackPostEffects)
        do { _ = try PlaybackObservation(player: model.player, mode: .trackPostEffects); check("Duplicate audio observation refuses existing tap", false) }
        catch { check("Duplicate audio observation refuses existing tap", model.player.currentItem?.audioMix?.inputParameters.contains { $0.audioTapProcessor != nil } == true) }
        await Task.yield()
        check("Old diagnostic cleanup cannot detach a newer audio observation", model.player.currentItem?.audioMix?.inputParameters.contains { $0.audioTapProcessor != nil } == true)
        for i in 0..<2100 { replacementObservation.sample("bounded-\(i)") }
        let boundedReport = try JSONSerialization.jsonObject(with: replacementObservation.finish()) as! [String:Any]
        check("Diagnostic rows remain bounded after2100 samples", (boundedReport["rows"] as! [[String:Any]]).count <= 2000)
        let nativeItem = model.player.currentItem!, nativeMix = model.player.currentItem!.audioMix
        let transportObservation = try PlaybackObservation(player: model.player)
        transportObservation.sample("native-scope")
        check("Default diagnostic leaves the original audio mix untouched", transportObservation.mode == .transport && transportObservation.attachedAudioTaps == 0 && nativeItem.audioMix === nativeMix)
        let transportReport = try JSONSerialization.jsonObject(with: transportObservation.finish()) as! [String:Any]
        let transportRows = transportReport["rows"] as? [[String:Any]] ?? []
        check("Default diagnostic reports audio unmeasured rather than silent", transportReport["audioMeasurement"] as? String == "notMeasured" && transportReport["audioGraphModified"] as? Bool == false && !transportRows.isEmpty && transportRows.allSatisfy { row in row["audioMeasurement"] as? String == "notMeasured" && ["audioCallbacks","audioFrames","nonSilentBuffers","audioErrors","unsupportedAudioFormats"].allSatisfy { name in row[name] is NSNull } })
        check("Default diagnostic cleanup preserves audio mix identity", nativeItem.audioMix === nativeMix)
        model.startPlaybackObservation()
        let appTransportObservation = model.playbackObservation
        check("App diagnostic command selects transport without changing audio", appTransportObservation?.mode == .transport && appTransportObservation?.attachedAudioTaps == 0 && nativeItem.audioMix === nativeMix)
        model.seek(0.2); model.togglePlay()
        model.startPlaybackObservation(mode: .trackPostEffects)
        check("App refuses intrusive audio diagnosis during pending or active playback", model.playing && model.playbackObservation === appTransportObservation && nativeItem.audioMix === nativeMix && model.error?.contains("재생을 멈춘 뒤") == true)
        model.pausePlayback(); model.error = nil
        model.startPlaybackObservation(mode: .trackPostEffects)
        check("Paused app can explicitly select per-track audio diagnosis", model.playbackObservation?.mode == .trackPostEffects && (model.playbackObservation?.attachedAudioTaps ?? 0) > 0 && !model.playing && model.player.rate == 0)
        model.playbackObservation?.stop(); model.playbackObservation = nil
        check("App audio diagnosis cleanup restores the original mix", nativeItem.audioMix === nativeMix)
        var isolatedPlayer: AVPlayer? = AVPlayer(playerItem: model.plan!.makePlayerItem())
        weak var releasedPlayer = isolatedPlayer
        for _ in 0..<1000 { if isolatedPlayer!.currentItem?.status == .readyToPlay { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let releasedObservation = try PlaybackObservation(player: isolatedPlayer!, mode: .trackPostEffects)
        releasedObservation.stop(); isolatedPlayer = nil
        for _ in 0..<1000 { if releasedPlayer == nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let releasedReport = try releasedObservation.finish()
        check("Stopped diagnostic releases player while report remains available", releasedPlayer == nil && !releasedReport.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        model.savedData = try encoder.encode(model.project)
        check("Saved document cache is clean", !model.dirty)
        var edited = project; edited.name = "Changed"
        model.history = EditorHistory(project: edited)
        check("Dirty cache invalidates after edit", model.dirty)
        // Owned synthetic GUI document uses the same media, repeated to60s (not diverse footage).
        var guiProject = project; guiProject.id = UUID(); guiProject.name = "재생 검증 · 합성 60초"
        guiProject.sequence.tracks[0].clips = (0..<10).map { Clip(name: "장면 \($0)", assetID: asset.id, start: MediaTime(seconds: Double($0)*6), duration: MediaTime(seconds:6)) }
        guiProject.sequence.tracks[3].clips = (0..<10).map { Clip(name: "음악 \($0)", assetID: audioAsset.id, start: MediaTime(seconds: Double($0)*6), duration: MediaTime(seconds:6)) }
        try encoder.encode(guiProject).write(to:root.appendingPathComponent("gui-project.jhcut"))
        try await PlaybackMatrixProbe.run(root:root,sound:audioAsset,check:check)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: root.appendingPathComponent("playback-checks.json"))
        print("PLAYBACK_RESULT checks=\(rows.count) failures=\(rows.filter { ($0["passed"] as? Bool) != true }.count)")
        if rows.contains(where: { ($0["passed"] as? Bool) != true }) { exit(1) }
    }
}
#endif

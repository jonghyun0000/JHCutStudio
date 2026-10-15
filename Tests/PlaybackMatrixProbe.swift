#if PLAYBACK_PROBE
import Foundation
import AVFoundation
import AppKit
import JHCutCore

enum PlaybackMatrixProbe {
    @MainActor static func run(root: URL, sound: MediaAsset, check: (String, Bool, String) -> Void) async throws {
        var results: [[String: Any]] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (width, height) in [(1920,1080),(3840,2160)] {
            let source = root.appendingPathComponent("matrix-\(width).mp4")
            try await Fixtures.video(to: source, scene: 3, color: CGColor(red:0.2,green:0.7,blue:0.3,alpha:1), frames:90, width:width, height:height)
            let asset = try await MediaImporter.inspect(url:source)
            let cache = ProxyCache(directory:root.appendingPathComponent("matrix-proxy-\(width)"))
            let proxy = try await cache.generate(for:source)
            for enabled in [false,true] {
                let label = "\(width)×\(height) proxy=\(enabled)"
                let folder = root.appendingPathComponent("matrix-\(width)-\(enabled)")
                try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
                var project = Project(name:label)
                project.assets = [asset,sound]; project.sequence.width = width; project.sequence.height = height
                var first = Clip(name:"stabilized", assetID:asset.id, duration:MediaTime(seconds:1.5), playbackRate:PlaybackRate(numerator:2))
                first.stabilization = StabilizationData(step:1.0/30, analyzedStart:.zero, frameWidth:width, frameHeight:height, x:(0..<91).map { Float(sin(Double($0)*0.1)*0.002) }, y:Array(repeating:0,count:91), angle:Array(repeating:0,count:91))
                let second = Clip(name:"transition",assetID:asset.id,start:MediaTime(seconds:1.5),duration:MediaTime(seconds:1.5))
                project.sequence.tracks[0].clips = [first,second]
                project.sequence.tracks[2].clips = [Clip(name:"caption",start:.zero,duration:MediaTime(seconds:2.7),title:Title(text:"재생 · 日本語 · English"))]
                project.sequence.tracks[3].clips = [Clip(name:"tone",assetID:sound.id,duration:MediaTime(seconds:2.7))]
                try TransitionEditing.add(in:&project.sequence,trackID:project.sequence.tracks[0].id,clipID:first.id,effect:ClipTransition(kind:.dissolve,duration:MediaTime(seconds:0.3)))
                let model = EditorModel(recoveryStore:RecoveryStore(directory:folder.appendingPathComponent("recovery")),exportHistoryURL:folder.appendingPathComponent("journal.json"),proxyCache:cache)
                model.history = EditorHistory(project:project); model.proxyURLs = [asset.id:proxy]; model.proxyEnabled = enabled; model.rebuild()
                for _ in 0..<2000 { if !model.isBuilding && model.player.currentItem?.status == .readyToPlay { break }; try await Task.sleep(nanoseconds:5_000_000) }
                try encoder.encode(project).write(to:folder.appendingPathComponent("project.jhcut"))
                check(label+" ready with effects and requested media",model.plan != nil && model.player.currentItem?.status == .readyToPlay && model.plan?.usesProxyMedia == enabled, "error=\(model.error ?? model.player.currentItem?.error?.localizedDescription ?? "none") status=\(model.player.currentItem?.status.rawValue ?? -1)")
                guard model.plan != nil, model.player.currentItem?.status == .readyToPlay else { continue }
                let observation = try PlaybackObservation(player:model.player, mode:.trackPostEffects); model.playbackObservation = observation
                var heartbeat: [Double] = []
                let ticker = Task { @MainActor in
                    var last = ProcessInfo.processInfo.systemUptime
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds:5_000_000) } catch { break }
                        let now = ProcessInfo.processInfo.systemUptime; heartbeat.append((now-last)*1000); last = now
                    }
                }
                var seeks: [Double] = []; var arrived = true; var aligned = true
                for target in [0.2,1.3,2.0,0.7,1.4] {
                    let begin = ProcessInfo.processInfo.systemUptime
                    model.seek(target); model.pausePlayback()
                    var found = false
                    for _ in 0..<400 {
                        observation.sample("seek-frame",displayedTime:model.playhead)
                        if let frame = observation.currentSample?["lastFrameTime"] as? Double, abs(frame-target)<model.frameStep*1.1 { found = true; break }
                        try await Task.sleep(nanoseconds:5_000_000)
                    }
                    seeks.append((ProcessInfo.processInfo.systemUptime-begin)*1000); arrived = arrived && found
                    aligned = aligned && !model.playing && model.player.rate == 0 && abs(model.player.currentTime().seconds-target)<model.frameStep*1.1 && abs(model.playhead-target)<model.frameStep*1.1
                }
                check(label+" seek delivers decoded target frames",arrived, "samples=5")
                check(label+" rapid seek/stop keeps state and time aligned",aligned, "")
                observation.sample("matrix-before-play")
                let beforePlay = observation.currentSample!
                let priorFrames = beforePlay["videoFrames"] as? Int ?? 0
                let priorSignals = beforePlay["nonSilentBuffers"] as? Int64 ?? 0
                model.seek(0.2); model.togglePlay(); try await Task.sleep(nanoseconds:600_000_000)
                observation.sample("matrix-playing")
                let playing = observation.currentSample!
                let deliveredFrames = (playing["videoFrames"] as? Int ?? 0) - priorFrames
                let deliveredSignals = (playing["nonSilentBuffers"] as? Int64 ?? 0) - priorSignals
                let clock = playing["playerTime"] as? Double ?? 0
                let frameTime = playing["lastFrameTime"] as? Double ?? 0
                check(label+" video and non-silent per-track post-effects audio delivered",deliveredFrames>0 && deliveredSignals>0 && clock>0.2+model.frameStep && frameTime>0.2+model.frameStep,
                      "600ms clock=\(clock) frame=\(frameTime) newFrames=\(deliveredFrames) newSignals=\(deliveredSignals)")
                let begin = ProcessInfo.processInfo.systemUptime; model.pausePlayback(); let pauseMS = (ProcessInfo.processInfo.systemUptime-begin)*1000
                try await Task.sleep(nanoseconds:500_000_000); observation.sample("matrix-settled"); let settled = observation.currentSample!
                try await Task.sleep(nanoseconds:250_000_000); observation.sample("matrix-held"); let held = observation.currentSample!
                check(label+" paused frame/time/signal hold",(settled["playerTime"] as? Double)==(held["playerTime"] as? Double) && (settled["lastFrameTime"] as? Double)==(held["lastFrameTime"] as? Double) && (settled["nonSilentBuffers"] as? Int64)==(held["nonSilentBuffers"] as? Int64), "")
                model.loopStart = 0.2; model.loopEnd = 0.6; model.loopEnabled = true; model.seek(0.2); model.togglePlay()
                var wraps = 0; var last = 0.2
                for _ in 0..<30 { try await Task.sleep(nanoseconds:50_000_000); let current = model.player.currentTime().seconds; if current < last-0.15 { wraps += 1 }; last = current }
                model.pausePlayback(); let stopped = model.player.currentTime().seconds; try await Task.sleep(nanoseconds:300_000_000)
                check(label+" loop wraps and explicit stop holds",wraps>=1 && !model.playing && model.player.rate==0 && abs(model.player.currentTime().seconds-stopped)<model.frameStep, "wraps=\(wraps)")
                check(label+" diagnostic format and audio errors absent",(held["audioErrors"] as? Int64)==0 && (held["unsupportedAudioFormats"] as? Int64)==0, "")
                ticker.cancel(); await ticker.value
                try observation.saveReport(to:folder.appendingPathComponent("trace.json"))
                check(label+" project document remains unchanged",try encoder.encode(project)==encoder.encode(model.project), "")
                let sorted = seeks.sorted()
                results.append(["case":label,"sourceWidth":width,"sourceHeight":height,"sourceFPS":30,"sourceCodec":"H.264 SDR Rec.709","canvasWidth":width,"canvasHeight":height,"proxy":enabled,"effects":"2x speed, nonzero synthetic stabilization path, dissolve, multilingual title, tone","decodedFrameSeekMilliseconds":seeks,"decodedFrameSeekP50":sorted[sorted.count/2],"decodedFrameSeekP95":sorted.last!,"pauseCallMilliseconds":pauseMS,"mainActorHeartbeatMaxGapMilliseconds":heartbeat.max() ?? 0,"scope":"5 seek samples per case; p95=max for n5; heartbeat scheduling gaps include runtime/system load; not physical speaker or native GUI latency"])
                model.playbackObservation = nil; model.player.replaceCurrentItem(with:nil)
                try await NativePlaybackStartProbe.run(project:project, cache:cache, proxyURLs:[asset.id:proxy], enabled:enabled, folder:folder.appendingPathComponent("native-start"), check:check)
            }
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("playback-matrix.json"))
    }
}
#endif

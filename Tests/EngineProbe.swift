// Standalone integration probe; compile with Validation/Fixtures.swift and Validation/MediaInspection.swift.
import Foundation
import AVFoundation
import CoreImage
import CryptoKit
import JHCutCore

@main struct EngineProbe {
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    static func main() async {
        do { try await run() }
        catch { fputs("Engine probe failed: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let folder = try ProbeWorkspace.prepare(defaultPath: "Artifacts/EngineUpgrade")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = try await Fixtures.generate(in: folder.appendingPathComponent("fixtures", isDirectory: true))
        let video = try await MediaImporter.inspect(url: fixtures.videos[0])
        let overlay = try await MediaImporter.inspect(url: fixtures.overlay)
        let audio = try await MediaImporter.inspect(url: fixtures.bgm)
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) { checks.append(Check(name: name, passed: passed, detail: detail)); print("[\(passed ? "PASS" : "FAIL")] \(name): \(detail)") }
        var project = Project(name: "Engine upgrade proof")
        project.assets = [video, overlay, audio]
        var main = Clip(name: "2× grayscale cropped", assetID: video.id, sourceStart: MediaTime(seconds: 0.5), duration: MediaTime(seconds: 2))
        main.playbackRate = PlaybackRate(numerator: 2)
        main.visual = VisualAdjustments(exposure: 0.3, contrast: 1.1, saturation: 0, cropLeft: 0.05, cropRight: 0.05)
        main.fadeIn = MediaTime(seconds: 0.25); main.fadeOut = MediaTime(seconds: 0.25)
        project.sequence.tracks[0].clips = [main]
        var overlayClip = Clip(name: "Moving PNG", assetID: overlay.id, duration: MediaTime(seconds: 2), transform: ClipTransform(x: -350, y: -500, scale: 0.2))
        overlayClip.keyframes = [TransformKeyframe(time: .zero, transform: overlayClip.transform, interpolation: .ease),
                                 TransformKeyframe(time: MediaTime(seconds: 2), transform: ClipTransform(x: 350, y: -500, scale: 0.2))]
        project.sequence.tracks[1].clips = [overlayClip]
        let styled = Title(text: "종현의 새로운 영상\n한글 자막의 외곽선과 배경\n마지막 문장도 모두 표시됩니다", fontSize: 68, colorHex: "FFE55B", x: 0.5, y: 0.8,
                           style: TextStyle(strokeHex: "142236", strokeWidth: 5, backgroundHex: "123459", backgroundOpacity: 0.9, padding: 28, alignment: .center, shadow: false, maxLines: 2, lineSpacing: 20))
        project.sequence.tracks[2].clips = [Clip(name: "Styled Korean", duration: MediaTime(seconds: 2), title: styled)]
        var sound = Clip(name: "2× pitch preserved with envelope", assetID: audio.id, duration: MediaTime(seconds: 2), volume: 0.5)
        sound.playbackRate = PlaybackRate(numerator: 2)
        sound.audioFadeIn = MediaTime(seconds: 0.5); sound.audioFadeOut = MediaTime(seconds: 0.5)
        sound.keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(), volume: 0.5, interpolation: .ease),
                           TransformKeyframe(time: MediaTime(seconds: 1), transform: ClipTransform(), volume: 0.25, interpolation: .ease),
                           TransformKeyframe(time: MediaTime(seconds: 2), transform: ClipTransform(), volume: 0.5)]
        project.sequence.tracks[3].clips = [sound]
        let layout = try TitlePreviewRenderer.layout(title: styled, canvasWidth: 1080)
        check("Max-line target retains full text", !layout.wasTruncated && layout.visibleLines == layout.totalLines && layout.exceedsLineLimit && layout.lineTexts.joined() == styled.text, "\(layout.visibleLines)/\(layout.totalLines) lines; no ellipsis")
        let titlePreview = try TitlePreviewRenderer.image(title: styled, size: CGSize(width: 1080, height: 1920))
        try Fixtures.savePNG(titlePreview, to: folder.appendingPathComponent("styled-title.png"))
        let document = folder.appendingPathComponent("engine-upgrade.jhcut")
        try ProjectStore.save(project, to: document)
        let reopened = try ProjectStore.load(from: document)
        check("Advanced model save/reload", reopened.sequence == project.sequence, "Styles, rational rates, effects, fades and keyframes retained")
        let plan = try await TimelineRenderer.build(project: reopened, documentURL: document)
        let movie = folder.appendingPathComponent("engine-upgrade.mp4")
        if FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.removeItem(at: movie) }
        let start = Date()
        try await ExportJob().export(plan: plan, to: movie) { _ in }
        let decoded = try await MediaInspection.decode(movie)
        check("Actual speed export", decoded.frameCount == 60 && abs(decoded.videoEndSeconds - 2) < 0.001 && decoded.width == 1080 && decoded.height == 1920, "\(decoded.frameCount) frames / \(decoded.videoEndSeconds)s, export \(Date().timeIntervalSince(start))s")
        let preview = AVAssetImageGenerator(asset: plan.composition); preview.videoComposition = plan.videoComposition
        preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        var positions: [Double] = []
        var brightness: [Double] = []
        for frame in [3, 15, 30, 45, 57] {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let a = try await preview.image(at: time).image
            let b = try await exported.image(at: time).image
            let difference = try MediaInspection.compare(a, b)
            check("Shared advanced render frame \(frame)", difference.mean < 0.035 && difference.p99 < 0.2, "MAE \(difference.mean), p99 \(difference.p99)")
            try Fixtures.savePNG(b, to: folder.appendingPathComponent("export-frame-\(frame).png"))
            let pixels = try MediaInspection.rgba(b)
            var count = 0, sumX = 0.0
            for y in 1000..<1600 { for x in 0..<1080 { let i = (y * 1080 + x) * 4
                if pixels[i] < 70 && pixels[i+1] > 160 && pixels[i+2] > 160 { count += 1; sumX += Double(x) }
            }}
            positions.append(count > 0 ? sumX / Double(count) : -1)
            let background = try MediaInspection.averageColor(b, normalizedRegion: CGRect(x: 0.1, y: 0.6, width: 0.1, height: 0.05))
            brightness.append(background.reduce(0,+) / 3)
            if frame == 30 {
                let text = try MediaInspection.recognizeText(b)
                check("Retimed source frame mapping", text.contains("075"), "At timeline1s source=.5+2×1=2.5s: \(text)")
                check("Styled Korean pixels", text.contains("종현") && text.contains("모두"), text)
                let color = try MediaInspection.averageColor(b, normalizedRegion: CGRect(x: 0.1, y: 0.6, width: 0.1, height: 0.05))
                check("Saturation zero", (color.max()! - color.min()!) < 0.015, "Bottom sample RGB=\(color)")
            }
        }
        check("Visual fades", brightness[0] < brightness[2] * 0.8 && brightness[4] < brightness[2] * 0.8, "Background grayscale=\(brightness)")
        check("Transform ease keyframes in pixels", positions.first! >= 0 && positions.last! - positions.first! > 500 && zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 }, "Cyan overlay x-centroids=\(positions)")
        let pcm = try await audioPCM(movie)
        func rms(_ a: Double, _ b: Double) -> Double {
            let values = pcm[Int(a * 48_000)..<min(pcm.count, Int(b * 48_000))]
            return sqrt(values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count))
        }
        let head = rms(0.02,0.10), middle = rms(0.95,1.05), tail = rms(1.90,1.98)
        check("Audio fade and keyframe envelope", head < middle * 0.6 && tail < middle * 0.6 && middle > 0.04 && middle < 0.09, "RMS start=\(head), middle=\(middle), end=\(tail)")
        let lo = Int(0.6 * 48_000), hi = Int(1.4 * 48_000)
        var crossings = 0
        for i in (lo+1)..<hi { if pcm[i-1] <= 0 && pcm[i] > 0 { crossings += 1 } }
        let frequency = Double(crossings) / 0.8
        check("Spectral pitch at 2×", abs(frequency - 440) < 5, "440Hz source estimated \(frequency)Hz after retiming (zero crossings in stable window)")
        let waveform = try await WaveformAnalyzer.analyze(url: fixtures.bgm, bins: 80)
        let cached = try await WaveformAnalyzer.analyze(url: fixtures.bgm, bins: 80)
        check("Streaming waveform and cache", waveform.count == 80 && waveform.allSatisfy { $0.isFinite && $0 > 0.39 && $0 < 0.41 } && waveform == cached, "80 PCM peak bins, max=\(waveform.max() ?? -1); cached second result exact")
        try await verifyAudioLanePitch(audio: audio, folder: folder, check: check)
        let data = try JSONEncoder().encode(checks)
        try data.write(to: folder.appendingPathComponent("engine-checks.json"), options: .atomic)
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let coreURL = executable.deletingLastPathComponent().appendingPathComponent("libJHCutCore.dylib")
        let hash = SHA256.hash(data: try Data(contentsOf: coreURL)).map { String(format: "%02x", $0) }.joined()
        let metadata = ["coreSHA256": hash, "generatedAt": ISO8601DateFormatter().string(from: Date())]
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("engine-checks-metadata.json"), options: .atomic)
        print("ENGINE_RESULT checks=\(checks.count) failures=\(checks.filter { !$0.passed }.count), output=\(movie.path)")
        guard checks.allSatisfy(\.passed) else { throw ValidationFailure.failed("Engine checks failed; inspect engine-checks.json") }
    }
    static func verifyAudioLanePitch(audio: MediaAsset, folder: URL, check: (String, Bool, String) -> Void) async throws {
        func project(_ clips: [Clip]) -> Project {
            var result = Project(name: "Audio lane pitch")
            result.assets = [audio]; result.sequence.width = 160; result.sequence.height = 90
            result.sequence.tracks[3].clips = clips
            return result
        }
        func frequency(_ samples: [Float], _ start: Double, _ end: Double) -> Double {
            let lo = Int(start * 48_000), hi = min(samples.count, Int(end * 48_000))
            guard hi > lo + 1 else { return 0 }
            var count = 0
            for i in (lo + 1)..<hi where samples[i - 1] <= 0 && samples[i] > 0 { count += 1 }
            return Double(count) / (Double(hi - lo) / 48_000)
        }
        func rms(_ samples: [Float], _ start: Double, _ end: Double) -> Double {
            let lo = Int(start * 48_000), hi = min(samples.count, Int(end * 48_000))
            guard hi > lo else { return 0 }
            return sqrt(samples[lo..<hi].reduce(0) { $0 + Double($1 * $1) } / Double(hi - lo))
        }
        var unity = Clip(name: "Trimmed unity tone", assetID: audio.id, sourceStart: MediaTime(seconds: 0.5), duration: MediaTime(seconds: 2), volume: 0.5)
        unity.audioFadeIn = MediaTime(seconds: 0.25); unity.audioFadeOut = MediaTime(seconds: 0.25)
        let unityPlan = try await TimelineRenderer.build(project: project([unity]))
        check("Unscaled trimmed lane avoids pitch-correction buffering", unityPlan.audioMix.inputParameters.count == 1 && unityPlan.audioMix.inputParameters[0].audioTimePitchAlgorithm == .varispeed, "actual finalized lane; preview and export share parameters")
        let unityMovie = folder.appendingPathComponent("unity-lane.mp4")
        try await ExportJob().export(plan: unityPlan, to: unityMovie) { _ in }
        let decoded = try await MediaInspection.decode(unityMovie), samples = try await audioPCM(unityMovie)
        check("Unity lane complete export keeps duration and samples", decoded.frameCount == 60 && decoded.monotonic && samples.count == 96_000, "frames=\(decoded.frameCount), PCM=\(samples.count)")
        let hz = frequency(samples, 0.5, 1.5), level = rms(samples, 0.5, 1.5)
        check("Unity lane retains source pitch and gain", abs(hz - 440) < 5 && level > 0.13 && level < 0.15, "frequency=\(hz)Hz RMS=\(level)")
        check("Unity lane retains both fades", rms(samples, 0.01, 0.08) < level * 0.6 && rms(samples, 1.92, 1.99) < level * 0.6, "decoded PCM start/end envelope")
        for scaledFirst in [false, true] {
            var normal = Clip(name: "Unity", assetID: audio.id, start: MediaTime(seconds: scaledFirst ? 1 : 0), duration: MediaTime(seconds: 1))
            normal.sourceStart = MediaTime(seconds: 4)
            let scaled = Clip(name: "Double speed", assetID: audio.id, start: MediaTime(seconds: scaledFirst ? 0 : 1), duration: MediaTime(seconds: 1), playbackRate: PlaybackRate(numerator: 2))
            let plan = try await TimelineRenderer.build(project: project(scaledFirst ? [scaled, normal] : [normal, scaled]))
            check("Mixed packed lane preserves pitch correction scaledFirst=\(scaledFirst)", plan.audioMix.inputParameters.count == 1 && plan.audioMix.inputParameters[0].audioTimePitchAlgorithm == .spectral, "2x and1x share one compatible-format lane")
            if scaledFirst {
                let movie = folder.appendingPathComponent("mixed-lane.mp4")
                try await ExportJob().export(plan: plan, to: movie) { _ in }
                let pcm = try await audioPCM(movie)
                let firstHz = frequency(pcm, 0.2, 0.8), lastHz = frequency(pcm, 1.2, 1.8)
                check("Mixed lane actual2x and subsequent1x retain440Hz", pcm.count == 96_000 && abs(firstHz - 440) < 5 && abs(lastHz - 440) < 5, "first=\(firstHz)Hz last=\(lastHz)Hz PCM=\(pcm.count)")
            }
        }
        var scaled = unity; scaled.id = UUID(); scaled.playbackRate = PlaybackRate(numerator: 2)
        let overlap = try await TimelineRenderer.build(project: project([unity, scaled]))
        let algorithms = overlap.audioMix.inputParameters.map { $0.audioTimePitchAlgorithm }
        check("Overlapping unity and scaled lanes keep independent algorithms", algorithms.count == 2 && algorithms.contains(.varispeed) && algorithms.contains(.spectral), "packing preserves overlap and only the scaled lane corrects pitch")
    }
    static func audioPCM(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:48_000, AVNumberOfChannelsKey:2, AVLinearPCMIsFloatKey:true, AVLinearPCMBitDepthKey:32, AVLinearPCMIsNonInterleaved:false])
        reader.add(output); guard reader.startReading() else { throw reader.error! }
        var all: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block)/4)
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw ValidationFailure.failed("PCM copy failed") }
            all += stride(from: 0, to: chunk.count, by: 2).map { chunk[$0] }
        }
        guard reader.status == .completed else { throw reader.error! }; return all
    }
}

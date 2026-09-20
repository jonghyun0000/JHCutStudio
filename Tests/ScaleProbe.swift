// Standalone probe for composition-track packing and carrier reuse.
// Compile with Validation/Fixtures.swift and Validation/MediaInspection.swift.
import Foundation
import AVFoundation
import CoreImage
import JHCutCore

@main struct ScaleProbe {
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    static var checks: [Check] = []
    static func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(name: name, passed: passed, detail: detail))
        print("[\(passed ? "PASS" : "FAIL")] \(name): \(detail)")
    }

    static func main() async {
        do { try await run() }
        catch { fputs("Scale probe failed: \(error)\n", stderr); exit(1) }
    }

    /// Mean square of the exported audio inside one timeline window, used to prove that clips sharing
    /// a packed audio lane keep their own volume.
    static func windowRMS(_ url: URL, from: Double, to: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ValidationFailure.failed("audio read failed") }
        var squares = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            let samples = length / 2
            let rate = 48_000.0, channels = 2.0
            pointer.withMemoryRebound(to: Int16.self, capacity: samples) { buffer in
                for index in 0..<samples {
                    let time = start + Double(index) / (rate * channels)
                    guard time >= from, time < to else { continue }
                    let value = Double(buffer[index]) / 32_768.0
                    squares += value * value; count += 1
                }
            }
        }
        guard reader.status == .completed, count > 0 else { return 0 }
        return (squares / Double(count)).squareRoot()
    }

    static func run() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Scale", isDirectory: true).standardizedFileURL
        let clipCount = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 60
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = try await Fixtures.generate(in: folder.appendingPathComponent("fixtures", isDirectory: true))
        let videos = try await [MediaImporter.inspect(url: fixtures.videos[0]),
                                MediaImporter.inspect(url: fixtures.videos[1]),
                                MediaImporter.inspect(url: fixtures.videos[2])]
        let overlay = try await MediaImporter.inspect(url: fixtures.overlay)
        let bgm = try await MediaImporter.inspect(url: fixtures.bgm)

        // ---- Part A: packed lanes must not change a single frame or a single sample. ----
        var project = Project(name: "Lane packing proof")
        project.assets = videos + [overlay, bgm]
        // Main video track: three sequential clips that previously used three composition tracks.
        project.sequence.tracks[0].clips = (0..<3).map { index in
            Clip(name: "scene \(index)", assetID: videos[index].id,
                 start: MediaTime(seconds: Double(index) * 2), duration: MediaTime(seconds: 2))
        }
        // Overlay track: two video clips that genuinely overlap, so packing must keep two lanes.
        // A still image needs no composition track at all, so only video clips prove lane separation.
        project.sequence.tracks[1].clips = [
            Clip(name: "overlay A", assetID: videos[1].id, start: .zero, duration: MediaTime(seconds: 3),
                 transform: ClipTransform(x: -250, y: 400, scale: 0.3)),
            Clip(name: "overlay B", assetID: videos[2].id, start: MediaTime(seconds: 1.5), duration: MediaTime(seconds: 3),
                 transform: ClipTransform(x: 250, y: 400, scale: 0.3))
        ]
        // Audio track: two sequential clips at different volumes now share one lane and one
        // AVMutableAudioMixInputParameters, so each clip's own volume must survive the merge.
        var faded = Clip(name: "faded", assetID: bgm.id, start: MediaTime(seconds: 4), sourceStart: MediaTime(seconds: 4),
                         duration: MediaTime(seconds: 2), volume: 1.0)
        faded.audioFadeIn = MediaTime(seconds: 1)
        project.sequence.tracks[3].clips = [
            Clip(name: "loud", assetID: bgm.id, start: .zero, duration: MediaTime(seconds: 2), volume: 1.0),
            Clip(name: "quiet", assetID: bgm.id, start: MediaTime(seconds: 2), sourceStart: MediaTime(seconds: 2),
                 duration: MediaTime(seconds: 2), volume: 0.25),
            faded
        ]

        let plan = try await TimelineRenderer.build(project: project)
        let videoTracks = plan.composition.tracks(withMediaType: .video).count
        let audioTracks = plan.composition.tracks(withMediaType: .audio).count
        // 1 carrier + 1 packed main-video lane + 2 overlapping overlay lanes.
        check("Video lanes follow overlap depth, not clip count", videoTracks == 4,
              "\(videoTracks) composition video tracks for 5 video clips (was 6 before packing)")
        check("Sequential audio clips share one lane", audioTracks == 1,
              "\(audioTracks) composition audio track for 2 sequential audio clips (was 2 before packing)")
        check("One audio mix parameter object per lane", plan.audioMix.inputParameters.count == audioTracks,
              "\(plan.audioMix.inputParameters.count) input parameters for \(audioTracks) audio track(s)")

        let movie = folder.appendingPathComponent("packed.mp4")
        if FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.removeItem(at: movie) }
        try await ExportJob().export(plan: plan, to: movie) { _ in }
        let decoded = try await MediaInspection.decode(movie)
        check("Packed timeline exports every frame", decoded.frameCount == 180 && abs(decoded.videoEndSeconds - 6) < 0.001 && decoded.monotonic,
              "\(decoded.frameCount) frames / \(decoded.videoEndSeconds)s, monotonic=\(decoded.monotonic)")

        // Each source is a different dominant colour, so a wrong lane assignment shows up as a wrong frame.
        let generator = AVAssetImageGenerator(asset: plan.composition)
        generator.videoComposition = plan.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var order: [String] = []
        var correct = true
        for (index, second) in [1.0, 3.0, 5.0].enumerated() {
            let image = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
            let rgb = try MediaInspection.averageColor(image, normalizedRegion: CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.15))
            let dominant = rgb.firstIndex(of: rgb.prefix(3).max() ?? 0) ?? -1
            order.append(["R", "G", "B"][max(0, min(2, dominant))])
            if dominant != index { correct = false }
        }
        check("Packed lane keeps clip order in pixels", correct, "dominant channel at 1s/3s/5s = \(order.joined(separator: "→")) (expected R→G→B)")

        let loud = try await windowRMS(movie, from: 0.15, to: 1.85)
        let quiet = try await windowRMS(movie, from: 2.15, to: 3.85)
        let ratio = quiet > 0 ? loud / quiet : .infinity
        check("Per-clip volume survives the shared lane", ratio > 3.6 && ratio < 4.4,
              String(format: "RMS %.5f at volume 1.0 vs %.5f at volume 0.25, ratio %.2f (expected ≈4)", loud, quiet, ratio))
        // A 1s fade-in on the third clip of the same lane: the first half must stay clearly quieter.
        let fadeEarly = try await windowRMS(movie, from: 4.05, to: 4.45)
        let fadeLate = try await windowRMS(movie, from: 5.05, to: 5.85)
        check("Fade envelope survives the shared lane", fadeEarly < fadeLate * 0.5 && fadeLate > 0.24,
              String(format: "RMS %.5f during fade-in vs %.5f after it", fadeEarly, fadeLate))

        // ---- Part B: build cost on a long, clip-dense timeline. ----
        var big = Project(name: "Scale")
        big.assets = videos
        big.sequence.tracks[0].clips = (0..<clipCount).map { index in
            Clip(name: "clip \(index)", assetID: videos[index % 3].id,
                 start: MediaTime(seconds: Double(index) * 2), duration: MediaTime(seconds: 2))
        }
        let timelineSeconds = Double(clipCount) * 2
        let started = Date()
        let bigPlan = try await TimelineRenderer.build(project: big)
        let first = Date().timeIntervalSince(started)
        let restarted = Date()
        _ = try await TimelineRenderer.build(project: big)
        let second = Date().timeIntervalSince(restarted)
        let bigVideoTracks = bigPlan.composition.tracks(withMediaType: .video).count
        check("Long timeline packs into a constant lane count", bigVideoTracks == 2,
              "\(bigVideoTracks) composition video tracks for \(clipCount) sequential clips over \(Int(timelineSeconds))s")
        check("Rebuild after an edit does not re-encode the carrier", second < max(1.0, first),
              String(format: "first build %.2fs, immediate rebuild %.2fs", first, second))
        print(String(format: "SCALE_TIMING clips=%d timeline=%.0fs build1=%.3fs build2=%.3fs videoTracks=%d",
                     clipCount, timelineSeconds, first, second, bigVideoTracks))

        let report = folder.appendingPathComponent("scale-checks.json")
        try JSONEncoder().encode(checks).write(to: report, options: .atomic)
        let failures = checks.filter { !$0.passed }.count
        print("SCALE_RESULT checks=\(checks.count) failures=\(failures), report=\(report.path)")
        if failures > 0 { exit(1) }
    }
}

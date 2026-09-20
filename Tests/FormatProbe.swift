// Standalone probe for canvas size and frame-rate support.
// Compile with Validation/Fixtures.swift and Validation/MediaInspection.swift.
import Foundation
import AVFoundation
import CoreImage
import JHCutCore

@main struct FormatProbe {
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    static var checks: [Check] = []
    static func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(name: name, passed: passed, detail: detail))
        print("[\(passed ? "PASS" : "FAIL")] \(name): \(detail)")
    }

    /// One clip of `frames` frames on a `width`×`height` canvas at `rate`, exported and decoded back.
    static func exportAndDecode(asset: MediaAsset, width: Int, height: Int, rate: FrameRate, frames: Int64,
                                bitRate: Int, to url: URL) async throws -> DecodedMovie {
        var project = Project(name: "Format \(width)x\(height)@\(rate.label)")
        project.assets = [asset]
        // Exact rational duration, so the expected frame count is not a rounding artefact.
        let duration = rate.time(forFrame: frames)
        project.sequence = Sequence(name: "seq", width: width, height: height, frameRate: rate,
                                    tracks: [Track(name: "메인 영상", kind: .video,
                                                   clips: [Clip(name: "clip", assetID: asset.id, duration: duration)])])
        let plan = try await TimelineRenderer.build(project: project)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try await ExportJob(videoBitRate: bitRate).export(plan: plan, to: url) { _ in }
        return try await MediaInspection.decode(url)
    }

    static func main() async {
        do { try await run() }
        catch { fputs("Format probe failed: \(error)\n", stderr); exit(1) }
    }

    static func run() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Format", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = try await Fixtures.generate(in: folder.appendingPathComponent("fixtures", isDirectory: true))
        let source = try await MediaImporter.inspect(url: fixtures.videos[0])

        // ---- 4K UHD ----
        let uhdStart = Date()
        let uhd = try await exportAndDecode(asset: source, width: 3840, height: 2160,
                                            rate: FrameRate(numerator: 30, denominator: 1), frames: 30,
                                            bitRate: ExportJob.recommendedBitRate(width: 3840, height: 2160, fps: 30),
                                            to: folder.appendingPathComponent("uhd-3840x2160.mp4"))
        check("3840×2160 UHD exports and decodes",
              uhd.width == 3840 && uhd.height == 2160 && uhd.frameCount == 30 && uhd.monotonic,
              "\(uhd.width)×\(uhd.height), \(uhd.frameCount) frames, \(uhd.videoCodec), \(String(format: "%.1f", Date().timeIntervalSince(uhdStart)))s")

        // ---- DCI 4K, the widest canvas the cap allows ----
        let dci = try await exportAndDecode(asset: source, width: 4096, height: 2160,
                                            rate: FrameRate(numerator: 24, denominator: 1), frames: 24,
                                            bitRate: ExportJob.recommendedBitRate(width: 4096, height: 2160, fps: 24),
                                            to: folder.appendingPathComponent("dci-4096x2160.mp4"))
        check("4096×2160 DCI at 24fps", dci.width == 4096 && dci.height == 2160 && dci.frameCount == 24,
              "\(dci.width)×\(dci.height), \(dci.frameCount) frames")

        // ---- Every supported frame rate, at 1080p so the sweep stays quick ----
        var rateResults: [String] = []
        var ratesOK = true
        for rate in FrameRate.supportedRenderRates {
            let frames: Int64 = 24
            let decoded = try await exportAndDecode(asset: source, width: 1280, height: 720, rate: rate, frames: frames,
                                                    bitRate: 8_000_000,
                                                    to: folder.appendingPathComponent("rate-\(rate.numerator)-\(rate.denominator).mp4"))
            let expectedSeconds = rate.time(forFrame: frames).seconds
            let ok = decoded.frameCount == Int(frames) && abs(decoded.videoEndSeconds - expectedSeconds) < 0.002 && decoded.monotonic
            ratesOK = ratesOK && ok
            rateResults.append("\(rate.label)=\(decoded.frameCount)f/\(String(format: "%.4f", decoded.videoEndSeconds))s\(ok ? "" : " ✗")")
        }
        check("All supported frame rates export the exact frame count", ratesOK, rateResults.joined(separator: " · "))

        // ---- NTSC must not reuse the integer-rate carrier ----
        let ntsc = try await exportAndDecode(asset: source, width: 1280, height: 720,
                                             rate: FrameRate(numerator: 30000, denominator: 1001), frames: 60,
                                             bitRate: 8_000_000, to: folder.appendingPathComponent("ntsc-2002ms.mp4"))
        check("29.97 keeps its own timebase", ntsc.frameCount == 60 && abs(ntsc.videoEndSeconds - 60.0 * 1001 / 30000) < 0.002,
              String(format: "%d frames / %.4fs (30fps would be 2.0000s)", ntsc.frameCount, ntsc.videoEndSeconds))

        // ---- Caps still refuse what is not verified ----
        var project = Project(name: "Rejects")
        project.assets = [source]
        project.sequence = Sequence(name: "s", width: 4098, height: 2160,
                                    tracks: [Track(name: "t", kind: .video, clips: [Clip(assetID: source.id, duration: MediaTime(seconds: 1))])])
        var oversizeRejected = false
        do { _ = try await TimelineRenderer.build(project: project) } catch { oversizeRejected = true }
        check("Canvas above 4096 is refused", oversizeRejected, "4098×2160 rejected before rendering")

        project.sequence = Sequence(name: "s", width: 1920, height: 1080, frameRate: FrameRate(numerator: 48, denominator: 1),
                                    tracks: [Track(name: "t", kind: .video, clips: [Clip(assetID: source.id, duration: MediaTime(seconds: 1))])])
        var rateRejected = false
        do { _ = try await TimelineRenderer.build(project: project) } catch { rateRejected = true }
        check("Unverified frame rate is refused", rateRejected, "48fps rejected rather than silently retimed")

        // ---- Bitrate ladder ----
        let hd = ExportJob.recommendedBitRate(width: 1920, height: 1080, fps: 30)
        let uhdRate = ExportJob.recommendedBitRate(width: 3840, height: 2160, fps: 30)
        let uhd60 = ExportJob.recommendedBitRate(width: 3840, height: 2160, fps: 60)
        check("Recommended bitrate scales with pixels and rate",
              uhdRate > hd && uhd60 >= uhdRate && ExportJob.supportedVideoBitRates.contains(uhdRate),
              "1080p30=\(hd / 1_000_000)Mbps, 2160p30=\(uhdRate / 1_000_000)Mbps, 2160p60=\(uhd60 / 1_000_000)Mbps")

        let report = folder.appendingPathComponent("format-checks.json")
        try JSONEncoder().encode(checks).write(to: report, options: .atomic)
        let failures = checks.filter { !$0.passed }.count
        print("FORMAT_RESULT checks=\(checks.count) failures=\(failures), report=\(report.path)")
        if failures > 0 { exit(1) }
    }
}

import Foundation
import AVFoundation
import CoreImage
import CoreText
import Vision
import Darwin
import JHCutCore

struct CheckResult: Codable {
    var name: String
    var status: String
    var detail: String
}

struct ValidationReport: Codable {
    var gate = "G0"
    var generatedAt = ISO8601DateFormatter().string(from: Date())
    var passed = false
    var environment: [String: String] = [:]
    var metrics: [String: Double] = [:]
    var checks: [CheckResult] = []
    var files: [String: String] = [:]
    var limitations: [String] = []
    mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(CheckResult(name: name, status: passed ? "passed" : "failed", detail: detail))
        print("[\(passed ? "PASS" : "FAIL")] \(name): \(detail)")
    }
    mutating func unrun(_ name: String, _ detail: String) { checks.append(CheckResult(name: name, status: "not_run", detail: detail)) }
}

enum G0Validation {
    static func run(in output: URL) async throws {
        var report = ValidationReport()
        let overallStart = Date()
        report.environment = ["os": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture(), "chip": sysctlString("machdep.cpu.brand_string"), "hardwareModel": sysctlString("hw.model"), "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory), "processorCount": String(ProcessInfo.processInfo.processorCount), "input": "3 × 5 s SDR Rec.709 H.264 540×960 /30 fps, PNG, PCM 48 kHz mono", "output": "15 s H.264/AAC MP4 1080×1920 /30 fps", "network": "No network or paid media used"]
        do {
            print("Generating reproducible fixtures in \(output.path)")
            let fixtures = try await Fixtures.generate(in: output.appendingPathComponent("한국어 공백 픽스처", isDirectory: true))
            var history = EditorHistory(project: Project(name: "종현의 첫 영상 · G0"))
            var assets: [MediaAsset] = []
            for url in fixtures.videos + [fixtures.endCard, fixtures.overlay, fixtures.bgm] {
                let asset = try await MediaImporter.inspect(url: url)
                guard asset.supported else { throw ValidationFailure.failed("Fixture import rejected \(url.lastPathComponent): \(asset.issue ?? "unknown")") }
                try history.apply(.addAsset(asset))
                assets.append(asset)
            }
            report.check("Korean filenames, spaces, duplicate basenames", Set(assets.prefix(3).map(\.id)).count == 3 && Set(assets.prefix(3).map(\.path)).count == 3, "Three separate '같은 이름 영상.mp4' sources imported from Korean folders containing spaces")
            report.check("Silent video imports", assets.prefix(3).allSatisfy { !$0.hasAudio }, "Generated H.264 inputs contain no audio track; separate BGM supplies output audio")
            let videoTrackID = history.project.sequence.tracks.first { $0.kind == .video }!.id
            let overlayTrackID = history.project.sequence.tracks.first { $0.kind == .overlay }!.id
            let titleTrackID = history.project.sequence.tracks.first { $0.kind == .title }!.id
            let audioTrackID = history.project.sequence.tracks.first { $0.kind == .audio }!.id
            var videoClips: [Clip] = []
            for index in 0..<3 {
                let clip = Clip(name: "장면 \(index + 1)", assetID: assets[index].id, start: MediaTime(seconds: Double(index * 5)), duration: MediaTime(seconds: 5))
                try history.apply(.addClip(trackID: videoTrackID, clip: clip))
                videoClips.append(clip)
            }
            for index in 0..<3 {
                videoClips[index].start = MediaTime(seconds: Double(index * 4))
                videoClips[index].sourceStart = MediaTime(seconds: 0.5)
                videoClips[index].duration = MediaTime(seconds: 4)
                try history.apply(.updateClip(trackID: videoTrackID, clip: videoClips[index]))
            }
            let beforeSplit = history.project
            try history.apply(.split(trackID: videoTrackID, clipID: videoClips[0].id, at: MediaTime(seconds: 2)))
            let splitState = history.project
            history.undo()
            let undoMatches = history.project == beforeSplit
            history.redo()
            let redoMatches = history.project == splitState
            history.undo()
            report.check("Split, undo and redo", undoMatches && redoMatches, "Split at 2 s; undo restores exact project value; redo restores split state; undo restores original clips")
            try history.apply(.reorder(trackID: videoTrackID, clipID: videoClips[1].id, direction: 1))
            history.undo()
            report.check("Reorder undo", history.project == beforeSplit, "Reorder command executed and undone before the final render")
            try history.apply(.addClip(trackID: videoTrackID, clip: Clip(name: "3초 엔드카드", assetID: assets[3].id, start: MediaTime(seconds: 12), duration: MediaTime(seconds: 3))))
            try history.apply(.addClip(trackID: overlayTrackID, clip: Clip(name: "투명 PNG", assetID: assets[4].id, start: .zero, duration: MediaTime(seconds: 15), transform: ClipTransform(x: -350, y: -500, scale: 0.2))))
            try history.apply(.addClip(trackID: titleTrackID, clip: Clip(name: "한국어 제목", start: .zero, duration: MediaTime(seconds: 12), title: Title(text: "종현의 첫 영상", fontSize: 76, x: 0.5, y: 0.8))))
            try history.apply(.addClip(trackID: audioTrackID, clip: Clip(name: "BGM 25%", assetID: assets[5].id, start: .zero, duration: MediaTime(seconds: 15), volume: 0.25)))
            try ProjectValidator.validate(history.project)
            report.check("Timeline duration", history.project.sequence.duration == MediaTime(seconds: 15), "Three trimmed 4 s clips + 3 s image end card; BGM/PNG last 15 s, title lasts 12 s")
            let documentURL = output.appendingPathComponent("종현의 첫 영상.jhcut")
            try ProjectStore.save(history.project, to: documentURL)
            let reloaded = try ProjectStore.load(from: documentURL)
            report.check("Project save/reload", reloaded.sequence == history.project.sequence && reloaded.assets.allSatisfy { $0.relativePath != nil }, "Disk document reloaded independently, with relative media references and exact timeline equality")
            report.files["project"] = documentURL.path
            let buildStart = Date()
            let plan = try await TimelineRenderer.build(project: reloaded, documentURL: documentURL)
            report.metrics["renderPlanBuildSeconds"] = Date().timeIntervalSince(buildStart)
            let generator = AVAssetImageGenerator(asset: plan.composition)
            generator.videoComposition = plan.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let firstPreviewStart = Date()
            let (firstPreviewImage, _) = try await generator.image(at: .zero)
            report.metrics["firstPreviewFrameSeconds"] = Date().timeIntervalSince(firstPreviewStart)
            let movieURL = output.appendingPathComponent("종현의 첫 영상 1080x1920.mp4")
            if FileManager.default.fileExists(atPath: movieURL.path) { try FileManager.default.removeItem(at: movieURL) }
            let exportStart = Date()
            let job = ExportJob()
            try await job.export(plan: plan, to: movieURL) { _ in }
            report.metrics["exportSeconds"] = Date().timeIntervalSince(exportStart)
            report.files["movie"] = movieURL.path
            report.metrics["outputBytes"] = Double((try FileManager.default.attributesOfItem(atPath: movieURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
            print("Export complete; decoding every output video/audio sample")
            let decoded = try await MediaInspection.decode(movieURL)
            report.metrics.merge(decoded.metrics) { _, new in new }
            report.check("1080×1920 H.264 /30 fps", decoded.width == 1080 && decoded.height == 1920 && decoded.videoCodec == "avc1" && abs(decoded.nominalFrameRate - 30) < 0.01, "\(decoded.width)×\(decoded.height), \(decoded.videoCodec), \(decoded.nominalFrameRate) fps")
            report.check("450 actual decoded video frames", decoded.frameCount == 450 && abs(decoded.videoEndSeconds - 15) < 0.001 && decoded.monotonic, "\(decoded.frameCount) decoded frames, presentation end \(decoded.videoEndSeconds) s, monotonic timestamps=\(decoded.monotonic); container/audio padding reported separately")
            report.check("AAC audio and lowered BGM volume", ["aac ", "mp4a"].contains(decoded.audioCodec) && decoded.audioRMS > 0.035 && decoded.audioRMS < 0.11, "codec=\(decoded.audioCodec), RMS=\(decoded.audioRMS), ideal 0.4 × 0.25 / sqrt(2) = 0.07071; decoder sample count includes codec padding")
            let proofDirectory = output.appendingPathComponent("proof", isDirectory: true)
            try FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true)
            try Fixtures.savePNG(firstPreviewImage, to: proofDirectory.appendingPathComponent("preview-first-frame.png"))
            for frame in [30, 150, 270, 390] {
                let stamp = CMTime(value: Int64(frame), timescale: 30)
                let start = Date()
                let (preview, _) = try await generator.image(at: stamp)
                let elapsed = Date().timeIntervalSince(start)
                report.metrics["previewSeekFrame\(frame)Seconds"] = elapsed
                guard let exported = decoded.images[frame] else { throw ValidationFailure.failed("Missing decoded representative frame \(frame)") }
                try Fixtures.savePNG(preview, to: proofDirectory.appendingPathComponent("preview-frame-\(frame).png"))
                try Fixtures.savePNG(exported, to: proofDirectory.appendingPathComponent("export-frame-\(frame).png"))
                try MediaInspection.contactSheet(preview: preview, exported: exported, frame: frame, to: proofDirectory.appendingPathComponent("comparison-frame-\(frame).png"))
                let comparison = try MediaInspection.compare(preview, exported)
                report.metrics["frame\(frame)MAE_0to1"] = comparison.mean
                report.metrics["frame\(frame)P99_0to1"] = comparison.p99
                report.check("Preview/export match frame \(frame)", comparison.mean < 0.035 && comparison.p99 < 0.20, "RGB mean absolute error \(comparison.mean), p99 \(comparison.p99); thresholds MAE < .035, p99 < .20 allow H.264/chroma loss")
            }
            for (frame, channel) in [(30, 0), (150, 1), (270, 2)] {
                let channels = try MediaInspection.averageColor(decoded.images[frame]!, normalizedRegion: CGRect(x: 0.7, y: 0.5, width: 0.15, height: 0.1))
                report.check("Scene order frame \(frame)", channels[channel] > 0.45 && channels[channel] > channels[(channel + 1) % 3] * 2 && channels[channel] > channels[(channel + 2) % 3] * 2, "Decoded RGB region=\(channels), expected dominant \(["red", "green", "blue"][channel])")
            }
            let endRGB = try MediaInspection.averageColor(decoded.images[390]!, normalizedRegion: CGRect(x: 0.7, y: 0.7, width: 0.15, height: 0.1))
            let endCardOCR = try MediaInspection.recognizeText(decoded.images[390]!)
            report.check("Image end card after 12 s", endCardOCR.replacingOccurrences(of: " ", with: "").contains("종현의다음이야기") && endRGB[2] > endRGB[1] * 1.3, "Decoded 13 s end card OCR=\(endCardOCR), purple background RGB=\(endRGB)")
            let ocr = try MediaInspection.recognizeText(decoded.images[30]!)
            report.check("Source trim frame mapping", ocr.contains("045"), "At timeline 1 s, source trim 0.5 s maps to source frame 45; OCR: \(ocr)")
            report.check("Korean title exists in decoded pixels", ocr.replacingOccurrences(of: " ", with: "").contains("종현의첫영상"), "Local Vision OCR on exported frame: \(ocr)")
            let cyanPixels = try MediaInspection.countCyanPixels(decoded.images[30]!)
            report.check("Transparent PNG exists in decoded pixels", cyanPixels > 2000, "\(cyanPixels) cyan pixels from separately imported transparent PNG; base fixture/title contain no cyan")
            report.files["proofDirectory"] = proofDirectory.path
            try await errorChecks(fixtures: fixtures, project: reloaded, documentURL: documentURL, plan: plan, directory: output, report: &report)
            report.unrun("App quit/relaunch and interactive playback", "CLI verifies disk reload and shared compositor preview. Native app lifecycle/playback/drop measurements require a separate GUI run.")
            report.unrun("Physical disk full", "No user storage was filled. Controlled low-capacity preflight test is reported separately as simulated; physical mid-write exhaustion remains untested.")
            report.unrun("Playback dropped frames", "Offline frame count is verified. Real-time AVPlayer dropped frames were not measured by this CLI.")
            report.limitations = ["Input fixtures are deterministic 540×960 SDR H.264; output is 1080×1920. No 4K, HEVC, HDR, VFR, or 29.97 fps claim.", "Preview measurements use the shared video composition through AVAssetImageGenerator, not interactive AVPlayer presentation latency.", "Process peak RSS includes fixture generation, export and validation; it is not an isolated app-only memory benchmark.", "Proof PNGs are provided for visual review. Automated OCR/color/pixel-difference checks do not replace human visual inspection."]
            report.passed = !report.checks.contains { $0.status == "failed" }
        } catch {
            report.check("Validation execution", false, String(describing: error))
            report.passed = false
        }
        report.metrics["totalSeconds"] = Date().timeIntervalSince(overallStart)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        report.metrics["processPeakRSSBytes"] = Double(usage.ru_maxrss)
        try writeReport(report, to: output)
        if !report.passed { throw ValidationFailure.failed("One or more checks failed; see \(output.appendingPathComponent("report.json").path)") }
        print("G0 automated validation passed. Report: \(output.appendingPathComponent("report.json").path)")
    }

    static func errorChecks(fixtures: FixtureSet, project: Project, documentURL: URL, plan: RenderPlan, directory: URL, report: inout ValidationReport) async throws {
        let rotated = try await MediaImporter.inspect(url: fixtures.rotated)
        report.check("90° rotation metadata", rotated.supported && rotated.width == 360 && rotated.height == 640, "Landscape 640×360 encoded source displays as \(rotated.width)×\(rotated.height) using preferred transform")
        var rotatedProject = Project(name: "Rotation proof")
        rotatedProject.assets = [rotated]
        rotatedProject.sequence.tracks[0].clips = [Clip(name: "90° fixture", assetID: rotated.id, duration: MediaTime(seconds: 1))]
        let rotatedPlan = try await TimelineRenderer.build(project: rotatedProject)
        let rotatedGenerator = AVAssetImageGenerator(asset: rotatedPlan.composition)
        rotatedGenerator.videoComposition = rotatedPlan.videoComposition
        rotatedGenerator.requestedTimeToleranceBefore = .zero; rotatedGenerator.requestedTimeToleranceAfter = .zero
        let (rotatedPreview, _) = try await rotatedGenerator.image(at: CMTime(value: 15, timescale: 30))
        let referenceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: fixtures.rotated))
        referenceGenerator.appliesPreferredTrackTransform = true
        referenceGenerator.requestedTimeToleranceBefore = .zero; referenceGenerator.requestedTimeToleranceAfter = .zero
        let (referenceSource, _) = try await referenceGenerator.image(at: CMTime(value: 15, timescale: 30))
        let reference = try MediaInspection.resized(referenceSource, width: 1080, height: 1920)
        let rotationDifference = try MediaInspection.compare(reference, rotatedPreview)
        try Fixtures.savePNG(rotatedPreview, to: directory.appendingPathComponent("proof/rotation-compositor.png"))
        try Fixtures.savePNG(reference, to: directory.appendingPathComponent("proof/rotation-avfoundation-reference.png"))
        report.check("Rotation compositor pixels", rotationDifference.mean < 0.035, "Shared compositor vs native preferred-transform decoder, RGB MAE=\(rotationDifference.mean)")
        let corrupt = directory.appendingPathComponent("잘못된 파일.mp4")
        try Data("not a media file".utf8).write(to: corrupt)
        do {
            let result = try await MediaImporter.inspect(url: corrupt)
            report.check("Corrupt input rejection", !result.supported, result.issue ?? "Importer returned supported=\(result.supported)")
        } catch { report.check("Corrupt input rejection", true, String(describing: error)) }
        var missing = project
        missing.assets[0].path = directory.appendingPathComponent("없는 원본.mp4").path
        missing.assets[0].relativePath = nil
        missing.assets[0].bookmark = nil
        do { _ = try await TimelineRenderer.build(project: missing, documentURL: documentURL); report.check("Missing media rejection", false, "Renderer unexpectedly accepted missing source") }
        catch { report.check("Missing media rejection", true, String(describing: error)) }
        let invalidDirectory = directory.appendingPathComponent("does-not-exist", isDirectory: true).appendingPathComponent("output.mp4")
        do { try await ExportJob().export(plan: plan, to: invalidDirectory) { _ in }; report.check("Invalid output directory", false, "Export unexpectedly accepted nonexistent parent") }
        catch { report.check("Invalid output directory", true, String(describing: error)) }
        let existing = directory.appendingPathComponent("must-not-overwrite.mp4")
        let sentinel = Data("existing-file-sentinel".utf8)
        try sentinel.write(to: existing)
        do { try await ExportJob().export(plan: plan, to: existing) { _ in }; report.check("Existing output preserved", false, "Export unexpectedly overwrote file") }
        catch { report.check("Existing output preserved", (try Data(contentsOf: existing)) == sentinel, String(describing: error)) }
        let readonly = FileManager.default.temporaryDirectory.appendingPathComponent("JHCut-read-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonly.path); try? FileManager.default.removeItem(at: readonly) }
        if FileManager.default.isWritableFile(atPath: readonly.path) {
            report.unrun("Unwritable output directory", "The current user/filesystem still permits writing chmod 0555; no false rejection pass claimed.")
        } else {
            do { try await ExportJob().export(plan: plan, to: readonly.appendingPathComponent("output.mp4")) { _ in }; report.check("Unwritable output directory", false, "Export unexpectedly accepted read-only directory") }
            catch { report.check("Unwritable output directory", true, String(describing: error)) }
        }
        let lowDiskOutput = directory.appendingPathComponent("simulated-low-disk.mp4")
        do { try await ExportJob(minimumFreeSpaceOverride: Int64.max).export(plan: plan, to: lowDiskOutput) { _ in }; report.check("Low disk preflight — simulated threshold", false, "Export unexpectedly bypassed capacity preflight") }
        catch { report.check("Low disk preflight — simulated threshold", error.localizedDescription.contains("공간이 부족") && !FileManager.default.fileExists(atPath: lowDiskOutput.path), "Controlled required-capacity override Int64.max; actual filesystem capacity queried; no disk filling. \(error.localizedDescription)") }
        let cancelOutput = directory.appendingPathComponent("cancelled-must-not-exist.mp4")
        if FileManager.default.fileExists(atPath: cancelOutput.path) { try FileManager.default.removeItem(at: cancelOutput) }
        let cancellingJob = ExportJob()
        let cancellationTask = Task {
            try await Task.sleep(nanoseconds: 80_000_000)
            cancellingJob.cancel()
        }
        do { try await cancellingJob.export(plan: plan, to: cancelOutput) { _ in }; cancellationTask.cancel(); report.check("Export cancellation", false, "Job completed despite cancellation") }
        catch {
            cancellationTask.cancel()
            let cancelled: Bool
            if case MediaEngineError.cancelled = error { cancelled = true } else { cancelled = false }
            report.check("Export cancellation", cancelled && !FileManager.default.fileExists(atPath: cancelOutput.path), "\(error.localizedDescription); no completed output file")
        }
        let partials = (try FileManager.default.contentsOfDirectory(atPath: directory.path)).filter { $0.contains("partial") }
        report.check("Partial output cleanup", partials.isEmpty, "Incomplete files after cancellation/errors: \(partials)")
    }

    static func writeReport(_ report: ValidationReport, to directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        var markdown = "# G0 validation — \(report.passed ? "AUTOMATED CHECKS PASSED" : "FAILED")\n\nGenerated \(report.generatedAt). Only executed checks marked passed.\n\n"
        markdown += "## Environment\n\n" + report.environment.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n"
        markdown += "## Checks\n\n| Check | Status | Evidence |\n|---|---|---|\n" + report.checks.map { "| \($0.name) | \($0.status) | \($0.detail.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")) |" }.joined(separator: "\n") + "\n\n"
        markdown += "## Measurements\n\n" + report.metrics.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n"
        markdown += "## Files\n\n" + report.files.sorted { $0.key < $1.key }.map { "- \($0.key): `\($0.value)`" }.joined(separator: "\n") + "\n\n"
        markdown += "## Limits\n\n" + report.limitations.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try markdown.write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    static func sysctlString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
        var data = [CChar](repeating: 0, count: size)
        return data.withUnsafeMutableBufferPointer { buffer in
            guard sysctlbyname(key, buffer.baseAddress, &size, nil, 0) == 0 else { return "unavailable" }
            return String(cString: buffer.baseAddress!)
        }
    }

    static func architecture() -> String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }
}

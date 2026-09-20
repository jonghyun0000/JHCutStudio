import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit
import Darwin
import JHCutCore

/// Offline, deterministic timeline regressions plus checks of the actual bundled media catalog.
/// This is evidence for the implemented G1 subset, not a claim that every G1 feature is complete.
enum UpgradeValidation {
    static func run(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = ValidationReport()
        report.gate = "G1 implemented subset — 60 s / 600 s regression"
        let started = Date()
        report.environment = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                              "architecture": G0Validation.architecture(), "chip": G0Validation.sysctlString("machdep.cpu.brand_string"), "hardwareModel": G0Validation.sysctlString("hw.model"),
                              "input": "Generated 540×960 SDR H.264 30fps, actual bundled PNG/WAV/MP3; output bitrate8Mbps H.264 +192kbps AAC",
                              "physicalMemoryBytes": String(ProcessInfo.processInfo.physicalMemory),
                              "processorCount": String(ProcessInfo.processInfo.processorCount),
                              "network": "No network used by this validation. Bundled media provenance and hashes verified locally.",
                              "engine": "Shared Core Image/Core Text video composition; H.264/AAC writer; 30 fps SDR Rec.709"]
        do {
            log("Verifying bundled library hashes and streaming all audio assets")
            let library = try AssetLibrary()
            try library.verify()
            var imported: [String: MediaAsset] = [:]
            var audioCount = 0, imageCount = 0
            let libraryStart = Date()
            for (index, item) in library.assets.enumerated() {
                var media = try await MediaImporter.inspect(url: library.url(for: item))
                guard media.supported else { throw ValidationFailure.failed("Bundled media unsupported: \(item.name): \(media.issue ?? "unknown")") }
                media.name = item.name
                media.provenance = AssetProvenance(sourceURL: item.sourceURL, author: item.author, license: item.license, licenseURL: item.licenseURL, sha256: item.sha256)
                imported[item.id] = media
                if media.kind == .audio {
                    let peaks = try await WaveformAnalyzer.analyze(url: library.url(for: item), bins: 64)
                    guard peaks.count == 64, peaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ValidationFailure.failed("Invalid library waveform: \(item.name)") }
                    audioCount += 1
                } else if media.kind == .image { imageCount += 1 }
                if index % 25 == 24 { log("Library decoded \(index + 1)/\(library.assets.count)") }
            }
            report.metrics["libraryVerificationSeconds"] = Date().timeIntervalSince(libraryStart)
            report.check("Bundled library checksums and decodability", imported.count == library.assets.count && audioCount > 100 && imageCount >= 24,
                         "\(library.assets.count) SHA-256 hashes, \(audioCount) streaming audio envelopes / \(imageCount) decoded PNGs; cache may serve previously validated unchanged audio")
            report.check("Library source separation", library.assets.contains { $0.origin == "downloaded" } && library.assets.contains { $0.origin == "original" },
                         "Downloaded CC0=\(library.assets.filter { $0.origin == "downloaded" }.count), original=\(library.assets.filter { $0.origin == "original" }.count); all retained source/author/license/hash records")
            guard let musicItem = library.assets.first(where: { $0.category == .music && ($0.duration ?? 0) > 120 }),
                  let sfxItem = library.assets.first(where: { $0.category == .sfx && ($0.duration ?? 0) > 0.15 }),
                  let overlayItem = library.assets.first(where: { $0.category == .overlay }),
                  let music = imported[musicItem.id], let effect = imported[sfxItem.id], let overlay = imported[overlayItem.id] else {
                throw ValidationFailure.failed("Required long music, SFX or PNG overlay missing from actual library")
            }
            report.files["musicSource"] = library.url(for: musicItem).path
            report.files["overlaySource"] = library.url(for: overlayItem).path
            log("Rendering all shared Core Text style presets")
            let styleFolder = directory.appendingPathComponent("styles", isDirectory: true)
            try FileManager.default.createDirectory(at: styleFolder, withIntermediateDirectories: true)
            for preset in TitlePreset.builtIns {
                let actual = try TitlePreviewRenderer.image(title: preset.title, size: CGSize(width: 1080, height: 1920))
                let small = try MediaInspection.resized(actual, width: 216, height: 384)
                try Fixtures.savePNG(small, to: styleFolder.appendingPathComponent(preset.id + ".png"))
            }
            report.check("Actual title preset rasterization", TitlePreset.builtIns.count >= 20, "\(TitlePreset.builtIns.count) original presets rendered by the export rasterizer; PNG previews saved")
            let fixtures = try await Fixtures.generate(in: directory.appendingPathComponent("fixtures", isDirectory: true))
            var videos: [MediaAsset] = []
            for url in fixtures.videos { videos.append(try await MediaImporter.inspect(url: url)) }
            let portrait = try makePortrait(videos: videos, music: music, effect: effect, overlay: overlay, report: &report)
            log("Building, reopening and rendering 60 s portrait timeline")
            try await render(project: portrait, label: "portrait-60s", seconds: 60, sampleFrames: [30,150,450,900,1350,1794], directory: directory, report: &report)
            let landscape = makeLandscape(videos: videos, music: music, overlay: overlay)
            log("Building, reopening and rendering 600 s landscape timeline (low-complexity regression)")
            try await render(project: landscape, label: "landscape-600s", seconds: 600, sampleFrames: [30,1800,9000,17970], directory: directory, report: &report)
            if let metadataData = try? Data(contentsOf: URL(fileURLWithPath: "Artifacts/EngineUpgrade/engine-checks-metadata.json")),
               let metadata = try? JSONDecoder().decode([String:String].self, from: metadataData), metadata["coreSHA256"] == currentCoreFingerprint(),
               let data = try? Data(contentsOf: URL(fileURLWithPath: "Artifacts/EngineUpgrade/engine-checks.json")),
               let checks = try? JSONDecoder().decode([EngineCheckReference].self, from: data) {
                report.check("Advanced 2 s pixel / pitch probe", checks.count >= 16 && checks.allSatisfy(\.passed), "\(checks.count) checks from separately executed Tests/EngineProbe.swift, including source-frame mapping, styled Korean OCR, grayscale, visual/audio fades, ease motion, 440 Hz at 2× and cached waveform")
                report.files["advancedProbe"] = URL(fileURLWithPath: "Artifacts/EngineUpgrade/engine-checks.json").standardizedFileURL.path
            } else { report.unrun("Advanced 2 s pixel / pitch probe", "Run Scripts/test-engine.sh Artifacts/EngineUpgrade against this exact built core; missing or stale binary fingerprint prevents reuse of an old result") }
            report.unrun("Interactive 10 minute playback dropped frames", "This CLI decodes exports fully and compares shared preview frames; it does not measure real-time AVPlayer presentation drops")
            report.unrun("Proxy workflow", "Proxy generation and mapping are not implemented in this upgrade")
            report.unrun("HEVC / JPEG / HDR / VFR / 4K inputs", "Input expansion remains disabled; tested input is SDR H.264, PNG and native decodable audio")
            report.limitations = [
                "60-second fixture: 18 source-video clips at 1×, 2× and 0.5×, imported SRT titles with original styles, actual library PNG, music and SFX; effects/fades/keyframes; no cross-dissolve claim.",
                "600-second fixture: 120 repeated 5-second generated H.264 clips, ten chapter titles, a real library PNG and explicit successive placements of the real music source. It is a low-complexity regression, not a general 10-minute editing performance guarantee.",
                "Audio source repetitions are separate visible timeline clips, not claimed as an original 600-second recording. AAC padding is reported separately and audio/video ends are compared within 0.10 s.",
                "Peak RSS covers library validation, fixture generation, composition, export and decoding in this CLI process; it is not isolated application memory.",
                "Local screenshot/OCR and pixel thresholds demonstrate rendered content; interactive UI and subjective design quality require separate review.",
                "This report covers the implemented G1 subset. Proxy media and overlapping cross-dissolves are not implemented; no claim of complete G1 is made."
            ]
            report.passed = !report.checks.contains { $0.status == "failed" }
        } catch {
            report.check("Upgrade pipeline completed", false, String(describing: error))
            finishMetrics(&report, started: started)
            try write(report, to: directory)
            throw error
        }
        finishMetrics(&report, started: started)
        try write(report, to: directory)
        guard report.passed else { throw ValidationFailure.failed("Upgrade regression failed; see \(directory.appendingPathComponent("report.json").path)") }
        log("UPGRADE_RESULT passed=\(report.checks.filter { $0.status == "passed" }.count), failed=0, report=\(directory.appendingPathComponent("report.json").path)")
    }
    private static func makePortrait(videos: [MediaAsset], music: MediaAsset, effect: MediaAsset, overlay: MediaAsset, report: inout ValidationReport) throws -> Project {
        var history = EditorHistory(project: Project(name: "60초 실제 편집 회귀"))
        try history.apply(.batch((videos + [music,effect,overlay]).map { .addAsset($0) }))
        let tracks = history.project.sequence.tracks
        var commands: [EditCommand] = [], cursor = MediaTime.zero
        for cycle in 0..<6 { for part in 0..<3 {
            let duration = MediaTime(seconds: part == 1 ? 2 : 4)
            var clip = Clip(name: "장면 \(cycle + 1)-\(part + 1)", assetID: videos[part].id, start: cursor, sourceStart: MediaTime(seconds: 0.5), duration: duration)
            clip.playbackRate = part == 1 ? PlaybackRate(numerator: 2) : part == 2 ? PlaybackRate(numerator: 1, denominator: 2) : nil
            clip.visual = VisualAdjustments(exposure: part == 1 ? 0.15 : 0, contrast: 1.05, saturation: part == 2 ? 0.65 : 1, cropLeft: part == 1 ? 0.03 : 0, cropRight: part == 1 ? 0.03 : 0)
            clip.fadeIn = MediaTime(5,30); clip.fadeOut = MediaTime(5,30)
            commands.append(.addClip(trackID: tracks[0].id, clip: clip)); cursor = cursor + duration
        }}
        try history.apply(.batch(commands))
        let cues = (0..<6).map { CaptionCue(start: MediaTime(seconds: Double($0 * 10)), duration: MediaTime(seconds: 9.5), text: "종현의 새로운 이야기 \($0 + 1)\n스타일과 소재로 완성하는 영상") }
        let srt = try SRTCodec.serialize(cues)
        let parsed = try SRTCodec.parse("\u{FEFF}" + srt.replacingOccurrences(of: "\n", with: "\r\n"))
        report.check("Korean SRT time/text roundtrip", parsed.map(\.start) == cues.map(\.start) && parsed.map(\.duration) == cues.map(\.duration) && parsed.map(\.text) == cues.map(\.text), "UTF-8 BOM, CRLF, Korean and multiline text; six rational-time cues")
        for (index,cue) in parsed.enumerated() {
            var title = TitlePreset.builtIns[[0,2,8,11,17,23][index]].title
            title.text = cue.text; title.x = 0.5; title.y = 0.82; title.fontSize = 62
            title.style?.alignment = .center; title.style?.maxLines = 2
            let clip = Clip(name: "SRT \(index + 1)", start: cue.start, duration: cue.duration, title: title)
            try history.apply(.addClip(trackID: tracks[2].id, clip: clip))
        }
        var graphic = Clip(name: overlay.name, assetID: overlay.id, duration: MediaTime(seconds: 60), transform: ClipTransform(scale: 0.7))
        graphic.fadeIn = MediaTime(seconds: 1); graphic.fadeOut = MediaTime(seconds: 1)
        graphic.keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(x: -80, scale: 0.65), interpolation: .ease),
                             TransformKeyframe(time: MediaTime(seconds: 30), transform: ClipTransform(x: 80, scale: 0.7), interpolation: .ease),
                             TransformKeyframe(time: MediaTime(seconds: 60), transform: ClipTransform(x: -80, scale: 0.65))]
        try history.apply(.addClip(trackID: tracks[1].id, clip: graphic))
        var bgm = Clip(name: music.name, assetID: music.id, duration: MediaTime(seconds: 60), volume: 0.18)
        bgm.audioFadeIn = MediaTime(seconds: 2); bgm.audioFadeOut = MediaTime(seconds: 2)
        try history.apply(.addClip(trackID: tracks[3].id, clip: bgm))
        let sfxTrack = Track(name: "실제 라이브러리 효과음", kind: .audio)
        try history.apply(.addTrack(sfxTrack))
        for time in [5,20,35,50] { try history.apply(.addClip(trackID: sfxTrack.id, clip: Clip(name: effect.name, assetID: effect.id, start: MediaTime(seconds: Double(time)), duration: min(effect.duration, MediaTime(seconds: 3)), volume: 0.35))) }
        let before = history.project
        let first = before.sequence.tracks[0].clips[0]
        try history.apply(.setRate(trackID: tracks[0].id, clipID: first.id, rate: PlaybackRate(numerator: 3, denominator: 2)))
        history.undo()
        report.check("Rate edit undo restores source mapping", history.project == before, "1×→1.5× retimes source range and subsequent same-track clips, then exact undo")
        try history.apply(.deriveSequence(name: "가로 파생 테스트", width: 1920, height: 1080))
        let derived = history.project
        history.undo()
        report.check("Derived ratio independence and undo", derived.sequence.id != before.sequence.id && derived.sequence.tracks[0].clips[0].id != first.id && history.project == before, "Independent sequence/track/clip IDs; source media reused; original restored")
        report.check("60 second edited project", before.sequence.duration == MediaTime(seconds: 60) && before.sequence.tracks[0].clips.count == 18, "18 video placements; 1×/2×/0.5×; 6 SRT titles, 1 PNG, music and 4 SFX")
        return history.project
    }
    private static func makeLandscape(videos: [MediaAsset], music: MediaAsset, overlay: MediaAsset) -> Project {
        var project = Project(name: "10분 가로 타임라인 회귀")
        project.assets = videos + [music, overlay]
        project.sequence.width = 1920; project.sequence.height = 1080
        project.sequence.tracks[0].clips = (0..<120).map { index in
            Clip(name: "원본 \(index % 3 + 1) · 배치 \(index + 1)", assetID: videos[index % 3].id, start: MediaTime(seconds: Double(index * 5)), duration: MediaTime(seconds: 5), transform: ClipTransform(fill: true))
        }
        project.sequence.tracks[1].clips = [Clip(name: overlay.name, assetID: overlay.id, duration: MediaTime(seconds: 600), transform: ClipTransform(x: 700, y: -250, scale: 0.25, opacity: 0.8))]
        project.sequence.tracks[2].clips = (0..<10).map { minute in
            let title = Title(text: "종현의 10분 영상\n\(minute + 1)번째 이야기", fontSize: 60, x: 0.5, y: 0.78, style: TextStyle(strokeWidth: 2, backgroundOpacity: 0.65, padding: 20, maxLines: 2))
            var clip = Clip(name: "챕터 \(minute + 1)", start: MediaTime(seconds: Double(minute * 60)), duration: MediaTime(seconds: 10), title: title)
            clip.fadeIn = MediaTime(seconds: 0.5); clip.fadeOut = MediaTime(seconds: 0.5)
            return clip
        }
        var cursor = MediaTime.zero
        while cursor < MediaTime(seconds: 600) {
            let duration = min(music.duration, MediaTime(seconds: 600) - cursor)
            var clip = Clip(name: music.name + " · 명시적 반복 배치", assetID: music.id, start: cursor, duration: duration, volume: 0.18)
            if cursor == .zero { clip.audioFadeIn = MediaTime(seconds: 2) }
            if cursor + duration == MediaTime(seconds: 600) { clip.audioFadeOut = MediaTime(seconds: 2) }
            project.sequence.tracks[3].clips.append(clip)
            cursor = cursor + duration
        }
        return project
    }
    private static func render(project: Project, label: String, seconds: Int, sampleFrames: [Int], directory: URL, report: inout ValidationReport) async throws {
        let document = directory.appendingPathComponent(label + ".jhcut")
        try ProjectStore.save(project, to: document)
        let reopened = try ProjectStore.load(from: document)
        report.check("\(label) save/reopen", reopened.sequence == project.sequence && reopened.assets.allSatisfy { $0.relativePath != nil }, "Exact edit/style/time equality with relative media references")
        let build = Date(), plan = try await TimelineRenderer.build(project: reopened, documentURL: document)
        report.metrics[label + "BuildSeconds"] = Date().timeIntervalSince(build)
        let preview = AVAssetImageGenerator(asset: plan.composition); preview.videoComposition = plan.videoComposition
        preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
        let firstStart = Date(); _ = try await preview.image(at: .zero)
        report.metrics[label + "FirstPreviewFrameSeconds"] = Date().timeIntervalSince(firstStart)
        let movie = directory.appendingPathComponent(label + ".mp4")
        if FileManager.default.fileExists(atPath: movie.path) { try FileManager.default.removeItem(at: movie) }
        let exportStart = Date()
        var last = -1
        try await ExportJob().export(plan: plan, to: movie) { value in
            let bucket = Int(value * 10)
            if bucket > last { last = bucket; log("\(label) export \(min(100, bucket * 10))%") }
        }
        report.metrics[label + "ExportSeconds"] = Date().timeIntervalSince(exportStart)
        log("\(label): decoding every video and audio sample")
        let decodeStart = Date(), decoded = try await MediaInspection.decode(movie)
        report.metrics[label + "DecodeSeconds"] = Date().timeIntervalSince(decodeStart)
        for (key,value) in decoded.metrics { report.metrics[label + key] = value }
        report.check("\(label) exact video samples", decoded.frameCount == seconds * 30 && decoded.monotonic && abs(decoded.videoEndSeconds - Double(seconds)) < 0.001,
                     "\(decoded.frameCount) decoded frames; monotonic=\(decoded.monotonic); video end=\(decoded.videoEndSeconds)s")
        report.check("\(label) output format", decoded.width == project.sequence.width && decoded.height == project.sequence.height && decoded.videoCodec == "avc1" && decoded.audioCodec == "aac " && abs(decoded.nominalFrameRate - 30) < 0.01,
                     "\(decoded.width)×\(decoded.height), H.264/AAC, \(decoded.nominalFrameRate)fps")
        let audioEnd = decoded.metrics["audioPresentationEndSeconds"] ?? 0
        report.check("\(label) audio continuity and endpoint", decoded.audioRMS > 0.00001 && abs(audioEnd - Double(seconds)) <= 0.1,
                     "All PCM samples decoded; RMS=\(decoded.audioRMS); audio end=\(audioEnd)s; video end=\(decoded.videoEndSeconds)s; AAC pad tolerance0.10s")
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        let proof = directory.appendingPathComponent(label + "-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        for frame in sampleFrames {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let seekStart = Date(), a = try await preview.image(at: time).image
            report.metrics[label + "PreviewFrame\(frame)Seconds"] = Date().timeIntervalSince(seekStart)
            let b = try await exported.image(at: time).image
            let difference = try MediaInspection.compare(a,b)
            report.check("\(label) preview/export frame\(frame)", difference.mean < 0.035 && difference.p99 < 0.20, "RGB MAE=\(difference.mean); p99=\(difference.p99), allowing H.264/chroma error")
            try Fixtures.savePNG(b, to: proof.appendingPathComponent("export-frame-\(frame).png"))
            if frame == sampleFrames[0] {
                let text = try MediaInspection.recognizeText(b)
                report.check("\(label) Korean title in encoded pixels", text.contains("종현"), text)
            }
        }
        report.files[label + "Movie"] = movie.path; report.files[label + "Project"] = document.path; report.files[label + "Proof"] = proof.path
        report.metrics[label + "OutputBytes"] = Double((try FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
    private static func currentCoreFingerprint() -> String? {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let coreURL = executable.deletingLastPathComponent().appendingPathComponent("libJHCutCore.dylib")
        guard let data = try? Data(contentsOf: coreURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private struct EngineCheckReference: Decodable { let name: String; let passed: Bool; let detail: String }
    private static func finishMetrics(_ report: inout ValidationReport, started: Date) {
        report.metrics["totalSeconds"] = Date().timeIntervalSince(started)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        report.metrics["processPeakRSSBytes"] = Double(usage.ru_maxrss)
    }
    private static func write(_ report: ValidationReport, to directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        var lines = ["# G1 구현 부분 실제 회귀 검증", "", "- 결과: \(report.passed ? "실행한 자동 검사 통과" : "실패 — 상세 확인 필요")", "- 생성 시각: \(report.generatedAt)", "", "| 검사 | 상태 | 근거 |", "|---|---|---|"]
        for check in report.checks { lines.append("| \(check.name) | \(check.status) | \(check.detail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " / ")) |") }
        lines += ["", "## 측정", ""]
        for key in report.metrics.keys.sorted() { lines.append("- \(key): \(report.metrics[key]!)") }
        lines += ["", "## 산출물", ""]
        for key in report.files.keys.sorted() { lines.append("- \(key): \(report.files[key]!)") }
        lines += ["", "## 한계와 미실행", ""] + report.limitations.map { "- " + $0 }
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }
    private static func log(_ text: String) { print(text); fflush(stdout) }
}

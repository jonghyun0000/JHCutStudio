// Standalone, real AVFoundation/ImageIO integration probe. See Scripts/test-compatibility.sh.
import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import JHCutCore

@main struct CompatibilityProbe {
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    struct Report: Codable { let generatedAt: Date; let coreSHA256: String; let checks: [Check]; let elapsedSeconds: Double; let scope: String }
    static func main() async {
        do { try await run() }
        catch { fputs("Compatibility probe failed: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Compatibility", isDirectory: true).standardizedFileURL
        let fixtureFolder = folder.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        let start = Date()
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(Check(name: name, passed: passed, detail: detail))
            print("[\(passed ? "PASS" : "FAIL")] \(name): \(detail)")
        }
        defer {
            let executable = Bundle.main.executableURL!
            let core = executable.deletingLastPathComponent().appendingPathComponent("libJHCutCore.dylib")
            let hash = (try? Data(contentsOf: core)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unavailable"
            let report = Report(generatedAt: Date(), coreSHA256: hash, checks: checks, elapsedSeconds: Date().timeIntervalSince(start),
                                scope: "Locally generated SDR samples only; macOS native encoders/decoders. Does not establish every camera profile, HEVC Main10, ProRes4444, DolbyVision, HDR, VFR or damaged-input compatibility. Proxy sample timing is checked exactly at 30000/1001 fps; preview source mapping at selected frames, not realtime frame-drop performance.")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
            let lines = checks.map { "| \($0.passed ? "PASS" : "FAIL") | \($0.name) | \($0.detail.replacingOccurrences(of: "|", with: "/")) |" }.joined(separator: "\n")
            try? ("# Compatibility / preview proxy evidence\n\n\(checks.filter(\.passed).count)/\(checks.count) checks passed. \(report.elapsedSeconds)s.\n\n\(report.scope)\n\n| Status | Check | Evidence |\n|---|---|---|\n\(lines)\n").write(to: folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
        let codecs: [(String, AVVideoCodecType)] = [("h264", .h264), ("hevc", .hevc), ("prores422", .proRes422), ("prores422hq", .proRes422HQ)]
        var formatAssets: [MediaAsset] = []
        for (name, codec) in codecs {
            let url = fixtureFolder.appendingPathComponent(name + ".mov")
            try await video(url: url, codec: codec, frames: 30, width: 640, height: 360)
            let asset = try await MediaImporter.inspect(url: url)
            let decoded = try await MediaInspection.decode(url)
            check("Actual \(name) SDR import/decode", asset.supported && decoded.frameCount == 30, "\(asset.codec), \(asset.width)×\(asset.height), decoded=\(decoded.frameCount), color=\(asset.colorInfo), issue=\(asset.issue ?? "none")")
            guard asset.supported else { throw ValidationFailure.failed("Codec was generated but importer rejected it") }
            formatAssets.append(asset)
        }
        let still = try baseImage()
        let ci = CIContext()
        for (name, type, orientation) in [("jpeg-rotate6", UTType.jpeg, 6), ("heic-rotate6", UTType.heic, 6), ("jpeg-mirror2", UTType.jpeg, 2), ("heic-mirror7", UTType.heic, 7)] {
            let url = fixtureFolder.appendingPathComponent(name + "." + (type == .jpeg ? "jpg" : "heic"))
            try writeImage(still, url: url, type: type, orientation: orientation)
            let asset = try await MediaImporter.inspect(url: url)
            let loaded = try MediaImporter.loadImage(url: url)
            let expectedCI = CIImage(cgImage: still).oriented(forExifOrientation: Int32(orientation))
            let reference = ci.createCGImage(expectedCI, from: expectedCI.extent)!
            let delta = try MediaInspection.compare(loaded, reference)
            check("Actual \(name) EXIF pixels", asset.supported && asset.width == reference.width && asset.height == reference.height && delta.mean < 0.03,
                  "\(asset.codec), \(asset.width)×\(asset.height); orientation \(orientation), sRGB MAE=\(delta.mean)")
            try Fixtures.savePNG(loaded, to: folder.appendingPathComponent(name + "-decoded.png"))
            formatAssets.append(asset)
        }
        // Explicit non-SDR / unknown color fixtures must not silently enter the SDR timeline.
        let hdr = fixtureFolder.appendingPathComponent("pq-tagged-hevc.mov")
        try await video(url: hdr, codec: .hevc, frames: 3, width: 640, height: 360, hdr: true)
        let hdrInfo = try await MediaImporter.inspect(url: hdr)
        check("HDR transfer metadata rejection", !hdrInfo.supported && (hdrInfo.issue?.contains("HDR") ?? false), hdrInfo.issue ?? "unexpected acceptance")
        let depthURL = fixtureFolder.appendingPathComponent("16bit-linear.png")
        let depthContext = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 16, bytesPerRow: 800,
                                     space: CGColorSpace(name: CGColorSpace.linearSRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        depthContext.setFillColor(CGColor(gray: 0.5, alpha: 1)); depthContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        try writeImage(depthContext.makeImage()!, url: depthURL, type: .png, orientation: 1)
        let depthInfo = try await MediaImporter.inspect(url: depthURL)
        check("Unverified 16bit still rejection", !depthInfo.supported, depthInfo.issue ?? "unexpected acceptance")
        let unknown = fixtureFolder.appendingPathComponent("unprofiled.jpg")
        try writeImage(still, url: unknown, type: .jpeg, orientation: 1, excludeProfile: true)
        let unknownInfo = try await MediaImporter.inspect(url: unknown)
        check("Unprofiled JPEG rejection", !unknownInfo.supported, unknownInfo.issue ?? "unexpected acceptance: \(unknownInfo.colorInfo)")
        let unknownHEIC = fixtureFolder.appendingPathComponent("unprofiled.heic")
        try writeImage(still, url: unknownHEIC, type: .heic, orientation: 1, excludeProfile: true)
        let unknownHEICInfo = try await MediaImporter.inspect(url: unknownHEIC)
        check("Unspecified HEIC color rejection", !unknownHEICInfo.supported, unknownHEICInfo.issue ?? "unexpected acceptance")
        var montage = Project(name: "Actual HEVC ProRes JPEG HEIC compatibility")
        montage.sequence.width = 1280; montage.sequence.height = 720
        montage.assets = formatAssets
        montage.sequence.tracks[0].clips = formatAssets.enumerated().map { i, asset in
            Clip(name: asset.name, assetID: asset.id, start: MediaTime(seconds: Double(i)), duration: MediaTime(seconds: 1))
        }
        let montagePlan = try await TimelineRenderer.build(project: montage)
        let montageURL = folder.appendingPathComponent("formats-to-h264.mp4")
        try await ExportJob().export(plan: montagePlan, to: montageURL) { _ in }
        let montageDecode = try await MediaInspection.decode(montageURL)
        check("All eight inputs render to H264", montageDecode.videoCodec == "avc1" && montageDecode.frameCount == 240,
              "1280×720 / \(montageDecode.frameCount) decoded frames / \(montageDecode.videoEndSeconds)s / \(montageDecode.videoCodec)")
        let rendered = generator(montagePlan), exported = AVAssetImageGenerator(asset: AVURLAsset(url: montageURL))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
        for i in 0..<formatAssets.count {
            let t = CMTime(value: Int64(i * 30 + 15), timescale: 30)
            let a = try await rendered.image(at: t).image, b = try await exported.image(at: t).image
            let delta = try MediaInspection.compare(a, b)
            check("\(formatAssets[i].name) shared/output", delta.mean < 0.025, "MAE=\(delta.mean)")
        }
        let proxySource = fixtureFolder.appendingPathComponent("rotated-2997.mov")
        try await video(url: proxySource, codec: .h264, frames: 120, width: 1920, height: 1080,
                        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0), frameDuration: CMTime(value: 1001, timescale: 30_000))
        let original = try await MediaImporter.inspect(url: proxySource)
        let cacheURL = folder.appendingPathComponent("proxy-cache", isDirectory: true)
        let cache = ProxyCache(directory: cacheURL)
        let progress = ProgressBox()
        let proxyStart = Date()
        let proxy = try await cache.generate(for: proxySource) { progress.record($0) }
        let proxySeconds = Date().timeIntervalSince(proxyStart)
        let proxyAsset = AVURLAsset(url: proxy)
        let proxyTrack = try await proxyAsset.loadTracks(withMediaType: .video).first!
        let proxySize = try await proxyTrack.load(.naturalSize)
        let proxyTransform = try await proxyTrack.load(.preferredTransform)
        let proxyFPS = try await proxyTrack.load(.nominalFrameRate)
        let sourceTrack = try await AVURLAsset(url: proxySource).loadTracks(withMediaType: .video).first!
        let sourceFPS = try await sourceTrack.load(.nominalFrameRate)
        let originalTiming = try await timing(proxySource), proxyTiming = try await timing(proxy)
        check("Proxy 29.97 sample timing exact", originalTiming == proxyTiming && originalTiming.count == 120 && abs(sourceFPS - proxyFPS) < 0.001,
              "\(originalTiming.count) source / \(proxyTiming.count) proxy PTS+effective-duration samples, sourcefps=\(sourceFPS), proxyfps=\(proxyFPS), generated=\(proxySeconds)s")
        check("Proxy bounds and baked orientation", proxySize.width <= 1280 && proxySize.height <= 720 && proxySize.height > proxySize.width && proxyTransform.isIdentity,
              "Source display1080×1920 => stored\(proxySize.width)×\(proxySize.height), identity=\(proxyTransform.isIdentity)")
        check("Proxy progress completion", progress.valid, "Callbacks=\(progress.count), monotonic finite [0,1], final1")
        var project = Project(name: "Proxy original source mapping")
        project.assets = [original]
        var clip = Clip(name: "Retimed rotated video", assetID: original.id, sourceStart: MediaTime(seconds: 0.25), duration: MediaTime(seconds: 2))
        clip.playbackRate = PlaybackRate(numerator: 3, denominator: 2)
        project.sequence.tracks[0].clips = [clip]
        let originalPlan = try await TimelineRenderer.build(project: project)
        let proxyPlan = try await TimelineRenderer.build(project: project, mediaURLOverrides: [original.id: proxy])
        let originalPreview = generator(originalPlan), proxyPreview = generator(proxyPlan)
        check("Proxy designation and original source export plan", proxyPlan.usesProxyMedia && !originalPlan.usesProxyMedia, "Explicit transient override only; project asset path remains original")
        for frame in [0, 7, 23, 45, 59] {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let a = try await originalPreview.image(at: time).image, b = try await proxyPreview.image(at: time).image
            let delta = try MediaInspection.compare(a, b)
            check("Retimed proxy orientation/source frame \(frame)", delta.mean < 0.025, "MAE=\(delta.mean), source seconds=0.25+1.5×\(time.seconds); source PTS preserved exactly")
            if frame == 23 {
                try Fixtures.savePNG(a, to: folder.appendingPathComponent("original-preview.png")); try Fixtures.savePNG(b, to: folder.appendingPathComponent("proxy-preview.png"))
                var sourceText = "", proxyText = ""
                for orientation: Int32 in [6,8] {
                    let sourceCI = CIImage(cgImage: a).oriented(forExifOrientation: orientation)
                    let proxyCI = CIImage(cgImage: b).oriented(forExifOrientation: orientation)
                    sourceText += try MediaInspection.recognizeText(ci.createCGImage(sourceCI, from: sourceCI.extent)!) + " "
                    proxyText += try MediaInspection.recognizeText(ci.createCGImage(proxyCI, from: proxyCI.extent)!) + " "
                }
                let expected = Int((0.25 + 1.5 * time.seconds) * 30_000 / 1001)
                let nearby = [expected-1,expected,expected+1].map { String(format: "%03d", $0) }
                check("Decoded original/proxy frame index within one", nearby.contains(where: sourceText.contains) && nearby.contains(where: proxyText.contains),
                      "Expected source frame≈\(expected); source OCR=\(sourceText), proxy OCR=\(proxyText)")
            }
        }
        // New cache instance proves persistence; mtime change and truncated output prove invalidation.
        let persisted = ProxyCache(directory: cacheURL)
        let hit = try await persisted.cachedURL(for: proxySource)
        check("Persistent cache hit", hit == proxy, "New actor reads existing fingerprint and metadata")
        let damagedDirectory = folder.appendingPathComponent("truncated-cache")
        try FileManager.default.copyItem(at: cacheURL, to: damagedDirectory)
        let truncated = damagedDirectory.appendingPathComponent(proxy.lastPathComponent)
        try Data([0,1,2,3]).write(to: truncated)
        let damagedCache = ProxyCache(directory: damagedDirectory)
        let damagedHit = try await damagedCache.cachedURL(for: proxySource)
        check("Truncated proxy cache rejection", damagedHit == nil, "Published size metadata prevents reuse of incomplete cache file")
        let size = try await persisted.sizeBytes()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: proxySource.path)
        let stale = try await persisted.cachedURL(for: proxySource)
        check("Source fingerprint invalidation", stale == nil, "Same path changed modification time invalidates cache")
        // A tiny quota must fail without publishing an oversized result.
        let smallCache = ProxyCache(directory: folder.appendingPathComponent("small-cache"), limitBytes: 100)
        var quotaRejected = false
        do { _ = try await smallCache.generate(for: proxySource) } catch { quotaRejected = true }
        let smallSize = try await smallCache.sizeBytes()
        check("Proxy cache capacity enforced", quotaRejected && smallSize == 0, "100-byte quota rejects before publication")
        // Cancellation includes in-flight encoding, not just an already-cancelled task.
        let cancellationFolder = folder.appendingPathComponent("cancel-cache")
        let cancelCache = ProxyCache(directory: cancellationFolder)
        let cancelProgress = ProgressBox()
        let job = Task { try await cancelCache.generate(for: proxySource) { cancelProgress.record($0) } }
        for _ in 0..<500 { if cancelProgress.count > 0 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        job.cancel()
        var cancelled = false
        do { _ = try await job.value } catch is CancellationError { cancelled = true } catch { print("Cancellation other error: \(error)") }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cancellationFolder.path)) ?? []
        check("In-flight proxy cancellation cleanup", cancelled && leftovers.isEmpty, "Progress callbacks before cancel=\(cancelProgress.count); directory entries=\(leftovers)")
        let evictionFolder = folder.appendingPathComponent("eviction-cache")
        let eviction = ProxyCache(directory: evictionFolder, limitBytes: max(size * 3 / 2, 10_000))
        let first = try await eviction.generate(for: proxySource)
        let copy = fixtureFolder.appendingPathComponent("same-content-other-file.mov")
        try FileManager.default.copyItem(at: proxySource, to: copy)
        let sentinel = evictionFolder.appendingPathComponent("user-note.txt")
        try "must survive cache clear".write(to: sentinel, atomically: true, encoding: .utf8)
        let second = try await eviction.generate(for: copy)
        let remaining = try await eviction.sizeBytes()
        check("Owned-file LRU eviction", !FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path) && remaining <= max(size * 3 / 2, 10_000), "Second entry evicts first; bytes=\(remaining)")
        await eviction.setProtectedURLs([second])
        try await eviction.removeAll()
        check("Cache clear protects active media", FileManager.default.fileExists(atPath: second.path) && FileManager.default.fileExists(atPath: sentinel.path), "Current plan URL pinned; unrelated user-note.txt untouched")
        await eviction.setProtectedURLs([])
        try await eviction.removeAll()
        check("Cache clear only removes owned entries", (try await eviction.sizeBytes()) == 0 && FileManager.default.fileExists(atPath: sentinel.path), "All owned media removed; sentinel preserved")
        // Real original AAC audio survives a silent video proxy override.
        let bgm = fixtureFolder.appendingPathComponent("tone.wav"); try Fixtures.audio(to: bgm, seconds: 4)
        let sound = try await MediaImporter.inspect(url: bgm)
        var withAudio = project; withAudio.assets.append(sound)
        withAudio.sequence.tracks[3].clips = [Clip(name: "tone", assetID: sound.id, duration: MediaTime(seconds: 2), volume: 0.25)]
        let soundPlan = try await TimelineRenderer.build(project: withAudio)
        let audioOriginal = folder.appendingPathComponent("original-with-audio.mp4")
        try await ExportJob().export(plan: soundPlan, to: audioOriginal) { _ in }
        let audioInfo = try await MediaImporter.inspect(url: audioOriginal)
        let audioProxy = try await cache.generate(for: audioOriginal)
        var audioProject = Project(name: "Original source audio stays in proxy playback"); audioProject.assets = [audioInfo]
        audioProject.sequence.tracks[0].clips = [Clip(name: "Original audio", assetID: audioInfo.id, duration: MediaTime(seconds: 2))]
        let audioPreviewPlan = try await TimelineRenderer.build(project: audioProject, mediaURLOverrides: [audioInfo.id: audioProxy])
        let audioTracks = try await audioPreviewPlan.composition.loadTracks(withMediaType: .audio)
        check("Proxy playback retains original audio", audioTracks.count == 1 && audioPreviewPlan.audioMix.inputParameters.count == 1,
              "Silent video proxy; original source audio composition track and mix retained")
        let blockedURL = folder.appendingPathComponent("forbidden-proxy-export.mp4")
        var proxyExportRejected = false
        do { try await ExportJob().export(plan: audioPreviewPlan, to: blockedURL) { _ in } } catch { proxyExportRejected = true }
        check("Proxy plan cannot export", proxyExportRejected && !FileManager.default.fileExists(atPath: blockedURL.path), "ExportJob rejects proxy plan before creating output")
        let originalExportPlan = try await TimelineRenderer.build(project: audioProject)
        let finalURL = folder.appendingPathComponent("original-export-after-proxy.mp4")
        try await ExportJob().export(plan: originalExportPlan, to: finalURL) { _ in }
        let final = try await MediaInspection.decode(finalURL)
        check("Final export rebuilds originals", !originalExportPlan.usesProxyMedia && final.width == 1080 && final.height == 1920 && final.frameCount == 60 && final.audioRMS > 0.04,
              "\(final.width)×\(final.height), \(final.frameCount) frames, audioRMS=\(final.audioRMS)")
        for bitrate in [4_000_000, 16_000_000] {
            let output = folder.appendingPathComponent("original-\(bitrate)-bps.mp4")
            try await ExportJob(videoBitRate: bitrate).export(plan: originalExportPlan, to: output) { _ in }
            let decoded = try await MediaInspection.decode(output)
            let byteCount = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            check("Actual \(bitrate / 1_000_000)Mbps setting export", decoded.frameCount == 60 && decoded.videoCodec == "avc1" && decoded.audioRMS > 0.04,
                  "Full decode60frames, AAC audio, file=\(byteCount) bytes; configured average target is not constant measured bitrate")
        }
        let invalidURL = folder.appendingPathComponent("invalid-bitrate.mp4")
        var bitrateRejected = false
        do { try await ExportJob(videoBitRate: 123).export(plan: originalExportPlan, to: invalidURL) { _ in } } catch { bitrateRejected = true }
        check("Invalid bitrate has no output", bitrateRejected && !FileManager.default.fileExists(atPath: invalidURL.path), "Unsupported setting123 rejected before file creation")
        // Missing original must block even if a proxy exists.
        var missingProject = audioProject; missingProject.assets[0].path = fixtureFolder.appendingPathComponent("missing-original.mp4").path; missingProject.assets[0].bookmark = nil
        var missingRejected = false
        do { _ = try await TimelineRenderer.build(project: missingProject, mediaURLOverrides: [audioInfo.id: audioProxy]) } catch { missingRejected = true }
        check("Proxy cannot conceal missing original", missingRejected, "Renderer inspects original before applying video override")
        let ok = checks.allSatisfy(\.passed)
        print("COMPATIBILITY_RESULT \(checks.filter(\.passed).count)/\(checks.count) passed; \(folder.path)")
        guard ok else { throw ValidationFailure.failed("See compatibility report failures") }
    }
    static func generator(_ plan: RenderPlan) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: plan.composition); generator.videoComposition = plan.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return generator
    }
    static func baseImage() throws -> CGImage {
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors: [CGColor] = [CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1), CGColor(red: 0.9, green: 0.8, blue: 0.1, alpha: 1)]
        for i in 0..<4 { context.setFillColor(colors[i]); context.fill(CGRect(x: (i%2)*300, y: (i/2)*200, width: 300, height: 200)) }
        Fixtures.drawText("TOP LEFT", at: CGPoint(x: 20, y: 340), size: 35, context: context)
        Fixtures.drawText("ORIENTATION", at: CGPoint(x: 20, y: 35), size: 35, context: context)
        return context.makeImage()!
    }
    static func writeImage(_ image: CGImage, url: URL, type: UTType, orientation: Int, excludeProfile: Bool = false) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw ValidationFailure.failed("Image encoder unavailable: \(type)") }
        var options: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95,
                                       kCGImageDestinationEmbedThumbnail: false,
                                       kCGImageDestinationOptimizeColorForSharing: false]
        if !excludeProfile { options[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifColorSpace: 1] }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ValidationFailure.failed("Image encode failed: \(type)") }
        if excludeProfile && type == .jpeg {
            let bytes = Array(try Data(contentsOf: url))
            var stripped = Data(bytes.prefix(2)); var offset = 2
            while offset + 3 < bytes.count, bytes[offset] == 0xff {
                let marker = bytes[offset+1]
                if marker == 0xda { stripped.append(contentsOf: bytes[offset...]); break }
                let length = Int(bytes[offset+2]) * 256 + Int(bytes[offset+3])
                guard length >= 2, offset + 2 + length <= bytes.count else { throw ValidationFailure.failed("JPEG metadata fixture parser failed") }
                if marker != 0xe1 && marker != 0xe2 { stripped.append(contentsOf: bytes[offset..<(offset+2+length)]) }
                offset += 2 + length
            }
            try stripped.write(to: url)
        }
    }
    static func video(url: URL, codec: AVVideoCodecType, frames: Int, width: Int, height: Int,
                      transform: CGAffineTransform = .identity, frameDuration: CMTime = CMTime(value: 1, timescale: 30), hdr: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = frameDuration.timescale
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: hdr ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2]]
        if codec == .h264 || codec == .hevc { settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 4_000_000, AVVideoAllowFrameReorderingKey: false] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.mediaTimeScale = frameDuration.timescale; input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
           kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw ValidationFailure.failed("Cannot encode \(codec)") }; writer.add(input)
        guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData && writer.status == .writing { try await Task.sleep(nanoseconds: 1_000_000) }
            try autoreleasepool {
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else { throw ValidationFailure.failed("Video fixture buffer failed") }
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                     bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                let shades: [CGColor] = [CGColor(red: 0.7, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.65, blue: 0.15, alpha: 1), CGColor(red: 0.1, green: 0.2, blue: 0.75, alpha: 1), CGColor(red: 0.75, green: 0.65, blue: 0.1, alpha: 1)]
                for i in 0..<4 { context.setFillColor(shades[i]); context.fill(CGRect(x: (i%2)*width/2, y: (i/2)*height/2, width: width/2, height: height/2)) }
                Fixtures.drawText(String(format: "FRAME %03d", frame), at: CGPoint(x: width/10, y: height/2), size: CGFloat(width)/12, context: context)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: (frame * max(1,width/130)) % (width-30), y: 30, width: 24, height: 50))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))) else { throw writer.error ?? ValidationFailure.failed("Append failed") }
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames)))
        await writer.finishWriting(); guard writer.status == .completed else { throw writer.error! }
    }
    static func timing(_ url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); guard reader.startReading() else { throw reader.error! }
        let range = try await track.load(.timeRange)
        var result: [String] = []
        var pending = output.copyNextSampleBuffer()
        while let sample = pending {
            let next = output.copyNextSampleBuffer(); pending = next
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sample)
            let declaredDuration = CMSampleBufferGetDuration(sample)
            let nextPTS = next.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? range.end
            let pts = MediaTime(rawPTS), duration = MediaTime(declaredDuration.isNumeric && declaredDuration > .zero ? declaredDuration : nextPTS - rawPTS)
            result.append("\(pts.value)/\(pts.timescale):\(duration.value)/\(duration.timescale)")
        }
        guard reader.status == .completed else { throw reader.error! }; return result
    }
}
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Double] = []
    func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return !values.isEmpty && values.last == 1 && values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
}

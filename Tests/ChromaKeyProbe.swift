import Foundation
import AVFoundation
import CoreImage
import ImageIO
import CoreVideo
@testable import JHCutCore

/// Analytic geometry/alpha tests are independent of the production kernel. The old
/// renderer is used ONLY as the compatibility oracle. No generated pixels are ground truth.
@main struct ChromaKeyProbe {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // Direct geometry isolates kernel math at float precision; compatibility/media retain
    // the default pipeline context. This does not change any product renderer setting.
    static let geometryContext = CIContext(options: [.workingColorSpace: linear, .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue), .cacheIntermediates: false])
    static let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
    }
    static func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    static func close(_ a: [Double], _ b: [Double], tolerance: Double = 0.00005) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.isFinite && abs($0 - $1) <= tolerance }
    }
    static func image(_ rgb: [Double], alpha: Double = 1, extent: CGRect) -> CIImage {
        var components: [CGFloat] = rgb.map { CGFloat($0) }; components.append(CGFloat(alpha))
        return CIImage(color: CIColor(cgColor: CGColor(colorSpace: linear, components: components)!)).cropped(to: extent)
    }
    static func geometryPixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Double] {
        pixel(image, x, y, using: geometryContext)
    }
    static func pixel(_ image: CIImage, _ x: Int, _ y: Int, using selectedContext: CIContext? = nil) -> [Double] {
        var floats = [Float](repeating: 0, count: 4)
        floats.withUnsafeMutableBytes { buffer in
            (selectedContext ?? context).render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        }
        return floats.map(Double.init)
    }
    static func bytes(_ image: CIImage, extent: CGRect) -> [UInt8] {
        let width = Int(extent.width), height = Int(extent.height)
        var result = [UInt8](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return result
    }
    static func visual(_ key: ChromaKey) -> VisualAdjustments { var value = VisualAdjustments(); value.chromaKey = key; return value }
    static func geometry() throws {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        check("sRGB midpoint transfer", abs(ChromaKey.linearChannel(0.5) - 0.21404114048223255) < 0.000000000001)
        for (name, rgb, opponent) in [("green", [0.0, 1, 0], [1.0, 0, 0]), ("blue", [0.0, 0, 1], [0.0, 1, 0]), ("red", [1.0, 0, 0], [0.0, 0, 1])] {
            let key = ChromaKey(keyRed: rgb[0], keyGreen: rgb[1], keyBlue: rgb[2], spillReduction: 0)
            for level in [1.0, 0.5, 0.125] {
                let result = try ChromaKeyRenderer.apply(to: image(rgb.map { $0 * level }, extent: rect), key: key)
                check("selected \(name) removes brightness \(level) without changing extent", result.extent == rect && close(geometryPixel(result, 10, 20), [0, 0, 0, 0]))
            }
            let foreground = try ChromaKeyRenderer.apply(to: image(opponent, alpha: 0.5, extent: rect), key: key)
            check("\(name) keeps opposite color and partial alpha", close(geometryPixel(foreground, 10, 20), opponent.map { $0 * 0.5 } + [0.5]))
            let black = try ChromaKeyRenderer.apply(to: image([0, 0, 0], extent: rect), key: key)
            check("chromatic \(name) retains black foreground", close(geometryPixel(black, 10, 20), [0, 0, 0, 1]))
        }
        var key = ChromaKey(similarity: 0.25, softness: 0.5, spillReduction: 0)
        let cyan = image([0, 0.5, 0.5], alpha: 0.5, extent: rect)
        let half = try ChromaKeyRenderer.apply(to: cyan, key: key)
        check("analytic distance .5 and half matte multiply original alpha", close(geometryPixel(half, 10, 20), [0, 0.125, 0.125, 0.25]))
        key.spillReduction = 1
        let spill = try ChromaKeyRenderer.apply(to: cyan, key: key)
        // Fixed independent double-precision projection values, not a product helper oracle.
        check("full spill projection retains matte", close(geometryPixel(spill, 10, 20), [0.038188422729317266, 0.10979297707870588, 0.16318842272931727, 0.25]))
        key.spillReduction = 0.5
        let partial = try ChromaKeyRenderer.apply(to: cyan, key: key)
        check("half spill strength", close(geometryPixel(partial, 10, 20), [0.019094211364658633, 0.11739648853935294, 0.14409421136465864, 0.25]))
        key.spillReduction = 1
        let gray = image([0.4, 0.4, 0.4], extent: rect)
        let graySpill = try ChromaKeyRenderer.apply(to: gray, key: key)
        let grayPlain = try ChromaKeyRenderer.apply(to: gray, key: ChromaKey(similarity: 0.25, softness: 0.5, spillReduction: 0))
        check("neutral foreground unchanged by spill", close(geometryPixel(graySpill, 10, 20), geometryPixel(grayPlain, 10, 20)))
        let red = try ChromaKeyRenderer.apply(to: image([1, 0, 0], extent: rect), key: key)
        check("outside band red unchanged", close(geometryPixel(red, 10, 20), [1, 0, 0, 1]))
        let invisible = try ChromaKeyRenderer.apply(to: image([0, 0.5, 0.5], alpha: 0, extent: rect), key: key)
        check("zero alpha stays zero", close(geometryPixel(invisible, 10, 20), [0, 0, 0, 0]))
        key.spillReduction = 0; key.softness = 0; key.similarity = 0.5
        let boundary = try ChromaKeyRenderer.apply(to: cyan, key: key)
        check("hard threshold includes equality", close(geometryPixel(boundary, 10, 20), [0, 0, 0, 0]))
        key.similarity = 0.49
        let above = try ChromaKeyRenderer.apply(to: cyan, key: key)
        check("hard threshold preserves above boundary", close(geometryPixel(above, 10, 20), [0, 0.25, 0.25, 0.5]))
        key.similarity = 1
        let all = try ChromaKeyRenderer.apply(to: cyan, key: key)
        check("similarity one removes all", close(geometryPixel(all, 10, 20), [0, 0, 0, 0]))
        let neutral = ChromaKey(keyRed: 0.5, keyGreen: 0.5, keyBlue: 0.5, similarity: 0.01, softness: 0, spillReduction: 1)
        let exactGray = try ChromaKeyRenderer.apply(to: image([0.21404114048223255, 0.21404114048223255, 0.21404114048223255], extent: rect), key: neutral)
        let brighterGray = try ChromaKeyRenderer.apply(to: image([0.5, 0.5, 0.5], extent: rect), key: neutral)
        check("gray key separates absolute linear brightness", close(geometryPixel(exactGray, 10, 20), [0, 0, 0, 0]) && close(geometryPixel(brighterGray, 10, 20), [0.5, 0.5, 0.5, 1]))
        let blackKey = ChromaKey(keyRed: 0, keyGreen: 0, keyBlue: 0, similarity: 0, softness: 0)
        let erasedBlack = try ChromaKeyRenderer.apply(to: image([0, 0, 0], extent: rect), key: blackKey)
        let preservedGray = try ChromaKeyRenderer.apply(to: image([0.5, 0.5, 0.5], extent: rect), key: blackKey)
        check("black key erases black only", close(geometryPixel(erasedBlack, 10, 20), [0, 0, 0, 0]) && close(geometryPixel(preservedGray, 10, 20), [0.5, 0.5, 0.5, 1]))
        var maskVisual = VisualAdjustments(); maskVisual.shapeMask = ShapeMask(kind: .rectangle, centerX: 110.5/200, centerY: 50.5/100, width: 0.5, height: 1, feather: 0.2)
        let masked = try ShapeMaskRenderer.apply(to: half, visual: maskVisual)
        check("mask after chroma multiplies existing coverage", close(geometryPixel(masked, 165, 70), [0, 0.0625, 0.0625, 0.125]))
    }
    static func writePNG(_ input: CIImage, _ url: URL) throws {
        guard let cg = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw ProjectError("PNG fixture creation") }
        CGImageDestinationAddImage(writer, cg, nil)
        guard CGImageDestinationFinalize(writer) else { throw ProjectError("PNG fixture save") }
    }
    static func documents(_ project: Project, root: URL) throws {
        var original = project
        for index in original.sequence.tracks[1].clips.indices { original.sequence.tracks[1].clips[index].visual = nil }
        let document = root.appendingPathComponent("Masks.jhcut")
        try ProjectStore.save(original, to: document)
        let oldData = try Data(contentsOf: document)
        check("no key omits optional key", !String(decoding: oldData, as: UTF8.self).contains("chromaKey"))
        var oldGreen = original; var appearance = VisualAdjustments(); appearance.greenScreen = 0.5
        oldGreen.sequence.tracks[1].clips[0].visual = appearance
        let oldURL = root.appendingPathComponent("LegacyGreen.jhcut"); try ProjectStore.save(oldGreen, to: oldURL)
        let reopened = try ProjectStore.load(from: oldURL)
        check("old green document retains stored strength without promotion", reopened.sequence == oldGreen.sequence && reopened.sequence.tracks[1].clips[0].visual?.chromaKey == nil)
        try ProjectStore.save(project, to: document)
        let retained = ProjectStore.beforeChromaKeyURL(for: document)
        check("first shape save preserves exact previous bytes", try Data(contentsOf: retained) == oldData)
        check("all geometry reopens without loss", try ProjectStore.load(from: document).sequence == project.sequence)
        try ProjectStore.save(project, to: document)
        check("later save keeps immutable original", try Data(contentsOf: retained) == oldData)
        let saved = try Data(contentsOf: document)
        // Unknown keys and kind/version are invalid, never silently dropped by Codable.
        let changed = String(decoding: saved, as: UTF8.self).replacingOccurrences(of: "\"softness\"", with: "\"futureSoftness\"")
        let future = root.appendingPathComponent("Unknown-field.jhcut"); try Data(changed.utf8).write(to: future)
        check("unknown nested field rejects load", rejected { _ = try ProjectStore.load(from: future) })
        let mutators: [(String, (inout ChromaKey) -> Void)] = [
            ("version", { $0.version = 2 }), ("negative red", { $0.keyRed = -0.01 }), ("green above one", { $0.keyGreen = 1.01 }),
            ("sum above one", { $0.similarity = 0.9; $0.softness = 0.2 }), ("negative softness", { $0.softness = -0.1 }),
            ("spill above one", { $0.spillReduction = 1.01 }), ("nonfinite", { $0.keyBlue = .nan })
        ]
        for (name, mutate) in mutators {
            var bad = project; var shape = ChromaKey(); mutate(&shape)
            bad.sequence.tracks[1].clips[0].visual = visual(shape)
            check("validator rejects \(name)", rejected { try ProjectValidator.validate(bad) })
        }
        var dual = project; dual.sequence.tracks[1].clips[0].visual?.greenScreen = 0
        check("validator rejects ambiguous old and new key", rejected { try ProjectValidator.validate(dual) })
        var title = project; title.sequence.tracks[2].clips = [Clip(title: Title(text: "NO"))]
        title.sequence.tracks[2].clips[0].visual = visual(ChromaKey())
        check("validator rejects title key outside supported media", rejected { try ProjectValidator.validate(title) })
        var sound = project
        let audio = MediaAsset(name: "audio", path: "/probe/absent.wav", kind: .audio, duration: MediaTime(seconds: 4), hasAudio: true)
        sound.assets.append(audio); sound.sequence.tracks[3].clips = [Clip(assetID: audio.id, visual: visual(ChromaKey()))]
        check("validator rejects audio key", rejected { try ProjectValidator.validate(sound) })
        var history = EditorHistory(project: original)
        let track = original.sequence.tracks[1]
        try history.apply(.updateClip(trackID: track.id, clip: project.sequence.tracks[1].clips[0]))
        let edited = history.project
        history.undo(); check("key one Undo exact project", history.project == original && !history.canUndo)
        history.redo(); check("key Redo exact project", history.project == edited)
        var locked = original; locked.sequence.tracks[1].isLocked = true
        var lockedHistory = EditorHistory(project: locked)
        check("locked key update atomic", rejected { try lockedHistory.apply(.updateClip(trackID: track.id, clip: project.sequence.tracks[1].clips[0])) } && lockedHistory.project == locked)
        var audioSeparation = original
        var videoAsset = project.assets[1]; videoAsset.id = UUID(); videoAsset.kind = .video
        videoAsset.duration = MediaTime(seconds: 4); videoAsset.hasAudio = true
        audioSeparation.assets.append(videoAsset)
        var videoClip = Clip(assetID: videoAsset.id, sourceStart: MediaTime(seconds: 0.5), duration: MediaTime(seconds: 3), visual: visual(ChromaKey()))
        videoClip.blendMode = .multiply
        audioSeparation.sequence.tracks[0].clips = [videoClip]
        var audioHistory = EditorHistory(project: audioSeparation)
        try audioHistory.apply(.separateAudio(trackID: audioSeparation.sequence.tracks[0].id, clipID: videoClip.id, destinationTrackID: nil))
        let separatedAudioClips = audioHistory.project.sequence.tracks.filter { $0.kind == .audio }.flatMap(\.clips)
        check("separate audio creates exactly one audio clip", separatedAudioClips.count == 1)
        if separatedAudioClips.count == 1, let separatedAudio = separatedAudioClips.first,
           let connection = separatedAudio.connection {
            let sameSource = separatedAudio.assetID == videoAsset.id && separatedAudio.id != videoClip.id
            let sameTiming = separatedAudio.start == videoClip.start && separatedAudio.duration == videoClip.duration
                && separatedAudio.sourceStart == videoClip.sourceStart && separatedAudio.sourceDuration == videoClip.sourceDuration
            let sameConnection = connection.parentID == videoClip.id && connection.sourceStart == videoClip.sourceStart
                && connection.sourceDuration == videoClip.sourceDuration
            check("separated audio preserves source identity, timing and parent connection", sameSource && sameTiming && sameConnection)
            check("existing separated audio clears key and blend", separatedAudio.visual == nil && separatedAudio.blendMode == nil)
        } else {
            check("separated audio requires an existing clip and connection", false)
        }
        if let preservedVideo = audioHistory.project.sequence.tracks[0].clips.first(where: { $0.id == videoClip.id }) {
            check("audio separation preserves original video appearance", preservedVideo.assetID == videoClip.assetID
                && preservedVideo.visual == videoClip.visual && preservedVideo.blendMode == videoClip.blendMode
                && preservedVideo.sourceStart == videoClip.sourceStart && preservedVideo.sourceDuration == videoClip.sourceDuration)
        } else {
            check("audio separation requires original video to remain", false)
        }
        try Data("corrupt retained copy".utf8).write(to: retained)
        check("corrupt immutable old copy blocks save", rejected { try ProjectStore.save(project, to: document) })
        check("blocked save preserves current document", try Data(contentsOf: document) == saved)
        try oldData.write(to: retained) // only repair this probe's own intentionally damaged fixture
    }
    static func legacyCompatibility(root: URL) async throws {
        // Both sides cross the actual AV compositor BGRA8/Rec.709 buffer and CGImage boundary.
        // The oracle class below is a literal copy of the pre-chroma compositor, not production's new key path.
        let extent = CGRect(x: 0, y: 0, width: 320, height: 180)
        let base = image([0.1, 0.8, 0.2], alpha: 0.5, extent: extent)
        let stripe = image([0.7, 0.2, 0.5], alpha: 0.25, extent: CGRect(x: 90, y: 0, width: 70, height: 180)).composited(over: base)
        let url = root.appendingPathComponent("legacy-nonuniform.png"); try writePNG(stripe, url)
        let asset = try await MediaImporter.inspect(url: url)
        let rec709 = CVImageBufferCreateColorSpaceFromAttachments([
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ] as CFDictionary)!.takeRetainedValue()
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 180)
        func rgba(_ image: CIImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 240 * 180 * 4)
            pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 240 * 4, bounds: bounds, format: .RGBA8, colorSpace: rec709) }
            return pixels
        }
        for strength in [0.0, 0.5, 1.0] {
            var legacy = VisualAdjustments(cropLeft: 0.125, cropRight: 0.125); legacy.greenScreen = strength
            var project = Project(name: "Legacy RGBA8 compatibility")
            project.sequence.width = 240; project.sequence.height = 180; project.assets = [asset]
            project.sequence.tracks[0].clips = [Clip(assetID: asset.id, duration: MediaTime(seconds: 1), visual: legacy)]
            let plan = try await TimelineRenderer.build(project: project, transparentBackground: true)
            let generator = AVAssetImageGenerator(asset: plan.composition); generator.videoComposition = plan.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let actual = CIImage(cgImage: try generator.copyCGImage(at: CMTime(value: 15, timescale: 30), actualTime: nil))
            let baselinePlan = try await TimelineRenderer.build(project: project, transparentBackground: true)
            baselinePlan.videoComposition.customVideoCompositorClass = ChromaLegacyBaselineCompositor.self
            let baselineGenerator = AVAssetImageGenerator(asset: baselinePlan.composition)
            baselineGenerator.videoComposition = baselinePlan.videoComposition
            baselineGenerator.requestedTimeToleranceBefore = .zero; baselineGenerator.requestedTimeToleranceAfter = .zero
            let expected = CIImage(cgImage: try baselineGenerator.copyCGImage(at: CMTime(value: 15, timescale: 30), actualTime: nil))
            check("legacy full RGBA8 nonuniform partial alpha crop strength \(strength)", rgba(actual) == rgba(expected))
        }
    }
    static func media(root: URL) async throws {
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        let backURL = root.appendingPathComponent("back.png")
        try writePNG(image([0.25, 0.5, 0.75], extent: canvas), backURL)
        let back = try await MediaImporter.inspect(url: backURL)
        var project = Project(name: "Selected color actual preview and export")
        project.sequence.width = 640; project.sequence.height = 360; project.assets = [back]
        project.sequence.tracks[0].clips = [Clip(assetID: back.id, duration: MediaTime(seconds: 4))]
        for (index, rgb) in [[0.0, 0.5, 0], [0.0, 0, 0.5], [0.5, 0, 0], [0.0, 0.5, 0.5]].enumerated() {
            let url = root.appendingPathComponent("front-\(index).png"); try writePNG(image(rgb, extent: canvas), url)
            let asset = try await MediaImporter.inspect(url: url); project.assets.append(asset)
            let key = index == 3 ? ChromaKey(similarity: 0.25, softness: 0.5, spillReduction: 0) : ChromaKey(keyRed: index == 2 ? 1 : 0, keyGreen: index == 0 ? 1 : 0, keyBlue: index == 1 ? 1 : 0, spillReduction: 0)
            var appearance = visual(key)
            if index == 3 { appearance.shapeMask = ShapeMask(kind: .rectangle, width: 0.5, height: 0.5, feather: 0) }
            var clip = Clip(assetID: asset.id, start: MediaTime(seconds: Double(index)), duration: MediaTime(seconds: 1), visual: appearance)
            if index == 3 { clip.blendMode = .multiply; clip.transform = ClipTransform(x: 40, y: 20, scale: 0.8, rotation: 90) }
            project.sequence.tracks[1].clips.append(clip)
        }
        try documents(project, root: root)
        let plan = try await TimelineRenderer.build(project: project)
        let movie = root.appendingPathComponent("chroma-key.mp4")
        try await ExportJob().export(plan: plan, to: movie) { _ in }
        let preview = AVAssetImageGenerator(asset: plan.composition); preview.videoComposition = plan.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        for (name, generator) in [("preview", preview), ("export", exported)] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for index in 0..<4 {
                let actual = CIImage(cgImage: try generator.copyCGImage(at: CMTime(seconds: Double(index) + 0.5, preferredTimescale: 30), actualTime: nil))
                let wanted: [Double] = index == 3 ? [0.125, 0.375, 0.5625, 1] : [0.25, 0.5, 0.75, 1]
                check("actual \(name) selected-color scene \(index)", close(pixel(actual, 360, 200), wanted, tolerance: 0.025))
                check("actual \(name) retains crop/fit extent scene \(index)", close(pixel(actual, 30, 30), [0.25, 0.5, 0.75, 1], tolerance: 0.025))
            }
        }
        let decoded = try await MediaInspection.decode(movie)
        check("four-second output fully decodes", decoded.frameCount == 120 && abs(decoded.videoEndSeconds - 4) < 0.0001)
        // A partially transparent masked overlay changes an ordinary lower caption's colors.
        var captions = project; captions.sequence.tracks[1].clips = []
        var caption = Clip(duration: MediaTime(seconds: 4), title: Title(text: "KEY", fontSize: 72, colorHex: "FFFFFF", x: 0.5, y: 0.5, style: TextStyle(padding: 0, shadow: false)))
        caption.captionRole = .original; captions.sequence.tracks[2].clips = [caption]
        var cover = Clip(assetID: project.assets[4].id, duration: MediaTime(seconds: 4), visual: visual(ChromaKey(similarity: 0.25, softness: 0.5, spillReduction: 0)))
        cover.transform.opacity = 0.5
        captions.sequence.tracks.append(Track(name: "Masked overlay above title", kind: .overlay, clips: [cover]))
        let captionPlan = try await TimelineRenderer.build(project: captions)
        let expectation = OutputExpectation.from(project: captions, plan: captionPlan)
        check("upper mask routes ordinary caption to full reference", expectation.captions.first?.pixelComparable == false && expectation.captions.first?.dynamicClip?.id == caption.id && expectation.captions.first?.pixelExclusionReason?.contains("overlying shape mask/chroma key") == true)
        let positive = root.appendingPathComponent("chroma-caption.mp4")
        try await ExportJob().export(plan: captionPlan, to: positive) { _ in }
        let good = try await OutputQuality.check(output: positive, expectation: expectation)
        _ = try OutputQuality.write(good, to: root.appendingPathComponent("Reports"), name: "chroma-caption-good")
        check("correct caption below mask verifies", good.errors == 0 && good.burnIn.contains { $0.verified == true } && !good.burnIn.contains { $0.verified == false })
        captions.sequence.tracks[2].clips = []
        let missingPlan = try await TimelineRenderer.build(project: captions)
        let negative = root.appendingPathComponent("chroma-caption-missing.mp4")
        try await ExportJob().export(plan: missingPlan, to: negative) { _ in }
        let bad = try await OutputQuality.check(output: negative, expectation: expectation)
        _ = try OutputQuality.write(bad, to: root.appendingPathComponent("Reports"), name: "chroma-caption-missing")
        check("missing caption below mask fails", bad.errors > 0 && bad.burnIn.contains { $0.verified == false })
        captions.sequence.tracks[2].clips = [caption]
        captions.sequence.tracks[captions.sequence.tracks.count - 1].clips[0].transform.opacity = 1
        captions.sequence.tracks[captions.sequence.tracks.count - 1].clips[0].visual = visual(ChromaKey(keyRed: 1, keyGreen: 0, keyBlue: 0, similarity: 0.08, softness: 0.12, spillReduction: 0))
        let obscuredPlan = try await TimelineRenderer.build(project: captions)
        let obscuredExpectation = OutputExpectation.from(project: captions, plan: obscuredPlan)
        let obscuredMovie = root.appendingPathComponent("chroma-caption-obscured.mp4")
        try await ExportJob().export(plan: obscuredPlan, to: obscuredMovie) { _ in }
        let obscured = try await OutputQuality.check(output: obscuredMovie, expectation: obscuredExpectation)
        _ = try OutputQuality.write(obscured, to: root.appendingPathComponent("Reports"), name: "chroma-caption-obscured")
        check("fully obscured caption stays unverified", obscured.burnIn.contains { $0.verified == nil } && !obscured.burnIn.contains { $0.verified == true })
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/ChromaKeyProbe")
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        try geometry(); try await legacyCompatibility(root: root); try await media(root: root)
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("CHROMA_KEY_RESULT checks=\(checks.count) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}

// Literal baseline captured before selected-color support. Keep separate from product code.
private final class ChromaLegacyBaselineCompositor: NSObject, AVVideoCompositing {
    private static let greenKey = CIColorKernel(source: "kernel vec4 key(__sample s, float strength) { vec3 rgb = unpremultiply(s).rgb; float excess = max(0.0, rgb.g - max(rgb.r, rgb.b)); float alpha = 1.0 - smoothstep(0.05, max(0.06, 1.0-strength), excess); return s * alpha; }")
    private let queue = DispatchQueue(label: "studio.jhcut.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
    // Match AVFoundation's video Rec.709 profile (HDTV), rather than the distinct generic graphics BT.709 ICC profile.
    private let colorSpace = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary)!.takeRetainedValue()
    public var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]() ]
    }
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? TimelineInstruction else {
                    request.finish(with: MediaEngineError.failed("잘못된 합성 명령입니다.")); return
                }
                guard let buffer = request.renderContext.newPixelBuffer() else {
                    request.finish(with: MediaEngineError.failed("영상 프레임 메모리를 확보하지 못했습니다.")); return
                }
                let bounds = CGRect(origin: .zero, size: instruction.canvas)
                let background = CIImage(color: instruction.transparentBackground ? .clear : .black).cropped(to: bounds)
                var groups: [(families: Set<UUID>, scene: BlendScene)] = []
                for layer in instruction.layers {
                    let source: CIImage
                    if let fixed = layer.image { source = fixed }
                    else if let trackID = layer.trackID, let frame = request.sourceFrame(byTrackID: trackID) {
                        var raw = CIImage(cvPixelBuffer: frame)
                        // Before the track rotation: the analysed path is in decoded-frame axes.
                        if let plan = layer.stabilization { raw = Self.stabilized(raw, plan: plan, clip: layer.clip, localSeconds: (request.compositionTime - layer.clip.start.cmTime).seconds) }
                        let oriented = raw.transformed(by: layer.orientation)
                        source = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
                    } else {
                        request.finish(with: MediaEngineError.failed("타임라인 영상 프레임을 디코딩하지 못했습니다: \(layer.clip.name)")); return
                    }
                    let localTime = MediaTime(request.compositionTime - layer.clip.start.cmTime)
                    let transform = layer.clip.evaluatedTransform(at: localTime)
                    var image = source
                    if let visual = layer.clip.visual {
                        let rect = image.extent
                        let crop = CGRect(x: rect.minX + rect.width * visual.cropLeft,
                                          y: rect.minY + rect.height * visual.cropBottom,
                                          width: rect.width * (1 - visual.cropLeft - visual.cropRight),
                                          height: rect.height * (1 - visual.cropTop - visual.cropBottom))
                        image = image.cropped(to: crop)
                        if visual.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": visual.exposure]) }
                        if visual.contrast != 1 || visual.saturation != 1 {
                            image = image.applyingFilter("CIColorControls", parameters: ["inputContrast": visual.contrast, "inputSaturation": visual.saturation])
                        }
                        if visual.temperature != nil || visual.tint != nil {
                            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: visual.temperature ?? 6500, y: visual.tint ?? 0)])
                        }
                        if visual.shadows != nil || visual.highlights != nil {
                            image = image.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25 + (visual.shadows ?? 0)), "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + (visual.highlights ?? 0)), "inputPoint4": CIVector(x: 1, y: 1)])
                        }
                        if let lut = visual.lut {
                            let data = lut.values.withUnsafeBytes { Data($0) }
                            image = image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": lut.size, "inputCubeData": data, "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
                        }
                        if let strength = visual.greenScreen, strength > 0 {
                            guard let keyed = Self.greenKey?.apply(extent: image.extent, arguments: [image, strength]) else { request.finish(with: MediaEngineError.failed("크로마키를 적용하지 못했습니다.")); return }
                            image = keyed
                        }
                        do { image = try ShapeMaskRenderer.apply(to: image, visual: visual) }
                        catch { request.finish(with: error); return }
                    }
                    let input = image.extent
                    if layer.clip.title == nil {
                        let sx = bounds.width / input.width, sy = bounds.height / input.height
                        let fitted = (transform.fill ? max(sx, sy) : min(sx, sy)) * transform.scale
                        image = image.transformed(by: CGAffineTransform(translationX: -input.midX, y: -input.midY))
                            .transformed(by: CGAffineTransform(scaleX: fitted, y: fitted))
                            .transformed(by: CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
                            .transformed(by: CGAffineTransform(translationX: bounds.midX + transform.x, y: bounds.midY + transform.y))
                    } else {
                        // Title raster already uses normalized title coordinates on a full-size canvas.
                        if let animation = layer.clip.titleAnimation, !animation.isEmpty, let title = layer.clip.title {
                            let state = animation.state(at: localTime.seconds, clipDuration: layer.clip.duration.seconds)
                            // Scaling is about the title's own anchor (Title.x/y are fractions of the canvas, y up).
                            image = TransitionRenderer.animate(image, state: state, anchor: CGPoint(x: title.x * bounds.width, y: title.y * bounds.height), canvas: bounds, textBounds: layer.titleBounds)
                        }
                        image = image.transformed(by: CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
                            .transformed(by: CGAffineTransform(scaleX: transform.scale, y: transform.scale))
                            .transformed(by: CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
                            .transformed(by: CGAffineTransform(translationX: bounds.midX + transform.x, y: bounds.midY + transform.y))
                    }
                    let opacity = transform.opacity * ClipEnvelopes.fade(at: localTime.cmTime, duration: layer.clip.duration.cmTime, fadeIn: layer.clip.fadeIn?.cmTime, fadeOut: layer.clip.fadeOut?.cmTime)
                    if opacity < 1 {
                        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
                    }
                    let family = TransitionEditing.family(layer.clip)
                    let scene = BlendScene.clip(image, layer.clip.blendMode ?? .normal)
                    // Pair only the outgoing/incoming scenes. Decorative overlays are composed
                    // afterward at their own positions and never move with a push transition.
                    if let transition = layer.clip.transition, layer.clip.title == nil, transition.isActive(at: localTime), transition.independentFade == true || transition.kind != .dissolve || layer.clip.fadeIn == nil {
                        if let outgoing = layer.outgoingFamily, let index = groups.lastIndex(where: { $0.families.contains(outgoing) }) {
                            groups[index].scene = .transition(transition, transition.progress(at: localTime), scene, groups[index].scene)
                            groups[index].families.insert(family)
                        } else {
                            let clear = CIImage(color: .clear).cropped(to: bounds)
                            groups.append(([family], .transition(transition, transition.progress(at: localTime), scene, .clip(clear, .normal))))
                        }
                    } else {
                        groups.append(([family], scene))
                    }
                }
                let result: CIImage
                do {
                    result = try groups.reduce(background) { try $1.scene.render(over: $0, bounds: bounds) }
                } catch { request.finish(with: error); return }
                context.render(result, to: buffer, bounds: bounds, colorSpace: colorSpace)
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                request.finish(withComposedVideoFrame: buffer)
            }
        }
    }
    /// Removes the measured shake: translate/rotate by the correction and zoom by the plan's constant
    /// factor so the frame edges never show. Coordinates are those of the decoded frame.
    static func stabilized(_ image: CIImage, plan: StabilizationPlan, clip: Clip, localSeconds: Double) -> CIImage {
        let rate = (clip.playbackRate ?? PlaybackRate()).multiplier
        let c = plan.correction(atSource: clip.sourceStart.seconds + max(0, localSeconds) * rate)
        let e = image.extent
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .transformed(by: CGAffineTransform(scaleX: plan.zoom, y: plan.zoom))
            .transformed(by: CGAffineTransform(rotationAngle: c.angle))
            .transformed(by: CGAffineTransform(translationX: e.midX + c.x * e.width, y: e.midY + c.y * e.height))
            .cropped(to: e)
    }
    public func cancelAllPendingVideoCompositionRequests() {
        // Queue drain guarantees no previous request survives completion of this cancellation call.
        queue.sync { }
    }
}

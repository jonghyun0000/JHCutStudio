import Foundation
import AVFoundation
import CoreImage
import ImageIO
@testable import JHCutCore

/// Analytic geometry/alpha tests are independent of the production kernel. The old
/// renderer is used ONLY as the compatibility oracle. No generated pixels are ground truth.
@main struct ShapeMaskProbe {
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
    static func visual(_ shape: ShapeMask) -> VisualAdjustments { var value = VisualAdjustments(); value.shapeMask = shape; return value }
    static func oldEllipse(_ source: CIImage) -> CIImage {
        // Literal pre-feature pipeline; retained to detect a visual change to older documents.
        let extent = source.extent
        let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.96, "inputRadius1": 1.0, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: extent.width / 2, y: extent.height / 2))
            .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
        return source.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage(color: .clear).cropped(to: extent), "inputMaskImage": mask]).cropped(to: extent)
    }
    static func geometry() throws {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let source = image([0.75, 0.5, 0.25], alpha: 0.5, extent: rect)
        // Center at pixel center (110.5,70.5); half-axes 50 and 30 source pixels.
        for kind in ShapeMaskKind.allCases {
            var mask = ShapeMask(kind: kind, centerX: 0.5025, centerY: 0.505, width: 0.5, height: 0.6, feather: 0)
            let hard = try ShapeMaskRenderer.apply(to: source, visual: visual(mask))
            check("\(kind) center preserves premultiplied RGB/alpha", close(geometryPixel(hard, 110, 70), [0.375, 0.25, 0.125, 0.5]))
            check("\(kind) exterior becomes transparent without changing extent", hard.extent == rect && close(geometryPixel(hard, 165, 70), [0, 0, 0, 0]))
            let corner: [Double] = kind == .rectangle ? [0.375, 0.25, 0.125, 0.5] : [0, 0, 0, 0]
            check("\(kind) analytic .8/.8 corner distinguishes shape", close(geometryPixel(hard, 150, 94), corner))
            mask.feather = 0.2
            let soft = try ShapeMaskRenderer.apply(to: source, visual: visual(mask))
            // radius .9, feather [ .8, 1 ] -> t=.5 -> cubic smoothstep=.5.
            let half: [Double] = [0.1875, 0.125, 0.0625, 0.25]
            check("\(kind) horizontal feather halves existing alpha", close(geometryPixel(soft, 155, 70), half))
            check("\(kind) vertical feather scales with its own axis", close(geometryPixel(soft, 110, 97), half))
            check("\(kind) feather is inward only", close(geometryPixel(soft, 161, 70), [0, 0, 0, 0]))
            mask.feather = 0; mask.rotation = 90
            let rotated = try ShapeMaskRenderer.apply(to: source, visual: visual(mask))
            check("\(kind) 90-degree rotation happens in source pixels", close(geometryPixel(rotated, 150, 70), [0, 0, 0, 0]) && close(geometryPixel(rotated, 110, 110), [0.375, 0.25, 0.125, 0.5]))
            mask.rotation = 0; mask.centerX = 0.2525; mask.width = 0.2
            let shifted = try ShapeMaskRenderer.apply(to: source, visual: visual(mask))
            check("\(kind) center includes nonzero crop origin and independent width", close(geometryPixel(shifted, 60, 70), [0.375, 0.25, 0.125, 0.5]) && close(geometryPixel(shifted, 110, 70), [0, 0, 0, 0]))
            let transparent = image([0.75, 0.5, 0.25], alpha: 0, extent: rect)
            check("\(kind) mask cannot create alpha from transparent source", close(geometryPixel(try ShapeMaskRenderer.apply(to: transparent, visual: visual(mask)), 60, 70), [0, 0, 0, 0]))
        }
        let stripe = image([1, 0, 0.5], alpha: 0.25, extent: CGRect(x: 10, y: 20, width: 80, height: 100)).composited(over: source)
        let positioned = stripe.transformed(by: CGAffineTransform(scaleX: 1.5, y: 1.4)).transformed(by: CGAffineTransform(translationX: -80, y: -30))
        var legacy = VisualAdjustments(); legacy.ellipseMask = true
        for (name, input) in [("solid partial alpha", source), ("nonuniform partial alpha", stripe), ("oversized positioned", positioned)] {
            let old = oldEllipse(input), new = try ShapeMaskRenderer.apply(to: input, visual: legacy)
            check("old ellipse full RGBA8 compatibility: \(name)", bytes(old, extent: input.extent) == bytes(new, extent: input.extent))
            let unchanged = try ShapeMaskRenderer.apply(to: input, visual: VisualAdjustments())
            check("absent mask full RGBA8 compatibility: \(name)", bytes(input, extent: input.extent) == bytes(unchanged, extent: input.extent))
        }
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
        check("no mask omits optional key", !String(decoding: oldData, as: UTF8.self).contains("shapeMask"))
        var oldEllipseProject = original
        var oldAppearance = VisualAdjustments(); oldAppearance.ellipseMask = true
        oldEllipseProject.sequence.tracks[1].clips[0].visual = oldAppearance
        let oldEllipseDocument = root.appendingPathComponent("LegacyEllipse.jhcut")
        try ProjectStore.save(oldEllipseProject, to: oldEllipseDocument)
        let oldEllipseReopened = try ProjectStore.load(from: oldEllipseDocument)
        check("legacy ellipse reopens without promotion", oldEllipseReopened.sequence == oldEllipseProject.sequence && oldEllipseReopened.sequence.tracks[1].clips[0].visual?.shapeMask == nil)
        try ProjectStore.save(project, to: document)
        let retained = ProjectStore.beforeShapeMasksURL(for: document)
        check("first shape save preserves exact previous bytes", try Data(contentsOf: retained) == oldData)
        check("all geometry reopens without loss", try ProjectStore.load(from: document).sequence == project.sequence)
        try ProjectStore.save(project, to: document)
        check("later save keeps immutable original", try Data(contentsOf: retained) == oldData)
        let saved = try Data(contentsOf: document)
        // Unknown keys and kind/version are invalid, never silently dropped by Codable.
        for (label, from, to) in [("kind", "\"ellipse\"", "\"polygon\""), ("key", "\"feather\"", "\"futureFeather\"")] {
            let changed = String(decoding: saved, as: UTF8.self).replacingOccurrences(of: from, with: to)
            let future = root.appendingPathComponent("Unknown-\(label).jhcut"); try Data(changed.utf8).write(to: future)
            check("unknown mask \(label) rejects load", rejected { _ = try ProjectStore.load(from: future) })
        }
        let mutators: [(String, (inout ShapeMask) -> Void)] = [
            ("version", { $0.version = 2 }), ("zero width", { $0.width = 0 }), ("negative height", { $0.height = -1 }),
            ("center", { $0.centerX = 3 }), ("rotation", { $0.rotation = 181 }), ("feather", { $0.feather = 0.51 }),
            ("nonfinite", { $0.centerY = .nan })
        ]
        for (name, mutate) in mutators {
            var bad = project; var shape = ShapeMask(); mutate(&shape)
            bad.sequence.tracks[1].clips[0].visual = visual(shape)
            check("validator rejects \(name)", rejected { try ProjectValidator.validate(bad) })
        }
        var dual = project; dual.sequence.tracks[1].clips[0].visual?.ellipseMask = true
        check("validator rejects ambiguous old and new mask", rejected { try ProjectValidator.validate(dual) })
        var title = project; title.sequence.tracks[2].clips = [Clip(title: Title(text: "NO"))]
        title.sequence.tracks[2].clips[0].visual = visual(ShapeMask())
        check("validator rejects title mask outside supported media", rejected { try ProjectValidator.validate(title) })
        var sound = project
        let audio = MediaAsset(name: "audio", path: "/probe/absent.wav", kind: .audio, duration: MediaTime(seconds: 4), hasAudio: true)
        sound.assets.append(audio); sound.sequence.tracks[3].clips = [Clip(assetID: audio.id, visual: visual(ShapeMask()))]
        check("validator rejects audio mask", rejected { try ProjectValidator.validate(sound) })
        var history = EditorHistory(project: original)
        let track = original.sequence.tracks[1]
        try history.apply(.updateClip(trackID: track.id, clip: project.sequence.tracks[1].clips[0]))
        let edited = history.project
        history.undo(); check("mask one Undo exact project", history.project == original && !history.canUndo)
        history.redo(); check("mask Redo exact project", history.project == edited)
        var locked = original; locked.sequence.tracks[1].isLocked = true
        var lockedHistory = EditorHistory(project: locked)
        check("locked mask update atomic", rejected { try lockedHistory.apply(.updateClip(trackID: track.id, clip: project.sequence.tracks[1].clips[0])) } && lockedHistory.project == locked)
        var audioSeparation = original
        var videoAsset = project.assets[1]; videoAsset.id = UUID(); videoAsset.kind = .video
        videoAsset.duration = MediaTime(seconds: 4); videoAsset.hasAudio = true
        audioSeparation.assets.append(videoAsset)
        var videoClip = Clip(assetID: videoAsset.id, sourceStart: MediaTime(seconds: 0.5), duration: MediaTime(seconds: 3), visual: visual(ShapeMask()))
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
            check("existing separated audio clears mask and blend", separatedAudio.visual == nil && separatedAudio.blendMode == nil)
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
    static func media(root: URL) async throws {
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        let backURL = root.appendingPathComponent("back.png"), frontURL = root.appendingPathComponent("front.png")
        try writePNG(image([0.25, 0.5, 0.75], extent: canvas), backURL)
        try writePNG(image([0.75, 0.25, 0.5], extent: canvas), frontURL)
        let back = try await MediaImporter.inspect(url: backURL), front = try await MediaImporter.inspect(url: frontURL)
        var project = Project(name: "Shape masks analytic media")
        project.sequence.width = 640; project.sequence.height = 360; project.assets = [back, front]
        project.sequence.tracks[0].clips = [Clip(assetID: back.id, duration: MediaTime(seconds: 6))]
        let base = ShapeMask(centerX: 320.5 / 640, centerY: 180.5 / 360, width: 0.5, height: 0.5, feather: 0)
        for index in 0..<6 {
            var shape = base
            if index == 1 { shape.kind = .rectangle }
            if index == 2 { shape.feather = 0.2 }
            if index == 3 { shape.kind = .rectangle; shape.rotation = 90; shape.height = 0.25 }
            if index == 4 { shape.kind = .rectangle; shape.centerX = 160.5 / 320 }
            var clip = Clip(assetID: front.id, start: MediaTime(seconds: Double(index)), duration: MediaTime(seconds: 1), visual: visual(shape))
            if index == 2 || index == 3 { clip.blendMode = .multiply }
            if index == 3 { clip.transform = ClipTransform(x: 40, y: 20, scale: 0.75, rotation: 90) }
            if index == 4 { clip.visual?.cropLeft = 0.25; clip.visual?.cropRight = 0.25 }
            if index == 5 { clip.transform.opacity = 0; clip.blendMode = .screen }
            project.sequence.tracks[1].clips.append(clip)
        }
        try documents(project, root: root)
        let plan = try await TimelineRenderer.build(project: project)
        let movie = root.appendingPathComponent("shape-mask.mp4")
        try await ExportJob().export(plan: plan, to: movie) { _ in }
        let preview = AVAssetImageGenerator(asset: plan.composition); preview.videoComposition = plan.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        let backRGB: [Double] = [0.25, 0.5, 0.75, 1], sourceRGB: [Double] = [0.75, 0.25, 0.5, 1]
        let productRGB: [Double] = [0.1875, 0.125, 0.375, 1]
        let samples: [(Int64, Int, Int, [Double], String)] = [
            (15, 320, 180, sourceRGB, "ellipse center"), (15, 448, 252, backRGB, "ellipse corner outside"),
            (45, 448, 252, sourceRGB, "rectangle corner inside"), (45, 500, 180, backRGB, "rectangle exterior"),
            (75, 320, 180, productRGB, "mask plus multiply center"), (75, 464, 180, [0.21875, 0.3125, 0.5625, 1], "mask feather plus multiply half coverage"),
            (105, 440, 200, productRGB, "mask rotation plus clip rotation/scale/translation inside"),
            (105, 360, 250, backRGB, "combined rotated thin rectangle exterior"),
            (135, 390, 180, sourceRGB, "crop-first rectangle interior"), (135, 430, 180, backRGB, "crop-first rectangle exterior"),
            (165, 320, 180, backRGB, "zero opacity masked screen leaves backdrop")
        ]
        for (name, generator) in [("preview", preview), ("export", exported)] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for (frame, x, y, wanted, label) in samples {
                let cg = try generator.copyCGImage(at: CMTime(value: frame, timescale: 30), actualTime: nil)
                let actual = pixel(CIImage(cgImage: cg), x, y)
                check("actual \(name) \(label)", close(actual, wanted, tolerance: 0.025), "actual=\(actual) expected=\(wanted)")
            }
        }
        let decoded = try await MediaInspection.decode(movie)
        check("all six seconds of masked output decode", decoded.frameCount == 180 && abs(decoded.videoEndSeconds - 6) < 0.0001)
        // A partially transparent masked overlay changes an ordinary lower caption's colors.
        var captions = project; captions.sequence.tracks[1].clips = []
        var caption = Clip(duration: MediaTime(seconds: 6), title: Title(text: "MASK", fontSize: 72, colorHex: "FFFFFF", x: 0.5, y: 0.5, style: TextStyle(padding: 0, shadow: false)))
        caption.captionRole = .original; captions.sequence.tracks[2].clips = [caption]
        var cover = Clip(assetID: front.id, duration: MediaTime(seconds: 6), visual: visual(ShapeMask(kind: .rectangle, feather: 0)))
        cover.transform.opacity = 0.5
        captions.sequence.tracks.append(Track(name: "Masked overlay above title", kind: .overlay, clips: [cover]))
        let captionPlan = try await TimelineRenderer.build(project: captions)
        let expectation = OutputExpectation.from(project: captions, plan: captionPlan)
        check("upper mask routes ordinary caption to full reference", expectation.captions.first?.pixelComparable == false && expectation.captions.first?.dynamicClip?.id == caption.id && expectation.captions.first?.pixelExclusionReason?.contains("overlying shape mask") == true)
        let positive = root.appendingPathComponent("mask-caption.mp4")
        try await ExportJob().export(plan: captionPlan, to: positive) { _ in }
        let good = try await OutputQuality.check(output: positive, expectation: expectation)
        _ = try OutputQuality.write(good, to: root.appendingPathComponent("Reports"), name: "mask-caption-good")
        check("correct caption below mask verifies", good.errors == 0 && good.burnIn.contains { $0.verified == true } && !good.burnIn.contains { $0.verified == false })
        captions.sequence.tracks[2].clips = []
        let missingPlan = try await TimelineRenderer.build(project: captions)
        let negative = root.appendingPathComponent("mask-caption-missing.mp4")
        try await ExportJob().export(plan: missingPlan, to: negative) { _ in }
        let bad = try await OutputQuality.check(output: negative, expectation: expectation)
        _ = try OutputQuality.write(bad, to: root.appendingPathComponent("Reports"), name: "mask-caption-missing")
        check("missing caption below mask fails", bad.errors > 0 && bad.burnIn.contains { $0.verified == false })
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/ShapeMaskProbe")
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        try geometry(); try await media(root: root)
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("SHAPE_MASK_RESULT checks=\(checks.count) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}

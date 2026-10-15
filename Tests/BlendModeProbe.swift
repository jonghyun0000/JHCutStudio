import Foundation
import AVFoundation
import CoreImage
import ImageIO
@testable import JHCutCore

/// Independent arithmetic oracles use hand-calculated straight-RGB values and the
/// Porter-Duff alpha equation. Media checks additionally exercise the actual timeline/export.
@main struct BlendModeProbe {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
    static let bounds = CGRect(x: 0, y: 0, width: 64, height: 36)
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
    }
    static func image(_ rgb: [Double], alpha: Double = 1) -> CIImage {
        CIImage(color: CIColor(cgColor: CGColor(colorSpace: linear, components: rgb.map { CGFloat($0) } + [CGFloat(alpha)])!)).cropped(to: bounds)
    }
    static func pixel(_ image: CIImage, x: Int = 32, y: Int = 18) -> [Double] {
        var data = [Float](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: MemoryLayout<Float>.stride * 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        }
        return data.map(Double.init)
    }
    static func rgba8(_ image: CIImage) -> [UInt8] {
        let width = Int(bounds.width), height = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return bytes
    }
    static func close(_ a: [Double], _ b: [Double], tolerance: Double = 0.00005) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.isFinite && abs($0 - $1) < tolerance }
    }
    static func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/BlendModeProbe")
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let b: [Double] = [0.2, 0.6, 0.8]
        let s: [Double] = [0.7, 0.3, 0.4]
        let expected: [(ClipBlendMode, [Double])] = [
            (.normal, [0.7, 0.3, 0.4]), (.multiply, [0.14, 0.18, 0.32]),
            (.screen, [0.76, 0.72, 0.88]), (.overlay, [0.28, 0.44, 0.76]),
            (.darken, [0.2, 0.3, 0.4]), (.lighten, [0.7, 0.6, 0.8])
        ]
        for (mode, color) in expected {
            let full = try ClipBlendRenderer.compose(image(s), over: image(b), mode: mode, bounds: bounds)
            check("\(mode.rawValue) independent opaque RGB", close(pixel(full), color + [1]), "\(pixel(full)) expected \(color)")
            // alpha_out = .4 + .7 * .6 = .82. Premultiplied RGB = .42B + .12S + .28blend(B,S).
            let partial = try ClipBlendRenderer.compose(image(s, alpha: 0.4), over: image(b, alpha: 0.7), mode: mode, bounds: bounds)
            var premult: [Double] = []
            premult.reserveCapacity(4)
            for channel in 0..<3 {
                let backdropTerm: Double = b[channel] * 0.42
                let sourceTerm: Double = s[channel] * 0.12
                let blendTerm: Double = color[channel] * 0.28
                let unblendedTerms: Double = backdropTerm + sourceTerm
                premult.append(unblendedTerms + blendTerm)
            }
            premult.append(0.82)
            check("\(mode.rawValue) partial source AND backdrop alpha", close(pixel(partial), premult), "\(pixel(partial)) expected \(premult)")
            let zero = try ClipBlendRenderer.compose(image(s, alpha: 0), over: image(b, alpha: 0.7), mode: mode, bounds: bounds)
            check("\(mode.rawValue) zero opacity leaves premultiplied backdrop", close(pixel(zero), b.map { $0 * 0.7 } + [0.7]))
            let noBackground = try ClipBlendRenderer.compose(image(s, alpha: 0.4), over: image(b, alpha: 0), mode: mode, bounds: bounds)
            check("\(mode.rawValue) transparent backdrop preserves source", close(pixel(noBackground), s.map { $0 * 0.4 } + [0.4]))
        }
        // A black/white carrier proves multiply/screen do not become another generic source-over.
        for (mode, foreground, result) in [(ClipBlendMode.multiply, [0.0, 0, 0], [0.0, 0, 0]), (.screen, [1.0, 1, 1], [1.0, 1, 1])] {
            check("\(mode.rawValue) endpoint", close(pixel(try ClipBlendRenderer.compose(image(foreground), over: image(b), mode: mode, bounds: bounds)), result + [1]))
        }
        let outgoing = BlendScene.clip(image([0.5, 0.5, 0.5]), .screen)  // [.6, .8, .9]
        let incoming = BlendScene.clip(image([0.5, 0.5, 0.5]), .multiply) // [.1, .3, .4]
        for kind in TransitionKind.allCases {
            let effect = ClipTransition(kind: kind, direction: .fromLeft, duration: MediaTime(seconds: 1))
            for (p, wanted) in [(0.0, [0.6, 0.8, 0.9, 1.0]), (1.0, [0.1, 0.3, 0.4, 1.0])] {
                let result = try BlendScene.transition(effect, p, incoming, outgoing).render(over: image(b), bounds: bounds)
                check("\(kind.rawValue) blend endpoint \(p)", close(pixel(result), wanted), "\(pixel(result))")
            }
            let middle = try BlendScene.transition(effect, 0.5, incoming, outgoing).render(over: image(b), bounds: bounds)
            switch kind {
            case .dissolve, .zoom: check("\(kind.rawValue) independent half transition", close(pixel(middle), [0.35, 0.55, 0.65, 1]))
            case .dipToBlack: check("dip reaches black", close(pixel(middle), [0, 0, 0, 1]))
            case .wipe, .slide, .push:
                check("\(kind.rawValue) incoming on left/outgoing on right", close(pixel(middle, x: 8), [0.1, 0.3, 0.4, 1]) && close(pixel(middle, x: 56), [0.6, 0.8, 0.9, 1]))
            }
        }
        // A nonuniform lower track and transparent foreground detect accidental backdrop movement.
        // These colors are exact in the default RGBAh intermediate format. Decimal .2/.4/.6
        // introduced half-float quantization in this graph, independently of background motion.
        // Keep the strict tolerance and the product's working format unchanged.
        let left = image([0.25, 0.5, 0.75]).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 36))
        let checker = left.composited(over: image([0.875, 0.375, 0.125]))
        for kind in [TransitionKind.slide, .push, .zoom, .wipe, .dissolve] {
            let effect = ClipTransition(kind: kind, direction: .fromLeft, duration: MediaTime(seconds: 1))
            let blank = BlendScene.clip(image(s, alpha: 0), .multiply)
            let result = try BlendScene.transition(effect, 0.5, blank, blank).render(over: checker, bounds: bounds)
            check("\(kind.rawValue) lower tracks stay fixed", close(pixel(result, x: 8), [0.25, 0.5, 0.75, 1]) && close(pixel(result, x: 56), [0.875, 0.375, 0.125, 1]), "left=\(pixel(result, x: 8)) right=\(pixel(result, x: 56))")
        }
        // Positioned nonuniform pixels start outside the canvas and re-enter during motion.
        // Check both blended leaves and a normal leaf nested in a blended transition group.
        let pattern = image([0.8, 0.2, 0.4]).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 36))
            .composited(over: image([0.1, 0.9, 0.3]))
        for mode in [ClipBlendMode.multiply, .normal] {
            for kind in [TransitionKind.slide, .push] {
                for direction in [TransitionDirection.fromRight, .fromLeft] {
                    let offset: CGFloat = direction == .fromRight ? -32 : 32
                    let offscreen = BlendScene.clip(pattern.transformed(by: CGAffineTransform(translationX: offset, y: 0)), mode)
                    let effect = ClipTransition(kind: kind, direction: direction, duration: MediaTime(seconds: 1))
                    let result = try BlendScene.transition(effect, 0.5, offscreen, outgoing).render(over: image(b), bounds: bounds)
                    let wantedLeft = mode == .multiply ? [0.16, 0.12, 0.32, 1.0] : [0.8, 0.2, 0.4, 1.0]
                    let wantedRight = mode == .multiply ? [0.02, 0.54, 0.24, 1.0] : [0.1, 0.9, 0.3, 1.0]
                    check("\(kind.rawValue) \(direction.rawValue) preserves offcanvas \(mode.rawValue) source pixels", close(pixel(result, x: 8), wantedLeft) && close(pixel(result, x: 56), wantedRight), "left=\(pixel(result, x: 8)) right=\(pixel(result, x: 56))")
                }
            }
        }
        // Compatibility oracle: compare the ORIGINAL transition renderer's entire RGBA8
        // canvas with the new all-normal group path. This is intentionally an existing-
        // implementation oracle for pixel compatibility, separate from independent blend math.
        let partialPattern = image([0.8, 0.2, 0.4], alpha: 0.35).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 36))
            .composited(over: image([0.1, 0.9, 0.3], alpha: 0.65))
        let oversized = pattern.transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.5))
            .transformed(by: CGAffineTransform(translationX: -20, y: -8))
        let oldFixtures: [(String, CIImage, CIImage)] = [
            ("nonuniform", pattern, checker),
            ("partial-alpha", partialPattern, image([0.2, 0.5, 0.7], alpha: 0.6)),
            ("oversized-positioned", oversized, partialPattern.transformed(by: CGAffineTransform(translationX: 12, y: -5)))
        ]
        for kind in TransitionKind.allCases {
            let effect = ClipTransition(kind: kind, direction: .fromRight, duration: MediaTime(seconds: 1))
            for p in [0.0, 0.5, 1.0] {
                for (name, front, back) in oldFixtures {
                    let expected = TransitionRenderer.compose(effect, progress: p, incoming: front, below: back, bounds: bounds)
                        .composited(over: checker).cropped(to: bounds)
                    let actual = try BlendScene.transition(effect, p, .clip(front, .normal), .clip(back, .normal))
                        .render(over: checker, bounds: bounds)
                    check("all-normal RGBA8 byte compatibility \(kind.rawValue) p=\(p) \(name)", rgba8(expected) == rgba8(actual))
                }
            }
        }
        // A -> B -> C exercises nested graph modes, not one mode incorrectly applied to a merged group.
        let dissolve = ClipTransition(kind: .dissolve, duration: MediaTime(seconds: 1))
        let ab = BlendScene.transition(dissolve, 0.5, incoming, outgoing)
        let abc = BlendScene.transition(dissolve, 0.5, .clip(image([0.2, 0.2, 0.2]), .normal), ab)
        check("nested blended transition independent arithmetic", close(pixel(try abc.render(over: image(b), bounds: bounds)), [0.275, 0.375, 0.425, 1]))
        // Legacy normal dissolve preserves old alpha semantics: .4 source alpha * .5 progress.
        let legacy = BlendScene.transition(dissolve, 0.5, .clip(image(s, alpha: 0.4), .normal), .clip(image(b), .normal))
        var legacyRGB: [Double] = []
        legacyRGB.reserveCapacity(4)
        for channel in 0..<3 {
            let sourceTerm: Double = s[channel] * 0.2
            let backdropTerm: Double = b[channel] * 0.8
            legacyRGB.append(sourceTerm + backdropTerm)
        }
        legacyRGB.append(1)
        check("legacy normal transition retains its alpha behavior", close(pixel(try legacy.render(over: image([0, 0, 0]), bounds: bounds)), legacyRGB))
        try await persistenceAndMedia(root: root, expected: expected)
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("BLEND_MODES_RESULT checks=\(checks.count) failures=\(failures)")
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        if failures != 0 { exit(1) }
    }

    static func persistenceAndMedia(root: URL, expected: [(ClipBlendMode, [Double])]) async throws {
        func writePNG(_ value: CIImage, name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".png")
            guard let cg = context.createCGImage(value, from: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw ProjectError("blend fixture PNG") }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else { throw ProjectError("blend fixture PNG save") }
            return url
        }
        let bgURL = try writePNG(image([0.2, 0.6, 0.8]), name: "backdrop")
        let fgURL = try writePNG(image([0.7, 0.3, 0.4]), name: "foreground")
        let bg = try await MediaImporter.inspect(url: bgURL), fg = try await MediaImporter.inspect(url: fgURL)
        var project = Project(name: "Blend mode independent pixels")
        project.sequence.width = 640; project.sequence.height = 360; project.assets = [bg, fg]
        project.sequence.tracks[0].clips = [Clip(assetID: bg.id, duration: MediaTime(seconds: 7))]
        project.sequence.tracks[1].clips = expected.enumerated().map { index, pair in
            var clip = Clip(name: pair.0.rawValue, assetID: fg.id, start: MediaTime(seconds: Double(index)), duration: MediaTime(seconds: 1))
            clip.blendMode = pair.0 == .normal ? nil : pair.0
            return clip
        }
        var transparent = Clip(name: "zero", assetID: fg.id, start: MediaTime(seconds: 6), duration: MediaTime(seconds: 1))
        transparent.blendMode = .overlay; transparent.transform.opacity = 0
        project.sequence.tracks[1].clips.append(transparent)
        let plan = try await TimelineRenderer.build(project: project)
        let movie = root.appendingPathComponent("blend.mp4")
        try await ExportJob().export(plan: plan, to: movie) { _ in }
        let preview = AVAssetImageGenerator(asset: plan.composition); preview.videoComposition = plan.videoComposition
        let output = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        for generator in [preview, output] { generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero }
        let wanted = expected.map { $0.1 } + [[0.2, 0.6, 0.8]]
        for index in wanted.indices {
            let time = CMTime(value: Int64(index * 30 + 15), timescale: 30)
            let a = try preview.copyCGImage(at: time, actualTime: nil), c = try output.copyCGImage(at: time, actualTime: nil)
            let p = pixel(CIImage(cgImage: a), x: 320, y: 180), q = pixel(CIImage(cgImage: c), x: 320, y: 180)
            check("timeline and actual H264 independent color \(index)", close(p, wanted[index] + [1], tolerance: 0.025) && close(q, wanted[index] + [1], tolerance: 0.025), "preview=\(p) output=\(q) expected=\(wanted[index])")
        }
        let inspection = try await MediaInspection.decode(movie)
        check("entire seven-second output decodes", inspection.frameCount == 210 && abs(inspection.videoEndSeconds - 7) < 0.0001)
        let grayURL = try writePNG(image([0.5, 0.5, 0.5]), name: "scene-gray")
        let gray = try await MediaImporter.inspect(url: grayURL)
        for kind in TransitionKind.allCases {
            var scenes = Project(name: "Blend transition " + kind.rawValue)
            scenes.sequence.width = 640; scenes.sequence.height = 360; scenes.assets = [bg, gray]
            scenes.sequence.tracks[0].clips = [Clip(assetID: bg.id, duration: MediaTime(seconds: 3))]
            var a = Clip(name: "outgoing", assetID: gray.id, duration: MediaTime(seconds: 2)); a.blendMode = .screen
            var b = Clip(name: "incoming", assetID: gray.id, start: MediaTime(seconds: 2), duration: MediaTime(seconds: 2)); b.blendMode = .multiply
            let story = Track(name: "blended scenes", kind: .video, clips: [a, b])
            scenes.sequence.tracks.insert(story, at: 1)
            var history = EditorHistory(project: scenes)
            try history.apply(.addTransition(trackID: story.id, clipID: a.id, kind: kind, direction: .fromLeft, duration: MediaTime(seconds: 1)))
            let composed = try await TimelineRenderer.build(project: history.project)
            let destination = root.appendingPathComponent("transition-" + kind.rawValue + ".mp4")
            try await ExportJob().export(plan: composed, to: destination) { _ in }
            let pg = AVAssetImageGenerator(asset: composed.composition); pg.videoComposition = composed.videoComposition
            let eg = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
            for generator in [pg, eg] { generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero }
            var samples: [(Int64, Int, [Double])] = [(30, 320, [0.6, 0.8, 0.9, 1]), (60, 320, [0.1, 0.3, 0.4, 1])]
            switch kind {
            case .dissolve, .zoom: samples.append((45, 320, [0.35, 0.55, 0.65, 1]))
            case .dipToBlack: samples.append((45, 320, [0, 0, 0, 1]))
            case .wipe, .slide, .push:
                samples.append((45, 80, [0.1, 0.3, 0.4, 1])); samples.append((45, 560, [0.6, 0.8, 0.9, 1]))
            }
            for (frame, x, wanted) in samples {
                let when = CMTime(value: frame, timescale: 30)
                let pp = pixel(CIImage(cgImage: try pg.copyCGImage(at: when, actualTime: nil)), x: x, y: 180)
                let ep = pixel(CIImage(cgImage: try eg.copyCGImage(at: when, actualTime: nil)), x: x, y: 180)
                check("actual preview/export \(kind.rawValue) frame \(frame) x=\(x)", close(pp, wanted, tolerance: 0.025) && close(ep, wanted, tolerance: 0.025), "preview=\(pp) output=\(ep) expected=\(wanted)")
            }
            let decoded = try await MediaInspection.decode(destination)
            check("\(kind.rawValue) all output frames decode", decoded.frameCount == 90 && abs(decoded.videoEndSeconds - 3) < 0.0001)
            if kind == .dissolve {
                var legacyProject = history.project
                for ti in legacyProject.sequence.tracks.indices where legacyProject.sequence.tracks[ti].transitionContext != nil {
                    legacyProject.sequence.tracks[ti].name = "디졸브 · legacy"
                    legacyProject.sequence.tracks[ti].transitionContext = nil
                    for ci in legacyProject.sequence.tracks[ti].clips.indices {
                        legacyProject.sequence.tracks[ti].clips[ci].transition = nil
                        legacyProject.sequence.tracks[ti].clips[ci].fadeIn = MediaTime(seconds: 1)
                    }
                }
                let oldPlan = try await TimelineRenderer.build(project: legacyProject)
                let oldMovie = root.appendingPathComponent("legacy-blended-dissolve.mp4")
                try await ExportJob().export(plan: oldPlan, to: oldMovie) { _ in }
                let pg = AVAssetImageGenerator(asset: oldPlan.composition); pg.videoComposition = oldPlan.videoComposition
                let eg = AVAssetImageGenerator(asset: AVURLAsset(url: oldMovie))
                for generator in [pg, eg] { generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero }
                let when = CMTime(value: 45, timescale: 30)
                let pp = pixel(CIImage(cgImage: try pg.copyCGImage(at: when, actualTime: nil)), x: 320, y: 180)
                let ep = pixel(CIImage(cgImage: try eg.copyCGImage(at: when, actualTime: nil)), x: 320, y: 180)
                check("legacy fade-only dissolve with selected modes has scene-pair blend semantics", close(pp, [0.35, 0.55, 0.65, 1], tolerance: 0.025) && close(ep, [0.35, 0.55, 0.65, 1], tolerance: 0.025), "preview=\(pp), output=\(ep)")
                // Distinct 0.25-second user fade must not be consumed as the one-second
                // legacy dissolve envelope. Black multiply makes loss numerically visible.
                let blackAsset = try await MediaImporter.inspect(url: writePNG(image([0, 0, 0]), name: "legacy-user-fade-black"))
                var userFade = history.project; userFade.assets.append(blackAsset)
                var fadedID: UUID?
                for ti in userFade.sequence.tracks.indices where userFade.sequence.tracks[ti].transitionContext != nil {
                    for ci in userFade.sequence.tracks[ti].clips.indices {
                        userFade.sequence.tracks[ti].clips[ci].assetID = blackAsset.id
                        userFade.sequence.tracks[ti].clips[ci].transition?.independentFade = nil
                        userFade.sequence.tracks[ti].clips[ci].fadeIn = MediaTime(1, 4)
                        fadedID = userFade.sequence.tracks[ti].clips[ci].id
                    }
                }
                let fadePlan = try await TimelineRenderer.build(project: userFade)
                let prepared = fadePlan.videoComposition.instructions.compactMap { $0 as? TimelineInstruction }.flatMap(\.layers).first { $0.clip.id == fadedID }?.clip
                check("distinct legacy clip fade survives render preparation", prepared?.fadeIn == MediaTime(1, 4) && prepared?.transition?.independentFade == true)
                let fadeMovie = root.appendingPathComponent("legacy-distinct-user-fade.mp4")
                try await ExportJob().export(plan: fadePlan, to: fadeMovie) { _ in }
                let preview = AVAssetImageGenerator(asset: fadePlan.composition); preview.videoComposition = fadePlan.videoComposition
                let exported = AVAssetImageGenerator(asset: AVURLAsset(url: fadeMovie))
                // frame 34: transition p=2/15, user fade alpha=8/15.
                // incoming = (7/15)*backdrop; outgoing=[.6,.8,.9].
                let wanted = [0.532444444444, 0.730666666667, 0.829777777778, 1]
                for (name, generator) in [("preview", preview), ("export", exported)] {
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    let actual = pixel(CIImage(cgImage: try generator.copyCGImage(at: CMTime(value: 34, timescale: 30), actualTime: nil)), x: 320, y: 180)
                    check("distinct legacy fade affects actual \(name) pixels", close(actual, wanted, tolerance: 0.025), "actual=\(actual), expected=\(wanted)")
                }

            }
        }
        // Actual renderer/export regression: horizontal pattern is shifted half a canvas
        // offscreen, then the transition moves it back into view at its midpoint.
        let stripe = image([0.8, 0.2, 0.4]).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 36))
            .composited(over: image([0.1, 0.9, 0.3]))
        let stripeAsset = try await MediaImporter.inspect(url: writePNG(stripe, name: "offscreen-pattern"))
        for kind in [TransitionKind.slide, .push] {
            for direction in [TransitionDirection.fromRight, .fromLeft] {
                var moved = Project(name: "Offcanvas blend " + kind.rawValue + direction.rawValue)
                moved.sequence.width = 640; moved.sequence.height = 360; moved.assets = [bg, gray, stripeAsset]
                moved.sequence.tracks[0].clips = [Clip(assetID: bg.id, duration: MediaTime(seconds: 3))]
                var out = Clip(name: "out", assetID: gray.id, duration: MediaTime(seconds: 2)); out.blendMode = .screen
                var entering = Clip(name: "offcanvas", assetID: stripeAsset.id, start: MediaTime(seconds: 2), duration: MediaTime(seconds: 2))
                entering.blendMode = .multiply; entering.transform.x = direction == .fromRight ? -320 : 320
                let story = Track(name: "positioned story", kind: .video, clips: [out, entering]); moved.sequence.tracks.insert(story, at: 1)
                var h = EditorHistory(project: moved)
                try h.apply(.addTransition(trackID: story.id, clipID: out.id, kind: kind, direction: direction, duration: MediaTime(seconds: 1)))
                let movedPlan = try await TimelineRenderer.build(project: h.project)
                let movedMovie = root.appendingPathComponent("offcanvas-" + kind.rawValue + "-" + direction.rawValue + ".mp4")
                try await ExportJob().export(plan: movedPlan, to: movedMovie) { _ in }
                let preview = AVAssetImageGenerator(asset: movedPlan.composition); preview.videoComposition = movedPlan.videoComposition
                let exported = AVAssetImageGenerator(asset: AVURLAsset(url: movedMovie))
                for (name, generator) in [("preview", preview), ("export", exported)] {
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    let frame = CIImage(cgImage: try generator.copyCGImage(at: CMTime(value: 45, timescale: 30), actualTime: nil))
                    let left = pixel(frame, x: 80, y: 180), right = pixel(frame, x: 560, y: 180)
                    check("actual offcanvas \(kind.rawValue) \(direction.rawValue) \(name)", close(left, [0.16, 0.12, 0.32, 1], tolerance: 0.025) && close(right, [0.02, 0.54, 0.24, 1], tolerance: 0.025), "left=\(left), right=\(right)")
                }
                let decoded = try await MediaInspection.decode(movedMovie)
                check("offcanvas \(kind.rawValue) \(direction.rawValue) fully decodes", decoded.frameCount == 90 && abs(decoded.videoEndSeconds - 3) < 0.0001)
            }
        }
        let document = root.appendingPathComponent("Blend.jhcut")
        var original = project
        for index in original.sequence.tracks[1].clips.indices { original.sequence.tracks[1].clips[index].blendMode = nil }
        try ProjectStore.save(original, to: document)
        let before = try Data(contentsOf: document)
        check("legacy nil mode omits document key", !String(decoding: before, as: UTF8.self).contains("blendMode"))
        try ProjectStore.save(project, to: document)
        check("first mode save preserves old document", try Data(contentsOf: ProjectStore.beforeBlendModesURL(for: document)) == before)
        let restored = try ProjectStore.load(from: document)
        check("all modes reopen without loss", restored.sequence == project.sequence)
        try ProjectStore.save(project, to: document)
        check("later saves do not replace preserved old bytes", try Data(contentsOf: ProjectStore.beforeBlendModesURL(for: document)) == before)
        let data = try Data(contentsOf: document)
        let unknown = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"multiply\"", with: "\"future-mode\"")
        let future = root.appendingPathComponent("Future.jhcut"); try Data(unknown.utf8).write(to: future)
        check("unknown mode is rejected", rejected { _ = try ProjectStore.load(from: future) })
        var history = EditorHistory(project: original)
        let track = original.sequence.tracks[1], first = track.clips[0]
        var edit = first; edit.blendMode = .screen
        try history.apply(.updateClip(trackID: track.id, clip: edit)); let committed = history.project
        history.undo(); check("one Undo restores exact original blend state", history.project == original && !history.canUndo)
        history.redo(); check("Redo restores blend mode", history.project == committed)
        var locked = original; locked.sequence.tracks[1].isLocked = true
        var lockedHistory = EditorHistory(project: locked)
        check("locked blend edit rejected atomically", rejected { try lockedHistory.apply(.updateClip(trackID: track.id, clip: edit)) } && lockedHistory.project == locked)
        let sound = MediaAsset(name: "audio", path: "/probe/absent.wav", kind: .audio, duration: MediaTime(seconds: 7), hasAudio: true)
        var invalid = original; invalid.assets.append(sound)
        var soundClip = Clip(assetID: sound.id, duration: MediaTime(seconds: 1)); soundClip.blendMode = .screen
        invalid.sequence.tracks[3].clips = [soundClip]
        check("audio-only clip cannot persist visual blend", rejected { try ProjectValidator.validate(invalid) })
        var soundProject = original
        var video = sound; video.kind = .video; video.width = 640; video.height = 360
        soundProject.assets.append(video)
        var videoClip = Clip(assetID: video.id, duration: MediaTime(seconds: 2)); videoClip.blendMode = .multiply
        soundProject.sequence.tracks[0].clips = [videoClip]
        var soundHistory = EditorHistory(project: soundProject)
        try soundHistory.apply(.separateAudio(trackID: soundProject.sequence.tracks[0].id, clipID: videoClip.id, destinationTrackID: nil))
        check("separate audio clears only audio copy blend", soundHistory.project.sequence.tracks[3].clips.first?.blendMode == nil && soundHistory.project.sequence.tracks[0].clips[0].blendMode == .multiply)
        var titleProject = project
        var title = Clip(duration: MediaTime(seconds: 7), title: Title(text: "BLEND", fontSize: 60, colorHex: "FF6060", x: 0.5, y: 0.5, style: TextStyle(padding: 0, shadow: false)))
        title.captionRole = .original; title.blendMode = .multiply
        titleProject.sequence.tracks[2].clips = [title]
        let titlePlan = try await TimelineRenderer.build(project: titleProject)
        let expectation = OutputExpectation.from(project: titleProject, plan: titlePlan)
        check("blended title uses composited QA reference", expectation.captions.first?.pixelComparable == false && expectation.captions.first?.dynamicClip?.blendMode == .multiply)
        let titleMovie = root.appendingPathComponent("blend-title.mp4")
        try await ExportJob().export(plan: titlePlan, to: titleMovie) { _ in }
        let good = try await OutputQuality.check(output: titleMovie, expectation: expectation)
        _ = try OutputQuality.write(good, to: root.appendingPathComponent("Reports"), name: "blend-title-good")
        check("blended title QA compares actual blend colors", good.burnIn.contains { $0.verified == true } && !good.burnIn.contains { $0.verified == false })
        let absent = try await OutputQuality.check(output: movie, expectation: expectation)
        _ = try OutputQuality.write(absent, to: root.appendingPathComponent("Reports"), name: "blend-title-absent")
        check("absent blended title fails QA", absent.errors > 0 && absent.burnIn.contains { $0.verified == false })
        var invisible = titleProject; invisible.sequence.tracks[2].clips[0].title?.colorHex = "FFFFFF"
        let invisiblePlan = try await TimelineRenderer.build(project: invisible)
        let white = try await OutputQuality.check(output: movie, expectation: OutputExpectation.from(project: invisible, plan: invisiblePlan))
        _ = try OutputQuality.write(white, to: root.appendingPathComponent("Reports"), name: "blend-title-invisible")
        check("invisible white multiply title remains unverified", white.burnIn.allSatisfy { $0.verified == nil })
        // A normal white title BELOW a red multiply overlay must be compared as red text.
        // Source background is dark so the title remains distinguishable from the same
        // complete composition with that title removed.
        let dark = try await MediaImporter.inspect(url: writePNG(image([0.05, 0.05, 0.05]), name: "upper-blend-dark"))
        let red = try await MediaImporter.inspect(url: writePNG(image([1, 0, 0]), name: "upper-blend-red"))
        var below = Project(name: "Normal caption below upper blend overlay")
        below.sequence.width = 640; below.sequence.height = 360; below.assets = [dark, red]
        below.sequence.tracks[0].clips = [Clip(assetID: dark.id, duration: MediaTime(seconds: 3))]
        var normalTitle = Clip(duration: MediaTime(seconds: 3), title: Title(text: "WHITE", fontSize: 72, colorHex: "FFFFFF", x: 0.5, y: 0.5, style: TextStyle(padding: 0, shadow: false)))
        normalTitle.captionRole = .original; below.sequence.tracks[2].clips = [normalTitle]
        var redClip = Clip(assetID: red.id, duration: MediaTime(seconds: 3)); redClip.blendMode = .multiply
        below.sequence.tracks.append(Track(name: "red overlay above caption", kind: .overlay, clips: [redClip]))
        let belowPlan = try await TimelineRenderer.build(project: below)
        let belowExpectation = OutputExpectation.from(project: below, plan: belowPlan)
        check("upper blended overlay routes ordinary title to full reference", belowExpectation.captions.first?.pixelComparable == false && belowExpectation.captions.first?.dynamicClip?.id == normalTitle.id && belowExpectation.captions.first?.pixelExclusionReason?.contains("overlying blend mode") == true)
        let belowMovie = root.appendingPathComponent("normal-title-under-blend.mp4")
        try await ExportJob().export(plan: belowPlan, to: belowMovie) { _ in }
        let belowGood = try await OutputQuality.check(output: belowMovie, expectation: belowExpectation)
        _ = try OutputQuality.write(belowGood, to: root.appendingPathComponent("Reports"), name: "normal-title-under-blend-good")
        check("recolored normal caption passes composited pixel comparison", belowGood.errors == 0 && belowGood.burnIn.contains { $0.verified == true } && !belowGood.burnIn.contains { $0.verified == false })
        var missingBelow = below; missingBelow.sequence.tracks[2].clips = []
        let missingBelowPlan = try await TimelineRenderer.build(project: missingBelow)
        let missingBelowMovie = root.appendingPathComponent("normal-title-under-blend-missing.mp4")
        try await ExportJob().export(plan: missingBelowPlan, to: missingBelowMovie) { _ in }
        let belowAbsent = try await OutputQuality.check(output: missingBelowMovie, expectation: belowExpectation)
        _ = try OutputQuality.write(belowAbsent, to: root.appendingPathComponent("Reports"), name: "normal-title-under-blend-missing")
        check("missing recolored normal caption fails comparison", belowAbsent.errors > 0 && belowAbsent.burnIn.contains { $0.verified == false })

    }
}

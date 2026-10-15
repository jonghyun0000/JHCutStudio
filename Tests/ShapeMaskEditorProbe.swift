import Foundation
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import JHCutCore

/// EditorModel acceptance; native SwiftUI Picker/slider accessibility remains a UI gate.
@main struct ShapeMaskEditorProbe {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [.workingColorSpace: linear])
    @MainActor static func settle(_ model: EditorModel) async throws {
        for _ in 0..<1000 {
            if !model.isBuilding && !model.isLiveRendering && !model.productivityBusy {
                try await Task.sleep(nanoseconds: 20_000_000)
                if !model.isBuilding && !model.isLiveRendering && !model.productivityBusy { return }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProjectError("마스크 편집/렌더 대기 시간 초과")
    }
    static func pixel(_ input: CIImage, x: Int, y: Int) -> [Double] {
        var value = [Float](repeating: 0, count: 4)
        value.withUnsafeMutableBytes { buffer in
            context.render(input, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        }
        return value.map(Double.init)
    }
    @MainActor static func frame(_ model: EditorModel, seconds: Double = 1) throws -> CIImage {
        guard let plan = model.plan else { throw ProjectError("preview plan missing") }
        let generator = AVAssetImageGenerator(asset: plan.composition); generator.videoComposition = plan.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return CIImage(cgImage: try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 30), actualTime: nil))
    }
    static func close(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.025 } }
    static func png(_ color: [CGFloat], to url: URL) throws {
        let input = CIImage(color: CIColor(cgColor: CGColor(colorSpace: linear, components: color + [1])!))
        let cg = context.createCGImage(input, from: CGRect(x: 0, y: 0, width: 640, height: 360), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, cg, nil)
        guard CGImageDestinationFinalize(writer) else { throw ProjectError("PNG save") }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/ShapeMaskEditorProbe")
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
        }
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let backURL = root.appendingPathComponent("back.png"), sourceURL = root.appendingPathComponent("front.png")
        try png([0.25, 0.5, 0.75], to: backURL); try png([0.75, 0.25, 0.5], to: sourceURL)
        let back = try await MediaImporter.inspect(url: backURL), source = try await MediaImporter.inspect(url: sourceURL)
        // Make our own actual video so the ordinary makeFreezeFrame action is exercised.
        var fixture = Project(name: "Mask source fixture"); fixture.sequence.width = 640; fixture.sequence.height = 360
        fixture.assets = [source]; fixture.sequence.tracks[0].clips = [Clip(assetID: source.id, duration: MediaTime(seconds: 3))]
        let fixturePlan = try await TimelineRenderer.build(project: fixture)
        let movie = root.appendingPathComponent("source.mp4")
        try await ExportJob().export(plan: fixturePlan, to: movie) { _ in }
        let front = try await MediaImporter.inspect(url: movie)
        var project = Project(name: "Shape mask EditorModel acceptance")
        project.sequence.width = 640; project.sequence.height = 360; project.assets = [back, front]
        project.sequence.tracks[0].clips = [Clip(assetID: back.id, duration: MediaTime(seconds: 3))]
        let clip = Clip(assetID: front.id, duration: MediaTime(seconds: 3))
        project.sequence.tracks[1] = Track(name: "Masked scene", kind: .video, clips: [clip])
        let trackID = project.sequence.tracks[1].id
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: root.appendingPathComponent("ProxyCache")))
        model.generatedMediaRoot = root.appendingPathComponent("Generated"); model.backupRoot = root.appendingPathComponent("Backups")
        model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
        model.rebuild(); try await settle(model)
        var edited = clip
        var appearance = VisualAdjustments(); appearance.shapeMask = ShapeMask(kind: .rectangle, width: 0.5, height: 0.5, rotation: 30, feather: 0.2)
        edited.visual = appearance; edited.blendMode = .multiply
        edited.transform = ClipTransform(x: 40, y: 20, scale: 0.8, rotation: 20)
        check("Inspector updateClip accepted", model.perform(.updateClip(trackID: trackID, clip: edited)))
        try await settle(model)
        let expectedProduct: [Double] = [0.1875, 0.125, 0.375, 1], expectedBack: [Double] = [0.25, 0.5, 0.75, 1]
        let first = try frame(model)
        check("mask geometry+transform+blend reaches actual preview", close(pixel(first, x: 360, y: 200), expectedProduct) && close(pixel(first, x: 50, y: 40), expectedBack))
        model.undo(); try await settle(model)
        let undoneFrame = try frame(model)
        check("one Undo restores original document and pixels", model.project == project && !model.history.canUndo && close(pixel(undoneFrame, x: 360, y: 200), [0.75, 0.25, 0.5, 1]))
        model.redo(); try await settle(model)
        let committed = model.project
        model.beginLiveEdit()
        for tick in 1...20 {
            var live = edited; live.visual?.shapeMask?.centerX = 0.5 - Double(tick) / 40
            model.updateLiveEdit(trackID: trackID, clip: live)
        }
        try await settle(model)
        check("center drag leaves persisted document untouched", model.project == committed)
        check("center drag updates preview geometry", close(pixel(try frame(model), x: 360, y: 200), expectedBack))
        model.commitLiveEdit(); try await settle(model)
        check("center drag release commits final coordinate", model.project.sequence.tracks[1].clips[0].visual?.shapeMask?.centerX == 0)
        model.undo(); try await settle(model)
        check("one Undo removes entire twenty-tick gesture", model.project == committed)
        model.isExporting = true
        model.beginLiveEdit(); var ignored = edited; ignored.visual?.shapeMask?.width = 0.1
        model.updateLiveEdit(trackID: trackID, clip: ignored); model.commitLiveEdit()
        check("busy document rejects mask gesture", model.project == committed)
        model.isExporting = false
        model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.playhead = 1
        check("video mask can use ordinary freeze action", model.freezeFrameProblem == nil)
        model.makeFreezeFrame(seconds: 1)
        let job = model.productivityTask; await job?.value; try await settle(model)
        guard let still = model.project.sequence.tracks[1].clips.first(where: { candidate in
            model.project.assets.contains { $0.id == candidate.assetID && $0.kind == .image && $0.id != back.id }
        }), let frozenAsset = model.project.assets.first(where: { $0.id == still.assetID }) else {
            throw ProjectError("Masked freeze did not create a still: " + (model.error ?? "unknown"))
        }
        check("freeze bakes shape and transform once while retaining blend", still.visual == nil && still.transform == ClipTransform() && still.blendMode == .multiply)
        let frozenPNG = CIImage(contentsOf: URL(fileURLWithPath: frozenAsset.path))!
        check("freeze PNG retains transparent mask exterior", pixel(frozenPNG, x: 50, y: 40)[3] < 0.001 && pixel(frozenPNG, x: 360, y: 200)[3] > 0.99)
        model.undo(); try await settle(model)
        check("single Undo removes complete freeze transaction", model.project == committed)
        // Restore the same lower layer explicitly; this comparison isolates freeze appearance
        // from unrelated timeline-ripple policies of a background track spanning the insertion.
        var frozenProject = committed; var normalizedStill = still; normalizedStill.start = .zero; normalizedStill.duration = MediaTime(seconds: 3)
        frozenProject.assets.append(frozenAsset); frozenProject.sequence.tracks[1].clips = [normalizedStill]
        let frozenPlan = try await TimelineRenderer.build(project: frozenProject)
        let frozenMovie = root.appendingPathComponent("masked-freeze.mp4")
        try await ExportJob().export(plan: frozenPlan, to: frozenMovie) { _ in }
        let freezePreview = AVAssetImageGenerator(asset: frozenPlan.composition); freezePreview.videoComposition = frozenPlan.videoComposition
        let freezeOutput = AVAssetImageGenerator(asset: AVURLAsset(url: frozenMovie))
        for (name, generator) in [("preview", freezePreview), ("export", freezeOutput)] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let actual = CIImage(cgImage: try generator.copyCGImage(at: CMTime(value: 30, timescale: 30), actualTime: nil))
            var same = true
            for (x, y) in [(50, 40), (200, 180), (280, 120), (360, 200), (420, 230), (560, 320)] {
                same = same && close(pixel(actual, x: x, y: y), pixel(first, x: x, y: y))
            }
            check("masked/rotated/blended freeze matches original \(name) samples", same)
        }
        let retentionRoot = root.appendingPathComponent("Retention")
        try FileManager.default.createDirectory(at: retentionRoot, withIntermediateDirectories: true)
        let currentURL = retentionRoot.appendingPathComponent("Current.jhcut")
        let empty = Project(name: "No generated files currently referenced")
        try ProjectStore.save(empty, to: currentURL)
        var prior = empty; prior.assets = [frozenAsset]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let retained = ProjectStore.beforeShapeMasksURL(for: currentURL)
        try encoder.encode(prior).write(to: retained)
        let retention = EditorModel(recoveryStore: RecoveryStore(directory: retentionRoot.appendingPathComponent("Recovery")), exportHistoryURL: retentionRoot.appendingPathComponent("journal.json"))
        retention.history = EditorHistory(project: empty); retention.documentURL = currentURL; retention.mediaBaseURL = currentURL
        retention.backupRoot = retentionRoot.appendingPathComponent("Backups")
        let references = retention.generatedMediaReferences()
        check("before-shape-masks copy alone protects generated media", references.paths.contains(GeneratedMediaReferences.canonical(URL(fileURLWithPath: frozenAsset.path))))
        try Data("damaged retained copy".utf8).write(to: retained)
        check("unreadable retained copy reports cleanup uncertainty", !retention.generatedMediaReferences().gaps.isEmpty)
        model.pausePlayback(); retention.pausePlayback()
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("SHAPE_MASK_EDITOR_RESULT checks=\(checks.count) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}

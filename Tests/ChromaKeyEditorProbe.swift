import Foundation
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import JHCutCore

/// EditorModel acceptance; native SwiftUI Picker/slider accessibility remains a UI gate.
@main struct ChromaKeyEditorProbe {
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
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/ChromaKeyEditorProbe")
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
        }
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let backURL = root.appendingPathComponent("back.png"), sourceURL = root.appendingPathComponent("front.png")
        try png([0.25, 0.5, 0.75], to: backURL); try png([0, 0.5, 0.5], to: sourceURL)
        let back = try await MediaImporter.inspect(url: backURL), source = try await MediaImporter.inspect(url: sourceURL)
        // Make our own actual video so the ordinary makeFreezeFrame action is exercised.
        var fixture = Project(name: "Chroma source fixture"); fixture.sequence.width = 640; fixture.sequence.height = 360
        fixture.assets = [source]; fixture.sequence.tracks[0].clips = [Clip(assetID: source.id, duration: MediaTime(seconds: 3))]
        let fixturePlan = try await TimelineRenderer.build(project: fixture)
        let movie = root.appendingPathComponent("source.mp4")
        try await ExportJob().export(plan: fixturePlan, to: movie) { _ in }
        let front = try await MediaImporter.inspect(url: movie)
        var project = Project(name: "Chroma key EditorModel acceptance")
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
        var appearance = VisualAdjustments(); appearance.chromaKey = ChromaKey(similarity: 0.25, softness: 0.5, spillReduction: 0); appearance.shapeMask = ShapeMask(kind: .rectangle, width: 0.5, height: 0.5, rotation: 30, feather: 0.2)
        edited.visual = appearance; edited.blendMode = .multiply
        edited.transform = ClipTransform(x: 40, y: 20, scale: 0.8, rotation: 20)
        check("Inspector updateClip accepted", model.perform(.updateClip(trackID: trackID, clip: edited)))
        try await settle(model)
        let expectedProduct: [Double] = [0.125, 0.375, 0.5625, 1], expectedBack: [Double] = [0.25, 0.5, 0.75, 1]
        let first = try frame(model)
        check("key+mask+transform+blend reaches actual preview", close(pixel(first, x: 360, y: 200), expectedProduct) && close(pixel(first, x: 50, y: 40), expectedBack))
        model.undo(); try await settle(model)
        let undoneFrame = try frame(model)
        check("one Undo restores original document and pixels", model.project == project && !model.history.canUndo && close(pixel(undoneFrame, x: 360, y: 200), [0, 0.5, 0.5, 1]))
        model.redo(); try await settle(model)
        let committed = model.project
        model.beginLiveEdit()
        for tick in 1...20 {
            var live = edited; live.visual?.chromaKey?.similarity = 0.25 + Double(tick) / 80
            model.updateLiveEdit(trackID: trackID, clip: live)
        }
        try await settle(model)
        check("similarity drag leaves persisted document untouched", model.project == committed)
        let liveFrame = try frame(model)
        check("similarity drag updates preview geometry", close(pixel(liveFrame, x: 360, y: 200), expectedBack))
        model.commitLiveEdit(); try await settle(model)
        check("similarity drag release commits final similarity", model.project.sequence.tracks[1].clips[0].visual?.chromaKey?.similarity == 0.5)
        model.undo(); try await settle(model)
        check("one Undo removes entire twenty-tick gesture", model.project == committed)
        let pure = NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        let stored = try ChromaColorConversion.storing(pure, in: ChromaKey())
        check("AppKit sRGB key channels retain gamma values", abs(stored.keyRed - 0.5) < 0.000001 && abs(stored.keyGreen - 0.25) < 0.000001 && abs(stored.keyBlue - 0.75) < 0.000001)
        let p3 = NSColor(displayP3Red: 0.6, green: 0.4, blue: 0.2, alpha: 1)
        let converted = try ChromaColorConversion.storing(p3, in: ChromaKey())
        let oracle = p3.usingColorSpace(.sRGB)!
        check("Display P3 converts explicitly to sRGB gamut", abs(converted.keyRed - min(1, max(0, Double(oracle.redComponent)))) < 0.000001 && abs(converted.keyGreen - min(1, max(0, Double(oracle.greenComponent)))) < 0.000001 && abs(converted.keyBlue - min(1, max(0, Double(oracle.blueComponent)))) < 0.000001)
        let colorPlan = model.plan
        guard var canceled = ChromaColorDraft.begin(in: model, trackID: trackID, clipID: clip.id) else { throw ProjectError("color draft begin") }
        for tick in 1...20 {
            _ = try canceled.select(NSColor(srgbRed: Double(tick) / 40, green: 0.25, blue: 0.75, alpha: 1), in: model)
        }
        check("twenty color picks remain entirely local", model.project == committed && model.previewProject == committed && model.plan === colorPlan && !model.isLivePreviewing && !model.isLiveRendering)
        canceled.cancel()
        let lateAccepted = try canceled.select(pure, in: model)
        check("cancel rejects late color setter and Apply", !lateAccepted && !canceled.apply(to: model) && model.project == committed && model.plan === colorPlan)
        for flag: ReferenceWritableKeyPath<EditorModel, Bool> in [\.isExporting, \.isImporting, \.productivityBusy, \.proxyBusy] {
            guard var busyDraft = ChromaColorDraft.begin(in: model, trackID: trackID, clipID: clip.id) else { throw ProjectError("busy draft begin") }
            _ = try busyDraft.select(pure, in: model)
            model[keyPath: flag] = true
            let ignored = try busyDraft.select(NSColor.red, in: model)
            check("busy transition rejects local color without preview rollback", !ignored && !busyDraft.apply(to: model) && model.project == committed && model.previewProject == committed && model.plan === colorPlan)
            model[keyPath: flag] = false
        }
        guard var selectedDraft = ChromaColorDraft.begin(in: model, trackID: trackID, clipID: clip.id) else { throw ProjectError("selection draft begin") }
        _ = try selectedDraft.select(pure, in: model); model.selectedClipID = nil
        check("changed selection cannot receive old color draft", !selectedDraft.apply(to: model) && model.project == committed)
        model.selectedClipID = clip.id
        guard var applied = ChromaColorDraft.begin(in: model, trackID: trackID, clipID: clip.id) else { throw ProjectError("apply draft begin") }
        for tick in 1...20 { _ = try applied.select(NSColor(srgbRed: Double(tick) / 40, green: 0.25, blue: 0.75, alpha: 1), in: model) }
        check("explicit Apply commits color draft", applied.apply(to: model))
        try await settle(model)
        let colorCommitted = model.project
        let latestKey = colorCommitted.sequence.tracks[1].clips[0].visual!.chromaKey!
        check("color Apply changes only RGB and preserves other key parameters", latestKey.keyRed == stored.keyRed && latestKey.keyGreen == stored.keyGreen && latestKey.keyBlue == stored.keyBlue && latestKey.similarity == appearance.chromaKey!.similarity && latestKey.softness == appearance.chromaKey!.softness && latestKey.spillReduction == appearance.chromaKey!.spillReduction && colorCommitted.sequence.tracks[1].clips[0].transform == edited.transform)
        model.undo(); try await settle(model)
        check("one Undo removes complete twenty-pick/cancel/Apply history", model.project == committed)
        model.undo(); try await settle(model)
        check("canceled color and busy drafts added no Undo entries", model.project == project && !model.history.canUndo)
        model.redo(); try await settle(model)
        model.redo(); try await settle(model)
        check("Redo restores exact color transaction", model.project == colorCommitted)
        model.undo(); try await settle(model)
        check("freeze starts from committed pre-color appearance", model.project == committed)
        // Context tests need no renderer: the shared helper rejects stale local data before perform().
        let owner = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("OwnerRecovery")), exportHistoryURL: root.appendingPathComponent("owner-journal.json"))
        owner.history = EditorHistory(project: committed); owner.selectedClipID = clip.id; owner.selectedClipIDs = [clip.id]
        guard var replaced = ChromaColorDraft.begin(in: owner, trackID: trackID, clipID: clip.id) else { throw ProjectError("owner draft begin") }
        _ = try replaced.select(pure, in: owner)
        owner.history = EditorHistory(project: committed) // identical UUIDs and document values, new history generation
        check("identical-ID document replacement rejects old draft", !replaced.apply(to: owner) && owner.project == committed && !owner.history.canUndo)
        guard var aba = ChromaColorDraft.begin(in: owner, trackID: trackID, clipID: clip.id) else { throw ProjectError("ABA draft begin") }
        _ = try aba.select(pure, in: owner)
        owner.documentURL = root.appendingPathComponent("Other.jhcut"); owner.documentURL = nil
        check("document URL ABA rejects old draft", !aba.apply(to: owner) && owner.project == committed)
        guard var lockedDraft = ChromaColorDraft.begin(in: owner, trackID: trackID, clipID: clip.id) else { throw ProjectError("lock draft begin") }
        _ = try lockedDraft.select(pure, in: owner)
        var locked = committed; locked.sequence.tracks[1].isLocked = true; owner.history = EditorHistory(project: locked)
        check("locked clip cannot receive old color draft", !lockedDraft.apply(to: owner) && owner.project == locked)
        model.isExporting = true
        model.beginLiveEdit(); var ignored = edited; ignored.visual?.chromaKey?.similarity = 0.8; ignored.visual?.chromaKey?.softness = 0.2
        model.updateLiveEdit(trackID: trackID, clip: ignored); model.commitLiveEdit()
        check("busy document rejects key gesture", model.project == committed)
        model.isExporting = false
        model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.playhead = 1
        check("keyed video can use ordinary freeze action", model.freezeFrameProblem == nil)
        model.makeFreezeFrame(seconds: 1)
        let job = model.productivityTask; await job?.value; try await settle(model)
        guard let still = model.project.sequence.tracks[1].clips.first(where: { candidate in
            model.project.assets.contains { $0.id == candidate.assetID && $0.kind == .image && $0.id != back.id }
        }), let frozenAsset = model.project.assets.first(where: { $0.id == still.assetID }) else {
            throw ProjectError("Masked freeze did not create a still: " + (model.error ?? "unknown"))
        }
        check("freeze bakes key, shape and transform once while retaining blend", still.visual == nil && still.transform == ClipTransform() && still.blendMode == .multiply)
        let frozenPNG = CIImage(contentsOf: URL(fileURLWithPath: frozenAsset.path))!
        check("freeze PNG retains mask exterior and half-keyed alpha", pixel(frozenPNG, x: 50, y: 40)[3] < 0.001 && abs(pixel(frozenPNG, x: 360, y: 200)[3] - 0.5) < 0.025)
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
        let retained = ProjectStore.beforeChromaKeyURL(for: currentURL)
        try encoder.encode(prior).write(to: retained)
        let retention = EditorModel(recoveryStore: RecoveryStore(directory: retentionRoot.appendingPathComponent("Recovery")), exportHistoryURL: retentionRoot.appendingPathComponent("journal.json"))
        retention.history = EditorHistory(project: empty); retention.documentURL = currentURL; retention.mediaBaseURL = currentURL
        retention.backupRoot = retentionRoot.appendingPathComponent("Backups")
        let references = retention.generatedMediaReferences()
        check("before-chroma-key copy alone protects generated media", references.paths.contains(GeneratedMediaReferences.canonical(URL(fileURLWithPath: frozenAsset.path))))
        try Data("damaged retained copy".utf8).write(to: retained)
        check("unreadable retained copy reports cleanup uncertainty", !retention.generatedMediaReferences().gaps.isEmpty)
        model.pausePlayback(); retention.pausePlayback()
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("CHROMA_KEY_EDITOR_RESULT checks=\(checks.count) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}

import Foundation
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import JHCutCore

/// Exercises the same discrete updateClip path and live opacity path used by ClipInspector.
/// Native Picker interaction still requires UI acceptance after this headless probe passes.
@main struct BlendEditorProbe {
    @MainActor static func settle(_ model: EditorModel) async throws {
        for _ in 0..<800 {
            if !model.isBuilding && !model.isLiveRendering {
                try await Task.sleep(nanoseconds: 20_000_000)
                if !model.isBuilding && !model.isLiveRendering { return }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProjectError("블렌드 편집 미리보기 대기 시간 초과")
    }
    @MainActor static func sample(_ model: EditorModel) throws -> [Double] {
        guard let plan = model.plan else { throw ProjectError("preview plan missing") }
        let generator = AVAssetImageGenerator(asset: plan.composition); generator.videoComposition = plan.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let cg = try generator.copyCGImage(at: CMTime(value: 30, timescale: 30), actualTime: nil)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var rgba = [Float](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            CIContext(options: [.workingColorSpace: space]).render(CIImage(cgImage: cg), toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 320, y: 180, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        }
        return rgba.map(Double.init)
    }
    static func close(_ a: [Double], _ b: [Double]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.025 } }
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/BlendEditorProbe")
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func png(_ color: [CGFloat], _ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".png")
            let ci = CIImage(color: CIColor(cgColor: CGColor(colorSpace: space, components: color + [1])!))
            let cg = CIContext(options: [.workingColorSpace: space]).createCGImage(ci, from: CGRect(x: 0, y: 0, width: 64, height: 36), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, cg, nil)
            guard CGImageDestinationFinalize(writer) else { throw ProjectError("PNG save") }; return url
        }
        let back = try await MediaImporter.inspect(url: png([0.2, 0.6, 0.8], "back"))
        let front = try await MediaImporter.inspect(url: png([0.7, 0.3, 0.4], "front"))
        var project = Project(name: "Blend Inspector model acceptance")
        project.sequence.width = 640; project.sequence.height = 360; project.assets = [back, front]
        project.sequence.tracks[0].clips = [Clip(assetID: back.id, duration: MediaTime(seconds: 3))]
        let clip = Clip(assetID: front.id, duration: MediaTime(seconds: 3)); let trackID = project.sequence.tracks[1].id
        project.sequence.tracks[1].clips = [clip]
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: root.appendingPathComponent("ProxyCache")))
        model.history = EditorHistory(project: project); model.selectedClipID = clip.id
        model.rebuild(); try await settle(model)
        var selected = clip; selected.blendMode = .multiply
        check("picker update accepted", model.perform(.updateClip(trackID: trackID, clip: selected)))
        try await settle(model)
        check("picker change reaches actual preview pixels", try close(sample(model), [0.14, 0.18, 0.32, 1]))
        model.undo(); try await settle(model)
        let afterUndoPixels = try sample(model)
        check("one Undo restores original document and preview", model.project == project && !model.history.canUndo && close(afterUndoPixels, [0.7, 0.3, 0.4, 1]))
        model.redo(); try await settle(model)
        let committed = model.project
        check("Redo restores chosen mode", model.project.sequence.tracks[1].clips[0].blendMode == .multiply)
        model.beginLiveEdit()
        for tick in 1...20 { var value = selected; value.transform.opacity = 1 - Double(tick) / 40; model.updateLiveEdit(trackID: trackID, clip: value) }
        try await settle(model)
        check("opacity drag leaves document untouched", model.project == committed)
        check("opacity drag previews blend with independent alpha", try close(sample(model), [0.17, 0.39, 0.56, 1]))
        model.commitLiveEdit(); try await settle(model)
        check("opacity release commits one gesture", model.project.sequence.tracks[1].clips[0].transform.opacity == 0.5)
        model.undo(); try await settle(model)
        check("one Undo removes entire opacity gesture only", model.project == committed)
        model.undo(); try await settle(model)
        check("second Undo removes mode selection", model.project == project && !model.history.canUndo)
        // Rendered freeze source excludes backdrop-dependent blend; the inserted still retains it.
        let frozenPNG = root.appendingPathComponent("freeze-source.png")
        var frozenProject = project; frozenProject.sequence.tracks[1].clips[0].blendMode = .multiply
        try await EditorModel.extractRenderedFrame(project: frozenProject, clip: selected, documentURL: nil, at: MediaTime(seconds: 1), to: frozenPNG)
        let frozenAsset = try await MediaImporter.inspect(url: frozenPNG)
        frozenProject.assets.append(frozenAsset)
        var still = Clip(assetID: frozenAsset.id, duration: MediaTime(seconds: 3)); still.blendMode = selected.blendMode
        frozenProject.sequence.tracks[1].clips = [still]
        model.history = EditorHistory(project: frozenProject); model.rebuild(); try await settle(model)
        check("freeze keeps blend interaction with lower tracks", try close(sample(model), [0.14, 0.18, 0.32, 1]))
        model.pausePlayback()
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("BLEND_EDITOR_RESULT checks=\(checks.count) failures=\(failures)")
        if failures != 0 { exit(1) }
    }
}

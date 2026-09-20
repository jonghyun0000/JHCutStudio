#if LIVE_PREVIEW_PROBE
import Foundation
import AppKit
import AVFoundation
import CoreImage
import JHCutCore

/// Headless proof that dragging a control previews without touching the document, and that the whole
/// gesture costs exactly one undo step.
@main struct LivePreviewProbe {
    static var results: [[String: Any]] = []
    @MainActor static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append(["name": name, "passed": passed, "detail": detail])
        print("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
    }

    /// Waits for both the committed build and any live render loop to go quiet.
    @MainActor static func settle(_ model: EditorModel) async {
        for _ in 0..<800 {
            if !model.isBuilding && !model.isLiveRendering {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if !model.isBuilding && !model.isLiveRendering { return }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Mean luminance of the plan's rendered frame, so a preview change is verified in pixels.
    @MainActor static func luma(_ model: EditorModel, at seconds: Double) throws -> Double {
        guard let plan = model.plan else { throw ProjectError("no plan") }
        let generator = AVAssetImageGenerator(asset: plan.composition)
        generator.videoComposition = plan.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProjectError("no context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
        }
        return total / Double(width * height)
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/LivePreview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let media = output.appendingPathComponent("source.mp4")
            if !FileManager.default.fileExists(atPath: media.path) {
                try await Fixtures.video(to: media, scene: 1, color: CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1), frames: 90)
            }
            let asset = try await MediaImporter.inspect(url: media)
            var project = Project(name: "Live preview probe")
            let clip = Clip(name: "graded", assetID: asset.id, start: .zero, duration: MediaTime(seconds: 3))
            project.assets = [asset]; project.sequence.tracks[0].clips = [clip]

            // The probe owns a throwaway recovery slot; the user's own slot is never touched.
            let model = EditorModel(recoveryStore: RecoveryStore(directory: output.appendingPathComponent("recovery", isDirectory: true)))
            model.history = EditorHistory(project: project)
            model.selectedClipID = clip.id
            model.rebuild()
            await settle(model)
            let baseline = try luma(model, at: 1)
            check("Baseline preview renders", model.plan != nil && baseline > 0.05, String(format: "luma %.4f", baseline))

            // ---- A drag: 30 ticks of an exposure slider. ----
            let documentBefore = model.project
            model.beginLiveEdit()
            let dragStart = Date()
            for tick in 1...30 {
                var candidate = clip
                candidate.visual = VisualAdjustments(exposure: Double(tick) / 10)
                model.updateLiveEdit(trackID: project.sequence.tracks[0].id, clip: candidate)
            }
            await settle(model)
            let dragSeconds = Date().timeIntervalSince(dragStart)

            check("Drag leaves the document untouched", model.project == documentBefore,
                  "history unchanged while previewing")
            check("Drag leaves undo history untouched", !model.history.canUndo, "no undo entry mid-drag")
            check("Preview project carries the in-progress value",
                  model.previewProject.sequence.tracks[0].clips[0].visual?.exposure == 3.0,
                  "exposure 3.0 substituted for the preview only")
            let dragged = try luma(model, at: 1)
            check("Preview pixels follow the slider", dragged > baseline * 1.3,
                  String(format: "luma %.4f → %.4f at +3EV", baseline, dragged))
            check("Rapid ticks coalesce", model.livePreviewRenders >= 1 && model.livePreviewRenders < 30,
                  "\(model.livePreviewRenders) renders for 30 ticks in \(String(format: "%.2f", dragSeconds))s")

            // ---- Release: one history entry for the whole gesture. ----
            model.commitLiveEdit()
            await settle(model)
            check("Release commits the dragged value", model.project.sequence.tracks[0].clips[0].visual?.exposure == 3.0)
            check("Release creates an undo entry", model.history.canUndo)
            model.undo()
            await settle(model)
            check("One undo reverts the whole drag", model.project == documentBefore,
                  "30 ticks cost exactly one undo step")
            model.redo()
            await settle(model)
            check("Redo restores the dragged value", model.project.sequence.tracks[0].clips[0].visual?.exposure == 3.0)

            // ---- A rejected value must not survive the commit. ----
            let beforeBad = model.project
            model.beginLiveEdit()
            var invalid = model.project.sequence.tracks[0].clips[0]
            invalid.fadeIn = MediaTime(seconds: 10)   // longer than the 3s clip
            model.updateLiveEdit(trackID: project.sequence.tracks[0].id, clip: invalid)
            await settle(model)
            model.error = nil
            model.commitLiveEdit()
            await settle(model)
            check("Rejected value is not committed", model.project == beforeBad && model.error != nil,
                  model.error ?? "no error reported")
            check("Rejected gesture restores a usable preview", model.plan != nil && !model.isLivePreviewing)

            // ---- A drag paced like a real 60 Hz gesture, to measure the feedback rate a user sees. ----
            let pacedBefore = model.livePreviewRenders
            model.beginLiveEdit()
            let pacedStart = Date()
            var ticks = 0
            while Date().timeIntervalSince(pacedStart) < 1.0 {
                var candidate = model.project.sequence.tracks[0].clips[0]
                candidate.transform.opacity = 1 - Date().timeIntervalSince(pacedStart) * 0.5
                model.updateLiveEdit(trackID: project.sequence.tracks[0].id, clip: candidate)
                ticks += 1
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            await settle(model)
            let pacedRenders = model.livePreviewRenders - pacedBefore
            model.commitLiveEdit()
            await settle(model)
            check("Paced drag gives continuous feedback", pacedRenders >= 8 && pacedRenders < ticks,
                  "\(pacedRenders) previews for \(ticks) ticks over 1s ≈ \(pacedRenders) fps of feedback")

            // ---- Latency of a single live update. ----
            let before = model.livePreviewRenders
            model.beginLiveEdit()
            var one = model.project.sequence.tracks[0].clips[0]
            one.transform.opacity = 0.5
            let started = Date()
            model.updateLiveEdit(trackID: project.sequence.tracks[0].id, clip: one)
            await settle(model)
            let latency = Date().timeIntervalSince(started)
            model.commitLiveEdit()
            await settle(model)
            check("Single update lands within one frame budget", latency < 0.2 && model.livePreviewRenders > before,
                  String(format: "%.0f ms per live preview", latency * 1000))
            print(String(format: "LIVE_TIMING singleUpdate=%.0fms dragOf30Ticks=%.0fms renders=%d",
                         latency * 1000, dragSeconds * 1000, model.livePreviewRenders))
        } catch {
            check("Probe execution", false, error.localizedDescription)
        }
        do {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("live-checks.json"))
        } catch { print(error); exit(2) }
        let failures = results.filter { ($0["passed"] as? Bool) != true }.count
        print("LIVE_RESULT checks=\(results.count) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif

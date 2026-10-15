import Foundation
import AppKit
import AVFoundation
import JHCutCore

@main struct LibraryWorkflowProbe {
    static func pcm(_ asset: AVAsset, mix: AVAudioMix? = nil, seconds: Double = 10) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        output.audioMix = mix; reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? ProjectError("PCM reader failed") }
        var result = [Float](repeating: 0, count: Int(seconds * 48_000) * 2)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: bytes / 4)
            let code = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard code == kCMBlockBufferNoErr else { throw ProjectError("PCM copy failed") }
            let offset = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48_000).rounded()) * 2
            for index in data.indices where offset + index >= 0 && offset + index < result.count { result[offset + index] = data[index] }
        }
        guard reader.status == .completed else { throw reader.error ?? ProjectError("PCM decode incomplete") }
        return result
    }
    static func rms(_ values: [Float]) -> Double { sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))) }

    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/LibraryWorkflow")
        let fm = FileManager.default
        var checks: [[String: Any]] = [], measurements: [String: Any] = [:]
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
        }
        defer {
            let report: [String: Any] = ["checks": checks, "measurements": measurements,
                "scope": "Actual catalog items and EditorModel insertion, owned iPhone trim, save/reopen, bundle replacement, collection/move, complete output decode. Authored title is not an ASR reference. No native search/favorites or human listening acceptance."]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        }
        let library = try AssetLibrary()
        let music = library.assets.first { $0.category == .music && (120...180).contains($0.duration ?? 0) }!
        let selected = [music] + [LibraryCategory.sfx, .background, .overlay, .texture].map { category in library.assets.first { $0.category == category }! }
        let oldBundle = root.appendingPathComponent("OldApp/Library"), retained = root.appendingPathComponent("LibraryMedia")
        for item in selected {
            let target = oldBundle.appendingPathComponent(item.relativePath)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: library.url(for: item), to: target)
            check("Catalog source SHA: " + item.id, try await FileIdentity.sha256(target) == item.sha256)
        }
        try JSONEncoder().encode(selected).write(to: oldBundle.appendingPathComponent("manifest.json"))
        measurements["catalogIDs"] = selected.map(\.id)

        let original = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_0047.mov")
        let trimmed = root.appendingPathComponent("iphone-45s.mov")
        guard let trim = AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetPassthrough) else { throw ProjectError("iPhone trim setup failed") }
        trim.outputURL = trimmed; trim.outputFileType = .mov
        trim.timeRange = CMTimeRange(start: CMTime(seconds: 660, preferredTimescale: 600), duration: CMTime(seconds: 45, preferredTimescale: 600))
        await withCheckedContinuation { continuation in trim.exportAsynchronously { continuation.resume() } }
        guard trim.status == .completed else { throw trim.error ?? ProjectError("iPhone trim failed") }
        var source = try await MediaImporter.inspect(url: trimmed); source.contentHash = try await FileIdentity.sha256(trimmed)
        var base = Project(name: "실소재 45초 세로 편집")
        base.sequence.width = 1080; base.sequence.height = 1920; base.assets = [source]
        base.sequence.tracks[0].clips = [Clip(name: "iPhone speech", assetID: source.id, duration: MediaTime(45, 1), volume: 0.6)]
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: root.appendingPathComponent("Proxies")))
        model.generatedMediaRoot = root.appendingPathComponent("Generated"); model.backupRoot = root.appendingPathComponent("Backups")
        model.libraryMediaStore = LibraryMediaStore(directory: retained)
        model.bundledLibrary = try AssetLibrary(rootURL: oldBundle); model.history = EditorHistory(project: base)
        defer { model.invalidateAsyncJobs(); model.pausePlayback() }
        for (index, item) in selected.enumerated() {
            model.playhead = [0.0, 2.0, 5.0, 15.0, 25.0][index]
            let before = model.project
            model.insertLibraryAsset(item); await model.importTask?.value
            let added = model.project.assets.filter { asset in !before.assets.contains { $0.id == asset.id } }
            check("Actual insertion adds one asset: " + item.id, added.count == 1, model.error ?? "")
            guard let asset = added.first, let clip = model.selected?.1 else { throw ProjectError("Insertion failed: " + item.id) }
            check("Durable verified source and credit: " + item.id, asset.path.hasPrefix(retained.path + "/") && asset.contentHash == item.sha256 && asset.provenance?.sha256 == item.sha256 && asset.provenance?.author == item.author && asset.provenance?.license == item.license)
            if item.category == .music {
                check("2–3 minute music fits video with default volume and fades", (120...180).contains(item.duration ?? 0) && clip.duration == MediaTime(45, 1) && clip.volume == 0.25 && clip.audioFadeIn == MediaTime(1, 1) && clip.audioFadeOut == MediaTime(1, 1))
            }
            let after = model.project
            model.undo(); check("Single Undo restores pre-insertion state: " + item.id, model.project == before)
            model.redo(); check("Redo restores insertion: " + item.id, model.project == after)
        }
        let titleTrack = model.project.sequence.tracks.first { $0.kind == .title }!
        var title = TitlePreset.builtIns.first { $0.id == "clean-caption" }!.title
        title.text = "소재 검증 · Library check · 編集確認"; title.fontSize = 48
        check("Authored multilingual title applied", model.perform(.addClip(trackID: titleTrack.id, clip: Clip(name: "Authored validation title", start: .zero, duration: MediaTime(45, 1), title: title))))
        let document = root.appendingPathComponent("Project.jhcut")
        try ProjectStore.save(model.project, to: document)
        let beforeReplacement = model.project
        for item in selected { try fm.removeItem(at: oldBundle.appendingPathComponent(item.relativePath)) }
        let reopened = try ProjectStore.load(from: document)
        check("Project reopens after all owned old-bundle assets are removed", reopened.sequence == beforeReplacement.sequence && reopened.assets.allSatisfy { fm.fileExists(atPath: $0.resolvedURL(relativeTo: document).path) })
        for asset in reopened.assets { check("Saved source hash remains valid: " + asset.name, try await FileIdentity.sha256(asset.resolvedURL(relativeTo: document)) == asset.contentHash) }

        // Reuse is content-addressed; bad existing content is never silently replaced.
        let store = LibraryMediaStore(directory: root.appendingPathComponent("StoreChecks"))
        async let first = store.retain(source: library.url(for: music), item: music)
        async let second = store.retain(source: library.url(for: music), item: music)
        let (one, two) = try await (first, second)
        let retainedHash = try await FileIdentity.sha256(one)
        check("Concurrent retention converges on one verified source", one == two && retainedHash == music.sha256)
        try Data("owned corruption fixture".utf8).write(to: one)
        var refused = false
        do { _ = try await store.retain(source: library.url(for: music), item: music) } catch { refused = true }
        let corruptedBytes = try Data(contentsOf: one)
        check("Damaged retained source is refused without replacement", refused && corruptedBytes == Data("owned corruption fixture".utf8))

        let collected = root.appendingPathComponent("Collected")
        _ = try ProjectCollector.collect(project: reopened, documentURL: document, to: collected)
        let moved = root.appendingPathComponent("MovedCollection"); try fm.moveItem(at: collected, to: moved)
        // Remove only owned retained copies to force the portable collection to stand alone.
        try fm.removeItem(at: retained)
        let movedDocument = moved.appendingPathComponent("Project.jhcut")
        let portable = try ProjectStore.load(from: movedDocument)
        check("Moved collection resolves every asset without the app or retained store", portable.assets.allSatisfy { $0.resolvedURL(relativeTo: movedDocument).path.hasPrefix(moved.path + "/Media/") && fm.fileExists(atPath: $0.resolvedURL(relativeTo: movedDocument).path) })
        let plan = try await TimelineRenderer.build(project: portable, documentURL: movedDocument)
        let output = root.appendingPathComponent("library-45s-vertical.mp4")
        try await ExportJob().export(plan: plan, to: output) { _ in }
        let decoded = try await MediaInspection.decode(output)
        measurements["output"] = decoded.metrics
        check("Full output decode: 1080×1920, 1350 ordered frames, 45 seconds", decoded.width == 1080 && decoded.height == 1920 && decoded.frameCount == 1350 && decoded.monotonic && abs(decoded.videoEndSeconds - 45) < 0.001)
        check("Full output contains finite nonzero audio through the end", decoded.audioRMS.isFinite && decoded.audioRMS > 0.0001 && abs((decoded.metrics["audioPresentationEndSeconds"] ?? 0) - 45) < 0.05)
        let expectedPCM = try await pcm(plan.composition, mix: plan.audioMix)
        let actualPCM = try await pcm(AVURLAsset(url: output))
        let residual = zip(expectedPCM, actualPCM).map { $0 - $1 }
        let relativeError = rms(residual) / max(rms(expectedPCM), 0.000001)
        measurements["first10SecondsPCMRelativeRMSError"] = relativeError
        check("Decoded soundtrack matches preview mix within AAC tolerance", relativeError < 0.12, String(relativeError))
        var noMusic = portable
        let musicID = noMusic.assets.first { $0.provenance?.sha256 == music.sha256 }!.id
        for ti in noMusic.sequence.tracks.indices { for ci in noMusic.sequence.tracks[ti].clips.indices where noMusic.sequence.tracks[ti].clips[ci].assetID == musicID { noMusic.sequence.tracks[ti].clips[ci].volume = 0 } }
        let voicePlan = try await TimelineRenderer.build(project: noMusic, documentURL: movedDocument)
        let voicePCM = try await pcm(voicePlan.composition, mix: voicePlan.audioMix)
        check("Music measurably contributes alongside iPhone audio", rms(zip(expectedPCM, voicePCM).map { $0 - $1 }) > 0.0001 && rms(voicePCM) > 0.0001)
        let preview = AVAssetImageGenerator(asset: plan.composition); preview.videoComposition = plan.videoComposition
        preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
        let movie = AVAssetImageGenerator(asset: AVURLAsset(url: output)); movie.requestedTimeToleranceBefore = .zero; movie.requestedTimeToleranceAfter = .zero
        for second in [1, 7, 17, 27, 43] {
            let time = CMTime(value: Int64(second), timescale: 1)
            let reference = try await preview.image(at: time).image, actual = try await movie.image(at: time).image
            let difference = try MediaInspection.compare(reference, actual)
            check("Preview/output image at \(second)s", difference.mean < 0.04, "mean RGB error=\(difference.mean)")
        }
        for item in selected { check("Original catalog unchanged: " + item.id, try await FileIdentity.sha256(library.url(for: item)) == item.sha256) }
        let failed = checks.filter { $0["passed"] as? Bool != true }.count
        print("LIBRARY_WORKFLOW_RESULT checks=\(checks.count) failures=\(failed)")
        if failed > 0 { throw ProjectError("Library workflow failed \(failed) checks") }
    }
}

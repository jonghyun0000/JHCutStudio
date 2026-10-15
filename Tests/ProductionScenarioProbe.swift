import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Actual app operations on unique iPhone ranges. Execution/timing checks do not score ASR accuracy.
@main struct ProductionScenarioProbe {
    static func trim(_ source: URL, start: Double, seconds: Double, to destination: URL) async throws {
        guard let job = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else { throw ProjectError("Scenario input preparation failed") }
        job.outputURL = destination; job.outputFileType = .mov
        job.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: seconds, preferredTimescale: 600))
        await withCheckedContinuation { continuation in job.exportAsynchronously { continuation.resume() } }
        guard job.status == .completed else { throw job.error ?? ProjectError("Scenario input copy failed") }
    }
    /// Independent SRT boundary oracle: round a positive rational time to the nearest millisecond.
    /// Whole-second decomposition avoids floating-point rounding and does not call SRTCodec.serialize.
    static func srtTime(_ time: MediaTime) -> MediaTime {
        let scale = Int64(time.timescale), whole = time.value / Int64(time.timescale), remainder = time.value % Int64(time.timescale)
        return MediaTime(whole * 1_000 + (remainder * 1_000 + scale / 2) / scale, 1_000)
    }
    static func linkedAtSourceTime(_ caption: Clip, parent: Clip) -> Bool {
        guard let link = caption.connection, link.parentID == parent.id,
              link.sourceStart >= parent.sourceStart,
              link.sourceStart + link.sourceDuration <= parent.sourceStart + parent.sourceDuration else { return false }
        let rate = parent.playbackRate ?? PlaybackRate()
        return caption.start == parent.start + rate.timelineDuration(for: link.sourceStart - parent.sourceStart)
            && caption.duration == rate.timelineDuration(for: link.sourceDuration)
            && caption.start >= parent.start && caption.end <= parent.end
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/ProductionScenarios")
        let library = try AssetLibrary(), fm = FileManager.default
        var checks: [[String: Any]] = [], records: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
        }
        defer {
            try? JSONSerialization.data(withJSONObject: ["checks": checks, "scenarios": records,
                "scope": "Actual EditorModel import/edit/transcribe/installed translation/music/ducking/save/reopen/export queue on owned real iPhone ranges. No human reference, translation quality score, physical speaker or native pointer acceptance."], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        }
        func wait(_ model: EditorModel, phase: String, timeout: Double = 1800, idle: () -> Bool) async throws {
            let begin = ProcessInfo.processInfo.systemUptime; var next = begin
            while !idle() {
                let now = ProcessInfo.processInfo.systemUptime
                if now >= next { print("SCENARIO_PROGRESS phase=\(phase) elapsed=\(Int(now-begin))s transcription=\(model.transcriptionProgress ?? 0) export=\(model.exportProgress)"); next = now + 10 }
                guard now - begin < timeout else { throw ProjectError("Scenario did not finish: " + phase) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let requested = ProcessInfo.processInfo.environment["JHCUT_SCENARIO"] ?? "all"
        for name in ["ad", "promo", "dialogue"] where requested == "all" || requested == name {
            let folder = root.appendingPathComponent(name); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let seconds = name == "ad" ? 45 : (name == "promo" ? 180 : 720)
            let targetWidth = name == "ad" ? 1080 : 1920, targetHeight = name == "ad" ? 1920 : 1080
            // Promo uses 181 seconds of real source, then two actual 0.5-second overlaps: 180 seconds of video.
            let inputs: [(String, Double, Double)] = name == "promo"
                ? [("IMG_0047.mov", 210, 60), ("IMG_0140.mov", 400, 60), ("IMG_9211.mov", 480, 61)]
                : (name == "ad" ? [("IMG_0047.mov", 660, 45)] : [("IMG_0047.mov", 0, 720)])
            var urls: [URL] = [], sourceHashes: [String: String] = [:]
            for (index, input) in inputs.enumerated() {
                let source = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/" + input.0)
                sourceHashes[source.path] = try await FileIdentity.sha256(source)
                let copy = folder.appendingPathComponent("iphone-\(index).mov")
                try await trim(source, start: input.1, seconds: input.2, to: copy); urls.append(copy)
            }
            let model = EditorModel(recoveryStore: RecoveryStore(directory: folder.appendingPathComponent("Recovery")), exportHistoryURL: folder.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: folder.appendingPathComponent("Proxies")))
            model.generatedMediaRoot = folder.appendingPathComponent("Generated"); model.backupRoot = folder.appendingPathComponent("Backups")
            model.reportsDirectory = folder.appendingPathComponent("Reports"); model.libraryMediaStore = LibraryMediaStore(directory: folder.appendingPathComponent("LibraryMedia"))
            model.checkpointStore = TranscriptionCheckpointStore(root: folder.appendingPathComponent("Checkpoints")); model.mediaFingerprints = MediaFingerprintCache()
            model.bundledLibrary = library; model.autoCaptionImportedVideos = false
            var base = Project(name: name == "ad" ? "45초 세로 광고 흐름 검증" : (name == "promo" ? "3분 홍보 편집 검증" : "12분 대화 편집 검증"))
            base.sequence.width = targetWidth; base.sequence.height = targetHeight
            model.history = EditorHistory(project: base)
            model.importFiles(urls); await model.importTask?.value
            check(name + " actual import contains all distinct inputs", model.project.assets.count == urls.count, model.error ?? "")
            guard model.project.assets.count == urls.count else { throw ProjectError("Scenario import failed") }
            let videoTrack = model.project.sequence.tracks.first { $0.kind == .video }!
            var at = MediaTime.zero, clips: [Clip] = []
            for (index, asset) in model.project.assets.enumerated() {
                let duration = MediaTime(seconds: inputs[index].2)
                let clip = Clip(name: "iPhone range \(index+1)", assetID: asset.id, start: at, duration: duration, volume: 0.8)
                clips.append(clip); at = clip.end
            }
            check(name + " edited timeline committed", model.perform(.batch(clips.map { .addClip(trackID: videoTrack.id, clip: $0) })))
            if name == "promo" {
                // Apply a visible, nonidentity correction through the same edit command as the inspector.
                // This is an authored functional setting, not a claim of a correct grade for these scenes.
                let beforeColor = model.project
                let colorEdits = clips.enumerated().map { index, clip -> EditCommand in
                    var value = clip
                    value.visual = VisualAdjustments(exposure: 0.08 + Double(index) * 0.04, contrast: 1.04, saturation: 1.03)
                    return .updateClip(trackID: videoTrack.id, clip: value)
                }
                check("Promo applies nonidentity color to all three source clips", model.perform(.batch(colorEdits)))
                let colored = model.project
                model.undo(); check("Promo color correction is one Undo", model.project == beforeColor)
                model.redo(); check("Promo color correction Redo", model.project == colored)

                model.speechOptions.language = "auto"; model.skipNonSpeech = false; model.speechWindowSeconds = 300
                model.translateAfterTranscription = false
                check("Promo installed local speech model is ready", model.transcriptionReady)
                for (index, parent) in clips.enumerated() {
                    let previousOriginals = CaptionQuery.originals(in: model.project.sequence, scope: .all).map(\.clip)
                    model.selectClip(parent.id); model.transcribeSelection()
                    try await wait(model, phase: "promo-ASR-\(index + 1)", idle: { !model.productivityBusy })
                    let originals = CaptionQuery.originals(in: model.project.sequence, scope: .sources([parent.id])).map(\.clip)
                    check("Promo source \(index + 1) has its own nonempty linked ASR captions", !originals.isEmpty && originals.allSatisfy { $0.captionMetadata != nil && linkedAtSourceTime($0, parent: parent) }, model.error ?? "")
                    let allOriginals = CaptionQuery.originals(in: model.project.sequence, scope: .all).map(\.clip)
                    check("Promo source \(index + 1) ASR preserves all earlier source captions", previousOriginals.allSatisfy { old in allOriginals.first(where: { $0.id == old.id }) == old })
                    guard let first = originals.first, let text = first.title?.text else { throw ProjectError("Promo source \(index + 1) has no recognized captions") }
                    let beforeCorrection = model.project
                    model.updateCaption(first.id, text: text + " [검증]")
                    let corrected = model.project
                    check("Promo source \(index + 1) caption correction applies", corrected != beforeCorrection && CaptionQuery.originals(in: corrected.sequence, scope: .sources([parent.id])).contains { $0.clip.id == first.id && $0.clip.title?.text == text + " [검증]" })
                    model.undo(); check("Promo source \(index + 1) correction Undo", model.project == beforeCorrection)
                    model.redo(); check("Promo source \(index + 1) correction Redo", model.project == corrected)
                }
                let allBeforeTranslation = CaptionQuery.originals(in: model.project.sequence, scope: .all).map(\.clip)
                check("Promo all three input sources contribute captions", Set(allBeforeTranslation.compactMap { $0.connection?.parentID }) == Set(clips.map(\.id)))

                for (index, parent) in clips.enumerated() {
                    let scope = CaptionScope.sources([parent.id])
                    let originals = CaptionQuery.originals(in: model.project.sequence, scope: scope).map(\.clip)
                    let sourceLanguages = Set(originals.compactMap { $0.captionMetadata?.language })
                    // English-only input uses Korean so the acceptance case still exercises translation.
                    let target = sourceLanguages == Set(["en"]) ? "ko" : "en"
                    model.translationTargetLanguage = target; model.translationSourceLanguage = "auto"; model.bilingualTranslation = true
                    let beforeTranslation = model.project
                    let unrelatedBefore = CaptionQuery.entries(in: beforeTranslation.sequence, scope: .all).map(\.clip).filter { $0.connection?.parentID != parent.id }
                    let reviewBefore = originals.filter { $0.captionMetadata?.languageNeedsReview == true }.count
                    model.translateCaptionTracks(scope: scope)
                    try await wait(model, phase: "promo-translation-\(index + 1)", idle: { !model.productivityBusy })
                    var translated = CaptionQuery.entries(in: model.project.sequence, scope: scope, role: .translation, visibleOnly: true).map(\.clip)
                    var override: String?
                    if translated.isEmpty && reviewBefore > 0 {
                        check("Promo source \(index + 1) uncertain automatic translation is refused without edits", model.project == beforeTranslation && model.error?.contains("원문 언어 확인") == true)
                        // Keep the same explicit-setting functional path as ad/dialogue, per source.
                        // A machine dominant label does not constitute human language confirmation.
                        let detected = Set(originals.compactMap { $0.captionMetadata?.clipLanguage })
                        guard detected.count == 1, let language = detected.first, CaptionLanguage(rawValue: language) != nil else { throw ProjectError("Promo source \(index + 1) needs independent language review") }
                        guard language != target else { throw ProjectError("Promo source \(index + 1) dominant language matches target; review the target before continuing") }
                        override = language; model.translationSourceLanguage = language
                        model.translateCaptionTracks(scope: scope)
                        try await wait(model, phase: "promo-explicit-translation-\(index + 1)", idle: { !model.productivityBusy })
                        translated = CaptionQuery.entries(in: model.project.sequence, scope: scope, role: .translation, visibleOnly: true).map(\.clip)
                    }
                    let afterOriginals = CaptionQuery.originals(in: model.project.sequence, scope: scope).map(\.clip)
                    let unrelatedAfter = CaptionQuery.entries(in: model.project.sequence, scope: .all).map(\.clip).filter { $0.connection?.parentID != parent.id }
                    check("Promo source \(index + 1) translation leaves other source captions exact", unrelatedAfter == unrelatedBefore)
                    check("Promo source \(index + 1) translation preserves original text, timing, metadata and uncertainty", originals.count == afterOriginals.count && originals.allSatisfy { old in
                        guard let after = afterOriginals.first(where: { $0.id == old.id }) else { return false }
                        var expected = old; expected.captionHidden = after.captionHidden
                        return expected == after
                    })
                    check("Promo source \(index + 1) translation count and one-to-one linkage match originals", translated.count == originals.count && !translated.isEmpty && Set(translated.compactMap { $0.captionMetadata?.translatedFrom }) == Set(originals.map(\.id)) && translated.allSatisfy { translatedClip in
                        guard let source = originals.first(where: { $0.id == translatedClip.captionMetadata?.translatedFrom }) else { return false }
                        return translatedClip.captionMetadata?.language == target && linkedAtSourceTime(translatedClip, parent: parent)
                            && translatedClip.start == source.start && translatedClip.duration == source.duration
                            && translatedClip.connection?.sourceStart == source.connection?.sourceStart
                            && translatedClip.connection?.sourceDuration == source.connection?.sourceDuration
                    }, model.error ?? "")
                    guard !translated.isEmpty else { throw ProjectError("Promo installed translation produced no linked captions") }
                    records.append(["name": name, "sourceIndex": index + 1, "sourceClipID": parent.id.uuidString,
                        "originalCaptions": originals.count, "translatedCaptions": translated.count,
                        "detectedLanguages": Array(sourceLanguages).sorted(), "languageReviewRequired": reviewBefore,
                        "targetLanguage": target, "translationSourceOverride": override ?? "auto",
                        "overrideBasis": override == nil ? "automatic per-caption language" : "machine dominant clip label; explicit functional setting, not human confirmation",
                        "accuracy": "unscored: no human reference", "translationQuality": "not human-reviewed"])
                }

                let completeOriginals = CaptionQuery.originals(in: model.project.sequence, scope: .all).map(\.clip)
                let completeTranslations = CaptionQuery.entries(in: model.project.sequence, scope: .all, role: .translation, visibleOnly: true).map(\.clip)
                check("Promo complete translation retains all source originals", completeOriginals.count == allBeforeTranslation.count && allBeforeTranslation.allSatisfy { old in
                    guard let new = completeOriginals.first(where: { $0.id == old.id }) else { return false }
                    var expected = old; expected.captionHidden = new.captionHidden
                    return expected == new
                })
                check("Promo all three source scopes retain exactly one translation per original", completeTranslations.count == allBeforeTranslation.count && Set(completeTranslations.compactMap { $0.captionMetadata?.translatedFrom }) == Set(allBeforeTranslation.map(\.id)) && Set(completeTranslations.compactMap { $0.connection?.parentID }) == Set(clips.map(\.id)))

                // Exercise the app transition API AFTER generating captions so source-linked global
                // times must be remapped. The third real source is one second longer to preserve 180 s.
                let beforeTransitions = model.project
                let beforeTransitionCaptions = CaptionQuery.entries(in: beforeTransitions.sequence, scope: .all).map(\.clip)
                for (index, parent) in clips.prefix(2).enumerated() {
                    model.selectClip(parent.id)
                    let before = model.project
                    model.addTransition(kind: index == 0 ? .dissolve : .wipe, direction: .fromRight, seconds: 0.5)
                    let after = model.project
                    check("Promo transition \(index + 1) creates a real half-second overlap", after != before && after.sequence.tracks.filter { $0.transitionContext != nil }.count == index + 1, model.error ?? "")
                    model.undo(); check("Promo transition \(index + 1) Undo", model.project == before)
                    model.redo(); check("Promo transition \(index + 1) Redo", model.project == after)
                }
                let finalSources = clips.compactMap { source in model.project.sequence.tracks.flatMap(\.clips).first { $0.id == source.id } }
                let expectedStarts = [MediaTime.zero, MediaTime(119, 2), MediaTime(119, 1)]
                check("Promo source starts reflect exactly two overlaps", finalSources.count == 3 && finalSources.enumerated().allSatisfy { index, clip in clip.start == expectedStarts[index] && clip.duration == clips[index].duration && clip.sourceStart == clips[index].sourceStart && clip.visual == colored.sequence.tracks.flatMap(\.clips).first(where: { $0.id == clip.id })?.visual })
                var coveredThrough = MediaTime.zero, contiguous = finalSources.count == 3
                for source in finalSources.sorted(by: { $0.start < $1.start }) {
                    contiguous = contiguous && source.start <= coveredThrough
                    coveredThrough = max(coveredThrough, source.end)
                }
                check("Promo actual video alone covers exactly 180 seconds with no gaps", contiguous && coveredThrough == MediaTime(180, 1))
                let remapped = CaptionQuery.entries(in: model.project.sequence, scope: .all).map(\.clip)
                check("Promo transitions preserve every original/translated caption and remap once", remapped.count == beforeTransitionCaptions.count && beforeTransitionCaptions.allSatisfy { old in
                    guard let new = remapped.first(where: { $0.id == old.id }), let parentID = old.connection?.parentID,
                          let oldParent = clips.first(where: { $0.id == parentID }), let parent = finalSources.first(where: { $0.id == parentID }) else { return false }
                    return new.start == old.start + parent.start - oldParent.start && new.duration == old.duration
                        && new.connection == old.connection && new.captionMetadata == old.captionMetadata
                        && new.title == old.title && new.captionRole == old.captionRole && new.captionHidden == old.captionHidden
                        && linkedAtSourceTime(new, parent: parent)
                })
                // Add template only after overlap edits, so its last title cannot hide shortened video.
                let before = model.project; model.applyTemplate(.story)
                check("Promo application template adds authored titles", model.project.sequence.tracks.count == before.sequence.tracks.count + 1)
                let after = model.project; model.undo(); check("Promo template is one Undo", model.project == before); model.redo(); check("Promo template Redo", model.project == after)
                records.append(["name": name, "inputSeconds": inputs.map { $0.2 }, "transitionSeconds": [0.5, 0.5],
                    "videoCoverageSeconds": coveredThrough.seconds,
                    "scope": "Three real iPhone ranges with per-source local ASR and installed translation, linked-caption remapping through two transitions, mild authored color, titles, ducked music, save/reopen, SRT and full decode. No native pointer, speaker or human semantic acceptance."])
            } else {
                model.speechOptions.language = "auto"; model.skipNonSpeech = false; model.speechWindowSeconds = 300
                model.translateAfterTranscription = false; model.selectClip(clips[0].id)
                check("Installed local speech model is ready", model.transcriptionReady)
                model.transcribeSelection()
                try await wait(model, phase: "dialogue-ASR", idle: { !model.productivityBusy })
                let original = CaptionQuery.originals(in: model.project.sequence, scope: .all).map(\.clip)
                check(name + " app ASR yields linked original captions", !original.isEmpty && original.allSatisfy { $0.captionMetadata != nil && $0.connection?.parentID == clips[0].id }, model.error ?? "")
                guard let first = original.first, let text = first.title?.text else { throw ProjectError("Real dialogue transcription produced no captions") }
                check("Original captions stay within timeline", original.allSatisfy { $0.start >= .zero && $0.end <= MediaTime(seconds: Double(seconds)) && $0.duration > .zero })
                let before = model.project
                model.updateCaption(first.id, text: text + " [검증]"); let edited = model.project
                check("Original text correction applies", edited != before)
                model.undo(); check("Caption correction Undo", model.project == before); model.redo(); check("Caption correction Redo", model.project == edited)
                model.translationTargetLanguage = "en"; model.translationSourceLanguage = "auto"; model.bilingualTranslation = true
                let beforeTranslation = model.project
                let reviewBefore = CaptionQuery.originals(in: model.project.sequence, scope: .all).filter { $0.clip.captionMetadata?.languageNeedsReview == true }.count
                model.translateCaptionTracks(scope: .all)
                try await wait(model, phase: "dialogue-translation", idle: { !model.productivityBusy })
                var translated = CaptionQuery.entries(in: model.project.sequence, scope: .all, role: .translation, visibleOnly: true).map(\.clip)
                if translated.isEmpty && reviewBefore > 0 {
                    check("Automatic translation refuses uncertain language and preserves originals", model.project == beforeTranslation && model.error?.contains("원문 언어 확인") == true)
                    let detected = Set(original.compactMap { $0.captionMetadata?.originalLanguage })
                    guard detected.count == 1, let language = detected.first, CaptionLanguage(rawValue: language) != nil else { throw ProjectError("Mixed or unsupported language needs independent review") }
                    // Exercise the product's explicit source-language setting. This test operator uses
                    // the recognizer's dominant label, without claiming a human language/accuracy review.
                    model.translationSourceLanguage = language
                    records.append(["name": name, "translationSourceOverride": language, "basis": "machine dominant label; functional explicit-language setting, not human confirmation"])
                    model.translateCaptionTracks(scope: .all)
                    try await wait(model, phase: "dialogue-explicit-translation", idle: { !model.productivityBusy })
                    translated = CaptionQuery.entries(in: model.project.sequence, scope: .all, role: .translation, visibleOnly: true).map(\.clip)
                    check("Explicit-language translation preserves original uncertainty flags", CaptionQuery.originals(in: model.project.sequence, scope: .all).filter { $0.clip.captionMetadata?.languageNeedsReview == true }.count == reviewBefore)
                }
                check("Installed translation produces visible linked captions", !translated.isEmpty && translated.allSatisfy { $0.captionMetadata?.language == "en" }, model.error ?? "")
                records.append(["name": name, "originalCaptions": original.count, "translatedCaptions": translated.count,
                    "detectedLanguages": Array(Set(original.compactMap { $0.captionMetadata?.originalLanguage })).sorted(),
                    "languageReviewRequired": original.filter { $0.captionMetadata?.languageNeedsReview == true }.count,
                    "accuracy": "unscored: no human reference", "translationQuality": "not human-reviewed"])
                guard !translated.isEmpty else { throw ProjectError("Actual installed translation failed; original captions retained") }
            }
            if name == "ad" {
                let beforeTemplate = model.project
                model.applyTemplate(.social)
                guard let titleTrack = model.project.sequence.tracks.last, titleTrack.clips.count == 3 else { throw ProjectError("Social template failed") }
                let words = ["45초 편집 검증", "영상과 자막을 함께 편집", "JH CUT Studio"]
                let edits = titleTrack.clips.enumerated().map { index, value -> EditCommand in
                    var clip = value; clip.title?.text = words[index]
                    return .updateClip(trackID: titleTrack.id, clip: clip)
                }
                check("Ad replaces template placeholders with authored validation copy", model.perform(.batch(edits)))
                let styled = model.project
                model.undo(); model.undo(); check("Ad template and copy Undo retain generated captions", model.project == beforeTemplate)
                model.redo(); model.redo(); check("Ad template and copy Redo", model.project == styled)
                let logoSource = URL(fileURLWithPath: "Resources/Brand/JHCutStudio-logo-sRGB.png")
                let logoSHA = try await FileIdentity.sha256(logoSource)
                let logo = folder.appendingPathComponent("JHCutStudio-logo.png")
                try fm.copyItem(at: logoSource, to: logo)
                model.importFiles([logo]); await model.importTask?.value
                guard let asset = model.project.assets.first(where: { $0.name == logo.lastPathComponent }),
                      let overlay = model.project.sequence.tracks.first(where: { $0.kind == .overlay }) else { throw ProjectError("Ad logo import failed") }
                var logoClip = Clip(name: "JH CUT Studio validation logo", assetID: asset.id, duration: MediaTime(45,1))
                logoClip.transform.scale = 0.13; logoClip.transform.x = 400; logoClip.transform.y = 780
                check("Ad actual app adds logo overlay", model.perform(.addClip(trackID: overlay.id, clip: logoClip)))
                check("Ad source logo bytes unchanged", try await FileIdentity.sha256(logoSource) == logoSHA)
                guard let sound = library.assets.first(where: { $0.category == .sfx && ($0.duration ?? 99) < 2 }) else { throw ProjectError("Ad short effect missing") }
                model.playhead = 42; model.insertLibraryAsset(sound); await model.importTask?.value
                check("Ad actual app applies a short effect within end card", model.selected?.1.start == MediaTime(42,1) && (model.selected?.1.end ?? MediaTime(99,1)) <= MediaTime(45,1))
                records.append(["name":name,"logoSHA256":logoSHA,"copy":"Authored functional validation copy, not claims about a real advertiser","scope":"Vertical actual iPhone range with local ASR, installed translation, social title template, app logo, sound effect, music, ducking, save/reopen/queue/SRT/full decode. Native pointer and human quality acceptance remain separate."])
            }
            let music = library.assets.filter { $0.category == .music && (120...180).contains($0.duration ?? 0) }.max { ($0.duration ?? 0) < ($1.duration ?? 0) }!
            model.playhead = 0; model.insertLibraryAsset(music); await model.importTask?.value
            guard let selected = model.selected, let musicAsset = model.project.assets.first(where: { $0.id == selected.1.assetID }) else { throw ProjectError("Scenario music insertion failed") }
            var musicClip = selected.1; musicClip.volume = 0.12
            check(name + " real music volume edited", model.perform(.updateClip(trackID: selected.0.id, clip: musicClip)))
            model.duckSelectedMusic(); check("App ducking retains volume/fades", model.selected?.1.ducking?.isEmpty == false && model.selected?.1.volume == 0.12)
            var cursor = musicClip.end
            while cursor < MediaTime(seconds: Double(seconds)) {
                var next = model.selected?.1 ?? musicClip; next.id = UUID(); next.start = cursor; next.sourceStart = .zero
                next.duration = min(musicAsset.duration, MediaTime(seconds: Double(seconds)) - cursor); next.ducking = nil
                let fade = min(MediaTime(1, 1), MediaTime(seconds: next.duration.seconds / 4)); next.audioFadeIn = fade; next.audioFadeOut = fade
                check(name + " explicit repeated music placement", model.perform(.addClip(trackID: selected.0.id, clip: next)))
                model.selectClip(next.id); model.duckSelectedMusic()
                check("Repeated music ducking is applied", model.selected?.1.ducking?.isEmpty == false)
                cursor = next.end
            }
            check(name + " final timeline has exact target duration", model.project.sequence.duration == MediaTime(seconds: Double(seconds)))
            let document = folder.appendingPathComponent("Project.jhcut")
            let beforeSave = model.project
            var savedAssetHashes: [UUID: String] = [:]
            for asset in beforeSave.assets { savedAssetHashes[asset.id] = try await FileIdentity.sha256(asset.resolvedURL(relativeTo: model.mediaBaseURL)) }
            model.documentURL = document; model.save()
            check(name + " actual app saves edited project", fm.fileExists(atPath: document.path) && !model.dirty, model.error ?? "")
            guard !model.dirty else { throw ProjectError("Scenario save failed") }
            let savedProject = try ProjectStore.load(from: document)
            check(name + " save preserves exact sequence including all caption metadata", savedProject.sequence == beforeSave.sequence)
            // ProjectStore writes bookmark/relativePath and resolves path. Normalize only these transport
            // fields, verifying their resolved file identities independently; all edit fields stay exact.
            var normalizedSaved = savedProject
            var assetIdentityPreserved = savedProject.assets.map(\.id) == beforeSave.assets.map(\.id)
            for index in normalizedSaved.assets.indices {
                guard let old = beforeSave.assets.first(where: { $0.id == normalizedSaved.assets[index].id }) else { assetIdentityPreserved = false; continue }
                let savedURL = normalizedSaved.assets[index].resolvedURL(relativeTo: document)
                let oldURL = old.resolvedURL(relativeTo: model.mediaBaseURL)
                assetIdentityPreserved = assetIdentityPreserved && savedURL.standardizedFileURL == oldURL.standardizedFileURL
                let savedHash = try await FileIdentity.sha256(savedURL)
                assetIdentityPreserved = assetIdentityPreserved && savedAssetHashes[old.id] == savedHash
                normalizedSaved.assets[index].path = old.path
                normalizedSaved.assets[index].relativePath = old.relativePath
                normalizedSaved.assets[index].bookmark = old.bookmark
            }
            check(name + " save preserves the whole edited project after documented path normalization", assetIdentityPreserved && normalizedSaved == beforeSave)
            model.load(document)
            try await wait(model, phase: name + "-reopen", timeout: 120, idle: { !model.isBuilding && !model.isImporting })
            check(name + " saved captions/timing/media survive real app reload", model.project.sequence.duration == MediaTime(seconds: Double(seconds)) && model.project.assets.allSatisfy { fm.fileExists(atPath: $0.resolvedURL(relativeTo: document).path) } && model.plan != nil, model.error ?? "")
            check(name + " reopened project exactly matches saved normalized project", model.project == savedProject)
            let savedCaptions = CaptionQuery.entries(in: savedProject.sequence, scope: .all).map(\.clip)
            let reopenedCaptions = CaptionQuery.entries(in: model.project.sequence, scope: .all).map(\.clip)
            check(name + " reopened captions preserve exact count, text, times, parent and translation links", reopenedCaptions == savedCaptions && !reopenedCaptions.isEmpty)
            let output = folder.appendingPathComponent(name + ".mp4")
            let request = QueuedExport(project: model.project, baseURL: document, url: output, codec: .h264, bitRate: 8_000_000, sidecarSRT: true)
            model.exportQueue = [request]; model.startNextExport()
            try await wait(model, phase: name + "-export", idle: { !model.isExporting })
            check(name + " actual queue publishes movie and QA", model.lastExportReceipt?.jobID == request.id && model.lastExportReceipt?.movie == .published && model.lastExportReceipt?.quality == .completed && model.lastExportReceipt?.report == .published, model.error ?? "")
            check(name + " QA has no errors", model.lastQualityReport?.errors == 0)
            guard fm.fileExists(atPath: output.path) else { throw ProjectError("Scenario movie was not published") }
            let decoded = try await MediaInspection.decode(output)
            check(name + " complete output frames/size/time", decoded.width == targetWidth && decoded.height == targetHeight && decoded.frameCount == seconds * 30 && decoded.monotonic && abs(decoded.videoEndSeconds - Double(seconds)) < 0.001)
            check(name + " full audio reaches movie end", decoded.audioRMS > 0.0001 && abs((decoded.metrics["audioPresentationEndSeconds"] ?? 0) - Double(seconds)) < 0.05)
            let srt = output.deletingPathExtension().appendingPathExtension("srt")
            let cues = try SRTCodec.parse(String(contentsOf: srt, encoding: .utf8))
            check("App writes matching nonempty sidecar subtitles", !cues.isEmpty && cues.allSatisfy { $0.start >= .zero && $0.start + $0.duration <= MediaTime(seconds: Double(seconds)) })
            let expectedCaptions = CaptionQuery.entries(in: request.project.sequence, scope: .all, visibleOnly: true).map(\.clip)
            check(name + " queue publishes sidecar for this job", model.lastExportReceipt?.subtitles == .published && model.lastExportReceipt?.subtitleURL == srt.path)
            check(name + " sidecar contains every visible caption exactly once", cues.count == expectedCaptions.count && !expectedCaptions.isEmpty)
            check(name + " sidecar matches exact text and independently rounded millisecond times", cues.count == expectedCaptions.count && zip(cues, expectedCaptions).allSatisfy { cue, clip in
                let text = (clip.title?.text ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                return cue.text == text && cue.start == srtTime(clip.start) && cue.start + cue.duration == srtTime(clip.end)
            })
            records.append(["name": name, "seconds": seconds, "outputMetrics": decoded.metrics, "qualityErrors": model.lastQualityReport?.errors ?? -1])
            for (path, expected) in sourceHashes { check(name + " authorized source copy unchanged", try await FileIdentity.sha256(URL(fileURLWithPath: path)) == expected) }
            model.invalidateAsyncJobs(); model.pausePlayback()
        }
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("PRODUCTION_SCENARIO_RESULT checks=\(checks.count) failures=\(failures)")
        if failures > 0 { throw ProjectError("Production scenarios failed \(failures) checks") }
    }
}

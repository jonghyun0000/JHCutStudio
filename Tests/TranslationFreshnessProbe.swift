import Foundation
import AppKit
@testable import JHCutCore

@main struct TranslationFreshnessProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "TranslationFreshness")
        var rows: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { rows.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)") }
        defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
        model.autoCaptionImportedVideos = false; model.translateAfterTranscription = false
        model.translationTargetLanguage = "ko"; model.translationSourceLanguage = "auto"
        var requests: [[CaptionTranslationRequest]] = []
        func goodProvider() {
            model.translationProvider = nil
            model.translationBatchProvider = { input, _, _ in
                requests.append(input)
                return input.reversed().map { CaptionTranslationResponse(id: $0.id, text: "번역: " + $0.text) }
            }
        }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(30)
            while model.productivityBusy || model.productivityTask != nil {
                guard Date() < deadline else { throw ProjectError("Translation probe timeout") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let group = UUID()
        func original(_ text: String, at seconds: Int = 1, groupID: UUID? = nil, language: String = "en") -> Clip {
            var clip = Clip(name: "자동 자막", start: MediaTime(Int64(seconds), 1), duration: MediaTime(2, 1), title: Title(text: text))
            clip.captionRole = .original; clip.captionGroupID = groupID ?? group
            clip.captionMetadata = CaptionMetadata(language: language, originalLanguage: language, originalText: text, generatedText: text)
            return clip
        }
        // Stage8's list editor excludes hidden captions. These freshness checks model an
        // explicit inspector edit of the preserved original, through the same validated history.
        func editPreservedOriginalThroughInspector(_ id: UUID, text: String) {
            guard let entry = CaptionQuery.entries(in: model.project.sequence, scope: .selected([id]), role: .original).first else { return }
            var clip = entry.clip; clip.title?.text = text
            model.perform(.updateClip(trackID: entry.track.id, clip: clip))
        }
        let a = original("Hello Minsu."), b = original("Different words at the same time.")
        var initial = Project(name: "Translation identity fixture")
        initial.sequence.tracks[2].clips = [a, b]
        let decoration = Clip(name: "Other title", duration: MediaTime(3, 1), title: Title(text: "Decoration"))
        let outside = original("Outside scope", at: 8, groupID: UUID())
        initial.sequence.tracks.append(Track(name: "Unrelated hidden locked", kind: .title, clips: [outside, decoration], isHidden: true, isLocked: true))
        model.history = EditorHistory(project: initial); goodProvider()
        model.translateCaptionTracks(scope: .groups([group])); try await settle()
        let translated = model.project
        func translations(_ p: Project) -> [Clip] { CaptionQuery.entries(in: p.sequence, role: .translation).map(\.clip) }
        func forSource(_ p: Project, _ id: UUID) -> Clip { translations(p).first { $0.captionMetadata?.translatedFrom == id }! }
        let ta = forSource(translated, a.id), tb = forSource(translated, b.id)
        check("Same-time cues receive separate exact source IDs", translations(translated).count == 2 && ta.id != tb.id && !CaptionQuery.related(ta, to: b))
        check("Reordered identified responses reassemble by sentence ID", ta.title?.text == "번역: " + a.title!.text && tb.title?.text == "번역: " + b.title!.text)
        check("New revisions are valid and current", translations(translated).allSatisfy { $0.captionMetadata?.translationRevision?.isValid == true && model.translationFreshness($0) == .current })
        check("Outside scope preserves entire locked hidden track", translated.sequence.tracks.first { $0.id == initial.sequence.tracks.last!.id } == initial.sequence.tracks.last)
        model.undo(); check("Translation applies in one Undo", model.project == initial)
        model.redo(); check("Translation Redo restores revisions", model.project == translated)
        requests = []; model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Latest captions issue zero provider requests", requests.isEmpty && model.project == translated)
        editPreservedOriginalThroughInspector(a.id, text: "Hello revised Minsu.")
        check("Original edits immediately show sourceChanged", model.translationFreshness(forSource(model.project, a.id)) == .sourceChanged && model.translationFreshness(forSource(model.project, b.id)) == .current)
        check("Creation-time source text remains available", forSource(model.project, a.id).captionMetadata?.originalText == "Hello Minsu.")
        requests = []; model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Only stale automatic caption is requested", requests.flatMap { $0 }.map(\.id) == [a.id] && forSource(model.project, b.id) == tb)
        check("Refreshed caption records new source snapshot", forSource(model.project, a.id).captionMetadata?.originalText == "Hello revised Minsu." && model.translationFreshness(forSource(model.project, a.id)) == .current)
        let refreshed = model.project, manualID = forSource(refreshed, a.id).id
        model.updateCaption(manualID, text: "내가 직접 다듬은 번역입니다.")
        editPreservedOriginalThroughInspector(a.id, text: "Changed again while translation is manual.")
        let manualSnapshot = model.project, manual = forSource(manualSnapshot, a.id)
        requests = []; model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Manual correction after source edit makes no provider request", requests.isEmpty && forSource(model.project, a.id) == manual)
        check("Manual status takes priority over source staleness", model.translationFreshness(manual) == .manualKept)
        requests = []; model.regenerateManualTranslation(manual.id); try await settle()
        check("Explicit one-cue replacement targets only that source", requests.flatMap { $0 }.map(\.id) == [a.id] && forSource(model.project, b.id) == tb)
        check("Explicit replacement creates current automatic translation", forSource(model.project, a.id).title?.text != manual.title?.text && model.translationFreshness(forSource(model.project, a.id)) == .current)
        model.undo(); check("Undo recovers exact manual text and revision", model.project == manualSnapshot)
        model.redo(); let current = model.project
        model.translationStyle = "polite"
        check("Style change marks automatic translation stale", model.translationFreshness(forSource(model.project, a.id)) == .settingsChanged)
        model.translationStyle = "natural"; model.bilingualTranslation = true
        check("Bilingual setting marks translation stale", model.translationFreshness(forSource(model.project, a.id)) == .settingsChanged)
        model.bilingualTranslation = false; model.translationGlossaryText = "Minsu=민수"
        check("Quick glossary change marks translation stale", model.translationFreshness(forSource(model.project, a.id)) == .settingsChanged)
        model.translationGlossaryText = ""
        let term = GlossaryEntry(source: "Minsu", target: "민수")
        let sameTerm = GlossaryEntry(source: "Minsu", target: "민수")
        let recipe = CaptionTranslationTracking.recipeDigest(source: "en", target: "ko", glossary: [], style: .natural, bilingual: false)
        check("Glossary UUID does not alter behavior digest", CaptionTranslationTracking.recipeDigest(source: "en", target: "ko", glossary: [term], style: .natural, bilingual: false) == CaptionTranslationTracking.recipeDigest(source: "en", target: "ko", glossary: [sameTerm], style: .natural, bilingual: false))
        check("Irrelevant language glossary does not invalidate recipe", recipe == CaptionTranslationTracking.recipeDigest(source: "en", target: "ko", glossary: [GlossaryEntry(source: "Name", target: "이름", sourceLanguage: "ja")], style: .natural, bilingual: false))
        model.perform(.replaceGlossary([term]))
        check("Saved glossary revision marks translations stale", model.translationFreshness(forSource(model.project, a.id)) == .settingsChanged)
        editPreservedOriginalThroughInspector(a.id, text: "Minsu changed again.")
        requests = []; model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Group glossary refresh uses one consistent recipe", translations(model.project).allSatisfy { model.translationFreshness($0) == .current } && forSource(model.project, a.id).captionMetadata?.glossaryApplied == ["Minsu"])
        model.history = EditorHistory(project: current); model.setCaptionLanguage([a.id], to: "ja")
        check("Manual source language edit marks translation stale", model.translationFreshness(forSource(model.project, a.id)) == .sourceChanged)
        model.history = EditorHistory(project: current)
        var stale = current; let ai = stale.sequence.tracks[2].clips.firstIndex { $0.id == a.id }!; stale.sequence.tracks[2].clips[ai].title?.text += " new"
        for mode in ["missing", "duplicate", "unknown", "empty", "extra"] {
            model.history = EditorHistory(project: stale); model.error = nil
            model.translationBatchProvider = { input, _, _ in
                let response = CaptionTranslationResponse(id: input[0].id, text: "valid")
                switch mode {
                case "missing": return []
                case "duplicate": return [response, response]
                case "unknown": return [CaptionTranslationResponse(id: UUID(), text: "wrong")]
                case "empty": return [CaptionTranslationResponse(id: input[0].id, text: "  \n")]
                default: return [response, CaptionTranslationResponse(id: UUID(), text: "extra")]
                }
            }
            model.translateCaptionTracks(scope: .groups([group])); try await settle()
            check("\(mode) response preserves whole document", model.project == stale && model.error != nil && model.translationFreshness(forSource(model.project, a.id)) == .failed && model.translationFreshness(forSource(model.project, b.id)) == .current)
        }
        let rq = [CaptionTranslationRequest(id: a.id, text: "a"), CaptionTranslationRequest(id: b.id, text: "b")]
        do { _ = try CaptionTranslationResponses.ordered([CaptionTranslationResponse(id: a.id, text: "a"), CaptionTranslationResponse(id: a.id, text: "b")], for: rq); check("Equal-count duplicate IDs rejected", false) }
        catch { check("Equal-count duplicate IDs rejected", true) }
        model.history = EditorHistory(project: stale); model.error = nil
        model.translationBatchProvider = { input, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return input.map { CaptionTranslationResponse(id: $0.id, text: "late") } }
        model.translateCaptionTracks(scope: .groups([group])); model.cancelProductivity(); try await settle()
        check("Cancellation leaves document and failure state unchanged", model.project == stale && model.error == nil && !model.translationActive && model.translationFailureSourceIDs.isEmpty)
        model.translationBatchProvider = { input, _, _ in try await Task.sleep(nanoseconds: 100_000_000); return input.map { CaptionTranslationResponse(id: $0.id, text: "late") } }
        model.translateCaptionTracks(scope: .groups([group])); var changed = stale; changed.name = "Changed during translation"; model.history = EditorHistory(project: changed); try await settle()
        check("Snapshot guard prevents late overwrite", model.project == changed && model.error?.contains("프로젝트가 변경") == true)
        model.history = EditorHistory(project: stale); model.error = nil; goodProvider()
        requests = []; model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Successful retry clears failed source state", model.error == nil && model.translationFailureSourceIDs.isEmpty && model.translationFreshness(forSource(model.project, a.id)) == .current)
        var uncertain = stale; uncertain.sequence.tracks[2].clips[ai].captionMetadata?.languageNeedsReview = true
        model.history = EditorHistory(project: uncertain); model.error = nil; requests = []
        model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Uncertain auto source never silently forces guessed translation", requests.isEmpty && model.project == uncertain && model.error?.contains("원문 언어 확인") == true)
        model.error = nil; model.translationSourceLanguage = "en"; model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Explicit source override permits reviewed translation", model.error == nil && model.translationFreshness(forSource(model.project, a.id)) == .current)
        model.translationSourceLanguage = "auto"
        check("Removing override restores source language review warning", model.translationFreshness(forSource(model.project, a.id)) == .reviewRequired)
        model.history = EditorHistory(project: current); model.error = nil
        var missing = current; missing.sequence.tracks[2].clips.removeAll { $0.id == a.id }; model.history = EditorHistory(project: missing)
        check("Deleted or re-recognized source ID shows missing link", model.translationFreshness(ta) == .sourceMissing)
        var legacy = ta; legacy.captionMetadata?.translationRevision = nil
        check("Legacy translation reports unknown creation recipe", CaptionTranslationTracking.automaticState(of: legacy, source: a, language: "en", recipe: recipe) == .legacy)
        var wrong = b; wrong.lineageID = a.id
        check("Exact revision rejects overlapping sibling lineage", !CaptionQuery.related(ta, to: wrong))
        // 70 requests span local batch boundaries. Same-time IDs above exercise ordering separately.
        let many = (0..<70).map { original("Sentence \($0)", at: $0 * 2) }
        var bulk = initial; bulk.sequence.tracks[2].clips = many
        model.history = EditorHistory(project: bulk); requests = []; goodProvider(); model.error = nil
        model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Local groups chunk 70 cues as 32/32/6", requests.map(\.count) == [32, 32, 6])
        check("Reassembly retains every original ID once", Set(translations(model.project).compactMap { $0.captionMetadata?.translatedFrom }) == Set(many.map(\.id)) && translations(model.project).count == 70)
        check("Shuffled responses across chunks retain all words", many.allSatisfy { forSource(model.project, $0.id).title?.text == "번역: " + $0.title!.text })
        let separate = [original("one", at: 0), original("two", at: 2, groupID: UUID()), original("three", at: 4)]
        check("Group boundaries never combine independent sources", CaptionTranslationBatching.batches(separate).map(\.count) == [1, 1, 1])
        var speakers = [original("one", at: 0), original("two", at: 2)]; speakers[0].captionMetadata?.speaker = "A"; speakers[1].captionMetadata?.speaker = "B"
        check("Speaker boundary starts separate batch", CaptionTranslationBatching.batches(speakers).count == 2)
        check("Long temporal gap starts separate batch", CaptionTranslationBatching.batches([original("one", at: 0), original("two", at: 30)]).count == 2)
        check("Character budget splits batches without dropping text", CaptionTranslationBatching.batches([original(String(repeating: "x", count: 9000), at: 0), original(String(repeating: "y", count: 9000), at: 2)], maxCharacters: 10_000).count == 2)
        // One direction succeeds locally, second fails: nothing from first direction is committed.
        var mixed = initial; mixed.sequence.tracks[2].clips = [a, original("日本語の文です。", at: 3, language: "ja")]
        model.history = EditorHistory(project: mixed); model.error = nil; var directions: [String] = []
        model.translationBatchProvider = { input, source, _ in directions.append(source); if source == "ja" { throw ProjectError("언어팩 없음 fixture") }; return input.map { CaptionTranslationResponse(id: $0.id, text: "valid") } }
        model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("One-direction pack failure cannot commit other direction", directions == ["en", "ja"] && model.project == mixed && model.error?.contains("언어팩") == true)
        // Connected parent split/duplicate/derive exercise actual EditorHistory reconciliation.
        let asset = MediaAsset(name: "Fixture", path: "/fixture/translation-source.mov", kind: .video, duration: MediaTime(20, 1), width: 640, height: 360, hasAudio: true)
        let parent = Clip(name: "Parent", assetID: asset.id, duration: MediaTime(6, 1))
        var attached = original("Spanning source.", at: 0); attached.duration = MediaTime(6, 1); attached.captionGroupID = parent.id
        attached.connection = ClipConnection(parentID: parent.id, sourceStart: .zero, sourceDuration: attached.duration, generatedText: attached.title!.text)
        var target = try CaptionTranslationEditing.translated(attached, text: "연결 번역", sourceLanguage: "en", targetLanguage: "ko", bilingual: false)
        target.captionMetadata?.translationRevision = CaptionTranslationTracking.revision(for: attached, language: "en", recipe: recipe)
        var connected = Project(); connected.assets = [asset]; connected.sequence.tracks[0].clips = [parent]; connected.sequence.tracks[2].clips = [attached, target]
        var history = EditorHistory(project: connected)
        try history.apply(.split(trackID: connected.sequence.tracks[0].id, clipID: parent.id, at: MediaTime(3, 1)))
        let split = history.project
        check("Parent split rebinds each translation to its own cue ID", translations(split).count == 2 && translations(split).allSatisfy { tr in CaptionTranslationTracking.source(for: tr, in: split.sequence).map { $0.start == tr.start && $0.duration == tr.duration && $0.id == tr.captionMetadata?.translatedFrom } == true })
        check("Split pieces retain creation snapshot and mark stale", translations(split).allSatisfy { tr in CaptionTranslationTracking.automaticState(of: tr, source: CaptionTranslationTracking.source(for: tr, in: split.sequence), language: "en", recipe: recipe) == .sourceChanged && tr.captionMetadata?.originalText == "Spanning source." })
        history.undo(); check("Split undo restores exact identity graph", history.project == connected)
        try history.apply(.move(trackID: connected.sequence.tracks[0].id, clipID: parent.id, to: MediaTime(5, 1)))
        let moved = history.project
        check("Connected timeline move remains current", translations(moved).allSatisfy { CaptionTranslationTracking.automaticState(of: $0, source: CaptionTranslationTracking.source(for: $0, in: moved.sequence), language: "en", recipe: recipe) == .current })
        history = EditorHistory(project: connected); try history.apply(.duplicate(trackID: connected.sequence.tracks[0].id, clipID: parent.id))
        let duplicate = history.project
        check("Duplicate sources remap exact revision IDs", translations(duplicate).count == 2 && translations(duplicate).allSatisfy { tr in CaptionTranslationTracking.source(for: tr, in: duplicate.sequence)?.id == tr.captionMetadata?.translatedFrom })
        history = EditorHistory(project: connected); try history.apply(.deriveSequence(name: "Copy", width: 640, height: 360))
        let derived = history.project
        check("Derived sequence remaps revisions without stale IDs", translations(derived).allSatisfy { tr in let source = CaptionTranslationTracking.source(for: tr, in: derived.sequence); return source?.id != attached.id && source?.id == tr.captionMetadata?.translatedFrom && CaptionTranslationTracking.automaticState(of: tr, source: source, language: "en", recipe: recipe) == .current })
        var mergeFirst = original("one", at: 0), mergeSecond = original("two", at: 2)
        mergeFirst.duration = MediaTime(2, 1); mergeSecond.duration = MediaTime(2, 1)
        let merged = try CaptionEditing.merged(first: mergeFirst, second: mergeSecond)
        var beforeMerge = try CaptionTranslationEditing.translated(mergeFirst, text: "하나", sourceLanguage: "en", targetLanguage: "ko", bilingual: false)
        beforeMerge.captionMetadata?.translationRevision = CaptionTranslationTracking.revision(for: mergeFirst, language: "en", recipe: recipe)
        check("Merged source is stale by text and interval", CaptionTranslationTracking.automaticState(of: beforeMerge, source: merged, language: "en", recipe: recipe) == .sourceChanged)
        let url = root.appendingPathComponent("revision.jhcut")
        var preRevision = translated
        for ti in preRevision.sequence.tracks.indices { for ci in preRevision.sequence.tracks[ti].clips.indices { preRevision.sequence.tracks[ti].clips[ci].captionMetadata?.translationRevision = nil } }
        try ProjectStore.save(preRevision, to: url); let oldBytes = try Data(contentsOf: url)
        try ProjectStore.save(translated, to: url)
        check("First revision save preserves permanent old bytes", try Data(contentsOf: ProjectStore.beforeTranslationRevisionURL(for: url)) == oldBytes)
        check("Round trip preserves exact revision and hidden scope", try ProjectStore.load(from: url).sequence == translated.sequence)
        try ProjectStore.save(current, to: url)
        check("Later save cannot replace permanent revision backup", try Data(contentsOf: ProjectStore.beforeTranslationRevisionURL(for: url)) == oldBytes)
        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: encoder.encode(translated)) as! [String: Any]
        var seq = json["sequence"] as! [String: Any], tracks = seq["tracks"] as! [[String: Any]]
        let ti = tracks.firstIndex { ($0["clips"] as? [[String: Any]])?.contains { ($0["captionMetadata"] as? [String: Any])?["translationRevision"] != nil } == true }!
        var clips = tracks[ti]["clips"] as! [[String: Any]]; var info = clips[0]["captionMetadata"] as! [String: Any]; var rev = info["translationRevision"] as! [String: Any]
        rev["futureContext"] = "unknown"; info["translationRevision"] = rev; clips[0]["captionMetadata"] = info; tracks[ti]["clips"] = clips; seq["tracks"] = tracks; json["sequence"] = seq
        do { try DocumentCompatibility.validate(JSONSerialization.data(withJSONObject: json)); check("Unknown nested revision field rejected", false) } catch { check("Unknown nested revision field rejected", true) }
        var invalid = translated; let ri = invalid.sequence.tracks.firstIndex { $0.clips.contains { $0.id == ta.id } }!, ci = invalid.sequence.tracks[ri].clips.firstIndex { $0.id == ta.id }!
        invalid.sequence.tracks[ri].clips[ci].captionMetadata?.translationRevision?.sourceDigest = "bad"
        do { try ProjectValidator.validate(invalid); check("Malformed revision digest rejected", false) } catch { check("Malformed revision digest rejected", true) }
        invalid = translated; invalid.sequence.tracks[ri].clips[ci].captionMetadata?.translationRevision?.version = 2
        do { try ProjectValidator.validate(invalid); check("Unsupported revision version rejected", false) } catch { check("Unsupported revision version rejected", true) }
        invalid = translated; invalid.sequence.tracks[ri].clips[ci].captionMetadata?.translationRevision?.sourceCaptionID = UUID()
        do { try ProjectValidator.validate(invalid); check("Conflicting exact source IDs rejected", false) } catch { check("Conflicting exact source IDs rejected", true) }
        var collision = attached; collision.id = UUID(); collision.title?.text = "Same interval different source."
        let collisionTranslation = try CaptionTranslationEditing.translated(collision, text: "별도 원문 번역", sourceLanguage: "en", targetLanguage: "ko", bilingual: false)
        check("Same-parent same-source-range cues remain separate", !CaptionQuery.related(collisionTranslation, to: attached) && !CaptionTranslationEditing.isTranslation(of: attached, collisionTranslation, target: "ko"))
        // Two manual variants for one source: explicit replacement must keep the other variant.
        var manualOne = forSource(current, a.id); manualOne.title?.text = "첫 번째 수동 수정"
        var manualTwo = manualOne; manualTwo.id = UUID(); manualTwo.title?.text = "두 번째 수동 수정"
        var variants = current
        for ti in variants.sequence.tracks.indices { variants.sequence.tracks[ti].clips.removeAll { $0.captionMetadata?.translatedFrom == a.id } }
        variants.sequence.tracks.append(Track(name: "Manual variants", kind: .title, clips: [manualOne, manualTwo]))
        model.history = EditorHistory(project: variants); model.error = nil; goodProvider(); requests = []
        model.regenerateManualTranslation(manualOne.id); try await settle()
        check("Explicit manual replacement preserves another manual variant", model.error == nil && translations(model.project).contains { $0.id == manualTwo.id && $0.title?.text == manualTwo.title?.text } && !translations(model.project).contains { $0.id == manualOne.id } && requests.flatMap { $0 }.map(\.id) == [a.id])
        model.undo(); check("Undo restores both manual variants and their track", model.project == variants)
        model.history = EditorHistory(project: translated); model.error = nil; model.selectClip(ta.id)
        model.setSelectedCaptionRole(.original)
        let converted = model.captionClips.first { $0.id == ta.id }
        check("Role conversion clears translation-only revision atomically", model.error == nil && converted?.captionRole == .original && converted?.captionMetadata?.translatedFrom == nil && converted?.captionMetadata?.translationRevision == nil)
        model.undo(); check("Role conversion Undo restores exact translation revision", model.project == translated)
        invalid = translated; invalid.sequence.tracks[ri].clips[ci].captionRole = .original
        do { try ProjectValidator.validate(invalid); check("Revision on a non-translation role rejected", false) } catch { check("Revision on a non-translation role rejected", true) }
        // Reproduction: source family sibling precedes exact source at the same interval.
        var overlappingSibling = collision; overlappingSibling.lineageID = attached.id
        var collisionProject = connected; collisionProject.sequence.tracks[2].clips = [overlappingSibling, attached, target]
        var collisionHistory = EditorHistory(project: collisionProject)
        try collisionHistory.apply(.duplicate(trackID: connected.sequence.tracks[0].id, clipID: parent.id))
        let duplicatedParent = collisionHistory.project.sequence.tracks[0].clips.last!
        let copiedTarget = translations(collisionHistory.project).first { $0.connection?.parentID == duplicatedParent.id }!
        check("Duplicate exact source ID beats earlier overlapping lineage sibling", CaptionTranslationTracking.source(for: copiedTarget, in: collisionHistory.project.sequence)?.title?.text == attached.title?.text)
        var legacyTarget = target; legacyTarget.captionMetadata?.translationRevision = nil
        collisionProject.sequence.tracks[2].clips = [overlappingSibling, attached, legacyTarget]
        collisionHistory = EditorHistory(project: collisionProject)
        try collisionHistory.apply(.duplicate(trackID: connected.sequence.tracks[0].id, clipID: parent.id))
        let legacyParent = collisionHistory.project.sequence.tracks[0].clips.last!
        let copiedLegacy = translations(collisionHistory.project).first { $0.connection?.parentID == legacyParent.id }!
        check("Legacy duplicate also prefers exact matching source ID", CaptionTranslationTracking.source(for: copiedLegacy, in: collisionHistory.project.sequence)?.title?.text == attached.title?.text)
        let ambiguousFamily = UUID()
        var ambiguousFirst = attached; ambiguousFirst.lineageID = ambiguousFamily
        var ambiguousSecond = overlappingSibling; ambiguousSecond.lineageID = ambiguousFamily
        legacyTarget.captionMetadata?.translatedFrom = ambiguousFamily
        collisionProject.sequence.tracks[2].clips = [ambiguousSecond, ambiguousFirst, legacyTarget]
        collisionHistory = EditorHistory(project: collisionProject)
        do { try collisionHistory.apply(.duplicate(trackID: connected.sequence.tracks[0].id, clipID: parent.id)); check("Ambiguous legacy source duplication rejected atomically", false) }
        catch { check("Ambiguous legacy source duplication rejected atomically", collisionHistory.project == collisionProject && !collisionHistory.canUndo) }
        // Failed status belongs to the attempted inputs, not every future state of that source ID.
        model.history = EditorHistory(project: current); model.error = nil
        editPreservedOriginalThroughInspector(a.id, text: "Fail this specific source revision.")
        model.translationBatchProvider = { _, _, _ in [] }
        model.translateCaptionTracks(scope: .groups([group])); try await settle()
        check("Failure status belongs to attempted source inputs", model.translationFreshness(forSource(model.project, a.id)) == .failed)
        model.undo()
        check("Undo of source edit restores current status after failure", model.project == current && model.translationFreshness(forSource(model.project, a.id)) == .current)
        editPreservedOriginalThroughInspector(a.id, text: "A different edit after the failed attempt.")
        check("A later unattempted source edit shows sourceChanged", model.translationFreshness(forSource(model.project, a.id)) == .sourceChanged)
        // A failed Korean attempt must not label an older Japanese translation as failed.
        var otherTarget = try CaptionTranslationEditing.translated(a, text: "こんにちは。", sourceLanguage: "en", targetLanguage: "ja", bilingual: false)
        otherTarget.captionMetadata?.translationRevision = CaptionTranslationTracking.revision(for: a, language: "en", recipe: CaptionTranslationTracking.recipeDigest(source: "en", target: "ja", glossary: [], style: .natural, bilingual: false))
        var beforeOtherTarget = current; beforeOtherTarget.sequence.tracks.append(Track(name: "Other target", kind: .title, clips: [otherTarget]))
        model.history = EditorHistory(project: beforeOtherTarget); editPreservedOriginalThroughInspector(a.id, text: "Fail this specific source revision.")
        check("Failure in one target cannot mark another target failed", model.translationFreshness(otherTarget) == .sourceChanged)
        let failures = rows.filter { $0["passed"] as? Bool != true }.count
        print("TRANSLATION_FRESHNESS_RESULT checks=\(rows.count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

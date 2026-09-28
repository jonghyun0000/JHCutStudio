import Foundation
import AppKit
import JHCutCore

/// Upgrade 6: translation register and project glossary, measured through the installed Apple translator.
@main struct GlossaryProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Glossary", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], samples: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() {
   try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
   try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("translations.json"))
  }
  defer { save() }

  // ---- Glossary protection (pure) ----
  let minsu = GlossaryEntry(source: "Minsu", target: "민수", sourceLanguage: "en", targetLanguage: "ko")
  let store = GlossaryEntry(source: "Apple Store", protected: true)
  let phone = GlossaryEntry(source: "iPhone", target: "아이폰")
  let p1 = GlossaryProtection.protect("I met Minsu at the Apple Store with my iPhone.", entries: [minsu, store, phone], from: "en", to: "ko")
  check("Terms replaced by markers", p1.terms.count == 3 && !p1.text.contains("Minsu") && !p1.text.contains("Apple Store"), p1.text)
  func marker(_ source: String) -> String { "ZQX\(p1.terms.first { $0.source == source }!.index)" }
  let r1 = GlossaryProtection.restore("나는 \(marker("Apple Store"))에서 \(marker("iPhone"))로 \(marker("Minsu"))를 만났다.", p1, targetLanguage: "ko")
  check("Markers restored with target / original forms", r1.failed.isEmpty && r1.text.contains("민수") && r1.text.contains("Apple Store") && r1.text.contains("아이폰"), r1.text)
  check("Korean particle follows the restored word", r1.text.contains("민수를") && r1.text.contains("아이폰으로"), r1.text)
  let jimin = ProtectedText(text: "ZQX1", terms: [ProtectedTerm(index: 1, source: "Jimin", replacement: "지민")])
  check("Particle 를→을 after a final consonant", GlossaryProtection.restore("ZQX1를 만났다", jimin, targetLanguage: "ko").text == "지민을 만났다")
  check("Word boundary: Mac does not match Machine", GlossaryProtection.protect("Machine and Mac", entries: [GlossaryEntry(source: "Mac", target: "맥")], from: "en", to: "ko").terms.count == 1)
  check("Case rule honoured", GlossaryProtection.protect("apple pie", entries: [GlossaryEntry(source: "Apple", target: "애플", caseSensitive: true)], from: "en", to: "ko").terms.isEmpty
        && GlossaryProtection.protect("apple pie", entries: [GlossaryEntry(source: "Apple", target: "애플")], from: "en", to: "ko").terms.count == 1)
  check("Language scope honoured", GlossaryProtection.protect("Minsu", entries: [minsu], from: "ja", to: "ko").terms.isEmpty)
  let lost = GlossaryProtection.restore("나는 민수를 만났다.", p1, targetLanguage: "ko")
  check("Lost markers reported, never assumed", lost.failed.count == 3 && lost.applied.isEmpty)
  check("Marker-only sentence skips the translator", GlossaryProtection.protect("iPhone!", entries: [phone], from: "en", to: "ko").isOnlyTerms)

  // ---- Register conversion (pure) ----
  let S = TranslationStyleConverter.self
  check("합쇼체→해요체", S.apply(.polite, to: "오늘 촬영했습니다. 날씨가 좋습니다. 내일 갑니다. 그는 학생입니다. 이것은 사과입니다.", language: "ko").text == "오늘 촬영했어요. 날씨가 좋아요. 내일 가요. 그는 학생이에요. 이것은 사과예요.",
        S.apply(.polite, to: "오늘 촬영했습니다. 날씨가 좋습니다. 내일 갑니다. 그는 학생입니다. 이것은 사과입니다.", language: "ko").text)
  check("해요체→방송체", S.apply(.formal, to: "밥을 먹어요. 운동을 해요. 공원에 가요. 사과예요.", language: "ko").text == "밥을 먹습니다. 운동을 합니다. 공원에 갑니다. 사과입니다.",
        S.apply(.formal, to: "밥을 먹어요. 운동을 해요. 공원에 가요. 사과예요.", language: "ko").text)
  check("해요체→반말", S.apply(.casual, to: "촬영했어요. 학생이에요. 좋죠?", language: "ko").text == "촬영했어. 학생이야. 좋지?", S.apply(.casual, to: "촬영했어요. 학생이에요. 좋죠?", language: "ko").text)
  check("방송체→반말 via 해요체", S.apply(.casual, to: "영상을 찍고 있습니다.", language: "ko").text == "영상을 찍고 있어.")
  let hot = S.apply(.polite, to: "오늘은 덥습니다.", language: "ko")
  check("Irregular stem left as translated and reported", hot.text == "오늘은 덥습니다." && hot.unsupported == 1 && hot.applied == false)
  check("ㄹ-stem exception", S.apply(.polite, to: "저는 그 사람을 압니다.", language: "ko").text == "저는 그 사람을 알아요.")
  check("English has no register", S.apply(.formal, to: "Hello there.", language: "en").applied == nil)
  check("Japanese です・ます → plain", S.apply(.casual, to: "今日は晴れです。公園で撮影しています。", language: "ja").text == "今日は晴れだ。公園で撮影している。", S.apply(.casual, to: "今日は晴れです。公園で撮影しています。", language: "ja").text)
  check("Japanese plain → です・ます", S.apply(.polite, to: "静かだ。", language: "ja").text == "静かです。")

  // ---- Editor integration with the real translator ----
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  var project = Project(name: "용어집"); project.sequence.width = 1280; project.sequence.height = 720
  let lines: [(String, String)] = [("en", "I met Minsu at the Apple Store today."), ("en", "The new iPhone is really fast."), ("en", "We will film again tomorrow."),
                                   ("en", "Minsu bought a case for his iPhone."), ("ja", "今日はミンスさんと公園で撮影しました。"), ("ja", "明日も撮影します。")]
  let ti = project.sequence.tracks.firstIndex { $0.kind == .title }!
  for (i, (language, text)) in lines.enumerated() {
   var clip = Clip(name: "자막", start: MediaTime(seconds: Double(i) * 3), duration: MediaTime(seconds: 2.5), title: Title(text: text))
   clip.captionMetadata = CaptionMetadata(language: language, originalLanguage: language, originalText: text, generatedText: text)
   project.sequence.tracks[ti].clips.append(clip)
  }
  model.history = EditorHistory(project: project)
  let before = model.project
  model.addGlossaryEntry(minsu); model.addGlossaryEntry(store); model.addGlossaryEntry(phone)
  model.addGlossaryEntry(GlossaryEntry(source: "ミンス", target: "민수", sourceLanguage: "ja", targetLanguage: "ko"))
  check("Glossary stored on the project", model.glossaryEntries.count == 4)
  model.undo(); check("Undo removes the last entry", model.glossaryEntries.count == 3)
  model.redo(); check("Redo restores it", model.glossaryEntries.count == 4)
  _ = before

  func translate(_ style: TranslationStyle) async throws -> [Clip] {
   model.translationTargetLanguage = "ko"; model.translationStyle = style.rawValue; model.error = nil
   model.translateCaptionTracks(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
   let result = model.captionClips.filter { $0.captionMetadata?.translatedFrom != nil && $0.captionMetadata?.language == "ko" }
   for clip in result { samples.append(["style": style.rawValue, "source": clip.captionMetadata?.originalText ?? "", "translation": clip.title?.text ?? "",
                                        "styleApplied": clip.captionMetadata?.styleApplied.map { $0 ? "yes" : "no" } ?? "n/a",
                                        "glossaryApplied": clip.captionMetadata?.glossaryApplied ?? [], "glossaryFailed": clip.captionMetadata?.glossaryFailed ?? []]) }
   print("  [\(style.label)] " + result.map { $0.title?.text ?? "" }.joined(separator: " | "))
   print("  " + model.message)
   return result
  }
  let formal = try await translate(.formal)
  check("Real translation completed", model.error == nil && formal.count == lines.count, model.error ?? model.message)
  let allText = formal.map { $0.title?.text ?? "" }.joined(separator: " ")
  check("Fixed translation used (Minsu/ミンス → 민수)", formal.filter { ($0.captionMetadata?.originalText ?? "").contains("Minsu") || ($0.captionMetadata?.originalText ?? "").contains("ミンス") }.allSatisfy { ($0.title?.text ?? "").contains("민수") }, allText)
  check("Protected brand kept verbatim", formal.first { ($0.captionMetadata?.originalText ?? "").contains("Apple Store") }?.title?.text.contains("Apple Store") == true)
  check("Glossary use recorded per caption", formal.filter { $0.captionMetadata?.glossaryApplied != nil }.count == 4 && model.message.contains("용어집 적용"))
  check("No marker leaked into captions", !allText.contains("ZQX"))
  let formalOK = formal.filter { $0.captionMetadata?.styleApplied == true }
  check("Style recorded and verified where claimed", formal.allSatisfy { $0.captionMetadata?.translationStyle == "formal" } &&
        formalOK.allSatisfy { clip in TranslationStyleConverter.sentences(clip.title?.text ?? "").allSatisfy { let r = TranslationStyleConverter.koreanRegister($0); return r == nil || r == .formal } },
        "방송체 적용 \(formalOK.count)/\(formal.count)")

  let casual = try await translate(.casual)
  let casualOK = casual.filter { $0.captionMetadata?.styleApplied == true }
  check("Retranslation replaces generated captions with the new register", casual.allSatisfy { $0.captionMetadata?.translationStyle == "casual" } &&
        casualOK.allSatisfy { clip in TranslationStyleConverter.sentences(clip.title?.text ?? "").allSatisfy { let r = TranslationStyleConverter.koreanRegister($0); return r == nil || r == .casual } },
        "반말 적용 \(casualOK.count)/\(casual.count)")

  // User-edited translation survives retranslation.
  guard var edited = casual.first, let track = model.project.sequence.tracks.first(where: { $0.clips.contains { $0.id == edited.id } }) else { check("Edit target", false); return }
  edited.title?.text = "직접 고친 번역입니다"
  model.perform(.updateClip(trackID: track.id, clip: edited))
  let polite = try await translate(.polite)
  check("Hand-edited translation preserved on retranslation", polite.contains { $0.title?.text == "직접 고친 번역입니다" } && model.message.contains("직접 고친 번역 1개 보존"))
  let generated = polite.filter { $0.title?.text == $0.captionMetadata?.generatedText }
  let politeOK = generated.filter { $0.captionMetadata?.styleApplied == true }
  check("존댓말 verified where claimed", generated.allSatisfy { $0.captionMetadata?.translationStyle == "polite" } &&
        politeOK.allSatisfy { clip in TranslationStyleConverter.sentences(clip.title?.text ?? "").allSatisfy { let r = TranslationStyleConverter.koreanRegister($0); return r == nil || r == .polite } },
        "존댓말 적용 \(politeOK.count)/\(generated.count)")

  // Save / reopen
  let url = root.appendingPathComponent("Glossary.jhcut")
  try ProjectStore.save(model.project, to: url)
  let reopened = try ProjectStore.load(from: url)
  check("Save/reopen keeps glossary and translation metadata", reopened.glossary == model.project.glossary && reopened.sequence == model.project.sequence)

  // Translator that drops markers → honest failure + plain translation fallback.
  model.showOriginalCaptionTracks()
  let realProvider = model.translationProvider
  model.translationProvider = { texts, s, t in
   try await realProvider(texts.map { $0.replacingOccurrences(of: "ZQX1", with: "") }, s, t)
  }
  let dropped = try await translate(.natural)
  let failedClips = dropped.filter { $0.captionMetadata?.glossaryFailed != nil }
  check("Dropped marker marked as glossary failure", !failedClips.isEmpty && model.message.contains("적용 실패"), model.message)
  check("Failed sentence falls back to a full plain translation", failedClips.allSatisfy { !($0.title?.text ?? "").contains("ZQX") && !($0.title?.text ?? "").isEmpty })
  model.translationProvider = realProvider

  // English target: register does not apply.
  model.showOriginalCaptionTracks()
  model.translationTargetLanguage = "en"; model.translationStyle = TranslationStyle.formal.rawValue
  model.translateCaptionTracks(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  check("English target reports style not applicable", model.error == nil && model.message.contains("존댓말 구분이 없어"), model.error ?? model.message)
  let enProtected = model.captionClips.first { $0.captionMetadata?.language == "en" && $0.captionMetadata?.translatedFrom != nil && ($0.captionMetadata?.originalText ?? "").contains("ミンス") }
  check("ja→en keeps ko-only entry out of scope", enProtected.map { !($0.title?.text ?? "").contains("민수") } ?? false, enProtected?.title?.text ?? "")

  // Quick glossary text → project glossary
  model.translationGlossaryText = "Tokyo=도쿄\nMinsu=민수"
  model.importQuickGlossary()
  check("Quick lines imported in one undo step", model.glossaryEntries.contains { $0.source == "Tokyo" } && model.translationGlossaryText.isEmpty)
  model.undo(); check("Undo of import", !model.glossaryEntries.contains { $0.source == "Tokyo" })

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("GLOSSARY_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }
}

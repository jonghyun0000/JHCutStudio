import Foundation
import AppKit
import JHCutCore

/// Upgrade 3: sentence-level language detection, manual override, per-sentence translation groups.
@main struct LanguageProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Language", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  defer { save() }

  // ---- Detector ----
  let d = SentenceLanguage.detect
  check("Korean sentence with an English brand stays Korean", d("오늘 iPhone으로 영상을 찍었어요", "en").language == "ko")
  check("Japanese kana sentence", d("今日は公園で撮影しています", "ko").language == "ja")
  check("English sentence", d("We are filming in the park today.", "ko").language == "en" && !d("We are filming in the park today.", "ko").needsReview)
  let short = d("OK", "ko")
  check("Too-short text keeps clip language and asks for review", short.language == "ko" && short.needsReview && short.confidence == 0)
  let han = d("東京駅", "ko")
  check("Han-only text is not trusted", han.needsReview && han.language == "ko", "\(han)")
  check("Confidence is recorded for detected sentences", d("안녕하세요 반갑습니다", "ja").confidence > 0.6)

  // ---- Mixed-language speech in ONE clip ----
  let lines: [(String, String, String)] = [("ko", "Yuna", "안녕하세요. 오늘은 공원에서 영상을 촬영하고 있습니다."),
                                           ("en", "Samantha", "Hello everyone, welcome to our channel."),
                                           ("ja", "Kyoko", "こんにちは。今日はいい天気ですね。"),
                                           ("ko", "Yuna", "다음에는 카페에서 차를 마시겠습니다.")]
  let media = try await mixedSpeech(root, lines)
  let asset = try await MediaImporter.inspect(url: media)
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.translateAfterTranscription = false; model.useSpeechCheckpoints = false
  var project = Project(name: "한 클립 다국어"); project.sequence.width = 640; project.sequence.height = 360
  let clip = Clip(name: "섞인 대사", assetID: asset.id, duration: asset.duration)
  project.assets = [asset]; project.sequence.tracks[0].clips = [clip]
  model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.refreshTranscriptionStatus()
  model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  let originals = model.captionClips.filter { $0.captionMetadata?.translatedFrom == nil }
  let languages = originals.map { $0.captionMetadata?.language ?? "?" }
  let texts = originals.map { "[\($0.captionMetadata?.language ?? "?") \(String(format: "%.2f", $0.captionMetadata?.languageConfidence ?? -1))] \($0.title?.text ?? "")" }
  check("Mixed clip captioned", !originals.isEmpty && model.error == nil, texts.joined(separator: " | "))
  let clipLanguages = Set(originals.compactMap { $0.captionMetadata?.clipLanguage })
  check("Clip language recorded separately from sentence language", clipLanguages.count == 1, "clip: \(clipLanguages)")
  check("Sentence languages differ within one clip", Set(languages).count >= 2, "\(languages)")
  check("Every sentence language matches its own script", originals.allSatisfy { cue in
   let s = SentenceLanguage.scripts(cue.title?.text ?? ""), lang = cue.captionMetadata?.language
   if cue.captionMetadata?.languageNeedsReview == true { return true }
   if s.hangul > s.letters / 2 { return lang == "ko" }
   if s.kana > 0 { return lang == "ja" }
   if s.latin > s.letters * 8 / 10 { return lang == "en" }
   return true
  })
  let captioned = model.project

  // ---- Manual override ----
  guard let target = originals.first(where: { $0.captionMetadata?.language == "ko" }) ?? originals.first else { check("Sentence available for override", false); return }
  model.setCaptionLanguage([target.id], to: "en")
  let overridden = model.captionClips.first { $0.id == target.id }?.captionMetadata
  check("Manual language stored with flag, confidence cleared", overridden?.language == "en" && overridden?.languageManual == true && overridden?.languageConfidence == nil)
  let url = root.appendingPathComponent("Language.jhcut")
  try ProjectStore.save(model.project, to: url)
  let reopened = try ProjectStore.load(from: url)
  check("Save/reopen keeps manual language and confidence metadata", reopened.sequence == model.project.sequence)
  model.undo(); check("One undo restores detected language", model.project == captioned)
  model.redo(); check("Redo reapplies manual language", model.captionClips.first { $0.id == target.id }?.captionMetadata?.languageManual == true)

  // Re-recognition with replacement must keep the hand-set sentence.
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  let kept = model.captionClips.filter { $0.captionMetadata?.languageManual == true }
  check("Re-recognition preserves hand-set language", kept.count == 1 && kept.first?.captionMetadata?.language == "en" && kept.first?.title?.text == target.title?.text)
  check("Re-recognition does not duplicate the preserved sentence", model.captionClips.filter { $0.captionMetadata?.translatedFrom == nil && $0.start < target.end && $0.end > target.start }.count == 1)

  // ---- Per-sentence translation groups with the real translator ----
  model.translationTargetLanguage = "ko"
  model.translateCaptionTracks(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  let translations = model.captionClips.filter { $0.captionMetadata?.translatedFrom != nil }
  let sources = Set(translations.compactMap { $0.captionMetadata?.originalLanguage })
  check("Translation grouped by each sentence's language", model.error == nil && sources.count >= 2 && model.message.contains("문장별 원문 언어"), model.error ?? model.message)
  check("Hand-set sentence translated from its chosen language", translations.first { $0.captionMetadata?.translatedFrom == kept.first?.id }?.captionMetadata?.originalLanguage == "en")
  check("Korean sentences are carried over, not re-translated", translations.filter { $0.captionMetadata?.originalLanguage == "ko" }.allSatisfy { t in t.title?.text == t.captionMetadata?.originalText })

  // ---- Reset to automatic ----
  model.showOriginalCaptionTracks()
  model.resetCaptionLanguage([kept.first!.id])
  let reset = model.captionClips.first { $0.id == kept.first!.id }?.captionMetadata
  check("Reset clears manual flag and re-detects", reset?.languageManual == nil && reset?.languageConfidence != nil)

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("LANGUAGE_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }

 static func mixedSpeech(_ root: URL, _ lines: [(String, String, String)]) async throws -> URL {
  let output = root.appendingPathComponent("mixed-ko-en-ja.mp4")
  if FileManager.default.fileExists(atPath: output.path) { return output }
  var p = Project(name: "mixed"); p.sequence.width = 640; p.sequence.height = 360
  let ti = p.sequence.tracks.firstIndex { $0.kind == .audio }!
  var at = MediaTime(seconds: 0.3)
  for (i, (_, voice, text)) in lines.enumerated() {
   let audio = root.appendingPathComponent("mixed-\(i).aiff")
   let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say"); say.arguments = ["-v", voice, "-r", "160", "-o", audio.path, text]
   try say.run(); say.waitUntilExit()
   let a = try await MediaImporter.inspect(url: audio); p.assets.append(a)
   p.sequence.tracks[ti].clips.append(Clip(assetID: a.id, start: at, duration: a.duration)); at = at + a.duration + MediaTime(seconds: 1)
  }
  try await ExportJob().export(plan: TimelineRenderer.build(project: p), to: output) { _ in }
  return output
 }
}

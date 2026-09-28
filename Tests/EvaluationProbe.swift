import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Upgrade 2: transcript-based accuracy evaluation. Pure metric checks, then real Whisper captions
/// scored against the exact text and placement of synthetic speech. Values reported here are for
/// Mac system voices, not real-world recordings.
@main struct EvaluationProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Evaluation", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") {
   rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
  }
  func save() { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  defer { save() }

  // ---- Normalisation and metrics ----
  typealias E = TranscriptEvaluation
  check("Korean normalisation drops punctuation and full-width forms", E.normalized("안녕하세요, ＡＢＣ！", language: "ko") == "안녕하세요 abc")
  check("Korean CER ignores spacing", E.characters("안녕 하세요", language: "ko") == E.characters("안녕하세요", language: "ko"))
  let cer = E.editCounts(reference: E.characters("안녕하세요", language: "ko"), hypothesis: E.characters("안녕하새요", language: "ko"))
  check("One substitution in five characters is CER 20%", cer.substitutions == 1 && cer.deletions == 0 && cer.insertions == 0 && abs((cer.errorRate ?? 0) - 0.2) < 1e-9)
  let wer = E.editCounts(reference: E.words("The cat sat on the mat.", language: "en"), hypothesis: E.words("the cat sit on mat", language: "en"))
  check("English WER counts substitution and deletion", wer.substitutions == 1 && wer.deletions == 1 && wer.insertions == 0 && abs((wer.errorRate ?? 0) - 2.0 / 6.0) < 1e-9, "\(wer)")
  let ins = E.editCounts(reference: Array("abc"), hypothesis: Array("abxc"))
  check("Insertion counted separately", ins.insertions == 1 && ins.substitutions == 0 && ins.deletions == 0)
  let jaTokens = E.words("今日は公園で動画を撮影しています。", language: "ja")
  check("Japanese words come from a tokenizer, not spaces", jaTokens.count >= 4, jaTokens.joined(separator: "|"))
  check("Identical Japanese text scores zero WER", E.editCounts(reference: jaTokens, hypothesis: E.words("今日は公園で動画を撮影しています", language: "ja")).errorRate == 0)
  check("English normalisation is case-insensitive", E.words("HELLO World", language: "en") == ["hello", "world"])
  check("Empty reference has no error rate", E.editCounts(reference: [Character](), hypothesis: Array("x")).errorRate == nil)

  // ---- Sentence alignment ----
  let reference = TranscriptReference(url: root.appendingPathComponent("r.srt"), units: [
   .init(text: "오늘은 공원에서 영상을 찍습니다.", start: 0, end: 3),
   .init(text: "날씨가 정말 좋습니다.", start: 3.5, end: 5.5),
   .init(text: "카페에서 차를 마십니다.", start: 6, end: 8)])
  let split = [EvaluatedCaption(text: "오늘은 공원에서", start: 0.1, end: 1.5), EvaluatedCaption(text: "영상을 찍습니다.", start: 1.5, end: 3.1),
               EvaluatedCaption(text: "날씨가 정말 좋습니다.", start: 3.6, end: 5.4), EvaluatedCaption(text: "카페에서 차를 마십니다.", start: 6.2, end: 8.0)]
  let splitReport = E.evaluate(captions: split, reference: reference, language: "ko", sourceRange: 0...8, mediaDuration: 8)
  check("Sentence split across two captions is not missing+extra", splitReport.missing.isEmpty && splitReport.extra.isEmpty && splitReport.matchedSentences == 3, "\(splitReport.matchedSentences) matched")
  check("Perfect text scores CER 0", splitReport.cer == 0)
  check("Timing error measured from .srt", splitReport.timing != nil && abs((splitReport.timing?.maxAbsoluteStart ?? 1) - 0.2) < 1e-9, "\(String(describing: splitReport.timing))")
  let gaps = [EvaluatedCaption(text: "오늘은 공원에서 영상을 찍습니다.", start: 0, end: 3), EvaluatedCaption(text: "고양이가 노래를 부릅니다 크게.", start: 9, end: 10)]
  let gapReport = E.evaluate(captions: gaps, reference: reference, language: "ko", sourceRange: 0...10, mediaDuration: 10)
  check("Missing and extra sentences detected", gapReport.missing.count == 2 && gapReport.extra.count == 1, "missing \(gapReport.missing.map(\.text)) extra \(gapReport.extra.map(\.text))")

  // ---- “평가 불가” paths ----
  let none = E.evaluate(captions: split, reference: nil, language: "ko", sourceRange: 0...8, mediaDuration: 8)
  check("No transcript: unscored and no numbers", none.status == .unscored && none.cer == nil && none.wer == nil && none.timing == nil && (none.reason ?? "").contains("대본 없음"))
  check("Unscored report text says 평가 불가 and shows no CER value", E.markdown(none, title: "x").contains("평가 불가") && !E.markdown(none, title: "x").contains("| CER |"))
  let plain = TranscriptReference(url: root.appendingPathComponent("r.txt"), units: reference.units.map { .init(text: $0.text, start: nil, end: nil) })
  let partialPlain = E.evaluate(captions: split, reference: plain, language: "ko", sourceRange: 3...8, mediaDuration: 8)
  check("Untimed transcript refused for a partial clip", partialPlain.status == .unscored && partialPlain.cer == nil, partialPlain.reason ?? "")
  let fullPlain = E.evaluate(captions: split, reference: plain, language: "ko", sourceRange: 0...8, mediaDuration: 8)
  check("Untimed transcript scores a full clip without timing", fullPlain.status == .scored && fullPlain.timing == nil && fullPlain.cer == 0)
  let partialTimed = E.evaluate(captions: Array(split.dropFirst(2)), reference: reference, language: "ko", sourceRange: 3.2...8, mediaDuration: 8)
  check("Timed transcript is restricted to the clip's source range", partialTimed.status == .scored && partialTimed.referenceSentences == 2 && partialTimed.missing.isEmpty)
  check("Plain-text sentence splitting", E.sentences("첫 문장입니다. 두 번째!\n세 번째") == ["첫 문장입니다.", "두 번째!", "세 번째"])

  // ---- Real recognition against known synthetic speech ----
  let voices = ["ko": ("Yuna", ["안녕하세요. 오늘은 공원에서 영상을 촬영합니다.", "날씨가 좋아서 친구와 함께 산책을 합니다.", "잠시 후에는 카페에서 따뜻한 차를 마실 예정입니다.", "저녁에는 촬영한 영상을 정리하겠습니다."]),
                "ja": ("Kyoko", ["こんにちは。今日は公園で動画を撮影しています。", "天気が良いので友達と散歩をしています。", "このあとカフェで温かいお茶を飲む予定です。"]),
                "en": ("Samantha", ["Hello everyone, today we are filming in the park.", "The weather is beautiful, so I am taking a walk with my friend.", "Later we will visit a cafe and have a cup of warm tea."])]
  var metrics: [[String: Any]] = []
  for language in ["ko", "ja", "en"] {
   let (voice, lines) = voices[language]!
   let (media, srt, txt) = try await makeTimedSpeech(root, language: language, voice: voice, lines: lines)
   let asset = try await MediaImporter.inspect(url: media)
   let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery-" + language)), exportHistoryURL: root.appendingPathComponent("journal.json"))
   model.reportsDirectory = root.appendingPathComponent("Reports", isDirectory: true)
   model.translateAfterTranscription = false; model.useSpeechCheckpoints = false
   var project = Project(name: "평가 \(language)"); project.sequence.width = 640; project.sequence.height = 360
   let clip = Clip(name: "\(language) 대사", assetID: asset.id, duration: asset.duration)
   project.assets = [asset]; project.sequence.tracks[0].clips = [clip]
   model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
   model.refreshTranscriptionStatus()
   model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
   check("\(language): real captions generated", model.error == nil && !model.captionClips.isEmpty, model.message)
   model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
   // Beside-media lookup prefers .srt; the fixture folder holds both.
   model.evaluateSelectedCaptions(); while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
   guard let report = model.lastEvaluation else { check("\(language): evaluation produced", false); continue }
   check("\(language): timed transcript scored", report.status == .scored && report.referenceTimed && report.cer != nil && report.wer != nil, EditorModel.summary(report))
   check("\(language): CER is a finite rate", (report.cer ?? -1) >= 0 && (report.cer ?? .infinity).isFinite)
   check("\(language): timing error measured", report.timing != nil)
   check("\(language): report files written", model.lastEvaluationReportURL.map { FileManager.default.fileExists(atPath: $0.path) && FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("json").path) } ?? false)
   check("\(language): nothing written beside the media", Set((try? FileManager.default.contentsOfDirectory(atPath: media.deletingLastPathComponent().path)) ?? []).isSubset(of: [media.lastPathComponent, srt.lastPathComponent, txt.lastPathComponent] + ((try? FileManager.default.contentsOfDirectory(atPath: media.deletingLastPathComponent().path)) ?? []).filter { $0.hasSuffix(".aiff") }))
   model.evaluateSelectedCaptions(referenceURL: txt); while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
   check("\(language): plain .txt scores full clip without timing", model.lastEvaluation?.status == .scored && model.lastEvaluation?.timing == nil)
   metrics.append(["language": language, "voice": voice, "cer": report.cer ?? NSNull(), "wer": report.wer ?? NSNull(), "wordUnit": report.wordUnit ?? "",
                   "referenceSentences": report.referenceSentences, "captionSentences": report.captionSentences, "missing": report.missing.count, "extra": report.extra.count,
                   "medianStartError": report.timing?.medianAbsoluteStart ?? NSNull(), "maxStartError": report.timing?.maxAbsoluteStart ?? NSNull()])
  }
  try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("synthetic-speech-metrics.json"))

  // Editor without any transcript: 평가 불가 and no number.
  let bare = root.appendingPathComponent("Bare", isDirectory: true)
  try? FileManager.default.removeItem(at: bare); try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
  let (koMedia, _, _) = try await makeTimedSpeech(root, language: "ko", voice: "Yuna", lines: voices["ko"]!.1)
  let lone = bare.appendingPathComponent("no-transcript.mp4"); try FileManager.default.copyItem(at: koMedia, to: lone)
  let loneAsset = try await MediaImporter.inspect(url: lone)
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery-bare")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.reportsDirectory = root.appendingPathComponent("Reports", isDirectory: true); model.translateAfterTranscription = false; model.useSpeechCheckpoints = false
  var p = Project(name: "대본 없음"); p.sequence.width = 640; p.sequence.height = 360
  let c = Clip(name: "대본 없는 대사", assetID: loneAsset.id, duration: loneAsset.duration); p.assets = [loneAsset]; p.sequence.tracks[0].clips = [c]
  model.history = EditorHistory(project: p); model.selectedClipID = c.id; model.selectedClipIDs = [c.id]; model.refreshTranscriptionStatus()
  model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  model.selectedClipID = c.id; model.selectedClipIDs = [c.id]
  model.evaluateSelectedCaptions(); while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Editor without transcript reports 평가 불가", model.lastEvaluation?.status == .unscored && model.lastEvaluation?.cer == nil && model.message.contains("평가 불가"), model.message)
  check("Evaluation does not change the document", model.project.sequence.tracks.flatMap(\.clips).allSatisfy { $0.captionMetadata != nil || $0.title == nil })

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("EVALUATION_RESULT checks=\(rows.count) failures=\(failures)")
  save()
  if failures > 0 { exit(1) }
 }

 /// Speaks each line separately, places them at known offsets, and writes the exact placement as
 /// the reference `.srt` (plus a `.txt`). Reference times are the clip placement of each line;
 /// the voices' own leading/trailing silence is inside those spans.
 static func makeTimedSpeech(_ root: URL, language: String, voice: String, lines: [String]) async throws -> (URL, URL, URL) {
  let folder = root.appendingPathComponent("Speech-" + language, isDirectory: true)
  let media = folder.appendingPathComponent("\(language)-timed.mp4"), srt = folder.appendingPathComponent("\(language)-timed.srt"), txt = folder.appendingPathComponent("\(language)-timed.txt")
  if FileManager.default.fileExists(atPath: media.path), FileManager.default.fileExists(atPath: srt.path) { return (media, srt, txt) }
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  var project = Project(name: "timed \(language)"); project.sequence.width = 640; project.sequence.height = 360
  let ti = project.sequence.tracks.firstIndex { $0.kind == .audio }!
  var at = MediaTime(seconds: 0.5); var cues: [CaptionCue] = []
  for (index, line) in lines.enumerated() {
   let audio = folder.appendingPathComponent("line-\(index).aiff")
   let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say"); say.arguments = ["-v", voice, "-r", "160", "-o", audio.path, line]
   try say.run(); say.waitUntilExit(); guard say.terminationStatus == 0 else { throw ProjectError("say failed") }
   let asset = try await MediaImporter.inspect(url: audio)
   project.assets.append(asset)
   project.sequence.tracks[ti].clips.append(Clip(assetID: asset.id, start: at, duration: asset.duration))
   cues.append(CaptionCue(start: at, duration: asset.duration, text: line))
   at = at + asset.duration + MediaTime(seconds: 0.8)
  }
  try await ExportJob().export(plan: TimelineRenderer.build(project: project), to: media) { _ in }
  try SRTCodec.serialize(cues).write(to: srt, atomically: true, encoding: .utf8)
  try lines.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
  return (media, srt, txt)
 }
}

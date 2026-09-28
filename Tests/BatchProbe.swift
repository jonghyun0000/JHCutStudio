import Foundation
import AppKit
import JHCutCore

/// Upgrade 5: caption batch editing.
@main struct BatchProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Batch", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  defer { save() }

  let source = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/Evaluation/Speech-ko/ko-timed.mp4").standardizedFileURL
  let asset = try await MediaImporter.inspect(url: source)
  var p = Project(name: "일괄 편집"); p.sequence.width = 1080; p.sequence.height = 1920; p.assets = [asset]
  let parent = Clip(name: "영상", assetID: asset.id, start: .zero, duration: asset.duration)
  p.sequence.tracks[0].clips = [parent]
  func caption(_ text: String, _ start: Double, _ length: Double) -> Clip {
   var c = Clip(name: "자막", start: MediaTime(seconds: start), duration: MediaTime(seconds: length), title: Title(text: text, fontSize: 70, x: 0.5, y: 0.2, style: TextStyle()))
   c.connection = ClipConnection(parentID: parent.id, sourceStart: MediaTime(seconds: start), sourceDuration: MediaTime(seconds: length), generatedText: text)
   c.captionMetadata = CaptionMetadata(language: "ko", originalLanguage: "ko", originalText: text, generatedText: text); return c
  }
  let a = caption("첫 번째 자막입니다", 1, 2), b = caption("두 번째 자막입니다", 4, 2), c = caption("세 번째 자막", 7, 2)
  p.sequence.tracks[2].clips = [a, b, c]
  var hiddenClip = caption("숨긴 번역 자막", 1, 2); hiddenClip.captionMetadata?.translatedFrom = a.id
  p.sequence.tracks.append(Track(name: "번역 · 숨김", kind: .title, clips: [hiddenClip], isHidden: true))
  p.sequence.tracks.append(Track(name: "잠금", kind: .title, clips: [caption("잠긴 자막", 10, 1.5)], isLocked: true))
  let lockedID = p.sequence.tracks.last!.clips[0].id
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.history = EditorHistory(project: p)
  model.selectedClipIDs = [a.id, b.id, hiddenClip.id, lockedID]; model.selectedClipID = a.id
  let original = model.project

  var style = CaptionBatchChange(); style.fontSize = 60; style.colorHex = "#ffe55b"; style.strokeHex = "142236"; style.strokeWidth = 4; style.backgroundOpacity = 0.6; style.maxLines = 2; style.y = 0.15
  check("Batch style applied", model.applyCaptionBatch(style, fitSafeArea: false), model.message)
  let captions = model.project.sequence.tracks.flatMap(\.clips)
  func find(_ id: UUID) -> Clip { captions.first { $0.id == id }! }
  check("Selected visible captions changed", [a.id, b.id].allSatisfy { let t = find($0).title!; return t.fontSize == 60 && t.colorHex == "FFE55B" && t.style?.strokeWidth == 4 && t.style?.maxLines == 2 && t.y == 0.15 && t.style?.backgroundOpacity == 0.6 })
  check("Unselected caption untouched", find(c.id) == c)
  check("Hidden translation not changed even though selected", find(hiddenClip.id) == hiddenClip)
  check("Locked-track caption not changed", find(lockedID) == original.sequence.tracks.last!.clips[0])
  check("Message reports excluded hidden/locked captions", model.message.contains("제외"), model.message)
  model.undo(); check("One undo reverts the whole batch", model.project == original)
  model.redo(); check("Redo reapplies", model.project != original)
  model.undo()

  // Timing: both edges later by 0.5 s. Connected captions update their attached source range.
  var timing = CaptionBatchChange(); timing.startOffset = MediaTime(seconds: 0.5); timing.endOffset = MediaTime(seconds: 0.5)
  model.selectedClipIDs = [a.id, b.id]
  check("Batch time shift applied", model.applyCaptionBatch(timing, fitSafeArea: false), model.message)
  let shiftedA = model.project.sequence.tracks.flatMap(\.clips).first { $0.id == a.id }!
  check("Start and end both moved", abs(shiftedA.start.seconds - 1.5) < 1e-9 && abs(shiftedA.end.seconds - 3.5) < 1e-9)
  check("Connection follows the moved caption", abs((shiftedA.connection?.sourceStart.seconds ?? 0) - 1.5) < 1e-9 && shiftedA.connection?.parentID == parent.id)
  var end = CaptionBatchChange(); end.endOffset = MediaTime(seconds: -0.5)
  model.applyCaptionBatch(end, fitSafeArea: false)
  let trimmed = model.project.sequence.tracks.flatMap(\.clips).first { $0.id == a.id }!
  check("End-only change keeps start", abs(trimmed.start.seconds - 1.5) < 1e-9 && abs(trimmed.duration.seconds - 1.5) < 1e-9)
  let beforeBad = model.project
  var early = CaptionBatchChange(); early.startOffset = MediaTime(seconds: -5)
  model.error = nil
  check("Start before zero refused, document unchanged", !model.applyCaptionBatch(early, fitSafeArea: false) && model.project == beforeBad && model.error != nil, model.error ?? "")
  var past = CaptionBatchChange(); past.startOffset = MediaTime(seconds: 30); past.endOffset = MediaTime(seconds: 30)
  model.error = nil
  check("Move outside the parent clip refused, document unchanged", !model.applyCaptionBatch(past, fitSafeArea: false) && model.project == beforeBad, model.error ?? "")
  var tooShort = CaptionBatchChange(); tooShort.endOffset = MediaTime(seconds: -1.45)
  check("Result shorter than 0.1 s refused", !model.applyCaptionBatch(tooShort, fitSafeArea: false) && model.project == beforeBad)

  // Safe-area fit, verified on the rasterised pixels the export uses.
  var big = CaptionBatchChange(); big.fontSize = 180; big.y = 0.01
  model.selectedClipIDs = [c.id]
  model.applyCaptionBatch(big, fitSafeArea: false)
  let bigTitle = model.project.sequence.tracks.flatMap(\.clips).first { $0.id == c.id }!.title!
  check("Oversized caption starts outside the safe area", !(try CaptionLayout.isInsideSafeArea(bigTitle, width: 1080, height: 1920)))
  model.applyCaptionBatch(CaptionBatchChange(), fitSafeArea: true)
  let fittedTitle = model.project.sequence.tracks.flatMap(\.clips).first { $0.id == c.id }!.title!
  let box = try CaptionLayout.bounds(of: fittedTitle, width: 1080, height: 1920)
  check("Fit moves/shrinks it inside the 80% safe area", try CaptionLayout.isInsideSafeArea(fittedTitle, width: 1080, height: 1920), "font \(fittedTitle.fontSize) y \(fittedTitle.y) box \(String(describing: box))")
  check("Fit keeps the text", fittedTitle.text == bigTitle.text)
  var essay = Title(text: String(repeating: "아주 긴 자막 문장을 계속 이어서 씁니다 ", count: 40), fontSize: 90, x: 0.5, y: 0.5, style: TextStyle())
  essay.style?.maxLines = 0
  check("Caption that cannot fit at minimum size is reported, not clipped", try CaptionLayout.fitted(essay, width: 1080, height: 1920, minimumFontSize: 60) == nil)

  let url = root.appendingPathComponent("Batch.jhcut"); try ProjectStore.save(model.project, to: url)
  check("Save/reopen keeps batch edits", try ProjectStore.load(from: url).sequence == model.project.sequence)

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("BATCH_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }
}

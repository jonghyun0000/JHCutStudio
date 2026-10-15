import Foundation
import AppKit
import JHCutCore

/// Editor flow for stabilisation: analyse the selected clip, undo/redo, save/reopen, cancel,
/// a project changed during analysis, locked tracks, settings that survive re-analysis.
@main struct StabilizeEditorProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/StabilizeEditor")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }

  let source = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov").standardizedFileURL
  let digest = try await FileIdentity.sha256(source)
  let asset = try await MediaImporter.inspect(url: source)
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  var project = Project(name: "안정화 편집"); project.sequence.width = 1080; project.sequence.height = 1920
  let clip = Clip(name: "실사", assetID: asset.id, sourceStart: MediaTime(seconds: 120), duration: MediaTime(seconds: 15))
  project.assets = [asset]; project.sequence.tracks[0].clips = [clip]
  model.history = EditorHistory(project: project)
  func stored() -> StabilizationData? { model.project.sequence.tracks[0].clips[0].stabilization }
  func waitIdle() async throws { while model.productivityBusy { try await Task.sleep(nanoseconds: 30_000_000) } }

  model.selectedClipID = nil; model.selectedClipIDs = []
  model.analyzeStabilization()
  check("Nothing selected: refused with a message, nothing started", model.error != nil && !model.productivityBusy && stored() == nil, model.error ?? "")
  model.error = nil
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  let before = model.project
  model.analyzeStabilization()
  check("Analysis runs in the background and locks other work", model.productivityBusy && model.busyDocument)
  try await waitIdle()
  check("Analysis stored on the clip", model.error == nil && stored() != nil, model.error ?? model.message)
  let data = stored()!
  check("Stored range covers the clip's source range", data.covers(clip.sourceStart, duration: clip.sourceDuration), String(format: "%.1f s at 30 Hz, %d samples", data.analyzedDuration, data.count))
  check("Message describes the result in plain words", model.message.contains("손떨림 분석 완료") && (model.message.contains("화면 확대") || model.message.contains("원본 유지")), model.message)
  model.undo()
  check("One undo removes the whole analysis", model.project == before)
  model.redo()
  check("Redo restores it exactly", stored() == data)
  // Settings survive a second analysis.
  var tuned = model.project.sequence.tracks[0].clips[0]; tuned.stabilization?.strength = 0.4; tuned.stabilization?.smoothing = 1.6
  model.perform(.updateClip(trackID: model.project.sequence.tracks[0].id, clip: tuned))
  model.analyzeStabilization(); try await waitIdle()
  check("Re-analysis keeps the user's strength and smoothing", stored()?.strength == min(0.4,(stored()?.confidence ?? 1)<0.65 ? 0.35 : 1) && stored()?.smoothing == 1.6)
  tuned = model.project.sequence.tracks[0].clips[0]; tuned.stabilization?.enabled = false
  model.perform(.updateClip(trackID:model.project.sequence.tracks[0].id,clip:tuned))
  model.analyzeStabilization(); try await waitIdle()
  check("Manual disabled setting survives re-analysis", stored()?.enabled == false)
  let beforeDocumentChange = model.project
  model.analyzeStabilization(); model.documentURL = root.appendingPathComponent("Other.jhcut")
  try await waitIdle()
  check("Same project in changed document: stale analysis refused", model.project == beforeDocumentChange && model.error?.contains("변경") == true)
  model.documentURL = nil; model.error = nil
  // Save / reopen
  let doc = root.appendingPathComponent("Stabilized.jhcut")
  try ProjectStore.save(model.project, to: doc)
  check("Save/reopen keeps the analysis and settings", try ProjectStore.load(from: doc).sequence == model.project.sequence)
  // Cancel mid-analysis
  let snapshotBeforeCancel = model.project
  var long = model.project.sequence.tracks[0].clips[0]; long.stabilization = nil; long.duration = MediaTime(seconds: 120)
  model.perform(.updateClip(trackID: model.project.sequence.tracks[0].id, clip: long))
  let beforeCancel = model.project
  model.analyzeStabilization()
  try await Task.sleep(nanoseconds: 300_000_000); model.cancelProductivity(); try await waitIdle()
  check("Cancelled analysis leaves the document unchanged", model.project == beforeCancel && model.message.contains("취소"), model.message)
  _ = snapshotBeforeCancel
  // Project changed during analysis → result must not be applied
  model.analyzeStabilization()
  model.perform(.rename("분석 중 이름 변경"))
  try await waitIdle()
  check("Project edited during analysis: stale result is not applied", model.project.sequence.tracks[0].clips[0].stabilization == nil && model.error?.contains("변경") == true, model.error ?? model.message)
  model.error = nil
  // Locked track
  var locked = model.project.sequence.tracks[0]; locked.isLocked = true
  model.perform(.updateTrack(locked))
  model.analyzeStabilization()
  check("Locked track: refused with a message", model.error?.contains("잠긴") == true && !model.productivityBusy, model.error ?? "")
  model.error = nil
  locked.isLocked = false; model.perform(.updateTrack(locked))
  // Over-long clip
  var tooLong = model.project.sequence.tracks[0].clips[0]; tooLong.duration = MediaTime(seconds: 700)
  var project2 = model.project; project2.sequence.tracks[0].clips[0] = tooLong
  let longAsset = { () -> MediaAsset in var a = asset; a.duration = MediaTime(seconds: 900); return a }()
  project2.assets = [longAsset]; model.history = EditorHistory(project: project2)
  model.selectedClipID = tooLong.id; model.selectedClipIDs = [tooLong.id]
  model.analyzeStabilization()
  check("Clip longer than 10 minutes: refused with the reason", model.error?.contains("10분") == true && !model.productivityBusy, model.error ?? "")
  model.error = nil
  // Remove
  model.history = EditorHistory(project: { var p = project; p.sequence.tracks[0].clips[0].stabilization = data; return p }())
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.removeStabilization()
  check("Remove takes the analysis off in one undo step", stored() == nil)
  model.undo(); check("Undo of remove restores it", stored() == data)
  // Non-video selections
  let title = Clip(name: "제목", start: .zero, duration: MediaTime(seconds: 2), title: Title(text: "x"))
  var p3 = project; p3.sequence.tracks[2].clips = [title]; model.history = EditorHistory(project: p3)
  model.selectedClipID = title.id; model.selectedClipIDs = [title.id]
  check("Title clips are not stabilisable", model.stabilizableSelection == nil)
  // Exercise the same asynchronous conversion entry point used by the menu without modal panels.
  let prepared = root.appendingPathComponent("Prepared")
  let small = URL(fileURLWithPath:"Artifacts/Stage5Copies/IMG_8490.mov").standardizedFileURL
  model.history = EditorHistory(project:Project(name:"Conversion")); model.error = nil
  let assetsBefore = model.project.assets.count
  model.prepareMedia(audioOnly:false,sourceURL:small,audioTrackIndex:0,outputDirectory:prepared)
  try await waitIdle()
  check("SDR copy conversion is added through editor workflow", model.error == nil && model.project.assets.count == assetsBefore+1,model.error ?? "")
  let afterConversion = model.project
  model.undo(); check("Prepared media addition is undoable", model.project.assets.count == assetsBefore)
  model.redo(); check("Prepared media redo restores asset", model.project == afterConversion)
  let filesBefore = (try? FileManager.default.contentsOfDirectory(atPath:prepared.path)) ?? []
  model.error = nil
  model.prepareMedia(audioOnly:false,sourceURL:small,audioTrackIndex:0,outputDirectory:prepared)
  model.documentURL = root.appendingPathComponent("ChangedDuringConversion.jhcut")
  try await waitIdle()
  let filesAfter = (try? FileManager.default.contentsOfDirectory(atPath:prepared.path)) ?? []
  check("Changed document rejects converted copy and removes orphan", model.project == afterConversion && model.error?.contains("변경") == true && Set(filesBefore)==Set(filesAfter))
  model.documentURL = nil; model.error = nil
  model.prepareMedia(audioOnly:false,sourceURL:small,audioTrackIndex:0,outputDirectory:prepared)
  model.cancelProductivity(); try await waitIdle()
  let filesAfterCancel = (try? FileManager.default.contentsOfDirectory(atPath:prepared.path)) ?? []
  check("Cancelled conversion leaves document/files unchanged", model.project == afterConversion && Set(filesBefore)==Set(filesAfterCancel) && model.message.contains("취소"))
  check("Source media never modified", try await FileIdentity.sha256(source) == digest)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("STABILIZE_EDITOR_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

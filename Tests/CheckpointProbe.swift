import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Upgrade 1: long-recognition checkpoints and resume. Uses real Whisper on a synthetic Korean
/// speech file with known text; nothing here claims recognition accuracy.
@main struct CheckpointProbe {
 final class TaskBox: @unchecked Sendable { var task: Task<LocalTranscript, Error>?; var cancelled = false; var etaSeen: [Double?] = [] ; let lock = NSLock() }

 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Checkpoint", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") {
   rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
  }
  defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }

  // ---- Fixture: ~90s of known Korean speech (three spoken passes separated by pauses). ----
  let fixture = try await makeFixture(root)
  let working = root.appendingPathComponent("media-copy.mp4")
  try? FileManager.default.removeItem(at: working)
  try FileManager.default.copyItem(at: fixture, to: working)
  let asset = try await MediaImporter.inspect(url: working)
  let duration = asset.duration
  check("Fixture spans several 30s windows", duration.seconds > 61, String(format: "%.1fs", duration.seconds))

  let store = TranscriptionCheckpointStore(root: root.appendingPathComponent("Checkpoints", isDirectory: true))
  try? FileManager.default.removeItem(at: store.root)
  let fingerprints = MediaFingerprintCache()
  var options = SpeechOptions(); options.language = "ko"
  let configuration = WhisperConfiguration()
  let projectID = UUID(), clipID = UUID(), window = 30.0
  let digest = try await fingerprints.sha256(of: working)
  let key = TranscriptionCheckpointKey(projectID: projectID, clipID: clipID, mediaSHA256: digest, sourceStart: .zero, duration: duration,
                                       windowSeconds: window, options: options, modelSHA256: configuration.modelSpec.sha256)
  let session = TranscriptionCheckpointSession(store: store, key: key)
  check("Media digest equals full-file SHA-256", digest == (try await FileIdentity.sha256(working)))

  // ---- Run A: cancel once the first window is on disk. ----
  let tempBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("JHCutSpeech-") }
  let box = TaskBox()
  box.task = Task.detached {
   try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: options, windowSeconds: window,
                                               checkpoint: session, detail: { d in
    box.lock.lock(); box.etaSeen.append(d.estimatedRemainingSeconds); let first = !box.cancelled && d.windowIndex >= 1; if first { box.cancelled = true }; box.lock.unlock()
    if first { box.task?.cancel() }
   })
  }
  var cancelledA = false
  do { _ = try await box.task!.value } catch is CancellationError { cancelledA = true } catch { check("Run A unexpected error", false, "\(error)") }
  let afterA = store.completedWindows(for: key)
  check("Cancel mid-run raises cancellation", cancelledA)
  check("Completed window survives cancellation", afterA.count >= 1 && afterA[0] != nil, "saved windows: \(afterA.keys.sorted())")
  check("Window in progress was not saved partially", afterA.count < key.windowCount, "\(afterA.count)/\(key.windowCount)")
  try await Task.sleep(nanoseconds: 1_500_000_000)
  let tempAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("JHCutSpeech-") }
  check("Cancelled run removed its temporary audio", tempAfter.subtracting(tempBefore).isEmpty, "leftover: \(tempAfter.subtracting(tempBefore).sorted())")
  check("No whisper process left running after cancel", !processRunning("whisper-cli"))
  box.lock.lock(); let etaBeforeCompute = box.etaSeen.first ?? nil; box.lock.unlock()
  check("No time estimate before any window is recognised", etaBeforeCompute == nil)

  // ---- Run B: resume. ----
  let etaBox = TaskBox()
  let resumed = try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: options, windowSeconds: window,
                                                            checkpoint: session, detail: { d in etaBox.lock.lock(); etaBox.etaSeen.append(d.estimatedRemainingSeconds); etaBox.lock.unlock() })
  check("Resume reuses finished windows", resumed.reusedWindows == afterA.count, "reused \(resumed.reusedWindows ?? -1), computed \(resumed.computedWindows ?? -1)")
  check("Resume recognises only the remaining windows", resumed.computedWindows == key.windowCount - afterA.count)
  check("All windows stored after resume", store.completedWindows(for: key).count == key.windowCount)
  // Mirror the assembly rule: a later window drops cues in its first 0.5s (they belong to the
  // previous window's tail); everything else from disk must come back byte-for-byte.
  let reusedCues = afterA.values.flatMap { w in w.cues.filter { $0.start.seconds >= w.sourceStart.seconds + (w.index == 0 ? 0 : 0.5) } }
  check("Reused cues appear unchanged in the resumed result", !reusedCues.isEmpty && reusedCues.allSatisfy { resumed.cues.contains($0) }, "\(reusedCues.count) cues from disk")
  etaBox.lock.lock(); let etas = etaBox.etaSeen; etaBox.lock.unlock()
  check("Estimate appears after this run recognises a window", etas.contains { $0 != nil })

  // ---- Run C: everything from disk. ----
  let started = Date()
  let full = try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: options, windowSeconds: window, checkpoint: session)
  let reloadSeconds = Date().timeIntervalSince(started)
  check("Second complete run skips Whisper entirely", full.reusedWindows == key.windowCount && full.computedWindows == 0, String(format: "%.2fs", reloadSeconds))
  check("Checkpoint result identical to resumed result", full.cues == resumed.cues && full.language == resumed.language)

  // ---- Uninterrupted reference run, no checkpoint. ----
  let reference = try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: options, windowSeconds: window)
  let sameText = reference.cues.map(\.text) == full.cues.map(\.text)
  let sameTimes = zip(reference.cues, full.cues).allSatisfy { abs($0.start.seconds - $1.start.seconds) < 0.01 && abs($0.duration.seconds - $1.duration.seconds) < 0.01 }
  let firstDiff = zip(reference.cues, full.cues).enumerated().first { $0.element.0.text != $0.element.1.text || abs($0.element.0.start.seconds - $0.element.1.start.seconds) >= 0.01 }
  check("Interrupted+resumed captions match an uninterrupted run", sameText && sameTimes && reference.cues.count == full.cues.count,
        "\(full.cues.count) vs \(reference.cues.count) cues" + (firstDiff.map { " · first difference #\($0.offset): '\($0.element.1.text)'@\($0.element.1.start.seconds) vs '\($0.element.0.text)'@\($0.element.0.start.seconds)" } ?? ""))

  // ---- Keys that must not share windows. ----
  var otherOptions = options; otherOptions.glossary = "공원"
  let byOptions = TranscriptionCheckpointKey(projectID: projectID, clipID: clipID, mediaSHA256: digest, sourceStart: .zero, duration: duration, windowSeconds: window, options: otherOptions, modelSHA256: configuration.modelSpec.sha256)
  check("Different recognition hint does not reuse", store.completedWindows(for: byOptions).isEmpty && byOptions.identifier != key.identifier)
  let byProject = TranscriptionCheckpointKey(projectID: UUID(), clipID: clipID, mediaSHA256: digest, sourceStart: .zero, duration: duration, windowSeconds: window, options: options, modelSHA256: configuration.modelSpec.sha256)
  check("Different project does not reuse", store.completedWindows(for: byProject).isEmpty)
  let byClip = TranscriptionCheckpointKey(projectID: projectID, clipID: clipID, mediaSHA256: digest, sourceStart: MediaTime(seconds: 1), duration: duration - MediaTime(seconds: 1), windowSeconds: window, options: options, modelSHA256: configuration.modelSpec.sha256)
  check("Different trim does not reuse", store.completedWindows(for: byClip).isEmpty)
  do {
   _ = try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: otherOptions, windowSeconds: window, checkpoint: session)
   check("Mismatched session and request is refused", false)
  } catch { check("Mismatched session and request is refused", "\(error)".contains("체크포인트")) }

  // Media change: the same path now holds different bytes.
  let handle = try FileHandle(forWritingTo: working); try handle.seekToEnd(); try handle.write(contentsOf: Data([0x00, 0x01, 0x02])); try handle.close()
  let changedDigest = try await fingerprints.sha256(of: working)
  let byMedia = TranscriptionCheckpointKey(projectID: projectID, clipID: clipID, mediaSHA256: changedDigest, sourceStart: .zero, duration: duration, windowSeconds: window, options: options, modelSHA256: configuration.modelSpec.sha256)
  check("Changed media bytes change the digest (stat cache invalidated)", changedDigest != digest)
  check("Changed media does not reuse", store.completedWindows(for: byMedia).isEmpty)
  try FileManager.default.removeItem(at: working); try FileManager.default.copyItem(at: fixture, to: working)

  // Tampered manifest in the right folder.
  let manifest = store.directory(for: key).appendingPathComponent("manifest.json")
  let original = try Data(contentsOf: manifest)
  var tampered = try JSONSerialization.jsonObject(with: original) as! [String: Any]; tampered["projectID"] = UUID().uuidString
  try JSONSerialization.data(withJSONObject: tampered).write(to: manifest)
  check("Manifest for another key is ignored", store.completedWindows(for: key).isEmpty)
  try original.write(to: manifest)

  // Damaged window: removed, then recognised again.
  let damaged = store.directory(for: key).appendingPathComponent("window-00001.json")
  try Data("{\"index\": 1, \"cues\": [trunc".utf8).write(to: damaged)
  let afterDamage = store.completedWindows(for: key)
  check("Damaged window is dropped, others kept", afterDamage[1] == nil && afterDamage.count == key.windowCount - 1 && !FileManager.default.fileExists(atPath: damaged.path))
  let repaired = try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: options, windowSeconds: window, checkpoint: session)
  check("Only the damaged window is recognised again", repaired.computedWindows == 1 && repaired.reusedWindows == key.windowCount - 1)

  // Out-of-range cue in a stored window is rejected.
  var bogus = store.completedWindows(for: key)[2]!
  bogus.cues = [CaptionCue(start: MediaTime(seconds: 9_999), duration: MediaTime(seconds: 1), text: "범위 밖")]
  try store.save(bogus, for: key)
  check("Stored cue outside the clip range is rejected", store.completedWindows(for: key)[2] == nil)
  _ = try await LocalTranscription.transcribeLong(url: working, duration: duration, configuration: configuration, options: options, windowSeconds: window, checkpoint: session)

  // Summaries and deletion.
  let summaries = store.summaries(projectID: projectID)
  check("Summary reports complete checkpoint", summaries.count == 1 && summaries[0].completedWindows == key.windowCount && summaries[0].bytes > 0)
  try store.remove(key)
  check("Delete removes checkpoint", store.summaries(projectID: projectID).isEmpty && !FileManager.default.fileExists(atPath: store.directory(for: key).path))

  // A checkpoint write failure must not fail recognition.
  let blocked = root.appendingPathComponent("blocked-root")
  try? FileManager.default.removeItem(at: blocked); try Data("file, not a folder".utf8).write(to: blocked)
  let badStore = TranscriptionCheckpointStore(root: blocked)
  final class Flag: @unchecked Sendable { var hit = false }
  let flag = Flag()
  let shortKey = TranscriptionCheckpointKey(projectID: projectID, clipID: clipID, mediaSHA256: digest, sourceStart: .zero, duration: MediaTime(seconds: 30), windowSeconds: window, options: options, modelSHA256: configuration.modelSpec.sha256)
  let survived = try await LocalTranscription.transcribeLong(url: working, duration: MediaTime(seconds: 30), configuration: configuration, options: options, windowSeconds: window,
                                                             checkpoint: TranscriptionCheckpointSession(store: badStore, key: shortKey), onCheckpointError: { _ in flag.hit = true })
  check("Unwritable checkpoint folder reports but still returns captions", flag.hit && !survived.cues.isEmpty)

  // ---- Editor: the same flow through the real command path. ----
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.checkpointStore = store; model.mediaFingerprints = fingerprints; model.speechWindowSeconds = window
  model.translateAfterTranscription = false; model.speechOptions = options
  var project = Project(name: "체크포인트 편집기 검증"); project.sequence.width = 640; project.sequence.height = 360
  let clip = Clip(name: "긴 대사", assetID: asset.id, duration: duration)
  project.assets = [asset]; project.sequence.tracks[0].clips = [clip]
  model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.refreshTranscriptionStatus()
  check("Model installed for editor run", model.transcriptionReady, model.transcriptionStatus)

  // Cancel from the editor once one window is stored.
  model.transcribeSelection()
  while model.transcriptionActive {
   if store.summaries(projectID: project.id).first.map({ $0.completedWindows >= 1 }) == true { model.cancelProductivity(); break }
   try await Task.sleep(nanoseconds: 50_000_000)
  }
  while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  check("Editor cancel keeps document unchanged", model.project == project)
  check("Editor cancel reports preserved windows", model.message.contains("체크포인트에 보존"), model.message)
  model.refreshCheckpointSummaries()
  check("Panel sees resumable checkpoint for the selection", !model.selectedClipCheckpoints.isEmpty && model.selectedClipCheckpoints[0].completedWindows < model.selectedClipCheckpoints[0].totalWindows)

  model.transcribeSelection()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  let firstCaptions = model.captionClips.map { $0.title?.text ?? "" }
  check("Editor resume applies captions", model.error == nil && !firstCaptions.isEmpty, model.message)
  check("Editor resume message states reused windows", model.message.contains("재사용"), model.message)
  check("Detail state cleared after run", model.transcriptionDetail == nil && !model.transcriptionActive)
  let captioned = model.project
  model.undo()
  check("One undo removes resumed captions", model.project == project)
  // Generating captions selects the first caption (intended UI behaviour); pick the source again.
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.transcribeSelection()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  check("Full reuse reproduces identical captions", model.captionClips.map { $0.title?.text ?? "" } == firstCaptions && model.message.contains("\(key.windowCount)/\(key.windowCount)구간 재사용"), model.message)
  check("Captions carry the same timing on full reuse", model.captionClips.map(\.start) == captioned.sequence.tracks.flatMap(\.clips).filter { $0.title != nil }.sorted { $0.start < $1.start }.map(\.start))
  model.deleteSelectedCheckpoints()
  check("Panel delete clears selection checkpoints", model.selectedClipCheckpoints.isEmpty)

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("CHECKPOINT_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")); exit(1) }
 }

 static func processRunning(_ name: String) -> Bool {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", name]
  p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
  try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
 }

 /// Known Korean text spoken by the system voice, placed three times with pauses so the file
 /// crosses several recognition windows. Built once and reused.
 static func makeFixture(_ root: URL) async throws -> URL {
  let output = root.appendingPathComponent("long-ko-speech.mp4")
  if FileManager.default.fileExists(atPath: output.path) { return output }
  let script = "안녕하세요. 오늘은 긴 영상의 자동 자막을 확인합니다. 첫 번째 문장은 공원에 대한 이야기입니다. 날씨가 맑아서 많은 사람들이 산책을 하고 있습니다. 두 번째 문장은 카페에 대한 이야기입니다. 따뜻한 차와 케이크를 주문했습니다. 세 번째 문장은 저녁 계획입니다. 친구와 함께 영화를 보기로 했습니다. 마지막으로 오늘 촬영한 영상을 정리하겠습니다."
  let audio = root.appendingPathComponent("long-ko.aiff")
  let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say"); say.arguments = ["-v", "Yuna", "-r", "150", "-o", audio.path, script]
  try say.run(); say.waitUntilExit()
  guard say.terminationStatus == 0 else { throw ProjectError("say failed") }
  let speech = try await MediaImporter.inspect(url: audio)
  var p = Project(name: "long fixture"); p.sequence.width = 640; p.sequence.height = 360; p.assets = [speech]
  let ti = p.sequence.tracks.firstIndex { $0.kind == .audio }!
  var at = MediaTime.zero
  for _ in 0..<3 {
   p.sequence.tracks[ti].clips.append(Clip(assetID: speech.id, start: at, duration: speech.duration))
   at = at + speech.duration + MediaTime(seconds: 4)
  }
  try await ExportJob().export(plan: TimelineRenderer.build(project: p), to: output) { _ in }
  return output
 }
}

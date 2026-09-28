import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Upgrade 8: long-form recognition through the editor pipeline (voice activity + checkpoints +
/// Whisper) on 30/60/120-minute recordings made by concatenating the AUDIO of the real iPhone
/// video copies. Measures wall/CPU time, memory over time, main-thread stalls, ETA accuracy.
/// Run one duration per process so peak-memory numbers are per duration.
@main struct LongFormProbe {
 static func cpu(_ who: Int32) -> Double { var u = rusage(); getrusage(who, &u); return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6 }
 static func peakMB(_ who: Int32) -> Double { var u = rusage(); getrusage(who, &u); return Double(u.ru_maxrss) / 1_048_576 }
 /// Current physical footprint (what Activity Monitor shows as Memory).
 static func footprintMB() -> Double {
  var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
  return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
 }
 static func whisperRunning() -> Bool {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "whisper-cli"]
  p.standardOutput = Pipe(); try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
 }
 static func speechTemps() -> Set<String> { Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("JHCutSpeech-") }) }

 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let args = Array(CommandLine.arguments.dropFirst())
  let root = URL(fileURLWithPath: args.first ?? "Artifacts/Upgrade-0.7/LongForm", isDirectory: true).standardizedFileURL
  let minutes = Int(args.dropFirst().first ?? "30") ?? 30
  let mode = args.dropFirst(2).first ?? "vad" // vad | full | cancel
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], metrics: [String: Any] = ["minutes": minutes, "mode": mode]
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  let tag = "\(minutes)min-\(mode)"
  func save() {
   try? JSONSerialization.data(withJSONObject: ["checks": rows, "metrics": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result-\(tag).json"))
  }
  defer { save() }

  let media = try await fixture(root, minutes: minutes)
  let asset = try await MediaImporter.inspect(url: media)
  metrics["mediaSeconds"] = asset.duration.seconds; metrics["mediaBytes"] = (try? FileManager.default.attributesOfItem(atPath: media.path)[.size] as? NSNumber)?.intValue ?? 0
  print("fixture \(media.lastPathComponent) \(String(format: "%.0f", asset.duration.seconds))s")
  check("Fixture has the requested length", abs(asset.duration.seconds - Double(minutes * 60)) < 2, String(format: "%.1fs", asset.duration.seconds))

  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery-\(tag)")), exportHistoryURL: root.appendingPathComponent("journal-\(tag).json"))
  model.translateAfterTranscription = false; model.useSpeechCheckpoints = true; model.skipNonSpeech = mode != "full"
  model.speechOptions.language = "ko"
  model.checkpointStore = TranscriptionCheckpointStore(root: root.appendingPathComponent("Checkpoints-\(tag)", isDirectory: true))
  try? FileManager.default.removeItem(at: model.checkpointStore.root)
  var project = Project(name: "긴 영상 \(minutes)분"); project.sequence.width = 1280; project.sequence.height = 720
  let clip = Clip(name: "긴 녹음", assetID: asset.id, duration: asset.duration)
  project.assets = [asset]
  let audioTrack = project.sequence.tracks.firstIndex { $0.kind == .audio }!
  project.sequence.tracks[audioTrack].clips = [clip]
  model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.refreshTranscriptionStatus()
  check("Recognition ready (installed model)", model.transcriptionReady, model.transcriptionStatus)
  let before = model.project, tempsBefore = speechTemps()

  // Main-thread watchdog: the gap between 10 ms ticks is how long the UI would have been frozen.
  var maxGap = 0.0, gaps = 0, samples: [(Double, Double)] = [], etas: [(elapsed: Double, eta: Double)] = []
  let t0 = Date(), cpu0 = cpu(RUSAGE_SELF) + cpu(RUSAGE_CHILDREN), footprint0 = footprintMB()
  var running = true
  let watchdog = Task { @MainActor in
   var last = Date(), lastSample = Date.distantPast
   while running {
    try? await Task.sleep(nanoseconds: 10_000_000)
    let now = Date(), gap = now.timeIntervalSince(last) - 0.01
    if gap > 0.25 { gaps += 1 }
    maxGap = max(maxGap, gap); last = now
    if now.timeIntervalSince(lastSample) >= 1 { samples.append((now.timeIntervalSince(t0), footprintMB())); lastSample = now }
    if let eta = model.transcriptionDetail?.estimatedRemainingSeconds { etas.append((now.timeIntervalSince(t0), eta)) }
   }
  }
  model.transcribeSelection()
  var cancelledAt: Double?
  while model.productivityBusy {
   try await Task.sleep(nanoseconds: 100_000_000)
   if mode == "cancel", cancelledAt == nil, (model.transcriptionDetail?.windowIndex ?? 0) >= 2 {
    // Mid-run: while Whisper is working on the third window.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    cancelledAt = Date().timeIntervalSince(t0); model.cancelProductivity()
   }
  }
  let wall = Date().timeIntervalSince(t0), cpuUsed = cpu(RUSAGE_SELF) + cpu(RUSAGE_CHILDREN) - cpu0
  running = false; _ = await watchdog.value
  // Let deferred cleanup and autorelease pools drain, then read the settled footprint.
  try await Task.sleep(nanoseconds: 2_000_000_000)
  let footprintAfter = footprintMB()
  let peakSample = samples.map(\.1).max() ?? -1
  metrics["wallSeconds"] = wall; metrics["cpuSeconds"] = cpuUsed; metrics["realtimeFactor"] = asset.duration.seconds / max(0.001, wall)
  metrics["footprintStartMB"] = footprint0; metrics["footprintPeakSampledMB"] = peakSample; metrics["footprintAfterMB"] = footprintAfter
  metrics["peakRSSProcessMB"] = peakMB(RUSAGE_SELF); metrics["peakRSSWhisperMB"] = peakMB(RUSAGE_CHILDREN)
  metrics["mainThreadMaxStallSeconds"] = maxGap; metrics["mainThreadStallsOver250ms"] = gaps
  metrics["memoryTimeline"] = samples.enumerated().filter { $0.offset % 10 == 0 }.map { ["t": $0.element.0, "mb": $0.element.1] }
  metrics["message"] = model.message; metrics["error"] = model.error ?? ""
  print(String(format: "wall %.1fs (%.1fx realtime) · CPU %.1fs · footprint start %.0f / peak %.0f / after %.0f MB · whisper peak %.0f MB · main-thread max stall %.3fs (%d > 250ms)",
               wall, asset.duration.seconds / max(0.001, wall), cpuUsed, footprint0, peakSample, footprintAfter, peakMB(RUSAGE_CHILDREN), maxGap, gaps))
  print("  " + (model.error ?? model.message))
  check("UI stays responsive (no main-thread stall over 0.5 s)", maxGap < 0.5, String(format: "max %.3fs", maxGap))
  check("Memory returns near the starting level after the job", footprintAfter < footprint0 + 300, String(format: "%.0f → %.0f MB", footprint0, footprintAfter))
  check("No temporary recognition audio left", speechTemps().subtracting(tempsBefore).isEmpty)
  check("No whisper process left", !whisperRunning())

  if mode == "cancel" {
   check("Cancelled mid-run", cancelledAt != nil && model.message.contains("취소"), model.message)
   check("Document unchanged after cancel", model.project == before)
   let kept = model.checkpointStore.summaries().reduce(0) { $0 + $1.completedWindows }
   check("Finished windows kept for resume", kept >= 2, "\(kept) windows")
   // Resume and measure how much is reused.
   let r0 = Date()
   model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 100_000_000) }
   metrics["resumeWallSeconds"] = Date().timeIntervalSince(r0); metrics["resumeMessage"] = model.message
   check("Resume completes and reuses finished windows", model.error == nil && model.message.contains("재사용"), model.error ?? model.message)
  } else {
   let captions = model.captionClips
   metrics["captions"] = captions.count
   check("Long recognition completed", model.error == nil && !captions.isEmpty, model.error ?? "\(captions.count) captions")
   check("Every caption lies inside the clip", captions.allSatisfy { $0.start >= clip.start && $0.end <= clip.end + MediaTime(seconds: 0.05) })
   // ETA accuracy: compare each estimate with the time that actually remained.
   let errors = etas.map { abs(($0.elapsed + $0.eta) - wall) / wall }
   if !errors.isEmpty {
    let sorted = errors.sorted()
    metrics["etaSamples"] = errors.count; metrics["etaMedianRelativeError"] = sorted[sorted.count / 2]; metrics["etaMaxRelativeError"] = sorted.last!
    metrics["etaFirstAtSeconds"] = etas.first!.elapsed
    check("Time estimate shown during the run", true, String(format: "first after %.0fs · median error %.0f%% of total · max %.0f%%", etas.first!.elapsed, sorted[sorted.count / 2] * 100, sorted.last! * 100))
   } else { check("Time estimate shown during the run", false, "no estimate observed") }
   let saved = root.appendingPathComponent("long-\(tag).jhcut")
   try ProjectStore.save(model.project, to: saved)
   check("Project with long captions saves and reopens", try ProjectStore.load(from: saved).sequence == model.project.sequence)
  }
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("LONGFORM_RESULT \(tag) checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }

 /// Audio-only concatenation of the real iPhone copies (read-only), repeated to `minutes`.
 static func fixture(_ root: URL, minutes: Int) async throws -> URL {
  let output = root.appendingPathComponent("long-\(minutes)min.m4a")
  if FileManager.default.fileExists(atPath: output.path) { return output }
  let copies = ["IMG_0047.mov", "IMG_9211.mov", "IMG_0140.mov"].map { URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/\($0)") }
  let composition = AVMutableComposition()
  guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ProjectError("composition") }
  var at = CMTime.zero
  let target = CMTime(seconds: Double(minutes * 60), preferredTimescale: 48_000)
  var i = 0
  while at < target {
   let asset = AVURLAsset(url: copies[i % copies.count]); i += 1
   guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
   let length = min(try await asset.load(.duration), target - at)
   try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
   at = at + length
  }
  guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw ProjectError("export") }
  let staging = root.appendingPathComponent("staging-\(minutes).m4a"); try? FileManager.default.removeItem(at: staging)
  export.outputURL = staging; export.outputFileType = .m4a
  await export.export()
  guard export.status == .completed else { throw export.error ?? ProjectError("fixture export failed") }
  try FileManager.default.moveItem(at: staging, to: output)
  return output
 }
}

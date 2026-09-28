import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Upgrade 9: automatic output check after export — file properties, caption layout lint,
/// burn-in pixel verification, SRT vs burned captions, export journal link.
@main struct QualityProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Quality", isDirectory: true).standardizedFileURL
  try? FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], metrics: [String: Any] = [:]
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() { try? JSONSerialization.data(withJSONObject: ["checks": rows, "metrics": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  defer { save() }

  // Background: 12 s of a real iPhone video COPY (read-only).
  let source = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov").standardizedFileURL
  let sourceDigest = try await FileIdentity.sha256(source)
  let asset = try await MediaImporter.inspect(url: source)
  var project = Project(name: "출력 검사"); project.sequence.width = 1280; project.sequence.height = 720; project.sequence.frameRate = FrameRate(numerator: 30, denominator: 1)
  let video = Clip(name: "배경", assetID: asset.id, sourceStart: MediaTime(seconds: 120), duration: MediaTime(seconds: 12))
  project.assets = [asset]; project.sequence.tracks[0].clips = [video]
  let style = TitleSizing.title(for: TitlePreset.builtIns[0], width: 1280, height: 720)
  func caption(_ text: String, _ start: Double, _ duration: Double, y: Double? = nil) -> Clip {
   var title = style; title.text = text; if let y { title.y = y }
   var clip = Clip(name: "자막", start: MediaTime(seconds: start), duration: MediaTime(seconds: duration), title: title)
   clip.captionMetadata = CaptionMetadata(language: "ko", originalLanguage: "ko", originalText: text, generatedText: text)
   return clip
  }
  let ti = project.sequence.tracks.firstIndex { $0.kind == .title }!
  project.sequence.tracks[ti].clips = [
   caption("안녕하세요 오늘은 공원입니다", 0.5, 2.0),
   caption("두 번째 자막입니다", 2.6, 1.6),
   caption("두 번째 자막입니다", 4.2, 1.0),                                   // duplicate right after
   caption("아주아주아주긴문장을아주짧은시간에보여줍니다", 5.3, 1.0),          // too fast
   caption("화면 아래로 빠져나간 자막", 6.5, 1.5, y: 0.0),                  // off screen
   caption("마지막 자막입니다", 9.0, 2.0)
  ]
  // Overlapping in time AND position on a second visible track.
  var second = Track(name: "자막 2", kind: .title); second.clips = [caption("겹치는 자막", 9.5, 1.5)]
  var hidden = Track(name: "숨긴 번역", kind: .title, isHidden: true); hidden.clips = [caption("숨긴 트랙 자막", 3.0, 2.0)]
  project.sequence.tracks += [second, hidden]

  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.reportsDirectory = root.appendingPathComponent("Reports")
  model.history = EditorHistory(project: project); model.rebuild()
  while model.isBuilding { try await Task.sleep(nanoseconds: 50_000_000) }
  model.exportSidecarSRT = true
  let output = root.appendingPathComponent("checked.mp4")
  model.exportQueue.append(QueuedExport(project: model.project, baseURL: nil, url: output, codec: .h264, bitRate: 8_000_000))
  let t0 = Date()
  model.startNextExport(); while model.isExporting { try await Task.sleep(nanoseconds: 100_000_000) }
  metrics["exportPlusCheckSeconds"] = Date().timeIntervalSince(t0)
  guard let report = model.lastQualityReport else { check("Quality report produced after export", false, model.error ?? model.exportQualityStatus); return }
  metrics["checkSeconds"] = report.checkSeconds
  print("  " + report.summary); for i in report.issues { print("   - \(i.severity.rawValue) \(i.code) \(i.message)") }
  let codes = Set(report.issues.map(\.code))
  check("Quality report produced after export", true, report.summary)
  check("File properties match the timeline", !codes.contains("duration") && !codes.contains("resolution") && !codes.contains("frameRate") && !codes.contains("audioMissing"),
        report.measured.map { String(format: "%d×%d %.3ffps %.3fs audio %d", $0.width, $0.height, $0.frameRate, $0.duration, $0.audioTracks) } ?? "")
  // The rasteriser keeps a caption centred on the bottom edge inside the frame, so it is reported
  // as outside the safe area (not as cut off); valid projects cannot place glyphs off the frame.
  check("Caption on the frame edge reported outside the safe area", report.issues.contains { $0.code == "outsideSafeArea" && $0.message.contains("빠져나간") } && !codes.contains("offScreen"))
  check("Duplicate caption reported", codes.contains("duplicate"))
  check("Too-fast caption reported", codes.contains("tooFast"))
  check("Overlapping captions reported", codes.contains("overlap"))
  check("Hidden track not treated as burned in", report.captionCount == 7, "\(report.captionCount) captions")
  let verified = report.burnIn.filter { $0.verified == true }.count, sampled = report.burnIn.filter { $0.verified != nil }.count
  metrics["burnInVerified"] = verified; metrics["burnInSampled"] = sampled
  metrics["burnInShares"] = report.burnIn.map { ["text": $0.text, "share": $0.matchShare ?? -1, "note": $0.note ?? ""] }
  // The off-screen caption is still partly drawn; every other sampled caption must be found.
  check("Burned-in captions found in the output frames", sampled >= 4 && report.burnIn.filter { $0.verified == false }.allSatisfy { $0.text.contains("빠져나간") },
        report.burnIn.map { "\($0.text.prefix(8)) \($0.matchShare.map { String(format: "%.0f%%", $0 * 100) } ?? ($0.note ?? "-"))" }.joined(separator: ", "))
  check("Sidecar SRT written and matches the burned captions", report.subtitles.map { $0.subtitleCount == 7 && $0.matched == 7 && $0.onlyBurned == 0 } == true,
        report.subtitles.map { "\($0.subtitleCount)/\($0.burnedCount) matched \($0.matched)" } ?? "none")
  let journal = model.exportJournal.last ?? [:]
  check("Export journal links the check result", journal["quality"] == report.summary && journal["qualityReport"].map { FileManager.default.fileExists(atPath: $0) } == true, journal.description)
  check("Report written as JSON and Markdown", model.lastQualityReportURL.map { FileManager.default.fileExists(atPath: $0.path) && FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("json").path) } == true)
  let outputDigest = try await FileIdentity.sha256(output)

  // ---- SRT edited after export: shifted and missing cues are reported on re-check ----
  let srt = output.deletingPathExtension().appendingPathExtension("srt")
  var cues = try SRTCodec.parse(String(contentsOf: srt, encoding: .utf8))
  cues[1].start = cues[1].start + MediaTime(seconds: 0.5); cues.removeLast()
  try SRTCodec.serialize(cues).write(to: srt, atomically: true, encoding: .utf8)
  model.recheckLastExport(); while model.isExporting { try await Task.sleep(nanoseconds: 100_000_000) }
  let recheck = model.lastQualityReport?.subtitles
  check("Shifted and missing SRT cues reported", recheck.map { $0.timeMismatches == 1 && $0.onlyBurned == 1 && $0.subtitleCount == 6 } == true, recheck.map { "\($0)" } ?? "none")

  // ---- Wrong expectations must be caught (the checker is not a rubber stamp) ----
  let plan = try await TimelineRenderer.build(project: model.project)
  var expected = OutputExpectation.from(project: model.project, plan: plan)
  var wrong = expected; wrong.width = 1920; wrong.height = 1080; wrong.frameRate = 24; wrong.duration += 1; wrong.captions = []
  let wrongReport = try await OutputQuality.check(output: output, expectation: wrong)
  let wrongCodes = Set(wrongReport.issues.map(\.code))
  check("Resolution, frame rate and duration mismatches are errors", wrongCodes.isSuperset(of: ["resolution", "frameRate", "duration"]) && !wrongReport.passed, wrongCodes.sorted().joined(separator: ","))
  var ghost = style; ghost.text = "출력에 없는 자막"; ghost.y = 0.5
  expected.captions.append(ExpectedCaption(title: ghost, start: 1.0, end: 2.0, isCaption: true, pixelComparable: true, fadeIn: 0, fadeOut: 0))
  expected.captions.sort { $0.start < $1.start }
  let ghostReport = try await OutputQuality.check(output: output, expectation: expected)
  check("A caption missing from the video is detected", ghostReport.burnIn.contains { $0.text == "출력에 없는 자막" && $0.verified == false } && ghostReport.issues.contains { $0.code == "burnIn" },
        ghostReport.burnIn.first { $0.text == "출력에 없는 자막" }.flatMap { $0.matchShare }.map { String(format: "%.0f%%", $0 * 100) } ?? "")

  // ---- Silent export when the timeline has sound ----
  var silentProject = model.project
  for i in silentProject.sequence.tracks.indices where silentProject.sequence.tracks[i].kind == .video { silentProject.sequence.tracks[i].isMuted = true }
  let silentPlan = try await TimelineRenderer.build(project: silentProject)
  let silentOut = root.appendingPathComponent("silent.mp4")
  try await ExportJob().export(plan: silentPlan, to: silentOut) { _ in }
  var claimsAudio = OutputExpectation.from(project: silentProject, plan: silentPlan); claimsAudio.expectsAudio = true
  let silentReport = try await OutputQuality.check(output: silentOut, expectation: claimsAudio)
  check("Missing or silent audio is reported when sound is expected", silentReport.issues.contains { $0.code == "audioMissing" || $0.code == "audioSilent" }, silentReport.issues.map(\.code).joined(separator: ","))

  check("Checking never modifies the output", try await FileIdentity.sha256(output) == outputDigest)
  check("Source copy unchanged", try await FileIdentity.sha256(source) == sourceDigest)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("QUALITY_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }
}

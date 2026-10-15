import Foundation
import JHCutCore

/// Real iPhone video COPIES, full length: voice-activity analysis and recognition with and without
/// skipping non-speech. Reports measured time/CPU/memory and caption counts. No accuracy numbers:
/// there is no human transcript beside these videos, so evaluation reports “평가 불가”.
@main struct RealIPhone07Probe {
 static func childCPU() -> Double { var u = rusage(); getrusage(RUSAGE_CHILDREN, &u); return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6 }
 static func selfCPU() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6 }
 static func childPeakMB() -> Double { var u = rusage(); getrusage(RUSAGE_CHILDREN, &u); return Double(u.ru_maxrss) / 1_048_576 }
 static func selfPeakMB() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576 }

 static func main() async throws {
  setbuf(stdout, nil)
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/RealIPhone")
  let copies = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies", isDirectory: true)
  let names = CommandLine.arguments.count > 2 ? Array(CommandLine.arguments.dropFirst(2)) : ["IMG_0140.mov", "IMG_0047.mov", "IMG_9211.mov"]
  if ProcessInfo.processInfo.environment["JHCUT_REAL_IPHONE_MODE"] != "full" {
   try await boundaryProbe(root: root, copies: copies, names: names)
   return
  }
  var records: [[String: Any]] = []
  var options = SpeechOptions(); options.language = "auto"
  let config = WhisperConfiguration()
  for name in names {
   let url = copies.appendingPathComponent(name)
   let before = try await FileIdentity.sha256(url)
   let asset = try await MediaImporter.inspect(url: url)
   print("== \(name) \(String(format: "%.0f", asset.duration.seconds))s")
   var cpu0 = selfCPU()
   let vad = try await VoiceActivity.analyze(url: url, sourceStart: .zero, duration: asset.duration)
   let vadCPU = selfCPU() - cpu0
   print("  VAD \(String(format: "%.1fs wall, %.1fs CPU", vad.analysisSeconds, vadCPU)) · skippable \(String(format: "%.0f%%", vad.skippableShare * 100))")
   func run(_ regions: [ClosedRange<Double>]?) async throws -> (LocalTranscript, Double, Double) {
    let c0 = childCPU(), s0 = selfCPU(), t0 = Date()
    let r = try await LocalTranscription.transcribeLong(url: url, duration: asset.duration, configuration: config, options: options, windowSeconds: 300, speechRegions: regions, speechEvidence: regions == nil ? nil : vad.confidentSpeech)
    return (r, Date().timeIntervalSince(t0), childCPU() - c0 + selfCPU() - s0)
   }
   let (full, fullWall, fullCPU) = try await run(nil)
   print("  full: \(full.cues.count) cues \(String(format: "%.1fs wall %.1fs CPU", fullWall, fullCPU)) lang \(full.language)")
   let (skip, skipWall, skipCPU) = try await run(vad.speechRegions)
   print("  skip: \(skip.cues.count) cues \(String(format: "%.1fs wall %.1fs CPU", skipWall, skipCPU)) lang \(skip.language) · skipped windows \(skip.skippedWindows ?? 0)")
   print("  full loops removed \(full.repeatedCuesRemoved ?? 0), most repeated line ×\(topRepeat(full.cues)) · skip loops removed \(skip.repeatedCuesRemoved ?? 0), ×\(topRepeat(skip.cues))")
   // Whisper's own non-speech output: "[Music]"-style markers and ♪ lyric lines.
   func isMarker(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) || t.contains("♪")
   }
   func topRepeat(_ cues: [CaptionCue]) -> Int { Dictionary(grouping: cues.map { RepetitionGuard.normalized($0.text) }, by: { $0 }).values.map(\.count).max() ?? 0 }
   func byKind(_ cues: [CaptionCue]) -> [String: Int] {
    var d: [String: Int] = [:]
    for cue in cues {
     let mid = cue.start.seconds + cue.duration.seconds / 2
     let kind = vad.segments.first { $0.start <= mid && mid < $0.end }?.kind.rawValue ?? "none"
     d[kind, default: 0] += 1
    }
    return d
   }
   let silentFull = VoiceActivity.silentCaptions(full.cues.map { $0.start.seconds...($0.start.seconds + $0.duration.seconds) }, report: vad)
   let silentSkip = VoiceActivity.silentCaptions(skip.cues.map { $0.start.seconds...($0.start.seconds + $0.duration.seconds) }, report: vad)
   // Consistency only (not accuracy): how much of the full run's text over speech the skipping run kept.
   let speechText = full.cues.filter { cue in vad.speechRegions.contains { $0.lowerBound <= cue.start.seconds && cue.start.seconds <= $0.upperBound } }.map(\.text).joined()
   let consistency = try TranscriptEvaluation.editCounts(reference: Array(TranscriptEvaluation.normalized(speechText, language: full.language)), hypothesis: Array(TranscriptEvaluation.normalized(skip.cues.map(\.text).joined(), language: full.language)))
   let refLen = max(1, TranscriptEvaluation.normalized(speechText, language: full.language).count)
   let evaluation = try TranscriptEvaluation.evaluate(captions: skip.cues.map { EvaluatedCaption(text: $0.text, start: $0.start.seconds, end: $0.start.seconds + $0.duration.seconds) },
                                                  reference: try TranscriptReference.locate(besideMedia: url).map(TranscriptReference.load), language: full.language, sourceRange: 0...asset.duration.seconds, mediaDuration: asset.duration.seconds)
   let prefix = root.appendingPathComponent(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)
   try SRTCodec.serialize(full.cues).write(to: prefix.appendingPathExtension("full.srt"), atomically: true, encoding: .utf8)
   try SRTCodec.serialize(skip.cues).write(to: prefix.appendingPathExtension("skip.srt"), atomically: true, encoding: .utf8)
   let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
   try encoder.encode(vad).write(to: prefix.appendingPathExtension("vad.json"))
   let after = try await FileIdentity.sha256(url)
   var record: [String: Any] = [
    "source": name, "durationSeconds": asset.duration.seconds, "copyUnchanged": before == after,
    "vad": ["wallSeconds": vad.analysisSeconds, "cpuSeconds": vadCPU, "classifier": vad.classifierAvailable, "skippableShare": vad.skippableShare,
            "speechSeconds": vad.seconds(of: .speech), "silenceSeconds": vad.seconds(of: .silence), "musicSeconds": vad.seconds(of: .music),
            "noiseSeconds": vad.seconds(of: .noise), "uncertainSeconds": vad.seconds(of: .uncertain)],
    "full": ["wallSeconds": fullWall, "cpuSeconds": fullCPU, "cues": full.cues.count, "language": full.language, "cuesByKind": byKind(full.cues), "cuesOverNonSpeech": silentFull.count, "markerOrLyricCues": full.cues.filter { isMarker($0.text) }.count, "repeatedCuesRemoved": full.repeatedCuesRemoved ?? 0, "loopSuspects": full.repetitionSuspects?.count ?? 0, "mostRepeatedLine": topRepeat(full.cues)],
    "skip": ["wallSeconds": skipWall, "cpuSeconds": skipCPU, "cues": skip.cues.count, "language": skip.language, "cuesByKind": byKind(skip.cues), "cuesOverNonSpeech": silentSkip.count, "markerOrLyricCues": skip.cues.filter { isMarker($0.text) }.count, "repeatedCuesRemoved": skip.repeatedCuesRemoved ?? 0, "loopSuspects": skip.repetitionSuspects?.count ?? 0, "mostRepeatedLine": topRepeat(skip.cues), "skippedWindows": skip.skippedWindows ?? 0],
    "wallReduction": 1 - skipWall / max(0.001, fullWall), "cpuReduction": 1 - skipCPU / max(0.001, fullCPU),
    "consistencyOverSpeech": ["referenceCharacters": refLen, "changedCharacterShare": Double(consistency.substitutions + consistency.deletions + consistency.insertions) / Double(refLen),
                              "note": "Difference between the two automatic runs over speech regions. Not an accuracy measure."],
    "evaluation": evaluation.status.rawValue, "evaluationMessage": evaluation.reason ?? "",
    "peakMemoryMB": ["probe": selfPeakMB(), "whisperChildMax": childPeakMB()]]
   record["cpuTotalSkipIncludingVAD"] = skipCPU + vadCPU
   records.append(record)
   guard before == after else { throw NSError(domain: "Real07", code: 1) }
   print("PASS full-length copy unchanged \(name)")
   print("  marker/lyric cues: full \(full.cues.filter { isMarker($0.text) }.count) → skip \(skip.cues.filter { isMarker($0.text) }.count) · cues over non-speech: full \(silentFull.count) → skip \(silentSkip.count) · evaluation: \(evaluation.reason ?? evaluation.status.rawValue)")
   cpu0 = 0
   try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
  }
  print("REAL07_DONE videos=\(records.count)")
 }
 /// Bounded actual-media checks at absolute 300/600s. A 30s window begins 30s before
 /// the boundary; pure fixture tests separately exercise full 300s windows.
 static func boundaryProbe(root: URL, copies: URL, names: [String]) async throws {
  var rows: [[String: Any]] = [], checks = 0, failures = 0
  func check(_ name: String, _ ok: Bool) {
   checks += 1; if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL") \(name)")
  }
  var options = SpeechOptions(); options.language = "auto"
  let config = WhisperConfiguration()
  for name in names {
   let url = copies.appendingPathComponent(name), before = try await FileIdentity.sha256(copies.appendingPathComponent(name))
   let asset = try await MediaImporter.inspect(url: url)
   for boundary in [300.0, 600.0] {
    let start = MediaTime(seconds: boundary - 30), length = MediaTime(seconds: 45)
    guard start + length <= asset.duration else { throw NSError(domain: "Real07.shortMedia", code: 1) }
    let folder = root.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(boundary))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let label = "\(name) boundary \(Int(boundary))s"
    print("MEASURE \(label) source \(start.seconds)…\((start + length).seconds), actual Whisper base; no human transcript")
    let key = TranscriptionCheckpointKey(projectID: UUID(), clipID: UUID(), mediaSHA256: before, sourceStart: start, duration: length, windowSeconds: 30, options: options, modelSHA256: config.modelSpec.sha256)
    let store = TranscriptionCheckpointStore(root: folder.appendingPathComponent("Checkpoints")), session = TranscriptionCheckpointSession(store: store, key: key)
    let reference = try await LocalTranscription.transcribeLong(url: url, sourceStart: start, duration: length, configuration: config, options: options, windowSeconds: 30)
    let task = Task.detached {
     try await LocalTranscription.transcribeLong(url: url, sourceStart: start, duration: length, configuration: config, options: options, windowSeconds: 30, checkpoint: session, detail: { d in
      if d.windowIndex == 1 { withUnsafeCurrentTask { $0?.cancel() } }
     })
    }
    var cancelled = false
    do { _ = try await task.value } catch is CancellationError { cancelled = true }
    check(label + " cancellation retains first completed window", cancelled && store.completedWindows(for: key).keys.sorted() == [0])
    let resumed = try await LocalTranscription.transcribeLong(url: url, sourceStart: start, duration: length, configuration: config, options: options, windowSeconds: 30, checkpoint: session)
    let received = store.completedWindows(for: key).values.sorted { $0.index < $1.index }.flatMap(\.cues)
    let expected = received.enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
    check(label + " all received cue IDs preserved once", resumed.cues.map(\.id) == expected.map(\.id) && resumed.cues.count == received.count)
    check(label + " fresh/resume normalized SRT equal", try SRTCodec.serialize(reference.cues) == SRTCodec.serialize(resumed.cues))
    check(label + " first half-second cues preserved", received.filter { $0.start >= MediaTime(seconds: boundary) && $0.start < MediaTime(seconds: boundary + 0.5) }.allSatisfy { resumed.cues.contains($0) })
    check(label + " absolute source bounds", resumed.cues.allSatisfy { $0.start >= start && $0.start + $0.duration <= start + length })
    let reload = try await LocalTranscription.transcribeLong(url: url, sourceStart: start, duration: length, configuration: config, options: options, windowSeconds: 30, checkpoint: session)
    check(label + " completed reload does no recognition", try reload.computedWindows == 0 && reload.reusedWindows == 2 && SRTCodec.serialize(reload.cues) == SRTCodec.serialize(reference.cues))
    let vad = try await VoiceActivity.analyze(url: url, sourceStart: start, duration: length)
    var skip: LocalTranscript?, skipError: String?
    let skipKey = TranscriptionCheckpointKey(projectID: key.projectID, clipID: key.clipID, mediaSHA256: before, sourceStart: start, duration: length, windowSeconds: 30, options: options, modelSHA256: config.modelSpec.sha256, skipsSilence: true)
    do {
     skip = try await LocalTranscription.transcribeLong(url: url, sourceStart: start, duration: length, configuration: config, options: options, windowSeconds: 30, checkpoint: TranscriptionCheckpointSession(store: store, key: skipKey), speechRegions: vad.speechRegions, speechEvidence: vad.confidentSpeech)
     let skipReceived = store.completedWindows(for: skipKey).values.flatMap(\.cues)
     check(label + " VAD received cues all preserved", skip!.cues.count == skipReceived.count && skipReceived.allSatisfy { skip!.cues.contains($0) })
     check(label + " VAD restored original bounds", skip!.cues.allSatisfy { $0.start >= start && $0.start + $0.duration <= start + length })
    } catch {
     skipError = "\(error)"
     check(label + " no-speech VAD refusal recorded", vad.speechRegions.isEmpty && skipError!.contains("음성 후보"))
    }
    try SRTCodec.serialize(reference.cues).write(to: folder.appendingPathComponent("fresh.srt"), atomically: true, encoding: .utf8)
    try SRTCodec.serialize(resumed.cues).write(to: folder.appendingPathComponent("resumed.srt"), atomically: true, encoding: .utf8)
    if let skip { try SRTCodec.serialize(skip.cues).write(to: folder.appendingPathComponent("vad.srt"), atomically: true, encoding: .utf8) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(vad).write(to: folder.appendingPathComponent("vad.json"))
    let row: [String: Any] = ["source": name, "sourceStart": start.seconds, "duration": length.seconds, "absoluteBoundary": boundary, "windowSeconds": 30,
      "pipeline": LocalTranscription.pipelineVersion, "receivedCues": received.count, "mergedCues": resumed.cues.count,
      "receivedLeadingHalfSecondCues": received.filter { $0.start.seconds >= boundary && $0.start.seconds < boundary + 0.5 }.count,
      "speechSkippingCues": skip?.cues.count ?? 0, "speechSkippingError": skipError ?? "", "repetitionReviewCues": resumed.repetitionSuspects?.count ?? 0,
      "evaluation": "unscored", "reason": "No human transcript: recognizer omission/word accuracy cannot be scored. Received-cue preservation and deterministic resume are checked separately."]
    rows.append(row)
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
   }
   check(name + " read-only copy hash unchanged", before == (try await FileIdentity.sha256(url)))
  }
  print("REAL_IPHONE_RESULT checks=\(checks) failures=\(failures)")
  if failures > 0 { exit(1) }
 }

}

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
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/RealIPhone", isDirectory: true)
  let copies = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let names = CommandLine.arguments.count > 2 ? Array(CommandLine.arguments.dropFirst(2)) : ["IMG_0140.mov", "IMG_0047.mov", "IMG_9211.mov"]
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
   let consistency = TranscriptEvaluation.editCounts(reference: Array(TranscriptEvaluation.normalized(speechText, language: full.language)), hypothesis: Array(TranscriptEvaluation.normalized(skip.cues.map(\.text).joined(), language: full.language)))
   let refLen = max(1, TranscriptEvaluation.normalized(speechText, language: full.language).count)
   let evaluation = TranscriptEvaluation.evaluate(captions: skip.cues.map { EvaluatedCaption(text: $0.text, start: $0.start.seconds, end: $0.start.seconds + $0.duration.seconds) },
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
   print("  marker/lyric cues: full \(full.cues.filter { isMarker($0.text) }.count) → skip \(skip.cues.filter { isMarker($0.text) }.count) · cues over non-speech: full \(silentFull.count) → skip \(silentSkip.count) · evaluation: \(evaluation.reason ?? evaluation.status.rawValue)")
   cpu0 = 0
   try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
  }
  print("REAL07_DONE videos=\(records.count)")
 }
}

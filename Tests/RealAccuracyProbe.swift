import Foundation
import AVFoundation
@testable import JHCutCore

/// Real-video accuracy against a HUMAN transcript of a short segment of a read-only copy.
/// Without `<segment>.reference.srt|txt` it prepares a listening clip and a Whisper draft and
/// reports “평가 불가”. With a reference it scores full recognition and non-speech skipping.
@main struct RealAccuracyProbe {
 static func main() async throws {
  setbuf(stdout, nil)
  let args = Array(CommandLine.arguments.dropFirst())
  let root = URL(fileURLWithPath: args.first ?? "Artifacts/Upgrade-0.7/Accuracy", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let specs = args.count > 1 ? Array(args.dropFirst()) : ["IMG_0047.mov:660:780", "IMG_9211.mov:480:600"]
  var summary: [[String: Any]] = []
  for spec in specs {
   let parts = spec.split(separator: ":").map(String.init)
   guard parts.count == 3, let start = Double(parts[1]), let end = Double(parts[2]), end > start else { print("잘못된 구간: \(spec)"); continue }
   let url = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/\(parts[0])")
   let tag = "\(URL(fileURLWithPath: parts[0]).deletingPathExtension().lastPathComponent)-\(Int(start))-\(Int(end))"
   let base = root.appendingPathComponent(tag)
   print("== \(tag)")
   // Listening clip for the transcriber (audio only, from the copy).
   let listen = base.appendingPathExtension("listen.m4a")
   if !FileManager.default.fileExists(atPath: listen.path) {
    let asset = AVURLAsset(url: url)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw ProjectError("export") }
    export.outputURL = listen; export.outputFileType = .m4a
    export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    await export.export()
    guard export.status == .completed else { throw export.error ?? ProjectError("listen clip") }
   }
   var options = SpeechOptions(); options.language = "ko"
   let duration = MediaTime(seconds: end - start)
   let full = try await LocalTranscription.transcribeLong(url: url, sourceStart: MediaTime(seconds: start), duration: duration, options: options, windowSeconds: 300)
   let vad = try await VoiceActivity.analyze(url: url, sourceStart: MediaTime(seconds: start), duration: duration)
   let skip = try await LocalTranscription.transcribeLong(url: url, sourceStart: MediaTime(seconds: start), duration: duration, options: options, windowSeconds: 300, speechRegions: vad.speechRegions, speechEvidence: vad.confidentSpeech)
   try SRTCodec.serialize(full.cues).write(to: base.appendingPathExtension("whisper-full.srt"), atomically: true, encoding: .utf8)
   try SRTCodec.serialize(skip.cues).write(to: base.appendingPathExtension("whisper-skip.srt"), atomically: true, encoding: .utf8)
   // Draft for correction. Times are SOURCE times of the whole video, as the reference must be.
   let draft = base.appendingPathExtension("draft-from-whisper.srt")
   if !FileManager.default.fileExists(atPath: draft.path) { try SRTCodec.serialize(full.cues).write(to: draft, atomically: true, encoding: .utf8) }

   let referenceURL = ["srt", "txt"].map { base.appendingPathExtension("reference.\($0)") }.first { FileManager.default.fileExists(atPath: $0.path) }
   var record: [String: Any] = ["segment": tag, "start": start, "end": end, "speechSeconds": vad.seconds(of: .speech), "fullCues": full.cues.count, "skipCues": skip.cues.count]
   guard let referenceURL else {
    print("  평가 불가 · 사람이 만든 대본이 없습니다. \(listen.lastPathComponent)을 듣고 \(base.lastPathComponent).reference.srt(또는 .txt)를 만드세요.")
    record["status"] = "unscored: no human reference"; summary.append(record); continue
   }
   let reference = try TranscriptReference.load(referenceURL)
   // A reference that is still the machine draft would score Whisper against itself.
   let draftCues = try SRTCodec.parse(String(contentsOf: draft, encoding: .utf8))
   let refChars = TranscriptEvaluation.characters(reference.units.map(\.text).joined(separator: " "), language: "ko")
   let draftChars = TranscriptEvaluation.characters(draftCues.map(\.text).joined(separator: " "), language: "ko")
   let edits = TranscriptEvaluation.editCounts(reference: refChars, hypothesis: draftChars)
   let changed = Double(edits.substitutions + edits.deletions + edits.insertions) / Double(max(1, refChars.count))
   record["referenceChangedFromDraft"] = changed
   if changed == 0 {
    print("  평가 거부 · 대본이 Whisper 초안과 똑같습니다. 직접 듣고 고친 대본이어야 합니다.")
    record["status"] = "refused: reference identical to machine draft"; summary.append(record); continue
   }
   if changed < 0.02 { print(String(format: "  주의 · 대본이 초안과 %.1f%%만 다릅니다. 초안을 그대로 받아들인 부분은 오류가 과소평가될 수 있습니다.", changed * 100)) }
   for (mode, result) in [("full", full), ("skip", skip)] {
    let captions = result.cues.filter { $0.start.seconds < end && $0.start.seconds + $0.duration.seconds > start }
     .map { EvaluatedCaption(text: $0.text, start: $0.start.seconds, end: $0.start.seconds + $0.duration.seconds) }
    let report = TranscriptEvaluation.evaluate(captions: captions, reference: reference, language: "ko", sourceRange: start...end, mediaDuration: end - start)
    _ = try TranscriptEvaluation.write(report, title: "\(tag) · \(mode == "full" ? "전체 인식" : "비음성 건너뛰기")", to: root, name: "\(tag).evaluation-\(mode)")
    let line = report.status == .scored
     ? String(format: "CER %.1f%% · WER %.1f%% · 누락 문장 %d · 추가 문장 %d · 일치 %d/%d", (report.cer ?? 0) * 100, (report.wer ?? 0) * 100, report.missing.count, report.extra.count, report.matchedSentences, report.referenceSentences)
     : "평가 불가 · \(report.reason ?? "")"
    print("  \(mode): \(line)")
    record[mode] = ["status": report.status.rawValue, "cer": report.cer ?? NSNull(), "wer": report.wer ?? NSNull(), "missing": report.missing.count, "extra": report.extra.count,
                    "matched": report.matchedSentences, "referenceSentences": report.referenceSentences,
                    "startErrorMedian": report.timing?.medianAbsoluteStart ?? NSNull()]
   }
   summary.append(record)
  }
  try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("summary.json"))
  print("ACCURACY_DONE segments=\(summary.count) scored=\(summary.filter { $0["full"] != nil }.count)")
 }
}

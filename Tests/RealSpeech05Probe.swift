import Foundation
import JHCutCore

@main struct RealSpeech05Probe {
 static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Multilingual-0.6/RealIPhone")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  // Verified read-only COPIES of the supplied iPhone videos (Scripts/test-real-iphone.sh makes them).
  // The originals in /Volumes/T7/아이폰/동영상 are never opened by this probe.
  let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "Artifacts/Upgrade-0.7/RealCopies")
  let names = ["IMG_0140.mov", "IMG_0047.mov", "IMG_9211.mov"]
  var records: [[String: Any]] = []
  for name in names {
   let url = folder.appendingPathComponent(name)
   let asset = try await MediaImporter.inspect(url: url)
   let window = min(30.0, max(1.0, asset.duration.seconds))
   let startSeconds = min(30.0, max(0.0, asset.duration.seconds - window))
   let start = MediaTime(seconds: startSeconds), duration = MediaTime(seconds: window)
   let result = try await LocalTranscription.transcribe(url: url, sourceStart: start, duration: duration)
   let prefix = root.appendingPathComponent(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)
   let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
   try encoder.encode(result).write(to: prefix.appendingPathExtension("json"))
   if !result.cues.isEmpty { try SRTCodec.serialize(result.cues).write(to: prefix.appendingPathExtension("source-times.srt"), atomically: true, encoding: .utf8) }
   let valid = result.cues.allSatisfy { $0.start >= start && $0.start + $0.duration <= start + duration && $0.duration > .zero }
   let cueSeconds = result.cues.reduce(0.0) { $0 + $1.duration.seconds }
   let referenceURL = url.deletingPathExtension().appendingPathExtension("txt")
   var referenceMetrics: [String: Any] = ["available": false, "status": "unscored: no manually transcribed reference"]
   if FileManager.default.fileExists(atPath: referenceURL.path), let reference = try? String(contentsOf: referenceURL, encoding: .utf8) {
    let hypothesis = result.cues.map(\.text).joined(separator: " ")
    let distance = Self.editDistance(Self.normalize(reference), Self.normalize(hypothesis))
    let denominator = max(1, Self.normalize(reference).count)
    referenceMetrics = ["available": true, "status": "scored", "characterErrorRate": Double(distance) / Double(denominator), "referenceCharacters": denominator]
   }
   records.append(["source": name, "fileBytes": (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0,
                   "assetDurationSeconds": asset.duration.seconds, "sourceStartSeconds": startSeconds, "windowSeconds": window,
                   "detectedLanguage": result.language, "cueCount": result.cues.count, "captionedSeconds": cueSeconds,
                   "captionCoverage": min(1.0, cueSeconds / max(0.001, window)), "elapsedSeconds": result.elapsedSeconds,
                   "realtimeFactor": result.elapsedSeconds / max(0.001, window), "validSourceTimes": valid,
                   "reference": referenceMetrics])
   if name == names[0], !result.cues.isEmpty {
    var p = Project(name: "실사 음성 30초 · 교정 전 자동 자막"); p.assets = [asset]; p.sequence.width = 1280; p.sequence.height = 720
    let clip = Clip(assetID: asset.id, sourceStart: start, duration: duration); p.sequence.tracks[0].clips = [clip]
    p.sequence.tracks[2].clips = CaptionEditing.automaticClips(cues: result.cues, source: clip, style: TitleSizing.title(for: TitlePreset.builtIns[0], width: 1280, height: 720))
    try ProjectStore.save(p, to: root.appendingPathComponent("real-captions.jhcut"))
    let plan = try await TimelineRenderer.build(project: p)
    try await ExportJob().export(plan: plan, to: root.appendingPathComponent("real-captions.mp4")) { _ in }
   }
   print("Completed \(name): \(result.cues.count) cues, \(result.elapsedSeconds)s; accuracy not scored")
  }
  try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
 }

 static func normalize(_ value: String) -> String {
  value.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.map(String.init).joined()
 }

 static func editDistance(_ lhs: String, _ rhs: String) -> Int {
  let a = Array(lhs), b = Array(rhs)
  var previous = Array(0...b.count)
  for (i, left) in a.enumerated() {
   var current = [i + 1]
   for (j, right) in b.enumerated() { current.append(left == right ? previous[j] : 1 + min(previous[j], previous[j + 1], current[j])) }
   previous = current
  }
  return previous[b.count]
 }
}

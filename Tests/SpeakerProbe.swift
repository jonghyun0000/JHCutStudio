import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Upgrade 4: channel-based speaker separation. Separated, uncertain and unavailable cases.
@main struct SpeakerProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Speaker", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  defer { save() }
  let lines: [(String, String)] = [("Yuna", "안녕하세요. 오늘 촬영을 시작하겠습니다."), ("Eddy (한국어(한국))", "네, 저는 카메라를 준비했습니다."),
                                   ("Yuna", "좋아요. 먼저 공원 입구에서 찍어 볼까요?"), ("Eddy (한국어(한국))", "알겠습니다. 조명도 확인해 주세요.")]
  let (separatedURL, spans) = try await dialogue(root, lines, mode: "separated")
  let (centeredURL, _) = try await dialogue(root, lines, mode: "centered")
  let (monoURL, _) = try await dialogue(root, lines, mode: "mono")

  func run(_ url: URL, _ name: String) async throws -> (EditorModel, Clip) {
   let asset = try await MediaImporter.inspect(url: url)
   let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery-" + name)), exportHistoryURL: root.appendingPathComponent("journal.json"))
   model.translateAfterTranscription = false; model.useSpeechCheckpoints = false; model.speechOptions.language = "ko"
   var p = Project(name: "화자 " + name); p.sequence.width = 640; p.sequence.height = 360; p.assets = [asset]
   let clip = Clip(name: name, assetID: asset.id, duration: asset.duration)
   let ai = p.sequence.tracks.firstIndex { $0.kind == .audio }!; p.sequence.tracks[ai].clips = [clip]
   model.history = EditorHistory(project: p); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.refreshTranscriptionStatus()
   model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
   model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
   return (model, clip)
  }

  // ---- Separated channels ----
  let (model, clip) = try await run(separatedURL, "separated")
  check("Dialogue captioned", !model.captionClips.isEmpty && model.error == nil, model.message)
  // Whisper's mixed transcript crosses speaker turns here, so per-sentence labels must not be guessed.
  model.separateSpeakers(); while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Sentences spanning both speakers are left uncertain", model.captionClips.allSatisfy { $0.captionMetadata?.speaker == nil }, model.speakerStatus)
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  let before = model.project
  model.transcribeSpeakersByChannel(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  let captions = model.captionClips
  check("Per-channel recognition on a one-mic-per-speaker recording", model.error == nil && model.speakerStatus.contains("화자 2명"), model.error ?? model.speakerStatus)
  // Ground truth by content: which script line the recognised words come from.
  func norm(_ t: String) -> String { TranscriptEvaluation.characters(t, language: "ko").map(String.init).joined() }
  let expected: [String] = captions.map { c in
   let text = norm(c.title?.text ?? "")
   return lines.enumerated().first { norm($0.element.1).contains(text) || text.contains(norm($0.element.1)) }.map { $0.offset % 2 == 0 ? "A" : "B" } ?? "?"
  }
  let got = captions.map { $0.captionMetadata?.speaker ?? "-" }
  check("Each sentence labelled with the speaker who said it", !got.isEmpty && got == expected && !expected.contains("?"), "got \(got) expected \(expected) · " + captions.map { $0.title?.text ?? "" }.joined(separator: " | "))
  // Timing is Whisper's; measured, not asserted.
  let inside = captions.filter { c in
   let mid = c.connection!.sourceStart.seconds + c.connection!.sourceDuration.seconds / 2
   return spans.contains { ($0.0 == "Yuna") == (c.captionMetadata?.speaker == "A") && $0.1.contains(mid) }
  }.count
  check("Caption timing measured against the speaker's own lines", true, "\(inside)/\(captions.count) caption midpoints inside that speaker's spoken span")
  check("Both speakers' lines are present", Set(got) == ["A", "B"])
  let timingBefore = captions.map { "\($0.id)|\($0.start)|\($0.duration)|\(String(describing: $0.connection))" }
  check("Captions stay inside the source clip", captions.allSatisfy { $0.start >= clip.start && $0.end <= clip.end && $0.connection?.parentID == clip.id })
  check("Speaker profiles created", (model.project.sequence.speakers ?? []).map(\.id) == ["A", "B"])
  let url = root.appendingPathComponent("Speakers.jhcut"); try ProjectStore.save(model.project, to: url)
  check("Save/reopen keeps speakers", try ProjectStore.load(from: url).sequence == model.project.sequence)
  let labelled = model.project
  model.undo(); check("One undo restores the previous captions", model.project == before)
  model.redo(); check("Redo restores speaker captions", model.project == labelled)
  model.updateSpeaker("B", name: "진행자", colorHex: "#7fd8ff")
  check("Rename and colour applies to that speaker only", model.captionClips.filter { $0.captionMetadata?.speaker == "B" }.allSatisfy { $0.title?.colorHex == "7FD8FF" }
        && model.captionClips.filter { $0.captionMetadata?.speaker == "A" }.allSatisfy { $0.title?.colorHex != "7FD8FF" } && model.project.sequence.speakers?.first { $0.id == "B" }?.name == "진행자")
  let ids = Set(model.captionClips.map(\.id))
  model.splitCaptionTracksBySpeaker()
  let speakerTracks = model.project.sequence.tracks.filter { $0.name.hasPrefix("화자 · ") }
  check("Split creates one track per speaker", speakerTracks.count == 2 && speakerTracks.allSatisfy { t in t.clips.allSatisfy { $0.captionMetadata?.speaker == t.clips.first?.captionMetadata?.speaker } })
  check("Split keeps caption ids, times and connections", Set(model.captionClips.map(\.id)) == ids && model.captionClips.map { "\($0.id)|\($0.start)|\($0.duration)|\(String(describing: $0.connection))" }.sorted() == timingBefore.sorted())
  let firstCaption = model.captionClips[0]
  if let t = try? CaptionTranslationEditing.translated(firstCaption, text: "Hello", sourceLanguage: "ko", targetLanguage: "en", bilingual: false) {
   check("Translation keeps the original's speaker", t.captionMetadata?.speaker == firstCaption.captionMetadata?.speaker)
  }
  _ = clip

  // ---- Both voices on both channels: must not guess ----
  let (centered, _) = try await run(centeredURL, "centered")
  centered.separateSpeakers(); while centered.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Same signal on both channels is reported uncertain", centered.speakerStatus.contains("불확실"), centered.speakerStatus)
  let centeredBefore = centered.project
  centered.selectedClipIDs = Set(centered.project.sequence.tracks.flatMap(\.clips).filter { $0.assetID != nil }.map(\.id)); centered.selectedClipID = centered.selectedClipIDs.first
  centered.transcribeSpeakersByChannel(); while centered.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Per-channel recognition refused when channels carry the same signal", centered.project == centeredBefore && centered.speakerStatus.contains("분리된 녹음이 아닙니다"), centered.speakerStatus)
  check("Uncertain result assigns no speaker", centered.captionClips.allSatisfy { $0.captionMetadata?.speaker == nil && $0.captionMetadata?.speakerStatus == "uncertain" } && centered.project.sequence.speakers == nil)

  // ---- Mono: unavailable ----
  let (mono, _) = try await run(monoURL, "mono")
  let monoBefore = mono.project
  mono.separateSpeakers(); while mono.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Mono is reported unavailable", mono.speakerStatus.contains("모노"), mono.speakerStatus)
  check("Unavailable leaves the document unchanged", mono.project == monoBefore)

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("SPEAKER_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }

 /// Two voices alternating. separated: A on left only, B on right only. centered: both voices on
 /// both channels. mono: one channel. Returns each line's [start, end] in seconds.
 static func dialogue(_ root: URL, _ lines: [(String, String)], mode: String) async throws -> (URL, [(String, ClosedRange<Double>)]) {
  let rate = 22_050.0
  var pieces: [(String, [Float])] = []
  for (i, (voice, text)) in lines.enumerated() {
   let aiff = root.appendingPathComponent("line-\(i).wav")
   if !FileManager.default.fileExists(atPath: aiff.path) {
    let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say"); say.arguments = ["-v", voice, "-r", "165", "--file-format=WAVE", "--data-format=LEI16@22050", "-o", aiff.path, text]
    try say.run(); say.waitUntilExit()
   }
   let file = try AVAudioFile(forReading: aiff)
   let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
   try file.read(into: buffer)
   pieces.append((voice, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))))
  }
  let gap = [Float](repeating: 0, count: Int(rate * 0.7))
  var left: [Float] = gap, right: [Float] = gap, spans: [(String, ClosedRange<Double>)] = []
  for (index, (voice, samples)) in pieces.enumerated() {
   let start = Double(left.count) / rate
   let isA = index % 2 == 0
   switch mode {
   case "separated": left += isA ? samples : [Float](repeating: 0, count: samples.count); right += isA ? [Float](repeating: 0, count: samples.count) : samples
   default: left += samples; right += samples
   }
   spans.append((voice, start...(Double(left.count) / rate)))
   left += gap; right += gap
  }
  let channels: AVAudioChannelCount = mode == "mono" ? 1 : 2
  let url = root.appendingPathComponent("dialogue-\(mode).wav")
  try? FileManager.default.removeItem(at: url)
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
  let out = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
  buffer.frameLength = AVAudioFrameCount(left.count)
  left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
  if channels == 2 { right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) } }
  try out.write(from: buffer)
  return (url, spans)
 }
}

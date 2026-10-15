import Foundation
import AppKit
import AVFoundation
import JHCutCore
import Darwin

/// Upgrade 4: channel-based speaker separation. Separated, uncertain and unavailable cases.
@main struct SpeakerProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/Speaker")
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
   model.checkpointStore = TranscriptionCheckpointStore(root: root.appendingPathComponent("Checkpoints-" + name)); model.translateAfterTranscription = false; model.useSpeechCheckpoints = false; model.speechOptions.language = "auto"
   var p = Project(name: "화자 " + name); p.sequence.width = 640; p.sequence.height = 360; p.assets = [asset]
   let clip = Clip(name: name, assetID: asset.id, duration: asset.duration)
   let ai = p.sequence.tracks.firstIndex { $0.kind == .audio }!; p.sequence.tracks[ai].clips = [clip]
   model.history = EditorHistory(project: p); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.channelSpeakerMappingConfirmed = true; model.refreshTranscriptionStatus()
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
  model.speechOptions.language = "ko"; model.useSpeechCheckpoints = true
  model.transcribeSpeakersByChannel(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  let captions = model.captionClips
  check("Per-channel recognition on a one-mic-per-speaker recording", model.error == nil && model.speakerStatus.contains("화자 후보 2개"), model.error ?? model.speakerStatus)
  let channelCheckpoints = model.checkpointStore.summaries(projectID:model.project.id)
  check("Actual channel recognition writes isolated per-channel checkpoints", channelCheckpoints.count == 2 && channelCheckpoints.allSatisfy { $0.completedWindows > 0 })
  // Ground truth by content: which script line the recognised words come from.
  func norm(_ t: String) -> String { TranscriptEvaluation.characters(t, language: "ko").map(String.init).joined() }
  let expected: [String] = captions.map { c in
   let text = norm(c.title?.text ?? "")
   return lines.enumerated().first { norm($0.element.1).contains(text) || text.contains(norm($0.element.1)) }.map { $0.offset % 2 == 0 ? "A" : "B" } ?? "?"
  }
  let aID = SpeakerIdentity.channel(sourceID: clip.assetID!, index: 0), bID = SpeakerIdentity.channel(sourceID: clip.assetID!, index: 1)
  let got = captions.map { c in c.captionMetadata?.speaker.flatMap(SpeakerIdentity.channelIndex).map { SpeakerSeparation.label(for: $0) } ?? "-" }
  check("Each sentence labelled with the speaker who said it", !got.isEmpty && got == expected && !expected.contains("?"), "got \(got) expected \(expected) · " + captions.map { $0.title?.text ?? "" }.joined(separator: " | "))
  // Timing is Whisper's; measured, not asserted.
  let inside = captions.filter { c in
   let mid = c.connection!.sourceStart.seconds + c.connection!.sourceDuration.seconds / 2
   return spans.contains { ($0.0 == "Yuna") == (c.captionMetadata?.speaker == aID) && $0.1.contains(mid) }
  }.count
  let matches = captions.compactMap { c -> (Double, Double, Double)? in
   guard let link = c.connection else { return nil }
   let a = link.sourceStart.seconds, b = a + link.sourceDuration.seconds
   let own = spans.filter { ($0.0 == "Yuna") == (c.captionMetadata?.speaker == aID) }
   guard let span = own.max(by: { x, y in max(0,min(b,x.1.upperBound)-max(a,x.1.lowerBound)) < max(0,min(b,y.1.upperBound)-max(a,y.1.lowerBound)) })?.1 else { return nil }
   let intersection = max(0,min(b,span.upperBound)-max(a,span.lowerBound)), union = max(b,span.upperBound)-min(a,span.lowerBound)
   return (intersection / max(union,0.0001), abs(a-span.lowerBound), abs(b-span.upperBound))
  }
  // Sentence fragments are measured individually above; compare utterance coverage by the
  // union of fragments belonging to each known script line, rather than grading a short word
  // against an entire utterance's boundaries.
  let utterances = spans.enumerated().compactMap { index, span -> (Double, Double, Double)? in
   let matching = captions.filter { c in
    let text = norm(c.title?.text ?? "")
    return !text.isEmpty && norm(lines[index].1).contains(text) && c.captionMetadata?.speaker == (index % 2 == 0 ? aID : bID)
   }
   guard let a = matching.compactMap({ $0.connection?.sourceStart.seconds }).min(), let b = matching.compactMap({ c in c.connection.map { ($0.sourceStart + $0.sourceDuration).seconds } }).max() else { return nil }
   let intersection = max(0,min(b,span.1.upperBound)-max(a,span.1.lowerBound)), union = max(b,span.1.upperBound)-min(a,span.1.lowerBound)
   return (intersection / max(union,0.0001), abs(a-span.1.lowerBound), abs(b-span.1.upperBound))
  }
  let meanIoU = utterances.map { $0.0 }.reduce(0,+)/Double(max(1,utterances.count))
  let startMAE = utterances.map { $0.1 }.reduce(0,+)/Double(max(1,utterances.count)), endMAE = utterances.map { $0.2 }.reduce(0,+)/Double(max(1,utterances.count))
  let midpointShare = Double(inside)/Double(max(1,captions.count)), unknown = got.filter { $0 == "-" }.count
  let confusion = zip(got,expected).filter { $0 != $1 }.count
  let timingAccepted = utterances.count == spans.count && !captions.isEmpty && midpointShare >= 0.75 && meanIoU >= 0.4 && startMAE <= 1.5 && endMAE <= 1.5 && unknown == 0 && confusion == 0
  let measurement: [String:Any] = ["reference":"known scheduled synthetic TTS; not a human reference", "captionCount":captions.count,"midpointInsideShare":midpointShare,"utteranceCount":utterances.count,"utteranceUnionMeanIoU":meanIoU,"fragmentMeanIoU":matches.map {$0.0}.reduce(0,+)/Double(max(1,matches.count)),"startMAESeconds":startMAE,"endMAESeconds":endMAE,"speakerConfusionCount":confusion,"unknownCount":unknown,"referenceOverlapCount":0,"accepted":timingAccepted,"criteria":["midpointShareMin":0.75,"meanIoUMin":0.4,"startMAEMaxSeconds":1.5,"endMAEMaxSeconds":1.5,"confusionMax":0,"unknownMax":0]]
  try JSONSerialization.data(withJSONObject:measurement,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("timing-measurement.json"))
  print("MEASUREMENT speaker timing IoU=\(meanIoU) startMAE=\(startMAE) endMAE=\(endMAE) inside=\(midpointShare)")
  check("Synthetic timing meets declared regression thresholds", timingAccepted)
  check("Both speakers' lines are present", Set(got) == ["A", "B"])
  let checkpointTimes = channelCheckpoints.map { model.checkpointStore.directory(for:$0.key).appendingPathComponent("window-00000.json") }
  let oldCheckpointBytes = try checkpointTimes.map { try Data(contentsOf:$0) }
  let beforeReplay = model.project
  model.transcribeSpeakersByChannel(); while model.productivityBusy { try await Task.sleep(nanoseconds:50_000_000) }
  check("Actual channel checkpoint replay preserves manual-language captions without duplicates", model.project == beforeReplay && model.captionClips.count == captions.count)
  check("Replay leaves completed channel window bytes unchanged", try checkpointTimes.map { try Data(contentsOf:$0) } == oldCheckpointBytes)
  let timingBefore = captions.map { "\($0.id)|\($0.start)|\($0.duration)|\(String(describing: $0.connection))" }
  check("Captions stay inside the source clip", captions.allSatisfy { $0.start >= clip.start && $0.end <= clip.end && $0.connection?.parentID == clip.id })
  check("Speaker profiles created", (model.project.sequence.speakers ?? []).map(\.id) == [aID, bID])
  let url = root.appendingPathComponent("Speakers.jhcut"); try ProjectStore.save(model.project, to: url)
  check("Save/reopen keeps speakers", try ProjectStore.load(from: url).sequence == model.project.sequence)
  let labelled = model.project
  model.undo(); check("One undo restores the previous captions", model.project == before)
  model.redo(); check("Redo restores speaker captions", model.project == labelled)
  model.updateSpeaker(bID, name: "진행자", colorHex: "#7fd8ff")
  check("Rename and colour applies to that speaker only", model.captionClips.filter { $0.captionMetadata?.speaker == bID }.allSatisfy { $0.title?.colorHex == "7FD8FF" }
        && model.captionClips.filter { $0.captionMetadata?.speaker == aID }.allSatisfy { $0.title?.colorHex != "7FD8FF" } && model.project.sequence.speakers?.first { $0.id == bID }?.name == "진행자")
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

  // A real speech track beside synthetic tonal background music has independent energy, but
  // that is no evidence of two people. Do not silently label the music as a second person.
  let musicURL = root.appendingPathComponent("speech-plus-music.wav")
  try musicOverlay(monoURL, to:musicURL)
  let musicAsset = try await MediaImporter.inspect(url:musicURL)
  var musicProject = Project(name:"Speech and music"); musicProject.assets = [musicAsset]
  let musicClip = Clip(name:"Speech and music",assetID:musicAsset.id,duration:musicAsset.duration)
  musicProject.sequence.tracks.firstIndex(where: { $0.kind == .audio }).map { musicProject.sequence.tracks[$0].clips = [musicClip] }
  let musicModel = EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("MusicRecovery")),exportHistoryURL:root.appendingPathComponent("MusicJournal.json"))
  musicModel.history = EditorHistory(project:musicProject); musicModel.refreshTranscriptionStatus(); musicModel.selectedClipID = musicClip.id; musicModel.selectedClipIDs = [musicClip.id]
  let musicLayout = try await SpeakerSeparation.channelLayout(url:musicURL,sourceStart:.zero,duration:musicClip.duration)
  musicModel.transcribeSpeakersByChannel(); while musicModel.productivityBusy { try await Task.sleep(nanoseconds:20_000_000) }
  check("Speech beside independent tonal music does not imply two people", musicLayout.isSeparated && musicModel.project == musicProject && musicModel.speakerStatus.contains("불확실"))
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

 static func musicOverlay(_ speech: URL, to output: URL) throws {
  let file = try AVAudioFile(forReading:speech), rate = file.processingFormat.sampleRate
  let input = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!; try file.read(into:input)
  let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:2,interleaved:false)!
  let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:input.frameLength)!; buffer.frameLength = input.frameLength
  let energy = (0..<Int(input.frameLength)).reduce(0.0) { $0 + pow(Double(input.floatChannelData![0][$1]),2) }
  let amplitude = sqrt(energy / Double(input.frameLength) / 1.5)
  for i in 0..<Int(input.frameLength) {
   buffer.floatChannelData![0][i] = input.floatChannelData![0][i]
   let t = Double(i)/rate
   buffer.floatChannelData![1][i] = Float((sin(t*2*Double.pi*220)+sin(t*2*Double.pi*277.18)+sin(t*2*Double.pi*329.63))*amplitude)
  }
  var settings = format.settings; settings.removeValue(forKey:AVLinearPCMIsNonInterleaved)
  let writer = try AVAudioFile(forWriting:output,settings:settings); try writer.write(from:buffer)
 }

 /// A stalled system voice is a failed fixture, never a silently accepted partial WAV.
 /// Retry once after terminating only the child created here; keep every attempt as evidence.
 @MainActor static func synthesize(_ process: Process, to output: URL, root: URL, voice: String) async throws {
  var attempts: [[String:Any]] = []
  let log = root.appendingPathComponent("tts-attempts.json")
  if let data = try? Data(contentsOf:log), let previous = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] { attempts = previous }
  defer { try? JSONSerialization.data(withJSONObject:attempts,options:[.prettyPrinted,.sortedKeys]).write(to:log) }
  for attempt in 1...2 {
   let child = Process(); child.executableURL=process.executableURL; child.arguments=process.arguments
   defer { if child.isRunning { child.terminate(); kill(child.processIdentifier,SIGKILL) } }
   try? FileManager.default.removeItem(at:output)
   let begun = ProcessInfo.processInfo.systemUptime
   try child.run()
   while child.isRunning && ProcessInfo.processInfo.systemUptime-begun < 20 {
    try Task.checkCancellation(); try await Task.sleep(nanoseconds:50_000_000)
   }
   let timedOut = child.isRunning
   if timedOut {
    child.terminate(); try await Task.sleep(nanoseconds:100_000_000)
    if child.isRunning { kill(child.processIdentifier,SIGKILL) }
   }
   while child.isRunning { try await Task.sleep(nanoseconds:50_000_000) }
   let valid = !timedOut && child.terminationStatus == 0 && ((try? AVAudioFile(forReading:output).length) ?? 0) > 0
   attempts.append(["voice":voice,"file":output.lastPathComponent,"attempt":attempt,"elapsedSeconds":ProcessInfo.processInfo.systemUptime-begun,"timedOut":timedOut,"exitCode":child.terminationStatus,"accepted":valid])
   if valid { return }
  }
  throw ProjectError("System voice fixture failed within bounded retries: " + voice)
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
    try await synthesize(say, to:aiff, root:root, voice:voice)
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

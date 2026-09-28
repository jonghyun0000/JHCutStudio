import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Upgrade 7: voice activity candidates, skipping non-speech in recognition, captions over silence.
@main struct VoiceActivityProbe {
 struct Span { var kind: String; var start: Double; var end: Double }
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/VoiceActivity", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], metrics: [String: Any] = [:]
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() {
   try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
   try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("metrics.json"))
  }
  defer { save() }

  // ---- Compacted timeline mapping (pure) ----
  let t = CompactedTimeline(regions: [2...5, 10...12], recordingDuration: 20)
  check("Compaction joins pieces with short silence", t.pieces.count == 2 && abs(t.compactDuration - (3 + 0.6 + 2)) < 1e-9)
  check("Time inside a piece maps back", t.sourceRange(compactStart: 1, compactEnd: 2) == 3...4)
  check("Time in the second piece maps back", t.sourceRange(compactStart: 3.6, compactEnd: 4.6).map { abs($0.lowerBound - 10) < 1e-9 && abs($0.upperBound - 11) < 1e-9 } == true)
  check("Cue entirely inside a join is dropped", t.sourceRange(compactStart: 3.1, compactEnd: 3.5) == nil)
  let across = t.sourceRange(compactStart: 2.5, compactEnd: 4.0)!
  check("Cue across a join is not stretched over skipped audio", across.upperBound <= 5 && across.lowerBound >= 2, "\(across)")

  // ---- Fixture: speech / silence / music / noise ----
  let (media, spans) = try await fixture(root)
  let asset = try await MediaImporter.inspect(url: media)
  let digestBefore = try await FileIdentity.sha256(media)
  let speech = spans.filter { $0.kind == "speech" }
  print("fixture " + spans.map { "\($0.kind) \(String(format: "%.1f-%.1f", $0.start, $0.end))" }.joined(separator: ", "))

  let report = try await VoiceActivity.analyze(url: media, sourceStart: .zero, duration: asset.duration)
  print("segments " + report.segments.map { "\($0.kind.rawValue) \(String(format: "%.1f-%.1f %.2f", $0.start, $0.end, $0.confidence))" }.joined(separator: ", "))
  print("regions " + report.speechRegions.map { String(format: "%.1f-%.1f", $0.lowerBound, $0.upperBound) }.joined(separator: ", "))
  func share(_ span: Span, _ kind: VoiceActivityKind) -> Double {
   report.segments.filter { $0.kind == kind }.reduce(0) { $0 + max(0, min($1.end, span.end) - max($1.start, span.start)) } / (span.end - span.start)
  }
  check("Classifier available (built into macOS)", report.classifierAvailable)
  // Spans shorter than the 3 s skip minimum are pauses between sentences; only longer ones are scored.
  for span in spans where span.kind != "speech" && span.kind != "pad" && span.end - span.start >= 5 {
   let kind = VoiceActivityKind(rawValue: span.kind)!
   let s = share(span, kind)
   metrics["\(span.kind)_labelled_share"] = s
   check("\(kind.label) span recognised", s >= 0.7, String(format: "%.0f%% labelled %@", s * 100, kind.label))
  }
  let speechLabelled = speech.map { share($0, .speech) + share($0, .uncertain) }
  check("Every voiced sentence (incl. the last, cut off by the audio track end) labelled speech", speechLabelled.allSatisfy { $0 >= 0.9 },
        speechLabelled.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " "))
  let covered = speech.allSatisfy { span in report.speechRegions.contains { $0.lowerBound <= span.start && $0.upperBound >= span.end } }
  check("Every spoken sentence stays inside the regions sent to Whisper", covered)
  metrics["skippable_share"] = report.skippableShare; metrics["analysis_seconds"] = report.analysisSeconds; metrics["media_seconds"] = asset.duration.seconds
  check("Non-speech share is skipped", report.skippableShare > 0.3, String(format: "%.0f%% skippable · analysis %.2fs for %.0fs", report.skippableShare * 100, report.analysisSeconds, asset.duration.seconds))
  let again = try await VoiceActivity.analyze(url: media, sourceStart: .zero, duration: asset.duration)
  check("Analysis is repeatable", again.segments == report.segments && again.speechRegions == report.speechRegions)
  let energy = try await VoiceActivity.analyze(url: media, sourceStart: .zero, duration: asset.duration, useClassifier: false)
  check("Energy-only fallback: silence only, speech never skipped", !energy.classifierAvailable && energy.seconds(of: .music) == 0 && energy.seconds(of: .noise) == 0
        && speech.allSatisfy { span in energy.speechRegions.contains { $0.lowerBound <= span.start && $0.upperBound >= span.end } } && energy.seconds(of: .silence) > 10)
  let partial = try await VoiceActivity.analyze(url: media, sourceStart: MediaTime(seconds: 10), duration: MediaTime(seconds: 20))
  check("Sub-range analysis reports absolute source times", partial.segments.first.map { abs($0.start - 10) < 0.01 } == true && partial.segments.last.map { abs($0.end - 30) < 0.01 } == true)

  // Captions over silence
  let silence = spans.first { $0.kind == "silence" }!
  let warnings = VoiceActivity.silentCaptions([speech[0].start...speech[0].end, (silence.start + 1)...(silence.start + 3)], report: report)
  check("Caption over silence is flagged, spoken caption is not", warnings.count == 1 && warnings[0].index == 1 && warnings[0].kind == .silence)

  // ---- Recognition with and without skipping ----
  var options = SpeechOptions(); options.language = "ko"
  let config = WhisperConfiguration()
  let plainStart = Date()
  let plain = try await LocalTranscription.transcribeLong(url: media, duration: asset.duration, configuration: config, options: options, windowSeconds: 300, speechRegions: nil)
  let plainSeconds = Date().timeIntervalSince(plainStart)
  let skipStart = Date()
  let skipped = try await LocalTranscription.transcribeLong(url: media, duration: asset.duration, configuration: config, options: options, windowSeconds: 300, speechRegions: report.speechRegions)
  let skipSeconds = Date().timeIntervalSince(skipStart)
  func overlapsSpeech(_ cue: CaptionCue) -> Bool { speech.contains { $0.start < cue.start.seconds + cue.duration.seconds && $0.end > cue.start.seconds } }
  let plainOutside = plain.cues.filter { !overlapsSpeech($0) }, skipOutside = skipped.cues.filter { !overlapsSpeech($0) }
  metrics["whisper_seconds_full"] = plainSeconds; metrics["whisper_seconds_skipping"] = skipSeconds
  metrics["cues_full"] = plain.cues.count; metrics["cues_skipping"] = skipped.cues.count
  metrics["cues_outside_speech_full"] = plainOutside.map(\.text); metrics["cues_outside_speech_skipping"] = skipOutside.map(\.text)
  print("  full: " + plain.cues.map { "\(String(format: "%.1f", $0.start.seconds)) \($0.text)" }.joined(separator: " | "))
  print("  skip: " + skipped.cues.map { "\(String(format: "%.1f", $0.start.seconds)) \($0.text)" }.joined(separator: " | "))
  check("Skipping run captions every spoken sentence", speech.allSatisfy { span in skipped.cues.contains { $0.start.seconds < span.end && $0.start.seconds + $0.duration.seconds > span.start } })
  check("Skipping run has no captions outside speech", skipOutside.isEmpty, skipOutside.map(\.text).joined(separator: " / "))
  check("Recognition time measured with and without skipping", true, String(format: "full %.1fs (%d cues, %d outside speech) · skipping %.1fs (%d cues)", plainSeconds, plain.cues.count, plainOutside.count, skipSeconds, skipped.cues.count))
  let tight = VoiceActivity.tightened(skipped.cues, report: report)
  metrics["cues_tightened"] = tight.changed
  let strays = tight.cues.filter { cue in !speech.contains { cue.start.seconds >= $0.start - 1 && cue.start.seconds + cue.duration.seconds <= $0.end + 1.2 } }
  check("Cue times stay within their spoken sentence (after silence tightening)", strays.isEmpty, strays.map { String(format: "%.2f-%.2f %@", $0.start.seconds, $0.start.seconds + $0.duration.seconds, $0.text) }.joined(separator: " / "))

  // ---- Checkpoint keeps the analysis for resume ----
  let store = TranscriptionCheckpointStore(root: root.appendingPathComponent("Checkpoints", isDirectory: true))
  try? FileManager.default.removeItem(at: store.root)
  let key = TranscriptionCheckpointKey(projectID: UUID(), clipID: UUID(), mediaSHA256: digestBefore, sourceStart: .zero, duration: asset.duration, windowSeconds: 300,
                                       options: options, modelSHA256: config.modelSpec.sha256, skipsSilence: true)
  try store.saveVoiceActivity(report, for: key)
  check("Analysis saved with the checkpoint and read back", store.voiceActivity(for: key) == report)
  check("Folder with only an analysis is visible for deletion", store.summaries().contains { $0.key == key })
  _ = try store.removeAll(); check("Deleting checkpoints removes the analysis", store.voiceActivity(for: key) == nil)

  // ---- Editor integration ----
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.translateAfterTranscription = false; model.useSpeechCheckpoints = true; model.skipNonSpeech = true
  model.checkpointStore = TranscriptionCheckpointStore(root: root.appendingPathComponent("EditorCheckpoints", isDirectory: true))
  try? FileManager.default.removeItem(at: model.checkpointStore.root)
  var project = Project(name: "VAD"); project.sequence.width = 640; project.sequence.height = 360
  let clip = Clip(name: "구간 섞인 영상", assetID: asset.id, duration: asset.duration)
  project.assets = [asset]; project.sequence.tracks[0].clips = [clip]
  model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.refreshTranscriptionStatus()
  model.transcribeSelection(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  check("Editor recognition reports skipped non-speech", model.error == nil && model.message.contains("비음성") && !model.captionClips.isEmpty, model.error ?? model.message)
  check("Editor run stored the analysis in its checkpoint", model.checkpointStore.summaries().contains { $0.key.skipsSilence && model.checkpointStore.voiceActivity(for: $0.key) != nil })
  check("Generated captions are not flagged", model.silentCaptionWarnings.isEmpty)
  // A caption placed by hand over the music must be flagged by the check, without editing the document.
  let music = spans.first { $0.kind == "music" }!
  let titleTrack = model.project.sequence.tracks.first { $0.kind == .title && !$0.clips.isEmpty }!
  var manual = Clip(name: "수동 자막", start: MediaTime(seconds: music.start + 2), duration: MediaTime(seconds: 2), title: Title(text: "음악 위 자막"))
  manual.captionMetadata = CaptionMetadata(language: "ko", originalLanguage: "ko", originalText: "음악 위 자막", generatedText: "음악 위 자막")
  model.perform(.addClip(trackID: titleTrack.id, clip: manual))
  let beforeCheck = model.project
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.checkCaptionsAgainstVoiceActivity(); while model.productivityBusy { try await Task.sleep(nanoseconds: 50_000_000) }
  check("Caption over music flagged by the check", model.silentCaptionWarnings[manual.id] == .music, model.message)
  check("Check does not modify the document", model.project == beforeCheck)
  // Cancel during analysis.
  model.voiceActivityCache.removeAll()
  model.checkCaptionsAgainstVoiceActivity(); model.cancelProductivity(); while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Cancelled analysis leaves the document unchanged", model.project == beforeCheck && model.message.contains("취소"), model.message)

  // ---- Recogniser output robustness (both failures were seen on real iPhone videos) ----
  let parsed = SRTCodec.parseRecognizerOutput("1\n00:00:01,000 --> 00:00:02,000\n안녕하세요\n\n2\n00:00:02,000 --> 00:00:02,000\n반갑습니다\n\n3\n00:00:03,000 --> 00:00:04,000\n네\n")
  check("Zero-length recogniser cue folded into the previous one", parsed.cues.count == 2 && parsed.cues[0].text == "안녕하세요 반갑습니다" && parsed.repaired == 1)
  check("User SRT import stays strict", (try? SRTCodec.parse("1\n00:00:02,000 --> 00:00:02,000\n반갑습니다\n")) == nil)
  let fake = root.appendingPathComponent("fake-whisper.sh")
  // Writes a zero-length cue and a Hangul syllable cut in half (invalid UTF-8) into both outputs.
  try #"""
  #!/bin/bash
  while [[ $# -gt 0 ]]; do if [[ "$1" == "-of" ]]; then out="$2"; fi; shift; done
  printf '1\n00:00:00,500 --> 00:00:01,500\n\xec\x95\x88\xeb\x85\x95\n\n2\n00:00:01,500 --> 00:00:01,500\n\xed\x95\n\n3\n00:00:02,000 --> 00:00:03,000\n\xeb\x84\xa4\n' > "$out.srt"
  printf '{"result":{"language":"ko"},"transcription":[{"text":"\xed\x95"}]}' > "$out.json"
  """#.write(to: fake, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  let fakeConfig = WhisperConfiguration(runtimeURL: fake)
  do {
   let r = try await LocalTranscription.transcribe(url: media, sourceStart: .zero, duration: MediaTime(seconds: 5), configuration: fakeConfig, options: options)
   check("Invalid UTF-8 in recogniser output does not fail recognition", r.language == "ko" && r.cues.count == 2 && r.cues.allSatisfy { !$0.text.contains("\u{FFFD}") }, r.cues.map(\.text).joined(separator: " / "))
  } catch { check("Invalid UTF-8 in recogniser output does not fail recognition", false, "\(error)") }

  // ---- Repetition loop guard ----
  func cues(_ texts: [String]) -> [CaptionCue] { texts.enumerated().map { CaptionCue(start: MediaTime(seconds: Double($0.offset) * 2), duration: MediaTime(seconds: 1.5), text: $0.element) } }
  let loop = RepetitionGuard.collapsed(cues(["시작합니다", "호수에게 파는 거, 1, 2, 3.", "-호수에게 파는 거, 1, 2, 3.", "호수에게 파는 거 1 2 3", "호수에게 파는 거, 1, 2, 3.", "끝났습니다"]))
  check("Loop of one line collapsed to its first caption and flagged", loop.cues.map(\.text) == ["시작합니다", "호수에게 파는 거, 1, 2, 3.", "끝났습니다"] && loop.removed == 3 && loop.flagged == [2])
  check("Short interjection repeated 3 times is kept", RepetitionGuard.collapsed(cues(["어?", "어?", "어?"])).removed == 0 && RepetitionGuard.longestRun(cues(["어?", "어?", "어?"])) == 0)
  check("Short interjection repeated 6 times counts as a loop", RepetitionGuard.collapsed(cues(Array(repeating: "네", count: 6))).removed == 5)
  let alternating = RepetitionGuard.collapsed(cues(["첫 번째 문장입니다", "두 번째 문장입니다", "첫 번째 문장입니다", "두 번째 문장입니다", "첫 번째 문장입니다", "두 번째 문장입니다", "다른 말"]))
  check("Alternating loop collapsed to its first pair", alternating.cues.map(\.text) == ["첫 번째 문장입니다", "두 번째 문장입니다", "다른 말"], alternating.cues.map(\.text).joined(separator: "/"))
  let filler = RepetitionGuard.collapsed(cues(["버터 플라이인 것 같은데요", "-어?", "-어?", "-어?-어?", "-어?-어?-어?", "-어?-어?-어?", "-어?-어?-어?", "-어?", "네 저래요"]))
  check("Filler loop with varying repeats collapsed", filler.cues.map(\.text) == ["버터 플라이인 것 같은데요", "-어?", "네 저래요"], filler.cues.map(\.text).joined(separator: "/"))
  check("Distinct captions untouched", RepetitionGuard.collapsed(cues(["하나", "둘", "셋", "넷"])).removed == 0)
  let looping = root.appendingPathComponent("fake-whisper-loop.sh")
  try #"""
  #!/bin/bash
  mc=0; while [[ $# -gt 0 ]]; do if [[ "$1" == "-of" ]]; then out="$2"; fi; if [[ "$1" == "-mc" ]]; then mc=1; fi; shift; done
  if [[ $mc == 1 ]]; then
    printf '1\n00:00:00,500 --> 00:00:01,500\n첫 문장입니다\n\n2\n00:00:02,000 --> 00:00:03,000\n두 번째 문장입니다\n' > "$out.srt"
  else
    for i in 1 2 3 4 5; do printf "$i\n00:00:0$i,000 --> 00:00:0$i,800\n반복되는 잘못된 문장\n\n"; done > "$out.srt"
  fi
  printf '{"result":{"language":"ko"}}' > "$out.json"
  """#.write(to: looping, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: looping.path)
  let retried = try await LocalTranscription.transcribe(url: media, sourceStart: .zero, duration: MediaTime(seconds: 8), configuration: WhisperConfiguration(runtimeURL: looping), options: options)
  check("Loop triggers one retry without text conditioning; cleaner result kept", retried.repetitionRetried == true && retried.cues.map(\.text) == ["첫 문장입니다", "두 번째 문장입니다"] && retried.repeatedCuesRemoved == nil)

  // ---- Coverage repair: speech the main pass left without captions is recognised on its own ----
  func fakeWhisper(_ name: String, retryText: String) throws -> URL {
   let url = root.appendingPathComponent(name)
   try """
   #!/bin/bash
   while [[ $# -gt 0 ]]; do case "$1" in -of) out="$2";; -f) wav="$2";; esac; shift; done
   seconds=$(( ($(stat -f %z "$wav") - 44) / 32000 ))
   if [[ $seconds -gt 13 ]]; then printf '1\n00:00:00,000 --> 00:00:01,000\n[몇일이 없음]\n' > "$out.srt"
   else printf '1\n00:00:01,500 --> 00:00:04,500\n\(retryText)\n' > "$out.srt"; fi
   printf '{"result":{"language":"ko"}}' > "$out.json"
   """.write(to: url, atomically: true, encoding: .utf8)
   try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
   return url
  }
  let dropping = try fakeWhisper("fake-whisper-drop.sh", retryText: "복구된 대사입니다")
  let repaired = try await LocalTranscription.transcribeLong(url: media, sourceStart: MediaTime(seconds: 10), duration: MediaTime(seconds: 30), configuration: WhisperConfiguration(runtimeURL: dropping),
                                                         options: options, windowSeconds: 30, speechRegions: [12...20, 26...34])
  let recoveredCue = repaired.cues.first { $0.text == "복구된 대사입니다" }
  check("Speech left without captions is recognised again and recovered", repaired.recoveredCues == 2 && repaired.coverageRepairs == 2 && recoveredCue != nil,
        repaired.cues.map { String(format: "%.1f %@", $0.start.seconds, $0.text) }.joined(separator: " / "))
  // Regions are source seconds. Gap 26…34 → retry audio 24…36 (2 s context); its cue 1.5–4.5 s maps to 25.5–28.5 s and is trimmed to 26–28.5 s.
  check("A bracket line over recovered speech is replaced", !repaired.cues.contains { $0.text == "[몇일이 없음]" }, repaired.cues.map(\.text).joined(separator: " / "))
  check("Recovered captions stay inside the uncaptioned gap", repaired.cues.filter { $0.text == "복구된 대사입니다" }.allSatisfy { ($0.start.seconds >= 12 - 0.001 && $0.start.seconds + $0.duration.seconds <= 20.001) || ($0.start.seconds >= 26 - 0.001 && $0.start.seconds + $0.duration.seconds <= 34.001) }, repaired.cues.map { String(format: "%.2f-%.2f", $0.start.seconds, $0.start.seconds + $0.duration.seconds) }.joined(separator: " "))
  let bracketOnly = try fakeWhisper("fake-whisper-bracket.sh", retryText: "[음악]")
  let notRecovered = try await LocalTranscription.transcribeLong(url: media, sourceStart: MediaTime(seconds: 10), duration: MediaTime(seconds: 30), configuration: WhisperConfiguration(runtimeURL: bracketOnly),
                                                             options: options, windowSeconds: 30, speechRegions: [12...20, 26...34])
  check("Bracket-only retry output is not counted as recovered speech", notRecovered.recoveredCues == nil && !notRecovered.cues.contains { $0.text == "[음악]" })
  let noGap = CoverageRepair.uncovered(regions: [0...10], covered: [0...4, 5.5...10], limit: 30)
  check("Short pauses between captions are not retried", noGap.isEmpty)
  let gated = CoverageRepair.uncovered(regions: [0...30], covered: [0...2, 10...12, 20...22], limit: 30, evidence: [3...8, 13...14])
  check("Only gaps holding confident speech are retried", gated == [2...10], gated.map { "\($0)" }.joined(separator: ","))
  let full = try await LocalTranscription.transcribeLong(url: media, sourceStart: MediaTime(seconds: 10), duration: MediaTime(seconds: 30), configuration: WhisperConfiguration(runtimeURL: dropping), options: options)
  check("Full recognition (no skipping) is unchanged by coverage repair", full.coverageRepairs == nil && full.cues.count == 1)

  // A region that touches the next window by a few milliseconds must not fail the run (seen on a 30-minute recording).
  do {
   let touching = try await LocalTranscription.transcribeLong(url: media, duration: MediaTime(seconds: 45), configuration: WhisperConfiguration(runtimeURL: looping), options: options,
                                                               windowSeconds: 30, speechRegions: [2...10, 25...30.004])
   check("Window touched by a region for 4 ms is skipped, not failed", touching.skippedWindows == 1 && touching.computedWindows == 1)
  } catch { check("Window touched by a region for 4 ms is skipped, not failed", false, "\(error)") }

  check("Source media never modified", try await FileIdentity.sha256(media) == digestBefore)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("VAD_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }

 static func voicedExtent(_ url: URL) throws -> (Double, Double) {
  let f = try AVAudioFile(forReading: url), rate = f.processingFormat.sampleRate
  let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
  try f.read(into: b)
  let x = b.floatChannelData![0], n = Int(b.frameLength), block = Int(rate * 0.02)
  var first: Int?, last = 0
  for start in stride(from: 0, to: n, by: block) {
   var e: Float = 0; let end = min(n, start + block); for i in start..<end { e += x[i] * x[i] }
   if 10 * log10(max(1e-12, e / Float(end - start))) > -50 { if first == nil { first = start }; last = end }
  }
  return (Double(first ?? 0) / rate, Double(last) / rate)
 }
 /// speech, 8 s silence, speech, 12 s bundled music, speech, 8 s white noise, speech over quiet BGM, speech, 6 s silence.
 @MainActor static func fixture(_ root: URL) async throws -> (URL, [Span]) {
  let output = root.appendingPathComponent("vad-fixture.mp4"), spansURL = root.appendingPathComponent("vad-fixture.json")
  if FileManager.default.fileExists(atPath: output.path), let data = try? Data(contentsOf: spansURL),
     let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
   return (output, raw.map { Span(kind: $0["kind"] as! String, start: $0["start"] as! Double, end: $0["end"] as! Double) })
  }
  var p = Project(name: "vad"); p.sequence.width = 640; p.sequence.height = 360
  let ti = p.sequence.tracks.firstIndex { $0.kind == .audio }!
  var spans: [Span] = [], at = 0.5
  func speech(_ i: Int, _ text: String) async throws {
   let file = root.appendingPathComponent("vad-speech-\(i).wav")
   let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
   say.arguments = ["-v", "Yuna", "-r", "165", "--file-format=WAVE", "--data-format=LEI16@22050", "-o", file.path, text]
   try say.run(); say.waitUntilExit()
   let a = try await MediaImporter.inspect(url: file); p.assets.append(a)
   p.sequence.tracks[ti].clips.append(Clip(assetID: a.id, start: MediaTime(seconds: at), duration: a.duration))
   // Ground truth is the voiced part (above −50 dBFS), not the file length with its silent padding.
   let (head, tail) = try voicedExtent(file)
   spans.append(Span(kind: "speech", start: at + head, end: at + tail))
   if a.duration.seconds - tail > 0.05 { spans.append(Span(kind: "pad", start: at + tail, end: at + a.duration.seconds)) }
   at += a.duration.seconds
  }
  func gap(_ kind: String, _ seconds: Double) { spans.append(Span(kind: kind, start: at, end: at + seconds)); at += seconds }
  try await speech(0, "안녕하세요. 오늘은 공원에서 영상을 촬영하고 있습니다.")
  gap("silence", 8)
  try await speech(1, "잠시 후에 음악을 틀어 보겠습니다.")
  let musicURL = URL(fileURLWithPath: "Resources/Library/Audio/Music/bossa-nova.mp3").standardizedFileURL
  let music = try await MediaImporter.inspect(url: musicURL); p.assets.append(music)
  p.sequence.tracks[ti].clips.append(Clip(assetID: music.id, start: MediaTime(seconds: at), sourceStart: MediaTime(seconds: 20), duration: MediaTime(seconds: 12)))
  gap("music", 12)
  try await speech(2, "이제 주변 소음이 아주 큰 곳으로 이동합니다.")
  let noiseURL = root.appendingPathComponent("vad-noise.wav")
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
  do { // AVAudioFile finalises the header when it is released
   let file = try AVAudioFile(forWriting: noiseURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
   let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 8)!; buffer.frameLength = 48_000 * 8
   var seed: UInt64 = 0x9E3779B97F4A7C15
   for i in 0..<Int(buffer.frameLength) { seed = seed &* 6364136223846793005 &+ 1442695040888963407; buffer.floatChannelData![0][i] = (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * 0.35 }
   try file.write(from: buffer)
  }
  let noise = try await MediaImporter.inspect(url: noiseURL); p.assets.append(noise)
  p.sequence.tracks[ti].clips.append(Clip(assetID: noise.id, start: MediaTime(seconds: at), duration: MediaTime(seconds: 8)))
  gap("noise", 8)
  gap("silence", 3)
  // Narration over background music (a typical vlog) must be treated as speech.
  p.sequence.tracks.append(Track(name: "배경음악", kind: .audio))
  let bgmStart = at
  try await speech(4, "배경 음악이 흐르는 동안에도 설명은 계속됩니다. 자막이 빠지면 안 됩니다.")
  var bgm = Clip(assetID: music.id, start: MediaTime(seconds: bgmStart), sourceStart: MediaTime(seconds: 40), duration: MediaTime(seconds: at - bgmStart))
  bgm.volume = 0.3
  p.sequence.tracks[p.sequence.tracks.count - 1].clips.append(bgm)
  gap("silence", 3)
  try await speech(3, "마지막으로 오늘 촬영을 마치겠습니다. 감사합니다.")
  gap("silence", 6)
  // A silent tail needs something on the timeline to define the length.
  var tail = Clip(name: "끝", start: MediaTime(seconds: at - 6), duration: MediaTime(seconds: 6), title: Title(text: " "))
  tail.transform.opacity = 0
  p.sequence.tracks[p.sequence.tracks.firstIndex { $0.kind == .title }!].clips.append(tail)
  try await ExportJob().export(plan: TimelineRenderer.build(project: p), to: output) { _ in }
  try JSONSerialization.data(withJSONObject: spans.map { ["kind": $0.kind, "start": $0.start, "end": $0.end] }).write(to: spansURL)
  return (output, spans)
 }
}

import Foundation
import AppKit
import AVFoundation
@testable import JHCutCore

/// Ground truth is known speech injected without time/pitch changes. Candidate-audio recall,
/// actual ASR text errors and non-speech captions are reported separately for both policies.
@main struct VADSafetyProbe {
 final class ProgressBox: @unchecked Sendable {
  private let lock = NSLock(); private var values: [Double] = []
  func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
  var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
 }
 struct Utterance { var text: String; var start: Double; var samples: [Float]; var end: Double { start + Double(samples.count) / 16_000 } }
 static func speech(root: URL, text: String, index: Int, start: Double) throws -> Utterance {
  let url = root.appendingPathComponent("speech-\(index).wav"), process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
  process.arguments = ["-v", "Yuna", "-r", "180", "--file-format=WAVE", "--data-format=LEF32@16000", "-o", url.path, text]
  try process.run(); process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw AudioAnalysisError("검사 음성 생성 실패") }
  let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!; try file.read(into: buffer)
  let raw = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  let voiced = raw.indices.filter { abs(raw[$0]) > 0.003 }
  guard let a = voiced.first, let b = voiced.last else { throw AudioAnalysisError("무음 검사 음성") }
  return Utterance(text: text, start: start, samples: Array(raw[max(0, a - 160)...min(raw.count - 1, b + 160)]))
 }
 static func write(_ url: URL, seconds: Int, channels: Int, sample: (Int, Double) -> Float) throws {
  guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { throw AudioAnalysisError("검사 채널 배치 생성 실패") }
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, interleaved: false, channelLayout: layout)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else { throw AudioAnalysisError("검사 오디오 버퍼 생성 실패") }
  var settings = format.settings; settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
  let file = try AVAudioFile(forWriting: url, settings: settings)
  buffer.frameLength = 16_000
  for second in 0..<seconds {
   for i in 0..<16_000 { for c in 0..<channels { buffer.floatChannelData![c][i] = sample(c, Double(second) + Double(i) / 16_000) } }
   try file.write(from: buffer)
  }
 }
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Stage7/VADSafety")
  var checks = 0, failures = 0, rows: [[String: Any]] = [], measurements: [[String: Any]] = []
  func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks += 1; if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL") \(name) \(detail)"); rows.append(["name":name,"passed":ok,"detail":detail]) }
  func validProgress(_ values: [Double]) -> Bool { !values.isEmpty && values.first == 0 && values.last == 1 && values.allSatisfy { $0.isFinite && (0...1).contains($0) } && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
  func overlap(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double { max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound)) }
  func recall(_ report: VoiceActivityReport, _ utterances: [Utterance]) -> [Double] { utterances.map { u in min(1, report.speechRegions.reduce(0) { $0 + overlap($1, u.start...u.end) } / (u.end - u.start)) } }
  let utterances = try [speech(root:root,text:"네, 좋아요.",index:0,start:6), speech(root:root,text:"잠시 기다려 주세요.",index:1,start:13), speech(root:root,text:"지금 녹화를 시작합니다.",index:2,start:20)]
  func voice(_ t: Double) -> Float {
   let frame = Int((t * 16_000).rounded())
   for u in utterances { let local = frame - Int((u.start * 16_000).rounded()); if local >= 0 && local < u.samples.count { return u.samples[local] } }
   return 0
  }
  print("MEASURE unmodified utterance durations: " + utterances.map { String(format:"%.3fs",$0.end-$0.start) }.joined(separator:", "))
  check("Known responses are naturally 1–3s, without resampling", utterances.allSatisfy { (0.8...3.2).contains($0.end-$0.start) })
  let anti = root.appendingPathComponent("opposite-phase.wav")
  try write(anti,seconds:30,channels:2) { c,t in voice(t) * (c == 0 ? 1 : -1) }
  let progress = ProgressBox()
  let antiReport = try await VoiceActivity.analyze(url:anti,sourceStart:.zero,duration:MediaTime(seconds:30),progress:{progress.add($0)})
  check("Opposite-phase stereo auto uses one native channel", antiReport.channelSelection?.channels == [0])
  check("Opposite-phase speech is not declared silence or skipped", recall(antiReport,utterances).allSatisfy { $0 >= 0.99 })
  check("30s VAD progress is monotone 0…1 and completes", validProgress(progress.snapshot))
  let wav = root.appendingPathComponent("opposite-phase-asr.wav")
  _ = try await LocalTranscription.extractAudio(url:anti,sourceStart:.zero,duration:MediaTime(seconds:30),destination:wav,audioSelection:antiReport.channelSelection)
  var error = 0.0, received = [Float]()
  _ = try await SourcePCM.readStable(url:wav,sourceStart:.zero,duration:MediaTime(seconds:30)) { received += $0.values }
  for i in received.indices { error = max(error,abs(Double(received[i]-voice(Double(i)/16_000)))) }
  check("ASR extraction hears same phase-safe signal as VAD", error < 0.00006,String(format:"max PCM error %.8f",error))
  let left = root.appendingPathComponent("left-only.wav")
  try write(left,seconds:30,channels:2) { c,t in c == 0 ? voice(t) : 0 }
  let selectedLeft = try await VoiceActivity.analyze(url:left,sourceStart:.zero,duration:MediaTime(seconds:30),preferredChannel:0)
  let selectedRight = try await VoiceActivity.analyze(url:left,sourceStart:.zero,duration:MediaTime(seconds:30),preferredChannel:1)
  check("Explicit left channel preserves every response", selectedLeft.channelSelection?.channels == [0] && recall(selectedLeft,utterances).allSatisfy { $0 >= 0.99 })
  check("Explicit silent right channel is not replaced by auto", selectedRight.channelSelection?.channels == [1] && selectedRight.speechRegions.isEmpty)
  let right = root.appendingPathComponent("right-only.wav")
  try write(right,seconds:30,channels:2) { c,t in c == 1 ? voice(t) : 0 }
  let selected = try await VoiceActivity.analyze(url:right,sourceStart:.zero,duration:MediaTime(seconds:30))
  check("Auto finds dialogue on right channel", selected.channelSelection?.channels == [1] && recall(selected,utterances).allSatisfy { $0 >= 0.99 })
  let multi = root.appendingPathComponent("four-channel.wav")
  try write(multi,seconds:30,channels:4) { c,t in c == 3 ? voice(t) : 0 }
  let custom = try await VoiceActivity.analyze(url:multi,sourceStart:.zero,duration:MediaTime(seconds:30),preferredChannel:3)
  check("User-selected fourth native channel preserved", custom.channelSelection?.channels == [3] && recall(custom,utterances).allSatisfy { $0 >= 0.99 })
  var invalid = false
  do { _ = try await VoiceActivity.analyze(url:left,sourceStart:.zero,duration:MediaTime(seconds:30),preferredChannel:3) } catch { invalid = true }
  check("Unavailable requested channel rejected", invalid)
  let partialProgress = ProgressBox()
  let partial = try await VoiceActivity.analyze(url:anti,sourceStart:MediaTime(seconds:5),duration:MediaTime(seconds:22),progress:{partialProgress.add($0)})
  check("Partial VAD uses elapsed/requested duration and completes", validProgress(partialProgress.snapshot) && partial.sourceStart == 5 && partial.duration == 22)
  let long = root.appendingPathComponent("ten-minute.wav")
  try write(long,seconds:600,channels:1) { _,t in voice(t) }
  let longProgress = ProgressBox()
  _ = try await VoiceActivity.analyze(url:long,sourceStart:.zero,duration:MediaTime(seconds:600),useClassifier:false,progress:{longProgress.add($0)})
  check("Ten-minute progress advances beyond 1/600 and ends at one", validProgress(longProgress.snapshot) && longProgress.snapshot.contains { $0 > 0.3 && $0 < 0.8 })
  let short = root.appendingPathComponent("one-second.wav")
  try write(short,seconds:1,channels:1) { _,t in utterances[0].samples[min(utterances[0].samples.count-1,Int(t*16_000))] }
  let tiny = try await VoiceActivity.analyze(url:short,sourceStart:.zero,duration:MediaTime(seconds:1))
  check("Sub-classifier-window audible file falls back to energy, never empty silence", !tiny.speechRegions.isEmpty)
  check("Zero/nonfinite denominator produces finite safe progress", AudioAnalysisProgress.fraction(elapsed:1,total:0) == 0 && AudioAnalysisProgress.fraction(elapsed:.nan,total:30) == 0)
  check("Final partial ASR window progress advances by actual 5s length", abs(TranscriptionTiming.windowProgress(index:2,within:0.5,windowSeconds:30,total:65) - 62.5/65) < 1e-12 && TranscriptionTiming.windowProgress(index:2,within:1,windowSeconds:30,total:65) == 1)
  let manual = [VoiceActivitySegment(kind:.music,start:0,end:10,confidence:0.99),VoiceActivitySegment(kind:.speech,start:10,end:12,confidence:0.4),VoiceActivitySegment(kind:.music,start:12,end:30,confidence:0.99)]
  check("Two-second weak speech between music survives fast planning", VoiceActivity.candidateRegions(segments:manual,duration:30,policy:.fast) == [9.5...12.5])
  let uncertain = [VoiceActivitySegment(kind:.music,start:0,end:10,confidence:0.99),VoiceActivitySegment(kind:.uncertain,start:10,end:10.5,confidence:0.4),VoiceActivitySegment(kind:.noise,start:10.5,end:30,confidence:0.99)]
  check("Half-second uncertain response is never bridged out", VoiceActivity.candidateRegions(segments:uncertain,duration:30,policy:.fast) == [9.5...11])

  var music = [Float]()
  _ = try await SourcePCM.read(url:URL(fileURLWithPath:"Resources/Library/Audio/Music/bossa-nova.mp3"),sourceStart:MediaTime(seconds:20),duration:MediaTime(seconds:30),sampleRate:16_000,channels:1) { music += $0.values }
  func background(_ t: Double) -> Float { (5..<26).contains(t) ? music[min(music.count-1,Int(t*16_000))] * 0.08 : 0 }
  let separate = root.appendingPathComponent("dialogue-plus-music-channels.wav")
  try write(separate,seconds:30,channels:2) { c,t in c == 0 ? voice(t)*0.25 : background(t)*3 }
  let both = try await VoiceActivity.analyze(url:separate,sourceStart:.zero,duration:MediaTime(seconds:30))
  check("Auto retains quiet brief dialogue alongside music channel", both.channelSelection?.channels.count == 2 && recall(both,utterances).allSatisfy { $0 >= 0.99 })
  let exactLeft = try await VoiceActivity.analyze(url:separate,sourceStart:.zero,duration:MediaTime(seconds:30),preferredChannel:0)
  check("Manual dialogue channel excludes other-channel music", exactLeft.channelSelection?.channels == [0] && exactLeft.skippableShare > both.skippableShare)
  let mixed = root.appendingPathComponent("known-short-speech-music-noise.wav")
  var seed: UInt64 = 123
  try write(mixed,seconds:30,channels:1) { _,t in
   seed = seed &* 6364136223846793005 &+ 1442695040888963407
   let noise: Float = (10..<18).contains(t) ? (Float(seed>>40)/Float(1<<24)*2-1)*0.018 : 0
   return voice(t) + background(t) + noise
  }
  let referenceURL = root.appendingPathComponent("known-short-speech.reference.srt")
  let referenceCues = utterances.map { CaptionCue(start:MediaTime(seconds:$0.start),duration:MediaTime(seconds:$0.end-$0.start),text:$0.text) }
  try SRTCodec.serialize(referenceCues).write(to:referenceURL,atomically:true,encoding:.utf8)
  var options = SpeechOptions(); options.language = "ko"
  let config = WhisperConfiguration(), store = TranscriptionCheckpointStore(root:root.appendingPathComponent("Checkpoints"))
  let mediaSHA = try await FileIdentity.sha256(mixed), projectID = UUID(), clipID = UUID()
  for policy in VoiceActivityPolicy.allCases {
   let r = try await VoiceActivity.analyze(url:mixed,sourceStart:.zero,duration:MediaTime(seconds:30),policy:policy)
   let candidateRecall = recall(r,utterances)
   if policy == .conservative { check("Default conservative retains 100% of each real short mixed utterance", candidateRecall.allSatisfy { $0 >= 0.99 }, candidateRecall.description) }
   let key = TranscriptionCheckpointKey(projectID:projectID,clipID:clipID,mediaSHA256:mediaSHA,sourceStart:.zero,duration:MediaTime(seconds:30),windowSeconds:30,options:options,modelSHA256:config.modelSpec.sha256,skipsSilence:true,voiceActivityPolicy:policy)
   try store.saveVoiceActivity(r,for:key)
   let t = Date(), asrProgress = ProgressBox()
   let transcript = try await LocalTranscription.transcribeLong(url:mixed,duration:MediaTime(seconds:30),configuration:config,options:options,windowSeconds:30,checkpoint:TranscriptionCheckpointSession(store:store,key:key),speechRegions:r.speechRegions,speechEvidence:r.confidentSpeech,audioSelection:r.channelSelection,speechPolicy:policy,progress:{ if let fraction = $0 { asrProgress.add(fraction) } })
   check("\(policy.rawValue) ASR progress is monotone and completes",validProgress(asrProgress.snapshot))
   let wall = Date().timeIntervalSince(t)
   let received = store.completedWindows(for:key).values.flatMap(\.cues)
   check("\(policy.rawValue) ASR shares VAD channel selection", transcript.audioSelection == r.channelSelection)
   check("\(policy.rawValue) received cues preserved without retry duplicates", received.count == transcript.cues.count && received.allSatisfy { transcript.cues.contains($0) })
   let reload = try await LocalTranscription.transcribeLong(url:mixed,duration:MediaTime(seconds:30),configuration:config,options:options,windowSeconds:30,checkpoint:TranscriptionCheckpointSession(store:store,key:key),speechRegions:r.speechRegions,speechEvidence:r.confidentSpeech,audioSelection:r.channelSelection,speechPolicy:policy)
   check("\(policy.rawValue) policy-specific resume SRT identical", try SRTCodec.serialize(reload.cues) == SRTCodec.serialize(transcript.cues))
   let evaluation = try TranscriptEvaluation.evaluate(captions:transcript.cues.map { EvaluatedCaption(text:$0.text,start:$0.start.seconds,end:($0.start+$0.duration).seconds) },reference:try TranscriptReference.load(referenceURL),language:"ko",sourceRange:0...30,mediaDuration:30)
   let recognized = utterances.map { u in transcript.cues.contains { !CoverageRepair.isMarker($0.text) && overlap($0.start.seconds...($0.start+$0.duration).seconds,u.start...u.end) > 0 } }
   let outside = transcript.cues.filter { c in !utterances.contains { overlap(c.start.seconds...(c.start+c.duration).seconds,$0.start...$0.end) > 0 } }
   measurements.append(["policy":policy.rawValue,"candidateAudioRecall":candidateRecall,"utterancesWithNonMarkerCue":recognized,"nonSpeechCues":outside.map(\.text),"ASRWallSeconds":wall,"VADWallSeconds":r.analysisSeconds,"recognizedAudioSeconds":r.speechRegionSeconds,"CER":evaluation.cer ?? -1,"WER":evaluation.wer ?? -1,"matchedReferenceSentences":evaluation.matchedSentences,"source":"scripted Korean speech, natural timing, mixed with music/noise"])
   try JSONEncoder().encode(evaluation).write(to:root.appendingPathComponent("\(policy.rawValue)-evaluation.json"))
   try SRTCodec.serialize(transcript.cues).write(to:root.appendingPathComponent("\(policy.rawValue).srt"),atomically:true,encoding:.utf8)
   print("MEASURE \(policy.rawValue) candidateRecall=\(candidateRecall) voicedCues=\(recognized) outside=\(outside.count) ASR=\(wall)s")
  }
  let control = root.appendingPathComponent("music-noise-without-speech.wav")
  seed = 123
  try write(control,seconds:30,channels:1) { _,t in
   seed = seed &* 6364136223846793005 &+ 1442695040888963407
   return background(t) + ((10..<18).contains(t) ? (Float(seed>>40)/Float(1<<24)*2-1)*0.018 : 0)
  }
  for policy in VoiceActivityPolicy.allCases {
   let r = try await VoiceActivity.analyze(url:control,sourceStart:.zero,duration:MediaTime(seconds:30),policy:policy)
   var captions: [CaptionCue] = [], wall = 0.0
   if !r.speechRegions.isEmpty {
    let begun = Date()
    captions = try await LocalTranscription.transcribeLong(url:control,duration:MediaTime(seconds:30),configuration:config,options:options,windowSeconds:30,speechRegions:r.speechRegions,audioSelection:r.channelSelection,speechPolicy:policy).cues
    wall = Date().timeIntervalSince(begun)
   }
   measurements.append(["source":"known no-speech music/noise control", "policy":policy.rawValue, "recognizedAudioSeconds":r.speechRegionSeconds, "nonMarkerHallucinationCues":captions.filter { !CoverageRepair.isMarker($0.text) }.map(\.text), "allCues":captions.map(\.text), "ASRWallSeconds":wall, "VADWallSeconds":r.analysisSeconds])
   try SRTCodec.serialize(captions).write(to:root.appendingPathComponent("control-\(policy.rawValue).srt"),atomically:true,encoding:.utf8)
   print("MEASURE control \(policy.rawValue) recognizedSeconds=\(r.speechRegionSeconds) no-speech cues=\(captions.count)")
  }
  let conservativeKey = TranscriptionCheckpointKey(projectID:projectID,clipID:clipID,mediaSHA256:mediaSHA,sourceStart:.zero,duration:MediaTime(seconds:30),windowSeconds:30,options:options,modelSHA256:config.modelSpec.sha256,skipsSilence:true)
  let fastKey = TranscriptionCheckpointKey(projectID:projectID,clipID:clipID,mediaSHA256:mediaSHA,sourceStart:.zero,duration:MediaTime(seconds:30),windowSeconds:30,options:options,modelSHA256:config.modelSpec.sha256,skipsSilence:true,voiceActivityPolicy:.fast)
  check("Policy switch cannot share recognition/VAD checkpoints", conservativeKey.identifier != fastKey.identifier && store.voiceActivity(for:conservativeKey)?.policy == .conservative && store.voiceActivity(for:fastKey)?.policy == .fast)
  var altered = conservativeKey; altered.channel = 1
  var wrongChannelRejected = false
  do { try store.saveVoiceActivity(both,for:altered) } catch { wrongChannelRejected = true }
  check("VAD from another requested channel rejected before saving", wrongChannelRejected && store.voiceActivity(for:altered) == nil)
  let silence = root.appendingPathComponent("pure-silence.wav")
  try write(silence,seconds:30,channels:1) { _,_ in 0 }
  for policy in VoiceActivityPolicy.allCases {
   let r = try await VoiceActivity.analyze(url:silence,sourceStart:.zero,duration:MediaTime(seconds:30),policy:policy)
   check("\(policy.rawValue) pure silence yields no recognition region", r.speechRegions.isEmpty)
  }
  let model = EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")))
  check("Editor defaults to conservative policy", model.voiceActivityPolicy == .conservative)
  model.skipNonSpeech = true; model.voiceActivityPolicy = .conservative; model.speechOptions.channel = 0; model.speechOptions.language = "ko"
  model.translateAfterTranscription = false; model.checkpointStore = TranscriptionCheckpointStore(root:root.appendingPathComponent("EditorCheckpoints"))
  let asset = try await MediaImporter.inspect(url:separate)
  var project = Project(name:"Selected dialogue channel"); project.assets = [asset]
  let clip = Clip(assetID:asset.id,duration:MediaTime(seconds:30)); project.sequence.tracks[3].clips = [clip]
  model.history = EditorHistory(project:project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.transcribeSelection(); await model.productivityTask?.value
  let cached = model.checkpointStore.summaries().compactMap { model.checkpointStore.voiceActivity(for:$0.key) }.first
  check("Editor uses requested dialogue channel for VAD and captions", model.error == nil && cached?.channelSelection?.channels == [0] && !model.captionClips.isEmpty,model.error ?? model.productivityStatus)
  let before = model.project
  // Caption creation selects its first new caption. Inspect the actual source again.
  model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]
  model.voiceActivityCache.removeAll(); model.checkCaptionsAgainstVoiceActivity(); await model.productivityTask?.value
  check("Caption verification cache includes channel and policy", model.lastVoiceActivity?.requestedChannel == 0 && model.lastVoiceActivity?.policy == .conservative && model.voiceActivityCache.count == 1 && model.project == before)
  model.speechOptions.channel = 1; model.checkCaptionsAgainstVoiceActivity(); await model.productivityTask?.value
  check("Changing inspection channel does not reuse left-channel VAD", model.lastVoiceActivity?.requestedChannel == 1 && model.lastVoiceActivity?.channelSelection?.channels == [1] && model.voiceActivityCache.count == 2,"channel=\(String(describing:model.lastVoiceActivity?.requestedChannel)), cache=\(model.voiceActivityCache.count), error=\(model.error ?? "none")")
  // The previously missed real iPhone exchange. No human transcript exists, so report
  // candidate-audio/cue coverage, not word accuracy or proven recovery of the dialogue.
  let realURL = URL(fileURLWithPath:"Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov")
  let realSHA = try await FileIdentity.sha256(realURL), realStart = MediaTime(seconds:480), realLength = MediaTime(seconds:120)
  let realBaseline = try await LocalTranscription.transcribeLong(url:realURL,sourceStart:realStart,duration:realLength,configuration:config,options:options)
  try SRTCodec.serialize(realBaseline.cues).write(to:root.appendingPathComponent("iphone-480-600-full.srt"),atomically:true,encoding:.utf8)
  func focusCues(_ cues: [CaptionCue]) -> [CaptionCue] { cues.filter { !CoverageRepair.isMarker($0.text) && overlap($0.start.seconds...($0.start+$0.duration).seconds,523...531) > 0 } }
  measurements.append(["source":"IMG_9211.mov 480…600", "policy":"full no skipping", "focus":"523…531", "nonMarkerFocusCues":focusCues(realBaseline.cues).map(\.text), "evaluation":"unscored: no human transcript"])
  for policy in VoiceActivityPolicy.allCases {
   let r = try await VoiceActivity.analyze(url:realURL,sourceStart:realStart,duration:realLength,policy:policy)
   let key = TranscriptionCheckpointKey(projectID:UUID(),clipID:UUID(),mediaSHA256:realSHA,sourceStart:realStart,duration:realLength,windowSeconds:300,options:options,modelSHA256:config.modelSpec.sha256,skipsSilence:true,voiceActivityPolicy:policy)
   let begun = Date()
   let result = try await LocalTranscription.transcribeLong(url:realURL,sourceStart:realStart,duration:realLength,configuration:config,options:options,checkpoint:TranscriptionCheckpointSession(store:store,key:key),speechRegions:r.speechRegions,speechEvidence:r.confidentSpeech,audioSelection:r.channelSelection,speechPolicy:policy)
   let received = store.completedWindows(for:key).values.flatMap(\.cues)
   check("Real iPhone \(policy.rawValue): received cues all preserved", result.cues.count == received.count && received.allSatisfy { result.cues.contains($0) })
   let retained = min(1,r.speechRegions.reduce(0) { $0 + overlap($1,523...531) } / 8)
   if policy == .conservative { check("Real iPhone 8:43–8:51 reaches default ASR without VAD deletion",retained >= 0.99) }
   measurements.append(["source":"IMG_9211.mov 480…600", "policy":policy.rawValue, "focus":"523…531", "candidateFocusAudioShare":retained, "nonMarkerFocusCues":focusCues(result.cues).map(\.text), "recognizedAudioSeconds":r.speechRegionSeconds, "ASRWallSeconds":Date().timeIntervalSince(begun), "VADWallSeconds":r.analysisSeconds, "evaluation":"unscored: no human transcript"])
   try SRTCodec.serialize(result.cues).write(to:root.appendingPathComponent("iphone-480-600-\(policy.rawValue).srt"),atomically:true,encoding:.utf8)
   try JSONEncoder().encode(r).write(to:root.appendingPathComponent("iphone-480-600-\(policy.rawValue)-vad.json"))
   print("MEASURE iPhone \(policy.rawValue) 523…531 retained=\(retained) nonmarkerCues=\(focusCues(result.cues).count)")
  }
  check("Real iPhone copy hash unchanged", realSHA == (try await FileIdentity.sha256(realURL)))
  try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("measurements.json"))
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))
  print("VAD_SAFETY_RESULT checks=\(checks) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

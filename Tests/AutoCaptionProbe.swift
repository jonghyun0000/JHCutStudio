#if AUTO_CAPTION_PROBE
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
@testable import JHCutCore

@main struct AutoCaptionProbe {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Logo-Captions")
  let source = root.appendingPathComponent("Speech/한국어 음성.aiff")
  try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
  let speech = Process()
  speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
  speech.arguments = ["-v", "Yuna", "-r", "140", "-o", source.path,
      "안녕하세요. 오늘은 공원에서 영상을 촬영하고 있습니다. 날씨가 좋아서 친구와 함께 산책을 합니다. 잠시 후에는 카페에서 따뜻한 차를 마실 예정입니다. 저녁에는 촬영한 영상을 정리하겠습니다."]
  try speech.run(); speech.waitUntilExit()
  guard speech.terminationStatus == 0 else { throw MediaEngineError.failed("한국어 검사 음성 생성에 실패했습니다.") }
  let asset = try await MediaImporter.inspect(url:source)
  var project = Project(name:"한국어 자동 자막 실제 검증")
  project.sequence.width = 640; project.sequence.height = 360; project.assets = [asset]
  let first = Clip(name:"트림 + 2배속",assetID:asset.id,start:MediaTime(seconds:3),sourceStart:MediaTime(seconds:2),duration:MediaTime(seconds:4),playbackRate:PlaybackRate(numerator:2))
  let second = Clip(name:"원속도 대사",assetID:asset.id,start:MediaTime(seconds:9),duration:MediaTime(seconds:6))
  let audio = project.sequence.tracks.firstIndex { $0.kind == .audio }!
  let titles = project.sequence.tracks.firstIndex { $0.kind == .title }!
  project.sequence.tracks[audio].clips = [first,second]
  var manualTitle = TitlePreset.builtIns[0].title; manualTitle.text = "기존 수동 자막"
  project.sequence.tracks[titles].clips = [Clip(name:"수동 자막",duration:MediaTime(seconds:1),title:manualTitle)]
  let model = EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("probe-recovery")))
  model.history = EditorHistory(project:project);model.selectedClipIDs = [first.id,second.id];model.selectedClipID = first.id
  model.transcriptionPresetID = "bold-caption"
  var checks:[[String:Any]] = []
  func check(_ name:String,_ passed:Bool,_ detail:String = "") {
   checks.append(["name":name,"passed":passed,"detail":detail]);print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
  }
  check("Installed model ready",model.transcriptionReady)
  check("Multiple selected speech clips resolved",model.selectedSpeechClips.count == 2)
  let mapped = CaptionEditing.automaticClips(cues:[CaptionCue(start:MediaTime(seconds:1),duration:MediaTime(seconds:3),text:"앞 경계"),CaptionCue(start:MediaTime(seconds:9),duration:MediaTime(seconds:4),text:"뒤 경계"),CaptionCue(start:MediaTime(seconds:20),duration:MediaTime(seconds:1),text:"범위 밖")],source:first,style:manualTitle)
  check("Cue clipping accounts for source trim and 2x rate",mapped.count == 2 && mapped[0].start == MediaTime(seconds:3) && mapped[0].duration == MediaTime(seconds:1) && mapped[1].end == first.end)
  model.transcribeSelection(); await model.productivityTask?.value
  check("Recognition completes",model.error == nil && !model.productivityBusy && !model.transcriptionActive && model.transcriptionProgress == 1,model.error ?? model.message)
  let generated = Array(model.project.sequence.tracks.dropFirst(project.sequence.tracks.count))
  check("One caption track for each selected source",generated.count == 2)
  check("Existing captions preserved",model.project.sequence.tracks[titles] == project.sequence.tracks[titles])
  check("Selected caption style applied",!generated.isEmpty && generated.flatMap(\.clips).allSatisfy { $0.title?.colorHex == "FFE55B" })
  check("Built-in caption size adapts to small canvas",generated.flatMap(\.clips).allSatisfy { $0.title?.fontSize == 24 })
  check("Trim/rate alignment stays within each clip",generated.count == 2 && zip(generated,[first,second]).allSatisfy { track,clip in !track.clips.isEmpty && track.clips.allSatisfy { $0.start >= clip.start && $0.end <= clip.end } })
  let captioned = model.project
  let cues = generated.flatMap(\.clips).map { CaptionCue(start:$0.start,duration:$0.duration,text:$0.title!.text) }.sorted { $0.start < $1.start }
  let srt = try SRTCodec.serialize(cues)
  try srt.write(to:root.appendingPathComponent("자동 생성 자막.srt"),atomically:true,encoding:.utf8)
  check("Generated captions survive SRT round trip",try SRTCodec.parse(srt).map(\.text) == cues.map(\.text))
  model.undo();check("One undo removes entire batch",model.project == project)
  model.redo();check("Redo restores all generated captions",model.project == captioned)
  model.history = EditorHistory(project:project);model.selectedClipIDs = [first.id];model.selectedClipID = first.id
  model.transcribeSelection();model.cancelProductivity();await model.productivityTask?.value
  check("Cancel leaves project and existing captions intact",model.project == project && !model.productivityBusy && !model.transcriptionActive)
  model.transcribeSelection()
  var changed = project;changed.name = "사용자가 편집 중"
  model.history = EditorHistory(project:changed)
  await model.productivityTask?.value
  check("Stale recognition cannot overwrite changed document",model.project == changed && model.error?.contains("프로젝트가 변경") == true)
  let plan = try await TimelineRenderer.build(project:captioned)
  let file = root.appendingPathComponent("자동자막-검증-\(UUID().uuidString.prefix(8)).mp4")
  try await ExportJob().export(plan:plan,to:file) { _ in }
  let output = AVURLAsset(url:file)
  let duration = try await output.load(.duration).seconds
  let audioTracks = try await output.loadTracks(withMediaType:.audio)
  check("Captioned video exports with audio",abs(duration-15)<0.04 && !audioTracks.isEmpty,file.path)
  if let cue = cues.first {
   let generator = AVAssetImageGenerator(asset:output);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
   let image = try generator.copyCGImage(at:CMTime(seconds:cue.start.seconds+cue.duration.seconds/2,preferredTimescale:600),actualTime:nil)
   let bytes=NSMutableData();let destination=CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil)!
   CGImageDestinationAddImage(destination,image,nil);CGImageDestinationFinalize(destination)
   try (bytes as Data).write(to:root.appendingPathComponent("burned-caption.png"))
   var pixels=[UInt8](repeating:0,count:640*360*4)
   let context=CGContext(data:&pixels,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.draw(image,in:CGRect(x:0,y:0,width:640,height:360))
   let lit=stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>100 && pixels[$0+1]>70 }.count
   check("Caption pixels are burned into output",lit>100,"\(lit) lit pixels")
   let edgePixels = stride(from:0,to:pixels.count,by:4).filter { index in
    let y = index / (640*4)
    return (y < 8 || y >= 352) && pixels[index]>100 && pixels[index+1]>70
   }.count
   check("Burned caption is not clipped at top/bottom",edgePixels == 0)
  }
  try ProjectStore.save(captioned,to:root.appendingPathComponent("자동자막-검증.jhcut"))
  // A current-version completed window with three real repeated utterances must propagate
  // through the editor as three captions, three review badges and truthful completion text.
  model.history = EditorHistory(project: project)
  model.selectedClipIDs = [first.id]; model.selectedClipID = first.id
  model.skipNonSpeech = false; model.translateAfterTranscription = false
  model.useSpeechCheckpoints = true; model.speechWindowSeconds = 30; model.speechOptions.language = "ko"
  model.checkpointStore = TranscriptionCheckpointStore(root: root.appendingPathComponent("repeat-checkpoints"))
  let repeatCues = [3.0, 4.0, 5.0].map { CaptionCue(start: MediaTime(seconds: $0), duration: MediaTime(seconds: 0.8), text: "같은 문장을 반복합니다") }
  let repeatKey = TranscriptionCheckpointKey(projectID: project.id, clipID: first.id, mediaSHA256: try await FileIdentity.sha256(source), sourceStart: first.sourceStart, duration: first.sourceDuration, windowSeconds: 30, options: model.speechOptions, modelSHA256: model.speechModelSpec.sha256)
  var repeatWindow = TranscriptionWindowResult(index: 0, sourceStart: first.sourceStart, duration: first.sourceDuration, cues: repeatCues, language: "ko", channel: 0, elapsedSeconds: 1)
  repeatWindow.repetitionSuspects = repeatCues.map { $0.start.seconds }
  repeatWindow.audioSelection = try await AudioChannelSelection.resolve(url:source,sourceStart:first.sourceStart,duration:first.sourceDuration,preferredChannel:model.speechOptions.channel)
  repeatWindow.inputSignature = try RecognitionInputSignature.make(regions:nil,evidence:nil,selection:nil)
  try model.checkpointStore.save(repeatWindow, for: repeatKey)
  model.transcribeSelection(); await model.productivityTask?.value
  let repeatedTitles = model.project.sequence.tracks.dropFirst(project.sequence.tracks.count).flatMap(\.clips)
  check("Editor preserves all three repeated utterances", model.error == nil && repeatedTitles.count == 3 && repeatedTitles.allSatisfy { $0.title?.text == "같은 문장을 반복합니다" }, model.error ?? model.productivityStatus)
  check("Editor flags all preserved repeated captions for review", model.repetitionCaptionIDs == Set(repeatedTitles.map(\.id)) && model.repetitionCaptionIDs.count == 3)
  check("Completion states preservation rather than deletion", model.productivityStatus.contains("반복 인식 의심 3개 보존") && !model.productivityStatus.contains("개 제거"), model.productivityStatus)
  try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("caption-checks.json"))
  if checks.contains(where:{($0["passed"] as? Bool) != true}) {exit(1)}
 }
}
#endif

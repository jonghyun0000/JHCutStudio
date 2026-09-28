import Foundation
import AppKit
import Combine
import JHCutCore
@main struct Workflow05Probe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  _=NSApplication.shared
  let root=URL(fileURLWithPath:"Artifacts/Upgrade-0.5/Workflow")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  var rows:[[String:Any]]=[]
  func check(_ name:String,_ passed:Bool){rows.append(["name":name,"passed":passed]);print("\(passed ? "PASS":"FAIL") \(name)")}
  let journal = root.appendingPathComponent("journal-" + UUID().uuidString + ".json")
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")), exportHistoryURL:journal)
  var p=Project();p.sequence.width=640;p.sequence.height=360
  var editorUpdates = 0, clockUpdates = 0
  let editorSubscription = model.objectWillChange.sink { editorUpdates += 1 }
  let clockSubscription = model.playbackClock.objectWillChange.sink { clockUpdates += 1 }
  model.playhead = 0.25
  check("Playback ticks update only clock subscribers", editorUpdates == 0 && clockUpdates == 1)
  editorSubscription.cancel(); clockSubscription.cancel()
  let preset=TitlePreset.builtIns[0], title=TitleSizing.title(for:TitlePreset.builtIns[0],width:640,height:360)
  let clip=Clip(duration:MediaTime(3,1),title:title)
  p.sequence.tracks[2].clips=[clip]
  model.history=EditorHistory(project:p);model.selectClip(clip.id)
  model.applyTitlePreset(preset,toAll:false)
  check("Same preset retains 360p caption size",abs(model.captionClips[0].title!.fontSize-58.0/3)<0.001)
  model.setFormat(width:3840,height:2160,frameRate:FrameRate())
  check("Format resize preserves relative title size",abs(model.captionClips[0].title!.fontSize-116)<0.001)
  model.undo();check("Format resize undo",model.project.sequence.width == 640 && abs(model.captionClips[0].title!.fontSize-58.0/3)<0.001)
  model.seek(.nan);check("Nonfinite seek reports error without crash",model.error != nil && model.playhead.isFinite)
  model.error=nil;model.seek(1);model.addMarker();check("Marker stored in document",model.project.sequence.markers?.count == 1)
  let original=model.project;var named=original;named.name="New name"
  check("Metadata edits preserve render plan",!EditorModel.needsRender(original,named))
  var changed=original;changed.sequence.tracks[2].clips[0].title?.text="Visible change"
  check("Text edits still rebuild render plan",EditorModel.needsRender(original,changed))
  model.replaceCaptionText(find:"자막",replacement:"설명")
  check("Caption find/replace changes actual title",model.captionClips[0].title!.text.contains("설명"))
  model.undo();check("Caption replacement undo",model.project == original)
  var locked=model.project;locked.sequence.tracks[2].isLocked=true;model.history=EditorHistory(project:locked)
  let writable=model.writableTrack(.title)
  check("Insertion creates a writable track when original is locked",writable != nil && writable?.id != locked.sequence.tracks[2].id && model.project.sequence.tracks[2].isLocked)
  let source=URL(fileURLWithPath:"Artifacts/Logo-Captions/Speech/한국어 음성.aiff")
  let asset=try await MediaImporter.inspect(url:source)
  var speech=Project();speech.sequence.width=640;speech.sequence.height=360;speech.assets=[asset]
  let voice=Clip(assetID:asset.id,duration:MediaTime(6,1));speech.sequence.tracks[3].clips=[voice]
  model.history=EditorHistory(project:speech);model.selectClip(voice.id);model.error=nil
  model.transcribeSelection();await model.productivityTask?.value
  let firstCount=model.captionClips.count, trackCount=model.project.sequence.tracks.count
  check("Real base recognition completes",firstCount>0 && model.error == nil)
  if let first=model.captionClips.first {model.updateCaption(first.id,text:"직접 고친 자막을 보존합니다")}
  model.selectClip(voice.id);model.transcribeSelection();await model.productivityTask?.value
  check("Regeneration preserves manual correction",model.captionClips.contains {$0.title?.text == "직접 고친 자막을 보존합니다"})
  check("Regeneration does not accumulate tracks",model.project.sequence.tracks.count == trackCount)
  check("Regeneration does not duplicate cues",model.captionClips.count <= firstCount)
  model.selectClip(voice.id);model.perform(.move(trackID:speech.sequence.tracks[3].id,clipID:voice.id,to:MediaTime(5,1)))
  check("Regenerated captions follow later source move",model.captionClips.allSatisfy {$0.start >= MediaTime(5,1)})
  model.speechModelID="small";model.refreshTranscriptionStatus()
  let availability=LocalTranscription.availability(configuration:WhisperConfiguration(modelSpec:.small))
  check("Model readiness follows selected model",model.transcriptionReady == availability.canTranscribe)
  model.loopEnabled = true; model.loopEnd = 5; model.resetProductivityState()
  check("New document clears stale loop range", !model.loopEnabled && model.loopStart == 0 && model.loopEnd == 0)
  model.loopStart = .nan; model.loopEnd = 3
  check("Invalid loop boundaries are rejected", model.validLoopRange == nil)
  let firstOutput = root.appendingPathComponent("queue-" + UUID().uuidString + ".mp4")
  let secondOutput = root.appendingPathComponent("queue-" + UUID().uuidString + ".mp4")
  let queued = p
  model.exportQueue = [QueuedExport(project:queued,baseURL:nil,url:firstOutput,codec:.hevc,bitRate:4_000_000), QueuedExport(project:queued,baseURL:nil,url:secondOutput,codec:.h264,bitRate:4_000_000)]
  model.history = EditorHistory(project:Project(name:"Changed after queueing"))
  model.startNextExport()
  while model.isExporting { await model.exportTask?.value }
  check("Export queue completes two captured project snapshots",model.exportQueue.allSatisfy {$0.status == "완료"})
  let firstResult = try await MediaImporter.inspect(url:firstOutput), secondResult = try await MediaImporter.inspect(url:secondOutput)
  check("Queued outputs retain captured duration and codec",abs(firstResult.duration.seconds-3)<0.05 && abs(secondResult.duration.seconds-3)<0.05 && firstResult.codec != secondResult.codec)
  let restoredJournal=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery2")),exportHistoryURL:journal)
  check("Completed export history survives a new editor instance",restoredJournal.exportJournal.count == 2 && restoredJournal.exportJournal.allSatisfy {$0["status"] == "완료"})
  let protectedData=try Data(contentsOf:firstOutput)
  let waitingURL=root.appendingPathComponent("waiting-"+UUID().uuidString+".mp4")
  model.exportQueue=[QueuedExport(project:queued,baseURL:nil,url:firstOutput,codec:.h264,bitRate:4_000_000),QueuedExport(project:queued,baseURL:nil,url:waitingURL,codec:.h264,bitRate:4_000_000)]
  model.startNextExport(); await model.exportTask?.value
  let protectedAfterFailure = try Data(contentsOf:firstOutput)
  check("Failed export pauses remaining queue and preserves destination",model.exportQueue[0].status == "실패" && model.exportQueue[1].status == "대기" && !FileManager.default.fileExists(atPath:waitingURL.path) && protectedAfterFailure == protectedData)
  model.exportQueue.removeFirst();model.startNextExport();model.cancelExport();await model.exportTask?.value
  check("Cancelled queued export leaves no partial destination",model.exportQueue[0].status == "취소" && !FileManager.default.fileExists(atPath:waitingURL.path))
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))
  if rows.contains(where:{$0["passed"] as? Bool != true}) {exit(1)}
 }
}

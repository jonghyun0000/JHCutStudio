import Foundation
import AppKit
import AVFoundation
import JHCutCore

/// Prepared while the isolated long workload is running. Compile only with a fresh matching core.
/// Exercises the actual application export queue, not a manually assigned isExporting flag.
@main struct AppExportPreviewProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil);_=NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/AppExportPreview")
  let assets=try await TimelineWorkload.assets()
  let project=TimelineWorkload.project(assets:assets,minutes:3,width:3840,height:2160)
  let document=root.appendingPathComponent("preview-export.jhcut")
  try ProjectStore.save(project,to:document)
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"),proxyCache:ProxyCache(directory:root.appendingPathComponent("Proxy")))
  model.reportsDirectory=root.appendingPathComponent("Reports")
  model.load(document);try await TimelineWorkload.ready(model)
  let snapshot=model.project
  var checks:[[String:Any]]=[];var phases:[[String:Any]]=[];var samples:[[String:Any]]=[]
  let started=ProcessInfo.processInfo.systemUptime
  func check(_ name:String,_ passed:Bool,_ detail:String="") {
   checks.append(["name":name,"passed":passed,"detail":detail]);print("\(passed ? "PASS":"FAIL") \(name) \(detail)")
  }
  func waitUntil(_ label:String,seconds:Double,_ predicate:()->Bool) async throws {
   let deadline=ProcessInfo.processInfo.systemUptime+seconds
   while !predicate() {
    guard ProcessInfo.processInfo.systemUptime<deadline else {throw ProjectError("Timed out: \(label)")}
    try await Task.sleep(nanoseconds:10_000_000)
   }
  }
  model.exportPhaseObserver={ id,phase in
   phases.append(["jobID":id.uuidString,"phase":phase.rawValue,"elapsed":ProcessInfo.processInfo.systemUptime-started])
  }
  func persist() throws {
   let report:[String:Any]=["checks":checks,"exportPhases":phases,"samples":samples,"scope":"actual EditorModel.startNextExport and cancelExport; real AVPlayer frames and complete 3-minute4K output; not native mouse/menu or physical speaker validation"]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"),options:.atomic)
  }
  defer {
   model.cancelExport();model.pausePlayback();model.player.replaceCurrentItem(with:nil)
   try? persist()
  }
  let item=model.player.currentItem!
  let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(output)
  func observe(_ label:String,expectedJob:UUID) async throws {
   let begin=ProcessInfo.processInfo.systemUptime,clock=model.player.currentTime().seconds
   let activeBefore=model.isExporting && model.activeExportID==expectedJob && model.activeExportPhase == .movie && model.exportProgress > 0 && model.exportProgress < 1
   var timestamps:[Double]=[]
   while ProcessInfo.processInfo.systemUptime-begin<1 {
    let time=model.player.currentTime();var displayed=CMTime.invalid
    if output.hasNewPixelBuffer(forItemTime:time),output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&displayed) != nil {timestamps.append(displayed.seconds)}
    try await Task.sleep(nanoseconds:8_000_000)
   }
   let advance=model.player.currentTime().seconds-clock
   let frameAdvance=(timestamps.last ?? 0)-(timestamps.first ?? 0)
   let activeAfter=model.isExporting && model.activeExportID==expectedJob && model.activeExportPhase == .movie && model.exportProgress > 0 && model.exportProgress < 1
   samples.append(["label":label,"clockAdvance":advance,"frameAdvance":frameAdvance,"framePTS":timestamps,"encodingBefore":activeBefore,"encodingAfter":activeAfter,"exportProgress":model.exportProgress])
   check(label+" overlaps actual movie encoding",activeBefore && activeAfter)
   check(label+" clock and decoded frames advance within1s",advance>=0.1 && frameAdvance>=0.1 && timestamps.count>=3)
  }
  model.togglePlay();try await Task.sleep(nanoseconds:700_000_000)
  check("Preview is already playing before export starts",model.playing && model.player.currentTime().seconds>0.1)
  let destination=root.appendingPathComponent("completed-3min-4k.mp4")
  let request=QueuedExport(project:snapshot,baseURL:document,url:destination,codec:.h264,bitRate:40_000_000)
  model.exportQueue=[request];model.startNextExport()
  check("Starting actual queued export preserves play intent",model.playing && model.isExporting && model.activeExportID==request.id)
  try await waitUntil("first movie encoding",seconds:120) {(model.activeExportPhase == .movie && model.exportProgress > 0 && model.exportProgress < 1) || !model.isExporting}
  check("Encoding status replaces the source-check label",model.exportQualityStatus == "영상 출력 중…")
  try await observe("Initial concurrent playback",expectedJob:request.id)
  model.pausePlayback();let paused=model.player.currentTime().seconds
  try await Task.sleep(nanoseconds:200_000_000)
  check("Pause holds during actual export",!model.playing && abs(model.player.currentTime().seconds-paused)<model.frameStep && model.isExporting)
  model.seek(45);model.pausePlayback()
  var decodedSeek=false
  let seekDeadline=ProcessInfo.processInfo.systemUptime+5
  while ProcessInfo.processInfo.systemUptime<seekDeadline {
   let time=model.player.currentTime();var displayed=CMTime.invalid
   if output.hasNewPixelBuffer(forItemTime:time),output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&displayed) != nil,abs(displayed.seconds-45)<model.frameStep*1.1 {decodedSeek=true;break}
   try await Task.sleep(nanoseconds:5_000_000)
  }
  check("Seek returns target decoded frame during export",decodedSeek && model.isExporting)
  model.togglePlay();try await observe("Resume after seek",expectedJob:request.id)
  check("Export request and editor document preserve the same snapshot",model.project==snapshot && model.exportQueue.first?.project==snapshot)
  model.pausePlayback()
  try await waitUntil("complete application export and QA",seconds:1200) {!model.isExporting}
  check("Actual app publishes movie and linked QA report",model.lastExportReceipt?.jobID==request.id && model.lastExportReceipt?.movie == .published && model.lastExportReceipt?.quality == .completed && model.lastExportReceipt?.report == .published)
  check("Application output QA reports no errors",model.lastQualityReport?.errors==0)
  let decoded=try await MediaInspection.decode(destination)
  check("Complete output has5400 ordered4K frames and matching audio length",decoded.width==3840 && decoded.height==2160 && decoded.frameCount==5400 && decoded.monotonic && abs(decoded.videoEndSeconds-180)<0.001 && decoded.audioRMS>0 && abs((decoded.metrics["audioPresentationEndSeconds"] ?? 0)-180)<0.05)
  if let plan=model.plan,let exportedFrame=decoded.images[30] {
   let generator=AVAssetImageGenerator(asset:plan.composition);generator.videoComposition=plan.videoComposition
   generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
   let preview=try await generator.image(at:CMTime(value:30,timescale:30)).image
   let difference=try MediaInspection.compare(preview,exportedFrame)
   check("Selected first-second preview/output frame matches",difference.mean<0.04,"mean RGB error=\(difference.mean); one selected frame, not all-frame equivalence")
  } else {check("Selected first-second preview/output frame matches",false,"Missing plan or decoded frame")}
  let deliveredHash=try await FileIdentity.sha256(destination)
  check("Published bytes match the application's delivery receipt",deliveredHash==model.lastExportReceipt?.movieSHA256)
  let cancelledDestination=root.appendingPathComponent("cancelled.mp4")
  let cancelled=QueuedExport(project:snapshot,baseURL:document,url:cancelledDestination,codec:.h264,bitRate:40_000_000)
  model.exportQueue.append(cancelled);model.startNextExport()
  try await waitUntil("second encoding before cancellation",seconds:120) {(model.activeExportPhase == .movie && model.exportProgress > 0 && model.exportProgress < 1) || !model.isExporting}
  check("Cancellation scenario reaches actual encoding",model.isExporting && model.activeExportID==cancelled.id && model.activeExportPhase == .movie)
  model.togglePlay();model.cancelExport()
  try await waitUntil("cancelled job cleanup",seconds:30) {!model.isExporting}
  let cancelClock=model.player.currentTime().seconds
  try await Task.sleep(nanoseconds:900_000_000)
  check("Cancel export leaves preview operational",model.playing && model.player.currentTime().seconds>cancelClock+0.1)
  check("Cancelled output is not published",model.lastExportReceipt?.jobID==cancelled.id && model.lastExportReceipt?.movie == .cancelled && !FileManager.default.fileExists(atPath:cancelledDestination.path))
  check("Cancellation status replaces the encoding label",model.exportQualityStatus == "영상 출력 취소")
  check("Previous completed movie survives later cancellation",try await FileIdentity.sha256(destination)==deliveredHash)
  let failures=checks.filter {($0["passed"] as? Bool) != true}.count
  try persist()
  print("APP_EXPORT_PREVIEW_RESULT checks=\(checks.count) failures=\(failures)")
  if failures>0 {throw ProjectError("Application export/preview checks failed: \(failures)")}
 }
}

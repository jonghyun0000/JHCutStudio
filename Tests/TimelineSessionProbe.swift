import Foundation
import AVFoundation
import AppKit
import JHCutCore

@main struct TimelineSessionProbe {
 @MainActor static func playerState(_ player:AVPlayer, item:AVPlayerItem, elapsed:Double) -> [String:Any] {
  let clock=player.currentTime().seconds
  return ["elapsedMilliseconds":elapsed*1000,"clockSeconds":clock.isFinite ? clock:0,
          "clockIsFinite":clock.isFinite,"rate":Double(player.rate),
          "timeControlStatus":player.timeControlStatus.rawValue,
          "waitingReason":player.reasonForWaitingToPlay?.rawValue ?? "",
          "itemStatus":item.status.rawValue,"bufferEmpty":item.isPlaybackBufferEmpty,
          "bufferFull":item.isPlaybackBufferFull,"likelyToKeepUp":item.isPlaybackLikelyToKeepUp,
          "itemError":item.error?.localizedDescription ?? ""]
 }
 @MainActor static func main() async throws {
  setbuf(stdout,nil);_=NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/TimelineSession")
  let seconds=Double(CommandLine.arguments.dropFirst(2).first ?? "1200") ?? 1200
  guard seconds>=1200 && seconds<=3600 else {throw ProjectError("Session duration must be1200...3600seconds")}
  let assets=try await TimelineWorkload.assets();let p=TimelineWorkload.project(assets:assets,minutes:60,width:3840,height:2160)
  var hashes:[String:String]=[:];for a in assets {hashes[a.path]=try await FileIdentity.sha256(a.resolvedURL(relativeTo:nil))}
  let doc=root.appendingPathComponent("session.jhcut");try ProjectStore.save(p,to:doc)
  let cache=ProxyCache(directory:root.appendingPathComponent("proxy"));let proxy=try await cache.generate(for:assets[3].resolvedURL(relativeTo:nil))
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"),proxyCache:cache)
  model.load(doc);try await TimelineWorkload.ready(model)
  var samples:[[String:Any]]=[];var gaps:[Double]=[];var failures=0;var cycle=0;var cycleHeartbeatMaxMS=0.0;var rebuildEvents:[[String:Any]]=[]
  let heartbeat=Task { @MainActor in
   var last=ProcessInfo.processInfo.systemUptime
   while !Task.isCancelled {do {try await Task.sleep(nanoseconds:10_000_000)}catch{break};let now=ProcessInfo.processInfo.systemUptime;cycleHeartbeatMaxMS=max(cycleHeartbeatMaxMS,(now-last)*1000);gaps.append((now-last)*1000);if gaps.count>10000 {gaps.removeFirst(5000)};last=now}
  }
  let start=ProcessInfo.processInfo.systemUptime
  var lastBuildGeneration=0
  model.rebuildPhaseObserver={generation,phase,time in
   lastBuildGeneration=generation
   rebuildEvents.append(["generation":generation,"phase":phase,"elapsedSeconds":time-start])
  }
  func readyWithObservation() async throws {
   try await TimelineWorkload.ready(model)
   rebuildEvents.append(["generation":lastBuildGeneration,"phase":"readyObserved","elapsedSeconds":ProcessInfo.processInfo.systemUptime-start])
  }
  let concurrentExport=ProcessInfo.processInfo.environment["JHCUT_SESSION_EXPORT"] == "1"
  let exportURL=root.appendingPathComponent("concurrent-60min-4k.mp4")
  var exportState=concurrentExport ? "building":"not-requested"
  var exportProgress=0.0;var exportError="";var exportFinishedSeconds:Double?
  var exportStartedSeconds:Double?
  var editingFinishedSeconds:Double?;var lastExportBucket = -1
  let exportJob=ExportJob(videoBitRate:40_000_000)
  let exportTask:Task<Void,Never>? = concurrentExport ? Task { @MainActor in
   do {
    let exportPlan=try await TimelineRenderer.build(project:p)
    exportState="encoding";exportStartedSeconds=ProcessInfo.processInfo.systemUptime-start
    try await exportJob.export(plan:exportPlan,to:exportURL) { value in
     Task { @MainActor in
      exportProgress=value
      let bucket=Int(value*10)
      if bucket != lastExportBucket {lastExportBucket=bucket;print("CONCURRENT_EXPORT_PROGRESS \(Int(value*100))%")}
     }
    }
    exportState="completed"
   } catch {exportState="failed";exportError=error.localizedDescription}
   exportFinishedSeconds=ProcessInfo.processInfo.systemUptime-start
  }:nil
  // Bound an unresponsive encoder without changing the one-second playback criterion.
  let exportWatchdog:Task<Void,Never>? = concurrentExport ? Task {
   do {try await Task.sleep(nanoseconds:7_200_000_000_000);exportJob.cancel()} catch {}
  }:nil
  defer {exportWatchdog?.cancel();exportTask?.cancel();exportJob.cancel()}
  func checkpoint(_ final:Bool=false) throws {
   var metrics:[String:Any]=["schemaVersion":1,"status":final ? "completed":"running","elapsedSeconds":ProcessInfo.processInfo.systemUptime-start,"requestedSeconds":seconds,"cycles":cycle,"failures":failures,"samples":samples,"heartbeatMilliseconds":gaps,"sourceHashes":hashes,"scope":"scripted actual EditorModel editing/playback/save/Undo/Redo;60min timeline using45min distinct originals +15min repetition;4K canvas with1080p main/real4K overlays;4K-overlay-only proxy; not a human/native SwiftUI session; RSS includes AppKit/decoder/allocator; OS video services are not child processes"]
   metrics["concurrentExport"]=["requested":concurrentExport,"jobCount":concurrentExport ? 1:0,"state":exportState,"progress":exportProgress,"error":exportError,"startedSeconds":exportStartedSeconds.map {$0 as Any} ?? NSNull(),"finishedSeconds":exportFinishedSeconds.map {$0 as Any} ?? NSNull(),"output":exportURL.path,"width":3840,"height":2160,"durationSeconds":3600,"bitRate":40_000_000,"scope":"one independent ExportJob from immutable original project; editor model remains editable; not proof of native app export controls"]
   metrics["editingFinishedSeconds"]=editingFinishedSeconds.map {$0 as Any} ?? NSNull()
   try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("session-progress.json"),options:.atomic)
  }
  while ProcessInfo.processInfo.systemUptime-start<seconds {
   let begin=ProcessInfo.processInfo.systemUptime
   cycleHeartbeatMaxMS=0;rebuildEvents=[]
   let titleTrack=model.project.sequence.tracks[2];var clip=titleTrack.clips[cycle%titleTrack.clips.count];clip.title?.text="연속 편집 日本語 English \(cycle)"
   let editBegin=ProcessInfo.processInfo.systemUptime;let accepted=model.perform(.updateClip(trackID:titleTrack.id,clip:clip));let performMS=(ProcessInfo.processInfo.systemUptime-editBegin)*1000;try await readyWithObservation()
   let rebuildMS=(ProcessInfo.processInfo.systemUptime-editBegin)*1000
   if cycle%12==6 {model.proxyURLs=[assets[3].id:proxy];model.proxyEnabled.toggle();model.rebuild();try await readyWithObservation()}
   if cycle%10==4 {model.undo();try await readyWithObservation();model.redo();try await readyWithObservation()}
   let target=Double((cycle*137)%3500)+0.2;let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);let item=model.player.currentItem!;item.add(output)
   let seekBegin=ProcessInfo.processInfo.systemUptime;model.seek(target);model.pausePlayback();var found=false
   for _ in 0..<1000 {let time=model.player.currentTime();var display=CMTime.invalid;if output.hasNewPixelBuffer(forItemTime:time),output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display) != nil,abs(display.seconds-model.playhead)<model.frameStep*1.1 {found=true;break};try await Task.sleep(nanoseconds:5_000_000)}
   let seekMS=(ProcessInfo.processInfo.systemUptime-seekBegin)*1000
   let beforePlay=playerState(model.player,item:item,elapsed:0)
   let initialClock=model.player.currentTime().seconds
   model.togglePlay();let playbackBegin=ProcessInfo.processInfo.systemUptime;var observedFrames=0;var stamps:[Double]=[]
   var states:[[String:Any]]=[];var nextStateTime=0.0
   var firstClockAdvanceMS:Double?;var firstDecodedFrameMS:Double?
   while ProcessInfo.processInfo.systemUptime-playbackBegin<1 {
    let elapsed=ProcessInfo.processInfo.systemUptime-playbackBegin
    let time=model.player.currentTime()
    if firstClockAdvanceMS == nil,time.seconds-initialClock>=model.frameStep {firstClockAdvanceMS=elapsed*1000}
    if elapsed>=nextStateTime {states.append(playerState(model.player,item:item,elapsed:elapsed));nextStateTime=elapsed+0.05}
    var display=CMTime.invalid;if output.hasNewPixelBuffer(forItemTime:time),output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&display) != nil {observedFrames+=1;stamps.append(display.seconds);if firstDecodedFrameMS == nil {firstDecodedFrameMS=elapsed*1000}}
    try await Task.sleep(nanoseconds:8_000_000)
   }
   let playbackEnd=playerState(model.player,item:item,elapsed:ProcessInfo.processInfo.systemUptime-playbackBegin)
   model.pausePlayback();let stopped=model.player.currentTime().seconds;try await Task.sleep(nanoseconds:150_000_000);let held=abs(model.player.currentTime().seconds-stopped)<model.frameStep;item.remove(output)
   let saveBegin=ProcessInfo.processInfo.systemUptime;model.save();let saveMS=(ProcessInfo.processInfo.systemUptime-saveBegin)*1000
   var loaded=try ProjectStore.load(from:doc);for i in loaded.assets.indices {loaded.assets[i].relativePath=model.project.assets[i].relativePath;loaded.assets[i].bookmark=model.project.assets[i].bookmark}
   let saved=loaded==model.project
   if !accepted || !found || !held || !saved || stopped-target<0.1 {failures+=1}
   let metrics=await cache.metrics()
   samples.append(["cycle":cycle,"elapsed":ProcessInfo.processInfo.systemUptime-start,"editAccepted":accepted,"decodedFrameSeek":found,"pauseHeld":held,"savePreserved":saved,"playbackAdvanceSeconds":stopped-target,"observedFrames1s":observedFrames,"frameTimestamps":stamps,"largestObservedFrameGapSeconds":zip(stamps,stamps.dropFirst()).map{$0.1-$0.0}.max() ?? 0,"rebuildMilliseconds":rebuildMS,"seekMilliseconds":seekMS,"saveMilliseconds":saveMS,"rssBytes":TimelineWorkload.rss(),"physicalFootprintBytes":TimelineWorkload.footprint(),"thermalState":ProcessInfo.processInfo.thermalState.rawValue,"proxy":model.proxyEnabled,"proxyHits":metrics.hits,"proxyMisses":metrics.misses,"proxyVerifiedBytes":metrics.verifiedBytes])
   samples[samples.count-1]["playbackDiagnostics"]=["beforePlay":beforePlay,"states":states,"endBeforePause":playbackEnd,"firstClockAdvanceMilliseconds":firstClockAdvanceMS.map { $0 as Any } ?? NSNull(),"firstDecodedFrameMilliseconds":firstDecodedFrameMS.map { $0 as Any } ?? NSNull(),"initialClockSeconds":initialClock,"automaticallyWaitsToMinimizeStalling":model.player.automaticallyWaitsToMinimizeStalling]
   samples[samples.count-1]["rebuildPhases"]=rebuildEvents
   samples[samples.count-1]["performMilliseconds"]=performMS
   samples[samples.count-1]["cycleHeartbeatMaxMilliseconds"]=cycleHeartbeatMaxMS
   samples[samples.count-1]["cycleBeginElapsedSeconds"]=begin-start
   samples[samples.count-1]["exportState"]=exportState
   samples[samples.count-1]["exportProgress"]=exportProgress
   cycle+=1;try checkpoint();print("SESSION_PROGRESS cycle=\(cycle) elapsed=\(Int(ProcessInfo.processInfo.systemUptime-start))s failures=\(failures) RSS=\(TimelineWorkload.rss()/1048576)MiB")
   let remaining=5-(ProcessInfo.processInfo.systemUptime-begin);if remaining>0 {try await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))}
  }
  heartbeat.cancel();await heartbeat.value
  editingFinishedSeconds=ProcessInfo.processInfo.systemUptime-start
  try checkpoint()
  model.player.replaceCurrentItem(with:nil)
  if let exportTask {
   await exportTask.value;exportWatchdog?.cancel()
   try checkpoint();print("CONCURRENT_EXPORT_DECODE_BEGIN state=\(exportState)")
   var verified=false
   if exportState == "completed" {
    do {
     let decoded=try await MediaInspection.decode(exportURL)
     verified=decoded.width==3840 && decoded.height==2160 && decoded.frameCount==108000 && decoded.monotonic && abs(decoded.videoEndSeconds-3600)<0.001 && decoded.audioRMS>0 && abs((decoded.metrics["audioPresentationEndSeconds"] ?? 0)-3600)<0.05
     let report:[String:Any]=["verified":verified,"frameCount":decoded.frameCount,"width":decoded.width,"height":decoded.height,"videoEndSeconds":decoded.videoEndSeconds,"audioRMS":decoded.audioRMS,"metrics":decoded.metrics]
     try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("concurrent-export-decode.json"),options:.atomic)
    } catch {exportError=error.localizedDescription}
   }
   if !verified {failures+=1}
   print("CONCURRENT_EXPORT_VERIFIED \(verified) \(exportError)")
  }
  for a in assets {if try await FileIdentity.sha256(a.resolvedURL(relativeTo:nil)) != hashes[a.path] {failures+=1}}
  try checkpoint(true)
  print("TIMELINE_SESSION_RESULT checks=\(cycle+(concurrentExport ? 1:0)) failures=\(failures)")
  if failures>0 {exit(1)}
 }
}

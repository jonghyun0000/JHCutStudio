import Foundation
import AVFoundation
import AppKit
import Darwin
import JHCutCore

/// Owned, authorized media copies. Reports unique footage separately from repeated timeline length.
enum TimelineWorkload {
 static func rss() -> UInt64 {
  var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
  let s=withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } };return s==KERN_SUCCESS ? UInt64(info.resident_size):0
 }
 static func footprint() -> UInt64 {
  var info=task_vm_info_data_t();var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
  let status=withUnsafeMutablePointer(to:&info) {p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
  return status==KERN_SUCCESS ? info.phys_footprint:0
 }
 static func assets() async throws -> [MediaAsset] {
  let paths=["Artifacts/Upgrade-0.7/RealCopies/IMG_0140.mov","Artifacts/Upgrade-0.7/RealCopies/IMG_0047.mov","Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov","Artifacts/Stage15Copies/IMG_2351.mov"]
  var assets:[MediaAsset]=[]
  for path in paths { let a=try await MediaImporter.inspect(url:URL(fileURLWithPath:path));guard a.supported else {throw ProjectError(a.issue ?? "Unsupported copy")};assets.append(a) }
  return assets
 }
 static func project(assets:[MediaAsset],minutes:Int,width:Int=1080,height:Int=1920) -> Project {
  var p=Project(name:"실제 복사본 \(minutes)분 \(width)x\(height)");p.assets=assets;p.sequence.width=width;p.sequence.height=height
  var pieces:[(MediaAsset,Double)]=[]
  for a in assets.prefix(3) { for s in stride(from:0.0,through:max(0,a.duration.seconds-30),by:30) {pieces.append((a,s))} }
  for i in 0..<(minutes*2) {let (a,s)=pieces[i%pieces.count];p.sequence.tracks[0].clips.append(Clip(name:a.name,assetID:a.id,start:MediaTime(seconds:Double(i)*30),sourceStart:MediaTime(seconds:s),duration:MediaTime(seconds:30)))}
  // Complexity is bounded and stated:24 captions and12 real4K overlays across the full duration.
  for i in 0..<24 {p.sequence.tracks[2].clips.append(Clip(name:"caption",start:MediaTime(seconds:Double(i)*Double(minutes)*60/24),duration:MediaTime(seconds:3),title:Title(text:"실사 편집 日本語 English \(i)")))}
  for i in 0..<12 {p.sequence.tracks[1].clips.append(Clip(name:"actual4K overlay",assetID:assets[3].id,start:MediaTime(seconds:Double(i)*Double(minutes)*60/12),duration:MediaTime(seconds:3),volume:0,transform:ClipTransform(scale:0.3)))}
  return p
 }
 @MainActor static func ready(_ model:EditorModel) async throws {
  for _ in 0..<3000 {if !model.isBuilding && model.player.currentItem?.status == .readyToPlay {return};if !model.isBuilding,let error=model.error {throw ProjectError(error)};try await Task.sleep(nanoseconds:10_000_000)}
  throw ProjectError("Timeline player readiness timeout")
 }
}

#if REAL_TIMELINE_PROBE
@main struct RealTimelineProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil); _=NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/RealTimeline")
  let assets=try await TimelineWorkload.assets();var hashes:[String:String]=[:]
  for a in assets {hashes[a.path]=try await FileIdentity.sha256(a.resolvedURL(relativeTo:nil))}
  var rows:[[String:Any]]=[];var checks:[[String:Any]]=[]
  func check(_ name:String,_ passed:Bool){checks.append(["name":name,"passed":passed]);print("\(passed ? "PASS":"FAIL") \(name)")}
  let cache=ProxyCache(directory:root.appendingPathComponent("proxy"));let proxy=try await cache.generate(for:assets[3].resolvedURL(relativeTo:nil))
  for minutes in [30,60] {
   let p=TimelineWorkload.project(assets:assets,minutes:minutes)
   let doc=root.appendingPathComponent("real-\(minutes)min.jhcut");let saveBegin=ProcessInfo.processInfo.systemUptime;try ProjectStore.save(p,to:doc);let saveMS=(ProcessInfo.processInfo.systemUptime-saveBegin)*1000
   var reopened=try ProjectStore.load(from:doc)
   let resolvedSame=zip(reopened.assets,p.assets).allSatisfy { $0.resolvedURL(relativeTo:doc).standardizedFileURL==$1.resolvedURL(relativeTo:nil).standardizedFileURL }
   for i in reopened.assets.indices {reopened.assets[i].relativePath=p.assets[i].relativePath;reopened.assets[i].bookmark=p.assets[i].bookmark}
   check("\(minutes)min save/reopen preserves edit and resolved media",resolvedSame && reopened==p)
   let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("recovery-\(minutes)")),exportHistoryURL:root.appendingPathComponent("journal-\(minutes).json"),proxyCache:cache)
   model.history=EditorHistory(project:p);let buildBegin=ProcessInfo.processInfo.systemUptime;model.rebuild();try await TimelineWorkload.ready(model);let buildMS=(ProcessInfo.processInfo.systemUptime-buildBegin)*1000
   let observation=ProcessInfo.processInfo.environment["JHCUT_TIMELINE_OBSERVATION"] == "0" ? nil : try PlaybackObservation(player:model.player, mode:.trackPostEffects);model.playbackObservation=observation
   let bareOutput=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);let measuredItem=model.player.currentItem!
   if observation == nil {measuredItem.add(bareOutput)}
   var seeks:[Double]=[];var samples:[[String:Any]]=[];var framesOK=true
   for fraction in [0.001,0.1,0.25,0.5,0.75,0.9,0.99] {
    let target=Double(minutes)*60*fraction;let begin=ProcessInfo.processInfo.systemUptime;model.seek(target);model.pausePlayback();var found=false
    for _ in 0..<1000 {
     observation?.sample("long-seek",displayedTime:model.playhead)
     var frame=observation?.currentSample?["lastFrameTime"] as? Double
     if observation == nil {var displayed=CMTime.invalid;let time=model.player.currentTime();if bareOutput.hasNewPixelBuffer(forItemTime:time),bareOutput.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&displayed) != nil {frame=displayed.seconds}}
     if let frame,abs(frame-model.playhead)<model.frameStep*1.1 {found=true;break};try await Task.sleep(nanoseconds:5_000_000)
    }
    seeks.append((ProcessInfo.processInfo.systemUptime-begin)*1000);framesOK=framesOK && found
    let playBegin=ProcessInfo.processInfo.systemUptime;model.togglePlay()
    for _ in 0..<500 {if model.player.currentTime().seconds>=target+0.2 {break};try await Task.sleep(nanoseconds:10_000_000)}
    let advance=model.player.currentTime().seconds-target;let playLatency=(ProcessInfo.processInfo.systemUptime-playBegin)*1000
    check("\(minutes)min \(fraction) playback really advances",advance>=0.2)
    model.pausePlayback();let stopped=model.player.currentTime().seconds;try await Task.sleep(nanoseconds:350_000_000)
    check("\(minutes)min \(fraction) pause holds",!model.playing && abs(model.player.currentTime().seconds-stopped)<0.04)
    samples.append(["target":target,"pausedAt":stopped,"decodedFrameSeek":found,"advanceSeconds":advance,"playAdvanceLatencyMS":playLatency,"itemError":model.player.currentItem?.error?.localizedDescription ?? "","audioFrames":observation?.currentSample?["audioFrames"] ?? NSNull()])
   }
   check("\(minutes)min all7 seeks deliver requested frames",framesOK)
   try observation?.saveReport(to:root.appendingPathComponent("trace-\(minutes).json"));if observation == nil {measuredItem.remove(bareOutput)};model.playbackObservation=nil
   model.proxyURLs=[assets[3].id:proxy];model.proxyEnabled=true;model.rebuild();try await TimelineWorkload.ready(model)
   check("\(minutes)min actual4K overlay proxy enabled",model.plan?.usesProxyMedia==true)
   // Excerpts prove quality at first/middle/end; full export is opt-in and explicitly separately reported.
   for start in [0.0,Double(minutes)*30,Double(minutes)*60-2] {
    let part=try TimelineRange.project(p,start:MediaTime(seconds:start),end:MediaTime(seconds:start+2));let plan=try await TimelineRenderer.build(project:part);let movie=root.appendingPathComponent("excerpt-\(minutes)-\(Int(start)).mp4")
    try await ExportJob(videoBitRate:4_000_000).export(plan:plan,to:movie){_ in};let decoded=try await MediaInspection.decode(movie)
    check("\(minutes)min excerpt\(Int(start))60 frames/2s with audio",decoded.frameCount==60 && decoded.monotonic && abs(decoded.videoEndSeconds-2)<0.001 && decoded.audioCodec != "")
    let generator=AVAssetImageGenerator(asset:plan.composition);generator.videoComposition=plan.videoComposition;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    let preview=try await generator.image(at:CMTime(value:30,timescale:30)).image
    let delta=try MediaInspection.compare(preview,decoded.images[30]!);check("\(minutes)min excerpt\(Int(start)) decoded pixels match preview",delta.mean<0.04)
   }
   if CommandLine.arguments.contains("--full-export") || ProcessInfo.processInfo.environment["JHCUT_TIMELINE_FULL_EXPORT"] == "1" {
    let plan=try await TimelineRenderer.build(project:p);let destination=root.appendingPathComponent("full-\(minutes)min.mp4");let begin=ProcessInfo.processInfo.systemUptime
    try await ExportJob(videoBitRate:4_000_000).export(plan:plan,to:destination){progress in if Int(progress*100)%10==0 {print("FULL_EXPORT \(minutes)min \(Int(progress*100))%")}}
    let decoded=try await MediaInspection.decode(destination);check("\(minutes)min full output decodes expected duration/frames",decoded.frameCount==minutes*60*30 && decoded.monotonic && abs(decoded.videoEndSeconds-Double(minutes)*60)<0.001 && decoded.audioRMS > 0 && abs((decoded.metrics["audioPresentationEndSeconds"] ?? 0)-Double(minutes)*60)<0.05)
    rows.append(["fullExportMinutes":minutes,"seconds":ProcessInfo.processInfo.systemUptime-begin])
   }
   let sorted=seeks.sorted();rows.append(["minutes":minutes,"canvasWidth":1080,"canvasHeight":1920,"fps":30,"sourceCount":4,"sourceKinds":"three actual1080p long recordings + one actual3.9s4K","uniqueMainSourceCapacitySeconds":2700,"timelineRepeatedSeconds":max(0,minutes*60-2700),"titleCount":24,"overlayCount":12,"proxyScope":"only actual4K overlay; main1080p originals","saveMilliseconds":saveMS,"buildMilliseconds":buildMS,"decodedSeekMilliseconds":seeks,"decodedSeekP50":sorted[3],"decodedSeekP95":sorted.last!,"seekPercentileMeaning":"p95=max of7 measured samples","samples":samples,"rssBytes":TimelineWorkload.rss(),"thermalState":ProcessInfo.processInfo.thermalState.rawValue,"fullExportRequested":(CommandLine.arguments.contains("--full-export") || ProcessInfo.processInfo.environment["JHCUT_TIMELINE_FULL_EXPORT"] == "1")])
   model.player.replaceCurrentItem(with:nil)
  }
  for a in assets {check("Input unchanged \(a.name)",try await FileIdentity.sha256(a.resolvedURL(relativeTo:nil))==hashes[a.path])}
  try JSONSerialization.data(withJSONObject:["cases":rows,"checks":checks,"inputHashes":hashes,"scope":"actual EditorModel/AVPlayer + owned copies; not native GUI20minute session; excerpts do not prove full export"],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("real-timeline.json"))
  let failures=checks.filter {($0["passed"] as? Bool) != true}.count;print("REAL_TIMELINE_RESULT checks=\(checks.count) failures=\(failures)");if failures>0 {exit(1)}
 }
}
#endif

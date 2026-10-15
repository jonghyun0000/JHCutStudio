import Foundation
import JHCutCore
private final class PrefetchEvents: @unchecked Sendable {
 let lock=NSLock();var events:[(String,Double)]=[];var began=false
 func record(_ n:String,_ t:Double){lock.lock();defer{lock.unlock()};events.append((n,t));if n == "video.prefetch.begin" {began=true}}
 func started()->Bool{lock.lock();defer{lock.unlock()};return began}
 func snapshot()->[(String,Double)]{lock.lock();defer{lock.unlock()};return events}
}
@main struct PrefetchProbe {
 static func main() async throws {
  setbuf(stdout,nil)
  let out=try ProbeWorkspace.prepare(defaultPath:"Artifacts/Prefetch")
  var assertions:[[String:Any]]=[]
  func check(_ name:String,_ passed:Bool) throws {
   assertions.append(["name":name,"passed":passed]);print("\(passed ? "PASS":"FAIL") \(name)")
   guard passed else {throw ProjectError(name)}
  }
  defer {try? JSONSerialization.data(withJSONObject:assertions,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("assertions.json"))}
  let urls=["Artifacts/Upgrade-0.7/RealCopies/IMG_0140.mov","Artifacts/Upgrade-0.7/RealCopies/IMG_0047.mov","Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov","Artifacts/Stage15Copies/IMG_2351.mov"].map{URL(fileURLWithPath:$0)}
  var inputs:[String:String]=[:],assets:[MediaAsset]=[]
  for url in urls {inputs[url.path]=try await FileIdentity.sha256(url);assets.append(try await MediaImporter.inspect(url:url))}
  var project=Project(name:"영상트랙 준비 회귀");project.assets=assets;project.sequence.width=3840;project.sequence.height=2160
  for i in 0..<120 {let asset=assets[i%3];project.sequence.tracks[0].clips.append(Clip(assetID:asset.id,start:MediaTime(Int64(i*30),1),sourceStart:MediaTime(Int64(((i/3)%20)*30),1),duration:MediaTime(30,1)))}
  let ti=project.sequence.tracks.firstIndex{$0.kind == .overlay}!
  project.sequence.tracks[ti].clips.append(Clip(assetID:assets[3].id,duration:MediaTime(1,1),volume:0))
  let original=project.assets[0];let doc=out.appendingPathComponent("fixture.jhcut")
  try ProjectStore.save(project,to:doc)
  for i in 0..<8 {var a=original;a.id=UUID();project.assets.append(a);var c=Clip(name:"independent asset \(i)",assetID:a.id,start:.zero,duration:MediaTime(1,1),volume:0);c.transform.scale=0.01;project.sequence.tracks[ti].clips.append(c)}
  let events=PrefetchEvents();let plan=try await TimelineRenderer.build(project:project,documentURL:doc,cacheInspection:true,phaseObserver:{n,t in events.record(n,t)})
  var changes:[(Double,Int)]=[],starts=0,ends=0
  for (name,t) in events.snapshot() where name.hasPrefix("video.prefetch.") && name.contains(".tracks.") {
   if name.contains(".begin."){changes.append((t,1));starts+=1};if name.contains(".end."){changes.append((t,-1));ends+=1}
  }
  changes.sort{$0.0 == $1.0 ? $0.1<$1.1 : $0.0<$1.0};var active=0,maxActive=0
  for (_,delta) in changes{active+=delta;maxActive=max(maxActive,active);guard active>=0 else{throw ProjectError("Invalid concurrency events")}}
  try check("Every independent visual asset load has a matching end",starts==12 && ends==12)
  try check("All measured child requests finish",active==0)
  try check("Independent video loads actually overlap",maxActive>1)
  try check("Video load concurrency never exceeds four",maxActive<=4)
  try check("Prepared 60min plan retains exact duration",abs(plan.duration.seconds-3600)<0.001)
  let cancelling=PrefetchEvents();let frozen=project
  let task=Task{try await TimelineRenderer.build(project:frozen,documentURL:doc,cacheInspection:true,phaseObserver:{n,t in cancelling.record(n,t)})}
  for _ in 0..<10000 {if cancelling.started(){break};try await Task.sleep(nanoseconds:1_000_000)}
  guard cancelling.started() else{task.cancel();_ = try? await task.value;throw ProjectError("Prefetch cancellation point was not reached")}
  try check("Cancellation reached prefetch phase",cancelling.started())
  task.cancel();var cancelled=false
  do{_ = try await task.value}catch is CancellationError{cancelled=true}
  try check("Cancellation refuses to publish the prepared plan",cancelled)
  let fresh=try await TimelineRenderer.build(project:frozen,documentURL:doc,cacheInspection:true)
  try check("Fresh build after cancellation succeeds",abs(fresh.duration.seconds-3600)<0.001)
  for (path,expected) in inputs.sorted(by:{$0.key<$1.key}) {try check("Owned input unchanged: "+URL(fileURLWithPath:path).lastPathComponent,try await FileIdentity.sha256(URL(fileURLWithPath:path)) == expected)}
  let report:[String:Any]=["loads":starts,"maxConcurrent":maxActive,"cancelAtPrefetchRejected":cancelled,"freshBuildAfterCancel":true,"scope":"12 separate file-asset instances referencing owned real copies; no native UI or output quality claim"]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("checks.json"));print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!);print("PREFETCH_RESULT checks=\(assertions.count) failures=0")
 }
}

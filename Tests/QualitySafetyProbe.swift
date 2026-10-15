import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import JHCutCore

private final class QualitySignal: @unchecked Sendable {
 private let lock=NSLock();private var ready=false
 func set(){lock.lock();ready=true;lock.unlock()}
 func get()->Bool{lock.lock();defer{lock.unlock()};return ready}
}
@main struct QualitySafetyProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil); _ = NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/QualitySafety")
  var rows:[[String:Any]]=[]
  func check(_ name:String,_ ok:Bool,_ detail:String="") { rows.append(["name":name,"passed":ok,"detail":detail]);print("\(ok ? "PASS":"FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json")) }
  func title(_ text:String)->Title { Title(text:text,fontSize:36,x:0.5,y:0.5,style:TextStyle(strokeWidth:2,backgroundOpacity:0.7,padding:14,shadow:false)) }
  func caption(_ text:String,_ start:Double,_ seconds:Double)->Clip {
   var c=Clip(name:text,start:MediaTime(seconds:start),duration:MediaTime(seconds:seconds),title:title(text)); c.captionRole = .original;c.captionMetadata=CaptionMetadata(language:"en",originalLanguage:"en",originalText:text,generatedText:text);return c
  }
  var p=Project(name:"QA safety");p.sequence.width=640;p.sequence.height=360
  p.sequence.tracks[2].clips=[caption("Alpha",0.2,1),caption("Short",1.4,0.4),caption("Bravo",2,1)]
  let plan=try await TimelineRenderer.build(project:p);let out=root.appendingPathComponent("static.mp4")
  try await ExportJob().export(plan:plan,to:out){_ in}
  let digest=try await FileIdentity.sha256(out)
  let e=OutputExpectation.from(project:p,plan:plan)
  let srt=root.appendingPathComponent("captions.srt")
  let cues=e.captions.map { CaptionCue(start:MediaTime(seconds:$0.start),duration:MediaTime(seconds:$0.end-$0.start),text:$0.title.text) }
  func run(_ name:String,_ cues:[CaptionCue]?,_ ex:OutputExpectation?=nil) async throws->OutputQualityReport {
   if let cues { try SRTCodec.serialize(cues).write(to:srt,atomically:true,encoding:.utf8) }
   let r=try await OutputQuality.check(output:out,expectation:ex ?? e,subtitles:cues == nil ? nil:srt)
   _ = try OutputQuality.write(r,to:root.appendingPathComponent("Reports"),name:name);return r
  }
  let clean=try await run("clean",cues)
  check("Static technical sample passes",clean.passed && clean.status == .passed,clean.summary)
  check("Three frame phases for every static cue",clean.burnIn.count==9 && Set(clean.burnIn.compactMap(\.phase))==Set(["start","middle","end"]) && clean.burnIn.allSatisfy{$0.verified==true})
  check("0.4s cue sampled at start middle end",clean.burnIn.filter{$0.captionIndex==1}.count==3)
  check("Actual frame times recorded and aligned",clean.burnIn.allSatisfy{$0.actualTime != nil && abs($0.actualTime!-$0.time)<0.002})
  check("Coverage explicitly sample only",clean.scope?.fullMoviePixelsVerified==false && clean.scope?.unverifiedBurnInIndices.isEmpty==true && clean.checks?.first{$0.id=="burnIn"}?.checked==3)
  var allWrong=cues;for i in allWrong.indices {allWrong[i].start=allWrong[i].start+MediaTime(seconds:5);allWrong[i].text="UNRELATED \(i)"}
  let wrong=try await run("all-unmatched",allWrong)
  check("Same count completely unmatched fails",!wrong.passed && wrong.status == .failed && wrong.subtitles?.matched==0 && wrong.subtitles?.onlyBurned==3 && wrong.subtitles?.onlyInSubtitles==3 && wrong.issues.contains{$0.code=="subtitleMismatch"})
  var partial=cues;partial[2].start=partial[2].start+MediaTime(seconds:5);partial[2].text="UNRELATED"
  let partially=try await run("partial-unmatched",partial)
  check("Partial unmatched fails with exact counts",partially.subtitles?.matched==2 && partially.subtitles?.onlyBurned==1 && partially.subtitles?.onlyInSubtitles==1 && !partially.passed)
  var shift=cues;shift[0].start=shift[0].start+MediaTime(seconds:2.1)
  let shifted=try await run("shift-over-two",shift)
  check("More than two seconds shifted fails",!shifted.passed && shifted.subtitles?.onlyInSubtitles==1)
  var reused=cues;reused[1]=cues[0]
  let once=try await run("one-to-one",reused)
  check("A burned cue cannot be reused",once.subtitles?.matched==2 && once.subtitles?.onlyBurned==1 && once.subtitles?.onlyInSubtitles==1)
  var sameTime=e;sameTime.captions[1].start=sameTime.captions[0].start;sameTime.captions[1].end=sameTime.captions[0].end
  let reversed=[CaptionCue(start:MediaTime(seconds:0.2),duration:MediaTime(seconds:1),text:"Short"),cues[0],cues[2]]
  let simultaneous=try await run("same-start-order",reversed,sameTime)
  check("Simultaneous cues prefer text match independent of order",simultaneous.subtitles?.matched==3 && simultaneous.subtitles?.textMismatches==0)
  let missing=try await OutputQuality.check(output:out,expectation:e,subtitles:root.appendingPathComponent("missing.srt"))
  check("Requested missing sidecar is failed",missing.issues.contains{$0.code=="subtitleMissing"} && !missing.passed)
  try "invalid SRT".write(to:srt,atomically:true,encoding:.utf8)
  let malformed=try await OutputQuality.check(output:out,expectation:e,subtitles:srt)
  check("Malformed sidecar does not become no check",malformed.issues.contains{$0.code=="subtitleUnreadable" || $0.code=="subtitleMismatch"} && !malformed.passed)
  let noSRT=try await run("no-sidecar",nil)
  check("Optional sidecar omission explicit",noSRT.checks?.first{$0.id=="subtitles"}?.status == .skipped)
  var ghost=e;ghost.captions[0].title.text="Absent";ghost.captions[0].title.style?.backgroundOpacity=1
  let absent=try await run("ghost-background",nil,ghost)
  check("Background box cannot hide absent glyphs",absent.burnIn.contains{$0.captionIndex==0 && $0.verified==false} && !absent.passed)
  var animated=p;animated.sequence.tracks[2].clips=[]
  var n=0
  for kind in TitleAnimationKind.allCases {
   for entry in [true,false] {
    var c=caption("\(kind.rawValue) \(entry ? "in":"out")",Double(n)*0.8,0.8)
    c.titleAnimation=TitleAnimation(inKind:entry ? kind:nil,outKind:entry ? nil:kind,inSeconds:0.8,outSeconds:0.8)
    animated.sequence.tracks[2].clips.append(c);n+=1
   }
  }
  let animatedPlan=try await TimelineRenderer.build(project:animated);let animationOut=root.appendingPathComponent("animations.mp4")
  try await ExportJob().export(plan:animatedPlan,to:animationOut){_ in}
  let animatedE=OutputExpectation.from(project:animated,plan:animatedPlan)
  check("Every entrance exit excluded from static comparison",animatedE.captions.count==14 && animatedE.captions.allSatisfy{ !$0.pixelComparable && $0.pixelExclusionReason?.contains("titleAnimation")==true })
  let animation=try await OutputQuality.check(output:animationOut,expectation:animatedE)
  _ = try OutputQuality.write(animation,to:root.appendingPathComponent("Reports"),name:"all-animations")
  check("Normal animations never static false errors",animation.errors==0 && !animation.issues.contains{$0.code=="burnIn"},animation.summary)
  check("Animation sampling limits never become whole-film proof",!animation.passed && animation.scope?.fullMoviePixelsVerified==false && (animation.scope?.unverifiedBurnInIndices.count ?? 0)>=6 && animation.burnIn.contains{$0.phase?.hasPrefix("dynamic-")==true && $0.verified==true})
  check("Animation effect scope explicit",animation.checks?.first{$0.id=="effects"}?.total==14 && (animation.checks?.first{$0.id=="effects"}?.checked ?? 0)>0 && (animation.checks?.first{$0.id=="effects"}?.checked ?? 0)<=8)
  for mode in 0..<2 {
   var modified=p
   if mode==0 {modified.sequence.tracks[2].clips[0].transform.x=0.1}
   if mode==1 {modified.sequence.tracks[2].clips[0].keyframes=[TransformKeyframe(time:MediaTime(seconds:0.5),transform:ClipTransform(scale:1.2))]}
   let mp=try await TimelineRenderer.build(project:modified);let me=OutputExpectation.from(project:modified,plan:mp)
   check("Transform/keyframe excluded \(mode)",!me.captions[0].pixelComparable && me.captions[0].pixelExclusionReason != nil)
  }
  var faded=p;faded.sequence.tracks[2].clips[0].fadeIn=MediaTime(seconds:0.2);faded.sequence.tracks[2].clips[0].fadeOut=MediaTime(seconds:0.2)
  let fadePlan=try await TimelineRenderer.build(project:faded);let fadeOut=root.appendingPathComponent("fades.mp4");try await ExportJob().export(plan:fadePlan,to:fadeOut){_ in}
  let fadeReport=try await OutputQuality.check(output:fadeOut,expectation:OutputExpectation.from(project:faded,plan:fadePlan))
  _ = try OutputQuality.write(fadeReport,to:root.appendingPathComponent("Reports"),name:"native-fades")
  check("Native fade boundaries sample opaque frames",fadeReport.burnIn.filter{$0.captionIndex==0}.allSatisfy{$0.time>=0.4-0.001 && $0.time<1.0 && $0.verified==true})
  var crowded=e;var other=e.captions[0];other.title.text="Overlap";crowded.captions.append(other)
  let overlap=try await run("overlap",nil,crowded)
  check("Overlapping samples explicitly unverified",overlap.issues.contains{$0.code=="overlap"} && overlap.burnIn.contains{$0.verified==nil && $0.note?.contains("겹치")==true} && !overlap.passed)
  // Titles are composited above scene transitions. Probe both transition boundaries
  // and its middle, rather than assuming the background scene is static.
  func png(_ url:URL,_ color:CGColor)throws {
   let context=CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.setFillColor(color);context.fill(CGRect(x:0,y:0,width:640,height:360))
   try NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!.write(to:url)
  }
  let aURL=root.appendingPathComponent("scene-a.png"),bURL=root.appendingPathComponent("scene-b.png")
  try png(aURL,CGColor(red:0.6,green:0,blue:0,alpha:1));try png(bURL,CGColor(red:0,green:0,blue:0.6,alpha:1))
  var a=try await MediaImporter.inspect(url:aURL),b=try await MediaImporter.inspect(url:bURL);a.duration=MediaTime(seconds:2);b.duration=MediaTime(seconds:2)
  for kind in TransitionKind.allCases {
   var scene=p;scene.assets=[a,b]
   scene.sequence.tracks[0].clips=[Clip(name:"A",assetID:a.id,duration:MediaTime(seconds:2)),Clip(name:"B",assetID:b.id,start:MediaTime(seconds:2),duration:MediaTime(seconds:2))]
   scene.sequence.tracks[2].clips=[caption("Boundary",1.2,0.8)]
   var history=EditorHistory(project:scene)
   try history.apply(.addTransition(trackID:scene.sequence.tracks[0].id,clipID:scene.sequence.tracks[0].clips[0].id,kind:kind,direction:.fromLeft,duration:MediaTime(seconds:0.8)))
   let scenePlan=try await TimelineRenderer.build(project:history.project),sceneOut=root.appendingPathComponent("transition-\(kind.rawValue).mp4")
   try await ExportJob().export(plan:scenePlan,to:sceneOut){_ in}
   let sceneReport=try await OutputQuality.check(output:sceneOut,expectation:OutputExpectation.from(project:history.project,plan:scenePlan))
   _ = try OutputQuality.write(sceneReport,to:root.appendingPathComponent("Reports"),name:"transition-\(kind.rawValue)")
   check("Static title at transition boundaries \(kind.rawValue)",sceneReport.passed && sceneReport.burnIn.count==3 && sceneReport.burnIn.allSatisfy{$0.verified==true},sceneReport.summary)
  }
  var bounded=e;bounded.captions=(0..<305).map{ i in var c=e.captions[0];c.start=Double(i)*2;c.end=c.start+1;return c };bounded.duration=610
  let limit=try await run("sampling-limit",nil,bounded)
  check("Layout limit and omitted titles explicit",limit.scope?.layoutLimit==300 && limit.captionsLaidOut<=300 && limit.scope!.unverifiedLayoutIndices.count>=5 && limit.checks?.first{$0.id=="layout"}?.status == .unverified)
  check("Burn-in frame budget and unsampled cues explicit",limit.burnIn.filter{$0.verified != nil}.count<=24 && limit.scope!.unverifiedBurnInIndices.count>=297 && !limit.passed)
  check("Every cue including endpoints has a result or exclusion",limit.burnIn.contains{$0.captionIndex==304 && $0.phase=="unverified"} && limit.burnIn.contains{$0.captionIndex==0 && $0.phase != "unverified"})
  check("Unverified cue ranges contain exact times and reasons",animation.scope?.unverifiedRanges.count==14 && animation.scope!.unverifiedRanges.allSatisfy{$0.end>$0.start && $0.reason.contains("titleAnimation") && $0.checks.contains("unsampledEffectTimes")})
  var fullyFaded=e;fullyFaded.captions[0].fadeIn=0.5;fullyFaded.captions[0].fadeOut=0.5
  let hiddenFade=try await run("fully-faded",nil,fullyFaded)
  check("Fully faded cue recorded unverified",hiddenFade.burnIn.contains{$0.captionIndex==0 && $0.verified==nil} && !hiddenFade.passed)
  var tiny=e;tiny.captions[0].title.fontSize=2;tiny.captions[0].title.style?.padding=0
  let small=try await run("tiny-glyph",nil,tiny)
  check("Too few glyph pixels never passed",small.burnIn.contains{$0.captionIndex==0 && $0.verified==nil && $0.note?.contains("너무 적음")==true} && !small.passed)
  let encoded=try JSONEncoder().encode(animation);let decoded=try JSONDecoder().decode(OutputQualityReport.self,from:encoded)
  check("Scope and states JSON roundtrip",decoded==animation)
  var legacyObject=try JSONSerialization.jsonObject(with:encoded) as! [String:Any];legacyObject.removeValue(forKey:"checks");legacyObject.removeValue(forKey:"scope")
  let legacy=try JSONDecoder().decode(OutputQualityReport.self,from:JSONSerialization.data(withJSONObject:legacyObject))
  check("Legacy report lacks coverage not falsely passed",legacy.status == .unverified && !legacy.passed)
  let md=OutputQuality.markdown(animation)
  check("Markdown includes states coverage and exclusions",md.contains("unverified") && md.contains("titleAnimation") && md.contains("전체 영상 픽셀") && md.contains("음성 인식"))
  let task=Task{try await OutputQuality.check(output:out,expectation:bounded)};task.cancel()
  do {_ = try await task.value;check("Cancellation propagates",false)}catch is CancellationError{check("Cancellation propagates",true)}catch{check("Cancellation propagates",false,error.localizedDescription)}
  let signal=QualitySignal()
  let during=Task{try await OutputQuality.check(output:out,expectation:bounded,progress:{fraction in if fraction>=0.2 {signal.set()} })}
  while !signal.get(){try await Task.sleep(nanoseconds:1_000_000)}
  during.cancel()
  do{_ = try await during.value;check("Cancellation during layout propagates",false)}catch is CancellationError{check("Cancellation during layout propagates",true)}catch{check("Cancellation during layout propagates",false,error.localizedDescription)}
  var invalid=e;invalid.captions[0].fadeIn = .nan
  do{_ = try await OutputQuality.check(output:out,expectation:invalid);check("Invalid fade clock rejected",false)}catch{check("Invalid fade clock rejected",true)}
  check("Checking never modifies the movie",try await FileIdentity.sha256(out)==digest)
  let fails=rows.filter{($0["passed"] as? Bool) != true}.count
  print("QUALITY_SAFETY_RESULT checks=\(rows.count) failures=\(fails)");if fails>0{exit(1)}
 }
}

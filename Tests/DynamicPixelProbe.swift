import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import JHCutCore

@main struct DynamicPixelProbe {
 static func main() async throws {
  setbuf(stdout,nil)
  let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  var project=Project(name:"Authored dynamic pixel fixture")
  project.sequence.width=640;project.sequence.height=360
  func caption(_ text:String,_ start:Double)->Clip {
   var c=Clip(name:text,start:MediaTime(seconds:start),duration:MediaTime(seconds:3),title:Title(text:text,fontSize:48,x:0.5,y:0.5,style:TextStyle(padding:0,shadow:false)))
   c.captionRole = .original;return c
  }
  var moving=caption("TRACK",0)
  var left=moving.transform;left.x = -120
  var right=moving.transform;right.x = 120
  moving.keyframes=[TransformKeyframe(time:.zero,transform:left),TransformKeyframe(time:MediaTime(seconds:3),transform:right)]
  var slide=caption("SLIDE",3);slide.titleAnimation=TitleAnimation(inKind:.slideLeft,outKind:.fade,inSeconds:1,outSeconds:0.5)
  var typing=caption("TYPEWRITER",6);typing.titleAnimation=TitleAnimation(inKind:.typewriter,inSeconds:1)
  var rotating=caption("ROTATE",9)
  rotating.keyframes=[TransformKeyframe(time:.zero,transform:ClipTransform(rotation:0)),TransformKeyframe(time:MediaTime(seconds:3),transform:ClipTransform(rotation:90))]
  var scaling=caption("SCALE",12)
  scaling.keyframes=[TransformKeyframe(time:.zero,transform:ClipTransform(scale:0.5)),TransformKeyframe(time:MediaTime(seconds:3),transform:ClipTransform(scale:1.5))]
  var opacity=caption("OPACITY",15)
  opacity.keyframes=[TransformKeyframe(time:.zero,transform:ClipTransform(opacity:0.2)),TransformKeyframe(time:MediaTime(seconds:3),transform:ClipTransform(opacity:0.8))]
  project.sequence.tracks[2].clips=[moving,slide,typing,rotating,scaling,opacity]
  let plan=try await TimelineRenderer.build(project:project)
  let movie=root.appendingPathComponent("dynamic.mp4")
  try await ExportJob().export(plan:plan,to:movie){_ in}
  let preview=AVAssetImageGenerator(asset:plan.composition);preview.videoComposition=plan.videoComposition
  let output=AVAssetImageGenerator(asset:AVURLAsset(url:movie));output.appliesPreferredTrackTransform=true
  for generator in [preview,output] {generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero}
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(project).write(to:root.appendingPathComponent("fixture.jhcut"),options:.withoutOverwriting)
  var rows:[[String:Any]]=[];var masks:[String:(Double,Int)]=[:];var stats:[String:[String:Double]]=[:]
  func mask(_ image:CGImage)throws->(Double,Int) {
   let pixels=try MediaInspection.rgba(image);var count=0;var sum=0.0
   for y in 0..<image.height {for x in 0..<image.width {let i=(y*image.width+x)*4
    if pixels[i]>40 && pixels[i+1]>40 && pixels[i+2]>40 {count+=1;sum+=Double(x)}
   }}
   guard count>20 else {throw ProjectError("Dynamic white-glyph sample unavailable")}
   return (sum/Double(count),count)
  }
  for (label,time) in [("moveEarly",0.25),("moveMid",1.5),("moveLate",2.75),("slideEarly",3.5),("slideRest",4.5),("typeEarly",6.25),("typeLate",6.75),("typeRest",7.5),("rotateStart",9.0),("rotateEnd",11.9666666667),("scaleStart",12.0),("scaleEnd",14.9666666667),("opacityStart",15.0),("opacityEnd",17.9666666667)] {
   let requested=CMTime(seconds:time,preferredTimescale:600);var pt=CMTime.zero;var ot=CMTime.zero
   let a=try preview.copyCGImage(at:requested,actualTime:&pt),b=try output.copyCGImage(at:requested,actualTime:&ot)
   for (kind,image) in [("preview",a),("output",b)] {
    let url=root.appendingPathComponent(label+"-"+kind+".png")
    guard let writer=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else {throw ProjectError("증거 이미지 저장 실패")}
    CGImageDestinationAddImage(writer,image,nil);guard CGImageDestinationFinalize(writer) else {throw ProjectError("증거 이미지 저장 실패")}
   }
   let delta=try MediaInspection.compare(a,b);let sample=try mask(b);masks[label]=sample
   let pixels=try MediaInspection.rgba(b);var minX=b.width;var minY=b.height;var maxX=0;var maxY=0;var energy=0.0
   for y in 0..<b.height {for x in 0..<b.width {let i=(y*b.width+x)*4;energy += Double(pixels[i])+Double(pixels[i+1])+Double(pixels[i+2]);if pixels[i]>40 && pixels[i+1]>40 && pixels[i+2]>40 {minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}}}
   stats[label]=["width":Double(maxX-minX+1),"height":Double(maxY-minY+1),"energy":energy]
   let timeMatches=abs(pt.seconds-requested.seconds)<=1.0/30+0.00001 && abs(ot.seconds-requested.seconds)<=1.0/30+0.00001
   rows.append(["label":label,"time":time,"previewTime":pt.seconds,"outputTime":ot.seconds,"mean":delta.mean,"p99":delta.p99,"whiteX":sample.0,"whitePixels":sample.1,"passed":timeMatches && delta.mean<0.035 && delta.p99<0.20])
  }
  // These geometric/mask checks do not call the animation evaluator as their oracle.
  let displacement=masks["moveLate"]!.0-masks["moveEarly"]!.0
  rows.append(["independentLinearDisplacement":displacement,"passed":abs(displacement-200)<4])
  rows.append(["independentSlideDirection":"rightward entrance","passed":masks["slideRest"]!.0-masks["slideEarly"]!.0>20])
  rows.append(["independentTypewriterReveal":"more glyph pixels","passed":masks["typeEarly"]!.1<masks["typeLate"]!.1 && masks["typeLate"]!.1<masks["typeRest"]!.1])
  let first=stats["rotateStart"]!,last=stats["rotateEnd"]!
  rows.append(["independentQuarterTurn":"horizontal glyph block becomes vertical","passed":first["width"]!>first["height"]!*2 && last["height"]!>last["width"]!*2])
  let ratio=stats["scaleEnd"]!["width"]!/stats["scaleStart"]!["width"]!
  rows.append(["independentScaleRatio":ratio,"passed":abs(ratio-(1.5-1.0/90)/0.5)<0.12])
  let energyRatio=stats["opacityEnd"]!["energy"]!/stats["opacityStart"]!["energy"]!
  rows.append(["independentOpacityEnergyRatio":energyRatio,"passed":energyRatio>1.5])
  try JSONSerialization.data(withJSONObject:stats,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("glyph-stats.json"),options:.withoutOverwriting)
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("samples.json"),options:.withoutOverwriting)
  func qaCheck(_ name:String,_ passed:Bool,_ detail:String="") {rows.append(["qa":name,"passed":passed,"detail":detail]);print("\(passed ? "PASS":"FAIL") \(name) \(detail)")}
  let expectation=OutputExpectation.from(project:project,plan:plan)
  let instructions=plan.videoComposition.instructions.map {ObjectIdentifier($0 as AnyObject)}
  let report=try await OutputQuality.check(output:movie,expectation:expectation)
  _ = try OutputQuality.write(report,to:root.appendingPathComponent("Reports"),name:"dynamic-good")
  let effects=report.checks?.first {$0.id=="effects"}
  qaCheck("all six effects receive time-specific burn-in comparisons",effects?.checked==6 && effects?.failed==0 && report.burnIn.filter {$0.phase?.hasPrefix("dynamic-")==true && $0.verified==true}.count==18,report.summary)
  qaCheck("all six dynamic footprints sampled",report.checks?.first {$0.id=="dynamicLayout"}?.checked==6 && report.scope?.unverifiedLayoutIndices.isEmpty==true)
  qaCheck("unsampled effect times remain explicit",report.scope?.policyVersion==3 && report.scope?.fullMoviePixelsVerified==false && report.scope?.unverifiedRanges.count==6 && report.scope!.unverifiedRanges.allSatisfy {$0.checks.contains("unsampledEffectTimes")})
  qaCheck("reference plan instructions remain unchanged",plan.videoComposition.instructions.map {ObjectIdentifier($0 as AnyObject)}==instructions)
  var missing=project;missing.sequence.tracks[2].clips=[Clip(name:"blank duration carrier",duration:MediaTime(seconds:18),title:Title(text:" "))]
  let missingPlan=try await TimelineRenderer.build(project:missing);let missingMovie=root.appendingPathComponent("dynamic-missing.mp4")
  try await ExportJob().export(plan:missingPlan,to:missingMovie){_ in}
  let missingReport=try await OutputQuality.check(output:missingMovie,expectation:expectation)
  _ = try OutputQuality.write(missingReport,to:root.appendingPathComponent("Reports"),name:"dynamic-missing")
  qaCheck("absent animated captions fail the published QA",!missingReport.passed && missingReport.errors>0 && missingReport.burnIn.filter {$0.verified==false}.count>=6,missingReport.summary)
  var shifted=project
  shifted.sequence.tracks[2].clips=shifted.sequence.tracks[2].clips.map {original in var clip=original;clip.transform.x += 80;clip.keyframes=clip.keyframes?.map {original in var key=original;key.transform.x += 80;return key};return clip}
  let shiftedPlan=try await TimelineRenderer.build(project:shifted);let shiftedMovie=root.appendingPathComponent("dynamic-shifted.mp4")
  try await ExportJob().export(plan:shiftedPlan,to:shiftedMovie){_ in}
  let shiftedReport=try await OutputQuality.check(output:shiftedMovie,expectation:expectation)
  _ = try OutputQuality.write(shiftedReport,to:root.appendingPathComponent("Reports"),name:"dynamic-shifted")
  qaCheck("incorrect animated placement fails QA",!shiftedReport.passed && shiftedReport.burnIn.contains {$0.verified==false},shiftedReport.summary)
  let whiteURL=root.appendingPathComponent("white.png")
  let context=CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:640,height:360))
  let png=CGImageDestinationCreateWithURL(whiteURL as CFURL,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(png,context.makeImage()!,nil);guard CGImageDestinationFinalize(png) else {throw ProjectError("white fixture")}
  var whiteAsset=try await MediaImporter.inspect(url:whiteURL);whiteAsset.duration=MediaTime(seconds:18)
  var lowContrast=project;lowContrast.assets=[whiteAsset];lowContrast.sequence.tracks[0].clips=[Clip(name:"white backdrop",assetID:whiteAsset.id,duration:MediaTime(seconds:18))]
  let lowPlan=try await TimelineRenderer.build(project:lowContrast);let lowMovie=root.appendingPathComponent("dynamic-low-contrast.mp4");try await ExportJob().export(plan:lowPlan,to:lowMovie){_ in}
  let lowReport=try await OutputQuality.check(output:lowMovie,expectation:OutputExpectation.from(project:lowContrast,plan:lowPlan))
  _ = try OutputQuality.write(lowReport,to:root.appendingPathComponent("Reports"),name:"dynamic-low-contrast")
  qaCheck("white background cannot establish white animated glyphs",lowReport.status == .unverified && lowReport.burnIn.allSatisfy {$0.verified==nil} && lowReport.checks?.first {$0.id=="effects"}?.checked==0,lowReport.summary)
  var legacy=expectation;legacy.previewPlan=nil
  let legacyReport=try await OutputQuality.check(output:movie,expectation:legacy)
  qaCheck("missing composited reference remains unverified",legacyReport.checks?.first {$0.id=="effects"}?.checked==0 && legacyReport.burnIn.allSatisfy {$0.verified==nil})
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("all-checks.json"),options:.withoutOverwriting)
  let failures=rows.filter {$0["passed"] as? Bool != true}.count
  print("DYNAMIC_PIXEL_RESULT checks=\(rows.count) failures=\(failures)")
  guard failures==0 else {exit(1)}
  print("PASS Dynamic preview/export samples and independent geometry/reveal oracles")
 }
}

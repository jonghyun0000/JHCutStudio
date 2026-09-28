import Foundation
import AVFoundation
import CoreImage
import JHCutCore
@main struct Upgrade05Probe {
 static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.5/Features")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  var checks:[[String:Any]]=[]
  func check(_ name:String,_ passed:Bool,_ detail:String="") {checks.append(["name":name,"passed":passed,"detail":detail]);print("\(passed ? "PASS":"FAIL") \(name) \(detail)")}
  var meter=LoudnessMeter(),tone:[Float]=[]
  for n in 0..<48000 {tone += [Float(0.1*sin(2*Double.pi*997*Double(n)/48000)),0]}
  for _ in 0..<3 {meter.consume(stereo:tone)}
  check("48kHz K-weighted calibration tone",abs((meter.measurement.integratedLUFS ?? 0)+23.01)<0.15,"LUFS=\(meter.measurement.integratedLUFS ?? 0)")
  var silence=LoudnessMeter();silence.consume(stereo:[Float](repeating:0,count:48000*2))
  check("Digital silence is not a fabricated LUFS value",silence.measurement.integratedLUFS == nil)
  let fixture=try await Fixtures.generate(in:root.appendingPathComponent("fixtures"))
  let video=try await MediaImporter.inspect(url:fixture.videos[0]),audio=try await MediaImporter.inspect(url:fixture.bgm)
  var p=Project(name:"0.5 feature verification");p.sequence.width=640;p.sequence.height=360;p.assets=[video,audio]
  p.sequence.tracks[0].clips=[Clip(assetID:video.id,duration:MediaTime(3,1))]
  p.sequence.tracks[3].clips=[Clip(assetID:audio.id,duration:MediaTime(3,1),volume:1),Clip(assetID:audio.id,duration:MediaTime(3,1),volume:1)]
  let plan=try await TimelineRenderer.build(project:p)
  for codec in ExportJob.Codec.allCases {
   let output=root.appendingPathComponent(codec.rawValue+"."+codec.fileExtension)
   try await ExportJob(videoBitRate:4_000_000,codec:codec).export(plan:plan,to:output){_ in}
   let decoded=try await MediaImporter.inspect(url:output)
   check("\(codec.rawValue) output decodes",decoded.supported && decoded.width == 640 && decoded.height == 360 && abs(decoded.duration.seconds-3)<0.04,decoded.codec)
  }
  let mastered=try await MixMastering.render(plan:plan,to:root.appendingPathComponent("master.caf"),targetLUFS:-16)
  check("Master mix preserves PCM length",mastered.after.frames == 144000)
  check("Master limiter bounds sample peak",(mastered.after.samplePeakDBFS ?? 0) <= -1.49,"peak=\(mastered.after.samplePeakDBFS ?? 0), LUFS=\(mastered.after.integratedLUFS ?? 0)")
  check("Master mix 4x peak measurement finite",mastered.oversampledPeakDBFS?.isFinite == true)
  let enhanced=try await MixMastering.render(plan:plan,to:root.appendingPathComponent("voice.caf"),targetLUFS:-16,enhanceVoice:true)
  check("Voice EQ/compression changes output without changing length",enhanced.after.frames == mastered.after.frames && enhanced.after.samplePeakDBFS != mastered.after.samplePeakDBFS)
  let range=try TimelineRange.project(p,start:MediaTime(1,2),end:MediaTime(5,2))
  check("Range export remaps original source and duration",range.sequence.tracks[0].clips[0].sourceStart == MediaTime(1,2) && range.sequence.duration == MediaTime(2,1))
  let rangePlan=try await TimelineRenderer.build(project:range)
  try await ExportJob().export(plan:rangePlan,to:root.appendingPathComponent("range.mp4")){_ in}
  check("Range export actual duration",abs((try await MediaImporter.inspect(url:root.appendingPathComponent("range.mp4"))).duration.seconds-2)<0.04)
  let lutText="LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
  let lut=try CubeLUT.parse(lutText,name:"Identity")
  check("Valid cube LUT accepted",lut.values.count == 32)
  do {_=try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 nan",name:"Bad");check("Malformed LUT rejected",false)} catch {check("Malformed LUT rejected",true)}
  var styled=p; var adjustments=VisualAdjustments();adjustments.lut=lut;adjustments.temperature=7500;adjustments.shadows=0.1;adjustments.ellipseMask=true
  styled.sequence.tracks[0].clips[0].visual=adjustments
  let styledPlan=try await TimelineRenderer.build(project:styled)
  let image=try await preview(styledPlan,time:1)
  try Fixtures.savePNG(image,to:root.appendingPathComponent("masked-color.png"))
  let corner=pixel(image,x:4,y:4),center=pixel(image,x:image.width/2,y:image.height/2)
  check("Ellipse mask clears corners and retains center",corner.max()! < 12 && center.max()! > 20,"corner=\(corner), center=\(center)")
  styled.sequence.tracks[0].clips[0].visual?.greenScreen=0.5
  let keyedPlan = try await TimelineRenderer.build(project:styled)
  _=try await preview(keyedPlan,time:1)
  check("Chroma key pipeline renders",true)
  let greenContext = CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  greenContext.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1)); greenContext.fill(CGRect(x:0,y:0,width:640,height:360))
  let greenURL = root.appendingPathComponent("pure-green.png"); try Fixtures.savePNG(greenContext.makeImage()!,to:greenURL)
  let greenAsset = try await MediaImporter.inspect(url:greenURL)
  var keyed = p; keyed.assets.append(greenAsset)
  var greenClip = Clip(assetID:greenAsset.id,duration:MediaTime(3,1)); var keyAdjustment = VisualAdjustments(); keyAdjustment.greenScreen = 0.5; greenClip.visual = keyAdjustment
  keyed.sequence.tracks[1].clips = [greenClip]
  let baselinePlan = try await TimelineRenderer.build(project:p), greenPlan = try await TimelineRenderer.build(project:keyed)
  let baseline = pixel(try await preview(baselinePlan,time:1),x:50,y:50), removed = pixel(try await preview(greenPlan,time:1),x:50,y:50)
  check("Green-screen removes green and reveals lower video",zip(baseline,removed).allSatisfy {abs($0-$1)<8},"base=\(baseline) key=\(removed)")

  var transition=p;transition.sequence.tracks[3].clips=[]
  let second=try await MediaImporter.inspect(url:fixture.videos[1]);transition.assets.append(second)
  transition.sequence.tracks[0].clips.append(Clip(assetID:second.id,start:MediaTime(3,1),duration:MediaTime(3,1)))
  var history=EditorHistory(project:transition)
  try history.apply(.crossDissolve(trackID:transition.sequence.tracks[0].id,clipID:transition.sequence.tracks[0].clips[0].id,duration:MediaTime(1,2)))
  check("Dissolve creates real overlap and shortens sequence",history.project.sequence.duration == MediaTime(11,2))
  let transitionPlan=try await TimelineRenderer.build(project:history.project)
  try await ExportJob().export(plan:transitionPlan,to:root.appendingPathComponent("dissolve.mp4")){_ in}
  check("Dissolve export decodes",try await MediaImporter.inspect(url:root.appendingPathComponent("dissolve.mp4")).supported)
  for kind in EditTemplate.Kind.allCases {
   let track=try EditTemplate.track(kind:kind,sequence:transition.sequence)
   check("\(kind.rawValue) has three editable titles",track.clips.count == 3 && track.clips.allSatisfy {$0.title != nil && $0.end <= transition.sequence.duration})
  }
  let inventory=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"Artifacts/Upgrade-0.5/source-inventory.json"))) as! [[String:Any]]
  if let hdr=inventory.first(where:{($0["color"] as? String ?? "").lowercased().contains("2020") && ($0["duration"] as? Double ?? 0)>2}) {
    let path=hdr["path"] as! String
    let converted=try await MediaPreparation.convertToSDR(url:URL(fileURLWithPath:path),destination:root.appendingPathComponent("real-hdr-to-sdr.mp4"),timeRange:CMTimeRange(start:.zero,duration:CMTime(seconds:2,preferredTimescale:600)))
    check("User HDR source converted to valid SDR",converted.supported && converted.colorInfo.contains("709"),converted.colorInfo)
  }
  let extracted=try await MediaPreparation.extractAudio(url:fixture.bgm,trackIndex:0,destination:root.appendingPathComponent("audio-track.m4a"))
  check("Selected audio track extraction",extracted.kind == .audio && extracted.hasAudio)
  try ProjectStore.save(styled,to:root.appendingPathComponent("effects.jhcut"))
  check("Color LUT/mask round trip",try ProjectStore.load(from:root.appendingPathComponent("effects.jhcut")).sequence == styled.sequence)
  try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))
  if checks.contains(where:{$0["passed"] as? Bool != true}) {exit(1)}
 }
 static func preview(_ plan:RenderPlan,time:Double) async throws -> CGImage {
  let generator=AVAssetImageGenerator(asset:plan.composition);generator.videoComposition=plan.videoComposition
  generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
  return try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
 }
 static func pixel(_ image:CGImage,x:Int,y:Int)->[Int] {
  var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
  let context=CGContext(data:&bytes,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
  let offset=(y*image.width+x)*4;return (0..<3).map {Int(bytes[offset+$0])}
 }
}

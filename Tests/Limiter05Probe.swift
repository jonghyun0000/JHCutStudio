import Foundation
import AVFoundation
import JHCutCore
@main struct Limiter05Probe {
 static func main() async throws {
  let root=URL(fileURLWithPath:"Artifacts/Upgrade-0.5/Limiter-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let url=root.appendingPathComponent("transients.wav"),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
  let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:144000)!;buffer.frameLength=144000
  for i in 0..<144000 {let value:Float=i%4800 < 8 ? 0.95 : Float(0.01*sin(Double(i)*2*Double.pi*997/48000));buffer.floatChannelData![0][i]=value;buffer.floatChannelData![1][i]=value}
  do {let writer=try AVAudioFile(forWriting:url,settings:format.settings);try writer.write(from:buffer)}
  let asset=try await MediaImporter.inspect(url:url)
  var p=Project();p.assets=[asset];p.sequence.width=640;p.sequence.height=360
  p.sequence.tracks[3].clips=[Clip(assetID:asset.id,duration:MediaTime(3,1),volume:2)]
  p.sequence.tracks.append(Track(name:"Overlapping transient",kind:.audio,clips:[Clip(assetID:asset.id,duration:MediaTime(3,1),volume:2)]))
  let plan=try await TimelineRenderer.build(project:p),result=try await MixMastering.render(plan:plan,to:root.appendingPathComponent("limited.caf"),targetLUFS:-14)
  var rows:[[String:Any]]=[]
  func check(_ name:String,_ passed:Bool){rows.append(["name":name,"passed":passed]);print("\(passed ? "PASS":"FAIL") \(name)")}
  check("Overlapping input actually exceeds full scale",(result.before.samplePeakDBFS ?? -100)>0)
  check("Limiter clamps real overload to -1.5 dBFS",(result.after.samplePeakDBFS ?? 0) <= -1.499 && (result.after.samplePeakDBFS ?? -100) > -1.51)
  check("Limiting preserves sample count",result.after.frames==144000)
  let analysis=try await AudioAnalysis.analyze(url:result.url)
  check("Decoded final CAF has no full-scale sample clipping",analysis.clippingSampleCount==0 && (analysis.peakDBFS ?? 0) <= -1.49)
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))
  print("Before \(result.before.samplePeakDBFS ?? 0), after \(result.after.samplePeakDBFS ?? 0), 4x estimate \(result.oversampledPeakDBFS ?? 0)")
  if rows.contains(where:{$0["passed"] as? Bool != true}) {exit(1)}
 }
}

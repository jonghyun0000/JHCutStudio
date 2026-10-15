import Foundation
import AVFoundation
import CoreGraphics
import JHCutCore

@main struct ProxyIntegrityProbe {
 static func main() async throws {
  setbuf(stdout,nil)
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/ProxyIntegrity"),fm=FileManager.default
  let original=URL(fileURLWithPath:"Artifacts/Stage15Copies/IMG_2351.mov")
  let sourceHash=try await FileIdentity.sha256(original)
  let source=root.appendingPathComponent("owned-source.mov");try fm.copyItem(at:original,to:source)
  let cache=ProxyCache(directory:root.appendingPathComponent("cache"))
  var checks:[[String:Any]]=[];var timings:[String:Double]=[:]
  func check(_ name:String,_ ok:Bool){checks.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") \(name)")}
  let start=Date();let proxy=try await cache.generate(for:source);timings["generationSeconds"]=Date().timeIntervalSince(start)
  let decoded=try await MediaInspection.decode(proxy)
  check("Actual4K proxy decodes all117 frames",decoded.frameCount==117 && decoded.monotonic && abs(decoded.videoEndSeconds-3.9)<0.04)
  check("Actual4K proxy aspect and dimensions",decoded.width==1280 && decoded.height==720)
  let hitStart=Date();check("Verified persistent hit",try await cache.cachedURL(for:source)==proxy);timings["fullChecksumHitSeconds"]=Date().timeIntervalSince(hitStart)
  let bytes=try Data(contentsOf:proxy).count
  let metadata=proxy.deletingPathExtension().appendingPathExtension("json")
  let goodMetadata=try Data(contentsOf:metadata)
  try Data(repeating:0,count:bytes).write(to:proxy)
  check("Same size corruption refused",try await cache.cachedURL(for:source)==nil)
  _=try await cache.generate(for:source)
  check("Corrupt proxy regenerates readable media",try await MediaInspection.decode(proxy).frameCount==117)
  try fm.removeItem(at:proxy)
  check("Missing proxy refused",try await cache.cachedURL(for:source)==nil)
  _=try await cache.generate(for:source)
  var legacy=try JSONSerialization.jsonObject(with:goodMetadata) as! [String:Any];legacy["version"]=1;legacy.removeValue(forKey:"sha256")
  try JSONSerialization.data(withJSONObject:legacy).write(to:metadata)
  check("Legacy receipt without checksum refused",try await cache.cachedURL(for:source)==nil)
  check("Legacy rejection preserves old file",fm.fileExists(atPath:proxy.path))
  _=try await cache.generate(for:source)
  let cancelled=Task { () -> Bool in
   withUnsafeCurrentTask { $0?.cancel() }
   do {_=try await cache.cachedURL(for:source);return false} catch is CancellationError {return true} catch {return false}
  }
  check("Cancelled integrity lookup propagates cancellation",await cancelled.value)
  let pressureStart=Date()
  do {var pressure=Data(count:128*1024*1024);pressure.withUnsafeMutableBytes { raw in for i in stride(from:0,to:raw.count,by:4096){raw[i]=0x7f} };check("Proxy lookup with128MiB owned allocation",try await cache.cachedURL(for:source)==proxy);withExtendedLifetime(pressure){}}
  timings["boundedAllocationLookupSeconds"]=Date().timeIntervalSince(pressureStart)
  await cache.setProtectedURLs([proxy]);try await cache.removeAll()
  check("Cache clear preserves active proxy",fm.fileExists(atPath:proxy.path))
  await cache.setProtectedURLs([]);try await cache.removeAll()
  check("Released cache clears and recovers",try await cache.cachedURL(for:source)==nil)
  _=try await cache.generate(for:source)
  // Compare rendered original/proxy at selected actual-camera frames; audio remains original.
  let a=try await MediaImporter.inspect(url:source);var p=Project(name:"Real4K equivalence");p.assets=[a];p.sequence.width=640;p.sequence.height=360
  p.sequence.tracks[0].clips=[Clip(name:a.name,assetID:a.id,start:.zero,duration:MediaTime(seconds:3.9))]
  let originalPlan=try await TimelineRenderer.build(project:p),proxyPlan=try await TimelineRenderer.build(project:p,mediaURLOverrides:[a.id:proxy])
  func generator(_ plan:RenderPlan)->AVAssetImageGenerator {let g=AVAssetImageGenerator(asset:plan.composition);g.videoComposition=plan.videoComposition;g.requestedTimeToleranceBefore = .zero;g.requestedTimeToleranceAfter = .zero;return g}
  let g=generator(originalPlan),h=generator(proxyPlan);var deltas:[Double]=[]
  for seconds in [0.5,1.5,3.0] {let t=CMTime(seconds:seconds,preferredTimescale:600);let x=try await g.image(at:t).image,y=try await h.image(at:t).image;let d=try MediaInspection.compare(x,y);deltas.append(d.mean);check("Original/proxy direction color frame \(seconds)",d.mean<0.04)}
  func audio(_ plan:RenderPlan) async throws -> (Int,Double) {
   let reader=try AVAssetReader(asset:plan.composition)
   let tracks=try await plan.composition.loadTracks(withMediaType:.audio)
   let output=AVAssetReaderAudioMixOutput(audioTracks:tracks,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,AVSampleRateKey:48000,AVNumberOfChannelsKey:2]);output.audioMix=plan.audioMix;reader.add(output)
   guard reader.startReading() else {throw ProjectError("audio start")};var n=0;var square=0.0
   while let sample=output.copyNextSampleBuffer() {guard let block=CMSampleBufferGetDataBuffer(sample) else {continue};let count=CMBlockBufferGetDataLength(block)/4;var floats=[Float](repeating:0,count:count);let result=floats.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count*4,destination:$0.baseAddress!)};guard result==noErr else {throw ProjectError("PCM copy")};for f in floats {square+=Double(f)*Double(f)};n+=count}
   guard reader.status == .completed else {throw reader.error ?? ProjectError("audio incomplete")};return(n,n>0 ? sqrt(square/Double(n)):0)
  }
  let originalAudio=try await audio(originalPlan),proxyAudio=try await audio(proxyPlan)
  check("Proxy render retains original audio duration and RMS",originalAudio.1>0 && abs(originalAudio.1-proxyAudio.1)<0.000001 && originalAudio.0==proxyAudio.0)
  let changed=try FileHandle(forWritingTo:source);try changed.seek(toOffset:0);try changed.write(contentsOf:Data(repeating:0,count:32));try changed.close()
  check("Changed owned source invalidates proxy identity",try await cache.cachedURL(for:source)==nil)
  let cancelCache=ProxyCache(directory:root.appendingPathComponent("cancel"))
  let task=Task {try await cancelCache.generate(for:original)};task.cancel();var wasCancelled=false
  do {_=try await task.value} catch is CancellationError {wasCancelled=true}
  check("Cancelled generation publishes no proxy",wasCancelled && ((try? fm.contentsOfDirectory(atPath:root.appendingPathComponent("cancel").path)) ?? []).isEmpty)
  let activeTask=Task {try await cancelCache.generate(for:original)}
  var sawScratch=false
  for _ in 0..<250 {if ((try? fm.contentsOfDirectory(atPath:root.appendingPathComponent("cancel").path)) ?? []).contains(where:{$0.hasPrefix(".generating-")}) {sawScratch=true;break};try await Task.sleep(nanoseconds:20_000_000)}
  activeTask.cancel();var activeCancelled=false
  do {_=try await activeTask.value} catch is CancellationError {activeCancelled=true}
  check("Active generation cancellation removes scratch and publication",sawScratch && activeCancelled && ((try? fm.contentsOfDirectory(atPath:root.appendingPathComponent("cancel").path)) ?? []).isEmpty)
  _=try await cancelCache.generate(for:original)
  check("Generation recovers after cancellation",try await cancelCache.cachedURL(for:original) != nil)
  // Capacity eviction is exercised with two distinct owned source paths.
  let eviction=ProxyCache(directory:root.appendingPathComponent("eviction"),limitBytes:Int64(bytes*3/2))
  let first=try await eviction.generate(for:original)
  let secondSource=root.appendingPathComponent("second.mov");try fm.copyItem(at:original,to:secondSource)
  _=try await eviction.generate(for:secondSource)
  check("Capacity eviction counted and older proxy removed",await eviction.metrics().evictions==1 && !fm.fileExists(atPath:first.path))
  check("Authorized original unchanged",try await FileIdentity.sha256(original)==sourceHash)
  let m=await cache.metrics()
  let report:[String:Any]=["checks":checks,"timings":timings,"colorMeanErrors":deltas,"metrics":["hits":m.hits,"misses":m.misses,"invalidEntries":m.invalidEntries,"generations":m.generations,"clearedEntries":m.clearedEntries,"verifiedBytes":m.verifiedBytes],"scope":"Actual3.9s4K SDR camera copy;117 decoded proxy frames; selected pixel equivalence at640x360; bounded128MiB allocation, not system-wide pressure; pre-start cancellation and recovery; proxy has video only and renderer retains original audio; source fault modifies only owned test copy."]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("proxy-integrity.json"))
  let failures=checks.filter {($0["passed"] as? Bool)==false}.count
  print("PROXY_INTEGRITY_RESULT checks=\(checks.count) failures=\(failures)");if failures>0 {exit(1)}
 }
}

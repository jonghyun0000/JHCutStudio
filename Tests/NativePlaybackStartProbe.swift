#if PLAYBACK_PROBE
import Foundation
import AVFoundation
import AppKit
import JHCutCore
/// Video output observes the native transport without replacing its audio mix with diagnostic taps.
/// Audio delivery and physical speaker output are not measured by this probe.
enum NativePlaybackStartProbe {
 @MainActor static func run(project:Project, cache:ProxyCache, proxyURLs:[UUID:URL], enabled:Bool, folder:URL, check:(String,Bool,String)->Void) async throws {
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let model=EditorModel(recoveryStore:RecoveryStore(directory:folder.appendingPathComponent("recovery")),exportHistoryURL:folder.appendingPathComponent("journal.json"),proxyCache:cache)
  model.history=EditorHistory(project:project);model.proxyURLs=proxyURLs;model.proxyEnabled=enabled;model.rebuild()
  for _ in 0..<2000 {if !model.isBuilding && model.player.currentItem?.status == .readyToPlay {break};try await Task.sleep(nanoseconds:5_000_000)}
  let label=project.name+" native transport"
  check(label+" ready",model.plan != nil && model.player.currentItem?.status == .readyToPlay,"no audio mix replacement")
  guard model.plan != nil,let item=model.player.currentItem,item.status == .readyToPlay else {return}
  let originalMix=item.audioMix
  let video=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(video)
  defer {model.pausePlayback();item.remove(video);model.player.replaceCurrentItem(with:nil)}
  var lastFrame:Double?;var frames=0
  func sample(){let time=model.player.currentTime();if video.hasNewPixelBuffer(forItemTime:time){var actual=CMTime.invalid;if video.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:&actual) != nil {frames += 1;lastFrame=actual.seconds}}}
  for target in [0.2,1.3,2.0,0.7,1.4] {
   model.seek(target);model.pausePlayback()
   for _ in 0..<400 {sample();if let lastFrame,abs(lastFrame-target)<model.frameStep*1.1 {break};try await Task.sleep(nanoseconds:5_000_000)}
  }
  let baseline=frames;let began=ProcessInfo.processInfo.systemUptime
  model.seek(0.2);model.togglePlay();try await Task.sleep(nanoseconds:600_000_000);sample()
  let time=model.player.currentTime().seconds, elapsed=(ProcessInfo.processInfo.systemUptime-began)*1000
  let passed=model.playing && frames>baseline && time>0.2+model.frameStep && (lastFrame ?? -1)>0.2+model.frameStep
  check(label+" first play advances clock and fresh video within 600ms",passed,"clock=\(time) frame=\(lastFrame ?? -1) newFrames=\(frames-baseline) observedMS=\(elapsed)")
  model.pausePlayback();try await Task.sleep(nanoseconds:500_000_000);sample();let stopped=model.player.currentTime().seconds,frame=lastFrame
  try await Task.sleep(nanoseconds:250_000_000);sample()
  check(label+" pause holds clock and decoded frame",!model.playing && model.player.rate==0 && model.player.currentTime().seconds==stopped && lastFrame==frame,"")
  check(label+" original audio mix retained",item.audioMix === originalMix,"no post-mix signal claim")
  try JSONSerialization.data(withJSONObject:["scope":"native clock and video; audio mix untouched; audio output not measured","passed":passed,"playerTime":time,"lastFrameTime":lastFrame ?? -1,"freshFrames":frames-baseline,"observedMilliseconds":elapsed],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"))
 }
}
#endif

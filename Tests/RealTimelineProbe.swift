import Foundation
import AVFoundation
import QuartzCore
import JHCutCore
@main struct RealTimelineProbe {
 @MainActor static func main() async throws {
  let root = URL(fileURLWithPath: "Artifacts/Upgrade-0.5/RealTimeline")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let folder = URL(fileURLWithPath: "/Volumes/T7/아이폰/동영상")
  let names = ["IMG_0140.mov", "IMG_0047.mov", "IMG_9211.mov", "IMG_2351.mov"]
  var assets: [MediaAsset] = []
  for name in names { let asset = try await MediaImporter.inspect(url: folder.appendingPathComponent(name)); guard asset.supported else { throw ProjectError(asset.issue ?? "Unsupported") }; assets.append(asset) }
  var project = Project(name: "실사 45분 다중 트랙 검증")
  project.assets = assets; project.sequence.width = 1280; project.sequence.height = 720
  var time = MediaTime.zero
  for asset in assets.prefix(3) {
    var source = MediaTime.zero
    while source + MediaTime(5,1) <= asset.duration {
      project.sequence.tracks[0].clips.append(Clip(name: asset.name, assetID: asset.id, start: time, sourceStart: source, duration: MediaTime(5,1)))
      source = source + MediaTime(5,1); time = time + MediaTime(5,1)
    }
  }
  for second in stride(from: 0, to: Int(time.seconds), by: 60) {
    project.sequence.tracks[1].clips.append(Clip(name: "4K overlay", assetID: assets[3].id, start: MediaTime(Int64(second),1), duration: MediaTime(3,1), volume: 0, transform: ClipTransform(scale: 0.3)))
    project.sequence.tracks[2].clips.append(Clip(start: MediaTime(Int64(second),1), duration: MediaTime(4,1), title: TitleSizing.title(for: TitlePreset.builtIns[0], width: 1280, height: 720)))
  }
  try ProjectStore.save(project, to: root.appendingPathComponent("실사-45분.jhcut"))
  let began = Date(), plan = try await TimelineRenderer.build(project: project, cacheInspection: true)
  var report: [String: Any] = ["duration": time.seconds, "clips": project.sequence.tracks.flatMap(\.clips).count, "buildSeconds": Date().timeIntervalSince(began), "synthetic": false, "sourceNames": names]
  let player = AVPlayer(playerItem: plan.makePlayerItem())
  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
  player.currentItem?.add(output)
  for _ in 0..<1000 { if player.currentItem?.status == .readyToPlay { break }; try await Task.sleep(nanoseconds: 10_000_000) }
  var samples: [[String: Any]] = []
  for location in [0.0, 601.0, 1201.0, 2101.0, time.seconds - 15] {
    let seekBegan = Date()
    await player.seek(to: CMTime(seconds: location, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    let seekSeconds = Date().timeIntervalSince(seekBegan)
    player.play(); let start = Date(); var frames = 0
    while Date().timeIntervalSince(start) < 8 {
      let requested = output.itemTime(forHostTime: CACurrentMediaTime())
      if output.hasNewPixelBuffer(forItemTime: requested), output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: nil) != nil { frames += 1 }
      try await Task.sleep(nanoseconds: 8_000_000)
    }
    let pauseBegan = Date(); player.pause(); let pauseSeconds = Date().timeIntervalSince(pauseBegan)
    let stopped = player.currentTime().seconds; try await Task.sleep(nanoseconds: 300_000_000)
    samples.append(["position": location, "seekSeconds": seekSeconds, "observedFrames8s": frames, "pauseCallSeconds": pauseSeconds, "pauseHeld": abs(player.currentTime().seconds-stopped)<0.04, "advanceSeconds": stopped-location])
  }
  report["playbackSamples"] = samples
  report["dropMeasurement"] = "VideoOutput observed frames over 8 seconds; not an AVPlayer hardware dropped-frame counter"
  try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("playback.json"))
  print("Real playback completed", report["duration"]!, report["clips"]!)
  if CommandLine.arguments.contains("--export") {
    let destination = root.appendingPathComponent("실사-45분-검증.mp4")
    let exportBegan = Date()
    try await ExportJob(videoBitRate: 4_000_000).export(plan: plan, to: destination) { progress in if Int(progress*100)%10==0 { print("export \(Int(progress*100))%") } }
    let asset = AVURLAsset(url: destination), duration = try await asset.load(.duration)
    report["exportSeconds"] = Date().timeIntervalSince(exportBegan); report["exportDuration"] = duration.seconds
    let audio = try await asset.loadTracks(withMediaType: .audio)
    if let track = audio.first { report["audioEnd"] = try await track.load(.timeRange).end.seconds }
    report["exportPath"] = destination.path
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("report.json"))
    print("Real export completed", report["exportSeconds"]!)
  }
 }
}

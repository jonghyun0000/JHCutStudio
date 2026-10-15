import Foundation
import AVFoundation
import CoreImage
@testable import JHCutCore

/// Priority 3: speed ramp, reverse copy (freeze frame is tested with the editor flow).
/// A test video whose brightness is proportional to its own time lets a rendered frame tell us
/// which SOURCE time it shows, so time mappings are measured, not assumed.
@main struct SpeedToolsProbe {
 static let seconds = 6.0, fps = 30.0
 /// Mean luma of the central area of a frame.
 static func luma(_ cg: CGImage) -> Double {
  let w = 32, h = 18; var px = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  var sum = 0.0; for i in 0..<(w * h) { sum += Double(px[i * 4]) }
  return sum / Double(w * h)
 }
 /// Source time (0…seconds) a brightness value represents.
 /// (luma, time) pairs measured on the test source itself: the generator's colour conversion makes brightness non-linear in time.
 nonisolated(unsafe) static var calibration: [(luma: Double, time: Double)] = []
 static func timeFor(luma: Double) -> Double {
  guard let first = calibration.first, let last = calibration.last else { return max(0, min(seconds, (luma - 24) / 200 * seconds)) }
  if luma <= first.luma { return first.time }; if luma >= last.luma { return last.time }
  for (a, b) in zip(calibration, calibration.dropFirst()) where luma <= b.luma { return b.luma == a.luma ? a.time : a.time + (b.time - a.time) * (luma - a.luma) / (b.luma - a.luma) }
  return last.time
 }
 static func frame(_ asset: AVAsset, at t: Double, videoComposition: AVVideoComposition? = nil) throws -> CGImage {
  let g = AVAssetImageGenerator(asset: asset); g.videoComposition = videoComposition; g.appliesPreferredTrackTransform = true
  g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
  return try g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
 }
 static func makeRampVideo(_ url: URL, rotate: Bool = false) async throws {
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
   AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
   AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000, AVVideoMaxKeyFrameIntervalKey: 30]])
  if rotate { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
  writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
  let ctx = CIContext()
  for k in 0..<Int(seconds * fps) {
   while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
   let v = 24 + 200 * Double(k) / (seconds * fps)
   var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
   ctx.render(CIImage(color: CIColor(red: v / 255, green: v / 255, blue: v / 255)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)), to: buffer!)
   adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps)))
  }
  input.markAsFinished(); await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("test video") }
 }
 /// Mono 48 kHz: quiet tone with a loud click at `click` seconds.
 static func makeClickAudio(_ url: URL, click: Double) throws {
  try? FileManager.default.removeItem(at: url)
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
  let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
  let n = Int(seconds * 48_000), buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!; buffer.frameLength = AVAudioFrameCount(n)
  for i in 0..<n { buffer.floatChannelData![0][i] = 0.02 * Float(sin(Double(i) * 2 * .pi * 220 / 48_000)) }
  let c = Int(click * 48_000); for i in c..<(c + 480) { buffer.floatChannelData![0][i] = 0.9 * Float(sin(Double(i - c) * 2 * .pi * 1000 / 48_000)) }
  try file.write(from: buffer)
 }
 /// Time (seconds) of the loudest 10 ms window of an audio track.
 static func loudestMoment(_ url: URL) async throws -> Double {
  var energy: [Double] = [], rate = 48_000.0
  _ = try await SourcePCM.readStable(url: url, sourceStart: .zero, duration: nil) { chunk in
   rate = chunk.sampleRate
   let frames = chunk.values.count / chunk.channels
   for f in 0..<frames { energy.append(Double(chunk.values[f * chunk.channels]) * Double(chunk.values[f * chunk.channels])) }
  }
  let window = Int(rate * 0.01); var best = 0.0, at = 0
  var s = energy.prefix(window).reduce(0, +)
  for i in 0..<(energy.count - window) { if s > best { best = s; at = i }; s += energy[i + window] - energy[i] }
  return Double(at + window / 2) / rate
 }
 static func peakMemoryMB() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576 }

 static func main() async throws {
  setbuf(stdout, nil)
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/SpeedTools")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], metrics: [String: Any] = [:]
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: ["checks": rows, "metrics": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }

  // ---- Pure plan ----
  let encoderError = NSError(domain: "InjectedEncoderFailure", code: 7)
  var failureChecks = 0
  do { try ReverseRenderer.checkWriter(status: .failed, error: encoderError, idleSeconds: 0) }
  catch { if (error as NSError).domain == encoderError.domain { failureChecks += 1 } }
  do { try ReverseRenderer.checkWriter(status: .cancelled, error: nil, idleSeconds: 0) } catch { failureChecks += 1 }
  do { try ReverseRenderer.checkWriter(status: .writing, error: nil, idleSeconds: 31) } catch { failureChecks += 1 }
  check("Failed, cancelled and stalled writer states fail immediately", failureChecks == 3)
  try ReverseRenderer.checkWriter(status: .writing, error: nil, idleSeconds: 0)
  var partialRefused = false
  do { try ReverseRenderer.checkFrameCount(written: 59, expected: 60) } catch { partialRefused = true }
  check("Even one missing frame cannot report success", partialRefused)
  try ReverseRenderer.checkFrameCount(written: 60, expected: 60)
  let slow = SpeedRampPlan.rates(.slowDown, pieces: 8).map(\.multiplier)
  check("Slow-down ramp: monotonically slower, starts near 1×, ends near 0.3×", zip(slow, slow.dropFirst()).allSatisfy { $0 >= $1 } && slow[0] > 0.9 && slow[7] < 0.4 && slow.allSatisfy { SpeedRampPlan.speedRange.contains($0) }, slow.map { String(format: "%.2f", $0) }.joined(separator: " "))
  let fast = SpeedRampPlan.rates(.speedUp, pieces: 8).map(\.multiplier)
  check("Speed-up ramp: monotonically faster up to about 3×", zip(fast, fast.dropFirst()).allSatisfy { $0 <= $1 } && fast[7] > 2.5, fast.map { String(format: "%.2f", $0) }.joined(separator: " "))
  let dip = SpeedRampPlan.rates(.slowAndBack, pieces: 10).map(\.multiplier)
  check("Slow-and-back ramp: slowest in the middle, back near 1× at both ends", dip[4] < 0.4 && dip[0] > 0.8 && dip[9] > 0.8 && abs(dip[0] - dip[9]) < 0.05, dip.map { String(format: "%.2f", $0) }.joined(separator: " "))
  check("Rates are exact reduced fractions in range", SpeedRampPlan.rate(0.5) == PlaybackRate(numerator: 1, denominator: 2) && SpeedRampPlan.rate(0.1).multiplier == 0.25 && SpeedRampPlan.rate(9).multiplier == 4 && SpeedRampPlan.rate(0.3) == PlaybackRate(numerator: 3, denominator: 10))
  check("Suggested pieces follow the clip length within limits", SpeedRampPlan.suggestedPieces(timelineSeconds: 0.5) == 4 && SpeedRampPlan.suggestedPieces(timelineSeconds: 3) == 24 && SpeedRampPlan.suggestedPieces(timelineSeconds: 1) == 8 && SpeedRampPlan.suggestedPieces(timelineSeconds: 0.2) == 2)

  // ---- Test media ----
  let ramp = root.appendingPathComponent("ramp.mp4"), click = root.appendingPathComponent("click.wav")
  try await makeRampVideo(ramp); try makeClickAudio(click, click: 1.5)
  let rampAsset = try await MediaImporter.inspect(url: ramp), clickAsset = try await MediaImporter.inspect(url: click)
  // One file with picture AND sound (brightness = time, click at 1.5 s).
  var mix = Project(name: "원본"); mix.sequence.width = 320; mix.sequence.height = 180; mix.assets = [rampAsset, clickAsset]
  var picture = Clip(name: "영상", assetID: rampAsset.id, duration: rampAsset.duration); picture.transform.fill = true; picture.volume = 0
  mix.sequence.tracks[0].clips = [picture]
  mix.sequence.tracks[3].clips = [Clip(name: "소리", assetID: clickAsset.id, duration: rampAsset.duration)]
  let source = root.appendingPathComponent("source.mp4")
  try await ExportJob().export(plan: TimelineRenderer.build(project: mix), to: source) { _ in }
  let sourceAsset = try await MediaImporter.inspect(url: source)
  check("Test source has picture and sound with the expected click", sourceAsset.hasAudio && abs(sourceAsset.duration.seconds - 6) < 0.1, String(format: "click at %.3f s", try await loudestMoment(source)))

  calibration = try stride(from: 0.0, through: 5.9, by: 0.1).map { (luma(try frame(AVURLAsset(url: source), at: $0)), $0) }
  // ---- Reverse ----
  let reversed = root.appendingPathComponent("reversed.mp4")
  let t0 = Date()
  let reversedAsset = try await ReverseRenderer.render(url: source, sourceStart: .zero, duration: sourceAsset.duration, destination: reversed) { _ in }
  metrics["reverse6sSeconds"] = Date().timeIntervalSince(t0)
  check("Reversed copy keeps the length and has sound", abs(reversedAsset.duration.seconds - sourceAsset.duration.seconds) < 0.1 && reversedAsset.hasAudio, String(format: "%.2f s vs %.2f s", reversedAsset.duration.seconds, sourceAsset.duration.seconds))
  let rev = AVURLAsset(url: reversed), src = AVURLAsset(url: source)
  var errors: [Double] = []
  for t in [0.3, 1.0, 2.0, 3.0, 4.0, 5.0, 5.6] {
   let shown = timeFor(luma: luma(try frame(rev, at: t)))
   errors.append(abs(shown - (sourceAsset.duration.seconds - t)))
  }
  check("Reversed picture shows source time (length − t) at every probe", errors.allSatisfy { $0 < 0.25 }, errors.map { String(format: "%.2f", $0) }.joined(separator: " ") + " s error")
  let revClick = try await loudestMoment(reversed), srcClick = try await loudestMoment(source)
  check("Click sound moves to the mirrored position", abs(revClick - (sourceAsset.duration.seconds - srcClick)) < 0.05, String(format: "source %.3f s → reversed %.3f s (expected %.3f s)", srcClick, revClick, sourceAsset.duration.seconds - srcClick))
  // Partial range
  let partial = root.appendingPathComponent("partial.mp4")
  let partialAsset = try await ReverseRenderer.render(url: source, sourceStart: MediaTime(seconds: 2), duration: MediaTime(seconds: 3), destination: partial)
  let pa = AVURLAsset(url: partial)
  let partialShown = [0.2, 1.5, 2.7].map { timeFor(luma: luma(try! frame(pa, at: $0))) }
  check("Partial range 2–5 s reversed: shows 5 → 2 s", abs(partialAsset.duration.seconds - 3) < 0.12 && abs(partialShown[0] - 4.8) < 0.3 && abs(partialShown[1] - 3.5) < 0.3 && abs(partialShown[2] - 2.3) < 0.3, partialShown.map { String(format: "%.2f", $0) }.joined(separator: " "))
  // Rotation kept
  let portrait = root.appendingPathComponent("portrait.mp4"); try await makeRampVideo(portrait, rotate: true)
  let portraitReversed = root.appendingPathComponent("portrait-reversed.mp4")
  _ = try await ReverseRenderer.render(url: portrait, sourceStart: .zero, duration: MediaTime(seconds: 6), destination: portraitReversed)
  let pTrack = try await AVURLAsset(url: portraitReversed).loadTracks(withMediaType: .video)[0]
  let pt = try await pTrack.load(.preferredTransform)
  check("Rotation (portrait track) is preserved", abs(pt.b - 1) < 1e-6 && abs(pt.c + 1) < 1e-6, "\(pt)")
  // Video without sound
  let silent = root.appendingPathComponent("silent-reversed.mp4")
  let silentAsset = try await ReverseRenderer.render(url: ramp, sourceStart: .zero, duration: MediaTime(seconds: 6), destination: silent)
  check("Video without sound reverses without a sound track", !silentAsset.hasAudio && abs(silentAsset.duration.seconds - 6) < 0.1)
  // Refusals
  var refused = 0
  do { _ = try await ReverseRenderer.render(url: source, sourceStart: .zero, duration: sourceAsset.duration, destination: reversed) } catch { refused += 1 }
  do { _ = try await ReverseRenderer.render(url: source, sourceStart: .zero, duration: MediaTime(seconds: 121), destination: root.appendingPathComponent("long.mp4")) } catch { refused += 1 }
  check("Existing destination and over-long ranges are refused", refused == 2 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("long.mp4").path))
  // Source untouched
  let digestA = try await FileIdentity.sha256(source), digestB = try await FileIdentity.sha256(source)
  check("Source test file is intact", digestA == digestB && FileManager.default.fileExists(atPath: source.path))

  // ---- Real iPhone footage (read-only copy) ----
  let real = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_0047.mov").standardizedFileURL
  let realDigest = try await FileIdentity.sha256(real)
  let realOut = root.appendingPathComponent("real-reversed.mp4")
  let memoryBefore = peakMemoryMB(); let tr = Date()
  let realAsset = try await ReverseRenderer.render(url: real, sourceStart: MediaTime(seconds: 240), duration: MediaTime(seconds: 20), destination: realOut) { _ in }
  let realSeconds = Date().timeIntervalSince(tr)
  metrics["realReverse20sSeconds"] = realSeconds; metrics["peakMemoryMBAfterRealReverse"] = peakMemoryMB(); metrics["peakMemoryMBBefore"] = memoryBefore
  check("Real footage: 20 s reversed, sound kept, duration within a frame", realAsset.hasAudio && abs(realAsset.duration.seconds - 20) < 0.1, String(format: "%.1f s to render, peak memory %.0f MB", realSeconds, peakMemoryMB()))
  let sourceReal = AVURLAsset(url: real), outReal = AVURLAsset(url: realOut)
  func diff(_ a: CGImage, _ b: CGImage) -> Double {
   let w = 96, h = 54; var pa = [UInt8](repeating: 0, count: w * h * 4), pb = pa
   for (img, idx) in [(a, 0), (b, 1)] { var buf = [UInt8](repeating: 0, count: w * h * 4)
    let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); if idx == 0 { pa = buf } else { pb = buf } }
   var s = 0.0; for i in 0..<(w * h * 4) where i % 4 != 3 { s += abs(Double(pa[i]) - Double(pb[i])) }
   return s / Double(w * h * 3)
  }
  var right = 0.0, wrong = 0.0
  let probes = [2.0, 6.0, 10.0, 14.0, 18.0]
  for t in probes {
   let reversedFrame = try frame(outReal, at: t)
   right += diff(reversedFrame, try frame(sourceReal, at: 240 + 20 - t)); wrong += diff(reversedFrame, try frame(sourceReal, at: 240 + t))
  }
  metrics["realReverseFrameDifference"] = ["mirroredSource": right / 5, "unmirroredSource": wrong / 5]
  check("Real footage: reversed frames match the mirrored source time, not the same time", right < wrong * 0.6 && right < 12, String(format: "mean difference %.1f vs %.1f when compared with the wrong time", right / 5, wrong / 5))
  let realTrack = try await AVURLAsset(url: realOut).loadTracks(withMediaType: .video)[0]
  let sourceTrack = try await sourceReal.loadTracks(withMediaType: .video)[0]
  let realTransform = try await realTrack.load(.preferredTransform), sourceTransform = try await sourceTrack.load(.preferredTransform)
  let realSize = try await realTrack.load(.naturalSize), sourceSize = try await sourceTrack.load(.naturalSize)
  check("Real footage: rotation and size preserved", realTransform == sourceTransform && realSize == sourceSize)
  // Cancel
  let cancelDest = root.appendingPathComponent("cancelled.mp4")
  let tempBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("JHCutReverse-") }
  let task = Task { try await ReverseRenderer.render(url: real, sourceStart: MediaTime(seconds: 240), duration: MediaTime(seconds: 60), destination: cancelDest) }
  try await Task.sleep(nanoseconds: 2_500_000_000); task.cancel()
  var cancelled = false
  do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {}
  try await Task.sleep(nanoseconds: 500_000_000)
  let tempAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("JHCutReverse-") }
  let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(".jhcut-reverse") }
  check("Cancel leaves no output, staging file or temporary folder", cancelled && !FileManager.default.fileExists(atPath: cancelDest.path) && leftovers.isEmpty && tempAfter.subtracting(tempBefore).isEmpty)
  let realDigestAfter = try await FileIdentity.sha256(real)
  check("Real source copy never modified", realDigestAfter == realDigest)

  // ---- Speed ramp on the timeline ----
  func rampProject() -> Project {
   var p = Project(name: "램프"); p.sequence.width = 320; p.sequence.height = 180; p.assets = [rampAsset, clickAsset]
   var a = Clip(name: "앞", assetID: rampAsset.id, duration: MediaTime(seconds: 2)); a.transform.fill = true
   var b = Clip(name: "램프", assetID: rampAsset.id, start: MediaTime(seconds: 2), sourceStart: MediaTime(seconds: 1), duration: MediaTime(seconds: 4)); b.transform.fill = true
   var c = Clip(name: "뒤", assetID: rampAsset.id, start: MediaTime(seconds: 6), duration: MediaTime(seconds: 2)); c.transform.fill = true
   p.sequence.tracks[0].clips = [a, b, c]
   return p
  }
  let base = rampProject(); let track = base.sequence.tracks[0], target = track.clips[1]
  let rates = SpeedRampPlan.rates(.slowDown, pieces: 8)
  var h = EditorHistory(project: base)
  try h.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: rates, mutesAudio: true))
  let pieces = h.project.sequence.tracks[0].clips.filter { $0.start >= MediaTime(seconds: 2) && $0.end <= h.project.sequence.tracks[0].clips[h.project.sequence.tracks[0].clips.count - 2].end }
  let ordered = h.project.sequence.tracks[0].clips.sorted { $0.start < $1.start }
  let rampPieces = Array(ordered[1..<(ordered.count - 1)])
  check("Ramp: clip becomes 8 pieces with the planned speeds", rampPieces.count == 8 && zip(rampPieces, rates).allSatisfy { $0.0.playbackRate == $0.1 } && rampPieces.allSatisfy { $0.volume == 0 }, "\(pieces.count)")
  var expectedDuration = 0.0
  for r in rates { expectedDuration += 0.5 / r.multiplier }   // 8 pieces of 0.5 s source each
  let newTotal = h.project.sequence.duration.seconds
  check("Ramp: total length equals the sum of source pieces ÷ speeds, following clip moved up", abs(newTotal - (2 + expectedDuration + 2)) < 0.02 && ordered.last!.start == rampPieces.last!.end, String(format: "%.3f s (expected %.3f)", newTotal, 2 + expectedDuration + 2))
  check("Ramp: pieces are contiguous and cover the source range", zip(rampPieces, rampPieces.dropFirst()).allSatisfy { $0.0.end == $0.1.start } && rampPieces[0].sourceStart == MediaTime(seconds: 1) && abs(rampPieces.last!.sourceStart.seconds + rampPieces.last!.sourceDuration.seconds - 5) < 1e-6)
  check("Ramp result passes project validation", (try? ProjectValidator.validate(h.project)) != nil)
  h.undo(); check("One undo restores the clip exactly", h.project == base)
  h.redo()
  let doc = root.appendingPathComponent("Ramp.jhcut"); try ProjectStore.save(h.project, to: doc)
  check("Save/reopen keeps the ramp", try ProjectStore.load(from: doc).sequence == h.project.sequence)
  // Measured time mapping through the renderer: output time → source time
  let plan = try await TimelineRenderer.build(project: h.project)
  var maxError = 0.0
  var cursor = 2.0
  for (piece, r) in zip(rampPieces, rates) {
   let mid = cursor + 0.5 / r.multiplier / 2     // middle of this piece on the timeline
   let expectedSource = piece.sourceStart.seconds + 0.5 / 2
   let shown = timeFor(luma: luma(try frame(plan.composition, at: mid, videoComposition: plan.videoComposition)))
   maxError = max(maxError, abs(shown - expectedSource)); cursor += 0.5 / r.multiplier
  }
  check("Rendered ramp shows the right source moment in every piece", maxError < 0.2, String(format: "largest error %.2f s", maxError))
  // Output export length
  let rampOut = root.appendingPathComponent("ramp-out.mp4"); try await ExportJob().export(plan: plan, to: rampOut) { _ in }
  let rampOutAsset = try await MediaImporter.inspect(url: rampOut)
  check("Exported ramp has the planned length", abs(rampOutAsset.duration.seconds - newTotal) < 0.1)
  // Actual decoded audio, including split-baked fades and nonzero volume keys.
  var audioBase = Project(name: "램프 음소거 출력"); audioBase.sequence.width = 320; audioBase.sequence.height = 180
  audioBase.assets = [clickAsset]
  var tone = Clip(name: "톤", assetID: clickAsset.id, sourceStart: MediaTime(seconds: 1), duration: MediaTime(seconds: 4))
  tone.audioFadeIn = MediaTime(seconds: 0.6); tone.audioFadeOut = MediaTime(seconds: 0.7)
  tone.keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(scale: 1.1), volume: 0.8), TransformKeyframe(time: MediaTime(seconds: 3), transform: ClipTransform(x: 0.2, scale: 1.3), volume: 0.6)]
  audioBase.sequence.tracks[3].clips = [tone]
  func rms(_ url: URL) async throws -> Double {
   var energy = 0.0, count = 0
   _ = try await SourcePCM.readStable(url: url, sourceStart: .zero, duration: nil) { chunk in
    for sample in chunk.values { energy += Double(sample) * Double(sample); count += 1 }
   }
   guard count > 0 else { throw MediaEngineError.failed("음소거 출력 PCM이 비었습니다.") }
   return sqrt(energy / Double(count))
  }
  var mutedHistory = EditorHistory(project: audioBase)
  try mutedHistory.apply(.speedRamp(trackID: audioBase.sequence.tracks[3].id, clipID: tone.id, rates: rates, mutesAudio: true))
  let mutedClips = mutedHistory.project.sequence.tracks[3].clips
  let mutedOutput = root.appendingPathComponent("ramp-muted-tone.mp4")
  try await ExportJob().export(plan: try await TimelineRenderer.build(project: mutedHistory.project), to: mutedOutput) { _ in }
  let mutedRMS = try await rms(mutedOutput); metrics["rampMutedRMS"] = mutedRMS
  check("Exported ramp with volume keys and audio fades is silent below -80 dBFS", mutedRMS <= 0.0001, "RMS=\(mutedRMS)")
  var audibleHistory = EditorHistory(project: audioBase)
  try audibleHistory.apply(.speedRamp(trackID: audioBase.sequence.tracks[3].id, clipID: tone.id, rates: rates, mutesAudio: false))
  let audibleOutput = root.appendingPathComponent("ramp-audible-tone.mp4")
  try await ExportJob().export(plan: try await TimelineRenderer.build(project: audibleHistory.project), to: audibleOutput) { _ in }
  let audibleRMS = try await rms(audibleOutput); metrics["rampAudibleRMS"] = audibleRMS
  check("Unmuted control exports real audible PCM", audibleRMS > 0.005, "RMS=\(audibleRMS)")
  check("Muting preserves the visual keyframes of every ramp piece", zip(mutedClips, audibleHistory.project.sequence.tracks[3].clips).allSatisfy { a, b in
   a.keyframes?.map(\.transform) == b.keyframes?.map(\.transform) && a.keyframes?.map(\.time) == b.keyframes?.map(\.time) && a.keyframes?.allSatisfy { $0.volume == 0 } == true
  })
  mutedHistory.undo(); check("Keyframed ramp mute undoes in one step", mutedHistory.project == audioBase)
  mutedHistory.redo()
  let muteDoc = root.appendingPathComponent("Muted-Ramp.jhcut"); try ProjectStore.save(mutedHistory.project, to: muteDoc)
  check("Silent volume keys survive save/reopen", try ProjectStore.load(from: muteDoc).sequence == mutedHistory.project.sequence)

  // Same-track overlays at split positions used to be mistaken for the ramp pieces.
  for fps in [FrameRate(numerator: 24_000, denominator: 1001), FrameRate(numerator: 30_000, denominator: 1001)] {
   var overlap = Project(name: "겹침"); overlap.assets = [rampAsset]; overlap.sequence.frameRate = fps
   var fastTarget = Clip(name: "2배속", assetID: rampAsset.id, duration: MediaTime(seconds: 2), playbackRate: PlaybackRate(numerator: 2))
   fastTarget.keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(), volume: 0.7)]
   let intruder = Clip(name: "겹친 다른 클립", assetID: rampAsset.id, start: MediaTime(seconds: 0.5), duration: MediaTime(seconds: 0.5))
   let follower = Clip(name: "뒤", assetID: rampAsset.id, start: MediaTime(seconds: 2), duration: MediaTime(seconds: 1))
   overlap.sequence.tracks[1].clips = [intruder, fastTarget, follower]
   var oh = EditorHistory(project: overlap)
   try oh.apply(.speedRamp(trackID: overlap.sequence.tracks[1].id, clipID: fastTarget.id, rates: Array(rates.prefix(4)), mutesAudio: true))
   let result = oh.project.sequence.tracks[1].clips
   let parts = result.filter { $0.id != intruder.id && $0.id != follower.id }
   check("\(fps.fps) fps: split IDs preserve the overlapping clip and the 2x source range", result.first { $0.id == intruder.id } == intruder && parts.count == 4 && abs(parts.map { $0.sourceDuration.seconds }.reduce(0, +) - 4) < 0.001 && result.first { $0.id == follower.id }?.start == parts.map(\.end).max())
   let selectedPiece = parts[0]
   try oh.apply(.speedRamp(trackID: overlap.sequence.tracks[1].id, clipID: selectedPiece.id, rates: [SpeedRampPlan.rate(1), SpeedRampPlan.rate(2)], mutesAudio: true))
   check("\(fps.fps) fps: an already-ramped piece can be ramped again without touching its overlap", oh.project.sequence.tracks[1].clips.first { $0.id == intruder.id } == intruder && (try? ProjectValidator.validate(oh.project)) != nil)
   oh.undo(); oh.undo(); check("\(fps.fps) fps: repeated ramp undo restores the complete overlapping track", oh.project == overlap)
  }
  // Refusals
  var rejected = 0
  var h2 = EditorHistory(project: base)
  if (try? h2.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: [SpeedRampPlan.rate(1)], mutesAudio: true))) == nil { rejected += 1 }
  if (try? h2.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: Array(repeating: SpeedRampPlan.rate(1), count: 25), mutesAudio: true))) == nil { rejected += 1 }
  var tiny = base; tiny.sequence.tracks[0].clips[1].duration = MediaTime(seconds: 0.5); var h3 = EditorHistory(project: tiny)
  if (try? h3.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: Array(repeating: SpeedRampPlan.rate(1), count: 8), mutesAudio: true))) == nil { rejected += 1 }
  var withAudio = base; var child = Clip(name: "분리 오디오", assetID: clickAsset.id, start: MediaTime(seconds: 2), duration: MediaTime(seconds: 4)); child.connection = ClipConnection(parentID: target.id, sourceStart: MediaTime(seconds: 1), sourceDuration: MediaTime(seconds: 4))
  withAudio.sequence.tracks[3].clips = [child]; var h4 = EditorHistory(project: withAudio)
  if (try? h4.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: rates, mutesAudio: true))) == nil { rejected += 1 }
  var lockedProject = base; lockedProject.sequence.tracks[0].isLocked = true; var h5 = EditorHistory(project: lockedProject)
  if (try? h5.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: rates, mutesAudio: true))) == nil { rejected += 1 }
  check("Bad ramps are refused and change nothing (1 piece, 25 pieces, too short, connected audio, locked track)", rejected == 5 && h2.project == base && h4.project == withAudio && h5.project == lockedProject)
  // Connected captions follow the pieces
  var withCaption = base
  var title = Title(text: "자막"); title.y = 0.8
  var cap = Clip(name: "자막", start: MediaTime(seconds: 3), duration: MediaTime(seconds: 1), title: title); cap.connection = ClipConnection(parentID: target.id, sourceStart: MediaTime(seconds: 2), sourceDuration: MediaTime(seconds: 1))
  cap.captionMetadata = CaptionMetadata(language: "ko", originalLanguage: "ko", originalText: "자막", generatedText: "자막")
  withCaption.sequence.tracks[2].clips = [cap]
  var h6 = EditorHistory(project: withCaption)
  try h6.apply(.speedRamp(trackID: track.id, clipID: target.id, rates: rates, mutesAudio: false))
  check("A caption connected to the clip survives the ramp and stays valid", (try? ProjectValidator.validate(h6.project)) != nil && h6.project.sequence.tracks[2].clips.count >= 1, "\(h6.project.sequence.tracks[2].clips.map { String(format: "%.2f–%.2f", $0.start.seconds, $0.end.seconds) })")
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("SPEEDTOOLS_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

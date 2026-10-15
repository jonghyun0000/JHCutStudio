import Foundation
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import JHCutCore

/// Editor flows for the speed tools: ramp, freeze frame and reverse copy through the same model the window uses.
@main struct SpeedEditorProbe {
 static func makeVideo(_ url: URL, seconds: Double = 6, pattern: Bool = false) async throws {
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
   AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
  writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
  let ctx = CIContext(); let fps = 30.0
  for k in 0..<Int(seconds * fps) {
   while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
   let v = 24 + 200 * Double(k) / (seconds * fps)
   var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
   var image = CIImage(color: CIColor(red: v / 255, green: v / 255, blue: v / 255)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
   if pattern {
    image = CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.2)).cropped(to: CGRect(x: 14 + k % 25, y: 17, width: 85, height: 115)).composited(over: image)
    image = CIImage(color: CIColor(red: 0.1, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 183, y: 87, width: 118, height: 60)).composited(over: image)
   }
   ctx.render(image, to: buffer!)
   adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps)))
  }
  input.markAsFinished(); await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? ProjectError("검증 영상 생성 실패") }
 }
 static func pixels(_ image: CGImage) -> [UInt8] {
  let w = 160, h = 90; var bytes = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return bytes
 }
 static func pixelError(_ a: CGImage, _ b: CGImage) -> Double {
  let aa = pixels(a), bb = pixels(b)
  return zip(aa.indices, aa).filter { $0.0 % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.1) - Double(bb[$1.0])) } / Double(160 * 90 * 3)
 }
 static func onBlack(_ image: CGImage) -> CGImage {
  let ci = CIImage(cgImage: image)
  let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
  return context.createCGImage(ci.composited(over: CIImage(color: .black).cropped(to: ci.extent)), from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
 }
 static func exactFrameTimes(_ url: URL, rate: FrameRate) async throws -> Bool {
  let asset = AVURLAsset(url: url); let track = try await asset.loadTracks(withMediaType: .video).first!
  // Decode actual video frames. Compressed output also contains empty codec/header
  // and end marker buffers, which must not be counted as displayed frames.
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(output); guard reader.startReading() else { throw reader.error ?? ProjectError("출력 시각 읽기 실패") }
  var index: Int64 = 0, matches = true
  while let sample = output.copyNextSampleBuffer() {
   guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
   matches = matches && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), rate.time(forFrame: index).cmTime) == 0
   index += 1
  }
  return matches && index > 0 && reader.status == .completed
 }
 static func renderedFrame(_ plan: RenderPlan, at time: MediaTime) async throws -> CGImage {
  let generator = AVAssetImageGenerator(asset: plan.composition); generator.videoComposition = plan.videoComposition
  generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
  return try await generator.image(at: time.cmTime).image
 }
 static func luma(_ image: CGImage) -> Double {
  var px = [UInt8](repeating: 0, count: 4)
  let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.interpolationQuality = .medium; c.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return Double(px[0])
 }
 static func frameLuma(_ url: URL, at t: Double) throws -> Double {
  let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.appliesPreferredTrackTransform = true
  g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
  return luma(try g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil))
 }

 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/SpeedEditor")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }

  let video = root.appendingPathComponent("ramp.mp4"); try await makeVideo(video)
  var asset = try await MediaImporter.inspect(url: video); asset.contentHash = try await FileIdentity.sha256(video)
  let originalHash = asset.contentHash
  func makeProject() -> Project {
   var p = Project(name: "속도 편집"); p.sequence.width = 640; p.sequence.height = 360; p.assets = [asset]
   p.sequence.tracks[0].clips = [Clip(name: "앞", assetID: asset.id, start: .zero, duration: MediaTime(seconds: 6)), Clip(name: "뒤", assetID: asset.id, start: MediaTime(seconds: 6), duration: MediaTime(seconds: 2))]
   return p
  }
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.generatedMediaRoot = root.appendingPathComponent("Generated")
  let project = makeProject(); model.history = EditorHistory(project: project)
  let first = project.sequence.tracks[0].clips[0]
  func clips() -> [Clip] { model.project.sequence.tracks[0].clips.sorted { $0.start < $1.start } }

  // ---- Ramp ----
  model.selectedClipID = nil; model.selectedClipIDs = []
  model.applySpeedRamp(preset: .slowDown, pieces: 8, mutesAudio: true)
  check("Ramp with nothing selected: refused with a message, project unchanged", model.error != nil && model.project == project, model.error ?? ""); model.error = nil
  model.selectedClipID = first.id; model.selectedClipIDs = [first.id]
  check("Suggested piece count follows the clip length", model.suggestedRampPieces == 24, "\(model.suggestedRampPieces)")
  model.applySpeedRamp(preset: .slowDown, pieces: 8, mutesAudio: true)
  let rampClips = clips()
  check("Ramp: the clip became 8 pieces plus the untouched next clip", rampClips.count == 9, "\(rampClips.count) clips; \(model.message) / error: \(model.error ?? "-")")
  guard rampClips.count == 9 else { print("SPEED_EDITOR_RESULT aborted"); exit(1) }
  check("Pieces get slower step by step", zip(rampClips.prefix(8), rampClips.prefix(8).dropFirst()).allSatisfy { ($0.playbackRate ?? PlaybackRate()).multiplier >= ($1.playbackRate ?? PlaybackRate()).multiplier } && (rampClips[7].playbackRate?.multiplier ?? 1) < 0.4)
  check("Pieces are contiguous and the next clip moved back by the added length", zip(rampClips, rampClips.dropFirst()).allSatisfy { $0.end == $1.start } && rampClips[8].start == rampClips[7].end && rampClips[8].start.seconds > 6)
  check("Pieces together still cover the whole source range", abs(rampClips.prefix(8).map { $0.sourceDuration.seconds }.reduce(0, +) - 6) < 0.01)
  check("Sound muted on the ramp pieces only", rampClips.prefix(8).allSatisfy { $0.volume == 0 } && rampClips[8].volume == 1)
  model.undo(); check("One undo restores the clip exactly", model.project == project)
  model.redo(); check("Redo brings the ramp back", clips().count == 9)
  let rampedDoc = root.appendingPathComponent("Ramp.jhcut")
  try ProjectStore.save(model.project, to: rampedDoc)
  check("Save/reopen keeps the ramp", try ProjectStore.load(from: rampedDoc).sequence == model.project.sequence)
  model.undo()
  model.selectedClipID = first.id; model.selectedClipIDs = [first.id]
  model.applySpeedRamp(from: 1, to: 9, pieces: 6, mutesAudio: false)
  check("Custom ramp outside the allowed range is refused", model.error != nil && model.project == project, model.error ?? ""); model.error = nil
  model.applySpeedRamp(from: 0.5, to: 2, pieces: 6, mutesAudio: false)
  check("Custom ramp 0.5× → 2× works and keeps sound on", clips().count == 7 && clips().prefix(6).allSatisfy { $0.volume == 1 } && (clips()[0].playbackRate?.multiplier ?? 0) < (clips()[5].playbackRate?.multiplier ?? 0))
  model.undo()
  model.applySpeedRamp(preset: .slowDown, pieces: 99, mutesAudio: true)
  check("Too many pieces refused", model.error != nil && model.project == project, model.error ?? ""); model.error = nil
  var locked = makeProject(); locked.sequence.tracks[0].isLocked = true; model.history = EditorHistory(project: locked)
  model.selectedClipID = locked.sequence.tracks[0].clips[0].id; model.selectedClipIDs = [model.selectedClipID!]
  model.applySpeedRamp(preset: .speedUp, pieces: 8, mutesAudio: true)
  check("Locked track refused, nothing changes", model.project == locked && model.error != nil, model.error ?? ""); model.error = nil
  var connected = makeProject()
  var child = Clip(name: "분리 소리", assetID: asset.id, start: .zero, duration: MediaTime(seconds: 6))
  child.connection = ClipConnection(parentID: connected.sequence.tracks[0].clips[0].id, sourceStart: .zero, sourceDuration: MediaTime(seconds: 6))
  connected.sequence.tracks[1].clips = [child]
  model.history = EditorHistory(project: connected)
  model.selectedClipID = connected.sequence.tracks[0].clips[0].id; model.selectedClipIDs = [model.selectedClipID!]
  model.applySpeedRamp(preset: .speedUp, pieces: 8, mutesAudio: true)
  check("Clip with connected audio: ramp refused with the reason", model.project == connected && model.error?.contains("연결") == true, model.error ?? ""); model.error = nil
  check("…and reverse is refused too", model.reverseProblem?.contains("연결") == true, model.reverseProblem ?? "")

  // ---- Freeze frame ----
  model.history = EditorHistory(project: project)
  model.selectedClipID = first.id; model.selectedClipIDs = [first.id]
  model.playhead = 7
  check("Playhead outside the clip: not allowed, reason given", model.freezeFrameProblem != nil, model.freezeFrameProblem ?? "")
  model.makeFreezeFrame(seconds: 2)
  check("Freeze frame outside the clip is refused", model.error != nil && model.project == project, model.error ?? ""); model.error = nil
  model.playhead = 3
  check("Playhead inside the clip: allowed", model.freezeFrameProblem == nil)
  model.makeFreezeFrame(seconds: 0.1)
  check("Freeze length below the minimum refused", model.error != nil && model.project == project, model.error ?? ""); model.error = nil
  model.makeFreezeFrame(seconds: 2)
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let frozen = clips()
  check("Freeze frame: clip split around a 2 s still", frozen.count == 4 && frozen[1].duration == MediaTime(seconds: 2) && frozen[1].start == MediaTime(seconds: 3), "\(frozen.map { "\($0.name) \($0.start.seconds)+\($0.duration.seconds)" }); \(model.message)")
  check("Later clips moved by exactly the still's length", frozen[2].start == MediaTime(seconds: 5) && frozen[3].start == MediaTime(seconds: 8))
  let stillAsset = model.project.assets.first { $0.id == frozen[1].assetID }
  check("The still is a picture file in the generated folder, source untouched", stillAsset?.kind == .image && stillAsset.map { FileManager.default.fileExists(atPath: $0.path) && $0.path.hasPrefix(root.appendingPathComponent("Generated").path) } == true)
  let stillLuma = stillAsset.flatMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0.path) as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(luma) ?? -1
  let wanted = try frameLuma(video, at: 3)
  check("The still shows the source frame at the playhead", abs(stillLuma - wanted) < 4, String(format: "still %.0f vs source %.0f", stillLuma, wanted))
  model.undo(); check("One undo restores the exact project before freeze", model.project == project)
  model.redo()
  let stillDoc = root.appendingPathComponent("Still.jhcut")
  try ProjectStore.save(model.project, to: stillDoc)
  check("Save/reopen keeps the still", try ProjectStore.load(from: stillDoc).sequence == model.project.sequence)

  // A spatial pattern exposes rotation/crop/stabilization errors hidden by flat luma.
  let patternURL = root.appendingPathComponent("pattern.mp4"); try await makeVideo(patternURL, pattern: true)
  let patternAsset = try await MediaImporter.inspect(url: patternURL)
  for rate in [FrameRate(numerator: 24_000, denominator: 1001), FrameRate(numerator: 30_000, denominator: 1001)] {
   var corrected = Project(name: "정지 픽셀 비교"); corrected.assets = [patternAsset]; corrected.sequence.width = 640; corrected.sequence.height = 360; corrected.sequence.frameRate = rate
   var moving = Clip(name: "보정된 2배속", assetID: patternAsset.id, start: rate.time(forFrame: 12), sourceStart: MediaTime(seconds: 1), duration: rate.time(forFrame: 36), playbackRate: PlaybackRate(numerator: 2))
   moving.transform = ClipTransform(x: -0.15, scale: 0.9, rotation: -12, opacity: 0.65)
   moving.keyframes = [TransformKeyframe(time: .zero, transform: moving.transform), TransformKeyframe(time: moving.duration, transform: ClipTransform(x: 0.12, y: -0.08, scale: 1.25, rotation: 18, opacity: 0.85))]
   moving.fadeIn = rate.time(forFrame: 24)
   moving.visual = VisualAdjustments(exposure: 0.4, contrast: 1.15, saturation: 0.7, cropLeft: 0.13, cropRight: 0.08, cropTop: 0.04, cropBottom: 0.1)
   moving.visual?.temperature = 7500; moving.visual?.tint = 10
   let path: [Float] = (0...180).map { Float(sin(Double($0) * 0.4) * 0.025) }
   moving.stabilization = StabilizationData(step: 1.0 / 30, analyzedStart: .zero, frameWidth: 320, frameHeight: 180, x: path, y: path.map { -$0 / 2 }, angle: path.map { $0 / 3 })
   corrected.sequence.tracks[0].clips = [moving]
   let at = rate.time(forFrame: 30)
   let expected = try await renderedFrame(try await TimelineRenderer.build(project: corrected), at: at)
   var uncorrected = corrected; uncorrected.sequence.tracks[0].clips[0].stabilization = nil
   let withoutStab = try await renderedFrame(try await TimelineRenderer.build(project: uncorrected), at: at)
   check("\(rate.fps) fps: the stabilization fixture visibly changes the pixels", pixelError(expected, withoutStab) > 0.15)
   // Independent overlay must remain an editable layer, absent from the baked PNG.
   let overlay = Clip(name: "별도 자막", start: moving.start, duration: moving.duration, title: Title(text: "별도 자막", fontSize: 36))
   corrected.sequence.tracks[2].clips = [overlay]
   let background = Clip(name: "아래 영상", assetID: patternAsset.id, duration: moving.end)
   corrected.sequence.tracks.insert(Track(name: "아래 영상", kind: .video, clips: [background]), at: 0)
   let fullExpected = try await renderedFrame(try await TimelineRenderer.build(project: corrected), at: at)
   model.error = nil; model.history = EditorHistory(project: corrected); model.selectedClipID = moving.id; model.selectedClipIDs = [moving.id]; model.playhead = at.seconds
   model.makeFreezeFrame(seconds: 1)
   while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
   guard let held = model.selected?.1, let imageAsset = model.project.assets.first(where: { $0.id == held.assetID }), imageAsset.kind == .image else { throw ProjectError(model.error ?? "보정 정지 화면 생성 실패") }
   let png = try MediaImporter.loadImage(url: URL(fileURLWithPath: imageAsset.path))
   let bakedError = pixelError(expected, onBlack(png))
   check("\(rate.fps) fps: PNG matches keyframes, crop, color, opacity, fade and stabilization", bakedError < 1.5, "mean RGB error=\(bakedError)/255")
   let alpha = pixels(png).enumerated().filter { $0.offset % 4 == 3 }.map(\.element)
   check("\(rate.fps) fps: PNG preserves alpha so lower video layers remain visible", alpha.min() == 0 && (alpha.max() ?? 255) < 255)
   check("\(rate.fps) fps: baked still resets adjustments and preserves separate layers", held.transform == ClipTransform() && held.visual == nil && held.keyframes == nil && held.stabilization == nil && held.fadeIn == nil && held.fadeOut == nil && held.transition == nil && model.project.sequence.tracks[3].clips == [overlay] && model.project.sequence.tracks[0].clips == [background])
   let afterPlan = try await TimelineRenderer.build(project: model.project)
   let after = try await renderedFrame(afterPlan, at: at)
   check("\(rate.fps) fps: freeze insertion matches the composed frame without double effects", pixelError(fullExpected, after) < 1.5, "mean RGB error=\(pixelError(fullExpected, after))/255")
   let exported = root.appendingPathComponent("freeze-\(rate.numerator).mp4")
   try await ExportJob().export(plan: afterPlan, to: exported) { _ in }
   check("\(rate.fps) fps: exported frame timestamps match the rational sequence clock exactly", try await exactFrameTimes(exported, rate: rate))
   let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
   let exportImage = try await generator.image(at: at.cmTime).image
   check("\(rate.fps) fps: actual exported freeze matches the original composed pixels", pixelError(fullExpected, exportImage) < 3, "mean RGB error=\(pixelError(fullExpected, exportImage))/255")
   // The lower background continues playing: compare the export with the composed
   // hold at the same later time, rather than requiring the whole canvas to freeze.
   let later = at + rate.time(forFrame: 6)
   let duringHold = try await generator.image(at: later.cmTime).image
   let expectedHold = try await renderedFrame(afterPlan, at: later)
   check("\(rate.fps) fps: exported hold preserves the still while other layers continue", pixelError(expectedHold, duringHold) < 3, "mean RGB error=\(pixelError(expectedHold, duringHold))/255")
   let freezeSnapshot = model.project
   let pathDoc = root.appendingPathComponent("Freeze-\(rate.numerator).jhcut"); try ProjectStore.save(freezeSnapshot, to: pathDoc)
   check("\(rate.fps) fps: corrected freeze survives save and reopen", try ProjectStore.load(from: pathDoc).sequence == freezeSnapshot.sequence)
   model.undo(); check("\(rate.fps) fps: corrected freeze restores every original property with one undo", model.project == corrected)
   model.redo(); check("\(rate.fps) fps: corrected freeze redo restores the result", model.project == freezeSnapshot)
  }
  model.error = nil; model.history = EditorHistory(project: project); model.selectedClipID = first.id; model.selectedClipIDs = [first.id]; model.playhead = 3
  let beforeFreezeCancel = Set(try FileManager.default.contentsOfDirectory(atPath: model.generatedMediaRoot.path))
  model.makeFreezeFrame(seconds: 1); model.cancelProductivity()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let afterFreezeCancel = Set(try FileManager.default.contentsOfDirectory(atPath: model.generatedMediaRoot.path))
  check("Cancelled freeze keeps the project and all previous generated files intact", model.project == project && afterFreezeCancel == beforeFreezeCancel)
  model.error = nil; model.makeFreezeFrame(seconds: 1)
  var newer = project; newer.name = "수정된 문서"; model.history = EditorHistory(project: newer)
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let afterStaleFreeze = Set(try FileManager.default.contentsOfDirectory(atPath: model.generatedMediaRoot.path))
  check("Stale freeze cannot apply to a changed document or leave a generated PNG", model.project == newer && model.error != nil && afterStaleFreeze == beforeFreezeCancel)
  model.error = nil; model.history = EditorHistory(project: project); model.makeFreezeFrame(seconds: 1)
  model.documentURL = root.appendingPathComponent("Different-Document.jhcut")
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let afterDocumentSwitch = Set(try FileManager.default.contentsOfDirectory(atPath: model.generatedMediaRoot.path))
  check("Switching to an identical project in another document rejects the stale freeze", model.project == project && model.error != nil && afterDocumentSwitch == beforeFreezeCancel)
  model.documentURL = nil

  // ---- Reverse ----
  var withStab = makeProject(); let stabID = withStab.sequence.tracks[0].clips[0].id
  withStab.sequence.tracks[0].clips[0].stabilization = StabilizationData(step: 1.0 / 30, analyzedStart: .zero, frameWidth: 320, frameHeight: 180, x: Array(repeating: 0, count: 181), y: Array(repeating: 0, count: 181), angle: Array(repeating: 0, count: 181))
  model.history = EditorHistory(project: withStab)
  model.selectedClipID = stabID; model.selectedClipIDs = [stabID]
  check("Reverse is allowed for a plain video clip", model.reverseProblem == nil, model.reverseProblem ?? "")
  let beforeReverse = model.project
  model.reverseSelectedClip()
  check("Reverse starts as a cancellable background task", model.productivityBusy)
  model.cancelProductivity()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let generated = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Generated").path).filter { $0.contains("거꾸로") }) ?? []
  check("Cancelled reverse: project unchanged and no file left", model.project == beforeReverse && generated.isEmpty && model.error == nil, "files \(generated)")
  model.reverseSelectedClip()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let reversedClip = clips()[0]
  let reversedAsset = model.project.assets.first { $0.id == reversedClip.assetID }
  check("Reverse: the clip now uses the reversed copy from the start of that file", reversedAsset != nil && reversedAsset?.id != asset.id && reversedClip.sourceStart == .zero && abs(reversedClip.duration.seconds - 6) < 0.15, "\(model.message) \(model.error ?? "")")
  check("Stabilisation data of the forward footage was cleared", reversedClip.stabilization == nil)
  check("The reversed picture at the start is the end of the original", try reversedAsset.map { abs(try frameLuma(URL(fileURLWithPath: $0.path), at: 0.05) - (try frameLuma(video, at: 5.9))) < 6 } == true)
  check("Source video file is byte-identical", try await FileIdentity.sha256(video) == originalHash)
  model.undo(); check("One undo returns to the original clip and asset", model.project == beforeReverse)
  model.redo()
  let reverseDoc = root.appendingPathComponent("Reverse.jhcut")
  try ProjectStore.save(model.project, to: reverseDoc)
  check("Save/reopen keeps the reversed clip", try ProjectStore.load(from: reverseDoc).sequence == model.project.sequence)
  model.history = EditorHistory(project: withStab); model.selectedClipID = stabID; model.selectedClipIDs = [stabID]
  let other = makeProject(); model.reverseSelectedClip(); model.history = EditorHistory(project: other)   // project changes while the copy is being made
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  check("Project changed during the work: result not applied", model.project == other && model.error != nil, model.error ?? model.message)

  // A trimmed source range is outside the new reversed file's zero-based range.
  // Include a forward sibling in the same split family: it must not acquire reverse captions.
  var trimmed = makeProject()
  let family = UUID()
  trimmed.sequence.tracks[0].clips[0].sourceStart = MediaTime(seconds: 2)
  trimmed.sequence.tracks[0].clips[0].duration = MediaTime(seconds: 1.5)
  trimmed.sequence.tracks[0].clips[0].playbackRate = PlaybackRate(numerator: 2)
  trimmed.sequence.tracks[0].clips[0].lineageID = family
  trimmed.sequence.tracks[0].clips[1].lineageID = family
  let parent = trimmed.sequence.tracks[0].clips[0]
  var cue = Clip(name: "원문", start: MediaTime(seconds: 0.2), duration: MediaTime(seconds: 0.4), title: Title(text: "보존할 자막"))
  cue.connection = ClipConnection(parentID: parent.id, sourceStart: MediaTime(seconds: 2.4), sourceDuration: MediaTime(seconds: 0.8))
  var translation = cue; translation.id = UUID(); translation.name = "번역"; translation.title?.text = "Preserved caption"
  translation.captionMetadata = CaptionMetadata(language: "en", originalLanguage: "ko", originalText: "보존할 자막", translatedFrom: cue.id, generatedText: "Preserved caption")
  trimmed.sequence.tracks[2].clips = [cue, translation]
  model.error = nil; model.history = EditorHistory(project: trimmed)
  model.selectedClipID = parent.id; model.selectedClipIDs = [parent.id]
  model.reverseSelectedClip()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let kept = model.project.sequence.tracks[2].clips
  check("Trimmed 2x reverse preserves original and translated caption IDs", model.error == nil && Set(kept.map(\.id)) == Set([cue.id, translation.id]), model.error ?? model.message)
  check("Caption source and timeline are mirrored into the reversed file", kept.allSatisfy { abs(($0.connection?.sourceStart.seconds ?? -1) - 1.8) < 0.01 && abs($0.start.seconds - 0.9) < 0.01 && abs($0.duration.seconds - 0.4) < 0.01 })
  check("Forward sibling never acquires the reversed captions", kept.allSatisfy { $0.connection?.parentID == parent.id } && model.project.sequence.tracks[0].clips[1] == trimmed.sequence.tracks[0].clips[1])
  let reversedWithCaptions = model.project
  model.undo(); check("Reverse caption mapping is one undo transaction", model.project == trimmed)
  model.redo(); check("Reverse caption redo restores all mapped captions", model.project == reversedWithCaptions)
  let mappedDoc = root.appendingPathComponent("Reverse-Captions.jhcut")
  try ProjectStore.save(model.project, to: mappedDoc)
  check("Mapped caption connections survive save and reopen", try ProjectStore.load(from: mappedDoc).sequence == model.project.sequence)
  var lockedCaptions = trimmed; lockedCaptions.sequence.tracks[2].isLocked = true
  model.error = nil; model.history = EditorHistory(project: lockedCaptions)
  model.selectedClipID = parent.id; model.selectedClipIDs = [parent.id]
  let filesBeforeLockTest = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Generated").path))
  model.reverseSelectedClip()
  while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) }
  let filesAfterLockTest = Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Generated").path))
  check("Locked connected captions reject reverse without changing the document", model.project == lockedCaptions && model.error != nil)
  check("Rejected reverse removes only its newly generated copy", filesBeforeLockTest == filesAfterLockTest)

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("SPEED_EDITOR_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

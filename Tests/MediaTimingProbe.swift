import Foundation
import AVFoundation
import CoreImage
import VideoToolbox
@testable import JHCutCore

/// Stage 5: independently decode presentation intervals and pixels, not nominal-frame-rate guesses.
@main struct MediaTimingProbe {
 struct Frame { let pts: CMTime; let duration: CMTime; let levels: [Double] }
 static let w = 320, h = 180
 static func fail(_ text: String) -> NSError { NSError(domain: "MediaTiming", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
 static func make(_ url: URL, pts: [CMTime], end: CMTime, hdr: String? = nil, rotate: Bool = false) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let color: [String: Any] = [AVVideoColorPrimariesKey: hdr == nil ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020,
   AVVideoTransferFunctionKey: hdr ?? AVVideoTransferFunction_ITU_R_709_2,
   AVVideoYCbCrMatrixKey: hdr == nil ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020]
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: hdr == nil ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
   AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoColorPropertiesKey: color,
   AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoAllowFrameReorderingKey: false,
    AVVideoProfileLevelKey: hdr == nil ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main10_AutoLevel as String]])
  input.mediaTimeScale = pts.map(\.timescale).max() ?? end.timescale
  writer.movieTimeScale = input.mediaTimeScale
  if rotate { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0) }
  writer.add(input); guard writer.startWriting() else { throw writer.error ?? fail("writer start") }; writer.startSession(atSourceTime: .zero)
  for (i, time) in pts.enumerated() {
   while !input.isReadyForMoreMediaData { try Task.checkCancellation(); guard writer.status == .writing else { throw writer.error ?? fail("writer stopped") }; try await Task.sleep(nanoseconds: 1_000_000) }
   var b: CVPixelBuffer?
   let format = hdr == nil ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
   guard CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &b) == kCVReturnSuccess, let b else { throw fail("buffer") }
   CVPixelBufferLockBaseAddress(b, [])
   if hdr == nil {
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(b)
    let level = UInt8(24 + (180 * i / max(1, pts.count - 1)))
    for y in 0..<h { for x in 0..<w { let o = y * stride + 4 * x; base[o] = level; base[o+1] = level; base[o+2] = level; base[o+3] = 255 } }
   } else {
    // Six encoded signal levels, including highlights. 10-bit NV12 stores the code in its high bits.
    let codes: [UInt16] = [120, 240, 400, 560, 720, 880]
    for plane in 0..<2 {
     let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt16.self)
     let stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane) / 2
     for y in 0..<CVPixelBufferGetHeightOfPlane(b, plane) { for x in 0..<w { base[y * stride + x] = (plane == 0 ? codes[min(5, x * 6 / w)] : 512) << 6 } }
    }
   }
   CVPixelBufferUnlockBaseAddress(b, [])
   CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, (hdr == nil ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020), .shouldPropagate)
   CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, (hdr ?? AVVideoTransferFunction_ITU_R_709_2) as CFString, .shouldPropagate)
   CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, (hdr == nil ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020), .shouldPropagate)
   var description: CMVideoFormatDescription?
   guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: b, formatDescriptionOut: &description) == noErr, let description else { throw fail("description") }
   var timing = CMSampleTimingInfo(duration: (i + 1 < pts.count ? pts[i+1] : end) - time, presentationTimeStamp: time, decodeTimeStamp: .invalid)
   var sample: CMSampleBuffer?
   guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: b, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample, input.append(sample) else { throw writer.error ?? fail("append") }
  }
  writer.endSession(atSourceTime: end); input.markAsFinished(); await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? fail("finish") }
 }
 static func frames(_ url: URL, videoComposition: AVVideoComposition? = nil, timeRange: CMTimeRange? = nil) async throws -> [Frame] {
  let asset = AVURLAsset(url: url), track = try await asset.loadTracks(withMediaType: .video)[0]
  let reader = try AVAssetReader(asset: asset)
  if let timeRange { reader.timeRange = timeRange }
  let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
  let out: AVAssetReaderOutput
  if let videoComposition { let o = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings); o.videoComposition = videoComposition; out = o }
  else { out = AVAssetReaderTrackOutput(track: track, outputSettings: settings) }
  reader.add(out); guard reader.startReading() else { throw reader.error ?? fail("read") }
  var result: [Frame] = []
  while let sample = out.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
   CVPixelBufferLockBaseAddress(buffer, .readOnly)
   let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
   let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
   var levels = [Double](repeating: 0, count: 6)
   for patch in 0..<6 { var n = 0
    for y in (height/3)..<(height*2/3) { for x in (width*(2*patch+1)/12-3)..<(width*(2*patch+1)/12+3) { levels[patch] += Double(base[y * stride + x * 4 + 1]); n += 1 } }
    levels[patch] /= Double(n)
   }
   CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
   result.append(Frame(pts: CMSampleBufferGetPresentationTimeStamp(sample), duration: CMSampleBufferGetDuration(sample), levels: levels))
  }
  guard reader.status == .completed else { throw reader.error ?? fail("read finish") }
  result.sort { $0.pts < $1.pts }
  let end = try await track.load(.timeRange).end
  return result.enumerated().map { i, f in Frame(pts:f.pts,duration:(i+1<result.count ? result[i+1].pts : end)-f.pts,levels:f.levels) }
 }
 static func metadata(_ url: URL) async throws -> (String, String, CMTimeRange, CGAffineTransform) {
  let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0], formats = try await track.load(.formatDescriptions)
  let ext = CMFormatDescriptionGetExtensions(formats[0]) as NSDictionary? ?? [:]
  return (ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String ?? "", ext[kCMFormatDescriptionExtension_TransferFunction] as? String ?? "", try await track.load(.timeRange), try await track.load(.preferredTransform))
 }
 static func imageDifference(_ a: CIImage, _ b: CIImage) -> Double {
  let context = CIContext(options: [.useSoftwareRenderer: true]); let e = a.extent.integral
  var pa = [UInt8](repeating: 0, count: Int(e.width*e.height)*4), pb = pa
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  context.render(a, toBitmap: &pa, rowBytes: Int(e.width)*4, bounds: e, format: .RGBA8, colorSpace: space)
  context.render(b, toBitmap: &pb, rowBytes: Int(e.width)*4, bounds: e, format: .RGBA8, colorSpace: space)
  return zip(pa,pb).reduce(0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(pa.count)
 }
 static func hdrReference(_ url: URL) async throws -> [Double] {
  let asset=AVURLAsset(url:url), track=try await asset.loadTracks(withMediaType:.video)[0], reader=try AVAssetReader(asset:asset)
  let out=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
  reader.add(out); guard reader.startReading(), let sample=out.copyNextSampleBuffer(), let source=CMSampleBufferGetImageBuffer(sample) else { throw fail("HDR reference decode") }
  defer { reader.cancelReading() }
  var target:CVPixelBuffer?, session:VTPixelTransferSession?
  guard CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&target)==kCVReturnSuccess,
   VTPixelTransferSessionCreate(allocator:nil,pixelTransferSessionOut:&session)==noErr, let target, let session else { throw fail("HDR reference setup") }
  defer { VTPixelTransferSessionInvalidate(session) }
  for (key,value) in [(kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2),(kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2),(kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
   guard VTSessionSetProperty(session,key:key,value:value)==noErr else { throw fail("HDR reference properties") }
  }
  guard VTPixelTransferSessionTransferImage(session,from:source,to:target)==noErr else { throw fail("HDR reference transfer") }
  CVPixelBufferLockBaseAddress(target,.readOnly); defer { CVPixelBufferUnlockBaseAddress(target,.readOnly) }
  let p=CVPixelBufferGetBaseAddress(target)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRow(target)
  var levels=[Double](); for i in 0..<6 { let x=w*(2*i+1)/12; levels.append(Double(p[(h/2)*stride+x*4+1])) }; return levels
 }
 static func jitter(_ data: StabilizationData, width: Double = 320) -> Double {
  var full = data; full.enabled = true; full.strength = 1
  guard let plan = StabilizationPlan(full,unlimited:true), data.count>0 else { return 0 }
  let values = (0..<data.count).map { plan.correction(atSource:data.analyzedStart.seconds+Double($0)*data.step) }
  return sqrt(values.reduce(0) { $0 + pow($1.x*width,2) + pow($1.y*width*Double(data.frameHeight)/Double(data.frameWidth),2) } / Double(values.count))
 }
 static func addClick(video: URL, root: URL) async throws -> URL {
  let audio = root.appendingPathComponent("click.caf"), output = root.appendingPathComponent("vfr-audio.mov")
  let format = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1)!
  let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48_000)!; buffer.frameLength=48_000
  for i in 0..<48_000 { buffer.floatChannelData![0][i] = i>=8_000 && i<8_480 ? Float(0.8*sin(Double(i)*2*Double.pi*1000/48_000)) : 0 }
  do { let file = try AVAudioFile(forWriting:audio,settings:format.settings); try file.write(from:buffer) }
  let comp = AVMutableComposition(), src=AVURLAsset(url:video), snd=AVURLAsset(url:audio)
  let v = try await src.loadTracks(withMediaType:.video)[0], a = try await snd.loadTracks(withMediaType:.audio)[0]
  try comp.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:1,timescale:1)),of:v,at:.zero)
  try comp.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(value:1,timescale:1)),of:a,at:.zero)
  let session=AVAssetExportSession(asset:comp,presetName:AVAssetExportPresetPassthrough)!; session.outputURL=output; session.outputFileType = .mov
  await session.export(); guard session.status == .completed else { throw session.error ?? fail("vfr mix") }; return output
 }
 static func clickTime(_ url: URL) async throws -> (Double,Double) {
  let asset=AVURLAsset(url:url), track=try await asset.loadTracks(withMediaType:.audio)[0], reader=try AVAssetReader(asset:asset)
  let out=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48_000,AVNumberOfChannelsKey:1,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
  reader.add(out); guard reader.startReading() else { throw reader.error ?? fail("audio") }
  var energy=0.0, moment=0.0
  while let sample=out.copyNextSampleBuffer(), let block=CMSampleBufferGetDataBuffer(sample) {
   var values=[Float](repeating:0,count:CMBlockBufferGetDataLength(block)/4)
   guard values.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!) }) == noErr else { throw fail("PCM") }
   let start=CMSampleBufferGetPresentationTimeStamp(sample).seconds
   for (i,v) in values.enumerated() { let power=Double(v)*Double(v); energy += power; moment += power*(start+Double(i)/48_000) }
  }
  guard reader.status == .completed, energy>0 else { throw reader.error ?? fail("click missing") }
  return (moment/energy,try await track.load(.timeRange).end.seconds)
 }
 static func main() async throws {
  setbuf(stdout, nil); let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Stage5MediaTiming")
  var checks: [[String: Any]] = [], observations: [[String: Any]] = []
  func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks.append(["name":name,"passed":ok,"detail":detail]); print("\(ok ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: ["checks":checks,"observations":observations], options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  let vfr = root.appendingPathComponent("uneven.mov")
  let pts = [0,33,133,150,350,400,800].map { CMTime(value: Int64($0), timescale: 1000) }, end = CMTime(value:1000,timescale:1000)
  try await make(vfr, pts: pts, end:end)
  let before = try await FileIdentity.sha256(vfr), sourceFrames = try await frames(vfr)
  check("Fixture really has uneven presentation intervals", sourceFrames.map(\.pts) == pts && Set(zip(pts,pts.dropFirst()).map { MediaTime($1-$0) }).count > 3)
  for (name,start,finish) in [("full",0,1000),("trim",70,910),("single-held",180,280)] {
   let startTime = CMTime(value:Int64(start),timescale:1000), finishTime = CMTime(value:Int64(finish),timescale:1000)
   let output = root.appendingPathComponent("vfr-\(name).mp4")
   _ = try await ReverseRenderer.render(url:vfr,sourceStart:MediaTime(startTime),duration:MediaTime(finishTime-startTime),destination:output)
   let decoded = try await frames(output), range = try await metadata(output).2
   let expected = sourceFrames.enumerated().compactMap { i, f -> (CMTime,CMTime,Double)? in
    let next = i+1 < sourceFrames.count ? sourceFrames[i+1].pts : end
    let a = max(startTime,f.pts), b = min(finishTime,next)
    return b > a ? (finishTime-b,b-a,f.levels[0]) : nil
   }.sorted { $0.0 < $1.0 }
   check("VFR \(name): exact mirrored PTS, including held boundary frame", decoded.count == expected.count && zip(decoded,expected).allSatisfy { $0.pts == $1.0 }, "\(decoded.map { $0.pts.seconds })")
   check("VFR \(name): each exposure duration preserved", decoded.count == expected.count && zip(decoded,expected).allSatisfy { abs(($0.duration-$1.1).seconds) < 0.00002 }, "\(decoded.map { $0.duration.seconds })")
   check("VFR \(name): pixel identities reversed", decoded.count == expected.count && zip(decoded,expected).allSatisfy { abs($0.levels[0]-$1.2) < 4 })
   check("VFR \(name): exact track end", range.end == finishTime-startTime, "\(range.end.seconds)")
  }
  let vfrAudio=try await addClick(video:vfr,root:root), vfrReverse=root.appendingPathComponent("vfr-audio-reverse.mp4")
  _ = try await ReverseRenderer.render(url:vfrAudio,sourceStart:.zero,duration:MediaTime(1,1),destination:vfrReverse)
  let originalClick=try await clickTime(vfrAudio), reverseClick=try await clickTime(vfrReverse)
  check("Uneven VFR + AAC: sound click mirrored within one 30fps frame", abs(reverseClick.0-(1-originalClick.0))<1.0/30,"\(originalClick.0) → \(reverseClick.0)")
  check("Uneven VFR + AAC: audio/video ends agree within one frame", abs(reverseClick.1-1)<1.0/30,"\(reverseClick.1)")
  for rate in [FrameRate(numerator:24000,denominator:1001),FrameRate(numerator:30000,denominator:1001),FrameRate(numerator:60000,denominator:1001)] {
   // 73 frames crosses the reverse decoder's 60-frame chunk boundary.
   let count:Int64 = 73, clocks = (0..<count).map { rate.time(forFrame:$0).cmTime }, ending = rate.time(forFrame:count).cmTime
   let input = root.appendingPathComponent("ntsc-\(rate.numerator).mov"), output = root.appendingPathComponent("ntsc-\(rate.numerator)-reverse.mp4")
   try await make(input,pts:clocks,end:ending,rotate:true)
   _ = try await ReverseRenderer.render(url:input,sourceStart:.zero,duration:MediaTime(ending),destination:output)
   let f = try await frames(output), meta = try await metadata(output)
   check("\(rate.label): exact rational PTS/durations across chunks", f.count == Int(count) && zip(f,clocks).allSatisfy { $0.pts == $1 && $0.duration == rate.time(forFrame:1).cmTime } && meta.2.end == ending)
   check("\(rate.label): portrait rotation retained", abs(meta.3.b-1)<1e-6 && abs(meta.3.c+1)<1e-6)
  }
  let flat = root.appendingPathComponent("flat.mov")
  // Repeat a single brightness for a textureless source.
  try await make(flat,pts:(0..<30).map { CMTime(value:Int64($0),timescale:30) },end:CMTime(value:1,timescale:1))
  let data = try await StabilizationAnalyzer.analyze(url:flat,sourceStart:.zero,duration:MediaTime(1,1))
  check("Textureless source: low confidence keeps original", data.confidence == 0 && !data.enabled && StabilizationPlan(data) == nil)
  let phased = try await StabilizationAnalyzer.analyze(url:flat,sourceStart:MediaTime(1,100),duration:MediaTime(9,10))
  let phaseReference = try await frames(flat,timeRange:CMTimeRange(start:CMTime(value:1,timescale:100),duration:CMTime(value:9,timescale:10)))
  check("Analysis path anchors to actual first decoded PTS", phased.analyzedStart == MediaTime(phaseReference[0].pts), "\(phased.analyzedStart.seconds)")
  var bad = data; bad.confidence = .nan
  check("Nonfinite confidence rejected", bad.validationProblem != nil)
  let heldPath=try await StabilizationAnalyzer.analyze(url:vfr,sourceStart:.zero,duration:MediaTime(1,1))
  check("VFR analysis coverage includes final held exposure", heldPath.analyzedEnd == MediaTime(1,1) && heldPath.covers(.zero,duration:MediaTime(1,1)))
  // A patterned still proves source time after speed/trim/split without re-running estimation.
  let checker = CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":13,"inputColor0":CIColor(red:0.2,green:0.6,blue:0.8),"inputColor1":CIColor.white])!
  let pattern = checker.outputImage!.cropped(to:CGRect(x:0,y:0,width:320,height:180))
  var stored = data; stored.enabled = true; stored.strength = 1
  stored.x = (0..<120).map { Float(0.03*sin(Double($0)*0.5)) }; stored.y = stored.x.map { $0*0.6 }; stored.angle = stored.x.map { $0*0.3 }; stored.analyzedStart = .zero; stored.analyzedEnd = MediaTime(4,1)
  let plan = StabilizationPlan(stored)!
  var clip = Clip(duration:MediaTime(1,1)); clip.sourceStart=MediaTime(1,1); clip.playbackRate=PlaybackRate(numerator:2,denominator:1); clip.stabilization=stored
  let trim = try ClipTemporalEditor.trimmed(clip,newStart:.zero,newSourceStart:MediaTime(3,2),newDuration:MediaTime(3,4),frameRate:FrameRate(),temporalSource:true)
  let a = TimelineCompositor.stabilized(pattern,plan:plan,clip:clip,localSeconds:0.45)
  let b = TimelineCompositor.stabilized(pattern,plan:plan,clip:trim,localSeconds:0.20)
  check("2× trimmed/right split correction follows identical source time", imageDifference(a,b)<0.01 && trim.stabilization == stored)
  check("Coordinate fixture detects a wrong source clock", imageDifference(a,TimelineCompositor.stabilized(pattern,plan:plan,clip:clip,localSeconds:0.20))>1)
  // Apple's SDR conversion is measured against an in-memory color-conforming reference and a naive retag.
  for (name,transfer) in [("HLG",AVVideoTransferFunction_ITU_R_2100_HLG),("PQ",AVVideoTransferFunction_SMPTE_ST_2084_PQ)] {
   let input = root.appendingPathComponent("\(name)-10bit.mov"), output = root.appendingPathComponent("\(name)-sdr.mp4")
   try await make(input,pts:(0..<30).map { CMTime(value:Int64($0),timescale:30) },end:CMTime(value:1,timescale:1),hdr:transfer)
   let digest = try await FileIdentity.sha256(input), meta = try await metadata(input), info = try await MediaImporter.inspect(url:input)
   check("\(name) fixture: Rec.2020 HDR rejected by normal importer", meta.0 == AVVideoColorPrimaries_ITU_R_2020 && meta.1 == transfer && !info.supported)
   let asset = AVURLAsset(url:input), track = try await asset.loadTracks(withMediaType:.video)[0]
   let nativeReader = try AVAssetReader(asset:asset), nativeOutput = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
   nativeReader.add(nativeOutput); guard nativeReader.startReading(), let sample=nativeOutput.copyNextSampleBuffer(), let buf=CMSampleBufferGetImageBuffer(sample) else { throw fail("10bit fixture decode") }
   check("\(name) fixture decodes in 10-bit", CVPixelBufferGetPixelFormatType(buf)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange); nativeReader.cancelReading()
   var refused = 0
   do { _ = try await ReverseRenderer.render(url:input,sourceStart:.zero,duration:MediaTime(1,1),destination:root.appendingPathComponent("\(name)-unsafe.mp4")) } catch { refused += 1 }
   do { _ = try await StabilizationAnalyzer.analyze(url:input,sourceStart:.zero,duration:MediaTime(1,1)) } catch { refused += 1 }
   check("\(name): reverse/analysis refuse unsupported HDR before writing", refused == 2 && !FileManager.default.fileExists(atPath:root.appendingPathComponent("\(name)-unsafe.mp4").path))
   let converted = try await MediaPreparation.convertToSDR(url:input,destination:output)
   let sdmeta = try await metadata(output), sd = try await frames(output)
   let levels = sd[0].levels, ref = try await hdrReference(input)
   let naive = [120.0,240,400,560,720,880].map { ($0-64)/876*255 }
   check("\(name) conversion: supported Rec.709 output and duration", converted.supported && converted.codec == "avc1" && sdmeta.0 == AVVideoColorPrimaries_ITU_R_709_2 && sdmeta.1 == AVVideoTransferFunction_ITU_R_709_2 && abs(sdmeta.2.duration.seconds-1)<0.001)
   check("\(name) conversion: actual pixels match independent 10-bit VT color-conversion reference", zip(levels,ref).allSatisfy { abs($0-$1)<6 }, "output \(levels) reference \(ref)")
   check("\(name) conversion changes pixel signal, retains shadow/highlight ordering", zip(levels,naive).map { abs($0-$1) }.max()!>15 && zip(levels,levels.dropFirst()).allSatisfy { $1 >= $0-2 } && levels[3]>levels[0]+30 && levels[5]>levels[0]+80, "\(levels)")
   let audioRoot=root.appendingPathComponent(name+"-audio"); try FileManager.default.createDirectory(at:audioRoot,withIntermediateDirectories:true)
   let hdrSound=try await addClick(video:input,root:audioRoot), sdrSound=audioRoot.appendingPathComponent("sdr-sound.mp4")
   let soundInfo=try await MediaPreparation.convertToSDR(url:hdrSound,destination:sdrSound)
   let sourceSound=try await clickTime(hdrSound), convertedSound=try await clickTime(sdrSound)
   check("\(name) color conversion: AAC click and duration remain synchronized", soundInfo.hasAudio && abs(sourceSound.0-convertedSound.0)<1.0/30 && abs(convertedSound.1-1)<1.0/30,"\(sourceSound.0) → \(convertedSound.0)")
   let canceledOutput=audioRoot.appendingPathComponent("canceled.mp4")
   let canceled=Task { try await MediaPreparation.convertToSDR(url:hdrSound,destination:canceledOutput) }; canceled.cancel()
   var cancelObserved=false
   do { _ = try await canceled.value } catch is CancellationError { cancelObserved=true } catch { }
   check("\(name) canceled conversion keeps original and leaves no output", cancelObserved && !FileManager.default.fileExists(atPath:canceledOutput.path))
   check("\(name) original bytes preserved", try await FileIdentity.sha256(input)==digest)
  }
  let hdrPortrait=root.appendingPathComponent("HLG-portrait.mov"), hdrPortraitSDR=root.appendingPathComponent("HLG-portrait-sdr.mp4")
  try await make(hdrPortrait,pts:(0..<30).map { CMTime(value:Int64($0),timescale:30) },end:CMTime(value:1,timescale:1),hdr:AVVideoTransferFunction_ITU_R_2100_HLG,rotate:true)
  let convertedPortrait=try await MediaPreparation.convertToSDR(url:hdrPortrait,destination:hdrPortraitSDR,timeRange:CMTimeRange(start:CMTime(value:3,timescale:30),duration:CMTime(value:24,timescale:30)))
  check("HDR portrait trimmed conversion retains orientation and length", convertedPortrait.width==180 && convertedPortrait.height==320 && abs(convertedPortrait.duration.seconds-0.8)<1.0/30)
  // Real originals are represented only by immutable local copies and observational classifications.
  for file in ["IMG_8490.mov","IMG_2601.mov","IMG_2029.mov","IMG_5185.mov"] {
   let input=URL(fileURLWithPath:"Artifacts/Stage5Copies/"+file).standardizedFileURL
   let digest=try await FileIdentity.sha256(input), meta=try await metadata(input), info=try await MediaImporter.inspect(url:input)
   let duration=MediaTime(meta.2.duration), analyzed=try await StabilizationAnalyzer.analyze(url:input,sourceStart:MediaTime(meta.2.start),duration:duration)
   let correction=StabilizationPlan(analyzed)
   check("Real \(file): valid confidence and safe crop/original fallback", analyzed.validationProblem == nil && analyzed.covers(MediaTime(meta.2.start),duration:duration) && analyzed.confidence != nil && ((analyzed.confidence!<0.5 && correction == nil) || (correction != nil && correction!.zoom<=1.25)))
   var project=Project(name:file); project.assets=[info]; project.sequence.width=320; project.sequence.height=568
   var clip=Clip(assetID:info.id,sourceStart:MediaTime(meta.2.start),duration:duration); clip.stabilization=analyzed; project.sequence.tracks[0].clips=[clip]
   let output=root.appendingPathComponent(file+"-stabilized.mp4")
   try await ExportJob().export(plan:TimelineRenderer.build(project:project),to:output) { _ in }
   let rendered=try await MediaImporter.inspect(url:output), afterDigest=try await FileIdentity.sha256(input)
   check("Real \(file): decodable output, duration and source hash retained", rendered.supported && abs(rendered.duration.seconds-duration.seconds)<0.04 && afterDigest==digest)
   // Measure on equal-size control/output renders. These are observations, not asserted improvements:
   // fast intentional pans and scene cuts have no known camera-path ground truth.
   project.sequence.tracks[0].clips[0].stabilization=nil
   let control=root.appendingPathComponent(file+"-control.mp4")
   try await ExportJob().export(plan:TimelineRenderer.build(project:project),to:control) { _ in }
   let controlRange=try await metadata(control).2, outputRange=try await metadata(output).2
   let beforePath=try await StabilizationAnalyzer.analyze(url:control,sourceStart:MediaTime(controlRange.start),duration:MediaTime(controlRange.duration))
   let afterPath=try await StabilizationAnalyzer.analyze(url:output,sourceStart:MediaTime(outputRange.start),duration:MediaTime(outputRange.duration))
   observations.append(["file":file,"controlJitterPixels":jitter(beforePath),"outputJitterPixels":jitter(afterPath),"controlConfidence":beforePath.confidence ?? 0,"outputConfidence":afterPath.confidence ?? 0,"measurement":"Gaussian path residual; pan/subject estimation errors possible; not ground truth."])
   observations.append(["file":file,"confidence":analyzed.confidence!,"enabled":analyzed.enabled,"strength":analyzed.strength,"zoom":correction?.zoom ?? 1,"limitedSamples":correction?.limitedSamples ?? 0,"classification":"Candidate only; no ground-truth shake path or quality-improvement assertion."])
  }
  // Portrait proxy generation bakes orientation; active corrections must use original decoded axes.
  let portrait=root.appendingPathComponent("proxy-original.mov")
  try await make(portrait,pts:(0..<30).map { CMTime(value:Int64($0),timescale:30) },end:CMTime(value:1,timescale:1),rotate:true)
  let proxy=try await ProxyCache(directory:root.appendingPathComponent("proxy-cache")).generate(for:portrait), media=try await MediaImporter.inspect(url:portrait)
  var project=Project(name:"Proxy stabilization"); project.sequence.width=180; project.sequence.height=320; project.assets=[media]
  var portraitClip=Clip(assetID:media.id,duration:MediaTime(1,1)); portraitClip.stabilization=stored; portraitClip.sourceStart = .zero
  project.sequence.tracks[0].clips=[portraitClip]
  let preview=try await TimelineRenderer.build(project:project,mediaURLOverrides:[media.id:proxy])
  check("Portrait stabilized proxy preview falls back to original axes", !preview.usesProxyMedia)
  project.sequence.tracks[0].clips[0].stabilization=nil
  let uncorrected=try await TimelineRenderer.build(project:project,mediaURLOverrides:[media.id:proxy])
  check("Portrait uncorrected preview still uses proxy", uncorrected.usesProxyMedia)
  check("VFR original bytes preserved", try await FileIdentity.sha256(vfr)==before)
  let failures=checks.filter { !($0["passed"] as! Bool) }.count
  print("MEDIA_TIMING_RESULT checks=\(checks.count) failures=\(failures)")
  if failures>0 { throw fail("Stage5 checks failed") }
 }
}

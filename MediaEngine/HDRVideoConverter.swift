import Foundation
@preconcurrency import AVFoundation
import VideoToolbox

/// Direct native 10-bit decode -> explicit SDR pixel transfer -> 8-bit H.264 encoding.
/// Does not allow a composition to replace source HDR attachments before conversion.
enum HDRVideoConverter {
 static func render(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, destination: URL) async throws {
  guard !FileManager.default.fileExists(atPath:destination.path) else { throw MediaEngineError.failed("기존 파일은 덮어쓰지 않습니다.") }
  let size=try await track.load(.naturalSize), preferred=try await track.load(.preferredTransform)
  let width=Int(size.width), height=Int(size.height), naturalClock=try await track.load(.naturalTimeScale)
  var clock:Int64=1
  for scale in [naturalClock,range.start.timescale,range.duration.timescale] {
   var a=clock,b=Int64(scale); guard b>0 else { throw MediaEngineError.unsupported("원본 시간 단위가 유효하지 않습니다.") }
   while b != 0 { let r=a%b; a=b; b=r }; clock=clock/a*Int64(scale)
   guard clock<=Int64(Int32.max) else { throw MediaEngineError.unsupported("HDR 사본의 시간을 정확히 저장할 수 없습니다.") }
  }
  let reader=try AVAssetReader(asset:asset); reader.timeRange=range
  let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]); output.alwaysCopiesSampleData=false
  guard reader.canAdd(output) else { throw MediaEngineError.failed("10비트 HDR 디코더를 구성하지 못했습니다.") }; reader.add(output)
  var transfer:VTPixelTransferSession?
  guard VTPixelTransferSessionCreate(allocator:nil,pixelTransferSessionOut:&transfer)==noErr, let transfer else { throw MediaEngineError.failed("HDR 픽셀 변환기를 만들지 못했습니다.") }
  defer { VTPixelTransferSessionInvalidate(transfer) }
  for (key,value) in [(kVTPixelTransferPropertyKey_DestinationColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_709_2),
                       (kVTPixelTransferPropertyKey_DestinationTransferFunction,kCVImageBufferTransferFunction_ITU_R_709_2),
                       (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
   guard VTSessionSetProperty(transfer,key:key,value:value)==noErr else { throw MediaEngineError.failed("HDR → SDR 색 변환 설정 실패") }
  }
  let writer=try AVAssetWriter(outputURL:destination,fileType:.mp4)
  var complete=false
  defer { reader.cancelReading(); if !complete { writer.cancelWriting(); try? FileManager.default.removeItem(at:destination) } }
  writer.movieTimeScale=Int32(clock)
  let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
   AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],
   AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:ExportJob.recommendedBitRate(width:width,height:height,fps:Double(try await track.load(.nominalFrameRate))),AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel]])
  input.transform=preferred; input.mediaTimeScale=Int32(clock); input.expectsMediaDataInRealTime=false
  let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
  guard writer.canAdd(input) else { throw MediaEngineError.failed("SDR 기록기를 구성하지 못했습니다.") }; writer.add(input)
  guard reader.startReading(),writer.startWriting() else { throw reader.error ?? writer.error ?? MediaEngineError.failed("HDR 변환을 시작하지 못했습니다.") }; writer.startSession(atSourceTime:.zero)
  var idleSince=ProcessInfo.processInfo.systemUptime, written=0
  func append(_ sample:CMSampleBuffer, end:CMTime) async throws {
   try Task.checkCancellation()
   let pts=CMSampleBufferGetPresentationTimeStamp(sample), begin=max(pts,range.start), finish=min(end,range.end)
   guard pts.isNumeric,finish>begin,let source=CMSampleBufferGetImageBuffer(sample),CVPixelBufferGetPixelFormatType(source)==kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else { throw MediaEngineError.failed("유효한 10비트 HDR 프레임을 읽지 못했습니다.") }
   while !input.isReadyForMoreMediaData {
    try Task.checkCancellation()
    guard writer.status == .writing else { throw writer.error ?? MediaEngineError.failed("SDR 기록기가 중단되었습니다.") }
    guard ProcessInfo.processInfo.systemUptime-idleSince<30 else { throw MediaEngineError.failed("SDR 기록기가 30초 동안 진행되지 않았습니다.") }
    try await Task.sleep(nanoseconds:2_000_000)
   }
   guard let pool=adaptor.pixelBufferPool else { throw MediaEngineError.failed("SDR 픽셀 버퍼를 만들지 못했습니다.") }
   var converted:CVPixelBuffer?
   guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&converted)==kCVReturnSuccess, let converted,
    VTPixelTransferSessionTransferImage(transfer,from:source,to:converted)==noErr else { throw MediaEngineError.failed("HDR 픽셀의 SDR 색 변환에 실패했습니다.") }
   CVBufferSetAttachment(converted,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
   CVBufferSetAttachment(converted,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
   CVBufferSetAttachment(converted,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
   var description:CMVideoFormatDescription?, ready:CMSampleBuffer?
   guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:converted,formatDescriptionOut:&description)==noErr,let description else { throw MediaEngineError.failed("SDR 프레임 정보를 만들지 못했습니다.") }
   var timing=CMSampleTimingInfo(duration:finish-begin,presentationTimeStamp:begin-range.start,decodeTimeStamp:.invalid)
   guard CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:converted,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&ready)==noErr,let ready,input.append(ready) else { throw writer.error ?? MediaEngineError.failed("SDR 프레임 저장 실패") }
   written += 1; idleSince=ProcessInfo.processInfo.systemUptime
  }
  var previous=output.copyNextSampleBuffer()
  while let next=output.copyNextSampleBuffer() {
   if let previous { try await append(previous,end:CMSampleBufferGetPresentationTimeStamp(next)) }; previous=next
  }
  guard reader.status == .completed,let previous else { throw reader.error ?? MediaEngineError.failed("HDR 영상 디코딩이 끝나지 않았습니다.") }
  try await append(previous,end:range.end)
  guard written>0 else { throw MediaEngineError.failed("변환할 HDR 프레임이 없습니다.") }
  writer.endSession(atSourceTime:range.duration); input.markAsFinished(); await writer.finishWriting(); try Task.checkCancellation()
  guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("SDR 사본 저장 실패") }; complete=true
 }
}

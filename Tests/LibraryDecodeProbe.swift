import Foundation
import AVFoundation
import ImageIO
import CryptoKit
import JHCutCore

/// Whole-file decoding, not a substitute for listening or checking the editing UI.
@main struct LibraryDecodeProbe {
 static func main() async throws {
  setbuf(stdout,nil)
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/LibraryDecode")
  let library=try AssetLibrary(rootURL:URL(fileURLWithPath:"Resources/Library",isDirectory:true))
  try library.verify()
  var rows:[[String:Any]]=[];var failures=0
  var decodedImageHashes:[String:[String]]=[:]
  for entry in library.assets {
   var row:[String:Any]=["id":entry.id,"category":entry.category.rawValue,"path":entry.relativePath,"declaredSHA256":entry.sha256]
   do {
    let url=library.url(for:entry)
    let bytes=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? -1
    guard Int64(bytes)==entry.fileBytes else {throw ProjectError("File size differs from manifest")}
    if entry.category == .sfx || entry.category == .music {
     let file=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
     let format=file.processingFormat
     guard format.sampleRate>0,format.channelCount>0,
           let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16384) else {throw ProjectError("Invalid audio format")}
     var frames:Int64=0;var samples:Int64=0;var squares=0.0;var peak=0.0;var nonFinite=0
     while file.framePosition < file.length {
      try file.read(into:pcm)
      if pcm.frameLength==0 {break}
      guard let channels=pcm.floatChannelData else {throw ProjectError("PCM decoder did not return float samples")}
      for channel in 0..<Int(format.channelCount) {
       for offset in 0..<Int(pcm.frameLength) {
        let value=Double(channels[channel][offset])
        if value.isFinite {peak=max(peak,abs(value));squares+=value*value} else {nonFinite+=1}
        samples+=1
       }
      }
      frames+=Int64(pcm.frameLength)
     }
     let duration=Double(frames)/format.sampleRate
     row.merge(["decodedFrames":frames,"fileFrames":file.length,"sampleRate":format.sampleRate,"channels":format.channelCount,"decodedDuration":duration,"declaredDuration":entry.duration ?? 0,"durationDifference":duration-(entry.duration ?? 0),"peak":peak,"rms":sqrt(squares/Double(max(1,samples))),"nonFiniteSamples":nonFinite]) {_,new in new}
     guard frames>0,frames==file.length,nonFinite==0,peak>0 else {throw ProjectError("Incomplete, silent or non-finite audio")}
     // MP3 may include codec priming/padding; collect the measured difference instead of silently rewriting metadata.
     guard let expected=entry.duration,abs(duration-expected)<0.15 else {throw ProjectError("Decoded duration differs from catalog by at least150ms")}
    } else {
     guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(source)==1,
           let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
           image.width>0,image.height>0,image.width*image.height<=64_000_000 else {throw ProjectError("Image decode failed or image size is unsupported")}
     if let expected=entry.width,expected != image.width {throw ProjectError("Image width differs from catalog")}
     if let expected=entry.height,expected != image.height {throw ProjectError("Image height differs from catalog")}
     let rowBytes=image.width*4;var rgba=[UInt8](repeating:0,count:rowBytes*image.height)
     try rgba.withUnsafeMutableBytes { buffer in
      guard let context=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:rowBytes,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw ProjectError("Image bitmap allocation failed")}
      context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
     }
     let visible=stride(from:3,to:rgba.count,by:4).reduce(0) {$0+(rgba[$1]>0 ? 1:0)}
     let digest=SHA256.hash(data:Data(rgba)).map {String(format:"%02x",$0)}.joined()
     decodedImageHashes["\(image.width)x\(image.height):\(digest)",default:[]].append(entry.id)
     row.merge(["width":image.width,"height":image.height,"visiblePixels":visible,"decodedRGBA_SHA256":digest]) {_,new in new}
     guard visible>0 else {throw ProjectError("Image contains no visible pixels")}
    }
    let imported=try await MediaImporter.inspect(url:url)
    let expectedKind:MediaKind = (entry.category == .sfx || entry.category == .music) ? .audio : .image
    guard imported.supported,imported.kind==expectedKind else {throw ProjectError(imported.issue ?? "Editor importer rejected this library asset")}
    row["importerAccepted"]=true
    row["passed"]=true
   } catch {row["passed"]=false;row["error"]=error.localizedDescription;failures+=1}
   rows.append(row)
   if row["passed"] as? Bool != true {print("FAIL \(entry.id): \(row["error"] ?? "unknown")")}
  }
  try library.verify()
  let report:[String:Any]=["checked":rows.count,"failures":failures,"rows":rows,"decodedImageDuplicates":decodedImageHashes.values.filter {$0.count>1},"scope":"Every catalog asset's hash/size, complete native PCM or PNG decode and editor importer acceptance, with final hash recheck; no subjective audio quality, license proof or UI insertion claim"]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("library-decode.json"),options:.atomic)
  print("LIBRARY_DECODE_RESULT checks=\(rows.count) failures=\(failures)")
  if failures>0 {throw ProjectError("Bundled media decoding failed")}
 }
}

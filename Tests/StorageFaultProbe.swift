import Foundation
import AppKit
import AVFoundation
import Darwin
import JHCutCore

@main struct StorageFaultProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil)
  guard CommandLine.arguments.count>=3 else{throw ProjectError("mode and fixture root required")}
  let mode=CommandLine.arguments[1],root=URL(fileURLWithPath:CommandLine.arguments[2]),doc=root.appendingPathComponent("project.jhcut")
  let marker=root.appendingPathComponent(".jhcut-storage-fixture")
  func owned()throws{guard (try? String(contentsOf:marker))=="JHCut storage v2" else{throw ProjectError("Not an owned fixture")}}
  func pause(_ phase:String)throws {
   try Data(phase.utf8).write(to:root.appendingPathComponent("barrier"),options:.withoutOverwriting)
   let until=Date().addingTimeInterval(30);while Date()<until{usleep(10_000)}
   throw ProjectError("Kill barrier timed out")
  }
  func render(_ project:Project,_ output:URL)async throws {
   let plan=try await TimelineRenderer.build(project:project,documentURL:doc)
   try await ExportJob(videoBitRate:4_000_000).export(plan:plan,to:output){_ in}
   let asset=AVURLAsset(url:output),tracks=try await asset.loadTracks(withMediaType:.video)
   guard let track=tracks.first else{throw ProjectError("No rendered video")}
   let size=try await track.load(.naturalSize),duration=try await asset.load(.duration)
   let reader=try AVAssetReader(asset:asset),decoder=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);reader.add(decoder)
   guard reader.startReading() else{throw ProjectError("Decode failed")};var count=0;while decoder.copyNextSampleBuffer() != nil{count+=1}
   guard reader.status == .completed,count==60,size.width==640,size.height==360,abs(duration.seconds-2)<0.005 else{throw ProjectError("Wrong restored render")}
  }
  switch mode {
  case "filesystem":
   let format=try root.resourceValues(forKeys:[.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription ?? "unknown"
   guard format.lowercased().contains("exfat") else{throw ProjectError("ExFAT fixture required, found: \(format)")};print("PASS ExFAT fixture filesystem confirmed")
  case "seed":
   try Data("JHCut storage v2".utf8).write(to:marker,options:.withoutOverwriting)
   let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640,pixelsHigh:360,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
   memset(bitmap.bitmapData!,110,bitmap.bytesPerRow*360)
   let image=root.appendingPathComponent("generated.png");try bitmap.representation(using:.png,properties:[:])!.write(to:image)
   let asset=try await MediaImporter.inspect(url:image)
   var p=Project(name:"saved-one");p.sequence.width=640;p.sequence.height=360;p.assets=[asset];p.sequence.tracks[0].clips=[Clip(assetID:asset.id,duration:MediaTime(seconds:2))]
   var caption=Clip(name:"원문",duration:MediaTime(seconds:2),title:Title(text:"복구 검증",fontSize:32));caption.captionRole = .original;caption.captionMetadata=CaptionMetadata(language:"ko",originalLanguage:"ko",originalText:"복구 검증",generatedText:"복구 검증");p.sequence.tracks[2].clips=[caption]
   let recovery=RecoveryStore(directory:root.appendingPathComponent("Recovery"))
   try ProjectStore.save(p,to:doc);try recovery.save(project:p,documentURL:doc,mediaBaseURL:doc)
   p.name="saved-two";try ProjectStore.save(p,to:doc);try recovery.save(project:p,documentURL:doc,mediaBaseURL:doc)
   print("PASS seeded current feature fixture")
  case "full":
   try owned();let before=try Data(contentsOf:doc);var p=try ProjectStore.load(from:doc);p.name="must-not-publish"
   var failed=false
   do{try ProjectStore.save(p,to:doc)}catch{failed=true;print("EXPECTED_SAVE_FAILURE \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")}
   guard failed,try Data(contentsOf:doc)==before,try ProjectStore.load(from:doc).name=="saved-two",try ["saved-one","saved-two"].contains(ProjectStore.recover(from:doc).name) else{throw ProjectError("Full disk damaged last good document")}
   print("PASS real ENOSPC retains last good document and valid backup")
  case "crash":
   try owned();let phase=CommandLine.arguments[3];var p=try ProjectStore.load(from:doc);p.name="new-edit-not-yet-saved"
   if phase.hasPrefix("recovery-") {
    try RecoveryStore(directory:root.appendingPathComponent("Recovery")).save(project:p,documentURL:doc,mediaBaseURL:doc,phaseHandler:{at in if "recovery-"+at.rawValue==phase{try pause(phase)}})
   }else{try ProjectStore.save(p,to:doc,phaseHandler:{at in if at.rawValue==phase{try pause(phase)}})}
   throw ProjectError("Barrier not reached")
  case "verify":
   try owned();let phase=CommandLine.arguments[3],p=try ProjectStore.load(from:doc),backup=try ProjectStore.recover(from:doc)
   guard p.name==(phase=="documentCommitted" ? "new-edit-not-yet-saved":"saved-two"),["saved-one","saved-two"].contains(backup.name) else{throw ProjectError("Crash changed commit boundary")}
   let recovery=RecoveryStore(directory:root.appendingPathComponent("Recovery"));guard try recovery.load()?.project.name==(phase=="recovery-currentCommitted" ? "new-edit-not-yet-saved":"saved-two"),try !recovery.availableSnapshots().isEmpty else{throw ProjectError("Recovery lost")}
   let output=URL(fileURLWithPath:CommandLine.arguments[4]).appendingPathComponent("restored-"+phase+".mp4")
   try await render(p,output)
   print("PASS \(phase) killed writer reopened and decoded 60 frames")
  case "prepare-media":
   try owned();let outside=URL(fileURLWithPath:CommandLine.arguments[3]);try ProjectStore.save(ProjectStore.load(from:doc),to:outside.appendingPathComponent("reconnect.jhcut"));print("PASS prepared referenced removable media")
  case "offline":
   let outside=URL(fileURLWithPath:CommandLine.arguments[3]),document=outside.appendingPathComponent("reconnect.jhcut"),before=try Data(contentsOf:document),p=try ProjectStore.load(from:document)
   var rejected=false;do{_ = try await TimelineRenderer.build(project:p,documentURL:document)}catch{rejected=true}
   guard rejected,try Data(contentsOf:document)==before else{throw ProjectError("Offline input was not rejected safely")};print("PASS detached owned volume leaves project intact and requires relink")
  case "resumed":
   try owned();let outside=URL(fileURLWithPath:CommandLine.arguments[3]);let p=try ProjectStore.load(from:outside.appendingPathComponent("reconnect.jhcut"));try await render(p,outside.appendingPathComponent("reconnected.mp4"));print("PASS remounted media renders and decodes 60 frames")
  default:throw ProjectError("Unknown fixture mode")
  }
 }
}

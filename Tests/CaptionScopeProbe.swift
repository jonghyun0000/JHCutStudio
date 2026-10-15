import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import JHCutCore

/// Synthetic editor/translation fixtures; actual SRT, document and movie output. No ASR accuracy claim.
@main struct CaptionScopeProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil); _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "CaptionScope")
  var rows: [[String:Any]] = []
  func check(_ name:String,_ pass:Bool) { rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") \(name)") }
  defer { try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json")) }
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  func bytes(_ clip:Clip) -> Data { try! encoder.encode(clip) }
  func find(_ p:Project,_ id:UUID) -> Clip { p.sequence.tracks.flatMap(\.clips).first { $0.id == id }! }
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"))
  model.autoCaptionImportedVideos=false;model.translateAfterTranscription=false
  var p=Project(name:"Caption role/scope fixture");p.sequence.width=640;p.sequence.height=360
  var intro=Clip(name:"인트로",start:.zero,duration:MediaTime(3,1),title:Title(text:"INTRO TITLE",fontSize:30,colorHex:"FFE55B",x:0.5,y:0.85))
  intro.captionRole = .title
  p.sequence.tracks[2].clips=[intro];model.history=EditorHistory(project:p)
  let srtURL=root.appendingPathComponent("imported.srt")
  try "1\n00:00:01,000 --> 00:00:03,000\n첫 번째 원문\n\n2\n00:00:05,000 --> 00:00:06,000\n두 번째 원문\n".write(to:srtURL,atomically:true,encoding:.utf8)
  model.importSRT(from:srtURL)
  check("Actual SRT importer creates two originals with one explicit group",model.captionClips.count == 2 && Set(model.captionClips.compactMap(\.captionGroupID)).count == 1 && model.captionClips.allSatisfy { $0.captionRole == .original })
  check("SRT import never classifies the intro as a caption",!model.captionClips.contains { $0.id == intro.id })
  let imported=model.project, originals=model.captionClips, group=originals[0].captionGroupID!
  model.undo();check("SRT import is one undo including track creation",model.project == p)
  model.redo();check("SRT import redo restores roles and group",model.project == imported)

  // Local media fixture for a real connected ASR path and final render; no user originals modified.
  var carrier=Project(name:"fixture");carrier.sequence.width=640;carrier.sequence.height=360
  carrier.sequence.tracks[2].clips=[Clip(name:"carrier",duration:MediaTime(10,1),title:Title(text:"·",fontSize:8))]
  let carrierURL=root.appendingPathComponent("source-fixture.mp4")
  try await ExportJob().export(plan:TimelineRenderer.build(project:carrier),to:carrierURL) { _ in }
  let asset=try await MediaImporter.inspect(url:carrierURL)
  let parent=Clip(name:"원본",assetID:asset.id,duration:MediaTime(10,1))
  p=imported;p.assets=[asset];p.sequence.tracks[0].clips=[parent]
  var asr=CaptionEditing.automaticClips(cues:[CaptionCue(start:MediaTime(4,1),duration:MediaTime(2,1),text:"자동 원문")],source:parent,style:Title(text:"",fontSize:24,y:0.2))[0]
  asr.captionMetadata=CaptionMetadata(language:"ko",originalLanguage:"ko",originalText:asr.title!.text,generatedText:asr.title!.text)
  var en:[Clip]=[],ja:[Clip]=[]
  for original in originals {
   en.append(try CaptionTranslationEditing.translated(original,text:"EN fixture",sourceLanguage:"ko",targetLanguage:"en",bilingual:false))
   ja.append(try CaptionTranslationEditing.translated(original,text:"JA fixture",sourceLanguage:"ko",targetLanguage:"ja",bilingual:false))
  }
  // Mixed track: ordinary title + two SRT originals + ASR + translations in two languages.
  p.sequence.tracks[2].clips=[intro]+originals+[asr]+en+ja
  p.sequence.tracks.removeLast()
  var unrelated=Clip(name:"자막",start:MediaTime(7,1),duration:MediaTime(1,1),title:Title(text:"OTHER GROUP",fontSize:22,y:0.4))
  unrelated.captionRole = .original;unrelated.captionGroupID=UUID()
  let unrelatedEN=try CaptionTranslationEditing.translated(unrelated,text:"OTHER EN",sourceLanguage:"ko",targetLanguage:"en",bilingual:false)
  p.sequence.tracks.append(Track(name:"다른 그룹 번역",kind:.title,clips:[unrelatedEN]))
  p.sequence.tracks.append(Track(name:"다른 그룹 잠금",kind:.title,clips:[unrelated],isLocked:true))
  var hidden=Clip(name:"숨긴 장식",duration:MediaTime(2,1),title:Title(text:"HIDDEN DECORATION"));hidden.captionRole = .title
  let hiddenTrack=Track(name:"수동 숨김",kind:.title,clips:[hidden],isHidden:true)
  p.sequence.tracks.append(hiddenTrack)
  let unknown=Clip(name:"옛 모호한 제목",duration:MediaTime(2,1),title:Title(text:"UNCLASSIFIED"))
  p.sequence.tracks.append(Track(name:"미분류 보존",kind:.title,clips:[unknown],isHidden:true))
  model.history=EditorHistory(project:p);model.captionOperationScope="group";model.captionSelectedGroupID=group
  model.translationSourceLanguage="ko";model.translationTargetLanguage="ja"
  model.translationProvider={ texts,_,_ in texts.map { "NEW JA · " + $0 } }
  check("Common group query excludes ASR and decoration",Set(model.scopedCaptionClips.map(\.id)) == Set((originals+en+ja).map(\.id)))
  check("Source query returns only attached ASR",CaptionQuery.entries(in:p.sequence,scope:.sources([parent.id])).map { $0.clip.id } == [asr.id])
  check("Legacy ambiguous title stays unclassified",CaptionQuery.role(of:unknown) == nil && !model.captionClips.contains { $0.id == unknown.id })
  let outside=[intro,asr,unrelated,unrelatedEN,hidden,unknown]
  func outsideUnchanged(_ project:Project) -> Bool { outside.allSatisfy { bytes(find(project,$0.id)) == bytes($0) } && project.sequence.tracks.last == p.sequence.tracks.last && project.sequence.tracks.first { $0.id == hiddenTrack.id } == hiddenTrack }
  func settle() async throws {
   let until=Date().addingTimeInterval(30)
   while model.productivityBusy || model.productivityTask != nil { guard Date() < until else { throw ProjectError("Scope probe timeout") };try await Task.sleep(nanoseconds:20_000_000) }
  }
  model.translateCaptionTracks();try await settle()
  check("Unrelated locked title/caption does not block scoped translation",model.error == nil && model.project != p)
  check("Mixed-track translation changes no outside clip bytes or manual-hidden tracks",outsideUnchanged(model.project))
  check("Only selected originals and their other-language versions are hidden",originals.allSatisfy { find(model.project,$0.id).captionHidden == true } && en.allSatisfy { find(model.project,$0.id).captionHidden == true })
  check("Track visibility itself is unchanged",zip(p.sequence.tracks,model.project.sequence.tracks).allSatisfy { $0.0.isHidden == $0.1.isHidden })
  let translated=model.project
  check("Visible SRT scope has only two selected target captions",model.exportableCaptionClips.count == 2 && model.exportableCaptionClips.allSatisfy { $0.captionRole == .translation && $0.captionMetadata?.language == "ja" })
  model.undo();check("One undo restores scoped translation including visibility",model.project == p)
  model.redo();check("Redo exactly restores scoped translation",model.project == translated)
  let document=root.appendingPathComponent("roles.jhcut");try ProjectStore.save(translated,to:document)
  check("Save/reopen retains roles groups visibility and unrelated bytes",try ProjectStore.load(from:document).sequence == translated.sequence)
  model.showOriginalCaptionTracks()
  check("Show originals changes only the requested group",outsideUnchanged(model.project) && model.exportableCaptionClips.map(\.id).sorted { $0.uuidString < $1.uuidString } == originals.map(\.id).sorted { $0.uuidString < $1.uuidString })
  model.undo();check("Show-original is one undo",model.project == translated)

  let queued=QueuedExport(project:translated,baseURL:nil,url:root.appendingPathComponent("scope-output.mp4"),codec:.h264,bitRate:4_000_000,captionScope:.groups([group]))
  model.captionSelectedGroupID=unrelated.captionGroupID
  let sidecar=try model.writeSidecarSubtitles(for:queued,scope:"visible")!
  check("Queued sidecar uses captured group, not later UI selection",try SRTCodec.parse(String(contentsOf:sidecar)).map(\.text) == CaptionQuery.entries(in:translated.sequence,scope:.groups([group]),visibleOnly:true).map { $0.clip.title!.text })
  let plan=try await TimelineRenderer.build(project:translated)
  let renderIDs=Set(plan.videoComposition.instructions.compactMap { $0 as? TimelineInstruction }.flatMap(\.layers).map { $0.clip.id })
  check("Actual render plan preserves intro and removes per-caption hidden originals",renderIDs.contains(intro.id) && !originals.contains { renderIDs.contains($0.id) } && !renderIDs.contains(hidden.id))
  let expected=OutputExpectation.from(project:translated,plan:plan)
  check("Output QA uses the same role and visibility classification",expected.captions.contains { !$0.isCaption && $0.title.text == intro.title?.text } && !expected.captions.contains { $0.title.text == originals[0].title?.text })
  try await ExportJob(videoBitRate:4_000_000).export(plan:plan,to:queued.url) { _ in }
  let generator=AVAssetImageGenerator(asset:AVURLAsset(url:queued.url));generator.appliesPreferredTrackTransform=true
  generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
  let image=try await generator.image(at:CMTime(seconds:1.5,preferredTimescale:600)).image
  let png=root.appendingPathComponent("output-frame.png")
  let destination=CGImageDestinationCreateWithURL(png as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(destination,image,nil)
  check("Actual encoded movie frame can be decoded and reviewed",CGImageDestinationFinalize(destination) && image.width == 640 && image.height == 360)
  var pixels=[UInt8](repeating:0,count:640*360*4)
  let context=CGContext(data:&pixels,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image,in:CGRect(x:0,y:0,width:640,height:360))
  let yellow=stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>130 && pixels[$0+1]>100 && pixels[$0+2]<130 }.count
  let white=stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>160 && pixels[$0+1]>160 && pixels[$0+2]>160 }.count
  check("Exact output frame contains both the preserved yellow intro and white translated subtitle",yellow>100 && white>100)


  // Selected one caption must not change the next cue in the same group.
  model.history=EditorHistory(project:p);model.error=nil;model.captionOperationScope="selection";model.selectClip(originals[0].id)
  model.translateCaptionTracks();try await settle()
  check("Selected-caption translation preserves unselected original in same group",find(model.project,originals[1].id) == originals[1] && outsideUnchanged(model.project))
  check("Selected-caption translation preserves unselected same-group translations",find(model.project,en[1].id) == en[1] && find(model.project,ja[1].id) == ja[1])
  let beforeBatch=model.project
  model.showOriginalCaptionTracks();model.selectClip(originals[0].id)
  var change=CaptionBatchChange();change.fontSize=28
  check("Selected visible caption batch uses same scope",model.applyCaptionBatch(change,fitSafeArea:false))
  check("Batch does not edit title or another cue in the same group",find(model.project,intro.id) == intro && find(model.project,originals[1].id) == originals[1])
  model.undo();model.undo();check("Batch and display each use a single undo",model.project == beforeBatch)

  // Known legacy SRT shape continues to work without metadata. Unknown titles are not migrated.
  var legacy=p;legacy.sequence.tracks[2].clips=[intro,originals[0],unknown]
  legacy.sequence.tracks.removeLast()
  legacy.sequence.tracks[2].clips[1].captionRole=nil;legacy.sequence.tracks[2].clips[1].captionGroupID=nil
  let migrated=CaptionQuery.migrated(legacy.sequence)
  check("Legacy SRT migration is explicit deterministic and preserves ambiguous title",migrated.tracks[2].clips[1].captionRole == .original && migrated.tracks[2].clips[2] == unknown)
  for ti in legacy.sequence.tracks.indices {
   for ci in legacy.sequence.tracks[ti].clips.indices {
    legacy.sequence.tracks[ti].clips[ci].captionRole=nil;legacy.sequence.tracks[ti].clips[ci].captionGroupID=nil;legacy.sequence.tracks[ti].clips[ci].captionHidden=nil
   }
  }
  let oldURL=root.appendingPathComponent("legacy.jhcut")
  try encoder.encode(legacy).write(to:oldURL)
  var modern=legacy;modern.sequence=migrated
  try ProjectStore.save(modern,to:oldURL)
  check("First role save preserves exact old document",try Data(contentsOf:ProjectStore.beforeCaptionRolesURL(for:oldURL)) == encoder.encode(legacy))
  check("Legacy SRT stays editable/exportable before migration",CaptionQuery.entries(in:legacy.sequence,role:.original).contains { $0.clip.id == originals[0].id })
  model.history=EditorHistory(project:p);model.selectClip(unknown.id);model.setSelectedCaptionRole(.original)
  check("User can classify ambiguous title without moving or unhiding its track",CaptionQuery.role(of:find(model.project,unknown.id)) == .original && model.project.sequence.tracks.last?.isHidden == true)
  model.undo();check("Role assignment is reversible in one undo",model.project == p)

  // Split/merge, duplication and independent sequence derivation keep group semantics.
  var history=EditorHistory(project:p)
  let sourceTrack=p.sequence.tracks[0].id
  try history.apply(.duplicate(trackID:sourceTrack,clipID:parent.id))
  let copiedParent=history.project.sequence.tracks[0].clips.last!
  let copied=history.project.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == copiedParent.id }
  check("Duplicated source gets its own caption group",copied.count == 1 && copied[0].captionGroupID == copiedParent.id && copied[0].captionGroupID != asr.captionGroupID)
  history=EditorHistory(project:p)
  let ti=p.sequence.tracks[2].id
  try history.apply(.split(trackID:ti,clipID:originals[0].id,at:MediaTime(2,1)))
  let pieces=history.project.sequence.tracks[2].clips.filter { $0.id == originals[0].id || $0.lineageID == originals[0].id }
  check("Split preserves original role and group",pieces.count == 2 && pieces.allSatisfy { $0.captionRole == .original && $0.captionGroupID == group })
  let joined=try CaptionEditing.merged(first:pieces[0],second:pieces[1])
  check("Merge keeps role and group",joined.captionRole == .original && joined.captionGroupID == group)
  do { _=try CaptionEditing.merged(first:originals[0],second:asr);check("Cross-group merge refused",false) } catch { check("Cross-group merge refused",true) }
  history=EditorHistory(project:p);try history.apply(.deriveSequence(name:"derived",width:640,height:360))
  let derived=history.project.sequence
  let sourceCopies=derived.tracks.flatMap(\.clips).filter { $0.captionRole == .original && $0.captionGroupID != parent.id }
  let srtCopies=sourceCopies.filter { $0.name == "자막" && $0.title?.text != unrelated.title?.text }
  check("Independent sequence remaps shared group consistently",srtCopies.count == 2 && Set(srtCopies.compactMap(\.captionGroupID)).count == 1 && srtCopies[0].captionGroupID != group)
  check("Derived translations reference derived originals",derived.tracks.flatMap(\.clips).filter { $0.captionRole == .translation }.allSatisfy { t in derived.tracks.flatMap(\.clips).contains { $0.id == t.captionMetadata?.translatedFrom && $0.captionGroupID == t.captionGroupID } })
  model.history=EditorHistory(project:p);model.captionOperationScope="group";model.captionSelectedGroupID=group;model.selectClip(originals[0].id);model.error=nil
  model.mergeNextCaption()
  check("Merge with existing different-original translations refuses without orphaning references",model.project == p && model.error != nil)
  var legacySimple=Project(name:"Legacy SRT merge")
  var oldA=originals[0],oldB=originals[1]
  oldA.captionRole=nil;oldA.captionGroupID=nil;oldB.captionRole=nil;oldB.captionGroupID=nil
  legacySimple.sequence.tracks[2].clips=[intro,oldA,oldB]
  let legacyGroup=legacySimple.sequence.tracks[2].id
  model.history=EditorHistory(project:legacySimple);model.captionOperationScope="all";model.selectClip(oldA.id);model.error=nil
  model.mergeNextCaption()
  let mergedLegacy=find(model.project,oldA.id)
  check("App legacy SRT merge keeps its interpreted track group",model.error == nil && mergedLegacy.captionRole == .original && mergedLegacy.captionGroupID == legacyGroup && model.captionClips.count == 1)
  check("Legacy merge leaves the decoration byte-identical",bytes(find(model.project,intro.id)) == bytes(intro))
  model.undo();check("Legacy merge is one undo including role stamping",model.project == legacySimple)
  model.captionOperationScope="selection";model.selectClip(oldA.id);model.error=nil;model.mergeNextCaption()
  check("Merge refuses an unselected next cue outside the operation scope",model.project == legacySimple && model.error != nil)
  var lineageProject=Project(name:"Split then duplicate identity");lineageProject.assets=[asset]
  lineageProject.sequence.tracks[0].clips=[parent]
  let asrTranslation=try CaptionTranslationEditing.translated(asr,text:"ASR EN",sourceLanguage:"ko",targetLanguage:"en",bilingual:false)
  lineageProject.sequence.tracks[2].clips=[asr]
  lineageProject.sequence.tracks.append(Track(name:"ASR translation in a separate track",kind:.title,clips:[asrTranslation]))
  var lineageHistory=EditorHistory(project:lineageProject)
  let videoID=lineageProject.sequence.tracks[0].id,captionTrackID=lineageProject.sequence.tracks[2].id
  try lineageHistory.apply(.split(trackID:videoID,clipID:parent.id,at:MediaTime(5,1)))
  let splitProject=lineageHistory.project,rightParent=splitProject.sequence.tracks[0].clips.last!
  let rightChildren=splitProject.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == rightParent.id }
  let rightOriginal=rightChildren.first { $0.captionRole == .original }!,rightTranslation=rightChildren.first { $0.captionRole == .translation }!
  check("Selecting a split translation resolves only overlapping original, not unselected left lineage",CaptionQuery.originals(in:splitProject.sequence,scope:.selected([rightTranslation.id])).map { $0.clip.id } == [rightOriginal.id])
  try lineageHistory.apply(.duplicate(trackID:videoID,clipID:rightParent.id))
  let copiedRight=lineageHistory.project.sequence.tracks[0].clips.last!
  let copiedChildren=lineageHistory.project.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == copiedRight.id }
  let copiedOriginal=copiedChildren.first { $0.captionRole == .original }!,copiedTranslation=copiedChildren.first { $0.captionRole == .translation }!
  check("Split-source duplication binds translation to copied right original, not old left root",copiedTranslation.captionMetadata?.translatedFrom == copiedOriginal.id && copiedTranslation.captionGroupID == copiedOriginal.captionGroupID && copiedOriginal.captionGroupID == copiedRight.id)
  lineageHistory.undo();check("Split-source duplicate identity changes undo atomically",lineageHistory.project == splitProject)
  var repeated=splitProject
  let freshRightTranslation=try CaptionTranslationEditing.translated(rightOriginal,text:"Fresh right translation",sourceLanguage:"ko",targetLanguage:"en",bilingual:false)
  let repeatedTranslationTrack=repeated.sequence.tracks.firstIndex { $0.clips.contains { $0.id == rightTranslation.id } }!
  repeated.sequence.tracks[repeatedTranslationTrack].clips=[freshRightTranslation]
  var repeatedHistory=EditorHistory(project:repeated)
  try repeatedHistory.apply(.split(trackID:videoID,clipID:rightParent.id,at:MediaTime(11,2)))
  let newestParent=repeatedHistory.project.sequence.tracks[0].clips.last!
  let newestChildren=repeatedHistory.project.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == newestParent.id }
  let newestOriginal=newestChildren.first { $0.captionRole == .original }!,newestTranslation=newestChildren.first { $0.captionRole == .translation }!
  check("Fresh translation on a split original stays connected across another source split",CaptionQuery.related(newestTranslation,to:newestOriginal) && CaptionQuery.originals(in:repeatedHistory.project.sequence,scope:.selected([newestTranslation.id])).map { $0.clip.id } == [newestOriginal.id])
  lineageHistory=EditorHistory(project:splitProject)
  try lineageHistory.apply(.delete(trackID:captionTrackID,clipID:asr.id,ripple:false))
  try lineageHistory.apply(.deriveSequence(name:"missing root derived",width:640,height:360))
  let remappedRight=lineageHistory.project.sequence.tracks[0].clips.last!
  let derivedChildren=lineageHistory.project.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == remappedRight.id }
  let derivedOriginal=derivedChildren.first { $0.captionRole == .original }!,derivedTranslation=derivedChildren.first { $0.captionRole == .translation }!
  check("Independent sequence remaps translation lineage even when original root clip was removed",CaptionQuery.related(derivedTranslation,to:derivedOriginal) && derivedTranslation.captionMetadata?.translatedFrom != asr.id)
  let failures=rows.filter { ($0["passed"] as? Bool) != true }.count
  print("CAPTION_SCOPE_RESULT checks=\(rows.count) failures=\(failures)")
  if failures>0 { exit(1) }
 }
}

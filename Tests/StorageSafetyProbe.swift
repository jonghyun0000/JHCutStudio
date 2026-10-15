import Foundation
import AppKit
import Darwin
@testable import JHCutCore

@main struct StorageSafetyProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil);_ = NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/StorageSafety");var rows:[[String:Any]]=[]
  func check(_ n:String,_ value:Bool){rows.append(["name":n,"passed":value]);print("\(value ? "PASS":"FAIL") \(n)")}
  func rejected(_ body:()throws->Void)->Bool{do{try body();return false}catch{return true}}
  func bytes(_ u:URL)throws->Data{try Data(contentsOf:u)}
  var p=Project(name:"저장된 프로젝트");p.sequence.width=640;p.sequence.height=360;p.sequence.tracks[2].clips=[Clip(duration:MediaTime(seconds:2),title:Title(text:"마지막 저장 자막",fontSize:30))]
  let doc=root.appendingPathComponent("프로젝트.jhcut");try ProjectStore.save(p,to:doc);p.name="저장된 두 번째 상태";try ProjectStore.save(p,to:doc)
  let original=try bytes(doc);var edit=p;edit.name="미저장 편집"
  check("Injected document stage failure is reported",rejected{try ProjectStore.save(edit,to:doc,phaseHandler:{if $0 == .documentStaged{throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))}})})
  check("Staged failure retains exact current bytes",try bytes(doc)==original)
  check("Staged failure retains latest good backup",try ProjectStore.recover(from:doc).name==p.name)
  check("Owned failed staging removed",try !FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasSuffix(".partial")})
  try Data("damaged".utf8).write(to:doc);let goodBackup=try bytes(ProjectStore.backupURL(for:doc))
  check("Corrupt current cannot poison good backup",rejected{try ProjectStore.save(edit,to:doc)})
  check("Good backup bytes remain intact",try bytes(ProjectStore.backupURL(for:doc))==goodBackup)
  check("Strict load never silently substitutes backup",rejected{_ = try ProjectStore.load(from:doc)})
  let recovered=try ProjectStore.recover(from:doc),copy=root.appendingPathComponent("Recovered.jhcut");try ProjectStore.save(recovered,to:copy)
  check("Explicit recovery saved separately preserves damaged original",try String(contentsOf:doc)=="damaged" && ProjectStore.load(from:copy).name==p.name);try original.write(to:doc)
  let recovery=RecoveryStore(directory:root.appendingPathComponent("Recovery"))
  try recovery.save(project:p,documentURL:doc,mediaBaseURL:doc);try recovery.save(project:p,documentURL:doc,mediaBaseURL:doc)
  let current=try bytes(recovery.snapshotURL),previous=try bytes(recovery.backupURL)
  check("Recovery previous stage failure reported",rejected{try recovery.save(project:edit,documentURL:doc,mediaBaseURL:doc,phaseHandler:{if $0 == .previousStaged{throw NSError(domain:NSPOSIXErrorDomain,code:Int(EACCES))}})})
  check("Recovery failure preserves both previous bytes",try bytes(recovery.snapshotURL)==current && bytes(recovery.backupURL)==previous)
  check("Recovery current stage failure reported",rejected{try recovery.save(project:edit,documentURL:doc,mediaBaseURL:doc,phaseHandler:{if $0 == .currentStaged{throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))}})})
  check("Recovery current bytes still exact after stage failure",try bytes(recovery.snapshotURL)==current)
  try Data("broken".utf8).write(to:recovery.snapshotURL)
  check("Damaged active recovery is not silently read",rejected{_ = try recovery.load()})
  check("Explicit prior recovery remains available",try recovery.loadPrevious()?.project.id==p.id && recovery.availableSnapshots().count==1)
  var other=Project(name:"다른 미저장 문서");other.sequence=p.sequence
  try recovery.save(project:other,documentURL:nil,mediaBaseURL:nil);other.name="다른 문서 변경";try recovery.save(project:other,documentURL:nil,mediaBaseURL:nil)
  check("Different project recovery retained in archive",try Set(recovery.availableSnapshots().map{ $0.project.id })==Set([p.id,other.id]))
  check("Unsaved recovery records nil document and source base",try recovery.load()?.documentURL==nil && recovery.load()?.mediaBaseURL==nil)
  let backups=root.appendingPathComponent("Backups"),folder=try ProjectBackup.create(documentURL:doc,root:backups,appVersion:"stage11",unsavedChangesPresent:true)
  let entry=ProjectBackup.list(root:backups).first!
  check("Manifest explicitly describes saved-only contents",entry.manifest.contents=="lastSavedDocument" && entry.manifest.unsavedChangesPresent==true && entry.manifest.mediaIncluded==false)
  check("Manifest records automatic backup identity",entry.manifest.automaticBackupSHA256==ExportDeliveryReceipt.digest(goodBackup))
  check("Restore returns last saved data",try ProjectBackup.restore(entry).name==p.name)
  let concurrent=try await withThrowingTaskGroup(of:URL.self){g in for _ in 0..<2{g.addTask{try ProjectBackup.create(documentURL:doc,root:backups,appVersion:"race")}};var a:[URL]=[];for try await u in g{a.append(u)};return a}
  check("Concurrent backups have independent destination folders",concurrent[0] != concurrent[1] && ProjectBackup.list(root:backups).count==3)
  let savedFile=folder.appendingPathComponent(entry.manifest.documentName),savedBytes=try bytes(savedFile)
  try Data("tampered".utf8).write(to:savedFile)
  check("Damaged backup excluded from recovery list",ProjectBackup.scan(root:backups).rejected==1 && ProjectBackup.list(root:backups).count==2)
  check("Stale damaged selection rejects restore",rejected{_ = try ProjectBackup.restore(entry)})
  check("Backup scan preserves damaged bytes",try String(contentsOf:savedFile)=="tampered");try savedBytes.write(to:savedFile)
  let priorFile=folder.appendingPathComponent(entry.manifest.documentName+".backup"),priorBytes=try bytes(priorFile);try Data("tampered prior".utf8).write(to:priorFile)
  check("Manifest prior digest checked again at restore",rejected{_ = try ProjectBackup.restore(entry)})
  check("Damaged prior copy excluded by scan",ProjectBackup.scan(root:backups).rejected==1);try priorBytes.write(to:priorFile)
  let partial=backups.appendingPathComponent("incomplete-visible");try FileManager.default.createDirectory(at:partial,withIntermediateDirectories:false);try savedBytes.write(to:partial.appendingPathComponent("partial.jhcut"))
  check("Missing manifest never advertised as complete",ProjectBackup.scan(root:backups).rejected==1 && !ProjectBackup.list(root:backups).contains{$0.folder==partial})
  var unsafe=entry;unsafe.manifest.documentName="../Recovered.jhcut";check("Manifest path traversal refused",rejected{_ = try ProjectBackup.restore(unsafe)})
  let manifestURL=folder.appendingPathComponent("manifest.json"),manifestBytes=try bytes(manifestURL)
  var legacy=try JSONSerialization.jsonObject(with:manifestBytes) as! [String:Any];for key in ["contents","unsavedChangesPresent","mediaIncluded","automaticBackupSHA256"]{legacy.removeValue(forKey:key)}
  try JSONSerialization.data(withJSONObject:legacy).write(to:manifestURL)
  check("Legacy manifest remains readable with honest unknown dirty status",ProjectBackup.list(root:backups).first{$0.folder==folder}?.manifest.scopeSummary.contains("여부 기록 없음")==true)
  try manifestBytes.write(to:manifestURL)
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("EditorRecovery")),exportHistoryURL:root.appendingPathComponent("journal.json"));model.backupRoot=root.appendingPathComponent("EditorBackups");model.load(doc)
  while model.isBuilding{try await Task.sleep(nanoseconds:20_000_000)}
  _ = model.perform(.rename("미저장 프로젝트 이름"));model.createProjectBackup();let dirtyEntry=model.backupEntries.first!
  check("Editor success retains unsaved-change exclusion warning",model.message.contains("미저장 변경 제외") && dirtyEntry.manifest.unsavedChangesPresent==true)
  check("Editor backup excludes live unsaved edit",try ProjectBackup.restore(dirtyEntry).name==p.name && model.project.name != p.name)
  while model.isBuilding{try await Task.sleep(nanoseconds:20_000_000)};model.undo()
  while model.isBuilding{try await Task.sleep(nanoseconds:20_000_000)};model.restoreBackup(dirtyEntry)
  check("Editor restore opens new unsaved document with scope explanation",model.documentURL==nil && model.dirty && model.message.contains("마지막 저장본") && model.message.contains("미저장 변경 제외"))
  check("Original document unchanged by editor backup/restore",try bytes(doc)==original)
  // Recovery picker promises an unsaved copy, even when its snapshot came from a saved file.
  let editorRecoveryRoot=root.appendingPathComponent("RecoveredEditor");try FileManager.default.createDirectory(at:editorRecoveryRoot,withIntermediateDirectories:false)
  let editorRecoveryStore=RecoveryStore(directory:editorRecoveryRoot.appendingPathComponent("Autosaves"))
  var recoveredEdit=p;recoveredEdit.name="Recovered unsaved changes"
  let snapshot=RecoverySnapshot(project:recoveredEdit,documentURL:doc,mediaBaseURL:doc)
  try editorRecoveryStore.save(project:recoveredEdit,documentURL:doc,mediaBaseURL:doc)
  let fresh=EditorModel(recoveryStore:editorRecoveryStore,exportHistoryURL:editorRecoveryRoot.appendingPathComponent("journal.json"))
  fresh.error="A previous document failed";try fresh.applyRecoverySnapshot(snapshot)
  check("Saved-document autosave opens a separate dirty copy",fresh.documentURL==nil && fresh.dirty && fresh.savedData==nil && fresh.project==recoveredEdit)
  check("Recovery retains original media base and clears unrelated errors",fresh.mediaBaseURL==doc && fresh.error==nil)
  check("Opening autosave preserves original document bytes",try bytes(doc)==original)
  let recoveredDestination=editorRecoveryRoot.appendingPathComponent("Chosen-Recovery.jhcut");fresh.save(to:recoveredDestination)
  check("Explicit recovery destination saves restored edits",try fresh.error==nil && !fresh.dirty && fresh.documentURL==recoveredDestination && ProjectStore.load(from:recoveredDestination).name==recoveredEdit.name)
  check("Saving recovered copy preserves original and clears only its recovery slot",try bytes(doc)==original && editorRecoveryStore.availableSnapshots().isEmpty)
  let otherDoc=editorRecoveryRoot.appendingPathComponent("Other.jhcut");var otherSaved=p;otherSaved.id=UUID();otherSaved.name="Other saved document";try ProjectStore.save(otherSaved,to:otherDoc);let otherBytes=try bytes(otherDoc)
  let cross=EditorModel(recoveryStore:RecoveryStore(directory:editorRecoveryRoot.appendingPathComponent("CrossRecovery")),exportHistoryURL:editorRecoveryRoot.appendingPathComponent("cross-journal.json"))
  cross.load(otherDoc);try cross.applyRecoverySnapshot(snapshot)
  check("Cross-document recovery drops prior save identity",cross.documentURL==nil && cross.project.id==recoveredEdit.id && cross.dirty)
  let crossDestination=editorRecoveryRoot.appendingPathComponent("Cross-Recovered.jhcut");cross.save(to:crossDestination)
  check("Cross-document recovery saves without false external-change conflict",try cross.error==nil && !cross.dirty && ProjectStore.load(from:crossDestination).name==recoveredEdit.name)
  check("Cross-document recovery leaves both source documents exact",try bytes(doc)==original && bytes(otherDoc)==otherBytes)
  let mediaFolder=root.appendingPathComponent("RelativeMedia");try FileManager.default.createDirectory(at:mediaFolder,withIntermediateDirectories:false)
  let imageFile=mediaFolder.appendingPathComponent("source.png")
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  for y in 0..<4 {for x in 0..<4 {bitmap.setColor(.systemTeal,atX:x,y:y)}}
  let imageBytes=bitmap.representation(using:.png,properties:[:])!;try imageBytes.write(to:imageFile)
  var relativeAsset=try await MediaImporter.inspect(url:imageFile);relativeAsset.path=root.appendingPathComponent("missing-location.png").path;relativeAsset.bookmark=nil;relativeAsset.relativePath="RelativeMedia/source.png"
  var legacyRecovered=p;legacyRecovered.assets=[relativeAsset]
  let legacySnapshot=RecoverySnapshot(project:legacyRecovered,documentURL:doc,mediaBaseURL:nil)
  let relativeEditor=EditorModel(recoveryStore:RecoveryStore(directory:editorRecoveryRoot.appendingPathComponent("RelativeRecovery")),exportHistoryURL:editorRecoveryRoot.appendingPathComponent("relative-journal.json"))
  try relativeEditor.applyRecoverySnapshot(legacySnapshot)
  check("Legacy snapshot falls back to original document for relative media",relativeEditor.documentURL==nil && relativeEditor.mediaBaseURL==doc && relativeEditor.project.assets[0].resolvedURL(relativeTo:relativeEditor.mediaBaseURL)==imageFile)
  check("Recovery does not rewrite relative source bytes",try bytes(imageFile)==imageBytes && bytes(doc)==original)
  let movedRecoveryFolder=editorRecoveryRoot.appendingPathComponent("New-Save-Location");try FileManager.default.createDirectory(at:movedRecoveryFolder,withIntermediateDirectories:false)
  let movedRecoveryDocument=movedRecoveryFolder.appendingPathComponent("Relative-Recovered.jhcut");relativeEditor.save(to:movedRecoveryDocument)
  let reopenedRecovery=try ProjectStore.load(from:movedRecoveryDocument)
  check("Recovery Save As preserves resolved sources across document locations",relativeEditor.error==nil && reopenedRecovery.assets[0].resolvedURL(relativeTo:movedRecoveryDocument)==imageFile && reopenedRecovery.assets[0].contentHash==relativeAsset.contentHash)
  let reopenEditor=EditorModel(recoveryStore:RecoveryStore(directory:editorRecoveryRoot.appendingPathComponent("ReopenedRecovery")),exportHistoryURL:editorRecoveryRoot.appendingPathComponent("reopened-journal.json"));reopenEditor.load(movedRecoveryDocument)
  check("Saved relative recovery reopens in actual editor with original media intact",try reopenEditor.error==nil && !reopenEditor.dirty && reopenEditor.project.assets[0].resolvedURL(relativeTo:reopenEditor.mediaBaseURL)==imageFile && bytes(imageFile)==imageBytes && bytes(doc)==original)
  let locked=FileManager.default.temporaryDirectory.appendingPathComponent("JHCut-store-permission-"+UUID().uuidString);try FileManager.default.createDirectory(at:locked,withIntermediateDirectories:false)
  defer{chmod(locked.path,0o700);try? FileManager.default.removeItem(at:locked)}
  let lockedDoc=locked.appendingPathComponent("good.jhcut");try ProjectStore.save(p,to:lockedDoc);let lockedBytes=try bytes(lockedDoc);chmod(locked.path,0o500)
  check("Actual APFS permission denial fails save",rejected{try ProjectStore.save(edit,to:lockedDoc)})
  check("Permission denial leaves last saved bytes unchanged",try bytes(lockedDoc)==lockedBytes)
  let future=root.appendingPathComponent("Future.jhcut");var unknown=try JSONSerialization.jsonObject(with:original) as! [String:Any];unknown["schemaVersion"]=2;try JSONSerialization.data(withJSONObject:unknown).write(to:future)
  check("Future document cannot be saved over",rejected{try ProjectStore.save(p,to:future)})
  check("Future document cannot be backed up as compatible",rejected{_ = try ProjectBackup.create(documentURL:future,root:backups,appVersion:"current")})
  let legacyDoc=root.appendingPathComponent("Legacy.jhcut");try ProjectStore.save(p,to:legacyDoc)
  var roleEdit=p;roleEdit.sequence.tracks[2].clips[0].captionRole = .original
  check("Legacy preservation stage failure aborts current update",rejected{try ProjectStore.save(roleEdit,to:legacyDoc,phaseHandler:{if $0 == .legacyStaged{throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))}})})
  check("Legacy preservation fault leaves last document readable",try ProjectStore.load(from:legacyDoc).sequence.tracks[2].clips[0].captionRole==nil)
  check("Legacy preservation fault publishes no partial original",!FileManager.default.fileExists(atPath:ProjectStore.beforeCaptionRolesURL(for:legacyDoc).path))
  try ProjectStore.save(roleEdit,to:legacyDoc);let retained=ProjectStore.beforeCaptionRolesURL(for:legacyDoc),retainedBytes=try bytes(retained),legacyCurrent=try bytes(legacyDoc)
  try Data("incomplete original".utf8).write(to:retained)
  check("Damaged immutable original refuses silent further saves",rejected{try ProjectStore.save(roleEdit,to:legacyDoc)})
  check("Damaged original refusal preserves current document",try bytes(legacyDoc)==legacyCurrent);try retainedBytes.write(to:retained)
  let failures=rows.filter{($0["passed"] as? Bool) != true}.count;try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"));print("STORAGE_SAFETY_RESULT checks=\(rows.count) failures=\(failures)");if failures>0{exit(1)}
 }
}

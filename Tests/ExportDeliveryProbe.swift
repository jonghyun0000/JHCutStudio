import Foundation
import AppKit
import AVFoundation
import Darwin
import JHCutCore

@main struct ExportDeliveryProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil);_ = NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/ExportDelivery")
  var rows:[[String:Any]]=[]
  func check(_ name:String,_ ok:Bool,_ detail:String=""){rows.append(["name":name,"passed":ok,"detail":detail]);print("\(ok ? "PASS":"FAIL") \(name) \(detail)")}
  defer{try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))}
  func exists(_ u:URL)->Bool{FileManager.default.fileExists(atPath:u.path)}
  let fixtureProject=project("Report pair fixture"),fixtureMovie=root.appendingPathComponent("report-fixture.mp4")
  let fixturePlan=try await TimelineRenderer.build(project:fixtureProject)
  try await ExportJob().export(plan:fixturePlan,to:fixtureMovie){_ in}
  var report=try await OutputQuality.check(output:fixtureMovie,expectation:OutputExpectation.from(project:fixtureProject,plan:fixturePlan))
  report.exportJobID=UUID()
  let reports=root.appendingPathComponent("Bundles");let first=try OutputQuality.write(report,to:reports,name:"same")
  check("Manifest verified report pair",try OutputQuality.readPublished(first).exportJobID==report.exportJobID)
  let firstJSON=try Data(contentsOf:first.deletingPathExtension().appendingPathExtension("json")),firstMD=try Data(contentsOf:first)
  var other=report;other.exportJobID=UUID();other.file="different job"
  let second=try OutputQuality.write(other,to:reports,name:"same")
  check("Same name creates immutable independent pairs",try first != second && (try Data(contentsOf:first))==firstMD && (try Data(contentsOf:first.deletingPathExtension().appendingPathExtension("json")))==firstJSON)
  check("Reports retain own job identities",try OutputQuality.readPublished(second).exportJobID==other.exportJobID)
  do{_ = try OutputQuality.write(other,to:reports,name:"fault",beforeSecondWrite:{_ in throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))});check("Second write ENOSPC fails",false)}catch{check("Second write ENOSPC fails",true)}
  check("Second write failure preserves both prior files",try Data(contentsOf:first)==firstMD && Data(contentsOf:first.deletingPathExtension().appendingPathExtension("json"))==firstJSON)
  check("No failed pair advertised",try FileManager.default.contentsOfDirectory(atPath:reports.path).allSatisfy{!$0.hasPrefix("fault-") && !$0.hasSuffix(".partial")})
  do{_ = try OutputQuality.write(other,to:reports,name:"cancel",beforeSecondWrite:{_ in throw CancellationError()});check("Pair cancellation propagated",false)}catch is CancellationError{check("Pair cancellation propagated",true)}
  let id=UUID();let fixed=try OutputQuality.write(report,to:reports,name:"fixed",publicationID:id)
  do{_ = try OutputQuality.write(other,to:reports,name:"fixed",publicationID:id);check("Existing publication ID never replaced",false)}catch{check("Existing publication ID never replaced",try OutputQuality.readPublished(fixed).exportJobID==report.exportJobID)}
  try Data("corrupt".utf8).write(to:second)
  do{_ = try OutputQuality.readPublished(second);check("Mixed/tampered pair rejected",false)}catch{check("Mixed/tampered pair rejected",true)}
  let concurrent=try await withThrowingTaskGroup(of:URL.self){group in
   for _ in 0..<2{let value=report;group.addTask{try OutputQuality.write(value,to:reports,name:"concurrent")}}
   var urls:[URL]=[];for try await url in group{urls.append(url)};return urls
  }
  check("Concurrent same-name report publication isolated",try concurrent[0] != concurrent[1] && (try OutputQuality.readPublished(concurrent[0])).exportJobID==report.exportJobID && (try OutputQuality.readPublished(concurrent[1])).exportJobID==report.exportJobID)
  let target=root.appendingPathComponent("exclusive.bin"),a=root.appendingPathComponent("a.bin"),b=root.appendingPathComponent("b.bin")
  try Data("a".utf8).write(to:a);try Data("b".utf8).write(to:b)
  let wins=await withTaskGroup(of:Bool.self){group in
   for source in [a,b]{group.addTask{do{try ExclusivePublication.file(from:source,to:target);return true}catch{return false}}}
   var n=0;for await won in group{if won{n+=1}};return n
  }
  check("Exclusive same-destination race has one winner",try wins==1 && [Data("a".utf8),Data("b".utf8)].contains(try Data(contentsOf:target)))
  let protected=try Data(contentsOf:target);let late=root.appendingPathComponent("late.bin");try Data("late".utf8).write(to:late)
  do{try ExclusivePublication.file(from:late,to:target);check("Existing file protected",false)}catch{check("Existing file protected",try Data(contentsOf:target)==protected && exists(late))}
  let large=root.appendingPathComponent("large.bin"), interrupted=root.appendingPathComponent("interrupted.bin")
  try Data(repeating:7,count:3_145_728).write(to:large);var chunks=0
  do{try ExclusivePublication.file(from:large,to:interrupted,check:{chunks+=1;if chunks==3{throw CancellationError()}});check("ExFAT copy cancellation removes only owned partial",false)}catch is CancellationError{check("ExFAT copy cancellation removes only owned partial",!exists(interrupted) && exists(large))}
  let permissionRoot=FileManager.default.temporaryDirectory.appendingPathComponent("JHCut-permission-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:permissionRoot,withIntermediateDirectories:false)
  defer{chmod(permissionRoot.path,0o700);try? FileManager.default.removeItem(at:permissionRoot)}
  let permissionSource=permissionRoot.appendingPathComponent("source.bin");try Data("keep".utf8).write(to:permissionSource)
  chmod(permissionRoot.path,0o500)
  do{try ExclusivePublication.file(from:permissionSource,to:permissionRoot.appendingPathComponent("denied.bin"));check("Read-only destination fails preserves source",false)}catch{check("Read-only destination fails preserves source",(error as NSError).code==Int(EACCES) && exists(permissionSource) && !exists(permissionRoot.appendingPathComponent("denied.bin")))}
  let ws=try ExportWorkspace(parent:root,id:UUID()),foreign=root.appendingPathComponent(".JHCut-delivery-foreign.partial");try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:false)
  try Data("keep".utf8).write(to:foreign.appendingPathComponent("foreign"));ws.cleanup()
  check("Cleanup never scans sibling prefixes",!exists(ws.url) && exists(foreign.appendingPathComponent("foreign")))
  let swapped=try ExportWorkspace(parent:root,id:UUID()),moved=root.appendingPathComponent("moved-owned")
  try FileManager.default.moveItem(at:swapped.url,to:moved);try FileManager.default.createDirectory(at:swapped.url,withIntermediateDirectories:false);try Data("keep".utf8).write(to:swapped.url.appendingPathComponent("foreign"));swapped.cleanup()
  check("Cleanup rejects replaced workspace identity",exists(swapped.url.appendingPathComponent("foreign")))
  func project(_ text:String="Snapshot")->Project {
   var p=Project(name:text);p.sequence.width=640;p.sequence.height=360
   var clip=Clip(name:"caption",duration:MediaTime(seconds:2),title:Title(text:text,fontSize:30,x:0.5,y:0.5,style:TextStyle(shadow:false)))
   clip.captionRole = .original;clip.captionMetadata=CaptionMetadata(language:"en",originalLanguage:"en",originalText:text,generatedText:text);p.sequence.tracks[2].clips=[clip];return p
  }
  func model(_ name:String)->EditorModel {
   let dir=root.appendingPathComponent(name);let m=EditorModel(recoveryStore:RecoveryStore(directory:dir.appendingPathComponent("Recovery")),exportHistoryURL:dir.appendingPathComponent("journal.json"));m.reportsDirectory=dir.appendingPathComponent("Reports");return m
  }
  func wait(_ m:EditorModel)async {while m.isExporting{await m.exportTask?.value}}
  func request(_ p:Project,_ name:String,_ sidecar:Bool=true)->QueuedExport{QueuedExport(project:p,baseURL:nil,url:root.appendingPathComponent(name+".mp4"),codec:.h264,bitRate:4_000_000,sidecarSRT:sidecar)}
  let p=project(),m=model("Healthy"),q1=request(p,"healthy1"),q2=request(p,"healthy2")
  m.exportQueue=[q1,q2];m.exportSidecarSRT=false;m.subtitleExportScope="translation";m.history=EditorHistory(project:Project(name:"later editing"))
  m.startNextExport();await wait(m)
  check("Queue advances two successful captured snapshots",m.exportQueue.allSatisfy{$0.status=="완료"},m.exportQueue.map(\.status).joined(separator:","))
  check("Sidecar settings captured at enqueue",exists(q1.url.deletingPathExtension().appendingPathExtension("srt")) && exists(q2.url.deletingPathExtension().appendingPathExtension("srt")))
  check("Project receipt is captured queued project",m.lastExportReceipt?.projectSHA256 == (try ExportDeliveryReceipt(jobID:q2.id,project:p,destination:q2.url).projectSHA256))
  check("Receipt independently records four stages",m.lastExportReceipt?.movie == .published && m.lastExportReceipt?.subtitles == .published && m.lastExportReceipt?.quality == .completed && m.lastExportReceipt?.report == .published)
  check("Journal includes job/source/phase provenance",m.exportJournal.count==2 && m.exportJournal.last?["jobID"]==q2.id.uuidString && m.exportJournal.last?["receiptJSON"] != nil)
  let published=try OutputQuality.readPublished(m.lastQualityReportURL!)
  check("QA tied to same export snapshot and output bytes",published.exportJobID==q2.id && published.projectSHA256==m.lastExportReceipt?.projectSHA256 && published.outputSHA256==m.lastExportReceipt?.movieSHA256)
  let oldReport=m.lastQualityReportURL!;m.recheckLastExport();await wait(m)
  check("Recheck creates new pair preserves old pair",try m.lastQualityReportURL != oldReport && exists(oldReport) && (try OutputQuality.readPublished(oldReport)).exportJobID==q2.id)
  let originalMovie=try Data(contentsOf:q2.url);try Data(contentsOf:fixtureMovie).write(to:q2.url);m.recheckLastExport();await wait(m)
  check("Changed output not silently associated with old job",m.lastQualityReportURL==nil && m.exportQualityStatus.contains("실패") && m.exportQualityStatus.contains("변경"));try originalMovie.write(to:q2.url)
  let raceA=model("MovieRaceA"),raceB=model("MovieRaceB"),raceRequestA=request(p,"model-race",false),raceRequestB=request(p,"model-race",false)
  raceA.exportQueue=[raceRequestA];raceB.exportQueue=[raceRequestB];raceA.startNextExport();raceB.startNextExport();await wait(raceA);await wait(raceB)
  let raceModels=[raceA,raceB],raceWinners=raceModels.filter{$0.lastExportReceipt?.movie == .published}
  check("Concurrent EditorModel jobs never replace same movie",raceWinners.count==1 && raceModels.filter{$0.exportQueue[0].status=="실패"}.count==1)
  if let winner=raceWinners.first,let url=winner.lastQualityReportURL{check("Concurrent movie winner owns QA job identity",try OutputQuality.readPublished(url).exportJobID==winner.lastExportReceipt?.jobID)}else{check("Concurrent movie winner owns QA job identity",false)}
  let collision=model("SidecarCollision"),c1=request(p,"sidecar-collision"),c2=request(p,"after-collision")
  let oldSRT=Data("previous subtitles".utf8),srt=c1.url.deletingPathExtension().appendingPathExtension("srt");try oldSRT.write(to:srt)
  collision.exportQueue=[c1,c2];collision.startNextExport();await wait(collision)
  check("Sidecar collision preserves existing bytes and movie",try Data(contentsOf:srt)==oldSRT && exists(c1.url))
  check("Failed sidecar not treated as optional QA",collision.lastQualityReport?.issues.contains{$0.code=="sidecarPublicationFailed"}==true && collision.lastExportReceipt?.subtitles == .failed)
  check("Sidecar failure pauses queue",collision.exportQueue[1].status=="대기" && !exists(c2.url))
  let blocked=model("ReportFailure"),r1=request(p,"report-failure"),r2=request(p,"after-report-failure")
  try FileManager.default.createDirectory(at:blocked.reportsDirectory.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("block".utf8).write(to:blocked.reportsDirectory)
  blocked.lastQualityReportURL=oldReport;blocked.exportQueue=[r1,r2];blocked.startNextExport();await wait(blocked)
  check("Report failure preserves completed movie and QA result",exists(r1.url) && blocked.lastExportReceipt?.quality == .completed && blocked.lastExportReceipt?.report == .failed && blocked.lastQualityReport != nil)
  check("Report failure clears old link and pauses queue",blocked.lastQualityReportURL==nil && blocked.exportQueue[1].status=="대기")
  for phase in [ExportPhase.sources,.movie,.movieReady,.moviePublished,.subtitles,.quality,.report] {
   let cm=model("Cancel-"+phase.rawValue),one=request(p,"cancel-"+phase.rawValue),two=request(p,"after-cancel-"+phase.rawValue)
   cm.exportQueue=[one,two];cm.exportPhaseObserver={_,at in if at==phase{cm.cancelExport()}};cm.startNextExport();await wait(cm)
   let shouldPublish=phase == .moviePublished || phase == .subtitles || phase == .quality || phase == .report
   check("Cancellation at \(phase.rawValue) preserves commit boundary",exists(one.url)==shouldPublish && cm.lastExportReceipt?.movie == (shouldPublish ? .published:.cancelled),cm.exportQueue[0].status)
   check("Cancellation at \(phase.rawValue) pauses remaining queue",cm.exportQueue[1].status=="대기" && !exists(two.url) && !cm.isExporting)
   if shouldPublish {check("Post-movie cancellation at \(phase.rawValue) is explicit",cm.exportQueue[0].status.contains("추가 작업 취소") && cm.lastQualityReportURL==nil)}
  }
  let stale=model("StaleProgress");stale.activeExportID=UUID();stale.activeExportPhase = .quality;stale.isExporting=true;stale.exportProgress=0.25;stale.exportQualityStatus="current"
  stale.acceptExportProgress(0.99,jobID:UUID(),phase:.quality);stale.acceptExportProgress(0.99,jobID:stale.activeExportID!,phase:.movie)
  check("Old job and old phase progress rejected",stale.exportProgress==0.25 && stale.exportQualityStatus=="current");stale.isExporting=false;stale.activeExportID=nil
  let changed=model("SourceChanged"),png=root.appendingPathComponent("source.png")
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:640,pixelsHigh:360,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  memset(bitmap.bitmapData!,100,bitmap.bytesPerRow*360);try bitmap.representation(using:.png,properties:[:])!.write(to:png)
  let asset=try await MediaImporter.inspect(url:png);var source=p;source.assets=[asset];source.sequence.tracks[0].clips=[Clip(name:"source",assetID:asset.id,duration:MediaTime(seconds:2))]
  let stable=model("SourceSuccess"),stableRequest=request(source,"source-success");stable.exportQueue=[stableRequest];stable.startNextExport();await wait(stable)
  check("Used source hashes are recorded in receipt and QA",try stable.lastExportReceipt?.sources.count==1 && stable.lastExportReceipt?.sources==OutputQuality.readPublished(stable.lastQualityReportURL!).sourceSnapshot)
  let pngData=try Data(contentsOf:png);try FileManager.default.removeItem(at:png);stable.recheckLastExport();await wait(stable)
  check("Recheck uses captured expectation without source files",stable.lastQualityReportURL != nil && stable.lastQualityReport?.exportJobID==stableRequest.id);try pngData.write(to:png)
  let changeRequest=request(source,"source-changed");changed.exportQueue=[changeRequest];changed.exportPhaseObserver={_,phase in if phase == .movieReady{try? Data("mutation".utf8).appendToFile(png)}}
  changed.startNextExport();await wait(changed)
  check("Changed source prevents movie publication",!exists(changeRequest.url) && changed.exportQueue[0].status=="실패" && changed.error?.contains("변경")==true)
  let loss=model("DestinationAppears"),appeared=request(p,"appeared")
  loss.exportQueue=[appeared];loss.exportPhaseObserver={_,phase in if phase == .movieReady{try? protected.write(to:appeared.url)}};loss.startNextExport();await wait(loss)
  check("Destination appearing during render never overwritten",try Data(contentsOf:appeared.url)==protected && loss.exportQueue[0].status=="실패")
  let vanished=model("ParentDisappears"),parent=root.appendingPathComponent("RemovableParent"),parentMoved=root.appendingPathComponent("DetachedParent")
  try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
  let vanishRequest=QueuedExport(project:p,baseURL:nil,url:parent.appendingPathComponent("movie.mp4"),codec:.h264,bitRate:4_000_000)
  vanished.exportQueue=[vanishRequest];vanished.exportPhaseObserver={_,phase in if phase == .movieReady{try? FileManager.default.moveItem(at:parent,to:parentMoved)}};vanished.startNextExport();await wait(vanished)
  check("Unavailable destination pauses without publishing",vanished.exportQueue[0].status=="실패" && !exists(vanishRequest.url))
  check("Moved private directory is not swept as unknown output",try FileManager.default.contentsOfDirectory(atPath:parentMoved.path).contains{$0.hasSuffix(".partial")})
  let qaFail=model("QAFailure"),qa1=request(p,"qa-failure",false),qa2=request(p,"after-qa-failure",false)
  qaFail.exportQueue=[qa1,qa2];qaFail.exportPhaseObserver={_,phase in if phase == .quality{try? FileManager.default.removeItem(at:qa1.url)}};qaFail.startNextExport();await wait(qaFail)
  check("QA read failure cannot erase completed movie status",qaFail.lastExportReceipt?.movie == .published && qaFail.lastExportReceipt?.quality == .failed && qaFail.lastQualityReportURL==nil)
  check("QA read failure pauses remaining jobs",qaFail.exportQueue[0].status=="완료 · 추가 작업 실패" && qaFail.exportQueue[1].status=="대기")
  let qaError=model("QAErrors"),qe1=request(p,"qa-errors"),qe2=request(p,"after-qa-errors")
  qaError.exportQueue=[qe1,qe2];qaError.exportPhaseObserver={_,phase in if phase == .quality{try? "1\n00:00:00,000 --> 00:00:02,000\nDifferent subtitles\n".write(to:qe1.url.deletingPathExtension().appendingPathExtension("srt"),atomically:false,encoding:.utf8)}};qaError.startNextExport();await wait(qaError)
  check("QA errors retain movie and report pause queue",exists(qe1.url) && qaError.lastQualityReportURL != nil && qaError.exportQueue[0].status=="완료 · 검사 오류" && qaError.exportQueue[1].status=="대기")
  let lowSpace=root.appendingPathComponent("low-space.mp4")
  do{try await ExportJob(minimumFreeSpaceOverride:Int64.max).export(plan:fixturePlan,to:lowSpace){_ in};check("Low space preflight never advertises movie",false)}catch{check("Low space preflight never advertises movie",!exists(lowSpace) && error.localizedDescription.contains("공간"))}
  let journal=model("JournalFailure"),j1=request(p,"journal-failure"),j2=request(p,"after-journal-failure")
  try FileManager.default.createDirectory(at:journal.exportJournalURL.deletingLastPathComponent(),withIntermediateDirectories:true);try FileManager.default.createDirectory(at:journal.exportJournalURL,withIntermediateDirectories:false)
  journal.exportQueue=[j1,j2];journal.startNextExport();await wait(journal)
  check("Journal storage failure pauses queue preserves output",exists(j1.url) && journal.exportQueue[1].status=="대기" && journal.message.contains("기록 저장 실패"))
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"));let failures=rows.filter{($0["passed"] as? Bool) != true}.count;print("EXPORT_DELIVERY_RESULT checks=\(rows.count) failures=\(failures)");if failures>0{exit(1)}
 }
}
private extension Data {
 func appendToFile(_ url:URL)throws{let f=try FileHandle(forWritingTo:url);defer{try? f.close()};try f.seekToEnd();try f.write(contentsOf:self)}
}

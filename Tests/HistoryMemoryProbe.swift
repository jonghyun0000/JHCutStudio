import Foundation
import AppKit
import Darwin
@testable import JHCutCore

@main struct HistoryMemoryProbe {
 static func rss() -> UInt64 {
  var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
  return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
 }
 static func glossary(_ cycle: Int) -> [GlossaryEntry] {
  (0..<400).map { i in GlossaryEntry(source:"term-\(i)", target:"\(cycle)-\(i)-" + String(repeating: Character(UnicodeScalar(65 + cycle % 26)!), count:2048)) }
 }
 static func fixture(_ source: URL) throws -> Project {
  var p=Project(name:"대량 자막 및 안정화")
  let a=MediaAsset(name:"owned fixture",path:source.path,kind:.video,duration:MediaTime(seconds:600),width:1920,height:1080,hasAudio:true)
  p.assets=[a];p.assets[0].bookmark=Data(repeating:0x5a,count:4096)
  var c=Clip(name:"camera",assetID:a.id,start:.zero,duration:MediaTime(seconds:600))
  c.stabilization=StabilizationData(step:0.1,analyzedStart:.zero,frameWidth:1920,frameHeight:1080,x:(0..<6000).map { Float($0%10)/100 },y:[Float](repeating:0,count:6000),angle:[Float](repeating:0.01,count:6000))
  c.keyframes=(0..<1000).map { TransformKeyframe(time:MediaTime(seconds:Double($0)*0.5),transform:ClipTransform(),volume:1) }
  c.ducking=[GainPoint(time:.zero,gain:1),GainPoint(time:MediaTime(seconds:1),gain:0.5)]
  var visual=VisualAdjustments(); visual.lut=CubeLUT(name:"fixture",size:2,values:[Float](repeating:0.5,count:32));c.visual=visual
  p.sequence.tracks[0].clips=[c]
  p.sequence.tracks[2].clips=(0..<200).map { i in
   var caption=Clip(name:"caption \(i)",start:MediaTime(seconds:Double(i)*2),duration:MediaTime(seconds:2),title:Title(text:"한국어 Japanese English \(i)"))
   caption.captionRole = .original
   var metadata=CaptionMetadata(language:"ko",originalLanguage:"ko",originalText:String(repeating:"원문 ",count:100),generatedText:"generated \(i)")
   metadata.languageEvidence=[SourceLanguageObservation(start:Double(i)*2,end:Double(i)*2+2,language:"ko",method:.text,state:.uncertain,reason:String(repeating:"근거",count:100))]
   metadata.speaker="speaker-1";metadata.reviewDigest=String(repeating:"a",count:64)
   metadata.glossaryApplied=["용어 \(i)"];metadata.glossaryFailed=["보류 \(i)"];caption.captionMetadata=metadata
   return caption
  }
  p.sequence.speakers=[SpeakerProfile(id:"speaker-1",name:"화자",colorHex:"FFFFFF")]
  p.sequence.markers=[TimelineMarker(time:.zero,name:"marker")]
  p.glossary=[GlossaryEntry(source:"source",target:String(repeating:"translated",count:100))]
  try ProjectValidator.validate(p);return p
 }
 @MainActor static func main() async throws {
  setbuf(stdout,nil);_ = NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/HistoryMemory")
  let source=root.appendingPathComponent("source.reference");let original=Data("owned source marker".utf8);try original.write(to:source)
  var checks:[[String:Any]]=[];var samples:[[String:Any]]=[]
  func check(_ name:String,_ good:Bool) {checks.append(["name":name,"passed":good]);print("\(good ? "PASS" : "FAIL") \(name)")}
  func sample(_ name:String,_ history:EditorHistory) {
   let m=history.memoryUsage
   samples.append(["phase":name,"rssBytes":rss(),"undoCount":m.undoCount,"redoCount":m.redoCount,"undoLogicalBytes":m.undoLogicalBytes,"redoLogicalBytes":m.redoLogicalBytes,"currentLogicalBytes":m.currentLogicalBytes,"retainedEstimatedBytes":m.retainedEstimatedBytes,"trimmed":m.trimmedSnapshots])
  }
  let initialRSS=rss()
  // Exact state oracle independent of history implementation: count-only policy, mixed branches.
  do {
   var h=EditorHistory(project:Project(),budget:HistoryBudget(estimatedByteLimit:1_024*1_024*1_024));var current=h.project;var past:[Project]=[];var future:[Project]=[]
   var all=true
   for i in 0..<240 {
    let next="edit \(i)";past.append(current);current.name=next;future.removeAll();if past.count>100 {past.removeFirst()};try h.apply(.rename(next))
    if i%3==0 {for _ in 0..<2 {if let previous=past.popLast() {future.append(current);current=previous};h.undo()}}
    if i%5==0 {if let next=future.popLast() {past.append(current);current=next};h.redo()}
    all = all && h.project==current && h.memoryUsage.undoCount==past.count && h.memoryUsage.redoCount==future.count
   }
   check("240 mixed edit/Undo/Redo/branch cycles agree with independent state oracle",all)
   check("combined snapshot count stays within100",h.memoryUsage.undoCount+h.memoryUsage.redoCount<=100)
   let before=h.memoryUsage;try h.apply(.rename(h.project.name));check("no-op preserves both stacks and telemetry",h.memoryUsage==before)
   do {try h.apply(.batch([.rename("invalid partial"),.removeTrack(UUID())]));check("invalid batch rejects",false)}catch {check("invalid batch preserves current and history",h.project==current && h.memoryUsage==before)}
  }
  // Unchanged large buffers are shared; rename must not evict99 usable recent edits.
  do {
   var p=Project();p.glossary=glossary(0);var h=EditorHistory(project:p)
   for i in 0..<120 {try h.apply(.rename("rename \(i)"))}
   check("COW-shared glossary keeps100 rename states",h.memoryUsage.undoCount==100)
   check("shared-buffer estimate is nonzero and below standalone logical sum",h.memoryUsage.retainedEstimatedBytes>0 && h.memoryUsage.retainedEstimatedBytes < h.memoryUsage.undoLogicalBytes/10)
   sample("shared-glossary-rename120",h)
  }
  // Same workload as the frozen before probe, plus another120 edits to detect growth after warm-up.
  do {
   var h=EditorHistory(project:Project());var maxFirst:UInt64=0;var maxSecond:UInt64=0
   var within=true
   for cycle in 0..<240 {
    try h.apply(.replaceGlossary(glossary(cycle)))
    within = within && h.memoryUsage.retainedEstimatedBytes<=h.budget.estimatedByteLimit && h.memoryUsage.undoCount+h.memoryUsage.redoCount<=100
    if cycle%20==19 {sample("glossary-\(cycle+1)",h);if cycle<120 {maxFirst=max(maxFirst,rss())}else{maxSecond=max(maxSecond,rss())}}
   }
   check("240 independently changed glossary states obey combined byte and count budgets",within)
   check("large glossary is charged and old states trimmed",h.memoryUsage.undoLogicalBytes>32*1_024*1_024 && h.memoryUsage.undoCount<100 && h.memoryUsage.trimmedSnapshots>0)
   check("measured RSS plateaus across second120 glossary edits",maxFirst>0 && maxSecond<=maxFirst+32*1_024*1_024)
   let final=h.project;var count=0;while h.canUndo {h.undo();count+=1}
   sample("glossary-all-undo",h)
   check("redo-only retained history obeys same byte budget",h.memoryUsage.undoCount==0 && h.memoryUsage.redoCount>0 && h.memoryUsage.retainedEstimatedBytes<=h.budget.estimatedByteLimit)
   var redo=0;while h.canRedo {h.redo();redo+=1}
   check("all retained Undo/Redo returns exact final glossary",redo==count && h.project==final)
   let bytes=try JSONEncoder().encode(h.project);try bytes.write(to:root.appendingPathComponent("final-project.json"))
   h.clearHistory();sample("glossary-cleared",h)
   let reopened = try JSONDecoder().decode(Project.self,from:Data(contentsOf:root.appendingPathComponent("final-project.json")))
   check("clear releases history references and preserves current and saved document",h.memoryUsage.retainedEstimatedBytes==0 && !h.canUndo && !h.canRedo && h.project==final && reopened==final)
  }
  let f=try fixture(source)
  do {
   var h=EditorHistory(project:f,budget:HistoryBudget(estimatedByteLimit:4*1_024*1_024));let originalEstimate=h.memoryUsage.currentLogicalBytes
   var stripped=f;stripped.sequence.tracks[0].clips[0].stabilization=nil
   check("stabilization arrays contribute at least their raw bytes",originalEstimate-HistoryMemoryCounter.standalone(stripped)>=6000*3*4)
   stripped=f;stripped.sequence.tracks[2].clips.indices.forEach {stripped.sequence.tracks[2].clips[$0].captionMetadata=nil}
   check("language/review/speaker/translation/glossary metadata charged",originalEstimate>HistoryMemoryCounter.standalone(stripped)+100_000)
   var all=true;var settledFirst:UInt64=0;var settledSecond:UInt64=0
   for cycle in 0..<160 {
    var seq=h.project.sequence;seq.tracks[0].clips[0].stabilization?.x[cycle%6000]=Float(cycle)/100
    for i in seq.tracks[2].clips.indices {seq.tracks[2].clips[i].captionMetadata?.generatedText="\(cycle)-\(i)-"+String(repeating:"caption",count:100)}
    try h.apply(.replaceSequence(seq));let wanted=h.project
    h.undo();h.redo();all = all && h.project==wanted
    if cycle%4==0 {h.undo();try h.apply(.rename("branch \(cycle)"));all = all && !h.canRedo}
    all = all && h.memoryUsage.retainedEstimatedBytes<=4*1_024*1_024 && h.project.assets==f.assets
    if cycle%20==19 {sample("caption-stabilization-\(cycle+1)",h);if cycle<80 {settledFirst=max(settledFirst,rss())}else{settledSecond=max(settledSecond,rss())}}
   }
   check("160 large caption/stabilization edit/Undo/Redo/branch cycles preserve expected state",all)
   check("large mixed-payload history trims instead of growing indefinitely",h.memoryUsage.trimmedSnapshots>0 && h.memoryUsage.undoCount<100)
   check("measured mixed-payload RSS remains bounded after warm-up",settledFirst>0 && settledSecond<=settledFirst+32*1_024*1_024)
   sample("caption-stabilization-before-clear",h);let final=h.project;h.clearHistory();sample("caption-stabilization-cleared",h)
   check("current generated/source references survive history release",h.project==final && h.project.assets[0].path==source.path && h.memoryUsage.retainedEstimatedBytes==0)
  }
  do {
   var p=Project();p.glossary=glossary(1)
   var h=EditorHistory(project:p,budget:HistoryBudget(estimatedByteLimit:1024));try h.apply(.replaceGlossary([]))
   check("single oversized old state can be dropped without current loss",!h.canUndo && h.project.glossary==nil && h.memoryUsage.trimmedSnapshots==1)
   var reverse=EditorHistory(project:Project(),budget:HistoryBudget(estimatedByteLimit:2048));let empty=reverse.project
   try reverse.apply(.replaceGlossary(glossary(2)));let populated=reverse.project
   check("oversized current remains editable with small predecessor retained",reverse.canUndo && populated.glossary?.count==400)
   reverse.undo()
   check("Undo drops oversized redo instead of losing restored current",reverse.project==empty && !reverse.canRedo && reverse.memoryUsage.retainedEstimatedBytes<=2048)
   var disabled=EditorHistory(project:f,budget:HistoryBudget(snapshotLimit:0));try disabled.apply(.rename("kept current"))
   check("zero history budget preserves live edit",!disabled.canUndo && disabled.project.name=="kept current" && disabled.project.assets==f.assets)
  }
  // Actual EditorModel ticket snapshot is additional live storage outside history's budget.
  do {
   let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("export-history.json"),proxyCache:ProxyCache(directory:root.appendingPathComponent("ProxyCache")));var p=Project();p.glossary=glossary(77);model.history=EditorHistory(project:p)
   var ticket:EditorAsyncTicket?=model.beginAsyncJob(.productivity)
   try model.history.apply(.replaceGlossary([]));model.history.clearHistory()
   check("active app job snapshot remains valid independently of history clear",ticket!.context.project.glossary?.count==400 && model.history.memoryUsage.retainedEstimatedBytes==0 && model.project.glossary==nil)
   sample("active-job-snapshot-outside-history",model.history)
   check("job snapshot estimate is recorded separately from history",HistoryMemoryCounter.standalone(ticket!.context.project)>800_000)
   model.finishAsyncJob(ticket!);ticket=nil
   check("actual app job slot releases ownership after completion",model.productivityJobID==nil && !model.productivityBusy && ticket==nil)
   sample("job-snapshot-released",model.history)
  }
  check("owned source file remains byte-identical",try Data(contentsOf:source)==original)
  var usage=rusage();getrusage(RUSAGE_SELF,&usage)
  let report:[String:Any]=["schemaVersion":1,"initialRSSBytes":initialRSS,"finalRSSBytes":rss(),"peakRSSBytes":usage.ru_maxrss,"cycles":["stateOracle":240,"glossary":240,"captionStabilization":160],"samples":samples,"defaultByteBudget":64*1_024*1_024,"defaultSnapshotLimit":100,"limitations":["RSS includes AppKit, runtime, allocator retained pages and temporary fixtures; not an app render benchmark","buffer estimates do not expose allocator capacity; String/Data costs are conservative","active job check uses actual EditorModel ticket, not a completed media operation or GUI session"],"checks":checks]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("memory-report.json"))
  try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))
  let failures=checks.filter {($0["passed"] as? Bool) != true}.count
  print("HISTORY_MEMORY_RESULT checks=\(checks.count) failures=\(failures)");exit(failures==0 ? 0:1)
 }
}

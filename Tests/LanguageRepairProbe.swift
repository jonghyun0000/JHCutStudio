import Foundation
import AppKit
import AVFoundation
import CryptoKit
@testable import JHCutCore

/// Scripted speech is a synthetic reference, not human verification of private footage.
@main struct LanguageRepairProbe {
 static func cue(_ a:Double,_ b:Double,_ text:String)->CaptionCue {CaptionCue(start:MediaTime(seconds:a),duration:MediaTime(seconds:b-a),text:text)}
 @MainActor static func main() async throws {
  setbuf(stdout,nil); _=NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/LanguageRepair")
  var rows:[[String:Any]]=[]
  func check(_ name:String,_ ok:Bool,_ detail:String="") {rows.append(["name":name,"passed":ok,"detail":detail]);print("\(ok ? "PASS":"FAIL") \(name) \(detail)")}
  defer {try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))}
  let strong=SourceLanguageObservation(start:100,end:110,language:"ja",candidate:"ja",confidence:0.95,method:.audioProbe,state:.supported,reason:"acousticPosterior",measuredSpeechSeconds:3)
  check("Acoustic log exposes real posterior",SourceLanguageAnalysis.acousticResult(log:"auto-detected language: ja (p = 0.950000)")?.probability == 0.95)
  for invalid in ["language: ja","auto-detected language: ja (p = nan)","auto-detected language: ja (p = 1.2)","auto-detected language: auto (p = .9)"] {check("Malformed/missing posterior remains unavailable",SourceLanguageAnalysis.acousticResult(log:invalid) == nil,invalid)}
  check("Acoustic observation validates source clock",strong.isValid)
  check("NaturalLanguage roundoff stays within probability contract",SentenceLanguage.detect("Hello everyone, today we are filming a",clipLanguage:"en").confidence <= 1)
  var bad=strong;bad.sourceEnd=Double.nan;check("Nonfinite source evidence refused",!bad.isValid)
  bad=strong;bad.confidence=1.1;check("Out of range posterior refused",!bad.isValid)
  bad=strong;bad.reason=String(repeating:"x",count:1025);check("Oversized reason refused",!bad.isValid)
  for (lang,p,speech,expected) in [("ja",0.95,3.0,true),("ja",0.79,3.0,false),("zh",0.99,3.0,false),("ko",0.99,0.0,false)] {
   let o=LanguageRepair.observation(range:100...110,result:(lang,p),speechSeconds:speech)
   check("Speech, supported language and posterior gate",(o.state == .supported) == expected,"\(lang) \(p) speech=\(speech)")
  }
  let decision=SourceLanguageAnalysis.decision(text:"こんにちは。今日は撮影します。",start:101,end:108,clipLanguage:"ko",observations:[strong])
  check("Agreement labels acoustic origin",decision.language == "ja" && decision.origin == .audioProbe && !decision.needsReview)
  let short=SourceLanguageAnalysis.decision(text:"はい",start:101,end:102,clipLanguage:"ko",observations:[strong])
  check("Short response is not forced from surrounding language",short.needsReview && short.origin == .recognizerWindow)
  let conflict=SourceLanguageAnalysis.decision(text:"오늘은 촬영하고 있습니다",start:101,end:108,clipLanguage:"ko",observations:[strong])
  check("Acoustic/text conflict asks for review",conflict.needsReview && conflict.language == "ko")
  let manual=SourceLanguageAnalysis.decision(text:"오늘은 촬영하고 있습니다",start:101,end:108,clipLanguage:"ko",requestedLanguage:"en",observations:[strong])
  check("Explicit user language overrides audio and text",manual.language == "en" && manual.origin == .manual && manual.confidence == nil && !manual.needsReview)
  check("Evidence stores audio and text separately",decision.evidence.contains {$0.method == .audioProbe} && decision.evidence.contains {$0.method == .text})
  let old=[cue(100,104,"첫 번째 문장입니다"),cue(104,108,"두 번째 문장입니다"),cue(110,112,"옆 문장입니다")]
  let good=[cue(100,104,"こんにちは皆さん。"),cue(104,108,"今日は公園で撮影しています。")]
  let accepted=LanguageRepair.merge(original:old,replacement:good,range:100...108,language:"ja")
  check("Successful retry replaces whole owned cues",accepted.outcome == "accepted" && accepted.cues == good+[old[2]])
  for (replacement,range,outcome) in [([CaptionCue](),100.0...108.0,"empty"),([cue(99,105,"こんにちは皆さん。")],100.0...108.0,"boundaryHeld"),(good,101.0...108.0,"boundaryHeld"),([good[0]],100.0...108.0,"coverageHeld"),([cue(100,108,"오늘은 촬영하고 있습니다")],100.0...108.0,"languageHeld")] {
   let merged=LanguageRepair.merge(original:old,replacement:replacement,range:range,language:"ja")
   check("Rejected retry preserves IDs, text and timing",merged.cues == old && merged.outcome == outcome,outcome)
  }
  check("Boundary cue is held while adjacent empty gap is retried",LanguageRepair.coreRange(cues:[cue(14,17,"Hello everyone.")],probe:16...26) == 17...26)
  let gapFilled=LanguageRepair.merge(original:old,replacement:[cue(113,120,"今日は公園で撮影しています。")],range:113...120,language:"ja")
  check("Missing speech can be added without erasing successful cues",gapFilled.outcome == "accepted" && gapFilled.cues.prefix(old.count).elementsEqual(old))
  for count in [1,3,4,12,25,100] {
   let quotas=(0..<count).map { LanguageRepair.probeAllowance(window:$0,count:count) }
   check("Whole-request probe allocation stays bounded \(count)",quotas.reduce(0,+) == 24 && quotas.first! > 0 && quotas.last! > 0)
  }
  check("Three windows each retain eight probes",(0..<3).map { LanguageRepair.probeAllowance(window:$0,count:3) } == [8,8,8])
  let distributed=LanguageRepair.sampledRanges(LanguageRepair.ranges(cues:[],start:300,end:600),priority:[],limit:8)
  check("Window sampling includes start and end, not only its first minute",distributed.count==8 && distributed.first!.lowerBound==300 && distributed.last!.upperBound>=594)
  let conflictRanges=LanguageRepair.ranges(cues:[],start:0,end:300)
  let prioritized=LanguageRepair.sampledRanges(conflictRanges,priority:[3,4,5],limit:8)
  check("Conflict priority retains whole-window coverage",prioritized.count<=8 && prioritized.contains(conflictRanges[3]) && prioritized.last!.upperBound>=294)
  let budget=LanguageRepairBudget()
  for _ in 0..<24 {check("Probe budget reserves bounded original audio",budget.reserveProbe(10))}
  check("25th probe is refused",!budget.reserveProbe(10) && budget.used.probeAudioSeconds == 240)
  for _ in 0..<8 {_=budget.reserveRetry(15)}
  check("9th retry or over 120 seconds is refused",!budget.reserveRetry(6) && budget.used.retryAudioSeconds == 120)
  let resumed=LanguageRepairBudget();resumed.charge(budget.used)
  check("Resume charges saved work before new probes",!resumed.reserveProbe(10) && !resumed.reserveRetry(10))
  let timed=LanguageRepairBudget();timed.elapsed(60)
  check("Wall budget prevents more work",!timed.reserveProbe(10) && !timed.reserveRetry(10))
  check("Nonfinite and overlong retry not reserved",!LanguageRepairBudget().reserveRetry(Double.infinity) && !LanguageRepairBudget().reserveRetry(21))
  check("Short audio has no forced sampling",LanguageRepair.ranges(cues:[cue(0,2,"네")],start:0,end:3).isEmpty)

  var options=SpeechOptions()
  let key=TranscriptionCheckpointKey(projectID:UUID(),clipID:UUID(),mediaSHA256:String(repeating:"a",count:64),sourceStart:.zero,duration:MediaTime(seconds:30),windowSeconds:30,options:options,modelSHA256:String(repeating:"b",count:64))
  var previousPipeline=key;previousPipeline.engine=LocalTranscription.engineVersion + " · pipeline 7"
  check("Previous sampling results cannot be reused under the new pipeline",key.identifier != previousPipeline.identifier && key.isReusable && !previousPipeline.isReusable)
  options.languageRepairEnabled=false
  let disabled=TranscriptionCheckpointKey(projectID:key.projectID,clipID:key.clipID,mediaSHA256:key.mediaSHA256,sourceStart:key.sourceStart,duration:key.duration,windowSeconds:30,options:options,modelSHA256:key.modelSHA256)
  check("Toggle is part of checkpoint identity",disabled.identifier != key.identifier)
  var legacy=key;legacy.format=2;legacy.languageRepairEnabled=nil
  check("Legacy key decodes but is not reused",try JSONDecoder().decode(TranscriptionCheckpointKey.self,from:JSONEncoder().encode(legacy)).isValid && !legacy.isReusable)
  var metadata=CaptionMetadata(language:"ja",originalLanguage:"ja",originalText:"こんにちは",generatedText:"こんにちは")
  metadata.languageOrigin=decision.origin;metadata.languageEvidence=decision.evidence.map {e in var copy=e;copy.sourceStart -= 100;copy.sourceEnd -= 100;return copy}
  var original=Clip(name:"原文",duration:MediaTime(seconds:8)); original.title=Title(text:metadata.generatedText);original.captionMetadata=metadata
  var project=Project(name:"Evidence reload");let ti=project.sequence.tracks.firstIndex {$0.kind == .title}!
  project.sequence.tracks[ti].clips=[original]
  let document=root.appendingPathComponent("evidence.jhcut");try ProjectStore.save(project,to:document)
  let loaded=try ProjectStore.load(from:document)
  check("Source evidence survives strict project reload",loaded.sequence.tracks[ti].clips[0].captionMetadata == metadata)
  let migratedDocument=root.appendingPathComponent("migrated-evidence.jhcut")
  var previousProject=project;previousProject.sequence.tracks[ti].clips[0].captionMetadata?.languageEvidence=nil;previousProject.sequence.tracks[ti].clips[0].captionMetadata?.languageOrigin=nil;previousProject.sequence.tracks[ti].clips[0].captionMetadata?.clipLanguage="ja"
  try ProjectStore.save(previousProject,to:migratedDocument);let previousBytes=try Data(contentsOf:migratedDocument)
  try ProjectStore.save(project,to:migratedDocument);try ProjectStore.save(project,to:migratedDocument)
  check("First evidence save preserves old 0.7 document permanently",try Data(contentsOf:ProjectStore.beforeLanguageEvidenceURL(for:migratedDocument)) == previousBytes)
  var invalidProject=project;invalidProject.sequence.tracks[ti].clips[0].captionMetadata?.languageEvidence=Array(repeating:strong,count:9)
  var rejected=false;do {try ProjectValidator.validate(invalidProject)}catch {rejected=true}
  check("Project refuses excessive language evidence",rejected)
  let translated=try CaptionTranslationEditing.translated(original,text:"안녕하세요",sourceLanguage:"ja",targetLanguage:"ko",bilingual:false)
  project.sequence.tracks[ti].clips.append(translated)
  check("Original with translated lineage is preserved",CaptionLanguagePreservation.shouldKeep(original,trackLocked:false,in:project.sequence))
  var lone=project.sequence;lone.tracks[ti].clips=[original];var connected=original;connected.connection=ClipConnection(parentID:UUID(),sourceStart:.zero,sourceDuration:original.duration,generatedText:original.title!.text)
  check("Unedited original without translation can be regenerated",!CaptionLanguagePreservation.shouldKeep(connected,trackLocked:false,in:lone))
  check("Locked original is preserved",CaptionLanguagePreservation.shouldKeep(connected,trackLocked:true,in:lone))
  connected.captionMetadata?.languageManual=true;check("Manual language preserved",CaptionLanguagePreservation.shouldKeep(connected,trackLocked:false,in:lone))
  connected.captionMetadata?.languageManual=nil;connected.title?.text="수정한 문구";check("Manual text preserved",CaptionLanguagePreservation.shouldKeep(connected,trackLocked:false,in:lone))
  let editor=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"))
  editor.history=EditorHistory(project:loaded)
  editor.setCaptionLanguage([original.id],to:"en");check("Manual command records origin",editor.captionClips.first?.captionMetadata?.languageOrigin == .manual)
  editor.resetCaptionLanguage([original.id]);check("Reset restores automatic evidence",editor.captionClips.first?.captionMetadata?.languageManual != true && editor.captionClips.first?.captionMetadata?.languageEvidence?.contains {$0.method == .audioProbe} == true)
  editor.undo();check("Undo restores manual choice",editor.captionClips.first?.captionMetadata?.languageOrigin == .manual)

  // Fixed subprocesses exercise log-draining, deadline and cancellation, not model accuracy.
  let runtime=root.appendingPathComponent("fake.py")
  let fake="""
#!/usr/bin/env python3
import sys,time,json
args=sys.argv[1:]
if '--sleep' in args: time.sleep(20)
if '-dl' in args:
 print('whisper_full_with_state: auto-detected language: ja (p = 0.990000)',file=sys.stderr);sys.exit(0)
def arg(k,default=''): return args[args.index(k)+1] if k in args else default
prefix=arg('-of');lang=arg('-l');mode=arg('--prompt')
if lang=='ja' and mode=='fail':sys.exit(3)
text='こんにちは皆さん。今日は公園で撮影しています。' if lang=='ja' else '오늘은 공원에서 영상을 촬영하고 있습니다'
srt='' if lang=='ja' and mode=='empty' else '1\\n00:00:00,000 --> 00:00:08,000\\n'+text+'\\n'
open(prefix+'.srt','w').write(srt)
json.dump({'result':{'language':'ko' if lang=='auto' else lang},'transcription':[] if not srt else [{'text':text,'offsets':{'from':0,'to':8000}}]},open(prefix+'.json','w'),ensure_ascii=False)
"""
  try Data(fake.utf8).write(to:runtime);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:runtime.path)
  for _ in 0..<5 {let log=try await LocalTranscription.run(executable:runtime,arguments:["-dl"],directory:root,progress:nil);check("Fast process acoustic log drains completely",SourceLanguageAnalysis.acousticResult(log:log)?.language == "ja")}
  let began=Date();var expired=false;do {_=try await LocalTranscription.run(executable:runtime,arguments:["--sleep"],directory:root,timeout:0.15,progress:nil)}catch {expired=true}
  check("Supplemental subprocess timeout terminates",expired && Date().timeIntervalSince(began)<3)
  let task=Task {try await LocalTranscription.run(executable:runtime,arguments:["--sleep"],directory:root,progress:nil)}
  try await Task.sleep(nanoseconds:100_000_000);task.cancel();var cancelled=false;do {_=try await task.value}catch is CancellationError {cancelled=true}
  check("Cancellation propagates instead of applying partial cues",cancelled)

  // Real, scripted three-language speech and single-language controls. No network or model install.
  let lines=[("ko","Yuna","안녕하세요 여러분. 오늘은 공원에서 영상을 촬영하고 있습니다. 다음에는 카페에서 차를 마시겠습니다."),
             ("en","Samantha","Hello everyone. Today we are filming in the park. We will visit a cafe and have a cup of coffee after the recording."),
             ("ja","Kyoko","こんにちは皆さん。今日は公園で映像を撮影しています。この後はカフェでお茶を飲みます。よろしくお願いします。")]
  var audio:[URL]=[],units:[TranscriptReference.Unit]=[];var fixture=Project(name:"Synthetic mixed language");fixture.sequence.width=640;fixture.sequence.height=360
  let ai=fixture.sequence.tracks.firstIndex {$0.kind == .audio}!;var at=MediaTime(seconds:0.3)
  for (i,line) in lines.enumerated() {
   let url=root.appendingPathComponent("tts-\(line.0).aiff");let say=Process();say.executableURL=URL(fileURLWithPath:"/usr/bin/say");say.arguments=["-v",line.1,"-r","160","-o",url.path,line.2];try say.run();say.waitUntilExit();check("Installed voice produced fixture",say.terminationStatus == 0,line.1)
   let asset=try await MediaImporter.inspect(url:url);audio.append(url);fixture.assets.append(asset);fixture.sequence.tracks[ai].clips.append(Clip(assetID:asset.id,start:at,duration:asset.duration))
   units.append(.init(text:line.2,start:at.seconds,end:(at+asset.duration).seconds));at=at+asset.duration+MediaTime(seconds:1)
   check("Synthetic known-language segment exceeds short threshold",asset.duration.seconds>6,"\(line.0) \(asset.duration.seconds)")
   _=i
  }
  let mixed=root.appendingPathComponent("mixed.mp4");try await ExportJob().export(plan:TimelineRenderer.build(project:fixture),to:mixed) {_ in}
  let media=try await MediaImporter.inspect(url:mixed)
  var metrics:[[String:Any]]=[]
  for (label,url) in [("mixed",mixed)]+zip(lines.map {$0.0},audio).map {($0.0,$0.1)} {
   let asset=try await MediaImporter.inspect(url:url)
   for enabled in [false,true] {
    var opts=SpeechOptions();opts.languageRepairEnabled=enabled
    let result=try await LocalTranscription.transcribeLong(url:url,duration:asset.duration,options:opts)
    let name=label+"-"+(enabled ? "repair":"baseline")
    try JSONEncoder().encode(result).write(to:root.appendingPathComponent(name+".json"))
    check("Actual transcript retains valid absolute source time",result.cues.allSatisfy {$0.start >= .zero && $0.duration > .zero && $0.start+$0.duration <= asset.duration},name)
    check("Actual request obeys count and audio budgets",result.languageRepairCost?.isValid == true,name)
    if enabled {check("Actual runtime yields acoustic observations",result.languageObservations?.contains {$0.method == .audioProbe && $0.candidateLanguage != nil} == true,name)}
    var measured:[[String:Any]]=[]
    for (i,line) in lines.enumerated() where label == "mixed" || label == line.0 {
     let a=label == "mixed" ? units[i].start!:0,b=label == "mixed" ? units[i].end!:asset.duration.seconds
     let captions=result.cues.filter {let midpoint=$0.start.seconds+$0.duration.seconds/2;return midpoint>=a && midpoint<b}.map {EvaluatedCaption(text:$0.text,start:$0.start.seconds,end:$0.start.seconds+$0.duration.seconds)}
     let reference=TranscriptReference(url:root.appendingPathComponent("synthetic-script.txt"),units:[.init(text:line.2,start:a,end:b)])
     let report=try TranscriptEvaluation.evaluate(captions:captions,reference:reference,language:line.0,sourceRange:0...asset.duration.seconds,mediaDuration:asset.duration.seconds)
     check("Synthetic language comparison is scored",report.status == .scored,name+"-"+line.0)
     try JSONEncoder().encode(report).write(to:root.appendingPathComponent(name+"-"+line.0+"-evaluation.json"))
     let observations=(result.languageObservations ?? []).filter {$0.method == .audioProbe && $0.sourceStart>=a && $0.sourceEnd<=b}
     measured.append(["knownLanguage":line.0,"cer":report.cer as Any? ?? NSNull(),"wer":report.wer as Any? ?? NSNull(),"withinSegmentAudioCandidates":observations.map {$0.candidateLanguage ?? "unavailable"},"withinSegmentSupportedCorrect":observations.filter {$0.language == line.0 && $0.state == .supported}.count,"withinSegmentSupportedWrong":observations.filter {$0.language != nil && $0.language != line.0}.count,"sampleCount":observations.count])
    }
    metrics.append(["fixture":label,"enabled":enabled,"elapsedSeconds":result.elapsedSeconds,"measurements":measured,"referenceKind":"syntheticScriptNotHuman","captionAllocation":"sourceMidpointUnique; full source bounds preserve timing", "model":WhisperModelSpec.base.sha256])
   }
  }
  try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("synthetic-metrics.json"))
  try JSONSerialization.data(withJSONObject:["kind":"syntheticScriptNotHuman","lines":lines.map { ["language":$0.0,"voice":$0.1,"text":$0.2] },"sourceIntervals":units.map {["start":$0.start!,"end":$0.end!,"text":$0.text]}],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("synthetic-script.json"))
  let source=root.appendingPathComponent("copy-source.wav"),copy=root.appendingPathComponent("copy.wav")
  _=try await LocalTranscription.extractAudio(url:mixed,sourceStart:.zero,duration:MediaTime(seconds:10),destination:source)
  try LocalTranscription.writeCompacted(from:source,to:copy,timeline:CompactedTimeline(regions:[0...10],recordingDuration:10))
  let f=try AVAudioFile(forReading:copy)
  check("Continuous PCM copy retains every requested sample",f.length == 160_000)
  func pcm(_ url:URL)throws ->[Int16] {let f=try AVAudioFile(forReading:url,commonFormat:.pcmFormatInt16,interleaved:false);let buffer=AVAudioPCMBuffer(pcmFormat:f.processingFormat,frameCapacity:16_384)!;var data:[Int16]=[];while f.framePosition<f.length {try f.read(into:buffer);if buffer.frameLength == 0 {break};data += Array(UnsafeBufferPointer(start:buffer.int16ChannelData![0],count:Int(buffer.frameLength)))};return data}
  check("PCM sample values preserved without gaps",try pcm(source) == pcm(copy))
  // Integration failure recovery uses actual extracted audio plus deliberately fixed model output.
  let dummy=root.appendingPathComponent("fake.bin");try Data("test model".utf8).write(to:dummy)
  let digest=SHA256.hash(data:try Data(contentsOf:dummy)).map {String(format:"%02x",$0)}.joined()
  let spec=WhisperModelSpec(name:"Test fixed output",fileName:"fake.bin",downloadURL:URL(string:"https://example.invalid")!,byteCount:10,sha256:digest,license:"test",licenseURL:URL(string:"https://example.invalid")!,recommendedFreeBytes:0)
  let config=WhisperConfiguration(runtimeURL:runtime,modelURL:dummy,modelSpec:spec)
  let duration=MediaTime(seconds:8.5),evidence=[0.0...8.5]
  for mode in ["accepted","empty","fail"] {
   var opts=SpeechOptions();opts.glossary=mode
   let result=try await LocalTranscription.transcribe(url:audio[2],sourceStart:.zero,duration:duration,configuration:config,options:opts,verifyModel:true,speechEvidence:evidence,progress:nil)
   let expected=mode == "fail" ? "failed":mode
   check("Real pipeline handles retry outcome without losing cue",result.cues.count == 1 && result.languageRepairAttempts?.first?.outcome == expected,mode)
   check("Failed or empty retry keeps original output",mode == "accepted" ? result.cues.first!.text.contains("こんにちは"):result.cues.first!.text.contains("오늘은"),mode)
   check("Language repair metadata round trips",try JSONDecoder().decode(LocalTranscript.self,from:JSONEncoder().encode(result)).languageObservations == result.languageObservations,mode)
  }
  let cacheKey=TranscriptionCheckpointKey(projectID:UUID(),clipID:UUID(),mediaSHA256:try await FileIdentity.sha256(audio[2]),sourceStart:.zero,duration:duration,windowSeconds:30,options:SpeechOptions(),modelSHA256:spec.sha256)
  let store=TranscriptionCheckpointStore(root:root.appendingPathComponent("LanguageCheckpoints")),session=TranscriptionCheckpointSession(store:store,key:cacheKey)
  let computed=try await LocalTranscription.transcribeLong(url:audio[2],duration:duration,configuration:config,options:SpeechOptions(),windowSeconds:30,checkpoint:session,speechEvidence:evidence)
  let reloaded=try await LocalTranscription.transcribeLong(url:audio[2],duration:duration,configuration:config,options:SpeechOptions(),windowSeconds:30,checkpoint:session,speechEvidence:evidence)
  check("Checkpoint keeps exact language source intervals and cues",computed.languageObservations == reloaded.languageObservations && computed.cues == reloaded.cues && reloaded.reusedWindows == 1)
  check("Checkpoint resume charges exact recorded language cost",computed.languageRepairCost == reloaded.languageRepairCost && reloaded.computedWindows == 0)
  var corrupt=store.completedWindows(for:cacheKey)[0]!
  corrupt.languageObservations=Array(repeating:strong,count:129)
  var cacheRejected=false;do {try store.save(corrupt,for:cacheKey)}catch {cacheRejected=true}
  check("Checkpoint refuses invalid/oversized acoustic evidence",cacheRejected)
  let quiet=root.appendingPathComponent("quiet.wav"),format=AVAudioFormat(standardFormatWithSampleRate:16_000,channels:1)!
  do {let output=try AVAudioFile(forWriting:quiet,settings:format.settings);let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:160_000)!;buffer.frameLength=160_000;memset(buffer.floatChannelData![0],0,160_000*MemoryLayout<Float>.size);try output.write(from:buffer)}
  let quietResult=try await LocalTranscription.transcribe(url:quiet,sourceStart:.zero,duration:MediaTime(seconds:10),configuration:config,options:SpeechOptions(),verifyModel:true,progress:nil)
  check("High language posterior over silence does not force retry",quietResult.languageRepairCost?.retries == 0 && quietResult.languageObservations?.filter {$0.method == .audioProbe}.allSatisfy {$0.state == .uncertain} == true)
  var forced=SpeechOptions();forced.language="ko"
  let forcedResult=try await LocalTranscription.transcribe(url:audio[2],sourceStart:.zero,duration:duration,configuration:config,options:forced,verifyModel:true,speechEvidence:evidence,progress:nil)
  check("Forced language skips all probes and retries",forcedResult.languageRepairCost?.probes == 0 && forcedResult.languageRepairCost?.retries == 0 && forcedResult.languageObservations?.contains {$0.method == .manual} == true)
  // Exercise actual editor replacement, including 2x playback and a locked subtitle track.
  let editable=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("EditorRecovery")),exportHistoryURL:root.appendingPathComponent("editor-journal.json"))
  editable.translateAfterTranscription=false;editable.useSpeechCheckpoints=false
  let speechAsset=try await MediaImporter.inspect(url:audio[2])
  var editorProject=Project(name:"Replacement preservation");editorProject.assets=[speechAsset]
  var parent=Clip(name:"Japanese at double speed",assetID:speechAsset.id,duration:try speechAsset.duration.scaled(numerator:1,denominator:2));parent.playbackRate=PlaybackRate(numerator:2,denominator:1)
  editorProject.sequence.tracks[ai].clips=[parent]
  var originals=CaptionEditing.automaticClips(cues:[cue(0,2,"こんにちは皆さん"),cue(2,4,"今日は公園で撮影します"),cue(4,6,"カフェでお茶を飲みます"),cue(6,8,"よろしくお願いします")],source:parent,style:Title(text:""))
  for i in originals.indices {let text=originals[i].title!.text;originals[i].captionMetadata=CaptionMetadata(language:"ja",originalLanguage:"ja",originalText:text,generatedText:text)}
  originals[0].title?.text="직접 수정한 문장";originals[1].captionMetadata?.language="en";originals[1].captionMetadata?.languageManual=true;originals[1].captionMetadata?.languageOrigin = .manual
  let linked=try CaptionTranslationEditing.translated(originals[2],text:"카페에서 차를 마십니다",sourceLanguage:"ja",targetLanguage:"ko",bilingual:false)
  editorProject.sequence.tracks[ti].clips=Array(originals.prefix(3))+[linked]
  editorProject.sequence.tracks.append(Track(name:"Locked captions",kind:.title,clips:[originals[3]],isLocked:true))
  editable.history=EditorHistory(project:editorProject);editable.selectedClipID=parent.id;editable.selectedClipIDs=[parent.id];editable.refreshTranscriptionStatus()
  editable.transcribeSelection();while editable.productivityBusy {try await Task.sleep(nanoseconds:50_000_000)}
  check("Editor mixed-language rerun succeeds",editable.error == nil,editable.error ?? editable.message)
  let updated=editable.project.sequence.tracks.flatMap(\.clips)
  for (i,old) in originals.enumerated() {check("Rerun preserves protected original exactly",updated.first {$0.id == old.id} == old,"case=\(i)")}
  check("Rerun keeps translation ID, metadata and source linkage",updated.first {$0.id == linked.id}?.captionMetadata == linked.captionMetadata)
  check("No new cue overlaps preserved original",updated.filter {CaptionQuery.role(of:$0) == .original && $0.connection?.parentID == parent.id}.count == originals.count)
  check("Rerun retains source-to-2x timeline mapping",originals.allSatisfy {$0.connection?.sourceStart.seconds == $0.start.seconds*2 && $0.connection?.sourceDuration.seconds == $0.duration.seconds*2})
  let beforeCancel=editable.project;editable.selectedClipID=parent.id;editable.selectedClipIDs=[parent.id];editable.transcribeSelection();editable.cancelProductivity()
  while editable.productivityBusy {try await Task.sleep(nanoseconds:50_000_000)}
  check("Editor cancellation applies no partial language repair",editable.project == beforeCancel)
  editable.transcribeSelection();while editable.productivityBusy {try await Task.sleep(nanoseconds:50_000_000)}
  try await Task.sleep(nanoseconds:300_000_000)
  check("Restart ignores stale progress and preserves captions",editable.error == nil && editable.transcriptionProgress == 1 && editable.project.sequence.tracks.flatMap(\.clips).filter {CaptionQuery.role(of:$0) == .original}.map(\.id).sorted {$0.uuidString<$1.uuidString} == originals.map(\.id).sorted {$0.uuidString<$1.uuidString})
  print("LANGUAGE_REPAIR_PROBE checks=\(rows.count) failed=\(rows.filter {$0["passed"] as? Bool == false}.count)")
  if rows.contains(where: {$0["passed"] as? Bool == false}) {exit(1)}
  _=media
 }
}

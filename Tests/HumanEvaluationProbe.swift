import Foundation
import AppKit
@testable import JHCutCore

/// Metadata-only source fixture: exercises real hashing, reference/report I/O and editor jobs.
/// The declared reviewer and dialogue below are synthetic and never install corpus truth.
@main struct HumanEvaluationProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil);_=NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"HumanEvaluation")
  var rows:[[String:Any]]=[]
  func check(_ name:String,_ pass:Bool) {rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") \(name)")}
  defer {try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))}
  let media=root.appendingPathComponent("synthetic.mov");try Data("synthetic metadata-only source — no private speech".utf8).write(to:media)
  let hash=try await FileIdentity.sha256(media)
  var asset=MediaAsset(name:"synthetic",path:media.path,kind:.video,duration:MediaTime(30,1),hasAudio:true)
  asset.contentHash=String(repeating:"b",count:64) // Deliberately stale: actual file hash must win.
  var source=Clip(name:"trimmed fast source",assetID:asset.id,start:MediaTime(7,1),sourceStart:MediaTime(10,1),duration:MediaTime(5,1));source.playbackRate=PlaybackRate(numerator:2)
  var caption=Clip(name:"original",start:MediaTime(seconds:7.05),duration:MediaTime(seconds:4.9),title:Title(text:"hello world"))
  caption.captionRole = .original;caption.captionGroupID=source.id;caption.captionHidden=true
  caption.connection=ClipConnection(parentID:source.id,sourceStart:MediaTime(seconds:10.1),sourceDuration:MediaTime(seconds:9.8))
  caption.captionMetadata=CaptionMetadata(language:"en",originalLanguage:"en",originalText:"hello world",generatedText:"hello world")
  var decoration=caption;decoration.id=UUID();decoration.captionRole = .title;decoration.captionGroupID=nil;decoration.captionHidden=nil;decoration.captionMetadata?.language="ko";decoration.title?.text="INTRO DECORATION"
  let translation=try CaptionTranslationEditing.translated(caption,text:"안녕하세요",sourceLanguage:"en",targetLanguage:"ko",bilingual:false)
  var project=Project(name:"human-reference synthetic job");project.assets=[asset];project.sequence.tracks[0].clips=[source];project.sequence.tracks[2].clips=[caption,decoration,translation]
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"));model.reportsDirectory=root.appendingPathComponent("Reports");model.speechOptions.language="en"
  func reset(_ p:Project) {model.history=EditorHistory(project:p);model.selectedClipID=source.id;model.selectedClipIDs=[source.id];model.error=nil}
  reset(project)
  let captions=model.sourceTimedCaptions(for:source)
  check("Original source times survive speed trim hidden original and exclude decoration translation",captions.count == 1 && abs(captions[0].start-10.1)<0.00001 && abs(captions[0].end-19.9)<0.00001 && captions[0].text == "hello world")
  var ref=AccuracyReference.pending(segmentID:"synthetic-10-20",file:media.lastPathComponent,sha256:hash,start:10,end:20)
  ref.language="en";ref.reviewMethod="human-listened";ref.reviewer="TEST ONLY — synthetic fixture";ref.reviewedAt=Date(timeIntervalSince1970:1700000000);ref.textReviewed=true;ref.activityReviewed=true;ref.timingReviewed=true
  ref.spans=[.init(start:10,end:20,kind:.speech,text:"hello world",conditions:[.quiet])]
  let url=root.appendingPathComponent("human.reference.json")
  func write(_ value:AccuracyReference) throws {try RecognitionCacheSafety.encoder().encode(value).write(to:url,options:.atomic)}
  func settle() async throws {let until=Date().addingTimeInterval(40);while model.productivityBusy || model.productivityTask != nil {guard Date()<until else {throw ProjectError("Human evaluation timeout")};try await Task.sleep(nanoseconds:1_000_000)}}
  try write(ref);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  guard let valid=model.lastEvaluation else {throw ProjectError(model.error ?? "No human report")}
  let cli=try AccuracyDataset.evaluate(reference:ref,referenceURL:url,captions:captions,vadRegions:nil)
  check("App and CLI produce identical human metrics",valid.humanReference?.metrics == cli.metrics && valid.status == .scored && valid.cer == 0 && model.evaluationAttemptState == "scored")
  check("App verifies actual full source rather than stale asset hash",valid.humanReference?.sourceSHA256 == hash && valid.humanReference?.sourceSHA256 != asset.contentHash)
  check("Human report records exact reference bytes and revision",try valid.humanReference?.referenceSHA256 == AccuracyReference.load(url).sha256 && valid.humanReference?.metrics.referenceRevision == ref.revisionID)
  check("Human summary distinguishes verified JSON from plain comparison",EditorModel.summary(valid).contains("사람 검수 JSON 기준"))
  guard let oldURL=model.lastEvaluationReportURL else {throw ProjectError("Missing report path")};let oldBytes=try Data(contentsOf:oldURL)
  let oldReportCount=try FileManager.default.contentsOfDirectory(atPath:model.reportsDirectory.path).count
  let invalidCases:[(String,(inout AccuracyReference)->Void)]=[
   ("wrong complete source hash",{$0.sourceSHA256=String(repeating:"a",count:64)}),
   ("wrong source filename",{$0.sourceFile="foreign.mov"}),
   ("full-file reference never rebased to selected trim",{$0.sourceStart=0;$0.spans[0].start=0}),
   ("wrong selected language",{$0.language="ko"}),
   ("self-parent revision",{$0.parentRevisionID=$0.revisionID}),
   ("missing human review timestamp",{$0.reviewedAt=nil}),
   ("missing activity review",{$0.activityReviewed=false})]
  for (name,mutate) in invalidCases {
   var wrong=ref;mutate(&wrong);try write(wrong);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
   check("Invalid \(name) has no new score and preserves previous report",try model.error != nil && model.evaluationAttemptState == "unscored" && model.evaluationAttemptReason != nil && model.lastEvaluation == valid && model.lastEvaluationReportURL == oldURL && Data(contentsOf:oldURL) == oldBytes && FileManager.default.contentsOfDirectory(atPath:model.reportsDirectory.path).count == oldReportCount)
  }
  try write(ref);let raw=try String(contentsOf:url,encoding:.utf8)
  for (name,prefix) in [("root duplicate", "\"language\":\"ko\","),("escaped root duplicate", "\"langu\\u0061ge\":\"en\",")] {
   try ("{"+prefix+raw.dropFirst()).write(to:url,atomically:true,encoding:.utf8);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
   check("\(name) JSON is refused like CLI without replacing previous report",model.error?.contains("중복") == true && model.lastEvaluation == valid)
  }
  var mixed=project;var otherLanguage=caption;otherLanguage.id=UUID();otherLanguage.captionMetadata?.language="ko";mixed.sequence.tracks[2].clips.append(otherLanguage)
  reset(mixed);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("Mixed original languages cannot be silently reduced to majority language",model.error?.contains("섞여") == true && model.lastEvaluation == valid && model.evaluationRetainedPrevious)
  reset(project)
  let oversized=root.appendingPathComponent("oversized.json");FileManager.default.createFile(atPath:oversized.path,contents:nil);let handle=try FileHandle(forWritingTo:oversized);try handle.truncate(atOffset:4_000_001);try handle.close()
  model.evaluateSelectedCaptions(referenceURL:oversized);try await settle();check("Oversized JSON refused before decode and previous report preserved",model.error != nil && model.lastEvaluation == valid)
  let pending=AccuracyReference.pending(segmentID:ref.segmentID,file:ref.sourceFile,sha256:hash,start:10,end:20)
  try write(pending);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("Pending JSON publishes reason without accuracy or timing values",model.error == nil && model.lastEvaluation?.humanReference?.state == "pending" && model.lastEvaluation?.cer == nil && model.lastEvaluation?.timing == nil && EditorModel.summary(model.lastEvaluation!).contains("대기"))
  var untimed=ref;untimed.timingReviewed=false;try write(untimed);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("Text-only review has same CLI text metrics and explicitly absent timing",model.lastEvaluation?.status == .scored && model.lastEvaluation?.timing == nil && model.lastEvaluation?.humanReference?.metrics.startErrorP50 == nil && model.lastEvaluation?.humanReference?.timingReason.contains("시각 미검수") == true)
  let markdown=try String(contentsOf:model.lastEvaluationReportURL!,encoding:.utf8)
  check("Saved report preserves timing-unreviewed reason not missing-times claim",markdown.contains("시각 미검수") && !markdown.contains("대본에 시간 없음"))
  var boundary=ref;boundary.spans=[.init(start:10,end:15,kind:.speech,text:"hello world"),.init(start:15,end:20,kind:.excluded,reason:"synthetic exclusion")]
  try write(boundary);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("Cue crossing exclusion boundary cannot get guessed zero score",model.lastEvaluation?.humanReference?.state == "unscored" && model.lastEvaluation?.cer == nil && model.lastEvaluation?.humanReference?.metrics.reason?.contains("경계") == true)
  var silence=ref;silence.language="und";silence.spans=[.init(start:10,end:20,kind:.nonspeech,text:"")]
  try write(silence);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("Reviewed non-speech control shows overgeneration without undefined CER",model.lastEvaluation?.humanReference?.state == "nonspeech_control" && model.lastEvaluation?.cer == nil && model.lastEvaluation?.humanReference?.metrics.falsePositiveCaptions == 1 && EditorModel.summary(model.lastEvaluation!).contains("CER/WER 없음"))
  var noCaptions=project;noCaptions.sequence.tracks[2].clips=[decoration];reset(noCaptions)
  model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("Non-speech control works even with no original captions",model.error == nil && model.lastEvaluation?.humanReference?.metrics.falsePositiveCaptions == 0)
  try write(ref);model.evaluateSelectedCaptions(referenceURL:url);try await settle()
  check("No recognised captions reports full deletion rather than requiring hypothesis",model.error == nil && model.lastEvaluation?.cer == 1 && model.lastEvaluation?.humanReference?.metrics.matchedReferenceShare == 0)
  reset(project);let srt=root.appendingPathComponent("plain.srt");try "1\n00:00:10,000 --> 00:00:20,000\nhello world\n".write(to:srt,atomically:true,encoding:.utf8)
  model.evaluateSelectedCaptions(referenceURL:srt);try await settle()
  check("SRT remains general comparison and never acquires human provenance",model.lastEvaluation?.status == .scored && model.lastEvaluation?.humanReference == nil && EditorModel.summary(model.lastEvaluation!).contains("일반 대본"))
  try write(ref);model.evaluateSelectedCaptions(referenceURL:url);try await settle();let preserved=model.lastEvaluation!,preservedURL=model.lastEvaluationReportURL!,preservedBytes=try Data(contentsOf:preservedURL)
  // A long synthetic comparison keeps the real worker busy so cancellation/input races are measured.
  var large=project;large.assets[0].duration=MediaTime(7200,1);large.sequence.tracks[0].clips[0].sourceStart = .zero;large.sequence.tracks[0].clips[0].duration=MediaTime(7200,1);large.sequence.tracks[0].clips[0].playbackRate=nil;large.sequence.tracks[2].clips=[]
  var long=ref;long.sourceStart=0;long.sourceEnd=7200;long.segmentID="synthetic-long";long.spans=[]
  for i in 0..<1800 {
   let start=Double(i*4),text="today we record scene \(i) in the park and walk with friends"
   long.spans.append(.init(start:start,end:start+4,kind:.speech,text:text))
   var cue=caption;cue.id=UUID();cue.title?.text=i%10 == 0 ? text.replacingOccurrences(of:"friends",with:"family"):text;cue.start=MediaTime(seconds:start);cue.duration=MediaTime(4,1);cue.connection=ClipConnection(parentID:source.id,sourceStart:cue.start,sourceDuration:cue.duration)
   large.sequence.tracks[2].clips.append(cue)
  }
  func startLong() async throws -> Bool {
   reset(large);try write(long);model.evaluateSelectedCaptions(referenceURL:url)
   let until=Date().addingTimeInterval(5);while model.productivityBusy && (model.evaluationProgress ?? 0)<0.05 && Date()<until {try await Task.sleep(nanoseconds:1_000_000)}
   return model.productivityBusy && (model.evaluationProgress ?? 0)>=0.05
  }
  let active=try await startLong(),cancelStart=ProcessInfo.processInfo.systemUptime;model.cancelProductivity();try await settle();let cancelSeconds=ProcessInfo.processInfo.systemUptime-cancelStart
  check("JSON editor cancellation stops detached comparison and preserves prior result",try active && cancelSeconds<2 && !model.evaluationActive && model.evaluationProgress == nil && model.lastEvaluation == preserved && Data(contentsOf:preservedURL) == preservedBytes)
  let status=model.productivityStatus;try await Task.sleep(nanoseconds:100_000_000)
  check("Late JSON progress cannot overwrite cancellation status",model.productivityStatus == status)
  let referenceActive=try await startLong();try (Data(contentsOf:url)+Data("\n".utf8)).write(to:url,options:.atomic);try await settle()
  check("JSON replacement during comparison rejects new publication",referenceActive && model.error?.contains("바뀌었습니다") == true && model.lastEvaluation == preserved)
  let projectActive=try await startLong();var altered=model.project;altered.name="edited during human evaluation";model.history=EditorHistory(project:altered);try await settle()
  check("Document edit during JSON evaluation cannot publish stale result",projectActive && model.error?.contains("바뀌었습니다") == true && model.lastEvaluation == preserved)
  let sourceActive=try await startLong();try Data("changed actual source bytes".utf8).write(to:media,options:.atomic);try await settle()
  check("Actual source replacement during JSON evaluation preserves old report",try sourceActive && model.error != nil && model.lastEvaluation == preserved && Data(contentsOf:preservedURL) == preservedBytes)
  try JSONSerialization.data(withJSONObject:["synthetic":true,"cancelSeconds":cancelSeconds,"sourceSHA256":hash],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("measurements.json"))
  let failures=rows.filter {($0["passed"] as? Bool) != true}.count;print("HUMAN_EVALUATION_RESULT checks=\(rows.count) failures=\(failures)");if failures>0 {exit(1)}
 }
}

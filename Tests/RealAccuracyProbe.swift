import Foundation
import AVFoundation
@testable import JHCutCore

/// Real input preparation and repeatable recognition, separate from human reference status.
@main struct RealAccuracyProbe {
    struct Selection {var file:String;var start:Double;var end:Double;var rationale:String
        var id:String {URL(fileURLWithPath:file).deletingPathExtension().lastPathComponent+"-"+String(Int(start))+"-"+String(Int(end))}
    }
    static let selections=[
        Selection(file:"IMG_0047.mov",start:660,end:780,rationale:"기존 우선 검수 구간. 중계/주변 대화·소음 조건은 사람 검수로 확인."),
        Selection(file:"IMG_9211.mov",start:480,end:600,rationale:"기존 우선 검수 구간. 523…531초의 대사 여부·누락을 직접 확인."),
        Selection(file:"IMG_0140.mov",start:810,end:855,rationale:"과거 자동 VAD의 816…842.25초 말소리 후보. 발화로 확정하지 않음."),
        Selection(file:"IMG_0140.mov",start:30,end:60,rationale:"과거 음악 표식 구간. 사람이 비발화 여부를 확인할 대조 후보.")]
    static func main() async {
        setbuf(stdout,nil)
        let progress = AccuracyRunProgress()
        do {
            try await run(progress: progress)
            if progress.receipt.status != "completed" { exit(1) }
        } catch {
            do { try progress.fail(error) }
            catch { fputs("REAL_ACCURACY_RECEIPT_WRITE_FAILED; partial files remain at ACCURACY_OUTPUT.\n", stderr) }
            let status = progress.receipt
            print("REAL_ACCURACY_FAILED phase=\(status.phase) segment=\(status.segmentID ?? "none") mode=\(status.mode ?? "none") trial=\(status.trial ?? 0) completed=\(status.completedRecords)/\(status.plannedRecords) status=\(status.status)")
            exit(1)
        }
    }
    static func run(progress: AccuracyRunProgress) async throws {
        let root=try ProbeWorkspace.prepare(defaultPath:"RealAccuracy")
        print("ACCURACY_OUTPUT="+root.path)
        try progress.attach(root)
        try progress.advance("configuration")
        let env=ProcessInfo.processInfo.environment
        let copies=URL(fileURLWithPath:"Artifacts/Upgrade-0.7/RealCopies",isDirectory:true)
        let referenceDir=URL(fileURLWithPath:env["JHCUT_REFERENCE_DIR"] ?? "References/IPhone",isDirectory:true)
        let baseline=try AccuracyRunSupport.baseline(env["JHCUT_ACCURACY_BASELINE"].map {URL(fileURLWithPath:$0)})
        var options=SpeechOptions();options.language=env["JHCUT_ACCURACY_LANGUAGE"] ?? "auto"
        options.channel=Int(env["JHCUT_ACCURACY_CHANNEL"] ?? "-1") ?? -99
        guard ["auto","ko","ja","en"].contains(options.language),(-1...31).contains(options.channel) else {throw ProjectError("평가 인식 언어·채널 설정을 확인하세요.")}
        let opts:[String:String]=["language":options.language,"channel":String(options.channel),"accurate":"true","glossary":"","windowSeconds":"300"]
        let optionsSHA=try AccuracyRunSupport.digest(opts),config=WhisperConfiguration()
        try progress.advance("model-and-runtime-identity")
        let modelSHA=try await FileIdentity.sha256(config.modelURL),runtimeSHA=try await FileIdentity.sha256(config.runtimeURL)
        let build=URL(fileURLWithPath:env["JHCUT_BUILD_DIR"] ?? "Build",isDirectory:true)
        let coreSHA=try await FileIdentity.sha256(build.appendingPathComponent("libJHCutCore.dylib"))
        guard modelSHA == config.modelSpec.sha256 else {throw ProjectError("승인한 Whisper 모델 해시와 다릅니다.")}
        var checks:[[String:Any]]=[],records:[AccuracyRunRecord]=[],manifest:[[String:Any]]=[]
        func check(_ name:String,_ pass:Bool) {
            checks.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") \(name)")
            progress.updateCounts(assertionCount: checks.count, assertionFailures: checks.filter {($0["passed"] as? Bool) != true}.count)
        }
        func save() throws {
            progress.updateCounts(completedRecords: records.count, assertionCount: checks.count, assertionFailures: checks.filter {($0["passed"] as? Bool) != true}.count)
            try RecognitionCacheSafety.encoder().encode(records).write(to:root.appendingPathComponent("summary.json"),options:.atomic)
            try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"),options:.atomic)
            try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("dataset-manifest.json"),options:.atomic)
        }
        defer {
            if progress.receipt.status != "completed" {
                do { try save() }
                catch { fputs("REAL_ACCURACY_PARTIAL_SAVE_FAILED; no successful completion is implied.\n", stderr) }
            }
        }
        var sourceHashes:[String:String]=[:]
        for selection in selections {
            try progress.advance("preparing-segment", segmentID: selection.id)
            try Task.checkCancellation()
            let media=copies.appendingPathComponent(selection.file)
            if sourceHashes[selection.file] == nil {sourceHashes[selection.file]=try await FileIdentity.sha256(media)}
            let sourceSHA=sourceHashes[selection.file]!,stamp=try MediaFingerprintCache.stat(media)
            let mediaDuration=try await AVURLAsset(url:media).load(.duration).seconds
            guard selection.end <= mediaDuration,selection.start >= 0 else {throw ProjectError("평가 구간이 원본 밖입니다.")}
            let folder=root.appendingPathComponent(selection.id,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            let candidate=referenceDir.appendingPathComponent(selection.id+".reference.json")
            var reference=AccuracyReference.pending(segmentID:selection.id,file:selection.file,sha256:sourceSHA,start:selection.start,end:selection.end)
            var referenceIssue:String?,referenceData:Data?,referenceSourceSHA:String?
            if FileManager.default.fileExists(atPath:candidate.path) {
                do {
                    let loaded=try AccuracyReference.load(candidate)
                    try loaded.reference.validate(segmentID:selection.id,file:selection.file,sha256:sourceSHA,start:selection.start,end:selection.end)
                    reference=loaded.reference;referenceData=loaded.data;referenceSourceSHA=loaded.sha256
                } catch {referenceIssue=error.localizedDescription}
            }
            let snapshot=try referenceData ?? RecognitionCacheSafety.encoder().encode(reference)
            let referenceSHA=RecognitionCacheSafety.digest(snapshot)
            try snapshot.write(to:folder.appendingPathComponent("reference-snapshot.json"))
            var template=reference;template.parentRevisionID=reference.revisionID;template.revisionID=UUID()
            template.reviewer=nil;template.reviewedAt=nil;template.textReviewed=false;template.timingReviewed=false;template.activityReviewed=false;template.reviewMethod="pending"
            try RecognitionCacheSafety.encoder().encode(template).write(to:folder.appendingPathComponent("review-template.json"))
            let start=MediaTime(seconds:selection.start),duration=MediaTime(seconds:selection.end-selection.start)
            let conservative=try await VoiceActivity.analyze(url:media,sourceStart:start,duration:duration,preferredChannel:options.channel,policy:.conservative)
            let fast=try await VoiceActivity.analyze(url:media,sourceStart:start,duration:duration,preferredChannel:options.channel,policy:.fast)
            guard let frozenSelection=conservative.channelSelection else {throw ProjectError("공통 원본 오디오 채널을 선택하지 못했습니다.")}
            check(selection.id+": both VAD policies use identical native channel plan",fast.channelSelection == frozenSelection)
            try RecognitionCacheSafety.encoder().encode(conservative).write(to:folder.appendingPathComponent("vad-conservative.json"))
            try RecognitionCacheSafety.encoder().encode(fast).write(to:folder.appendingPathComponent("vad-fast.json"))
            let audition=folder.appendingPathComponent("listen.wav")
            _=try await LocalTranscription.extractAudio(url:media,sourceStart:start,duration:duration,destination:audition,preferredChannel:options.channel,audioSelection:frozenSelection)
            var nativeFiles:[String]=[]
            for channel in 0..<frozenSelection.channelCount {
                let path=folder.appendingPathComponent("native-\(channel).wav")
                _=try await LocalTranscription.extractAudio(url:media,sourceStart:start,duration:duration,destination:path,preferredChannel:channel)
                nativeFiles.append(path.lastPathComponent)
            }
            let pcmDuration=try await AVURLAsset(url:audition).load(.duration).seconds
            check(selection.id+": audition matches requested source interval",abs(pcmDuration-duration.seconds) < 0.002)
            manifest.append(["segmentID":selection.id,"sourceFile":selection.file,"sourceSHA256":sourceSHA,"sourceDuration":mediaDuration,"sourceStart":selection.start,"sourceEnd":selection.end,"selectionRationale":selection.rationale,"selectionHumanConfirmed":reference.humanReviewed,"referenceRevision":reference.revisionID.uuidString,"referenceSHA256":referenceSHA,"referenceState":reference.humanReviewed ? "human_reviewed":"pending_review","referenceIssue":referenceIssue as Any? ?? NSNull(),"auditionSHA256":try await FileIdentity.sha256(audition),"auditionFile":"\(selection.id)/listen.wav","nativeChannelFiles":nativeFiles,"reviewPage":"\(selection.id)/review.html"])
            var firstOutputs:[String:String]=[:]
            for trial in 1...2 {
                for (mode,vad) in [("full",Optional<VoiceActivityReport>.none),("skip-conservative",Optional(conservative)),("skip-fast",Optional(fast))] {
                    try Task.checkCancellation()
                    try progress.advance("recognizing", segmentID: selection.id, mode: mode, trial: trial)
                    print("MEASURE \(selection.id) \(mode) trial \(trial) · real Whisper · reference \(reference.humanReviewed ? "reviewed":"unreviewed")")
                    let began=ProcessInfo.processInfo.systemUptime
                    let transcript=try await LocalTranscription.transcribeLong(url:media,sourceStart:start,duration:duration,configuration:config,options:options,windowSeconds:300,speechRegions:vad?.speechRegions,speechEvidence:vad?.confidentSpeech,audioSelection:frozenSelection,speechPolicy:vad?.policy ?? .conservative)
                    let wall=ProcessInfo.processInfo.systemUptime-began
                    try progress.advance("publishing-trial", segmentID: selection.id, mode: mode, trial: trial)
                    check(selection.id+": \(mode) trial \(trial) uses frozen native audio plan",transcript.audioSelection == frozenSelection)
                    let srt=try SRTCodec.serialize(transcript.cues),srtData=Data(srt.utf8),outputSHA=RecognitionCacheSafety.digest(srtData)
                    try srtData.write(to:folder.appendingPathComponent("\(mode)-trial-\(trial).asr.srt"))
                    try RecognitionCacheSafety.encoder().encode(transcript).write(to:folder.appendingPathComponent("\(mode)-trial-\(trial).transcript.json"))
                    let captions=transcript.cues.map {EvaluatedCaption(text:$0.text,start:$0.start.seconds,end:(try? $0.start.adding($0.duration).seconds) ?? .nan)}
                    let evaluation=try referenceIssue.map {AccuracyDataset.unscored("정답 입력 오류: "+$0,revision:reference.revisionID)} ?? AccuracyDataset.evaluate(reference:reference,referenceURL:folder.appendingPathComponent("reference-snapshot.json"),captions:captions,vadRegions:vad?.speechRegions)
                    if let report=evaluation.transcriptReport {_=try TranscriptEvaluation.write(report,title:selection.id+" · "+mode,to:folder,name:"evaluation-trial-\(trial)-\(mode)")}
                    let identity=try AccuracyRunSupport.identity(source:sourceSHA,start:selection.start,end:selection.end,referenceSHA:referenceSHA,model:modelSHA,runtime:runtimeSHA,options:optionsSHA,selection:frozenSelection,mode:mode)
                    let previous=baseline.first {$0.identitySHA256 == identity && $0.trial == trial}
                    let gate=previous.map {AccuracyDataset.regression(baseline:$0.metrics,candidate:evaluation.metrics,identityMatches:$0.identitySHA256 == identity)} ?? (baseline.isEmpty ? "no_baseline":"unscored_or_incompatible")
                    records.append(AccuracyRunRecord(segmentID:selection.id,sourceFile:selection.file,sourceSHA256:sourceSHA,sourceStart:selection.start,sourceEnd:selection.end,referenceRevision:reference.revisionID,referenceSHA256:referenceSHA,referenceState:reference.humanReviewed ? "human_reviewed":"pending_review",referenceIssue:referenceIssue,modelSHA256:modelSHA,runtimeSHA256:runtimeSHA,coreSHA256:coreSHA,pipeline:LocalTranscription.pipelineVersion,optionsSHA256:optionsSHA,audioSelection:frozenSelection,mode:mode,trial:trial,metricPolicy:AccuracyDataset.metricPolicy,identitySHA256:identity,outputSHA256:outputSHA,languageDetected:transcript.language,wallSeconds:wall,vadSeconds:vad?.analysisSeconds,inputForwardedSeconds:vad?.speechRegionSeconds ?? duration.seconds,metrics:evaluation.metrics,regressionGate:gate,baselineIdentity:previous?.identitySHA256))
                    if trial == 1 {firstOutputs[mode]=outputSHA} else {check(selection.id+": \(mode) repeat output and reference revision stable",firstOutputs[mode] == outputSHA && records.filter {$0.segmentID == selection.id && $0.mode == mode}.allSatisfy {$0.identitySHA256 == identity && $0.referenceRevision == reference.revisionID})}
                    check(selection.id+": \(mode) never scores unreviewed reference",reference.humanReviewed || evaluation.metrics.status == "unscored" && evaluation.metrics.cer == nil && evaluation.metrics.wer == nil && evaluation.metrics.vadSpeechDurationRecall == nil)
                    check(selection.id+": \(mode) no unapproved reference or regression hold",referenceIssue == nil && gate != "hold_regression")
                    try save()
                }
            }
            if let referenceSourceSHA {check(selection.id+": persistent human reference unchanged",try AccuracyReference.load(candidate).sha256 == referenceSourceSHA)}
            check(selection.id+": source state unchanged",try MediaFingerprintCache.stat(media) == stamp)
        }
        try progress.advance("verifying-inputs")
        for (file,sha) in sourceHashes {check(file+": full copy SHA unchanged",try await FileIdentity.sha256(copies.appendingPathComponent(file)) == sha)}
        let finalModel=try await FileIdentity.sha256(config.modelURL),finalRuntime=try await FileIdentity.sha256(config.runtimeURL)
        check("Model and runtime bytes unchanged",finalModel == modelSHA && finalRuntime == runtimeSHA)
        check("All three real inputs and four review scopes represented",Set(records.map(\.sourceFile)).count == 3 && Set(records.map(\.segmentID)).count == 4 && records.count == 24)
        try save()
        let count=checks.filter {($0["passed"] as? Bool) != true}.count
        try progress.finish(assertionCount: checks.count, assertionFailures: count, completedRecords: records.count)
        print("REAL_ACCURACY_RESULT checks=\(checks.count) failures=\(count)")
        print("ACCURACY_DATA_STATUS reviewedSegments=\(manifest.filter {($0["selectionHumanConfirmed"] as? Bool) == true}.count)/4 realScores=\(records.filter {$0.metrics.status == "scored"}.count) · human verification is not inferred from test success")
    }
}

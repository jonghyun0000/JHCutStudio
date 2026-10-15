import Foundation
@testable import JHCutCore

@main struct AccuracyDatasetProbe {
    static let hash=String(repeating:"a",count:64)
    static func reference() -> AccuracyReference {
        var r=AccuracyReference.pending(segmentID:"fixture-10-20",file:"fixture.mov",sha256:hash,start:10,end:20)
        r.language="en";r.reviewMethod="human-listened";r.reviewer="TEST ONLY — synthetic reference";r.reviewedAt=Date(timeIntervalSince1970:1700000000);r.textReviewed=true;r.activityReviewed=true;r.timingReviewed=true
        r.spans=[.init(start:10,end:12,kind:.speech,text:"hello world",conditions:[.quiet]),.init(start:12,end:14,kind:.nonspeech,conditions:[.backgroundMusic]),.init(start:14,end:15,kind:.speech,text:"yes",conditions:[.shortResponse]),.init(start:15,end:17,kind:.excluded,reason:"overlap not intelligible",conditions:[.overlap]),.init(start:17,end:20,kind:.speech,text:"we are ready",conditions:[.noise])]
        return r
    }
    static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.dropFirst().first == "--verify-js-export" {
            let url=URL(fileURLWithPath:CommandLine.arguments[2]),loaded=try AccuracyReference.load(url)
            try loaded.reference.validate(segmentID:"fixture-10-20",file:"fixture.mov",sha256:hash,start:10,end:20)
            guard loaded.reference.humanReviewed,!loaded.reference.timingReviewed else {throw ProjectError("JS export review flags differ")}
            print("PASS JavaScript human-reference export validates through Swift provenance gate");return
        }
        let root=try ProbeWorkspace.prepare(defaultPath:"AccuracyDataset")
        var rows:[[String:Any]]=[]
        func check(_ name:String,_ pass:Bool) {rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") \(name)")}
        func rejected(_ name:String,_ mutation:(inout AccuracyReference)->Void) {
            var r=reference();mutation(&r)
            var rejected=false;do {try r.validate(segmentID:"fixture-10-20",file:"fixture.mov",sha256:hash,start:10,end:20)} catch {rejected=true}
            check(name,rejected)
        }
        let r=reference(),url=root.appendingPathComponent("synthetic.reference.json")
        try r.validate(segmentID:r.segmentID,file:r.sourceFile,sha256:hash,start:10,end:20)
        try RecognitionCacheSafety.encoder().encode(r).write(to:url)
        let loaded=try AccuracyReference.load(url)
        check("Exact reference bytes and human revision load",loaded.reference == r && loaded.sha256 == RecognitionCacheSafety.digest(loaded.data))
        rejected("Foreign source hash refused"){$0.sourceSHA256=String(repeating:"b",count:64)}
        rejected("Foreign selection scope refused"){$0.sourceStart=9}
        rejected("Wrong source file refused"){$0.sourceFile="other.mov"}
        rejected("Unknown reference schema refused"){$0.schemaVersion=2}
        rejected("Missing human reviewer refused"){$0.reviewer=nil}
        rejected("Missing human date refused"){$0.reviewedAt=nil}
        rejected("Machine-only review cannot attest human verification"){$0.reviewMethod="pending"}
        rejected("Human activity-only cannot score text"){$0.textReviewed=false}
        rejected("Timing cannot be reviewed without text"){$0.textReviewed=false;$0.timingReviewed=true}
        rejected("Partial time coverage is refused"){$0.spans.removeLast()}
        rejected("Unannotated gap refused"){$0.spans[1].start=12.1}
        rejected("Overlapping spans refused"){$0.spans[1].start=11.9}
        rejected("Nonfinite time refused"){$0.spans[0].end = .nan}
        rejected("Empty speech text refused"){$0.spans[0].text=""}
        rejected("Non-speech with invented dialogue refused"){$0.spans[1].text="guess"}
        rejected("Unclear area needs reason"){$0.spans[3].reason=""}
        rejected("Overlapping dialogue must be explicitly excluded"){$0.spans[0].conditions=[.overlap]}
        rejected("Placeholder cannot become reviewed by checkbox alone"){$0.spans[3].reason="사람 검수 미완료"}
        rejected("Duplicate interval ID refused"){$0.spans[1].id=$0.spans[0].id}
        rejected("Revision cannot be its own parent"){$0.parentRevisionID=$0.revisionID}
        rejected("Speech language cannot remain unknown"){$0.language="und"}
        let pending=AccuracyReference.pending(segmentID:r.segmentID,file:r.sourceFile,sha256:hash,start:10,end:20)
        try pending.validate(segmentID:r.segmentID,file:r.sourceFile,sha256:hash,start:10,end:20)
        let p=try AccuracyDataset.evaluate(reference:pending,referenceURL:url,captions:[],vadRegions:[])
        check("Pending reference leaves all accuracy fields absent",p.metrics.status == "unscored" && p.metrics.cer == nil && p.metrics.wer == nil && p.metrics.vadSpeechDurationRecall == nil && p.metrics.falsePositiveCaptions == nil)
        let perfect=[EvaluatedCaption(text:"hello world",start:10.1,end:12.1),.init(text:"yes",start:14.1,end:15),.init(text:"we are ready",start:17.1,end:19.9)]
        let scored=try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:perfect,vadRegions:[10...11,10.5...12,14...14.5,18...20])
        check("Reviewed text identical to ASR is legitimate, no edit quota",scored.metrics.status == "scored" && scored.metrics.cer == 0 && scored.metrics.wer == 0)
        check("Human interval geometry gives duration VAD recall without double counting",abs(scored.metrics.vadSpeechDurationRecall!-0.75)<1e-9)
        check("Reviewed reference and source exclusions are tracked",scored.metrics.referenceRevision == r.revisionID && scored.metrics.reviewedSpeechSeconds == 6 && scored.metrics.excludedSeconds == 2 && scored.metrics.reviewedNonspeechSeconds == 2)
        check("Timing p50 and nearest-rank p95 available only after timing review",abs(scored.metrics.startErrorP50!-0.1)<1e-9 && abs(scored.metrics.startErrorP95!-0.1)<1e-9)
        var textOnly=r;textOnly.timingReviewed=false
        let text=try AccuracyDataset.evaluate(reference:textOnly,referenceURL:url,captions:perfect,vadRegions:nil)
        check("Text-only verification has CER but no timing or imaginary VAD recall",text.metrics.cer == 0 && text.metrics.startErrorP95 == nil && text.metrics.endErrorP50 == nil && text.metrics.vadSpeechDurationRecall == nil && text.transcriptReport?.timing == nil)
        var hallucinated=perfect;hallucinated.append(.init(text:"Music",start:12.2,end:13.8))
        let extra=try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:hallucinated,vadRegions:nil)
        check("Caption entirely in reviewed non-speech is traced as extra output",extra.metrics.falsePositiveCaptions == 1 && extra.metrics.cer! > 0 && extra.metrics.events.contains {$0.kind == "captionInReviewedNonspeech" && $0.captionIndex == 3})
        let missing=try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:Array(perfect.dropLast()),vadRegions:nil)
        check("Missing human speech retains reference span ID and source times",missing.metrics.missingSentences == 1 && missing.metrics.events.contains {$0.kind == "missingReferenceSpeech" && $0.referenceSpanID == r.spans[4].id && $0.start == 17})
        var excluded=perfect;excluded.append(.init(text:"unknown",start:15.2,end:16.8))
        let masked=try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:excluded,vadRegions:nil)
        check("Wholly excluded prediction is omitted with audit event",masked.metrics.cer == 0 && masked.metrics.events.contains {$0.kind == "excludedCaption"})
        let crosses=try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:[.init(text:"maybe guess",start:14.8,end:17.2)],vadRegions:nil)
        check("Cross-exclusion cue cannot get guessed partial text or fake zero",crosses.metrics.status == "unscored" && crosses.metrics.cer == nil)
        var control=r;control.language="und";control.spans=[.init(start:10,end:20,kind:.nonspeech)]
        let nonspeech=try AccuracyDataset.evaluate(reference:control,referenceURL:url,captions:[.init(text:"invented",start:11,end:12)],vadRegions:nil)
        check("Reviewed non-speech control has false-positive count without undefined CER",nonspeech.metrics.status == "nonspeech_control" && nonspeech.metrics.cer == nil && nonspeech.metrics.falsePositiveCaptions == 1)
        var allExcluded=r;allExcluded.spans=[.init(start:10,end:20,kind:.excluded,reason:"all inaudible")]
        check("All-excluded reference never counts as accuracy success",try AccuracyDataset.evaluate(reference:allExcluded,referenceURL:url,captions:[],vadRegions:nil).metrics.status == "unscored")
        let noCaptions=try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:[],vadRegions:[])
        check("No recognised speech gives deletion error and zero recall",noCaptions.metrics.cer == 1 && noCaptions.metrics.matchedReferenceShare == 0 && noCaptions.metrics.vadSpeechDurationRecall == 0)
        check("Out-of-range VAD cannot claim recall",try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:perfect,vadRegions:[0...30]).metrics.status == "unscored")
        var units5:[TranscriptReference.Unit]=[]
        var c5:[EvaluatedCaption]=[]
        let errors=[0.1,0.2,0.3,0.4,1.0]
        for index in 0..<5 {
            let start=10.0+Double(index)*2.0,end=start+1.0
            units5.append(.init(text:"scene \(index)",start:start,end:end))
            c5.append(.init(text:"scene \(index)",start:start+errors[index],end:end+errors[index]))
        }
        let r5=TranscriptReference(url:url,units:units5)
        let times=try TranscriptEvaluation.evaluate(captions:c5,reference:r5,language:"en",sourceRange:10...20,mediaDuration:20)
        check("Five-pair timing has p50 0.3 and nearest-rank p95 1.0",abs(times.timing!.medianAbsoluteStart-0.3)<1e-9 && times.timing?.p95AbsoluteStart == 1)
        var base=scored.metrics,candidate=scored.metrics;base.reviewedSpeechSeconds=120;candidate.reviewedSpeechSeconds=120
        check("Fixed-reference comparable scores pass provisional gate",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "within_provisional_limits")
        candidate.cer=0.0200001
        check("CER worsening over 2pp holds regression",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "hold_regression")
        candidate=base;candidate.wer=0.03
        check("WER worsening over 2pp holds regression",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "hold_regression")
        candidate=base;candidate.matchedReferenceShare=0.989
        check("Matched reference share loss over 1pp holds regression",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "hold_regression")
        candidate=base;candidate.cer=0.02
        check("Exact 2pp boundary is not falsely greater",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "within_provisional_limits")
        candidate=base;candidate.referenceRevision=UUID()
        check("Foreign revision refuses comparison",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "unscored_or_incompatible")
        check("Foreign input model configuration refuses comparison",AccuracyDataset.regression(baseline:base,candidate:base,identityMatches:false) == "unscored_or_incompatible")
        candidate=base;candidate.cer = .nan
        check("Nonfinite regression numbers cannot pass",AccuracyDataset.regression(baseline:base,candidate:candidate,identityMatches:true) == "unscored_or_incompatible")
        check("Small samples require review despite good metrics",AccuracyDataset.regression(baseline:scored.metrics,candidate:scored.metrics,identityMatches:true) == "review_small_sample_or_alignment")
        let sig=try AccuracyRunSupport.identity(source:hash,start:10,end:20,referenceSHA:loaded.sha256,model:hash,runtime:hash,options:hash,selection:nil,mode:"full")
        check("Different truth bytes cannot share evaluation signature",try sig != AccuracyRunSupport.identity(source:hash,start:10,end:20,referenceSHA:String(repeating:"b",count:64),model:hash,runtime:hash,options:hash,selection:nil,mode:"full"))
        let record=AccuracyRunRecord(segmentID:r.segmentID,sourceFile:r.sourceFile,sourceSHA256:hash,sourceStart:10,sourceEnd:20,referenceRevision:r.revisionID,referenceSHA256:loaded.sha256,referenceState:"human_reviewed",modelSHA256:hash,runtimeSHA256:hash,coreSHA256:hash,pipeline:"TEST ONLY",optionsSHA256:hash,mode:"full",trial:1,metricPolicy:AccuracyDataset.metricPolicy,identitySHA256:sig,outputSHA256:hash,languageDetected:"en",wallSeconds:1,inputForwardedSeconds:10,metrics:scored.metrics,regressionGate:"no_baseline")
        let baselineURL=root.appendingPathComponent("synthetic-baseline.json");try RecognitionCacheSafety.encoder().encode([record]).write(to:baselineURL)
        check("Baseline preserves exact reference and input binding",try AccuracyRunSupport.baseline(baselineURL).first?.identitySHA256 == sig)
        var bad=record;bad.referenceSHA256=String(repeating:"c",count:64)
        let badURL=root.appendingPathComponent("tampered-baseline.json");try RecognitionCacheSafety.encoder().encode([bad]).write(to:badURL)
        var badRef=false;do {_=try AccuracyRunSupport.baseline(badURL)} catch {badRef=true}
        check("Altered baseline cannot reuse stale declared signature",badRef)
        let task=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try AccuracyDataset.evaluate(reference:r,referenceURL:url,captions:perfect,vadRegions:nil)}
        var cancelled=false;do {_=try await task.value} catch is CancellationError {cancelled=true}
        check("Dataset scoring propagates cancellation instead of success",cancelled)
        try RecognitionCacheSafety.encoder().encode(AccuracyReference.pending(segmentID:r.segmentID,file:r.sourceFile,sha256:hash,start:10,end:20)).write(to:root.appendingPathComponent("js-template.json"))
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("core-checks.json"))
        let failures=rows.filter {($0["passed"] as? Bool) != true}.count
        print("ACCURACY_DATASET_CORE checks=\(rows.count) failures=\(failures)")
        if failures > 0 {exit(1)}
    }
}

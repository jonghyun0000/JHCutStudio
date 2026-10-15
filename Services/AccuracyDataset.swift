import Foundation

/// Human reference provenance for a bounded SOURCE interval. Machine drafts never change review.
public struct AccuracyReference: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case speech, nonspeech, excluded }
    public enum Condition: String, Codable, Sendable, Hashable { case quiet, backgroundMusic, noise, shortResponse, overlap, unknown }
    public struct Span: Codable, Sendable, Equatable {
        public var id: UUID
        public var start: Double
        public var end: Double
        public var kind: Kind
        public var text: String
        public var reason: String
        public var conditions: [Condition]
        public init(id: UUID = UUID(),start: Double,end: Double,kind: Kind,text: String = "",reason: String = "",conditions: [Condition] = [.unknown]) {
            self.id=id;self.start=start;self.end=end;self.kind=kind;self.text=text;self.reason=reason;self.conditions=conditions
        }
    }
    public var schemaVersion = 1
    public var segmentID: String
    public var revisionID: UUID
    public var parentRevisionID: UUID?
    public var sourceFile: String
    public var sourceSHA256: String
    public var sourceStart: Double
    public var sourceEnd: Double
    public var language: String
    public var reviewer: String?
    public var reviewedAt: Date?
    public var reviewMethod: String
    public var textReviewed: Bool
    public var timingReviewed: Bool
    public var activityReviewed: Bool
    public var draftExposure: Bool
    public var overlapPolicy: String
    public var spans: [Span]

    public static func pending(segmentID: String,file: String,sha256: String,start: Double,end: Double) -> Self {
        Self(segmentID:segmentID,revisionID:UUID(),sourceFile:file,sourceSHA256:sha256,sourceStart:start,sourceEnd:end,language:"und",reviewMethod:"pending",textReviewed:false,timingReviewed:false,activityReviewed:false,draftExposure:false,overlapPolicy:"exclude",spans:[Span(start:start,end:end,kind:.excluded,reason:"사람 검수 미완료")])
    }
    public var humanReviewed: Bool {
        textReviewed && activityReviewed && reviewMethod == "human-listened" && !(reviewer?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) && reviewedAt != nil
    }
    /// Coverage has no silent gaps: unclear speech/overlap must be explicit excluded intervals.
    public func validate(segmentID: String,file: String,sha256: String,start: Double,end: Double) throws {
        try Task.checkCancellation()
        guard schemaVersion == 1,self.segmentID == segmentID,sourceFile == file,sourceSHA256 == sha256,
              sourceSHA256.count == 64,sourceSHA256.allSatisfy({$0.isHexDigit && !$0.isUppercase}),
              sourceStart.isFinite,sourceEnd.isFinite,abs(sourceStart-start) < 0.000001,abs(sourceEnd-end) < 0.000001,start >= 0,end > start,
              overlapPolicy == "exclude",!spans.isEmpty,spans.count <= 20_000,Set(spans.map(\.id)).count == spans.count,
              parentRevisionID != revisionID,reviewMethod == "pending" || reviewMethod == "human-listened",
              language == "und" || ["ko","ja","en"].contains(language) else {throw ProjectError("정답의 원본·범위·버전·검수 정책이 평가 입력과 다릅니다.")}
        guard (reviewer?.utf8.count ?? 0) <= 256,reviewedAt?.timeIntervalSince1970.isFinite ?? true,
              !timingReviewed || textReviewed && activityReviewed,
              !(textReviewed || activityReviewed || timingReviewed) || humanReviewed else {throw ProjectError("사람의 청취 검수자·일시·텍스트·발화 구간 확인이 필요합니다.")}
        var cursor=start,totalBytes=0
        for span in spans {
            try Task.checkCancellation()
            let amount=span.text.utf8.count+span.reason.utf8.count
            guard span.start.isFinite,span.end.isFinite,abs(span.start-cursor) < 0.000001,span.end > span.start,span.end <= end+0.000001,
                  amount <= 65_536,amount <= 2_000_000-totalBytes,!span.conditions.isEmpty,span.conditions.count <= Condition.all.count,Set(span.conditions).count == span.conditions.count else {throw ProjectError("정답 구간의 공백·겹침·시간·크기를 확인하세요.")}
            totalBytes+=amount;cursor=span.end
            if span.kind == .speech {
                guard !TranscriptEvaluation.characters(span.text,language:language).isEmpty,!span.conditions.contains(.overlap),["ko","ja","en"].contains(language) else {throw ProjectError("대사·언어를 확인하세요. 겹침 발화는 사유와 함께 평가 제외로 남깁니다.")}
            } else {
                if humanReviewed,span.kind == .excluded,["사람 검수 미완료","미검수 공백"].contains(span.reason.trimmingCharacters(in:.whitespacesAndNewlines)) {throw ProjectError("미검수 표시를 실제 검수 결과 또는 제외 사유로 바꾸세요.")}
                guard span.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,span.kind != .excluded || !span.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw ProjectError("비발화 구간에는 대사를 쓰지 않고, 제외 구간에는 사유를 적으세요.")}
            }
        }
        guard abs(cursor-end) < 0.000001 else {throw ProjectError("선택 구간 전체를 발화·비발화·제외로 구분하세요.")}
    }
    public static func load(_ url: URL) throws -> (reference:Self,sha256:String,data:Data) {
        try Task.checkCancellation()
        let data=try RecognitionCacheSafety.read(url,maximum:4_000_000)
        try ReferenceJSONSafety.validate(data)
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let spans=object["spans"] as? [Any],spans.count <= 20_000 else {throw ProjectError("정답 JSON 구간 수·형식이 올바르지 않습니다.")}
        let result=try RecognitionCacheSafety.decoder().decode(Self.self,from:data)
        try Task.checkCancellation()
        return (result,RecognitionCacheSafety.digest(data),data)
    }
}
private extension AccuracyReference.Condition { static var all:[Self] {[.quiet,.backgroundMusic,.noise,.shortResponse,.overlap,.unknown]} }

public struct AccuracyMetrics: Codable, Sendable, Equatable {
    public var status: String
    public var reason: String?
    public var referenceRevision: UUID?
    public var cer: Double?
    public var wer: Double?
    public var matchedReferenceShare: Double?
    public var vadSpeechDurationRecall: Double?
    public var falsePositiveCaptions: Int?
    public var missingSentences: Int?
    public var startErrorP50: Double?
    public var startErrorP95: Double?
    public var endErrorP50: Double?
    public var endErrorP95: Double?
    public var reviewedSpeechSeconds: Double?
    public var reviewedNonspeechSeconds: Double?
    public var excludedSeconds: Double?
    public var alignmentLimited: Bool?
    public var events: [AccuracyEvent]
}
public struct AccuracyEvent: Codable, Sendable, Equatable {
    public var kind: String
    public var referenceSpanID: UUID?
    public var captionIndex: Int?
    public var start: Double
    public var end: Double
    public var text: String
}
public struct AccuracyEvaluation: Sendable {
    public var metrics: AccuracyMetrics
    public var transcriptReport: TranscriptEvaluationReport?
}
public enum AccuracyDataset {
    public static let metricPolicy = "human-source-reference-v1-nonoverlap-nearest-rank-p95"
    public static func unscored(_ reason: String,revision: UUID? = nil) -> AccuracyEvaluation {
        AccuracyEvaluation(metrics:AccuracyMetrics(status:"unscored",reason:reason,referenceRevision:revision,events:[]),transcriptReport:nil)
    }
    /// No edit-quota heuristic: an independently heard, verified perfect ASR result is legitimate.
    public static func evaluate(reference: AccuracyReference?,referenceURL: URL,captions: [EvaluatedCaption],vadRegions: [ClosedRange<Double>]?, progress: (@Sendable (EvaluationProgress) -> Void)? = nil) throws -> AccuracyEvaluation {
        try Task.checkCancellation()
        guard let ref=reference else {return unscored("사람 검수 정답 없음")}
        try ref.validate(segmentID:ref.segmentID,file:ref.sourceFile,sha256:ref.sourceSHA256,start:ref.sourceStart,end:ref.sourceEnd)
        guard ref.humanReviewed else {return unscored("사람의 텍스트·발화 구간 청취 검수 대기",revision:ref.revisionID)}
        guard !captions.contains(where:{!$0.start.isFinite || !$0.end.isFinite || $0.start < ref.sourceStart-0.001 || $0.end > ref.sourceEnd+0.001 || $0.end <= $0.start}) else {return unscored("인식 자막이 선택한 원본 구간을 벗어납니다.",revision:ref.revisionID)}
        let speech=ref.spans.filter {$0.kind == .speech},nonspeech=ref.spans.filter {$0.kind == .nonspeech},excluded=ref.spans.filter {$0.kind == .excluded}
        var eligible:[EvaluatedCaption]=[],events:[AccuracyEvent]=[]
        for (index,caption) in captions.enumerated() {
            try Task.checkCancellation()
            let touched=excluded.filter {min($0.end,caption.end)-max($0.start,caption.start) > 0.001}
            if !touched.isEmpty {
                let fullyExcluded=touched.contains {$0.start <= caption.start+0.001 && $0.end >= caption.end-0.001}
                if !fullyExcluded {return unscored("자막이 평가 제외 경계에 걸립니다. 문구를 추측 분할하지 않고 이 실행의 채점을 보류합니다.",revision:ref.revisionID)}
                events.append(AccuracyEvent(kind:"excludedCaption",captionIndex:index,start:caption.start,end:caption.end,text:caption.text));continue
            }
            eligible.append(caption)
            if nonspeech.contains(where:{$0.start <= caption.start+0.001 && $0.end >= caption.end-0.001}) {
                events.append(AccuracyEvent(kind:"captionInReviewedNonspeech",captionIndex:index,start:caption.start,end:caption.end,text:caption.text))
            }
        }
        let speechSeconds=speech.reduce(0){$0+$1.end-$1.start},nonspeechSeconds=nonspeech.reduce(0){$0+$1.end-$1.start},excludedSeconds=excluded.reduce(0){$0+$1.end-$1.start}
        guard speechSeconds+nonspeechSeconds > 0 else {return unscored("구간 전체가 평가 제외입니다.",revision:ref.revisionID)}
        var metrics=AccuracyMetrics(status:speech.isEmpty ? "nonspeech_control":"scored",referenceRevision:ref.revisionID,falsePositiveCaptions:events.filter {$0.kind == "captionInReviewedNonspeech"}.count,reviewedSpeechSeconds:speechSeconds,reviewedNonspeechSeconds:nonspeechSeconds,excludedSeconds:excludedSeconds,events:events)
        if let vadRegions, !speech.isEmpty {
            guard vadRegions.allSatisfy({$0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= ref.sourceStart-0.001 && $0.upperBound <= ref.sourceEnd+0.001}) else {return unscored("VAD 후보 범위가 원본과 다릅니다.",revision:ref.revisionID)}
            let merged=union(vadRegions.map {($0.lowerBound,$0.upperBound)})
            let covered=speech.reduce(0.0) {sum,span in sum+merged.reduce(0.0){$0+max(0,min(span.end,$1.1)-max(span.start,$1.0))}}
            metrics.vadSpeechDurationRecall=min(1,max(0,covered/speechSeconds))
        }
        guard !speech.isEmpty else {return AccuracyEvaluation(metrics:metrics,transcriptReport:nil)}
        let units=speech.map {TranscriptReference.Unit(text:$0.text,start:$0.start,end:$0.end)}
        var report=try TranscriptEvaluation.evaluate(captions:eligible,reference:TranscriptReference(url:referenceURL,units:units),language:ref.language,sourceRange:ref.sourceStart...ref.sourceEnd,mediaDuration:ref.sourceEnd,progress:progress)
        guard report.status == .scored else {return unscored(report.reason ?? "정답 비교 불가",revision:ref.revisionID)}
        if !ref.timingReviewed {report.timing=nil}
        metrics.cer=report.cer;metrics.wer=report.wer;metrics.matchedReferenceShare=Double(report.matchedSentences)/Double(report.referenceSentences);metrics.missingSentences=report.missing.count;metrics.alignmentLimited=report.alignmentApproximate
        metrics.startErrorP50=report.timing?.medianAbsoluteStart;metrics.startErrorP95=report.timing?.p95AbsoluteStart;metrics.endErrorP50=report.timing?.medianAbsoluteEnd;metrics.endErrorP95=report.timing?.p95AbsoluteEnd
        for missing in report.missing {
            if let span=speech.first(where:{$0.start == missing.start && $0.text == missing.text}) {metrics.events.append(AccuracyEvent(kind:"missingReferenceSpeech",referenceSpanID:span.id,start:span.start,end:span.end,text:span.text))}
        }
        return AccuracyEvaluation(metrics:metrics,transcriptReport:report)
    }
    private static func union(_ ranges:[(Double,Double)]) -> [(Double,Double)] {
        var result:[(Double,Double)]=[]
        for range in ranges.sorted(by:{$0.0 < $1.0}) {
            if let last=result.last,range.0 <= last.1 {result[result.count-1].1=max(last.1,range.1)} else {result.append(range)}
        }
        return result
    }
    /// Recommended provisional gate; small samples and limited alignment always require review.
    public static func regression(baseline:AccuracyMetrics,candidate:AccuracyMetrics,identityMatches:Bool) -> String {
        guard identityMatches,baseline.referenceRevision == candidate.referenceRevision,baseline.status == candidate.status,baseline.status == "scored",
              let bc=baseline.cer,let cc=candidate.cer,let bw=baseline.wer,let cw=candidate.wer,
              let br=baseline.matchedReferenceShare,let cr=candidate.matchedReferenceShare,
              [bc,cc,bw,cw,br,cr].allSatisfy({$0.isFinite && $0 >= 0}),(0...1).contains(br),(0...1).contains(cr) else {return "unscored_or_incompatible"}
        if cc-bc > 0.02+1e-12 || cw-bw > 0.02+1e-12 || br-cr > 0.01+1e-12 {return "hold_regression"}
        if baseline.alignmentLimited == true || candidate.alignmentLimited == true || (candidate.reviewedSpeechSeconds ?? 0) < 60 {return "review_small_sample_or_alignment"}
        return "within_provisional_limits"
    }
}

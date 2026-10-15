import Foundation

/// Carries the exact same metrics as the dataset CLI. Review flags are human declarations.
public struct HumanReferenceAssessment: Codable, Sendable, Equatable {
    public var state: String
    public var metrics: AccuracyMetrics
    public var referenceSHA256: String
    public var sourceSHA256: String
    public var reviewer: String?
    public var timingReason: String
}

public enum HumanReferenceEvaluation {
    public static func evaluate(referenceURL: URL, mediaURL: URL, sourceFile: String,
                                range: ClosedRange<Double>, mediaDuration: Double, language: String,
                                captions: [EvaluatedCaption],
                                progress: (@Sendable (EvaluationProgress) -> Void)? = nil) async throws -> TranscriptEvaluationReport {
        try Task.checkCancellation()
        progress?(EvaluationProgress(fraction:0,phase:"원본 전체 SHA 확인"))
        let loaded = try AccuracyReference.load(referenceURL)
        let hash = try await MediaFingerprintCache.shared.sha256(of:mediaURL)
        try Task.checkCancellation()
        return try evaluateLoaded(reference:loaded.reference,referenceSHA256:loaded.sha256,referenceURL:referenceURL,
                                  sourceFile:sourceFile,sourceSHA256:hash,range:range,mediaDuration:mediaDuration,
                                  language:language,captions:captions,progress:progress)
    }

    /// The caller supplies independently verified source identity; no cropping/rebasing of truth.
    public static func evaluateLoaded(reference: AccuracyReference, referenceSHA256: String, referenceURL: URL,
                                      sourceFile: String, sourceSHA256: String, range: ClosedRange<Double>,
                                      mediaDuration: Double, language: String, captions: [EvaluatedCaption],
                                      progress: (@Sendable (EvaluationProgress) -> Void)? = nil) throws -> TranscriptEvaluationReport {
        guard range.lowerBound.isFinite,range.upperBound.isFinite,mediaDuration.isFinite,
              range.lowerBound >= 0,range.upperBound > range.lowerBound,range.upperBound <= mediaDuration+0.000001,
              !reference.segmentID.isEmpty,reference.segmentID.utf8.count <= 256,
              RecognitionCacheSafety.hashIsValid(referenceSHA256) else { throw ProjectError("검수 정답의 원본 범위·식별자를 확인하세요.") }
        try reference.validate(segmentID:reference.segmentID,file:sourceFile,sha256:sourceSHA256,
                               start:range.lowerBound,end:range.upperBound)
        if reference.humanReviewed,reference.spans.contains(where:{$0.kind == .speech}),reference.language != language {
            throw ProjectError("검수 정답의 언어가 선택 원문의 언어와 다릅니다. 원문 언어를 확인하고 지정하세요.")
        }
        let result = try AccuracyDataset.evaluate(reference:reference,referenceURL:referenceURL,
                                                  captions:captions,vadRegions:nil,progress:progress)
        var report = result.transcriptReport ?? .unscored(result.metrics.reason ?? "비발화 대조군 · CER/WER 정의 없음",
                                                         language:reference.language,captions:captions.count,range:range,reference:referenceURL)
        let timingReason: String
        if !reference.humanReviewed { timingReason = "사람 검수 대기" }
        else if !reference.timingReviewed { timingReason = "텍스트·발화 구간만 검수 · 대사 시작/끝 시각 미검수" }
        else if report.timing == nil { timingReason = "시간 검수됨 · 대응한 발화가 없어 시간 오차 계산 불가" }
        else { timingReason = "사람이 대사 시작/끝을 검수했다고 선언함" }
        report.humanReference = HumanReferenceAssessment(state:reference.humanReviewed ? result.metrics.status : "pending",
                                                         metrics:result.metrics,referenceSHA256:referenceSHA256,
                                                         sourceSHA256:sourceSHA256,reviewer:reference.reviewer,timingReason:timingReason)
        return report
    }
}

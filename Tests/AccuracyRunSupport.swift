import Foundation
@testable import JHCutCore

struct AccuracyRunRecord: Codable {
    var schemaVersion = 1
    var segmentID: String
    var sourceFile: String
    var sourceSHA256: String
    var sourceStart: Double
    var sourceEnd: Double
    var referenceRevision: UUID
    var referenceSHA256: String
    var referenceState: String
    var referenceIssue: String?
    var modelSHA256: String
    var runtimeSHA256: String
    var coreSHA256: String
    var pipeline: String
    var optionsSHA256: String
    var audioSelection: AudioChannelSelection?
    var mode: String
    var trial: Int
    var metricPolicy: String
    var identitySHA256: String
    var outputSHA256: String
    var languageDetected: String
    var wallSeconds: Double
    var vadSeconds: Double?
    var inputForwardedSeconds: Double
    var metrics: AccuracyMetrics
    var regressionGate: String
    var baselineIdentity: String?
}
enum AccuracyRunSupport {
    static func digest<T:Encodable>(_ value:T) throws -> String {RecognitionCacheSafety.digest(try RecognitionCacheSafety.encoder().encode(value))}
    static func identity(source:String,start:Double,end:Double,referenceSHA:String,model:String,runtime:String,options:String,selection:AudioChannelSelection?,mode:String) throws -> String {
        // Builds may differ; corpus, reference, model, runtime, settings, channels and metrics stay fixed.
        let fields:[String:String]=["source":source,"range":String(start)+":"+String(end),"reference":referenceSHA,"model":model,"runtime":runtime,"options":options,"selection":try digest(selection),"mode":mode,"metricPolicy":AccuracyDataset.metricPolicy]
        return try digest(fields)
    }
    static func baseline(_ url:URL?) throws -> [AccuracyRunRecord] {
        guard let url else {return []}
        let data=try RecognitionCacheSafety.read(url,maximum:16_000_000)
        guard let rows=try JSONSerialization.jsonObject(with:data) as? [Any],rows.count <= 5_000 else {throw ProjectError("정확도 기준선 형식·행 수를 확인하세요.")}
        let records=try RecognitionCacheSafety.decoder().decode([AccuracyRunRecord].self,from:data)
        for record in records {
            try Task.checkCancellation()
            let expected=try identity(source:record.sourceSHA256,start:record.sourceStart,end:record.sourceEnd,referenceSHA:record.referenceSHA256,model:record.modelSHA256,runtime:record.runtimeSHA256,options:record.optionsSHA256,selection:record.audioSelection,mode:record.mode)
            guard record.schemaVersion == 1,record.metricPolicy == AccuracyDataset.metricPolicy,record.identitySHA256 == expected,record.referenceRevision == record.metrics.referenceRevision,
                  record.sourceStart.isFinite,record.sourceEnd.isFinite,record.sourceEnd > record.sourceStart,record.wallSeconds.isFinite,record.wallSeconds >= 0,
                  record.inputForwardedSeconds.isFinite,record.inputForwardedSeconds >= 0,record.inputForwardedSeconds <= record.sourceEnd-record.sourceStart+0.001 else {throw ProjectError("기준선의 정답 버전·입력·지표 연결이 일치하지 않습니다.")}
        }
        return records
    }
}

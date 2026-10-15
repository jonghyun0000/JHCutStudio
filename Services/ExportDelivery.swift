import Foundation
import CryptoKit

public enum ExportPhase:String,Codable,Sendable {case sources, movie, movieReady, moviePublished, subtitles, quality, report, finished}
public enum ExportArtifactState:String,Codable,Sendable {case waiting,running,published,completed,notRequested,failed,cancelled}
public struct ExportSourceIdentity:Codable,Equatable,Sendable {
    public var path:String
    public var sha256:String
}
public struct ExportDeliveryReceipt:Codable,Sendable {
    public var jobID:UUID
    public var projectSHA256:String
    public var destination:String
    public var sources:[ExportSourceIdentity]=[]
    public var movieSHA256:String?
    public var movie:ExportArtifactState = .waiting
    public var subtitles:ExportArtifactState = .notRequested
    public var quality:ExportArtifactState = .waiting
    public var report:ExportArtifactState = .waiting
    public var qaResult:OutputCheckStatus?
    public var subtitleURL:String?
    public var reportURL:String?
    public var errors:[String]=[]
    public init(jobID:UUID,project:Project,destination:URL)throws {
        self.jobID=jobID;self.destination=destination.path
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        projectSHA256=Self.digest(try encoder.encode(project))
    }
    public static func digest(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    public static func capture(project:Project,baseURL:URL?)async throws->[ExportSourceIdentity] {
        let used=Set(project.sequence.tracks.filter{!$0.isHidden}.flatMap(\.clips).filter{$0.captionHidden != true}.compactMap(\.assetID))
        var result:[ExportSourceIdentity]=[]
        for asset in project.assets.filter({used.contains($0.id)}).sorted(by:{$0.id.uuidString<$1.id.uuidString}) {
            let url=asset.resolvedURL(relativeTo:baseURL);let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
            result.append(ExportSourceIdentity(path:url.path,sha256:try await FileIdentity.sha256(url)))
        }
        return result
    }
    public static func validate(_ sources:[ExportSourceIdentity])async throws {
        for source in sources {
            let url=URL(fileURLWithPath:source.path);let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
            guard try await FileIdentity.sha256(url)==source.sha256 else{throw ProjectError("출력 중 원본이 변경되었습니다: \(url.lastPathComponent) · 결과를 게시하지 않았습니다.")}
        }
    }
}
public struct OutputReportManifest:Codable,Sendable {
    public var publicationID:UUID
    public var jobID:UUID?
    public var jsonSHA256:String
    public var markdownSHA256:String
}

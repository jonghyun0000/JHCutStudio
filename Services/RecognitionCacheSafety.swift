import Foundation
import CryptoKit
import Darwin

/// Bounds apply before decoding disk data and before constructing ranges or doing time arithmetic.
enum RecognitionCacheSafety {
    static let maximumDuration = 86_400.0
    static let maximumStart = 31_536_000.0
    static let maximumWindows = 2_880
    static let maximumCues = 10_000
    static let maximumLoadedCues = 100_000
    static let maximumLoadedWindowBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumSegments = 131_072
    static let maximumRegions = 65_536
    static let manifestBytes = 65_536
    static let windowBytes = 4 * 1_024 * 1_024
    static let activityBytes = 24 * 1_024 * 1_024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    static func hashIsValid(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func array<T: Decodable>(_ type: T.Type, key: String, decoder: Decoder, maximum: Int) throws -> [T] {
        let c = try decoder.container(keyedBy: CacheField.self)
        var values = try c.nestedUnkeyedContainer(forKey: CacheField(stringValue:key)!)
        if let count = values.count, count > maximum { throw ProjectError("인식 캐시 배열이 허용 크기를 넘습니다.") }
        var result: [T] = []
        while !values.isAtEnd {
            guard result.count < maximum else { throw ProjectError("인식 캐시 배열이 허용 크기를 넘습니다.") }
            result.append(try values.decode(T.self))
        }
        return result
    }
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    /// Reads a regular file through one descriptor; symlinks and oversized files are refused.
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ProjectError("인식 캐시 파일을 읽을 수 없습니다.") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= Int64(maximum) else { throw ProjectError("인식 캐시 파일 크기·형식이 올바르지 않습니다.") }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        var after = stat()
        guard fstat(fd,&after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, data.count == Int(before.st_size) else { throw ProjectError("읽는 중 인식 캐시가 바뀌었습니다.") }
        return data
    }
    static func directoryIsSafe(_ url: URL) -> Bool { var s = stat(); return lstat(url.path,&s) == 0 && s.st_mode & S_IFMT == S_IFDIR }
}
private struct CacheField: CodingKey { var stringValue:String; var intValue:Int? { nil }; init?(stringValue:String) { self.stringValue=stringValue }; init?(intValue:Int) { return nil } }

/// Payload checksum catches partial/corrupted writes; key binding prevents cross-source reuse.
/// This is integrity checking, not a signature against someone deliberately rewriting all fields.
struct RecognitionCacheEnvelope: Codable {
    var version = 1
    var keyIdentifier: String
    var checksum: String
    var payload: Data
    static func encode<T: Encodable>(_ value: T, key: TranscriptionCheckpointKey, maximum: Int) throws -> Data {
        let payload = try RecognitionCacheSafety.encoder().encode(value)
        let result = try RecognitionCacheSafety.encoder().encode(Self(keyIdentifier:key.identifier,checksum:RecognitionCacheSafety.digest(payload),payload:payload))
        guard result.count <= maximum else { throw ProjectError("인식 캐시가 허용 파일 크기를 넘습니다.") }
        return result
    }
    static func decode<T: Decodable>(_ type: T.Type, data: Data, key: TranscriptionCheckpointKey) throws -> T {
        let envelope = try RecognitionCacheSafety.decoder().decode(Self.self,from:data)
        guard envelope.version == 1, envelope.keyIdentifier == key.identifier, envelope.checksum == RecognitionCacheSafety.digest(envelope.payload) else { throw ProjectError("인식 캐시의 무결성 또는 원본 설정이 다릅니다.") }
        return try RecognitionCacheSafety.decoder().decode(type,from:envelope.payload)
    }
}

public struct TranscriptionCachePolicy: Sendable {
    public var maximumBytes: Int64 = 512 * 1_024 * 1_024
    public var maximumFolders = 128
    public var completedRetentionDays: Double = 30
    public var unfinishedRetentionDays: Double = 90
    public var quarantineBytes: Int64 = 32 * 1_024 * 1_024
    public var quarantineFiles = 32
    public init() {}
}
public struct TranscriptionCacheMaintenance: Sendable {
    public var removedFolders = 0
    public var remainingBytes: Int64 = 0
    public var protectedFolders = 0
}
/// A kernel-held exclusive lease, automatically released on completion, cancel or process exit.
/// Separate keys can run together; the same key cannot race another recognition session.
public final class TranscriptionCacheLease: @unchecked Sendable {
    private var descriptor: Int32
    private let root: String
    private let key: String
    private let lock = NSLock()
    init(_ descriptor: Int32, root: String, key: String) { self.descriptor = descriptor; self.root = root; self.key = key }
    func matches(store: TranscriptionCheckpointStore, key: TranscriptionCheckpointKey) -> Bool { lock.lock(); defer { lock.unlock() }; return descriptor >= 0 && root == store.root.path && self.key == key.identifier }
    public func finish() { lock.lock(); defer { lock.unlock() }; if descriptor >= 0 { flock(descriptor,LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { finish() }
}

public enum TranscriptionCacheError: LocalizedError {
    case activeSession
    public var errorDescription: String? { "같은 영상·설정의 인식 작업이 이미 실행 중입니다." }
}
struct RecognitionInputSignature: Codable {
    struct Region: Codable { var start: Double; var end: Double }
    var regions: [Region]?
    var evidence: [Region]?
    var selection: AudioChannelSelection?
    static func make(regions: [ClosedRange<Double>]?, evidence: [ClosedRange<Double>]?, selection: AudioChannelSelection?) throws -> String {
        let value = Self(regions:regions?.map { Region(start:$0.lowerBound,end:$0.upperBound) },evidence:evidence?.map { Region(start:$0.lowerBound,end:$0.upperBound) },selection:selection)
        return RecognitionCacheSafety.digest(try RecognitionCacheSafety.encoder().encode(value))
    }
}

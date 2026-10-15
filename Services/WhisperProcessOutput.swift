import Foundation
import CoreFoundation
import Darwin

/// Safe to surface in the editor or a verification log. Neither the error nor its description
/// contains subprocess arguments, media paths, glossary text, captions, or raw stderr.
public struct WhisperTranscriptionError: LocalizedError, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case launchFailed, processFailed, timedOut
        case srtMissing, srtUnreadable, srtInvalid
        case jsonMissing, jsonUnreadable, jsonInvalid, outputMismatch
    }
    public let code: Code
    public let diagnosticID: UUID
    public let diagnosticSaved: Bool
    public var errorDescription: String? {
        let message: String
        switch code {
        case .launchFailed: message = "로컬 음성 인식 프로그램을 실행하지 못했습니다."
        case .processFailed: message = "로컬 음성 인식 프로그램이 정상적으로 완료되지 않았습니다."
        case .timedOut: message = "언어 확인 시간 예산을 초과했습니다."
        case .srtMissing: message = "음성 인식 프로그램이 종료됐지만 요청한 SRT 자막 파일이 생성되지 않았습니다."
        case .srtUnreadable: message = "생성된 SRT 자막 파일을 안전하게 읽지 못했습니다."
        case .srtInvalid: message = "생성된 SRT 자막 파일의 형식이 올바르지 않습니다."
        case .jsonMissing: message = "음성 인식 프로그램이 종료됐지만 요청한 JSON 결과 파일이 생성되지 않았습니다."
        case .jsonUnreadable: message = "생성된 JSON 인식 결과를 안전하게 읽지 못했습니다."
        case .jsonInvalid: message = "생성된 JSON 인식 결과의 형식 또는 언어 정보가 올바르지 않습니다."
        case .outputMismatch: message = "SRT 자막과 JSON 인식 결과가 일치하지 않아 적용하지 않았습니다."
        }
        return message + (diagnosticSaved ? " 로컬 진단 ID: " : " 로컬 진단 저장 실패 · ID: ") + diagnosticID.uuidString
    }
    public var description: String { errorDescription ?? code.rawValue }
}

/// Raw stderr is intentionally not Codable or part of the public error. Some Whisper versions
/// print recognised text, model paths and prompts there. Only the in-memory acoustic parser uses it.
struct WhisperProcessResult: Sendable {
    enum Reason: String, Codable, Sendable { case exit, uncaughtSignal, launchFailure }
    let status: Int32?
    let reason: Reason
    let timedOut: Bool
    let elapsedSeconds: Double
    let stderrTail: String
    let launchErrorDomain: String?
    let launchErrorCode: Int?
}

enum WhisperOutputContract {
    struct Output: Sendable {
        let cues: [CaptionCue]
        let language: String
    }
    private struct Segment: Equatable {
        let start: MediaTime
        let end: MediaTime
        let text: String
    }
    private enum InvalidOutput: Error { case invalid }
    static let maximumOutputBytes = 16 * 1_024 * 1_024

    /// The exact path used in production, also exercised with a controlled subprocess in tests.
    /// No automatic retry and no missing-output-to-empty-success fallback is permitted here.
    static func recognize(executable: URL, arguments: [String], directory: URL, prefix: URL,
                          timeout: Double? = nil, diagnosticDirectory: URL? = nil,
                          progress: (@Sendable (Double?) -> Void)?) async throws -> Output {
        let result = try await LocalTranscription.execute(executable: executable, arguments: arguments,
            directory: directory, timeout: timeout, progress: progress)
        try Task.checkCancellation()
        try requireProcessSuccess(result, phase: "recognition", directory: directory,
            prefix: prefix, diagnosticDirectory: diagnosticDirectory)
        func fail(_ code: WhisperTranscriptionError.Code) -> WhisperTranscriptionError {
            failure(code, result: result, phase: "recognition", directory: directory,
                prefix: prefix, diagnosticDirectory: diagnosticDirectory)
        }
        let srtData: Data, jsonData: Data
        do { srtData = try readRegularFile(prefix.appendingPathExtension("srt")) }
        catch is CancellationError { throw CancellationError() }
        catch ReadFailure.missing { throw fail(.srtMissing) }
        catch { throw fail(.srtUnreadable) }
        do { jsonData = try readRegularFile(prefix.appendingPathExtension("json")) }
        catch is CancellationError { throw CancellationError() }
        catch ReadFailure.missing { throw fail(.jsonMissing) }
        catch { throw fail(.jsonUnreadable) }
        try Task.checkCancellation()

        // Whisper can split a multibyte character at a segment boundary. Keep the established
        // lenient byte decoding, but require complete JSON and matching segments in both files.
        let srt = clean(String(decoding: srtData, as: UTF8.self))
        let jsonText = clean(String(decoding: jsonData, as: UTF8.self))
        let jsonSegments: [Segment], language: String
        do { (jsonSegments, language) = try decodeJSON(jsonText) }
        catch { throw fail(.jsonInvalid) }
        let srtSegments: [Segment]
        do { srtSegments = try decodeSRT(srt) }
        catch { throw fail(.srtInvalid) }
        guard srtSegments == jsonSegments else { throw fail(.outputMismatch) }
        // An empty SRT is accepted only with a structurally valid JSON result containing no
        // segments. Empty text segments, if present in both outputs, retain the existing parser
        // behaviour. Neither state is a measurement of whether the original audio had speech.
        let parsed = SRTCodec.parseRecognizerOutput(srt)
        try Task.checkCancellation()
        return Output(cues: parsed.cues, language: language)
    }

    static func requireProcessSuccess(_ result: WhisperProcessResult, phase: String, directory: URL,
                                      prefix: URL? = nil, diagnosticDirectory: URL? = nil) throws {
        let code: WhisperTranscriptionError.Code?
        if result.reason == .launchFailure { code = .launchFailed }
        else if result.timedOut { code = .timedOut }
        else if result.status != 0 || result.reason != .exit { code = .processFailed }
        else { code = nil }
        if let code { throw failure(code, result: result, phase: phase, directory: directory,
            prefix: prefix, diagnosticDirectory: diagnosticDirectory) }
    }

    private static func clean(_ text: String) -> String { text.replacingOccurrences(of: "\u{FFFD}", with: "") }
    private static func decodeJSON(_ text: String) throws -> ([Segment], String) {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any], let language = result["language"] as? String,
              language.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil, language != "auto",
              let records = object["transcription"] as? [[String: Any]] else { throw InvalidOutput.invalid }
        let segments = try records.map { record -> Segment in
            guard let body = record["text"] as? String, let offsets = record["offsets"] as? [String: Any],
                  let first = integer(offsets["from"]), let last = integer(offsets["to"]),
                  first >= 0, last >= first else { throw InvalidOutput.invalid }
            return Segment(start: MediaTime(first, 1_000), end: MediaTime(last, 1_000),
                text: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (segments, language)
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return Int64(exactly: number.doubleValue)
    }
    private static func decodeSRT(_ text: String) throws -> [Segment] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let separator = try NSRegularExpression(pattern: #"\n[ \t]*\n+"#)
        let blocks = separator.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\u{001E}").components(separatedBy: "\u{001E}")
        return try blocks.map { block in
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 2, let number = Int(lines[0].trimmingCharacters(in: .whitespaces)), number > 0 else { throw InvalidOutput.invalid }
            let times = lines[1].components(separatedBy: "-->")
            guard times.count == 2 else { throw InvalidOutput.invalid }
            let first = try time(times[0]), last = try time(times[1])
            guard last >= first else { throw InvalidOutput.invalid }
            return Segment(start: first, end: last, text: lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    private static func time(_ value: String) throws -> MediaTime {
        let fields = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
            .components(separatedBy: CharacterSet(charactersIn: ":,"))
        guard fields.count == 4, fields[0].count >= 2, fields[1].count == 2, fields[2].count == 2, fields[3].count == 3,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hours = Int64(fields[0]), let minutes = Int64(fields[1]), let seconds = Int64(fields[2]), let milliseconds = Int64(fields[3]),
              minutes < 60, seconds < 60 else { throw InvalidOutput.invalid }
        let hourPart = hours.multipliedReportingOverflow(by: 3_600_000)
        let total = hourPart.partialValue.addingReportingOverflow(minutes * 60_000 + seconds * 1_000 + milliseconds)
        guard !hourPart.overflow, !total.overflow else { throw InvalidOutput.invalid }
        return MediaTime(total.partialValue, 1_000)
    }

    private enum ReadFailure: Error { case missing, unreadable }
    /// O_NONBLOCK prevents a malformed FIFO output from hanging recognition; O_NOFOLLOW refuses
    /// a symlink. Check the opened inode, enforce a size bound and detect concurrent truncation.
    private static func readRegularFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw errno == ENOENT ? ReadFailure.missing : ReadFailure.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumOutputBytes) else { throw ReadFailure.unreadable }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ReadFailure.unreadable }
            if count == 0 { break }
            guard data.count <= maximumOutputBytes - count else { throw ReadFailure.unreadable }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Int64(data.count) == info.st_size, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw ReadFailure.unreadable }
        return data
    }

    private static func failure(_ code: WhisperTranscriptionError.Code, result: WhisperProcessResult,
                                phase: String, directory: URL, prefix: URL?, diagnosticDirectory: URL?) -> WhisperTranscriptionError {
        let id = UUID()
        let receipt = Diagnostic(schemaVersion: 1, diagnosticID: id, createdAt: Date(), code: code,
            phase: phase, processStatus: result.status, terminationReason: result.reason,
            timedOut: result.timedOut, elapsedSeconds: result.elapsedSeconds,
            launchErrorDomain: result.launchErrorDomain, launchErrorCode: result.launchErrorCode,
            stderrTail: diagnosticTail(result.stderrTail), rawStderrRetained: false,
            srt: prefix.map { metadata($0.appendingPathExtension("srt")) },
            json: prefix.map { metadata($0.appendingPathExtension("json")) },
            extractedAudio: metadata(directory.appendingPathComponent("source.wav")))
        let saved = (try? writeDiagnostic(receipt, directory: diagnosticDirectory ?? defaultDiagnosticDirectory)) != nil
        return WhisperTranscriptionError(code: code, diagnosticID: id, diagnosticSaved: saved)
    }
    struct FileMetadata: Codable {
        let kind: String
        let bytes: Int64?
    }
    struct Diagnostic: Codable {
        let schemaVersion: Int
        let diagnosticID: UUID
        let createdAt: Date
        let code: WhisperTranscriptionError.Code
        let phase: String
        let processStatus: Int32?
        let terminationReason: WhisperProcessResult.Reason
        let timedOut: Bool
        let elapsedSeconds: Double
        let launchErrorDomain: String?
        let launchErrorCode: Int?
        let stderrTail: String
        let rawStderrRetained: Bool
        let srt: FileMetadata?
        let json: FileMetadata?
        let extractedAudio: FileMetadata
    }
    private static func metadata(_ url: URL) -> FileMetadata {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return FileMetadata(kind: errno == ENOENT ? "missing" : "unavailable", bytes: nil) }
        let kind: String
        switch info.st_mode & S_IFMT { case S_IFREG: kind = "regular"; case S_IFDIR: kind = "directory"; case S_IFLNK: kind = "symlink"; default: kind = "other" }
        return FileMetadata(kind: kind, bytes: Int64(info.st_size))
    }
    /// Allowlist semantic categories, not substitutions on free-form text: a path or spoken text
    /// without quotation marks must still never leak. This retains the two known exit-0 failure
    /// branches while deliberately redacting all unrecognised lines. It is a bounded tail.
    static func diagnosticTail(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines).suffix(64).filter { !$0.isEmpty }
        return lines.map { line -> String in
            let lower = line.lowercased()
            if lower.contains("failed to read audio file") || lower.contains("failed to read wav") { return "inputAudioReadFailed" }
            if lower.contains("failed to open") && lower.contains("for writing") { return "outputOpenFailed" }
            if lower.contains("failed to load model") || lower.contains("failed to initialize whisper") { return "modelInitializationFailed" }
            if lower.contains("failed to allocate") || lower.contains("out of memory") { return "allocationFailed" }
            if lower.contains("saving output to") { return "outputWriteStarted" }
            if lower.contains("auto-detected language"), let language = SourceLanguageAnalysis.acousticResult(log: line) {
                return "detectedLanguage=\(language.language) probability=\(language.probability)"
            }
            if lower.contains("progress") {
                let pieces = line.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                if let percent = pieces.compactMap(Int.init).last, (0...100).contains(percent) { return "progress=\(percent)%" }
            }
            return "[redacted diagnostic line]"
        }.joined(separator: "\n")
    }
    static var defaultDiagnosticDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("JHCutStudio/Diagnostics/Transcription", isDirectory: true)
    }
    private static func writeDiagnostic(_ diagnostic: Diagnostic, directory: URL) throws {
        guard directory.isFileURL else { throw ReadFailure.unreadable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(diagnostic)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ReadFailure.unreadable }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == geteuid(), fchmod(directoryFD, 0o700) == 0,
              fstat(directoryFD, &info) == 0, info.st_mode & 0o777 == 0o700 else { throw ReadFailure.unreadable }
        let name = "transcription-\(diagnostic.diagnosticID.uuidString).json"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReadFailure.unreadable }
        defer { close(fd) }
        do {
            // A filesystem may accept chmod while ignoring Unix modes (for example ExFAT).
            // Do not report a private diagnostic as saved unless the opened inode confirms it.
            var fileInfo = stat()
            guard fchmod(fd, 0o600) == 0, fstat(fd, &fileInfo) == 0,
                  fileInfo.st_uid == geteuid(), fileInfo.st_mode & S_IFMT == S_IFREG,
                  fileInfo.st_mode & 0o777 == 0o600 else { throw ReadFailure.unreadable }
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 { if errno == EINTR { continue }; throw ReadFailure.unreadable }
                    guard count > 0 else { throw ReadFailure.unreadable }
                    written += count
                }
            }
            guard fsync(fd) == 0 else { throw ReadFailure.unreadable }
        } catch { unlinkat(directoryFD, name, 0); throw error }
    }
}

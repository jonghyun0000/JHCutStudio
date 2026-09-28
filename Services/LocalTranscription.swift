import Foundation
@preconcurrency import AVFoundation
import CryptoKit
import Speech
import Darwin

public struct WhisperModelSpec: Codable, Sendable {
    public let name: String
    public let fileName: String
    public let downloadURL: URL
    public let byteCount: Int64
    public let sha256: String
    public let license: String
    public let licenseURL: URL
    public let recommendedFreeBytes: Int64
    public static let base = WhisperModelSpec(name: "Whisper base · 다국어 (한·일·영)", fileName: "ggml-base.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin")!,
        byteCount: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        license: "MIT", licenseURL: URL(string: "https://github.com/openai/whisper/blob/main/LICENSE")!, recommendedFreeBytes: 400_000_000)
    public static let small = WhisperModelSpec(name: "Whisper small · 다국어", fileName: "ggml-small.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin")!,
        byteCount: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        license: "MIT", licenseURL: URL(string: "https://github.com/openai/whisper/blob/main/LICENSE")!, recommendedFreeBytes: 1_100_000_000)

}
public struct WhisperConfiguration: Sendable {
    public let runtimeURL: URL
    public let modelURL: URL
    public let modelSpec: WhisperModelSpec
    public init(runtimeURL: URL? = nil, modelURL: URL? = nil, modelSpec: WhisperModelSpec = .base) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Whisper/whisper-cli")
        self.runtimeURL = runtimeURL ?? ((bundled.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true) ? bundled! : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Whisper/whisper-cli"))
        self.modelSpec = modelSpec
        self.modelURL = modelURL ?? Self.defaultModelURL.deletingLastPathComponent().appendingPathComponent(modelSpec.fileName)
    }
    public static var defaultModelURL: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("JHCutStudio/Models/ggml-base.bin")
    }
}
public struct LocalTranscriptionAvailability: Codable, Sendable {
    public let canTranscribe: Bool
    public let message: String
    public let runtimeURL: URL
    public let modelURL: URL
}
public struct LocalTranscript: Codable, Sendable {
    /// Absolute SOURCE positions, not clip-relative or timeline positions. Map through playbackRate in the editor.
    public let cues: [CaptionCue]
    public let engine: String
    public let language: String
    public let sourceStart: MediaTime
    public let duration: MediaTime
    public let elapsedSeconds: Double
    /// Zero-based native channel with the greatest energy over the selected range. Channels are not phase-cancelled by downmixing.
    public let sourceChannelIndex: Int
    /// The repetition guard re-ran Whisper without text conditioning for this result.
    public var repetitionRetried: Bool? = nil
    /// Captions dropped because they repeated the previous caption's text in a loop.
    public var repeatedCuesRemoved: Int? = nil
    /// Start times (source seconds) of captions kept from a collapsed loop; the editor flags them.
    public var repetitionSuspects: [Double]? = nil
    /// Speech stretches without captions that were recognised again on their own, and the captions that recovered.
    public var coverageRepairs: Int? = nil
    public var recoveredCues: Int? = nil
    /// Windows loaded from a checkpoint instead of being recognised again.
    public var reusedWindows: Int? = nil
    /// Windows actually sent to Whisper in this run.
    public var computedWindows: Int? = nil
    /// Windows not sent to Whisper because voice-activity analysis found no speech in them.
    public var skippedWindows: Int? = nil
    /// Per-window language votes, so a caller can distinguish a clip's dominant language from a
    /// minority language that appears only in some windows.
    public var windowLanguages: [String]? = nil
}

/// Live state of a long recognition run, for a progress line that names the current window and an
/// estimate that is based only on windows this run actually recognised.
public struct TranscriptionProgress: Sendable, Equatable {
    public var fraction: Double
    public var windowIndex: Int
    public var windowCount: Int
    public var reusedWindows: Int
    public var skippedWindows: Int
    public var windowSourceStart: Double
    public var elapsedSeconds: Double
    /// nil until at least one window has been recognised in this run; a resumed run must not
    /// extrapolate from instant checkpoint loads.
    public var estimatedRemainingSeconds: Double?
}
public enum WhisperModelInstaller {
    /// Explicit consent boundary. Call only from a user-approved model installation action; never at startup.
    public static func installBaseModel(approvedByUser: Bool, destination: URL? = nil) async throws -> URL {
        try await installModel(.base, approvedByUser: approvedByUser, destination: destination)
    }
    public static func installModel(_ spec: WhisperModelSpec, approvedByUser: Bool, destination: URL? = nil) async throws -> URL {
        guard approvedByUser else { throw AudioAnalysisError("모델 출처·MIT 라이선스·\(spec.byteCount)바이트·SHA-256을 확인하고 설치에 동의해야 합니다.") }
        let destination = destination ?? WhisperConfiguration(modelSpec: spec).modelURL
        guard destination.isFileURL else { throw AudioAnalysisError("모델 저장 위치는 로컬 폴더여야 합니다.") }
        if FileManager.default.fileExists(atPath: destination.path) { try verifyModel(at: destination, spec: spec); return destination }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= spec.recommendedFreeBytes else { throw AudioAnalysisError("모델 설치에 최소 \(spec.recommendedFreeBytes / 1_000_000)MB의 빈 공간이 필요합니다.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: spec.downloadURL); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (download, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AudioAnalysisError("모델 다운로드 응답이 올바르지 않습니다.") }
        try Task.checkCancellation(); try verifyModel(at: download, spec: spec)
        // Copy to same-volume staging, verify again, then rename. An existing destination is never overwritten.
        let staged = directory.appendingPathComponent(".jhcut-model-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: download, to: staged)
        try verifyModel(at: staged, spec: spec); try Task.checkCancellation()
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }
    public static func verifyModel(at url: URL, spec: WhisperModelSpec = .base) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == spec.byteCount else { throw AudioAnalysisError("다국어 모델 크기가 다릅니다. 승인된 \(spec.fileName)을 선택하세요 (.en 모델 사용 불가).") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty { try Task.checkCancellation(); hash.update(data: block) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == spec.sha256 else { throw AudioAnalysisError("모델 SHA-256 검증에 실패했습니다. 파일이 변조되었거나 다운로드가 불완전합니다.") }
    }
}
public struct SpeechOptions: Equatable, Sendable {
    public var language = "auto"
    public var channel = -1
    public var glossary = ""
    public var accurate = true
    public init() {}
}
public enum LocalTranscription {
    public static let engineVersion = "whisper.cpp v1.9.4"
    /// Everything after Whisper that changes results. Part of the checkpoint identity, so windows
    /// recognised by an older pipeline (before the stable decoder, repetition guard and coverage repair) are not reused.
    public static let pipelineVersion = engineVersion + " · pipeline 3"

    /// Recognizes long clips in bounded windows. Each window is independently cancellable;
    /// returned cue times remain absolute source times just like `transcribe`.
    ///
    /// With a `checkpoint`, every window is written to disk as soon as it finishes, and a later run
    /// with an identical key loads finished windows instead of recognising them again. Cancelling
    /// or quitting mid-run therefore loses at most the window in progress. With `speechRegions`
    /// (absolute source seconds), windows that contain no speech are recorded as empty without
    /// starting Whisper; the source audio itself is never modified.
    public static func transcribeLong(url: URL, sourceStart: MediaTime = .zero, duration: MediaTime,
                                      configuration: WhisperConfiguration = .init(), options: SpeechOptions = .init(),
                                      windowSeconds: Double = 300,
                                      checkpoint: TranscriptionCheckpointSession? = nil,
                                      speechRegions: [ClosedRange<Double>]? = nil,
                                      speechEvidence: [ClosedRange<Double>]? = nil,
                                      onCheckpointError: (@Sendable (Error) -> Void)? = nil,
                                      detail: (@Sendable (TranscriptionProgress) -> Void)? = nil,
                                      progress: (@Sendable (Double?) -> Void)? = nil) async throws -> LocalTranscript {
        guard duration > .zero, windowSeconds >= 30 else { throw AudioAnalysisError("긴 음성 인식 구간을 확인하세요.") }
        if duration.seconds <= windowSeconds, checkpoint == nil, speechRegions == nil {
            return try await transcribe(url: url, sourceStart: sourceStart, duration: duration, configuration: configuration, options: options, progress: progress)
        }
        if let checkpoint {
            guard checkpoint.key.sourceStart == sourceStart, checkpoint.key.duration == duration, checkpoint.key.windowSeconds == windowSeconds,
                  checkpoint.key.language == options.language, checkpoint.key.channel == options.channel,
                  checkpoint.key.glossary == options.glossary, checkpoint.key.accurate == options.accurate,
                  checkpoint.key.modelSHA256 == configuration.modelSpec.sha256, checkpoint.key.skipsSilence == (speechRegions != nil)
            else { throw AudioAnalysisError("체크포인트 설정이 이번 인식 요청과 다릅니다. 체크포인트를 삭제하고 다시 실행하세요.") }
        }
        let started = Date()
        let count = max(1, Int((duration.seconds / windowSeconds).rounded(.up)))
        let saved = checkpoint.map { $0.store.completedWindows(for: $0.key) } ?? [:]
        var windows: [TranscriptionWindowResult] = []
        var reused = 0, computed = 0, skipped = 0
        var computedSourceSeconds = 0.0, computedElapsed = 0.0
        var modelVerified = false
        let savedIndices = Set(saved.keys), total = duration.seconds
        // Pure snapshot → value. The Whisper progress callback runs on a pipe-reader thread, so it
        // receives copies of the counters instead of reading this loop's mutable state.
        struct Counters: Sendable { var reused = 0, skipped = 0, computed = 0; var sourceSeconds = 0.0, elapsed = 0.0 }
        // Work per window = the audio Whisper will actually hear: the speech seconds when skipping
        // non-speech, otherwise the window length. Recognition time follows this, not window length.
        let work: [Double] = (0..<count).map { index in
            let a = sourceStart.seconds + Double(index) * windowSeconds, b = min(sourceStart.seconds + duration.seconds, a + windowSeconds)
            guard let speechRegions else { return b - a }
            return speechRegions.reduce(0) { $0 + max(0, min(b, $1.upperBound) - max(a, $1.lowerBound)) }
        }
        @Sendable func report(_ index: Int, _ within: Double, _ windowStart: Double, _ c: Counters) {
            let fraction = min(1, (Double(index) + within) * windowSeconds / total)
            progress?(fraction)
            guard let detail else { return }
            // Estimate only from windows recognised in this run. Loaded and skipped windows are
            // instant and would make the remaining time look far shorter than it is.
            var remaining: Double? = nil
            if c.computed > 0, c.sourceSeconds > 0 {
                let rate = c.elapsed / c.sourceSeconds
                let left = (index..<count).filter { !savedIndices.contains($0) }.reduce(0.0) { $0 + work[$1] }
                remaining = max(0, (left - within * work[index]) * rate)
            }
            detail(TranscriptionProgress(fraction: fraction, windowIndex: index, windowCount: count, reusedWindows: c.reused, skippedWindows: c.skipped,
                                         windowSourceStart: windowStart, elapsedSeconds: Date().timeIntervalSince(started), estimatedRemainingSeconds: remaining))
        }
        var counters: Counters { Counters(reused: reused, skipped: skipped, computed: computed, sourceSeconds: computedSourceSeconds, elapsed: computedElapsed) }
        for index in 0..<count {
            try Task.checkCancellation()
            let offset = Double(index) * windowSeconds
            let length = min(windowSeconds, duration.seconds - offset)
            let windowStart = MediaTime(seconds: sourceStart.seconds + offset)
            report(index, 0, windowStart.seconds, counters)
            if let stored = saved[index] { windows.append(stored); reused += 1; report(index, 1, windowStart.seconds, counters); continue }
            // Only the speech parts of this window reach Whisper (relative to the window start).
            // The skip decision uses exactly these pieces, so a region touching the window by a few
            // milliseconds cannot pass the check and then leave compaction with nothing.
            let local = speechRegions.map { regions in
                regions.compactMap { r -> ClosedRange<Double>? in
                    let a = max(0, r.lowerBound - windowStart.seconds), b = min(length, r.upperBound - windowStart.seconds)
                    return b - a >= 0.05 ? a...b : nil
                }
            }
            if let local, local.isEmpty {
                // No speech candidate anywhere in this window: record it as empty without Whisper,
                // which also avoids the text Whisper tends to hallucinate over silence.
                let empty = TranscriptionWindowResult(index: index, sourceStart: windowStart, duration: MediaTime(seconds: length), cues: [],
                                                      language: "", channel: max(0, options.channel), elapsedSeconds: 0, skippedWithoutSpeech: true)
                windows.append(empty); skipped += 1
                if let checkpoint { do { try checkpoint.store.save(empty, for: checkpoint.key) } catch { onCheckpointError?(error) } }
                report(index, 1, windowStart.seconds, counters); continue
            }
            let begun = Date(), frozen = counters, windowStartSeconds = windowStart.seconds
            let result = try await transcribe(url: url, sourceStart: windowStart, duration: MediaTime(seconds: length), configuration: configuration,
                                              options: options, verifyModel: !modelVerified, speechRegions: local,
                                              speechEvidence: speechEvidence.map { e in e.compactMap { r -> ClosedRange<Double>? in
                                                  let a = max(0, r.lowerBound - windowStart.seconds), b = min(length, r.upperBound - windowStart.seconds)
                                                  return b > a ? a...b : nil } }) { fraction in
                guard let fraction else { progress?(nil); return }
                report(index, fraction, windowStartSeconds, frozen)
            }
            modelVerified = true
            var window = TranscriptionWindowResult(index: index, sourceStart: windowStart, duration: MediaTime(seconds: length), cues: result.cues,
                                                   language: result.language, channel: result.sourceChannelIndex, elapsedSeconds: Date().timeIntervalSince(begun))
            window.repeatedCuesRemoved = result.repeatedCuesRemoved; window.repetitionSuspects = result.repetitionSuspects
            window.coverageRepairs = result.coverageRepairs; window.recoveredCues = result.recoveredCues
            windows.append(window); computed += 1
            computedSourceSeconds += work[index]; computedElapsed += window.elapsedSeconds
            // Saved only after the window fully succeeded, and before the next one starts: a
            // cancellation or crash during the next window cannot lose this one.
            if let checkpoint { do { try checkpoint.store.save(window, for: checkpoint.key) } catch { onCheckpointError?(error) } }
            report(index, 1, windowStart.seconds, counters)
        }
        var allCues: [CaptionCue] = []
        var detected: [String: Int] = [:]
        var channel = max(0, options.channel)
        for window in windows.sorted(by: { $0.index < $1.index }) {
            let boundary = window.sourceStart.seconds + (window.index == 0 ? 0 : 0.5)
            allCues.append(contentsOf: window.cues.filter { $0.start.seconds >= boundary })
            if !window.language.isEmpty { detected[window.language, default: 0] += 1; channel = window.channel }
        }
        var unique: [CaptionCue] = []
        for cue in allCues.sorted(by: { $0.start < $1.start }) {
            if let previous = unique.last, abs(previous.start.seconds - cue.start.seconds) < 0.2 && previous.text == cue.text { continue }
            unique.append(cue)
        }
        guard let language = detected.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else {
            throw AudioAnalysisError("선택 구간에서 음성 후보를 찾지 못했습니다. 무음 건너뛰기를 끄거나 대사가 있는 구간을 선택하세요.")
        }
        var transcript = LocalTranscript(cues: unique, engine: "\(engineVersion) · 분할 인식", language: language,
                                         sourceStart: sourceStart, duration: duration, elapsedSeconds: Date().timeIntervalSince(started), sourceChannelIndex: channel)
        transcript.reusedWindows = reused; transcript.computedWindows = computed; transcript.skippedWindows = skipped
        let removed = windows.reduce(0) { $0 + ($1.repeatedCuesRemoved ?? 0) }, suspects = windows.flatMap { $0.repetitionSuspects ?? [] }.sorted()
        transcript.repeatedCuesRemoved = removed > 0 ? removed : nil; transcript.repetitionSuspects = suspects.isEmpty ? nil : suspects
        let repairs = windows.reduce(0) { $0 + ($1.coverageRepairs ?? 0) }, recoveredTotal = windows.reduce(0) { $0 + ($1.recoveredCues ?? 0) }
        transcript.coverageRepairs = repairs > 0 ? repairs : nil; transcript.recoveredCues = recoveredTotal > 0 ? recoveredTotal : nil
        transcript.windowLanguages = windows.sorted(by: { $0.index < $1.index }).map(\.language)
        return transcript
    }

    public static func previewChannel(url: URL, sourceStart: MediaTime, duration: MediaTime, channel: Int) async throws -> (data: Data, channel: Int) {
        guard duration > .zero, duration.seconds <= 10, (-1...31).contains(channel) else { throw AudioAnalysisError("미리듣기는 10초 이내의 유효한 채널을 선택하세요.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JHCutChannel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("preview.wav")
        var selected = 0
        _ = try await extractAudio(url: url, sourceStart: sourceStart, duration: duration, destination: file, preferredChannel: channel) { selected = $0 }
        return (try Data(contentsOf: file), selected)
    }
    /// Read-only. Does not install a model, access a microphone, request system permission, or start recognition.
    public static func availability(configuration: WhisperConfiguration = .init()) -> LocalTranscriptionAvailability {
        let fm = FileManager.default
        let runtime = fm.isExecutableFile(atPath: configuration.runtimeURL.path)
        let size = (try? fm.attributesOfItem(atPath: configuration.modelURL.path)[.size] as? NSNumber)?.int64Value
        let model = size == configuration.modelSpec.byteCount
        let message = !runtime ? "로컬 whisper.cpp 실행 파일이 없습니다." : !model ? "선택한 다국어 모델 설치가 필요합니다. 설치 전 출처·용량·해시 확인 및 동의가 필요합니다." : "로컬 whisper.cpp 준비됨 · 실행 전 SHA-256 검증 · 음성 업로드 없음"
        return LocalTranscriptionAvailability(canTranscribe: runtime && model, message: message, runtimeURL: configuration.runtimeURL, modelURL: configuration.modelURL)
    }
    public static func transcribe(url: URL, sourceStart: MediaTime = .zero, duration: MediaTime? = nil,
                                  configuration: WhisperConfiguration = .init(), options: SpeechOptions = .init(), progress: (@Sendable (Double?) -> Void)? = nil) async throws -> LocalTranscript {
        try await transcribe(url: url, sourceStart: sourceStart, duration: duration, configuration: configuration, options: options, verifyModel: true, progress: progress)
    }
    static func transcribe(url: URL, sourceStart: MediaTime, duration: MediaTime?, configuration: WhisperConfiguration,
                           options: SpeechOptions, verifyModel: Bool, speechRegions: [ClosedRange<Double>]? = nil, speechEvidence: [ClosedRange<Double>]? = nil,
                           progress: (@Sendable (Double?) -> Void)?) async throws -> LocalTranscript {
        guard ["ko", "en", "ja", "auto"].contains(options.language), (-1...31).contains(options.channel), options.glossary.count <= 500 else { throw AudioAnalysisError("인식 언어·채널·500자 이내 용어 힌트를 확인하세요.") }
        let begun = Date(); try Task.checkCancellation()
        let state = availability(configuration: configuration)
        guard state.canTranscribe else { throw AudioAnalysisError(state.message) }
        progress?(0)
        // The size check in availability() runs every window; the full digest once per run.
        if verifyModel { try WhisperModelInstaller.verifyModel(at: configuration.modelURL, spec: configuration.modelSpec) }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("JHCutSpeech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let wav = workspace.appendingPathComponent("source.wav")
        var sourceChannelIndex = 0
        let extracted = try await extractAudio(url: url, sourceStart: sourceStart, duration: duration, destination: wav, preferredChannel: options.channel) { sourceChannelIndex = $0 }
        progress?(0.1)
        // Recognise a compacted copy (speech regions only) when that removes a meaningful share.
        var recognised = wav, timeline: CompactedTimeline?
        if let speechRegions {
            let candidate = CompactedTimeline(regions: speechRegions.sorted { $0.lowerBound < $1.lowerBound }, recordingDuration: extracted)
            if candidate.pieces.isEmpty { throw AudioAnalysisError("선택 구간에서 음성 후보를 찾지 못했습니다.") }
            if candidate.compactDuration < extracted * 0.85 {
                recognised = workspace.appendingPathComponent("speech-only.wav")
                try writeCompacted(from: wav, to: recognised, timeline: candidate); timeline = candidate
            }
        }
        // One Whisper pass over `recognised`; `extra` adds arguments (used for the loop retry).
        func recognise(_ name: String, extra: [String], audio: URL? = nil, map: CompactedTimeline?? = nil,
                       progress: (@Sendable (Double?) -> Void)?) async throws -> (cues: [CaptionCue], language: String) {
            let prefix = workspace.appendingPathComponent(name)
            let input = audio ?? recognised, timeline = map ?? timeline
            var args = ["-m", configuration.modelURL.path, "-f", input.path, "-l", options.language, "-osrt", "-oj", "-of", prefix.path,
                        "-ml", "42", "-sow", "-pp", "-ng", "-t", String(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))]
            args += ["-bs", options.accurate ? "5" : "1", "-bo", options.accurate ? "5" : "1"]
            if !options.glossary.isEmpty { args += ["--prompt", options.glossary] }
            args += extra
            try await run(executable: configuration.runtimeURL, arguments: args, directory: workspace, progress: progress)
            try Task.checkCancellation()
            // whisper.cpp can cut a multibyte character at a segment boundary, leaving invalid UTF-8
            // in both files. Decode leniently (the broken bytes become U+FFFD and are removed) instead
            // of failing the whole recognition.
            let srt = String(decoding: try Data(contentsOf: prefix.appendingPathExtension("srt")), as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
            let jsonText = String(decoding: try Data(contentsOf: prefix.appendingPathExtension("json")), as: UTF8.self)
            let json = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any]
            var reported = (json?["result"] as? [String: Any])?["language"] as? String
            if reported == nil, let match = jsonText.range(of: #""language"\s*:\s*"([a-z]{2,3})""#, options: .regularExpression) {
                reported = jsonText[match].split(separator: "\"").dropFirst(2).first.map(String.init)
            }
            guard let language = reported, !language.isEmpty, language != "auto" else { throw AudioAnalysisError("인식 결과의 실제 언어를 확인하지 못했습니다. 원본 언어를 직접 선택해 다시 시도하세요.") }
            let relative = SRTCodec.parseRecognizerOutput(srt).cues, limit = sourceStart.seconds + extracted
            let cues = relative.compactMap { cue -> CaptionCue? in
                if let timeline {
                    guard let range = timeline.sourceRange(compactStart: cue.start.seconds, compactEnd: cue.start.seconds + cue.duration.seconds) else { return nil }
                    let start = sourceStart.seconds + range.lowerBound, end = min(limit, sourceStart.seconds + range.upperBound)
                    guard end > start, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return CaptionCue(start: MediaTime(seconds: start), duration: MediaTime(seconds: end - start), text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let start = max(sourceStart.seconds, sourceStart.seconds + cue.start.seconds)
                let end = min(limit, sourceStart.seconds + cue.start.seconds + cue.duration.seconds)
                guard end > start, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return CaptionCue(start: MediaTime(seconds: start), duration: MediaTime(seconds: end - start), text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (cues, language)
        }
        var (cues, language) = try await recognise("transcript", extra: [], progress: progress)
        // Repetition loop guard. Measured on real iPhone videos: Whisper sometimes repeats one line
        // for minutes (113 of 131 captions in one 5-minute window). Retrying the same audio without
        // text conditioning (-mc 0) cut that to 19; the result with fewer repeats is kept, and any
        // run that remains is collapsed to its first caption and reported for review.
        var retried = false
        if RepetitionGuard.longestRun(cues) > 0 {
            retried = true
            let second = try await recognise("transcript-retry", extra: ["-mc", "0"], progress: nil)
            if RepetitionGuard.longestRun(second.cues) < RepetitionGuard.longestRun(cues) { cues = second.cues; language = second.language }
        }
        var guarded = RepetitionGuard.collapsed(cues)
        cues = guarded.cues
        // Coverage repair (non-speech skipping only). Measured on a real iPhone video: after a
        // hallucinated bracket line at the start of the speech-only audio, Whisper returned nothing
        // for ~13 s of dialogue inside a speech region. Every speech stretch of `CoverageRepair.minimumGap`
        // or more with no caption is recognised again ON ITS OWN (fresh run, no carried context);
        // bracket/lyric-only lines from that retry are not accepted as recovered speech.
        var repairedSpans = 0, recovered = 0
        // Only where the audio was actually compacted: that is where context is lost at the joins.
        // An uncompacted window is recognised exactly like full recognition.
        if let speechRegions, timeline != nil {
            // A bracket/lyric-only line is not speech coverage (real case: “[몇일이 없음]” over dialogue).
            let covered = cues.filter { !CoverageRepair.isMarker($0.text) }.map { ($0.start.seconds - sourceStart.seconds)...($0.start.seconds + $0.duration.seconds - sourceStart.seconds) }
            let gaps = CoverageRepair.uncovered(regions: speechRegions, covered: covered, limit: extracted, evidence: speechEvidence)
            for (i, gap) in gaps.enumerated() {
                func overlaps(_ a: CaptionCue, _ b: CaptionCue) -> Bool { a.start < b.start + b.duration && b.start < a.start + a.duration }
                let gapStart = sourceStart.seconds + gap.lowerBound, gapEnd = sourceStart.seconds + gap.upperBound
                repairedSpans += 1
                // Short context first, then a wider one: on real clips each setting recovered
                // dialogue the other returned nothing for.
                for (attempt, padding) in CoverageRepair.paddings.enumerated() {
                    try Task.checkCancellation()
                    let piece = CompactedTimeline(regions: [max(0, gap.lowerBound - padding)...min(extracted, gap.upperBound + padding)], recordingDuration: extracted)
                    guard !piece.pieces.isEmpty else { continue }
                    let audio = workspace.appendingPathComponent("gap-\(i)-\(attempt).wav")
                    try writeCompacted(from: wav, to: audio, timeline: piece)
                    let again = try await recognise("gap-\(i)-\(attempt)", extra: [], audio: audio, map: .some(piece), progress: nil)
                    let found = RepetitionGuard.collapsed(again.cues).cues.filter { !CoverageRepair.isMarker($0.text) }
                    // Retry timestamps often spill into the context. Trim each recovered caption to
                    // the gap (which no caption covers) instead of dropping it for touching a neighbour.
                    let fresh = found.compactMap { cue -> CaptionCue? in
                        let a = max(cue.start.seconds, gapStart), b = min(cue.start.seconds + cue.duration.seconds, gapEnd)
                        guard b - a >= CoverageRepair.minimumCaptionSeconds else { return nil }
                        var trimmed = cue; trimmed.start = MediaTime(seconds: a); trimmed.duration = MediaTime(seconds: b - a)
                        return cues.contains { !CoverageRepair.isMarker($0.text) && overlaps($0, trimmed) } ? nil : trimmed
                    }
                    guard !fresh.isEmpty else { continue }
                    // Recovered speech replaces bracket lines on top of it or inside the same gap
                    // (the gap is speech that was mislabelled as “[…]”).
                    cues.removeAll { old in
                        CoverageRepair.isMarker(old.text) && (fresh.contains { overlaps($0, old) } || (old.start.seconds >= gapStart - 0.05 && old.start.seconds + old.duration.seconds <= gapEnd + 0.05))
                    }
                    recovered += fresh.count; cues += fresh
                    break
                }
            }
            cues.sort { $0.start < $1.start }
            if recovered > 0 { guarded = (cues, guarded.removed, guarded.flagged) }
        }
        progress?(1)
        var transcript = LocalTranscript(cues: cues, engine: "\(engineVersion) · \(configuration.modelSpec.name) · CPU/Accelerate", language: language, sourceStart: sourceStart,
                                         duration: MediaTime(seconds: extracted), elapsedSeconds: Date().timeIntervalSince(begun), sourceChannelIndex: sourceChannelIndex)
        transcript.repetitionRetried = retried ? true : nil
        transcript.coverageRepairs = repairedSpans > 0 ? repairedSpans : nil
        transcript.recoveredCues = recovered > 0 ? recovered : nil
        transcript.repeatedCuesRemoved = guarded.removed > 0 ? guarded.removed : nil
        transcript.repetitionSuspects = guarded.flagged.isEmpty ? nil : guarded.flagged
        return transcript
    }
    /// Copies the speech pieces of a 16 kHz mono 16-bit WAV into a new file, joined by short silence.
    /// Works on the temporary extraction only; the source media is never touched.
    static func writeCompacted(from source: URL, to destination: URL, timeline: CompactedTimeline) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = input.processingFormat, rate = format.sampleRate
        let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let joinFrames = AVAudioFrameCount((CompactedTimeline.joinSilence * rate).rounded())
        for (i, piece) in timeline.pieces.enumerated() {
            try Task.checkCancellation()
            let first = AVAudioFramePosition((piece.sourceStart * rate).rounded())
            let count = AVAudioFrameCount(min(Double(input.length - first), (piece.length * rate).rounded()))
            guard first < input.length, count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { continue }
            input.framePosition = first
            try input.read(into: buffer, frameCount: count)
            try output.write(from: buffer)
            if i < timeline.pieces.count - 1, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: joinFrames) {
                silence.frameLength = joinFrames
                memset(silence.int16ChannelData![0], 0, Int(joinFrames) * MemoryLayout<Int16>.size)
                try output.write(from: silence)
            }
        }
    }
    static func extractAudio(url: URL, sourceStart: MediaTime, duration: MediaTime?, destination: URL, preferredChannel: Int = -1, channelSelected: ((Int) -> Void)? = nil) async throws -> Double {
        // Two streaming passes choose ONE consistent highest-energy native channel, then resample it to mono.
        // This avoids cancellation of opposite-phase stereo. Dialogue on a quieter separate channel may need external channel isolation.
        var channelEnergy: [Double] = []
        var cross: [[Double]] = []
        _ = try await SourcePCM.readStable(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            let n = chunk.channels
            if channelEnergy.isEmpty { channelEnergy = [Double](repeating: 0, count: n); cross = [[Double]](repeating: [Double](repeating: 0, count: n), count: n) }
            guard channelEnergy.count == n else { throw AudioAnalysisError("음성 추출 중 채널 수가 변경되었습니다.") }
            for frame in 0..<(chunk.values.count / n) {
                for a in 0..<n {
                    let x = Double(chunk.values[frame * n + a]); channelEnergy[a] += x * x
                    for b in (a + 1)..<max(a + 1, n) { cross[a][b] += x * Double(chunk.values[frame * n + b]) }
                }
            }
        }
        let ranked = channelEnergy.indices.sorted { channelEnergy[$0] > channelEnergy[$1] }
        let selectedChannel = preferredChannel >= 0 ? preferredChannel : (ranked.first ?? 0)
        guard channelEnergy.indices.contains(selectedChannel) else { throw AudioAnalysisError("선택한 채널이 없습니다. 자동 선택 또는 실제 채널 번호를 선택하세요.") }
        // Automatic mode: when a second channel carries real signal (≥ −10 dB) and is not an
        // inverted copy (correlation ≥ −0.5), average the two. Picking only the loudest channel
        // silently dropped the other person on recordings with one microphone per channel;
        // an opposite-phase pair still uses one channel so it cannot cancel.
        var mixChannel: Int? = nil
        if preferredChannel < 0, ranked.count > 1 {
            let a = ranked[0], b = ranked[1], ea = channelEnergy[a], eb = channelEnergy[b]
            let correlation = ea > 0 && eb > 0 ? cross[min(a, b)][max(a, b)] / (ea * eb).squareRoot() : 0
            if eb >= ea * 0.1, correlation >= -0.5 { mixChannel = b }
        }
        channelSelected?(selectedChannel)
        // Decode at the NATIVE rate and resample here, in fixed-size blocks. Letting the reader
        // resample produced buffers whose timestamps jittered by a sample between runs; re-placing
        // every buffer by its rounded timestamp then inserted or dropped a sample mid-speech, so the
        // same clip yielded different PCM (and different captions) on each run. Decoder buffers are
        // now appended contiguously and only a real discontinuity (> 2 ms) is padded or trimmed.
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        // Quantise to 16-bit here with plain rounding, so the file holds exactly the same integers
        // for the same float samples (no converter-side rounding or dither choices).
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false], commonFormat: .pcmFormatInt16, interleaved: false)
        var outputFrames: Int64 = 0
        func write(_ buffer: AVAudioPCMBuffer) throws {
            let count = Int(buffer.frameLength)
            guard count > 0, let quantised = AVAudioPCMBuffer(pcmFormat: integer, frameCapacity: AVAudioFrameCount(count)) else { return }
            quantised.frameLength = AVAudioFrameCount(count)
            let source = buffer.floatChannelData![0], destination = quantised.int16ChannelData![0]
            for index in 0..<count { destination[index] = Int16(max(-32768, min(32767, (Double(source[index]) * 32767).rounded()))) }
            try file!.write(from: quantised); outputFrames += Int64(count)
        }
        var converter: AVAudioConverter?
        var nativeRate = 0.0
        var nativeFrames: Int64 = 0
        var pending: [Float] = []
        let block = 16_384
        func convert(_ samples: [Float], final: Bool) throws {
            guard let converter, let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false) else { return }
            var input: AVAudioPCMBuffer?
            if !samples.isEmpty {
                input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
                input!.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { input!.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            }
            var supplied = false
            while true {
                let capacity = AVAudioFrameCount(Double(max(samples.count, block)) * 16_000 / nativeRate) + 512
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw AudioAnalysisError("음성 변환 버퍼를 만들지 못했습니다.") }
                var failure: NSError?
                let status = converter.convert(to: out, error: &failure) { _, state in
                    if !supplied, let input { supplied = true; state.pointee = .haveData; return input }
                    state.pointee = final ? .endOfStream : .noDataNow; return nil
                }
                if let failure { throw failure }
                try write(out)
                if status == .endOfStream || status == .error || (status == .inputRanDry && out.frameLength == 0) { break }
                if status == .inputRanDry { break }
                if out.frameLength == 0 && supplied { break }
            }
        }
        func append(_ mono: [Float]) throws {
            pending.append(contentsOf: mono)
            while pending.count >= block {
                try Task.checkCancellation()
                try convert(Array(pending.prefix(block)), final: false); pending.removeFirst(block)
            }
        }
        let range = try await SourcePCM.readStable(url: url, sourceStart: sourceStart, duration: duration) { chunk in
            guard selectedChannel < chunk.channels else { throw AudioAnalysisError("선택한 음성 채널을 읽을 수 없습니다.") }
            if converter == nil {
                nativeRate = chunk.sampleRate
                guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false),
                      let made = AVAudioConverter(from: source, to: target) else { throw AudioAnalysisError("음성 변환기를 만들 수 없습니다.") }
                made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter = made
            }
            guard chunk.sampleRate == nativeRate else { throw AudioAnalysisError("음성 추출 중 샘플레이트가 변경되었습니다.") }
            var mono = stride(from: selectedChannel, to: chunk.values.count, by: chunk.channels).map { chunk.values[$0] }
            if let other = mixChannel {
                for (i, index) in stride(from: other, to: chunk.values.count, by: chunk.channels).enumerated() where i < mono.count { mono[i] = (mono[i] + chunk.values[index]) * 0.5 }
            }
            let expected = Int64(((chunk.start - sourceStart.seconds) * nativeRate).rounded())
            let tolerance = Int64(nativeRate * 0.002)
            if expected > nativeFrames + tolerance {
                // A genuine gap in the source (e.g. a missing packet): keep timing with silence.
                var gap = expected - nativeFrames
                while gap > 0 { try Task.checkCancellation(); let n = Int(min(gap, 48_000)); try append([Float](repeating: 0, count: n)); nativeFrames += Int64(n); gap -= Int64(n) }
            } else if expected < nativeFrames - tolerance {
                // Overlapping decoder packets: drop the part already written.
                mono = Array(mono.dropFirst(min(mono.count, Int(nativeFrames - expected))))
            }
            try append(mono); nativeFrames += Int64(mono.count)
        }
        guard converter != nil, nativeFrames > 0 else { throw AudioAnalysisError("선택 범위에서 음성을 읽지 못했습니다.") }
        try convert(pending, final: true); pending.removeAll()
        let requestedFrames = Int64((range.duration * 16_000).rounded())
        while requestedFrames > outputFrames {
            try Task.checkCancellation()
            let n = Int(min(requestedFrames - outputFrames, 16_000))
            let pad = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(n))!; pad.frameLength = AVAudioFrameCount(n)
            memset(pad.floatChannelData![0], 0, n * MemoryLayout<Float>.size); try write(pad)
        }
        file = nil // Close the WAV header before the subprocess opens it.
        return range.duration
    }
    static func run(executable: URL, arguments: [String], directory: URL,
                            progress: (@Sendable (Double?) -> Void)?) async throws {
        let process = Process(), output = Pipe(), controller = ProcessController()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = output
        let log = LockedLog()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self); log.append(text)
            for line in text.components(separatedBy: .newlines) where line.contains("progress") {
                let components = line.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
                if let value = components.compactMap(Double.init).last, (0...100).contains(value) { progress?(0.1 + 0.85 * value / 100) }
            }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil; try? output.fileHandleForReading.close() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { task in
                    if controller.cancelled { continuation.resume(throwing: CancellationError()) }
                    else if task.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: AudioAnalysisError("로컬 음성 인식 실패 (\(task.terminationStatus)): \(log.tail)")) }
                }
                do { try controller.start(process); progress?(nil) }
                catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        }, onCancel: { controller.cancel() })
    }
    private final class LockedLog: @unchecked Sendable {
        private let lock = NSLock(); private var value = ""
        func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value = String((value + text).suffix(3000)) }
        var tail: String { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class ProcessController: @unchecked Sendable {
        private let lock = NSLock(); private var process: Process?; private var didCancel = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return didCancel }
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !didCancel else { throw CancellationError() }
            self.process = process; try process.run()
        }
        func cancel() {
            lock.lock(); didCancel = true; let running = process; lock.unlock()
            guard let running, running.isRunning else { return }
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if running.isRunning { kill(running.processIdentifier, SIGKILL) } }
        }
    }
}

public struct AppleSpeechAvailability: Codable, Sendable {
    public let authorization: String
    public let supportsOnDeviceRecognition: Bool
    public let isAvailable: Bool
    public let canTranscribe: Bool
    public let message: String
}
/// Experimental system capability inspection only. The production transcription path is whisper.cpp.
public enum AppleLocalTranscription {
    @MainActor public static func availability(localeIdentifier: String = "ko-KR") -> AppleSpeechAvailability {
        let status = SFSpeechRecognizer.authorizationStatus()
        let authorization: String
        switch status { case .authorized: authorization = "authorized"; case .denied: authorization = "denied"; case .restricted: authorization = "restricted"; case .notDetermined: authorization = "notDetermined"; @unknown default: authorization = "unknown" }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        let local = recognizer?.supportsOnDeviceRecognition ?? false, available = recognizer?.isAvailable ?? false
        return AppleSpeechAvailability(authorization: authorization, supportsOnDeviceRecognition: local, isAvailable: available,
            canTranscribe: false, message: "Apple Speech 실험적 상태: 권한 \(authorization), 온디바이스 \(local ? "지원" : "미지원"), 서비스 \(available ? "사용 가능" : "사용 불가"). 실제 자동 자막은 검증된 whisper.cpp 경로를 사용합니다.")
    }
    /// Optional explicit UI button only. No automatic call from availability or transcription.
    @MainActor public static func requestAuthorization(localeIdentifier: String = "ko-KR") async -> AppleSpeechAvailability {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined,
           Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        return availability(localeIdentifier: localeIdentifier)
    }
}

/// Detects and collapses Whisper repetition loops: the same line (after normalisation) repeated
/// in consecutive captions, or two lines alternating.
public enum RepetitionGuard {
    public static let minimumRun = 3
    public static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }
    /// Comparison key for loops: the normalised text reduced to its repeating unit, so
    /// "-어?-어?-어?", "어?" and "어어" all count as the same line.
    public static func loopKey(_ text: String) -> String {
        let key = Array(normalized(text))
        guard key.count > 1 else { return String(key) }
        for period in 1...(key.count / 2) where key.count % period == 0 {
            let unit = key[0..<period]
            if stride(from: period, to: key.count, by: period).allSatisfy({ key[$0..<($0 + period)] == unit }) { return String(unit) }
        }
        return String(key)
    }
    /// Longest number of consecutive captions that are one repeated line or an A/B alternation
    /// (an alternation of n captions counts as n / 2 repeats).
    public static func longestRun(_ cues: [CaptionCue]) -> Int {
        let keys = cues.map { loopKey($0.text) }
        var best = 0, run = 1
        for i in keys.indices.dropFirst() {
            if !keys[i].isEmpty && keys[i] == keys[i - 1] { run += 1 } else { run = 1 }
            if qualifies(keys[i], run) { best = max(best, run) }
        }
        var alt = 0
        for i in keys.indices.dropFirst(2) {
            if !keys[i].isEmpty && keys[i] == keys[i - 2] && keys[i] != keys[i - 1] { alt += 1; if qualifies(keys[i], (alt + 2) / 2) { best = max(best, (alt + 2) / 2) } } else { alt = 0 }
        }
        return best
    }
    /// Short interjections ("네", "어?") genuinely repeat; they count as a loop only from 6 repeats.
    static func qualifies(_ key: String, _ run: Int) -> Bool { run >= (key.count >= 4 ? minimumRun : 6) }
    /// Keeps the first caption of each loop (first two of an alternation) and drops the repeats.
    public static func collapsed(_ cues: [CaptionCue]) -> (cues: [CaptionCue], removed: Int, flagged: [Double]) {
        let keys = cues.map { loopKey($0.text) }
        var drop = Set<Int>(), flagged: [Double] = []
        var i = 0
        while i < cues.count {
            var j = i + 1
            while j < cues.count, !keys[i].isEmpty, keys[j] == keys[i] { j += 1 }
            if qualifies(keys[i], j - i) { flagged.append(cues[i].start.seconds); for k in (i + 1)..<j { drop.insert(k) } }
            i = j
        }
        i = 0
        while i + 2 < cues.count {
            var j = i + 2
            while j < cues.count, !keys[j].isEmpty, keys[j] == keys[j - 2], keys[j] != keys[j - 1] { j += 1 }
            if j - i >= minimumRun * 2 && qualifies(keys[i], (j - i) / 2) { flagged.append(cues[i].start.seconds); for k in (i + 2)..<j { drop.insert(k) }; i = j } else { i += 1 }
        }
        return (cues.enumerated().filter { !drop.contains($0.offset) }.map(\.element), drop.count, flagged.sorted())
    }
}

/// Finds speech that the main recognition pass left without any caption.
public enum CoverageRepair {
    /// A stretch of speech region this long with no caption is recognised again.
    public static let minimumGap = 3.0
    /// Context heard on both sides of a gap, tried in order until something is recovered.
    /// Measured on real iPhone clips: 0.4 s recovered a 13 s exchange that 2 s missed, and 2 s
    /// recovered lines where 0.4 s returned only “[놀람]” or a fragment.
    public static let paddings = [0.4, 2.0]
    /// Recovered captions shorter than this after trimming to the gap are not kept.
    public static let minimumCaptionSeconds = 0.3
    /// At most this many retries per window (largest gaps first), to bound the extra time.
    public static let maximumRetries = 4
    /// Confident speech a gap must contain before it is retried (when evidence is given).
    public static let minimumEvidenceSeconds = 2.5
    /// Classifier confidence for a speech segment to count as evidence.
    public static let evidenceConfidence = 0.6

    /// Region parts (relative seconds) not covered by any caption, `minimumGap` or longer, largest first.
    /// With `evidence` (confident speech spans), a gap is retried only when it holds at least
    /// `minimumEvidenceSeconds` of it. Measured on a concert video: retrying every caption-free
    /// stretch (mostly singing and crowd noise) made skipping slower than full recognition.
    public static func uncovered(regions: [ClosedRange<Double>], covered: [ClosedRange<Double>], limit: Double, evidence: [ClosedRange<Double>]? = nil) -> [ClosedRange<Double>] {
        let spans = covered.sorted { $0.lowerBound < $1.lowerBound }
        var gaps: [ClosedRange<Double>] = []
        for region in regions {
            var cursor = max(0, region.lowerBound)
            let end = min(limit, region.upperBound)
            for c in spans where c.upperBound > cursor && c.lowerBound < end {
                if c.lowerBound - cursor >= minimumGap { gaps.append(cursor...c.lowerBound) }
                cursor = max(cursor, c.upperBound)
            }
            if end - cursor >= minimumGap { gaps.append(cursor...end) }
        }
        func evidenceSeconds(_ g: ClosedRange<Double>) -> Double { (evidence ?? []).reduce(0) { $0 + max(0, min($1.upperBound, g.upperBound) - max($1.lowerBound, g.lowerBound)) } }
        if evidence != nil { gaps = gaps.filter { evidenceSeconds($0) >= minimumEvidenceSeconds } }
        let rank: (ClosedRange<Double>) -> Double = { evidence != nil ? evidenceSeconds($0) : $0.upperBound - $0.lowerBound }
        return Array(gaps.sorted { rank($0) > rank($1) }.prefix(maximumRetries)).sorted { $0.lowerBound < $1.lowerBound }
    }
    /// Whisper's non-speech output: "[…]", "(…)" or lyric lines.
    public static func isMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) || t.contains("♪")
    }
}

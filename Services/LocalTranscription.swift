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
    public var audioSelection: AudioChannelSelection? = nil
    /// Legacy pipeline metadata: older results could retry using only text repetition.
    public var repetitionRetried: Bool? = nil
    /// Legacy pipeline metadata: pipeline 4 and later preserve repetitions, so new results leave this nil.
    public var repeatedCuesRemoved: Int? = nil
    /// Absolute source starts of suspicious repeated captions, preserved for editor review.
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
    public var languageObservations: [SourceLanguageObservation]? = nil
    public var languageRepairAttempts: [LanguageRepairAttempt]? = nil
    public var languageRepairCost: LanguageRepairCost? = nil
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
    public var languageRepairEnabled = true
    public init() {}
}
public enum LocalTranscription {
    public static let engineVersion = "whisper.cpp v1.9.4"
    /// Everything after Whisper that changes results. Part of the checkpoint identity, so windows
    /// recognised by an older pipeline (including destructive boundary/repetition filtering) are not reused.
    // Changing the runtime CPU arithmetic policy invalidates completed windows from the older executable.
    public static let pipelineVersion = engineVersion + " · cpu-armv8.2-fp16-r3 · pipeline 9"

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
                                      audioSelection: AudioChannelSelection? = nil, speechPolicy: VoiceActivityPolicy = .conservative,
                                      onCheckpointError: (@Sendable (Error) -> Void)? = nil,
                                      detail: (@Sendable (TranscriptionProgress) -> Void)? = nil,
                                      progress: (@Sendable (Double?) -> Void)? = nil) async throws -> LocalTranscript {
        guard duration > .zero, duration.seconds <= RecognitionCacheSafety.maximumDuration, sourceStart >= .zero, sourceStart.seconds <= RecognitionCacheSafety.maximumStart,
              windowSeconds.isFinite, (30...3600).contains(windowSeconds), (try? sourceStart.adding(duration)) != nil, (try? sourceStart.adding(MediaTime(1,60_000))) != nil, (try? duration.adding(MediaTime(1,60_000))) != nil else { throw AudioAnalysisError("인식 구간은 24시간 이내, 분할 창은 30~3600초로 선택하세요.") }
        let endSeconds = sourceStart.seconds + duration.seconds
        for regions in [speechRegions,speechEvidence].compactMap({ $0 }) {
            guard regions.count <= RecognitionCacheSafety.maximumRegions else { throw AudioAnalysisError("말소리 후보 개수가 허용 한도를 넘습니다.") }
            var previous = sourceStart.seconds
            for r in regions { guard r.lowerBound.isFinite, r.upperBound.isFinite, r.lowerBound >= previous - 0.0001, r.lowerBound >= sourceStart.seconds - 0.0001, r.upperBound > r.lowerBound, r.upperBound <= endSeconds + 0.0001 else { throw AudioAnalysisError("말소리 후보의 원본 범위·정렬을 확인하세요.") }; previous = r.upperBound }
        }
        guard audioSelection == nil || audioSelection!.matches(requestedChannel:options.channel) else { throw AudioAnalysisError("인식 채널 선택을 확인하세요.") }
        if duration.seconds <= windowSeconds, checkpoint == nil, speechRegions == nil {
            return try await transcribe(url: url, sourceStart: sourceStart, duration: duration, configuration: configuration, options: options, verifyModel: true, audioSelection: audioSelection, speechEvidence: speechEvidence.map {e in e.map {($0.lowerBound-sourceStart.seconds)...($0.upperBound-sourceStart.seconds)}}, progress: progress)
        }
        if let checkpoint {
            guard checkpoint.key.isReusable, checkpoint.key.sourceStart == sourceStart, checkpoint.key.duration == duration, checkpoint.key.windowSeconds == windowSeconds,
                  checkpoint.key.language == options.language, checkpoint.key.channel == options.channel,
                  checkpoint.key.glossary == options.glossary, checkpoint.key.accurate == options.accurate, checkpoint.key.languageRepairEnabled == options.languageRepairEnabled,
                  checkpoint.key.modelSHA256 == configuration.modelSpec.sha256, checkpoint.key.engine == pipelineVersion, checkpoint.key.skipsSilence == (speechRegions != nil),
                  checkpoint.key.voiceActivityPolicy == (speechRegions == nil ? nil : speechPolicy.rawValue)
            else { throw AudioAnalysisError("체크포인트 설정이 이번 인식 요청과 다릅니다. 체크포인트를 삭제하고 다시 실행하세요.") }
        }
        var session = checkpoint
        var lease: TranscriptionCacheLease?
        if let checkpoint {
            do {
                if let supplied = checkpoint.lease { guard supplied.matches(store:checkpoint.store,key:checkpoint.key) else { throw TranscriptionCacheError.activeSession }; lease = supplied }
                else { lease = try checkpoint.store.beginSession(for:checkpoint.key) }
            }
            catch let error as TranscriptionCacheError { throw error }
            catch { session = nil; onCheckpointError?(error) }
        }
        defer { lease?.finish() }
        let sourceStamp = try MediaFingerprintCache.stat(url)
        if let checkpoint {
            let digest = try await FileIdentity.sha256(url)
            guard digest == checkpoint.key.mediaSHA256, try MediaFingerprintCache.stat(url) == sourceStamp else { throw AudioAnalysisError("체크포인트 원본과 현재 미디어가 다릅니다. 원본을 확인하고 새로 인식하세요.") }
        }
        let inputSignature = try RecognitionInputSignature.make(regions:speechRegions,evidence:speechEvidence,selection:audioSelection)
        let started = Date()
        let count = max(1, Int((duration.seconds / windowSeconds).rounded(.up)))
        let saved = session.map { $0.store.completedWindows(for:$0.key,inputSignature:inputSignature) } ?? [:]
        let languageBudget = LanguageRepairBudget()
        for stored in saved.values { if let cost = stored.languageRepairCost { languageBudget.charge(cost) } }
        var windows: [TranscriptionWindowResult] = []
        var reused = 0, computed = 0, skipped = 0
        var computedSourceSeconds = 0.0, computedElapsed = 0.0
        var modelVerified = false
        var frozenSelection = audioSelection
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
            let fraction = TranscriptionTiming.windowProgress(index: index, within: within, windowSeconds: windowSeconds, total: total)
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
            guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw AudioAnalysisError("인식 중 원본 미디어가 바뀌었습니다. 기존 편집 내용은 유지합니다.") }
            let offset = Double(index) * windowSeconds
            let windowOffset = MediaTime(seconds:offset)
            let windowStart = try sourceStart.adding(windowOffset)
            let windowDuration = min(try duration.subtracting(windowOffset),MediaTime(seconds:windowSeconds))
            let length = windowDuration.seconds
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
                var empty = TranscriptionWindowResult(index: index, sourceStart: windowStart, duration: windowDuration, cues: [],
                                                      language: "", channel: max(0, options.channel), elapsedSeconds: 0, skippedWithoutSpeech: true)
                empty.inputSignature = inputSignature
                windows.append(empty); skipped += 1
                if let checkpoint = session { do { try checkpoint.store.save(empty, for: checkpoint.key) } catch { onCheckpointError?(error) } }
                report(index, 1, windowStart.seconds, counters); continue
            }
            if frozenSelection == nil {
                frozenSelection = try await AudioChannelSelection.resolve(url: url, sourceStart: sourceStart, duration: duration, preferredChannel: options.channel)
            }
            let begun = Date(), frozen = counters, windowStartSeconds = windowStart.seconds
            let result = try await transcribe(url: url, sourceStart: windowStart, duration: windowDuration, configuration: configuration,
                                              options: options, verifyModel: !modelVerified, audioSelection: frozenSelection, speechRegions: local,
                                              speechEvidence: speechEvidence.map { e in e.compactMap { r -> ClosedRange<Double>? in
                                                  let a = max(0, r.lowerBound - windowStart.seconds), b = min(length, r.upperBound - windowStart.seconds)
                                                  return b > a ? a...b : nil } }, languageBudget: languageBudget, languageProbeLimit: LanguageRepair.probeAllowance(window: index, count: count)) { fraction in
                guard let fraction else { progress?(nil); return }
                report(index, fraction, windowStartSeconds, frozen)
            }
            guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw AudioAnalysisError("인식 중 원본 미디어가 바뀌었습니다. 이 구간은 저장하지 않았습니다.") }
            modelVerified = true
            var window = TranscriptionWindowResult(index: index, sourceStart: windowStart, duration: windowDuration, cues: result.cues,
                                                   language: result.language, channel: result.sourceChannelIndex, elapsedSeconds: Date().timeIntervalSince(begun))
            window.inputSignature = inputSignature
            window.audioSelection = result.audioSelection
            window.languageObservations = result.languageObservations; window.languageRepairAttempts = result.languageRepairAttempts; window.languageRepairCost = result.languageRepairCost
            window.repeatedCuesRemoved = result.repeatedCuesRemoved; window.repetitionSuspects = result.repetitionSuspects
            window.coverageRepairs = result.coverageRepairs; window.recoveredCues = result.recoveredCues
            windows.append(window); computed += 1
            computedSourceSeconds += work[index]; computedElapsed += window.elapsedSeconds
            // Saved only after the window fully succeeded, and before the next one starts: a
            // cancellation or crash during the next window cannot lose this one.
            if let checkpoint = session { do { try checkpoint.store.save(window, for: checkpoint.key) } catch { onCheckpointError?(error) } }
            report(index, 1, windowStart.seconds, counters)
        }
        try Task.checkCancellation()
        guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw AudioAnalysisError("인식 중 원본 미디어가 바뀌었습니다. 기존 편집 내용은 유지합니다.") }
        var detected: [String: Int] = [:]
        var channel = max(0, options.channel)
        for window in windows.sorted(by: { $0.index < $1.index }) {
            if !window.language.isEmpty { detected[window.language, default: 0] += 1; channel = window.channel }
        }
        let assembled = TranscriptionTiming.assembledCues(windows)
        guard let language = detected.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else {
            throw AudioAnalysisError("선택 구간에서 음성 후보를 찾지 못했습니다. 무음 건너뛰기를 끄거나 대사가 있는 구간을 선택하세요.")
        }
        var transcript = LocalTranscript(cues: assembled, engine: "\(engineVersion) · 분할 인식", language: language,
                                         sourceStart: sourceStart, duration: duration, elapsedSeconds: Date().timeIntervalSince(started), sourceChannelIndex: channel)
        transcript.audioSelection = frozenSelection ?? windows.compactMap(\.audioSelection).first
        transcript.reusedWindows = reused; transcript.computedWindows = computed; transcript.skippedWindows = skipped
        let removed = windows.reduce(0) { $0 + ($1.repeatedCuesRemoved ?? 0) }, suspects = windows.flatMap { $0.repetitionSuspects ?? [] }.sorted()
        transcript.repeatedCuesRemoved = removed > 0 ? removed : nil; transcript.repetitionSuspects = suspects.isEmpty ? nil : suspects
        let repairs = windows.reduce(0) { $0 + ($1.coverageRepairs ?? 0) }, recoveredTotal = windows.reduce(0) { $0 + ($1.recoveredCues ?? 0) }
        transcript.coverageRepairs = repairs > 0 ? repairs : nil; transcript.recoveredCues = recoveredTotal > 0 ? recoveredTotal : nil
        transcript.windowLanguages = windows.sorted(by: { $0.index < $1.index }).map(\.language)
        transcript.languageObservations = windows.flatMap { $0.languageObservations ?? [] }
        transcript.languageRepairAttempts = windows.flatMap { $0.languageRepairAttempts ?? [] }
        transcript.languageRepairCost = languageBudget.used
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
                           options: SpeechOptions, verifyModel: Bool, audioSelection: AudioChannelSelection? = nil, speechRegions: [ClosedRange<Double>]? = nil, speechEvidence: [ClosedRange<Double>]? = nil, languageBudget: LanguageRepairBudget? = nil, languageProbeLimit: Int? = nil,
                           diagnosticDirectory: URL? = nil,
                           progress: (@Sendable (Double?) -> Void)?) async throws -> LocalTranscript {
        guard ["ko", "en", "ja", "auto"].contains(options.language), (-1...31).contains(options.channel), options.glossary.count <= 500 else { throw AudioAnalysisError("인식 언어·채널·500자 이내 용어 힌트를 확인하세요.") }
        let begun = Date(); try Task.checkCancellation()
        let state = availability(configuration: configuration)
        guard state.canTranscribe else { throw AudioAnalysisError(state.message) }
        progress?(0)
        // The size check in availability() runs every window; the full digest once per run.
        if verifyModel { try WhisperModelInstaller.verifyModel(at: configuration.modelURL, spec: configuration.modelSpec) }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("JHCutSpeech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let wav = workspace.appendingPathComponent("source.wav")
        let selection: AudioChannelSelection
        if let audioSelection { selection = audioSelection }
        else { selection = try await AudioChannelSelection.resolve(url: url, sourceStart: sourceStart, duration: duration, preferredChannel: options.channel) }
        var sourceChannelIndex = 0
        let extracted = try await extractAudio(url: url, sourceStart: sourceStart, duration: duration, destination: wav, preferredChannel: options.channel, audioSelection: selection) { sourceChannelIndex = $0 }
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
        // One Whisper pass over `recognised`; repair passes can supply a different compacted map.
        func recognise(_ name: String, extra: [String], audio: URL? = nil, map: CompactedTimeline?? = nil,
                       forcedLanguage: String? = nil, timeout: Double? = nil,
                       progress: (@Sendable (Double?) -> Void)?) async throws -> (cues: [CaptionCue], language: String) {
            let prefix = workspace.appendingPathComponent(name)
            let input = audio ?? recognised, timeline = map ?? timeline
            var args = ["-m", configuration.modelURL.path, "-f", input.path, "-l", forcedLanguage ?? options.language, "-osrt", "-oj", "-of", prefix.path,
                        "-ml", "42", "-sow", "-pp", "-ng", "-t", String(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))]
            args += ["-bs", options.accurate ? "5" : "1", "-bo", options.accurate ? "5" : "1"]
            if !options.glossary.isEmpty { args += ["--prompt", options.glossary] }
            args += extra
            // A successful child exit is not sufficient: whisper.cpp can skip unreadable input
            // or fail to open an output and still exit 0. Validate both requested outputs and
            // preserve a private, content-free diagnostic before the workspace defer removes it.
            let output = try await WhisperOutputContract.recognize(executable: configuration.runtimeURL, arguments: args,
                directory: workspace, prefix: prefix, timeout: timeout, diagnosticDirectory: diagnosticDirectory, progress: progress)
            let cues = TranscriptionTiming.sourceCues(output.cues, sourceStart: sourceStart,
                                                     duration: min(duration ?? MediaTime(seconds:extracted),MediaTime(seconds: extracted)), compacted: timeline)
            return (cues, output.language)
        }
        var (cues, language) = try await recognise("transcript", extra: [], progress: progress)
        // Text repetition is a review hint, not acoustic evidence of hallucination. Replacing
        // a pass with fewer repeated lines or collapsing it can erase real consecutive speech.
        var guarded = RepetitionGuard.reviewed(cues)
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
                    let found = RepetitionGuard.reviewed(again.cues).cues.filter { !CoverageRepair.isMarker($0.text) }
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
            if recovered > 0 { guarded = RepetitionGuard.reviewed(cues) }
        }
        // Independent language probes hear CONTIGUOUS original audio, not VAD joins. A strong
        // acoustic posterior plus measured speech can nominate a bounded forced-language retry.
        let budget = languageBudget ?? LanguageRepairBudget(), before = budget.used
        let end = sourceStart.seconds + extracted
        var observations = [SourceLanguageObservation(start:sourceStart.seconds,end:end,language:CaptionLanguage(rawValue:language) == nil ? nil:language,candidate:language,
            method:.recognizerWindow,state:.uncertain,reason:"wholeWindowRecognizerLanguage")]
        var attempts: [LanguageRepairAttempt] = []
        if options.language != "auto" {
            observations.append(SourceLanguageObservation(start:sourceStart.seconds,end:end,language:options.language,method:.manual,state:.specified,reason:"userForcedLanguage"))
        } else if options.languageRepairEnabled {
            let nominated = LanguageRepair.ranges(cues:cues,start:sourceStart.seconds,end:end)
            let priority = Set(nominated.indices.filter { index in
                let range = nominated[index]
                return cues.contains { cue in
                    let decision = SentenceLanguage.detect(cue.text, clipLanguage: language)
                    return !decision.needsReview && decision.language != language && cue.start.seconds < range.upperBound && cue.start.seconds + cue.duration.seconds > range.lowerBound
                }
            })
            let ranges = LanguageRepair.sampledRanges(nominated, priority: priority, limit: languageProbeLimit ?? LanguageRepairPolicy.maximumProbes)
            if nominated.isEmpty, extracted < LanguageRepairPolicy.minimumAudio {
                observations.append(LanguageRepair.observation(range:sourceStart.seconds...end,result:nil,speechSeconds:0,reason:"shortAudio"))
            }
            var repairedRanges: [ClosedRange<Double>] = []
            for (i,range) in ranges.enumerated() {
                try Task.checkCancellation()
                guard budget.reserveProbe(range.upperBound-range.lowerBound) else { break }
                let begun = Date()
                defer { budget.elapsed(Date().timeIntervalSince(begun)) }
                let piece = CompactedTimeline(regions:[(range.lowerBound-sourceStart.seconds)...(range.upperBound-sourceStart.seconds)],recordingDuration:extracted)
                let audio = workspace.appendingPathComponent("language-\(i).wav")
                do {
                    try writeCompacted(from:wav,to:audio,timeline:piece)
                    let speech: Double
                    if let speechEvidence {
                        speech = speechEvidence.reduce(0) { $0 + max(0,min(range.upperBound-sourceStart.seconds,$1.upperBound)-max(range.lowerBound-sourceStart.seconds,$1.lowerBound)) }
                    } else {
                        let report = try await VoiceActivity.analyze(url:audio,sourceStart:.zero,duration:MediaTime(seconds:range.upperBound-range.lowerBound))
                        speech = report.confidentSpeech.reduce(0) {$0+$1.upperBound-$1.lowerBound}
                    }
                    let available = budget.remainingWall-Date().timeIntervalSince(begun)
                    guard available > 0.05 else { observations.append(LanguageRepair.observation(range:range,result:nil,speechSeconds:speech,reason:"timeBudget")); break }
                    let log = try await run(executable:configuration.runtimeURL,arguments:["-m",configuration.modelURL.path,"-f",audio.path,"-dl","-ng","-t","4"],directory:workspace,timeout:available,progress:nil)
                    let observation = LanguageRepair.observation(range:range,result:SourceLanguageAnalysis.acousticResult(log:log),speechSeconds:speech)
                    observations.append(observation)
                    guard observation.state == .supported, let target = observation.language else { continue }
                    let owned = cues.filter {$0.start.seconds < range.upperBound && $0.start.seconds+$0.duration.seconds > range.lowerBound && !CoverageRepair.isMarker($0.text)}
                    let conflict = target != language || owned.contains {let d=SentenceLanguage.detect($0.text,clipLanguage:language);return !d.needsReview && d.language != target}
                    guard conflict,let core=LanguageRepair.coreRange(cues:cues,probe:range),
                          !repairedRanges.contains(where: {$0.lowerBound < core.upperBound && $0.upperBound > core.lowerBound}) else {continue}
                    let a=core.lowerBound,b=core.upperBound
                    let hasOwned=cues.contains {$0.start.seconds < b && $0.start.seconds+$0.duration.seconds > a}
                    // At least six seconds of continuous core is already context. An empty gap
                    // has no old cue boundaries to borrow; extra padding must not spill over it.
                    let lo=hasOwned ? max(sourceStart.seconds,a-1):a,hi=hasOwned ? min(end,b+1):b
                    let span=hi-lo, remaining=budget.remainingWall-Date().timeIntervalSince(begun)
                    guard remaining > 0.05,budget.reserveRetry(span) else { continue }
                    repairedRanges.append(core)
                    let context=CompactedTimeline(regions:[(lo-sourceStart.seconds)...(hi-sourceStart.seconds)],recordingDuration:extracted)
                    let retryAudio=workspace.appendingPathComponent("language-retry-\(i).wav")
                    do {
                        try writeCompacted(from:wav,to:retryAudio,timeline:context)
                        let again=try await recognise("language-retry-\(i)",extra:[],audio:retryAudio,map:.some(context),forcedLanguage:target,timeout:remaining,progress:nil)
                        let merged=LanguageRepair.merge(original:cues,replacement:again.cues,range:core,language:target)
                        cues=merged.cues; attempts.append(LanguageRepairAttempt(start:a,end:b,language:target,outcome:merged.outcome))
                    } catch { if Task.isCancelled || error is CancellationError {throw CancellationError()}; attempts.append(LanguageRepairAttempt(start:a,end:b,language:target,outcome:"failed")) }
                } catch {
                    if Task.isCancelled || error is CancellationError {throw CancellationError()}
                    observations.append(LanguageRepair.observation(range:range,result:nil,speechSeconds:0,reason:"probeUnavailable: " + String(error.localizedDescription.prefix(200))))
                }
            }
        }
        try Task.checkCancellation()
        guarded=RepetitionGuard.reviewed(cues)
        progress?(1)
        var transcript = LocalTranscript(cues: cues, engine: "\(engineVersion) · \(configuration.modelSpec.name) · CPU/Accelerate", language: language, sourceStart: sourceStart,
                                         duration: min(duration ?? MediaTime(seconds:extracted),MediaTime(seconds: extracted)), elapsedSeconds: Date().timeIntervalSince(begun), sourceChannelIndex: sourceChannelIndex)
        transcript.audioSelection = selection
        transcript.languageObservations = observations; transcript.languageRepairAttempts = attempts; transcript.languageRepairCost = budget.difference(from:before)
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
            guard first >= 0,first < input.length else {throw AudioAnalysisError("언어 확인 오디오 범위가 원본을 벗어났습니다.")}
            var remaining = min(input.length-first,AVAudioFramePosition((piece.length*rate).rounded()))
            guard remaining > 0,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16_384) else {throw AudioAnalysisError("음성 복사 버퍼를 만들 수 없습니다.")}
            input.framePosition=first
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into:buffer,frameCount:AVAudioFrameCount(min(remaining,16_384)))
                guard buffer.frameLength > 0 else {throw AudioAnalysisError("음성 복사가 끝나기 전에 원본 읽기가 종료됐습니다.")}
                try output.write(from:buffer);remaining -= AVAudioFramePosition(buffer.frameLength)
            }
            if i < timeline.pieces.count - 1, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: joinFrames) {
                silence.frameLength = joinFrames
                memset(silence.int16ChannelData![0], 0, Int(joinFrames) * MemoryLayout<Int16>.size)
                try output.write(from: silence)
            }
        }
    }
    static func extractAudio(url: URL, sourceStart: MediaTime, duration: MediaTime?, destination: URL, preferredChannel: Int = -1, audioSelection: AudioChannelSelection? = nil, channelSelected: ((Int) -> Void)? = nil) async throws -> Double {
        let selection: AudioChannelSelection
        if let audioSelection { selection = audioSelection }
        else { selection = try await AudioChannelSelection.resolve(url: url, sourceStart: sourceStart, duration: duration, preferredChannel: preferredChannel) }
        guard preferredChannel < 0 || (selection.primary == preferredChannel && selection.secondary == nil) else { throw AudioAnalysisError("분석 채널과 인식 채널이 다릅니다.") }
        channelSelected?(selection.primary)
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
            if converter == nil {
                nativeRate = chunk.sampleRate
                guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false),
                      let made = AVAudioConverter(from: source, to: target) else { throw AudioAnalysisError("음성 변환기를 만들 수 없습니다.") }
                made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter = made
            }
            guard chunk.sampleRate == nativeRate else { throw AudioAnalysisError("음성 추출 중 샘플레이트가 변경되었습니다.") }
            var mono = try selection.mono(chunk)
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
    @discardableResult static func run(executable: URL, arguments: [String], directory: URL, timeout: Double? = nil,
                            progress: (@Sendable (Double?) -> Void)?) async throws -> String {
        let result = try await execute(executable: executable, arguments: arguments, directory: directory, timeout: timeout, progress: progress)
        try WhisperOutputContract.requireProcessSuccess(result, phase: "languageProbe", directory: directory)
        return result.stderrTail
    }
    /// Captures termination and drains stderr before returning. Raw stderr remains in memory
    /// for acoustic language parsing; user-visible errors and disk diagnostics never include it.
    static func execute(executable: URL, arguments: [String], directory: URL, timeout: Double? = nil,
                        progress: (@Sendable (Double?) -> Void)?) async throws -> WhisperProcessResult {
        let started = ProcessInfo.processInfo.systemUptime
        let process = Process(), output = Pipe(), controller = ProcessController()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = output
        let log = LockedLog()
        let drain = DispatchGroup(); drain.enter()
        DispatchQueue.global().async {
            defer { drain.leave() }
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty {break}
                let text=String(decoding:data,as:UTF8.self);log.append(text)
                for line in text.components(separatedBy:.newlines) where line.contains("progress") {
                    let components=line.components(separatedBy:CharacterSet.decimalDigits.inverted).filter {!$0.isEmpty}
                    if let value=components.compactMap(Double.init).last,(0...100).contains(value) {progress?(0.1+0.85*value/100)}
                }
            }
        }
        defer { try? output.fileHandleForReading.close() }
        let deadline = timeout.map { seconds in DispatchWorkItem { controller.expire() } }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WhisperProcessResult, Error>) in
                process.terminationHandler = { task in
                  drain.notify(queue:.global()) {
                    if controller.cancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(returning: WhisperProcessResult(status: task.terminationStatus,
                        reason: task.terminationReason == .exit ? .exit : .uncaughtSignal,
                        timedOut: controller.timedOut, elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started),
                        stderrTail: log.tail, launchErrorDomain: nil, launchErrorCode: nil)) }
                  }
                }
                do { try controller.start(process); try? output.fileHandleForWriting.close(); if let timeout,let deadline { DispatchQueue.global().asyncAfter(deadline:.now()+max(0.01,timeout),execute:deadline) }; progress?(nil) }
                catch {
                    try? output.fileHandleForWriting.close(); process.terminationHandler = nil
                    drain.notify(queue:.global()) {
                        if controller.cancelled || error is CancellationError { continuation.resume(throwing: CancellationError()) }
                        else { let issue = error as NSError
                            continuation.resume(returning: WhisperProcessResult(status: nil, reason: .launchFailure,
                                timedOut: false, elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started),
                                stderrTail: log.tail, launchErrorDomain: issue.domain, launchErrorCode: issue.code)) }
                    }
                }
            }
        }, onCancel: { controller.cancel() })
    }
    private final class LockedLog: @unchecked Sendable {
        private let lock = NSLock(); private var value = ""
        func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value = String((value + text).suffix(16_384)) }
        var tail: String { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class ProcessController: @unchecked Sendable {
        private let lock = NSLock(); private var process: Process?; private var didCancel = false; private var didTimeout = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return didCancel }
        var timedOut: Bool {lock.lock();defer {lock.unlock()};return didTimeout}
        func expire() {lock.lock();didTimeout=true;let running=process;lock.unlock();stop(running)}
        private func stop(_ running:Process?) {
            guard let running,running.isRunning else {return};running.terminate()
            DispatchQueue.global().asyncAfter(deadline:.now()+1) {if running.isRunning {kill(running.processIdentifier,SIGKILL)}}
        }
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !didCancel else { throw CancellationError() }
            self.process = process; try process.run()
        }
        func cancel() {
            lock.lock(); didCancel = true; let running = process; lock.unlock()
            stop(running)
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

/// Flags possible Whisper repetition loops without deleting unverified speech: the same line (after normalisation) repeated
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
    /// Flags every caption in a suspicious run. Identical text alone cannot prove a hallucination.
    public static func reviewed(_ cues: [CaptionCue]) -> (cues: [CaptionCue], removed: Int, flagged: [Double]) {
        let keys = cues.map { loopKey($0.text) }
        var suspects = Set<Int>()
        var i = 0
        while i < cues.count {
            var j = i + 1
            while j < cues.count, !keys[i].isEmpty, keys[j] == keys[i] { j += 1 }
            if qualifies(keys[i], j - i) { for k in i..<j { suspects.insert(k) } }
            i = j
        }
        i = 0
        while i + 2 < cues.count {
            var j = i + 2
            while j < cues.count, !keys[j].isEmpty, keys[j] == keys[j - 2], keys[j] != keys[j - 1] { j += 1 }
            if j - i >= minimumRun * 2 && qualifies(keys[i], (j - i) / 2) { for k in i..<j { suspects.insert(k) }; i = j } else { i += 1 }
        }
        let flagged = suspects.sorted().map { cues[$0].start.seconds }
        return (cues, 0, flagged)
    }
    /// Source compatibility for callers of the older API; no destructive collapsing remains.
    @available(*, deprecated, renamed: "reviewed")
    public static func collapsed(_ cues: [CaptionCue]) -> (cues: [CaptionCue], removed: Int, flagged: [Double]) {
        reviewed(cues)
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

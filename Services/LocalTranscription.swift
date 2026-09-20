import Foundation
import AVFoundation
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
    public static let base = WhisperModelSpec(name: "Whisper base · 다국어 (한국어)", fileName: "ggml-base.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin")!,
        byteCount: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        license: "MIT", licenseURL: URL(string: "https://github.com/openai/whisper/blob/main/LICENSE")!, recommendedFreeBytes: 400_000_000)
}
public struct WhisperConfiguration: Sendable {
    public let runtimeURL: URL
    public let modelURL: URL
    public init(runtimeURL: URL? = nil, modelURL: URL? = nil) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Whisper/whisper-cli")
        self.runtimeURL = runtimeURL ?? ((bundled.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true) ? bundled! : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Whisper/whisper-cli"))
        self.modelURL = modelURL ?? Self.defaultModelURL
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
}
public enum WhisperModelInstaller {
    /// Explicit consent boundary. Call only from a user-approved model installation action; never at startup.
    public static func installBaseModel(approvedByUser: Bool, destination: URL? = nil) async throws -> URL {
        guard approvedByUser else { throw AudioAnalysisError("모델 출처·MIT 라이선스·147,951,465바이트·SHA-256을 확인하고 설치에 동의해야 합니다.") }
        let destination = destination ?? WhisperConfiguration.defaultModelURL, spec = WhisperModelSpec.base
        guard destination.isFileURL else { throw AudioAnalysisError("모델 저장 위치는 로컬 폴더여야 합니다.") }
        if FileManager.default.fileExists(atPath: destination.path) { try verifyModel(at: destination); return destination }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= spec.recommendedFreeBytes else { throw AudioAnalysisError("모델 설치에 최소 400MB의 빈 공간이 필요합니다.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: spec.downloadURL); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (download, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AudioAnalysisError("모델 다운로드 응답이 올바르지 않습니다.") }
        try Task.checkCancellation(); try verifyModel(at: download)
        // Copy to same-volume staging, verify again, then rename. An existing destination is never overwritten.
        let staged = directory.appendingPathComponent(".jhcut-model-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: download, to: staged)
        try verifyModel(at: staged); try Task.checkCancellation()
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }
    public static func verifyModel(at url: URL) throws {
        let spec = WhisperModelSpec.base
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == spec.byteCount else { throw AudioAnalysisError("다국어 base 모델 크기가 다릅니다. 승인된 ggml-base.bin을 선택하세요 (.en 모델 사용 불가).") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty { try Task.checkCancellation(); hash.update(data: block) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == spec.sha256 else { throw AudioAnalysisError("모델 SHA-256 검증에 실패했습니다. 파일이 변조되었거나 다운로드가 불완전합니다.") }
    }
}
public enum LocalTranscription {
    /// Read-only. Does not install a model, access a microphone, request system permission, or start recognition.
    public static func availability(configuration: WhisperConfiguration = .init()) -> LocalTranscriptionAvailability {
        let fm = FileManager.default
        let runtime = fm.isExecutableFile(atPath: configuration.runtimeURL.path)
        let size = (try? fm.attributesOfItem(atPath: configuration.modelURL.path)[.size] as? NSNumber)?.int64Value
        let model = size == WhisperModelSpec.base.byteCount
        let message = !runtime ? "로컬 whisper.cpp 실행 파일이 없습니다." : !model ? "한국어 다국어 base 모델 설치가 필요합니다. 설치 전 출처·용량·해시 확인 및 동의가 필요합니다." : "로컬 whisper.cpp 준비됨 · 실행 전 SHA-256 검증 · 음성 업로드 없음"
        return LocalTranscriptionAvailability(canTranscribe: runtime && model, message: message, runtimeURL: configuration.runtimeURL, modelURL: configuration.modelURL)
    }
    public static func transcribe(url: URL, sourceStart: MediaTime = .zero, duration: MediaTime? = nil,
                                  configuration: WhisperConfiguration = .init(), progress: (@Sendable (Double?) -> Void)? = nil) async throws -> LocalTranscript {
        let begun = Date(); try Task.checkCancellation()
        let state = availability(configuration: configuration)
        guard state.canTranscribe else { throw AudioAnalysisError(state.message) }
        progress?(0); try WhisperModelInstaller.verifyModel(at: configuration.modelURL)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("JHCutSpeech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let wav = workspace.appendingPathComponent("source.wav")
        var sourceChannelIndex = 0
        let extracted = try await extractAudio(url: url, sourceStart: sourceStart, duration: duration, destination: wav) { sourceChannelIndex = $0 }
        progress?(0.1)
        let prefix = workspace.appendingPathComponent("transcript")
        let args = ["-m", configuration.modelURL.path, "-f", wav.path, "-l", "ko", "-osrt", "-of", prefix.path,
                    "-ml", "42", "-sow", "-pp", "-ng", "-t", String(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))]
        try await run(executable: configuration.runtimeURL, arguments: args, directory: workspace, progress: progress)
        try Task.checkCancellation()
        let srt = try String(contentsOf: prefix.appendingPathExtension("srt"), encoding: .utf8)
        let relative = try SRTCodec.parse(srt), limit = sourceStart.seconds + extracted
        let cues = relative.compactMap { cue -> CaptionCue? in
            let start = max(sourceStart.seconds, sourceStart.seconds + cue.start.seconds)
            let end = min(limit, sourceStart.seconds + cue.start.seconds + cue.duration.seconds)
            guard end > start, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CaptionCue(start: MediaTime(seconds: start), duration: MediaTime(seconds: end - start), text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress?(1)
        return LocalTranscript(cues: cues, engine: "whisper.cpp v1.9.4 · multilingual base · CPU/Accelerate", language: "ko", sourceStart: sourceStart,
                               duration: MediaTime(seconds: extracted), elapsedSeconds: Date().timeIntervalSince(begun), sourceChannelIndex: sourceChannelIndex)
    }
    static func extractAudio(url: URL, sourceStart: MediaTime, duration: MediaTime?, destination: URL, channelSelected: ((Int) -> Void)? = nil) async throws -> Double {
        // Two streaming passes choose ONE consistent highest-energy native channel, then resample it to mono.
        // This avoids cancellation of opposite-phase stereo. Dialogue on a quieter separate channel may need external channel isolation.
        var channelEnergy: [Double] = []
        _ = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration, sampleRate: 16_000) { chunk in
            if channelEnergy.isEmpty { channelEnergy = [Double](repeating: 0, count: chunk.channels) }
            guard channelEnergy.count == chunk.channels else { throw AudioAnalysisError("음성 추출 중 채널 수가 변경되었습니다.") }
            for index in chunk.values.indices { let value = Double(chunk.values[index]); channelEnergy[index % chunk.channels] += value * value }
        }
        let selectedChannel = channelEnergy.indices.max { channelEnergy[$0] < channelEnergy[$1] } ?? 0
        channelSelected?(selectedChannel)
        // Native decoder produces only the requested source range. Transcription uses 16kHz mono PCM16 WAV.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: Int64 = 0
        func write(_ values: [Float]) throws {
            guard !values.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(values.count)
            values.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: values.count) }
            try file!.write(from: buffer); frames += Int64(values.count)
        }
        let range = try await SourcePCM.read(url: url, sourceStart: sourceStart, duration: duration, sampleRate: 16_000) { chunk in
            let expected = max(0, Int64(((chunk.start - sourceStart.seconds) * 16_000).rounded()))
            while expected > frames { try Task.checkCancellation(); try write([Float](repeating: 0, count: Int(min(expected - frames, 16_000)))) }
            guard selectedChannel < chunk.channels else { throw AudioAnalysisError("선택한 음성 채널을 읽을 수 없습니다.") }
            let mono = stride(from: selectedChannel, to: chunk.values.count, by: chunk.channels).map { chunk.values[$0] }
            let skip = min(mono.count, max(0, Int(frames - expected)))
            try write(Array(mono.dropFirst(skip)))
        }
        guard frames > 0 else { throw AudioAnalysisError("선택 범위에서 음성을 읽지 못했습니다.") }
        let requestedFrames = Int64((range.duration * 16_000).rounded())
        while requestedFrames > frames { try Task.checkCancellation(); try write([Float](repeating: 0, count: Int(min(requestedFrames - frames, 16_000)))) }
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

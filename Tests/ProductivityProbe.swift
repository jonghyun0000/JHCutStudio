import Foundation
import AVFoundation
import CryptoKit

struct ProductivityCheck: Codable { let name: String; let passed: Bool; let detail: String }
@main struct ProductivityProbe {
    static func main() async {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Productivity-0.3", isDirectory: true)
        var checks: [ProductivityCheck] = [], measurements: [String: AudioAnalysisResult] = [:]
        func record(_ name: String, _ condition: Bool, _ detail: String = "") { checks.append(.init(name: name, passed: condition, detail: detail)); print("\(condition ? "PASS" : "FAIL") \(name): \(detail)") }
        func failure(_ name: String, _ operation: () async throws -> Void) async {
            do { try await operation(); record(name, false, "Expected an error") } catch { record(name, true, error.localizedDescription) }
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let fixture = output.appendingPathComponent("오디오 분석 원본.wav"), sine = output.appendingPathComponent("위상 반전 스테레오.wav"), zero = output.appendingPathComponent("디지털 무음.wav")
            try writeWave(fixture, seconds: 6, channels: 2) { t, channel in
                let amplitude: Float
                if t < 0.5 || (t >= 1.5 && t < 2) || (t >= 3 && t < 3.2) || t >= 5 { amplitude = 0 }
                else if t < 1.5 { amplitude = 0.5 }
                else if t < 2.02 { return channel == 0 ? 1 : -1 }
                else if t >= 3.2 && t < 4 { amplitude = 0.001 }
                else { amplitude = 0.25 }
                return amplitude * Float(sin(2 * Double.pi * 440 * t)) * (channel == 0 ? 1 : -1)
            }
            try writeWave(sine, seconds: 2, channels: 2) { t, channel in Float(0.5 * sin(2 * Double.pi * 440 * t)) * (channel == 0 ? 1 : -1) }
            try writeWave(zero, seconds: 1, channels: 1) { _, _ in 0 }
            let digest = SHA256.hash(data: try Data(contentsOf: fixture))
            let tone = try await AudioAnalysis.analyze(url: sine); measurements["antiphaseSine"] = tone
            record("Native stereo channels and frame count", tone.channelCount == 2 && tone.sampleRate == 48_000 && tone.frameCount == 96_000)
            record("Peak -6.0206 dBFS", abs((tone.peakDBFS ?? 99) + 6.020599913) < 0.0001, "\(tone.peakDBFS ?? 99)")
            record("RMS -9.0309 dBFS without opposite-phase cancellation", abs((tone.rmsDBFS ?? 99) + 9.030899869) < 0.0001, "\(tone.rmsDBFS ?? 99)")
            record("Peak normalization targets -1 dBFS, not LUFS", abs((tone.normalizationGainDB ?? 99) - 5.020599913) < 0.0001)
            record("Loud sine contains no silence", tone.silenceRegions.isEmpty)
            let waveform = try await WaveformAnalyzer.analyze(url: sine, bins: 80)
            record("Opposite-phase stereo waveform retains native-channel peaks", waveform.count == 80 && waveform.allSatisfy { $0 > 0.48 && $0 < 0.52 }, "min=\(waveform.min() ?? 0) max=\(waveform.max() ?? 0)")
            let full = try await AudioAnalysis.analyze(url: fixture); measurements["complete"] = full
            record("Streaming PCM counts full 6-second source", full.frameCount == 288_000 && full.decodedDuration == 6)
            record("Full-scale clipping channel-sample count", full.clippingSampleCount == 1_920 && full.peak == 1, "\(full.clippingSampleCount)")
            record("Four real silence regions including low-level audio", full.silenceRegions.count == 4, "\(full.silenceRegions.map { [$0.start.seconds,$0.duration.seconds] })")
            record("Silence starts and durations within one window", full.silenceRegions.count == 4 && zip(full.silenceRegions, [(0.0,0.5),(1.5,0.5),(3.0,1.0),(5.0,1.0)]).allSatisfy { abs($0.0.start.seconds - $0.1.0) < 0.0201 && abs($0.0.duration.seconds - $0.1.1) < 0.0201 })
            let trimmed = try await AudioAnalysis.analyze(url: fixture, sourceStart: MediaTime(seconds: 0.75), duration: MediaTime(seconds: 1.1), options: .init(minimumSilenceDuration: 0.3)); measurements["trimmed"] = trimmed
            record("Source offset and duration exact", trimmed.frameCount == 52_800 && trimmed.sourceStart.seconds == 0.75 && abs(trimmed.duration.seconds - 1.1) < 0.00001)
            record("Trim excludes later clipped samples", trimmed.clippingSampleCount == 0 && abs(trimmed.peak - 0.5) < 0.0001)
            record("Silence timestamps remain absolute source times", trimmed.silenceRegions.count == 1 && abs(trimmed.silenceRegions[0].start.seconds - 1.5) <= 0.0201 && trimmed.silenceRegions[0].start.seconds > 0.75)
            let silence = try await AudioAnalysis.analyze(url: zero); measurements["digitalSilence"] = silence
            record("Digital silence has no fabricated dB floor or normalization gain", silence.peakDBFS == nil && silence.rmsDBFS == nil && silence.normalizationGain == nil && silence.silenceRegions.count == 1)
            let quiet = try await AudioAnalysis.analyze(url: fixture, sourceStart: MediaTime(seconds: 3.2), duration: MediaTime(seconds: 0.8)); measurements["quiet"] = quiet
            record("Excessive gain is explicitly limited", quiet.normalizationBoostLimited && quiet.normalizationGainDB == 12 && (quiet.normalizationGain ?? 99) < 4)
            let threshold = try await AudioAnalysis.analyze(url: fixture, sourceStart: MediaTime(seconds: 3.2), duration: MediaTime(seconds: 0.8), options: .init(silenceThresholdDBFS: -80))
            record("Silence threshold changes actual detections", threshold.silenceRegions.isEmpty)
            let longMinimum = try await AudioAnalysis.analyze(url: fixture, options: .init(minimumSilenceDuration: 0.75))
            record("Minimum silence length filters short candidates", longMinimum.silenceRegions.count == 2)
            await failure("Negative source start rejected") { _ = try await AudioAnalysis.analyze(url: fixture, sourceStart: MediaTime(seconds: -0.1)) }
            await failure("Zero duration rejected") { _ = try await AudioAnalysis.analyze(url: fixture, duration: .zero) }
            await failure("Out-of-bounds source range rejected") { _ = try await AudioAnalysis.analyze(url: fixture, sourceStart: MediaTime(seconds: 5), duration: MediaTime(seconds: 2)) }
            await failure("Non-finite options rejected") { _ = try await AudioAnalysis.analyze(url: fixture, options: .init(silenceThresholdDBFS: .nan)) }
            await failure("Missing source rejected") { _ = try await AudioAnalysis.analyze(url: output.appendingPathComponent("없는 파일.wav")) }
            let corrupt = output.appendingPathComponent("손상.wav"); try Data("not audio".utf8).write(to: corrupt)
            await failure("Corrupt source rejected") { _ = try await AudioAnalysis.analyze(url: corrupt) }
            let invalidPCM = output.appendingPathComponent("비정상 샘플.wav")
            try writeWave(invalidPCM, seconds: 0.1, channels: 1) { _, _ in .nan }
            await failure("Non-finite PCM samples rejected") { _ = try await AudioAnalysis.analyze(url: invalidPCM) }
            let cancelled = Task { try await AudioAnalysis.analyze(url: fixture) }; cancelled.cancel()
            do { _ = try await cancelled.value; record("Analysis cancellation", false) } catch is CancellationError { record("Analysis cancellation", true) } catch { record("Analysis cancellation", false, error.localizedDescription) }
            let m4a = output.appendingPathComponent("압축 AAC.m4a")
            if FileManager.default.fileExists(atPath: m4a.path) { try FileManager.default.removeItem(at: m4a) }
            let exporter = AVAssetExportSession(asset: AVURLAsset(url: sine), presetName: AVAssetExportPresetAppleM4A)!
            exporter.outputURL = m4a; exporter.outputFileType = .m4a
            await withCheckedContinuation { continuation in exporter.exportAsynchronously { continuation.resume() } }
            guard exporter.status == .completed else { throw exporter.error ?? AudioAnalysisError("AAC fixture export failed") }
            let aac = try await AudioAnalysis.analyze(url: m4a, sourceStart: MediaTime(seconds: 0.25), duration: MediaTime(seconds: 0.75)); measurements["aacRange"] = aac
            record("Compressed AAC range decoded with RMS tolerance", abs(aac.decodedDuration - 0.75) < 0.001 && abs(aac.rms - tone.rms) < 0.015, "duration=\(aac.decodedDuration) RMS=\(aac.rms)")
            let extraction = output.appendingPathComponent("인식 입력 16k.wav")
            let extracted = try await LocalTranscription.extractAudio(url: fixture, sourceStart: MediaTime(seconds: 0.75), duration: MediaTime(seconds: 1.1), destination: extraction)
            let extractedFile = try AVAudioFile(forReading: extraction)
            record("Transcription extracts requested range as 16kHz mono WAV", extracted == 1.1 && extractedFile.length == 17_600 && extractedFile.processingFormat.sampleRate == 16_000 && extractedFile.processingFormat.channelCount == 1)
            let extractionAnalysis = try await AudioAnalysis.analyze(url: extraction)
            record("Opposite-phase stereo survives speech extraction", extractionAnalysis.peak > 0.48 && extractionAnalysis.rms > 0.25, "peak=\(extractionAnalysis.peak) RMS=\(extractionAnalysis.rms)")
            record("Original content unchanged", SHA256.hash(data: try Data(contentsOf: fixture)) == digest)
            let noModel = WhisperConfiguration(modelURL: output.appendingPathComponent("no-model.bin"))
            record("Missing model availability is honest", !LocalTranscription.availability(configuration: noModel).canTranscribe)
            await failure("Model install requires explicit approval without network") { _ = try await WhisperModelInstaller.installBaseModel(approvedByUser: false, destination: output.appendingPathComponent("must-not-download.bin")) }
            record("Unapproved model has not appeared", !FileManager.default.fileExists(atPath: output.appendingPathComponent("must-not-download.bin").path))
            await failure("Incorrect-size model rejected before recognition") { try WhisperModelInstaller.verifyModel(at: corrupt) }
            let tamperedModel = output.appendingPathComponent("tampered-base-test.bin")
            FileManager.default.createFile(atPath: tamperedModel.path, contents: nil)
            let invalidModelFile = try FileHandle(forWritingTo: tamperedModel)
            try invalidModelFile.truncate(atOffset: UInt64(WhisperModelSpec.base.byteCount)); try invalidModelFile.close()
            do {
                try WhisperModelInstaller.verifyModel(at: tamperedModel); record("Correct-size tampered model fails SHA256", false)
            } catch { record("Correct-size tampered model fails SHA256", error.localizedDescription.contains("SHA-256"), error.localizedDescription) }
            try FileManager.default.removeItem(at: tamperedModel)
            await failure("Missing model transcription fails closed") { _ = try await LocalTranscription.transcribe(url: fixture, configuration: noModel) }
            let subprocess = Task { try await LocalTranscription.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: output, progress: nil) }
            try await Task.sleep(nanoseconds: 150_000_000)
            let cancelStart = Date(); subprocess.cancel()
            do { try await subprocess.value; record("Recognition subprocess cancellation", false) } catch is CancellationError { record("Recognition subprocess cancellation", Date().timeIntervalSince(cancelStart) < 3) } catch { record("Recognition subprocess cancellation", false, error.localizedDescription) }
            let apple = await AppleLocalTranscription.availability()
            try JSONEncoder().encode(apple).write(to: output.appendingPathComponent("apple-speech-availability.json"))
            record("Apple status probe does not claim untested transcription", !apple.canTranscribe, apple.message)
            if CommandLine.arguments.contains("--transcribe") {
                let speech = output.appendingPathComponent("한국어 음성.aiff")
                let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-v", "Yuna", "-r", "145", "-o", speech.path, "안녕하세요. 오늘은 한국어 자동 자막을 시험합니다. 영상과 소리의 시간을 정확하게 맞춥니다. 편집한 결과를 저장하고 다시 확인합니다."]
                try say.run(); say.waitUntilExit(); guard say.terminationStatus == 0 else { throw AudioAnalysisError("Installed Korean voice fixture failed") }
                let transcript = try await LocalTranscription.transcribe(url: speech)
                try JSONEncoder().encode(transcript).write(to: output.appendingPathComponent("korean-transcript.json"))
                try SRTCodec.serialize(transcript.cues).write(to: output.appendingPathComponent("한국어 실제 인식.srt"), atomically: true, encoding: .utf8)
                let text = transcript.cues.map(\.text).joined(separator: " ")
                record("Actual offline Korean speech recognition", !transcript.cues.isEmpty && text.contains("한국어") && text.contains("자막"), text)
                record("Actual caption timings stay within source", transcript.cues.allSatisfy { $0.start >= .zero && $0.duration > .zero && $0.start + $0.duration <= transcript.duration })
                let offset = try await LocalTranscription.transcribe(url: speech, sourceStart: MediaTime(seconds: 2), duration: MediaTime(seconds: min(8, transcript.duration.seconds - 2)))
                try JSONEncoder().encode(offset).write(to: output.appendingPathComponent("korean-offset-transcript.json"))
                record("Actual transcription source offset respected", !offset.cues.isEmpty && offset.cues.allSatisfy { $0.start >= MediaTime(seconds: 2) && $0.start + $0.duration <= MediaTime(seconds: 2) + offset.duration })
            }
        } catch { record("Unexpected validation failure", false, error.localizedDescription) }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(checks).write(to: output.appendingPathComponent("checks.json"))
            try encoder.encode(measurements).write(to: output.appendingPathComponent("audio-measurements.json"))
        } catch { print(error.localizedDescription); exit(2) }
        print("PRODUCTIVITY_RESULT checks=\(checks.count) failures=\(checks.filter { !$0.passed }.count)")
        exit(checks.allSatisfy(\.passed) ? 0 : 1)
    }
    static func writeWave(_ url: URL, seconds: Double, channels: Int, sample: (Double, Int) -> Float) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * 48_000)
        for start in stride(from: 0, to: frames, by: 4096) {
            let count = min(4096, frames - start), buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels { for offset in 0..<count { buffer.floatChannelData![channel][offset] = sample(Double(start + offset) / 48_000, channel) } }
            try file.write(from: buffer)
        }
    }
}

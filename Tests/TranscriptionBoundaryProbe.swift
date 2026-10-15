import Foundation
import AVFoundation
import CryptoKit
@testable import JHCutCore

/// Fixed recognizer output tests merging, NOT speech recognition accuracy.
@main struct TranscriptionBoundaryProbe {
    static func cue(_ start: Double, _ end: Double, _ text: String) -> CaptionCue {
        CaptionCue(start: MediaTime(seconds: start), duration: MediaTime(seconds: end) - MediaTime(seconds: start), text: text)
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Stage6/Boundary")
        var checks = 0, failures = 0, records: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) {
            checks += 1; if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)"); records.append(["name": name, "passed": ok])
        }
        let fixture: [[CaptionCue]] = [
            [cue(299.7, 300, "경계 앞" )],
            [cue(300, 300.8, "경계 뒤"), cue(300.1, 300.18, "네"), cue(300.2, 300.28, "네"),
             cue(301, 302, "다시 말합니다"), cue(302, 303, "다시 말합니다"), cue(303, 304, "다시 말합니다"), cue(599.8, 600, "두 번째 앞")],
            [cue(600, 600.7, "두 번째 뒤"), cue(600.1, 600.3, "시작합니다")]
        ]
        let windows = fixture.enumerated().map { TranscriptionWindowResult(index: $0.offset, sourceStart: MediaTime(seconds: Double($0.offset) * 300), duration: MediaTime(seconds: $0.offset == 2 ? 1 : 300), cues: $0.element, language: "ko", channel: 0, elapsedSeconds: 1) }
        let merged = TranscriptionTiming.assembledCues(windows.reversed())
        let expected = fixture.flatMap { $0 }.sorted { $0.start < $1.start }
        check("4:59.7–5:00.8 received fragments both survive", merged.contains(fixture[0][0]) && merged.contains(fixture[1][0]))
        check("5:00.1 onset survives leading half second", merged.contains(fixture[1][1]))
        check("9:59.8–10:00.7 received fragments both survive", merged.contains(fixture[1].last!) && merged.contains(fixture[2][0]))
        check("All received cue IDs preserved once; zero merger loss or duplication", merged.map(\.id) == expected.map(\.id) && Set(merged.map(\.id)).count == expected.count)
        check("Two real short replies within 0.2s are preserved", merged.filter { $0.text == "네" }.count == 2)
        let repeated = RepetitionGuard.reviewed(Array(fixture[1][3...5]))
        check("Three consecutive identical sentences preserved, flagged for review", repeated.cues == Array(fixture[1][3...5]) && repeated.removed == 0 && repeated.flagged.count == 3)
        let tied = [cue(300.1, 300.2, "첫째"), cue(300.1, 300.3, "둘째")]
        var ties = windows; ties[1].cues = tied
        check("Equal start times keep window-local order", TranscriptionTiming.assembledCues(ties.reversed()).filter { $0.start == tied[0].start }.map(\.text) == ["첫째", "둘째"])

        // Selected source begins at 12.25s. Compact audio is NOT absolute media time.
        let compact = CompactedTimeline(regions: [299.7...300], recordingDuration: 300)
        let first = TranscriptionTiming.sourceCues([cue(0, 0.3, "경계 앞")], sourceStart: MediaTime(seconds: 12.25), duration: MediaTime(seconds: 300), compacted: compact)
        let next = TranscriptionTiming.sourceCues([cue(0, 0.8, "경계 뒤")], sourceStart: MediaTime(seconds: 312.25), duration: MediaTime(seconds: 300), compacted: CompactedTimeline(regions: [0...0.8], recordingDuration: 300))
        check("VAD compact time restores to original 311.95–312.25", first.count == 1 && first[0].start == MediaTime(seconds: 311.95) && first[0].duration == MediaTime(seconds: 0.3))
        check("Next compact window restores to original 312.25–313.05", next.count == 1 && next[0].start == MediaTime(seconds: 312.25) && next[0].duration == MediaTime(seconds: 0.8))
        let joined = CompactedTimeline(regions: [10...11, 20...21], recordingDuration: 30)
        check("Cue entirely in VAD join silence excluded before merging", TranscriptionTiming.sourceCues([cue(1.1, 1.5, "없는 음성")], sourceStart: MediaTime(seconds: 300), duration: MediaTime(seconds: 30), compacted: joined).isEmpty)
        let clipped = TranscriptionTiming.sourceCues([cue(299.7, 300.8, "잘린 끝")], sourceStart: MediaTime(seconds: 12.25), duration: MediaTime(seconds: 300))
        check("Recognizer-local end clamps to its own window, without leading deletion", clipped.count == 1 && clipped[0].start == MediaTime(seconds: 311.95) && clipped[0].duration == MediaTime(seconds: 0.3))
        var source = Clip(name: "선택 원본", start: MediaTime(seconds: 7), sourceStart: MediaTime(seconds: 12.25), duration: MediaTime(seconds: 301))
        source.playbackRate = PlaybackRate(numerator: 2, denominator: 1)
        let titles = CaptionEditing.automaticClips(cues: first + next, source: source, style: Title(text: ""))
        check("Absolute original times map once through trim and 2× to timeline", titles.count == 2 && titles[0].start == MediaTime(seconds: 156.85) && titles[0].duration == MediaTime(seconds: 0.15) && titles[1].start == MediaTime(seconds: 157) && titles[1].duration == MediaTime(seconds: 0.4))
        check("Connected caption retains original source position", titles.count == 2 && titles[1].connection?.sourceStart == MediaTime(seconds: 312.25))

        // Real Korean speech fixtures: exact audio spans on both 5-minute boundaries,
        // a separate 300.1s onset, and three genuine consecutive repeats. The recognizer
        // mock below tests merge/extraction independently of what Whisper happens to hear.
        let spoken = root.appendingPathComponent("known-좋아요.wav")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Yuna", "-r", "180", "-o", spoken.path, "--file-format=WAVE", "--data-format=LEF32@16000", "좋아요"]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw NSError(domain: "BoundaryFixture.say", code: 1) }
        let speechFile = try AVAudioFile(forReading: spoken, commonFormat: .pcmFormatFloat32, interleaved: false)
        let speech = AVAudioPCMBuffer(pcmFormat: speechFile.processingFormat, frameCapacity: AVAudioFrameCount(speechFile.length))!
        try speechFile.read(into: speech)
        let mono = Array(UnsafeBufferPointer(start: speech.floatChannelData![0], count: Int(speech.frameLength)))
        let audible = mono.indices.filter { abs(mono[$0]) > 0.005 }
        guard let begin = audible.first, let end = audible.last, end > begin else { throw NSError(domain: "BoundaryFixture.silent", code: 1) }
        let voice = Array(mono[begin...end])
        func writeSpeechFixture(_ name: String, spans: [(Double, Double)]) throws -> URL {
            let url = root.appendingPathComponent(name), format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for second in 0..<625 {
                for i in 0..<16_000 {
                    let t = Double(second) + Double(i) / 16_000
                    var value: Float = 0
                    for (a, b) in spans where t >= a && t < b {
                        let position = (t - a) / (b - a) * Double(voice.count - 1)
                        let j = min(voice.count - 2, Int(position)), f = Float(position - Double(j))
                        value += voice[j] * (1 - f) + voice[j + 1] * f
                    }
                    buffer.floatChannelData![0][i] = value
                }
                try file.write(from: buffer)
            }
            return url
        }
        let spans = [(299.7, 300.8), (302.0, 303.1), (304.0, 305.1), (306.0, 307.1), (599.8, 600.7)]
        let audio = try writeSpeechFixture("known-boundaries-625s.wav", spans: spans)
        _ = try writeSpeechFixture("known-onset-300.1s.wav", spans: [(300.1, 301.2)])
        try SRTCodec.serialize(spans.map { cue($0.0, $0.1, "좋아요") }).write(to: root.appendingPathComponent("known-boundaries.reference.srt"), atomically: true, encoding: .utf8)
        try SRTCodec.serialize([cue(300.1, 301.2, "좋아요")]).write(to: root.appendingPathComponent("known-onset.reference.srt"), atomically: true, encoding: .utf8)
        check("Audible Korean fixture, not silence/tone, covers both exact boundary spans", !voice.isEmpty && spans.first!.0 == 299.7 && spans.last!.1 == 600.7)

        let model = root.appendingPathComponent("mock-model.bin"), bytes = Data("deterministic recognizer fixture".utf8)
        try bytes.write(to: model)
        let spec = WhisperModelSpec(name: "TEST ONLY", fileName: model.lastPathComponent, downloadURL: model, byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), license: "test", licenseURL: model, recommendedFreeBytes: 0)
        let runtime = root.appendingPathComponent("mock-recognizer.sh")
        try #"""
        #!/bin/bash
        while [[ $# -gt 0 ]]; do if [[ "$1" == "-of" ]]; then out="$2"; fi; shift; done
        printf '1\n00:00:00,100 --> 00:00:00,180\n네\n\n2\n00:00:00,200 --> 00:00:00,280\n네\n\n3\n00:00:00,300 --> 00:00:00,380\n네\n\n4\n00:04:59,700 --> 00:05:00,800\n경계 앞\n' > "$out.srt"
        printf '{"result":{"language":"ko"},"transcription":[{"text":"네","offsets":{"from":100,"to":180}},{"text":"네","offsets":{"from":200,"to":280}},{"text":"네","offsets":{"from":300,"to":380}},{"text":"경계 앞","offsets":{"from":299700,"to":300800}}]}' > "$out.json"
        """#.write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let config = WhisperConfiguration(runtimeURL: runtime, modelURL: model, modelSpec: spec)
        var options = SpeechOptions(); options.language = "ko"
        let start = MediaTime(seconds: 12.25), duration = MediaTime(seconds: 605)
        let key = TranscriptionCheckpointKey(projectID: UUID(), clipID: UUID(), mediaSHA256: try await FileIdentity.sha256(audio), sourceStart: start, duration: duration, windowSeconds: 300, options: options, modelSHA256: spec.sha256)
        let store = TranscriptionCheckpointStore(root: root.appendingPathComponent("Checkpoints")), session = TranscriptionCheckpointSession(store: store, key: key)
        let task = Task.detached {
            try await LocalTranscription.transcribeLong(url: audio, sourceStart: start, duration: duration, configuration: config, options: options, checkpoint: session, detail: { d in
                if d.windowIndex == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        check("Cancellation after first actual 300s extraction retains only completed window", cancelled && store.completedWindows(for: key).keys.sorted() == [0])
        let resumed = try await LocalTranscription.transcribeLong(url: audio, sourceStart: start, duration: duration, configuration: config, options: options, checkpoint: session)
        let uninterrupted = try await LocalTranscription.transcribeLong(url: audio, sourceStart: start, duration: duration, configuration: config, options: options)
        let reloaded = try await LocalTranscription.transcribeLong(url: audio, sourceStart: start, duration: duration, configuration: config, options: options, checkpoint: session)
        check("300s windows: resume computes two and reuses one", resumed.reusedWindows == 1 && resumed.computedWindows == 2)
        check("Mock received output retains every valid cue (4 + 4 + 3)", resumed.cues.count == 11)
        check("Actual long pipeline retains 312.35s and 612.35s onsets", resumed.cues.contains { $0.start == MediaTime(seconds: 312.35) } && resumed.cues.contains { $0.start == MediaTime(seconds: 612.35) })
        let normalized = try SRTCodec.serialize(uninterrupted.cues)
        check("Cancellation/resume normalized SRT identical to uninterrupted", try SRTCodec.serialize(resumed.cues) == normalized)
        check("All-window reload normalized SRT identical; no recognizer work", try SRTCodec.serialize(reloaded.cues) == normalized && reloaded.computedWindows == 0 && reloaded.reusedWindows == 3)
        check("Merger output equals every checkpoint cue exactly once", resumed.cues == TranscriptionTiming.assembledCues(Array(store.completedWindows(for: key).values)))
        var oldKey = key; oldKey.engine = LocalTranscription.engineVersion + " · pipeline 3"
        let oldFolder = store.directory(for:oldKey)
        try FileManager.default.createDirectory(at:oldFolder,withIntermediateDirectories:true)
        try RecognitionCacheSafety.encoder().encode(oldKey).write(to:oldFolder.appendingPathComponent("manifest.json"))
        check("Current pipeline identity cannot load pipeline 3 windows", key.identifier != oldKey.identifier && store.completedWindows(for: key).count == 3)
        var refused = false
        do { _ = try await LocalTranscription.transcribeLong(url: audio, sourceStart: start, duration: duration, configuration: config, options: options, checkpoint: TranscriptionCheckpointSession(store: store, key: oldKey)) }
        catch { refused = "\(error)".contains("체크포인트") }
        check("Explicit stale pipeline session rejected before recognition", refused)
        // Actual Whisper on declared speech-only pieces of the same 625s original. This
        // separately records recognizer omissions; never conflate them with merger loss.
        let realConfig = WhisperConfiguration()
        let realKey = TranscriptionCheckpointKey(projectID: UUID(), clipID: UUID(), mediaSHA256: key.mediaSHA256, sourceStart: .zero, duration: duration, windowSeconds: 300, options: options, modelSHA256: realConfig.modelSpec.sha256, skipsSilence: true)
        let real = try await LocalTranscription.transcribeLong(url: audio, duration: duration, configuration: realConfig, options: options,
                         checkpoint: TranscriptionCheckpointSession(store: store, key: realKey), speechRegions: [299...308, 599...602])
        let realReceived = store.completedWindows(for: realKey).values.flatMap(\.cues)
        check("Actual Whisper with 300s windows: every received speech cue preserved", real.cues.count == realReceived.count && realReceived.allSatisfy { real.cues.contains($0) })
        check("Actual Whisper compacted result remains in original 299…308/599…602", real.cues.allSatisfy { ($0.start.seconds >= 299 && ($0.start + $0.duration).seconds <= 308.001) || ($0.start.seconds >= 599 && ($0.start + $0.duration).seconds <= 602.001) })
        try SRTCodec.serialize(real.cues).write(to: root.appendingPathComponent("known-boundaries.whisper.srt"), atomically: true, encoding: .utf8)
        let reference = try TranscriptReference.load(root.appendingPathComponent("known-boundaries.reference.srt"))
        let evaluation = try TranscriptEvaluation.evaluate(captions: real.cues.map { EvaluatedCaption(text: $0.text, start: $0.start.seconds, end: ($0.start + $0.duration).seconds) }, reference: reference, language: real.language, sourceRange: 0...duration.seconds, mediaDuration: 625)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evaluation).write(to: root.appendingPathComponent("known-boundaries.asr-evaluation.json"))
        print("MEASURE actual synthetic ASR score recorded separately; received=\(realReceived.count) merged=\(real.cues.count)")
        try normalized.write(to: root.appendingPathComponent("uninterrupted.srt"), atomically: true, encoding: .utf8)
        try SRTCodec.serialize(resumed.cues).write(to: root.appendingPathComponent("resumed.srt"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        print("TRANSCRIPTION_BOUNDARY_RESULT checks=\(checks) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

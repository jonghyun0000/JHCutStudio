import Foundation
@preconcurrency import AVFoundation
import CoreGraphics

/// Automatic checks of a finished export against what the timeline asked for. Reads the output
/// file only; nothing is modified.
public struct OutputQualityIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning, info }
    public var severity: Severity
    public var code: String
    public var message: String
    /// Output time in seconds, when the issue belongs to one moment.
    public var time: Double?
}

public struct OutputMeasurement: Codable, Equatable, Sendable {
    public var duration: Double
    public var videoDuration: Double?
    public var audioDuration: Double?
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var videoCodec: String
    public var audioTracks: Int
    public var audioPeakDBFS: Double?
}

public struct CaptionBurnInResult: Codable, Equatable, Sendable {
    public var time: Double
    public var text: String
    /// Share of the caption's solid glyph pixels found with the same colour in the output frame.
    public var matchShare: Double?
    public var verified: Bool?
    public var note: String?
}

public struct SubtitleComparison: Codable, Equatable, Sendable {
    public var path: String
    public var subtitleCount: Int
    public var burnedCount: Int
    public var matched: Int
    public var timeMismatches: Int
    public var textMismatches: Int
    public var onlyInSubtitles: Int
    public var onlyBurned: Int
}

public struct OutputQualityReport: Codable, Equatable, Sendable {
    public var file: String
    public var checkedAt: Date
    public var expectedWidth: Int
    public var expectedHeight: Int
    public var expectedFrameRate: Double
    public var expectedDuration: Double
    public var expectsAudio: Bool
    public var measured: OutputMeasurement?
    public var issues: [OutputQualityIssue]
    public var captionCount: Int
    /// Captions whose on-screen position was rendered and checked (all of them up to a limit).
    public var captionsLaidOut: Int
    public var burnIn: [CaptionBurnInResult]
    public var subtitles: SubtitleComparison?
    public var checkSeconds: Double
    public var errors: Int { issues.filter { $0.severity == .error }.count }
    public var warnings: Int { issues.filter { $0.severity == .warning }.count }
    public var passed: Bool { errors == 0 }
    public var summary: String {
        let burned = burnIn.filter { $0.verified == true }.count, sampled = burnIn.filter { $0.verified != nil }.count
        var parts = [passed ? "출력 검사 통과" : "출력 검사 오류 \(errors)개"]
        if warnings > 0 { parts.append("경고 \(warnings)개") }
        if sampled > 0 { parts.append("자막 번인 확인 \(burned)/\(sampled)") }
        if let s = subtitles { parts.append("SRT \(s.subtitleCount)개 · 번인 \(s.burnedCount)개 · 일치 \(s.matched)") }
        return parts.joined(separator: " · ")
    }
}

/// One burned-in title as the timeline defines it (output seconds).
public struct ExpectedCaption: Sendable {
    public var title: Title
    public var start: Double
    public var end: Double
    public var isCaption: Bool
    /// Moving, scaled, rotated, faded or keyframed titles are not compared pixel by pixel.
    public var pixelComparable: Bool
    public var fadeIn: Double
    public var fadeOut: Double
    public init(title: Title, start: Double, end: Double, isCaption: Bool, pixelComparable: Bool, fadeIn: Double, fadeOut: Double) {
        self.title = title; self.start = start; self.end = end; self.isCaption = isCaption; self.pixelComparable = pixelComparable; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

public struct OutputExpectation: Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var duration: Double
    public var expectsAudio: Bool
    public var captions: [ExpectedCaption]

    public init(width: Int, height: Int, frameRate: Double, duration: Double, expectsAudio: Bool, captions: [ExpectedCaption]) {
        self.width = width; self.height = height; self.frameRate = frameRate; self.duration = duration; self.expectsAudio = expectsAudio; self.captions = captions
    }

    /// What `project` (the exported snapshot) and its render plan will put in the file.
    public static func from(project: Project, plan: RenderPlan) -> OutputExpectation {
        let size = plan.videoComposition.renderSize
        let captions: [ExpectedCaption] = project.sequence.tracks.filter { $0.kind == .title && !$0.isHidden }.flatMap(\.clips).compactMap { clip in
            guard let title = clip.title else { return nil }
            let t = clip.transform
            let still = t.x == 0 && t.y == 0 && t.scale == 1 && t.rotation == 0 && t.opacity >= 0.999 && (clip.keyframes ?? []).isEmpty
            return ExpectedCaption(title: title, start: clip.start.seconds, end: clip.end.seconds,
                                   isCaption: clip.captionMetadata != nil || clip.connection != nil || clip.name == "자막",
                                   pixelComparable: still, fadeIn: clip.fadeIn?.seconds ?? 0, fadeOut: clip.fadeOut?.seconds ?? 0)
        }.sorted { $0.start < $1.start }
        let audio = plan.composition.tracks(withMediaType: .audio).contains { !$0.segments.isEmpty && $0.segments.contains { !$0.isEmpty } }
        return OutputExpectation(width: Int(size.width), height: Int(size.height), frameRate: 1 / plan.frameDuration.seconds,
                                 duration: plan.duration.seconds, expectsAudio: audio, captions: captions)
    }
}

public enum OutputQuality {
    /// Reading speed above which a caption is flagged (same limit as the caption list's “읽기 빠름”).
    public static let maximumCharactersPerSecond = 15.0
    public static let minimumCaptionSeconds = 0.3
    /// Captions whose layout is rendered; beyond this the longest and an even sample are checked.
    public static let layoutLimit = 300
    public static let burnInSamples = 24

    public static func check(output: URL, expectation: OutputExpectation, subtitles: URL? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> OutputQualityReport {
        let begun = Date()
        var issues: [OutputQualityIssue] = []
        func issue(_ severity: OutputQualityIssue.Severity, _ code: String, _ message: String, _ time: Double? = nil) {
            issues.append(OutputQualityIssue(severity: severity, code: code, message: message, time: time))
        }
        let frame = 1 / max(1, expectation.frameRate)
        // ---- File ----
        let measured = try await measure(output)
        progress?(0.2)
        if abs(measured.duration - expectation.duration) > frame + 0.02 {
            issue(.error, "duration", String(format: "출력 길이 %.3f초 · 타임라인 %.3f초", measured.duration, expectation.duration))
        }
        if measured.width != expectation.width || measured.height != expectation.height {
            issue(.error, "resolution", "해상도 \(measured.width)×\(measured.height) · 설정 \(expectation.width)×\(expectation.height)")
        }
        if abs(measured.frameRate - expectation.frameRate) > 0.02 {
            issue(.error, "frameRate", String(format: "프레임레이트 %.3f · 설정 %.3f", measured.frameRate, expectation.frameRate))
        }
        if expectation.expectsAudio {
            if measured.audioTracks == 0 { issue(.error, "audioMissing", "타임라인에 소리가 있지만 출력에 오디오 트랙이 없습니다.") }
            else {
                if let a = measured.audioDuration, let v = measured.videoDuration, abs(a - v) > 0.1 {
                    issue(.warning, "audioLength", String(format: "오디오 %.2f초 · 영상 %.2f초", a, v))
                }
                if let peak = measured.audioPeakDBFS, peak < -60 { issue(.warning, "audioSilent", String(format: "오디오가 거의 무음입니다(최대 %.0fdBFS).", peak)) }
            }
        }
        // ---- Captions as laid out on the canvas ----
        let captions = expectation.captions
        for (i, c) in captions.enumerated() where c.isCaption {
            let text = c.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { issue(.error, "emptyCaption", "빈 자막", c.start); continue }
            let seconds = c.end - c.start
            if seconds < minimumCaptionSeconds { issue(.warning, "tooShort", String(format: "%.2f초만 보이는 자막 · %@", seconds, String(text.prefix(20))), c.start) }
            let letters = Double(text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count)
            if seconds > 0, letters / seconds > maximumCharactersPerSecond {
                issue(.warning, "tooFast", String(format: "초당 %.0f자 · %@", letters / seconds, String(text.prefix(20))), c.start)
            }
            if i > 0 {
                let p = captions[i - 1]
                if p.isCaption, RepetitionGuard.normalized(p.title.text) == RepetitionGuard.normalized(text), c.start - p.end < 0.1 {
                    issue(.warning, "duplicate", "같은 문구가 연달아 나옵니다 · " + String(text.prefix(20)), c.start)
                }
            }
        }
        // Positions: render every caption up to the limit, otherwise the longest texts (most likely
        // to overflow) plus an even sample, and say how many were checked.
        var order = Array(captions.indices)
        if order.count > layoutLimit {
            let longest = order.sorted { captions[$0].title.text.count > captions[$1].title.text.count }.prefix(layoutLimit / 2)
            let step = Double(order.count) / Double(layoutLimit / 2)
            let even = (0..<(layoutLimit / 2)).map { Int(Double($0) * step) }
            order = Array(Set(longest).union(even)).sorted()
        }
        var boxes: [Int: CGRect] = [:]
        let canvas = CGRect(x: 0, y: 0, width: expectation.width, height: expectation.height)
        let safe = CaptionLayout.safeArea(width: expectation.width, height: expectation.height).insetBy(dx: -1, dy: -1)
        for (n, i) in order.enumerated() {
            try Task.checkCancellation()
            let c = captions[i]
            guard c.pixelComparable, let box = try CaptionLayout.bounds(of: c.title, width: expectation.width, height: expectation.height) else { continue }
            boxes[i] = box
            if !canvas.insetBy(dx: -0.5, dy: -0.5).contains(box) { issue(.error, "offScreen", "화면 밖으로 잘리는 자막 · " + String(c.title.text.prefix(20)), c.start) }
            else if c.isCaption && !safe.contains(box) { issue(.warning, "outsideSafeArea", "안전 영역 밖 자막 · " + String(c.title.text.prefix(20)), c.start) }
            if n % 20 == 0 { progress?(0.2 + 0.4 * Double(n) / Double(max(1, order.count))) }
        }
        // Overlap: two titles on screen at the same time whose drawn pixels intersect.
        for i in captions.indices {
            guard let a = boxes[i] else { continue }
            var j = i + 1
            while j < captions.count, captions[j].start < captions[i].end {
                if let b = boxes[j], captions[j].start < captions[i].end - 0.001, a.intersects(b) {
                    issue(.warning, "overlap", "겹쳐 보이는 자막 · " + String(captions[i].title.text.prefix(12)) + " / " + String(captions[j].title.text.prefix(12)), captions[j].start)
                }
                j += 1
            }
        }
        // ---- Burn-in: the caption's own solid pixels must appear in the output frame ----
        var burnIn: [CaptionBurnInResult] = []
        let candidates = captions.indices.filter { captions[$0].pixelComparable && captions[$0].isCaption && boxes[$0] != nil }
        let picks: [Int] = candidates.count <= burnInSamples ? candidates : (0..<burnInSamples).map { candidates[Int(Double($0) * Double(candidates.count - 1) / Double(burnInSamples - 1))] }
        if !picks.isEmpty, measured.videoDuration != nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            for (n, i) in picks.enumerated() {
                try Task.checkCancellation()
                let c = captions[i]
                // A moment inside the caption, away from fades and from a neighbouring title.
                let a = c.start + c.fadeIn, b = c.end - c.fadeOut
                guard b - a > frame else { burnIn.append(CaptionBurnInResult(time: c.start, text: c.title.text, matchShare: nil, verified: nil, note: "페이드 중이라 제외")); continue }
                let t = (a + b) / 2
                let covered = captions.indices.contains { $0 != i && captions[$0].start <= t && t < captions[$0].end && boxes[$0].map { $0.intersects(boxes[i]!) } ?? true }
                if covered { burnIn.append(CaptionBurnInResult(time: t, text: c.title.text, matchShare: nil, verified: nil, note: "다른 제목과 겹쳐 제외")); continue }
                let share = try await matchShare(caption: c.title, generator: generator, time: t, width: expectation.width, height: expectation.height)
                let verified = share.map { $0 >= 0.6 }
                burnIn.append(CaptionBurnInResult(time: t, text: c.title.text, matchShare: share, verified: verified, note: share == nil ? "글자 픽셀이 너무 적음" : nil))
                if let share, share < 0.6 {
                    issue(share < 0.3 ? .error : .warning, "burnIn", String(format: "출력 화면에서 자막이 확인되지 않음(일치 %.0f%%) · %@", share * 100, String(c.title.text.prefix(20))), t)
                }
                progress?(0.6 + 0.3 * Double(n + 1) / Double(picks.count))
            }
        }
        // ---- Subtitle file vs burned-in captions ----
        var comparison: SubtitleComparison?
        if let subtitles, FileManager.default.fileExists(atPath: subtitles.path) {
            let text = try SubtitleTextDecoder.decode(Data(contentsOf: subtitles))
            let cues = try SRTCodec.parse(text)
            let burned = captions.filter(\.isCaption)
            var used = Set<Int>(), matched = 0, timeOff = 0, textOff = 0
            for cue in cues {
                let start = cue.start.seconds, end = (cue.start + cue.duration).seconds
                if let k = burned.indices.first(where: { !used.contains($0) && abs(burned[$0].start - start) <= frame + 0.002 }) {
                    used.insert(k)
                    let sameText = RepetitionGuard.normalized(burned[k].title.text) == RepetitionGuard.normalized(cue.text)
                    let sameEnd = abs(burned[k].end - end) <= frame + 0.002
                    if sameText && sameEnd { matched += 1 } else { if !sameText { textOff += 1 }; if !sameEnd { timeOff += 1 } }
                } else if let k = burned.indices.first(where: { !used.contains($0) && RepetitionGuard.normalized(burned[$0].title.text) == RepetitionGuard.normalized(cue.text) && abs(burned[$0].start - start) < 2 }) {
                    used.insert(k); timeOff += 1
                }
            }
            comparison = SubtitleComparison(path: subtitles.path, subtitleCount: cues.count, burnedCount: burned.count, matched: matched, timeMismatches: timeOff,
                                            textMismatches: textOff, onlyInSubtitles: cues.count - used.count, onlyBurned: burned.count - used.count)
            if cues.count != burned.count || timeOff > 0 || textOff > 0 {
                issue(.warning, "subtitleMismatch", "SRT \(cues.count)개 · 번인 \(burned.count)개 · 시간 다름 \(timeOff) · 문구 다름 \(textOff) · SRT에만 \(cues.count - used.count) · 번인에만 \(burned.count - used.count)")
            }
        }
        progress?(1)
        return OutputQualityReport(file: output.path, checkedAt: Date(), expectedWidth: expectation.width, expectedHeight: expectation.height,
                                   expectedFrameRate: expectation.frameRate, expectedDuration: expectation.duration, expectsAudio: expectation.expectsAudio,
                                   measured: measured, issues: issues, captionCount: captions.filter(\.isCaption).count, captionsLaidOut: boxes.count,
                                   burnIn: burnIn, subtitles: comparison, checkSeconds: Date().timeIntervalSince(begun))
    }

    public static func measure(_ url: URL) async throws -> OutputMeasurement {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var width = 0, height = 0, rate = 0.0, codec = "", videoDuration: Double?
        if let video {
            let (size, transform, fps, range, formats) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange, .formatDescriptions)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(rect.width).rounded()); height = Int(abs(rect.height).rounded()); rate = Double(fps); videoDuration = range.duration.seconds
            if let f = formats.first { let s = CMFormatDescriptionGetMediaSubType(f); codec = String(bytes: [UInt8(s >> 24 & 255), UInt8(s >> 16 & 255), UInt8(s >> 8 & 255), UInt8(s & 255)], encoding: .ascii) ?? "" }
        }
        var audioDuration: Double?, peak: Double?
        if let first = audio.first {
            audioDuration = try await first.load(.timeRange).duration.seconds
            var maxValue: Float = 0
            _ = try await SourcePCM.readStable(url: url, sourceStart: .zero, duration: nil) { chunk in
                for v in chunk.values { let m = abs(v); if m > maxValue { maxValue = m } }
            }
            peak = maxValue > 0 ? 20 * log10(Double(maxValue)) : -120
        }
        return OutputMeasurement(duration: duration, videoDuration: videoDuration, audioDuration: audioDuration, width: width, height: height,
                                 frameRate: rate, videoCodec: codec, audioTracks: audio.count, audioPeakDBFS: peak)
    }

    /// Renders the caption alone, takes its solid interior pixels (text fill, stroke, box) and
    /// counts how many have the same colour (±40 per channel) in the output frame at `time`.
    static func matchShare(caption: Title, generator: AVAssetImageGenerator, time: Double, width: Int, height: Int) async throws -> Double? {
        let rendered = try TitlePreviewRenderer.image(title: caption, size: CGSize(width: width, height: height))
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        guard let a = pixels(rendered), let b = pixels(frame) else { return nil }
        var solid = 0, same = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let p = (y * width + x) * 4
                // Interior only: chroma subsampling blurs colour at glyph edges.
                guard a[p + 3] >= 250, a[p - 4 + 3] >= 250, a[p + 4 + 3] >= 250, a[p - width * 4 + 3] >= 250, a[p + width * 4 + 3] >= 250 else { continue }
                solid += 1
                if abs(Int(a[p]) - Int(b[p])) <= 40 && abs(Int(a[p + 1]) - Int(b[p + 1])) <= 40 && abs(Int(a[p + 2]) - Int(b[p + 2])) <= 40 { same += 1 }
            }
        }
        return solid >= 50 ? Double(same) / Double(solid) : nil
    }

    public static func markdown(_ r: OutputQualityReport) -> String {
        var lines = ["# 출력 품질 검사", "", "- 파일: \(r.file)", "- 결과: \(r.summary)", String(format: "- 검사 시간: %.1f초", r.checkSeconds)]
        if let m = r.measured {
            lines.append(String(format: "- 측정: %d×%d · %.3ffps · %.3f초 · 코덱 %@ · 오디오 트랙 %d%@", m.width, m.height, m.frameRate, m.duration, m.videoCodec, m.audioTracks,
                                m.audioPeakDBFS.map { String(format: " · 최대 %.1fdBFS", $0) } ?? ""))
        }
        lines.append(String(format: "- 설정: %d×%d · %.3ffps · %.3f초 · 오디오 %@", r.expectedWidth, r.expectedHeight, r.expectedFrameRate, r.expectedDuration, r.expectsAudio ? "있음" : "없음"))
        lines.append("- 자막 \(r.captionCount)개 · 위치 검사 \(r.captionsLaidOut)개 · 번인 표본 \(r.burnIn.count)개")
        if !r.issues.isEmpty {
            lines += ["", "## 문제", ""]
            for i in r.issues {
                let level = i.severity == .error ? "오류" : i.severity == .warning ? "경고" : "참고"
                lines.append("- [\(level)] " + (i.time.map { String(format: "%.2f초 · ", $0) } ?? "") + i.message)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(_ report: OutputQualityReport, to folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let base = folder.appendingPathComponent(name)
        try encoder.encode(report).write(to: base.appendingPathExtension("json"), options: .atomic)
        try markdown(report).write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        return base.appendingPathExtension("md")
    }
}

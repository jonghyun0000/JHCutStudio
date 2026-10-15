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
    public init(severity: Severity, code: String, message: String, time: Double? = nil) {
        self.severity = severity; self.code = code; self.message = message; self.time = time
    }
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
    public var captionIndex: Int?
    public var phase: String?
    public var actualTime: Double?
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

public enum OutputCheckStatus: String, Codable, Sendable { case passed, failed, warning, skipped, unverified }

/// Counts have the stated unit; sampling never asserts coverage of the whole movie.
public struct OutputQualityCheck: Codable, Equatable, Sendable {
    public var id: String
    public var status: OutputCheckStatus
    public var unit: String
    public var total: Int
    public var checked: Int
    public var failed: Int
    public var warnings: Int
    public var note: String
    public init(id: String, status: OutputCheckStatus, unit: String, total: Int, checked: Int, failed: Int, warnings: Int, note: String) {
        self.id = id; self.status = status; self.unit = unit; self.total = total; self.checked = checked; self.failed = failed; self.warnings = warnings; self.note = note
    }
}

public struct OutputQualityUnverifiedRange: Codable, Equatable, Sendable {
    public var titleIndex: Int
    public var start: Double
    public var end: Double
    public var checks: [String]
    public var reason: String
}

public struct OutputQualityScope: Codable, Equatable, Sendable {
    public var policyVersion: Int
    public var layoutLimit: Int
    public var burnInFrameLimit: Int
    public var samplePolicy: String
    public var selectedLayoutIndices: [Int]
    public var unverifiedLayoutIndices: [Int]
    public var unverifiedBurnInIndices: [Int]
    public var fullMoviePixelsVerified: Bool
    public var unverifiedRanges: [OutputQualityUnverifiedRange]
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
    /// Titles with checked static footprints or selected time-specific dynamic footprints.
    public var captionsLaidOut: Int
    public var burnIn: [CaptionBurnInResult]
    public var subtitles: SubtitleComparison?
    public var checkSeconds: Double
    public var checks: [OutputQualityCheck]?
    public var scope: OutputQualityScope?
    public var exportJobID: UUID?
    public var projectSHA256: String?
    public var sourceSnapshot: [ExportSourceIdentity]?
    public var outputSHA256: String?
    public var errors: Int { issues.filter { $0.severity == .error }.count }
    public var warnings: Int { issues.filter { $0.severity == .warning }.count }
    public var noErrors: Bool { errors == 0 }
    public var status: OutputCheckStatus {
        if errors > 0 { return .failed }
        if warnings > 0 { return .warning }
        guard let checks, !checks.isEmpty else { return .unverified }
        if checks.contains(where: { $0.status == .failed }) { return .failed }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        if checks.contains(where: { $0.status == .unverified || ($0.status == .skipped && $0.total > 0) }) { return .unverified }
        return .passed
    }
    public var passed: Bool { status == .passed }
    public var summary: String {
        let burned = burnIn.filter { $0.verified == true }.count, sampled = burnIn.filter { $0.verified != nil }.count
        let label: String
        switch status {
        case .failed: label = "출력 검사 오류 \(errors)개"
        case .warning: label = "출력 검사 경고"
        case .unverified: label = "출력 검사 일부 미확인"
        case .skipped: label = "출력 검사 생략"
        case .passed: label = "출력 표본 검사 통과"
        }
        var parts = [label]
        if let checks, checks.contains(where: { $0.checked < $0.total }) { parts.append("미검사 범위 있음") }
        if warnings > 0 { parts.append("경고 \(warnings)개") }
        if sampled > 0 { parts.append("자막 번인 확인 \(burned)/\(sampled)") }
        if let s = subtitles { parts.append("SRT \(s.subtitleCount)개 · 번인 \(s.burnedCount)개 · 일치 \(s.matched)") }
        return parts.joined(separator: " · ")
    }
}

/// One burned-in title as the timeline defines it (output seconds).
public struct ExpectedCaption: Sendable {
    public var language: String?
    public var title: Title
    public var start: Double
    public var end: Double
    public var isCaption: Bool
    /// Static opaque titles only; animation/transition/transform/keyframe exclusions are explicit.
    public var pixelComparable: Bool
    public var fadeIn: Double
    public var fadeOut: Double
    public var pixelExclusionReason: String?
    public var dynamicClip: Clip?
    public init(title: Title, start: Double, end: Double, isCaption: Bool, pixelComparable: Bool, fadeIn: Double, fadeOut: Double, language: String? = nil, pixelExclusionReason: String? = nil) {
        self.dynamicClip = nil
        self.pixelExclusionReason = pixelExclusionReason
        self.language = language; self.title = title; self.start = start; self.end = end; self.isCaption = isCaption; self.pixelComparable = pixelComparable; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

public struct OutputExpectation: Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var duration: Double
    public var expectsAudio: Bool
    public var captions: [ExpectedCaption]
    /// Original immutable render plan supplies the composited reference at each sampled time.
    public var previewPlan: RenderPlan?

    public init(width: Int, height: Int, frameRate: Double, duration: Double, expectsAudio: Bool, captions: [ExpectedCaption]) {
        self.previewPlan = nil
        self.width = width; self.height = height; self.frameRate = frameRate; self.duration = duration; self.expectsAudio = expectsAudio; self.captions = captions
    }

    /// What `project` (the exported snapshot) and its render plan will put in the file.
    public static func from(project: Project, plan: RenderPlan) -> OutputExpectation {
        let size = plan.videoComposition.renderSize
        // Use actual instruction order, which includes relocated transition lanes and excludes
        // hidden/inactive clips. An upper blended overlay can recolor an otherwise ordinary title.
        // Conservatively route every temporally affected title through full-composition sampling;
        // geometry or an invisible blend is resolved by the reference/background contrast check.
        var captionsBelowBlend = Set<UUID>()
        var captionsBelowMask = Set<UUID>()
        for case let instruction as TimelineInstruction in plan.videoComposition.instructions {
            var hasBlendAbove = false
            var hasMaskAbove = false
            for layer in instruction.layers.reversed() {
                if layer.clip.title != nil, hasBlendAbove { captionsBelowBlend.insert(layer.clip.id) }
                if layer.clip.title != nil, hasMaskAbove { captionsBelowMask.insert(layer.clip.id) }
                if (layer.clip.blendMode ?? .normal) != .normal { hasBlendAbove = true }
                if layer.clip.visual?.shapeMask != nil || layer.clip.visual?.ellipseMask == true || layer.clip.visual?.chromaKey != nil || (layer.clip.visual?.greenScreen ?? 0) > 0 { hasMaskAbove = true }
            }
        }
        let captions: [ExpectedCaption] = project.sequence.tracks.filter { $0.kind == .title && !$0.isHidden }.flatMap { track in
            track.clips.compactMap { clip -> ExpectedCaption? in
                guard clip.captionHidden != true, let title = clip.title else { return nil }
                let t = clip.transform
                var reasons: [String] = []
                if t.x != 0 || t.y != 0 || t.scale != 1 || t.rotation != 0 || t.opacity < 0.999 { reasons.append("transform/opacity") }
                if let mode = clip.blendMode, mode != .normal { reasons.append("blendMode: " + mode.rawValue) }
                if captionsBelowBlend.contains(clip.id) { reasons.append("overlying blend mode") }
                if captionsBelowMask.contains(clip.id) { reasons.append("overlying shape mask/chroma key") }
                if !(clip.keyframes ?? []).isEmpty { reasons.append("keyframes") }
                if let a = clip.titleAnimation, !a.isEmpty { reasons.append("titleAnimation: \(a.inKind?.rawValue ?? "none")/\(a.outKind?.rawValue ?? "none")") }
                if clip.transition != nil || track.transitionContext != nil { reasons.append("transition") }
                var expected = ExpectedCaption(title: title, start: clip.start.seconds, end: clip.end.seconds,
                    isCaption: CaptionQuery.role(of: clip) == .original || CaptionQuery.role(of: clip) == .translation,
                    pixelComparable: reasons.isEmpty, fadeIn: clip.fadeIn?.seconds ?? 0, fadeOut: clip.fadeOut?.seconds ?? 0,
                    language: clip.captionMetadata?.language, pixelExclusionReason: reasons.isEmpty ? nil : reasons.joined(separator: ", "))
                // Transition families require their outgoing/incoming contexts, not an isolated title mask.
                if !reasons.isEmpty, clip.transition == nil, track.transitionContext == nil { expected.dynamicClip = clip }
                return expected
            }
        }.sorted { $0.start < $1.start }
        let audio = plan.composition.tracks(withMediaType: .audio).contains { !$0.segments.isEmpty && $0.segments.contains { !$0.isEmpty } }
        var expectation = OutputExpectation(width: Int(size.width), height: Int(size.height), frameRate: 1 / plan.frameDuration.seconds,
                                 duration: plan.duration.seconds, expectsAudio: audio, captions: captions)
        expectation.previewPlan = plan
        return expectation
    }
}

public enum OutputQuality {
    /// Reading speed above which a caption is flagged (same limit as the caption list's “읽기 빠름”).
    /// Legacy generic threshold; current warnings use CaptionReadability.reading per language.
    public static let maximumCharactersPerSecond = 15.0
    public static let minimumCaptionSeconds = 0.4
    /// Title-layout budget; beyond it the longest and an even sample are checked.
    public static let layoutLimit = 300
    /// Output frame budget: up to eight titles, three static or visible dynamic phases per title.
    public static let burnInSamples = 24

    public static func check(output: URL, expectation: OutputExpectation, subtitles: URL? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> OutputQualityReport {
        let begun = Date()
        var issues: [OutputQualityIssue] = []
        func issue(_ severity: OutputQualityIssue.Severity, _ code: String, _ message: String, _ time: Double? = nil) {
            issues.append(OutputQualityIssue(severity: severity, code: code, message: message, time: time))
        }
        try Task.checkCancellation()
        guard expectation.width >= 3, expectation.height >= 3, expectation.frameRate.isFinite, expectation.frameRate > 0,
              expectation.duration.isFinite, expectation.duration >= 0,
              expectation.captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.fadeIn.isFinite && $0.fadeOut.isFinite && $0.fadeIn >= 0 && $0.fadeOut >= 0 }) else {
            throw MediaEngineError.failed("출력 검사 기대치의 크기·시간·프레임레이트가 올바르지 않습니다.")
        }
        let frame = 1 / expectation.frameRate
        var checks: [OutputQualityCheck] = []
        func record(_ id: String, unit: String, total: Int, checked: Int, codes: Set<String>, note: String, skipped: Bool = false) {
            let relevant = issues.filter { codes.contains($0.code) }
            let failed = relevant.filter { $0.severity == .error }.count
            let warnings = relevant.filter { $0.severity == .warning }.count
            let state: OutputCheckStatus = failed > 0 ? .failed : warnings > 0 ? .warning : skipped ? .skipped : checked < total ? .unverified : .passed
            checks.append(OutputQualityCheck(id: id, status: state, unit: unit, total: total, checked: checked, failed: failed, warnings: warnings, note: note))
        }
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
        record("file", unit: "file", total: 1, checked: 1, codes: ["duration", "resolution", "frameRate", "audioMissing", "audioLength", "audioSilent"], note: "길이·해상도·fps·예상 오디오 트랙/길이/첫 오디오 트랙 PCM 피크. 음성 의미·LUFS 검사는 아님.")
        // ---- Captions as laid out on the canvas ----
        let captions = expectation.captions.sorted { $0.start < $1.start }
        for (i, c) in captions.enumerated() where c.isCaption {
            let text = c.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { issue(.error, "emptyCaption", "빈 자막", c.start); continue }
            let seconds = c.end - c.start
            if seconds < minimumCaptionSeconds { issue(.warning, "tooShort", String(format: "%.2f초만 보이는 자막 · %@", seconds, String(text.prefix(20))), c.start) }
            let reading = CaptionReadability.reading(text: text, language: c.language, seconds: seconds)
            if seconds > 0, reading.tooFast {
                issue(.warning, "tooFast", String(format: "초당 %.1f자 (검수 기준 %.0f) · %@", reading.charactersPerSecond, reading.limit, String(text.prefix(20))), c.start)
            }
            if i > 0 {
                let p = captions[i - 1]
                if p.isCaption, RepetitionGuard.normalized(p.title.text) == RepetitionGuard.normalized(text), c.start - p.end < 0.1 {
                    issue(.warning, "duplicate", "같은 문구가 연달아 나옵니다 · " + String(text.prefix(20)), c.start)
                }
            }
        }
        record("captionReading", unit: "caption", total: captions.filter(\.isCaption).count, checked: captions.filter(\.isCaption).count,
               codes: ["emptyCaption", "tooShort", "tooFast", "duplicate"], note: "전체 문구/시간 기반 휴리스틱. 음성 인식·번역 의미 정확도 아님.")
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
            guard c.pixelComparable else { continue }
            if try TitlePreviewRenderer.layout(title: c.title, canvasWidth: Double(expectation.width)).exceedsLineLimit {
                issue(.warning, "lineLimitExceeded", "목표 줄 수 초과 · 전체 문구를 표시합니다 · " + String(c.title.text.prefix(20)), c.start)
            }
            let pixels = try CaptionLayout.bounds(of: c.title, width: expectation.width, height: expectation.height)
            guard let fullBox = TitlePreviewRenderer.fullBounds(title: c.title, size: CGSize(width: expectation.width, height: expectation.height)) ?? pixels else { continue }
            boxes[i] = pixels ?? fullBox
            if !canvas.insetBy(dx: -0.5, dy: -0.5).contains(fullBox) { issue(.error, "offScreen", "화면 밖으로 잘리는 자막 · " + String(c.title.text.prefix(20)), c.start) }
            else if c.isCaption && !safe.contains(fullBox) { issue(.warning, "outsideSafeArea", "안전 영역 밖 자막 · " + String(c.title.text.prefix(20)), c.start) }
            if n % 20 == 0 { progress?(0.2 + 0.4 * Double(n) / Double(max(1, order.count))) }
        }
        record("layout", unit: "title", total: captions.filter(\.pixelComparable).count, checked: boxes.count, codes: ["lineLimitExceeded", "offScreen", "outsideSafeArea"],
               note: "최대 \(layoutLimit)개, 긴 문구+균등 표본. 정적 전체 footprint만 검사; 움직임은 미확인.")
        // Overlap: two titles on screen at the same time whose drawn pixels intersect.
        var overlapTotal = 0, overlapChecked = 0
        for i in captions.indices {
            var j = i + 1
            while j < captions.count, captions[j].start < captions[i].end {
                overlapTotal += 1
                if let a = boxes[i], let b = boxes[j] {
                    overlapChecked += 1
                    if captions[j].start < captions[i].end - 0.001, a.intersects(b) {
                        issue(.warning, "overlap", "겹쳐 보이는 자막 · " + String(captions[i].title.text.prefix(12)) + " / " + String(captions[j].title.text.prefix(12)), captions[j].start)
                    }
                }
                j += 1
            }
        }
        record("overlap", unit: "concurrent title pair", total: overlapTotal, checked: overlapChecked, codes: ["overlap"], note: "동시에 보이는 정적 footprint 쌍. 움직이는/미표본 제목과의 충돌은 미확인.")
        // ---- Static burn-in samples: first opaque frame, middle, last opaque frame ----
        var burnIn: [CaptionBurnInResult] = []
        let eligible = captions.indices.filter {
            let c = captions[$0]
            return (c.pixelComparable && c.isCaption && boxes[$0] != nil) || (!c.pixelComparable && order.contains($0) && c.dynamicClip != nil && expectation.previewPlan != nil)
        }
        let captionBudget = burnInSamples / 3
        let picks: [Int] = eligible.count <= captionBudget ? eligible : (0..<captionBudget).map { eligible[Int(Double($0) * Double(eligible.count - 1) / Double(captionBudget - 1))] }
        var tested = Set<Int>(), dynamicTested = Set<Int>(), dynamicLayoutTested = Set<Int>(), frameCount = 0
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let preview = expectation.previewPlan.map { plan in
            let g = AVAssetImageGenerator(asset: plan.composition)
            g.videoComposition = plan.videoComposition
            g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            return g
        }
        for i in captions.indices where captions[i].isCaption && !picks.contains(i) {
            let c = captions[i]
            let reason = !c.pixelComparable ? (c.pixelExclusionReason ?? "움직임/효과가 있는 제목") : boxes[i] == nil ? "레이아웃 미검사" : "번인 프레임 표본 한도"
            burnIn.append(CaptionBurnInResult(time: c.start, text: c.title.text, matchShare: nil, verified: nil, note: reason, captionIndex: i, phase: "unverified"))
        }
        for (n, i) in picks.enumerated() {
            try Task.checkCancellation()
            let c = captions[i]
            let background: AVAssetImageGenerator?
            if let clip = c.dynamicClip, !c.pixelComparable, let plan = expectation.previewPlan {
                background = try? DynamicCaptionPixels.background(plan: plan, clipID: clip.id)
            } else { background = nil }
            // Frame numbers are in the output clock. End is exclusive; avoid native fades.
            let dynamic = !c.pixelComparable
            // Sample visible entrance/rest/exit, not a zero-alpha animation boundary.
            let inset = dynamic ? min(0.2, max(0, (c.end - c.start) / 4)) : 0
            let firstValue = ceil((c.start + (dynamic ? inset : c.fadeIn)) / frame - 1e-7)
            let lastValue = floor(min(c.end - (dynamic ? inset : c.fadeOut) - frame, min(expectation.duration, measured.duration) - frame) / frame + 1e-7)
            let clockLimit = Double(Int.max / 2)
            guard firstValue.isFinite, lastValue.isFinite, abs(firstValue) < clockLimit, abs(lastValue) < clockLimit else {
                burnIn.append(CaptionBurnInResult(time: c.start, text: c.title.text, matchShare: nil, verified: nil, note: "검사 가능한 프레임 시각 범위 초과", captionIndex: i, phase: "unverified")); continue
            }
            let first = Int(firstValue), last = Int(lastValue)
            guard measured.videoDuration != nil, first <= last else {
                burnIn.append(CaptionBurnInResult(time: c.start, text: c.title.text, matchShare: nil, verified: nil, note: "영상 없음 또는 페이드 밖 완전 프레임 없음", captionIndex: i, phase: "unverified")); continue
            }
            let points = Array(Set([first, (first + last) / 2, last])).sorted()
            var complete = true, layoutComplete = true
            for (pointIndex, k) in points.enumerated() {
                try Task.checkCancellation()
                let period = expectation.previewPlan?.frameDuration ?? CMTime(seconds: frame, preferredTimescale: 600_000)
                let ticks = period.value.multipliedReportingOverflow(by: Int64(k))
                guard period.isNumeric, !ticks.overflow else {
                    complete = false; layoutComplete = false
                    burnIn.append(CaptionBurnInResult(time: c.start, text: c.title.text, matchShare: nil, verified: nil, note: "정확한 프레임 시각 범위 초과", captionIndex: i, phase: "unverified")); continue
                }
                let requested = CMTime(value: ticks.partialValue, timescale: period.timescale)
                let t = requested.seconds
                let phase = points.count == 1 ? "only" : pointIndex == 0 ? "start" : pointIndex == points.count - 1 ? "end" : "middle"
                let dynamicBox: CGRect?
                if let clip = c.dynamicClip, dynamic {
                    dynamicBox = try DynamicCaptionPixels.bounds(clip: clip, time: t, size: canvas.size)
                    if let box = dynamicBox {
                        if !canvas.insetBy(dx: -0.5, dy: -0.5).contains(box) {
                            // Entry/exit may intentionally reveal only part of the text.
                            let state = clip.titleAnimation?.state(at: t - c.start, clipDuration: clip.duration.seconds) ?? .rest
                            let partial = state.reveal < 0.999 || state.opacity < 0.999 || state.offsetX != 0 || state.offsetY != 0
                            issue(partial ? .info : .error, "dynamicOffScreen", "효과 표본에서 화면 밖 글자 · " + String(c.title.text.prefix(20)), t)
                        } else if c.isCaption && !safe.contains(box) { issue(.warning, "dynamicOutsideSafeArea", "효과 표본에서 안전 영역 밖 자막 · " + String(c.title.text.prefix(20)), t) }
                    } else { layoutComplete = false }
                } else { dynamicBox = boxes[i] }
                let covered = captions.indices.contains {
                    $0 != i && captions[$0].start <= t && t < captions[$0].end && (boxes[$0].flatMap { other in dynamicBox.map { other.intersects($0) } } ?? true)
                }
                if covered {
                    complete = false
                    burnIn.append(CaptionBurnInResult(time: t, text: c.title.text, matchShare: nil, verified: nil, note: "다른 제목과 겹치거나 상대 배치 미확인", captionIndex: i, phase: phase)); continue
                }
                do {
                    let result: (share: Double?, actualTime: Double)
                    if dynamic, let clip = c.dynamicClip, let preview, let background {
                        result = try await dynamicMatchShare(clip: clip, expectedTitle: c.title, preview: preview, background: background, generator: generator, time: t, width: expectation.width, height: expectation.height, requestedTime: requested)
                    } else if dynamic {
                        result = (nil, t)
                    } else { result = try await matchShare(caption: c.title, generator: generator, time: t, width: expectation.width, height: expectation.height, requestedTime: requested) }
                    frameCount += 1
                    let aligned = abs(result.actualTime - t) <= frame / 2 + 0.002
                    let share = aligned ? result.share : nil
                    let verified = share.map { $0 >= 0.6 }
                    if verified == nil { complete = false }
                    burnIn.append(CaptionBurnInResult(time: t, text: c.title.text, matchShare: share, verified: verified,
                        note: !aligned ? "요청/실제 프레임 시각 다름" : share == nil ? (dynamic ? "합성 참조/시간/문구 불일치 또는 작은·투명·배경 대비 부족 글자" : "글자 내부 픽셀이 너무 적음") : nil, captionIndex: i, phase: dynamic ? "dynamic-" + phase : phase, actualTime: result.actualTime))
                    if let share, share < 0.6 {
                        issue(share < 0.3 ? .error : .warning, dynamic ? "dynamicBurnIn" : "burnIn", String(format: "출력 화면에서 자막이 확인되지 않음(일치 %.0f%%) · %@", share * 100, String(c.title.text.prefix(20))), t)
                    }
                } catch {
                    try Task.checkCancellation()
                    complete = false
                    burnIn.append(CaptionBurnInResult(time: t, text: c.title.text, matchShare: nil, verified: nil, note: "프레임 읽기 실패: " + error.localizedDescription, captionIndex: i, phase: phase))
                }
            }
            if complete { tested.insert(i); if dynamic { dynamicTested.insert(i) } }
            if dynamic && layoutComplete { dynamicLayoutTested.insert(i) }
            progress?(0.6 + 0.3 * Double(n + 1) / Double(max(1, picks.count)))
        }
        record("burnIn", unit: "caption", total: captions.filter(\.isCaption).count, checked: tested.filter { captions[$0].isCaption }.count, codes: ["burnIn", "dynamicBurnIn"],
               note: "최대 \(burnInSamples)프레임/\(captionBudget)자막의 start/middle/end. 실제 비교 프레임 \(frameCount). 미지원 전환·겹침·작은/투명 글자·한도는 사유와 함께 미확인. 전체 영상 픽셀 증명 아님.")
        let moving = captions.filter { !$0.pixelComparable }.count
        record("effects", unit: "title", total: moving, checked: dynamicTested.count, codes: ["dynamicBurnIn", "dynamicOffScreen", "dynamicOutsideSafeArea"], note: "변형·키프레임·등장/퇴장 효과의 시간별 합성 참조+글자 마스크 start/middle/end 표본. 전환·겹침·작은/투명 글자·미선택 시점은 미확인. 전체 구간 확인 아님.", skipped: moving == 0)
        record("dynamicLayout", unit: "title", total: moving, checked: dynamicLayoutTested.count, codes: ["dynamicOffScreen", "dynamicOutsideSafeArea"], note: "동적 글자 전체 footprint의 선택된 세 시점만 검사. 표본 사이·전환·겹침 배치는 미확인.", skipped: moving == 0)
        // ---- Subtitle file vs burned-in captions ----
        var comparison: SubtitleComparison?
        if let subtitles {
            if !FileManager.default.fileExists(atPath: subtitles.path) {
                issue(.error, "subtitleMissing", "요청한 SRT 파일이 없습니다.")
            } else {
                do {
                    let text = try SubtitleTextDecoder.decode(Data(contentsOf: subtitles))
                    let cues = try SRTCodec.parse(text)
                    let burned = captions.filter(\.isCaption)
                    var used = Set<Int>(), matched = 0, timeOff = 0, textOff = 0
                    for cue in cues {
                        let start = cue.start.seconds, end = (cue.start + cue.duration).seconds
                        if let k = burned.indices.filter({ !used.contains($0) && abs(burned[$0].start - start) <= frame + 0.002 }).sorted(by: {
                            let a = RepetitionGuard.normalized(burned[$0].title.text) == RepetitionGuard.normalized(cue.text)
                            let b = RepetitionGuard.normalized(burned[$1].title.text) == RepetitionGuard.normalized(cue.text)
                            return a != b ? a : abs(burned[$0].end - end) < abs(burned[$1].end - end)
                        }).first {
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
                    if cues.count != burned.count || timeOff > 0 || textOff > 0 || cues.count != used.count || burned.count != used.count {
                        issue(.error, "subtitleMismatch", "SRT \(cues.count)개 · 번인 \(burned.count)개 · 시간 다름 \(timeOff) · 문구 다름 \(textOff) · SRT에만 \(cues.count - used.count) · 번인에만 \(burned.count - used.count)")
                    }
                } catch {
                    try Task.checkCancellation()
                    issue(.error, "subtitleUnreadable", "SRT를 해석하지 못했습니다: " + error.localizedDescription)
                }
            }
        }
        record("subtitles", unit: "file", total: subtitles == nil ? 0 : 1, checked: comparison == nil ? 0 : 1,
               codes: ["subtitleMismatch", "subtitleMissing", "subtitleUnreadable"], note: subtitles == nil ? "SRT 비교 미요청" : "일대일 문구/시각 대응; unmatched도 오류. 음성 의미 정답 아님.", skipped: subtitles == nil)
        try Task.checkCancellation()
        let ranges: [OutputQualityUnverifiedRange] = captions.indices.compactMap { i in
            let c = captions[i]
            var unchecked: [String] = []
            if boxes[i] == nil && !dynamicLayoutTested.contains(i) { unchecked.append("layout") }
            if c.isCaption && !tested.contains(i) { unchecked.append("burnIn") }
            if !c.pixelComparable && !dynamicTested.contains(i) { unchecked.append("effects") }
            if !c.pixelComparable { unchecked.append("unsampledEffectTimes") }
            guard !unchecked.isEmpty else { return nil }
            let reason = c.pixelExclusionReason ?? burnIn.first(where: { $0.captionIndex == i && $0.verified == nil })?.note ?? "레이아웃 표본 한도 또는 표시 픽셀 없음"
            return OutputQualityUnverifiedRange(titleIndex: i, start: c.start, end: c.end, checks: unchecked, reason: reason)
        }
        let scope = OutputQualityScope(policyVersion: 3, layoutLimit: layoutLimit, burnInFrameLimit: burnInSamples,
            samplePolicy: "layout: longest+even; static burn-in: first/middle/last opaque frame; supported effects: visible entrance/middle/exit glyph-mask vs composited preview; transitions, overlaps, unsampled times explicitly unverified",
            selectedLayoutIndices: order.filter { boxes[$0] != nil || dynamicLayoutTested.contains($0) }, unverifiedLayoutIndices: captions.indices.filter { boxes[$0] == nil && !dynamicLayoutTested.contains($0) },
            unverifiedBurnInIndices: captions.indices.filter { captions[$0].isCaption && !tested.contains($0) }, fullMoviePixelsVerified: false, unverifiedRanges: ranges)
        progress?(1)
        return OutputQualityReport(file: output.path, checkedAt: Date(), expectedWidth: expectation.width, expectedHeight: expectation.height,
                                   expectedFrameRate: expectation.frameRate, expectedDuration: expectation.duration, expectsAudio: expectation.expectsAudio,
                                   measured: measured, issues: issues, captionCount: captions.filter(\.isCaption).count, captionsLaidOut: boxes.count + dynamicLayoutTested.count,
                                   burnIn: burnIn, subtitles: comparison, checkSeconds: Date().timeIntervalSince(begun), checks: checks, scope: scope)
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

    /// Renders only glyph fill (no background/stroke/shadow), takes solid interior pixels and
    /// counts how many have the same colour (±40 per channel) in the output frame at `time`.
    static func matchShare(caption: Title, generator: AVAssetImageGenerator, time: Double, width: Int, height: Int, requestedTime: CMTime? = nil) async throws -> (share: Double?, actualTime: Double) {
        var glyphTitle = caption
        if var style = glyphTitle.style { style.backgroundOpacity = 0; style.shadow = false; style.strokeWidth = 0; glyphTitle.style = style }
        let rendered = try TitlePreviewRenderer.image(title: glyphTitle, size: CGSize(width: width, height: height))
        let sampled = try await generator.image(at: requestedTime ?? CMTime(seconds: time, preferredTimescale: 60_000))
        let frame = sampled.image
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        guard let a = pixels(rendered), let b = pixels(frame) else { return (nil, sampled.actualTime.seconds) }
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
        return (solid >= 50 ? Double(same) / Double(solid) : nil, sampled.actualTime.seconds)
    }

    /// The alpha mask locates time-specific glyph interiors. Colours come from the full
    /// composited reference, so partial opacity over footage is compared against that footage.
    static func dynamicMatchShare(clip: Clip, expectedTitle: Title, preview: AVAssetImageGenerator, background: AVAssetImageGenerator, generator: AVAssetImageGenerator, time: Double, width: Int, height: Int, requestedTime: CMTime? = nil) async throws -> (share: Double?, actualTime: Double) {
        guard clip.title == expectedTitle else { return (nil, time) }
        let requested = requestedTime ?? CMTime(seconds: time, preferredTimescale: 60_000)
        let reference = try await preview.image(at: requested)
        let backdrop = try await background.image(at: requested)
        let output = try await generator.image(at: requested)
        let frame = preview.videoComposition?.frameDuration.seconds ?? 1.0 / 30
        guard abs(reference.actualTime.seconds - time) <= frame / 2 + 0.002,
              abs(backdrop.actualTime.seconds - time) <= frame / 2 + 0.002 else { return (nil, output.actualTime.seconds) }
        let mask = try DynamicCaptionPixels.glyphs(clip: clip, time: time, size: CGSize(width: width, height: height))
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        guard let maskPixels = pixels(mask), let expected = pixels(reference.image), let bare = pixels(backdrop.image), let actual = pixels(output.image) else { return (nil, output.actualTime.seconds) }
        var solid = 0, same = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let p = (y * width + x) * 4, alpha = Int(maskPixels[p + 3])
                // Opaque or partially transparent interiors, excluding interpolation edges.
                guard alpha >= 32, [p - 4, p + 4, p - width * 4, p + width * 4].allSatisfy({ Int(maskPixels[$0 + 3]) >= alpha - 5 }) else { continue }
                // Compare with the same composition without this glyph. A matching white wall,
                // near-zero opacity or other invisible text must never establish caption presence.
                guard (0..<3).contains(where: { abs(Int(expected[p + $0]) - Int(bare[p + $0])) >= 48 }) else { continue }
                guard (0..<3).contains(where: { abs(Int(expected[p + $0]) - Int(actual[p + $0])) > 40 }) == false else { solid += 1; continue }
                solid += 1; same += 1
            }
        }
        return (solid >= 50 ? Double(same) / Double(solid) : nil, output.actualTime.seconds)
    }

    public static func markdown(_ r: OutputQualityReport) -> String {
        var lines = ["# 출력 품질 검사", "", "- 파일: \(r.file)", "- 결과: \(r.summary)", String(format: "- 검사 시간: %.1f초", r.checkSeconds)]
        if let m = r.measured {
            lines.append(String(format: "- 측정: %d×%d · %.3ffps · %.3f초 · 코덱 %@ · 오디오 트랙 %d%@", m.width, m.height, m.frameRate, m.duration, m.videoCodec, m.audioTracks,
                                m.audioPeakDBFS.map { String(format: " · 최대 %.1fdBFS", $0) } ?? ""))
        }
        lines.append(String(format: "- 설정: %d×%d · %.3ffps · %.3f초 · 오디오 %@", r.expectedWidth, r.expectedHeight, r.expectedFrameRate, r.expectedDuration, r.expectsAudio ? "있음" : "없음"))
        lines.append("- 자막 \(r.captionCount)개 · 위치 검사 \(r.captionsLaidOut)개 · 번인 표본 \(r.burnIn.count)개")
        lines += ["", "검사는 전달된 기대치와의 기술적 일치만 평가합니다. 음성 인식·번역 의미 정확도 또는 전체 영상 픽셀 검증이 아닙니다."]
        if let checks = r.checks {
            lines += ["", "## 검사 범위", "", "| 검사 | 상태 | 검사/전체 | 단위 | 오류/경고 | 범위·제외 |", "|---|---|---:|---|---|---|"]
            for c in checks { lines.append("| \(c.id) | \(c.status.rawValue) | \(c.checked)/\(c.total) | \(c.unit) | \(c.failed)/\(c.warnings) | \(c.note.replacingOccurrences(of: "|", with: "/")) |") }
        } else { lines.append("기존 보고서: 검사 범위 정보 없음 · 전체 통과로 해석하지 않습니다.") }
        if let s = r.scope { lines.append("\n레이아웃 한도 \(s.layoutLimit), 번인 프레임 한도 \(s.burnInFrameLimit). 미확인 레이아웃 \(s.unverifiedLayoutIndices.count), 미확인 번인 자막 \(s.unverifiedBurnInIndices.count). 전체 영상 픽셀 확인: 아니오.") }
        if let s = r.scope, !s.unverifiedRanges.isEmpty {
            lines += ["", "## 미확인 자막/제목 구간", ""]
            for u in s.unverifiedRanges { lines.append(String(format: "- %.3f~%.3f초 · 제목 %d · %@ · %@", u.start, u.end, u.titleIndex, u.checks.joined(separator: "/"), u.reason)) }
        }
        let excluded = r.burnIn.filter { $0.verified == nil }
        if !excluded.isEmpty {
            lines += ["", "## 미확인 번인 표본", ""]
            for b in excluded { lines.append(String(format: "- %.3f초 · %@ · %@", b.time, b.phase ?? "legacy", b.note ?? "사유 없음")) }
        }
        if !r.issues.isEmpty {
            lines += ["", "## 문제", ""]
            for i in r.issues {
                let level = i.severity == .error ? "오류" : i.severity == .warning ? "경고" : "참고"
                lines.append("- [\(level)] " + (i.time.map { String(format: "%.2f초 · ", $0) } ?? "") + i.message)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(_ report: OutputQualityReport, to folder: URL, name: String, publicationID: UUID = UUID(),
                             beforeSecondWrite: ((URL) throws -> Void)? = nil) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw ProjectError("보고서 이름을 확인하세요.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = try ExportWorkspace(parent: folder, id: publicationID)
        defer { workspace.cleanup() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(report), md = Data(markdown(report).utf8)
        try json.write(to: workspace.url.appendingPathComponent("report.json"), options: .withoutOverwriting)
        try beforeSecondWrite?(workspace.url)
        try md.write(to: workspace.url.appendingPathComponent("report.md"), options: .withoutOverwriting)
        let manifest = OutputReportManifest(publicationID: publicationID, jobID: report.exportJobID,
            jsonSHA256: ExportDeliveryReceipt.digest(json), markdownSHA256: ExportDeliveryReceipt.digest(md))
        try encoder.encode(manifest).write(to: workspace.url.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        let destination = folder.appendingPathComponent(name + "-" + publicationID.uuidString, isDirectory: true)
        try ExclusivePublication.directory(from: workspace.url, to: destination, manifest: "manifest.json")
        return destination.appendingPathComponent("report.md")
    }

    public static func readPublished(_ markdownURL: URL) throws -> OutputQualityReport {
        let folder = markdownURL.deletingLastPathComponent()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(OutputReportManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let json = try Data(contentsOf: folder.appendingPathComponent("report.json")), md = try Data(contentsOf: folder.appendingPathComponent("report.md"))
        guard ExportDeliveryReceipt.digest(json) == manifest.jsonSHA256, ExportDeliveryReceipt.digest(md) == manifest.markdownSHA256 else { throw ProjectError("QA 보고서 쌍의 무결성을 확인하지 못했습니다.") }
        let report = try decoder.decode(OutputQualityReport.self, from: json)
        guard report.exportJobID == manifest.jobID else { throw ProjectError("QA 보고서 작업 ID가 다릅니다.") }
        return report
    }
}

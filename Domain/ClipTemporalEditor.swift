import Foundation

/// Destructive-to-metadata, nondestructive-to-media range edits. Evaluated animation is baked
/// at output-frame instants and original breakpoints, never silently reparameterized as a new ease.
public enum ClipTemporalEditor {
    public static let maximumBakedKeyframes = 36_000
    public static func trimmed(_ original: Clip, newStart: MediaTime, newSourceStart: MediaTime, newDuration: MediaTime, frameRate: FrameRate, temporalSource: Bool, animationOffset: MediaTime? = nil) throws -> Clip {
        guard newStart >= .zero, newSourceStart >= .zero, newDuration > .zero else { throw ProjectError("트림의 시작·원본 시작은 0 이상이고 길이는 0보다 커야 합니다.") }
        guard temporalSource || newSourceStart == .zero else { throw ProjectError("제목·정지 이미지의 원본 시작은 0이어야 합니다.") }
        var result = original; result.start = newStart; result.sourceStart = newSourceStart; result.duration = newDuration
        let rate = original.playbackRate ?? PlaybackRate()
        let offset = try animationOffset ?? (temporalSource ? newSourceStart.subtracting(original.sourceStart).scaled(numerator: rate.denominator, denominator: rate.numerator) : newStart.subtracting(original.start))
        if var transition = original.transition {
            transition.offset = try (transition.offset ?? .zero).adding(offset)
            let bakedLegacyDissolve = transition.independentFade != true && transition.kind == .dissolve && (original.fadeIn ?? .zero) > .zero
            result.transition = transition.offset! >= transition.duration || bakedLegacyDissolve ? nil : transition
        }
        if var animation = original.titleAnimation {
            animation.referenceDuration = animation.referenceDuration ?? original.duration.seconds
            animation.timeOffset = (animation.timeOffset ?? 0) + offset.seconds * (animation.timeScale ?? 1)
            result.titleAnimation = animation
        }
        result.transitionAudioFades = try original.transitionAudioFades?.map { value in
            var fade = value; fade.start = try fade.start.subtracting(offset)
            fade.points = try fade.points?.map { var p = $0; p.time = try p.time.subtracting(offset); return p }; return fade
        }
        let hasAnimation = !(original.ducking ?? []).isEmpty || !(original.keyframes ?? []).isEmpty || [original.fadeIn, original.fadeOut, original.audioFadeIn, original.audioFadeOut].contains { ($0 ?? .zero) > .zero }
        guard hasAnimation else { return result }
        var times: Set<MediaTime> = [.zero, newDuration]
        let end = try newStart.adding(newDuration)
        let fps = Double(frameRate.numerator) / Double(frameRate.denominator)
        let firstDouble = ceil(newStart.seconds * fps), lastDouble = floor(end.seconds * fps)
        guard firstDouble.isFinite, lastDouble.isFinite, firstDouble < Double(Int64.max) - 1, lastDouble < Double(Int64.max) - 1, (lastDouble - firstDouble) < Double(maximumBakedKeyframes) else { throw ProjectError("한 번에 구체화할 수 있는 애니메이션은 \(maximumBakedKeyframes)개 키 이내입니다. 먼저 구간을 나누세요.") }
        let firstFrame = Int64(firstDouble), lastFrame = Int64(lastDouble)
        guard !firstFrame.multipliedReportingOverflow(by: Int64(frameRate.denominator)).overflow, !lastFrame.multipliedReportingOverflow(by: Int64(frameRate.denominator)).overflow else { throw TimeArithmeticError.nonRepresentable }
        if firstFrame <= lastFrame {
            for frame in firstFrame...lastFrame {
                let local = try frameRate.time(forFrame: frame).subtracting(newStart)
                if local >= .zero, local <= newDuration { times.insert(local) }
            }
        }
        var boundaries = (original.ducking ?? []).map(\.time) + (original.keyframes ?? []).map(\.time) + [.zero, original.duration]
        boundaries += [original.fadeIn, original.audioFadeIn].compactMap { $0 }
        for fade in [original.fadeOut, original.audioFadeOut].compactMap({ $0 }) { boundaries.append(try original.duration.subtracting(fade)) }
        for boundary in boundaries {
            let local = try boundary.subtracting(offset)
            if local >= .zero, local <= newDuration { times.insert(local) }
        }
        guard times.count <= maximumBakedKeyframes else { throw ProjectError("트림 후 애니메이션 키가 \(maximumBakedKeyframes)개를 초과합니다.") }
        let keys = try times.sorted().map { local -> TransformKeyframe in
            let originalTime = max(.zero, min(original.duration, try local.adding(offset)))
            var evaluated = original.evaluatedKeyframe(at: originalTime)
            evaluated.time = local; evaluated.interpolation = .linear
            evaluated.transform.opacity *= envelope(at: originalTime, duration: original.duration, fadeIn: original.fadeIn, fadeOut: original.fadeOut)
            evaluated.volume *= AudioAutomation.gain(original.ducking, at: originalTime) * envelope(at: originalTime, duration: original.duration, fadeIn: original.audioFadeIn, fadeOut: original.audioFadeOut)
            return evaluated
        }
        result.ducking = nil
        result.keyframes = keys
        result.transform = keys[0].transform; result.volume = keys[0].volume
        result.fadeIn = nil; result.fadeOut = nil; result.audioFadeIn = nil; result.audioFadeOut = nil
        return result
    }
    /// Shared time mapping for direct speed edits and connected captions/media.
    public static func retimed(_ original: Clip, duration: MediaTime, mapping: (MediaTime) throws -> MediaTime) throws -> Clip {
        guard duration > .zero else { throw ProjectError("배속 편집 후 클립 길이는 0보다 커야 합니다.") }
        var result = original; result.duration = duration
        result.fadeIn = try original.fadeIn.map(mapping); result.fadeOut = try original.fadeOut.map(mapping)
        result.audioFadeIn = try original.audioFadeIn.map(mapping); result.audioFadeOut = try original.audioFadeOut.map(mapping)
        result.ducking = try original.ducking?.map { var point = $0; point.time = try mapping(point.time); return point }
        result.keyframes = try original.keyframes?.map { var frame = $0; frame.time = try mapping(frame.time); return frame }
        if var effect = original.transition { effect.duration = try mapping(effect.duration); effect.offset = try effect.offset.map(mapping); result.transition = effect }
        result.transitionAudioFades = try original.transitionAudioFades?.map { var fade = $0; fade.start = try mapping(fade.start); fade.duration = try mapping(fade.duration); fade.points = try fade.points?.map { var p = $0; p.time = try mapping(p.time); return p }; return fade }
        if var animation = original.titleAnimation {
            animation.referenceDuration = animation.referenceDuration ?? original.duration.seconds
            animation.timeScale = (animation.timeScale ?? 1) * original.duration.seconds / duration.seconds
            result.titleAnimation = animation
        }
        return result
    }
    public static func envelope(at time: MediaTime, duration: MediaTime, fadeIn: MediaTime?, fadeOut: MediaTime?) -> Double {
        let local = max(.zero, min(duration, time))
        var amount = 1.0
        if let fadeIn, fadeIn > .zero { amount *= min(1, max(0, local.seconds / fadeIn.seconds)) }
        if let fadeOut, fadeOut > .zero { amount *= min(1, max(0, (duration - local).seconds / fadeOut.seconds)) }
        return amount
    }
}

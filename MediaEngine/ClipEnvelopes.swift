import Foundation
import AVFoundation

/// Timing is local timeline time, after rational source-speed mapping.
enum ClipEnvelopes {
    static func fade(at time: CMTime, duration: CMTime, fadeIn: CMTime?, fadeOut: CMTime?) -> Double {
        var result = 1.0
        if let fadeIn, fadeIn > .zero { result *= min(1, max(0, time.seconds / fadeIn.seconds)) }
        if let fadeOut, fadeOut > .zero { result *= min(1, max(0, (duration - time).seconds / fadeOut.seconds)) }
        return result
    }
    static func audioVolume(clip: Clip, at time: CMTime) -> Float {
        Float(AudioAutomation.gain(clip.ducking, at: MediaTime(time)) * clip.evaluatedVolume(at: MediaTime(time)) * fade(at: time, duration: clip.duration.cmTime,
                                                           fadeIn: clip.audioFadeIn?.cmTime, fadeOut: clip.audioFadeOut?.cmTime))
    }
    static func applyAudio(clip: Clip, to input: AVMutableAudioMixInputParameters) {
        input.audioTimePitchAlgorithm = .spectral
        guard !(clip.ducking ?? []).isEmpty || !(clip.keyframes ?? []).isEmpty || (clip.audioFadeIn?.seconds ?? 0) > 0 || (clip.audioFadeOut?.seconds ?? 0) > 0 else {
            // A flat ramp across the clip's own range, not a bare `setVolume` point: consecutive volume
            // points interpolate, so a point would slide this clip's level toward whatever the next clip
            // on the same packed lane asks for.
            input.setVolumeRamp(fromStartVolume: Float(clip.volume), toEndVolume: Float(clip.volume),
                                timeRange: CMTimeRange(start: clip.start.cmTime, duration: clip.duration.cmTime))
            return
        }
        var points = [CMTime.zero, clip.duration.cmTime]
        points += (clip.keyframes ?? []).map { $0.time.cmTime }
        points += (clip.ducking ?? []).map { $0.time.cmTime }
        if let fade = clip.audioFadeIn, fade > .zero { points.append(fade.cmTime) }
        if let fade = clip.audioFadeOut, fade > .zero { points.append((clip.duration - fade).cmTime) }
        var sorted: [CMTime] = []
        for time in points.sorted(by: { $0 < $1 }) { if sorted.last != time { sorted.append(time) } }
        for (start, end) in zip(sorted, sorted.dropFirst()) {
            guard end > start else { continue }
            let startValue = audioVolume(clip: clip, at: start)
            // Preserve hold interpolation's discontinuity at a keyframe instead of fading into it early.
            let nearEnd = max(start, end - CMTime(value: 1, timescale: 480_000))
            let endValue = audioVolume(clip: clip, at: nearEnd)
            appendAdaptive(clip: clip, input: input, start: start, end: end, from: startValue, to: endValue, depth: 0)
            input.setVolume(audioVolume(clip: clip, at: end), at: clip.start.cmTime + end)
        }
    }
    private static func appendAdaptive(clip: Clip, input: AVMutableAudioMixInputParameters, start: CMTime, end: CMTime, from: Float, to: Float, depth: Int) {
        let midpoint = start + CMTimeMultiplyByRatio(end - start, multiplier: 1, divisor: 2)
        let quarter = start + CMTimeMultiplyByRatio(end - start, multiplier: 1, divisor: 4)
        let threeQuarter = start + CMTimeMultiplyByRatio(end - start, multiplier: 3, divisor: 4)
        let middle = audioVolume(clip: clip, at: midpoint)
        // Sampling quarter points also detects symmetric ease curves whose midpoint lies on a straight line.
        let error = max(abs(middle - (from + to) / 2),
                        abs(audioVolume(clip: clip, at: quarter) - (from * 0.75 + to * 0.25)),
                        abs(audioVolume(clip: clip, at: threeQuarter) - (from * 0.25 + to * 0.75)))
        if depth < 12, (end - start).seconds > 1.0 / 240, error > 0.0005 {
            appendAdaptive(clip: clip, input: input, start: start, end: midpoint, from: from, to: middle, depth: depth + 1)
            appendAdaptive(clip: clip, input: input, start: midpoint, end: end, from: middle, to: to, depth: depth + 1)
        } else {
            input.setVolumeRamp(fromStartVolume: from, toEndVolume: to,
                                timeRange: CMTimeRange(start: clip.start.cmTime + start, duration: end - start))
        }
    }
}

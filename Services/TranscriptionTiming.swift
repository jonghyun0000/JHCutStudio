import Foundation

/// Three clocks: recognizer-local (optionally compacted), absolute original media, and
/// editor timeline. Only the editor's CaptionEditing maps the last of these through trim/rate.
enum TranscriptionTiming {
    static func windowProgress(index: Int, within: Double, windowSeconds: Double, total: Double) -> Double {
        let offset = Double(index) * windowSeconds, length = max(0, min(windowSeconds, total - offset))
        let part = within.isFinite ? min(1, max(0, within)) : 0
        return AudioAnalysisProgress.fraction(elapsed: offset + part * length, total: total)
    }

    static func sourceCues(_ relative: [CaptionCue], sourceStart: MediaTime, duration: MediaTime,
                           compacted: CompactedTimeline? = nil) -> [CaptionCue] {
        let limit = sourceStart + duration
        return relative.compactMap { cue in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let localStart: MediaTime, localEnd: MediaTime
            if let compacted {
                guard let range = compacted.sourceRange(compactStart: cue.start.seconds,
                                                       compactEnd: (cue.start + cue.duration).seconds) else { return nil }
                localStart = MediaTime(seconds: range.lowerBound); localEnd = MediaTime(seconds: range.upperBound)
            } else {
                localStart = cue.start; localEnd = cue.start + cue.duration
            }
            let start = max(sourceStart, sourceStart + localStart), end = min(limit, sourceStart + localEnd)
            guard end > start, !text.isEmpty else { return nil }
            return CaptionCue(start: start, duration: end - start, text: text)
        }
    }

    /// Audio windows do not overlap. Each received cue has exactly one window owner; neither
    /// leading time nor equal text implies a duplicate. Keep every cue, including real repeats.
    /// Explicit ordinal tie-breaking keeps reload order independent of dictionary enumeration.
    static func assembledCues(_ windows: [TranscriptionWindowResult]) -> [CaptionCue] {
        windows.sorted { $0.index < $1.index }.flatMap(\.cues).enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
    }
}

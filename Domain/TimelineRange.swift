import Foundation
public enum TimelineRange {
    public static func project(_ project: Project, start: MediaTime, end: MediaTime) throws -> Project {
        guard start >= .zero, end > start, end <= project.sequence.duration else { throw ProjectError("출력 구간은 타임라인 안의 양수 길이여야 합니다.") }
        var copy = project
        for ti in copy.sequence.tracks.indices {
            copy.sequence.tracks[ti].clips = try project.sequence.tracks[ti].clips.compactMap { clip in
                let begin = max(start, clip.start), finish = min(end, clip.end)
                guard finish > begin else { return nil }
                let temporal = clip.assetID.flatMap { id in project.assets.first { $0.id == id } }?.kind != .image && clip.title == nil
                let offset = begin - clip.start
                let source = temporal ? clip.sourceStart + (clip.playbackRate ?? PlaybackRate()).sourceDuration(for: offset) : .zero
                var trimmed = try ClipTemporalEditor.trimmed(clip, newStart: begin - start, newSourceStart: source, newDuration: finish - begin, frameRate: project.sequence.frameRate, temporalSource: temporal, animationOffset: offset)
                // A range-export snapshot is independent; retain the editor's connections in its source document.
                trimmed.connection = nil
                return trimmed
            }
        }
        copy.sequence.markers = project.sequence.markers?.filter { $0.time >= start && $0.time < end }.map { var marker = $0; marker.time = marker.time - start; return marker }
        copy.derivedSequences = nil
        try ProjectValidator.validate(copy)
        return copy
    }
}

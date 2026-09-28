import Foundation

public struct ClipConnection: Codable, Equatable, Sendable {
    public var parentID: UUID
    /// The attached interval in the parent's original media, independent of timeline position/rate.
    public var sourceStart: MediaTime
    public var sourceDuration: MediaTime
    public var generatedText: String?
    public init(parentID: UUID, sourceStart: MediaTime, sourceDuration: MediaTime, generatedText: String? = nil) {
        self.parentID = parentID; self.sourceStart = sourceStart; self.sourceDuration = sourceDuration; self.generatedText = generatedText
    }
}
public struct GainPoint: Codable, Equatable, Sendable {
    public var time: MediaTime
    public var gain: Double
    public init(time: MediaTime, gain: Double) { self.time = time; self.gain = gain }
}
public struct TimelineMarker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var time: MediaTime
    public var name: String
    public init(time: MediaTime, name: String) { id = UUID(); self.time = time; self.name = name }
}
public enum TitleSizing {
    public static func resized(_ title: Title, from: Int, to: Int) -> Title {
        var title = title
        let factor = Double(max(1, to)) / Double(max(1, from))
        title.fontSize *= factor; title.style?.strokeWidth *= factor
        title.style?.padding *= factor; title.style?.lineSpacing *= factor
        return title
    }
    public static func title(for preset: TitlePreset, width: Int, height: Int) -> Title {
        let reference = preset.referenceShortEdge ?? (TitlePreset.builtIns.contains(where: { $0.id == preset.id }) ? 1080 : Double(min(width, height)))
        return resized(preset.title, from: Int(reference), to: min(width, height))
    }
}

public enum ConnectionEditing {
    public static func validate(_ sequence: Sequence) throws {
        let values = sequence.tracks.flatMap(\.clips)
        guard Set(values.map(\.id)).count == values.count else { throw ProjectError("중복된 클립 ID입니다.") }
        let clips = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        for clip in clips.values {
            if let link = clip.connection {
                guard link.parentID != clip.id, let parent = clips[link.parentID], parent.assetID != nil,
                      link.sourceStart >= .zero, link.sourceDuration > .zero else { throw ProjectError("연결된 원본 클립이나 시간 범위가 올바르지 않습니다.") }
                var visited: Set<UUID> = [clip.id], current: Clip? = parent
                while let value = current {
                    guard visited.insert(value.id).inserted else { throw ProjectError("클립 연결에 순환이 있습니다.") }
                    current = value.connection.flatMap { clips[$0.parentID] }
                }
            }
            var previous: MediaTime?
            for point in clip.ducking ?? [] {
                guard point.time >= .zero, point.time <= clip.duration, point.gain.isFinite, (0...1).contains(point.gain), previous.map({ $0 < point.time }) ?? true else { throw ProjectError("배경음 감쇠 구간이 올바르지 않습니다.") }
                previous = point.time
            }
        }
        for marker in sequence.markers ?? [] {
            guard marker.time >= .zero, !marker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("마커 이름과 시간을 확인하세요.") }
        }
    }
    /// Reconcile the entire transaction once; coordinated edits never double-move dependencies.
    public static func reconcile(before: Sequence, after: inout Sequence) throws {
        let old = Dictionary(uniqueKeysWithValues: before.tracks.flatMap(\.clips).map { ($0.id, $0) })
        // A child may itself be a parent (captions generated from separated dialogue).
        var depthMemo: [UUID: Int] = [:]
        func depth(_ clip: Clip, visited: Set<UUID> = []) throws -> Int {
            if let cached = depthMemo[clip.id] { return cached }
            guard !visited.contains(clip.id) else { throw ProjectError("클립 연결에 순환이 있습니다.") }
            guard let parent = clip.connection.flatMap({ id in old[id.parentID] }) else { return 0 }
            let value = try 1 + depth(parent, visited: visited.union([clip.id])); depthMemo[clip.id] = value; return value
        }
        let work = try after.tracks.flatMap(\.clips).filter { $0.connection != nil }.map { ($0.id, try depth($0)) }.sorted { $0.1 < $1.1 }
        for (id, _) in work {
            guard let ti = after.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  let ci = after.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { continue }
            let child = after.tracks[ti].clips[ci]
            guard var link = child.connection else { continue }
            let oldParent = old[link.parentID]
            let all = after.tracks.flatMap(\.clips)
            // Explicit edits of the child change its attached interval when its parent did not move.
            if let previous = old[id], let parent = all.first(where: { $0.id == link.parentID }), parent == oldParent,
               child.start != previous.start || child.duration != previous.duration {
                let rate = parent.playbackRate ?? PlaybackRate()
                link.sourceStart = try parent.sourceStart.adding(child.start.subtracting(parent.start).scaled(numerator: rate.numerator, denominator: rate.denominator))
                link.sourceDuration = rate.sourceDuration(for: child.duration)
                guard link.sourceStart >= parent.sourceStart, try link.sourceStart.adding(link.sourceDuration) <= parent.sourceStart.adding(parent.sourceDuration) else {
                    throw ProjectError("연결 범위 밖으로 이동하려면 먼저 연결을 해제하세요.")
                }
            }
            let family = oldParent.map { $0.lineageID ?? $0.id }
            let parents = all.filter { parent in
                parent.id == link.parentID || (family != nil && parent.lineageID == family)
            }.sorted { $0.start < $1.start }
            var replacements: [Clip] = []
            for parent in parents {
                let begin = max(link.sourceStart, parent.sourceStart)
                let end = min(try link.sourceStart.adding(link.sourceDuration), try parent.sourceStart.adding(parent.sourceDuration))
                guard end > begin else { continue }
                let newRate = parent.playbackRate ?? PlaybackRate()
                let oldRate = oldParent?.playbackRate ?? parent.playbackRate ?? PlaybackRate()
                let offset = oldRate.timelineDuration(for: begin - link.sourceStart)
                let length = oldRate.timelineDuration(for: end - begin)
                let start = try parent.start.adding(newRate.timelineDuration(for: begin - parent.sourceStart))
                let duration = newRate.timelineDuration(for: end - begin)
                if child.duration == duration, link.sourceStart == begin, link.sourceDuration == end - begin, oldRate == newRate {
                    var moved = child; moved.start = start; moved.connection = link; moved.connection?.parentID = parent.id
                    replacements.append(moved); continue
                }
                var copy = try ClipTemporalEditor.trimmed(child, newStart: start, newSourceStart: child.title == nil ? begin : .zero,
                    newDuration: length, frameRate: after.frameRate, temporalSource: child.title == nil, animationOffset: offset)
                let ratio = duration.seconds / length.seconds
                copy.duration = duration
                if child.title == nil { copy.playbackRate = newRate }
                copy.keyframes = copy.keyframes?.map { var key = $0; key.time = MediaTime(seconds: key.time.seconds * ratio); return key }
                copy.ducking = nil // a range edit needs fresh dialogue-based automation
                copy.connection = ClipConnection(parentID: parent.id, sourceStart: begin, sourceDuration: end - begin, generatedText: link.generatedText)
                if parents.count > 1 { copy.lineageID = child.lineageID ?? child.id }
                if !replacements.isEmpty { copy.id = UUID() }
                replacements.append(copy)
            }
            if replacements != [child], after.tracks[ti].isLocked { throw ProjectError("연결된 트랙이 잠겨 있어 편집할 수 없습니다: \(after.tracks[ti].name)") }
            after.tracks[ti].clips.replaceSubrange(ci...ci, with: replacements)
        }
    }
}

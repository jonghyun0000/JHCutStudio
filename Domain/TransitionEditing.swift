import Foundation

/// Storyline relationships are explicit; ordinary decorative overlays never participate.
public enum TransitionEditing {
    public static func validate(_ sequence: Sequence) throws {
        var links: [UUID: UUID] = [:]
        for track in sequence.tracks {
            guard let context = track.transitionContext else { continue }
            guard track.kind == .overlay, let incoming = track.clips.first, Set(track.clips.map(family)).count == 1,
                  sequence.tracks.contains(where: { $0.id == context.originTrackID && $0.kind == .video }),
                  sequence.tracks.flatMap(\.clips).contains(where: { family($0) == context.outgoingFamilyID }), context.effect.duration > .zero else { throw ProjectError("전환의 장면 연결이 올바르지 않습니다. 전환을 제거한 뒤 장면을 편집하세요.") }
            links[family(incoming)] = context.outgoingFamilyID
        }
        for first in links.keys {
            var seen = Set<UUID>(), current: UUID? = first
            while let id = current { guard seen.insert(id).inserted else { throw ProjectError("전환 장면 연결에 순환이 있습니다.") }; current = links[id] }
        }
    }
    public static func family(_ clip: Clip) -> UUID { clip.lineageID ?? clip.id }
    public static func context(of track: Track, in sequence: Sequence) -> TransitionContext? {
        if let value = track.transitionContext { return value }
        guard track.kind == .overlay, let incoming = track.clips.min(by: { $0.start < $1.start }), incoming.title == nil else { return nil }
        let effect = incoming.transition ?? (track.name.hasPrefix("디졸브") ? incoming.fadeIn.map { ClipTransition(kind: .dissolve, duration: $0) } : nil)
        guard let effect, effect.duration > .zero, let index = sequence.tracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        for earlier in sequence.tracks[..<index].reversed() {
            guard earlier.kind == .video || earlier.transitionContext != nil || context(of: earlier, in: sequence) != nil else { continue }
            if let outgoing = earlier.clips.first(where: { $0.end == incoming.start + effect.duration && $0.start < incoming.start }) {
                let origin = earlier.transitionContext?.originTrackID ?? context(of: earlier, in: sequence)?.originTrackID ?? earlier.id
                return TransitionContext(originTrackID: origin, outgoingFamilyID: family(outgoing), effect: effect)
            }
        }
        return nil
    }
    private static func requireUnlocked(_ track: Track) throws {
        guard !track.isLocked else { throw ProjectError("전환에 포함된 트랙의 잠금을 먼저 해제하세요: \(track.name)") }
    }
    private static func span(_ clips: [Clip]) throws -> (start: MediaTime, end: MediaTime) {
        guard let start = clips.map(\.start).min(), let end = clips.map(\.end).max() else { throw ProjectError("전환 장면을 찾을 수 없습니다.") }
        return (start, end)
    }
    private static func familyClips(_ id: UUID, _ sequence: Sequence) -> [Clip] { sequence.tracks.flatMap(\.clips).filter { family($0) == id } }
    /// Promote only legacy pairs touched by a temporal edit; the original document remains the undo snapshot.
    public static func prepareTemporal(_ command: EditCommand, in sequence: inout Sequence) throws {
        switch command {
        case .batch(let commands):
            for child in commands { try prepareTemporal(child, in: &sequence) }
        case .split(let trackID, let clipID, _), .trimClip(let trackID, let clipID, _, _, _), .setRate(let trackID, let clipID, _), .speedRamp(let trackID, let clipID, _, _):
            guard let clip = sequence.tracks.first(where: { $0.id == trackID })?.clips.first(where: { $0.id == clipID }) else { return }
            let id = family(clip)
            let affected = sequence.tracks.filter { track in
                guard track.transitionContext == nil, let value = context(of: track, in: sequence) else { return false }
                return value.outgoingFamilyID == id || track.clips.contains { family($0) == id }
            }.map(\.id)
            for id in affected { _ = try adopt(id, in: &sequence) }
        default: break
        }
    }
    /// Legacy files are promoted only inside an explicit, undoable transition edit.
    private static func adopt(_ trackID: UUID, in sequence: inout Sequence) throws -> TransitionContext {
        guard let ti = sequence.tracks.firstIndex(where: { $0.id == trackID }), var value = context(of: sequence.tracks[ti], in: sequence) else { throw ProjectError("수정할 전환을 찾을 수 없습니다.") }
        try requireUnlocked(sequence.tracks[ti])
        if sequence.tracks[ti].transitionContext == nil {
            value.effect.independentFade = true
            let incomingIDs = Set(sequence.tracks[ti].clips.map(\.id))
            let outgoingIDs = Set(familyClips(value.outgoingFamilyID, sequence).map(\.id))
            for t in sequence.tracks.indices {
                for c in sequence.tracks[t].clips.indices {
                    var clip = sequence.tracks[t].clips[c]
                    let outgoing = outgoingIDs.contains(clip.id) || clip.connection.map { outgoingIDs.contains($0.parentID) } == true
                    let incoming = incomingIDs.contains(clip.id) || clip.connection.map { incomingIDs.contains($0.parentID) } == true
                    let d = min(value.effect.duration, clip.duration)
                    if incomingIDs.contains(clip.id) {
                        clip.transition = value.effect
                        if clip.fadeIn == value.effect.duration { clip.fadeIn = nil }
                    }
                    if incoming, clip.audioFadeIn == d { clip.audioFadeIn = nil }
                    if outgoing, clip.audioFadeOut == d { clip.audioFadeOut = nil }
                    if clip != sequence.tracks[t].clips[c] { try requireUnlocked(sequence.tracks[t]); sequence.tracks[t].clips[c] = clip }
                }
            }
            sequence.tracks[ti].transitionContext = value
        }
        return value
    }
    public static func add(in sequence: inout Sequence, trackID: UUID, clipID: UUID, effect: ClipTransition) throws {
        guard let selected = sequence.tracks.first(where: { $0.id == trackID }), let left = selected.clips.first(where: { $0.id == clipID }) else { throw ProjectError("전환의 앞 장면을 찾을 수 없습니다.") }
        try requireUnlocked(selected)
        let origin: UUID
        if selected.kind == .video { origin = selected.id }
        else { origin = try adopt(trackID, in: &sequence).originTrackID }
        guard let root = sequence.tracks.first(where: { $0.id == origin }) else { throw ProjectError("메인 영상 트랙을 찾을 수 없습니다.") }
        try requireUnlocked(root)
        guard !sequence.tracks.contains(where: { $0.transitionContext?.outgoingFamilyID == family(left) }) else { throw ProjectError("이 장면에는 이미 다음 전환이 있습니다. 기존 전환을 수정하거나 제거하세요.") }
        if selected.kind == .video {
            // Raw cuts can share caption lineage without constituting one scene group.
            let oldFamily = family(left)
            for t in sequence.tracks.indices where sequence.tracks[t].id == origin {
                for c in sequence.tracks[t].clips.indices where family(sequence.tracks[t].clips[c]) == oldFamily { sequence.tracks[t].clips[c].lineageID = nil }
            }
        }
        let leftFamily = selected.kind == .video ? left.id : family(left)
        let leftSpan = selected.kind == .video ? (start: left.start, end: left.end) : try span(familyClips(leftFamily, sequence))
        guard let right = root.clips.filter({ $0.start >= leftSpan.end }).min(by: { $0.start < $1.start }) else { throw ProjectError("다음 영상 클립이 있어야 합니다.") }
        let rightFamily = family(right)
        let groupedRight = sequence.tracks.contains { $0.transitionContext?.outgoingFamilyID == rightFamily }
        let rightPieces = groupedRight ? root.clips.filter { family($0) == rightFamily } : [right]
        let rightSpan = try span(rightPieces)
        guard rightSpan.start == leftSpan.end, effect.duration > .zero, effect.duration < min(leftSpan.end - leftSpan.start, rightSpan.end - rightSpan.start) else { throw ProjectError("서로 붙어 있는 두 클립보다 짧은 전환을 선택하세요.") }
        if !groupedRight {
            for t in sequence.tracks.indices where sequence.tracks[t].id == origin {
                for c in sequence.tracks[t].clips.indices where family(sequence.tracks[t].clips[c]) == rightFamily { sequence.tracks[t].clips[c].lineageID = nil }
            }
        }
        // Three-way overlaps would require a different compositing policy.
        let previousWindowEnd = selected.clips.compactMap { clip -> MediaTime? in
            guard let transition = clip.transition else { return nil }
            return clip.start + min(clip.duration, max(.zero, transition.duration - (transition.offset ?? .zero)))
        }.max() ?? leftSpan.start
        guard leftSpan.end - effect.duration >= previousWindowEnd else { throw ProjectError("앞 전환과 겹치지 않도록 전환 길이를 줄이세요.") }
        let boundary = right.start
        for t in sequence.tracks.indices where sequence.tracks[t].id == origin || sequence.tracks[t].transitionContext?.originTrackID == origin {
            for c in sequence.tracks[t].clips.indices where sequence.tracks[t].clips[c].start >= boundary {
                try requireUnlocked(sequence.tracks[t])
                sequence.tracks[t].clips[c].start = try sequence.tracks[t].clips[c].start.subtracting(effect.duration)
            }
        }
        guard let ri = sequence.tracks.firstIndex(where: { $0.id == origin }) else { throw ProjectError("다음 장면이 변경되었습니다.") }
        let rightIDs = Set(rightPieces.map(\.id))
        let moved = sequence.tracks[ri].clips.filter { rightIDs.contains($0.id) }
        sequence.tracks[ri].clips.removeAll { rightIDs.contains($0.id) }
        let incomingStart = moved.map(\.start).min()!
        let incoming = moved.map { original -> Clip in
            var clip = original, t = effect
            let offset = clip.start - incomingStart
            if offset != .zero { t.offset = offset }
            clip.transition = offset >= t.duration ? nil : t; return clip
        }
        var transitionTrack = Track(name: effect.kind.label + " · " + right.name, kind: .overlay, clips: incoming)
        transitionTrack.transitionContext = TransitionContext(originTrackID: origin, outgoingFamilyID: leftFamily, effect: effect)
        let leftTrack = sequence.tracks.firstIndex(where: { $0.id == trackID })!
        sequence.tracks.insert(transitionTrack, at: leftTrack + 1)
    }
    public static func update(in sequence: inout Sequence, trackID: UUID, effect: ClipTransition?) throws {
        let context = try adopt(trackID, in: &sequence)
        let ti = sequence.tracks.firstIndex(where: { $0.id == trackID })!
        let incoming = sequence.tracks[ti].clips, current = try span(incoming)
        let outgoing = familyClips(context.outgoingFamilyID, sequence), previous = try span(outgoing)
        if let effect {
            guard effect.duration > .zero, effect.duration < min(previous.end - previous.start, current.end - current.start) else { throw ProjectError("서로 붙어 있는 두 클립보다 짧은 전환을 선택하세요.") }
            let previousWindowEnd = outgoing.compactMap { clip -> MediaTime? in
                guard let t = clip.transition else { return nil }; return clip.start + min(clip.duration, max(.zero, t.duration - (t.offset ?? .zero)))
            }.max() ?? previous.start
            guard previous.end - effect.duration >= previousWindowEnd else { throw ProjectError("앞 전환과 겹치지 않도록 전환 길이를 줄이세요.") }
        }
        let newStart = try previous.end.subtracting(effect?.duration ?? .zero)
        let delta = try newStart.subtracting(current.start)
        let own = Set(incoming.map(\.id)), outgoingIDs = Set(outgoing.map(\.id))
        for t in sequence.tracks.indices where sequence.tracks[t].id == context.originTrackID || sequence.tracks[t].transitionContext?.originTrackID == context.originTrackID {
            for c in sequence.tracks[t].clips.indices {
                let clip = sequence.tracks[t].clips[c]
                if own.contains(clip.id) || (!outgoingIDs.contains(clip.id) && clip.start > current.start) {
                    try requireUnlocked(sequence.tracks[t]); sequence.tracks[t].clips[c].start = try clip.start.adding(delta)
                }
            }
        }
        if let effect {
            sequence.tracks[ti].transitionContext?.effect = effect
            sequence.tracks[ti].name = effect.kind.label + " · " + (incoming.first?.name ?? "영상")
            for c in sequence.tracks[ti].clips.indices {
                var t = effect; let offset = sequence.tracks[ti].clips[c].start - newStart
                if offset == .zero { sequence.tracks[ti].clips[c].transition = t }
                else { t.offset = offset; sequence.tracks[ti].clips[c].transition = offset >= t.duration ? nil : t }
            }
        } else {
            guard let destination = sequence.tracks.firstIndex(where: { $0.id == context.originTrackID }) else { throw ProjectError("원래 메인 트랙을 찾을 수 없습니다.") }
            try requireUnlocked(sequence.tracks[destination])
            sequence.tracks[destination].clips += sequence.tracks[ti].clips.map { var clip = $0; clip.transition = nil; return clip }
            sequence.tracks[destination].clips.sort { $0.start < $1.start }
            sequence.tracks.remove(at: ti)
        }
    }
    public static func changeAppearance(in sequence: inout Sequence, trackID: UUID, kind: TransitionKind, direction: TransitionDirection) throws {
        _ = try adopt(trackID, in: &sequence)
        let ti = sequence.tracks.firstIndex(where: { $0.id == trackID })!
        sequence.tracks[ti].transitionContext?.effect.kind = kind
        sequence.tracks[ti].transitionContext?.effect.direction = direction
        sequence.tracks[ti].name = kind.label + " · " + (sequence.tracks[ti].clips.first?.name ?? "영상")
        for ci in sequence.tracks[ti].clips.indices {
            sequence.tracks[ti].clips[ci].transition?.kind = kind
            sequence.tracks[ti].clips[ci].transition?.direction = direction
        }
    }
    /// Rebuild absolute storyline positions only for speed changes. This avoids separately
    /// rippling a main lane and its transition lanes, or double-moving a later transition.
    public static func reconcileRates(before: Sequence, after: inout Sequence) throws {
        let old = before.tracks.flatMap(\.clips)
        let changedFamilies = Set(after.tracks.flatMap(\.clips).compactMap { clip -> UUID? in
            let previous = old.first { $0.id == clip.id } ?? old.first { family($0) == family(clip) && $0.assetID == clip.assetID }
            return previous.map { ($0.playbackRate ?? PlaybackRate()).multiplier != (clip.playbackRate ?? PlaybackRate()).multiplier } == true ? family(clip) : nil
        })
        guard !changedFamilies.isEmpty else { return }
        for root in after.tracks.filter({ $0.kind == .video }) where after.tracks.contains(where: { $0.transitionContext?.originTrackID == root.id }) {
            let oldTracks = before.tracks.filter { $0.id == root.id || $0.transitionContext?.originTrackID == root.id }
            let newTracks = after.tracks.filter { $0.id == root.id || $0.transitionContext?.originTrackID == root.id }
            let oldGroups = Dictionary(grouping: oldTracks.flatMap(\.clips), by: family)
            let groups = Dictionary(grouping: newTracks.flatMap(\.clips), by: family)
            guard !Set(groups.keys).isDisjoint(with: changedFamilies) else { continue }
            let ordered = try oldGroups.keys.sorted { try span(oldGroups[$0]!).start < span(oldGroups[$1]!).start }
            var previousEnd: MediaTime?, previousOldEnd: MediaTime?, previousEffectEnd: MediaTime?
            for id in ordered {
                guard groups[id] != nil else { continue }
                var pieces = after.tracks.flatMap(\.clips).filter { family($0) == id }
                let oldSpan = try span(oldGroups[id]!), current = try span(pieces)
                let context = newTracks.first(where: { $0.clips.contains(where: { family($0) == id }) })?.transitionContext
                var target = current.start
                if let end = previousEnd, let oldEnd = previousOldEnd {
                    if context != nil {
                        var effectEnd = pieces.compactMap { clip -> MediaTime? in
                            guard let t = clip.transition else { return nil }; return clip.start + min(clip.duration, max(.zero, t.duration - (t.offset ?? .zero)))
                        }.max() ?? current.start
                        let available = max(.zero, end - (previousEffectEnd ?? end))
                        if effectEnd - current.start > available {
                            // Shortening a middle scene must not create a three-scene overlap.
                            let first = pieces.sorted { $0.start < $1.start }.first?.transition
                            let p = first?.progress(at: .zero) ?? 0
                            let d = available > .zero && p < 1 ? MediaTime(seconds: available.seconds / (1 - p)) : .zero
                            for t in after.tracks.indices {
                                for c in after.tracks[t].clips.indices where family(after.tracks[t].clips[c]) == id {
                                    try requireUnlocked(after.tracks[t])
                                    var effect = first ?? context!.effect
                                    effect.duration = d
                                    effect.offset = MediaTime(seconds: d.seconds * p) + after.tracks[t].clips[c].start - current.start
                                    after.tracks[t].clips[c].transition = d > .zero && effect.offset! < d ? effect : nil
                                }
                            }
                            pieces = after.tracks.flatMap(\.clips).filter { family($0) == id }
                            effectEnd = current.start + available
                        }
                        target = end - (effectEnd - current.start) + max(.zero, oldSpan.start - oldEnd)
                    } else { target = end + (oldSpan.start - oldEnd) }
                }
                let delta = target - current.start
                for t in after.tracks.indices {
                    for c in after.tracks[t].clips.indices where family(after.tracks[t].clips[c]) == id {
                        if delta != .zero { try requireUnlocked(after.tracks[t]); after.tracks[t].clips[c].start = try after.tracks[t].clips[c].start.adding(delta) }
                    }
                }
                previousEnd = try current.end.adding(delta); previousOldEnd = oldSpan.end
                previousEffectEnd = pieces.compactMap { clip -> MediaTime? in
                    guard let effect = clip.transition else { return nil }
                    return clip.start + min(clip.duration, max(.zero, effect.duration - (effect.offset ?? .zero))) + delta
                }.max() ?? target
            }
        }
    }
    /// Runs after connected-media reconciliation, so child fades use their final timeline times.
    public static func refreshAudio(in sequence: inout Sequence) throws {
        let all = Dictionary(uniqueKeysWithValues: sequence.tracks.flatMap(\.clips).map { ($0.id, $0) })
        func rootFamily(_ clip: Clip) -> UUID {
            var root = clip, seen = Set<UUID>()
            while let parent = root.connection.flatMap({ all[$0.parentID] }), seen.insert(root.id).inserted { root = parent }
            return family(root)
        }
        var desired: [UUID: [TransitionAudioFade]] = [:]
        for ti in sequence.tracks.indices {
            let track = sequence.tracks[ti]
            guard let context = track.transitionContext, let incoming = track.clips.first else { continue }
            var global: [MediaTime: Double] = [:]
            for clip in track.clips {
                guard let effect = clip.transition else { continue }
                let end = min(clip.duration, max(.zero, effect.duration - (effect.offset ?? .zero)))
                guard end > .zero else { continue }
                global[clip.start] = effect.progress(at: .zero); global[clip.start + end] = effect.progress(at: end)
                if let offset = effect.offset, offset < .zero, -offset.seconds < end.seconds { global[clip.start - offset] = 0 }
            }
            guard let start = global.keys.min(), let end = global.keys.max(), end > start else { continue }
            let window = end - start
            if sequence.tracks[ti].transitionContext?.effect.duration != window {
                try requireUnlocked(track); sequence.tracks[ti].transitionContext?.effect.duration = window
            }
            if let first = global[start], first > 0, start > .zero { global[max(.zero, start - MediaTime(1, 480_000))] = 0 }
            for clip in all.values where clip.title == nil {
                let id = rootFamily(clip), isIncoming = id == family(incoming)
                guard isIncoming || id == context.outgoingFamilyID else { continue }
                var fade = TransitionAudioFade(ownerID: track.id, start: start - clip.start, duration: end - start, incoming: isIncoming)
                var gains = global.mapValues { isIncoming ? $0 : 1 - $0 }
                let tick = MediaTime(1, 480_000)
                if clip.end > end {
                    if isIncoming {
                        // A later, non-effect fragment must regain its normal volume.
                        if gains[end] != 1 { gains[end + tick] = 1 }
                    } else {
                        // If a tail trim ends the incoming scene early, the visible outgoing
                        // scene resumes its own volume. While incoming media continues, stay muted.
                        func coveredGain(_ time: MediaTime) -> Double { track.clips.contains { $0.start <= time && $0.end > time } ? 0 : 1 }
                        let resumed = coveredGain(end)
                        if gains[end] != resumed { gains[end + tick] = resumed }
                        let boundaries = Set(track.clips.flatMap { [$0.start, $0.end] }).filter { $0 > end && $0 < clip.end }.sorted()
                        for boundary in boundaries {
                            let before = max(end + tick, boundary - tick)
                            gains[before] = coveredGain(before); gains[boundary] = coveredGain(boundary)
                        }
                    }
                }
                fade.points = gains.keys.sorted().map { GainPoint(time: $0 - clip.start, gain: gains[$0]!) }
                desired[clip.id, default: []].append(fade)
            }
        }
        for t in sequence.tracks.indices {
            for c in sequence.tracks[t].clips.indices {
                let fades = desired[sequence.tracks[t].clips[c].id]
                if sequence.tracks[t].clips[c].transitionAudioFades != fades {
                    try requireUnlocked(sequence.tracks[t]); sequence.tracks[t].clips[c].transitionAudioFades = fades
                }
            }
        }
    }
}

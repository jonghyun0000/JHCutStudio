import Foundation

public enum CaptionRole: String, Codable, Sendable, CaseIterable {
    case title, original, translation
    public var label: String { switch self { case .title: return "일반 제목"; case .original: return "원문 자막"; case .translation: return "번역 자막" } }
}

public enum CaptionScope: Equatable, Sendable {
    case all
    case selected(Set<UUID>)
    case sources(Set<UUID>)
    case groups(Set<UUID>)
}

public struct CaptionEntry: Sendable {
    public let track: Track
    public let clip: Clip
    public let role: CaptionRole
    public let groupID: UUID
    public var isVisible: Bool { !track.isHidden && clip.captionHidden != true }
}

/// One classification/query contract for editing, translation, SRT and rendering QA.
public enum CaptionQuery {
    public static func role(of clip: Clip) -> CaptionRole? {
        guard clip.title != nil else { return nil }
        if let role = clip.captionRole { return role }
        if let metadata = clip.captionMetadata { return metadata.translatedFrom == nil ? .original : .translation }
        // Schema-1 SRT importer used this exact name/shape. Arbitrary title names stay unclassified.
        if clip.name == "자막", clip.assetID == nil, clip.sourceStart == .zero { return .original }
        if clip.name == "자동 자막", clip.connection?.generatedText != nil { return .original }
        return nil
    }
    public static func entries(in sequence: Sequence, scope: CaptionScope = .all, role: CaptionRole? = nil,
                               visibleOnly: Bool = false, editableOnly: Bool = false) -> [CaptionEntry] {
        let locations = sequence.tracks.flatMap { track in track.clips.map { (track, $0) } }
        func group(_ track: Track, _ clip: Clip) -> UUID {
            clip.captionGroupID ?? clip.connection?.parentID ?? (clip.name == "자막" ? track.id : clip.lineageID ?? clip.id)
        }
        return locations.compactMap { track, clip -> CaptionEntry? in
            guard track.kind == .title, let kind = self.role(of: clip), kind != .title, role == nil || role == kind else { return nil }
            var groupID = group(track, clip)
            if clip.captionGroupID == nil, kind == .translation, let from = clip.captionMetadata?.translatedFrom,
               let (sourceTrack, source) = locations.first(where: { $0.1.id == from || $0.1.lineageID == from }) {
                groupID = group(sourceTrack, source)
            }
            let entry = CaptionEntry(track: track, clip: clip, role: kind, groupID: groupID)
            guard (!visibleOnly || entry.isVisible), (!editableOnly || !track.isLocked) else { return nil }
            switch scope {
            case .all: break
            case .selected(let ids): guard ids.contains(clip.id) else { return nil }
            case .sources(let ids): guard clip.connection.map({ ids.contains($0.parentID) }) == true else { return nil }
            case .groups(let ids): guard ids.contains(groupID) else { return nil }
            }
            return entry
        }.sorted { $0.clip.start == $1.clip.start ? $0.clip.id.uuidString < $1.clip.id.uuidString : $0.clip.start < $1.clip.start }
    }
    public static func originals(in sequence: Sequence, scope: CaptionScope) -> [CaptionEntry] {
        if case .selected(let ids) = scope {
            let chosen = entries(in: sequence, scope: scope)
            return entries(in: sequence, role: .original).filter { original in
                ids.contains(original.clip.id) || chosen.contains { related($0.clip, to: original.clip) }
            }
        }
        return entries(in: sequence, scope: scope, role: .original)
    }
    public static func migrated(_ sequence: Sequence) -> Sequence {
        var result = sequence
        for entry in entries(in: sequence) {
            let ti = result.tracks.firstIndex { $0.id == entry.track.id }!
            let ci = result.tracks[ti].clips.firstIndex { $0.id == entry.clip.id }!
            if result.tracks[ti].clips[ci].captionRole == nil { result.tracks[ti].clips[ci].captionRole = entry.role }
            if result.tracks[ti].clips[ci].captionGroupID == nil { result.tracks[ti].clips[ci].captionGroupID = entry.groupID }
        }
        return result
    }
    public static func related(_ candidate: Clip, to original: Clip) -> Bool {
        guard self.role(of: candidate) == .translation, let from = candidate.captionMetadata?.translatedFrom,
              (candidate.captionMetadata?.translationRevision.map { $0.sourceCaptionID == original.id } ?? (from == original.id || from == original.lineageID)),
              candidate.captionMetadata?.translationRevision != nil || (candidate.start < original.end && candidate.end > original.start) else { return false }
        return candidate.captionGroupID == nil || original.captionGroupID == nil || candidate.captionGroupID == original.captionGroupID
    }
}

public enum CaptionScopeEditing {
    /// Never toggles a track. Only selected originals and their related representations change.
    public static func displaying(in sequence: Sequence, originals: [Clip], target: String?) throws -> Sequence {
        var result = sequence
        let ids = Set(originals.map(\.id))
        for ti in result.tracks.indices where result.tracks[ti].kind == .title {
            for ci in result.tracks[ti].clips.indices {
                let old = result.tracks[ti].clips[ci]
                let isOriginal = ids.contains(old.id) && CaptionQuery.role(of: old) == .original
                let isTranslation = originals.contains { CaptionQuery.related(old, to: $0) }
                guard isOriginal || isTranslation else { continue }
                let hide = target == nil ? isTranslation : isOriginal || old.captionMetadata?.language != target
                guard (old.captionHidden == true) != hide else { continue }
                guard !result.tracks[ti].isLocked else { throw ProjectError("선택 범위의 자막 트랙 잠금을 해제하세요: " + result.tracks[ti].name) }
                result.tracks[ti].clips[ci].captionHidden = hide ? true : nil
            }
        }
        return result
    }
    public static func installing(_ translated: [Clip], for originals: [Clip], target: String, in sequence: Sequence) throws -> Sequence {
        guard Set(translated.map(\.id)).count == translated.count else { throw ProjectError("번역 자막의 원문 연결이 중복되어 적용하지 않았습니다. 원문을 확인하세요.") }
        let incoming = Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0) })
        var result = try displaying(in: sequence, originals: originals, target: target)
        let existing = result.tracks.firstIndex { track in
            !track.isLocked && !track.isHidden && track.kind == .title && track.clips.contains { candidate in
                candidate.captionMetadata?.language == target && originals.contains { CaptionQuery.related(candidate, to: $0) }
            }
        }
        for ti in result.tracks.indices {
            let removals = result.tracks[ti].clips.filter { candidate in
                candidate.captionMetadata?.language == target && originals.contains { CaptionQuery.related(candidate, to: $0) }
            }
            if !removals.isEmpty {
                guard !result.tracks[ti].isLocked else { throw ProjectError("선택 범위의 번역 트랙 잠금을 해제하세요.") }
                let ids = Set(removals.filter { incoming[$0.id] == nil }.map(\.id))
                result.tracks[ti].clips.removeAll { ids.contains($0.id) }
                for ci in result.tracks[ti].clips.indices {
                    if var kept = incoming[result.tracks[ti].clips[ci].id] { kept.captionHidden = nil; result.tracks[ti].clips[ci] = kept }
                }
            }
        }
        let keptIDs = Set(result.tracks.flatMap(\.clips).map(\.id))
        let clips = translated.filter { !keptIDs.contains($0.id) }.map { value -> Clip in var clip = value; clip.captionHidden = nil; return clip }.sorted { $0.start < $1.start }
        guard !clips.isEmpty else { return result }
        if let ti = existing { result.tracks[ti].clips += clips }
        else { result.tracks.append(Track(name: "번역 자막 · " + (CaptionLanguage(rawValue: target)?.label ?? target), kind: .title, clips: clips)) }
        return result
    }
}

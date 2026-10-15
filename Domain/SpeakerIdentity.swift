import Foundation

/// Identity is a recording's native channel, never a globally inferred human identity.
/// Asset IDs survive trims, splits, copies and derived sequences; names/colours are presentation.
public enum SpeakerIdentity {
    public static func channel(sourceID: UUID, index: Int) -> String {
        "channel|\(sourceID.uuidString.lowercased())|\(index)"
    }
    public static func manual(sourceID: UUID) -> String { "manual|\(sourceID.uuidString.lowercased())|\(UUID().uuidString.lowercased())" }
    public static func sourceID(_ identity: String) -> UUID? {
        let parts = identity.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, ["channel", "manual", "legacy"].contains(String(parts[0])) else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
    public static func channelIndex(_ identity: String) -> Int? {
        let parts = identity.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "channel", sourceID(identity) != nil,
              let n = Int(parts[2]), (0..<32).contains(n) else { return nil }
        return n
    }
    public static func sourceID(for clip: Clip, in sequence: Sequence) -> UUID {
        let original = CaptionQuery.role(of: clip) == .translation ? CaptionTranslationTracking.source(for: clip, in: sequence) ?? clip : clip
        if let parent = original.connection?.parentID, let asset = sequence.tracks.flatMap(\.clips).first(where: { $0.id == parent })?.assetID { return asset }
        // Unattached legacy cues remain isolated by their known group/family, never global A/B.
        return original.captionGroupID ?? original.lineageID ?? original.id
    }
    public static func isValid(_ identity: String) -> Bool {
        guard let kind = identity.split(separator: "|").first else { return false }
        if !["channel", "manual", "legacy"].contains(String(kind)) { return !identity.isEmpty } // old custom IDs
        guard sourceID(identity) != nil else { return false }
        let parts = identity.split(separator: "|", omittingEmptySubsequences: false)
        if kind == "channel" { return channelIndex(identity) != nil }
        if kind == "manual" { return UUID(uuidString: String(parts[2])) != nil }
        return !parts[2].isEmpty
    }
}

public enum SpeakerEditing {
    /// Deterministic, idempotent migration of the old A…H namespace. Clone presentation per source;
    /// translations resolve their actual source, including hidden tracks. No media or timing changes.
    public static func migrating(_ sequence: Sequence) -> Sequence {
        var result = sequence
        let oldProfiles = sequence.speakers ?? []
        var profiles = oldProfiles.filter { !SpeakerSeparation.labels.contains($0.id) }
        var used = Set<String>()
        for ti in result.tracks.indices { for ci in result.tracks[ti].clips.indices {
            let clip = result.tracks[ti].clips[ci]
            guard let old = clip.captionMetadata?.speaker, let index = SpeakerSeparation.labels.firstIndex(of: old) else { continue }
            let scope = SpeakerIdentity.sourceID(for: clip, in: sequence), id = SpeakerIdentity.channel(sourceID: scope, index: index)
            result.tracks[ti].clips[ci].captionMetadata?.speaker = id; used.insert(old)
            if !profiles.contains(where: { $0.id == id }) {
                let previous = oldProfiles.first { $0.id == old }
                profiles.append(SpeakerProfile(id: id, name: previous?.name ?? "화자 \(old)", colorHex: previous?.colorHex ?? SpeakerProfile.defaultColors[index % SpeakerProfile.defaultColors.count]))
            }
        } }
        // Keep even a temporarily unused user name/colour, without reintroducing global identities.
        for profile in oldProfiles where SpeakerSeparation.labels.contains(profile.id) && !used.contains(profile.id) {
            var saved = profile; saved.id = "legacy|\(sequence.id.uuidString.lowercased())|\(profile.id)"; profiles.append(saved)
        }
        result.speakers = profiles.isEmpty ? sequence.speakers : profiles
        return result
    }
    public static func assigning(_ id: String?, to originalIDs: Set<UUID>, in sequence: Sequence) throws -> Sequence {
        var result = migrating(sequence)
        let originals = CaptionQuery.entries(in: result, role: .original).filter { originalIDs.contains($0.clip.id) }
        guard !originals.isEmpty else { throw ProjectError("화자를 지정할 원문 또는 번역 자막을 선택하세요.") }
        if let id {
            guard result.speakers?.contains(where: { $0.id == id }) == true else { throw ProjectError("선택한 화자가 없습니다.") }
            guard let scope = SpeakerIdentity.sourceID(id), originals.allSatisfy({ SpeakerIdentity.sourceID(for: $0.clip, in: result) == scope }) else { throw ProjectError("같은 원본의 화자를 선택하세요. 서로 다른 녹음은 자동으로 합치지 않습니다.") }
        }
        for ti in result.tracks.indices { for ci in result.tracks[ti].clips.indices {
            let clip = result.tracks[ti].clips[ci]
            let direct = originals.contains { $0.clip.id == clip.id }
            let related = originals.contains { CaptionQuery.related(clip, to: $0.clip) }
            guard direct || related else { continue }
            if related && !direct {
                guard let source = CaptionTranslationTracking.source(for: clip, in: result), originalIDs.contains(source.id) else { throw ProjectError("번역의 원문 연결이 불확실합니다. 화자를 변경하기 전에 연결을 확인하세요.") }
            }
            guard !result.tracks[ti].isLocked else { throw ProjectError("연결된 자막 트랙 잠금을 해제하세요: " + result.tracks[ti].name) }
            if result.tracks[ti].clips[ci].captionMetadata == nil {
                let text = clip.title?.text ?? ""
                result.tracks[ti].clips[ci].captionMetadata = CaptionMetadata(language: "auto", originalLanguage: "auto", originalText: text, generatedText: text)
            }
            result.tracks[ti].clips[ci].captionMetadata?.speaker = id
            result.tracks[ti].clips[ci].captionMetadata?.speakerStatus = id == nil ? "cleared" : "manual"
            result.tracks[ti].clips[ci].captionMetadata?.speakerManual = true
            if let color = result.speakers?.first(where: { $0.id == id })?.colorHex { result.tracks[ti].clips[ci].title?.colorHex = color }
        } }
        return result
    }
    public static func merging(_ from: String, into to: String, in sequence: Sequence) throws -> Sequence {
        guard from != to, let scope = SpeakerIdentity.sourceID(from), scope == SpeakerIdentity.sourceID(to) else { throw ProjectError("같은 원본의 서로 다른 두 화자를 선택하세요.") }
        var result = migrating(sequence)
        guard result.speakers?.contains(where: { $0.id == from }) == true, result.speakers?.contains(where: { $0.id == to }) == true else { throw ProjectError("합칠 화자가 없습니다.") }
        for ti in result.tracks.indices { for ci in result.tracks[ti].clips.indices where result.tracks[ti].clips[ci].captionMetadata?.speaker == from {
            guard !result.tracks[ti].isLocked else { throw ProjectError("화자의 자막 트랙 잠금을 해제하세요.") }
            result.tracks[ti].clips[ci].captionMetadata?.speaker = to
            result.tracks[ti].clips[ci].captionMetadata?.speakerStatus = "manual"
            result.tracks[ti].clips[ci].captionMetadata?.speakerManual = true
            result.tracks[ti].clips[ci].title?.colorHex = result.speakers?.first { $0.id == to }?.colorHex ?? "FFFFFF"
        } }
        result.speakers?.removeAll { $0.id == from }; return result
    }
    /// A source speaker correction follows the exact translation link, never same-time adjacency.
    public static func reconcile(before: Sequence, after: inout Sequence) throws {
        let old = Dictionary(uniqueKeysWithValues: before.tracks.flatMap(\.clips).map { ($0.id, $0) })
        for ti in after.tracks.indices { for ci in after.tracks[ti].clips.indices {
            let clip = after.tracks[ti].clips[ci]
            guard CaptionQuery.role(of: clip) == .translation, let source = CaptionTranslationTracking.source(for: clip, in: after), let prior = old[source.id],
                  prior.captionMetadata?.speaker != source.captionMetadata?.speaker || prior.captionMetadata?.speakerStatus != source.captionMetadata?.speakerStatus || prior.captionMetadata?.speakerManual != source.captionMetadata?.speakerManual else { continue }
            var updated = clip
            updated.captionMetadata?.speaker = source.captionMetadata?.speaker
            updated.captionMetadata?.speakerStatus = source.captionMetadata?.speakerStatus
            updated.captionMetadata?.speakerManual = source.captionMetadata?.speakerManual
            if let id = source.captionMetadata?.speaker, let color = after.speakers?.first(where: { $0.id == id })?.colorHex { updated.title?.colorHex = color }
            guard updated != clip else { continue }
            guard !after.tracks[ti].isLocked else { throw ProjectError("연결된 번역 자막 트랙 잠금을 해제하세요.") }
            after.tracks[ti].clips[ci] = updated
        } }
    }
}

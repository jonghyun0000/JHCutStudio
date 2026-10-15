import Foundation
import CryptoKit

/// Creation-time inputs. Status is computed against the live document, never stored as a stale flag.
public struct TranslationRevision: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sourceCaptionID: UUID
    public var sourceDigest: String
    public var recipeDigest: String
    public init(sourceCaptionID: UUID, sourceDigest: String, recipeDigest: String) {
        self.sourceCaptionID = sourceCaptionID; self.sourceDigest = sourceDigest; self.recipeDigest = recipeDigest
    }
    public var isValid: Bool {
        version == 1 && [sourceDigest, recipeDigest].allSatisfy { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    }
}

public enum TranslationFreshness: String, Sendable {
    case current, sourceChanged, settingsChanged, manualKept, sourceMissing, reviewRequired, legacy, failed
    public var label: String {
        switch self {
        case .current: return "최신 번역"
        case .sourceChanged: return "원문 변경 · 갱신 필요"
        case .settingsChanged: return "번역 설정 변경 · 갱신 필요"
        case .manualKept: return "직접 고친 번역 · 자동 갱신에서 보존"
        case .sourceMissing: return "원문 연결 없음 · 확인 필요"
        case .reviewRequired: return "원문 언어 확인 필요"
        case .legacy: return "이전 번역 · 생성 설정 확인 불가"
        case .failed: return "갱신 실패 · 기존 번역 보존"
        }
    }
}

public enum CaptionTranslationTracking {
    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try! encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sourceDigest(_ clip: Clip, language: String) -> String {
        // Timeline moves do not change words; source interval/length changes do require a refresh.
        struct Input: Encodable { let text, language: String; let review: Bool; let duration: MediaTime; let sourceStart, sourceDuration: MediaTime? }
        return digest(Input(text: clip.title?.text ?? "", language: language, review: clip.captionMetadata?.languageNeedsReview == true && clip.captionMetadata?.languageManual != true,
                            duration: clip.duration, sourceStart: clip.connection?.sourceStart, sourceDuration: clip.connection?.sourceDuration))
    }
    public static func recipeDigest(source: String, target: String, glossary: [GlossaryEntry], style: TranslationStyle, bilingual: Bool) -> String {
        struct Term: Encodable { let source, target: String; let sourceLanguage, targetLanguage: String?; let caseSensitive, protected: Bool }
        struct Recipe: Encodable { let version: Int; let source, target, style: String; let bilingual: Bool; let terms: [Term] }
        // IDs are document identity, not translation behavior. Entry order matters for overlapping terms.
        let terms = glossary.filter { $0.applies(from: source, to: target) }.map { Term(source: $0.source, target: $0.target, sourceLanguage: $0.sourceLanguage, targetLanguage: $0.targetLanguage, caseSensitive: $0.caseSensitive, protected: $0.protected) }
        return digest(Recipe(version: 1, source: source, target: target, style: style.rawValue, bilingual: bilingual, terms: terms))
    }
    public static func revision(for clip: Clip, language: String, recipe: String) -> TranslationRevision {
        TranslationRevision(sourceCaptionID: clip.id, sourceDigest: sourceDigest(clip, language: language), recipeDigest: recipe)
    }
    public static func isManual(_ clip: Clip) -> Bool {
        guard let metadata = clip.captionMetadata, metadata.translatedFrom != nil else { return false }
        return clip.title?.text != metadata.generatedText
    }
    public static func source(for translated: Clip, in sequence: Sequence) -> Clip? {
        let originals = CaptionQuery.entries(in: sequence, role: .original).map(\.clip)
        if let id = translated.captionMetadata?.translationRevision?.sourceCaptionID {
            return originals.first { $0.id == id }
        }
        // Legacy lineage links are accepted only when the overlapping interval identifies one cue.
        let matches = originals.filter { CaptionQuery.related(translated, to: $0) }
        if let exact = matches.first(where: { $0.id == translated.captionMetadata?.translatedFrom }) { return exact }
        return matches.count == 1 ? matches.first : nil
    }
    public static func automaticState(of translated: Clip, source: Clip?, language: String?, recipe: String?, allowUncertainLanguage: Bool = false) -> TranslationFreshness {
        guard let source, let metadata = translated.captionMetadata else { return .sourceMissing }
        if !allowUncertainLanguage && source.captionMetadata?.languageNeedsReview == true && source.captionMetadata?.languageManual != true && language == source.captionMetadata?.language { return .reviewRequired }
        guard let language else { return .reviewRequired }
        guard let revision = metadata.translationRevision else {
            return metadata.originalText != source.title?.text || metadata.originalLanguage != language ? .sourceChanged : .legacy
        }
        guard revision.sourceCaptionID == source.id, revision.sourceDigest == sourceDigest(source, language: language), translated.start == source.start, translated.duration == source.duration else { return .sourceChanged }
        if let recipe, revision.recipeDigest != recipe { return .settingsChanged }
        if metadata.glossaryFailed?.isEmpty == false { return .failed }
        return .current
    }
    public static func state(of translated: Clip, source: Clip?, language: String?, recipe: String?) -> TranslationFreshness {
        isManual(translated) ? .manualKept : automaticState(of: translated, source: source, language: language, recipe: recipe)
    }
    /// Parent splits create new IDs on both caption tracks. Rebind only a unique matching piece of
    /// the known source family, never an unrelated cue with the same parent and time.
    public static func reconcile(before: Sequence, after: inout Sequence) throws {
        let old = Dictionary(uniqueKeysWithValues: before.tracks.flatMap(\.clips).map { ($0.id, $0) })
        let originals = CaptionQuery.entries(in: after, role: .original).map(\.clip)
        let oldOriginals = CaptionQuery.entries(in: before, role: .original).map(\.clip)
        for ti in after.tracks.indices {
            for ci in after.tracks[ti].clips.indices {
                let clip = after.tracks[ti].clips[ci]
                guard CaptionQuery.role(of: clip) == .translation, let from = clip.captionMetadata?.translatedFrom else { continue }
                let id = clip.captionMetadata?.translationRevision?.sourceCaptionID ?? from
                let fallback = oldOriginals.filter { $0.lineageID == id }
                guard let prior = old[id].flatMap({ CaptionQuery.role(of: $0) == .original ? $0 : nil }) ?? (fallback.count == 1 ? fallback.first : nil) else { continue }
                let family = prior.lineageID ?? prior.id
                let matches = originals.filter { candidate in
                    (candidate.id == prior.id || candidate.lineageID == family) && candidate.start == clip.start && candidate.duration == clip.duration && candidate.connection?.parentID == clip.connection?.parentID
                }
                guard matches.count == 1, let source = matches.first, source.id != id else { continue }
                guard !after.tracks[ti].isLocked else { throw ProjectError("번역의 원문 연결을 갱신하려면 해당 트랙의 잠금을 해제하세요.") }
                after.tracks[ti].clips[ci].captionMetadata?.translatedFrom = source.id
                after.tracks[ti].clips[ci].captionMetadata?.translationRevision?.sourceCaptionID = source.id
                // Leave creation-time digests untouched: splitting is observable as sourceChanged.
            }
        }
    }
}

/// Boundaries reflect provider capabilities: separate requests with IDs in contiguous local batches.
/// Apple does not expose a context prompt or guarantee cross-sentence semantic understanding.
public enum CaptionTranslationBatching {
    public static func batches(_ clips: [Clip], maxCount: Int = 32, maxCharacters: Int = 20_000) -> [[Clip]] {
        var result: [[Clip]] = []
        for clip in clips {
            if let last = result.last?.last, let batch = result.last,
               last.captionGroupID == clip.captionGroupID, last.captionMetadata?.speaker == clip.captionMetadata?.speaker,
               last.captionMetadata?.language == clip.captionMetadata?.language,
               clip.start >= last.start, clip.start.seconds - last.end.seconds <= 10,
               batch.count < max(1, maxCount), batch.reduce(0, { $0 + ($1.title?.text.count ?? 0) }) + (clip.title?.text.count ?? 0) <= maxCharacters {
                result[result.count - 1].append(clip)
            } else { result.append([clip]) }
        }
        return result
    }
}

public struct CaptionTranslationRequest: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}
public struct CaptionTranslationResponse: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}
public enum CaptionTranslationResponses {
    public static func ordered(_ responses: [CaptionTranslationResponse], for requests: [CaptionTranslationRequest]) throws -> [String] {
        let ids = Set(requests.map(\.id))
        guard ids.count == requests.count, responses.count == requests.count else { throw ProjectError("번역 결과 개수가 원문과 다릅니다. 원문과 기존 번역은 유지됩니다.") }
        var mapped: [UUID: String] = [:]
        for response in responses {
            guard ids.contains(response.id), mapped[response.id] == nil, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.text.count <= 20_000 else { throw ProjectError("번역 문장 ID·내용이 올바르지 않습니다. 원문과 기존 번역은 유지됩니다.") }
            mapped[response.id] = response.text
        }
        return try requests.map { request in
            guard let text = mapped[request.id] else { throw ProjectError("일부 자막 번역이 빠졌습니다. 기존 문서는 유지됩니다.") }; return text
        }
    }
}

import Foundation

public enum CaptionLanguage: String, CaseIterable, Codable, Sendable {
    case ko, ja, en
    public var label: String { switch self { case .ko: return "한국어"; case .ja: return "일본어"; case .en: return "영어" } }
}

/// Translation is a separate editable clip. The original text remains available even if its track is hidden.
public struct CaptionMetadata: Codable, Equatable, Sendable {
    public var language: String
    public var originalLanguage: String
    public var originalText: String
    public var translatedFrom: UUID?
    public var generatedText: String
    /// Dominant language Whisper reported for the whole source clip; `language` is this sentence's.
    public var clipLanguage: String?
    /// 0…1 evidence for `language`. nil when set by hand or imported without detection.
    public var languageConfidence: Double?
    /// The user chose this sentence's language; detection and re-recognition must not replace it.
    public var languageManual: Bool?
    /// Detection fell back to the clip language because the sentence was too short or ambiguous.
    public var languageNeedsReview: Bool?
    /// "A", "B", … from channel separation, or nil. Never assigned by guesswork.
    public var speaker: String?
    /// "separated" when assigned, "uncertain" when analysed but not clearly separated.
    public var speakerStatus: String?
    /// Translation register requested for this clip ("natural", "polite", "formal", "casual").
    public var translationStyle: String?
    /// Whether the register conversion actually changed/confirmed the sentence ending.
    public var styleApplied: Bool?
    /// Glossary terms applied to this translation, and terms whose protection marker was lost.
    public var glossaryApplied: [String]?
    public var glossaryFailed: [String]?
    public init(language: String, originalLanguage: String, originalText: String, translatedFrom: UUID? = nil, generatedText: String) {
        self.language = language; self.originalLanguage = originalLanguage; self.originalText = originalText
        self.translatedFrom = translatedFrom; self.generatedText = generatedText
    }
}

public enum CaptionTranslationEditing {
    public static func translated(_ original: Clip, text: String, sourceLanguage: String, targetLanguage: String, bilingual: Bool) throws -> Clip {
        guard let title = original.title, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CaptionLanguage(rawValue: sourceLanguage) != nil, CaptionLanguage(rawValue: targetLanguage) != nil else { throw ProjectError("번역할 원문과 지원 언어를 선택하세요.") }
        var clip = original; clip.id = UUID(); clip.lineageID = nil
        let rendered = bilingual && sourceLanguage != targetLanguage ? title.text + "\n" + text : text
        clip.title?.text = rendered; clip.name = "\(CaptionLanguage(rawValue: targetLanguage)!.label) 번역"
        if bilingual, var style = clip.title?.style { style.maxLines = max(4, style.maxLines); clip.title?.style = style }
        clip.connection?.generatedText = rendered
        var metadata = CaptionMetadata(language: targetLanguage, originalLanguage: sourceLanguage, originalText: title.text, translatedFrom: original.id, generatedText: rendered)
        // A translation speaks for the same person as its original.
        metadata.speaker = original.captionMetadata?.speaker; metadata.speakerStatus = original.captionMetadata?.speakerStatus
        clip.captionMetadata = metadata
        return clip
    }
    public static func isTranslation(of original: Clip, _ candidate: Clip, target: String) -> Bool {
        guard let metadata = candidate.captionMetadata, metadata.translatedFrom != nil, metadata.language == target else { return false }
        if let source = original.connection, let other = candidate.connection {
            return source.parentID == other.parentID && source.sourceStart == other.sourceStart && source.sourceDuration == other.sourceDuration
        }
        return metadata.translatedFrom == original.id
    }
}

/// Display name and caption colour for one speaker label. Stored on the sequence so every caption
/// of that speaker can be restyled together.
public struct SpeakerProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var colorHex: String
    public init(id: String, name: String, colorHex: String) { self.id = id; self.name = name; self.colorHex = colorHex }
    public static let defaultColors = ["FFFFFF", "FFE55B", "7FD8FF", "FF9E7A", "B8F28C", "E3A8FF", "FFB3D1", "C7C7C7"]
}

/// One glossary rule. An empty `target`, or `protected`, keeps the source form untranslated
/// (names, brands, product names). Language fields nil = any language.
public struct GlossaryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: String
    public var target: String
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var caseSensitive: Bool
    public var protected: Bool
    public init(id: UUID = UUID(), source: String, target: String = "", sourceLanguage: String? = nil, targetLanguage: String? = nil, caseSensitive: Bool = false, protected: Bool = false) {
        self.id = id; self.source = source; self.target = target; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.caseSensitive = caseSensitive; self.protected = protected
    }
    public var keepsSource: Bool { protected || target.trimmingCharacters(in: .whitespaces).isEmpty }
    public func applies(from source: String, to target: String) -> Bool {
        (sourceLanguage == nil || sourceLanguage == source) && (targetLanguage == nil || targetLanguage == target)
    }
}

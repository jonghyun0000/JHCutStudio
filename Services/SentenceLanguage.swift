import Foundation
import NaturalLanguage

/// Per-sentence language for Korean / Japanese / English captions.
///
/// Hangul, kana and Latin letters are disjoint scripts, so their shares are strong evidence; the
/// NaturalLanguage recogniser (constrained to the three languages) decides the rest. Text that is
/// too short or ambiguous keeps the clip's language and is marked for review instead of guessed.
public struct SentenceLanguageResult: Equatable, Sendable {
    public var language: String
    public var confidence: Double
    /// True when the sentence did not carry enough evidence and fell back to the clip language.
    public var needsReview: Bool
    public var method: String
}

public enum SentenceLanguage {
    /// Below this, the detected language is not trusted over the clip language.
    public static let minimumConfidence = 0.6
    /// Fewer letters than this cannot be told apart reliably (e.g. “OK”, “네”).
    public static let minimumLetters = 4

    public struct ScriptCounts: Equatable, Sendable { public var hangul = 0, kana = 0, han = 0, latin = 0; public var letters: Int { hangul + kana + han + latin } }

    public static func scripts(_ text: String) -> ScriptCounts {
        var c = ScriptCounts()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: c.hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: c.kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: c.han += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: c.latin += 1
            default: break
            }
        }
        return c
    }

    public static func detect(_ text: String, clipLanguage: String) -> SentenceLanguageResult {
        let fallback = CaptionLanguage(rawValue: clipLanguage) != nil ? clipLanguage : "ko"
        let c = scripts(text)
        guard c.letters >= minimumLetters else {
            return SentenceLanguageResult(language: fallback, confidence: 0, needsReview: true, method: "짧은 문장 · 클립 언어 사용")
        }
        let letters = Double(c.letters)
        // Script evidence first: these three writing systems do not overlap.
        if Double(c.hangul) / letters >= 0.5 { return SentenceLanguageResult(language: "ko", confidence: Double(c.hangul) / letters, needsReview: false, method: "문자 체계(한글)") }
        if c.kana > 0 && Double(c.kana + c.han) / letters >= 0.5 { return SentenceLanguageResult(language: "ja", confidence: Double(c.kana + c.han) / letters, needsReview: false, method: "문자 체계(가나)") }
        if Double(c.latin) / letters >= 0.8 && c.hangul == 0 && c.kana == 0 {
            // Latin text could still be romanised Korean/Japanese; let the recogniser weigh in.
            let p = probabilities(text)["en"] ?? 0
            let confidence = max(p, 0.0)
            if confidence >= minimumConfidence { return SentenceLanguageResult(language: "en", confidence: confidence, needsReview: false, method: "문자 체계(라틴)·언어 모델") }
            return SentenceLanguageResult(language: fallback, confidence: confidence, needsReview: true, method: "라틴 문자지만 영어 확률 낮음 · 클립 언어 사용")
        }
        // Mixed or Han-only text: Han alone is shared by Japanese and (rarely) Korean.
        let p = probabilities(text)
        if let best = p.max(by: { $0.value < $1.value }), best.value >= minimumConfidence, !(c.kana == 0 && c.hangul == 0 && c.han > 0) {
            return SentenceLanguageResult(language: best.key, confidence: best.value, needsReview: false, method: "언어 모델")
        }
        return SentenceLanguageResult(language: fallback, confidence: p[fallback] ?? 0, needsReview: true, method: "근거 부족 · 클립 언어 사용")
    }

    static func probabilities(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.korean, .japanese, .english]
        recognizer.processString(text)
        var result: [String: Double] = [:]
        for (language, value) in recognizer.languageHypotheses(withMaximum: 3) where CaptionLanguage(rawValue: language.rawValue) != nil { result[language.rawValue] = value }
        return result
    }
}

import Foundation

// MARK: - Glossary protection

/// A glossary term hidden behind a marker while the sentence goes through the translator.
public struct ProtectedTerm: Equatable, Sendable {
    public var index: Int
    public var source: String
    /// What replaces the marker after translation (the target term, or the original for protected names).
    public var replacement: String
    public init(index: Int, source: String, replacement: String) { self.index = index; self.source = source; self.replacement = replacement }
}

public struct ProtectedText: Equatable, Sendable {
    public var text: String
    public var terms: [ProtectedTerm]
    public init(text: String, terms: [ProtectedTerm]) { self.text = text; self.terms = terms }
    /// True when nothing but markers and punctuation is left, so the translator is not needed.
    public var isOnlyTerms: Bool {
        GlossaryProtection.stripMarkers(text).unicodeScalars.allSatisfy { !CharacterSet.letters.contains($0) }
    }
}

public struct RestoredText: Equatable, Sendable {
    public var text: String
    public var applied: [String]
    /// Terms whose marker the translator dropped or damaged. Their sentence needs another path.
    public var failed: [String]
}

/// Replaces glossary terms with markers before translation and puts the chosen words back afterwards.
///
/// The marker `ZQX<n>` was chosen after measuring the installed Apple translator in all six
/// ko/ja/en directions: it survived unchanged in every direction (see docs/UPGRADE-0.7-WORKLOG.md).
/// Restoration still verifies every marker and reports the ones that were lost instead of assuming.
public enum GlossaryProtection {
    public static let markerPrefix = "ZQX"
    private static let markerPattern = try! NSRegularExpression(pattern: "[Zz]\\s?[Qq]\\s?[Xx]\\s?-?\\s?([0-9]+)")

    public static func stripMarkers(_ text: String) -> String {
        markerPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    public static func applicable(_ entries: [GlossaryEntry], from source: String, to target: String) -> [GlossaryEntry] {
        entries.filter { !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.applies(from: source, to: target) }
            .sorted { $0.source.count > $1.source.count }
    }

    private static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.isLetter && c.unicodeScalars.allSatisfy { $0.isASCII } || c.isNumber
    }

    public static func protect(_ text: String, entries: [GlossaryEntry], from source: String, to target: String) -> ProtectedText {
        var result = text, terms: [ProtectedTerm] = []
        for entry in applicable(entries, from: source, to: target) {
            let needle = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            // Latin terms need word boundaries ("Mac" must not hit "Machine"); CJK terms attach to particles.
            let latin = needle.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result.range(of: needle, options: entry.caseSensitive ? [] : [.caseInsensitive], range: searchStart..<result.endIndex) {
                let before = range.lowerBound > result.startIndex ? result[result.index(before: range.lowerBound)] : nil
                let after = range.upperBound < result.endIndex ? result[range.upperBound] : nil
                if latin && (isWordCharacter(before) || isWordCharacter(after)) { searchStart = range.upperBound; continue }
                let original = String(result[range])
                let index = terms.count + 1
                terms.append(ProtectedTerm(index: index, source: entry.source, replacement: entry.keepsSource ? original : entry.target))
                let marker = markerPrefix + String(index)
                // A marker glued to Latin letters would merge into one word; CJK neighbours are fine.
                let padded = (isWordCharacter(before) ? " " : "") + marker + (isWordCharacter(after) ? " " : "")
                result.replaceSubrange(range, with: padded)
                searchStart = result.index(range.lowerBound, offsetBy: padded.count)
            }
        }
        return ProtectedText(text: result, terms: terms)
    }

    public static func restore(_ translated: String, _ protected: ProtectedText, targetLanguage: String) -> RestoredText {
        let byIndex = Dictionary(protected.terms.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let ns = translated as NSString
        var output = "", cursor = 0, found = Set<Int>(), pendingParticle: String?
        for match in markerPattern.matches(in: translated, range: NSRange(location: 0, length: ns.length)) {
            var before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let term = pendingParticle { before = fixKoreanParticle(after: term, in: before); pendingParticle = nil }
            output += before
            let index = Int(ns.substring(with: match.range(at: 1))) ?? -1
            if let term = byIndex[index] {
                output += term.replacement; found.insert(index)
                if targetLanguage == "ko" { pendingParticle = term.replacement }
            }
            cursor = match.range.location + match.range.length
        }
        var tail = ns.substring(from: cursor)
        if let term = pendingParticle { tail = fixKoreanParticle(after: term, in: tail) }
        output += tail
        var applied: [String] = [], failed: [String] = []
        for term in protected.terms {
            if found.contains(term.index) { if !applied.contains(term.source) { applied.append(term.source) } }
            else if !failed.contains(term.source) { failed.append(term.source) }
        }
        return RestoredText(text: output, applied: applied, failed: failed)
    }

    /// Korean particles depend on the last sound of the word before them (민수를 / 지민을).
    /// Only a particle that ends a word right after the restored term is corrected.
    static func fixKoreanParticle(after term: String, in following: String) -> String {
        guard let last = term.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return following }
        let final = Int(last.value - 0xAC00) % 28
        let pairs: [(withFinal: String, without: String)] = [("으로", "로"), ("이나", "나"), ("을", "를"), ("이", "가"), ("은", "는"), ("과", "와")]
        for pair in pairs {
            for candidate in [pair.withFinal, pair.without] where following.hasPrefix(candidate) {
                let rest = following.dropFirst(candidate.count)
                if let next = rest.first, next.isLetter { continue }
                let wanted: String
                if pair.withFinal == "으로" { wanted = final == 0 || final == 8 ? "로" : "으로" }
                else { wanted = final == 0 ? pair.without : pair.withFinal }
                return wanted + rest
            }
        }
        return following
    }
}

// MARK: - Translation register

/// Register requested for translated captions. Conversion is rule-based on sentence endings only;
/// sentences whose ending is not covered by a safe rule are left as the translator produced them
/// and reported, never rewritten by guesswork.
public enum TranslationStyle: String, CaseIterable, Codable, Sendable {
    case natural, polite, formal, casual
    public var label: String {
        switch self { case .natural: return "자연스러운"; case .polite: return "존댓말"; case .formal: return "방송체"; case .casual: return "반말" }
    }
}

public struct StyleConversion: Equatable, Sendable {
    public var text: String
    /// nil when the style does not apply (natural, English, or no sentence with a recognisable ending).
    public var applied: Bool?
    public var converted: Int
    public var alreadyMatching: Int
    public var unsupported: Int
}

public enum TranslationStyleConverter {
    // Hangul syllable helpers
    private static func parts(_ c: Character) -> (lead: Int, vowel: Int, final: Int)? {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1, (0xAC00...0xD7A3).contains(s.value) else { return nil }
        let v = Int(s.value - 0xAC00); return (v / 588, (v % 588) / 28, v % 28)
    }
    private static func syllable(_ lead: Int, _ vowel: Int, _ final: Int) -> Character {
        Character(UnicodeScalar(UInt32(0xAC00 + lead * 588 + vowel * 28 + final))!)
    }

    /// Korean sentence register: formal (합쇼체), polite (해요체), casual (반말) or nil (no Hangul ending).
    public static func koreanRegister(_ sentence: String) -> TranslationStyle? {
        let core = trimmedEnding(sentence).core
        guard let last = core.last, parts(last) != nil else { return nil }
        if core.hasSuffix("니다") || core.hasSuffix("니까") || core.hasSuffix("시오") { return .formal }
        if core.hasSuffix("요") || core.hasSuffix("죠") { return .polite }
        return .casual
    }

    public static func japaneseRegister(_ sentence: String) -> TranslationStyle? {
        var core = trimmedEnding(sentence).core
        while let last = core.last, "ねよか".contains(last) { core.removeLast() }
        guard let last = core.last, last.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        for ending in ["です", "ます", "ました", "ません", "でした", "ましょう", "ください", "でしょう"] where core.hasSuffix(ending) { return .polite }
        return .casual
    }

    /// Splits trailing punctuation/quotes/spaces off a sentence.
    private static func trimmedEnding(_ sentence: String) -> (core: String, tail: String) {
        var core = sentence, tail = ""
        while let last = core.last, !(last.isLetter || last.isNumber) { tail.insert(last, at: tail.startIndex); core.removeLast() }
        return (core, tail)
    }

    /// Sentences with their terminal punctuation kept attached.
    public static func sentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        for c in text {
            current.append(c)
            if ".?!。？！\n".contains(c) { result.append(current); current = "" }
            else if c == " " || c == "　", let prev = current.dropLast().last, ".?!。？！".contains(prev) { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func apply(_ style: TranslationStyle, to text: String, language: String) -> StyleConversion {
        guard style != .natural, language == "ko" || language == "ja" else {
            return StyleConversion(text: text, applied: nil, converted: 0, alreadyMatching: 0, unsupported: 0)
        }
        // Japanese has one polite register: 방송체 and 존댓말 both mean です・ます.
        let wanted: TranslationStyle = language == "ja" && style == .formal ? .polite : style
        var out = "", converted = 0, matching = 0, unsupported = 0
        for sentence in sentences(text) {
            let register = language == "ko" ? koreanRegister(sentence) : japaneseRegister(sentence)
            guard let register else { out += sentence; continue }
            if register == wanted { matching += 1; out += sentence; continue }
            let (core, tail) = trimmedEnding(sentence)
            let candidate = language == "ko" ? convertKorean(core, from: register, to: wanted) : convertJapanese(core, from: register, to: wanted)
            if let candidate, (language == "ko" ? koreanRegister(candidate + tail) : japaneseRegister(candidate + tail)) == wanted {
                converted += 1; out += candidate + tail
            } else { unsupported += 1; out += sentence }
        }
        let counted = converted + matching + unsupported
        return StyleConversion(text: out, applied: counted == 0 ? nil : unsupported == 0, converted: converted, alreadyMatching: matching, unsupported: unsupported)
    }

    // MARK: Korean

    static func convertKorean(_ core: String, from: TranslationStyle, to: TranslationStyle) -> String? {
        switch (from, to) {
        case (.formal, .polite): return formalToPolite(core)
        case (.polite, .formal): return politeToFormal(core)
        case (.polite, .casual): return politeToCasual(core)
        case (.casual, .polite): return casualToPolite(core)
        case (.formal, .casual): return formalToPolite(core).flatMap(politeToCasual)
        case (.casual, .formal): return casualToPolite(core).flatMap(politeToFormal)
        default: return nil
        }
    }

    /// ㄹ-stem verbs lose their ㄹ before ㅂ니다, so the stem cannot be recovered by rule.
    private static let formalExceptions: [(String, String)] = [
        ("것입니다", "거예요"), ("겁니다", "거예요"), ("압니다", "알아요"), ("삽니다", "살아요"), ("팝니다", "팔아요"), ("놉니다", "놀아요"),
        ("만듭니다", "만들어요"), ("엽니다", "열어요"), ("깁니다", "길어요"), ("멉니다", "멀어요"), ("겁니까", "거예요"),
    ]

    static func formalToPolite(_ core: String) -> String? {
        for (formal, polite) in formalExceptions where core.hasSuffix(formal) { return String(core.dropLast(formal.count)) + polite }
        guard core.hasSuffix("니다") || core.hasSuffix("니까") else { return nil }
        var body = Array(core.dropLast(2))
        guard let last = body.last else { return nil }
        if last == "습" {
            body.removeLast()
            guard let stem = body.last, let p = parts(stem) else { return nil }
            switch p.final {
            case 20, 18: return String(body) + "어요" // 했/있/갔 · 없
            case 17, 7, 19: return nil // ㅂ·ㄷ·ㅅ irregular stems
            case 27 where !["좋", "놓", "넣", "낳"].contains(stem): return nil
            default: return String(body) + (p.vowel == 0 || p.vowel == 8 ? "아요" : "어요")
            }
        }
        guard let p = parts(last), p.final == 17 else { return nil }
        body.removeLast()
        let open = syllable(p.lead, p.vowel, 0)
        switch open {
        case "하": return String(body) + "해요"
        case "되": return String(body) + "돼요"
        case "시": return String(body) + "세요"
        case "이":
            let prev = body.last.flatMap(parts)
            return String(body) + (prev.map { $0.final != 0 } ?? true ? "이에요" : "예요")
        default: break
        }
        switch p.vowel {
        case 0, 4, 1, 5, 6: return String(body) + String(open) + "요" // 가요 서요 내요 세요 켜요
        case 8: return String(body) + String(syllable(p.lead, 9, 0)) + "요" // 봐요 와요
        case 13: return String(body) + String(syllable(p.lead, 14, 0)) + "요" // 줘요 둬요
        case 20: return String(body) + String(syllable(p.lead, 6, 0)) + "요" // 가져요 기다려요
        default: return nil
        }
    }

    static func politeToFormal(_ core: String) -> String? {
        let specials: [(String, String)] = [("거예요", "겁니다"), ("이에요", "입니다"), ("해요", "합니다"), ("돼요", "됩니다")]
        for (polite, formal) in specials where core.hasSuffix(polite) { return String(core.dropLast(polite.count)) + formal }
        if core.hasSuffix("예요") { return String(core.dropLast(2)) + "입니다" }
        guard core.hasSuffix("요"), !core.hasSuffix("세요"), !core.hasSuffix("네요"), !core.hasSuffix("군요"), !core.hasSuffix("지요") else { return nil }
        var body = Array(core.dropLast())
        guard let last = body.last, let p = parts(last) else { return nil }
        if (last == "어" || last == "아"), body.count >= 2, let stem = parts(body[body.count - 2]), stem.final != 0 {
            body.removeLast(); return String(body) + "습니다" // 먹어요 → 먹습니다, 있어요 → 있습니다
        }
        guard p.final == 0 else { return nil }
        body.removeLast()
        switch p.vowel {
        case 0, 4, 1, 5: return String(body) + String(syllable(p.lead, p.vowel, 17)) + "니다" // 가요 → 갑니다
        case 9: return String(body) + String(syllable(p.lead, 8, 17)) + "니다" // 봐요 → 봅니다
        case 14: return String(body) + String(syllable(p.lead, 13, 17)) + "니다" // 줘요 → 줍니다
        default: return nil
        }
    }

    static func politeToCasual(_ core: String) -> String? {
        let specials: [(String, String)] = [("거예요", "거야"), ("이에요", "이야"), ("예요", "야"), ("죠", "지")]
        for (polite, casual) in specials where core.hasSuffix(polite) { return String(core.dropLast(polite.count)) + casual }
        guard core.hasSuffix("요"), !core.hasSuffix("세요") else { return nil }
        let body = String(core.dropLast())
        guard let last = body.last, parts(last) != nil else { return nil }
        return body
    }

    static func casualToPolite(_ core: String) -> String? {
        let specials: [(String, String)] = [("거야", "거예요"), ("이야", "이에요"), ("이다", "이에요")]
        for (casual, polite) in specials where core.hasSuffix(casual) { return String(core.dropLast(casual.count)) + polite }
        guard let last = core.last, let p = parts(last) else { return nil }
        if last == "야", let prev = core.dropLast().last, let q = parts(prev), q.final == 0 { return String(core.dropLast()) + "예요" }
        if last == "지" { return String(core.dropLast()) + "죠" }
        if last == "다" {
            // 했다/있다/없다 → 했어요/있어요/없어요; other plain forms (간다, 먹는다) are not safe to rewrite.
            guard let stem = core.dropLast().last, let q = parts(stem), q.final == 20 || q.final == 18 else { return nil }
            return String(core.dropLast()) + "어요"
        }
        // Informal 해체 endings take 요 directly.
        if ["어", "아", "해", "돼", "봐", "와", "줘", "네", "게", "래", "대"].contains(last) || (p.final == 0 && [0, 4, 1, 5, 6].contains(p.vowel) && core.count >= 2) {
            return core + "요"
        }
        return nil
    }

    // MARK: Japanese

    static func convertJapanese(_ core: String, from: TranslationStyle, to: TranslationStyle) -> String? {
        var body = core, particle = ""
        while let last = body.last, "ねよ".contains(last) { particle.insert(last, at: particle.startIndex); body.removeLast() }
        if body.hasSuffix("か") { return nil } // questions change shape between registers
        let table: [(String, String)]
        if from == .polite && to == .casual {
            table = [("ではありませんでした", "ではなかった"), ("ではありません", "ではない"), ("ていました", "ていた"), ("ています", "ている"),
                     ("でした", "だった"), ("でしょう", "だろう"), ("いです", "い"), ("です", "だ")]
        } else if from == .casual && to == .polite {
            table = [("ではなかった", "ではありませんでした"), ("ではない", "ではありません"), ("ていた", "ていました"), ("ている", "ています"),
                     ("だった", "でした"), ("だろう", "でしょう"), ("だ", "です"), ("い", "いです")]
        } else { return nil }
        for (a, b) in table where body.hasSuffix(a) { return String(body.dropLast(a.count)) + b + particle }
        return nil
    }
}

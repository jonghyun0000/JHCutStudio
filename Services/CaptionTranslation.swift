import Foundation
import Translation
import NaturalLanguage

public enum CaptionTranslation {
    private static func missingLanguages(source: String, target: String, unsupported: Bool = false) -> ProjectError {
        let direction = (CaptionLanguage(rawValue: source)?.label ?? source) + " → " + (CaptionLanguage(rawValue: target)?.label ?? target)
        if unsupported { return ProjectError(direction + " 번역은 이 Mac의 Apple 번역에서 지원하지 않습니다. 원문과 기존 번역을 보존합니다.") }
        return ProjectError(direction + "에 사용할 Apple 번역 언어팩이 없습니다. 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서 설치한 뒤 다시 번역하세요. 원문과 기존 번역은 보존됩니다.")
    }
    public static func detectTextLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        guard let language = recognizer.dominantLanguage?.rawValue, CaptionLanguage(rawValue: language) != nil else { return nil }
        return language
    }
    /// Installed ko/ja/en pairs ("한국어→영어"), or nil when on-device translation is unavailable
    /// on this system. Read-only: never triggers a download.
    public static func installedPairs() async -> [String]? {
        guard #available(macOS 26.0, *) else { return nil }
        var pairs: [String] = []
        for source in CaptionLanguage.allCases {
            for target in CaptionLanguage.allCases where target != source {
                let from = Locale.Language(identifier: source.rawValue), to = Locale.Language(identifier: target.rawValue)
                // Same strategies translate() uses. Measured: on macOS 26.4+ the default strategy
                // reported every pair as only “supported” while the high-fidelity models were installed.
                var installed = false
                if #available(macOS 26.4, *) {
                    installed = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: from, to: to) == .installed
                    if !installed { installed = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: from, to: to) == .installed }
                } else { installed = await LanguageAvailability().status(from: from, to: to) == .installed }
                if installed { pairs.append("\(source.label)→\(target.label)") }
            }
        }
        return pairs
    }
    /// Installed languages only: no implicit downloads and no third-party text upload.
    @MainActor public static func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        let requests = texts.map { CaptionTranslationRequest(id: UUID(), text: $0) }
        return try CaptionTranslationResponses.ordered(await translateIdentified(requests, from: source, to: target), for: requests)
    }
    @MainActor public static func translateIdentified(_ input: [CaptionTranslationRequest], from source: String, to target: String) async throws -> [CaptionTranslationResponse] {
        let texts = input.map(\.text)
        guard Set(input.map(\.id)).count == input.count else { throw ProjectError("번역 요청 문장 ID가 중복되었습니다.") }
        guard CaptionLanguage(rawValue: source) != nil, CaptionLanguage(rawValue: target) != nil else { throw ProjectError("한국어·일본어·영어 사이의 번역을 선택하세요.") }
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 10_000 }) else { throw ProjectError("번역할 자막은 비어 있지 않은 10,000자 이내 문장이어야 합니다.") }
        if source == target { return input.map { CaptionTranslationResponse(id: $0.id, text: $0.text) } }
        guard #available(macOS 26.0, *) else { throw ProjectError("이 앱의 기기 내 자막 번역은 macOS 26 이상이 필요합니다. 원문 자동 자막은 계속 사용할 수 있습니다.") }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            // Availability and execution must use the same strategy. The system default
            // varies with deployment target and may miss an installed high-fidelity model.
            let high = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: from, to: to)
            let low = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: from, to: to)
            if high == .installed {
                session = TranslationSession(installedSource: from, target: to, preferredStrategy: .highFidelity)
            } else if low == .installed {
                session = TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
            } else { throw missingLanguages(source: source, target: target, unsupported: high == .unsupported && low == .unsupported) }
        } else {
            let status = await LanguageAvailability().status(from: from, to: to)
            guard status == .installed else { throw missingLanguages(source: source, target: target, unsupported: status == .unsupported) }
            session = TranslationSession(installedSource: from, target: to)
        }
        return try await withTaskCancellationHandler(operation: {
            var result: [CaptionTranslationResponse] = []
            for offset in stride(from: 0, to: texts.count, by: 32) {
                try Task.checkCancellation()
                let end = min(texts.count, offset + 32)
                let requests = (offset..<end).map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: input[$0].id.uuidString) }
                let responses = try await session.translations(from: requests)
                let mapped = try responses.map { response -> CaptionTranslationResponse in
                    guard let raw = response.clientIdentifier, let id = UUID(uuidString: raw) else { throw ProjectError("번역 응답의 문장 ID가 없습니다. 기존 문서는 유지됩니다.") }
                    return CaptionTranslationResponse(id: id, text: response.targetText)
                }
                let batch = Array(input[offset..<end])
                let ordered = try CaptionTranslationResponses.ordered(mapped, for: batch)
                result += zip(batch, ordered).map { CaptionTranslationResponse(id: $0.0.id, text: $0.1) }
            }
            try Task.checkCancellation(); return result
        }, onCancel: { session.cancel() })
    }
}

import Foundation
import Translation
import NaturalLanguage

public enum CaptionTranslation {
    private static func missingLanguages() -> ProjectError {
        ProjectError("이 언어 조합에 사용할 Apple 번역 언어팩이 없습니다. 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서 설치한 뒤 다시 번역하세요. 원문 자막은 보존됩니다.")
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
        guard CaptionLanguage(rawValue: source) != nil, CaptionLanguage(rawValue: target) != nil else { throw ProjectError("한국어·일본어·영어 사이의 번역을 선택하세요.") }
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 10_000 }) else { throw ProjectError("번역할 자막은 비어 있지 않은 10,000자 이내 문장이어야 합니다.") }
        if source == target { return texts }
        guard #available(macOS 26.0, *) else { throw ProjectError("이 앱의 기기 내 자막 번역은 macOS 26 이상이 필요합니다. 원문 자동 자막은 계속 사용할 수 있습니다.") }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            // Availability and execution must use the same strategy. The system default
            // varies with deployment target and may miss an installed high-fidelity model.
            if await LanguageAvailability(preferredStrategy: .highFidelity).status(from: from, to: to) == .installed {
                session = TranslationSession(installedSource: from, target: to, preferredStrategy: .highFidelity)
            } else if await LanguageAvailability(preferredStrategy: .lowLatency).status(from: from, to: to) == .installed {
                session = TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
            } else { throw missingLanguages() }
        } else {
            guard await LanguageAvailability().status(from: from, to: to) == .installed else { throw missingLanguages() }
            session = TranslationSession(installedSource: from, target: to)
        }
        return try await withTaskCancellationHandler(operation: {
            var result: [String] = []
            for offset in stride(from: 0, to: texts.count, by: 32) {
                try Task.checkCancellation()
                let end = min(texts.count, offset + 32)
                let requests = (offset..<end).map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
                let responses = try await session.translations(from: requests)
                var mapped: [String: String] = [:]
                for response in responses {
                    guard let id = response.clientIdentifier, mapped[id] == nil, !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("번역 응답을 자막과 연결하지 못했습니다. 원문은 유지됩니다.") }
                    mapped[id] = response.targetText
                }
                guard mapped.count == requests.count else { throw ProjectError("일부 자막의 번역이 빠졌습니다. 원문은 유지됩니다.") }
                for index in offset..<end { guard let text = mapped[String(index)] else { throw ProjectError("번역 자막 순서가 올바르지 않습니다.") }; result.append(text) }
            }
            try Task.checkCancellation(); return result
        }, onCancel: { session.cancel() })
    }
}

import Foundation
import AppKit
import CryptoKit
import JHCutCore

/// Uses actual UIL10n/AppUILanguage from App/EditorModel.swift, never a copied implementation.
/// No editor construction, app launch, standard preference writes, or network requests.
@main struct UILocalizationProbe {
    // Actual UIL10n.format call sites. Ordinary percentage prose is not a format input.
    static let captionFormatKeys: Set<String> = [
        "현재 원본·설정으로 재사용 가능 · %ld/%ld구간",
        "보관된 인식 기록 %ld개 · 현재 원본·설정의 재사용 확인 전",
        "채널 %ld",
        "확인 필요 %ld개",
        "원본: %@%@",
        " · 채널 %ld",
        "선택 %ld개 · 숨긴 원문·번역 트랙은 바꾸지 않습니다",
    ]
    static func catalog(_ url: URL) throws -> [String: String] {
        guard let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: String] else { throw ProjectError("Catalog is not an OpenStep string dictionary") }
        return result
    }
    static func specifiers(_ text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[-+ #0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|h|ll|l|L|z|j|t)?[@diuoxXfFeEgGaAcCsSp%]"#)
        let value = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).map { value.substring(with: $0.range) }.filter { $0 != "%%" }
    }
    static func hashes(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for code in ["ko", "en"] { result[code] = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(code + ".lproj/Localizable.strings"))).map { String(format: "%02x", $0) }.joined() }
        return result
    }
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let output = try ProbeWorkspace.prepare(defaultPath: "Artifacts/UILocalizationProbe")
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JHCUT_UI_LOCALIZATION_RESOURCE_ROOT"] ?? "Resources/Localization", isDirectory: true).standardizedFileURL
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") { checks.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
        let suiteName = "studio.jhcut.probe.localization." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw ProjectError("Temporary defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let beforeLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        let beforeStandardSelection = UserDefaults.standard.string(forKey: UIL10n.preferenceKey)
        let beforeHashes = try hashes(source)
        check("English first preference selects English without persisting", UIL10n.language(defaults: defaults, preferred: ["en-US", "ko-KR"]) == "en" && defaults.string(forKey: UIL10n.preferenceKey) == nil)
        check("Korean first preference selects Korean", UIL10n.language(defaults: defaults, preferred: ["ko-KR", "en-US"]) == "ko")
        check("Unsupported preferred language preserves Korean fallback", UIL10n.language(defaults: defaults, preferred: ["ja-JP"]) == "ko")
        check("Empty preferred language list preserves Korean fallback", UIL10n.language(defaults: defaults, preferred: []) == "ko")
        defaults.set("en", forKey: UIL10n.preferenceKey)
        check("Saved English overrides Korean preference", UIL10n.language(defaults: defaults, preferred: ["ko-KR"]) == "en")
        defaults.set("ko", forKey: UIL10n.preferenceKey)
        check("Saved Korean overrides English preference", UIL10n.language(defaults: defaults, preferred: ["en-US"]) == "ko")
        defaults.set("invalid", forKey: UIL10n.preferenceKey)
        check("Invalid saved preference is ignored", UIL10n.language(defaults: defaults, preferred: ["en-GB"]) == "en")
        check("Observable ignores invalid persisted language on initialization", AppUILanguage(defaults: defaults, preferred: ["en-GB"]).selection == "en")
        defaults.removeObject(forKey: UIL10n.preferenceKey)
        let language = AppUILanguage(defaults: defaults, preferred: ["en-US"])
        check("Actual observable initializes English without persisting", language.selection == "en" && language.locale.identifier == "en" && defaults.string(forKey: UIL10n.preferenceKey) == nil)
        language.selection = "ko"
        check("Observable persists Korean to temporary domain", language.locale.identifier == "ko" && defaults.string(forKey: UIL10n.preferenceKey) == "ko")
        language.selection = "en"
        check("Observable persists English to temporary domain", language.locale.identifier == "en" && defaults.string(forKey: UIL10n.preferenceKey) == "en")
        language.selection = "xx"
        check("Observable rejects invalid language without overwriting persistence", language.selection == "en" && defaults.string(forKey: UIL10n.preferenceKey) == "en")
        check("New observable restores saved English", AppUILanguage(defaults: defaults, preferred: ["ko-KR"]).selection == "en")
        let ko = try catalog(source.appendingPathComponent("ko.lproj/Localizable.strings")), en = try catalog(source.appendingPathComponent("en.lproj/Localizable.strings"))
        check("Real catalogs parse and contain first-use translations", !ko.isEmpty && en["미디어 가져오기…"] == "Import Media…" && en["저장하지 않은 변경사항이 있습니다."] == "You have unsaved changes.")
        check("Real catalog keys match exactly", Set(ko.keys) == Set(en.keys), "ko=\(ko.count) en=\(en.count)")
        check("All translated catalog values are nonempty", ko.values.allSatisfy { !$0.isEmpty } && en.values.allSatisfy { !$0.isEmpty })
        check("Every declared caption format key exists in both catalogs", captionFormatKeys.isSubset(of: Set(ko.keys)) && captionFormatKeys.isSubset(of: Set(en.keys)))
        let mismatch = try ko.keys.filter { $0.hasPrefix("ui.") || captionFormatKeys.contains($0) }.sorted().filter { try specifiers(ko[$0]!) != specifiers(en[$0] ?? "") }
        check("Every declared format (ui.* and seven caption keys) preserves argument types widths and order", mismatch.isEmpty, mismatch.joined(separator: ", "))
        let fixture = output.appendingPathComponent("Fixture.bundle")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "studio.jhcut.probe.resources." + UUID().uuidString, "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "ko", "CFBundleLocalizations": ["ko", "en"]], format: .xml, options: 0).write(to: fixture.appendingPathComponent("Info.plist"))
        for code in ["ko", "en"] { try FileManager.default.copyItem(at: source.appendingPathComponent(code + ".lproj"), to: fixture.appendingPathComponent(code + ".lproj")) }
        guard let bundle = Bundle(url: fixture) else { throw ProjectError("Resource fixture bundle unavailable") }
        check("Actual helper reads English from temporary bundle", UIL10n.text("미디어 가져오기…", bundle: bundle, language: "en") == "Import Media…")
        check("Actual helper reads Korean from temporary bundle", UIL10n.text("미디어 가져오기…", bundle: bundle, language: "ko") == "미디어 가져오기…")
        check("English model guidance explicitly permits editing and export", UIL10n.text("자동 자막에는 음성 모델이 필요합니다. 모델 없이도 이 영상을 편집하고 출력할 수 있습니다.", bundle: bundle, language: "en") == "Auto captions need a speech model. You can edit and export this video now.")
        check("Korean model guidance explicitly permits editing and export", UIL10n.text("자동 자막에는 음성 모델이 필요합니다. 모델 없이도 이 영상을 편집하고 출력할 수 있습니다.", bundle: bundle, language: "ko") == "자동 자막에는 음성 모델이 필요합니다. 모델 없이도 이 영상을 편집하고 출력할 수 있습니다.")
        check("English recovery explains original preservation and separate Save As", UIL10n.text("복구본을 새 문서로 열었습니다. 원본은 보존됩니다. 다른 이름으로 저장하세요.", bundle: bundle, language: "en") == "Recovery opened as a new document. The original is preserved. Use Save As to keep this copy.")
        check("Recovery error retains the exact underlying diagnostic", UIL10n.format("ui.recovery.read.failure", bundle: bundle, language: "en", arguments: ["원인 100% %@"]) == "Could not read recovery copies: 원인 100% %@")
        check("Relink progress retains both counts and individual followup", UIL10n.format("ui.relink.result", bundle: bundle, language: "en", arguments: [Int(2),Int(3)]) == "Relinked 2 of 3 originals · Relink any remaining files individually.")
        check("Missing translation key remains verbatim", UIL10n.text("unknown.key.%@.한글", bundle: bundle, language: "en") == "unknown.key.%@.한글")
        check("Unsupported explicit language uses safe fallback", UIL10n.text("저장", bundle: bundle, language: "fr") == "저장")
        let empty = output.appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "studio.jhcut.probe.empty." + UUID().uuidString, "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: empty.appendingPathComponent("Info.plist"))
        guard let emptyBundle = Bundle(url: empty) else { throw ProjectError("Empty resource fixture bundle unavailable") }
        check("Missing language resource retains readable literal", UIL10n.text("저장", bundle: emptyBundle, language: "en") == "저장")
        check("Missing language resource retains readable named format", UIL10n.format("ui.saved.file", bundle: emptyBundle, language: "en", arguments: ["내 원본 100%.jhcut"]) == "저장됨 · 내 원본 100%.jhcut")
        check("Reusable caption-region format retains both singular and multiple counts", [(1, 3), (2, 4)].allSatisfy { done, total in
            UIL10n.format("현재 원본·설정으로 재사용 가능 · %ld/%ld구간", bundle: bundle, language: "en", arguments: [done, total]) == "Reusable regions with the current source and settings: \(done)/\(total)"
        })
        check("Stored caption-record format retains count and unverified-reuse warning", [1, 2].allSatisfy { count in
            UIL10n.format("보관된 인식 기록 %ld개 · 현재 원본·설정의 재사용 확인 전", bundle: bundle, language: "en", arguments: [count]) == "Saved transcription records: \(count) · Reuse with the current source and settings has not been checked"
        })
        check("Caption channel picker format renders one and thirty-two", [1, 32].allSatisfy { channel in
            UIL10n.format("채널 %ld", bundle: bundle, language: "en", arguments: [channel]) == "Channel \(channel)"
        })
        check("Caption review-count format handles singular and multiple without noun agreement", [1, 3].allSatisfy { count in
            UIL10n.format("확인 필요 %ld개", bundle: bundle, language: "en", arguments: [count]) == "\(count) to review"
        })
        let captionFilename = "저장 100% %@ 한국어_日本語.mov"
        let captionSourceEnglish = UIL10n.format("원본: %@%@", bundle: bundle, language: "en", arguments: [captionFilename, " · Channel 1"])
        let captionSourceKorean = UIL10n.format("원본: %@%@", bundle: bundle, language: "ko", arguments: [captionFilename, " · 채널 1"])
        check("Caption speaker-source format preserves adversarial filename and suffix literally in both languages", captionSourceEnglish == "Source: " + captionFilename + " · Channel 1" && captionSourceKorean == "원본: " + captionFilename + " · 채널 1")
        check("Caption speaker-channel suffix format retains separator and channel counts", [1, 2].allSatisfy { channel in
            UIL10n.format(" · 채널 %ld", bundle: bundle, language: "en", arguments: [channel]) == " · Channel \(channel)"
        })
        check("Caption batch-count format handles one and multiple with hidden-track scope", [1, 3].allSatisfy { count in
            UIL10n.format("선택 %ld개 · 숨긴 원문·번역 트랙은 바꾸지 않습니다", bundle: bundle, language: "en", arguments: [count]) == "\(count) selected · Hidden original and translation tracks are unchanged"
        })
        let filename = "내 원본 100% %@ 日本語.mov"
        check("English library preview preserves asset names literally", UIL10n.format("ui.library.asset.preview", bundle: bundle, language: "en", arguments: [filename]) == "Preview " + filename)
        check("Library duration uses English units and decimal precision", UIL10n.format("ui.library.seconds", bundle: bundle, language: "en", arguments: [12.25]) == "12.2 s · ")
        let backupLabel = UIL10n.format("ui.project.backup.picker", bundle: bundle, language: "en", arguments: [filename, "2026-10-15 23:01:02.345", "1234abcd", "Unsaved Changes Not Included"])
        check("Backup picker retains filename timestamp identifier and saved-document scope", backupLabel.contains(filename) && backupLabel.contains("2026-10-15 23:01:02.345") && backupLabel.contains("1234abcd") && backupLabel.contains("Unsaved Changes Not Included") && backupLabel.contains("Last Saved Document") && backupLabel.contains("Original Media Not Included"), backupLabel)
        check("Headless project format retains readable Korean fallback", UIL10n.format("ui.project.asset.relink", bundle: emptyBundle, language: "en", arguments: [filename]) == filename + " 재연결")
        check("English substitution preserves filename bytes and percent signs", UIL10n.format("ui.saved.file", bundle: bundle, language: "en", arguments: [filename]) == "Saved · " + filename)
        check("Korean substitution preserves filename bytes and percent signs", UIL10n.format("ui.saved.file", bundle: bundle, language: "ko", arguments: [filename]) == "저장됨 · " + filename)
        check("Integer progress produces a literal percent sign", UIL10n.format("ui.export.progress", bundle: bundle, language: "en", arguments: [Int(73)]) == "Exporting Video 73%")
        check("Relink substitution preserves names duration order and precision", UIL10n.format("ui.relink.confirm", bundle: bundle, language: "en", arguments: ["원본.mov", "새 파일.mov", 1.25, 2.5]) == "원본.mov → 새 파일.mov\nDuration 1.25 s → 2.50 s\nReplace with the new file?")
        let consent = UIL10n.format("ui.speech.install.consent", bundle: bundle, language: "en", arguments: ["base 다국어", "MIT", Int64(5_123_456_789), Int64(6_123_456_789), "https://example.invalid/model", "https://example.invalid/license", "0123456789abcdef"])
        check("Consent formats values beyond 32 bits without truncation", consent.contains("Download: 5,123,456,789 bytes · Required space: 6,123,456,789 MB"), consent)
        check("Consent retains source license checksum and local disclosure", consent.contains("License: MIT") && consent.contains("https://example.invalid/model") && consent.contains("https://example.invalid/license") && consent.contains("SHA-256: 0123456789abcdef") && consent.contains("speech is processed only on this Mac"))
        var project = Project(name: "새 프로젝트")
        project.sequence.tracks[0].name = "저장"
        project.sequence.tracks[0].clips = [Clip(name: filename, title: Title(text: "일시정지\n자막 원문 100% %@"))]
        let original = project
        for code in ["en", "ko", "en"] { language.selection = code; _ = UIL10n.format("ui.track.lock", bundle: bundle, language: code, arguments: [project.sequence.tracks[0].name]); _ = UIL10n.format("ui.saved.file", bundle: bundle, language: code, arguments: [project.name]) }
        check("Language changes preserve actual Project names captions and clip names", project == original)
        check("User values equal to translation keys remain literal", UIL10n.format("ui.saved.file", bundle: bundle, language: "en", arguments: [project.name]) == "Saved · 새 프로젝트" && UIL10n.format("ui.track.lock", bundle: bundle, language: "en", arguments: [project.sequence.tracks[0].name]) == "Lock 저장")
        check("Original catalog bytes remain unchanged", try hashes(source) == beforeHashes)
        check("Standard app selection remains unchanged", UserDefaults.standard.string(forKey: UIL10n.preferenceKey) == beforeStandardSelection)
        check("AppleLanguages remains unchanged", UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] == beforeLanguages)
        let failures = checks.filter { ($0["passed"] as? Bool) != true }.count
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "checks": checks, "failures": failures, "catalogEntries": ko.count, "resourceHashes": beforeHashes, "scope": "Real localization helper, observable defaults and catalogs; native UI remains unverified."], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print("UI_LOCALIZATION_RESULT checks=\(checks.count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

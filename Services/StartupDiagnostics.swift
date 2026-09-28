import Foundation

/// Plain-language checks for problems that stop the app, captions or translation from working on
/// a new Mac. Read-only: nothing is installed, downloaded or changed.
public struct DiagnosticItem: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable { case ok, info, warning, error }
    public var id: String
    public var level: Level
    public var title: String
    /// What the user can do about it, in plain words.
    public var advice: String
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var system: String
    public var items: [DiagnosticItem]
    public var hasErrors: Bool { items.contains { $0.level == .error } }
    public var text: String {
        (["JH CUT Studio \(appVersion) (\(build)) · \(system)"] + items.map { "[\($0.level.rawValue)] \($0.title) — \($0.advice)" }).joined(separator: "\n")
    }
}

public enum StartupDiagnostics {
    public struct Environment: Sendable {
        public var bundleURL: URL
        public var infoDictionary: [String: String]
        public var supportDirectory: URL
        public var whisper: WhisperConfiguration
        public var systemVersion: OperatingSystemVersion
        public var freeBytes: Int64?
        /// Installed translation pairs ("ko→en"), or nil when translation is unavailable on this system.
        public var translationPairs: [String]?
        public init(bundleURL: URL, infoDictionary: [String: String], supportDirectory: URL, whisper: WhisperConfiguration,
                    systemVersion: OperatingSystemVersion, freeBytes: Int64?, translationPairs: [String]?) {
            self.bundleURL = bundleURL; self.infoDictionary = infoDictionary; self.supportDirectory = supportDirectory; self.whisper = whisper
            self.systemVersion = systemVersion; self.freeBytes = freeBytes; self.translationPairs = translationPairs
        }
        public static func current(translationPairs: [String]?) -> Environment {
            let info = (Bundle.main.infoDictionary ?? [:]).compactMapValues { $0 as? String }
            let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                           ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio")
            let free = (try? URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            return Environment(bundleURL: Bundle.main.bundleURL, infoDictionary: info, supportDirectory: support, whisper: WhisperConfiguration(),
                               systemVersion: ProcessInfo.processInfo.operatingSystemVersion, freeBytes: free, translationPairs: translationPairs)
        }
    }

    public static func run(_ env: Environment) -> DiagnosticReport {
        var items: [DiagnosticItem] = []
        func add(_ id: String, _ level: DiagnosticItem.Level, _ title: String, _ advice: String) { items.append(DiagnosticItem(id: id, level: level, title: title, advice: advice)) }
        let fm = FileManager.default
        let path = env.bundleURL.path
        // Gatekeeper runs a quarantined app from a random read-only location until it is moved.
        if path.contains("/AppTranslocation/") {
            add("translocation", .warning, "앱이 임시 격리 위치에서 실행 중입니다", "Finder에서 JH CUT Studio를 ‘응용 프로그램’ 폴더로 옮긴 뒤 다시 여세요. 그대로 쓰면 설정이 저장되지 않거나 업데이트가 실패할 수 있습니다.")
        } else if path.hasPrefix("/Volumes/") && path.contains(".dmg") {
            add("diskImage", .warning, "디스크 이미지 안에서 실행 중입니다", "앱을 ‘응용 프로그램’ 폴더로 복사한 뒤 실행하세요.")
        }
        // Bundle integrity: the recogniser ships inside the app.
        if fm.isExecutableFile(atPath: env.whisper.runtimeURL.path) {
            add("runtime", .ok, "음성 인식 실행 파일 확인", "whisper.cpp 실행 파일이 앱 안에 있습니다.")
        } else {
            add("runtime", .error, "앱 안의 음성 인식 실행 파일이 없거나 실행할 수 없습니다", "앱이 손상됐습니다. 받은 압축 파일에서 앱을 다시 복사하세요. 편집·출력은 계속 쓸 수 있지만 자동 자막은 만들 수 없습니다.")
        }
        // Model: never downloaded automatically; the user installs it with consent.
        let state = LocalTranscription.availability(configuration: env.whisper)
        if state.canTranscribe { add("model", .ok, "자동 자막 모델 설치됨", env.whisper.modelSpec.name) }
        else if fm.isExecutableFile(atPath: env.whisper.runtimeURL.path) {
            add("model", .info, "자동 자막 모델이 아직 설치되지 않았습니다", "자막 패널의 ‘Whisper 모델 설치…’를 눌러 출처·용량·해시를 확인하고 동의하면 설치됩니다(약 \(env.whisper.modelSpec.byteCount / 1_000_000)MB). 설치 전에도 편집·출력은 사용할 수 있습니다.")
        }
        // Translation language packs (Apple Translation, macOS 26+).
        if let pairs = env.translationPairs {
            if pairs.isEmpty {
                add("translation", .info, "설치된 번역 언어팩이 없습니다", "자막 번역을 쓰려면 시스템 설정 → 일반 → 언어 및 지역 → 번역 언어에서 한국어·영어·일본어를 내려받으세요. 원문 자막은 언어팩 없이도 만들 수 있습니다.")
            } else { add("translation", .ok, "번역 언어팩", pairs.joined(separator: ", ")) }
        } else if env.systemVersion.majorVersion < 26 {
            add("translation", .info, "이 macOS에서는 기기 내 자막 번역을 쓸 수 없습니다", "자막 번역은 macOS 26 이상에서 동작합니다. 자동 자막과 편집·출력은 그대로 사용할 수 있습니다.")
        }
        // Settings, checkpoints and reports live here.
        do {
            try fm.createDirectory(at: env.supportDirectory, withIntermediateDirectories: true)
            let probe = env.supportDirectory.appendingPathComponent(".write-test-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe); try fm.removeItem(at: probe)
            add("support", .ok, "설정·체크포인트 폴더에 쓸 수 있음", env.supportDirectory.path)
        } catch {
            add("support", .error, "설정 폴더에 쓸 수 없습니다", "\(env.supportDirectory.path) 폴더의 권한을 확인하세요. 체크포인트·보고서·모델을 저장할 수 없습니다. (\(error.localizedDescription))")
        }
        if let free = env.freeBytes {
            if free < 2_000_000_000 { add("disk", .warning, "저장 공간이 부족합니다 (\(free / 1_000_000)MB)", "출력과 음성 인식 임시 파일에 최소 2GB 이상이 필요합니다. 공간을 확보한 뒤 출력하세요.") }
            else { add("disk", .ok, "저장 공간", "\(free / 1_000_000_000)GB 사용 가능") }
        }
        let version = env.infoDictionary["CFBundleShortVersionString"] ?? "?"
        let build = env.infoDictionary["CFBundleVersion"] ?? "?"
        let v = env.systemVersion
        return DiagnosticReport(appVersion: version, build: build, system: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", items: items)
    }
}

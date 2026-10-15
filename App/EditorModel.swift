import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import CryptoKit
import JHCutCore

/// App-only UI localization. It never rewrites project names, filenames, captions, or stored edits.
/// Kept in this existing compilation unit so explicit EditorModel probe source lists remain valid.
enum UIL10n {
    static let preferenceKey = "JHCutStudio.uiLanguage"
    static func language(defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages) -> String {
        if let saved = defaults.string(forKey: preferenceKey), ["ko", "en"].contains(saved) { return saved }
        return preferred.first?.lowercased().hasPrefix("en") == true ? "en" : "ko"
    }
    private static let formatFallbacks: [String: String] = [
        "ui.project.canvas.preset": "%@ · %ld×%ld",
        "ui.project.canvas.custom": "사용자 지정 · %ld×%ld",
        "ui.project.export.estimate": "예상 %ldMB",
        "ui.project.export.history.count": "최근 출력 기록 %ld개",
        "ui.project.marker.seconds": "%@ · %.2f초",
        "ui.project.asset.relink": "%@ 재연결",
        "ui.project.issue.more": "외 %ld개 · 보고서에서 확인",
        "ui.project.backup.picker": "%@ · %@ · %@ · 마지막 저장본 · %@ · 원본 미디어 미포함",
        "ui.library.asset.preview": "%@ 미리듣기",
        "ui.library.asset.add": "%@ 추가",
        "ui.library.seconds": "%.1f초 · ",
        "ui.recovery.cleanup.failure": "복구본 정리 실패: %@",
        "ui.recovery.autosaved": "복구본 자동 저장됨 · %@",
        "ui.recovery.save.failure": "복구본 저장 실패: %@",
        "ui.recovery.read.failure": "복구본을 읽을 수 없습니다: %@",
        "ui.relink.result": "%ld/%ld개 원본 연결됨 · 남은 파일은 개별 재연결로 확인하세요.",
        "ui.speech.install.consent": "%@\n라이선스: %@\n다운로드: %lld바이트 · 필요 공간: %lldMB\n출처: %@\n라이선스: %@\nSHA-256: %@\n\n설치 후 음성은 이 Mac에서만 처리됩니다.",
        "ui.duration": "전체 길이 %@",
        "ui.export.completed": "영상 출력 완료 · %@",
        "ui.export.progress": "영상 출력 중 %ld%%",
        "ui.import.count": "미디어 %ld개 가져옴 · 한 번의 실행취소로 되돌릴 수 있습니다.",
        "ui.inspector.count": "속성 · %ld개 선택",
        "ui.media.count": "미디어 %ld개",
        "ui.opened.file": "프로젝트 열림 · %@",
        "ui.position": "현재 위치 %@",
        "ui.redo.hint": "되돌린 편집을 다시 적용합니다 ⇧⌘Z · 현재 %ld개. 새 편집을 시작하면 재실행 기록은 지워집니다.",
        "ui.relink.choose": "%@의 새 위치를 선택하세요. 사용 중인 소스 범위가 유효해야 합니다.",
        "ui.relink.confirm": "%@ → %@\n길이 %.2f초 → %.2f초\n새 파일로 교체할까요?",
        "ui.saved.file": "저장됨 · %@",
        "ui.sequence.description": "시퀀스 %ld × %ld, 초당 %@프레임, Rec.709",
        "ui.speech.count": "선택한 음성 클립 %ld개",
        "ui.speech.detected": "감지된 음성: %@",
        "ui.time.long": "%ld분 %ld초 %ld프레임",
        "ui.time.short": "%ld초 %ld프레임",
        "ui.track.hide": "%@ 숨기기",
        "ui.track.lock": "%@ 잠금",
        "ui.track.mute": "%@ 음소거",
        "ui.track.show": "%@ 보이기",
        "ui.track.unlock": "%@ 잠금 해제",
        "ui.track.unmute": "%@ 음소거 해제",
        "ui.undo.hint": "마지막 편집을 되돌립니다 ⌘Z · 현재 %ld개. 최근 최대 100개를 보관하며, 큰 편집은 보관 범위가 줄어듭니다.",
        "ui.version": "JH CUT STUDIO %@ · 로컬 편집",
        "ui.zoom.value": "초당 %ld 포인트"
    ]
    static func text(_ key: String, bundle: Bundle = .main, language: String? = nil) -> String {
        let code = language ?? self.language()
        guard ["ko", "en"].contains(code), let path = bundle.path(forResource: code, ofType: "lproj"),
              let selected = Bundle(path: path) else { return formatFallbacks[key] ?? key }
        return selected.localizedString(forKey: key, value: formatFallbacks[key] ?? key, table: "Localizable")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, bundle: .main, language: language(), arguments: arguments)
    }
    // Dependency injection exercises the production formatting path with temporary resource bundles.
    static func format(_ key: String, bundle: Bundle, language: String, arguments: [CVarArg]) -> String {
        String(format: text(key, bundle: bundle, language: language), locale: Locale(identifier: language), arguments: arguments)
    }
}

@MainActor
final class AppUILanguage: ObservableObject {
    @Published var selection: String {
        didSet {
            // App-specific preference only. Never writes AppleLanguages or system settings.
            if !["ko", "en"].contains(selection) { selection = oldValue; return }
            defaults.set(selection, forKey: UIL10n.preferenceKey)
        }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.selection = UIL10n.language(defaults: defaults, preferred: preferred)
    }
    var locale: Locale { Locale(identifier: selection) }
}

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var seconds = 0.0
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var history = EditorHistory(project: Project()) {
        didSet { encodedProject = nil; asyncDocumentRevision &+= 1 }
    }
    // Monotonic revision also rejects edit → Undo and document/base ABA while work is suspended.
    var asyncDocumentRevision: UInt64 = 0
    var productivityJobID: UUID?
    var importJobID: UUID?
    var proxyJobID: UUID?
    var productivityCancelRequested = false
    var importCancelRequested = false
    var proxyCancelRequested = false
    /// Nil in the product; deterministic barriers in fresh-workspace probes.
    var asyncJobBarrier: ((String) async throws -> Void)?
    var asyncProgressHandled: ((UUID) -> Void)?
    var asyncProgressObserver: ((String, @escaping @Sendable (Double) -> Void) -> Void)?
    var analyzedContext: EditorAsyncContext?
    var analyzedSource: EditorSourceIdentity?
    private var encodedProject: Data?
    @Published var selectedClipID: UUID?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedAssetID: UUID?
    @Published var documentURL: URL? { didSet { asyncDocumentRevision &+= 1 } }
    // In-memory history retains the original document's relative reference base across Save As.
    @Published var mediaBaseURL: URL? { didSet { asyncDocumentRevision &+= 1 } }
    @Published var message = "영상을 가져와 첫 타임라인을 시작하세요."
    @Published var error: String?
    @Published var isBuilding = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    let playbackClock = PlaybackClock()
    var playhead: Double { get { playbackClock.seconds } set { playbackClock.seconds = newValue } }
    @Published var playing = false
    @Published var zoom = 48.0
    @Published var libraryVisible = true
    @Published var inspectorVisible = true
    @Published var savedData: Data?
    private var diskRevision: Data?
    @Published var snappingEnabled = true
    @Published var bundledLibrary: AssetLibrary?
    var libraryMediaStore = LibraryMediaStore()
    @Published var auditionID: String?
    @Published var userTitlePresets: [TitlePreset] = []
    @Published var recoveryStatus = "변경사항을 로컬 복구본에 자동 저장합니다."
    private var auditionPlayer: AVAudioPlayer?
    private var auditionTask: Task<Void, Never>?
    func playChannelPreview() {
        guard !busyDocument, let (_, clip, asset) = selectedSpeechClips.first else { return }
        stopAudition(); pausePlayback()
        let source = asset.resolvedURL(relativeTo: mediaBaseURL), channel = speechOptions.channel
        productivityBusy = true
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                let identity = try await EditorSourceIdentity.capture(source)
                let preview = try await LocalTranscription.previewChannel(url: source, sourceStart: clip.sourceStart, duration: min(clip.sourceDuration, MediaTime(10, 1)), channel: channel)
                try Task.checkCancellation()
                try await checkpointAsyncJob(ticket, "channelPreview.beforePlay")
                try await identity.validate(); try validateAsyncJob(ticket)
                let audio = try AVAudioPlayer(data: preview.data)
                guard audio.prepareToPlay(), audio.play() else { throw ProjectError("대사 채널을 재생할 수 없습니다.") }
                auditionPlayer = audio; auditionID = "speech-channel"
                message = "대사 채널 \(preview.channel + 1) · 원본 시작 구간 미리듣기"
                auditionTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((audio.duration + 0.1) * 1_000_000_000))
                    guard !Task.isCancelled, self?.auditionID == "speech-channel" else { return }; self?.stopAudition()
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var recoveryTask: Task<Void, Never>?
    let recoveryStore: RecoveryStore
    private var offeredRecovery = false
    let player = AVPlayer()
    var plan: RenderPlan?
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0
    /// Optional monotonic phase observations for a rebuild; nil in ordinary app use.
    var rebuildPhaseObserver: ((Int, String, Double) -> Void)?
    var exportJob: ExportJob?
    var exportTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var productivityTask: Task<Void, Never>?
    var proxyTask: Task<Void, Never>?
    let proxyCache: ProxyCache
    @Published var proxyURLs: [UUID: URL] = [:]
    @Published var proxyEnabled = false
    @Published var proxyBusy = false
    @Published var proxyProgress = 0.0
    @Published var proxyStatus = "원본 미디어로 미리보기"
    @Published var importProgress = 0.0
    @Published var productivityBusy = false
    @Published var productivityStatus = ""
    @Published var audioResult: AudioAnalysisResult?
    @Published var analyzedClip: Clip?
    @Published var analyzedAsset: MediaAsset?
    @Published var analyzedProjectID: UUID?
    @Published var speechModelID = "base"
    var speechModelSpec: WhisperModelSpec { speechModelID == "small" ? .small : .base }
    @Published var speechOptions = SpeechOptions()
    @Published var autoCaptionImportedVideos = true
    @Published var translateAfterTranscription = true
    @Published var translationTargetLanguage = "ko"
    @Published var translationSourceLanguage = "auto"
    @Published var bilingualTranslation = false
    /// Presentation fitting applies only to newly generated translations, never reused/manual captions.
    @Published var fitNewTranslatedCaptions = true
    @Published var translationGlossaryText = ""
    /// TranslationStyle raw value applied to new translations.
    @Published var translationStyle = TranslationStyle.natural.rawValue
    @Published var translationActive = false
    @Published var detectedSpeechLanguages = ""
    @Published var subtitleExportScope = "visible"
    /// Legacy positional injection for existing probes only. Production uses identified responses.
    var translationProvider: (@MainActor ([String], String, String) async throws -> [String])?
    var translationBatchProvider: @MainActor ([CaptionTranslationRequest], String, String) async throws -> [CaptionTranslationResponse] = { requests, source, target in
        try await CaptionTranslation.translateIdentified(requests, from: source, to: target)
    }
    @Published var translationFailureAttempts: [UUID: TranslationRevision] = [:]
    var translationFailureSourceIDs: Set<UUID> { Set(translationFailureAttempts.keys) }

    @Published var replaceAutomaticCaptions = true
    /// Long recognition keeps each finished 5-minute window on disk so a cancel or quit resumes.
    @Published var useSpeechCheckpoints = true
    /// Voice-activity analysis: silence, music and strong noise longer than 3 s are not sent to Whisper.
    @Published var skipNonSpeech = true
    @Published var voiceActivityPolicy = VoiceActivityPolicy.conservative
    /// Captions found over silence/music/noise by the last voice-activity check (not saved in the document).
    @Published var silentCaptionWarnings: [UUID: VoiceActivityKind] = [:]
    /// Captions kept from a collapsed Whisper repetition loop; the user should check them (not saved).
    @Published var repetitionCaptionIDs: Set<UUID> = []
    @Published var lastVoiceActivity: VoiceActivityReport?
    /// In-memory analysis cache keyed by verified full media digest, range, channel and policy.
    var voiceActivityCache: [String: VoiceActivityReport] = [:]
    @Published var transcriptionDetail: TranscriptionProgress?
    var checkpointWriteFailed = false
    @Published var lastEvaluation: TranscriptEvaluationReport?
    @Published var evaluationActive = false
    @Published var evaluationProgress: Double?
    var evaluationJobID: UUID?
    @Published var evaluationAttemptState: String?
    @Published var evaluationAttemptReason: String?
    @Published var evaluationRetainedPrevious = false
    @Published var speakerStatus = ""
    /// Session-only confirmation scoped to a recording; never inferred from channel energy.
    @Published var confirmedSpeakerSources = Set<UUID>()
    var speakerTranscriptionProvider: ((Int) async throws -> [CaptionCue])?
    var channelSpeakerMappingConfirmed: Bool {
        get { selectedSpeechClips.first.map { confirmedSpeakerSources.contains($0.2.id) } ?? false }
        set { guard let id = selectedSpeechClips.first?.2.id else { return }; if newValue { confirmedSpeakerSources.insert(id) } else { confirmedSpeakerSources.remove(id) } }
    }
    @Published var lastEvaluationReportURL: URL?
    var reportsDirectory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio/Reports", isDirectory: true)
    /// Where files generated from the user's media (reversed copies, freeze-frame stills) are written.
    var generatedMediaRoot = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio/PreparedMedia", isDirectory: true)
    @Published var generatedMediaStatus = ""
    @Published var generatedMediaReport: GeneratedMediaReport?
    var generatedMediaScanTask: Task<Void, Never>?
    var generatedMediaScanID = UUID()
    /// Injectable destination for owned validation fixtures; normal use goes to macOS Trash.
    var generatedMediaTrash: @MainActor (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    @Published var checkpointSummaries: [TranscriptionCheckpointSummary] = []
    @Published var checkpointMediaHashes: [UUID:String] = [:]
    var checkpointMediaPaths: [UUID:String] = [:]
    var checkpointMediaStamps: [UUID:String] = [:]
    var checkpointRefreshTask: Task<Void,Never>?
    var checkpointRefreshID = UUID()
    var transcriptionAnalysisClipID: UUID?
    var speechWindowSeconds: Double = 300
    var checkpointStore = TranscriptionCheckpointStore()
    var mediaFingerprints = MediaFingerprintCache(persistURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("JHCutStudio/media-fingerprints.json"))
    @Published var loopEnabled = false
    @Published var loopStart = 0.0
    @Published var loopEnd = 0.0
    @Published var exportRangeEnabled = false
    /// Writes the burned-in captions as an .srt beside the video and compares the two after export.
    @Published var exportSidecarSRT = false
    @Published var diagnostics: DiagnosticReport?
    @Published var backupEntries: [ProjectBackup.Entry] = []
    @Published var backupStatus = "백업은 마지막 저장본이며 원본 미디어를 포함하지 않습니다."
    var backupRoot = ProjectBackup.defaultRoot
    @Published var exportQualityStatus = ""
    @Published var lastQualityReport: OutputQualityReport?
    @Published var lastQualityReportURL: URL?
    var lastExportedRequest: QueuedExport?
    var lastExportExpectation: OutputExpectation?
    var lastExportSources: [ExportSourceIdentity] = []
    var lastExportOutputSHA256: String?
    @Published var activeExportID: UUID?
    @Published var activeExportPhase: ExportPhase?
    @Published var lastExportReceipt: ExportDeliveryReceipt?
    /// Deterministic phase observation for integration/fault tests; absent in the product.
    var exportPhaseObserver: ((UUID, ExportPhase) -> Void)?
    @Published var exportQueue: [QueuedExport] = []
    @Published var exportJournal: [[String: String]] = []
    var exportJournalURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/export-history.json")
    @Published var exportCodec = ExportJob.Codec.h264
    @Published var duckingDB = -12.0
    @Published var duckingRelease = 0.4
    @Published var targetLUFS = -16.0
    @Published var enhanceMixVoice = false
    @Published var mixStatus = ""
    @Published var transcriptionReady = false
    @Published var transcriptionStatus = "모델 설치 상태 확인 중"
    @Published var transcriptionActive = false
    @Published var transcriptionProgress: Double?
    @Published var transcriptionPresetID = TitlePreset.builtIns[0].id
    var transcriptionJobID: UUID?
    @Published var timelineScrollY = 0.0
    @Published var safeAreaVisible = false
    @Published var outputBitRate = 8_000_000
    @Published var outputQuality: ExportJob.Quality = .standard
    var busyDocument: Bool { isExporting || isImporting || productivityBusy || proxyBusy }

    private var observer: Any?
    private var playbackObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var menuTrackingCount = 0
    private var menuObservers: [NSObjectProtocol] = []
    var project: Project { history.project }
    /// Every UI timebase derives from the sequence, so a 24 or 60fps project steps correctly.
    var frameRate: FrameRate { project.sequence.frameRate }
    var fps: Double { frameRate.fps }
    var frameStep: Double { 1.0 / max(1, fps) }
    /// Nearest frame boundary as an exact rational, never a float round-trip.
    func snapped(_ seconds: Double) -> MediaTime {
        let safe = seconds.isFinite ? max(0, min(project.sequence.duration.seconds, seconds)) : 0
        let count = (safe * fps).rounded()
        guard count.isFinite, count < Double(Int64.max) - 1024 else { return .zero }
        let frame = max(0, Int64(count))
        let time = frameRate.time(forFrame: frame)
        let limit = project.sequence.duration
        return time > limit ? limit : time
    }
    @Published var captionOperationScope = "all"
    @Published var captionEditProposal: CaptionEditProposal?
    @Published var captionSelectedGroupID: UUID?
    var currentCaptionScope: CaptionScope {
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        switch captionOperationScope {
        case "selection": return .selected(ids)
        case "source":
            let parents = CaptionQuery.entries(in: project.sequence, scope: .selected(ids)).compactMap { $0.clip.connection?.parentID }
            return .sources(ids.union(parents))
        case "group": return .groups(captionSelectedGroupID.map { Set([$0]) } ?? Set(CaptionQuery.entries(in: project.sequence, scope: .selected(ids)).map(\.groupID)))
        default: return .all
        }
    }
    var captionClips: [Clip] { CaptionQuery.entries(in: project.sequence).map(\.clip) }
    var scopedCaptionClips: [Clip] { CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope).map(\.clip) }
    var allTitlePresets: [TitlePreset] { userTitlePresets + TitlePreset.builtIns }
    private func projectData() -> Data? {
        if let encodedProject { return encodedProject }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encodedProject = try? encoder.encode(project)
        return encodedProject
    }
    var dirty: Bool { projectData() != savedData }
    var selected: (Track, Clip)? {
        guard let selectedClipID else { return nil }
        for track in project.sequence.tracks {
            if let clip = track.clips.first(where: { $0.id == selectedClipID }) { return (track, clip) }
        }
        return nil
    }
    /// The recovery store is injectable so headless probes never write to the user's slot.
    init(recoveryStore: RecoveryStore = RecoveryStore(), exportHistoryURL: URL? = nil, proxyCache: ProxyCache = ProxyCache()) {
        self.proxyCache = proxyCache
        self.recoveryStore = recoveryStore
        if let exportHistoryURL { exportJournalURL = exportHistoryURL }
        if let data = try? Data(contentsOf: exportJournalURL), data.count <= 1_000_000, let records = try? JSONDecoder().decode([[String: String]].self, from: data) { exportJournal = Array(records.suffix(30)) }
        savedData = projectData()
        bundledLibrary = try? AssetLibrary()
        if let data = try? Data(contentsOf: Self.presetsURL), let presets = try? JSONDecoder().decode([TitlePreset].self, from: data) { userTitlePresets = presets }
        refreshTranscriptionStatus()
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                // `rate == 0` also means buffering. It must never erase a pending play request.
                if self.playing, time.seconds.isFinite, abs(self.playhead - time.seconds) > 0.001 {
                    self.playhead = time.seconds
                    if self.loopEnabled, self.validLoopRange != nil, time.seconds >= self.loopEnd {
                        self.player.seek(to: CMTime(seconds: self.loopStart, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
        }
        // The committed HEAD version never observed end-of-item at all, so `playing` stayed true
        // forever after natural completion; the next click then hit the `rate != 0` branch's `else`
        // and replayed from the start instead of the pause the user pressed.
        playbackObservers = [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                    if name == AVPlayerItem.didPlayToEndTimeNotification, self.loopEnabled, self.validLoopRange != nil {
                        self.seek(self.loopStart); self.playing = true; self.player.play(); return
                    }
                    self.pausePlayback()
                    if name == AVPlayerItem.failedToPlayToEndTimeNotification {
                        self.error = item.error?.localizedDescription ?? "미리보기 재생에 실패했습니다."
                    }
                }
            }
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingCount += 1 }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.menuTrackingCount = max(0, self.menuTrackingCount - 1) } }
            }
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow?.identifier?.rawValue != "save-panel" else { return event }
            if self.menuTrackingCount > 0 { return event }
            if NSApp.modalWindow != nil || NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil { return event }
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable || text.hasMarkedText() { return event }
            if NSApp.keyWindow?.firstResponder is NSTextField { return event }
            // Physical key codes retain editor shortcuts when the Korean input source is active.
            if event.modifierFlags.contains(.command), event.keyCode == 6 {
                if event.modifierFlags.contains(.shift) { self.redo() } else { self.undo() }
                return nil
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.keyCode {
                case 49: if !event.isARepeat { self.togglePlay() }; return nil
                case 53: self.pausePlayback(); self.stopAudition(); return nil
                case 123: self.seek(self.playhead - self.frameStep); return nil
                case 124: self.seek(self.playhead + self.frameStep); return nil
                case 51, 117: self.remove(); return nil
                default: break
                }
            }
            return event
        }
    }
    deinit {
        if let observer { player.removeTimeObserver(observer) }
        for token in playbackObservers + menuObservers { NotificationCenter.default.removeObserver(token) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        buildTask?.cancel(); recoveryTask?.cancel(); auditionTask?.cancel(); checkpointRefreshTask?.cancel(); productivityTask?.cancel(); importTask?.cancel(); proxyTask?.cancel(); generatedMediaScanTask?.cancel()
    }
    @discardableResult func perform(_ command: EditCommand) -> Bool {
        guard !isExporting else { return false }
        do {
            let before = project
            try history.apply(command)
            guard project != before else { return true }
            message = "편집 적용됨"; scheduleRecovery()
            let existing = Set(project.sequence.tracks.flatMap(\.clips).map(\.id))
            selectedClipIDs.formIntersection(existing)
            if let id = selectedClipID, !existing.contains(id) { selectedClipID = selectedClipIDs.first }
            if Self.needsRender(before, project) { rebuild() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func undo() {
        guard !isExporting else { return }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable { text.undoManager?.undo(); return }
        history.undo(); message = "타임라인 실행취소"; scheduleRecovery(); rebuild()
    }
    func redo() {
        guard !isExporting else { return }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable { text.undoManager?.redo(); return }
        history.redo(); message = "타임라인 재실행"; scheduleRecovery(); rebuild()
    }
    var playbackObservation: PlaybackObservation?
    private var pendingSeek: (id: UUID, target: Double)?

    func seek(_ seconds: Double) {
        guard seconds.isFinite else { error = "이동 시간을 유효한 숫자로 입력하세요."; return }
        let time = snapped(seconds)
        playhead = time.seconds
        playbackObservation?.sample("seek-request", displayedTime: time.seconds)
        let requestID = UUID(), expectedItem = player.currentItem, generation = buildGeneration
        pendingSeek = (requestID, time.seconds)
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.pendingSeek?.id == requestID, self.buildGeneration == generation,
                      self.player.currentItem === expectedItem else { return }
                self.pendingSeek = nil
                if !self.playing {
                    let actual = self.player.currentTime().seconds
                    if finished { self.playhead = time.seconds }
                    else if actual.isFinite { self.playhead = max(0, min(self.project.sequence.duration.seconds, actual)) }
                }
            }
        }
    }
    func togglePlay() {
        playbackObservation?.sample("toggle", displayedTime: playhead)
        // Pausing always wins, including while the item is waiting for data or rebuilding. The
        // committed HEAD version checked `isBuilding`/`isExporting` before this and used a bare
        // `player.rate != 0` test, so a click during a rebuild, or during the brief rate==0 window
        // AVPlayer reports while buffering mid-playback, silently did nothing or replayed instead of
        // pausing — exactly the "pause button doesn't stop the video" report.
        if playing || player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            pausePlayback(); return
        }
        guard !isBuilding, plan != nil else { return }
        if loopEnabled, validLoopRange == nil { error = "반복 구간의 시작·끝을 영상 길이 안에서 지정하세요."; return }
        stopAudition()
        if playhead >= project.sequence.duration.seconds - frameStep { seek(0) }
        playing = true
        player.play()
    }
    func pausePlayback() {
        playbackObservation?.sample("pause-request", displayedTime: playhead)
        player.pause()
        playing = false
        // A seek completes asynchronously. Pausing must not replace its requested position with
        // the old clock reading while the decoder is still moving to the new frame.
        let seconds = pendingSeek?.target ?? player.currentTime().seconds
        if seconds.isFinite { playhead = max(0, min(project.sequence.duration.seconds, seconds)) }
        playbackObservation?.sample("pause-complete", displayedTime: playhead)
    }
    func rebuild() {
        let phaseObserver = rebuildPhaseObserver
        let observedGeneration = buildGeneration + 1
        func phase(_ name: String) { phaseObserver?(observedGeneration, name, ProcessInfo.processInfo.systemUptime) }
        phase("request")
        playbackObservation?.sample("rebuild-request", displayedTime: playhead)
        buildTask?.cancel(); buildGeneration += 1; pendingSeek = nil
        // A committed build is authoritative, so any gesture still previewing is retired first.
        retireLiveEdit()
        let generation = buildGeneration
        player.pause(); playing = false
        playbackObservation?.sample("rebuild-paused", displayedTime: playhead)
        playbackObservation?.stop()
        phase("paused")
        plan = nil; player.replaceCurrentItem(with: nil)
        phase("itemRetired")
        guard project.sequence.duration > .zero else { isBuilding = false; return }
        isBuilding = true
        let snapshot = project, url = mediaBaseURL
        let overrides = proxyEnabled ? proxyURLs : [:]
        let cache = proxyCache
        phase("scheduled")
        buildTask = Task { [weak self] in
            phase("taskStarted")
            let rendererTrace = phaseObserver == nil ? nil : RendererPhaseBuffer()
            let rendererObserver: (@Sendable (String, TimeInterval) -> Void)? = rendererTrace.map { buffer in
                { name, time in buffer.append(name: name, time: time) }
            }
            func flushRendererTrace() {
                for event in rendererTrace?.drain() ?? [] {
                    phaseObserver?(generation, "renderer." + event.name, event.time)
                }
            }
            defer { flushRendererTrace() }
            do {
                var verified: [UUID: URL] = [:]
                for asset in snapshot.assets where overrides[asset.id] != nil {
                    if let cached = try await cache.cachedURL(for: asset.resolvedURL(relativeTo: url)), cached == overrides[asset.id] { verified[asset.id] = cached }
                }
                phase("proxiesVerified")
                let result = try await TimelineRenderer.build(project: snapshot, documentURL: url, mediaURLOverrides: verified, cacheInspection: true, phaseObserver: rendererObserver)
                flushRendererTrace()
                phase("planBuilt")
                guard let self, !Task.isCancelled, self.buildGeneration == generation else { phase("superseded"); return }
                self.plan = result
                let item = result.makePlayerItem()
                phase("itemCreated")
                self.player.replaceCurrentItem(with: item)
                phase("itemAttached")
                self.isBuilding = false; self.seek(self.playhead)
                phase("seekRequested")
            } catch {
                guard let self, !Task.isCancelled, self.buildGeneration == generation else { return }
                self.isBuilding = false; self.error = error.localizedDescription
                self.message = "미리보기를 만들지 못했습니다. 미디어와 오류를 확인하세요."
            }
        }
    }
    // MARK: - Live control preview
    //
    // A control being dragged substitutes one clip into the rendered project without touching the
    // document or the undo stack. The gesture commits a single history entry when it ends, so a drag
    // costs one undo step rather than one per slider tick.
    struct LiveEdit { var trackID: UUID; var clip: Clip }
    private var liveEdit: LiveEdit?
    private var livePending = false
    private var liveRunning = false
    // Bumped to retire a gesture. The render loop checks it rather than its own task handle, so a new
    // gesture starting while the previous loop unwinds cannot be clobbered by it.
    private var liveGeneration = 0
    private var liveOverrides: [UUID: URL] = [:]
    var isLivePreviewing: Bool { liveEdit != nil }
    var isLiveRendering: Bool { liveRunning }
    /// Counts previews actually rendered, so coalescing can be asserted rather than assumed.
    private(set) var livePreviewRenders = 0
    /// The committed document, with the in-progress control value substituted for its clip.
    var previewProject: Project {
        guard let live = liveEdit,
              let trackIndex = project.sequence.tracks.firstIndex(where: { $0.id == live.trackID }),
              let clipIndex = project.sequence.tracks[trackIndex].clips.firstIndex(where: { $0.id == live.clip.id })
        else { return project }
        var copy = project
        copy.sequence.tracks[trackIndex].clips[clipIndex] = live.clip
        return copy
    }
    func beginLiveEdit() {
        guard !isExporting, !busyDocument else { return }
        if playing || player.rate != 0 { pausePlayback() }
        // Proxy verification hits the cache directory, so it is resolved once per gesture.
        liveOverrides = proxyEnabled ? proxyURLs : [:]
    }
    func updateLiveEdit(trackID: UUID, clip: Clip) {
        guard !isExporting, !busyDocument, !isBuilding else { return }
        liveEdit = LiveEdit(trackID: trackID, clip: clip)
        guard !liveRunning else { livePending = true; return }
        liveRunning = true
        let generation = liveGeneration
        // Self-pacing: coalesces to whatever rate the renderer can actually sustain, with no timer.
        Task { [weak self] in
            while let self, self.liveGeneration == generation {
                self.livePending = false
                await self.renderLivePreview(generation: generation)
                guard self.livePending else { break }
            }
            if let self, self.liveGeneration == generation { self.liveRunning = false }
        }
    }
    /// Ends the gesture with one history entry. A rejected value reverts the preview to the document.
    func commitLiveEdit() {
        guard let live = liveEdit else { retireLiveEdit(); return }
        retireLiveEdit()
        let committed = project.sequence.tracks.first { $0.id == live.trackID }?.clips.first { $0.id == live.clip.id }
        guard live.clip != committed else { rebuild(); return }
        if !perform(.updateClip(trackID: live.trackID, clip: live.clip)) { rebuild() }
    }
    /// Retires the current gesture without committing; the caller decides what the player shows next.
    func retireLiveEdit() {
        liveGeneration &+= 1
        liveEdit = nil; livePending = false; liveRunning = false; liveOverrides = [:]
    }
    private func renderLivePreview(generation: Int) async {
        let snapshot = previewProject, url = mediaBaseURL, overrides = liveOverrides
        let buildID = buildGeneration
        guard snapshot.sequence.duration > .zero else { return }
        do {
            let result = try await TimelineRenderer.build(project: snapshot, documentURL: url, mediaURLOverrides: overrides, cacheInspection: true)
            // A committed rebuild started meanwhile owns the player; never fight it.
            guard liveGeneration == generation, buildGeneration == buildID, !isBuilding else { return }
            let resume = player.currentTime()
            // The previous item stays on screen until the new one is ready, so dragging never blanks.
            plan = result
            livePreviewRenders += 1
            player.replaceCurrentItem(with: result.makePlayerItem())
            player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        } catch {
            // Mid-gesture failures keep the last good preview; the commit reports the real error.
        }
    }

    func chooseMedia() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.title = UIL10n.text("미디어 가져오기…"); panel.prompt = UIL10n.text("가져오기")
        panel.allowedContentTypes = [.movie, .audio, .png, .jpeg, .heic]
        panel.message = UIL10n.text("로컬 SDR H.264·HEVC·ProRes, PNG·JPEG·HEIC, 오디오를 가져옵니다. 원본은 변경하지 않습니다.")
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    func importFiles(_ urls: [URL]) {
        guard !busyDocument else { return }
        let captionOnImport = autoCaptionImportedVideos
        importProgress = 0
        let ticket = beginAsyncJob(.importing)
        importTask = Task {
            defer { finishAsyncJob(ticket) }
            var failures: [String] = []; var assets: [MediaAsset] = []
            var identities: [EditorSourceIdentity] = []
            do {
                for (index, url) in urls.enumerated() {
                    try validateAsyncJob(ticket)
                    do {
                        let identity = try await EditorSourceIdentity.capture(url)
                        var asset = try await MediaImporter.inspect(url: url)
                        try await identity.validate()
                        try validateAsyncJob(ticket)
                        asset.contentHash = identity.sha256
                        identities.append(identity); assets.append(asset)
                        if !asset.supported { failures.append("\(asset.name): \(asset.issue ?? "지원하지 않는 미디어")") }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    try validateAsyncJob(ticket)
                    importProgress = Double(index + 1) / Double(max(1, urls.count))
                }
                try await checkpointAsyncJob(ticket, "import.beforeApply")
                for identity in identities { try await identity.validate() }
                try validateAsyncJob(ticket)
                guard !assets.isEmpty else { error = failures.joined(separator: "\n"); message = "가져올 수 있는 미디어가 없습니다."; return }
                guard perform(.batch(assets.map { .addAsset($0) })) else { return }
                selectedAssetID = assets.last?.id
                message = UIL10n.format("ui.import.count", assets.count)
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
                // End this import before starting the independently owned ASR task.
                finishAsyncJob(ticket)
                if captionOnImport { captionImportedVideos(assets.filter { $0.kind == .video && $0.supported && $0.hasAudio }) }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                message = Task.isCancelled ? "가져오기 취소됨 · 프로젝트에 추가하지 않았습니다." : error.localizedDescription
            }
        }
    }
    func cancelImport() { importCancelRequested = true; importTask?.cancel() }
    func addAsset(_ asset: MediaAsset, overlay: Bool = false) {
        guard asset.supported else { error = asset.issue ?? "지원하지 않는 미디어입니다."; return }
        let kind: TrackKind = asset.kind == .audio ? .audio : (overlay ? .overlay : .video)
        guard let track = writableTrack(kind) else { return }
        var clip = Clip(name: asset.name, assetID: asset.id, start: .zero, sourceStart: .zero,
                        duration: asset.kind == .image ? MediaTime(3, 1) : asset.duration)
        clip.start = kind == .video ? (track.clips.map { $0.start + $0.duration }.max() ?? .zero) : MediaTime(seconds: playhead)
        if overlay { clip.transform.scale = 0.35; clip.transform.x = 270; clip.transform.y = 550 }
        if asset.kind == .audio { clip.volume = 0.25 }
        if perform(.addClip(trackID: track.id, clip: clip)) { selectClip(clip.id) }
    }
    func addTitle() {
        guard let track = writableTrack(.title) else { return }
        var clip = Clip(name: "한국어 제목", assetID: nil, start: MediaTime(seconds: playhead), sourceStart: .zero, duration: MediaTime(3, 1))
        clip.captionRole = .title
        clip.title = TitleSizing.resized(Title(text: "종현의 첫 영상"), from: 1080, to: min(project.sequence.width, project.sequence.height))
        if perform(.addClip(trackID: track.id, clip: clip)) { selectClip(clip.id) }
    }
    func split() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable || text.hasMarkedText() { return }
        guard let (track, clip) = selected else { return }
        perform(.split(trackID: track.id, clipID: clip.id, at: MediaTime(seconds: playhead)))
    }
    func remove(ripple: Bool = false) {
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        let commands = project.sequence.tracks.flatMap { track in
            track.clips.filter { ids.contains($0.id) }.sorted { $0.start > $1.start }.map { EditCommand.delete(trackID: track.id, clipID: $0.id, ripple: ripple) }
        }
        guard !commands.isEmpty else { return }
        if perform(.batch(commands)) { selectedClipID = nil; selectedClipIDs = [] }
    }
    func reorder(_ direction: Int) {
        guard let (track, clip) = selected else { return }
        perform(.reorder(trackID: track.id, clipID: clip.id, direction: direction))
    }
    func save(as saveAs: Bool = false) {
        var destination = documentURL
        if saveAs || destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jhcut") ?? .json]
            panel.nameFieldStringValue = project.name + ".jhcut"
            panel.title = UIL10n.text("다른 이름으로 저장…"); panel.prompt = UIL10n.text("저장")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard let destination else { return }
        save(to: destination)
    }
    /// Writes the destination chosen by Save/Save As. A recovered copy has no destination until
    /// the user chooses one; keeping this write path shared also allows filesystem regressions.
    func save(to destination: URL) {
        do {
            if destination == documentURL, let diskRevision,
               (try? Data(contentsOf: destination)) != diskRevision {
                error = UIL10n.text("다른 프로그램에서 프로젝트 파일을 변경했습니다. 현재 편집을 ‘다른 이름으로 저장’하여 두 버전을 보존하세요."); return
            }
            // Recovery and backup copies can still rely on their original document's relative
            // paths. Resolve using that source base before Save As computes new relative paths.
            // The destination must never be used to guess which same-name media to bind.
            var document = project
            for index in document.assets.indices {
                document.assets[index].path = project.assets[index].resolvedURL(relativeTo: mediaBaseURL).path
            }
            try ProjectStore.save(document, to: destination); documentURL = destination; savedData = projectData()
            diskRevision = try Data(contentsOf: destination)
            recoveryTask?.cancel(); clearOwnRecovery()
            message = UIL10n.format("ui.saved.file", destination.lastPathComponent)
        }
        catch { self.error = error.localizedDescription }
    }
    func permitDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = UIL10n.text("저장하지 않은 변경사항이 있습니다.")
        alert.informativeText = UIL10n.text("먼저 저장하거나 변경사항을 버릴 수 있습니다.")
        alert.addButton(withTitle: UIL10n.text("저장")); alert.addButton(withTitle: UIL10n.text("취소")); alert.addButton(withTitle: UIL10n.text("버리기"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !dirty
        case .alertThirdButtonReturn: recoveryTask?.cancel(); clearOwnRecovery(); return true
        default: return false
        }
    }
    func newProject() {
        guard !busyDocument, permitDiscard() else { return }
        recoveryTask?.cancel(); stopAudition(); resetProductivityState()
        history = EditorHistory(project: Project()); diskRevision = nil; documentURL = nil; mediaBaseURL = nil; savedData = projectData(); selectedClipID = nil; selectedClipIDs = []; playhead = 0; rebuild()
    }
    /// Opens a restored project as a NEW unsaved document (never over an existing file). Relative
    /// media paths resolve against `baseURL`, the document's original location.
    func openRestored(_ project: Project, baseURL: URL, note: String) {
        guard !busyDocument, permitDiscard() else { return }
        recoveryTask?.cancel(); stopAudition(); resetProductivityState()
        history = EditorHistory(project: project); diskRevision = nil; documentURL = nil; mediaBaseURL = baseURL
        selectedClipID = nil; selectedClipIDs = []; playhead = 0; savedData = nil
        error = nil; message = note; if !restoreBundledLibraryMedia() { rebuild() }
    }
    func openProject() {
        guard !busyDocument else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jhcut") ?? .json]
        panel.title = UIL10n.text("프로젝트 열기…"); panel.prompt = UIL10n.text("열기")
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        guard !busyDocument, permitDiscard() else { return }
        do {
            let value = try ProjectStore.load(from: url)
            recoveryTask?.cancel(); stopAudition(); resetProductivityState()
            history = EditorHistory(project: value); diskRevision = try Data(contentsOf: url); documentURL = url; mediaBaseURL = url; selectedClipID = nil; selectedClipIDs = []; playhead = 0
            savedData = projectData(); message = UIL10n.format("ui.opened.file", url.lastPathComponent)
            if !restoreBundledLibraryMedia() { rebuild() }
        } catch {
            self.error = error.localizedDescription
            if FileManager.default.fileExists(atPath: ProjectStore.backupURL(for: url).path) {
                let alert = NSAlert(); alert.messageText = UIL10n.text("프로젝트를 열지 못했습니다. 이전 저장본을 복구할까요?")
                alert.informativeText = error.localizedDescription + UIL10n.text("\n원본과 백업은 그대로 보존하며, 복구 후 다른 이름으로 저장합니다.")
                alert.addButton(withTitle: UIL10n.text("백업 복구")); alert.addButton(withTitle: UIL10n.text("취소"))
                if alert.runModal() == .alertFirstButtonReturn {
                    do {
                        let recovered = try ProjectStore.recover(from: url)
                        recoveryTask?.cancel(); stopAudition(); resetProductivityState()
                        history = EditorHistory(project: recovered); diskRevision = nil; documentURL = nil; mediaBaseURL = url
                        selectedClipID = nil; selectedClipIDs = []; playhead = 0; savedData = nil
                        self.error = nil; message = "백업 복구됨 · 다른 이름으로 저장하세요."; if !restoreBundledLibraryMedia() { rebuild() }
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
    func exportVideo() {
        guard plan != nil, !isBuilding, !isImporting, !productivityBusy, !proxyBusy else { return }
        let codec = exportCodec
        let panel = NSSavePanel(); panel.allowedContentTypes = codec == .proRes422 ? [.quickTimeMovie] : [.mpeg4Movie]
        panel.nameFieldStringValue = project.name + "." + codec.fileExtension
        panel.title = UIL10n.text("영상 출력…"); panel.prompt = UIL10n.text("출력")
        panel.message = "\(project.sequence.width) × \(project.sequence.height) · \(frameRate.label) fps · \(codec.label)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.path) || exportQueue.contains(where: { $0.url == url }) { error = UIL10n.text("기존 파일 또는 대기 중인 출력과 다른 이름을 선택하세요."); return }
        do {
            guard loopStart.isFinite, loopEnd.isFinite, abs(loopStart) < 864000, abs(loopEnd) < 864000 else { throw ProjectError("출력 구간 시간을 확인하세요.") }
            let snapshot = exportRangeEnabled ? try TimelineRange.project(project, start: MediaTime(seconds: loopStart), end: MediaTime(seconds: loopEnd)) : project
            exportQueue.append(QueuedExport(project: snapshot, baseURL: mediaBaseURL, url: url, codec: codec, bitRate: outputBitRate, captionScope: currentCaptionScope, sidecarSRT: exportSidecarSRT, subtitleRepresentation: subtitleExportScope))
            startNextExport()
        } catch { self.error = error.localizedDescription }
    }
    func cancelExport() { exportJob?.cancel(); exportTask?.cancel() }

    func selectClip(_ id: UUID, extend: Bool = false) {
        if extend { if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) } }
        else { selectedClipIDs = [id] }
        selectedClipID = selectedClipIDs.contains(id) ? id : selectedClipIDs.first
    }
    func duplicateSelection() {
        guard let (track, clip) = selected else { return }
        perform(.duplicate(trackID: track.id, clipID: clip.id))
    }
    func stopAudition() {
        auditionTask?.cancel(); auditionPlayer?.stop(); auditionPlayer = nil; auditionID = nil
    }
    func audition(_ item: LibraryAsset) {
        guard !isExporting, let library = bundledLibrary else { return }
        if auditionID == item.id { stopAudition(); return }
        stopAudition(); player.pause(); playing = false
        do {
            let audio = try AVAudioPlayer(contentsOf: library.url(for: item)); audio.volume = item.category == .music ? 0.35 : 0.55
            guard audio.prepareToPlay(), audio.play() else { throw ProjectError("이 소스를 미리 들을 수 없습니다.") }
            auditionPlayer = audio; auditionID = item.id
            auditionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(audio.duration, 600) * 1_000_000_000))
                guard !Task.isCancelled, self?.auditionID == item.id else { return }; self?.stopAudition()
            }
        } catch { self.error = error.localizedDescription }
    }
    func insertLibraryAsset(_ item: LibraryAsset) {
        guard !busyDocument, let library = bundledLibrary else { return }
        stopAudition()
        let url = library.url(for: item), insertion = MediaTime(seconds: playhead)
        let ticket = beginAsyncJob(.importing)
        importTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                let identity = try await EditorSourceIdentity.capture(url)
                guard identity.sha256.lowercased() == item.sha256.lowercased() else { throw ProjectError("소재 파일이 목록의 검증값과 다릅니다. 추가하지 않았습니다.") }
                let retainedURL = try await libraryMediaStore.retain(source: url, item: item)
                let retainedIdentity = try await EditorSourceIdentity.capture(retainedURL)
                guard retainedIdentity.sha256 == identity.sha256 else { throw ProjectError("보관한 소재 파일이 원본과 다릅니다.") }
                var asset = try await MediaImporter.inspect(url: retainedURL)
                try await checkpointAsyncJob(ticket, "library.beforeApply")
                try await identity.validate()
                try await retainedIdentity.validate()
                try validateAsyncJob(ticket)
                guard asset.supported else { throw ProjectError(asset.issue ?? "지원하지 않는 소스입니다.") }
                asset.name = item.name; asset.contentHash = identity.sha256
                asset.provenance = AssetProvenance(sourceURL: item.sourceURL, author: item.author, license: item.license, licenseURL: item.licenseURL, sha256: item.sha256)
                let kind: TrackKind = asset.kind == .audio ? .audio : .overlay
                guard let track = writableTrack(kind) else { return }
                let available = max(frameRate.time(forFrame: 1), project.sequence.duration - insertion)
                let length = asset.kind == .image ? (project.sequence.duration > insertion ? min(available, MediaTime(5, 1)) : MediaTime(5, 1)) : (item.category == .music && project.sequence.duration > insertion ? min(asset.duration, available) : asset.duration)
                var clip = Clip(name: item.name, assetID: asset.id, start: insertion, duration: length, volume: item.category == .music ? 0.25 : 0.7)
                if item.category == .music { let fade = min(MediaTime(1, 1), MediaTime(seconds: length.seconds / 4)); clip.audioFadeIn = fade; clip.audioFadeOut = fade }
                if item.category == .overlay { clip.transform.scale = 0.75 }
                if item.tags.contains("픽셀 아트") { clip.transform.scale = 0.2 }
                if item.category == .background || item.category == .texture { clip.transform.fill = true }
                if perform(.batch([.addAsset(asset), .addClip(trackID: track.id, clip: clip)])) {
                    selectClip(clip.id); message = "\(item.name) 추가 · \(item.license) · \(item.author)"
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "소재 추가 취소됨 · 프로젝트는 바뀌지 않았습니다." }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func applyTitlePreset(_ preset: TitlePreset, toAll: Bool) {
        var commands: [EditCommand] = []; var newSelection: UUID?
        let allowed = Set(CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true).map { $0.clip.id })
        for track in project.sequence.tracks where track.kind == .title && !track.isLocked && !track.isHidden {
            for existing in track.clips where existing.captionHidden != true && (toAll ? allowed.contains(existing.id) : selectedClipIDs.contains(existing.id) || selectedClipID == existing.id) {
                var clip = existing; var title = TitleSizing.title(for: preset, width: project.sequence.width, height: project.sequence.height); title.text = existing.title?.text ?? title.text; clip.title = title
                commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        if commands.isEmpty && !toAll, let track = writableTrack(.title) {
            var title = TitleSizing.title(for: preset, width: project.sequence.width, height: project.sequence.height); title.text = "종현의 첫 영상"
            var clip = Clip(name: preset.name, start: MediaTime(seconds: playhead), duration: MediaTime(3, 1), title: title)
            clip.captionRole = .title
            commands.append(.addClip(trackID: track.id, clip: clip)); newSelection = clip.id
        }
        if !commands.isEmpty, perform(.batch(commands)), let id = newSelection { selectClip(id) }
    }
    private static var presetsURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/title-presets.json") }
    func saveCurrentTitlePreset() {
        guard let title = selected?.1.title else { return }
        let alert = NSAlert(); alert.messageText = "나만의 자막 스타일 저장"
        let field = NSTextField(string: "내 스타일 \(userTitlePresets.count + 1)"); field.frame = NSRect(x: 0, y: 0, width: 260, height: 25); alert.accessoryView = field
        alert.addButton(withTitle: UIL10n.text("저장")); alert.addButton(withTitle: UIL10n.text("취소"))
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var saved = title; saved.text = "종현의 이야기"
        var preset = TitlePreset(id: UUID().uuidString, name: field.stringValue, category: "내 스타일", title: saved)
        preset.referenceShortEdge = Double(min(project.sequence.width, project.sequence.height))
        do { let next = userTitlePresets + [preset]; try FileManager.default.createDirectory(at: Self.presetsURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(next).write(to: Self.presetsURL, options: .atomic); userTitlePresets = next }
        catch { self.error = error.localizedDescription }
    }
    func importSRT(from sourceURL: URL? = nil) {
        guard !busyDocument else { return }
        let url: URL
        if let sourceURL { url = sourceURL }
        else {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
            guard panel.runModal() == .OK, let selected = panel.url else { return }; url = selected
        }
        do {
            let cues = try SRTCodec.parse(SubtitleTextDecoder.decode(Data(contentsOf: url)))
            let style = selected?.1.title ?? TitleSizing.title(for: TitlePreset.builtIns[0], width: project.sequence.width, height: project.sequence.height)
            let group = UUID()
            let clips: [Clip] = cues.map { cue in
                var title = style; title.text = cue.text
                var clip = Clip(name: "자막", start: cue.start, duration: cue.duration, title: title)
                clip.captionRole = .original; clip.captionGroupID = group
                return clip
            }
            guard !clips.isEmpty else { throw ProjectError("SRT에 자막이 없습니다.") }
            let track = Track(name: "SRT 원문 · " + url.deletingPathExtension().lastPathComponent, kind: .title, clips: clips)
            if perform(.addTrack(track)) { message = "SRT 자막 \(cues.count)개 추가 · 별도 원문 그룹 · ⌘Z로 한 번에 되돌리기" }
        } catch { self.error = error.localizedDescription }
    }
    func exportSRT() {
        guard !exportableCaptionClips.isEmpty else { error = "선택한 언어 범위에 자막이 없습니다."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]; panel.nameFieldStringValue = project.name + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let cues = exportableCaptionClips.map { CaptionCue(id: $0.id, start: $0.start, duration: $0.duration, text: $0.title?.text ?? "") }
            try SRTCodec.serialize(cues).write(to: url, atomically: true, encoding: .utf8)
            message = "SRT 저장됨 · 스타일은 프로젝트 문서에 별도로 보존됩니다."
        } catch { self.error = error.localizedDescription }
    }
    /// Applies a new canvas and/or frame rate to the active sequence. Clip times are rational, so they
    /// survive a rate change unchanged; only the snapping grid the UI offers moves.
    func setFormat(width: Int, height: Int, frameRate newRate: FrameRate) {
        guard !busyDocument else { return }
        var sequence = project.sequence
        let oldEdge = min(sequence.width, sequence.height)
        for ti in sequence.tracks.indices {
            for ci in sequence.tracks[ti].clips.indices {
                if let title = sequence.tracks[ti].clips[ci].title {
                    sequence.tracks[ti].clips[ci].title = TitleSizing.resized(title, from: oldEdge, to: min(width, height))
                }
            }
        }
        sequence.width = width; sequence.height = height; sequence.frameRate = newRate
        guard perform(.replaceSequence(sequence)) else { return }
        outputBitRate = ExportJob.recommendedBitRate(width: width, height: height, fps: newRate.fps,
                                                     quality: outputQuality)
        message = "\(width) × \(height) · \(newRate.label) fps"
    }

    func derive(width: Int, height: Int, name: String) {
        perform(.deriveSequence(name: name, width: width, height: height)); selectedClipID = nil; selectedClipIDs = []; seek(0)
    }
    func relink(_ original: MediaAsset) {
        guard !busyDocument else { return }
        let panel = NSOpenPanel(); panel.message = UIL10n.format("ui.relink.choose", original.name)
        panel.title = UIL10n.text("미디어 재연결…"); panel.prompt = UIL10n.text("재연결")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ticket = beginAsyncJob(.importing)
        importTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                let identity = try await EditorSourceIdentity.capture(url)
                var replacement = try await MediaImporter.inspect(url: url)
                guard replacement.kind == original.kind, replacement.supported else { throw ProjectError(UIL10n.text("원본과 같은 종류의 지원 미디어를 선택하세요.")) }
                replacement.contentHash = identity.sha256
                try validateAsyncJob(ticket)
                let expected = original.contentHash ?? original.provenance?.sha256
                if expected == nil || expected != replacement.contentHash {
                    let alert = NSAlert(); alert.messageText = expected == nil ? UIL10n.text("동일한 원본인지 확인할 정보가 없습니다.") : UIL10n.text("기존 원본과 내용이 다른 파일입니다.")
                    alert.informativeText = UIL10n.format("ui.relink.confirm", original.name, replacement.name, original.duration.seconds, replacement.duration.seconds)
                    alert.addButton(withTitle: UIL10n.text("다른 원본으로 교체")); alert.addButton(withTitle: UIL10n.text("취소"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                replacement.id = original.id; replacement.relativePath = nil
                if let provenance = original.provenance, !provenance.sha256.isEmpty {
                    let fingerprint = try await Task.detached { try Self.fileSHA256(url) }.value
                    if fingerprint == provenance.sha256.lowercased() { replacement.provenance = provenance }
                }
                try await checkpointAsyncJob(ticket, "relink.beforeApply")
                try await identity.validate(); try validateAsyncJob(ticket)
                proxyURLs[original.id] = nil
                if perform(.replaceAsset(replacement)), original.provenance != nil, replacement.provenance == nil {
                    message = "다른 파일로 재연결됨 · 이전 소재의 라이선스 표시는 제거했습니다."
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "재연결 취소됨" } else { self.error = error.localizedDescription }
            }
        }
    }
    nonisolated private static func fileSHA256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func clearOwnRecovery() {
        do { try recoveryStore.clear(projectID: project.id); recoveryStatus = UIL10n.text("문서에 저장됨 · 이 프로젝트의 복구본 정리 완료") }
        catch { recoveryStatus = UIL10n.format("ui.recovery.cleanup.failure", error.localizedDescription) }
    }
    func scheduleRecovery() {
        recoveryTask?.cancel()
        guard dirty else { clearOwnRecovery(); return }
        let snapshot = project, document = documentURL, base = mediaBaseURL
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            do { try self.recoveryStore.save(project: snapshot, documentURL: document, mediaBaseURL: base); self.recoveryStatus = UIL10n.format("ui.recovery.autosaved", Date().formatted(.dateTime.hour().minute().locale(Locale(identifier: UIL10n.language())))) }
            catch { self.recoveryStatus = UIL10n.format("ui.recovery.save.failure", error.localizedDescription) }
        }
    }
    /// The picker has already obtained discard permission. Validate before cancelling current work.
    func applyRecoverySnapshot(_ recovered: RecoverySnapshot) throws {
        guard !isExporting, !isImporting else { throw ProjectError(UIL10n.text("출력 또는 가져오기를 마친 뒤 복구본을 여세요.")) }
        try ProjectValidator.validate(recovered.project)
        recoveryTask?.cancel(); stopAudition(); resetProductivityState()
        // Recovery opens a distinct unsaved copy, as promised by the picker. The snapshot's
        // original URL is a media-resolution base only, never an implicit save destination.
        history = EditorHistory(project: recovered.project); documentURL = nil; diskRevision = nil
        mediaBaseURL = recovered.mediaBaseURL ?? recovered.documentURL
        savedData = nil; selectedClipID = nil; selectedClipIDs = []; playhead = 0; error = nil
        message = UIL10n.text("복구본을 새 문서로 열었습니다. 원본은 보존됩니다. 다른 이름으로 저장하세요.")
        recoveryStatus = message
        if !restoreBundledLibraryMedia() { rebuild() }
    }
    func checkRecoveryOnLaunch() { guard !offeredRecovery else { return }; offeredRecovery = true; offerRecovery(onlyIfExists: true) }
    func offerRecovery(onlyIfExists: Bool = false) {
        guard !isExporting, !isImporting else { return }
        do {
            let snapshots = try recoveryStore.availableSnapshots()
            guard !snapshots.isEmpty else { if !onlyIfExists { message = UIL10n.text("저장된 복구본이 없습니다.") }; return }
            let alert = NSAlert(); alert.messageText = UIL10n.text("저장되지 않은 작업 복구")
            alert.informativeText = UIL10n.text("복구할 프로젝트를 선택하세요. 문서 원본을 덮어쓰지 않고 복구본을 엽니다.")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
            for item in snapshots { picker.addItem(withTitle: item.project.name + " · " + item.savedAt.formatted()) }
            alert.accessoryView = picker
            alert.addButton(withTitle: UIL10n.text("복구본 열기")); alert.addButton(withTitle: UIL10n.text("나중에"))
            guard alert.runModal() == .alertFirstButtonReturn, permitDiscard() else { return }
            let recovered = snapshots[max(0, picker.indexOfSelectedItem)]
            try applyRecoverySnapshot(recovered)
        } catch { self.error = UIL10n.format("ui.recovery.read.failure", error.localizedDescription) }
    }
}

struct EditorAsyncContext {
    let revision: UInt64
    let project: Project
    let base: URL?
    let document: URL?
}
enum EditorAsyncKind { case productivity, importing, proxy }
struct EditorAsyncTicket {
    let id: UUID
    let kind: EditorAsyncKind
    let context: EditorAsyncContext
}
/// Full digest around awaited work; stat is the inexpensive freshness gate in the audio panel.
extension EditorModel {
    /// Migrate old bundled links without changing media content, clip timing, or the saved document.
    /// Missing items require exact provenance/content hashes; names never choose a replacement.
    @discardableResult func restoreBundledLibraryMedia() -> Bool {
        guard !isImporting, !isExporting else { return false }
        let library = bundledLibrary
        let candidates = project.assets.filter { asset in
            guard let provenance = asset.provenance, let digest = asset.contentHash,
                  digest.count == 64, digest.lowercased() == provenance.sha256.lowercased() else { return false }
            let url = asset.resolvedURL(relativeTo: mediaBaseURL)
            let bundled = url.path.contains(".app/Contents/Resources/Library/") || library.map { url.path.hasPrefix($0.rootURL.path + "/") } == true
            return bundled || !FileManager.default.fileExists(atPath: url.path)
        }
        guard !candidates.isEmpty else { return false }
        retireLiveEdit()
        pausePlayback()
        playbackObservation?.stop()
        buildTask?.cancel(); buildGeneration += 1; pendingSeek = nil
        plan = nil; player.replaceCurrentItem(with: nil); isBuilding = false
        let ticket = beginAsyncJob(.importing)
        message = "저장된 프로젝트의 소재 연결을 확인하는 중…"
        importTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                var commands: [EditCommand] = [], identities: [EditorSourceIdentity] = [], failures: [String] = []
                for asset in candidates {
                    try validateAsyncJob(ticket)
                    do {
                        let digest = asset.contentHash!
                        var originalIdentity: EditorSourceIdentity?
                        let originalURL = asset.resolvedURL(relativeTo: ticket.context.base)
                        if FileManager.default.fileExists(atPath: originalURL.path) {
                            let original = try await EditorSourceIdentity.capture(originalURL)
                            guard original.sha256 == digest.lowercased() else { throw ProjectError("저장 후 소재 내용이 바뀌었습니다. 연결된 원본을 확인하세요.") }
                            originalIdentity = original
                        }
                        var retained = try await libraryMediaStore.existing(sha256: digest, fileExtension: URL(fileURLWithPath: asset.path).pathExtension)
                        if retained == nil, let item = library?.asset(matchingSHA256: digest), let library {
                            retained = try await libraryMediaStore.retain(source: library.url(for: item), item: item)
                        }
                        guard let retained else { failures.append(asset.name + ": 같은 검증값의 소재가 없습니다."); continue }
                        let identity = try await EditorSourceIdentity.capture(retained)
                        guard identity.sha256 == digest.lowercased() else { throw ProjectError("보관한 소재 검증값이 다릅니다.") }
                        let inspected = try await MediaImporter.inspect(url: retained)
                        guard inspected.supported, inspected.kind == asset.kind else { throw ProjectError("보관한 소재 형식이 다릅니다.") }
                        var repaired = asset; repaired.path = retained.path; repaired.relativePath = nil; repaired.bookmark = inspected.bookmark
                        if repaired != asset {
                            commands.append(.replaceAsset(repaired)); identities.append(identity)
                            if let originalIdentity { identities.append(originalIdentity) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append(asset.name + ": " + error.localizedDescription) }
                }
                try await checkpointAsyncJob(ticket, "library.restore.beforeApply")
                for identity in identities { try await identity.validate(); try validateAsyncJob(ticket) }
                try validateAsyncJob(ticket)
                if !commands.isEmpty {
                    guard perform(.batch(commands)) else { return }
                    error = nil
                    message = "소재 \(commands.count)개의 연결을 안전하게 복구했습니다. 프로젝트를 저장하세요."
                } else { rebuild() }
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
            } catch {
                guard ownsAsyncJob(ticket), contextMatches(ticket.context) else { return }
                if Task.isCancelled { message = "소재 연결 복구 취소 · 저장된 문서는 보존했습니다." }
                else { self.error = error.localizedDescription }
                rebuild()
            }
        }
        return true
    }
}

struct EditorSourceIdentity {
    let url: URL
    let stamp: String
    let sha256: String
    static func capture(_ url: URL) async throws -> Self {
        let stamp = try MediaFingerprintCache.stat(url)
        let digest = try await FileIdentity.sha256(url)
        try Task.checkCancellation()
        guard try MediaFingerprintCache.stat(url) == stamp else { throw ProjectError("원본 파일이 바뀌었습니다. 다시 실행하세요.") }
        return Self(url: url, stamp: stamp, sha256: digest)
    }
    var statMatches: Bool { (try? MediaFingerprintCache.stat(url)) == stamp }
    func validate() async throws {
        guard statMatches else { throw ProjectError("작업 중 원본 파일이 바뀌어 결과를 적용하지 않았습니다.") }
        let current = try await Self.capture(url)
        guard current.stamp == stamp, current.sha256 == sha256 else { throw ProjectError("작업 중 원본 내용이 바뀌어 결과를 적용하지 않았습니다.") }
    }
}
extension EditorModel {
    func asyncContext() -> EditorAsyncContext {
        EditorAsyncContext(revision: asyncDocumentRevision, project: project, base: mediaBaseURL, document: documentURL)
    }
    func contextMatches(_ context: EditorAsyncContext) -> Bool {
        asyncDocumentRevision == context.revision && project == context.project && mediaBaseURL == context.base && documentURL == context.document
    }
    func beginAsyncJob(_ kind: EditorAsyncKind) -> EditorAsyncTicket {
        let ticket = EditorAsyncTicket(id: UUID(), kind: kind, context: asyncContext())
        switch kind {
        case .productivity: productivityJobID = ticket.id; productivityCancelRequested = false; productivityBusy = true
        case .importing: importJobID = ticket.id; importCancelRequested = false; isImporting = true
        case .proxy: proxyJobID = ticket.id; proxyCancelRequested = false; proxyBusy = true
        }
        return ticket
    }
    func ownsAsyncJob(_ ticket: EditorAsyncTicket) -> Bool {
        switch ticket.kind {
        case .productivity: return productivityJobID == ticket.id
        case .importing: return importJobID == ticket.id
        case .proxy: return proxyJobID == ticket.id
        }
    }
    func acceptsAsyncProgress(_ ticket: EditorAsyncTicket) -> Bool {
        let cancelled: Bool
        switch ticket.kind {
        case .productivity: cancelled = productivityCancelRequested || productivityTask?.isCancelled == true
        case .importing: cancelled = importCancelRequested || importTask?.isCancelled == true
        case .proxy: cancelled = proxyCancelRequested || proxyTask?.isCancelled == true
        }
        return ownsAsyncJob(ticket) && !cancelled && contextMatches(ticket.context)
    }
    func acceptProductivityProgress(_ text: String, ticket: EditorAsyncTicket) {
        asyncProgressHandled?(ticket.id)
        guard acceptsAsyncProgress(ticket) else { return }; productivityStatus = text
    }
    func validateAsyncJob(_ ticket: EditorAsyncTicket) throws {
        try Task.checkCancellation()
        guard ownsAsyncJob(ticket) else { throw CancellationError() }
        guard acceptsAsyncProgress(ticket) else { throw ProjectError("작업 중 프로젝트가 변경되었거나 문서 연결이 바뀌어 오래된 결과를 적용하지 않았습니다. 다시 실행하세요.") }
    }
    func checkpointAsyncJob(_ ticket: EditorAsyncTicket, _ stage: String) async throws {
        try validateAsyncJob(ticket)
        try await asyncJobBarrier?(stage)
        try validateAsyncJob(ticket)
    }
    func finishAsyncJob(_ ticket: EditorAsyncTicket) {
        guard ownsAsyncJob(ticket) else { return }
        switch ticket.kind {
        case .productivity: productivityJobID = nil; productivityBusy = false; productivityTask = nil
        case .importing: importJobID = nil; isImporting = false; importTask = nil
        case .proxy: proxyJobID = nil; proxyBusy = false; proxyTask = nil
        }
    }
    /// A document reset invalidates old closures before a later document can start another job.
    func invalidateAsyncJobs() {
        productivityTask?.cancel(); importTask?.cancel(); proxyTask?.cancel()
        generatedMediaScanTask?.cancel(); generatedMediaScanTask = nil; generatedMediaScanID = UUID()
        generatedMediaReport = nil; generatedMediaStatus = ""
        checkpointRefreshTask?.cancel(); checkpointRefreshID = UUID()
        productivityJobID = nil; importJobID = nil; proxyJobID = nil
        productivityTask = nil; importTask = nil; proxyTask = nil
        productivityBusy = false; isImporting = false; proxyBusy = false
        transcriptionJobID = nil; transcriptionAnalysisClipID = nil; transcriptionActive = false; transcriptionDetail = nil
        translationActive = false; evaluationJobID = nil; evaluationActive = false; evaluationProgress = nil
    }
}


extension EditorModel {
    // Shared by menu validation and the command itself, including zero-rate play requests.
    static func playbackObservationChangeRequiresPause(mode: PlaybackObservationMode, hasActiveAudioTaps: Bool,
                                                       playRequested: Bool, rate: Float,
                                                       timeControlStatus: AVPlayer.TimeControlStatus) -> Bool {
        let changesAudioGraph = mode == .trackPostEffects || hasActiveAudioTaps
        return changesAudioGraph && (playRequested || rate != 0 || timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }
    func playbackObservationChangeRequiresPause(mode: PlaybackObservationMode = .transport) -> Bool {
        Self.playbackObservationChangeRequiresPause(mode: mode, hasActiveAudioTaps: playbackObservation?.hasActiveAudioTaps ?? false,
                                                  playRequested: playing, rate: player.rate, timeControlStatus: player.timeControlStatus)
    }
    func startPlaybackObservation(mode: PlaybackObservationMode = .transport) {
        guard !playbackObservationChangeRequiresPause(mode: mode) else {
            error = "오디오 진단 모드를 바꾸려면 재생을 멈춘 뒤 다시 시작하세요."
            return
        }
        do {
            playbackObservation?.stop()
            playbackObservation = try PlaybackObservation(player: player, mode: mode)
            message = mode == .transport
                ? "재생 진단 중 · 화면과 재생 상태를 기록합니다. 오디오는 측정하지 않습니다."
                : "상세 오디오 진단 중 · 재생 시작이 늦어질 수 있습니다. 트랙별 오디오 처리량을 기록합니다."
        } catch { self.error = error.localizedDescription }
    }
    func savePlaybackObservation() {
        guard let observation = playbackObservation else { return }
        pausePlayback()
        do {
            _ = try observation.finish()
            message = "재생 진단 종료 · 기록을 로컬 파일로 저장하세요."
            let panel = NSSavePanel(); panel.nameFieldStringValue = "재생-진단.json"
            guard panel.runModal() == .OK, let url = panel.url else {
                message = "진단 저장 취소 · 기록은 보존했습니다. 타임라인 메뉴에서 다시 저장하세요."
                return
            }
            try observation.saveReport(to: url); playbackObservation = nil
            message = "재생 진단을 저장했습니다. 녹음이나 원본 영상은 포함하지 않습니다."
        } catch { self.error = error.localizedDescription }
    }
}

/// Diagnostics only: each rebuild owns a buffer; worker events are replayed on the model actor.
private final class RendererPhaseBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(name: String, time: TimeInterval)] = []
    func append(name: String, time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        events.append((name, time))
    }
    func drain() -> [(name: String, time: TimeInterval)] {
        lock.lock(); defer { lock.unlock() }
        let snapshot = events; events.removeAll(keepingCapacity: true)
        return snapshot
    }
}

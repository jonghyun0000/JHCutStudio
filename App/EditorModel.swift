import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import CryptoKit
import JHCutCore

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var seconds = 0.0
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var history = EditorHistory(project: Project()) {
        didSet { encodedProject = nil }
    }
    private var encodedProject: Data?
    @Published var selectedClipID: UUID?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedAssetID: UUID?
    @Published var documentURL: URL?
    // In-memory history retains the original document's relative reference base across Save As.
    @Published var mediaBaseURL: URL?
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
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let preview = try await LocalTranscription.previewChannel(url: source, sourceStart: clip.sourceStart, duration: min(clip.sourceDuration, MediaTime(10, 1)), channel: channel)
                try Task.checkCancellation()
                let audio = try AVAudioPlayer(data: preview.data)
                guard audio.prepareToPlay(), audio.play() else { throw ProjectError("대사 채널을 재생할 수 없습니다.") }
                auditionPlayer = audio; auditionID = "speech-channel"
                message = "대사 채널 \(preview.channel + 1) · 원본 시작 구간 미리듣기"
                auditionTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((audio.duration + 0.1) * 1_000_000_000))
                    guard !Task.isCancelled, self?.auditionID == "speech-channel" else { return }; self?.stopAudition()
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private var recoveryTask: Task<Void, Never>?
    private let recoveryStore: RecoveryStore
    private var offeredRecovery = false
    let player = AVPlayer()
    var plan: RenderPlan?
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0
    var exportJob: ExportJob?
    var exportTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var productivityTask: Task<Void, Never>?
    var proxyTask: Task<Void, Never>?
    let proxyCache = ProxyCache()
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
    @Published var translationGlossaryText = ""
    /// TranslationStyle raw value applied to new translations.
    @Published var translationStyle = TranslationStyle.natural.rawValue
    @Published var translationActive = false
    @Published var detectedSpeechLanguages = ""
    @Published var subtitleExportScope = "visible"
    var translationProvider: @MainActor ([String], String, String) async throws -> [String] = { texts, source, target in
        try await CaptionTranslation.translate(texts, from: source, to: target)
    }

    @Published var replaceAutomaticCaptions = true
    /// Long recognition keeps each finished 5-minute window on disk so a cancel or quit resumes.
    @Published var useSpeechCheckpoints = true
    /// Voice-activity analysis: silence, music and strong noise longer than 3 s are not sent to Whisper.
    @Published var skipNonSpeech = true
    /// Captions found over silence/music/noise by the last voice-activity check (not saved in the document).
    @Published var silentCaptionWarnings: [UUID: VoiceActivityKind] = [:]
    /// Captions kept from a collapsed Whisper repetition loop; the user should check them (not saved).
    @Published var repetitionCaptionIDs: Set<UUID> = []
    @Published var lastVoiceActivity: VoiceActivityReport?
    /// In-memory analysis cache: "<file digest or path>|<start>|<duration>".
    var voiceActivityCache: [String: VoiceActivityReport] = [:]
    @Published var transcriptionDetail: TranscriptionProgress?
    var checkpointWriteFailed = false
    @Published var lastEvaluation: TranscriptEvaluationReport?
    @Published var speakerStatus = ""
    @Published var lastEvaluationReportURL: URL?
    var reportsDirectory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio/Reports", isDirectory: true)
    @Published var checkpointSummaries: [TranscriptionCheckpointSummary] = []
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
    var backupRoot = ProjectBackup.defaultRoot
    @Published var exportQualityStatus = ""
    @Published var lastQualityReport: OutputQualityReport?
    @Published var lastQualityReportURL: URL?
    var lastExportedRequest: QueuedExport?
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
    var captionClips: [Clip] { project.sequence.tracks.filter { $0.kind == .title }.flatMap(\.clips).sorted { $0.start < $1.start } }
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
    init(recoveryStore: RecoveryStore = RecoveryStore(), exportHistoryURL: URL? = nil) {
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
        buildTask?.cancel(); recoveryTask?.cancel(); auditionTask?.cancel()
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
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { error = "이동 시간을 유효한 숫자로 입력하세요."; return }
        let time = snapped(seconds)
        playhead = time.seconds
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlay() {
        // Pausing always wins, including while the item is waiting for data or rebuilding. The
        // committed HEAD version checked `isBuilding`/`isExporting` before this and used a bare
        // `player.rate != 0` test, so a click during a rebuild, or during the brief rate==0 window
        // AVPlayer reports while buffering mid-playback, silently did nothing or replayed instead of
        // pausing — exactly the "pause button doesn't stop the video" report.
        if playing || player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            pausePlayback(); return
        }
        guard !isBuilding, !isExporting, plan != nil else { return }
        if loopEnabled, validLoopRange == nil { error = "반복 구간의 시작·끝을 영상 길이 안에서 지정하세요."; return }
        stopAudition()
        if playhead >= project.sequence.duration.seconds - frameStep { seek(0) }
        playing = true
        player.play()
    }
    func pausePlayback() {
        player.pause()
        playing = false
        let seconds = player.currentTime().seconds
        if seconds.isFinite { playhead = max(0, min(project.sequence.duration.seconds, seconds)) }
    }
    func rebuild() {
        buildTask?.cancel(); buildGeneration += 1
        // A committed build is authoritative, so any gesture still previewing is retired first.
        retireLiveEdit()
        let generation = buildGeneration
        player.pause(); playing = false; plan = nil; player.replaceCurrentItem(with: nil)
        guard project.sequence.duration > .zero else { isBuilding = false; return }
        isBuilding = true
        let snapshot = project, url = mediaBaseURL
        let overrides = proxyEnabled ? proxyURLs : [:]
        let cache = proxyCache
        buildTask = Task { [weak self] in
            do {
                var verified: [UUID: URL] = [:]
                for asset in snapshot.assets where overrides[asset.id] != nil {
                    if let cached = try await cache.cachedURL(for: asset.resolvedURL(relativeTo: url)), cached == overrides[asset.id] { verified[asset.id] = cached }
                }
                let result = try await TimelineRenderer.build(project: snapshot, documentURL: url, mediaURLOverrides: verified, cacheInspection: true)
                guard let self, !Task.isCancelled, self.buildGeneration == generation else { return }
                self.plan = result; self.player.replaceCurrentItem(with: result.makePlayerItem())
                self.isBuilding = false; self.seek(self.playhead)
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
        panel.allowedContentTypes = [.movie, .audio, .png, .jpeg, .heic]
        panel.message = "로컬 SDR H.264·HEVC·ProRes, PNG·JPEG·HEIC, 오디오를 가져옵니다. 원본은 변경하지 않습니다."
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    func importFiles(_ urls: [URL]) {
        guard !busyDocument else { return }
        let captionOnImport = autoCaptionImportedVideos, importedInto = project.id
        isImporting = true; importProgress = 0
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            var failures: [String] = []; var assets: [MediaAsset] = []
            do {
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    do {
                        var asset = try await MediaImporter.inspect(url: url)
                        asset.contentHash = try await FileIdentity.sha256(url)
                        assets.append(asset)
                        if !asset.supported { failures.append("\(asset.name): \(asset.issue ?? "지원하지 않는 미디어")") }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    importProgress = Double(index + 1) / Double(max(1, urls.count))
                }
                try Task.checkCancellation()
                guard project.id == importedInto else { throw CancellationError() }
                guard !assets.isEmpty else { error = failures.joined(separator: "\n"); message = "가져올 수 있는 미디어가 없습니다."; return }
                guard perform(.batch(assets.map { .addAsset($0) })) else { return }
                selectedAssetID = assets.last?.id

                message = "미디어 \(assets.count)개 가져옴 · 한 번의 실행취소로 되돌릴 수 있습니다."
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
                if captionOnImport {
                    isImporting = false
                    captionImportedVideos(assets.filter { $0.kind == .video && $0.supported && $0.hasAudio })
                }
            } catch { message = "가져오기 취소됨 · 프로젝트에 추가하지 않았습니다." }
        }
    }
    func cancelImport() { importTask?.cancel() }
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
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard let destination else { return }
        do {
            if destination == documentURL, let diskRevision,
               (try? Data(contentsOf: destination)) != diskRevision {
                error = "다른 프로그램에서 프로젝트 파일을 변경했습니다. 현재 편집을 ‘다른 이름으로 저장’하여 두 버전을 보존하세요."; return
            }
            try ProjectStore.save(project, to: destination); documentURL = destination; savedData = projectData()
            diskRevision = try Data(contentsOf: destination)
            recoveryTask?.cancel(); clearOwnRecovery()
            message = "저장됨 · \(destination.lastPathComponent)"
        }
        catch { self.error = error.localizedDescription }
    }
    func permitDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "저장하지 않은 변경사항이 있습니다."
        alert.informativeText = "먼저 저장하거나 변경사항을 버릴 수 있습니다."
        alert.addButton(withTitle: "저장"); alert.addButton(withTitle: "취소"); alert.addButton(withTitle: "버리기")
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
        error = nil; message = note; rebuild()
    }
    func openProject() {
        guard !busyDocument else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jhcut") ?? .json]
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        guard !busyDocument, permitDiscard() else { return }
        do {
            let value = try ProjectStore.load(from: url)
            recoveryTask?.cancel(); stopAudition(); resetProductivityState()
            history = EditorHistory(project: value); diskRevision = try Data(contentsOf: url); documentURL = url; mediaBaseURL = url; selectedClipID = nil; selectedClipIDs = []; playhead = 0
            savedData = projectData(); message = "프로젝트 열림 · " + url.lastPathComponent; rebuild()
        } catch {
            self.error = error.localizedDescription
            if FileManager.default.fileExists(atPath: ProjectStore.backupURL(for: url).path) {
                let alert = NSAlert(); alert.messageText = "프로젝트를 열지 못했습니다. 이전 저장본을 복구할까요?"
                alert.informativeText = error.localizedDescription + "\n원본과 백업은 그대로 보존하며, 복구 후 다른 이름으로 저장합니다."
                alert.addButton(withTitle: "백업 복구"); alert.addButton(withTitle: "취소")
                if alert.runModal() == .alertFirstButtonReturn {
                    do {
                        let recovered = try ProjectStore.recover(from: url)
                        recoveryTask?.cancel(); stopAudition(); resetProductivityState()
                        history = EditorHistory(project: recovered); documentURL = nil; mediaBaseURL = url
                        selectedClipID = nil; selectedClipIDs = []; playhead = 0; savedData = nil
                        self.error = nil; message = "백업 복구됨 · 다른 이름으로 저장하세요."; rebuild()
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
        panel.message = "\(project.sequence.width) × \(project.sequence.height) · \(frameRate.label) fps · \(codec.label)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.path) || exportQueue.contains(where: { $0.url == url }) { error = "기존 파일 또는 대기 중인 출력과 다른 이름을 선택하세요."; return }
        do {
            guard loopStart.isFinite, loopEnd.isFinite, abs(loopStart) < 864000, abs(loopEnd) < 864000 else { throw ProjectError("출력 구간 시간을 확인하세요.") }
            let snapshot = exportRangeEnabled ? try TimelineRange.project(project, start: MediaTime(seconds: loopStart), end: MediaTime(seconds: loopEnd)) : project
            exportQueue.append(QueuedExport(project: snapshot, baseURL: mediaBaseURL, url: url, codec: codec, bitRate: outputBitRate))
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
        guard !isExporting, !isImporting, let library = bundledLibrary else { return }
        stopAudition(); isImporting = true
        let url = library.url(for: item), insertion = MediaTime(seconds: playhead)
        Task {
            defer { isImporting = false }
            do {
                var asset = try await MediaImporter.inspect(url: url)
                guard asset.supported else { throw ProjectError(asset.issue ?? "지원하지 않는 소스입니다.") }
                asset.name = item.name
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
            } catch { self.error = error.localizedDescription }
        }
    }
    func applyTitlePreset(_ preset: TitlePreset, toAll: Bool) {
        var commands: [EditCommand] = []; var newSelection: UUID?
        for track in project.sequence.tracks where track.kind == .title {
            for existing in track.clips where toAll || selectedClipIDs.contains(existing.id) || selectedClipID == existing.id {
                var clip = existing; var title = TitleSizing.title(for: preset, width: project.sequence.width, height: project.sequence.height); title.text = existing.title?.text ?? title.text; clip.title = title
                commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        if commands.isEmpty && !toAll, let track = writableTrack(.title) {
            var title = TitleSizing.title(for: preset, width: project.sequence.width, height: project.sequence.height); title.text = "종현의 첫 영상"
            let clip = Clip(name: preset.name, start: MediaTime(seconds: playhead), duration: MediaTime(3, 1), title: title)
            commands.append(.addClip(trackID: track.id, clip: clip)); newSelection = clip.id
        }
        if !commands.isEmpty, perform(.batch(commands)), let id = newSelection { selectClip(id) }
    }
    private static var presetsURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/title-presets.json") }
    func saveCurrentTitlePreset() {
        guard let title = selected?.1.title else { return }
        let alert = NSAlert(); alert.messageText = "나만의 자막 스타일 저장"
        let field = NSTextField(string: "내 스타일 \(userTitlePresets.count + 1)"); field.frame = NSRect(x: 0, y: 0, width: 260, height: 25); alert.accessoryView = field
        alert.addButton(withTitle: "저장"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var saved = title; saved.text = "종현의 이야기"
        var preset = TitlePreset(id: UUID().uuidString, name: field.stringValue, category: "내 스타일", title: saved)
        preset.referenceShortEdge = Double(min(project.sequence.width, project.sequence.height))
        do { let next = userTitlePresets + [preset]; try FileManager.default.createDirectory(at: Self.presetsURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(next).write(to: Self.presetsURL, options: .atomic); userTitlePresets = next }
        catch { self.error = error.localizedDescription }
    }
    func importSRT() {
        guard !isExporting, !isImporting else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let track = writableTrack(.title) else { return }
        do {
            let cues = try SRTCodec.parse(SubtitleTextDecoder.decode(Data(contentsOf: url)))
            let style = selected?.1.title ?? TitleSizing.title(for: TitlePreset.builtIns[0], width: project.sequence.width, height: project.sequence.height)
            let commands: [EditCommand] = cues.map { cue in var title = style; title.text = cue.text; return .addClip(trackID: track.id, clip: Clip(name: "자막", start: cue.start, duration: cue.duration, title: title)) }
            if perform(.batch(commands)) { message = "SRT 자막 \(cues.count)개 추가 · 기존 영상 유지" }
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
        let panel = NSOpenPanel(); panel.message = "\(original.name)의 새 위치를 선택하세요. 사용 중인 소스 범위가 유효해야 합니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                var replacement = try await MediaImporter.inspect(url: url)
                guard replacement.kind == original.kind, replacement.supported else { throw ProjectError("원본과 같은 종류의 지원 미디어를 선택하세요.") }
                replacement.contentHash = try await FileIdentity.sha256(url)
                let expected = original.contentHash ?? original.provenance?.sha256
                if expected == nil || expected != replacement.contentHash {
                    let alert = NSAlert(); alert.messageText = expected == nil ? "동일한 원본인지 확인할 정보가 없습니다." : "기존 원본과 내용이 다른 파일입니다."
                    alert.informativeText = "\(original.name) → \(replacement.name)\n길이 \(String(format: "%.2f", original.duration.seconds))초 → \(String(format: "%.2f", replacement.duration.seconds))초\n새 파일로 교체할까요?"
                    alert.addButton(withTitle: "다른 원본으로 교체"); alert.addButton(withTitle: "취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                replacement.id = original.id; replacement.relativePath = nil
                if let provenance = original.provenance, !provenance.sha256.isEmpty {
                    let fingerprint = try await Task.detached { try Self.fileSHA256(url) }.value
                    if fingerprint == provenance.sha256.lowercased() { replacement.provenance = provenance }
                }
                proxyURLs[original.id] = nil
                if perform(.replaceAsset(replacement)), original.provenance != nil, replacement.provenance == nil {
                    message = "다른 파일로 재연결됨 · 이전 소재의 라이선스 표시는 제거했습니다."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    nonisolated private static func fileSHA256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func clearOwnRecovery() {
        do { try recoveryStore.clear(projectID: project.id); recoveryStatus = "문서에 저장됨 · 이 프로젝트의 복구본 정리 완료" }
        catch { recoveryStatus = "복구본 정리 실패: " + error.localizedDescription }
    }
    func scheduleRecovery() {
        recoveryTask?.cancel()
        guard dirty else { clearOwnRecovery(); return }
        let snapshot = project, document = documentURL, base = mediaBaseURL
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            do { try self.recoveryStore.save(project: snapshot, documentURL: document, mediaBaseURL: base); self.recoveryStatus = "복구본 자동 저장됨 · " + Date().formatted(date: .omitted, time: .shortened) }
            catch { self.recoveryStatus = "복구본 저장 실패: " + error.localizedDescription }
        }
    }
    func checkRecoveryOnLaunch() { guard !offeredRecovery else { return }; offeredRecovery = true; offerRecovery(onlyIfExists: true) }
    func offerRecovery(onlyIfExists: Bool = false) {
        guard !isExporting, !isImporting else { return }
        do {
            let snapshots = try recoveryStore.availableSnapshots()
            guard !snapshots.isEmpty else { if !onlyIfExists { message = "저장된 복구본이 없습니다." }; return }
            let alert = NSAlert(); alert.messageText = "저장되지 않은 작업 복구"
            alert.informativeText = "복구할 프로젝트를 선택하세요. 문서 원본을 덮어쓰지 않고 복구본을 엽니다."
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
            for item in snapshots { picker.addItem(withTitle: item.project.name + " · " + item.savedAt.formatted()) }
            alert.accessoryView = picker
            alert.addButton(withTitle: "복구본 열기"); alert.addButton(withTitle: "나중에")
            guard alert.runModal() == .alertFirstButtonReturn, permitDiscard() else { return }
            let recovered = snapshots[max(0, picker.indexOfSelectedItem)]
            recoveryTask?.cancel(); stopAudition(); history = EditorHistory(project: recovered.project); documentURL = recovered.documentURL; mediaBaseURL = recovered.mediaBaseURL
            savedData = nil; selectedClipID = nil; selectedClipIDs = []; playhead = 0; rebuild(); recoveryStatus = "복구본을 열었습니다. 확인 후 문서에 저장하세요."
        } catch { self.error = "복구본을 읽을 수 없습니다: " + error.localizedDescription }
    }
}

import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import CryptoKit
import JHCutCore

@MainActor
final class EditorModel: ObservableObject {
    @Published var history = EditorHistory(project: Project())
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
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var zoom = 48.0
    @Published var libraryVisible = true
    @Published var inspectorVisible = true
    @Published var savedData: Data?
    @Published var snappingEnabled = true
    @Published var bundledLibrary: AssetLibrary?
    @Published var auditionID: String?
    @Published var userTitlePresets: [TitlePreset] = []
    @Published var recoveryStatus = "변경사항을 로컬 복구본에 자동 저장합니다."
    private var auditionPlayer: AVAudioPlayer?
    private var auditionTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private let recoveryStore: RecoveryStore
    private var offeredRecovery = false
    let player = AVPlayer()
    var plan: RenderPlan?
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0
    private var exportJob: ExportJob?
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
    @Published var transcriptionReady = false
    @Published var transcriptionStatus = "모델 설치 상태 확인 중"
    @Published var timelineScrollY = 0.0
    @Published var safeAreaVisible = false
    @Published var outputBitRate = 8_000_000
    var busyDocument: Bool { isExporting || isImporting || productivityBusy || proxyBusy }

    private var observer: Any?
    private var keyMonitor: Any?
    private var menuTrackingCount = 0
    private var menuObservers: [NSObjectProtocol] = []
    var project: Project { history.project }
    var captionClips: [Clip] { project.sequence.tracks.filter { $0.kind == .title }.flatMap(\.clips).sorted { $0.start < $1.start } }
    var allTitlePresets: [TitlePreset] { userTitlePresets + TitlePreset.builtIns }
    private func projectData() -> Data? { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try? encoder.encode(project) }
    var dirty: Bool { projectData() != savedData }
    var selected: (Track, Clip)? {
        for track in project.sequence.tracks {
            if let clip = track.clips.first(where: { $0.id == selectedClipID }) { return (track, clip) }
        }
        return nil
    }
    /// The recovery store is injectable so headless probes never write to the user's slot.
    init(recoveryStore: RecoveryStore = RecoveryStore()) {
        self.recoveryStore = recoveryStore
        savedData = projectData()
        bundledLibrary = try? AssetLibrary()
        if let data = try? Data(contentsOf: Self.presetsURL), let presets = try? JSONDecoder().decode([TitlePreset].self, from: data) { userTitlePresets = presets }
        refreshTranscriptionStatus()
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if self.player.rate != 0 { self.playhead = time.seconds }
                self.playing = self.player.rate != 0
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
                case 49: self.togglePlay(); return nil
                case 123: self.seek(self.playhead - 1.0 / 30); return nil
                case 124: self.seek(self.playhead + 1.0 / 30); return nil
                case 51, 117: self.remove(); return nil
                default: break
                }
            }
            return event
        }
    }
    @discardableResult func perform(_ command: EditCommand) -> Bool {
        guard !isExporting else { return false }
        do { try history.apply(command); message = "편집 적용됨"; scheduleRecovery(); rebuild(); return true } catch { self.error = error.localizedDescription; return false }
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
        playhead = max(0, min(project.sequence.duration.seconds, (seconds * 30).rounded() / 30))
        player.seek(to: CMTime(value: Int64((playhead * 30).rounded()), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlay() {
        guard !isBuilding, !isExporting, plan != nil else { return }
        stopAudition()
        if player.rate != 0 { player.pause(); playing = false }
        else { if playhead >= project.sequence.duration.seconds - 1.0 / 30 { seek(0) }; player.play(); playing = true }
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
                let result = try await TimelineRenderer.build(project: snapshot, documentURL: url, mediaURLOverrides: verified)
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
        if player.rate != 0 { player.pause(); playing = false }
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
            let result = try await TimelineRenderer.build(project: snapshot, documentURL: url, mediaURLOverrides: overrides)
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
        guard !isImporting, !isExporting else { return }
        isImporting = true; importProgress = 0
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            var failures: [String] = []; var assets: [MediaAsset] = []
            do {
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let asset = try await MediaImporter.inspect(url: url)
                        assets.append(asset)
                        if !asset.supported { failures.append("\(asset.name): \(asset.issue ?? "지원하지 않는 미디어")") }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    importProgress = Double(index + 1) / Double(max(1, urls.count))
                }
                try Task.checkCancellation()
                if !assets.isEmpty, perform(.batch(assets.map { .addAsset($0) })) { selectedAssetID = assets.last?.id }
                message = "미디어 \(assets.count)개 가져옴 · 한 번의 실행취소로 되돌릴 수 있습니다."
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
            } catch { message = "가져오기 취소됨 · 프로젝트에 추가하지 않았습니다." }
        }
    }
    func cancelImport() { importTask?.cancel() }
    func addAsset(_ asset: MediaAsset, overlay: Bool = false) {
        guard asset.supported else { error = asset.issue ?? "지원하지 않는 미디어입니다."; return }
        let kind: TrackKind = asset.kind == .audio ? .audio : (overlay ? .overlay : .video)
        guard let track = project.sequence.tracks.first(where: { $0.kind == kind }) else { return }
        var clip = Clip(name: asset.name, assetID: asset.id, start: .zero, sourceStart: .zero,
                        duration: asset.kind == .image ? MediaTime(3, 1) : asset.duration)
        clip.start = kind == .video ? (track.clips.map { $0.start + $0.duration }.max() ?? .zero) : MediaTime(seconds: playhead)
        if overlay { clip.transform.scale = 0.35; clip.transform.x = 270; clip.transform.y = 550 }
        if asset.kind == .audio { clip.volume = 0.25 }
        if perform(.addClip(trackID: track.id, clip: clip)) { selectClip(clip.id) }
    }
    func addTitle() {
        guard let track = project.sequence.tracks.first(where: { $0.kind == .title }) else { return }
        var clip = Clip(name: "한국어 제목", assetID: nil, start: MediaTime(seconds: playhead), sourceStart: .zero, duration: MediaTime(3, 1))
        clip.title = Title(text: "종현의 첫 영상")
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
            try ProjectStore.save(project, to: destination); documentURL = destination; savedData = projectData()
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
        history = EditorHistory(project: Project()); documentURL = nil; mediaBaseURL = nil; savedData = projectData(); selectedClipID = nil; selectedClipIDs = []; playhead = 0; rebuild()
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
            history = EditorHistory(project: value); documentURL = url; mediaBaseURL = url; selectedClipID = nil; selectedClipIDs = []; playhead = 0
            savedData = projectData(); message = "프로젝트 열림 · " + url.lastPathComponent; rebuild()
        } catch { self.error = error.localizedDescription }
    }
    func exportVideo() {
        guard plan != nil, !isBuilding, !busyDocument else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = project.name + ".mp4"
        panel.message = "\(project.sequence.width) × \(project.sequence.height) · 30 fps · SDR H.264 / AAC · \(outputBitRate / 1_000_000)Mbps"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.path) { error = "기존 파일 보호를 위해 다른 출력 이름을 선택하세요."; return }
        stopAudition(); player.pause(); playing = false; isExporting = true; exportProgress = 0
        let job = ExportJob(videoBitRate: outputBitRate); exportJob = job
        let snapshot = project, base = mediaBaseURL
        exportTask = Task {
            do {
                message = "출력용 원본 미디어 준비 중…"
                let originalPlan = try await TimelineRenderer.build(project: snapshot, documentURL: base)
                try Task.checkCancellation()
                try await job.export(plan: originalPlan, to: url) { [weak self] value in Task { @MainActor in self?.exportProgress = value } }
                message = "출력 완료 · \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription; message = "출력이 중단되었습니다." }
            isExporting = false; exportJob = nil; exportTask = nil
        }
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
                guard let track = project.sequence.tracks.first(where: { $0.kind == kind }) else { return }
                let available = max(MediaTime(1, 30), project.sequence.duration - insertion)
                let length = asset.kind == .image ? (project.sequence.duration > insertion ? min(available, MediaTime(5, 1)) : MediaTime(5, 1)) : (item.category == .music && project.sequence.duration > insertion ? min(asset.duration, available) : asset.duration)
                var clip = Clip(name: item.name, assetID: asset.id, start: insertion, duration: length, volume: item.category == .music ? 0.25 : 0.7)
                if item.category == .music { let fade = min(MediaTime(1, 1), MediaTime(seconds: length.seconds / 4)); clip.audioFadeIn = fade; clip.audioFadeOut = fade }
                if item.category == .overlay { clip.transform.scale = 0.75 }
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
                var clip = existing; var title = preset.title; title.text = existing.title?.text ?? title.text; clip.title = title
                commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        if commands.isEmpty && !toAll, let track = project.sequence.tracks.first(where: { $0.kind == .title }) {
            var title = preset.title; title.text = "종현의 첫 영상"
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
        let preset = TitlePreset(id: UUID().uuidString, name: field.stringValue, category: "내 스타일", title: saved)
        do { let next = userTitlePresets + [preset]; try FileManager.default.createDirectory(at: Self.presetsURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(next).write(to: Self.presetsURL, options: .atomic); userTitlePresets = next }
        catch { self.error = error.localizedDescription }
    }
    func importSRT() {
        guard !isExporting, !isImporting else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let track = project.sequence.tracks.first(where: { $0.kind == .title }) else { return }
        do {
            let cues = try SRTCodec.parse(SubtitleTextDecoder.decode(Data(contentsOf: url)))
            let style = selected?.1.title ?? TitlePreset.builtIns[0].title
            let commands: [EditCommand] = cues.map { cue in var title = style; title.text = cue.text; return .addClip(trackID: track.id, clip: Clip(name: "자막", start: cue.start, duration: cue.duration, title: title)) }
            if perform(.batch(commands)) { message = "SRT 자막 \(cues.count)개 추가 · 기존 영상 유지" }
        } catch { self.error = error.localizedDescription }
    }
    func exportSRT() {
        guard !captionClips.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]; panel.nameFieldStringValue = project.name + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let cues = captionClips.map { CaptionCue(id: $0.id, start: $0.start, duration: $0.duration, text: $0.title?.text ?? "") }
            try SRTCodec.serialize(cues).write(to: url, atomically: true, encoding: .utf8)
            message = "SRT 저장됨 · 스타일은 프로젝트 문서에 별도로 보존됩니다."
        } catch { self.error = error.localizedDescription }
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

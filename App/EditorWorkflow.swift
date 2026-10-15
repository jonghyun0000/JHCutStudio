import Foundation
import AppKit
import AVFoundation
import JHCutCore

extension EditorModel {
    func relinkMissingFolder() {
        guard !busyDocument else { return }
        let snapshot = project
        let missing = snapshot.assets.filter { !FileManager.default.fileExists(atPath: $0.resolvedURL(relativeTo: mediaBaseURL).path) }
        guard !missing.isEmpty else { message = UIL10n.text("누락된 미디어가 없습니다."); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = UIL10n.text("원본이 있는 폴더를 선택하세요. 파일 이름과 내용이 모두 같은 원본만 자동 연결합니다.")
        panel.title = UIL10n.text("누락된 미디어 연결…"); panel.prompt = UIL10n.text("폴더 선택")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        productivityBusy = true; productivityStatus = UIL10n.text("폴더에서 누락된 원본 확인 중…")
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                let replacements = try await FolderRelinking.replacements(for: missing, folder: folder)
                try Task.checkCancellation()
                try await checkpointAsyncJob(ticket, "relinkFolder.beforeApply")
                guard project == snapshot else { throw ProjectError("프로젝트가 변경되었습니다. 원본 찾기를 다시 실행하세요.") }
                for replacement in replacements {
                    let identity = try await EditorSourceIdentity.capture(replacement.resolvedURL(relativeTo: nil))
                    guard identity.sha256 == replacement.contentHash else { throw ProjectError("재연결 후보의 원본 내용이 변경되었습니다.") }
                }
                try validateAsyncJob(ticket)
                if !replacements.isEmpty, !perform(.batch(replacements.map { .replaceAsset($0) })) { return }
                for asset in replacements { proxyURLs[asset.id] = nil }
                message = UIL10n.format("ui.relink.result", replacements.count, missing.count)
                productivityStatus = message
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = UIL10n.text("원본 찾기 취소됨") } else { self.error = error.localizedDescription } }
        }
    }
    static func needsRender(_ before: Project, _ after: Project) -> Bool {
        func normalized(_ source: Project) -> Project {
            var p = source; p.name = ""; p.derivedSequences = nil; p.sequence.name = ""; p.sequence.markers = nil
            for ti in p.sequence.tracks.indices {
                p.sequence.tracks[ti].name = ""; p.sequence.tracks[ti].isLocked = false; p.sequence.tracks[ti].syncLocked = nil
                for ci in p.sequence.tracks[ti].clips.indices {
                    p.sequence.tracks[ti].clips[ci].name = ""; p.sequence.tracks[ti].clips[ci].connection = nil; p.sequence.tracks[ti].clips[ci].lineageID = nil; p.sequence.tracks[ti].clips[ci].captionMetadata = nil; p.sequence.tracks[ti].clips[ci].captionRole = nil; p.sequence.tracks[ti].clips[ci].captionGroupID = nil
                }
            }
            return p
        }
        return normalized(before) != normalized(after)
    }
    func writableTrack(_ kind: TrackKind) -> Track? {
        guard !isExporting else { return nil }
        if let track = project.sequence.tracks.first(where: { $0.kind == kind && !$0.isLocked && TransitionEditing.context(of: $0, in: project.sequence) == nil }) { return track }
        let name: String
        switch kind { case .video: name = "영상"; case .overlay: name = "오버레이"; case .title: name = "자막"; case .audio: name = "오디오" }
        let track = Track(name: "\(name) \(project.sequence.tracks.filter { $0.kind == kind }.count + 1)", kind: kind)
        return perform(.addTrack(track)) ? track : nil
    }
    func detachSelected() {
        guard let (track, clip) = selected, clip.connection != nil else { return }
        var value = clip; value.connection = nil
        if perform(.updateClip(trackID: track.id, clip: value)) { message = "연결 해제됨 · 이 클립은 독립적으로 편집됩니다." }
    }
    func addMarker() {
        var sequence = project.sequence
        sequence.markers = (sequence.markers ?? []) + [TimelineMarker(time: snapped(playhead), name: "마커 \((sequence.markers?.count ?? 0) + 1)")]
        perform(.replaceSequence(sequence))
    }
    func removeMarker(_ id: UUID) {
        var sequence = project.sequence; sequence.markers?.removeAll { $0.id == id }; perform(.replaceSequence(sequence))
    }
    var validLoopRange: ClosedRange<Double>? {
        guard loopStart.isFinite, loopEnd.isFinite, loopStart >= 0, loopEnd > loopStart, loopEnd <= project.sequence.duration.seconds else { return nil }
        return loopStart...loopEnd
    }
    func loopSelection() {
        guard let clip = selected?.1 else { return }
        loopStart = clip.start.seconds; loopEnd = clip.end.seconds; loopEnabled = true
        pausePlayback(); seek(loopStart); togglePlay()
    }
    func nextCaption(_ direction: Int) {
        let clips = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true).map(\.clip)
        guard !clips.isEmpty else { return }
        let index = clips.firstIndex { $0.id == selectedClipID } ?? (direction > 0 ? -1 : clips.count)
        let next = max(0, min(clips.count - 1, index + direction))
        selectClip(clips[next].id); pausePlayback(); seek(clips[next].start.seconds)
    }
    func updateCaption(_ id: UUID, text: String) {
        guard !busyDocument, let entry = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true).first(where: { $0.clip.id == id }) else {
            error = "현재 작업 범위의 보이는 잠금 해제 자막만 수정할 수 있습니다."; return
        }
        let track = entry.track; var clip = entry.clip
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "자막 문구를 입력하세요."; return }
        clip.title?.text = text; perform(.updateClip(trackID: track.id, clip: clip))
    }
    func replaceCaptionText(find: String, replacement: String, preview: Bool = false) {
        guard !busyDocument, !find.isEmpty else { return }
        var commands: [EditCommand] = []
        for entry in CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true) {
            var clip = entry.clip
            guard let current = clip.title?.text, current.contains(find) else { continue }
            let text = current.replacingOccurrences(of: find, with: replacement)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "전체 문구가 빈 자막이 생겨 교정을 중단했습니다."; return }
            clip.title?.text = text; commands.append(.updateClip(trackID: entry.track.id, clip: clip))
        }
        guard !commands.isEmpty else { message = "현재 범위의 편집 가능한 자막에서 일치하는 문구가 없습니다."; return }
        if preview { prepareCaptionProposal(commands, label: "검색어 일괄 교정") }
        else if perform(.batch(commands)) { message = "자막 \(commands.count)개 일괄 교정 · ⌘Z로 되돌리기" }
    }
    func duckSelectedMusic() {
        guard let (track, clip, _) = selectedSound else { return }
        let speech = captionClips.map { ($0.start, $0.end) }
        guard !speech.isEmpty else { error = "대사 자막을 먼저 생성하거나 추가하세요."; return }
        do {
            var value = clip; value.ducking = try AudioAutomation.duck(clip: clip, speech: speech, reductionDB: duckingDB, release: duckingRelease)
            if perform(.updateClip(trackID: track.id, clip: value)) { message = "자막 구간에서 배경음을 낮춥니다. 기존 볼륨·페이드는 유지됩니다." }
        } catch { self.error = error.localizedDescription }
    }
    func removeDucking() {
        guard let (track, original) = selected else { return }; var clip = original; clip.ducking = nil; perform(.updateClip(trackID: track.id, clip: clip))
    }
}

struct QueuedExport: Identifiable {
    let id = UUID()
    let project: Project
    let baseURL: URL?
    let url: URL
    let codec: ExportJob.Codec
    let bitRate: Int
    let captionScope: CaptionScope
    let sidecarSRT: Bool
    let subtitleRepresentation: String
    init(project: Project, baseURL: URL?, url: URL, codec: ExportJob.Codec, bitRate: Int, captionScope: CaptionScope = .all, sidecarSRT: Bool = false, subtitleRepresentation: String = "visible") {
        self.project = project; self.baseURL = baseURL; self.url = url; self.codec = codec; self.bitRate = bitRate; self.captionScope = captionScope; self.sidecarSRT = sidecarSRT; self.subtitleRepresentation = subtitleRepresentation
    }
    var status = "대기"
}
extension EditorModel {
    func setExportPhase(_ phase: ExportPhase, jobID: UUID) {
        guard activeExportID == jobID else { return }
        activeExportPhase = phase
        switch phase {
        case .sources: exportQualityStatus = "원본 확인 중…"
        case .movie: exportQualityStatus = "영상 출력 중…"
        case .movieReady: exportQualityStatus = "출력 영상 확인 중…"
        case .moviePublished: exportQualityStatus = "영상 저장 완료 · 검사 준비 중…"
        case .subtitles: exportQualityStatus = "자막 파일 저장 중…"
        case .quality: exportQualityStatus = "출력 파일 검사 중…"
        case .report, .finished: break // Keep the final QA summary or failure/cancellation explanation.
        }
        exportPhaseObserver?(jobID, phase)
    }
    func acceptExportProgress(_ value: Double, jobID: UUID, phase: ExportPhase) {
        guard activeExportID == jobID, activeExportPhase == phase, isExporting else { return }
        if phase == .movie { exportProgress = value }
        if phase == .quality { exportQualityStatus = "출력 파일 검사 \(Int(value * 100))%" }
    }
    func startNextExport() {
        guard !isExporting, let request = exportQueue.first(where: { $0.status == "대기" }) else { return }
        var initial: ExportDeliveryReceipt
        do { initial = try ExportDeliveryReceipt(jobID: request.id, project: request.project, destination: request.url) }
        catch { self.error = error.localizedDescription; return }
        initial.subtitles = request.sidecarSRT ? .waiting : .notRequested
        stopAudition(); isExporting = true; exportProgress = 0
        activeExportID = request.id; activeExportPhase = .sources
        lastQualityReport = nil; lastQualityReportURL = nil; exportQualityStatus = "원본 확인 중…"
        if let index = exportQueue.firstIndex(where: { $0.id == request.id }) { exportQueue[index].status = "출력 중" }
        let job = ExportJob(videoBitRate: request.bitRate, codec: request.codec); exportJob = job
        exportTask = Task {
            var receipt = initial, status = "완료", extra: [String: String] = [:]
            var workspace: ExportWorkspace?
            defer { workspace?.cleanup() }
            do {
                setExportPhase(.sources, jobID: request.id)
                receipt.sources = try await ExportDeliveryReceipt.capture(project: request.project, baseURL: request.baseURL)
                try Task.checkCancellation()
                let stage = try ExportWorkspace(parent: request.url.deletingLastPathComponent(), id: request.id); workspace = stage
                let plan = try await TimelineRenderer.build(project: request.project, documentURL: request.baseURL)
                let expectation = OutputExpectation.from(project: request.project, plan: plan)
                receipt.movie = .running; setExportPhase(.movie, jobID: request.id)
                let stagedMovie = stage.url.appendingPathComponent("movie." + request.codec.fileExtension)
                try await job.export(plan: plan, to: stagedMovie) { [weak self] value in
                    Task { @MainActor in self?.acceptExportProgress(value, jobID: request.id, phase: .movie) }
                }
                setExportPhase(.movieReady, jobID: request.id)
                try await ExportDeliveryReceipt.validate(receipt.sources)
                receipt.movieSHA256 = try await FileIdentity.sha256(stagedMovie)
                try Task.checkCancellation()
                let destination = request.url
                let publisher = Task.detached(priority: .utility) { try ExclusivePublication.file(from: stagedMovie, to: destination) }
                try await withTaskCancellationHandler(operation: { try await publisher.value }, onCancel: { publisher.cancel() })
                receipt.movie = .published
                lastExportedRequest = request; lastExportExpectation = expectation; lastExportSources = receipt.sources; lastExportOutputSHA256 = receipt.movieSHA256
                setExportPhase(.moviePublished, jobID: request.id)
                message = UIL10n.format("ui.export.completed", request.url.lastPathComponent)
                var srt: URL?
                if request.sidecarSRT {
                    setExportPhase(.subtitles, jobID: request.id); receipt.subtitles = .running
                    do {
                        try Task.checkCancellation()
                        srt = try writeSidecarSubtitles(for: request, scope: request.subtitleRepresentation)
                        receipt.subtitles = srt == nil ? .notRequested : .published; receipt.subtitleURL = srt?.path
                        if let srt { extra["subtitles"] = srt.path }
                    } catch {
                        receipt.subtitles = Task.isCancelled ? .cancelled : .failed
                        receipt.errors.append(error.localizedDescription)
                        // Do not borrow an existing sidecar from another job. The requested
                        // publication failure is added explicitly to the QA report below.
                        srt = nil
                        extra["subtitles"] = "저장 실패: " + error.localizedDescription
                    }
                }
                try Task.checkCancellation()
                receipt.quality = .running; setExportPhase(.quality, jobID: request.id)
                var report = try await OutputQuality.check(output: request.url, expectation: expectation, subtitles: srt) { [weak self] value in
                    Task { @MainActor in self?.acceptExportProgress(value, jobID: request.id, phase: .quality) }
                }
                try Task.checkCancellation()
                if receipt.subtitles == .failed {
                    report.issues.append(OutputQualityIssue(severity: .error, code: "sidecarPublicationFailed", message: "요청한 SRT를 게시하지 못했습니다. 기존 SRT를 이번 작업의 자막으로 사용하지 않았습니다.", time: nil))
                    if let index = report.checks?.firstIndex(where: { $0.id == "subtitles" }) {
                        report.checks?[index] = OutputQualityCheck(id: "subtitles", status: .failed, unit: "file", total: 1, checked: 0, failed: 1, warnings: 0, note: "SRT 게시 실패 · 기존 파일 보존 · 대응 검사 미실행")
                    }
                }
                report.exportJobID = request.id; report.projectSHA256 = receipt.projectSHA256; report.sourceSnapshot = receipt.sources
                let currentOutput = try await FileIdentity.sha256(request.url)
                guard currentOutput == receipt.movieSHA256 else { throw ProjectError("게시 후 출력 파일이 변경되었습니다. 다른 파일을 이 작업의 검사 결과로 연결하지 않았습니다.") }
                report.outputSHA256 = currentOutput
                receipt.quality = .completed; receipt.qaResult = report.status
                lastQualityReport = report; exportQualityStatus = report.summary
                extra["quality"] = report.summary; extra["qualityErrors"] = String(report.errors); extra["qualityWarnings"] = String(report.warnings)
                receipt.report = .running; setExportPhase(.report, jobID: request.id)
                do {
                    try Task.checkCancellation()
                    let url = try OutputQuality.write(report, to: reportsDirectory.appendingPathComponent("OutputQuality"), name: request.url.deletingPathExtension().lastPathComponent)
                    lastQualityReportURL = url; receipt.reportURL = url.path; receipt.report = .published; extra["qualityReport"] = url.path
                } catch {
                    receipt.report = Task.isCancelled ? .cancelled : .failed; receipt.errors.append(error.localizedDescription)
                    exportQualityStatus = report.summary + " · 보고서 저장 실패: " + error.localizedDescription
                    extra["quality"] = exportQualityStatus
                }
                if Task.isCancelled { status = "완료 · 추가 작업 취소" }
                else if receipt.subtitles == .failed || receipt.report == .failed { status = "완료 · 추가 작업 실패" }
                else if receipt.report == .cancelled { status = "완료 · 추가 작업 취소" }
                else if report.errors > 0 { status = "완료 · 검사 오류" }
                message = "영상 보존됨 · \(request.url.lastPathComponent) · " + exportQualityStatus
            } catch {
                let cancelled = Task.isCancelled
                if receipt.movie == .published {
                    status = cancelled ? "완료 · 추가 작업 취소" : "완료 · 추가 작업 실패"
                    if receipt.subtitles == .running || receipt.subtitles == .waiting { receipt.subtitles = cancelled ? .cancelled : .failed }
                    if receipt.quality != .completed { receipt.quality = cancelled ? .cancelled : .failed }
                    if receipt.report != .published { receipt.report = cancelled ? .cancelled : .failed }
                    exportQualityStatus = cancelled ? "출력 검사 취소 · 완성 영상 보존" : "출력 검사 실패 · 완성 영상 보존"
                    extra["quality"] = exportQualityStatus
                } else {
                    status = cancelled ? "취소" : "실패"; receipt.movie = cancelled ? .cancelled : .failed
                    exportQualityStatus = cancelled ? "영상 출력 취소" : "영상 출력 실패"
                }
                receipt.errors.append(error.localizedDescription); self.error = cancelled ? nil : error.localizedDescription
                message = "출력 \(status) · \(request.url.lastPathComponent)"
            }
            guard activeExportID == request.id else { return }
            lastExportReceipt = receipt
            if let data = try? JSONEncoder().encode(receipt), let json = String(data: data, encoding: .utf8) { extra["receiptJSON"] = json }
            extra["jobID"] = request.id.uuidString; extra["projectSHA256"] = receipt.projectSHA256
            extra["movieState"] = receipt.movie.rawValue; extra["subtitleState"] = receipt.subtitles.rawValue
            extra["qaState"] = receipt.quality.rawValue; extra["reportState"] = receipt.report.rawValue
            if let index = exportQueue.firstIndex(where: { $0.id == request.id }) { exportQueue[index].status = status }
            setExportPhase(.finished, jobID: request.id)
            isExporting = false; activeExportID = nil; activeExportPhase = nil; exportJob = nil; exportTask = nil
            let journalSaved = saveExportJournal(request: request, status: status, extra: extra)
            // Only a successful delivery advances automatically. Post-video failure/cancellation
            // preserves the movie and pauses remaining jobs until explicit Continue.
            if status == "완료", journalSaved { startNextExport() }
        }
    }
    func removeQueuedExport(_ id: UUID) { exportQueue.removeAll { $0.id == id && $0.status != "출력 중" } }
    func saveExportJournal(request: QueuedExport, status: String, extra: [String: String] = [:]) -> Bool {
        exportJournal.append(["file": request.url.path, "codec": request.codec.rawValue, "status": status, "date": ISO8601DateFormatter().string(from: Date())].merging(extra) { a, _ in a })
        exportJournal = Array(exportJournal.suffix(30))
        do {
            try FileManager.default.createDirectory(at: exportJournalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: exportJournal, options: [.prettyPrinted,.sortedKeys]).write(to: exportJournalURL, options: .atomic)
            return true
        } catch { message += " · 출력 기록 저장 실패 · 대기열 중단: " + error.localizedDescription; return false }
    }
    func prepareMedia(audioOnly: Bool, sourceURL: URL? = nil, audioTrackIndex: Int? = nil, outputDirectory: URL? = nil) {
        guard !busyDocument else { return }
        let url: URL
        if let sourceURL { url = sourceURL }
        else {
            let panel = NSOpenPanel(); panel.message = audioOnly ? "오디오 트랙을 추출할 원본 선택" : "SDR 사본으로 변환할 영상 선택 · 원본 보존"
            guard panel.runModal() == .OK, let selected = panel.url else { return }; url = selected
        }
        let snapshot = project, baseSnapshot = mediaBaseURL, documentSnapshot = documentURL
        productivityBusy = true; productivityStatus = "원본 트랙 확인 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            var preparedOutput: URL?
            var added = false
            defer {
                if !added, let preparedOutput { GeneratedMediaRegistry.discard(preparedOutput) }
                finishAsyncJob(ticket)
            }
            do {
                try validateAsyncJob(ticket)
                let identity = try await EditorSourceIdentity.capture(url)
                let tracks = try await MediaPreparation.audioTracks(in: url)
                try Task.checkCancellation()
                var index = audioTrackIndex ?? 0
                if tracks.count > 1, audioTrackIndex == nil {
                    let alert = NSAlert(); alert.messageText = "사용할 오디오 트랙"
                    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
                    picker.addItems(withTitles: tracks.map(\.name)); alert.accessoryView = picker
                    alert.addButton(withTitle: "사용"); alert.addButton(withTitle: "취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }; index = picker.indexOfSelectedItem
                }
                let root = outputDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/PreparedMedia")
                let output = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + (audioOnly ? ".m4a" : ".mp4"))
                productivityStatus = audioOnly ? "선택한 오디오 추출 중…" : "색상·픽셀을 Rec.709 SDR로 변환 중…"
                var asset = try await (audioOnly ? MediaPreparation.extractAudio(url: url, trackIndex: index, destination: output) : MediaPreparation.convertToSDR(url: url, destination: output, audioTrackIndex: index))
                preparedOutput = output
                try Task.checkCancellation()
                guard project == snapshot, mediaBaseURL == baseSnapshot, documentURL == documentSnapshot else { throw ProjectError("변환 중 프로젝트 또는 문서가 변경되었습니다. 오래된 사본 추가를 중단했습니다.") }
                try await checkpointAsyncJob(ticket, "prepare.beforeApply")
                try await identity.validate(); try validateAsyncJob(ticket)
                asset.name = url.deletingPathExtension().lastPathComponent + (audioOnly ? " · 오디오 \(index + 1)" : " · SDR 사본")
                let record = try await GeneratedMediaRegistry.register(file: output, purpose: audioOnly ? .audioExtract : .sdrCopy, projectID: snapshot.id, jobID: ticket.id, sourceName: url.lastPathComponent)
                asset.contentHash = record.sha256
                if perform(.addAsset(asset)) { added = true; selectedAssetID = asset.id; message = "변환 사본을 미디어에 추가했습니다. 원본은 보존했습니다." }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "미디어 변환 취소됨 · 문서는 바뀌지 않았습니다." }
                else { self.error = error.localizedDescription }
            }
        }
    }
}

extension EditorModel {
    func importLUT() {
        guard !busyDocument, let (track, original) = selected else { return }
        let panel = NSOpenPanel(); panel.message = "RGB 0~1 범위의 3D .cube LUT 선택 · 문서에 함께 저장됩니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 4_000_000 else { throw ProjectError("LUT는 4MB 이하여야 합니다.") }
            let lut = try CubeLUT.parse(String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
            var clip = original; if clip.visual == nil { clip.visual = VisualAdjustments() }; clip.visual?.lut = lut
            perform(.updateClip(trackID: track.id, clip: clip))
        } catch { self.error = error.localizedDescription }
    }
}

extension EditorModel {
    func masterMix(outputDirectory: URL? = nil) {
        guard !busyDocument, plan != nil else { return }
        let snapshot = project, base = mediaBaseURL, target = targetLUFS, enhance = enhanceMixVoice
        pausePlayback(); productivityBusy = true; productivityStatus = "최종 믹스 분석·음량 처리 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            var ownedOutput: URL?
            var added = false
            defer {
                if !added, let ownedOutput { GeneratedMediaRegistry.discard(ownedOutput) }
                finishAsyncJob(ticket)
            }
            do {
                try validateAsyncJob(ticket)
                let sources = try await ExportDeliveryReceipt.capture(project: snapshot, baseURL: base)
                try validateAsyncJob(ticket)
                let plan = try await TimelineRenderer.build(project: snapshot, documentURL: base)
                let root = outputDirectory ?? generatedMediaRoot
                let output = root.appendingPathComponent("Master-" + UUID().uuidString + ".caf")
                ownedOutput = output
                try validateAsyncJob(ticket)
                let result = try await MixMastering.render(plan: plan, to: output, targetLUFS: target, enhanceVoice: enhance)
                guard project == snapshot else { GeneratedMediaRegistry.discard(output); throw ProjectError("믹싱 중 프로젝트가 변경되어 결과 적용을 중단했습니다.") }
                var asset = try await MediaImporter.inspect(url: output); asset.name = "완성 믹스"
                let mixRecord = try await GeneratedMediaRegistry.register(file: output, purpose: .mix, projectID: snapshot.id, jobID: ticket.id, sourceName: snapshot.sequence.name)
                asset.contentHash = mixRecord.sha256
                try await checkpointAsyncJob(ticket, "mix.beforeApply")
                try await ExportDeliveryReceipt.validate(sources); try validateAsyncJob(ticket)
                var derived = snapshot.sequence; derived.id = UUID(); derived.name += " · 믹스 완성"
                for ti in derived.tracks.indices { derived.tracks[ti].isMuted = true }
                derived.tracks.append(Track(name: "완성 믹스", kind: .audio, clips: [Clip(name: "완성 믹스 · 수정 시 원본 버전에서 재생성", assetID: asset.id, duration: snapshot.sequence.duration)]))
                if perform(.batch([.addAsset(asset), .addIndependentSequence(derived)])) {
                    added = true
                    func number(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "−∞" }
                    mixStatus = "LUFS \(number(result.before.integratedLUFS)) → \(number(result.after.integratedLUFS)) · 4배 보간 피크 \(number(result.oversampledPeakDBFS))dBFS"
                    message = "믹스 완성 버전 생성 · 원본 버전은 보존됩니다. 편집을 바꾸면 원본 버전에서 믹스를 다시 만드세요."
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "믹스 만들기 취소됨 · 문서는 바뀌지 않았습니다." }
                else { self.error = error.localizedDescription } }
        }
    }
    func applyTemplate(_ kind: EditTemplate.Kind) {
        do { let track = try EditTemplate.track(kind: kind, sequence: project.sequence); perform(.addTrack(track)) }
        catch { self.error = error.localizedDescription }
    }
}

extension EditorModel {
    var exportableCaptionClips: [Clip] {
        CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope,
                             role: subtitleExportScope == "original" ? .original : subtitleExportScope == "translation" ? .translation : nil,
                             visibleOnly: subtitleExportScope == "visible").map(\.clip)
    }
    func captionImportedVideos(_ assets: [MediaAsset]) {
        guard !assets.isEmpty else { return }
        guard transcriptionReady else { message += " · " + UIL10n.text("자동 자막에는 음성 모델이 필요합니다. 모델 없이도 이 영상을 편집하고 출력할 수 있습니다."); return }
        guard let track = writableTrack(.video) else { return }
        var at = track.clips.map(\.end).max() ?? .zero
        let clips = assets.map { asset -> Clip in
            let clip = Clip(name: asset.name, assetID: asset.id, start: at, duration: asset.duration)
            at = clip.end; return clip
        }
        if perform(.batch(clips.map { .addClip(trackID: track.id, clip: $0) })) {
            selectedClipIDs = Set(clips.map(\.id)); selectedClipID = clips.first?.id
            transcribeSelection()
        }
    }
    func showOriginalCaptionTracks() {
        guard !busyDocument else { return }
        do {
            let originals = CaptionQuery.originals(in: project.sequence, scope: currentCaptionScope).map(\.clip)
            guard !originals.isEmpty else { message = "선택 범위에 원문 자막이 없습니다."; return }
            let sequence = try CaptionScopeEditing.displaying(in: project.sequence, originals: originals, target: nil)
            if sequence == project.sequence { message = "선택 범위의 원문 표시 상태입니다. 수동 트랙 숨김은 유지합니다."; return }
            if perform(.replaceSequence(sequence)) { message = "선택 범위의 원문 자막 표시 · 다른 그룹과 수동 트랙 숨김 유지" }
        } catch { self.error = error.localizedDescription }
    }
    func setSelectedCaptionRole(_ role: CaptionRole) {
        guard !busyDocument, role != .translation else { return }
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        let group = UUID()
        var commands: [EditCommand] = []
        for track in project.sequence.tracks where track.kind == .title {
            for original in track.clips where ids.contains(original.id) && original.title != nil {
                guard !track.isLocked else { error = "선택한 트랙의 잠금을 해제하세요."; return }
                var clip = original; clip.captionRole = role; clip.captionHidden = nil
                let existing = CaptionQuery.entries(in: project.sequence, scope: .selected([original.id])).first
                clip.captionGroupID = role == .original ? (existing?.groupID ?? group) : nil
                clip.captionMetadata?.translationRevision = nil
                if role == .original { clip.captionMetadata?.translatedFrom = nil }
                commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        if !commands.isEmpty, perform(.batch(commands)) { message = "선택한 클립을 " + role.label + "으로 지정 · ⌘Z로 되돌리기" }
    }
    var effectiveTranslationGlossary: [GlossaryEntry] {
        let entries = project.glossary ?? []
        let quick = translationGlossaryText.split(whereSeparator: \.isNewline).compactMap { line -> GlossaryEntry? in
            let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return nil }
            let source = fields[0].trimmingCharacters(in: .whitespaces), target = fields[1].trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, !entries.contains(where: { $0.source.caseInsensitiveCompare(source) == .orderedSame }) else { return nil }
            return GlossaryEntry(source: source, target: target)
        }
        return entries + quick
    }
    func translationFreshness(_ clip: Clip) -> TranslationFreshness {
        if CaptionTranslationTracking.isManual(clip) { return .manualKept }
        let source = CaptionTranslationTracking.source(for: clip, in: project.sequence)
        let language = translationSourceLanguage == "auto" ? (source?.captionMetadata?.language ?? CaptionTranslation.detectTextLanguage(source?.title?.text ?? "")) : translationSourceLanguage
        let recipe = language.map { CaptionTranslationTracking.recipeDigest(source: $0, target: clip.captionMetadata?.language ?? "", glossary: effectiveTranslationGlossary, style: TranslationStyle(rawValue: translationStyle) ?? .natural, bilingual: bilingualTranslation) }
        if let source, let language, let recipe,
           translationFailureAttempts[source.id] == CaptionTranslationTracking.revision(for: source, language: language, recipe: recipe) { return .failed }
        return CaptionTranslationTracking.automaticState(of: clip, source: source, language: language, recipe: recipe, allowUncertainLanguage: translationSourceLanguage != "auto")
    }
    func regenerateManualTranslation(_ id: UUID) {
        guard !busyDocument, let clip = captionClips.first(where: { $0.id == id }), CaptionTranslationTracking.isManual(clip), let language = clip.captionMetadata?.language else { return }
        guard CaptionTranslationTracking.source(for: clip, in: project.sequence) != nil else { error = "원문 연결이 없는 번역은 먼저 원문을 확인하세요."; return }
        translationTargetLanguage = language
        translateCaptionTracks(scope: .selected([id]), replacingManual: [id])
    }
    func translateCaptionTracks(scope explicitScope: CaptionScope? = nil, replacingManual idsToReplace: Set<UUID> = []) {
        guard !busyDocument else { return }
        let snapshot = project
        let originalEntries = CaptionQuery.originals(in: snapshot.sequence, scope: explicitScope ?? currentCaptionScope)
        let originals = originalEntries.map { entry -> Clip in
            var clip = entry.clip; clip.captionRole = .original; clip.captionGroupID = entry.groupID; return clip
        }
        guard !originals.isEmpty else { message = "번역할 원문 자막을 먼저 생성하거나 SRT로 가져오세요."; return }
        let target = translationTargetLanguage, override = translationSourceLanguage, bilingual = bilingualTranslation
        let fitNewCaptions = fitNewTranslatedCaptions
        let glossary = translationGlossaryText.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2, !fields[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (fields[0].trimmingCharacters(in: .whitespaces), fields[1].trimmingCharacters(in: .whitespaces))
        }
        // Quick "원문=번역" lines act like project entries for this run; project entries win on the same term.
        let projectGlossary = snapshot.glossary ?? []
        let entries = projectGlossary + glossary.filter { pair in !projectGlossary.contains { $0.source.caseInsensitiveCompare(pair.0) == .orderedSame } }
            .map { GlossaryEntry(source: $0.0, target: $0.1) }
        let style = TranslationStyle(rawValue: translationStyle) ?? .natural
        guard CaptionLanguage(rawValue: target) != nil else { error = "번역 언어를 선택하세요."; return }
        // Only affected captions participate in lock checks; decorative/unrelated tracks are irrelevant.
        do { _ = try CaptionScopeEditing.displaying(in: snapshot.sequence, originals: originals, target: target) }
        catch { self.error = error.localizedDescription; return }
        if originalEntries.contains(where: { $0.track.isLocked }) { error = "선택 범위의 원문 트랙 잠금을 해제하세요."; return }
        var groups: [String: [Clip]] = [:]
        for clip in originals {
            let source = override == "auto" ? (clip.captionMetadata?.language ?? CaptionTranslation.detectTextLanguage(clip.title?.text ?? "")) : override
            guard let source, CaptionLanguage(rawValue: source) != nil else { error = "원문 언어를 확정하지 못했습니다. 번역 설정의 원문 언어를 직접 선택하세요."; return }
            groups[source, default: []].append(clip)
        }
        if groups.keys.allSatisfy({ $0 == target }) {
            do {
                let sequence = try CaptionScopeEditing.displaying(in: snapshot.sequence, originals: originals, target: nil)
                if sequence != snapshot.sequence { _ = perform(.replaceSequence(sequence)) }
            } catch { self.error = error.localizedDescription; return }
            message = "원문이 이미 \(CaptionLanguage(rawValue: target)!.label)입니다. 선택 범위의 원문 자막을 표시합니다."; return }
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; translationActive = true; productivityStatus = "자막을 기기 안에서 번역 중…"
        let provider = translationProvider, identifiedProvider = translationBatchProvider
        for clip in originals { translationFailureAttempts.removeValue(forKey: clip.id) }
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { if ownsAsyncJob(ticket) { translationActive = false; finishAsyncJob(ticket) } }
            var attempted: [UUID: TranslationRevision] = [:]
            do {
                try validateAsyncJob(ticket)
                var translated: [Clip] = [], preserved = 0, reused = 0, refreshed = 0
                @MainActor func request(_ clips: [Clip], texts: [String], source: String) async throws -> [String] {
                    let requests = zip(clips, texts).map { CaptionTranslationRequest(id: $0.0.id, text: $0.1) }
                    if let provider {
                        let values = try await provider(texts, source, target)
                        try validateAsyncJob(ticket)
                        guard values.count == requests.count else { throw ProjectError("번역 결과 개수가 원문과 다릅니다. 원문과 기존 번역은 유지됩니다.") }
                        return try CaptionTranslationResponses.ordered(zip(requests, values).map { CaptionTranslationResponse(id: $0.0.id, text: $0.1) }, for: requests)
                    }
                    let responses = try await identifiedProvider(requests, source, target)
                    try validateAsyncJob(ticket)
                    return try CaptionTranslationResponses.ordered(responses, for: requests)
                }
                var glossaryHits = 0, glossaryMisses = 0, styleConverted = 0, styleMatching = 0, styleKept = 0
                var fittedCaptions = 0, unfittedCaptions = 0
                for source in groups.keys.sorted() {
                    let recipe = CaptionTranslationTracking.recipeDigest(source: source, target: target, glossary: entries, style: style, bilingual: bilingual)
                    var pending: [Clip] = []
                    for clip in groups[source]! {
                        let existing = snapshot.sequence.tracks.flatMap(\.clips).filter { $0.captionMetadata?.language == target && CaptionQuery.related($0, to: clip) }
                        let manual = existing.filter(CaptionTranslationTracking.isManual)
                        let replacing = existing.contains { idsToReplace.contains($0.id) }
                        if !manual.isEmpty && !replacing { translated += existing; preserved += manual.count; continue }
                        if !replacing && !existing.isEmpty && existing.allSatisfy( { CaptionTranslationTracking.automaticState(of: $0, source: clip, language: source, recipe: recipe, allowUncertainLanguage: override != "auto") == .current }) {
                            translated += existing; reused += existing.count; continue
                        }
                        let keep = manual.filter { !idsToReplace.contains($0.id) }; translated += keep; preserved += keep.count
                        attempted[clip.id] = CaptionTranslationTracking.revision(for: clip, language: source, recipe: recipe)
                        guard override != "auto" || clip.captionMetadata?.languageNeedsReview != true || clip.captionMetadata?.languageManual == true else { throw ProjectError("원문 언어 확인이 필요한 자막이 있습니다. 자막의 언어를 지정하거나 번역 설정에서 원문 언어를 직접 선택하세요. 기존 번역은 유지됩니다.") }
                        pending.append(clip)
                    }
                    for clips in CaptionTranslationBatching.batches(pending) {
                        productivityStatus = "\(CaptionLanguage(rawValue: source)!.label) → \(CaptionLanguage(rawValue: target)!.label) · \(clips.count)개 자막 번역 중…"
                        let texts = clips.map { $0.title!.text }
                        var values = texts
                        var applied = [[String]](repeating: [], count: clips.count), failed = applied
                        if source != target {
                            let protected = texts.map { GlossaryProtection.protect($0, entries: entries, from: source, to: target) }
                            let sendIndices = protected.indices.filter { !protected[$0].isOnlyTerms }
                            let raw = sendIndices.isEmpty ? [] : try await request(sendIndices.map { clips[$0] }, texts: sendIndices.map { protected[$0].text }, source: source)
                            try Task.checkCancellation()
                            guard raw.count == sendIndices.count else { throw ProjectError("번역 결과 개수가 원문과 다릅니다. 원문 자막은 그대로 유지됩니다.") }
                            var translatedProtected = protected.map(\.text)
                            for (k, i) in sendIndices.enumerated() { translatedProtected[i] = raw[k] }
                            var retry: [Int] = []
                            for i in texts.indices {
                                let restored = GlossaryProtection.restore(translatedProtected[i], protected[i], targetLanguage: target)
                                values[i] = restored.text; applied[i] = restored.applied; failed[i] = restored.failed
                                if !restored.failed.isEmpty { retry.append(i) }
                            }
                            // A dropped marker would leave a hole in the sentence: translate that sentence plainly instead.
                            if !retry.isEmpty {
                                let plain = try await request(retry.map { clips[$0] }, texts: retry.map { texts[$0] }, source: source)
                                try Task.checkCancellation()
                                guard plain.count == retry.count else { throw ProjectError("번역 결과 개수가 원문과 다릅니다. 원문 자막은 그대로 유지됩니다.") }
                                for (k, i) in retry.enumerated() { values[i] = plain[k]; applied[i] = [] }
                            }
                            // Legacy quick-glossary behaviour: replace the term in the output when it was not in the source.
                            for i in values.indices {
                                for pair in glossary where !texts[i].localizedCaseInsensitiveContains(pair.0) && values[i].contains(pair.0) {
                                    values[i] = values[i].replacingOccurrences(of: pair.0, with: pair.1)
                                    if !applied[i].contains(pair.0) { applied[i].append(pair.0) }
                                }
                            }
                        }
                        for (i, clip) in clips.enumerated() {
                            var text = values[i], conversion: StyleConversion?
                            if source != target && style != .natural {
                                let result = TranslationStyleConverter.apply(style, to: text, language: target)
                                text = result.text; conversion = result
                                styleConverted += result.converted; styleMatching += result.alreadyMatching; styleKept += result.unsupported
                            }
                            var made = try CaptionTranslationEditing.translated(clip, text: text, sourceLanguage: source, targetLanguage: target, bilingual: bilingual)
                            if source != target {
                                made.captionMetadata?.translationStyle = style == .natural ? nil : style.rawValue
                                made.captionMetadata?.styleApplied = conversion?.applied
                                made.captionMetadata?.glossaryApplied = applied[i].isEmpty ? nil : applied[i]
                                made.captionMetadata?.glossaryFailed = failed[i].isEmpty ? nil : failed[i]
                                glossaryHits += applied[i].count; glossaryMisses += failed[i].count
                            }
                            if fitNewCaptions, let title = made.title,
                               let layout = try CaptionReadability.assess(made, width: snapshot.sequence.width, height: snapshot.sequence.height),
                               layout.outsideSafeArea || layout.exceedsLineLimit {
                                if let fitted = try CaptionLayout.fitted(title, width: snapshot.sequence.width, height: snapshot.sequence.height) {
                                    // No text, explicit newline, timing, linkage, or generation metadata changes.
                                    made.title = fitted; fittedCaptions += 1
                                } else {
                                    // Preserve every word and the original presentation; keep the warning visible.
                                    unfittedCaptions += 1
                                }
                            }
                            made.captionMetadata?.translationRevision = CaptionTranslationTracking.revision(for: clip, language: source, recipe: recipe)
                            translated.append(made); refreshed += 1
                        }
                    }
                }
                try Task.checkCancellation()
                try await checkpointAsyncJob(ticket, "translation.beforeApply")
                guard project == snapshot else { throw ProjectError("번역 중 프로젝트가 변경되었습니다. 오래된 번역으로 편집을 덮어쓰지 않도록 중단했습니다.") }
                let sequence = try CaptionScopeEditing.installing(translated, for: originals, target: target, in: snapshot.sequence)
                if perform(.replaceSequence(sequence)) {
                    let composition = groups.keys.sorted().map { "\(CaptionLanguage(rawValue: $0)!.label) \(groups[$0]!.count)" }.joined(separator: " · ")
                    var notes: [String] = []
                    if fittedCaptions > 0 { notes.append("새 번역 안전 영역 맞춤 \(fittedCaptions)개") }
                    if unfittedCaptions > 0 { notes.append("안전 영역 맞춤 불가 \(unfittedCaptions)개 · 문구/시간은 보존했으며 배치를 확인하세요") }
                    if !entries.isEmpty { notes.append("용어집 적용 \(glossaryHits)건" + (glossaryMisses > 0 ? " · 적용 실패 \(glossaryMisses)건(해당 문장은 일반 번역)" : "")) }
                    if style != .natural {
                        if target == "en" { notes.append("영어는 존댓말 구분이 없어 \(style.label) 스타일을 적용하지 않았습니다") }
                        else { notes.append("\(style.label) 변환 \(styleConverted)문장 · 이미 맞음 \(styleMatching) · 규칙 밖 \(styleKept)문장은 번역기 문장 유지") }
                    }
                    message = "\(CaptionLanguage(rawValue: target)!.label) 번역 자막 \(translated.count)개 · 문장별 원문 언어 \(composition) · 직접 고친 번역 \(preserved)개 보존 · 최신 \(reused)개 재사용 · 갱신 \(refreshed)개" + notes.map { " · " + $0 }.joined() + " · 원문은 숨긴 트랙에 유지됩니다."
                    productivityStatus = message
                    if let first = translated.first { selectClip(first.id); seek(first.start.seconds) }
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "번역 취소됨 · 원문과 기존 번역을 유지합니다." }
                else { translationFailureAttempts.merge(attempted, uniquingKeysWith: { _, new in new }); self.error = error.localizedDescription; message = "번역 실패 · 원문과 기존 번역을 유지합니다." }
                productivityStatus = message
            }
        }
    }
}

// MARK: - Output quality check (upgrade 9)

extension EditorModel {
    /// Captions of the exported snapshot as an .srt beside the video (same scope rules as SRT export,
    /// always limited to visible tracks so it describes what was burned in).
    func writeSidecarSubtitles(for request: QueuedExport, scope: String) throws -> URL? {
        let clips = CaptionQuery.entries(in: request.project.sequence, scope: request.captionScope,
                                         role: scope == "original" ? .original : scope == "translation" ? .translation : nil,
                                         visibleOnly: true).map(\.clip)
        guard !clips.isEmpty else { return nil }
        let url = request.url.deletingPathExtension().appendingPathExtension("srt")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ProjectError("같은 이름의 SRT가 이미 있어 덮어쓰지 않았습니다: \(url.lastPathComponent)") }
        let cues = clips.map { CaptionCue(id: $0.id, start: $0.start, duration: $0.duration, text: $0.title?.text ?? "") }
        let stage = try ExportWorkspace(parent: url.deletingLastPathComponent(), id: UUID())
        defer { stage.cleanup() }
        let file = stage.url.appendingPathComponent("subtitles.srt")
        try SRTCodec.serialize(cues).write(to: file, atomically: false, encoding: .utf8)
        try ExclusivePublication.file(from: file, to: url)
        return url
    }

    /// Re-check uses the captured expectation of the completed movie, not changed source media.
    func recheckLastExport() {
        guard !isExporting, let request = lastExportedRequest, let expectation = lastExportExpectation,
              FileManager.default.fileExists(atPath: request.url.path) else { error = "다시 검사할 최근 출력 파일이 없습니다."; return }
        let attemptID = UUID(); activeExportID = attemptID; activeExportPhase = .quality; isExporting = true
        lastQualityReport = nil; lastQualityReportURL = nil
        exportTask = Task {
            defer { if activeExportID == attemptID { activeExportID = nil; activeExportPhase = nil; isExporting = false; exportTask = nil } }
            do {
                setExportPhase(.quality, jobID: attemptID)
                let srt = request.url.deletingPathExtension().appendingPathExtension("srt")
                let sidecar = request.sidecarSRT || FileManager.default.fileExists(atPath: srt.path) ? srt : nil
                var report = try await OutputQuality.check(output: request.url, expectation: expectation, subtitles: sidecar) { [weak self] value in
                    Task { @MainActor in self?.acceptExportProgress(value, jobID: attemptID, phase: .quality) }
                }
                try Task.checkCancellation()
                guard activeExportID == attemptID else { return }
                report.exportJobID = request.id; report.sourceSnapshot = lastExportSources
                report.projectSHA256 = try ExportDeliveryReceipt(jobID: request.id, project: request.project, destination: request.url).projectSHA256
                let currentOutput = try await FileIdentity.sha256(request.url)
                guard currentOutput == lastExportOutputSHA256 else { throw ProjectError("완성 후 영상 파일이 변경되었습니다. 원래 작업의 정상 출력으로 재검수하지 않았습니다.") }
                report.outputSHA256 = currentOutput
                lastQualityReport = report; setExportPhase(.report, jobID: attemptID)
                lastQualityReportURL = try OutputQuality.write(report, to: reportsDirectory.appendingPathComponent("OutputQuality"), name: request.url.deletingPathExtension().lastPathComponent)
                exportQualityStatus = report.summary; message = report.summary
            } catch {
                guard activeExportID == attemptID else { return }
                exportQualityStatus = Task.isCancelled ? "다시 검사 취소 · 완성 영상 보존" : "다시 검사/보고서 저장 실패 · 완성 영상 보존: " + error.localizedDescription
                message = exportQualityStatus
            }
        }
    }

}

struct CaptionProposalChange: Identifiable {
    let id: UUID
    let before: Clip?
    let after: Clip?
}
struct CaptionEditProposal: Identifiable {
    let id = UUID()
    let label: String
    let snapshot: Project
    let scope: CaptionScope
    let sequence: JHCutCore.Sequence
    let changes: [CaptionProposalChange]
}

extension EditorModel {
    /// Preview the validated candidate, including connection reconciliation, without modifying history.
    func prepareCaptionProposal(_ commands: [EditCommand], label: String) {
        guard !busyDocument, !commands.isEmpty else { return }
        do {
            var candidate = EditorHistory(project: project)
            try candidate.apply(.batch(commands))
            installCaptionProposal(candidate.project.sequence, label: label)
        } catch { self.error = error.localizedDescription }
    }
    private func installCaptionProposal(_ sequence: JHCutCore.Sequence, label: String) {
        let before = Dictionary(uniqueKeysWithValues: project.sequence.tracks.flatMap(\.clips).map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: sequence.tracks.flatMap(\.clips).map { ($0.id, $0) })
        let changes = Set(before.keys).union(after.keys).compactMap { id -> CaptionProposalChange? in
            guard before[id] != after[id] else { return nil }
            return CaptionProposalChange(id: id, before: before[id], after: after[id])
        }.sorted { ($0.after?.start ?? $0.before?.start ?? .zero) < ($1.after?.start ?? $1.before?.start ?? .zero) }
        guard !changes.isEmpty else { message = "바뀌는 자막이 없습니다."; return }
        captionEditProposal = CaptionEditProposal(label: label, snapshot: project, scope: currentCaptionScope, sequence: sequence, changes: changes)
    }
    @discardableResult func applyCaptionProposal() -> Bool {
        guard !busyDocument, let proposal = captionEditProposal else { return false }
        guard project == proposal.snapshot, currentCaptionScope == proposal.scope else {
            captionEditProposal = nil; error = "미리보기 뒤 프로젝트 또는 작업 범위가 바뀌었습니다. 변경 내용을 다시 확인하세요."; return false
        }
        guard perform(.replaceSequence(proposal.sequence)) else { return false }
        captionEditProposal = nil; message = "\(proposal.label) 적용 · ⌘Z로 한 번에 되돌리기"; return true
    }
    /// Split text only at a Swift Character boundary and time only through the existing temporal editor.
    func previewCaptionSplit(characterOffset: Int) {
        guard !busyDocument, let id = selectedClipID,
              let entry = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true).first(where: { $0.clip.id == id }),
              let text = entry.clip.title?.text else { error = "편집 가능한 자막을 선택하세요."; return }
        guard characterOffset > 0, characterOffset < text.count else { error = "문자 분할 위치는 문구의 처음과 끝 사이여야 합니다."; return }
        let boundary = text.index(text.startIndex, offsetBy: characterOffset)
        let left = String(text[..<boundary]), right = String(text[boundary...])
        guard !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "분할 후 두 문구 모두 내용이 있어야 합니다."; return }
        // An exact translation cannot choose between two changed original sentences by itself.
        if entry.role == .original, CaptionQuery.entries(in: project.sequence, role: .translation).contains(where: { CaptionQuery.related($0.clip, to: entry.clip) }) {
            error = "번역이 연결된 원문은 문구 분할을 보류했습니다. 원문/번역 연결을 검토한 뒤 시간 분할을 사용하세요."; return
        }
        do {
            var candidate = EditorHistory(project: project)
            let at = MediaTime(seconds: playhead)
            try candidate.apply(.split(trackID: entry.track.id, clipID: id, at: at))
            let pieces = candidate.project.sequence.tracks.first(where: { $0.id == entry.track.id })!.clips.filter {
                $0.id == id || (($0.lineageID ?? $0.id) == (entry.clip.lineageID ?? id) && $0.start == at)
            }.sorted { $0.start < $1.start }
            guard pieces.count == 2 else { throw ProjectError("분할된 자막 두 조각을 확인할 수 없습니다.") }
            var a = pieces[0], b = pieces[1]; a.title?.text = left; b.title?.text = right
            try candidate.apply(.batch([.updateClip(trackID: entry.track.id, clip: a), .updateClip(trackID: entry.track.id, clip: b)]))
            installCaptionProposal(candidate.project.sequence, label: "문구·재생 위치 분할")
        } catch { self.error = error.localizedDescription }
    }
    func markCaptionReviewed(_ id: UUID, reviewed: Bool) {
        guard !busyDocument, let entry = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true).first(where: { $0.clip.id == id }) else { return }
        perform(.updateClip(trackID: entry.track.id, clip: CaptionReview.marking(entry.clip, reviewed: reviewed)))
    }
    func seekCaptionForReview(_ clip: Clip) {
        selectClip(clip.id); pausePlayback(); seek(clip.start.seconds)
    }
    func captionOriginal(for clip: Clip) -> Clip? {
        CaptionQuery.role(of: clip) == .translation ? CaptionTranslationTracking.source(for: clip, in: project.sequence) : clip
    }
    func seekCaptionOriginal(_ clip: Clip) {
        guard let source = captionOriginal(for: clip) else { error = "이 번역의 원문 연결이 모호하거나 사라졌습니다."; return }
        // Seek the displayed original's timeline instant. Its connection supplies the original file time.
        selectClip(source.id); pausePlayback(); seek(source.start.seconds)
    }
}

extension EditorModel {
    func captionReviewFlags(_ clip: Clip, report: CaptionReadabilityReport?) -> Set<String> {
        var result: Set<String> = [CaptionReview.isReviewed(clip) ? "reviewed" : "pending"]
        if let report {
            if report.exceedsLineLimit || report.outsideSafeArea || report.fallbackFont != nil { result.insert("layout") }
            if report.tooFast || report.shortCue { result.insert("reading") }
        }
        if clip.captionMetadata?.languageNeedsReview == true && clip.captionMetadata?.languageManual != true || CaptionLanguage(rawValue: clip.captionMetadata?.language ?? "") == nil { result.insert("language") }
        if CaptionQuery.role(of: clip) == .translation, translationFreshness(clip) != .current { result.insert("translation") }
        if clip.captionMetadata?.speaker == nil || clip.captionMetadata?.speakerStatus == "uncertain" { result.insert("speaker") }
        return result
    }
}

extension EditorModel {
    func seekNextCaptionForReview(_ direction: Int, ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == selectedClipID } ?? (direction > 0 ? -1 : ids.count)
        let index = max(0, min(ids.count - 1, current + direction))
        guard let clip = scopedCaptionClips.first(where: { $0.id == ids[index] }) else { return }
        seekCaptionForReview(clip)
    }
}

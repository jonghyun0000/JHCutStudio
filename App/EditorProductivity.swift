import SwiftUI
import AppKit
import JHCutCore

extension EditorModel {
    func resetProductivityState() {
        audioResult = nil; analyzedClip = nil; analyzedAsset = nil; analyzedProjectID = nil
        loopEnabled = false; loopStart = 0; loopEnd = 0; mixStatus = ""; detectedSpeechLanguages = ""
        proxyURLs = [:]; Task { await proxyCache.setProtectedURLs([]) }; proxyEnabled = false; proxyStatus = "원본 미디어로 미리보기"
    }
    func refreshTranscriptionStatus() {
        let value = LocalTranscription.availability(configuration: WhisperConfiguration(modelSpec: speechModelSpec))
        transcriptionReady = value.canTranscribe; transcriptionStatus = value.message
    }
    var selectedSound: (Track, Clip, MediaAsset)? {
        guard let (track, clip) = selected, let asset = project.assets.first(where: { $0.id == clip.assetID }), asset.kind == .audio || asset.hasAudio else { return nil }
        return (track, clip, asset)
    }
    var selectedSpeechClips: [(Track, Clip, MediaAsset)] {
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        return project.sequence.tracks.flatMap { track in
            track.clips.compactMap { clip -> (Track, Clip, MediaAsset)? in
                guard ids.contains(clip.id), let asset = project.assets.first(where: { $0.id == clip.assetID }),
                      asset.supported, asset.kind == .audio || asset.hasAudio else { return nil }
                return (track, clip, asset)
            }
        }.sorted { $0.1.start < $1.1.start }
    }
    func analyzeSound() {
        guard !busyDocument, let (_, clip, asset) = selectedSound else { return }
        let url = asset.resolvedURL(relativeTo: mediaBaseURL), projectID = project.id
        productivityBusy = true; productivityStatus = "선택 구간의 실제 PCM 오디오 분석 중…"
        audioResult = nil
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let result = try await AudioAnalysis.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration)
                try Task.checkCancellation()
                guard project.id == projectID else { return }
                audioResult = result; analyzedClip = clip; analyzedAsset = asset; analyzedProjectID = projectID
                productivityStatus = "오디오 분석 완료 · 원본 피크/RMS · 무음 후보 \(result.silenceRegions.count)개"
                message = productivityStatus
            } catch { if Task.isCancelled { message = "분석 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    var analysisMatchesSelection: Bool {
        guard let (_, clip, asset) = selectedSound else { return false }
        return analyzedProjectID == project.id && analyzedClip == clip && analyzedAsset == asset
    }
    func normalizePeak() {
        guard !busyDocument, analysisMatchesSelection, let result = audioResult, let (_, original, _) = selectedSound,
              let gain = result.normalizationGain, let (track, _) = selected else { return }
        var clip = original
        // Source target gain replaces the static fader; animated envelopes retain their relative shape.
        let divisor = original.volume > 0 ? original.volume : 1
        let keyVolumes = (clip.keyframes ?? []).map { $0.volume / divisor * gain }
        guard gain <= 4, keyVolumes.allSatisfy({ $0 <= 4 }) else { error = "정규화에 4배 이상의 볼륨이 필요합니다. 자동으로 제한하지 않았습니다. 속성에서 직접 조절하세요."; return }
        clip.volume = gain
        if clip.keyframes != nil { for i in clip.keyframes!.indices { clip.keyframes![i].volume = keyVolumes[i] } }
        if perform(.updateClip(trackID: track.id, clip: clip)) {
            let achieved = (result.peakDBFS ?? 0) + (result.normalizationGainDB ?? 0)
            message = "원본 피크 \(String(format: "%.1f", achieved))dBFS 조정\(result.normalizationBoostLimited ? " · +12dB 증폭 상한 적용" : "") · 믹스 후 최종 음량은 달라질 수 있습니다."
        }
    }
    func seekSilence(_ region: AudioSilenceRegion) {
        guard analysisMatchesSelection, let clip = analyzedClip else { return }
        let local = (clip.playbackRate ?? PlaybackRate()).timelineDuration(for: region.start - clip.sourceStart)
        seek((clip.start + local).seconds)
    }
    func transcribeSelection() {
        let sources = selectedSpeechClips
        guard !busyDocument, transcriptionReady, !sources.isEmpty else { return }
        let snapshot = project, base = mediaBaseURL, jobID = UUID()
        let preset = allTitlePresets.first(where: { $0.id == transcriptionPresetID }) ?? TitlePreset.builtIns[0]
        let style = TitleSizing.title(for: preset, width: snapshot.sequence.width, height: snapshot.sequence.height)
        let options = speechOptions, replaceExisting = replaceAutomaticCaptions
        let configuration = WhisperConfiguration(modelSpec: speechModelSpec)
        let store = checkpointStore, fingerprints = mediaFingerprints, useCheckpoints = useSpeechCheckpoints, windowSeconds = speechWindowSeconds
        let skipsNonSpeech = skipNonSpeech
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; transcriptionActive = true; transcriptionProgress = 0; transcriptionJobID = jobID; transcriptionDetail = nil
        productivityStatus = "음성 언어를 확인하고 로컬에서 인식 중…"
        productivityTask = Task {
            var completed = false
            checkpointWriteFailed = false
            defer {
                productivityBusy = false; transcriptionActive = false; transcriptionJobID = nil; productivityTask = nil; transcriptionDetail = nil
                refreshCheckpointSummaries()
                if completed && translateAfterTranscription { translateCaptionTracks() }
            }
            do {
                let begun = Date()
                var tracks: [Track] = []; var languages: Set<String> = []
                var reusedWindows = 0, totalWindows = 0
                var skippedSeconds = 0.0, analysedSeconds = 0.0, vadSeconds = 0.0, tightenedCues = 0, repeatedRemoved = 0, recoveredCues = 0
                var suspects = Set<UUID>()
                var reports: [UUID: VoiceActivityReport] = [:]
                for (index, entry) in sources.enumerated() {
                    try Task.checkCancellation()
                    let (_, clip, asset) = entry
                    let url = asset.resolvedURL(relativeTo: base)
                    var session: TranscriptionCheckpointSession? = nil
                    if useCheckpoints {
                        productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 원본 확인 중…"
                        // The key carries the CURRENT file digest: a file swapped at the same path
                        // gets a different key, so stale windows from the old file are never reused.
                        let digest = try await fingerprints.sha256(of: url)
                        session = TranscriptionCheckpointSession(store: store, key: TranscriptionCheckpointKey(
                            projectID: snapshot.id, clipID: clip.id, mediaSHA256: digest, sourceStart: clip.sourceStart, duration: clip.sourceDuration,
                            windowSeconds: windowSeconds, options: options, modelSHA256: configuration.modelSpec.sha256, skipsSilence: skipsNonSpeech))
                    }
                    var regions: [ClosedRange<Double>]? = nil
                    if skipsNonSpeech {
                        // A resumed run must skip exactly what the first run skipped: reuse its saved analysis.
                        let report: VoiceActivityReport
                        if let session, let saved = session.store.voiceActivity(for: session.key) { report = saved }
                        else {
                            productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 말소리·무음·음악 구간 분석 중…"
                            report = try await VoiceActivity.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration) { [weak self] fraction in
                                Task { @MainActor in
                                    guard let self, self.transcriptionJobID == jobID else { return }
                                    self.productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 말소리 구간 분석 \(Int(fraction * 100))%"
                                }
                            }
                            if let session { do { try session.store.saveVoiceActivity(report, for: session.key) } catch { checkpointWriteFailed = true } }
                            vadSeconds += report.analysisSeconds
                        }
                        reports[clip.id] = report; regions = report.speechRegions
                        skippedSeconds += report.duration - report.speechRegionSeconds; analysedSeconds += report.duration
                    }
                    productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 음성 인식 중…"
                    let result = try await LocalTranscription.transcribeLong(
                        url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, configuration: configuration, options: options,
                        windowSeconds: windowSeconds, checkpoint: session, speechRegions: regions, speechEvidence: reports[clip.id]?.confidentSpeech,
                        onCheckpointError: { [weak self] _ in Task { @MainActor in guard let self, self.transcriptionJobID == jobID else { return }; self.checkpointWriteFailed = true } },
                        detail: { [weak self] detail in
                            Task { @MainActor in
                                guard let self, self.transcriptionJobID == jobID else { return }
                                self.transcriptionDetail = detail
                            }
                        }) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.transcriptionJobID == jobID else { return }
                            if let fraction { self.transcriptionProgress = max(self.transcriptionProgress ?? 0, (Double(index) + fraction) / Double(sources.count)) }
                        }
                    }
                    reusedWindows += result.reusedWindows ?? 0
                    totalWindows += (result.reusedWindows ?? 0) + (result.computedWindows ?? 1) + (result.skippedWindows ?? 0)
                    languages.insert(result.language)
                    let languageLabel = CaptionLanguage(rawValue: result.language)?.label ?? result.language
                    var track = Track(name: "자동 자막 · \(languageLabel) · \(clip.name)", kind: .title)
                    var cues = result.cues
                    let suspectIndices = Set(cues.indices.filter { i in (result.repetitionSuspects ?? []).contains { abs($0 - cues[i].start.seconds) < 0.001 } })
                    if let report = reports[clip.id] { let t = VoiceActivity.tightened(cues, report: report); cues = t.cues; tightenedCues += t.changed }
                    let suspectStarts = suspectIndices.map { cues[$0].start.seconds }
                    repeatedRemoved += result.repeatedCuesRemoved ?? 0
                    recoveredCues += result.recoveredCues ?? 0
                    track.clips = CaptionEditing.automaticClips(cues: cues, source: clip, style: style)
                    for caption in track.clips where suspectStarts.contains(where: { abs($0 - (caption.connection?.sourceStart.seconds ?? -1)) < 0.01 }) { suspects.insert(caption.id) }
                    for ci in track.clips.indices {
                        let text = track.clips[ci].title?.text ?? ""
                        // Whisper reports the dominant clip language. Refine each cue from its
                        // recognized text so mixed-language clips can be translated per sentence.
                        let detected = SentenceLanguage.detect(text, clipLanguage: result.language)
                        var metadata = CaptionMetadata(language: detected.language, originalLanguage: detected.language, originalText: text, generatedText: text)
                        metadata.clipLanguage = result.language; metadata.languageConfidence = detected.confidence
                        metadata.languageNeedsReview = detected.needsReview ? true : nil
                        track.clips[ci].captionMetadata = metadata
                    }
                    if !track.clips.isEmpty { tracks.append(track) }
                }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("인식 중 프로젝트가 변경되었습니다. 자막을 잘못된 위치에 넣지 않도록 중단했습니다. 다시 실행하세요.") }
                guard !tracks.isEmpty else { throw ProjectError("인식된 자막이 없습니다. 대사가 있는 구간을 선택하세요.") }
                var commands: [EditCommand] = []
                // Visibility updates must precede cue edits: updateTrack replaces the whole track.
                let sourceIDs = Set(sources.map { $0.1.id })
                for var track in project.sequence.tracks where track.kind == .title && track.clips.contains(where: { $0.connection.map { sourceIDs.contains($0.parentID) } == true }) {
                    let translated = track.clips.allSatisfy { $0.captionMetadata?.translatedFrom != nil }
                    let original = track.clips.allSatisfy { $0.captionMetadata?.translatedFrom == nil }
                    if (translated && !track.isHidden) || (original && track.isHidden) { track.isHidden = translated; commands.append(.updateTrack(track)) }
                }
                if replaceExisting {
                    let ids = Set(sources.map { $0.1.id })
                    for oldTrack in project.sequence.tracks {
                        for caption in oldTrack.clips where caption.connection.map({ ids.contains($0.parentID) }) == true && caption.title != nil && caption.captionMetadata?.translatedFrom == nil {
                            // Preserve manually corrected text or a hand-set language; avoid generating another cue over it.
                            if caption.title?.text != caption.connection?.generatedText || caption.captionMetadata?.languageManual == true {
                                for ti in tracks.indices { tracks[ti].clips.removeAll { $0.connection?.parentID == caption.connection?.parentID && $0.start < caption.end && $0.end > caption.start } }
                            } else { commands.append(.delete(trackID: oldTrack.id, clipID: caption.id, ripple: false)) }
                        }
                    }
                }
                for track in tracks where !track.clips.isEmpty {
                    if replaceExisting, let parent = track.clips.first?.connection?.parentID,
                       let existing = project.sequence.tracks.first(where: { $0.kind == .title && $0.clips.contains(where: { $0.connection?.parentID == parent && $0.captionMetadata?.translatedFrom == nil }) }) {
                        commands += track.clips.map { .addClip(trackID: existing.id, clip: $0) }
                    } else { commands.append(.addTrack(track)) }
                }
                if perform(.batch(commands)) {
                    completed = true
                    detectedSpeechLanguages = languages.sorted().map { CaptionLanguage(rawValue: $0)?.label ?? $0 }.joined(separator: " · ")
                    transcriptionProgress = 1
                    if let first = tracks.first?.clips.first { selectClip(first.id); seek(first.start.seconds) }
                    let resumed = reusedWindows > 0 ? " · 체크포인트 \(reusedWindows)/\(totalWindows)구간 재사용" : ""
                    var warning = checkpointWriteFailed ? " · 체크포인트 저장 실패(자막은 정상 생성)" : ""
                    repetitionCaptionIDs = suspects
                    if repeatedRemoved > 0 { warning += " · 반복 인식 의심 \(repeatedRemoved)개 제거 · 남긴 \(suspects.count)개 검토 필요" }
                    if !reports.isEmpty {
                        warning += String(format: " · 비음성 %.0f초/%.0f초 인식 생략", skippedSeconds, analysedSeconds)
                        if recoveredCues > 0 { warning += " · 놓친 말소리 다시 인식해 자막 \(recoveredCues)개 복구" }
                        if tightenedCues > 0 { warning += " · 무음까지 늘어진 자막 \(tightenedCues)개 끝 맞춤" }
                        let flagged = flagSilentCaptions(reports: reports)
                        if flagged > 0 { warning += " · 무음·음악 위 자막 \(flagged)개 확인 필요" }
                        lastVoiceActivity = reports.values.first
                    }
                    productivityStatus = "자막 \(tracks.reduce(0) { $0 + $1.clips.count })개 생성 · \(String(format: "%.1f", Date().timeIntervalSince(begun)))초 소요" + resumed + warning
                    message = productivityStatus + " · 문구와 시간을 검토하세요. ⌘Z로 한 번에 되돌릴 수 있습니다."
                }
            } catch {
                transcriptionProgress = nil
                let kept = useCheckpoints ? store.summaries(projectID: snapshot.id, clipIDs: Set(sources.map { $0.1.id })).reduce(0) { $0 + $1.completedWindows } : 0
                let resumeNote = kept > 0 ? " · 완료된 \(kept)개 구간은 체크포인트에 보존했습니다. 다시 실행하면 이어서 인식합니다." : ""
                if Task.isCancelled { message = "음성 인식 취소됨 · 기존 자막은 유지됩니다." + resumeNote; productivityStatus = message }
                else { self.error = error.localizedDescription + resumeNote; productivityStatus = "자막 생성 실패 · 다시 시도할 수 있습니다." }
            }
        }
    }
    func installSpeechModel() {
        guard !busyDocument else { return }
        let spec = speechModelSpec
        let alert = NSAlert(); alert.messageText = "다국어 자동 자막 모델 설치"
        alert.informativeText = "\(spec.name)\n라이선스: \(spec.license)\n다운로드: \(spec.byteCount)바이트 · 필요 공간: \(spec.recommendedFreeBytes / 1_000_000)MB\n출처: \(spec.downloadURL.absoluteString)\n라이선스: \(spec.licenseURL.absoluteString)\nSHA-256: \(spec.sha256)\n\n설치 후 음성은 이 Mac에서만 처리됩니다."
        alert.addButton(withTitle: "동의하고 설치"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        productivityBusy = true; productivityStatus = "공식 한국어 다국어 모델 다운로드·체크섬 검증 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil; refreshTranscriptionStatus() }
            do { _ = try await WhisperModelInstaller.installModel(spec, approvedByUser: true); message = "Whisper 모델 설치 완료 · 선택한 음성 클립으로 자동 자막을 만드세요." }
            catch { if Task.isCancelled { message = "모델 설치 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    func cancelProductivity() { productivityTask?.cancel() }
    func refreshCheckpointSummaries() { checkpointSummaries = checkpointStore.summaries(projectID: project.id) }
    var selectedClipCheckpoints: [TranscriptionCheckpointSummary] {
        let ids = Set(selectedSpeechClips.map { $0.1.id })
        return checkpointSummaries.filter { ids.contains($0.key.clipID) }
    }
    func deleteSelectedCheckpoints() {
        guard !busyDocument else { return }
        let ids = Set(selectedSpeechClips.map { $0.1.id })
        do { let removed = try checkpointStore.removeAll(projectID: project.id, clipIDs: ids); message = "선택 클립의 인식 체크포인트 \(removed)개 삭제" }
        catch { self.error = "체크포인트 삭제 실패: " + error.localizedDescription }
        refreshCheckpointSummaries()
    }
    func deleteAllCheckpoints() {
        guard !busyDocument else { return }
        do { let removed = try checkpointStore.removeAll(); message = "모든 인식 체크포인트 \(removed)개 삭제" }
        catch { self.error = "체크포인트 삭제 실패: " + error.localizedDescription }
        refreshCheckpointSummaries()
    }
    /// Discards finished windows for the selection first, so every window is recognised again.
    func restartTranscriptionFromScratch() {
        guard !busyDocument, transcriptionReady, !selectedSpeechClips.isEmpty else { return }
        deleteSelectedCheckpoints(); transcribeSelection()
    }
    func separateSelectedAudio() {
        guard let (track, clip, asset) = selectedSound, asset.kind == .video, track.kind != .audio else { return }
        if perform(.separateAudio(trackID: track.id, clipID: clip.id)) { message = "원본 소리를 별도 트랙으로 분리했습니다. 영상의 소리는 음소거했습니다." }
    }
    func editAssetAtPlayhead(_ asset: MediaAsset, overwrite: Bool) {
        guard asset.supported, asset.kind != .audio, let track = project.sequence.tracks.first(where: { $0.kind == .video }) else { return }
        let clip = Clip(name: asset.name, assetID: asset.id, duration: asset.kind == .image ? MediaTime(3, 1) : asset.duration)
        let at = MediaTime(seconds: playhead)
        if perform(overwrite ? .overwriteClip(trackID: track.id, clip: clip, at: at) : .insertClip(trackID: track.id, clip: clip, at: at)) {
            selectClip(clip.id); message = "\(overwrite ? "덮어쓰기" : "삽입") 완료 · 연결 클립과 동기 편집 트랙을 함께 반영했습니다."
        }
    }
    func moveSelectedClip(to destination: Track) {
        guard let (track, clip) = selected, track.id != destination.id else { return }
        if perform(.batch([.delete(trackID: track.id, clipID: clip.id, ripple: false), .addClip(trackID: destination.id, clip: clip)])) { selectClip(clip.id) }
    }
    func addTrack(_ kind: TrackKind) {
        let name: String
        switch kind { case .video: name = "영상"; case .overlay: name = "오버레이"; case .audio: name = "오디오"; case .title: name = "자막" }
        perform(.addTrack(Track(name: name + " \(project.sequence.tracks.filter { $0.kind == kind }.count + 1)", kind: kind)))
    }
    func reorderTrack(_ track: Track, by offset: Int) {
        var sequence = project.sequence
        guard let index = sequence.tracks.firstIndex(where: { $0.id == track.id }), sequence.tracks.indices.contains(index + offset) else { return }
        sequence.tracks.swapAt(index, index + offset); perform(.replaceSequence(sequence))
    }
    func collectProject() {
        guard !busyDocument else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + " 원본 모음"; panel.canCreateDirectories = true
        panel.message = "새 폴더에 프로젝트와 모든 원본을 복사합니다. 원본 파일은 그대로 유지됩니다."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let snapshot = project, base = mediaBaseURL
        productivityBusy = true; productivityStatus = "프로젝트와 원본 파일 수집·검증 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            let worker = Task.detached { try ProjectCollector.collect(project: snapshot, documentURL: base, to: destination) }
            do {
                let url = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                message = "원본 수집 완료 · \(url.path)"; NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { if Task.isCancelled { message = "프로젝트 수집 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    func generateProxies() {
        guard !busyDocument else { return }
        let assets = project.assets.filter { $0.kind == .video && $0.supported }, base = mediaBaseURL, projectID = project.id
        guard !assets.isEmpty else { message = "프록시를 만들 영상이 없습니다."; return }
        proxyBusy = true; proxyProgress = 0; proxyStatus = "프록시 생성 중…"
        proxyTask = Task {
            defer { proxyBusy = false; proxyTask = nil }
            do {
                await proxyCache.setProtectedURLs(Array(proxyURLs.values))
                for (index, asset) in assets.enumerated() {
                    try Task.checkCancellation()
                    proxyStatus = "\(asset.name) 프록시 생성 (\(index + 1)/\(assets.count))"
                    let proxy = try await proxyCache.generate(for: asset.resolvedURL(relativeTo: base))
                    guard project.id == projectID, project.assets.first(where: { $0.id == asset.id }) == asset else { throw ProjectError("프록시 생성 중 원본 연결이 바뀌었습니다. 다시 생성하세요.") }
                    proxyURLs[asset.id] = proxy; await proxyCache.setProtectedURLs(Array(proxyURLs.values)); proxyProgress = Double(index + 1) / Double(assets.count)
                }
                proxyEnabled = true; proxyStatus = "프록시 \(proxyURLs.count)개 준비 · 출력은 항상 원본 사용"; rebuild()
            } catch { if Task.isCancelled { proxyStatus = "프록시 생성 취소됨" } else { self.error = error.localizedDescription; proxyStatus = "프록시 생성 실패" } }
        }
    }
    func cancelProxy() { proxyTask?.cancel() }
    func clearProxies() {
        guard !busyDocument else { return }
        proxyBusy = true
        proxyTask = Task {
            defer { proxyBusy = false; proxyTask = nil }
            proxyEnabled = false; proxyURLs = [:]; rebuild()
            do { await proxyCache.setProtectedURLs([]); try await proxyCache.removeAll(); proxyStatus = "프록시 캐시 삭제됨 · 원본 미디어 사용" }
            catch { self.error = error.localizedDescription }
        }
    }
    func mergeNextCaption() {
        guard let (track, clip) = selected, clip.title != nil else { return }
        let sorted = track.clips.sorted { $0.start < $1.start }
        guard let index = sorted.firstIndex(where: { $0.id == clip.id }), sorted.indices.contains(index + 1) else { return }
        do {
            let next = sorted[index + 1], merged = try CaptionEditing.merged(first: clip, second: sorted[index + 1])
            perform(.batch([.delete(trackID: track.id, clipID: next.id, ripple: false), .updateClip(trackID: track.id, clip: merged)]))
        } catch { self.error = error.localizedDescription }
    }
    func offsetCaptions(_ seconds: Double) {
        guard seconds.isFinite, abs(seconds) < 86400 else { error = "24시간 미만의 자막 이동 시간을 입력하세요."; return }
        do {
            let offset = MediaTime(seconds: seconds)
            var commands: [EditCommand] = []
            for track in project.sequence.tracks where track.kind == .title {
                commands += try CaptionEditing.shifted(track.clips, by: offset).map { .updateClip(trackID: track.id, clip: $0) }
            }
            if !commands.isEmpty { perform(.batch(commands)) }
        } catch { self.error = error.localizedDescription }
    }
}

// Voice-activity helpers used right after recognition (upgrade 7).
extension EditorModel {
    /// Marks original captions of the analysed clips that sit over silence, music or noise.
    /// Returns how many were flagged. Nothing in the document changes.
    @discardableResult func flagSilentCaptions(reports: [UUID: VoiceActivityReport]) -> Int {
        var flagged = 0
        for (clipID, report) in reports {
            guard let clip = project.sequence.tracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { continue }
            // Same source-time mapping as sourceTimedCaptions, kept paired with each caption's id.
            let rate = clip.playbackRate ?? PlaybackRate()
            var ids: [UUID] = [], ranges: [ClosedRange<Double>] = []
            for caption in project.sequence.tracks.filter({ $0.kind == .title }).flatMap(\.clips) where caption.title != nil && caption.captionMetadata?.translatedFrom == nil {
                if let link = caption.connection {
                    guard link.parentID == clip.id else { continue }
                    ids.append(caption.id); ranges.append(link.sourceStart.seconds...(link.sourceStart + link.sourceDuration).seconds)
                } else if caption.start >= clip.start, caption.end <= clip.end {
                    let a = clip.sourceStart.seconds + (caption.start - clip.start).seconds * rate.multiplier
                    ids.append(caption.id); ranges.append(a...(a + caption.duration.seconds * rate.multiplier))
                }
            }
            for id in ids { silentCaptionWarnings[id] = nil }
            for warning in VoiceActivity.silentCaptions(ranges, report: report) {
                silentCaptionWarnings[ids[warning.index]] = warning.kind; flagged += 1
            }
        }
        return flagged
    }
}

enum VoiceActivitySummary {
    static func describe(_ report: VoiceActivityReport) -> String {
        func m(_ s: Double) -> String { s >= 60 ? String(format: "%.1f분", s / 60) : String(format: "%.0f초", s) }
        var parts = ["말소리 \(m(report.seconds(of: .speech)))", "무음 \(m(report.seconds(of: .silence)))"]
        if report.classifierAvailable {
            parts.append("음악 \(m(report.seconds(of: .music)))"); parts.append("강한 소음 \(m(report.seconds(of: .noise)))"); parts.append("불확실 \(m(report.seconds(of: .uncertain)))")
        } else { parts.append("소리 분류기 사용 불가 · 무음만 구분") }
        parts.append(String(format: "인식 생략 가능 %.0f%%", report.skippableShare * 100))
        return parts.joined(separator: " · ")
    }
}

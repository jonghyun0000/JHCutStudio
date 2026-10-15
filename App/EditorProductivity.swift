import SwiftUI
import AppKit
import JHCutCore

extension EditorModel {
    func resetProductivityState() {
        invalidateAsyncJobs()
        analyzedContext = nil; analyzedSource = nil
        audioResult = nil; analyzedClip = nil; analyzedAsset = nil; analyzedProjectID = nil
        loopEnabled = false; loopStart = 0; loopEnd = 0; mixStatus = ""; detectedSpeechLanguages = ""
        proxyURLs = [:]; proxyEnabled = false; proxyStatus = "원본 미디어로 미리보기"
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
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                let identity = try await EditorSourceIdentity.capture(url)
                let result = try await AudioAnalysis.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration)
                try await checkpointAsyncJob(ticket, "audio.beforeApply")
                try await identity.validate(); try validateAsyncJob(ticket)
                try Task.checkCancellation()
                guard project.id == projectID else { return }
                audioResult = result; analyzedClip = clip; analyzedAsset = asset; analyzedProjectID = projectID
                analyzedContext = ticket.context; analyzedSource = identity
                productivityStatus = "오디오 분석 완료 · 원본 피크/RMS · 무음 후보 \(result.silenceRegions.count)개"
                message = productivityStatus
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "분석 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    var analysisMatchesSelection: Bool {
        guard let (_, clip, asset) = selectedSound else { return false }
        return analyzedProjectID == project.id && analyzedClip == clip && analyzedAsset == asset
            && analyzedContext.map(contextMatches) == true && analyzedSource?.statMatches == true
    }
    func normalizePeak() {
        guard !busyDocument, analysisMatchesSelection, let result = audioResult, let (_, original, _) = selectedSound,
              let gain = result.normalizationGain, let (track, _) = selected else { return }
        guard let source = analyzedSource else { return }
        productivityStatus = "원본 확인 후 음량 조정 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try await source.validate()
                try await checkpointAsyncJob(ticket, "normalize.beforeApply")
                try await source.validate(); try validateAsyncJob(ticket)
                var clip = original
                // Source target replaces the static fader; envelopes retain their relative shape.
                let divisor = original.volume > 0 ? original.volume : 1
                let keyVolumes = (clip.keyframes ?? []).map { $0.volume / divisor * gain }
                guard gain <= 4, keyVolumes.allSatisfy({ $0 <= 4 }) else { error = "정규화에 4배 이상의 볼륨이 필요합니다. 자동으로 제한하지 않았습니다. 속성에서 직접 조절하세요."; return }
                clip.volume = gain
                if clip.keyframes != nil { for i in clip.keyframes!.indices { clip.keyframes![i].volume = keyVolumes[i] } }
                if perform(.updateClip(trackID: track.id, clip: clip)) {
                    let achieved = (result.peakDBFS ?? 0) + (result.normalizationGainDB ?? 0)
                    message = "원본 피크 \(String(format: "%.1f", achieved))dBFS 조정\(result.normalizationBoostLimited ? " · +12dB 증폭 상한 적용" : "") · 믹스 후 최종 음량은 달라질 수 있습니다."
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "음량 조정 취소됨" } else { self.error = error.localizedDescription }
            }
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
        let skipsNonSpeech = skipNonSpeech, activityPolicy = voiceActivityPolicy
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; transcriptionActive = true; transcriptionProgress = 0; transcriptionJobID = jobID; transcriptionDetail = nil
        productivityStatus = "음성 언어를 확인하고 로컬에서 인식 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            var completed = false
            checkpointWriteFailed = false
            defer {
                if ownsAsyncJob(ticket) {
                    transcriptionActive = false; transcriptionJobID = nil; transcriptionAnalysisClipID = nil; transcriptionDetail = nil
                    finishAsyncJob(ticket)
                    refreshCheckpointSummaries()
                    if completed && translateAfterTranscription { translateCaptionTracks(scope: .sources(Set(sources.map { $0.1.id }))) }
                }
            }
            do {
                try validateAsyncJob(ticket)
                let begun = Date()
                var tracks: [Track] = []; var languages: Set<String> = []
                var reusedWindows = 0, totalWindows = 0
                var skippedSeconds = 0.0, analysedSeconds = 0.0, vadSeconds = 0.0, tightenedCues = 0, recoveredCues = 0
                var suspects = Set<UUID>()
                var reports: [UUID: VoiceActivityReport] = [:]
                var sourceStamps: [URL:String] = [:]
                for (index, entry) in sources.enumerated() {
                    try validateAsyncJob(ticket)
                    let (_, clip, asset) = entry
                    let url = asset.resolvedURL(relativeTo: base)
                    let sourceStamp = try MediaFingerprintCache.stat(url)
                    sourceStamps[url] = sourceStamp
                    var session: TranscriptionCheckpointSession?
                    var checkpointLease: TranscriptionCacheLease?
                    defer { checkpointLease?.finish() }
                    if useCheckpoints {
                        productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 원본 확인 중…"
                        // The key carries the CURRENT file digest: a file swapped at the same path
                        // gets a different key, so stale windows from the old file are never reused.
                        let digest = try await fingerprints.sha256(of: url)
                        session = TranscriptionCheckpointSession(store: store, key: TranscriptionCheckpointKey(
                            projectID: snapshot.id, clipID: clip.id, mediaSHA256: digest, sourceStart: clip.sourceStart, duration: clip.sourceDuration,
                            windowSeconds: windowSeconds, options: options, modelSHA256: configuration.modelSpec.sha256, skipsSilence: skipsNonSpeech, voiceActivityPolicy: activityPolicy))
                    }
                    if let created = session {
                        do { checkpointLease = try store.beginSession(for:created.key); session = TranscriptionCheckpointSession(store:store,key:created.key,lease:checkpointLease) }
                        catch let e as TranscriptionCacheError { throw e }
                        catch { checkpointWriteFailed = true; session = nil }
                    }
                    var regions: [ClosedRange<Double>]? = nil
                    if skipsNonSpeech {
                        // A resumed run must skip exactly what the first run skipped: reuse its saved analysis.
                        let report: VoiceActivityReport
                        if let session, let saved = session.store.voiceActivity(for: session.key) { report = saved }
                        else {
                            productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 말소리·무음·음악 구간 분석 중…"
                            transcriptionAnalysisClipID = clip.id
                            report = try await VoiceActivity.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, preferredChannel: options.channel, policy: activityPolicy) { [weak self] fraction in
                                Task { @MainActor in
                                    guard let self, self.transcriptionJobID == jobID, self.acceptsAsyncProgress(ticket), self.transcriptionAnalysisClipID == clip.id else { return }
                                    self.transcriptionProgress = max(self.transcriptionProgress ?? 0, (Double(index) + 0.08 * fraction) / Double(sources.count))
                                    self.productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 말소리 구간 분석 \(Int(fraction * 100))%"
                                }
                            }
                            try validateAsyncJob(ticket)
                            transcriptionAnalysisClipID = nil
                            guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("말소리 분석 중 원본 미디어가 바뀌었습니다.") }
                            if let session { do { try session.store.saveVoiceActivity(report, for: session.key) } catch { checkpointWriteFailed = true } }
                            vadSeconds += report.analysisSeconds
                        }
                        guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("말소리 분석 중 원본 미디어가 바뀌었습니다. 다시 인식하세요.") }
                        reports[clip.id] = report; regions = report.speechRegions
                        skippedSeconds += report.duration - report.speechRegionSeconds; analysedSeconds += report.duration
                    }
                    productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 음성 인식 중…"
                    let result = try await LocalTranscription.transcribeLong(
                        url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, configuration: configuration, options: options,
                        windowSeconds: windowSeconds, checkpoint: session, speechRegions: regions, speechEvidence: reports[clip.id]?.confidentSpeech, audioSelection: reports[clip.id]?.channelSelection, speechPolicy: activityPolicy,
                        onCheckpointError: { [weak self] _ in Task { @MainActor in guard let self, self.transcriptionJobID == jobID, self.acceptsAsyncProgress(ticket) else { return }; self.checkpointWriteFailed = true } },
                        detail: { [weak self] detail in
                            Task { @MainActor in
                                guard let self, self.transcriptionJobID == jobID, self.acceptsAsyncProgress(ticket) else { return }
                                self.transcriptionDetail = detail
                            }
                        }) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.transcriptionJobID == jobID, self.acceptsAsyncProgress(ticket) else { return }
                            if let fraction { self.transcriptionProgress = max(self.transcriptionProgress ?? 0, (Double(index) + (skipsNonSpeech ? 0.08 + 0.92 * fraction : fraction)) / Double(sources.count)) }
                        }
                    }
                    try validateAsyncJob(ticket)
                    reusedWindows += result.reusedWindows ?? 0
                    totalWindows += (result.reusedWindows ?? 0) + (result.computedWindows ?? 1) + (result.skippedWindows ?? 0)
                    languages.insert(result.language)
                    let languageLabel = CaptionLanguage(rawValue: result.language)?.label ?? result.language
                    var track = Track(name: "자동 자막 · \(languageLabel) · \(clip.name)", kind: .title)
                    var cues = result.cues
                    let suspectIndices = Set(cues.indices.filter { i in (result.repetitionSuspects ?? []).contains { abs($0 - cues[i].start.seconds) < 0.001 } })
                    if let report = reports[clip.id] { let t = VoiceActivity.tightened(cues, report: report); cues = t.cues; tightenedCues += t.changed }
                    let suspectStarts = suspectIndices.map { cues[$0].start.seconds }
                    recoveredCues += result.recoveredCues ?? 0
                    track.clips = CaptionEditing.automaticClips(cues: cues, source: clip, style: style)
                    for caption in track.clips where suspectStarts.contains(where: { abs($0 - (caption.connection?.sourceStart.seconds ?? -1)) < 0.01 }) { suspects.insert(caption.id) }
                    for ci in track.clips.indices {
                        let text = track.clips[ci].title?.text ?? ""
                        // Whisper reports the dominant clip language. Refine each cue from its
                        // recognized text so mixed-language clips can be translated per sentence.
                        let connection = track.clips[ci].connection
                        let a = connection?.sourceStart.seconds ?? result.sourceStart.seconds
                        let b = a + (connection?.sourceDuration.seconds ?? track.clips[ci].duration.seconds)
                        let detected = SourceLanguageAnalysis.decision(text:text,start:a,end:b,clipLanguage:result.language,requestedLanguage:options.language,observations:result.languageObservations ?? [])
                        var metadata = CaptionMetadata(language: detected.language, originalLanguage: detected.language, originalText: text, generatedText: text)
                        metadata.clipLanguage = result.language; metadata.languageConfidence = detected.confidence
                        metadata.languageOrigin = detected.origin; metadata.languageEvidence = detected.evidence
                        metadata.languageManual = detected.origin == .manual ? true:nil
                        metadata.languageNeedsReview = detected.needsReview ? true : nil
                        track.clips[ci].captionMetadata = metadata
                    }
                    if !track.clips.isEmpty { tracks.append(track) }
                }
                try Task.checkCancellation()
                for (url,stamp) in sourceStamps { guard try MediaFingerprintCache.stat(url) == stamp else { throw ProjectError("인식 중 원본 미디어가 바뀌었습니다. 자막을 적용하지 않았습니다.") } }
                try await checkpointAsyncJob(ticket, "asr.beforeApply")
                for (url,stamp) in sourceStamps { guard try MediaFingerprintCache.stat(url) == stamp else { throw ProjectError("인식 중 원본 미디어가 바뀌었습니다.") } }
                guard project == snapshot else { throw ProjectError("인식 중 프로젝트가 변경되었습니다. 자막을 잘못된 위치에 넣지 않도록 중단했습니다. 다시 실행하세요.") }
                guard !tracks.isEmpty else { throw ProjectError("인식된 자막이 없습니다. 대사가 있는 구간을 선택하세요.") }
                var commands: [EditCommand] = []
                let sourceIDs = Set(sources.map { $0.1.id })
                for entry in CaptionQuery.entries(in: project.sequence, scope: .sources(sourceIDs)) {
                    let hidden = entry.role == .translation
                    if !entry.track.isLocked, (entry.clip.captionHidden == true) != hidden {
                        var clip = entry.clip; clip.captionHidden = hidden ? true : nil
                        commands.append(.updateClip(trackID: entry.track.id, clip: clip))
                    }
                }
                if replaceExisting {
                    let ids = Set(sources.map { $0.1.id })
                    for oldTrack in project.sequence.tracks {
                        for caption in oldTrack.clips where caption.connection.map({ ids.contains($0.parentID) }) == true && CaptionQuery.role(of: caption) == .original {
                            // Preserve manually corrected text or a hand-set language; avoid generating another cue over it.
                            if CaptionLanguagePreservation.shouldKeep(caption,trackLocked:oldTrack.isLocked,in:project.sequence) {
                                for ti in tracks.indices { tracks[ti].clips.removeAll { $0.connection?.parentID == caption.connection?.parentID && $0.start < caption.end && $0.end > caption.start } }
                            } else { commands.append(.delete(trackID: oldTrack.id, clipID: caption.id, ripple: false)) }
                        }
                    }
                }
                for track in tracks where !track.clips.isEmpty {
                    if replaceExisting, let parent = track.clips.first?.connection?.parentID,
                       let existing = project.sequence.tracks.first(where: { $0.kind == .title && !$0.isLocked && $0.clips.contains(where: { $0.connection?.parentID == parent && CaptionQuery.role(of: $0) == .original }) }) {
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
                    if !suspects.isEmpty { warning += " · 반복 인식 의심 \(suspects.count)개 보존 · 원음 검토 필요" }
                    if !reports.isEmpty {
                        warning += String(format: " · %@ · 비음성 %.0f초/%.0f초 인식 생략", activityPolicy.label, skippedSeconds, analysedSeconds)
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
                guard ownsAsyncJob(ticket) else { return }
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
        let alert = NSAlert(); alert.messageText = UIL10n.text("다국어 자동 자막 모델 설치")
        alert.informativeText = UIL10n.format("ui.speech.install.consent", spec.name, spec.license, spec.byteCount, spec.recommendedFreeBytes / 1_000_000, spec.downloadURL.absoluteString, spec.licenseURL.absoluteString, spec.sha256)
        alert.addButton(withTitle: UIL10n.text("동의하고 설치")); alert.addButton(withTitle: UIL10n.text("취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        productivityBusy = true; productivityStatus = "공식 한국어 다국어 모델 다운로드·체크섬 검증 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { if ownsAsyncJob(ticket) { finishAsyncJob(ticket); refreshTranscriptionStatus() } }
            do {
                try validateAsyncJob(ticket)
                _ = try await WhisperModelInstaller.installModel(spec, approvedByUser: true)
                try await checkpointAsyncJob(ticket, "model.beforeComplete")
                message = "Whisper 모델 설치 완료 · 선택한 음성 클립으로 자동 자막을 만드세요."
            }
            catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "모델 설치 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    func cancelProductivity() { productivityCancelRequested = true; productivityTask?.cancel() }
    func refreshCheckpointSummaries() {
        checkpointRefreshTask?.cancel(); checkpointRefreshID = UUID()
        let context = asyncContext()
        let refreshID = checkpointRefreshID, projectID = project.id, sources = selectedSpeechClips, base = mediaBaseURL, fingerprints = mediaFingerprints
        checkpointSummaries = checkpointStore.summaries(projectID:projectID); checkpointMediaHashes = [:]; checkpointMediaPaths = [:]; checkpointMediaStamps = [:]
        guard !sources.isEmpty else { return }
        checkpointRefreshTask = Task { [weak self] in
            // Settings edits can arrive in bursts; cancelled refreshes do not publish stale digests.
            do {
                try await Task.sleep(nanoseconds:250_000_000)
                var hashes: [UUID:String] = [:], paths: [UUID:String] = [:], stamps: [UUID:String] = [:]
                for (_,clip,asset) in sources {
                    try Task.checkCancellation(); let url = asset.resolvedURL(relativeTo:base), stamp = try MediaFingerprintCache.stat(url)
                    hashes[clip.id] = try await fingerprints.sha256(of:url)
                    guard try MediaFingerprintCache.stat(url) == stamp else { throw ProjectError("재개 확인 중 미디어가 바뀌었습니다.") }
                    paths[clip.id] = url.standardizedFileURL.path; stamps[clip.id] = stamp
                }
                guard let self, !Task.isCancelled, self.checkpointRefreshID == refreshID, self.contextMatches(context) else { return }
                self.checkpointMediaPaths = paths; self.checkpointMediaStamps = stamps; self.checkpointMediaHashes = hashes
            } catch { /* A hash failure cannot advertise resumable work; no URL-path fallback. */ }
        }
    }
    var selectedCheckpointRecords: [TranscriptionCheckpointSummary] {
        let ids = Set(selectedSpeechClips.map { $0.1.id })
        return checkpointSummaries.filter { $0.key.projectID == project.id && ids.contains($0.key.clipID) }
    }
    var selectedClipCheckpoints: [TranscriptionCheckpointSummary] {
        guard useSpeechCheckpoints else { return [] }
        return selectedCheckpointRecords.filter { summary in
            guard summary.completedWindows > 0, let digest = checkpointMediaHashes[summary.key.clipID], let source = selectedSpeechClips.first(where:{ $0.1.id == summary.key.clipID }) else { return false }
            let sourceURL = source.2.resolvedURL(relativeTo:mediaBaseURL)
            guard checkpointMediaPaths[source.1.id] == sourceURL.standardizedFileURL.path, checkpointMediaStamps[source.1.id] == (try? MediaFingerprintCache.stat(sourceURL)) else { return false }
            let expected = TranscriptionCheckpointKey(projectID:project.id,clipID:source.1.id,mediaSHA256:digest,sourceStart:source.1.sourceStart,duration:source.1.sourceDuration,windowSeconds:speechWindowSeconds,options:speechOptions,modelSHA256:speechModelSpec.sha256,skipsSilence:skipNonSpeech,voiceActivityPolicy:voiceActivityPolicy)
            return summary.key.isReusable && summary.key == expected
        }
    }
    func cleanInactiveCheckpoints() {
        guard !busyDocument else { return }
        do { let result = try checkpointStore.maintain(); message = "오래된 인식 기록 \(result.removedFolders)개 정리 · 사용 중 \(result.protectedFolders)개 보존" }
        catch { self.error = error.localizedDescription }
        refreshCheckpointSummaries()
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
        do { let removed = try checkpointStore.removeAll(); message = "인식 체크포인트 \(removed)개 삭제 · 사용 중인 기록은 보존" }
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
    func collectProject(destinationURL: URL? = nil, revealsResult: Bool = true) {
        guard !busyDocument else { return }
        let destination: URL
        if let destinationURL { destination = destinationURL }
        else {
            let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + " 원본 모음"; panel.canCreateDirectories = true
            panel.message = "새 폴더에 프로젝트와 모든 원본을 복사합니다. 원본 파일은 그대로 유지됩니다."
            guard panel.runModal() == .OK, let selected = panel.url else { return }; destination = selected
        }
        let snapshot = project, base = mediaBaseURL
        productivityStatus = "프로젝트와 원본 파일 수집·검증 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try await checkpointAsyncJob(ticket, "collection.beforeWork")
                let worker = Task.detached { try ProjectCollector.collect(project: snapshot, documentURL: base, to: destination) }
                defer { worker.cancel() }
                let url = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try await checkpointAsyncJob(ticket, "collection.beforeComplete")
                message = "원본 수집 완료 · \(url.path)"
                if revealsResult { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "프로젝트 수집 취소됨" } else { self.error = error.localizedDescription }
            }
        }
    }
    func generateProxies() {
        guard !busyDocument else { return }
        let assets = project.assets.filter { $0.kind == .video && $0.supported }, base = mediaBaseURL
        guard !assets.isEmpty else { message = "프록시를 만들 영상이 없습니다."; return }
        proxyProgress = 0; proxyStatus = "프록시 생성 중…"
        let ticket = beginAsyncJob(.proxy), protected = Array(proxyURLs.values)
        proxyTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                await proxyCache.setProtectedURLs(protected)
                try validateAsyncJob(ticket)
                var generated = proxyURLs, identities: [EditorSourceIdentity] = []
                for (index, asset) in assets.enumerated() {
                    try validateAsyncJob(ticket)
                    proxyStatus = "\(asset.name) 프록시 생성 (\(index + 1)/\(assets.count))"
                    let identity = try await EditorSourceIdentity.capture(asset.resolvedURL(relativeTo: base))
                    let proxy = try await proxyCache.generate(for: identity.url)
                    try await identity.validate(); try validateAsyncJob(ticket)
                    identities.append(identity); generated[asset.id] = proxy
                    proxyProgress = Double(index + 1) / Double(assets.count)
                }
                try await checkpointAsyncJob(ticket, "proxy.beforeApply")
                for identity in identities { try await identity.validate() }
                try validateAsyncJob(ticket)
                // No partially generated mapping is published into a later document.
                proxyURLs = generated
                await proxyCache.setProtectedURLs(Array(generated.values))
                try validateAsyncJob(ticket)
                proxyEnabled = true; proxyStatus = "프록시 \(proxyURLs.count)개 준비 · 출력은 항상 원본 사용"; rebuild()
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { proxyStatus = "프록시 생성 취소됨" }
                else { self.error = error.localizedDescription; proxyStatus = "프록시 생성 실패 · 기존 미리보기 유지" }
            }
        }
    }
    func cancelProxy() { proxyCancelRequested = true; proxyTask?.cancel() }
    func clearProxies() {
        guard !busyDocument else { return }
        let ticket = beginAsyncJob(.proxy)
        proxyTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try await checkpointAsyncJob(ticket, "proxy.beforeClear")
                proxyEnabled = false; proxyURLs = [:]; rebuild()
                await proxyCache.setProtectedURLs([])
                try validateAsyncJob(ticket)
                try await proxyCache.removeAll()
                try await checkpointAsyncJob(ticket, "proxy.afterClear")
                proxyStatus = "프록시 캐시 삭제됨 · 원본 미디어 사용"
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { proxyStatus = "프록시 삭제 취소됨" } else { self.error = error.localizedDescription }
            }
        }
    }
    func mergeNextCaption(preview: Bool = false) {
        guard !busyDocument else { return }
        guard let (track, clip) = selected, clip.title != nil else { return }
        guard let selectedEntry = CaptionQuery.entries(in: project.sequence, scope: .selected([clip.id])).first else { return }
        let sorted = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, role: selectedEntry.role,
                                          visibleOnly: true, editableOnly: true)
            .filter { $0.track.id == track.id && $0.groupID == selectedEntry.groupID }.map { entry -> Clip in
                var normalized = entry.clip; normalized.captionRole = entry.role; normalized.captionGroupID = entry.groupID; return normalized
            }
        guard let index = sorted.firstIndex(where: { $0.id == clip.id }), sorted.indices.contains(index + 1) else {
            error = "작업 범위에 같은 그룹의 다음 자막이 없습니다. 두 자막을 선택하거나 그룹 범위를 사용하세요."; return
        }
        do {
            let first = sorted[index], next = sorted[index + 1]
            if selectedEntry.role == .original, (first.lineageID ?? first.id) != (next.lineageID ?? next.id),
               CaptionQuery.entries(in: project.sequence, role: .translation).contains(where: { CaptionQuery.related($0.clip, to: first) || CaptionQuery.related($0.clip, to: next) }) {
                throw ProjectError("번역이 연결된 서로 다른 원문은 합칠 수 없습니다. 번역 연결 손실을 방지하기 위해 원문과 번역을 보존했습니다.")
            }
            let merged = try CaptionEditing.merged(first: first, second: next)
            let commands: [EditCommand] = [.delete(trackID: track.id, clipID: next.id, ripple: false), .updateClip(trackID: track.id, clip: merged)]
            if preview { prepareCaptionProposal(commands, label: "다음 자막과 합치기") } else { perform(.batch(commands)) }
        } catch { self.error = error.localizedDescription }
    }
    func offsetCaptions(_ seconds: Double, preview: Bool = false) {
        guard !busyDocument else { return }
        guard seconds.isFinite, abs(seconds) < 86400 else { error = "24시간 미만의 자막 이동 시간을 입력하세요."; return }
        do {
            let offset = MediaTime(seconds: seconds)
            var commands: [EditCommand] = []
            for entry in CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true) {
                let shifted = try CaptionEditing.shifted([entry.clip], by: offset)[0]
                commands.append(.updateClip(trackID: entry.track.id, clip: shifted))
            }
            if !commands.isEmpty {
                if preview { prepareCaptionProposal(commands, label: "범위의 자막 시간 이동") } else { perform(.batch(commands)) }
            }
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
            for caption in CaptionQuery.entries(in: project.sequence, role: .original).map(\.clip) {
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
        var parts = [report.policy.label, "말소리 \(m(report.seconds(of: .speech)))", "무음 \(m(report.seconds(of: .silence)))"]
        if let selection = report.channelSelection { parts.append("분석 채널 " + selection.channels.map { String($0 + 1) }.joined(separator: "+")) }
        if report.classifierAvailable {
            parts.append("음악 \(m(report.seconds(of: .music)))"); parts.append("강한 소음 \(m(report.seconds(of: .noise)))"); parts.append("불확실 \(m(report.seconds(of: .uncertain)))")
        } else { parts.append("소리 분류기 사용 불가 · 무음만 구분") }
        parts.append(String(format: "인식 생략 가능 %.0f%%", report.skippableShare * 100))
        return parts.joined(separator: " · ")
    }
}

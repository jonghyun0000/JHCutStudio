import SwiftUI
import AppKit
import JHCutCore

extension EditorModel {
    func resetProductivityState() {
        audioResult = nil; analyzedClip = nil; analyzedAsset = nil; analyzedProjectID = nil
        proxyURLs = [:]; Task { await proxyCache.setProtectedURLs([]) }; proxyEnabled = false; proxyStatus = "원본 미디어로 미리보기"
    }
    func refreshTranscriptionStatus() {
        let value = LocalTranscription.availability()
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
        var style = allTitlePresets.first(where: { $0.id == transcriptionPresetID })?.title ?? TitlePreset.builtIns[0].title
        // Built-in styles are authored at a 1080px short edge. Keep captions legible and
        // inside the canvas when generating for small landscape or larger 4K sequences.
        if TitlePreset.builtIns.contains(where: { $0.id == transcriptionPresetID }) {
            let scale = Double(min(snapshot.sequence.width, snapshot.sequence.height)) / 1080
            style.fontSize *= scale
            style.style?.strokeWidth *= scale
            style.style?.padding *= scale
            style.style?.lineSpacing *= scale
        }
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; transcriptionActive = true; transcriptionProgress = 0; transcriptionJobID = jobID
        productivityStatus = "한국어 음성을 로컬에서 인식 중…"
        productivityTask = Task {
            defer { productivityBusy = false; transcriptionActive = false; transcriptionJobID = nil; productivityTask = nil }
            do {
                let begun = Date()
                var tracks: [Track] = []
                for (index, entry) in sources.enumerated() {
                    try Task.checkCancellation()
                    let (_, clip, asset) = entry
                    productivityStatus = "\(index + 1)/\(sources.count) · \(clip.name) 음성 인식 중…"
                    let result = try await LocalTranscription.transcribe(url: asset.resolvedURL(relativeTo: base), sourceStart: clip.sourceStart, duration: clip.sourceDuration) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.transcriptionJobID == jobID else { return }
                            if let fraction { self.transcriptionProgress = (Double(index) + fraction) / Double(sources.count) }
                        }
                    }
                    var track = Track(name: "자동 자막 · \(clip.name)", kind: .title)
                    track.clips = CaptionEditing.automaticClips(cues: result.cues, source: clip, style: style)
                    if !track.clips.isEmpty { tracks.append(track) }
                }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("인식 중 프로젝트가 변경되었습니다. 자막을 잘못된 위치에 넣지 않도록 중단했습니다. 다시 실행하세요.") }
                guard !tracks.isEmpty else { throw ProjectError("인식된 자막이 없습니다. 대사가 있는 구간을 선택하세요.") }
                if perform(.batch(tracks.map(EditCommand.addTrack))) {
                    transcriptionProgress = 1
                    if let first = tracks.first?.clips.first { selectClip(first.id); seek(first.start.seconds) }
                    productivityStatus = "자막 \(tracks.reduce(0) { $0 + $1.clips.count })개 생성 · \(String(format: "%.1f", Date().timeIntervalSince(begun)))초 소요"
                    message = productivityStatus + " · 문구와 시간을 검토하세요. ⌘Z로 한 번에 되돌릴 수 있습니다."
                }
            } catch {
                transcriptionProgress = nil
                if Task.isCancelled { message = "음성 인식 취소됨 · 기존 자막은 유지됩니다."; productivityStatus = message }
                else { self.error = error.localizedDescription; productivityStatus = "자막 생성 실패 · 다시 시도할 수 있습니다." }
            }
        }
    }
    func installSpeechModel() {
        guard !busyDocument else { return }
        let spec = WhisperModelSpec.base
        let alert = NSAlert(); alert.messageText = "한국어 자동 자막 모델 설치"
        alert.informativeText = "\(spec.name)\n라이선스: \(spec.license)\n다운로드: \(spec.byteCount)바이트 · 필요 공간: \(spec.recommendedFreeBytes / 1_000_000)MB\n출처: \(spec.downloadURL.absoluteString)\n라이선스: \(spec.licenseURL.absoluteString)\nSHA-256: \(spec.sha256)\n\n설치 후 음성은 이 Mac에서만 처리됩니다."
        alert.addButton(withTitle: "동의하고 설치"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        productivityBusy = true; productivityStatus = "공식 한국어 다국어 모델 다운로드·체크섬 검증 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil; refreshTranscriptionStatus() }
            do { _ = try await WhisperModelInstaller.installBaseModel(approvedByUser: true); message = "Whisper 모델 설치 완료 · 선택한 음성 클립으로 자동 자막을 만드세요." }
            catch { if Task.isCancelled { message = "모델 설치 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    func cancelProductivity() { productivityTask?.cancel() }
    func separateSelectedAudio() {
        guard let (track, clip, asset) = selectedSound, asset.kind == .video, track.kind != .audio else { return }
        if perform(.separateAudio(trackID: track.id, clipID: clip.id)) { message = "원본 소리를 별도 트랙으로 분리했습니다. 영상의 소리는 음소거했습니다." }
    }
    func editAssetAtPlayhead(_ asset: MediaAsset, overwrite: Bool) {
        guard asset.supported, asset.kind != .audio, let track = project.sequence.tracks.first(where: { $0.kind == .video }) else { return }
        let clip = Clip(name: asset.name, assetID: asset.id, duration: asset.kind == .image ? MediaTime(3, 1) : asset.duration)
        let at = MediaTime(seconds: playhead)
        if perform(overwrite ? .overwriteClip(trackID: track.id, clip: clip, at: at) : .insertClip(trackID: track.id, clip: clip, at: at)) {
            selectClip(clip.id); message = "\(overwrite ? "덮어쓰기" : "삽입") 완료 · 메인 영상 트랙만 변경됩니다. 자막·오디오 싱크를 확인하세요."
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

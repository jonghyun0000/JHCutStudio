import Foundation
import AppKit
import AVFoundation
import JHCutCore

extension EditorModel {
    func relinkMissingFolder() {
        guard !busyDocument else { return }
        let snapshot = project
        let missing = snapshot.assets.filter { !FileManager.default.fileExists(atPath: $0.resolvedURL(relativeTo: mediaBaseURL).path) }
        guard !missing.isEmpty else { message = "누락된 미디어가 없습니다."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "원본이 있는 폴더를 선택하세요. 파일 이름과 내용이 모두 같은 원본만 자동 연결합니다."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        productivityBusy = true; productivityStatus = "폴더에서 누락된 원본 확인 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let replacements = try await FolderRelinking.replacements(for: missing, folder: folder)
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("프로젝트가 변경되었습니다. 원본 찾기를 다시 실행하세요.") }
                if !replacements.isEmpty, !perform(.batch(replacements.map { .replaceAsset($0) })) { return }
                for asset in replacements { proxyURLs[asset.id] = nil }
                message = "\(replacements.count)/\(missing.count)개 원본 연결됨 · 남은 파일은 개별 재연결로 확인하세요."
                productivityStatus = message
            } catch { if Task.isCancelled { message = "원본 찾기 취소됨" } else { self.error = error.localizedDescription } }
        }
    }
    static func needsRender(_ before: Project, _ after: Project) -> Bool {
        func normalized(_ source: Project) -> Project {
            var p = source; p.name = ""; p.derivedSequences = nil; p.sequence.name = ""; p.sequence.markers = nil
            for ti in p.sequence.tracks.indices {
                p.sequence.tracks[ti].name = ""; p.sequence.tracks[ti].isLocked = false; p.sequence.tracks[ti].syncLocked = nil
                for ci in p.sequence.tracks[ti].clips.indices {
                    p.sequence.tracks[ti].clips[ci].name = ""; p.sequence.tracks[ti].clips[ci].connection = nil; p.sequence.tracks[ti].clips[ci].lineageID = nil; p.sequence.tracks[ti].clips[ci].captionMetadata = nil
                }
            }
            return p
        }
        return normalized(before) != normalized(after)
    }
    func writableTrack(_ kind: TrackKind) -> Track? {
        guard !isExporting else { return nil }
        if let track = project.sequence.tracks.first(where: { $0.kind == kind && !$0.isLocked }) { return track }
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
        let clips = captionClips
        guard !clips.isEmpty else { return }
        let index = clips.firstIndex { $0.id == selectedClipID } ?? (direction > 0 ? -1 : clips.count)
        let next = max(0, min(clips.count - 1, index + direction))
        selectClip(clips[next].id); pausePlayback(); seek(clips[next].start.seconds)
    }
    func updateCaption(_ id: UUID, text: String) {
        guard let track = project.sequence.tracks.first(where: { $0.clips.contains { $0.id == id } }), var clip = track.clips.first(where: { $0.id == id }) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "자막 문구를 입력하세요."; return }
        clip.title?.text = text; perform(.updateClip(trackID: track.id, clip: clip))
    }
    func replaceCaptionText(find: String, replacement: String) {
        guard !find.isEmpty else { return }
        var commands: [EditCommand] = []
        for track in project.sequence.tracks where track.kind == .title {
            for var clip in track.clips where clip.title?.text.contains(find) == true {
                let text = clip.title!.text.replacingOccurrences(of: find, with: replacement)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "전체 문구가 빈 자막이 생겨 교정을 중단했습니다."; return }
                clip.title?.text = text; commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        if perform(.batch(commands)) { message = "자막 \(commands.count)개 일괄 교정 · ⌘Z로 되돌리기" }
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
    var status = "대기"
}
extension EditorModel {
    func startNextExport() {
        guard !isExporting, let request = exportQueue.first(where: { $0.status == "대기" }) else { return }
        stopAudition(); pausePlayback(); isExporting = true; exportProgress = 0
        if let index = exportQueue.firstIndex(where: { $0.id == request.id }) { exportQueue[index].status = "출력 중" }
        let job = ExportJob(videoBitRate: request.bitRate, codec: request.codec); exportJob = job
        let sidecar = exportSidecarSRT, scope = subtitleExportScope
        exportTask = Task {
            var status = "완료", extra: [String: String] = [:]
            var builtPlan: RenderPlan?
            do {
                let plan = try await TimelineRenderer.build(project: request.project, documentURL: request.baseURL)
                builtPlan = plan
                try Task.checkCancellation()
                try await job.export(plan: plan, to: request.url) { [weak self] progress in Task { @MainActor in self?.exportProgress = progress } }
                message = "출력 완료 · \(request.url.lastPathComponent)"
            } catch {
                status = Task.isCancelled ? "취소" : "실패"
                self.error = error.localizedDescription; message = "출력 \(status) · \(request.url.lastPathComponent)"
            }
            if status == "완료", let plan = builtPlan {
                // The export itself succeeded; checking is separate and never changes that status.
                var srt: URL?
                if sidecar {
                    do { srt = try writeSidecarSubtitles(for: request, scope: scope); if let srt { extra["subtitles"] = srt.path } }
                    catch { extra["subtitles"] = "저장 실패: " + error.localizedDescription }
                }
                if let report = await runOutputQuality(request: request, plan: plan, subtitles: srt) {
                    extra["quality"] = report.summary; extra["qualityErrors"] = String(report.errors); extra["qualityWarnings"] = String(report.warnings)
                    if let url = lastQualityReportURL { extra["qualityReport"] = url.path }
                    message += " · " + report.summary
                } else { extra["quality"] = exportQualityStatus }
            }
            if let index = exportQueue.firstIndex(where: { $0.id == request.id }) { exportQueue[index].status = status }
            isExporting = false; exportJob = nil; exportTask = nil
            saveExportJournal(request: request, status: status, extra: extra)
            // An error pauses the queue so a shared disk/media failure does not cascade.
            if status == "완료" { startNextExport() }
        }
    }
    func removeQueuedExport(_ id: UUID) { exportQueue.removeAll { $0.id == id && $0.status != "출력 중" } }
    func saveExportJournal(request: QueuedExport, status: String, extra: [String: String] = [:]) {
        exportJournal.append(["file": request.url.path, "codec": request.codec.rawValue, "status": status, "date": ISO8601DateFormatter().string(from: Date())].merging(extra) { a, _ in a })
        exportJournal = Array(exportJournal.suffix(30))
        do {
            try FileManager.default.createDirectory(at: exportJournalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: exportJournal, options: [.prettyPrinted,.sortedKeys]).write(to: exportJournalURL, options: .atomic)
        } catch { message += " · 출력 기록 저장 실패: " + error.localizedDescription }
    }
    func prepareMedia(audioOnly: Bool) {
        guard !busyDocument else { return }
        let panel = NSOpenPanel(); panel.message = audioOnly ? "오디오 트랙을 추출할 원본 선택" : "SDR 사본으로 변환할 영상 선택 · 원본 보존"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        productivityBusy = true; productivityStatus = "원본 트랙 확인 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let tracks = try await MediaPreparation.audioTracks(in: url)
                var index = 0
                if tracks.count > 1 {
                    let alert = NSAlert(); alert.messageText = "사용할 오디오 트랙"
                    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
                    picker.addItems(withTitles: tracks.map(\.name)); alert.accessoryView = picker
                    alert.addButton(withTitle: "사용"); alert.addButton(withTitle: "취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }; index = picker.indexOfSelectedItem
                }
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/PreparedMedia")
                let output = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString + (audioOnly ? ".m4a" : ".mp4"))
                productivityStatus = audioOnly ? "선택한 오디오 추출 중…" : "HDR → SDR 변환 중…"
                var asset = try await (audioOnly ? MediaPreparation.extractAudio(url: url, trackIndex: index, destination: output) : MediaPreparation.convertToSDR(url: url, destination: output, audioTrackIndex: index))
                asset.name = url.deletingPathExtension().lastPathComponent + (audioOnly ? " · 오디오 \(index + 1)" : " · SDR 사본")
                if perform(.addAsset(asset)) { selectedAssetID = asset.id; message = "변환 사본을 미디어에 추가했습니다. 원본은 보존했습니다." }
            } catch { self.error = error.localizedDescription }
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
    func masterMix() {
        guard !busyDocument, plan != nil else { return }
        let snapshot = project, base = mediaBaseURL, target = targetLUFS, enhance = enhanceMixVoice
        pausePlayback(); productivityBusy = true; productivityStatus = "최종 믹스 분석·음량 처리 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let plan = try await TimelineRenderer.build(project: snapshot, documentURL: base)
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JHCutStudio/PreparedMedia")
                let output = root.appendingPathComponent("Master-" + UUID().uuidString + ".caf")
                let result = try await MixMastering.render(plan: plan, to: output, targetLUFS: target, enhanceVoice: enhance)
                guard project == snapshot else { try? FileManager.default.removeItem(at: output); throw ProjectError("믹싱 중 프로젝트가 변경되어 결과 적용을 중단했습니다.") }
                var asset = try await MediaImporter.inspect(url: output); asset.name = "완성 믹스"
                var derived = snapshot.sequence; derived.id = UUID(); derived.name += " · 믹스 완성"
                for ti in derived.tracks.indices { derived.tracks[ti].isMuted = true }
                derived.tracks.append(Track(name: "완성 믹스", kind: .audio, clips: [Clip(name: "완성 믹스 · 수정 시 원본 버전에서 재생성", assetID: asset.id, duration: snapshot.sequence.duration)]))
                if perform(.batch([.addAsset(asset), .addIndependentSequence(derived)])) {
                    func number(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "−∞" }
                    mixStatus = "LUFS \(number(result.before.integratedLUFS)) → \(number(result.after.integratedLUFS)) · 4배 보간 피크 \(number(result.oversampledPeakDBFS))dBFS"
                    message = "믹스 완성 버전 생성 · 원본 버전은 보존됩니다. 편집을 바꾸면 원본 버전에서 믹스를 다시 만드세요."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func applyTemplate(_ kind: EditTemplate.Kind) {
        do { let track = try EditTemplate.track(kind: kind, sequence: project.sequence); perform(.addTrack(track)) }
        catch { self.error = error.localizedDescription }
    }
}

extension EditorModel {
    var exportableCaptionClips: [Clip] {
        project.sequence.tracks.filter { $0.kind == .title && (subtitleExportScope != "visible" || !$0.isHidden) }
            .flatMap(\.clips).filter { clip in
                subtitleExportScope == "original" ? clip.captionMetadata?.translatedFrom == nil :
                subtitleExportScope == "translation" ? clip.captionMetadata?.translatedFrom != nil : true
            }.sorted { $0.start < $1.start }
    }
    func captionImportedVideos(_ assets: [MediaAsset]) {
        guard !assets.isEmpty else { return }
        guard transcriptionReady else { message += " · 자동 자막 모델을 설치한 뒤 영상을 타임라인에 추가하세요."; return }
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
        var sequence = project.sequence
        for ti in sequence.tracks.indices where sequence.tracks[ti].kind == .title && !sequence.tracks[ti].clips.isEmpty {
            let clips = sequence.tracks[ti].clips
            if clips.allSatisfy({ $0.captionMetadata?.translatedFrom != nil }) { sequence.tracks[ti].isHidden = true }
            else if clips.allSatisfy({ $0.captionMetadata?.translatedFrom == nil }) { sequence.tracks[ti].isHidden = false }
        }
        if perform(.replaceSequence(sequence)) { message = "원문 자막 표시 · 번역 자막은 프로젝트에 보존됩니다." }
    }
    func translateCaptionTracks() {
        guard !busyDocument else { return }
        let snapshot = project
        let originals = captionClips.filter { $0.captionMetadata?.translatedFrom == nil }
        guard !originals.isEmpty else { message = "번역할 원문 자막을 먼저 생성하거나 SRT로 가져오세요."; return }
        let target = translationTargetLanguage, override = translationSourceLanguage, bilingual = bilingualTranslation
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
        // Mixed manually reorganized tracks need explicit separation before changing visibility.
        for track in snapshot.sequence.tracks where track.kind == .title && !track.clips.isEmpty {
            let count = track.clips.filter { $0.captionMetadata?.translatedFrom != nil }.count
            if count > 0 && count < track.clips.count { error = "원문과 번역이 같은 트랙에 섞여 있습니다. 두 종류를 별도 자막 트랙으로 옮긴 뒤 번역하세요."; return }
            if track.isLocked { error = "자막 트랙의 잠금을 해제한 뒤 번역하세요: " + track.name; return }
        }
        var groups: [String: [Clip]] = [:]
        for clip in originals {
            let source = override == "auto" ? (clip.captionMetadata?.language ?? CaptionTranslation.detectTextLanguage(clip.title?.text ?? "")) : override
            guard let source, CaptionLanguage(rawValue: source) != nil else { error = "원문 언어를 확정하지 못했습니다. 번역 설정의 원문 언어를 직접 선택하세요."; return }
            groups[source, default: []].append(clip)
        }
        if groups.keys.allSatisfy({ $0 == target }) { showOriginalCaptionTracks(); message = "원문이 이미 \(CaptionLanguage(rawValue: target)!.label)입니다. 원문 자막을 표시합니다."; return }
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; translationActive = true; productivityStatus = "자막을 기기 안에서 번역 중…"
        let provider = translationProvider
        productivityTask = Task {
            defer { productivityBusy = false; translationActive = false; productivityTask = nil }
            do {
                var translated: [Clip] = [], preserved = 0
                var glossaryHits = 0, glossaryMisses = 0, styleConverted = 0, styleMatching = 0, styleKept = 0
                for source in groups.keys.sorted() {
                    let clips = groups[source]!
                    productivityStatus = "\(CaptionLanguage(rawValue: source)!.label) → \(CaptionLanguage(rawValue: target)!.label) · \(clips.count)개 자막 번역 중…"
                    let texts = clips.map { $0.title!.text }
                    var values = texts
                    var applied = [[String]](repeating: [], count: clips.count), failed = applied
                    if source != target {
                        let protected = texts.map { GlossaryProtection.protect($0, entries: entries, from: source, to: target) }
                        let sendIndices = protected.indices.filter { !protected[$0].isOnlyTerms }
                        let raw = sendIndices.isEmpty ? [] : try await provider(sendIndices.map { protected[$0].text }, source, target)
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
                            let plain = try await provider(retry.map { texts[$0] }, source, target)
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
                        if let manual = snapshot.sequence.tracks.flatMap(\.clips).first(where: {
                            CaptionTranslationEditing.isTranslation(of: clip, $0, target: target) && $0.title?.text != $0.captionMetadata?.generatedText
                        }) { translated.append(manual); preserved += 1; continue }
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
                        translated.append(made)
                    }
                }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("번역 중 프로젝트가 변경되었습니다. 오래된 번역으로 편집을 덮어쓰지 않도록 중단했습니다.") }
                var sequence = snapshot.sequence
                // Keep previous languages and the original in hidden tracks; replace this target atomically.
                let existing = sequence.tracks.firstIndex { track in
                    !track.clips.isEmpty && track.clips.allSatisfy { $0.captionMetadata?.translatedFrom != nil && $0.captionMetadata?.language == target }
                }
                for ti in sequence.tracks.indices where sequence.tracks[ti].kind == .title && !sequence.tracks[ti].clips.isEmpty { sequence.tracks[ti].isHidden = true }
                translated.sort { $0.start < $1.start }
                if let ti = existing { sequence.tracks[ti].clips = translated; sequence.tracks[ti].isHidden = false }
                else { sequence.tracks.append(Track(name: "번역 자막 · \(CaptionLanguage(rawValue: target)!.label)", kind: .title, clips: translated)) }
                if perform(.replaceSequence(sequence)) {
                    let composition = groups.keys.sorted().map { "\(CaptionLanguage(rawValue: $0)!.label) \(groups[$0]!.count)" }.joined(separator: " · ")
                    var notes: [String] = []
                    if !entries.isEmpty { notes.append("용어집 적용 \(glossaryHits)건" + (glossaryMisses > 0 ? " · 적용 실패 \(glossaryMisses)건(해당 문장은 일반 번역)" : "")) }
                    if style != .natural {
                        if target == "en" { notes.append("영어는 존댓말 구분이 없어 \(style.label) 스타일을 적용하지 않았습니다") }
                        else { notes.append("\(style.label) 변환 \(styleConverted)문장 · 이미 맞음 \(styleMatching) · 규칙 밖 \(styleKept)문장은 번역기 문장 유지") }
                    }
                    message = "\(CaptionLanguage(rawValue: target)!.label) 번역 자막 \(translated.count)개 · 문장별 원문 언어 \(composition) · 직접 고친 번역 \(preserved)개 보존" + notes.map { " · " + $0 }.joined() + " · 원문은 숨긴 트랙에 유지됩니다."
                    productivityStatus = message
                    if let first = translated.first { selectClip(first.id); seek(first.start.seconds) }
                }
            } catch {
                if Task.isCancelled { message = "번역 취소됨 · 원문과 기존 번역을 유지합니다." }
                else { self.error = error.localizedDescription; message = "번역 실패 · 원문 자막을 유지합니다." }
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
        let clips = request.project.sequence.tracks.filter { $0.kind == .title && !$0.isHidden }.flatMap(\.clips).filter { clip in
            guard clip.title != nil, clip.captionMetadata != nil || clip.connection != nil || clip.name == "자막" else { return false }
            return scope == "original" ? clip.captionMetadata?.translatedFrom == nil : scope == "translation" ? clip.captionMetadata?.translatedFrom != nil : true
        }.sorted { $0.start < $1.start }
        guard !clips.isEmpty else { return nil }
        let url = request.url.deletingPathExtension().appendingPathExtension("srt")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ProjectError("같은 이름의 SRT가 이미 있어 덮어쓰지 않았습니다: \(url.lastPathComponent)") }
        let cues = clips.map { CaptionCue(id: $0.id, start: $0.start, duration: $0.duration, text: $0.title?.text ?? "") }
        try SRTCodec.serialize(cues).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Checks a finished export and writes the report; nil when the check itself could not run.
    func runOutputQuality(request: QueuedExport, plan: RenderPlan, subtitles: URL?) async -> OutputQualityReport? {
        exportQualityStatus = "출력 파일 검사 중…"
        lastExportedRequest = request
        let expectation = OutputExpectation.from(project: request.project, plan: plan)
        do {
            let report = try await OutputQuality.check(output: request.url, expectation: expectation, subtitles: subtitles) { [weak self] fraction in
                Task { @MainActor in self?.exportQualityStatus = "출력 파일 검사 \(Int(fraction * 100))%" }
            }
            let stamp = ISO8601DateFormatter().string(from: report.checkedAt).replacingOccurrences(of: ":", with: "-")
            lastQualityReportURL = try? OutputQuality.write(report, to: reportsDirectory.appendingPathComponent("OutputQuality"), name: request.url.deletingPathExtension().lastPathComponent + "-" + stamp)
            lastQualityReport = report; exportQualityStatus = report.summary
            return report
        } catch {
            exportQualityStatus = Task.isCancelled ? "출력 검사 취소 · 출력 파일은 완성됨" : "출력 검사 실패 · " + error.localizedDescription
            return nil
        }
    }

    /// Re-checks the most recent export (for example after saving an .srt beside it).
    func recheckLastExport() {
        guard !isExporting, let request = lastExportedRequest, FileManager.default.fileExists(atPath: request.url.path) else { error = "다시 검사할 최근 출력 파일이 없습니다."; return }
        isExporting = true
        exportTask = Task {
            defer { isExporting = false; exportTask = nil }
            do {
                let plan = try await TimelineRenderer.build(project: request.project, documentURL: request.baseURL)
                let srt = request.url.deletingPathExtension().appendingPathExtension("srt")
                if let report = await runOutputQuality(request: request, plan: plan, subtitles: FileManager.default.fileExists(atPath: srt.path) ? srt : nil) { message = report.summary }
            } catch { self.error = error.localizedDescription }
        }
    }
}

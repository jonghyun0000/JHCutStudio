import Foundation
import AppKit
import JHCutCore

// MARK: - Transcript-based accuracy (upgrade 2)

extension EditorModel {
    /// Original (non-translation) captions attached to `clip`, in SOURCE media time — the clock an
    /// `.srt` transcript of the file uses. Captions without a connection are mapped through the
    /// clip's trim and rate when they lie on it; others are ignored rather than guessed.
    func sourceTimedCaptions(for clip: Clip) -> [EvaluatedCaption] {
        let rate = clip.playbackRate ?? PlaybackRate()
        return project.sequence.tracks.filter { $0.kind == .title }.flatMap(\.clips).compactMap { caption -> EvaluatedCaption? in
            guard let text = caption.title?.text, caption.captionMetadata?.translatedFrom == nil else { return nil }
            if let link = caption.connection, link.parentID == clip.id {
                return EvaluatedCaption(text: text, start: link.sourceStart.seconds, end: (link.sourceStart + link.sourceDuration).seconds)
            }
            guard caption.connection == nil, caption.start >= clip.start, caption.end <= clip.end else { return nil }
            let start = clip.sourceStart.seconds + (caption.start - clip.start).seconds * rate.multiplier
            return EvaluatedCaption(text: text, start: start, end: start + caption.duration.seconds * rate.multiplier)
        }.sorted { $0.start < $1.start }
    }

    /// Scores the selected clip's captions against a transcript beside its media (or `referenceURL`).
    /// Without a transcript the report says “평가 불가” and carries no numbers.
    func evaluateSelectedCaptions(referenceURL: URL? = nil) {
        guard !busyDocument, let (_, clip, asset) = selectedSpeechClips.first else { return }
        let captions = sourceTimedCaptions(for: clip)
        guard !captions.isEmpty else { error = "평가할 원문 자막이 없습니다. 먼저 이 클립의 자동 자막을 만드세요."; return }
        let languages = project.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil }.compactMap { $0.captionMetadata?.language }
        let language = Dictionary(grouping: languages, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? speechOptions.language
        let media = asset.resolvedURL(relativeTo: mediaBaseURL)
        let range = clip.sourceStart.seconds...(clip.sourceStart + clip.sourceDuration).seconds
        let folder = reportsDirectory, title = "\(project.name) · \(clip.name)", duration = asset.duration.seconds
        let name = "evaluation-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + String(clip.id.uuidString.prefix(8))
        productivityBusy = true; productivityStatus = "대본과 자막 비교 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> (TranscriptEvaluationReport, URL) in
                    let located = referenceURL ?? TranscriptReference.locate(besideMedia: media)
                    let reference = try located.map { try TranscriptReference.load($0) }
                    let report = TranscriptEvaluation.evaluate(captions: captions, reference: reference, language: language, sourceRange: range, mediaDuration: duration)
                    return (report, try TranscriptEvaluation.write(report, title: title, to: folder, name: name).text)
                }
                let (report, url) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                lastEvaluation = report; lastEvaluationReportURL = url
                message = Self.summary(report)
                productivityStatus = message
            } catch { if Task.isCancelled { message = "정확도 평가 취소됨" } else { self.error = error.localizedDescription } }
        }
    }

    func chooseReferenceAndEvaluate() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .init(filenameExtension: "srt")!]
        panel.message = "이 클립의 사람이 작성한 대본(.srt 권장, .txt 가능)을 선택하세요. 대본 파일은 수정하지 않습니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        evaluateSelectedCaptions(referenceURL: url)
    }

    static func summary(_ report: TranscriptEvaluationReport) -> String {
        guard report.status == .scored else { return "정확도 평가 불가 · " + (report.reason ?? "대본 없음") }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "-" }
        var text = "CER \(pct(report.cer)) · WER \(pct(report.wer)) · 누락 \(report.missing.count) · 과잉 \(report.extra.count)"
        if let t = report.timing { text += String(format: " · 시작 오차 중앙값 %.2f초", t.medianAbsoluteStart) }
        return text + " · 이 대본 기준"
    }
}

// MARK: - Sentence language (upgrade 3)

extension EditorModel {
    /// Hand-sets the language of original captions. One undo step; translations are untouched
    /// until the user translates again, at which point these sentences join the chosen group.
    func setCaptionLanguage(_ ids: Set<UUID>, to language: String) {
        guard !busyDocument, CaptionLanguage(rawValue: language) != nil else { return }
        var commands: [EditCommand] = []
        for track in project.sequence.tracks where track.kind == .title && !track.isLocked {
            for var clip in track.clips where ids.contains(clip.id) && clip.title != nil && clip.captionMetadata?.translatedFrom == nil {
                let text = clip.title?.text ?? ""
                var metadata = clip.captionMetadata ?? CaptionMetadata(language: language, originalLanguage: language, originalText: text, generatedText: clip.connection?.generatedText ?? text)
                metadata.language = language; metadata.originalLanguage = language
                metadata.languageManual = true; metadata.languageConfidence = nil; metadata.languageNeedsReview = nil
                clip.captionMetadata = metadata
                commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        guard !commands.isEmpty else { message = "언어를 바꿀 원문 자막을 선택하세요. 잠긴 트랙과 번역 자막은 바꾸지 않습니다."; return }
        if perform(.batch(commands)) { message = "자막 \(commands.count)개 언어를 \(CaptionLanguage(rawValue: language)!.label)(으)로 지정 · 다시 번역하면 반영됩니다." }
    }
    /// Returns detection to automatic for the given captions (clears the manual flag).
    func resetCaptionLanguage(_ ids: Set<UUID>) {
        guard !busyDocument else { return }
        var commands: [EditCommand] = []
        for track in project.sequence.tracks where track.kind == .title && !track.isLocked {
            for var clip in track.clips where ids.contains(clip.id) && clip.captionMetadata?.translatedFrom == nil {
                guard var metadata = clip.captionMetadata else { continue }
                let detected = SentenceLanguage.detect(clip.title?.text ?? "", clipLanguage: metadata.clipLanguage ?? metadata.language)
                metadata.language = detected.language; metadata.originalLanguage = detected.language
                metadata.languageConfidence = detected.confidence; metadata.languageNeedsReview = detected.needsReview ? true : nil; metadata.languageManual = nil
                clip.captionMetadata = metadata; commands.append(.updateClip(trackID: track.id, clip: clip))
            }
        }
        if !commands.isEmpty, perform(.batch(commands)) { message = "자막 \(commands.count)개 언어를 자동 감지로 되돌림" }
    }
    /// Sentences whose language needs a human look, for the caption list badge.
    var captionsNeedingLanguageReview: [Clip] {
        captionClips.filter { $0.captionMetadata?.translatedFrom == nil && $0.captionMetadata?.languageNeedsReview == true && $0.captionMetadata?.languageManual != true }
    }
}

// MARK: - Speakers (upgrade 4)

extension EditorModel {
    /// Labels the selected clip's original captions by channel separation. Only metadata changes;
    /// caption times and connections are untouched. One undo step.
    func separateSpeakers() {
        guard !busyDocument, let (_, clip, asset) = selectedSpeechClips.first else { return }
        let captions = project.sequence.tracks.filter { $0.kind == .title && !$0.isLocked }.flatMap { track in
            track.clips.filter { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil }.map { (track.id, $0) }
        }
        guard !captions.isEmpty else { error = "화자를 나눌 원문 자막이 없습니다. 먼저 자동 자막을 만드세요."; return }
        let ranges = captions.map { $0.1.connection!.sourceStart.seconds...($0.1.connection!.sourceStart + $0.1.connection!.sourceDuration).seconds }
        let snapshot = project, url = asset.resolvedURL(relativeTo: mediaBaseURL)
        productivityBusy = true; productivityStatus = "채널별 음량으로 화자 구분 중…"
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                let result = try await SpeakerSeparation.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, ranges: ranges)
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("분석 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                var commands: [EditCommand] = []
                for ((trackID, original), assignment) in zip(captions, result.assignments) {
                    var caption = original
                    var metadata = caption.captionMetadata ?? CaptionMetadata(language: speechOptions.language, originalLanguage: speechOptions.language, originalText: caption.title?.text ?? "", generatedText: caption.title?.text ?? "")
                    metadata.speaker = result.status == .separated ? assignment.speaker : nil
                    metadata.speakerStatus = result.status == .unavailable ? nil : (metadata.speaker == nil ? "uncertain" : "separated")
                    caption.captionMetadata = metadata
                    if caption != original { commands.append(.updateClip(trackID: trackID, clip: caption)) }
                }
                if result.status == .separated {
                    var sequence = project.sequence
                    var profiles = sequence.speakers ?? []
                    for label in Set(result.assignments.compactMap(\.speaker)).sorted() where !profiles.contains(where: { $0.id == label }) {
                        let index = SpeakerSeparation.labels.firstIndex(of: label) ?? 0
                        profiles.append(SpeakerProfile(id: label, name: "화자 \(label)", colorHex: SpeakerProfile.defaultColors[index % SpeakerProfile.defaultColors.count]))
                    }
                    if profiles != (sequence.speakers ?? []) { sequence.speakers = profiles; commands.insert(.replaceSequence(sequence), at: 0) }
                }
                if !commands.isEmpty { _ = perform(.batch(commands)) }
                speakerStatus = result.message; message = result.message
            } catch { if Task.isCancelled { message = "화자 구분 취소됨" } else { self.error = error.localizedDescription } }
        }
    }

    /// Renames/recolours one speaker and restyles every caption of that speaker. One undo step.
    func updateSpeaker(_ id: String, name: String, colorHex: String) {
        let hex = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard !busyDocument, !name.trimmingCharacters(in: .whitespaces).isEmpty, hex.count == 6, hex.allSatisfy(\.isHexDigit) else { error = "화자 이름과 6자리 색상(RRGGBB)을 입력하세요."; return }
        var sequence = project.sequence
        guard var profiles = sequence.speakers, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name; profiles[index].colorHex = hex
        for ti in sequence.tracks.indices where sequence.tracks[ti].kind == .title && !sequence.tracks[ti].isLocked {
            for ci in sequence.tracks[ti].clips.indices where sequence.tracks[ti].clips[ci].captionMetadata?.speaker == id {
                sequence.tracks[ti].clips[ci].title?.colorHex = hex
            }
        }
        sequence.speakers = profiles
        if perform(.replaceSequence(sequence)) { message = "\(name) 자막 색상 적용" }
    }

    /// Moves each speaker's original captions to their own title track (ids and connections kept).
    func splitCaptionTracksBySpeaker() {
        guard !busyDocument, let profiles = project.sequence.speakers, !profiles.isEmpty else { return }
        var sequence = project.sequence
        var moved = 0
        for profile in profiles {
            var clips: [Clip] = []
            for ti in sequence.tracks.indices where sequence.tracks[ti].kind == .title && !sequence.tracks[ti].isLocked && !sequence.tracks[ti].name.hasPrefix("화자 · ") {
                clips += sequence.tracks[ti].clips.filter { $0.captionMetadata?.speaker == profile.id && $0.captionMetadata?.translatedFrom == nil }
                sequence.tracks[ti].clips.removeAll { $0.captionMetadata?.speaker == profile.id && $0.captionMetadata?.translatedFrom == nil }
            }
            guard !clips.isEmpty else { continue }
            moved += clips.count
            if let existing = sequence.tracks.firstIndex(where: { $0.kind == .title && $0.name == "화자 · \(profile.name)" }) { sequence.tracks[existing].clips += clips }
            else { sequence.tracks.append(Track(name: "화자 · \(profile.name)", kind: .title, clips: clips.sorted { $0.start < $1.start })) }
        }
        guard moved > 0 else { message = "화자가 지정된 자막이 없습니다."; return }
        if perform(.replaceSequence(sequence)) { message = "화자별 자막 트랙 \(profiles.count)개로 \(moved)개 이동 · 시간과 연결은 그대로입니다." }
    }
}

extension EditorModel {
    /// For recordings with one microphone per channel: recognise each active channel on its own and
    /// label its sentences with that channel's speaker. Refused (with the measured reason) when
    /// the channels are not independent, so nobody is labelled by guesswork. Replaces this clip's
    /// unedited automatic captions; hand-corrected ones are kept. One undo step.
    func transcribeSpeakersByChannel() {
        guard !busyDocument, transcriptionReady, let (_, clip, asset) = selectedSpeechClips.first else { return }
        let snapshot = project, url = asset.resolvedURL(relativeTo: mediaBaseURL), base = speechOptions
        let configuration = WhisperConfiguration(modelSpec: speechModelSpec)
        let preset = allTitlePresets.first(where: { $0.id == transcriptionPresetID }) ?? TitlePreset.builtIns[0]
        let style = TitleSizing.title(for: preset, width: snapshot.sequence.width, height: snapshot.sequence.height)
        pausePlayback(); productivityBusy = true; transcriptionActive = true; productivityStatus = "채널 구성 확인 중…"
        productivityTask = Task {
            defer { productivityBusy = false; transcriptionActive = false; productivityTask = nil }
            do {
                let layout = try await SpeakerSeparation.channelLayout(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration)
                guard layout.channels > 1 else { speakerStatus = "모노 음성이라 채널별 화자 인식을 할 수 없습니다."; message = speakerStatus; return }
                guard layout.isSeparated else {
                    speakerStatus = String(format: "화자 구분 불확실 · 채널이 분리된 녹음이 아닙니다(활성 채널 %d개, 채널 간 상관 %.2f). 채널별 인식을 하지 않았습니다.", layout.activeChannels.count, layout.maxCorrelation)
                    message = speakerStatus; return
                }
                var captions: [Clip] = []
                for (index, channel) in layout.activeChannels.prefix(SpeakerSeparation.labels.count).enumerated() {
                    try Task.checkCancellation()
                    productivityStatus = "채널 \(channel + 1) 인식 중 (\(index + 1)/\(layout.activeChannels.count))…"
                    var options = base; options.channel = channel
                    let result = try await LocalTranscription.transcribeLong(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, configuration: configuration, options: options)
                    let label = SpeakerSeparation.labels[channel]
                    for var caption in CaptionEditing.automaticClips(cues: result.cues, source: clip, style: style) {
                        let text = caption.title?.text ?? ""
                        let detected = SentenceLanguage.detect(text, clipLanguage: result.language)
                        var metadata = CaptionMetadata(language: detected.language, originalLanguage: detected.language, originalText: text, generatedText: text)
                        metadata.clipLanguage = result.language; metadata.languageConfidence = detected.confidence
                        metadata.languageNeedsReview = detected.needsReview ? true : nil
                        metadata.speaker = label; metadata.speakerStatus = "separated"
                        caption.captionMetadata = metadata; captions.append(caption)
                    }
                }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("인식 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                var sequence = snapshot.sequence
                var kept: [Clip] = []
                for ti in sequence.tracks.indices where sequence.tracks[ti].kind == .title && !sequence.tracks[ti].isLocked {
                    // Drop this clip's unedited automatic originals; keep corrected ones and translations.
                    kept += sequence.tracks[ti].clips.filter { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil && ($0.title?.text != $0.connection?.generatedText || $0.captionMetadata?.languageManual == true) }
                    sequence.tracks[ti].clips.removeAll { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil && !kept.contains($0) }
                }
                captions.removeAll { c in kept.contains { $0.start < c.end && $0.end > c.start && $0.captionMetadata?.speaker == c.captionMetadata?.speaker } }
                var profiles = sequence.speakers ?? []
                for label in Set(captions.compactMap { $0.captionMetadata?.speaker }).sorted() where !profiles.contains(where: { $0.id == label }) {
                    let i = SpeakerSeparation.labels.firstIndex(of: label) ?? 0
                    profiles.append(SpeakerProfile(id: label, name: "화자 \(label)", colorHex: SpeakerProfile.defaultColors[i % SpeakerProfile.defaultColors.count]))
                }
                for ci in captions.indices { if let hex = profiles.first(where: { $0.id == captions[ci].captionMetadata?.speaker })?.colorHex { captions[ci].title?.colorHex = hex } }
                sequence.speakers = profiles
                sequence.tracks.append(Track(name: "자동 자막 · 채널별 화자 · \(clip.name)", kind: .title, clips: captions.sorted { $0.start < $1.start }))
                if perform(.replaceSequence(sequence)) {
                    speakerStatus = "채널별 인식 · 화자 \(Set(captions.compactMap { $0.captionMetadata?.speaker }).count)명 · 자막 \(captions.count)개 (채널 간 상관 \(String(format: "%.2f", layout.maxCorrelation)))"
                    message = speakerStatus + " · ⌘Z로 되돌릴 수 있습니다."
                }
            } catch { if Task.isCancelled { message = "채널별 인식 취소됨 · 기존 자막 유지" } else { self.error = error.localizedDescription } }
        }
    }
}

// MARK: - Caption batch editing (upgrade 5)

extension EditorModel {
    /// Selected captions that batch edits may touch: on visible, unlocked title tracks only.
    var batchEditableCaptions: [(Track, Clip)] {
        project.sequence.tracks.filter { $0.kind == .title && !$0.isHidden && !$0.isLocked }.flatMap { track in
            track.clips.filter { selectedClipIDs.contains($0.id) && $0.title != nil }.map { (track, $0) }
        }
    }
    /// Applies one change to every selected visible caption as a single undo step. Captions on
    /// hidden tracks (the preserved original or other-language translation) are never changed, even
    /// if selected. With `fitSafeArea`, each result is shrunk/moved into the 80% safe area; a caption
    /// that cannot fit at the minimum size is left as edited and reported.
    @discardableResult
    func applyCaptionBatch(_ change: CaptionBatchChange, fitSafeArea: Bool) -> Bool {
        guard !busyDocument else { return false }
        let targets = batchEditableCaptions
        let hidden = project.sequence.tracks.filter { $0.kind == .title && ($0.isHidden || $0.isLocked) }.flatMap(\.clips).filter { selectedClipIDs.contains($0.id) }.count
        guard !targets.isEmpty else { error = hidden > 0 ? "선택한 자막이 모두 숨기거나 잠근 트랙에 있어 바꾸지 않았습니다." : "일괄 편집할 자막을 선택하세요."; return false }
        guard !change.isEmpty || fitSafeArea else { message = "바꿀 항목을 입력하세요."; return false }
        var commands: [EditCommand] = [], fitted = 0, unfit = 0
        do {
            for (track, original) in targets {
                var clip = try CaptionBatchEditing.applied(change, to: original)
                if fitSafeArea, let title = clip.title {
                    if let result = try CaptionLayout.fitted(title, width: project.sequence.width, height: project.sequence.height) {
                        if result != title { fitted += 1 }; clip.title = result
                    } else { unfit += 1 }
                }
                if clip != original { commands.append(.updateClip(trackID: track.id, clip: clip)) }
            }
        } catch { self.error = error.localizedDescription; return false }
        guard !commands.isEmpty else { message = "선택한 자막이 이미 그 상태입니다."; return true }
        guard perform(.batch(commands)) else { return false }
        var parts = ["자막 \(commands.count)개 일괄 수정"]
        if hidden > 0 { parts.append("숨김·잠금 트랙 \(hidden)개 제외") }
        if fitSafeArea { parts.append("안전 영역 맞춤 \(fitted)개") }
        if unfit > 0 { parts.append("최소 크기로도 맞출 수 없는 자막 \(unfit)개 — 문구를 줄이세요") }
        message = parts.joined(separator: " · ") + " · ⌘Z로 한 번에 되돌리기"
        return true
    }
    func selectAllVisibleCaptions() {
        let ids = project.sequence.tracks.filter { $0.kind == .title && !$0.isHidden }.flatMap(\.clips).filter { $0.title != nil }.map(\.id)
        selectedClipIDs = Set(ids); selectedClipID = ids.first
    }
}

// MARK: - Translation glossary (upgrade 6)

extension EditorModel {
    var glossaryEntries: [GlossaryEntry] { project.glossary ?? [] }

    @discardableResult func setGlossary(_ entries: [GlossaryEntry]) -> Bool {
        guard !busyDocument else { return false }
        return perform(.replaceGlossary(entries))
    }

    func addGlossaryEntry(_ entry: GlossaryEntry) {
        guard !entry.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "용어집 원문을 입력하세요."; return }
        var entries = glossaryEntries
        if let index = entries.firstIndex(where: { $0.source == entry.source && $0.sourceLanguage == entry.sourceLanguage && $0.targetLanguage == entry.targetLanguage }) {
            var replaced = entry; replaced.id = entries[index].id; entries[index] = replaced
        } else { entries.append(entry) }
        if setGlossary(entries) { message = "용어집 저장 · \(entry.source) → \(entry.keepsSource ? "원문 그대로" : entry.target) · 다음 번역부터 적용됩니다." }
    }

    func removeGlossaryEntry(_ id: UUID) {
        guard let entry = glossaryEntries.first(where: { $0.id == id }) else { return }
        if setGlossary(glossaryEntries.filter { $0.id != id }) { message = "용어집에서 삭제 · \(entry.source)" }
    }

    /// Moves the quick "원문=번역" lines into the saved project glossary in one undo step.
    func importQuickGlossary() {
        var entries = glossaryEntries, added = 0
        for line in translationGlossaryText.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty, !entries.contains(where: { $0.source == fields[0] && $0.sourceLanguage == nil && $0.targetLanguage == nil }) else { continue }
            entries.append(GlossaryEntry(source: fields[0], target: fields[1])); added += 1
        }
        guard added > 0 else { message = "옮길 새 용어가 없습니다."; return }
        if setGlossary(entries) { translationGlossaryText = ""; message = "빠른 용어집 \(added)개를 프로젝트 용어집으로 옮겼습니다." }
    }
}

// MARK: - Voice activity (upgrade 7)

extension EditorModel {
    /// Analyses the selected clips (read-only, cached) and flags captions over silence/music/noise.
    func checkCaptionsAgainstVoiceActivity() {
        let sources = selectedSpeechClips
        guard !busyDocument, !sources.isEmpty else { return }
        let base = mediaBaseURL, fingerprints = mediaFingerprints
        productivityBusy = true; productivityStatus = "말소리 구간 분석 중…"; error = nil
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                var reports: [UUID: VoiceActivityReport] = [:], summary: [String] = []
                for (_, clip, asset) in sources {
                    try Task.checkCancellation()
                    let url = asset.resolvedURL(relativeTo: base)
                    let digest = (try? await fingerprints.sha256(of: url)) ?? url.path
                    let key = "\(digest)|\(clip.sourceStart.seconds)|\(clip.sourceDuration.seconds)"
                    let report: VoiceActivityReport
                    if let cached = voiceActivityCache[key] { report = cached }
                    else {
                        report = try await VoiceActivity.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration) { [weak self] fraction in
                            Task { @MainActor in self?.productivityStatus = "\(clip.name) 말소리 구간 분석 \(Int(fraction * 100))%" }
                        }
                        // Bounded: a 2-hour analysis is a few hundred KB, but many clips in one session add up.
                        if voiceActivityCache.count >= 16 { voiceActivityCache.removeAll() }
                        voiceActivityCache[key] = report
                    }
                    reports[clip.id] = report
                    summary.append(VoiceActivitySummary.describe(report))
                }
                let flagged = flagSilentCaptions(reports: reports)
                lastVoiceActivity = reports.values.first
                message = summary.joined(separator: " / ") + (flagged > 0 ? " · 무음·음악·소음 위 자막 \(flagged)개 · 자막 목록에서 확인하세요." : " · 무음 위 자막 없음")
                productivityStatus = message
            } catch {
                if Task.isCancelled { message = "말소리 분석 취소됨" } else { self.error = error.localizedDescription }
                productivityStatus = message
            }
        }
    }
}


// MARK: - Install diagnostics and project backups (upgrade 10)

extension EditorModel {
    /// Read-only installation check. With `alertOnError`, problems that stop a feature are shown once.
    func runDiagnostics(alertOnError: Bool = false) {
        Task {
            let pairs = await CaptionTranslation.installedPairs()
            let report = StartupDiagnostics.run(.current(translationPairs: pairs))
            diagnostics = report
            if alertOnError, report.hasErrors {
                let alert = NSAlert(); alert.messageText = "JH CUT Studio 설치 점검"
                alert.informativeText = report.items.filter { $0.level == .error }.map { "• \($0.title)\n  \($0.advice)" }.joined(separator: "\n\n")
                alert.addButton(withTitle: "확인"); alert.runModal()
            }
        }
    }
    func copyDiagnostics() {
        guard let report = diagnostics else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.text, forType: .string)
        message = "진단 정보를 복사했습니다. 문의할 때 붙여 넣으세요(개인 파일 내용은 포함되지 않습니다)."
    }
    func openTranslationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func refreshBackups() { backupEntries = ProjectBackup.list(root: backupRoot) }
    /// Backs up the saved document. Unsaved changes are not included, so the user is told to save first.
    func createProjectBackup() {
        guard let url = documentURL else { error = "먼저 프로젝트를 저장한 뒤 백업하세요."; return }
        if dirty { message = "저장하지 않은 변경은 백업에 포함되지 않습니다. 저장된 상태를 백업합니다." }
        do {
            let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
            let folder = try ProjectBackup.create(documentURL: url, root: backupRoot, appVersion: version)
            refreshBackups()
            message = "프로젝트 백업 완료 · \(folder.lastPathComponent) · 원본 미디어는 복사하지 않고 위치만 기록합니다."
        } catch { self.error = "백업 실패: " + error.localizedDescription }
    }
    func restoreBackup(_ entry: ProjectBackup.Entry) {
        do {
            let project = try ProjectBackup.restore(entry)
            let missing = ProjectBackup.missingMedia(entry)
            openRestored(project, baseURL: URL(fileURLWithPath: entry.manifest.originalPath),
                         note: "백업에서 복원 · 새 문서로 열었습니다. 기존 파일은 그대로이며 ‘다른 이름으로 저장’하세요." + (missing.isEmpty ? "" : " · 찾을 수 없는 미디어 \(missing.count)개(다시 연결 필요)"))
        } catch { self.error = "복원 실패: " + error.localizedDescription }
    }
}

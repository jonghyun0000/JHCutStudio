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
        return CaptionQuery.entries(in: project.sequence, role: .original).map(\.clip).compactMap { caption -> EvaluatedCaption? in
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
        let humanJSON = referenceURL?.pathExtension.lowercased() == "json"
        guard humanJSON || !captions.isEmpty else { error = "평가할 원문 자막이 없습니다. 먼저 이 클립의 자동 자막을 만드세요."; return }
        let languages = CaptionQuery.entries(in:project.sequence,role:.original).map(\.clip).filter { $0.connection?.parentID == clip.id || $0.connection == nil && $0.start >= clip.start && $0.end <= clip.end }.compactMap { $0.captionMetadata?.language }
        if humanJSON,Set(languages.filter { ["ko","ja","en"].contains($0) }).count > 1 {
            error="선택 구간의 원문 언어가 섞여 있습니다. 단일 언어 검수 정답으로 채점하지 않습니다. 구간과 원문 언어를 확인하세요."
            evaluationAttemptState="unscored";evaluationAttemptReason=error;evaluationRetainedPrevious=true;return
        }
        let language = Dictionary(grouping: languages, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? speechOptions.language
        let media = asset.resolvedURL(relativeTo: mediaBaseURL)
        guard let sourceEnd=try? clip.sourceStart.adding(clip.sourceDuration),sourceEnd > clip.sourceStart else { error="평가할 원본 범위가 올바르지 않습니다.";return }
        let range = clip.sourceStart.seconds...sourceEnd.seconds
        let sourceFile = URL(fileURLWithPath:asset.path).lastPathComponent
        let folder = reportsDirectory, title = "\(project.name) · \(clip.name)", duration = asset.duration.seconds
        let snapshot=project,jobID=UUID(),name="evaluation-"+UUID().uuidString
        let sourceStamp: String
        do { sourceStamp=try MediaFingerprintCache.stat(media) } catch { self.error=error.localizedDescription;return }
        productivityBusy=true;evaluationActive=true;evaluationProgress=0;evaluationJobID=jobID;error=nil;evaluationAttemptState="pending";evaluationAttemptReason=nil;evaluationRetainedPrevious=false;productivityStatus=humanJSON ? "사람 검수 정답과 원본 확인 중…" : "일반 대본과 자막 비교 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask=Task {
            var generated: EvaluationReportFiles?
            var published=false
            defer {
                if !published { generated?.discard() }
                if ownsAsyncJob(ticket), evaluationJobID == jobID { evaluationActive=false;evaluationProgress=nil;evaluationJobID=nil;finishAsyncJob(ticket) }
            }
            do {
                try validateAsyncJob(ticket)
                let worker=Task.detached(priority:.userInitiated) { () async throws -> (report:TranscriptEvaluationReport,referenceURL:URL?,referenceStamp:String?) in
                    try Task.checkCancellation()
                    let located=referenceURL ?? TranscriptReference.locate(besideMedia:media)
                    let referenceStamp=try located.map { try MediaFingerprintCache.stat($0) }
                    let progress: @Sendable (EvaluationProgress) -> Void = { [weak self] state in
                        Task { @MainActor in
                            guard let self,self.evaluationJobID == jobID,self.evaluationActive,self.acceptsAsyncProgress(ticket) else { return }
                            self.evaluationProgress=max(self.evaluationProgress ?? 0,state.fraction)
                            self.productivityStatus=state.phase+" · "+String(Int(state.fraction*100))+"%"
                        }
                    }
                    let report: TranscriptEvaluationReport
                    if humanJSON,let located {
                        report=try await HumanReferenceEvaluation.evaluate(referenceURL:located,mediaURL:media,sourceFile:sourceFile,
                                                                          range:range,mediaDuration:duration,language:language,captions:captions,progress:progress)
                    } else {
                        let reference=try located.map { try TranscriptReference.load($0) }
                        report=try TranscriptEvaluation.evaluate(captions:captions,reference:reference,language:language,sourceRange:range,mediaDuration:duration,progress:progress)
                    }
                    guard try located.map({ try MediaFingerprintCache.stat($0) }) == referenceStamp else { throw ProjectError("평가 대본이 바뀌었습니다. 다시 평가하세요.") }
                    return (report,located,referenceStamp)
                }
                let result=try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                let report=result.report
                try Task.checkCancellation()
                guard project == snapshot,try MediaFingerprintCache.stat(media) == sourceStamp,try result.referenceURL.map({ try MediaFingerprintCache.stat($0) }) == result.referenceStamp else { throw ProjectError("평가 중 프로젝트·원본·대본이 바뀌었습니다. 다시 평가하세요.") }
                productivityStatus="평가 보고서 저장 중…"
                let writer=Task.detached(priority:.utility) { try TranscriptEvaluation.write(report,title:title,to:folder,name:name) }
                let files=try await withTaskCancellationHandler(operation:{ try await writer.value },onCancel:{ writer.cancel() });generated=files
                try Task.checkCancellation()
                guard project == snapshot,try MediaFingerprintCache.stat(media) == sourceStamp,try result.referenceURL.map({ try MediaFingerprintCache.stat($0) }) == result.referenceStamp else { throw ProjectError("보고서 저장 중 프로젝트·원본·대본이 바뀌었습니다. 새 결과는 적용하지 않았습니다.") }
                try await checkpointAsyncJob(ticket, "evaluation.beforeApply")
                guard try MediaFingerprintCache.stat(media) == sourceStamp, try result.referenceURL.map({ try MediaFingerprintCache.stat($0) }) == result.referenceStamp else { throw ProjectError("평가 원본 또는 대본이 변경되었습니다.") }
                lastEvaluation=report;lastEvaluationReportURL=files.text;published=true
                evaluationAttemptState=report.humanReference?.state ?? report.status.rawValue;evaluationAttemptReason=report.humanReference?.metrics.reason ?? report.reason
                message=Self.summary(report);productivityStatus=message
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                evaluationRetainedPrevious=true
                if Task.isCancelled || error is CancellationError { evaluationAttemptState="cancelled";evaluationAttemptReason="취소됨 · 이전 완료 결과 보존";message="정확도 평가 취소됨 · 이전 완료 결과를 보존했습니다.";productivityStatus=message }
                else { evaluationAttemptState="unscored";evaluationAttemptReason=error.localizedDescription;self.error=error.localizedDescription;productivityStatus="정확도 평가 실패 · 이전 완료 결과 보존" }
            }
        }
    }

    func chooseReferenceAndEvaluate() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .init(filenameExtension: "srt")!]
        panel.message = "일반 대본 비교(.srt/.txt)입니다. 검수자·원본 SHA·revision 확인 없이 문구만 비교합니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        evaluateSelectedCaptions(referenceURL: url)
    }

    func chooseHumanReferenceAndEvaluate() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json]
        panel.message="실제 청취 검수 JSON을 선택하세요. 원본 전체 SHA·원본 구간·언어·검수 revision을 확인합니다."
        guard panel.runModal() == .OK,let url=panel.url else { return }
        evaluateSelectedCaptions(referenceURL:url)
    }

    static func summary(_ report: TranscriptEvaluationReport) -> String {
        if let human=report.humanReference {
            if human.state == "pending" { return "사람 검수 대기 · 수치 없음 · " + (human.metrics.reason ?? "청취 검수 필요") }
            if human.state == "nonspeech_control" { return "비발화 대조군 · 과잉 자막 \(human.metrics.falsePositiveCaptions ?? 0)개 · CER/WER 없음" }
            if human.state == "unscored" { return "사람 검수 평가 보류 · 수치 없음 · " + (human.metrics.reason ?? "비교 조건 확인") }
        }
        guard report.status == .scored else { return "일반 대본 평가 불가 · " + (report.reason ?? "대본 없음") }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "-" }
        var text = "CER \(pct(report.cer)) · WER \(pct(report.wer)) · 누락 \(report.missing.count) · 과잉 \(report.extra.count)"
        if let t = report.timing { text += String(format: " · 시작 오차 중앙값 %.2f초", t.medianAbsoluteStart) }
        return text + (report.humanReference == nil ? " · 일반 대본 기준 · 검수 provenance 미확인" : " · 사람 검수 JSON 기준") + (report.alignmentApproximate == true ? " · 문장 대응 검토 필요" : "")
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
            for var clip in track.clips where ids.contains(clip.id) && CaptionQuery.role(of: clip) == .original {
                let text = clip.title?.text ?? ""
                var metadata = clip.captionMetadata ?? CaptionMetadata(language: language, originalLanguage: language, originalText: text, generatedText: clip.connection?.generatedText ?? text)
                metadata.language = language; metadata.originalLanguage = language
                metadata.languageManual = true; metadata.languageConfidence = nil; metadata.languageNeedsReview = nil; metadata.languageOrigin = .manual
                if let connection=clip.connection {
                    let evidence=(metadata.languageEvidence ?? []).filter {$0.method != .manual}.prefix(7)
                    metadata.languageEvidence=Array(evidence)+[SourceLanguageObservation(start:connection.sourceStart.seconds,end:connection.sourceStart.seconds+connection.sourceDuration.seconds,language:language,method:.manual,state:.specified,reason:"userCaptionLanguageOverride")]
                }
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
            for var clip in track.clips where ids.contains(clip.id) && CaptionQuery.role(of: clip) == .original {
                guard var metadata = clip.captionMetadata else { continue }
                let a=clip.connection?.sourceStart.seconds ?? clip.sourceStart.seconds
                let b=a+(clip.connection?.sourceDuration.seconds ?? clip.duration.seconds)
                let detected = SourceLanguageAnalysis.decision(text:clip.title?.text ?? "",start:a,end:b,clipLanguage:metadata.clipLanguage ?? metadata.language,observations:metadata.languageEvidence ?? [])
                metadata.language = detected.language; metadata.originalLanguage = detected.language
                metadata.languageConfidence = detected.confidence; metadata.languageNeedsReview = detected.needsReview ? true : nil; metadata.languageManual = nil
                metadata.languageOrigin = detected.origin; metadata.languageEvidence = detected.evidence
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
        guard channelSpeakerMappingConfirmed else { speakerStatus = "화자 구분 불확실 · 채널의 음성/음악과 인물은 음량만으로 확인할 수 없습니다. 원본별 마이크 배치를 확인하세요."; message = speakerStatus; return }
        error = nil
        let captions = project.sequence.tracks.filter { $0.kind == .title && !$0.isLocked }.flatMap { track in
            track.clips.filter { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil }.map { (track.id, $0) }
        }
        guard !captions.isEmpty else { error = "화자를 나눌 원문 자막이 없습니다. 먼저 자동 자막을 만드세요."; return }
        let ranges = captions.map { $0.1.connection!.sourceStart.seconds...($0.1.connection!.sourceStart + $0.1.connection!.sourceDuration).seconds }
        let snapshot = project, url = asset.resolvedURL(relativeTo: mediaBaseURL)
        productivityBusy = true; productivityStatus = "채널별 음량으로 화자 구분 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                let sourceStamp = try MediaFingerprintCache.stat(url)
                let result = try await SpeakerSeparation.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, ranges: ranges)
                guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("화자 분석 중 원본 미디어가 변경되었습니다.") }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("분석 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                try await checkpointAsyncJob(ticket, "speaker.beforeApply")
                guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("화자 분석 원본이 변경되었습니다.") }
                guard result.status != .unavailable else { speakerStatus = result.message; message = result.message; return }
                var sequence = SpeakerEditing.migrating(snapshot.sequence)
                var profiles = sequence.speakers ?? []
                for ((trackID, original), assignment) in zip(captions, result.assignments) {
                    guard original.captionMetadata?.speakerManual != true else { continue }
                    guard let ti = sequence.tracks.firstIndex(where: { $0.id == trackID }), let ci = sequence.tracks[ti].clips.firstIndex(where: { $0.id == original.id }) else { continue }
                    var caption = sequence.tracks[ti].clips[ci]
                    var metadata = caption.captionMetadata ?? CaptionMetadata(language: speechOptions.language, originalLanguage: speechOptions.language, originalText: caption.title?.text ?? "", generatedText: caption.title?.text ?? "")
                    metadata.speaker = result.status == .separated ? assignment.channelIndex.map { SpeakerIdentity.channel(sourceID: asset.id, index: $0) } : nil
                    metadata.speakerStatus = metadata.speaker == nil ? "uncertain" : "separated"
                    caption.captionMetadata = metadata
                    if let id = metadata.speaker, let channel = assignment.channelIndex {
                        if !profiles.contains(where: { $0.id == id }) { profiles.append(SpeakerProfile(id: id, name: "화자 \(SpeakerSeparation.label(for: channel)) · \(asset.name)", colorHex: SpeakerProfile.defaultColors[channel % SpeakerProfile.defaultColors.count])) }
                        caption.title?.colorHex = profiles.first { $0.id == id }?.colorHex ?? "FFFFFF"
                    }
                    sequence.tracks[ti].clips[ci] = caption
                }
                sequence.speakers = profiles.isEmpty ? sequence.speakers : profiles
                if sequence != snapshot.sequence && !perform(.replaceSequence(sequence)) { return }
                speakerStatus = result.message; message = result.message
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "화자 구분 취소됨" } else { self.error = error.localizedDescription } }
        }
    }

    /// Renames/recolours one speaker and restyles every caption of that speaker. One undo step.
    func updateSpeaker(_ id: String, name: String, colorHex: String) {
        let hex = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard !busyDocument, !name.trimmingCharacters(in: .whitespaces).isEmpty, hex.count == 6, hex.allSatisfy(\.isHexDigit) else { error = "화자 이름과 6자리 색상(RRGGBB)을 입력하세요."; return }
        var sequence = SpeakerEditing.migrating(project.sequence)
        guard var profiles = sequence.speakers, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard !sequence.tracks.contains(where: { $0.isLocked && $0.clips.contains { $0.captionMetadata?.speaker == id } }) else { error = "화자의 자막 트랙 잠금을 해제하세요."; return }
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
        var sequence = SpeakerEditing.migrating(project.sequence)
        var moved = 0
        for profile in sequence.speakers ?? [] {
            let target = sequence.tracks.firstIndex { track in
                track.kind == .title && !track.isLocked && !track.isHidden && track.name.hasPrefix("화자 · ") && !track.clips.isEmpty && track.clips.allSatisfy { $0.captionMetadata?.speaker == profile.id && CaptionQuery.role(of: $0) == .original }
            }
            var clips: [Clip] = []
            for ti in sequence.tracks.indices where ti != target && sequence.tracks[ti].kind == .title && !sequence.tracks[ti].isLocked && !sequence.tracks[ti].isHidden {
                let moving = sequence.tracks[ti].clips.filter { $0.captionMetadata?.speaker == profile.id && CaptionQuery.role(of: $0) == .original && $0.captionHidden != true }
                let ids = Set(moving.map(\.id)); clips += moving
                sequence.tracks[ti].clips.removeAll { ids.contains($0.id) }
            }
            guard !clips.isEmpty else { continue }; moved += clips.count
            if let target { sequence.tracks[target].clips += clips; sequence.tracks[target].clips.sort { $0.start < $1.start }; sequence.tracks[target].name = "화자 · " + profile.name }
            else { sequence.tracks.append(Track(name: "화자 · " + profile.name, kind: .title, clips: clips.sorted { $0.start < $1.start })) }
        }
        guard moved > 0 else { message = "이동할 화자 자막이 없습니다. 숨김·잠금 자막은 유지합니다."; return }
        if perform(.replaceSequence(sequence)) { message = "화자별 트랙으로 \(moved)개 이동 · 시간과 연결 유지" }
    }
}

extension EditorModel {
    /// For recordings with one microphone per channel: recognise each active channel on its own and
    /// label its sentences with that channel's speaker. Refused (with the measured reason) when
    /// the channels are not independent, so nobody is labelled by guesswork. Replaces this clip's
    /// unedited automatic captions; hand-corrected ones are kept. One undo step.
    func transcribeSpeakersByChannel() {
        guard !busyDocument, transcriptionReady, let (_, clip, asset) = selectedSpeechClips.first else { return }
        guard channelSpeakerMappingConfirmed else { speakerStatus = "화자 구분 불확실 · 원본별 마이크 배치를 먼저 확인하세요. 음악 채널은 화자로 추정하지 않습니다."; message = speakerStatus; return }
        error = nil
        let snapshot = project, url = asset.resolvedURL(relativeTo: mediaBaseURL), base = speechOptions
        let useCheckpoints = useSpeechCheckpoints, windowSeconds = speechWindowSeconds
        let skipsNonSpeech = skipNonSpeech, activityPolicy = voiceActivityPolicy
        let store = checkpointStore, fingerprints = mediaFingerprints, provider = speakerTranscriptionProvider
        let configuration = WhisperConfiguration(modelSpec: speechModelSpec)
        let preset = allTitlePresets.first(where: { $0.id == transcriptionPresetID }) ?? TitlePreset.builtIns[0]
        let style = TitleSizing.title(for: preset, width: snapshot.sequence.width, height: snapshot.sequence.height)
        pausePlayback(); productivityBusy = true; transcriptionActive = true; productivityStatus = "채널 구성 확인 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { if ownsAsyncJob(ticket) { transcriptionActive = false; finishAsyncJob(ticket); refreshCheckpointSummaries() } }
            do {
                try validateAsyncJob(ticket)
                let sourceStamp = try MediaFingerprintCache.stat(url)
                let layout = try await SpeakerSeparation.channelLayout(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration)
                try validateAsyncJob(ticket)
                guard layout.channels > 1 else { speakerStatus = "모노 음성이라 채널별 화자 인식을 할 수 없습니다."; message = speakerStatus; return }
                guard layout.isSeparated else {
                    speakerStatus = String(format: "화자 구분 불확실 · 채널이 분리된 녹음이 아닙니다(활성 채널 %d개, 채널 간 상관 %.2f). 채널별 인식을 하지 않았습니다.", layout.activeChannels.count, layout.maxCorrelation)
                    message = speakerStatus; return
                }
                guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("채널 구성 분석 중 원본 미디어가 변경되었습니다.") }
                let digest = useCheckpoints && provider == nil ? try await fingerprints.sha256(of: url) : nil
                try validateAsyncJob(ticket)
                var captions: [Clip] = []
                for choice in layout.recognitionChannels {
                    let channel = choice.index, index = choice.ordinal
                    try validateAsyncJob(ticket)
                    productivityStatus = "채널 \(channel + 1) 인식 중 (\(index + 1)/\(layout.activeChannels.count))…"
                    var options = base; options.channel = channel
                    let result: (cues: [CaptionCue], language: String, languageObservations: [SourceLanguageObservation])
                    if let provider { result = (try await provider(channel), options.language, []) }
                    else {
                        var session: TranscriptionCheckpointSession?, lease: TranscriptionCacheLease?
                        defer { lease?.finish() }
                        if let digest {
                            let key = TranscriptionCheckpointKey(projectID: snapshot.id, clipID: clip.id, mediaSHA256: digest, sourceStart: clip.sourceStart, duration: clip.sourceDuration, windowSeconds: windowSeconds, options: options, modelSHA256: configuration.modelSpec.sha256, skipsSilence: skipsNonSpeech, voiceActivityPolicy: activityPolicy)
                            lease = try store.beginSession(for: key)
                            session = TranscriptionCheckpointSession(store: store, key: key, lease: lease)
                        }
                        var report: VoiceActivityReport?
                        if skipsNonSpeech {
                            if let session, let saved = session.store.voiceActivity(for: session.key) { report = saved }
                            else {
                                productivityStatus = "채널 \(channel + 1) 말소리·무음 분석 중…"
                                report = try await VoiceActivity.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, preferredChannel: channel, policy: activityPolicy)
                                if let session, let report { try session.store.saveVoiceActivity(report, for: session.key) }
                            }
                        }
                        guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("채널 분석 중 원본 미디어가 변경되었습니다.") }
                        productivityStatus = "채널 \(channel + 1) 인식 중 (\(index + 1)/\(layout.activeChannels.count))…"
                        let actual = try await LocalTranscription.transcribeLong(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, configuration: configuration, options: options, windowSeconds: windowSeconds, checkpoint: session, speechRegions: report?.speechRegions, speechEvidence: report?.confidentSpeech, audioSelection: report?.channelSelection, speechPolicy: activityPolicy)
                        let coarse = report.map { VoiceActivity.tightened(actual.cues, report: $0).cues } ?? actual.cues
                        let timed = try await SpeakerSeparation.tightenedToChannelSignal(coarse, url: url, channel: channel, sourceStart: clip.sourceStart, duration: clip.sourceDuration)
                        result = (timed, actual.language, actual.languageObservations ?? [])
                    }
                    try validateAsyncJob(ticket)
                    let label = SpeakerIdentity.channel(sourceID: asset.id, index: channel)
                    for var caption in CaptionEditing.automaticClips(cues: result.cues, source: clip, style: style) {
                        let text = caption.title?.text ?? ""
                        let connection = caption.connection
                        let a = connection?.sourceStart.seconds ?? clip.sourceStart.seconds
                        let b = a + (connection?.sourceDuration.seconds ?? caption.duration.seconds)
                        let detected = SourceLanguageAnalysis.decision(text:text,start:a,end:b,clipLanguage:result.language,requestedLanguage:options.language,observations:result.languageObservations)
                        var metadata = CaptionMetadata(language: detected.language, originalLanguage: detected.language, originalText: text, generatedText: text)
                        metadata.clipLanguage = result.language; metadata.languageConfidence = detected.confidence
                        metadata.languageOrigin = detected.origin; metadata.languageEvidence = detected.evidence
                        metadata.languageManual = detected.origin == .manual ? true:nil
                        metadata.languageNeedsReview = detected.needsReview ? true : nil
                        metadata.speaker = label; metadata.speakerStatus = "separated"
                        caption.captionMetadata = metadata; captions.append(caption)
                    }
                }
                try Task.checkCancellation()
                guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("채널 인식 중 원본 미디어가 변경되었습니다.") }
                guard !captions.isEmpty else { speakerStatus = "화자 구분 불확실 · 인식된 말소리가 없어 기존 자막을 유지했습니다."; message = speakerStatus; return }
                guard project == snapshot else { throw ProjectError("인식 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                try await checkpointAsyncJob(ticket, "speakerASR.beforeApply")
                guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("인식 원본이 변경되었습니다.") }
                var sequence = SpeakerEditing.migrating(snapshot.sequence)
                var kept: [Clip] = []
                for ti in sequence.tracks.indices where sequence.tracks[ti].kind == .title && !sequence.tracks[ti].isLocked {
                    // Drop this clip's unedited automatic originals; keep corrected ones and translations.
                    kept += sequence.tracks[ti].clips.filter { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil && CaptionLanguagePreservation.shouldKeep($0,trackLocked:false,in:snapshot.sequence) }
                    sequence.tracks[ti].clips.removeAll { $0.connection?.parentID == clip.id && $0.captionMetadata?.translatedFrom == nil && !kept.contains($0) }
                }
                kept += snapshot.sequence.tracks.filter(\.isLocked).flatMap(\.clips).filter {$0.connection?.parentID == clip.id && CaptionQuery.role(of:$0) == .original}
                captions.removeAll { c in kept.contains { $0.start < c.end && $0.end > c.start } }
                var profiles = sequence.speakers ?? []
                for label in Set(captions.compactMap { $0.captionMetadata?.speaker }).sorted() where !profiles.contains(where: { $0.id == label }) {
                    let i = SpeakerIdentity.channelIndex(label) ?? 0
                    profiles.append(SpeakerProfile(id: label, name: "화자 \(SpeakerSeparation.label(for: i)) · \(asset.name)", colorHex: SpeakerProfile.defaultColors[i % SpeakerProfile.defaultColors.count]))
                }
                for ci in captions.indices { if let hex = profiles.first(where: { $0.id == captions[ci].captionMetadata?.speaker })?.colorHex { captions[ci].title?.colorHex = hex } }
                sequence.speakers = profiles
                if !captions.isEmpty { sequence.tracks.append(Track(name: "자동 자막 · 채널별 화자 · \(clip.name)", kind: .title, clips: captions.sorted { $0.start < $1.start })) }
                if perform(.replaceSequence(sequence)) {
                    speakerStatus = "채널별 인식 · 화자 후보 \(Set(captions.compactMap { $0.captionMetadata?.speaker }).count)개 · 자막 \(captions.count)개 (채널 간 상관 \(String(format: "%.2f", layout.maxCorrelation)))"
                    message = speakerStatus + " · ⌘Z로 되돌릴 수 있습니다."
                }
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "채널별 인식 취소됨 · 기존 자막 유지" } else { self.error = error.localizedDescription } }
        }
    }
}

extension EditorModel {
    var speakerSelectedOriginals: [CaptionEntry] {
        let ids = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        let entries = CaptionQuery.entries(in: project.sequence)
        var sourceIDs = ids
        for entry in entries where ids.contains(entry.clip.id) && entry.role == .translation {
            guard let source = CaptionTranslationTracking.source(for: entry.clip, in: project.sequence) else { return [] }
            sourceIDs.insert(source.id)
        }
        return entries.filter { $0.role == .original && sourceIDs.contains($0.clip.id) }
    }
    func assignSpeakerToSelected(_ id: String?) {
        guard !busyDocument else { return }
        do { let sequence = try SpeakerEditing.assigning(id, to: Set(speakerSelectedOriginals.map { $0.clip.id }), in: project.sequence)
            if perform(.replaceSequence(sequence)) { message = id == nil ? "선택 자막 화자 해제 · 재분석에서도 보존" : "선택 자막 화자 수동 지정 · 원문·번역 연결 유지" }
        } catch { self.error = error.localizedDescription }
    }
    func createSpeakerForSelection(name: String) {
        guard !busyDocument, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = speakerSelectedOriginals.first else { return }
        var sequence = SpeakerEditing.migrating(project.sequence)
        let scope = SpeakerIdentity.sourceID(for: first.clip, in: sequence)
        guard speakerSelectedOriginals.allSatisfy({ SpeakerIdentity.sourceID(for: $0.clip, in: sequence) == scope }) else { error = "같은 원본의 자막을 선택하세요."; return }
        let id = SpeakerIdentity.manual(sourceID: scope)
        sequence.speakers = (sequence.speakers ?? []) + [SpeakerProfile(id: id, name: name, colorHex: "FFFFFF")]
        do { sequence = try SpeakerEditing.assigning(id, to: Set(speakerSelectedOriginals.map { $0.clip.id }), in: sequence); _ = perform(.replaceSequence(sequence)) }
        catch { self.error = error.localizedDescription }
    }
    func mergeSpeakers(_ from: String, into to: String) {
        guard !busyDocument else { return }
        do { let sequence = try SpeakerEditing.merging(from, into: to, in: project.sequence); if perform(.replaceSequence(sequence)) { message = "같은 원본의 화자 합침 · ⌘Z로 복원" } }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Caption batch editing (upgrade 5)

extension EditorModel {
    /// Selected captions that batch edits may touch: on visible, unlocked title tracks only.
    var batchEditableCaptions: [(Track, Clip)] {
        let selected = selectedClipIDs.isEmpty ? Set([selectedClipID].compactMap { $0 }) : selectedClipIDs
        return CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true)
            .filter { selected.contains($0.clip.id) }.map { ($0.track, $0.clip) }
    }
    /// Applies one change to every selected visible caption as a single undo step. Captions on
    /// hidden tracks (the preserved original or other-language translation) are never changed, even
    /// if selected. With `fitSafeArea`, each result is shrunk/moved into the 80% safe area; a caption
    /// that cannot fit at the minimum size is left as edited and reported.
    @discardableResult
    func applyCaptionBatch(_ change: CaptionBatchChange, fitSafeArea: Bool) -> Bool {
        guard !busyDocument else { return false }
        let targets = batchEditableCaptions
        let hidden = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope).filter { selectedClipIDs.contains($0.clip.id) && (!$0.isVisible || $0.track.isLocked) }.count
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
        guard !commands.isEmpty else {
            message = unfit > 0 ? "최소 24px로도 맞출 수 없는 자막 \(unfit)개 · 문구를 자르지 않고 유지했습니다. 분할하거나 목표 줄 수를 조절하세요." : "선택한 자막이 이미 그 상태입니다."
            return unfit == 0
        }
        guard perform(.batch(commands)) else { return false }
        var parts = ["자막 \(commands.count)개 일괄 수정"]
        if hidden > 0 { parts.append("숨김·잠금 트랙 \(hidden)개 제외") }
        if fitSafeArea { parts.append("안전 영역 맞춤 \(fitted)개") }
        if unfit > 0 { parts.append("최소 24px로도 맞출 수 없는 자막 \(unfit)개 · 문구를 보존했습니다. 분할하거나 목표 줄 수를 조절하세요") }
        message = parts.joined(separator: " · ") + " · ⌘Z로 한 번에 되돌리기"
        return true
    }
    func selectAllVisibleCaptions() {
        let ids = CaptionQuery.entries(in: project.sequence, scope: currentCaptionScope, visibleOnly: true, editableOnly: true).map { $0.clip.id }
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
        let snapshot = project
        let base = mediaBaseURL, fingerprints = mediaFingerprints, channel = speechOptions.channel, policy = voiceActivityPolicy
        productivityBusy = true; productivityStatus = "말소리 구간 분석 중…"; error = nil
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                var reports: [UUID: VoiceActivityReport] = [:], summary: [String] = []
                var sourceStamps: [URL:String] = [:]
                for (_, clip, asset) in sources {
                    try Task.checkCancellation()
                    let url = asset.resolvedURL(relativeTo: base)
                    let sourceStamp = try MediaFingerprintCache.stat(url)
                    sourceStamps[url] = sourceStamp
                    let digest = try await fingerprints.sha256(of: url)
                    try validateAsyncJob(ticket)
                    let key = "\(digest)|\(clip.sourceStart.seconds)|\(clip.sourceDuration.seconds)|\(channel)|\(policy.rawValue)|\(VoiceActivityReport.version)"
                    let report: VoiceActivityReport
                    if let cached = voiceActivityCache[key], cached.isValid { report = cached }
                    else {
                        report = try await VoiceActivity.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, preferredChannel: channel, policy: policy) { [weak self] fraction in
                            Task { @MainActor in self?.acceptProductivityProgress("\(clip.name) 말소리 구간 분석 \(Int(fraction * 100))%", ticket: ticket) }
                        }
                        try validateAsyncJob(ticket)
                        guard try MediaFingerprintCache.stat(url) == sourceStamp else { throw ProjectError("말소리 분석 중 원본 미디어가 바뀌었습니다.") }
                        let memoryBytes = voiceActivityCache.values.reduce(0) { $0 + $1.estimatedBytes }
                        if voiceActivityCache.count >= 16 || memoryBytes + report.estimatedBytes > 16 * 1_024 * 1_024 { voiceActivityCache.removeAll() }
                        if report.isValid && report.estimatedBytes <= 16 * 1_024 * 1_024 { voiceActivityCache[key] = report }
                    }
                    reports[clip.id] = report
                    summary.append(VoiceActivitySummary.describe(report))
                }
                try Task.checkCancellation()
                for (url,stamp) in sourceStamps { guard try MediaFingerprintCache.stat(url) == stamp else { throw ProjectError("말소리 검사 중 원본 미디어가 바뀌었습니다. 다시 검사하세요.") } }
                guard project == snapshot else { throw ProjectError("말소리 검사 중 프로젝트가 바뀌었습니다. 다시 검사하세요.") }
                try await checkpointAsyncJob(ticket, "vad.beforeApply")
                for (url,stamp) in sourceStamps { guard try MediaFingerprintCache.stat(url) == stamp else { throw ProjectError("말소리 검사 원본이 변경되었습니다.") } }
                let flagged = flagSilentCaptions(reports: reports)
                lastVoiceActivity = reports.values.first
                message = summary.joined(separator: " / ") + (flagged > 0 ? " · 무음·음악·소음 위 자막 \(flagged)개 · 자막 목록에서 확인하세요." : " · 무음 위 자막 없음")
                productivityStatus = message
            } catch {
                guard ownsAsyncJob(ticket) else { return }
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

    func refreshBackups() {
        let scan = ProjectBackup.scan(root: backupRoot); backupEntries = scan.entries
        backupStatus = scan.rejected > 0 ? "손상되거나 불완전한 백업 \(scan.rejected)개는 복원 목록에서 제외했습니다. 파일은 보존했습니다." : "백업은 마지막 저장본이며 원본 미디어를 포함하지 않습니다."
    }
    /// Backs up the saved document. Unsaved changes are not included, so the user is told to save first.
    func createProjectBackup() {
        guard let url = documentURL else { error = "먼저 프로젝트를 저장한 뒤 백업하세요."; return }
        let excludesUnsaved = dirty
        do {
            let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
            let folder = try ProjectBackup.create(documentURL: url, root: backupRoot, appVersion: version, unsavedChangesPresent: excludesUnsaved)
            refreshBackups()
            message = "프로젝트 백업 완료 · 마지막 저장본 · " + (excludesUnsaved ? "미저장 변경 제외 · " : "미저장 변경 없음 · ") + "원본 미디어 미포함 · \(folder.lastPathComponent)"
        } catch { self.error = "백업 실패: " + error.localizedDescription }
    }
    func restoreBackup(_ entry: ProjectBackup.Entry) {
        do {
            let project = try ProjectBackup.restore(entry)
            let missing = ProjectBackup.missingMedia(entry)
            openRestored(project, baseURL: URL(fileURLWithPath: entry.manifest.originalPath),
                         note: entry.manifest.scopeSummary + " · 백업에서 복원 · 새 문서로 열었습니다. 기존 파일은 그대로이며 ‘다른 이름으로 저장’하세요." + (missing.isEmpty ? "" : " · 찾을 수 없는 미디어 \(missing.count)개(다시 연결 필요)"))
        } catch { self.error = "복원 실패: " + error.localizedDescription }
    }
}

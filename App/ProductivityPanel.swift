import SwiftUI
import AppKit
import JHCutCore

struct AudioTools: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button("선택 구간 오디오 분석") { model.analyzeSound() }.disabled(model.selectedSound == nil || model.busyDocument)
            if let (track, _, asset) = model.selectedSound, asset.kind == .video, track.kind != .audio {
                Button("영상에서 오디오 분리") { model.separateSelectedAudio() }.disabled(model.busyDocument)
            }
            DisclosureGroup("배경음 자동 감쇠") {
                Slider(value: $model.duckingDB, in: -30...0)
                Text(String(format: "대사 중 %.0fdB", model.duckingDB)).font(JH.Font.micro)
                Text(String(format: "복귀 시간 %.1f초", model.duckingRelease)).font(JH.Font.micro)
                Slider(value: $model.duckingRelease, in: 0.1...2)
                Button("선택한 배경음에 적용") { model.duckSelectedMusic() }.disabled(model.selectedSound == nil || model.busyDocument)
                Button("자동 감쇠 해제") { model.removeDucking() }.disabled(model.selected?.1.ducking == nil)
                Text("자막 구간 기준 · 대사 편집 후 다시 적용하세요.").font(JH.Font.micro)
            }
            if let result = model.audioResult, model.analysisMatchesSelection {
                Text("피크 \(decibels(result.peakDBFS)) · RMS \(decibels(result.rmsDBFS)) dBFS").font(JH.Font.numeric(10))
                Text("원본 \(Int(result.sampleRate))Hz · \(result.channelCount)채널 · 클리핑 경계 샘플 \(result.clippingSampleCount)개").font(JH.Font.micro).foregroundStyle(.secondary)
                Button(result.normalizationBoostLimited ? "피크 증폭 · +12dB 상한 적용" : "피크 -1dBFS에 맞추기") { model.normalizePeak() }.disabled(result.normalizationGain == nil || model.busyDocument)
                Text("최대 증폭 +12dB. 원본 분석이며 믹스 전체의 LUFS 측정은 아닙니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                DisclosureGroup("무음 후보 \(result.silenceRegions.count)개 · 클릭하여 이동") {
                    ForEach(Array(result.silenceRegions.prefix(100).enumerated()), id: \.offset) { _, region in
                        Button(String(format: "원본 %.2f초 · %.2f초 길이", region.start.seconds, region.duration.seconds)) { model.seekSilence(region) }.font(JH.Font.caption).buttonStyle(.borderless)
                    }
                    if result.silenceRegions.count > 100 { Text("처음 100개 표시 · 분석 범위를 좁혀 확인하세요.").font(.caption2) }
                }.font(JH.Font.caption)
            }
        }.buttonStyle(.jhTool).font(JH.Font.label)
    }
    private func decibels(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "−∞" }
}

struct SpeechTools: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("다국어 자동 자막·번역").font(JH.Font.label.weight(.semibold))
            Toggle("영상 가져오면 자동 자막 생성", isOn: $model.autoCaptionImportedVideos).disabled(model.busyDocument)
            Toggle("자막 생성 후 자동 번역", isOn: $model.translateAfterTranscription).disabled(model.busyDocument)
            if !model.detectedSpeechLanguages.isEmpty { Text("감지된 음성: " + model.detectedSpeechLanguages).font(JH.Font.micro) }
            Text(model.transcriptionStatus).font(JH.Font.micro).foregroundStyle(.secondary)
            if !model.selectedSpeechClips.isEmpty {
                Text("선택한 음성 클립 \(model.selectedSpeechClips.count)개").font(JH.Font.caption)
                ForEach(model.selectedSpeechClips.prefix(4), id: \.1.id) { entry in
                    Text(entry.1.name).font(JH.Font.micro).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            Picker("자막 스타일", selection: $model.transcriptionPresetID) {
                ForEach(model.allTitlePresets) { preset in Text(preset.name).tag(preset.id) }
            }.disabled(model.busyDocument)
            Picker("인식 모델", selection: $model.speechModelID) { Text("base · 빠르게").tag("base"); Text("small · 품질 비교용").tag("small") }.disabled(model.busyDocument)
                .onChange(of: model.speechModelID) { model.refreshTranscriptionStatus() }
            Toggle("기존 자동 자막 교체 · 직접 고친 문구 보존", isOn: $model.replaceAutomaticCaptions).disabled(model.busyDocument)
            Toggle("긴 영상 이어하기 · 5분 구간마다 저장", isOn: $model.useSpeechCheckpoints).disabled(model.busyDocument)
            Toggle("무음·음악·소음 구간은 인식 생략 · 원본 소리는 그대로", isOn: $model.skipNonSpeech).disabled(model.busyDocument)
            VoiceActivityRow(model: model)
            if !model.selectedClipCheckpoints.isEmpty {
                let done = model.selectedClipCheckpoints.reduce(0) { $0 + $1.completedWindows }
                let total = model.selectedClipCheckpoints.reduce(0) { $0 + $1.totalWindows }
                Text("이어하기 가능 · \(done)/\(total)구간 완료됨 · 원본·설정이 같을 때만 재사용").font(JH.Font.micro)
                HStack {
                    Button("체크포인트 삭제") { model.deleteSelectedCheckpoints() }
                    Button("처음부터 다시 인식") { model.restartTranscriptionFromScratch() }.disabled(!model.transcriptionReady)
                }.disabled(model.busyDocument)
            }
            DisclosureGroup("음성 인식 설정") {
                Picker("언어", selection: $model.speechOptions.language) {
                    Text("한국어").tag("ko"); Text("영어").tag("en"); Text("일본어").tag("ja"); Text("자동 감지").tag("auto")
                }
                Picker("대사 채널", selection: $model.speechOptions.channel) {
                    Text("자동 · 가장 큰 채널").tag(-1)
                    ForEach(0..<8) { Text("채널 \($0 + 1)").tag($0) }
                }
                Toggle("정확도 우선 탐색", isOn: $model.speechOptions.accurate)
                HStack {
                    Button("선택 채널 10초 미리듣기") { model.playChannelPreview() }.disabled(model.selectedSpeechClips.isEmpty)
                    Button("정지") { model.stopAudition() }.disabled(model.auditionID == nil)
                }
                TextField("이름·전문용어 힌트 · 500자 이내", text: $model.speechOptions.glossary).textFieldStyle(.roundedBorder)
            }.disabled(model.busyDocument)
            DisclosureGroup("자막 번역 설정") {
                Picker("번역 언어", selection: $model.translationTargetLanguage) {
                    ForEach(CaptionLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Picker("원문 언어", selection: $model.translationSourceLanguage) {
                    Text("자동 · 음성 인식 결과 사용").tag("auto")
                    ForEach(CaptionLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("원문·번역을 함께 표시", isOn: $model.bilingualTranslation)
                Picker("번역 말투", selection: $model.translationStyle) {
                    ForEach(TranslationStyle.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                GlossaryEditor(model: model)
                TextField("번역 용어집 · 원문=번역, 줄마다 입력", text: $model.translationGlossaryText)
                    .textFieldStyle(.roundedBorder)
                Button("원문 자막 전체 번역") { model.translateCaptionTracks() }.disabled(model.captionClips.isEmpty)
                Button("원문 자막 표시") { model.showOriginalCaptionTracks() }.disabled(model.captionClips.isEmpty)
                Text("한국어·일본어·영어 상호 번역 · macOS 26 이상 · Apple 번역 언어팩 필요. 원문은 숨긴 트랙에 보존하며 번역은 별도로 교정할 수 있습니다.").font(JH.Font.micro)
            }.disabled(model.busyDocument)
            if model.translationActive {
                ProgressView(); Text(model.productivityStatus).font(JH.Font.micro)
                Button("번역 취소") { model.cancelProductivity() }
            }
            if model.transcriptionReady {
                Button("자동 자막 생성") { model.transcribeSelection() }
                    .buttonStyle(.jhPrimary).disabled(model.selectedSpeechClips.isEmpty || model.busyDocument)
            } else {
                Button("Whisper 모델 설치…") { model.installSpeechModel() }.disabled(model.busyDocument)
            }
            if model.transcriptionActive {
                ProgressView(value: model.transcriptionProgress).accessibilityLabel("음성 인식 진행률")
                Text(model.productivityStatus).font(JH.Font.micro)
                if let detail = model.transcriptionDetail { Text(SpeechTools.describe(detail)).font(JH.Font.micro).foregroundStyle(.secondary) }
                Button("자막 생성 취소") { model.cancelProductivity() }
            }
            DisclosureGroup("대본으로 정확도 평가") {
                Text("영상과 같은 이름의 .srt(시간 포함) 또는 .txt 대본과 선택 클립의 원문 자막을 비교합니다. 대본이 없으면 수치를 표시하지 않습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                HStack {
                    Button("옆 대본으로 평가") { model.evaluateSelectedCaptions() }
                    Button("대본 선택…") { model.chooseReferenceAndEvaluate() }
                }.disabled(model.selectedSpeechClips.isEmpty || model.busyDocument)
                if let report = model.lastEvaluation {
                    Text(EditorModel.summary(report)).font(JH.Font.micro)
                    if let url = model.lastEvaluationReportURL { Button("보고서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }
            }
            Text("영상 가져오기 → 음성 언어 자동 감지 → 원문 자막 → 선택 언어로 번역. 자동 생성을 끄면 기존처럼 타임라인에서 선택 후 생성할 수 있습니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            Text("여러 클립도 함께 선택할 수 있습니다. 수정한 자막은 유지합니다. 교체 옵션을 끄면 새 자막을 추가합니다. 음성은 외부로 업로드하지 않습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
        }.buttonStyle(.jhTool).font(JH.Font.caption)
            .onAppear { model.refreshTranscriptionStatus(); model.refreshCheckpointSummaries() }
            .onChange(of: model.selectedClipIDs) { model.refreshCheckpointSummaries() }
    }
    /// "구간 3/12 · 원본 10:00~ · 재사용 2 · 남은 예상 약 4분" — the estimate appears only once
    /// this run has recognised a window, so a resumed run never shows an invented number.
    static func describe(_ detail: TranscriptionProgress) -> String {
        func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
        var parts = ["구간 \(detail.windowIndex + 1)/\(detail.windowCount)", "원본 \(clock(detail.windowSourceStart))부터"]
        if detail.reusedWindows > 0 { parts.append("재사용 \(detail.reusedWindows)") }
        if detail.skippedWindows > 0 { parts.append("무음 건너뜀 \(detail.skippedWindows)") }
        if let remaining = detail.estimatedRemainingSeconds { parts.append(remaining < 60 ? "남은 예상 1분 미만" : "남은 예상 약 \(Int((remaining / 60).rounded()))분") }
        else { parts.append("남은 시간 계산 중") }
        return parts.joined(separator: " · ")
    }
}

struct TrackManager: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu("트랙 추가") {
                Button("오버레이") { model.addTrack(.overlay) }
                Button("오디오") { model.addTrack(.audio) }
                Button("자막") { model.addTrack(.title) }
            }
            ForEach(model.project.sequence.tracks) { track in
                TrackSettingsRow(model: model, track: track)
            }
            Text("트랙 순서는 합성 순서입니다. 클립 속성에서 다른 트랙으로 옮길 수 있습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
        }
    }
}

struct SafeAreaOverlay: View {
    let width: Int
    let height: Int
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Double(width), geometry.size.height / Double(height))
            let w = Double(width) * scale, h = Double(height) * scale
            Rectangle().stroke(.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(width: w * 0.8, height: h * 0.8)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct TrackSettingsRow: View {
    @ObservedObject var model: EditorModel
    let track: Track
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("트랙 이름 · Enter로 적용", text: $name).font(JH.Font.label).disabled(track.isLocked)
                .onAppear { name = track.name }.onChange(of: track.name) { _, value in name = value }
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { name = track.name; return }
                    var value = track; value.name = name; if !model.perform(.updateTrack(value)) { name = track.name }
                }
            Toggle("리플 편집에 함께 이동", isOn: Binding(get: { track.syncLocked == true }, set: { value in var copy = track; copy.syncLocked = value; model.perform(.updateTrack(copy)) })).font(JH.Font.micro).disabled(track.isLocked)
            HStack {
                Button { model.reorderTrack(track, by: -1) } label: { Image(systemName: "arrow.up") }.help("트랙 위로")
                Button { model.reorderTrack(track, by: 1) } label: { Image(systemName: "arrow.down") }.help("트랙 아래로")
                Spacer()
                Button("빈 트랙 삭제") { model.perform(.removeTrack(track.id)) }.disabled(track.kind == .video || !track.clips.isEmpty || track.isLocked)
            }.font(JH.Font.micro).buttonStyle(.borderless)
        }
    }
}

/// Voice-activity status and the “captions over silence” check.
struct VoiceActivityRow: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let report = model.lastVoiceActivity { Text(VoiceActivitySummary.describe(report)).font(JH.Font.micro).foregroundStyle(.secondary) }
            HStack {
                Button("무음·음악 위 자막 확인") { model.checkCaptionsAgainstVoiceActivity() }
                    .disabled(model.selectedSpeechClips.isEmpty || model.busyDocument)
                if !model.silentCaptionWarnings.isEmpty { Text("확인 필요 \(model.silentCaptionWarnings.count)개").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
            }
        }
    }
}

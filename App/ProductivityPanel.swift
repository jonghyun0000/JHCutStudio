import SwiftUI
import JHCutCore

struct AudioTools: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button("선택 구간 오디오 분석") { model.analyzeSound() }.disabled(model.selectedSound == nil || model.busyDocument)
            if let (track, _, asset) = model.selectedSound, asset.kind == .video, track.kind != .audio {
                Button("영상에서 오디오 분리") { model.separateSelectedAudio() }.disabled(model.busyDocument)
            }
            if let result = model.audioResult, model.analysisMatchesSelection {
                Text("피크 \(decibels(result.peakDBFS)) · RMS \(decibels(result.rmsDBFS)) dBFS").font(.system(size: 10, design: .monospaced))
                Text("원본 \(Int(result.sampleRate))Hz · \(result.channelCount)채널 · 클리핑 경계 샘플 \(result.clippingSampleCount)개").font(.system(size: 9)).foregroundStyle(.secondary)
                Button(result.normalizationBoostLimited ? "피크 증폭 · +12dB 상한 적용" : "피크 -1dBFS에 맞추기") { model.normalizePeak() }.disabled(result.normalizationGain == nil || model.busyDocument)
                Text("최대 증폭 +12dB. 원본 분석이며 믹스 전체의 LUFS 측정은 아닙니다.").font(.system(size: 9)).foregroundStyle(.secondary)
                DisclosureGroup("무음 후보 \(result.silenceRegions.count)개 · 클릭하여 이동") {
                    ForEach(Array(result.silenceRegions.prefix(100).enumerated()), id: \.offset) { _, region in
                        Button(String(format: "원본 %.2f초 · %.2f초 길이", region.start.seconds, region.duration.seconds)) { model.seekSilence(region) }.font(.system(size: 10)).buttonStyle(.borderless)
                    }
                    if result.silenceRegions.count > 100 { Text("처음 100개 표시 · 분석 범위를 좁혀 확인하세요.").font(.caption2) }
                }.font(.system(size: 10))
            }
        }.buttonStyle(.bordered).font(.system(size: 11))
    }
    private func decibels(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "−∞" }
}

struct SpeechTools: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("한국어 자동 자막").font(.system(size: 11, weight: .semibold))
            Text(model.transcriptionStatus).font(.system(size: 9)).foregroundStyle(.secondary)
            if model.transcriptionReady {
                Button("선택 클립에서 한국어 인식") { model.transcribeSelection() }.disabled(model.selectedSound == nil || model.busyDocument)
            } else {
                Button("Whisper 모델 설치…") { model.installSpeechModel() }.disabled(model.busyDocument)
            }
            Text("영상 또는 오디오 클립을 선택하세요. 새 자막 트랙에 추가하며 문구와 싱크는 검토가 필요합니다.").font(.system(size: 9)).foregroundStyle(.secondary)
        }.buttonStyle(.bordered).font(.system(size: 10)).onAppear { model.refreshTranscriptionStatus() }
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
            Text("트랙 순서는 합성 순서입니다. 클립 속성에서 다른 트랙으로 옮길 수 있습니다.").font(.system(size: 9)).foregroundStyle(.secondary)
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
            TextField("트랙 이름 · Enter로 적용", text: $name).font(.system(size: 11)).disabled(track.isLocked)
                .onAppear { name = track.name }.onChange(of: track.name) { _, value in name = value }
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { name = track.name; return }
                    var value = track; value.name = name; if !model.perform(.updateTrack(value)) { name = track.name }
                }
            HStack {
                Button { model.reorderTrack(track, by: -1) } label: { Image(systemName: "arrow.up") }.help("트랙 위로")
                Button { model.reorderTrack(track, by: 1) } label: { Image(systemName: "arrow.down") }.help("트랙 아래로")
                Spacer()
                Button("빈 트랙 삭제") { model.perform(.removeTrack(track.id)) }.disabled(track.kind == .video || !track.clips.isEmpty || track.isLocked)
            }.font(.system(size: 9)).buttonStyle(.borderless)
        }
    }
}

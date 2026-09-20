import SwiftUI
import JHCutCore

struct ClipInspector: View {
    @ObservedObject var model: EditorModel
    let track: Track
    let clip: Clip
    @State private var draft = Clip()
    @State private var titleExpanded = true
    @State private var start = "0"
    @State private var source = "0"
    @State private var duration = "3"
    @State private var x = "0"
    @State private var y = "0"
    @State private var scale = "1"
    @State private var rotation = "0"
    @State private var titleSize = "76"
    @State private var titleX = "0.5"
    @State private var titleY = "0.8"
    @State private var rate = 1.0
    @State private var selectedKeyTime: MediaTime?
    @State private var keySelectionPlayhead: Double?
    @State private var interpolation = KeyframeInterpolation.linear
    @State private var fonts = NSFontManager.shared.availableFonts.sorted()
    private var hasSound: Bool { clip.assetID.flatMap { id in model.project.assets.first { $0.id == id } }.map { $0.kind == .audio || $0.hasAudio } ?? false }
    /// Snapping grid comes from the sequence, so a 24 or 60fps project trims on its own frames.
    private var seqRate: FrameRate { model.frameRate }
    private func frames(_ seconds: Double) -> MediaTime { seqRate.time(forFrame: Int64((seconds * seqRate.fps).rounded())) }
    private var temporal: Bool { clip.assetID.flatMap { id in model.project.assets.first { $0.id == id } }?.kind != .image && clip.title == nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(clip.name).font(JH.Font.sectionTitle).lineLimit(2)
                Text(track.isLocked ? "잠긴 트랙" : "\(track.name) · 슬라이더는 바로 반영 · 숫자는 Return").font(JH.Font.caption).foregroundStyle(.secondary)
                DisclosureGroup("시간과 길이") { timing }
                if draft.title != nil { DisclosureGroup("자막 모양", isExpanded: $titleExpanded) { titleControls } }
                if track.kind != .audio { DisclosureGroup("화면 배치") { transformControls } }
                if temporal { DisclosureGroup("재생 속도") { speedControls } }
                if hasSound {
                    Divider()
                    AudioTools(model: model)
                    slider("볼륨", $draft.volume, 0...4, suffix: "배")
                    fadeSlider("소리 페이드 인", \.audioFadeIn)
                    fadeSlider("소리 페이드 아웃", \.audioFadeOut)
                }
                if track.kind != .audio {
                    Divider()
                    fadeSlider("화면 페이드 인", \.fadeIn)
                    fadeSlider("화면 페이드 아웃", \.fadeOut)
                }
                if clip.title == nil && track.kind != .audio { DisclosureGroup("색 보정과 크롭") { colorControls } }
                Button("입력한 숫자 적용") { apply() }.buttonStyle(.jhPrimary).frame(maxWidth: .infinity).disabled(track.isLocked)
                DisclosureGroup("키프레임") { keyframeControls }
                Menu("다른 트랙으로 이동") {
                    ForEach(model.project.sequence.tracks.filter { $0.id != track.id && ($0.kind == track.kind || (track.kind == .video && $0.kind == .overlay) || (track.kind == .overlay && $0.kind == .video)) }) { destination in
                        Button(destination.name) { model.moveSelectedClip(to: destination) }.disabled(destination.isLocked)
                    }
                }
                Button("이 클립으로 이동") { model.seek(clip.start.seconds) }.buttonStyle(.jhTool)
                Divider()
                Button("일반 삭제 · 빈 공간 유지", role: .destructive) { model.remove() }.buttonStyle(.borderless)
                Button("리플 삭제 · 현재 트랙", role: .destructive) { model.remove(ripple: true) }.buttonStyle(.borderless)
                Text("리플 삭제는 현재 트랙의 뒤 클립만 당깁니다. 다른 트랙은 이동하지 않습니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            }.padding(15)
        }.onAppear { sync() }.onChange(of: clip) { sync() }
    }
    private var timing: some View {
        Group {
            field("타임라인 시작 · 초", $start)
            if temporal { field("원본 시작 · 초", $source) }
            field("길이 · 초", $duration)
            Text("\(seqRate.label) fps 프레임 단위 · 앞뒤 페이드 합은 클립 길이 이하여야 합니다.").font(JH.Font.caption).foregroundStyle(.secondary)
        }
    }
    private var titleControls: some View {
        Group {
            Divider()
            Text("자막과 타이틀").font(JH.Font.sectionTitle)
            TextEditor(text: Binding(get: { draft.title?.text ?? "" }, set: { draft.title?.text = $0 })).font(.system(size: 14)).frame(height: 70).border(.gray.opacity(0.3))
            Picker("설치 글꼴", selection: Binding(get: { draft.title?.fontName ?? "AppleSDGothicNeo-Bold" }, set: { draft.title?.fontName = $0 })) {
                ForEach(fonts, id: \.self) { Text($0).tag($0) }
            }.font(JH.Font.caption).onChange(of: draft.title?.fontName) { commitNow() }
            field("글자 크기 · px", $titleSize)
            field("가로 위치 · 0…1", $titleX)
            field("세로 위치 · 아래 0 / 위 1", $titleY)
            TextField("글자색 · RRGGBB", text: Binding(get: { draft.title?.colorHex ?? "FFFFFF" }, set: { draft.title?.colorHex = $0 })).textFieldStyle(.roundedBorder).onSubmit { commitNow() }
            Picker("정렬", selection: style(\.alignment)) {
                Text("왼쪽").tag(JHCutCore.TextAlignment.left); Text("가운데").tag(JHCutCore.TextAlignment.center); Text("오른쪽").tag(JHCutCore.TextAlignment.right)
            }.font(JH.Font.label).onChange(of: draft.title?.style?.alignment) { commitNow() }
            slider("외곽선 · px", style(\.strokeWidth), 0...12)
            TextField("외곽선 색 · RRGGBB", text: style(\.strokeHex)).textFieldStyle(.roundedBorder).onSubmit { commitNow() }
            slider("배경 불투명도", style(\.backgroundOpacity), 0...1)
            TextField("배경색 · RRGGBB", text: style(\.backgroundHex)).textFieldStyle(.roundedBorder).onSubmit { commitNow() }
            slider("배경 여백 · px", style(\.padding), 0...80)
            slider("줄 간격 · px", style(\.lineSpacing), 0...80)
            Stepper("최대 \(draft.title?.style?.maxLines ?? 0)줄 · 0은 제한 없음", value: style(\.maxLines), in: 0...20).font(JH.Font.caption)
                .onChange(of: draft.title?.style?.maxLines) { commitNow() }
            Toggle("글자 그림자", isOn: style(\.shadow)).font(JH.Font.label)
                .onChange(of: draft.title?.style?.shadow) { commitNow() }
            if let title = draft.title, let info = try? TitlePreviewRenderer.layout(title: title, canvasWidth: Double(model.project.sequence.width)), info.wasTruncated {
                Text("\(info.totalLines)줄 중 \(info.visibleLines)줄만 출력됩니다. 글자 크기나 최대 줄 수를 조절하세요.").font(JH.Font.caption).foregroundStyle(JH.Palette.warning)
            }
        }
    }
    private var transformControls: some View {
        Group {
            Divider()
            Text("화면 배치").font(JH.Font.sectionTitle)
            field("가로 이동 · px", $x); field("세로 이동 · px", $y)
            field("크기 · 배율", $scale); field("회전 · 도", $rotation)
            if draft.title == nil {
                Toggle("화면 채움", isOn: $draft.transform.fill).font(JH.Font.label)
                    .onChange(of: draft.transform.fill) { commitNow() }
            }
            slider("불투명도", $draft.transform.opacity, 0...1)
        }
    }
    private var speedControls: some View {
        Group {
            Divider()
            HStack {
                Picker("속도", selection: $rate) { ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }
                Button("속도 적용") { model.perform(.setRate(trackID: track.id, clipID: clip.id, rate: PlaybackRate(numerator: Int32(rate * 4), denominator: 4))) }.buttonStyle(.jhTool)
            }.font(JH.Font.label)
            Text("원본 구간은 유지하고 같은 트랙의 뒤 클립을 이동합니다. 소리 높이를 유지하며 일정 속도로 재생합니다.").font(JH.Font.caption).foregroundStyle(.secondary)
        }
    }
    private var colorControls: some View {
        Group {
            Divider()
            Text("색 보정과 크롭").font(JH.Font.sectionTitle)
            slider("노출", visual(\.exposure), -4...4)
            slider("대비", visual(\.contrast), 0...2)
            slider("채도", visual(\.saturation), 0...2)
            slider("왼쪽 크롭", visual(\.cropLeft), 0...0.45)
            slider("오른쪽 크롭", visual(\.cropRight), 0...0.45)
            slider("위쪽 크롭", visual(\.cropTop), 0...0.45)
            slider("아래쪽 크롭", visual(\.cropBottom), 0...0.45)
            Button("색·크롭 초기화") { draft.visual = nil; commitNow() }.font(JH.Font.caption)
        }
    }
    private var keyframeControls: some View {
        Group {
            Divider()
            Text("키프레임 · 위치 / 크기 / 회전 / 불투명도 / 볼륨").font(JH.Font.caption.weight(.semibold))
            Picker("다음 키까지", selection: $interpolation) {
                Text("직선").tag(KeyframeInterpolation.linear); Text("유지").tag(KeyframeInterpolation.hold); Text("부드럽게").tag(KeyframeInterpolation.ease)
            }.font(JH.Font.label)
            Button("현재 위치에 키프레임 저장") { addKeyframe() }.buttonStyle(.jhTool)
            Text("플레이헤드를 옮겨 위 배치·볼륨 값을 맞춘 뒤 저장하세요. 슬라이더와 숫자 적용은 키프레임이 아니라 기본값을 바꿉니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            ForEach(clip.keyframes ?? [], id: \.time) { frame in
                HStack {
                    Button(String(format: "%.3f초 · %@", frame.time.seconds, frame.interpolation.rawValue)) { model.seek(clip.start.seconds + frame.time.seconds); loadFrame(frame) }.buttonStyle(.borderless)
                    Spacer()
                    Button { var value = clip; value.keyframes?.removeAll { $0.time == frame.time }; model.perform(.updateClip(trackID: track.id, clip: value)) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }.font(JH.Font.caption)
            }
        }
    }
    private func style<T>(_ path: WritableKeyPath<TextStyle, T>) -> Binding<T> {
        Binding(get: { (draft.title?.style ?? TextStyle())[keyPath: path] }, set: { value in var s = draft.title?.style ?? TextStyle(); s[keyPath: path] = value; draft.title?.style = s })
    }
    private func visual(_ path: WritableKeyPath<VisualAdjustments, Double>) -> Binding<Double> {
        Binding(get: { (draft.visual ?? VisualAdjustments())[keyPath: path] }, set: { value in var v = draft.visual ?? VisualAdjustments(); v[keyPath: path] = value; draft.visual = v })
    }
    private func fadeSlider(_ name: String, _ path: WritableKeyPath<Clip, MediaTime?>) -> some View {
        slider(name, Binding(get: { draft[keyPath: path]?.seconds ?? 0 }, set: { draft[keyPath: path] = frames($0) }), 0...max(1.0 / seqRate.fps, min(30, clip.duration.seconds)), suffix: "초")
    }
    private func slider(_ name: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, suffix: String = "") -> some View {
        // Dragging previews through the model; releasing commits the whole gesture as one undo step.
        let live = Binding(get: { binding.wrappedValue }, set: { value in
            binding.wrappedValue = value
            model.updateLiveEdit(trackID: track.id, clip: liveCandidate())
        })
        return VStack(spacing: 3) {
            HStack { Text(name); Spacer(); Text(String(format: "%.2f", binding.wrappedValue) + suffix).monospacedDigit() }.font(JH.Font.caption)
            Slider(value: live, in: range, onEditingChanged: { editing in
                if editing { model.beginLiveEdit() } else { model.commitLiveEdit() }
            }).controlSize(.small).disabled(track.isLocked)
        }
    }
    /// The clip as the controls currently describe it. Timing stays exactly as committed: only the
    /// number fields and `apply()` retime a clip, so no drag can ever move or trim it.
    private func liveCandidate() -> Clip {
        var candidate = draft
        if let px = Double(x), let py = Double(y), let sc = Double(scale), let rot = Double(rotation),
           [px, py, sc, rot].allSatisfy(\.isFinite), sc > 0 {
            candidate.transform.x = px; candidate.transform.y = py; candidate.transform.scale = sc; candidate.transform.rotation = rot
        }
        if candidate.title != nil, let size = Double(titleSize), let tx = Double(titleX), let ty = Double(titleY),
           [size, tx, ty].allSatisfy(\.isFinite), size > 0, (0...1).contains(tx), (0...1).contains(ty) {
            candidate.title?.fontSize = size; candidate.title?.x = tx; candidate.title?.y = ty
        }
        candidate.start = clip.start; candidate.sourceStart = clip.sourceStart; candidate.duration = clip.duration
        return candidate
    }
    /// For discrete controls that have no drag: one value change is one history entry.
    private func commitNow() {
        guard !track.isLocked else { return }
        let candidate = liveCandidate()
        guard candidate != clip else { return }
        if !model.perform(.updateClip(trackID: track.id, clip: candidate)) { sync() }
    }
    private func field(_ name: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(name).font(JH.Font.label).foregroundStyle(.secondary)
            Spacer(minLength: 5)
            TextField("", text: value).textFieldStyle(.roundedBorder).font(JH.Font.numeric(11)).multilineTextAlignment(.trailing).frame(width: 78).onSubmit { apply() }
        }
    }
    private func sync() {
        draft = clip; selectedKeyTime = nil; keySelectionPlayhead = nil
        start = String(format: "%.4f", clip.start.seconds); source = String(format: "%.4f", clip.sourceStart.seconds); duration = String(format: "%.4f", clip.duration.seconds)
        loadTransform(clip.transform); rate = clip.playbackRate?.multiplier ?? 1
        titleSize = String(clip.title?.fontSize ?? 76); titleX = String(clip.title?.x ?? 0.5); titleY = String(clip.title?.y ?? 0.8)
    }
    private func loadTransform(_ t: ClipTransform) { x = String(t.x); y = String(t.y); scale = String(t.scale); rotation = String(t.rotation); draft.transform = t }
    private func loadFrame(_ frame: TransformKeyframe) { loadTransform(frame.transform); draft.volume = frame.volume; interpolation = frame.interpolation; selectedKeyTime = frame.time; keySelectionPlayhead = model.playhead }
    private func readTransform() -> ClipTransform? {
        guard let px = Double(x), let py = Double(y), let sc = Double(scale), let rot = Double(rotation), [px, py, sc, rot].allSatisfy(\.isFinite) else { model.error = "배치에 올바른 숫자를 입력하세요."; return nil }
        var t = draft.transform; t.x = px; t.y = py; t.scale = sc; t.rotation = rot; return t
    }
    private func addKeyframe() {
        guard let t = readTransform() else { return }
        guard (selectedKeyTime != nil && keySelectionPlayhead == model.playhead) || (model.playhead >= clip.start.seconds && model.playhead <= clip.end.seconds) else { model.error = "플레이헤드를 선택한 클립 안으로 옮기세요."; return }
        let rounded = frames(model.playhead - clip.start.seconds)
        let local = keySelectionPlayhead == model.playhead ? (selectedKeyTime ?? max(.zero, min(clip.duration, rounded))) : max(.zero, min(clip.duration, rounded))
        var value = clip; var frames = value.keyframes ?? []
        frames.removeAll { $0.time == local }; frames.append(TransformKeyframe(time: local, transform: t, volume: draft.volume, interpolation: interpolation))
        value.keyframes = frames.sorted { $0.time < $1.time }; model.perform(.updateClip(trackID: track.id, clip: value))
    }
    private func apply() {
        guard let s = Double(start), let src = Double(source), let d = Double(duration), [s, src, d].allSatisfy(\.isFinite), let transform = readTransform() else { model.error = "올바른 숫자를 입력하세요."; return }
        guard [s, src, d].allSatisfy({ abs($0) < 86400 }) else { model.error = "24시간 미만 타임라인만 지원합니다."; return }
        // Unrelated style/volume edits must retain exact rational source/timeline times.
        let newStart = start == String(format: "%.4f", clip.start.seconds) ? clip.start : frames(s)
        let newSource = temporal ? (source == String(format: "%.4f", clip.sourceStart.seconds) ? clip.sourceStart : MediaTime(seconds: src)) : .zero
        let newDuration = duration == String(format: "%.4f", clip.duration.seconds) ? clip.duration : frames(d)
        var candidate = draft
        candidate.transform = transform
        if candidate.title != nil {
            guard let size = Double(titleSize), let tx = Double(titleX), let ty = Double(titleY), [size, tx, ty].allSatisfy(\.isFinite) else { model.error = "제목 크기와 위치를 확인하세요."; return }
            candidate.title?.fontSize = size; candidate.title?.x = tx; candidate.title?.y = ty
        }
        do {
            if newSource != clip.sourceStart || newDuration != clip.duration {
                candidate = try ClipTemporalEditor.trimmed(candidate, newStart: newStart, newSourceStart: newSource, newDuration: newDuration, frameRate: model.project.sequence.frameRate, temporalSource: temporal)
            } else { candidate.start = newStart }
            if model.perform(.updateClip(trackID: track.id, clip: candidate)) { draft = candidate }
        } catch { model.error = error.localizedDescription }
    }
}

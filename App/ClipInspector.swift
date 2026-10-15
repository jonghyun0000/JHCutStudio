import SwiftUI
import JHCutCore

struct ClipInspector: View {
    @ObservedObject var model: EditorModel
    let track: Track
    let clip: Clip
    @State private var draft = Clip()
    @State private var chromaColorPresented = false
    @State private var chromaColorDraft: ChromaColorDraft?
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
    @State private var rampPreset = SpeedRampPreset.slowDown
    @State private var rampPieces = 8
    @State private var rampMutes = true
    @State private var rampCustom = false
    @State private var rampFrom = 1.0
    @State private var rampTo = 0.3
    @State private var freezeSeconds = 2.0
    @State private var selectedKeyTime: MediaTime?
    @State private var keySelectionPlayhead: Double?
    @State private var interpolation = KeyframeInterpolation.linear
    @State private var newTransitionKind = TransitionKind.dissolve
    @State private var newTransitionDirection = TransitionDirection.fromRight
    @State private var newTransitionSeconds = 0.5
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
                if clip.connection != nil {
                    Text("원본과 연결됨 · 이동·트림·배속을 따라갑니다").font(JH.Font.micro)
                    Button("원본 연결 해제") { model.detachSelected() }.buttonStyle(.jhTool).disabled(track.isLocked)
                }
                Button("선택 구간 반복 듣기") { model.loopSelection() }.buttonStyle(.jhTool)
                DisclosureGroup("시간과 길이") { timing }
                if draft.title != nil { DisclosureGroup("자막 모양", isExpanded: $titleExpanded) { titleControls } }
                if draft.title != nil { DisclosureGroup("글자 애니메이션") { titleAnimationControls } }
                if let transition = model.transitionOf(clip, on: track) { DisclosureGroup("전환 효과") { transitionChangeControls(transition) } }
                if track.kind != .audio { DisclosureGroup("화면 배치") { transformControls } }
                if temporal { DisclosureGroup("재생 속도") { speedControls } }
                if temporal && clip.assetID != nil { DisclosureGroup("속도 램프·정지 화면·거꾸로") { speedToolControls } }
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
                if isVideoClip { DisclosureGroup("손떨림 보정") { stabilizationControls } }
                if clip.title == nil && track.kind != .audio {
                    DisclosureGroup("크로마키") { chromaControls }
                    DisclosureGroup("도형 마스크") { maskControls }
                    DisclosureGroup("색 보정과 크롭") { colorControls }
                }
                Button("입력한 숫자 적용") { apply() }.buttonStyle(.jhPrimary).frame(maxWidth: .infinity).disabled(track.isLocked)
                DisclosureGroup("키프레임") { keyframeControls }
                Menu("다른 트랙으로 이동") {
                    ForEach(model.project.sequence.tracks.filter { $0.id != track.id && ($0.kind == track.kind || (track.kind == .video && $0.kind == .overlay) || (track.kind == .overlay && $0.kind == .video)) }) { destination in
                        Button(destination.name) { model.moveSelectedClip(to: destination) }.disabled(destination.isLocked)
                    }
                }
                if track.kind == .video || TransitionEditing.context(of: track, in: model.project.sequence) != nil { DisclosureGroup("다음 장면과 전환") { transitionAddControls } }
                Button("이 클립으로 이동") { model.seek(clip.start.seconds) }.buttonStyle(.jhTool)
                Divider()
                Button("일반 삭제 · 빈 공간 유지", role: .destructive) { model.remove() }.buttonStyle(.borderless)
                Button("리플 삭제 · 연결 포함", role: .destructive) { model.remove(ripple: true) }.buttonStyle(.borderless)
                Text("연결 클립과 ‘리플 편집에 함께 이동’ 트랙도 반영됩니다. 잠긴 연결 트랙이 있으면 편집을 중단합니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            }.padding(15)
        }.onAppear { sync() }.onChange(of: clip) {
            if chromaColorDraft != nil { finishChromaColor(apply: false) }
            sync()
        }.onDisappear { if chromaColorDraft != nil { finishChromaColor(apply: false) } }
        .onChange(of: model.busyDocument) { if model.busyDocument && chromaColorDraft != nil { finishChromaColor(apply: false) } }
        .onChange(of: track.isLocked) { if track.isLocked && chromaColorDraft != nil { finishChromaColor(apply: false) } }
        .onChange(of: model.asyncDocumentRevision) { if chromaColorDraft != nil { finishChromaColor(apply: false) } }
        .onChange(of: model.selectedClipID) { if chromaColorDraft != nil { finishChromaColor(apply: false) } }
    }
    private func optionalVisual(_ key: WritableKeyPath<VisualAdjustments, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { draft.visual?[keyPath: key] ?? fallback }, set: { value in if draft.visual == nil { draft.visual = VisualAdjustments() }; draft.visual?[keyPath: key] = value })
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
            Stepper("목표 \(draft.title?.style?.maxLines ?? 0)줄 · 0은 제한 없음", value: style(\.maxLines), in: 0...20).font(JH.Font.caption)
                .onChange(of: draft.title?.style?.maxLines) { commitNow() }
            Toggle("글자 그림자", isOn: style(\.shadow)).font(JH.Font.label)
                .onChange(of: draft.title?.style?.shadow) { commitNow() }
            if let title = draft.title, let info = try? TitlePreviewRenderer.layout(title: title, canvasWidth: Double(model.project.sequence.width)), info.exceedsLineLimit {
                Text("실제 \(info.totalLines)줄 · 목표 줄 수를 초과해도 전체 문구를 표시합니다. 글자 크기나 문구 분할을 검토하세요.").font(JH.Font.caption).foregroundStyle(JH.Palette.warning)
            }
            if let report = try? CaptionReadability.assess(draft, width: model.project.sequence.width, height: model.project.sequence.height) {
                ForEach(report.warnings, id: \.self) { Text($0).font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
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
            Picker("블렌드 모드", selection: Binding(get: { draft.blendMode ?? .normal }, set: { mode in
                draft.blendMode = mode == .normal ? nil : mode
                commitNow()
            })) {
                ForEach(ClipBlendMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.disabled(track.isLocked || model.busyDocument)
            Text("아래 트랙의 색과 섞습니다. 불투명도를 낮추면 효과가 약해집니다.").font(JH.Font.micro).foregroundStyle(.secondary)
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
    @ViewBuilder private var speedToolControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("속도 램프").font(JH.Font.sectionTitle)
            Text("클립을 같은 길이의 조각으로 나누고 조각마다 속도를 달리해 서서히 느려지거나 빨라지게 합니다. 결과는 평범한 클립들이라 자르기·되돌리기·저장이 그대로 동작합니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            Picker("모양", selection: $rampPreset) { ForEach(SpeedRampPreset.allCases, id: \.self) { Text($0.label).tag($0) } }.disabled(rampCustom)
            Toggle("시작·끝 속도 직접 정하기", isOn: $rampCustom)
            if rampCustom {
                Picker("시작 속도", selection: $rampFrom) { ForEach([0.25, 0.3, 0.5, 1, 1.5, 2, 3, 4], id: \.self) { Text(String(format: "%g배", $0)).tag($0) } }
                Picker("끝 속도", selection: $rampTo) { ForEach([0.25, 0.3, 0.5, 1, 1.5, 2, 3, 4], id: \.self) { Text(String(format: "%g배", $0)).tag($0) } }
            }
            Stepper("조각 수 \(rampPieces)개", value: $rampPieces, in: SpeedRampPlan.allowedPieces)
            Text("조각이 많을수록 변화가 매끄럽습니다. 이 클립에는 \(model.suggestedRampPieces)개를 권합니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            Toggle("램프 구간 소리 끄기", isOn: $rampMutes)
            Button("속도 램프 적용") {
                if rampCustom { model.applySpeedRamp(from: rampFrom, to: rampTo, pieces: rampPieces, mutesAudio: rampMutes) }
                else { model.applySpeedRamp(preset: rampPreset, pieces: rampPieces, mutesAudio: rampMutes) }
            }.buttonStyle(.jhTool).disabled(track.isLocked || model.busyDocument)
            if clip.assetID.flatMap({ id in model.project.assets.first { $0.id == id } })?.kind == .video {
                Divider()
                Text("정지 화면").font(JH.Font.sectionTitle)
                Text("선택한 메인 영상의 현재 보정·움직임을 반영한 화면을 멈춥니다. 자막·오버레이는 별도로 재생되며, 뒤 장면은 그만큼 밀립니다.").font(JH.Font.caption).foregroundStyle(.secondary)
                Stepper(String(format: "멈춰 있는 시간 %.1f초", freezeSeconds), value: $freezeSeconds, in: FreezeFrame.secondsRange, step: 0.5)
                Button("재생 위치에 정지 화면 넣기") { model.makeFreezeFrame(seconds: freezeSeconds) }.buttonStyle(.jhTool).disabled(model.freezeFrameProblem != nil || model.busyDocument)
                if let problem = model.freezeFrameProblem { Text(problem).font(JH.Font.micro).foregroundStyle(.secondary) }
                Divider()
                Text("거꾸로 재생").font(JH.Font.sectionTitle)
                Text("이 클립의 구간을 거꾸로 만든 사본 파일을 만들어 연결합니다(소리도 거꾸로). 원본 영상은 바뀌지 않고, 손떨림 분석 결과는 지워집니다.").font(JH.Font.caption).foregroundStyle(.secondary)
                if model.productivityBusy {
                    ProgressView(); Text(model.productivityStatus).font(JH.Font.micro)
                    Button("취소") { model.cancelProductivity() }.buttonStyle(.jhTool)
                } else {
                    Button("거꾸로 사본 만들기") { model.reverseSelectedClip() }.buttonStyle(.jhTool).disabled(model.reverseProblem != nil || model.busyDocument)
                    if let problem = model.reverseProblem { Text(problem).font(JH.Font.micro).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private var colorControls: some View {
        Group {
            Divider()
            Text("색 보정과 크롭").font(JH.Font.sectionTitle)
            slider("노출", visual(\.exposure), -4...4)
            slider("대비", visual(\.contrast), 0...2)
            slider("채도", visual(\.saturation), 0...2)
            slider("색온도", optionalVisual(\.temperature, fallback: 6500), 2000...12000)
            slider("색조", optionalVisual(\.tint, fallback: 0), -100...100)
            slider("어두운 영역", optionalVisual(\.shadows, fallback: 0), -0.2...0.2)
            slider("밝은 영역", optionalVisual(\.highlights, fallback: 0), -0.2...0.2)

            Button(draft.visual?.lut?.name ?? "3D LUT 가져오기…") { model.importLUT() }
            if draft.visual?.lut != nil { Button("LUT 해제") { draft.visual?.lut = nil; commitNow() } }
            slider("왼쪽 크롭", visual(\.cropLeft), 0...0.45)
            slider("오른쪽 크롭", visual(\.cropRight), 0...0.45)
            slider("위쪽 크롭", visual(\.cropTop), 0...0.45)
            slider("아래쪽 크롭", visual(\.cropBottom), 0...0.45)
            Button("색·크롭 초기화") {
                let shape = draft.visual?.shapeMask, legacy = draft.visual?.ellipseMask
                let key = draft.visual?.chromaKey, green = draft.visual?.greenScreen
                if shape != nil || legacy == true || key != nil || green != nil {
                    var reset = VisualAdjustments(); reset.shapeMask = shape; reset.ellipseMask = legacy
                    reset.chromaKey = key; reset.greenScreen = green; draft.visual = reset
                } else { draft.visual = nil }
                commitNow()
            }.font(JH.Font.caption)
        }
    }
    private enum ChromaChoice: String, Hashable { case none, legacy, selected }
    private var chromaChoice: ChromaChoice {
        if draft.visual?.chromaKey != nil { return .selected }
        return draft.visual?.greenScreen != nil ? .legacy : .none
    }
    private var chromaControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("배경 색 제거", selection: Binding(get: { chromaChoice }, set: { choice in
                guard !track.isLocked, !model.busyDocument else { return }
                if draft.visual == nil { draft.visual = VisualAdjustments() }
                switch choice {
                case .none: draft.visual?.chromaKey = nil; draft.visual?.greenScreen = nil
                case .legacy: draft.visual?.chromaKey = nil; draft.visual?.greenScreen = draft.visual?.greenScreen ?? 0.5
                case .selected: draft.visual?.greenScreen = nil; draft.visual?.chromaKey = draft.visual?.chromaKey ?? ChromaKey()
                }
                commitNow()
            })) {
                Text("없음").tag(ChromaChoice.none)
                Text("기존 그린스크린").tag(ChromaChoice.legacy)
                Text("선택 색").tag(ChromaChoice.selected)
            }.accessibilityIdentifier("chroma-mode")
            if chromaChoice == .legacy {
                slider("그린스크린 제거", optionalVisual(\.greenScreen, fallback: 0), 0...1)
                Text("이전 문서의 녹색 제거 방식과 강도를 유지합니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            }
            if let key = draft.visual?.chromaKey {
                Button("키 색 편집…") {
                    guard !track.isLocked, !model.busyDocument, !model.isBuilding else { return }
                    guard let transaction = ChromaColorDraft.begin(in: model, trackID: track.id, clipID: clip.id) else { return }
                    chromaColorDraft = transaction; chromaColorPresented = true
                }.buttonStyle(.jhTool).accessibilityIdentifier("chroma-color-edit")
                .popover(isPresented: Binding(get: { chromaColorPresented }, set: { value in
                    if !value { finishChromaColor(apply: false) }
                })) {
                    if let transaction = chromaColorDraft {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("제거할 색 · sRGB").font(.headline)
                            ColorPicker("키 색", selection: Binding(get: {
                                let current = chromaColorDraft?.key ?? transaction.key
                                return Color(.sRGB, red: current.keyRed, green: current.keyGreen, blue: current.keyBlue)
                            }, set: { color in
                                guard var current = chromaColorDraft, current.id == transaction.id else { return }
                                do {
                                    if try current.select(NSColor(color), in: model) { chromaColorDraft = current }
                                    else { finishChromaColor(apply: false) }
                                } catch { model.error = error.localizedDescription }
                            }), supportsOpacity: false)
                            chromaDraftChannel("빨강", \.keyRed, transaction: transaction)
                            chromaDraftChannel("초록", \.keyGreen, transaction: transaction)
                            chromaDraftChannel("파랑", \.keyBlue, transaction: transaction)
                            Text("색 선택기 또는 RGB 슬라이더로 고른 뒤 적용하세요. 적용 전에는 영상이 바뀌지 않습니다.").font(.caption).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("취소") { finishChromaColor(apply: false) }.keyboardShortcut(.cancelAction)
                                Spacer()
                                Button("적용") { finishChromaColor(apply: true) }.keyboardShortcut(.defaultAction)
                            }
                        }.padding().frame(width: 310)
                    }
                }
                slider("색 유사도", chromaValue(\.similarity), 0...1)
                slider("경계 부드러움", chromaValue(\.softness), 0...max(0, 1 - key.similarity))
                if key.isChromatic {
                    slider("색 번짐 제거", chromaValue(\.spillReduction), 0...1)
                } else {
                    Text("검정·흰색·회색 키는 밝기로 구별하며 색 번짐 제거를 사용하지 않습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                }
                Text("유사도가 높으면 전경의 비슷한 색도 사라질 수 있습니다. 번짐 제거를 0으로 하면 원래 색을 유지합니다. 마스크는 키를 적용한 뒤 계산합니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            }
        }.disabled(track.isLocked || model.busyDocument)
    }
    private func chromaDraftChannel(_ name: String, _ path: WritableKeyPath<ChromaKey, Double>, transaction: ChromaColorDraft) -> some View {
        let value = (chromaColorDraft?.key ?? transaction.key)[keyPath: path]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text("\(Int((value * 255).rounded())) / 255").monospacedDigit()
            }.font(.caption)
            Slider(value: Binding(get: {
                (chromaColorDraft?.key ?? transaction.key)[keyPath: path]
            }, set: { value in
                guard var current = chromaColorDraft, current.id == transaction.id else { return }
                var key = current.key
                key[keyPath: path] = value
                do {
                    let color = NSColor(srgbRed: key.keyRed, green: key.keyGreen, blue: key.keyBlue, alpha: 1)
                    if try current.select(color, in: model) { chromaColorDraft = current }
                    else { finishChromaColor(apply: false) }
                } catch { model.error = error.localizedDescription }
            }), in: 0...1)
            .accessibilityLabel("키 색 \(name) · sRGB")
            .accessibilityValue("\(Int((value * 255).rounded())) / 255")
        }
    }
    private func chromaValue(_ path: WritableKeyPath<ChromaKey, Double>) -> Binding<Double> {
        Binding(get: { (draft.visual?.chromaKey ?? ChromaKey())[keyPath: path] }, set: { value in
            guard !track.isLocked, !model.busyDocument else { return }
            var key = draft.visual?.chromaKey ?? ChromaKey()
            key[keyPath: path] = value
            if path == \ChromaKey.similarity { key.softness = min(key.softness, max(0, 1 - value)) }
            if path == \ChromaKey.softness { key.softness = min(value, max(0, 1 - key.similarity)) }
            if draft.visual == nil { draft.visual = VisualAdjustments() }
            draft.visual?.chromaKey = key; draft.visual?.greenScreen = nil
        })
    }
    private func finishChromaColor(apply: Bool) {
        guard var transaction = chromaColorDraft else { chromaColorPresented = false; return }
        // Retire the view transaction before closing NSColorPanel; late setter closures carry its old id.
        chromaColorDraft = nil; chromaColorPresented = false
        NSColorPanel.shared.close()
        if apply { _ = transaction.apply(to: model) } else { transaction.cancel() }
    }
    private enum MaskChoice: String, Hashable { case none, legacy, ellipse, rectangle }
    private var maskChoice: MaskChoice {
        if let shape = draft.visual?.shapeMask { return shape.kind == .ellipse ? .ellipse : .rectangle }
        return draft.visual?.ellipseMask == true ? .legacy : .none
    }
    private var maskControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("모양", selection: Binding(get: { maskChoice }, set: { choice in
                if draft.visual == nil { draft.visual = VisualAdjustments() }
                switch choice {
                case .none: draft.visual?.shapeMask = nil; draft.visual?.ellipseMask = nil
                case .legacy: draft.visual?.shapeMask = nil; draft.visual?.ellipseMask = true
                case .ellipse, .rectangle:
                    var shape = draft.visual?.shapeMask ?? ShapeMask()
                    shape.kind = choice == .ellipse ? .ellipse : .rectangle
                    draft.visual?.shapeMask = shape; draft.visual?.ellipseMask = nil
                }
                commitNow()
            })) {
                Text("없음").tag(MaskChoice.none)
                if draft.visual?.ellipseMask == true { Text("기존 타원 유지").tag(MaskChoice.legacy) }
                Text("타원").tag(MaskChoice.ellipse)
                Text("사각형").tag(MaskChoice.rectangle)
            }.disabled(track.isLocked || model.busyDocument)
            if draft.visual?.ellipseMask == true {
                Text("저장된 타원 모양을 그대로 유지합니다. 타원 또는 사각형을 고르면 위치와 크기를 조절할 수 있습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            }
            if draft.visual?.shapeMask != nil {
                slider("가로 중심", maskPercent(\.centerX), -100...200, suffix: "%")
                slider("세로 중심", maskPercent(\.centerY), -100...200, suffix: "%")
                slider("가로 크기", maskPercent(\.width), 1...200, suffix: "%")
                slider("세로 크기", maskPercent(\.height), 1...200, suffix: "%")
                slider("회전", maskValue(\.rotation), -180...180, suffix: "°")
                slider("테두리 부드러움", maskPercent(\.feather), 0...50, suffix: "%")
                Text("크롭한 영상 기준입니다. 중심 0%는 왼쪽·아래, 100%는 오른쪽·위입니다. 테두리는 도형 반지름의 지정 비율만큼 안쪽으로 부드러워집니다. 클립의 이동·확대·회전과 함께 움직입니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                Button("마스크 설정 초기화") {
                    draft.visual?.shapeMask = ShapeMask(kind: draft.visual?.shapeMask?.kind ?? .ellipse)
                    commitNow()
                }.buttonStyle(.jhTool).disabled(track.isLocked || model.busyDocument)
            }
        }.disabled(track.isLocked || model.busyDocument)
    }
    private func maskValue(_ key: WritableKeyPath<ShapeMask, Double>) -> Binding<Double> {
        Binding(get: { (draft.visual?.shapeMask ?? ShapeMask())[keyPath: key] }, set: { value in
            if draft.visual == nil { draft.visual = VisualAdjustments() }
            var shape = draft.visual?.shapeMask ?? ShapeMask(); shape[keyPath: key] = value
            draft.visual?.shapeMask = shape; draft.visual?.ellipseMask = nil
        })
    }
    private func maskPercent(_ key: WritableKeyPath<ShapeMask, Double>) -> Binding<Double> {
        let value = maskValue(key)
        return Binding(get: { value.wrappedValue * 100 }, set: { value.wrappedValue = $0 / 100 })
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
    // MARK: Transitions and title animation
    @ViewBuilder private var transitionAddControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("이 클립과 다음 클립을 겹쳐 전환합니다. 다음 장면이 길이만큼 앞당겨져 전체 길이가 그만큼 짧아지고, 소리는 함께 이어집니다. 서로 붙어 있는 두 클립만 가능합니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            Picker("효과", selection: $newTransitionKind) { ForEach(TransitionKind.allCases, id: \.self) { Text($0.label).tag($0) } }
            if newTransitionKind.usesDirection {
                Picker("방향", selection: $newTransitionDirection) { ForEach(TransitionDirection.allCases, id: \.self) { Text($0.label).tag($0) } }
            }
            HStack { Text("길이"); Spacer(); Text(String(format: "%.1f초", newTransitionSeconds)).monospacedDigit() }.font(JH.Font.caption)
            Slider(value: $newTransitionSeconds, in: 0.2...2.0, step: 0.1).controlSize(.small)
            Button("전환 추가") { model.addTransition(kind: newTransitionKind, direction: newTransitionDirection, seconds: newTransitionSeconds) }
                .buttonStyle(.jhTool).disabled(track.isLocked || model.busyDocument)
        }
    }
    @ViewBuilder private func transitionChangeControls(_ transition: ClipTransition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("이 장면과 앞 장면 사이의 전환입니다. 길이를 바꾸면 뒤 장면과 연결 자막도 함께 이동합니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            Picker("효과", selection: Binding(get: { transition.kind }, set: { model.changeTransition(kind: $0, direction: transition.direction) })) {
                ForEach(TransitionKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }.disabled(track.isLocked)
            if transition.kind.usesDirection {
                Picker("방향", selection: Binding(get: { transition.direction }, set: { model.changeTransition(kind: transition.kind, direction: $0) })) {
                    ForEach(TransitionDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(track.isLocked)
            }
            Stepper(String(format: "전환 길이 %.2f초", transition.duration.seconds), value: Binding(get: { transition.duration.seconds }, set: { model.resizeTransition(seconds: $0) }), in: 0.05...3, step: 0.05)
                .disabled(track.isLocked || model.busyDocument)
            Button("전환 제거 · 메인 트랙으로 복귀") { model.removeTransition() }.buttonStyle(.jhTool).disabled(track.isLocked || model.busyDocument)
        }
    }
    @ViewBuilder private var titleAnimationControls: some View {
        let current = clip.titleAnimation ?? TitleAnimation()
        VStack(alignment: .leading, spacing: 8) {
            Text("자막이 나타나고 사라질 때의 움직임입니다. 원본 영상과 자막 문구는 바뀌지 않습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            Picker("등장", selection: Binding(get: { current.inKind }, set: { var value = current; value.inKind = $0; model.setTitleAnimation(value) })) {
                Text("없음").tag(TitleAnimationKind?.none); ForEach(TitleAnimationKind.allCases, id: \.self) { Text($0.label).tag(TitleAnimationKind?.some($0)) }
            }.disabled(track.isLocked)
            Picker("퇴장", selection: Binding(get: { current.outKind }, set: { var value = current; value.outKind = $0; model.setTitleAnimation(value) })) {
                Text("없음").tag(TitleAnimationKind?.none); ForEach(TitleAnimationKind.allCases, id: \.self) { Text($0.label).tag(TitleAnimationKind?.some($0)) }
            }.disabled(track.isLocked)
            if current.inKind != nil {
                slider("등장 길이", animationSeconds(\.inSeconds), 0.001...min(3, max(0.001, clip.duration.seconds)), suffix: "초")
            }
            if current.outKind != nil {
                slider("퇴장 길이", animationSeconds(\.outSeconds), 0.001...min(3, max(0.001, clip.duration.seconds)), suffix: "초")
            }
            if !current.isEmpty {
                Button("같은 효과를 모든 자막에 적용") { model.applyTitleAnimationToAllCaptions(current) }.buttonStyle(.jhTool).disabled(model.busyDocument)
                Button("애니메이션 제거") { model.setTitleAnimation(nil) }.buttonStyle(.jhTool).disabled(track.isLocked)
            }
        }
    }
    private var isVideoClip: Bool { clip.title == nil && clip.assetID.flatMap { id in model.project.assets.first { $0.id == id } }?.kind == .video }
    private func animationSeconds(_ path: WritableKeyPath<TitleAnimation, Double>) -> Binding<Double> {
        Binding(get: {
            let value = draft.titleAnimation ?? clip.titleAnimation ?? TitleAnimation()
            return value[keyPath: path] / (value.timeScale ?? 1)
        }, set: { seconds in
            var value = EditorModel.restartedTitleAnimation(draft.titleAnimation ?? clip.titleAnimation ?? TitleAnimation(), duration: clip.duration)
            value[keyPath: path] = seconds; draft.titleAnimation = value
        })
    }
    @ViewBuilder private var stabilizationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("영상 속 손떨림을 분석해 줄입니다. 분석 결과는 프로젝트에 저장되고, 원본 영상은 바뀌지 않습니다. 크게 움직이는 피사체가 있어도 배경 기준으로 잡습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
            Text("신뢰도가 낮으면 보정을 제한하거나 꺼둡니다. 롤링셔터의 휘어짐은 교정하지 않습니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            if model.productivityBusy {
                ProgressView(); Text(model.productivityStatus).font(JH.Font.micro)
                Button("분석 취소") { model.cancelProductivity() }.buttonStyle(.jhTool)
            } else {
                Button(clip.stabilization == nil ? "손떨림 분석" : "다시 분석") { model.analyzeStabilization() }.buttonStyle(.jhTool)
                    .disabled(track.isLocked || model.busyDocument || clip.sourceDuration.seconds > StabilizationAnalyzer.maximumSeconds)
                if clip.sourceDuration.seconds > StabilizationAnalyzer.maximumSeconds { Text("이 클립은 \(Int(StabilizationAnalyzer.maximumSeconds / 60))분보다 길어 나눈 뒤 분석해야 합니다.").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
            }
            if let data = clip.stabilization {
                let covered = data.covers(clip.sourceStart, duration: clip.sourceDuration)
                Toggle("보정 사용", isOn: Binding(get: { draft.stabilization?.enabled ?? data.enabled }, set: { value in draft.stabilization?.enabled = value; commitNow() })).disabled(track.isLocked || !covered)
                slider("강도", Binding(get: { draft.stabilization?.strength ?? data.strength }, set: { draft.stabilization?.strength = $0 }), StabilizationData.strengthRange)
                slider("부드러움", Binding(get: { draft.stabilization?.smoothing ?? data.smoothing }, set: { draft.stabilization?.smoothing = $0 }), StabilizationData.smoothingRange, suffix: "초")
                if covered { Text(EditorModel.describeStabilization(data)).font(JH.Font.micro).foregroundStyle(.secondary) }
                else { Text("클립을 늘려 분석한 범위를 벗어났습니다. 이 클립은 보정 없이 나옵니다. ‘다시 분석’을 누르세요.").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                Text("강도를 낮추면 흔들림을 덜 없애고, 부드러움을 높이면 화면이 더 차분해지지만 천천히 움직이는 장면은 조금 늦게 따라갑니다. 흔들림을 없애느라 화면이 조금 확대됩니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                Button("보정 제거") { model.removeStabilization() }.buttonStyle(.jhTool).disabled(track.isLocked || model.busyDocument)
            }
        }
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
                .accessibilityLabel(name)
                .accessibilityValue(String(format: "%.2f", binding.wrappedValue) + suffix)
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

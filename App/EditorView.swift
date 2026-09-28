import SwiftUI
import AVKit
import JHCutCore
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var tab = "미디어"
    @State private var clipPicker = false
    @State private var mediaQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                HSplitView {
                    if model.libraryVisible { library.frame(minWidth: 224, idealWidth: 264, maxWidth: 380) }
                    preview.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    if model.inspectorVisible { inspector.frame(minWidth: 248, idealWidth: 282, maxWidth: 372) }
                }.frame(minHeight: 350)
                timeline.frame(minHeight: 250, idealHeight: 300, maxHeight: 440)
            }
            footer
        }
        .background(JH.Palette.canvas)
        .tint(JH.Palette.accent)
        .navigationTitle(model.project.name)
        .navigationSubtitle(model.dirty ? "저장하지 않은 변경사항" : "저장됨")
        .toolbar { toolbarItems }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("확인", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                model.importFiles(urls)
            }
            return !providers.isEmpty
        }
    }

    // MARK: Window chrome
    //
    // The document name lives in the window title and the actions live in the real NSToolbar, so the
    // app has one bar like every other macOS app instead of a custom strip under the title bar.

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .jhIconLabel("실행취소", hint: "마지막 편집을 되돌립니다 ⌘Z")
                .disabled(!model.history.canUndo || model.isExporting)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .jhIconLabel("재실행", hint: "되돌린 편집을 다시 적용합니다 ⇧⌘Z")
                .disabled(!model.history.canRedo || model.isExporting)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.libraryVisible.toggle() } label: { Image(systemName: "sidebar.leading") }
                .jhIconLabel(model.libraryVisible ? "라이브러리 접기" : "라이브러리 펼치기")
            Button { model.inspectorVisible.toggle() } label: { Image(systemName: "sidebar.trailing") }
                .jhIconLabel(model.inspectorVisible ? "속성 접기" : "속성 펼치기")
            Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }
                .jhIconLabel("프로젝트 저장", hint: "⌘S")
            // Toolbars collapse a Label to its icon by default; the one destination action keeps its text.
            Button { model.exportVideo() } label: { Label("영상 출력", systemImage: "square.and.arrow.up") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.jhPrimary)
                .accessibilityHint(Text("선택한 파일 형식으로 현재 타임라인을 출력합니다"))
                .disabled(model.plan == nil || model.isBuilding || model.busyDocument)
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            segmentedTabs
            Group {
                if tab == "미디어" { mediaTab }
                else if tab == "자막" { CaptionsPanel(model: model) }
                else { LibraryBrowser(model: model, audioOnly: tab == "사운드").id(tab) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(JH.Palette.canvas)
        .jhSeam(.trailing)
    }

    private var segmentedTabs: some View {
        Picker("라이브러리 구분", selection: $tab) {
            ForEach(["미디어", "자막", "사운드", "소스"], id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(JH.Space.m)
    }

    @ViewBuilder private var mediaTab: some View {
        VStack(alignment: .leading, spacing: JH.Space.s) {
            HStack {
                Text("프로젝트 미디어").font(JH.Font.sectionTitle)
                Spacer()
                Text("\(model.project.assets.count)").font(JH.Font.numeric(10)).foregroundStyle(.secondary)
                    .accessibilityLabel(Text("미디어 \(model.project.assets.count)개"))
            }
            Button { model.chooseMedia() } label: {
                Label(model.isImporting ? "미디어 분석 중…" : "파일 가져오기", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.jhTool)
            .disabled(model.isImporting || model.isExporting)

            TextField("이름·코덱 검색", text: $mediaQuery)
                .textFieldStyle(.roundedBorder).font(JH.Font.label)
                .accessibilityLabel(Text("미디어 검색"))
        }
        .padding(.horizontal, JH.Space.m)

        if model.project.assets.isEmpty { emptyMediaState } else { assetList }

        if let asset = model.project.assets.first(where: { $0.id == model.selectedAssetID }) {
            assetActions(asset)
        }
    }

    private var emptyMediaState: some View {
        VStack(spacing: JH.Space.m) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 30, weight: .ultraLight)).foregroundStyle(JH.Palette.accent)
                .accessibilityHidden(true)
            Text("촬영한 영상을 여기로 끌어오세요").font(JH.Font.label)
            Toggle("가져온 영상 자동 자막", isOn: $model.autoCaptionImportedVideos).font(JH.Font.caption).disabled(model.busyDocument)
            Text("SDR H.264 · HEVC · ProRes · 사진 · 오디오\n모든 편집은 이 Mac에서 처리됩니다.")
                .font(JH.Font.micro).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(JH.Space.l)
        .accessibilityElement(children: .combine)
    }

    private var assetList: some View {
        ScrollView {
            LazyVStack(spacing: JH.Space.xs) {
                ForEach(visibleAssets) { asset in
                    MediaRow(asset: asset, url: asset.resolvedURL(relativeTo: model.mediaBaseURL), selected: model.selectedAssetID == asset.id)
                        .onTapGesture(count: 2) { if !model.isExporting { model.addAsset(asset) } }
                        .onTapGesture { model.selectedAssetID = asset.id }
                }
            }
            .padding(.horizontal, JH.Space.m)
            .padding(.vertical, JH.Space.s)
        }
    }

    private var visibleAssets: [MediaAsset] {
        model.project.assets.filter {
            mediaQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(mediaQuery) || $0.codec.localizedCaseInsensitiveContains(mediaQuery)
        }
    }

    private func assetActions(_ asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: JH.Space.s) {
            if let provenance = asset.provenance {
                Text("\(provenance.author) · \(provenance.license)").font(JH.Font.micro).foregroundStyle(.tertiary)
            }
            Text(asset.issue ?? "\(asset.codec) · \(asset.colorInfo)")
                .font(JH.Font.caption).foregroundStyle(asset.supported ? Color.secondary : JH.Palette.warning).lineLimit(4)
            Button("타임라인 끝에 추가") { model.addAsset(asset) }
                .frame(maxWidth: .infinity).disabled(!asset.supported || model.isExporting)
            if asset.kind != .audio {
                HStack(spacing: JH.Space.s) {
                    Button("여기에 삽입") { model.editAssetAtPlayhead(asset, overwrite: false) }
                        .accessibilityHint(Text("플레이헤드 위치에 삽입하고 뒤 클립을 밉니다"))
                    Button("덮어쓰기") { model.editAssetAtPlayhead(asset, overwrite: true) }
                        .accessibilityHint(Text("플레이헤드 위치의 기존 내용을 덮어씁니다"))
                }
                .font(JH.Font.caption).disabled(!asset.supported || model.isExporting)
                Button("오버레이로 추가") { model.addAsset(asset, overlay: true) }
                    .frame(maxWidth: .infinity).disabled(!asset.supported || model.isExporting)
            }
        }
        .buttonStyle(.jhTool)
        .padding(JH.Space.m)
        .background(alignment: .top) { Rectangle().fill(JH.Palette.hairline).frame(height: JH.Stroke.hairline) }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: JH.Space.s) {
                Text(model.proxyEnabled ? "프록시 미리보기" : "미리보기").font(JH.Font.sectionTitle).foregroundStyle(.secondary)
                Button { model.safeAreaVisible.toggle() } label: {
                    Image(systemName: model.safeAreaVisible ? "viewfinder.circle.fill" : "viewfinder.circle")
                }
                .buttonStyle(.borderless)
                .jhIconLabel(model.safeAreaVisible ? "안전 영역 숨기기" : "안전 영역 보기", hint: "자막 안전 영역 80%를 표시합니다. 출력에는 포함되지 않습니다")
                Spacer()
                Text("\(model.project.sequence.width) × \(model.project.sequence.height) · \(model.frameRate.label) fps · Rec.709")
                    .font(JH.Font.numeric(10)).foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("시퀀스 \(model.project.sequence.width) × \(model.project.sequence.height), 초당 \(model.frameRate.label)프레임, Rec.709"))
            }
            .padding(.horizontal, JH.Space.l)
            .padding(.vertical, JH.Space.m)

            stage

            transport
        }
    }

    /// The video image and everything layered over it.
    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: JH.Radius.panel, style: .continuous).fill(.black)
            if model.plan != nil {
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: JH.Radius.panel, style: .continuous))
                    .accessibilityLabel(Text("미리보기 화면"))
            } else if !model.isBuilding {
                VStack(spacing: JH.Space.m) {
                    Image(systemName: "play.rectangle").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(model.project.sequence.duration > .zero ? "미디어를 확인하세요" : "나만의 첫 장면을 시작하세요")
                        .font(.system(size: 15, weight: .medium))
                    Text("미디어 가져오기 → 타임라인에 추가").font(JH.Font.label).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if model.safeAreaVisible {
                SafeAreaOverlay(width: model.project.sequence.width, height: model.project.sequence.height)
                    .accessibilityHidden(true)
            }
            if model.isBuilding {
                VStack(spacing: JH.Space.m) {
                    ProgressView()
                    Text("타임라인 합성 중…").font(JH.Font.label)
                }
                .padding(JH.Space.xl)
                .jhSurface(.floating, radius: JH.Radius.control)
                .accessibilityLabel(Text("타임라인 합성 중"))
            }
        }
        .padding(.horizontal, JH.Space.l)
        .overlay(alignment: .bottom) { proxyBadge.padding(.bottom, JH.Space.m) }
    }

    @ViewBuilder private var proxyBadge: some View {
        if model.proxyEnabled && model.plan != nil {
            Text("프록시").font(JH.Font.micro.weight(.semibold))
                .padding(.horizontal, JH.Space.s).padding(.vertical, JH.Space.xs)
                .jhSurface(.floating, in: Capsule())
                .accessibilityLabel(Text("프록시 미리보기 사용 중"))
        }
    }

    private var transport: some View { PlaybackTransport(model: model) }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selectedClipIDs.count > 1 ? "속성 · \(model.selectedClipIDs.count)개 선택" : "속성")
                    .font(JH.Font.sectionTitle)
                Spacer()
                Button("프로젝트") { model.selectedClipID = nil; model.selectedClipIDs = [] }
                    .font(JH.Font.caption).buttonStyle(.borderless)
                    .accessibilityHint(Text("클립 선택을 해제하고 프로젝트 속성을 봅니다"))
            }
            .padding(.horizontal, JH.Space.l)
            .padding(.vertical, JH.Space.m)
            .background(alignment: .bottom) { Rectangle().fill(JH.Palette.hairline).frame(height: JH.Stroke.hairline) }

            if let (track, clip) = model.selected {
                ClipInspector(model: model, track: track, clip: clip).id(clip.id)
                    .disabled(model.isExporting || track.isLocked)
            } else {
                ProjectTools(model: model)
            }
        }
        .background(JH.Palette.canvas)
        .jhSeam(.leading)
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 0) {
            timelineToolbar
            HStack(spacing: 0) {
                trackHeaders
                TimelineSurface(model: model)
            }
        }
        .background(JH.Palette.canvas)
        .jhSeam(.top)
    }

    private var timelineToolbar: some View {
        HStack(spacing: JH.Space.s) {
            Text("타임라인").font(JH.Font.sectionTitle)

            HStack(spacing: JH.Space.xs) {
                Button { model.split() } label: { Image(systemName: "scissors") }
                    .jhIconLabel("플레이헤드에서 분할", hint: "⌘B").disabled(model.selected == nil)
                Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                    .jhIconLabel("클립 복제", hint: "⌘D").disabled(model.selected == nil)
                Button { model.remove() } label: { Image(systemName: "trash") }
                    .jhIconLabel("삭제", hint: "빈 공간을 유지한 채 삭제합니다").disabled(model.selected == nil)
                Button { model.reorder(-1) } label: { Image(systemName: "arrow.left.to.line") }
                    .jhIconLabel("앞으로 이동").disabled(model.selected == nil)
                Button { model.reorder(1) } label: { Image(systemName: "arrow.right.to.line") }
                    .jhIconLabel("뒤로 이동").disabled(model.selected == nil)
                Button { model.addTitle() } label: { Image(systemName: "textformat") }
                    .jhIconLabel("제목 추가")
                Button { clipPicker.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                    .jhIconLabel("전체 클립 목록", hint: "겹친 클립을 포함해 모든 클립에서 선택합니다")
                    .popover(isPresented: $clipPicker) { clipPickerList }
            }
            .buttonStyle(.jhTool)

            Spacer()

            Toggle(isOn: $model.snappingEnabled) { Text("스냅").font(JH.Font.caption) }
                .toggleStyle(.switch).controlSize(.mini)
                .accessibilityHint(Text("클립 경계와 플레이헤드에 맞춥니다"))

            HStack(spacing: JH.Space.s) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $model.zoom, in: 12...180)
                    .frame(width: 104)
                    .accessibilityLabel(Text("타임라인 확대"))
                    .accessibilityValue(Text("초당 \(Int(model.zoom)) 포인트"))
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .font(JH.Font.label)
        .padding(.horizontal, JH.Space.l)
        .padding(.vertical, JH.Space.s)
        .disabled(model.isExporting)
        .background(alignment: .bottom) { Rectangle().fill(JH.Palette.hairline).frame(height: JH.Stroke.hairline) }
    }

    private var clipPickerList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: JH.Space.xs) {
                ForEach(model.project.sequence.tracks) { track in
                    HStack(spacing: JH.Space.s) {
                        Circle().fill(JH.Palette.track(track.kind.palette)).frame(width: 6, height: 6)
                        Text(track.name).font(JH.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, JH.Space.s)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(track.clips.sorted { $0.start < $1.start }) { clip in
                        Button {
                            model.selectClip(clip.id); model.seek(clip.start.seconds); clipPicker = false
                        } label: {
                            HStack {
                                Text(clip.name).lineLimit(1)
                                Spacer()
                                Text(timecode(clip.start.seconds, fps: model.fps)).font(JH.Font.numeric(10)).foregroundStyle(.secondary)
                            }
                            .font(JH.Font.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, JH.Space.s).padding(.vertical, JH.Space.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(clip.name), \(track.name), \(spokenTimecode(clip.start.seconds, fps: model.fps))"))
                    }
                }
            }
            .padding(JH.Space.m)
        }
        .frame(width: 320, height: 340)
    }

    private var trackHeaders: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                Text("트랙").font(JH.Font.micro).foregroundStyle(.tertiary).frame(height: 28)
                ForEach(model.project.sequence.tracks) { track in
                    VStack(alignment: .leading, spacing: JH.Space.xs) {
                        HStack(spacing: JH.Space.xs) {
                            Capsule().fill(JH.Palette.track(track.kind.palette)).frame(width: 3, height: 11)
                            Text(track.name).font(JH.Font.caption.weight(.semibold)).lineLimit(1)
                        }
                        HStack(spacing: JH.Space.m) {
                            Button { var t = track; t.isLocked.toggle(); model.perform(.updateTrack(t)) } label: {
                                Image(systemName: track.isLocked ? "lock.fill" : "lock.open")
                            }
                            .jhIconLabel(track.isLocked ? "\(track.name) 잠금 해제" : "\(track.name) 잠금")
                            Button { var t = track; t.isMuted.toggle(); model.perform(.updateTrack(t)) } label: {
                                Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                            }
                            .jhIconLabel(track.isMuted ? "\(track.name) 음소거 해제" : "\(track.name) 음소거")
                            .disabled(track.isLocked)
                            if track.kind != .audio {
                                Button { var t = track; t.isHidden.toggle(); model.perform(.updateTrack(t)) } label: {
                                    Image(systemName: track.isHidden ? "eye.slash" : "eye")
                                }
                                .jhIconLabel(track.isHidden ? "\(track.name) 보이기" : "\(track.name) 숨기기")
                                .disabled(track.isLocked)
                            }
                        }
                        .font(JH.Font.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 104, height: 51, alignment: .leading)
                    .padding(.leading, JH.Space.m)
                }
                Spacer(minLength: 0)
            }
            .offset(y: -model.timelineScrollY)
        }
        .clipped()
        .buttonStyle(.plain)
        .frame(width: 120)
        .disabled(model.isExporting)
        .jhSeam(.trailing)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: JH.Space.s) {
            Circle().fill(statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
            if model.isExporting {
                Text("영상 출력 중 \(Int(model.exportProgress * 100))%")
                ProgressView(value: model.exportProgress).frame(width: 150)
                    .accessibilityLabel(Text("출력 진행률"))
                Button("취소") { model.cancelExport() }.buttonStyle(.borderless)
            } else if model.productivityBusy {
                ProgressView().controlSize(.mini)
                Text(model.productivityStatus).lineLimit(1)
                Button("작업 취소") { model.cancelProductivity() }.buttonStyle(.borderless)
            } else if model.proxyBusy {
                Text(model.proxyStatus).lineLimit(1)
                ProgressView(value: model.proxyProgress).frame(width: 100)
                    .accessibilityLabel(Text("프록시 생성 진행률"))
                Button("프록시 취소") { model.cancelProxy() }.buttonStyle(.borderless)
            } else if model.isImporting {
                Text("미디어 가져오는 중…")
                ProgressView(value: model.importProgress).frame(width: 100)
                    .accessibilityLabel(Text("가져오기 진행률"))
                if model.importTask != nil { Button("가져오기 취소") { model.cancelImport() }.buttonStyle(.borderless) }
            } else {
                Text(model.message).lineLimit(1)
            }
            Spacer()
            Text("JH CUT STUDIO \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드") · 로컬 편집").font(JH.Font.micro).foregroundStyle(.tertiary)
        }
        .font(JH.Font.caption)
        .padding(.horizontal, JH.Space.l)
        .frame(height: 30)
        .jhSurface(.bar, in: Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("상태"))
    }

    private var statusColor: Color {
        if model.isExporting { return JH.Palette.warning }
        if model.busyDocument { return JH.Palette.warning }
        return JH.Palette.accent
    }
}

// MARK: - Shared helpers

extension TrackKind {
    var palette: JH.TrackPalette {
        switch self {
        case .video: return .video
        case .overlay: return .overlay
        case .title: return .title
        case .audio: return .audio
        }
    }
}

/// HH:MM:SS:FF at the sequence's own rate. NTSC rates use their rounded nominal for the frame field,
/// which is what every editor displays; this is not SMPTE drop-frame numbering.
func timecode(_ seconds: Double, fps: Double) -> String {
    let rate = max(1, Int((fps).rounded()))
    let frames = max(0, Int((seconds * Double(rate)).rounded()))
    let perHour = rate * 3600, perMinute = rate * 60
    return String(format: "%02d:%02d:%02d:%02d", frames / perHour, frames / perMinute % 60, frames / rate % 60, frames % rate)
}

/// VoiceOver reads "00:01:23:04" as digits; this spells the units instead.
func spokenTimecode(_ seconds: Double, fps: Double) -> String {
    let rate = max(1, Int((fps).rounded()))
    let frames = max(0, Int((seconds * Double(rate)).rounded()))
    let m = frames / (rate * 60), s = frames / rate % 60, f = frames % rate
    return m > 0 ? "\(m)분 \(s)초 \(f)프레임" : "\(s)초 \(f)프레임"
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct MediaRow: View {
    let asset: MediaAsset
    let url: URL
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: JH.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: JH.Radius.chip - 2, style: .continuous).fill(.black.opacity(0.4))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else {
                    Image(systemName: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: JH.Radius.chip - 2, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name).font(JH.Font.label.weight(.medium)).lineLimit(1)
                Text(detail).font(JH.Font.numeric(9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !asset.supported {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(JH.Palette.warning).font(.caption)
                    .accessibilityHidden(true)
            }
        }
        .padding(JH.Space.s)
        .background(selected ? JH.Palette.accent.opacity(0.16) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: JH.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: JH.Radius.chip, style: .continuous)
                .stroke(selected ? JH.Palette.accent.opacity(0.75) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(asset.name), \(detail)\(asset.supported ? "" : ", 지원하지 않는 미디어")"))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(Text("두 번 탭하면 타임라인 끝에 추가합니다"))
        .task(id: "\(asset.id)|\(url.path)|\(asset.width)|\(asset.height)") {
            thumbnail = nil
            if asset.kind == .image, let image = try? MediaImporter.loadImage(url: url, maxPixelSize: 180) {
                thumbnail = NSImage(cgImage: image, size: .zero)
            } else if asset.kind == .video {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 180, height: 100)
                if let result = try? await generator.image(at: .zero) { thumbnail = NSImage(cgImage: result.image, size: .zero) }
            }
        }
    }

    private var detail: String {
        asset.kind == .image
            ? "\(asset.codec) · \(asset.width)×\(asset.height)"
            : String(format: "%.2f초 · %@", asset.duration.seconds, asset.codec)
    }
}

private struct PlaybackTransport: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: PlaybackClock
    init(model: EditorModel) { self.model = model; self.clock = model.playbackClock }
    var body: some View {
        HStack(spacing: JH.Space.l) {
            Text(timecode(model.playhead, fps: model.fps))
                .font(JH.Font.timecode).foregroundStyle(JH.Palette.accent)
                .frame(minWidth: 92, alignment: .leading)
                .accessibilityLabel(Text("현재 위치 \(spokenTimecode(model.playhead, fps: model.fps))"))

            HStack(spacing: JH.Space.m) {
                Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }
                    .jhIconLabel("처음으로")
                Button { model.seek(model.playhead - model.frameStep) } label: { Image(systemName: "backward.frame.fill") }
                    .jhIconLabel("이전 프레임", hint: "왼쪽 화살표")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(JH.Palette.accent)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .jhIconLabel(model.playing ? "일시정지" : "재생", hint: "스페이스바")
                Button { model.seek(model.playhead + model.frameStep) } label: { Image(systemName: "forward.frame.fill") }
                    .jhIconLabel("다음 프레임", hint: "오른쪽 화살표")
            }
            .font(.system(size: 14))

            Text(timecode(model.project.sequence.duration.seconds, fps: model.fps))
                .font(JH.Font.numeric(11)).foregroundStyle(.secondary)
                .frame(minWidth: 92, alignment: .trailing)
                .accessibilityLabel(Text("전체 길이 \(spokenTimecode(model.project.sequence.duration.seconds, fps: model.fps))"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, JH.Space.l)
        .padding(.vertical, JH.Space.s)
        .jhSurface(.floating, in: Capsule(), interactive: true)
        .padding(.vertical, JH.Space.m)
        .disabled(!model.playing && (model.isBuilding || model.isExporting))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("재생 컨트롤"))
    }
}

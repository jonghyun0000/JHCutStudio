import SwiftUI
import AVKit
import JHCutCore
import UniformTypeIdentifiers

private let panelColor = Color(red: 0.095, green: 0.105, blue: 0.12)
private let accent = Color(red: 0.34, green: 0.80, blue: 0.70)

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var tab = "미디어"
    @State private var clipPicker = false
    @State private var mediaQuery = ""
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                HSplitView {
                    if model.libraryVisible { library.frame(minWidth: 210, idealWidth: 250, maxWidth: 370) }
                    preview.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    if model.inspectorVisible { inspector.frame(minWidth: 235, idealWidth: 270, maxWidth: 360) }
                }.frame(minHeight: 350)
                timeline.frame(minHeight: 250, idealHeight: 295, maxHeight: 420)
            }
            footer
        }
        .background(Color(red: 0.065, green: 0.072, blue: 0.085))
        .tint(accent)
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
    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: "film.stack.fill").font(.system(size: 24)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("JH CUT").font(.system(size: 17, weight: .heavy, design: .rounded))
                    Text("STUDIO  /  0.3").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                }
            }
            Divider().frame(height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.project.name).font(.system(size: 13, weight: .semibold))
                Text(model.dirty ? "● 저장하지 않은 변경사항" : "저장됨").font(.system(size: 10)).foregroundStyle(model.dirty ? .orange : .secondary)
            }
            Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }.help("프로젝트 저장 ⌘S")
            Spacer()
            Button { model.libraryVisible.toggle() } label: { Image(systemName: "sidebar.left") }.help("라이브러리 접기 / 펼치기")
            Button { model.inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }.help("속성 접기 / 펼치기")
            Divider().frame(height: 22)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.history.canUndo || model.isExporting)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.history.canRedo || model.isExporting)
            Button { model.exportVideo() } label: { Label("MP4 출력", systemImage: "square.and.arrow.up").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.plan == nil || model.isBuilding || model.busyDocument)
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 13)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["미디어", "자막", "사운드", "소스"], id: \.self) { name in
                    Button { tab = name } label: { Text(name).font(.system(size: 11, weight: tab == name ? .bold : .regular)).foregroundStyle(tab == name ? accent : .secondary).frame(maxWidth: .infinity).padding(.vertical, 13) }.buttonStyle(.plain)
                }
            }
            Divider()
            if tab == "미디어" {
                HStack {
                    Text("프로젝트 미디어").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.project.assets.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(14)
                Button { model.chooseMedia() } label: { Label(model.isImporting ? "미디어 분석 중…" : "파일 가져오기", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).padding(.horizontal, 12).disabled(model.isImporting || model.isExporting)
                TextField("미디어 이름·코덱 검색", text: $mediaQuery).textFieldStyle(.roundedBorder).font(.system(size: 11)).padding(.horizontal, 12).padding(.top, 8)
                if model.project.assets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(accent)
                        Text("촬영한 영상과 AI 클립을\n이곳으로 끌어오세요").font(.system(size: 12)).multilineTextAlignment(.center)
                        Text("SDR H.264·HEVC·ProRes · 사진·오디오\n모든 편집은 이 Mac에서 처리됩니다.").font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    assetList
                }
                if let asset = model.project.assets.first(where: { $0.id == model.selectedAssetID }) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let provenance = asset.provenance {
                            Text("\(provenance.author) · \(provenance.license)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Text(asset.issue ?? "\(asset.codec) · \(asset.colorInfo)").font(.system(size: 10)).foregroundStyle(asset.supported ? Color.secondary : Color.orange).lineLimit(4)
                        Button("타임라인 끝에 추가") { model.addAsset(asset) }.frame(maxWidth: .infinity).disabled(!asset.supported || model.isExporting)
                        if asset.kind != .audio {
                            HStack {
                                Button("여기에 삽입") { model.editAssetAtPlayhead(asset, overwrite: false) }
                                Button("덮어쓰기") { model.editAssetAtPlayhead(asset, overwrite: true) }
                            }.font(.system(size: 10)).disabled(!asset.supported || model.isExporting)
                        }
                        if asset.kind != .audio { Button("오버레이로 추가") { model.addAsset(asset, overlay: true) }.disabled(!asset.supported || model.isExporting) }
                    }.buttonStyle(.bordered).padding(12).background(.black.opacity(0.16))
                }
            } else if tab == "자막" {
                CaptionsPanel(model: model)
            } else {
                LibraryBrowser(model: model, audioOnly: tab == "사운드").id(tab)
            }
        }.background(panelColor)
    }
    private var assetList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(visibleAssets) { asset in assetRow(asset) }
            }.padding(10)
        }
    }
    private var visibleAssets: [MediaAsset] { model.project.assets.filter { mediaQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(mediaQuery) || $0.codec.localizedCaseInsensitiveContains(mediaQuery) } }
    private func assetRow(_ asset: MediaAsset) -> some View {
        MediaRow(asset: asset, url: asset.resolvedURL(relativeTo: model.mediaBaseURL), selected: model.selectedAssetID == asset.id)
            .onTapGesture(count: 2) { if !model.isExporting { model.addAsset(asset) } }
            .onTapGesture { model.selectedAssetID = asset.id }
    }
    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.proxyEnabled ? "프록시 미리보기" : "미리보기").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Button { model.safeAreaVisible.toggle() } label: { Image(systemName: model.safeAreaVisible ? "viewfinder.circle.fill" : "viewfinder.circle") }.buttonStyle(.borderless).help("자막 안전 영역 80% 표시 · 출력에는 포함되지 않습니다")
                Spacer()
                Text("\(model.project.sequence.width) × \(model.project.sequence.height)  /  30 fps  /  Rec.709").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            ZStack {
                Color.black
                if model.plan != nil { PlayerSurface(player: model.player) }
                else if !model.isBuilding {
                    VStack(spacing: 16) {
                        Image(systemName: "play.rectangle").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.gray)
                        Text(model.project.sequence.duration > .zero ? "미디어를 확인하세요" : "나만의 첫 장면을 시작하세요").font(.system(size: 16, weight: .medium))
                        Text("미디어 가져오기 → 타임라인에 추가").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if model.safeAreaVisible { SafeAreaOverlay(width: model.project.sequence.width, height: model.project.sequence.height) }
                if model.isBuilding { VStack(spacing: 12) { ProgressView(); Text("타임라인 합성 중…").font(.caption) } }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack(spacing: 20) {
                Text(timecode(model.playhead)).font(.system(size: 12, design: .monospaced)).foregroundStyle(accent).frame(width: 95)
                Spacer()
                Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }.help("처음으로")
                Button { model.seek(model.playhead - 1.0 / 30) } label: { Image(systemName: "backward.frame.fill") }.help("이전 프레임 ←")
                Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 22)).foregroundStyle(accent) }.help("재생 / 정지 Space")
                Button { model.seek(model.playhead + 1.0 / 30) } label: { Image(systemName: "forward.frame.fill") }.help("다음 프레임 →")
                Spacer()
                Text("/ " + timecode(model.project.sequence.duration.seconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 12).disabled(model.isBuilding || model.isExporting)
        }
    }
    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selectedClipIDs.count > 1 ? "속성 · \(model.selectedClipIDs.count)개 선택" : "속성").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("프로젝트") { model.selectedClipID = nil; model.selectedClipIDs = [] }.font(.system(size: 10)).buttonStyle(.borderless)
            }.padding(15)
            Divider()
            if let (track, clip) = model.selected {
                ClipInspector(model: model, track: track, clip: clip).id(clip.id).disabled(model.isExporting || track.isLocked)
            } else {
                ProjectTools(model: model)
            }
        }.background(panelColor)
    }
    private var timeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("타임라인").font(.system(size: 12, weight: .bold))
                Button { model.split() } label: { Label("분할", systemImage: "scissors") }.disabled(model.selected == nil)
                Button { model.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }.help("클립 복제").disabled(model.selected == nil)
                Button { model.remove() } label: { Image(systemName: "trash") }.help("일반 삭제 · 빈 공간 유지").disabled(model.selected == nil)
                Button { model.reorder(-1) } label: { Image(systemName: "arrow.left.to.line") }.help("선택 클립 순서를 앞으로").disabled(model.selected == nil)
                Button { model.reorder(1) } label: { Image(systemName: "arrow.right.to.line") }.help("선택 클립 순서를 뒤로").disabled(model.selected == nil)
                Button { model.addTitle() } label: { Label("제목", systemImage: "textformat") }
                Button { clipPicker.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                    .help("겹친 클립을 포함한 전체 클립 선택")
                    .popover(isPresented: $clipPicker) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(model.project.sequence.tracks) { track in
                                    Text(track.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                                    ForEach(track.clips.sorted { $0.start < $1.start }) { clip in
                                        Button { model.selectClip(clip.id); model.seek(clip.start.seconds); clipPicker = false } label: {
                                            HStack { Text(clip.name).lineLimit(1); Spacer(); Text(timecode(clip.start.seconds)).monospacedDigit() }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }.padding(12)
                        }.frame(width: 320, height: 330)
                    }
                Spacer()
                Toggle(isOn: $model.snappingEnabled) { Text("스냅").font(.system(size: 10)) }.toggleStyle(.switch).controlSize(.mini).help("클립 경계와 플레이헤드에 맞추기")
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $model.zoom, in: 12...180).frame(width: 105)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }.font(.system(size: 11)).buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 11).disabled(model.isExporting)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { _ in
                VStack(spacing: 0) {
                    Text("트랙").font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 28)
                    ForEach(model.project.sequence.tracks) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.name).font(.system(size: 10, weight: .semibold))
                            HStack(spacing: 12) {
                                Button { var t = track; t.isLocked.toggle(); model.perform(.updateTrack(t)) } label: { Image(systemName: track.isLocked ? "lock.fill" : "lock.open") }.help("트랙 잠금")
                                Button { var t = track; t.isMuted.toggle(); model.perform(.updateTrack(t)) } label: { Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2") }.help("트랙 음소거").disabled(track.isLocked)
                                if track.kind != .audio { Button { var t = track; t.isHidden.toggle(); model.perform(.updateTrack(t)) } label: { Image(systemName: track.isHidden ? "eye.slash" : "eye") }.help("트랙 숨김").disabled(track.isLocked) }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(width: 95, height: 51, alignment: .leading).padding(.leading, 12)
                    }
                    Spacer(minLength: 0)
                }.offset(y: -model.timelineScrollY)
                }.clipped().buttonStyle(.plain).frame(width: 112).background(panelColor).disabled(model.isExporting)
                Divider()
                TimelineSurface(model: model)
            }
        }.background(Color(red: 0.075, green: 0.083, blue: 0.096))
    }
    private var footer: some View {
        HStack {
            Circle().fill(model.isExporting ? Color.orange : accent).frame(width: 5, height: 5)
            if model.isExporting {
                Text("MP4 출력 중 \(Int(model.exportProgress * 100))%")
                ProgressView(value: model.exportProgress).frame(width: 160)
                Button("취소") { model.cancelExport() }.buttonStyle(.borderless)
            } else if model.productivityBusy {
                ProgressView().controlSize(.mini)
                Text(model.productivityStatus).lineLimit(1)
                Button("작업 취소") { model.cancelProductivity() }.buttonStyle(.borderless)
            } else if model.proxyBusy {
                Text(model.proxyStatus).lineLimit(1)
                ProgressView(value: model.proxyProgress).frame(width: 100)
                Button("프록시 취소") { model.cancelProxy() }.buttonStyle(.borderless)
            } else if model.isImporting {
                Text("미디어 가져오는 중…")
                ProgressView(value: model.importProgress).frame(width: 100)
                if model.importTask != nil { Button("가져오기 취소") { model.cancelImport() }.buttonStyle(.borderless) }
            } else { Text(model.message).lineLimit(1) }
            Spacer()
            Text("로컬 편집 · 0.3").foregroundStyle(.secondary)
        }.font(.system(size: 10)).padding(.horizontal, 16).frame(height: 29).background(panelColor)
    }
}

func timecode(_ seconds: Double) -> String {
    let frames = max(0, Int((seconds * 30).rounded()))
    return String(format: "%02d:%02d:%02d:%02d", frames / 108000, frames / 1800 % 60, frames / 30 % 60, frames % 30)
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct MediaRow: View {
    let asset: MediaAsset
    let url: URL
    let selected: Bool
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "film").foregroundStyle(.secondary) }
            }.frame(width: 61, height: 44).clipped()
            VStack(alignment: .leading, spacing: 5) {
                Text(asset.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(asset.kind == .image ? "\(asset.codec) · \(asset.width)×\(asset.height)" : String(format: "%.2f초 · %@", asset.duration.seconds, asset.codec)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !asset.supported { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
        }.padding(8).background(selected ? accent.opacity(0.15) : Color.white.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? accent.opacity(0.7) : .clear))
            .task(id: "\(asset.id)|\(url.path)|\(asset.width)|\(asset.height)") {
                thumbnail = nil
                if asset.kind == .image, let image = try? MediaImporter.loadImage(url: url, maxPixelSize: 180) { thumbnail = NSImage(cgImage: image, size: .zero) }
                else if asset.kind == .video {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 180, height: 100)
                    if let result = try? await generator.image(at: .zero) { thumbnail = NSImage(cgImage: result.image, size: .zero) }
                }
            }
    }
}

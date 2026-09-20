import SwiftUI
import JHCutCore

/// Canvas presets offered in the format picker. Every entry is inside the renderer's 4096-per-axis and
/// 9.4-megapixel bounds, so a preset can never produce a plan the engine refuses.
private struct CanvasPreset: Identifiable, Hashable {
    let name: String
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var label: String { "\(name) · \(width)×\(height)" }

    static let landscape: [CanvasPreset] = [
        CanvasPreset(name: "4K UHD", width: 3840, height: 2160),
        CanvasPreset(name: "DCI 4K", width: 4096, height: 2160),
        CanvasPreset(name: "2.7K", width: 2704, height: 1520),
        CanvasPreset(name: "1080p", width: 1920, height: 1080),
        CanvasPreset(name: "720p", width: 1280, height: 720)
    ]
    static let portrait: [CanvasPreset] = [
        CanvasPreset(name: "세로 4K", width: 2160, height: 3840),
        CanvasPreset(name: "세로 1080", width: 1080, height: 1920),
        CanvasPreset(name: "정사각형", width: 1080, height: 1080),
        CanvasPreset(name: "피드 4:5", width: 1080, height: 1350)
    ]
    static var all: [CanvasPreset] { landscape + portrait }
}

struct ProjectTools: View {
    @ObservedObject var model: EditorModel
    @State private var rename = ""

    private var sequence: Sequence { model.project.sequence }
    private var currentPreset: CanvasPreset? {
        CanvasPreset.all.first { $0.width == sequence.width && $0.height == sequence.height }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JH.Space.l) {
                section("프로젝트") {
                    TextField("프로젝트 이름", text: $rename)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("프로젝트 이름"))
                        .onAppear { rename = model.project.name }
                        .onChange(of: model.project.name) { _, value in rename = value }
                        .onSubmit { if !rename.isEmpty { model.perform(.rename(rename)) } }
                    Text(model.recoveryStatus).font(JH.Font.micro).foregroundStyle(.secondary)
                    HStack(spacing: JH.Space.s) {
                        Button("복구본 열기…") { model.offerRecovery() }
                        Button("원본 모으기…") { model.collectProject() }.disabled(model.busyDocument)
                    }
                    .buttonStyle(.jhTool).font(JH.Font.caption)
                }

                section("출력 형식") { formatControls }

                section("출력 품질") { qualityControls }

                DisclosureGroup("프록시 미리보기") {
                    VStack(alignment: .leading, spacing: JH.Space.s) {
                        Toggle("프록시 사용", isOn: $model.proxyEnabled)
                            .onChange(of: model.proxyEnabled) { model.rebuild() }
                            .disabled(model.proxyURLs.isEmpty || model.busyDocument)
                        Text(model.proxyStatus).font(JH.Font.micro).foregroundStyle(.secondary)
                        HStack(spacing: JH.Space.s) {
                            Button("프록시 생성") { model.generateProxies() }.disabled(model.busyDocument)
                            Button("캐시 비우기") { model.clearProxies() }.disabled(model.busyDocument)
                        }
                        Text("최대 1280×720 · 캐시 2GB · MP4 출력은 항상 원본을 사용합니다.")
                            .font(JH.Font.micro).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.jhTool).font(JH.Font.label)
                    .padding(.top, JH.Space.s)
                }
                .font(JH.Font.sectionTitle)

                DisclosureGroup("트랙 관리") { TrackManager(model: model).padding(.top, JH.Space.s) }
                    .font(JH.Font.sectionTitle)

                section("비율별 독립 버전") {
                    Menu("현재 시퀀스를 복제하여 만들기") {
                        ForEach(CanvasPreset.all) { preset in
                            Button(preset.label) { model.derive(width: preset.width, height: preset.height, name: preset.name) }
                        }
                    }
                    .font(JH.Font.label)
                    ForEach(model.project.derivedSequences ?? []) { derived in
                        Button("\(derived.name) · \(derived.width)×\(derived.height)") {
                            model.perform(.activateDerivedSequence(derived.id))
                            model.selectedClipID = nil; model.selectedClipIDs = []; model.seek(0)
                        }
                        .font(JH.Font.caption).buttonStyle(.jhTool)
                    }
                    Text("원본 미디어는 재사용하고 텍스트·크롭은 버전별로 독립 편집합니다.")
                        .font(JH.Font.micro).foregroundStyle(.tertiary)
                }

                section("미디어 연결") {
                    ForEach(model.project.assets) { asset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.name).font(JH.Font.caption).lineLimit(1)
                                if !FileManager.default.fileExists(atPath: asset.resolvedURL(relativeTo: model.mediaBaseURL).path) {
                                    Text("미디어 누락").font(JH.Font.micro).foregroundStyle(JH.Palette.warning)
                                }
                            }
                            Spacer()
                            Button("재연결") { model.relink(asset) }.font(JH.Font.micro).buttonStyle(.borderless)
                                .accessibilityLabel(Text("\(asset.name) 재연결"))
                        }
                    }
                }

                Text("클립을 선택하면 속성이 열립니다. ⌘를 누르고 클릭하면 여러 클립을 선택합니다.")
                    .font(JH.Font.caption).foregroundStyle(.secondary)
            }
            .padding(JH.Space.l)
        }
        .disabled(model.isExporting)
    }

    // MARK: Format

    @ViewBuilder private var formatControls: some View {
        // Reads back from the sequence rather than from local state, so undo and version switching
        // cannot leave the picker showing a format the project does not have.
        Picker("캔버스", selection: Binding(
            get: { currentPreset?.id ?? "custom" },
            set: { id in
                guard let preset = CanvasPreset.all.first(where: { $0.id == id }) else { return }
                model.setFormat(width: preset.width, height: preset.height, frameRate: sequence.frameRate)
            })) {
            Section("가로") { ForEach(CanvasPreset.landscape) { Text($0.label).tag($0.id) } }
            Section("세로") { ForEach(CanvasPreset.portrait) { Text($0.label).tag($0.id) } }
            if currentPreset == nil { Text("사용자 지정 · \(sequence.width)×\(sequence.height)").tag("custom") }
        }
        .font(JH.Font.label)
        .disabled(model.busyDocument)

        Picker("프레임레이트", selection: Binding(
            get: { sequence.frameRate },
            set: { model.setFormat(width: sequence.width, height: sequence.height, frameRate: $0) })) {
            ForEach(FrameRate.supportedRenderRates, id: \.self) { rate in
                Text("\(rate.label) fps").tag(rate)
            }
        }
        .font(JH.Font.label)
        .disabled(model.busyDocument)

        Text("\(sequence.width) × \(sequence.height) · \(sequence.frameRate.label) fps · SDR Rec.709")
            .font(JH.Font.numeric(11)).foregroundStyle(.secondary)

        if sequence.width * sequence.height > 1920 * 1080 {
            Label("4K는 소프트웨어 합성이라 미리보기가 느려질 수 있습니다. 프록시를 켜세요.", systemImage: "info.circle")
                .font(JH.Font.micro).foregroundStyle(.tertiary)
        }
        Text("클립 시간은 유리수로 저장되므로 프레임레이트를 바꿔도 편집이 그대로 유지됩니다.")
            .font(JH.Font.micro).foregroundStyle(.tertiary)
    }

    // MARK: Quality

    @ViewBuilder private var qualityControls: some View {
        Picker("품질", selection: Binding(
            get: { model.outputQuality },
            set: { quality in
                model.outputQuality = quality
                model.outputBitRate = ExportJob.recommendedBitRate(width: sequence.width, height: sequence.height,
                                                                   fps: sequence.frameRate.fps, quality: quality)
            })) {
            Text("작은 용량").tag(ExportJob.Quality.small)
            Text("표준").tag(ExportJob.Quality.standard)
            Text("높은 품질").tag(ExportJob.Quality.high)
        }
        .pickerStyle(.segmented)
        .font(JH.Font.label)

        HStack {
            Text("H.264 \(model.outputBitRate / 1_000_000)Mbps").font(JH.Font.numeric(11))
            Spacer()
            Text("예상 \(estimatedMegabytes)MB").font(JH.Font.numeric(11)).foregroundStyle(.secondary)
        }
        Text("실제 용량은 화면 내용에 따라 달라집니다. AAC 192kbps가 더해집니다.")
            .font(JH.Font.micro).foregroundStyle(.tertiary)
    }

    private var estimatedMegabytes: Int {
        Int(sequence.duration.seconds * Double(model.outputBitRate + 192_000) / 8 / 1_000_000)
    }

    // MARK: Layout

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: JH.Space.s) {
            Text(title).font(JH.Font.sectionTitle).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

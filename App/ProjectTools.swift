import SwiftUI
import JHCutCore

struct ProjectTools: View {
    @ObservedObject var model: EditorModel
    @State private var rename = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("프로젝트 설정").font(.headline)
                TextField("프로젝트 이름", text: $rename).textFieldStyle(.roundedBorder)
                    .onAppear { rename = model.project.name }.onChange(of: model.project.name) { _, value in rename = value }
                    .onSubmit { if !rename.isEmpty { model.perform(.rename(rename)) } }
                Text("\(model.project.sequence.width) × \(model.project.sequence.height)\n30 fps · SDR Rec.709").font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                Text(model.recoveryStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                Button("복구본 열기…") { model.offerRecovery() }.buttonStyle(.bordered)
                Button("프로젝트와 원본 모으기…") { model.collectProject() }.buttonStyle(.bordered).disabled(model.busyDocument)
                Divider()
                DisclosureGroup("프록시 미리보기") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("프록시 사용", isOn: $model.proxyEnabled).onChange(of: model.proxyEnabled) { model.rebuild() }.disabled(model.proxyURLs.isEmpty || model.busyDocument)
                        Text(model.proxyStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("영상 프록시 생성") { model.generateProxies() }.disabled(model.busyDocument)
                        Button("프록시 캐시 비우기") { model.clearProxies() }.disabled(model.busyDocument)
                        Text("최대 1280×720 · 캐시 2GB · MP4 출력은 원본 사용").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.buttonStyle(.bordered).font(.system(size: 11))
                }
                DisclosureGroup("출력 품질") {
                    Picker("H.264 비트레이트", selection: $model.outputBitRate) {
                        Text("작은 용량 · 4Mbps").tag(4_000_000)
                        Text("표준 · 8Mbps").tag(8_000_000)
                        Text("높은 품질 · 16Mbps").tag(16_000_000)
                    }.font(.system(size: 11))
                    Text("예상 \(Int(model.project.sequence.duration.seconds * Double(model.outputBitRate + 192_000) / 8 / 1_000_000))MB · 콘텐츠에 따라 달라집니다.").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                DisclosureGroup("트랙 관리") { TrackManager(model: model) }
                Divider()
                Text("비율별 독립 버전").font(.system(size: 12, weight: .semibold))
                Menu("현재 시퀀스를 복제하여 만들기") {
                    Button("세로 · 9:16") { model.derive(width: 1080, height: 1920, name: "세로 버전") }
                    Button("가로 · 16:9") { model.derive(width: 1920, height: 1080, name: "가로 버전") }
                    Button("정사각형 · 1:1") { model.derive(width: 1080, height: 1080, name: "정사각형 버전") }
                    Button("피드 · 4:5") { model.derive(width: 1080, height: 1350, name: "피드 버전") }
                }.font(.system(size: 11))
                ForEach(model.project.derivedSequences ?? []) { sequence in
                    Button("\(sequence.name) · \(sequence.width)×\(sequence.height)") { model.perform(.activateDerivedSequence(sequence.id)); model.selectedClipID = nil; model.selectedClipIDs = []; model.seek(0) }.font(.system(size: 10)).buttonStyle(.bordered)
                }
                Text("원본 미디어는 재사용하고 텍스트·크롭은 버전별로 독립 편집합니다.").font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
                Text("미디어 연결").font(.system(size: 12, weight: .semibold))
                ForEach(model.project.assets) { asset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(asset.name).font(.system(size: 10)).lineLimit(1)
                            if !FileManager.default.fileExists(atPath: asset.resolvedURL(relativeTo: model.mediaBaseURL).path) { Text("미디어 누락").font(.system(size: 9)).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("재연결") { model.relink(asset) }.font(.system(size: 9)).buttonStyle(.borderless)
                    }
                }
                Divider()
                Text("클립 선택 후 속성을 편집하세요. Cmd를 누르고 클릭하면 여러 클립을 선택합니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(15)
        }.disabled(model.isExporting)
    }
}

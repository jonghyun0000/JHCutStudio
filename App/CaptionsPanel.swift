import SwiftUI
import JHCutCore

struct CaptionsPanel: View {
    @ObservedObject var model: EditorModel
    @State private var mode = "스타일"
    @State private var query = ""
    @State private var allCaptions = false
    @State private var offset = "0"
    @State private var captionWarnings = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("자막과 타이틀").font(.headline); Spacer(); Button { model.addTitle() } label: { Image(systemName: "plus") } }.padding(.top, 14)
            HStack {
                Button("SRT 가져오기") { model.importSRT() }
                Button("SRT 저장") { model.exportSRT() }.disabled(model.captionClips.isEmpty)
            }.buttonStyle(.bordered).font(.system(size: 10))
            Picker("보기", selection: $mode) { Text("스타일").tag("스타일"); Text("자막 목록").tag("자막 목록") }.pickerStyle(.segmented)
            TextField(mode == "스타일" ? "스타일 검색" : "자막 문구 검색", text: $query).textFieldStyle(.roundedBorder)
            if mode == "스타일" {
                Toggle("모든 제목·자막에 스타일 적용", isOn: $allCaptions).font(.system(size: 10))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.allTitlePresets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }) { preset in
                            Button { model.applyTitlePreset(preset, toAll: allCaptions) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    PresetThumbnail(title: preset.title).frame(height: 65).frame(maxWidth: .infinity).background(Color(white: 0.14)).clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(preset.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(preset.category).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).disabled(model.isExporting)
                        }
                    }
                }
                Button("선택한 자막 스타일 저장") { model.saveCurrentTitlePreset() }.buttonStyle(.bordered).font(.system(size: 10)).disabled(model.selected?.1.title == nil)
                Text("자막 선택 시 스타일 변경 · 미선택 시 새 자막 추가").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.captionClips.filter { query.isEmpty || ($0.title?.text ?? "").localizedCaseInsensitiveContains(query) }) { clip in
                            Button { model.selectClip(clip.id); model.seek(clip.start.seconds) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clip.title?.text ?? "").font(.system(size: 12)).foregroundStyle(.primary).lineLimit(3)
                                    Text(timecode(clip.start.seconds) + " → " + timecode(clip.end.seconds)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(model.selectedClipID == clip.id ? Color.mint.opacity(0.14) : Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button("분할") { model.split() }.disabled(model.selected?.1.title == nil)
                    Button("다음 자막과 합치기") { model.mergeNextCaption() }.disabled(model.selected?.1.title == nil)
                }.font(.system(size: 10)).buttonStyle(.bordered)
                HStack {
                    TextField("이동 초 · ±", text: $offset).textFieldStyle(.roundedBorder)
                    Button("전체 시간 이동") {
                        if let seconds = Double(offset) { model.offsetCaptions(seconds) } else { model.error = "이동 시간을 숫자로 입력하세요." }
                    }
                }.font(.system(size: 10))
                if !captionWarnings.isEmpty { Text(captionWarnings).font(.system(size: 9)).foregroundStyle(.orange) }
                Text("문구·시간은 오른쪽 속성에서 수정합니다. 문구 수정은 영상을 자르지 않습니다.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            SpeechTools(model: model).padding(.bottom, 10)
        }.padding(.horizontal, 12)
            .onAppear { updateWarnings() }
            .onChange(of: model.captionClips) { updateWarnings() }
            .onChange(of: model.project.sequence.width) { updateWarnings() }
    }
    private func updateWarnings() {
        let clips = model.captionClips
        let truncated = clips.filter { clip in
            guard let title = clip.title, let layout = try? TitlePreviewRenderer.layout(title: title, canvasWidth: Double(model.project.sequence.width)) else { return false }
            return layout.wasTruncated
        }.count
        let overlaps = zip(clips, clips.dropFirst()).filter { $0.0.end > $0.1.start }.count
        captionWarnings = [truncated > 0 ? "최대 줄 수로 잘리는 자막 \(truncated)개" : "", overlaps > 0 ? "시간이 겹친 자막이 있습니다. 의도한 중첩인지 확인하세요." : ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct PresetThumbnail: View {
    let title: Title
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView().controlSize(.small) } }
            .task(id: try? JSONEncoder().encode(title)) {
                var sample = title; sample.text = "종현의 이야기"; sample.x = sample.style?.alignment == .left ? 0.12 : sample.style?.alignment == .right ? 0.88 : 0.5; sample.y = 0.5; sample.fontSize = 30
                if var style = sample.style { style.strokeWidth = min(style.strokeWidth, 2); style.padding = 6; sample.style = style }
                if let value = try? TitlePreviewRenderer.image(title: sample, size: CGSize(width: 300, height: 150)) { image = NSImage(cgImage: value, size: .zero) }
            }
    }
}

import SwiftUI
import AppKit
import JHCutCore

struct CaptionsPanel: View {
    @ObservedObject var model: EditorModel
    @State private var mode = "자동 자막"
    @State private var query = ""
    @State private var allCaptions = false
    @State private var offset = "0"
    @State private var replacement = ""
    @State private var captionWarnings = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("자막과 타이틀").font(JH.Font.sectionTitle); Spacer(); Button { model.addTitle() } label: { Image(systemName: "plus") }
            .buttonStyle(.jhTool).jhIconLabel("자막 추가", hint: "새 제목 클립을 타임라인에 추가합니다") }
            .padding(.top, JH.Space.m)
            HStack {
                Button("SRT 가져오기") { model.importSRT() }
                Button("SRT 저장") { model.exportSRT() }.disabled(model.captionClips.isEmpty)
            }.buttonStyle(.jhTool).font(JH.Font.caption)
            Picker("SRT 범위", selection: $model.subtitleExportScope) {
                Text("표시 중인 자막").tag("visible"); Text("원문 자막").tag("original"); Text("번역 자막").tag("translation")
            }.font(JH.Font.caption)
            Picker("보기", selection: $mode) { Text("자동 자막").tag("자동 자막"); Text("스타일").tag("스타일"); Text("자막 목록").tag("자막 목록") }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if mode != "자동 자막" { TextField(mode == "스타일" ? "스타일 검색" : "자막 문구 검색", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(mode == "스타일" ? "스타일 검색" : "자막 문구 검색"))
            }
            if mode == "자동 자막" {
                ScrollView { VStack(alignment: .leading, spacing: 10) { SpeechTools(model: model); SpeakerTools(model: model); CaptionBatchTools(model: model) }.padding(.vertical, 8) }
            } else if mode == "스타일" {
                Toggle("모든 제목·자막에 스타일 적용", isOn: $allCaptions).font(JH.Font.caption)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.allTitlePresets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }) { preset in
                            Button { model.applyTitlePreset(preset, toAll: allCaptions) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    PresetThumbnail(title: preset.title).frame(height: 65).frame(maxWidth: .infinity).background(JH.Palette.surface).clipShape(RoundedRectangle(cornerRadius: JH.Radius.chip, style: .continuous))
                                    Text(preset.name).font(JH.Font.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(preset.category).font(JH.Font.micro).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain).disabled(model.isExporting)
                            .accessibilityLabel(Text("\(preset.name) 스타일, \(preset.category)"))
                            .accessibilityHint(Text(allCaptions ? "모든 자막에 적용합니다" : "선택한 자막에 적용합니다"))
                        }
                    }
                }
                Button("선택한 자막 스타일 저장") { model.saveCurrentTitlePreset() }.buttonStyle(.jhTool).font(JH.Font.caption).disabled(model.selected?.1.title == nil)
                Text("자막 선택 시 스타일 변경 · 미선택 시 새 자막 추가").font(JH.Font.micro).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("이전") { model.nextCaption(-1) }; Button("다음") { model.nextCaption(1) }
                    Button("반복 듣기") { model.loopSelection() }; Toggle("반복", isOn: $model.loopEnabled)
                }.font(JH.Font.micro)
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.captionClips.filter { query.isEmpty || ($0.title?.text ?? "").localizedCaseInsensitiveContains(query) }) { clip in
                            VStack(alignment: .leading, spacing: 5) {
                                CaptionInlineEditor(model: model, clip: clip)
                                if let info = clip.captionMetadata { CaptionLanguageBadge(model: model, clipID: clip.id, info: info) }
                                if model.repetitionCaptionIDs.contains(clip.id) { Text("반복 인식 의심 · 같은 문장이 연속으로 나와 하나만 남겼습니다").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                                if let kind = model.silentCaptionWarnings[clip.id] { Text("\(kind.label) 구간 위 자막 · 말소리가 거의 없습니다").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                                if (Double(clip.title?.text.count ?? 0) / max(0.01, clip.duration.seconds)) > 15 { Text("읽기 빠름 · 문구를 줄이거나 시간을 늘리세요").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                                Button { model.selectClip(clip.id); model.seek(clip.start.seconds) } label: {
                                    Text(timecode(clip.start.seconds, fps: model.fps) + " → " + timecode(clip.end.seconds, fps: model.fps)).font(JH.Font.numeric(9)).foregroundStyle(.secondary)
                                }.buttonStyle(.plain).accessibilityLabel(Text("자막 구간으로 이동"))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(model.selectedClipID == clip.id ? JH.Palette.accent.opacity(0.16) : Color.white.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: JH.Radius.chip, style: .continuous))
                        }
                    }
                }
                // The list needs the height: less frequent tools are folded away (they used to leave
                // the list about 40 px on a 870 px window, hiding each caption's warnings).
                DisclosureGroup("찾아 바꾸기 · 분할 · 전체 시간 이동") {
                    VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("바꿀 문구", text: $replacement).textFieldStyle(.roundedBorder)
                        Button("검색어 일괄 교정") { model.replaceCaptionText(find: query, replacement: replacement) }.disabled(query.isEmpty)
                    }.font(JH.Font.micro)
                    HStack {
                        Button("분할") { model.split() }.disabled(model.selected?.1.title == nil)
                        Button("다음 자막과 합치기") { model.mergeNextCaption() }.disabled(model.selected?.1.title == nil)
                    }.font(JH.Font.caption).buttonStyle(.jhTool)
                    HStack {
                        TextField("이동 초 · ±", text: $offset).textFieldStyle(.roundedBorder)
                        Button("전체 시간 이동") {
                            if let seconds = Double(offset) { model.offsetCaptions(seconds) } else { model.error = "이동 시간을 숫자로 입력하세요." }
                        }
                    }.font(JH.Font.caption)
                    }
                }.font(JH.Font.caption)
                if !captionWarnings.isEmpty { Text(captionWarnings).font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                Text("문구·시간은 오른쪽 속성에서 수정합니다. 문구 수정은 영상을 자르지 않습니다.").font(JH.Font.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12)
            .onAppear { updateWarnings() }
            .onChange(of: model.project.sequence.tracks) { updateWarnings() }
            .onChange(of: model.project.sequence.width) { updateWarnings() }
            .onChange(of: model.transcriptionActive) { _, active in
                if !active, model.transcriptionProgress == 1 { mode = "자막 목록"; query = "" }
            }
    }
    private func updateWarnings() {
        let clips = model.project.sequence.tracks.filter { $0.kind == .title && !$0.isHidden }.flatMap(\.clips).sorted { $0.start < $1.start }
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

private struct CaptionInlineEditor: View {
    @ObservedObject var model: EditorModel
    let clip: Clip
    @State private var text = ""
    var body: some View {
        TextField("자막 문구 · Enter로 적용", text: $text).textFieldStyle(.roundedBorder)
            .onAppear { text = clip.title?.text ?? "" }
            .onChange(of: clip.title?.text) { _, value in text = value ?? "" }
            .onSubmit { model.updateCaption(clip.id, text: text) }
    }
}


/// Language line under a caption: detected language with confidence, a review flag for short or
/// ambiguous sentences, and a menu to set the language by hand (one undo step).
struct CaptionLanguageBadge: View {
    @ObservedObject var model: EditorModel
    let clipID: UUID
    let info: CaptionMetadata
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(JH.Font.micro).foregroundStyle(info.languageNeedsReview == true && info.languageManual != true ? JH.Palette.warning : .secondary)
            if info.translatedFrom == nil {
                Menu("언어") {
                    ForEach(CaptionLanguage.allCases, id: \.self) { language in
                        Button(language.label) { model.setCaptionLanguage([clipID], to: language.rawValue) }
                    }
                    if info.languageManual == true { Divider(); Button("자동 감지로 되돌리기") { model.resetCaptionLanguage([clipID]) } }
                }.menuStyle(.borderlessButton).fixedSize().font(JH.Font.micro)
            }
        }
        if info.translatedFrom != nil { Text("원문: " + info.originalText).font(JH.Font.micro).foregroundStyle(.secondary).lineLimit(2) }
        if let note = translationNote { Text(note).font(JH.Font.micro).foregroundStyle(info.glossaryFailed != nil ? JH.Palette.warning : .secondary).lineLimit(2) }
    }
    /// Whether the glossary and requested register actually took effect for this translation.
    private var translationNote: String? {
        guard info.translatedFrom != nil else { return nil }
        if let text = model.captionClips.first(where: { $0.id == clipID })?.title?.text, text != info.generatedText { return "직접 고친 번역 · 다시 번역해도 유지됩니다" }
        var parts: [String] = []
        if let applied = info.glossaryApplied { parts.append("용어집 적용: " + applied.joined(separator: ", ")) }
        if let failed = info.glossaryFailed { parts.append("용어집 적용 실패: " + failed.joined(separator: ", ")) }
        if let raw = info.translationStyle, let style = TranslationStyle(rawValue: raw) {
            switch info.styleApplied {
            case true?: parts.append(style.label + " 적용")
            case false?: parts.append(style.label + " 일부 문장 미적용")
            case nil: parts.append(style.label + " 해당 없음")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var label: String {
        let name = CaptionLanguage(rawValue: info.language)?.label ?? info.language
        if info.translatedFrom != nil { return name + " 번역" }
        if info.languageManual == true { return name + " 원문 · 직접 지정" }
        if info.languageNeedsReview == true { return name + " 원문 · 언어 확인 필요" }
        if let c = info.languageConfidence { return name + " 원문 · 감지 \(Int((c * 100).rounded()))%" }
        return name + " 원문"
    }
}

/// Channel-based speaker labels: run, see the honest status, rename/recolour, split into tracks.
struct SpeakerTools: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        DisclosureGroup("화자 구분") {
            VStack(alignment: .leading, spacing: 6) {
                Text("화자별로 채널이 나뉜 녹음에서만 구분합니다. 한 대의 기기로 녹음했다면 ‘불확실’로 표시하고 화자를 붙이지 않습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                Button("선택 클립 화자 구분") { model.separateSpeakers() }.disabled(model.selectedSpeechClips.isEmpty || model.busyDocument)
                Button("채널별로 따로 인식 · 화자별 마이크 녹음") { model.transcribeSpeakersByChannel() }.disabled(model.selectedSpeechClips.isEmpty || model.busyDocument || !model.transcriptionReady)
                if !model.speakerStatus.isEmpty { Text(model.speakerStatus).font(JH.Font.micro) }
                ForEach(model.project.sequence.speakers ?? []) { profile in SpeakerRow(model: model, profile: profile) }
                if !(model.project.sequence.speakers ?? []).isEmpty {
                    Button("화자별 자막 트랙으로 나누기") { model.splitCaptionTracksBySpeaker() }.disabled(model.busyDocument)
                }
            }.buttonStyle(.jhTool).font(JH.Font.caption)
        }.font(JH.Font.label)
    }
}

private struct SpeakerRow: View {
    @ObservedObject var model: EditorModel
    let profile: SpeakerProfile
    @State private var name = ""
    @State private var color = ""
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(nsColor: NSColor(hex: profile.colorHex))).frame(width: 10, height: 10)
            TextField("이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 90)
            TextField("RRGGBB", text: $color).textFieldStyle(.roundedBorder).frame(width: 70)
            Button("적용") { model.updateSpeaker(profile.id, name: name, colorHex: color) }
        }
        .onAppear { name = profile.name; color = profile.colorHex }
        .onChange(of: profile) { _, value in name = value.name; color = value.colorHex }
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
        self.init(calibratedRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Batch edit of the selected visible captions. Empty fields are left unchanged.
struct CaptionBatchTools: View {
    @ObservedObject var model: EditorModel
    @State private var size = ""
    @State private var color = ""
    @State private var stroke = ""
    @State private var strokeWidth = ""
    @State private var background = ""
    @State private var opacity = ""
    @State private var lines = ""
    @State private var x = ""
    @State private var y = ""
    @State private var startShift = ""
    @State private var endShift = ""
    @State private var fit = false
    var body: some View {
        DisclosureGroup("선택 자막 일괄 편집") {
            VStack(alignment: .leading, spacing: 6) {
                Text("선택 \(model.batchEditableCaptions.count)개 · 숨긴 원문·번역 트랙은 바꾸지 않습니다").font(JH.Font.micro).foregroundStyle(.secondary)
                Button("보이는 자막 모두 선택") { model.selectAllVisibleCaptions() }
                row("글자 크기", $size); row("글자색 RRGGBB", $color); row("외곽선색", $stroke); row("외곽선 두께", $strokeWidth)
                row("배경색", $background); row("배경 불투명도 0~1", $opacity); row("최대 줄 수", $lines)
                row("가로 위치 0~1", $x); row("세로 위치 0~1", $y); row("시작 이동(초)", $startShift); row("끝 이동(초)", $endShift)
                Toggle("안전 영역 안으로 자동 맞춤", isOn: $fit)
                Button("적용") { apply() }.disabled(model.batchEditableCaptions.isEmpty || model.busyDocument)
            }.buttonStyle(.jhTool).font(JH.Font.caption)
        }.font(JH.Font.label)
    }
    private func row(_ label: String, _ value: Binding<String>) -> some View {
        HStack { Text(label).font(JH.Font.micro).frame(width: 110, alignment: .leading); TextField("변경 안 함", text: value).textFieldStyle(.roundedBorder) }
    }
    private func apply() {
        func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces)) }
        func text(_ s: String) -> String? { let v = s.trimmingCharacters(in: .whitespaces); return v.isEmpty ? nil : v }
        var change = CaptionBatchChange()
        change.fontSize = number(size); change.colorHex = text(color); change.strokeHex = text(stroke); change.strokeWidth = number(strokeWidth)
        change.backgroundHex = text(background); change.backgroundOpacity = number(opacity); change.maxLines = number(lines).map { Int($0) }
        change.x = number(x); change.y = number(y)
        change.startOffset = number(startShift).map { MediaTime(seconds: $0) }; change.endOffset = number(endShift).map { MediaTime(seconds: $0) }
        model.applyCaptionBatch(change, fitSafeArea: fit)
    }
}

/// Project glossary: names/brands kept as-is, fixed translations, per-language scope, case rule.
struct GlossaryEditor: View {
    @ObservedObject var model: EditorModel
    @State private var source = ""
    @State private var target = ""
    @State private var sourceLanguage = "any"
    @State private var targetLanguage = "any"
    @State private var caseSensitive = false
    @State private var keepOriginal = false
    var body: some View {
        DisclosureGroup("프로젝트 용어집 · \(model.glossaryEntries.count)개") {
            VStack(alignment: .leading, spacing: 6) {
                Text("사람·브랜드·제품 이름은 ‘원문 그대로’로 두면 번역되지 않습니다. 프로젝트와 함께 저장되고 실행취소할 수 있습니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                ForEach(model.glossaryEntries) { entry in GlossaryRow(model: model, entry: entry) }
                TextField("원문 용어", text: $source).textFieldStyle(.roundedBorder)
                TextField(keepOriginal ? "원문 그대로 유지" : "번역할 용어", text: $target).textFieldStyle(.roundedBorder).disabled(keepOriginal)
                HStack {
                    languagePicker("원문", $sourceLanguage)
                    languagePicker("번역", $targetLanguage)
                }
                Toggle("원문 그대로 · 이름/브랜드 보호", isOn: $keepOriginal)
                Toggle("대소문자 구분", isOn: $caseSensitive)
                Button("용어 추가") {
                    model.addGlossaryEntry(GlossaryEntry(source: source.trimmingCharacters(in: .whitespaces), target: keepOriginal ? "" : target.trimmingCharacters(in: .whitespaces),
                                                         sourceLanguage: sourceLanguage == "any" ? nil : sourceLanguage, targetLanguage: targetLanguage == "any" ? nil : targetLanguage,
                                                         caseSensitive: caseSensitive, protected: keepOriginal))
                    source = ""; target = ""
                }.disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || (!keepOriginal && target.trimmingCharacters(in: .whitespaces).isEmpty) || model.busyDocument)
                if !model.translationGlossaryText.isEmpty {
                    Button("빠른 용어집 줄을 프로젝트 용어집으로 옮기기") { model.importQuickGlossary() }.disabled(model.busyDocument)
                }
            }
        }
    }
    private func languagePicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("모든 언어").tag("any")
            ForEach(CaptionLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
        }
    }
}

struct GlossaryRow: View {
    @ObservedObject var model: EditorModel
    let entry: GlossaryEntry
    var body: some View {
        HStack(spacing: 6) {
            Text(summary).font(JH.Font.micro).lineLimit(2)
            Spacer()
            Button("삭제") { model.removeGlossaryEntry(entry.id) }.font(JH.Font.micro).disabled(model.busyDocument)
        }
    }
    private var summary: String {
        let scope = [entry.sourceLanguage, entry.targetLanguage].map { $0.flatMap { CaptionLanguage(rawValue: $0)?.label } ?? "모든 언어" }.joined(separator: "→")
        let result = entry.keepsSource ? "원문 그대로" : entry.target
        return "\(entry.source) → \(result) · \(scope)" + (entry.caseSensitive ? " · 대소문자 구분" : "")
    }
}

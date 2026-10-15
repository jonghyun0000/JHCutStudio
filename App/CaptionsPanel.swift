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
    @State private var reviewFilter = "all"
    @State private var roleFilter = "all"
    @State private var showHidden = false
    @State private var splitPosition = ""
    @State private var reports: [UUID: CaptionReadabilityReport] = [:]
    @State private var overlapIDs: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("자막과 타이틀").font(JH.Font.sectionTitle); Spacer(); Button { model.addTitle() } label: { Image(systemName: "plus") }
            .buttonStyle(.jhTool).jhIconLabel("자막 추가", hint: "새 제목 클립을 타임라인에 추가합니다") }
            .padding(.top, JH.Space.m)
            HStack {
                Button("SRT 가져오기") { model.importSRT() }
                Button("SRT 저장") { model.exportSRT() }.disabled(model.captionClips.isEmpty)
            }.buttonStyle(.jhTool).font(JH.Font.caption)
            Picker("작업 범위", selection: $model.captionOperationScope) {
                Text("모든 자막").tag("all"); Text("선택한 자막").tag("selection")
                Text("선택 원본의 자막").tag("source"); Text("특정 자막 그룹").tag("group")
            }.font(JH.Font.caption)
            if model.captionOperationScope == "group" {
                let entries = CaptionQuery.entries(in: model.project.sequence)
                let groups = Array(Set(entries.map(\.groupID))).sorted { $0.uuidString < $1.uuidString }
                Picker("자막 그룹", selection: $model.captionSelectedGroupID) {
                    Text("선택한 자막의 그룹").tag(Optional<UUID>.none)
                    ForEach(groups, id: \.self) { group in
                        Text(entries.first(where: { $0.groupID == group })?.clip.title?.text.prefix(24).description ?? "자막 그룹").tag(Optional(group))
                    }
                }.font(JH.Font.caption)
            }
            if let clip = model.selected?.1, clip.title != nil {
                HStack {
                    Text(CaptionQuery.role(of: clip)?.label ?? "미분류 제목").font(JH.Font.micro)
                    Button("원문으로 지정") { model.setSelectedCaptionRole(.original) }
                    Button("제목으로 지정") { model.setSelectedCaptionRole(.title) }
                }.buttonStyle(.jhTool).font(JH.Font.micro)
            }
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
                Toggle("작업 범위의 보이는 자막에 스타일 적용", isOn: $allCaptions).font(JH.Font.caption)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        reviewControls
                        editingTools
                        if !captionWarnings.isEmpty {
                            DisclosureGroup("범위의 배치 경고") { Text(captionWarnings).font(JH.Font.micro).foregroundStyle(JH.Palette.warning).fixedSize(horizontal: false, vertical: true) }.font(JH.Font.micro)
                        }
                        captionList
                        Text("숨김·잠금은 읽기 전용, 장식 제목은 제외합니다. 직접 입력한 줄바꿈을 보존하고 자동 줄바꿈은 출력에만 적용합니다.").font(JH.Font.micro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

            }
        }.padding(.horizontal, 12)
            .onAppear { updateWarnings() }
            .onChange(of: model.project.sequence.tracks) { updateWarnings() }
            .onChange(of: model.project.sequence.width) { updateWarnings() }
            .onChange(of: model.project.sequence.height) { updateWarnings() }
            .onChange(of: model.currentCaptionScope) { updateWarnings() }
            .sheet(item: $model.captionEditProposal) { proposal in CaptionProposalSheet(model: model, proposal: proposal) }
            .onChange(of: model.transcriptionActive) { _, active in
                if !active, model.transcriptionProgress == 1 { mode = "자막 목록"; query = "" }
            }
    }
    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("이전") { model.seekNextCaptionForReview(-1, ids: listEntries.map { $0.clip.id }) }; Button("다음") { model.seekNextCaptionForReview(1, ids: listEntries.map { $0.clip.id }) }
                Button("반복 듣기") { model.loopSelection() }; Toggle("반복", isOn: $model.loopEnabled)
            }.font(JH.Font.micro)
            DisclosureGroup("검수 필터 · \(reviewFilter == "all" ? "전체" : "필터 적용 중")") {
                Picker("목록 역할", selection: $roleFilter) {
                    Text("원문과 번역").tag("all"); Text("원문").tag("original"); Text("번역").tag("translation")
                }.font(JH.Font.micro)
                Picker("검수 필터", selection: $reviewFilter) {
                    Text("전체").tag("all"); Text("미검수 / 편집 후 재검수").tag("pending")
                    Text("배치·줄 수").tag("layout"); Text("빠르거나 짧음").tag("reading")
                    Text("언어 불확실").tag("language"); Text("번역 갱신 필요").tag("translation")
                    Text("화자 미확정").tag("speaker"); Text("화면에서 겹침").tag("overlap"); Text("검수 표시됨").tag("reviewed")
                }.font(JH.Font.micro)
                Toggle("숨긴 자막도 읽기 전용으로 보기", isOn: $showHidden).font(JH.Font.micro)
            }.font(JH.Font.micro)
        }
    }
    private var listEntries: [CaptionEntry] {
        CaptionQuery.entries(in: model.project.sequence, scope: model.currentCaptionScope).filter { entry in
            let clip = entry.clip
            guard (showHidden || entry.isVisible), roleFilter == "all" || entry.role.rawValue == roleFilter,
                  query.isEmpty || (clip.title?.text ?? "").localizedCaseInsensitiveContains(query) else { return false }
            if reviewFilter == "all" { return true }
            if reviewFilter == "overlap" { return overlapIDs.contains(clip.id) }
            return model.captionReviewFlags(clip, report: reports[clip.id]).contains(reviewFilter)
        }
    }
    private var captionList: some View {
        LazyVStack(spacing: 7) {
            if listEntries.isEmpty { Text("현재 범위·검색·필터에 해당하는 자막이 없습니다.").font(JH.Font.caption).foregroundStyle(.secondary).padding(.vertical, 20) }
            ForEach(listEntries, id: \.clip.id) { entry in
                CaptionReviewRow(model: model, entry: entry, report: reports[entry.clip.id], overlapping: overlapIDs.contains(entry.clip.id))
            }
        }
    }
    private var editingTools: some View {
        DisclosureGroup("찾아 바꾸기 · 문구 분할 · 시간 이동") {
            VStack(alignment: .leading, spacing: 8) {
                Text("목록 필터는 보기만 바꿉니다. 교정·시간 이동은 작업 범위의 보이는 잠금 해제 자막에 적용합니다.").font(JH.Font.micro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("바꿀 문구", text: $replacement).textFieldStyle(.roundedBorder)
                    Button("교정 미리보기") { model.replaceCaptionText(find: query, replacement: replacement, preview: true) }.disabled(query.isEmpty || model.busyDocument)
                }.font(JH.Font.micro)
                HStack {
                    TextField("앞 문구의 문자 수", text: $splitPosition).textFieldStyle(.roundedBorder)
                    Button("문구 분할 미리보기") {
                        guard let count = Int(splitPosition) else { model.error = "앞 문구의 문자 수를 정수로 입력하세요."; return }
                        model.previewCaptionSplit(characterOffset: count)
                    }.disabled(model.selected?.1.title == nil || model.busyDocument)
                }.font(JH.Font.micro)
                Text("타임라인 재생 위치에서 시간을 나눕니다. 문자 수는 이모지와 결합문자를 한 글자로 셉니다.").font(JH.Font.micro).foregroundStyle(.secondary)
                Button("다음 자막과 합치기 미리보기") { model.mergeNextCaption(preview: true) }.disabled(model.selected?.1.title == nil || model.busyDocument)
                HStack {
                    TextField("이동 초 · ±", text: $offset).textFieldStyle(.roundedBorder)
                    Button("시간 이동 미리보기") {
                        if let seconds = Double(offset) { model.offsetCaptions(seconds, preview: true) } else { model.error = "이동 시간을 숫자로 입력하세요." }
                    }.disabled(model.busyDocument)
                }.font(JH.Font.micro)
            }.buttonStyle(.jhTool)
        }.font(JH.Font.caption)
    }
    private func updateWarnings() {
        let entries = CaptionQuery.entries(in: model.project.sequence, scope: model.currentCaptionScope)
        let w = model.project.sequence.width, h = model.project.sequence.height
        reports = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            (try? CaptionReadability.assess(entry.clip, width: w, height: h)).map { (entry.clip.id, $0) }
        })
        let visible = entries.filter(\.isVisible).sorted { $0.clip.start < $1.clip.start }
        var overlaps: Set<UUID> = []
        for i in visible.indices {
            guard let a = reports[visible[i].clip.id]?.fullBounds else { continue }
            var j = i + 1
            while j < visible.count, visible[j].clip.start < visible[i].clip.end {
                if let b = reports[visible[j].clip.id]?.fullBounds, a.intersects(b) {
                    overlaps.insert(visible[i].clip.id); overlaps.insert(visible[j].clip.id)
                }
                j += 1
            }
        }
        overlapIDs = overlaps
        let outside = visible.filter { reports[$0.clip.id]?.outsideCanvas == true }.count
        let lineLimit = visible.filter { reports[$0.clip.id]?.exceedsLineLimit == true }.count
        captionWarnings = [outside > 0 ? "화면 밖에서 잘리는 자막 \(outside)개 · 출력 전에 배치를 수정하세요" : "", lineLimit > 0 ? "목표 줄 수 초과 \(lineLimit)개 · 전체 문구는 보존합니다" : "", !overlaps.isEmpty ? "화면에서 겹치는 자막이 있습니다. 중첩 필터로 확인하세요." : ""].filter { !$0.isEmpty }.joined(separator: "\n")
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
    let editable: Bool
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text).font(JH.Font.caption).frame(minHeight: 60, maxHeight: 100)
                .accessibilityLabel("자막 문구 편집").disabled(!editable)
                .onAppear { text = clip.title?.text ?? "" }
                .onChange(of: clip.title?.text) { _, value in text = value ?? "" }
            if editable {
                if text != clip.title?.text { Text("미적용 문구 · 적용 후 검수 표시를 남길 수 있습니다").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                HStack {
                    Button("문구 적용") { NSApp.keyWindow?.makeFirstResponder(nil); model.updateCaption(clip.id, text: text) }.disabled(text == clip.title?.text || model.busyDocument)
                    Button("입력 취소") { text = clip.title?.text ?? "" }.disabled(text == clip.title?.text)
                    Text("Enter는 줄바꿈 · 적용 버튼으로 저장").foregroundStyle(.secondary)
                }.font(JH.Font.micro)
            }
        }
    }
}

private struct CaptionReviewRow: View {
    @ObservedObject var model: EditorModel
    let entry: CaptionEntry
    let report: CaptionReadabilityReport?
    let overlapping: Bool
    @State private var text = ""
    private var clip: Clip { entry.clip }
    private var editable: Bool { entry.isVisible && !entry.track.isLocked }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.role.label).font(JH.Font.micro)
                if !entry.isVisible { Text("숨김 · 읽기 전용").font(JH.Font.micro).foregroundStyle(.secondary) }
                if entry.track.isLocked { Text("잠금 · 읽기 전용").font(JH.Font.micro).foregroundStyle(.secondary) }
                Spacer()
                Text(CaptionReview.isReviewed(clip) ? "검수 표시됨" : "미검수 / 재검수").font(JH.Font.micro)
            }
            CaptionInlineEditor(model: model, clip: clip, editable: editable, text: $text)
            if let info = clip.captionMetadata { CaptionLanguageBadge(model: model, clipID: clip.id, info: info).disabled(!editable || model.busyDocument) }
            if let report { ForEach(report.warnings, id: \.self) { Text($0).font(JH.Font.micro).foregroundStyle(JH.Palette.warning) } }
            if overlapping { Text("다른 자막과 화면에서 겹침 · 두 언어/화자의 배치를 확인하세요").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
            if model.repetitionCaptionIDs.contains(clip.id) { Text("반복 인식 의심 · 원음을 듣고 검토하세요").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
            if let kind = model.silentCaptionWarnings[clip.id] { Text("\(kind.label) 구간 위 자막").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
            if entry.role == .translation {
                if let source = model.captionOriginal(for: clip) {
                    DisclosureGroup("원문 비교") {
                        Text(source.title?.text ?? "").font(JH.Font.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("원문 위치로 이동") { model.seekCaptionOriginal(clip) }.font(JH.Font.micro)
                        if let link = source.connection { Text("원본 파일 \(String(format: "%.3f", link.sourceStart.seconds))초 · 타임라인 \(String(format: "%.3f", source.start.seconds))초").font(JH.Font.micro).foregroundStyle(.secondary) }
                    }.font(JH.Font.micro)
                } else { Text("원문 연결 미확정 · 자동 비교할 수 없습니다").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
            }
            HStack {
                Button { model.seekCaptionForReview(clip) } label: { Text(timecode(clip.start.seconds, fps: model.fps) + " → " + timecode(clip.end.seconds, fps: model.fps)).font(JH.Font.numeric(9)) }
                    .buttonStyle(.plain).accessibilityLabel("자막 구간으로 이동 · 재생 정지")
                Spacer()
                Button(CaptionReview.isReviewed(clip) ? "검수 표시 해제" : "검수 완료 표시") { model.markCaptionReviewed(clip.id, reviewed: !CaptionReview.isReviewed(clip)) }.font(JH.Font.micro).disabled(!editable || model.busyDocument || text != clip.title?.text)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(model.selectedClipID == clip.id ? JH.Palette.accent.opacity(0.16) : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: JH.Radius.chip, style: .continuous))
    }
}

private struct CaptionProposalSheet: View {
    @ObservedObject var model: EditorModel
    let proposal: CaptionEditProposal
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposal.label + " · 변경 미리보기").font(.headline)
            Text("\(proposal.changes.count)개 클립의 변경을 확인하세요. 줄바꿈을 보존하며 적용 후 ⌘Z 한 번으로 되돌립니다.").font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(proposal.changes) { change in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("변경 전").font(.caption.bold())
                            Text(change.before?.title?.text ?? "새 클립").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let before = change.before { Text(String(format:"%.3f → %.3f초", before.start.seconds,before.end.seconds)).font(.caption.monospacedDigit()) }
                            Text("변경 후").font(.caption.bold())
                            Text(change.after?.title?.text ?? "클립 삭제 · 합쳐진 문구를 확인하세요").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let after = change.after { Text(String(format:"%.3f → %.3f초", after.start.seconds,after.end.seconds)).font(.caption.monospacedDigit()) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.white.opacity(0.04)).cornerRadius(8)
                    }
                }
            }
            HStack { Spacer(); Button("취소") { model.captionEditProposal = nil }; Button("확인한 변경 적용") {
                let documentWindow = NSApp.keyWindow?.sheetParent
                if model.applyCaptionProposal() { documentWindow?.makeFirstResponder(nil) }
            }.disabled(model.busyDocument) }
        }.padding(20).frame(width: 700, height: 580)
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
        if info.translatedFrom != nil, let clip = model.captionClips.first(where: { $0.id == clipID }) {
            Text(model.translationFreshness(clip).label).font(JH.Font.micro).foregroundStyle(model.translationFreshness(clip) == .current ? .secondary : JH.Palette.warning)
            if CaptionTranslationTracking.isManual(clip) {
                if let source = CaptionTranslationTracking.source(for: clip, in: model.project.sequence), source.title?.text != info.originalText { Text("원문도 변경됨 · 수동 문구 유지").font(JH.Font.micro).foregroundStyle(JH.Palette.warning) }
                Button("이 번역 새로 생성 · ⌘Z로 복원") { model.regenerateManualTranslation(clipID) }.font(JH.Font.micro).disabled(model.busyDocument)
            }
        }
        if info.translatedFrom != nil { Text("생성 당시 원문: " + info.originalText).font(JH.Font.micro).foregroundStyle(.secondary).lineLimit(2) }
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
        if info.languageOrigin == .audioProbe {return name + " 원문 · 음성 분석 추정"}
        if info.languageOrigin == .text {return name + " 원문 · 문구로 판단"}
        if info.languageOrigin == .recognizerWindow {return name + " 원문 · 구간 언어 추정"}
        return name + " 원문"
    }
}

/// Channel-based speaker labels: run, see the honest status, rename/recolour, split into tracks.
struct SpeakerTools: View {
    @ObservedObject var model: EditorModel
    @State private var newSpeakerName = ""
    var body: some View {
        DisclosureGroup("화자 구분") {
            VStack(alignment: .leading, spacing: 6) {
                Text("채널 분리는 목소리 인식이 아닙니다. 음악·동시 발화는 확인이 필요하며, 모노 녹음은 아래에서 직접 화자를 지정하세요.").font(JH.Font.micro).foregroundStyle(.secondary)
                Toggle("이 원본은 음악 채널 없이 화자별 마이크가 다른 채널에 연결됨", isOn: Binding(get: { model.channelSpeakerMappingConfirmed }, set: { model.channelSpeakerMappingConfirmed = $0 })).disabled(model.selectedSpeechClips.isEmpty || model.busyDocument)
                Button("선택 클립 화자 구분") { model.separateSpeakers() }.disabled(model.selectedSpeechClips.isEmpty || model.busyDocument)
                Button("채널별로 따로 인식 · 화자별 마이크 녹음") { model.transcribeSpeakersByChannel() }.disabled(model.selectedSpeechClips.isEmpty || model.busyDocument || !model.transcriptionReady)
                if !model.speakerStatus.isEmpty { Text(model.speakerStatus).font(JH.Font.micro) }
                HStack {
                    TextField("새 화자 이름", text: $newSpeakerName).textFieldStyle(.roundedBorder)
                    Button("선택 자막에 지정") { model.createSpeakerForSelection(name: newSpeakerName) }.disabled(model.speakerSelectedOriginals.isEmpty || model.busyDocument || newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("선택 자막 화자 해제 · 자동 재분석에서 보존") { model.assignSpeakerToSelected(nil) }.disabled(model.speakerSelectedOriginals.isEmpty || model.busyDocument)
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
    @State private var mergeTarget = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        let sourceID = SpeakerIdentity.sourceID(profile.id)
        Text("원본: " + (model.project.assets.first { $0.id == sourceID }?.name ?? "원본 연결 확인 필요") + (SpeakerIdentity.channelIndex(profile.id).map { " · 채널 \($0 + 1)" } ?? " · 수동 화자"))
            .font(JH.Font.micro).foregroundStyle(.secondary)
        HStack(spacing: 6) {
            Circle().fill(Color(nsColor: NSColor(hex: profile.colorHex))).frame(width: 10, height: 10)
            TextField("이름", text: $name).textFieldStyle(.roundedBorder).frame(width: 90)
            TextField("RRGGBB", text: $color).textFieldStyle(.roundedBorder).frame(width: 70)
            Button("적용") { model.updateSpeaker(profile.id, name: name, colorHex: color) }
        }
        HStack {
            Button("선택 자막에 이 화자 지정") { model.assignSpeakerToSelected(profile.id) }.disabled(model.speakerSelectedOriginals.isEmpty || model.busyDocument)
            Picker("합칠 대상", selection: $mergeTarget) {
                Text("같은 원본 화자 선택").tag("")
                ForEach((model.project.sequence.speakers ?? []).filter { $0.id != profile.id && SpeakerIdentity.sourceID($0.id) == SpeakerIdentity.sourceID(profile.id) }) { Text($0.name).tag($0.id) }
            }.labelsHidden()
            Button("합치기") { model.mergeSpeakers(profile.id, into: mergeTarget); mergeTarget = "" }.disabled(mergeTarget.isEmpty || model.busyDocument)
        }
        }.disabled(model.busyDocument)
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
                row("배경색", $background); row("배경 불투명도 0~1", $opacity); row("목표 줄 수", $lines)
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

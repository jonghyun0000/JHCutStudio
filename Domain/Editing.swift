import Foundation

public struct ProjectError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProjectValidator {
    public static func validate(_ project: Project) throws {
        guard project.schemaVersion == 1 else { throw ProjectError("지원하지 않는 프로젝트 버전입니다: \(project.schemaVersion)") }
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("프로젝트 이름이 비어 있습니다.") }
        let sequence = project.sequence
        guard sequence.width > 0, sequence.height > 0, sequence.width <= 16_384, sequence.height <= 16_384 else { throw ProjectError("영상 크기가 허용 범위를 벗어났습니다.") }
        guard sequence.colorSpace == "Rec.709" else { throw ProjectError("현재 게이트는 SDR Rec.709 시퀀스만 지원합니다.") }
        guard Set(project.assets.map(\.id)).count == project.assets.count else { throw ProjectError("중복된 미디어 ID입니다.") }
        guard Set(sequence.tracks.map(\.id)).count == sequence.tracks.count else { throw ProjectError("중복된 트랙 ID입니다.") }
        let versions = project.derivedSequences ?? []
        guard Set(([sequence] + versions).map(\.id)).count == versions.count + 1 else { throw ProjectError("중복된 시퀀스 버전 ID입니다.") }
        for version in versions {
            var stored = project; stored.sequence = version; stored.derivedSequences = nil
            try validate(stored)
        }
        guard Set((sequence.speakers ?? []).map(\.id)).count == (sequence.speakers ?? []).count else { throw ProjectError("중복된 화자 ID입니다.") }
        for profile in sequence.speakers ?? [] {
            guard SpeakerIdentity.isValid(profile.id), !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isHex(profile.colorHex) else { throw ProjectError("화자 ID·이름·색상이 올바르지 않습니다.") }
        }
        try ConnectionEditing.validate(sequence)
        let assets = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        for asset in project.assets {
            guard asset.duration >= .zero, asset.width >= 0, asset.height >= 0 else { throw ProjectError("미디어 메타데이터가 올바르지 않습니다: \(asset.name)") }
            guard !asset.path.isEmpty else { throw ProjectError("미디어 경로가 비어 있습니다: \(asset.name)") }
        }
        var clipIDs = Set<UUID>()
        for track in sequence.tracks {
            for clip in track.clips {
                guard clipIDs.insert(clip.id).inserted else { throw ProjectError("중복된 클립 ID입니다.") }
                guard clip.start >= .zero, clip.sourceStart >= .zero, clip.duration > .zero else { throw ProjectError("클립 위치와 원본 시작은 0 이상, 길이는 0보다 커야 합니다: \(clip.name)") }
                _ = try clip.start.adding(clip.duration)
                let rate = clip.playbackRate ?? PlaybackRate()
                guard rate.numerator > 0, rate.denominator > 0, rate.multiplier.isFinite, (0.25...4).contains(rate.multiplier) else { throw ProjectError("재생 속도는 0.25~4배 범위여야 합니다.") }
                let sourceDuration = try clip.duration.scaled(numerator: rate.numerator, denominator: rate.denominator)
                let sourceEnd = try clip.sourceStart.adding(sourceDuration)
                if clip.captionRole != nil || clip.captionGroupID != nil || clip.captionHidden != nil {
                    guard clip.title != nil else { throw ProjectError("자막 역할·표시는 제목 클립에만 저장할 수 있습니다.") }
                    if clip.captionRole == .translation { guard clip.captionMetadata?.translatedFrom != nil else { throw ProjectError("번역 자막의 원문 연결이 없습니다.") } }
                    if clip.captionRole == .title { guard clip.captionGroupID == nil, clip.captionHidden != true else { throw ProjectError("일반 제목에는 자막 그룹·표시 전환을 적용할 수 없습니다.") } }
                }
                if let speaker = clip.captionMetadata?.speaker {
                    guard SpeakerIdentity.isValid(speaker) else { throw ProjectError("자막 화자 ID가 올바르지 않습니다.") }
                    if let scope = SpeakerIdentity.sourceID(speaker), let parent = clip.connection?.parentID, let sourceAsset = sequence.tracks.flatMap(\.clips).first(where: { $0.id == parent })?.assetID {
                        guard scope == sourceAsset else { throw ProjectError("자막 화자가 다른 원본에 연결되어 있습니다.") }
                    }
                }
                if let digest = clip.captionMetadata?.reviewDigest {
                    guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProjectError("자막 검수 이력이 올바르지 않습니다.") }
                }
                if let evidence = clip.captionMetadata?.languageEvidence {
                    guard evidence.count <= 8,evidence.allSatisfy(\.isValid) else {throw ProjectError("자막 언어 판단 근거가 올바르지 않습니다.")}
                }
                if let revision = clip.captionMetadata?.translationRevision {
                    guard revision.isValid, CaptionQuery.role(of: clip) == .translation, clip.captionMetadata?.translatedFrom == revision.sourceCaptionID else { throw ProjectError("번역 생성 이력 또는 원문 ID가 올바르지 않습니다.") }
                }
                guard clip.volume.isFinite, clip.volume >= 0, clip.volume <= 4 else { throw ProjectError("볼륨은 0~4 범위여야 합니다.") }
                if clip.blendMode != nil {
                    guard track.kind != .audio, clip.title != nil || clip.assetID.flatMap({ assets[$0]?.kind }) != .audio else {
                        throw ProjectError("블렌드 모드는 영상·이미지·제목 클립에만 쓸 수 있습니다.")
                    }
                }
                let transform = clip.transform
                guard [transform.x, transform.y, transform.scale, transform.rotation, transform.opacity].allSatisfy(\.isFinite), transform.scale > 0, (0...1).contains(transform.opacity) else { throw ProjectError("클립의 위치·크기·회전·불투명도가 올바르지 않습니다.") }
                try validateEnvelope(clip.fadeIn, clip.fadeOut, duration: clip.duration)
                try validateEnvelope(clip.audioFadeIn, clip.audioFadeOut, duration: clip.duration)
                if let visual = clip.visual {
                    if let key = visual.chromaKey {
                        if let problem = key.validationProblem { throw ProjectError(problem) }
                        guard clip.title == nil, track.kind != .audio,
                              let assetID = clip.assetID, let asset = assets[assetID], asset.kind != .audio else {
                            throw ProjectError("선택 색 크로마키는 영상·이미지 클립에만 쓸 수 있습니다.")
                        }
                        guard visual.greenScreen == nil else { throw ProjectError("기존 그린스크린과 선택 색 크로마키를 동시에 저장할 수 없습니다.") }
                    }
                    if let mask = visual.shapeMask {
                        if let problem = mask.validationProblem { throw ProjectError(problem) }
                        guard clip.title == nil, track.kind != .audio,
                              let assetID = clip.assetID, let asset = assets[assetID], asset.kind != .audio else {
                            throw ProjectError("도형 마스크는 영상·이미지 클립에만 쓸 수 있습니다.")
                        }
                        guard visual.ellipseMask != true else { throw ProjectError("기존 타원과 새 도형 마스크를 동시에 적용할 수 없습니다.") }
                    }
                    for (value, range) in [(visual.temperature, 2000.0...12000.0), (visual.tint, -100.0...100.0), (visual.shadows, -0.2...0.2), (visual.highlights, -0.2...0.2), (visual.greenScreen, 0.0...1.0)] {
                        if let value { guard value.isFinite, range.contains(value) else { throw ProjectError("색 보정 값이 범위를 벗어났습니다.") } }
                    }
                    if let lut = visual.lut {
                        guard (2...33).contains(lut.size), lut.values.count == lut.size * lut.size * lut.size * 4, lut.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ProjectError("LUT 데이터가 올바르지 않습니다.") }
                    }
                    let crops = [visual.cropLeft, visual.cropRight, visual.cropTop, visual.cropBottom]
                    guard [visual.exposure, visual.contrast, visual.saturation].allSatisfy(\.isFinite), (-4...4).contains(visual.exposure), (0...4).contains(visual.contrast), (0...4).contains(visual.saturation), crops.allSatisfy({ $0.isFinite && (0..<1).contains($0) }), visual.cropLeft + visual.cropRight < 1, visual.cropTop + visual.cropBottom < 1 else { throw ProjectError("노출은 -4~4, 대비·채도는 0~4, 크롭은 각 축의 합이 1 미만이어야 합니다.") }
                }
                if let stabilization = clip.stabilization {
                    if let problem = stabilization.validationProblem { throw ProjectError(problem) }
                    guard clip.title == nil, clip.assetID != nil else { throw ProjectError("손떨림 보정은 영상 클립에만 저장할 수 있습니다.") }
                }
                if let transition = clip.transition {
                    guard clip.title == nil, transition.duration > .zero, transition.offset != nil || transition.duration < clip.duration else { throw ProjectError("전환 길이는 클립보다 짧아야 하며 제목에는 쓸 수 없습니다.") }
                }
                for fade in clip.transitionAudioFades ?? [] {
                    guard fade.duration > .zero else { throw ProjectError("전환 오디오 길이가 올바르지 않습니다.") }
                    var previous: MediaTime?
                    for point in fade.points ?? [] {
                        guard point.gain.isFinite, (0...1).contains(point.gain), previous.map({ $0 < point.time }) ?? true else { throw ProjectError("전환 오디오의 시간·게인이 올바르지 않습니다.") }; previous = point.time
                    }
                }
                if let animation = clip.titleAnimation {
                    guard clip.title != nil else { throw ProjectError("글자 애니메이션은 자막·제목 클립에만 쓸 수 있습니다.") }
                    if let problem = animation.validationProblem(clipDuration: clip.duration) { throw ProjectError(problem) }
                }
                var previousTime: MediaTime?
                for frame in clip.keyframes ?? [] {
                    let t = frame.transform
                    guard frame.time >= .zero, frame.time <= clip.duration, previousTime.map({ $0 < frame.time }) ?? true else { throw ProjectError("키프레임 시간은 클립 안에서 중복 없이 오름차순이어야 합니다.") }
                    guard [t.x,t.y,t.scale,t.rotation,t.opacity,frame.volume].allSatisfy(\.isFinite), t.scale > 0, (0...1).contains(t.opacity), (0...4).contains(frame.volume) else { throw ProjectError("키프레임 속성이 올바르지 않습니다.") }
                    previousTime = frame.time
                }
                if let title = clip.title {
                    guard track.kind == .title, clip.assetID == nil, clip.sourceStart == .zero else { throw ProjectError("제목은 제목 트랙의 독립 클립이어야 합니다.") }
                    guard title.fontSize.isFinite, title.fontSize > 0, title.x.isFinite, title.y.isFinite, (0...1).contains(title.x), (0...1).contains(title.y) else { throw ProjectError("제목의 크기와 위치가 올바르지 않습니다.") }
                    let hex = title.colorHex.hasPrefix("#") ? String(title.colorHex.dropFirst()) : title.colorHex
                    guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw ProjectError("제목 색상은 6자리 RGB 값이어야 합니다.") }
                    if let style = title.style {
                        if let wrap = style.wrapWidthFraction { guard wrap.isFinite && (0.1...1).contains(wrap) else { throw ProjectError("줄바꿈 너비는 화면의 10~100%입니다.") } }
                        guard isHex(style.strokeHex), isHex(style.backgroundHex), [style.strokeWidth,style.backgroundOpacity,style.padding,style.lineSpacing].allSatisfy(\.isFinite), (0...50).contains(style.strokeWidth), (0...1).contains(style.backgroundOpacity), (0...500).contains(style.padding), (0...300).contains(style.lineSpacing), (0...20).contains(style.maxLines) else { throw ProjectError("제목 스타일의 색상·외곽선·배경·여백·줄 수를 확인하세요.") }
                    }
                    guard rate.numerator == rate.denominator else { throw ProjectError("제목은 재생 속도 대신 길이를 편집하세요.") }
                } else {
                    guard let assetID = clip.assetID, let asset = assets[assetID] else { throw ProjectError("클립이 존재하지 않는 미디어를 참조합니다: \(clip.name)") }
                    guard asset.supported else { throw ProjectError(asset.issue ?? "지원하지 않는 미디어입니다: \(asset.name)") }
                    switch track.kind {
                    case .title: throw ProjectError("제목 트랙에는 제목 클립만 배치할 수 있습니다.")
                    case .audio:
                        guard asset.kind == .audio || (asset.kind == .video && asset.hasAudio) else { throw ProjectError("오디오가 있는 미디어가 필요합니다.") }
                    case .video, .overlay:
                        guard asset.kind != .audio else { throw ProjectError("영상 트랙에는 영상 또는 이미지를 배치하세요.") }
                    }
                    if asset.kind == .image {
                        guard clip.sourceStart == .zero else { throw ProjectError("정지 이미지의 원본 시작은 0이어야 합니다.") }
                        guard rate.numerator == rate.denominator else { throw ProjectError("정지 이미지는 재생 속도 대신 길이를 편집하세요.") }
                    } else {
                        guard sourceEnd <= asset.duration else { throw ProjectError("클립이 원본 길이를 초과합니다: \(clip.name)") }
                    }
                }
            }
            if track.kind == .video {
                let clips = track.clips.sorted { $0.start < $1.start }
                for index in 1..<max(clips.count, 1) {
                    guard clips[index - 1].end <= clips[index].start else { throw ProjectError("메인 영상 클립은 겹칠 수 없습니다. 오버레이 트랙을 사용하세요.") }
                }
            }
        }
        try TransitionEditing.validate(sequence)
    }
    private static func isHex(_ value: String) -> Bool {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        return hex.count == 6 && hex.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    private static func validateEnvelope(_ fadeIn: MediaTime?, _ fadeOut: MediaTime?, duration: MediaTime) throws {
        let first = fadeIn ?? .zero, last = fadeOut ?? .zero
        guard first >= .zero, last >= .zero, first <= duration, last <= duration, try first.adding(last) <= duration else { throw ProjectError("페이드 길이는 음수가 될 수 없고, 앞뒤 페이드의 합은 클립 길이 이하여야 합니다.") }
    }
}

public indirect enum EditCommand {
    case batch([EditCommand])
    case addAsset(MediaAsset)
    case replaceAsset(MediaAsset)
    case replaceSequence(Sequence)
    case addTrack(Track)
    case removeTrack(UUID)
    case duplicate(trackID: UUID, clipID: UUID)
    case setRate(trackID: UUID, clipID: UUID, rate: PlaybackRate)
    /// Cuts the clip into `rates.count` equal source pieces and gives each its own speed (a stepped ramp).
    case speedRamp(trackID: UUID, clipID: UUID, rates: [PlaybackRate], mutesAudio: Bool)
    case deriveSequence(name: String, width: Int, height: Int)
    case activateDerivedSequence(UUID)
    case addIndependentSequence(Sequence)
    case addClip(trackID: UUID, clip: Clip)
    case updateClip(trackID: UUID, clip: Clip)
    case crossDissolve(trackID: UUID, clipID: UUID, duration: MediaTime)
    /// Same overlap as `crossDissolve`, with a chosen kind (and side, for wipe/slide/push).
    case addTransition(trackID: UUID, clipID: UUID, kind: TransitionKind, direction: TransitionDirection, duration: MediaTime)
    case updateTransition(trackID: UUID, kind: TransitionKind, direction: TransitionDirection, duration: MediaTime)
    case changeTransitionAppearance(trackID: UUID, kind: TransitionKind, direction: TransitionDirection)
    case removeTransition(trackID: UUID)
    case separateAudio(trackID: UUID, clipID: UUID, destinationTrackID: UUID? = nil)
    case insertClip(trackID: UUID, clip: Clip, at: MediaTime)
    case overwriteClip(trackID: UUID, clip: Clip, at: MediaTime)
    case trimClip(trackID: UUID, clipID: UUID, newStart: MediaTime, newSourceStart: MediaTime, newDuration: MediaTime)
    case split(trackID: UUID, clipID: UUID, at: MediaTime)
    /// Ripple scope is the selected track only; clips starting at/after the removed end move left.
    case delete(trackID: UUID, clipID: UUID, ripple: Bool)
    case move(trackID: UUID, clipID: UUID, to: MediaTime)
    /// Exchange adjacent chronological clips, preserving their surrounding span and inter-clip gap.
    case reorder(trackID: UUID, clipID: UUID, direction: Int)
    case updateTrack(Track)
    case rename(String)
    case replaceGlossary([GlossaryEntry])
}

public struct EditorHistory {
    public private(set) var project: Project
    private struct Snapshot {
        let project: Project
        let logicalBytes: Int
        init(_ project: Project) {
            self.project = project; logicalBytes = HistoryMemoryCounter.standalone(project)
        }
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    public let budget: HistoryBudget
    public private(set) var memoryUsage = HistoryMemoryUsage()
    public var undoEstimatedBytes: Int { memoryUsage.undoLogicalBytes }
    public var redoEstimatedBytes: Int { memoryUsage.redoLogicalBytes }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public init(project: Project, budget: HistoryBudget = HistoryBudget()) {
        self.project = project
        self.budget = HistoryBudget(snapshotLimit: budget.snapshotLimit, estimatedByteLimit: budget.estimatedByteLimit)
        refreshMemoryUsage()
    }
    private mutating func refreshMemoryUsage() {
        var counter = HistoryMemoryCounter(); counter.project(project)
        let current = counter.bytes
        for snapshot in undoStack { counter.project(snapshot.project) }
        for snapshot in redoStack { counter.project(snapshot.project) }
        memoryUsage.undoCount = undoStack.count; memoryUsage.redoCount = redoStack.count
        memoryUsage.undoLogicalBytes = undoStack.reduce(0) { $0 + $1.logicalBytes }
        memoryUsage.redoLogicalBytes = redoStack.reduce(0) { $0 + $1.logicalBytes }
        memoryUsage.currentLogicalBytes = current
        memoryUsage.retainedEstimatedBytes = counter.bytes - current
    }
    /// Drop the farthest states first. Following Undo, keep the nearest redo; following Redo,
    /// keep the nearest undo. Even a single oversized old state may be discarded; current is never trimmed.
    private mutating func trimHistory(preferUndo: Bool) {
        refreshMemoryUsage()
        while undoStack.count + redoStack.count > budget.snapshotLimit || memoryUsage.retainedEstimatedBytes > budget.estimatedByteLimit {
            guard !undoStack.isEmpty || !redoStack.isEmpty else { break }
            if preferUndo ? !redoStack.isEmpty : undoStack.isEmpty { redoStack.removeFirst() }
            else { undoStack.removeFirst() }
            memoryUsage.trimmedSnapshots += 1
            refreshMemoryUsage()
        }
    }
    /// Every document state Undo/Redo can still return to (not the current one). Read-only: used to decide
    /// which generated media files are still referenced.
    public var retainedProjects: [Project] { undoStack.map(\.project) + redoStack.map(\.project) }
    /// Releases history references only, leaving the live document and external media untouched.
    public mutating func clearHistory() {
        undoStack.removeAll(keepingCapacity: false); redoStack.removeAll(keepingCapacity: false)
        refreshMemoryUsage()
    }
    public mutating func apply(_ command: EditCommand) throws {
        // A candidate copy guarantees rejection cannot partially mutate the live document or history.
        try ProjectValidator.validate(project)
        var candidate = project
        try TransitionEditing.prepareTemporal(command, in: &candidate.sequence)
        let temporalBefore = candidate.sequence
        try Self.execute(command, in: &candidate)
        try TransitionEditing.reconcileRates(before: temporalBefore, after: &candidate.sequence)
        try ConnectionEditing.reconcile(before: project.sequence, after: &candidate.sequence)
        try CaptionTranslationTracking.reconcile(before: project.sequence, after: &candidate.sequence)
        try SpeakerEditing.reconcile(before: project.sequence, after: &candidate.sequence)
        try TransitionEditing.refreshAudio(in: &candidate.sequence)
        try ProjectValidator.validate(candidate)
        guard candidate != project else { return }
        undoStack.append(Snapshot(project))
        project = candidate
        redoStack.removeAll(keepingCapacity: false)
        trimHistory(preferUndo: true)
    }
    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(project)); project = previous.project
        trimHistory(preferUndo: false)
    }
    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(project)); project = next.project
        trimHistory(preferUndo: true)
    }
    private static func trackIndex(_ id: UUID, in project: Project, allowLocked: Bool = false) throws -> Int {
        guard let index = project.sequence.tracks.firstIndex(where: { $0.id == id }) else { throw ProjectError("트랙을 찾을 수 없습니다.") }
        guard allowLocked || !project.sequence.tracks[index].isLocked else { throw ProjectError("잠긴 트랙은 편집할 수 없습니다.") }
        return index
    }
    private static func clipIndex(_ id: UUID, in track: Track) throws -> Int {
        guard let index = track.clips.firstIndex(where: { $0.id == id }) else { throw ProjectError("클립을 찾을 수 없습니다.") }
        return index
    }
    /// The incoming clip moves `duration` earlier onto its own overlay track (so it overlaps the
    /// outgoing clip), everything after it moves up, and audio cross-fades over the same time.
    private static func addTransition(in project: inout Project, trackID: UUID, clipID: UUID, kind: TransitionKind, direction: TransitionDirection, duration: MediaTime) throws {
        try TransitionEditing.add(in: &project.sequence, trackID: trackID, clipID: clipID, effect: ClipTransition(kind: kind, direction: direction, duration: duration))
    }

    private static func execute(_ command: EditCommand, in project: inout Project) throws {
        switch command {
        case .batch(let commands):
            // The final state is validated by apply(), allowing coordinated moves through
            // temporarily overlapping intermediate positions without exposing those states.
            for command in commands { try execute(command, in: &project) }
        case .addAsset(let asset): project.assets.append(asset)
        case .replaceAsset(let asset):
            guard let index = project.assets.firstIndex(where: { $0.id == asset.id }) else { throw ProjectError("교체할 미디어를 찾을 수 없습니다.") }
            project.assets[index] = asset
        case .replaceSequence(let sequence):
            for locked in project.sequence.tracks where locked.isLocked {
                guard sequence.tracks.first(where: { $0.id == locked.id }) == locked else { throw ProjectError("잠긴 트랙은 시퀀스 교체로 변경할 수 없습니다.") }
            }
            project.sequence = sequence
        case .addTrack(let track): project.sequence.tracks.append(track)
        case .removeTrack(let trackID):
            let ti = try trackIndex(trackID, in: project)
            project.sequence.tracks.remove(at: ti)
        case .deriveSequence(let name, let width, let height):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError("버전 이름을 입력하세요.") }
            let original = project.sequence
            var derived = original; derived.id = UUID(); derived.name = name; derived.width = width; derived.height = height
            let idMap = Dictionary(uniqueKeysWithValues: derived.tracks.flatMap(\.clips).map { ($0.id, UUID()) })
            let captionGroups = Set(derived.tracks.flatMap(\.clips).compactMap(\.captionGroupID))
            let captionGroupMap = Dictionary(uniqueKeysWithValues: captionGroups.map { ($0, idMap[$0] ?? UUID()) })
            let trackMap = Dictionary(uniqueKeysWithValues: derived.tracks.map { ($0.id, UUID()) })
            let families = Set(derived.tracks.flatMap(\.clips).map(TransitionEditing.family))
            let familyMap = Dictionary(uniqueKeysWithValues: families.map { ($0, idMap[$0] ?? UUID()) })
            for ti in derived.tracks.indices {
                derived.tracks[ti].id = trackMap[derived.tracks[ti].id]!
                if var context = derived.tracks[ti].transitionContext {
                    context.originTrackID = trackMap[context.originTrackID]!
                    context.outgoingFamilyID = familyMap[context.outgoingFamilyID]!
                    derived.tracks[ti].transitionContext = context
                }
                for ci in derived.tracks[ti].clips.indices {
                    let old = derived.tracks[ti].clips[ci]
                    derived.tracks[ti].clips[ci].id = idMap[old.id]!
                    derived.tracks[ti].clips[ci].lineageID = old.lineageID.map { familyMap[$0]! }
                    derived.tracks[ti].clips[ci].transitionAudioFades = old.transitionAudioFades?.map { var fade = $0; fade.ownerID = trackMap[fade.ownerID] ?? fade.ownerID; return fade }
                    derived.tracks[ti].clips[ci].captionGroupID = old.captionGroupID.map { captionGroupMap[$0]! }
                    if let source = old.captionMetadata?.translatedFrom { derived.tracks[ti].clips[ci].captionMetadata?.translatedFrom = idMap[source] ?? familyMap[source] ?? source }
                    if let source = old.captionMetadata?.translationRevision?.sourceCaptionID { derived.tracks[ti].clips[ci].captionMetadata?.translationRevision?.sourceCaptionID = idMap[source] ?? familyMap[source] ?? source }
                    if let parent = old.connection?.parentID { derived.tracks[ti].clips[ci].connection?.parentID = idMap[parent] ?? parent }
                    if let title = old.title { derived.tracks[ti].clips[ci].title = TitleSizing.resized(title, from: min(original.width, original.height), to: min(width, height)) }
                }
            }
            project.derivedSequences = (project.derivedSequences ?? []) + [original]
            project.sequence = derived
        case .addIndependentSequence(let sequence):
            project.derivedSequences = (project.derivedSequences ?? []) + [project.sequence]
            project.sequence = sequence
        case .activateDerivedSequence(let id):
            guard let index = project.derivedSequences?.firstIndex(where: { $0.id == id }), let version = project.derivedSequences?[index] else { throw ProjectError("시퀀스 버전을 찾을 수 없습니다.") }
            project.derivedSequences?[index] = project.sequence
            project.sequence = version
        case .duplicate(let trackID, let clipID):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            let original = project.sequence.tracks[ti].clips[ci]
            var duplicate = original; duplicate.id = UUID(); duplicate.lineageID = nil; duplicate.connection = nil; duplicate.name += " 복사"; duplicate.start = try original.start.adding(original.duration)
            if CaptionQuery.role(of: original) == .original { duplicate.captionRole = .original; duplicate.captionGroupID = UUID() }
            let allDependents = project.sequence.tracks.flatMap(\.clips).filter { $0.connection?.parentID == original.id }
            let childIDs = Dictionary(uniqueKeysWithValues: allDependents.map { ($0.id, UUID()) })
            try shiftFollowing(in: &project.sequence.tracks[ti], startingAt: duplicate.start, by: original.duration, excluding: original.id)
            project.sequence.tracks[ti].clips.insert(duplicate, at: ci + 1)
            for trackIndex in project.sequence.tracks.indices {
                let dependents = project.sequence.tracks[trackIndex].clips.filter { $0.connection?.parentID == original.id }
                if !dependents.isEmpty, project.sequence.tracks[trackIndex].isLocked { throw ProjectError("연결된 트랙의 잠금을 먼저 해제하세요.") }
                for child in dependents {
                    var copy = child; copy.id = childIDs[child.id]!; copy.lineageID = nil; copy.connection?.parentID = duplicate.id
                    if CaptionQuery.role(of: child) == .original || CaptionQuery.role(of: child) == .translation { copy.captionGroupID = duplicate.id }
                    if let from = child.captionMetadata?.translatedFrom {
                        // A source split leaves the right original with a lineage root rather than the
                        // left original's id. Bind the duplicated translation to its copied interval.
                        let sourceCaptions = allDependents.filter { CaptionQuery.role(of: $0) == .original }
                        func sameInterval(_ candidate: Clip) -> Bool {
                            candidate.connection?.sourceStart == child.connection?.sourceStart && candidate.connection?.sourceDuration == child.connection?.sourceDuration
                        }
                        // Exact identity wins even if an overlapping family fragment appears first.
                        let exact = sourceCaptions.first { $0.id == from && (child.captionMetadata?.translationRevision != nil || sameInterval($0)) }
                        let legacy = sourceCaptions.filter { $0.lineageID == from && sameInterval($0) }
                        guard exact != nil || legacy.count <= 1 else { throw ProjectError("같은 구간의 원문 연결이 모호해 영상을 복사하지 않았습니다. 번역의 원문을 확인하세요.") }
                        let matchingOriginal = exact ?? legacy.first
                        copy.captionMetadata?.translatedFrom = matchingOriginal.flatMap { childIDs[$0.id] } ?? childIDs[from] ?? from
                        if copy.captionMetadata?.translationRevision != nil, let bound = copy.captionMetadata?.translatedFrom { copy.captionMetadata?.translationRevision?.sourceCaptionID = bound }
                    }
                    copy.start = try copy.start.adding(original.duration)
                    project.sequence.tracks[trackIndex].clips.append(copy)
                }
            }
        case .setRate(let trackID, let clipID, let rate):
            guard rate.numerator > 0, rate.denominator > 0, (0.25...4).contains(rate.multiplier) else { throw ProjectError("재생 속도는 0.25~4배 범위여야 합니다.") }
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            var clip = project.sequence.tracks[ti].clips[ci]
            guard let id = clip.assetID, let asset = project.assets.first(where: { $0.id == id }), asset.kind != .image else { throw ProjectError("재생 속도는 영상 또는 오디오 클립에 적용하세요.") }
            let oldRate = clip.playbackRate ?? PlaybackRate(), oldDuration = clip.duration
            let oldEnd = try clip.start.adding(oldDuration)
            func remap(_ time: MediaTime) throws -> MediaTime { try time.scaled(numerator: oldRate.numerator, denominator: oldRate.denominator).scaled(numerator: rate.denominator, denominator: rate.numerator) }
            clip = try ClipTemporalEditor.retimed(clip, duration: remap(oldDuration), mapping: remap); clip.playbackRate = rate
            project.sequence.tracks[ti].clips[ci] = clip
            try shiftFollowing(in: &project.sequence.tracks[ti], startingAt: oldEnd, by: clip.duration.subtracting(oldDuration), excluding: clipID)
        case .speedRamp(let trackID, let clipID, let rates, let mutesAudio):
            guard SpeedRampPlan.allowedPieces.contains(rates.count) else { throw ProjectError("속도 램프는 \(SpeedRampPlan.allowedPieces.lowerBound)~\(SpeedRampPlan.allowedPieces.upperBound)조각으로 만듭니다.") }
            let ti = try trackIndex(trackID, in: project)
            let original = project.sequence.tracks[ti].clips[try clipIndex(clipID, in: project.sequence.tracks[ti])]
            guard original.title == nil else { throw ProjectError("속도 램프는 영상 또는 오디오 클립에 적용하세요.") }
            guard original.duration.seconds / Double(rates.count) >= SpeedRampPlan.minimumPieceSeconds else { throw ProjectError("클립이 짧아 이 조각 수로 나눌 수 없습니다. 조각 수를 줄이세요.") }
            // Connected audio would keep its own speed; refuse instead of letting picture and sound drift apart.
            guard !project.sequence.tracks.flatMap(\.clips).contains(where: { $0.connection?.parentID == original.id && $0.title == nil }) else {
                throw ProjectError("분리된 오디오가 연결돼 있어 속도 램프를 만들 수 없습니다. 오디오 연결을 해제하거나 삭제한 뒤 다시 시도하세요.")
            }
            let n = rates.count
            let unrelated = project.sequence.tracks[ti].clips.filter { $0.id != original.id }
            var pieceIDs = [original.id]
            var current = original.id
            for i in 1..<n {
                let at = try original.start.adding(try original.duration.scaled(numerator: Int32(i), denominator: Int32(n)))
                let existingIDs = Set(project.sequence.tracks[ti].clips.map(\.id))
                try execute(.split(trackID: trackID, clipID: current, at: at), in: &project)
                let created = project.sequence.tracks[ti].clips.filter { !existingIDs.contains($0.id) }
                guard created.count == 1, let next = created.first else { throw ProjectError("속도 램프를 나누지 못했습니다.") }
                current = next.id
                pieceIDs.append(current)
            }
            for (id, rate) in zip(pieceIDs, rates) { try execute(.setRate(trackID: trackID, clipID: id, rate: rate), in: &project) }
            // setRate ripples after each piece. Overlapping, unrelated clips must not be
            // swept into that ripple; only clips following the original range move.
            let newEnd = project.sequence.tracks[ti].clips[try clipIndex(current, in: project.sequence.tracks[ti])].end
            let delta = try newEnd.subtracting(original.end)
            for var other in unrelated {
                if other.start >= original.end { other.start = try other.start.adding(delta) }
                project.sequence.tracks[ti].clips[try clipIndex(other.id, in: project.sequence.tracks[ti])] = other
            }
            if mutesAudio {
                for id in pieceIDs {
                    let index = try clipIndex(id, in: project.sequence.tracks[ti])
                    project.sequence.tracks[ti].clips[index].volume = 0
                    project.sequence.tracks[ti].clips[index].keyframes = project.sequence.tracks[ti].clips[index].keyframes?.map {
                        var frame = $0; frame.volume = 0; return frame
                    }
                }
            }
        case .rename(let name): project.name = name
        case .replaceGlossary(let entries):
            for entry in entries where entry.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ProjectError("용어집 원문은 비워 둘 수 없습니다.") }
            project.glossary = entries.isEmpty ? nil : entries
        case .updateTrack(let track):
            let ti = try trackIndex(track.id, in: project, allowLocked: true)
            let original = project.sequence.tracks[ti]
            if original.isLocked {
                var unlocked = original; unlocked.isLocked = false
                guard track == original || track == unlocked else { throw ProjectError("잠긴 트랙을 먼저 잠금 해제하세요.") }
            }
            project.sequence.tracks[ti] = track
        case .addClip(let trackID, let clip):
            let ti = try trackIndex(trackID, in: project)
            project.sequence.tracks[ti].clips.append(clip)
        case .updateClip(let trackID, let clip):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clip.id, in: project.sequence.tracks[ti])
            project.sequence.tracks[ti].clips[ci] = clip
        case .move(let trackID, let clipID, let to):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            project.sequence.tracks[ti].clips[ci].start = to
        case .trimClip(let trackID, let clipID, let newStart, let newSourceStart, let newDuration):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            let original = project.sequence.tracks[ti].clips[ci]
            let temporal = original.assetID.flatMap { id in project.assets.first { $0.id == id } }?.kind != .image && original.title == nil
            project.sequence.tracks[ti].clips[ci] = try ClipTemporalEditor.trimmed(original, newStart: newStart, newSourceStart: newSourceStart, newDuration: newDuration, frameRate: project.sequence.frameRate, temporalSource: temporal)
        case .crossDissolve(let trackID, let clipID, let duration):
            try addTransition(in: &project, trackID: trackID, clipID: clipID, kind: .dissolve, direction: .fromRight, duration: duration)
        case .addTransition(let trackID, let clipID, let kind, let direction, let duration):
            try addTransition(in: &project, trackID: trackID, clipID: clipID, kind: kind, direction: direction, duration: duration)
        case .updateTransition(let trackID, let kind, let direction, let duration):
            try TransitionEditing.update(in: &project.sequence, trackID: trackID, effect: ClipTransition(kind: kind, direction: direction, duration: duration))
        case .changeTransitionAppearance(let trackID, let kind, let direction):
            try TransitionEditing.changeAppearance(in: &project.sequence, trackID: trackID, kind: kind, direction: direction)
        case .removeTransition(let trackID):
            try TransitionEditing.update(in: &project.sequence, trackID: trackID, effect: nil)
        case .separateAudio(let trackID, let clipID, let destinationTrackID):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            let original = project.sequence.tracks[ti].clips[ci]
            guard project.sequence.tracks[ti].kind == .video || project.sequence.tracks[ti].kind == .overlay, let assetID = original.assetID, let asset = project.assets.first(where: { $0.id == assetID }), asset.kind == .video, asset.hasAudio else { throw ProjectError("소리가 있는 영상 클립에서 오디오를 분리하세요.") }
            guard !project.sequence.tracks[ti].isMuted, !project.sequence.tracks[ti].isHidden else { throw ProjectError("분리 후 재생 상태를 유지하려면 원본 트랙의 음소거·숨김을 먼저 해제하세요.") }
            let audioIndex: Int
            if let destinationTrackID { audioIndex = try trackIndex(destinationTrackID, in: project) }
            else if let existing = project.sequence.tracks.firstIndex(where: { $0.kind == .audio && !$0.isLocked && !$0.isMuted && !$0.isHidden }) { audioIndex = existing }
            else { project.sequence.tracks.append(Track(name: "분리 오디오", kind: .audio)); audioIndex = project.sequence.tracks.count - 1 }
            let destination = project.sequence.tracks[audioIndex]
            guard destination.kind == .audio, !destination.isMuted, !destination.isHidden else { throw ProjectError("분리할 오디오는 재생 가능한 오디오 트랙에 배치하세요.") }
            guard !project.sequence.tracks.flatMap(\.clips).contains(where: { $0.connection?.parentID == original.id && $0.title == nil }) else { throw ProjectError("이미 분리된 연결 오디오가 있습니다. 기존 오디오를 편집하세요.") }
            var audio = original; audio.id = UUID(); audio.lineageID = nil; audio.blendMode = nil
            audio.connection = ClipConnection(parentID: original.id, sourceStart: original.sourceStart, sourceDuration: original.sourceDuration)
             audio.name += " · 분리 오디오"; audio.transform = ClipTransform(); audio.visual = nil; audio.fadeIn = nil; audio.fadeOut = nil
            audio.keyframes = original.keyframes?.map { frame in var copy = frame; copy.transform = ClipTransform(); return copy }
            project.sequence.tracks[audioIndex].clips.append(audio)
            project.sequence.tracks[ti].clips[ci].volume = 0
            project.sequence.tracks[ti].clips[ci].keyframes = original.keyframes?.map { frame in var copy = frame; copy.volume = 0; return copy }
        case .insertClip(let trackID, let inserted, let at):
            guard at >= .zero, inserted.duration > .zero else { throw ProjectError("삽입 위치와 길이를 확인하세요.") }
            let ti = try trackIndex(trackID, in: project)
            guard project.sequence.tracks[ti].kind == .video else { throw ProjectError("리플 삽입은 메인 영상 트랙에서 사용하세요.") }
            var clips: [Clip] = []
            for original in project.sequence.tracks[ti].clips {
                if original.start < at, original.end > at {
                    clips += try fragments(of: original, removingStart: at, removingEnd: at, project: project, shiftRightBy: inserted.duration)
                } else { var value = original; if original.start >= at { value.start = try value.start.adding(inserted.duration) }; clips.append(value) }
            }
            try rippleOtherTracks(project: &project, excluding: trackID, at: at, removed: .zero, inserted: inserted.duration)
            var placed = inserted; placed.start = at; clips.append(placed)
            project.sequence.tracks[ti].clips = clips.sorted { $0.start < $1.start }
        case .overwriteClip(let trackID, let inserted, let at):
            guard at >= .zero, inserted.duration > .zero else { throw ProjectError("덮어쓰기 위치와 길이를 확인하세요.") }
            let ti = try trackIndex(trackID, in: project)
            guard project.sequence.tracks[ti].kind == .video else { throw ProjectError("덮어쓰기는 메인 영상 트랙에서 사용하세요.") }
            let end = try at.adding(inserted.duration)
            var clips: [Clip] = []
            for original in project.sequence.tracks[ti].clips {
                if original.end <= at || original.start >= end { clips.append(original) }
                else { clips += try fragments(of: original, removingStart: at, removingEnd: end, project: project) }
            }
            var placed = inserted; placed.start = at; clips.append(placed)
            project.sequence.tracks[ti].clips = clips.sorted { $0.start < $1.start }
        case .split(let trackID, let clipID, let at):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            let original = project.sequence.tracks[ti].clips[ci]
            guard at > original.start, at < original.end else { throw ProjectError("분할 위치는 클립 시작과 끝 사이여야 합니다.") }
            let pieces = try fragments(of: original, removingStart: at, removingEnd: at, project: project)
            project.sequence.tracks[ti].clips.replaceSubrange(ci...ci, with: pieces)
        case .delete(let trackID, let clipID, let ripple):
            let ti = try trackIndex(trackID, in: project)
            let ci = try clipIndex(clipID, in: project.sequence.tracks[ti])
            let removed = project.sequence.tracks[ti].clips.remove(at: ci)
            if ripple {
                try rippleOtherTracks(project: &project, excluding: trackID, at: removed.start, removed: removed.duration, inserted: .zero)
                for index in project.sequence.tracks[ti].clips.indices where project.sequence.tracks[ti].clips[index].start >= removed.end {
                    project.sequence.tracks[ti].clips[index].start = try project.sequence.tracks[ti].clips[index].start.subtracting(removed.duration)
                }
            }
        case .reorder(let trackID, let clipID, let direction):
            guard direction == -1 || direction == 1 else { throw ProjectError("순서 변경 방향은 -1 또는 1이어야 합니다.") }
            let ti = try trackIndex(trackID, in: project)
            var clips = project.sequence.tracks[ti].clips.sorted { $0.start < $1.start }
            let ci = try clipIndex(clipID, in: Track(name: "", kind: .video, clips: clips))
            let target = ci + direction
            guard clips.indices.contains(target) else { return }
            let low = min(ci, target), high = max(ci, target)
            let left = clips[low], right = clips[high]
            guard left.end <= right.start else { throw ProjectError("겹친 클립은 순서 변경 전에 위치를 조절하세요.") }
            let gap = try right.start.subtracting(left.end)
            var newLeft = right, newRight = left
            newLeft.start = left.start
            newRight.start = try newLeft.start.adding(newLeft.duration).adding(gap)
            clips[low] = newLeft; clips[high] = newRight
            project.sequence.tracks[ti].clips = clips
        }
    }
    private static func fragments(of input: Clip, removingStart: MediaTime, removingEnd: MediaTime, project: Project, shiftRightBy: MediaTime = .zero) throws -> [Clip] {
        var original = input; original.lineageID = input.lineageID ?? input.id
        let temporal = original.assetID.flatMap { id in project.assets.first { $0.id == id } }?.kind != .image && original.title == nil
        let rate = original.playbackRate ?? PlaybackRate()
        var result: [Clip] = []
        if original.start < removingStart {
            let length = try min(removingStart, original.end).subtracting(original.start)
            if length > .zero { result.append(try ClipTemporalEditor.trimmed(original, newStart: original.start, newSourceStart: original.sourceStart, newDuration: length, frameRate: project.sequence.frameRate, temporalSource: temporal)) }
        }
        if original.end > removingEnd {
            let start = max(removingEnd, original.start)
            let offset = try start.subtracting(original.start)
            let sourceStart = temporal ? try original.sourceStart.adding(offset.scaled(numerator: rate.numerator, denominator: rate.denominator)) : .zero
            var right = try ClipTemporalEditor.trimmed(original, newStart: start.adding(shiftRightBy), newSourceStart: sourceStart, newDuration: original.end.subtracting(start), frameRate: project.sequence.frameRate, temporalSource: temporal, animationOffset: offset)
            if !result.isEmpty { right.id = UUID() }
            result.append(right)
        }
        return result
    }
    private static func rippleOtherTracks(project: inout Project, excluding: UUID, at: MediaTime, removed: MediaTime, inserted: MediaTime) throws {
        let end = try at.adding(removed), delta = try inserted.subtracting(removed)
        let snapshot = project
        for ti in project.sequence.tracks.indices where project.sequence.tracks[ti].id != excluding && project.sequence.tracks[ti].syncLocked == true {
            var clips: [Clip] = []
            for clip in project.sequence.tracks[ti].clips {
                if clip.connection != nil || clip.end <= at { clips.append(clip); continue }
                if project.sequence.tracks[ti].isLocked { throw ProjectError("동기 편집 대상 트랙이 잠겨 있습니다: \(project.sequence.tracks[ti].name)") }
                if clip.start >= end { var moved = clip; moved.start = try clip.start.adding(delta); clips.append(moved) }
                else { clips += try fragments(of: clip, removingStart: at, removingEnd: end, project: snapshot, shiftRightBy: delta) }
            }
            project.sequence.tracks[ti].clips = clips
        }
    }
    private static func shiftFollowing(in track: inout Track, startingAt boundary: MediaTime, by delta: MediaTime, excluding clipID: UUID) throws {
        for index in track.clips.indices where track.clips[index].id != clipID && track.clips[index].start >= boundary {
            track.clips[index].start = try track.clips[index].start.adding(delta)
        }
    }
}

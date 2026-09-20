import XCTest
@testable import JHCutCore

final class MediaTimeTests: XCTestCase {
    func testRationalIdentityAndExactFrameRates() throws {
        XCTAssertEqual(MediaTime(1, 30), MediaTime(20, 600))
        XCTAssertEqual(Set([MediaTime(1, 30), MediaTime(20, 600)]).count, 1)
        XCTAssertEqual(FrameRate().time(forFrame: 450), MediaTime(15, 1))
        let ntsc = FrameRate(numerator: 30_000, denominator: 1_001)
        XCTAssertEqual(ntsc.time(forFrame: 30_000), MediaTime(1_001, 1))
        let cinema = FrameRate(numerator: 24_000, denominator: 1_001)
        XCTAssertEqual(cinema.time(forFrame: 24_000), MediaTime(1_001, 1))
        var accumulated = MediaTime.zero
        for _ in 0..<30_000 { accumulated = accumulated + ntsc.time(forFrame: 1) }
        XCTAssertEqual(accumulated, MediaTime(1_001, 1))
        XCTAssertEqual(try JSONDecoder().decode(FrameRate.self, from: JSONEncoder().encode(ntsc)), ntsc)
    }
    func testArithmeticExtremesAreCheckedWithoutMultiplicationOverflow() throws {
        XCTAssertLessThan(MediaTime(Int64.max - 1, Int32.max), MediaTime(Int64.max, Int32.max))
        XCTAssertEqual(MediaTime(Int64.min, 2).value, Int64.min / 2)
        XCTAssertEqual(try MediaTime(Int64.max, Int32.max).subtracting(MediaTime(Int64.max, Int32.max)), .zero)
        XCTAssertThrowsError(try MediaTime(Int64.max, 1).adding(MediaTime(1, 1)))
        XCTAssertThrowsError(try MediaTime(1, Int32.max).adding(MediaTime(1, Int32.max - 1)))
    }
    func testInvalidTimeAndFrameRateCannotDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(MediaTime.self, from: Data(#"{"value":1,"timescale":0}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(MediaTime.self, from: Data(#"{"value":1,"timescale":-30}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FrameRate.self, from: Data(#"{"numerator":30000,"denominator":0}"#.utf8)))
    }
}

final class EditingTests: XCTestCase {
    private func baseProject() -> Project {
        var project = Project(name: "종현의 첫 영상")
        let asset = MediaAsset(name: "장면 1.mp4", path: "/fixture/장면 1.mp4", kind: .video, duration: MediaTime(10, 1), width: 1080, height: 1920)
        project.assets = [asset]
        project.sequence.tracks[0].clips = [Clip(name: "첫 장면", assetID: asset.id, duration: MediaTime(4, 1))]
        return project
    }
    func testSplitUsesSourceCoordinatesAndHalfOpenRanges() throws {
        let initial = baseProject()
        let track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        try history.apply(.split(trackID: track.id, clipID: clip.id, at: MediaTime(45, 30)))
        let result = history.project.sequence.tracks[0].clips
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].duration, MediaTime(3, 2))
        XCTAssertEqual(result[1].duration, MediaTime(5, 2))
        XCTAssertEqual(result[1].sourceStart, MediaTime(3, 2))
        XCTAssertFalse(result[0].contains(MediaTime(3, 2)))
        XCTAssertTrue(result[1].contains(MediaTime(3, 2)))
        XCTAssertEqual(history.project.sequence.duration, MediaTime(4, 1))
        history.undo(); XCTAssertEqual(history.project, initial)
        history.redo(); XCTAssertEqual(history.project.sequence.tracks[0].clips, result)
    }
    func testSplittingAtEitherBoundaryIsAtomic() throws {
        let initial = baseProject(), track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        for boundary in [clip.start, clip.end] {
            XCTAssertThrowsError(try history.apply(.split(trackID: track.id, clipID: clip.id, at: boundary)))
            XCTAssertEqual(history.project, initial)
            XCTAssertFalse(history.canUndo)
        }
    }
    func testInvalidEditsPreserveProjectAndRedo() throws {
        let initial = baseProject(), track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        try history.apply(.rename("이름 변경")); history.undo()
        var invalid = clip; invalid.sourceStart = MediaTime(8, 1)
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: invalid)))
        XCTAssertThrowsError(try history.apply(.move(trackID: track.id, clipID: clip.id, to: MediaTime(-1, 1))))
        XCTAssertEqual(history.project, initial)
        XCTAssertTrue(history.canRedo)
        history.redo(); XCTAssertEqual(history.project.name, "이름 변경")
    }
    func testImportPlacementTrimMoveStyleAndTrackSettingsUndoAsSingleCommands() throws {
        let original = Project(name: "빈 프로젝트")
        let asset = MediaAsset(name: "입력.mp4", path: "/fixture/입력.mp4", kind: .video, duration: MediaTime(10, 1))
        let track = original.sequence.tracks[0]
        let clip = Clip(assetID: asset.id, duration: MediaTime(5, 1))
        var history = EditorHistory(project: original)
        var states = [original]
        func checkpoint(_ history: EditorHistory) { states.append(history.project) }
        try history.apply(.addAsset(asset)); checkpoint(history)
        try history.apply(.addClip(trackID: track.id, clip: clip)); checkpoint(history)
        var trimmed = clip; trimmed.sourceStart = MediaTime(1, 1); trimmed.duration = MediaTime(3, 1)
        trimmed.transform.rotation = 25; trimmed.transform.opacity = 0.7; trimmed.volume = 0.4
        try history.apply(.updateClip(trackID: track.id, clip: trimmed)); checkpoint(history)
        try history.apply(.move(trackID: track.id, clipID: clip.id, to: MediaTime(2, 1))); checkpoint(history)
        var muted = history.project.sequence.tracks[0]; muted.isMuted = true; muted.isHidden = true
        try history.apply(.updateTrack(muted)); checkpoint(history)
        try history.apply(.rename("편집 완료")); checkpoint(history)
        for state in states.dropLast().reversed() { history.undo(); XCTAssertEqual(history.project, state) }
        XCTAssertFalse(history.canUndo)
        for state in states.dropFirst() { history.redo(); XCTAssertEqual(history.project, state) }
        XCTAssertFalse(history.canRedo)
    }
    func testLockedTrackCannotBeChangedThroughAnyClipCommandOrTrackReplacement() throws {
        var initial = baseProject(); initial.sequence.tracks[0].isLocked = true
        let track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        var replacement = track; replacement.clips = []
        let commands: [EditCommand] = [
            .addClip(trackID: track.id, clip: clip), .updateClip(trackID: track.id, clip: clip),
            .move(trackID: track.id, clipID: clip.id, to: MediaTime(5, 1)),
            .split(trackID: track.id, clipID: clip.id, at: MediaTime(2, 1)),
            .delete(trackID: track.id, clipID: clip.id, ripple: false),
            .reorder(trackID: track.id, clipID: clip.id, direction: 1), .updateTrack(replacement)
        ]
        for command in commands { XCTAssertThrowsError(try history.apply(command)); XCTAssertEqual(history.project, initial) }
        var unlocked = track; unlocked.isLocked = false
        try history.apply(.updateTrack(unlocked))
        XCTAssertFalse(history.project.sequence.tracks[0].isLocked)
        history.undo(); XCTAssertTrue(history.project.sequence.tracks[0].isLocked)
    }
    func testDeleteAndRippleHaveDifferentScopeAndUndo() throws {
        var initial = baseProject()
        let asset = initial.assets[0]
        initial.sequence.tracks[0].clips.append(Clip(name: "두 번째", assetID: asset.id, start: MediaTime(4, 1), duration: MediaTime(3, 1)))
        initial.sequence.tracks[2].clips = [Clip(start: MediaTime(5, 1), duration: MediaTime(2, 1), title: Title(text: "독립 자막"))]
        let track = initial.sequence.tracks[0]
        var history = EditorHistory(project: initial)
        try history.apply(.delete(trackID: track.id, clipID: track.clips[0].id, ripple: false))
        XCTAssertEqual(history.project.sequence.tracks[0].clips[0].start, MediaTime(4, 1))
        history.undo()
        try history.apply(.delete(trackID: track.id, clipID: track.clips[0].id, ripple: true))
        XCTAssertEqual(history.project.sequence.tracks[0].clips[0].start, .zero)
        XCTAssertEqual(history.project.sequence.tracks[2].clips[0].start, MediaTime(5, 1))
        XCTAssertFalse(history.canRedo)
        history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testReorderPreservesDurationsGapSpanAndUndo() throws {
        var initial = baseProject()
        initial.sequence.tracks[0].clips[0].duration = MediaTime(3, 1)
        initial.sequence.tracks[0].clips.append(Clip(name: "두 번째", assetID: initial.assets[0].id, start: MediaTime(4, 1), duration: MediaTime(2, 1)))
        let track = initial.sequence.tracks[0]
        var history = EditorHistory(project: initial)
        try history.apply(.reorder(trackID: track.id, clipID: track.clips[1].id, direction: -1))
        let reordered = history.project.sequence.tracks[0].clips
        XCTAssertEqual(reordered.map(\.id), [track.clips[1].id, track.clips[0].id])
        XCTAssertEqual(reordered[0].start, .zero)
        XCTAssertEqual(reordered[1].start, MediaTime(3, 1))
        XCTAssertEqual(history.project.sequence.duration, initial.sequence.duration)
        history.undo(); XCTAssertEqual(history.project, initial)
        history.redo(); XCTAssertEqual(history.project.sequence.tracks[0].clips, reordered)
    }
    func testImageAndTitleCanSplitWithoutInventingSourceTime() throws {
        var project = Project()
        let image = MediaAsset(name: "엔드 카드.png", path: "/fixture/엔드 카드.png", kind: .image)
        project.assets = [image]
        project.sequence.tracks[0].clips = [Clip(assetID: image.id, duration: MediaTime(3, 1))]
        project.sequence.tracks[2].clips = [Clip(duration: MediaTime(3, 1), title: Title(text: "종현의 첫 영상"))]
        var history = EditorHistory(project: project)
        for trackIndex in [0, 2] {
            let track = project.sequence.tracks[trackIndex]
            try history.apply(.split(trackID: track.id, clipID: track.clips[0].id, at: MediaTime(1, 1)))
            XCTAssertEqual(history.project.sequence.tracks[trackIndex].clips[1].sourceStart, .zero)
        }
    }
    func testInvalidReferencesDurationsOverlapAndSchemaRejected() throws {
        let valid = baseProject()
        var invalid = valid; invalid.schemaVersion = 2
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
        invalid = valid; invalid.sequence.tracks[0].clips[0].assetID = UUID()
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
        invalid = valid; invalid.sequence.tracks[0].clips[0].duration = .zero
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
        invalid = valid; invalid.sequence.tracks[0].clips[0].duration = MediaTime(-1, 1)
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
        invalid = valid; var duplicate = invalid.sequence.tracks[0].clips[0]; duplicate.id = UUID(); duplicate.start = MediaTime(3, 1); invalid.sequence.tracks[0].clips.append(duplicate)
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
        invalid = valid; invalid.assets.append(invalid.assets[0])
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
        invalid = valid; invalid.sequence.tracks[0].clips[0].transform.scale = .nan
        XCTAssertThrowsError(try ProjectValidator.validate(invalid))
    }
    func testKoreanAndCombiningCharactersRoundTrip() throws {
        var project = baseProject()
        project.sequence.tracks[2].clips = [Clip(title: Title(text: "종현의 첫 영상\n종현 — 안녕하세요! ‘춘천’"))]
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), project)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("종현의 첫 영상"))
    }
}

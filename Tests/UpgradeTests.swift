import XCTest
import AppKit
@testable import JHCutCore

final class UpgradeEditingTests: XCTestCase {
    private func project() -> Project {
        var p = Project(name: "속도 테스트")
        let a = MediaAsset(name: "장면.mp4", path: "/fixture/장면.mp4", kind: .video, duration: MediaTime(20, 1), hasAudio: true)
        p.assets = [a]
        p.sequence.tracks[0].clips = [Clip(assetID: a.id, sourceStart: MediaTime(2, 1), duration: MediaTime(4, 1)), Clip(assetID: a.id, start: MediaTime(4, 1), duration: MediaTime(4, 1))]
        p.sequence.tracks[2].clips = [Clip(start: MediaTime(3, 1), title: Title(text: "시간 유지"))]
        return p
    }
    func testRateMappingIsExactForNTSCAndRationalSpeed() throws {
        let ntsc = FrameRate(numerator: 30_000, denominator: 1_001)
        let rate = PlaybackRate(numerator: 3, denominator: 2)
        let duration = ntsc.time(forFrame: 127)
        XCTAssertEqual(rate.timelineDuration(for: rate.sourceDuration(for: duration)), duration)
        XCTAssertEqual(PlaybackRate(numerator: 1, denominator: 4).sourceDuration(for: MediaTime(4, 1)), MediaTime(1, 1))
        XCTAssertThrowsError(try MediaTime(1, 1).scaled(numerator: 0, denominator: 1))
    }
    func testRateChangePreservesSourceRangeRetimesEnvelopesAndRipplesOnlyCurrentTrack() throws {
        var initial = project()
        initial.sequence.tracks[0].clips[0].fadeIn = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].audioFadeOut = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].keyframes = [TransformKeyframe(time: MediaTime(2, 1), transform: ClipTransform(x: 60), volume: 0.5)]
        let track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        try history.apply(.setRate(trackID: track.id, clipID: clip.id, rate: PlaybackRate(numerator: 2)))
        let changed = history.project.sequence.tracks[0].clips[0]
        XCTAssertEqual(changed.sourceStart, clip.sourceStart)
        XCTAssertEqual(changed.sourceDuration, clip.duration)
        XCTAssertEqual(changed.duration, MediaTime(2, 1))
        XCTAssertEqual(changed.fadeIn, MediaTime(1, 2))
        XCTAssertEqual(changed.audioFadeOut, MediaTime(1, 2))
        XCTAssertEqual(changed.keyframes?[0].time, MediaTime(1, 1))
        XCTAssertEqual(history.project.sequence.tracks[0].clips[1].start, MediaTime(2, 1))
        XCTAssertEqual(history.project.sequence.tracks[2], initial.sequence.tracks[2])
        history.undo(); XCTAssertEqual(history.project, initial)
        history.redo(); XCTAssertEqual(history.project.sequence.tracks[0].clips[0], changed)
        try history.apply(.setRate(trackID: track.id, clipID: clip.id, rate: PlaybackRate(numerator: 1, denominator: 2)))
        XCTAssertEqual(history.project.sequence.tracks[0].clips[0].duration, MediaTime(8, 1))
        XCTAssertEqual(history.project.sequence.tracks[0].clips[1].start, MediaTime(8, 1))
        XCTAssertEqual(history.project.sequence.tracks[0].clips[0].sourceDuration, MediaTime(4, 1))
    }
    func testRateSourceRangeValidationAndInvalidRatesAreAtomic() throws {
        let initial = project(), track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        for rate in [PlaybackRate(numerator: 0), PlaybackRate(numerator: -1), PlaybackRate(numerator: 5), PlaybackRate(denominator: 0), PlaybackRate(numerator: 1, denominator: 5)] {
            XCTAssertThrowsError(try history.apply(.setRate(trackID: track.id, clipID: clip.id, rate: rate)))
            XCTAssertEqual(history.project, initial)
        }
        var bad = clip; bad.sourceStart = MediaTime(18, 1); bad.playbackRate = PlaybackRate(numerator: 2)
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: bad)))
        XCTAssertFalse(history.canUndo)
    }
    func testSpeedSplitMapsSourceAndPreservesLinearAnimation() throws {
        var initial = project()
        initial.sequence.tracks[0].clips.removeLast()
        initial.sequence.tracks[0].clips[0].playbackRate = PlaybackRate(numerator: 3, denominator: 2)
        initial.sequence.tracks[0].clips[0].keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(x: 0), volume: 0), TransformKeyframe(time: MediaTime(4, 1), transform: ClipTransform(x: 100), volume: 1)]
        let track = initial.sequence.tracks[0], original = track.clips[0]
        var history = EditorHistory(project: initial)
        try history.apply(.split(trackID: track.id, clipID: original.id, at: MediaTime(1, 1)))
        let parts = history.project.sequence.tracks[0].clips
        XCTAssertEqual(parts[1].sourceStart, MediaTime(7, 2))
        XCTAssertEqual(parts[0].sourceDuration + parts[1].sourceDuration, original.sourceDuration)
        for time in [MediaTime(0), MediaTime(1, 2), MediaTime(1, 1), MediaTime(3, 2), MediaTime(5, 2)] {
            XCTAssertEqual(parts[1].evaluatedTransform(at: time).x, original.evaluatedTransform(at: time + MediaTime(1, 1)).x, accuracy: 0.00001)
            XCTAssertEqual(parts[1].evaluatedVolume(at: time), original.evaluatedVolume(at: time + MediaTime(1, 1)), accuracy: 0.00001)
        }
        history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testSplitPreservesFadeAndEaseAtOutputFrameTimes() throws {
        var initial = project(); initial.sequence.tracks[0].clips.removeLast()
        initial.sequence.tracks[0].clips[0].fadeIn = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].audioFadeOut = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(), interpolation: .ease), TransformKeyframe(time: MediaTime(4, 1), transform: ClipTransform(x: 100))]
        let track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        let cut = MediaTime(1, 2)
        try history.apply(.split(trackID: track.id, clipID: clip.id, at: cut))
        let parts = history.project.sequence.tracks[0].clips
        XCTAssertNil(parts[0].fadeIn); XCTAssertNil(parts[1].audioFadeOut)
        for frame in 0..<120 {
            let originalTime = MediaTime(Int64(frame), 30)
            let part = originalTime < cut ? parts[0] : parts[1]
            let local = originalTime - part.start
            let expectedOpacity = clip.evaluatedTransform(at: originalTime).opacity * ClipTemporalEditor.envelope(at: originalTime, duration: clip.duration, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
            let expectedVolume = clip.evaluatedVolume(at: originalTime) * ClipTemporalEditor.envelope(at: originalTime, duration: clip.duration, fadeIn: clip.audioFadeIn, fadeOut: clip.audioFadeOut)
            XCTAssertEqual(part.evaluatedTransform(at: local).x, clip.evaluatedTransform(at: originalTime).x, accuracy: 0.000001)
            XCTAssertEqual(part.evaluatedTransform(at: local).opacity, expectedOpacity, accuracy: 0.000001)
            XCTAssertEqual(part.evaluatedVolume(at: local), expectedVolume, accuracy: 0.000001)
        }
        history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testKeyframeInterpolationUsesOutgoingModeAndHoldsEndpoints() {
        var clip = Clip(transform: ClipTransform(x: 0), keyframes: [TransformKeyframe(time: MediaTime(1, 1), transform: ClipTransform(x: 100), volume: 0.5, interpolation: .hold), TransformKeyframe(time: MediaTime(2, 1), transform: ClipTransform(x: 200), volume: 1)])
        XCTAssertEqual(clip.evaluatedTransform(at: MediaTime(1, 2)).x, 50)
        XCTAssertEqual(clip.evaluatedTransform(at: MediaTime(3, 2)).x, 100)
        XCTAssertEqual(clip.evaluatedTransform(at: MediaTime(2, 1)).x, 200)
        XCTAssertEqual(clip.evaluatedTransform(at: MediaTime(20, 1)).x, 200)
        clip.keyframes?[0].interpolation = .ease
        XCTAssertEqual(clip.evaluatedTransform(at: MediaTime(5, 4)).x, 115.625)
        clip.keyframes?.insert(TransformKeyframe(time: .zero, transform: ClipTransform(x: 25)), at: 0)
        XCTAssertEqual(clip.evaluatedTransform(at: MediaTime(-1, 1)).x, 25)
    }
    func testBatchIsSingleUndoAndFailureRollsBackEverySubcommand() throws {
        let initial = Project()
        let asset = MediaAsset(name: "이미지", path: "/fixture/a.png", kind: .image)
        let track = initial.sequence.tracks[0]
        let clip = Clip(assetID: asset.id)
        var history = EditorHistory(project: initial)
        XCTAssertThrowsError(try history.apply(.batch([.addAsset(asset), .addClip(trackID: track.id, clip: Clip(assetID: UUID()))])))
        XCTAssertEqual(history.project, initial); XCTAssertFalse(history.canUndo)
        try history.apply(.batch([.addAsset(asset), .addClip(trackID: track.id, clip: clip)]))
        let edited = history.project
        history.undo(); XCTAssertEqual(history.project, initial); XCTAssertFalse(history.canUndo)
        history.redo(); XCTAssertEqual(history.project, edited)
    }
    func testBatchMoveValidatesFinalLayoutAndHandlesInvalidIntermediateArithmetic() throws {
        let initial = project(), track = initial.sequence.tracks[0]
        var history = EditorHistory(project: initial)
        try history.apply(.batch(track.clips.map { .move(trackID: track.id, clipID: $0.id, to: $0.start + MediaTime(1, 1)) }))
        XCTAssertEqual(history.project.sequence.tracks[0].clips.map(\.start), [MediaTime(1, 1), MediaTime(5, 1)])
        history.undo(); XCTAssertEqual(history.project, initial)
        var malformed = track.clips[0]; malformed.start = MediaTime(Int64.max, 1)
        XCTAssertThrowsError(try history.apply(.batch([.updateClip(trackID: track.id, clip: malformed), .split(trackID: track.id, clipID: malformed.id, at: MediaTime(2, 1))])))
        XCTAssertEqual(history.project, initial)
    }
    func testDuplicateTracksRelinkAndLockChecks() throws {
        let initial = project(), track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        try history.apply(.duplicate(trackID: track.id, clipID: clip.id))
        let clips = history.project.sequence.tracks[0].clips
        XCTAssertEqual(clips.count, 3); XCTAssertNotEqual(clips[0].id, clips[1].id)
        XCTAssertEqual(clips.map(\.start), [.zero, MediaTime(4, 1), MediaTime(8, 1)])
        history.undo(); XCTAssertEqual(history.project, initial)
        let newTrack = Track(name: "새 오디오", kind: .audio)
        try history.apply(.addTrack(newTrack)); try history.apply(.removeTrack(newTrack.id))
        XCTAssertEqual(history.project.sequence.tracks, initial.sequence.tracks)
        var relink = initial.assets[0]; relink.path = "/new/장면.mp4"
        try history.apply(.replaceAsset(relink)); XCTAssertEqual(history.project.assets[0].path, relink.path)
        var locked = track; locked.isLocked = true
        try history.apply(.updateTrack(locked))
        XCTAssertThrowsError(try history.apply(.removeTrack(track.id)))
        XCTAssertThrowsError(try history.apply(.replaceSequence(Sequence())))
        XCTAssertThrowsError(try history.apply(.duplicate(trackID: track.id, clipID: clip.id)))
    }
    func testDerivedSequenceUsesIndependentIDsKeepsMediaAndUndo() throws {
        let initial = project()
        var history = EditorHistory(project: initial)
        try history.apply(.deriveSequence(name: "가로 버전", width: 1920, height: 1080))
        let derived = history.project.sequence
        XCTAssertNotEqual(derived.id, initial.sequence.id)
        XCTAssertNotEqual(derived.tracks[0].id, initial.sequence.tracks[0].id)
        XCTAssertNotEqual(derived.tracks[0].clips[0].id, initial.sequence.tracks[0].clips[0].id)
        XCTAssertEqual(derived.tracks[0].clips[0].assetID, initial.assets[0].id)
        var changed = derived.tracks[0].clips[0]; changed.transform.x = 120
        try history.apply(.updateClip(trackID: derived.tracks[0].id, clip: changed))
        try history.apply(.activateDerivedSequence(initial.sequence.id))
        XCTAssertEqual(history.project.sequence, initial.sequence)
        XCTAssertEqual(history.project.derivedSequences?[0].tracks[0].clips[0].transform.x, 120)
        history.undo(); XCTAssertEqual(history.project.sequence.tracks[0].clips[0].transform.x, 120)
        history.undo(); history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testMalformedEffectsKeyframesAndFadesRejected() throws {
        let initial = project(), track = initial.sequence.tracks[0], clip = track.clips[0]
        var history = EditorHistory(project: initial)
        var invalid = clip; invalid.visual = VisualAdjustments(cropLeft: 0.7, cropRight: 0.3)
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: invalid)))
        invalid = clip; invalid.visual = VisualAdjustments(exposure: .infinity)
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: invalid)))
        invalid = clip; invalid.fadeIn = MediaTime(3, 1); invalid.fadeOut = MediaTime(2, 1)
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: invalid)))
        invalid = clip; invalid.keyframes = [TransformKeyframe(time: MediaTime(2, 1), transform: ClipTransform()), TransformKeyframe(time: MediaTime(2, 1), transform: ClipTransform(x: 3))]
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: invalid)))
        invalid = clip; invalid.keyframes = [TransformKeyframe(time: MediaTime(5, 1), transform: ClipTransform())]
        XCTAssertThrowsError(try history.apply(.updateClip(trackID: track.id, clip: invalid)))
        XCTAssertEqual(history.project, initial)
    }
    func testPresetsUseInstalledFontHaveUniqueIDsAndValidStyles() throws {
        XCTAssertGreaterThanOrEqual(TitlePreset.builtIns.count, 20)
        XCTAssertEqual(Set(TitlePreset.builtIns.map(\.id)).count, TitlePreset.builtIns.count)
        for preset in TitlePreset.builtIns {
            XCTAssertNotNil(NSFont(name: preset.title.fontName, size: preset.title.fontSize))
            var p = Project(); p.sequence.tracks[2].clips = [Clip(title: preset.title)]
            try ProjectValidator.validate(p)
        }
        var p = Project(); p.sequence.tracks[2].clips = [Clip(title: Title(text: "한글", style: TextStyle(maxLines: -1)))]
        XCTAssertThrowsError(try ProjectValidator.validate(p))
    }
    func testLegacyG0JSONStillDecodesAndProvenancePersists() throws {
        var legacy = project()
        let bytes = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(Project.self, from: bytes)
        XCTAssertNil(decoded.sequence.tracks[0].clips[0].playbackRate)
        XCTAssertNil(decoded.sequence.tracks[2].clips[0].title?.style)
        XCTAssertNil(decoded.derivedSequences)
        legacy.assets[0].provenance = AssetProvenance(sourceURL: "https://example.invalid/original", author: "원작자", license: "CC0", licenseURL: "https://example.invalid/license", sha256: "abc")
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(legacy)), legacy)
    }
}

final class SRTAndRecoveryTests: XCTestCase {
    func testSRTBOMCRLFKoreanMultilineAndRoundTrip() throws {
        let text = "\u{FEFF}1\r\n00:00:01,001 --> 00:00:03,500\r\n종현의 첫 영상\r\n두 번째 줄!\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,100\r\n한글 · 춘천\r\n"
        let cues = try SRTCodec.parse(text)
        XCTAssertEqual(cues.count, 2); XCTAssertEqual(cues[0].start, MediaTime(1001, 1000))
        XCTAssertEqual(cues[0].text, "종현의 첫 영상\n두 번째 줄!")
        let decoded = try SRTCodec.parse(SRTCodec.serialize(cues))
        XCTAssertEqual(decoded.map(\.text), cues.map(\.text)); XCTAssertEqual(decoded.map(\.duration), cues.map(\.duration))
        let clips = SRTCodec.clips(from: cues, style: TitlePreset.builtIns[0].title)
        XCTAssertEqual(clips[0].title?.text, cues[0].text); XCTAssertEqual(clips[0].id, cues[0].id)
    }
    func testMalformedSRTRejectedAndHoursNotTruncated() throws {
        for bad in ["1\n-00:00:01,000 --> 00:00:02,000\n음수", "1\n00:00:02,000 --> 00:00:01,000\n역순", "1\n00:60:00,000 --> 01:01:00,000\n분 오류", "1\n00:00:00,000 --> 00:00:01,000", "time\n00:00:00,000 --> 00:00:01,000\n번호 오류"] {
            XCTAssertThrowsError(try SRTCodec.parse(bad))
        }
        let cue = CaptionCue(start: MediaTime(360_000, 1), duration: MediaTime(1, 1), text: "100시간")
        let text = try SRTCodec.serialize([cue]); XCTAssertTrue(text.contains("100:00:00,000"))
        XCTAssertEqual(try SRTCodec.parse(text)[0].start, cue.start)
        XCTAssertThrowsError(try SRTCodec.serialize([CaptionCue(start: .zero, duration: MediaTime(1, 100_000), text: "너무 짧음")]))
    }
    func testRecoveryWritesOnlyItsDirectoryAndRequiresExplicitBackupRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JH 복구 \(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecoveryStore(directory: folder.appendingPathComponent("복구"))
        XCTAssertNil(try store.load())
        let document = folder.appendingPathComponent("원본.jhcut"), base = folder.appendingPathComponent("이전 프로젝트.jhcut")
        let first = Project(name: "첫 복구")
        try store.save(project: first, documentURL: document, mediaBaseURL: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.path))
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.project, first); XCTAssertEqual(saved.mediaBaseURL, base); XCTAssertEqual(saved.documentURL, document)
        try store.save(project: Project(name: "둘째 복구"), documentURL: document, mediaBaseURL: base)
        XCTAssertEqual(try store.loadPrevious()?.project, first)
        try Data("손상".utf8).write(to: store.snapshotURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try store.loadPrevious()?.project, first)
        try store.clear(); XCTAssertNil(try store.load()); XCTAssertNil(try store.loadPrevious())
    }
    func testDeferredProjectRecoverySurvivesOtherProjectsRepeatedSavesAndSelectiveClear() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JH 복구 보관 \(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecoveryStore(directory: folder)
        let first = Project(name: "나중에 복구할 A")
        var second = Project(name: "현재 작업 B")
        try store.save(project: first, documentURL: nil, mediaBaseURL: nil)
        try store.save(project: second, documentURL: nil, mediaBaseURL: nil)
        for index in 0..<4 {
            second.name = "B 수정 \(index)"
            try store.save(project: second, documentURL: nil, mediaBaseURL: nil)
        }
        let choices = try store.availableSnapshots()
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices[0].project, second)
        XCTAssertEqual(choices.first(where: { $0.project.id == first.id })?.project, first)
        try store.clear(projectID: second.id)
        XCTAssertNil(try store.load()); XCTAssertNil(try store.loadPrevious())
        XCTAssertEqual(try store.availableSnapshots().map(\.project), [first])
        try store.clear(projectID: first.id)
        XCTAssertTrue(try store.availableSnapshots().isEmpty)
    }
    func testAnotherProjectsLastGoodBackupSurvivesCorruptionAndSlotReuse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JH 복구 손상 \(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecoveryStore(directory: folder)
        let first = Project(name: "A 마지막 정상본"), second = Project(name: "B")
        try store.save(project: first, documentURL: nil, mediaBaseURL: nil)
        try store.save(project: first, documentURL: nil, mediaBaseURL: nil)
        try Data("손상된 현재 파일".utf8).write(to: store.snapshotURL)
        try store.save(project: second, documentURL: nil, mediaBaseURL: nil)
        try store.save(project: second, documentURL: nil, mediaBaseURL: nil)
        XCTAssertEqual(try store.availableSnapshots().first(where: { $0.project.id == first.id })?.project, first)
    }
}

final class AdvancedCommandTests: XCTestCase {
    private func project() -> Project {
        var p = Project()
        let source = MediaAsset(name: "원본", path: "/fixture/original.mp4", kind: .video, duration: MediaTime(20, 1), hasAudio: true)
        p.assets = [source]
        p.sequence.tracks[0].clips = [Clip(name: "앞", assetID: source.id, sourceStart: MediaTime(2, 1), duration: MediaTime(4, 1), playbackRate: PlaybackRate(numerator: 3, denominator: 2)), Clip(name: "뒤", assetID: source.id, start: MediaTime(4, 1), duration: MediaTime(4, 1))]
        p.sequence.tracks[2].clips = [Clip(start: MediaTime(3, 1), title: Title(text: "독립 자막"))]
        return p
    }
    func testSeparateAudioPreservesTimingRateFadesAndVolumeKeysAndMutesOriginalKeys() throws {
        var initial = project()
        initial.sequence.tracks[0].clips[0].volume = 0.7
        initial.sequence.tracks[0].clips[0].audioFadeIn = MediaTime(1, 2)
        initial.sequence.tracks[0].clips[0].audioFadeOut = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(x: 5), volume: 0.8), TransformKeyframe(time: MediaTime(4, 1), transform: ClipTransform(x: 50), volume: 0.2)]
        let track = initial.sequence.tracks[0], original = track.clips[0]
        var history = EditorHistory(project: initial)
        try history.apply(.separateAudio(trackID: track.id, clipID: original.id))
        let audio = try XCTUnwrap(history.project.sequence.tracks.first(where: { $0.kind == .audio })?.clips.first)
        XCTAssertEqual(audio.assetID, original.assetID); XCTAssertEqual(audio.sourceStart, original.sourceStart)
        XCTAssertEqual(audio.duration, original.duration); XCTAssertEqual(audio.playbackRate, original.playbackRate)
        XCTAssertEqual(audio.audioFadeIn, original.audioFadeIn); XCTAssertEqual(audio.audioFadeOut, original.audioFadeOut)
        for frame in 0..<120 {
            let time = MediaTime(Int64(frame), 30)
            XCTAssertEqual(audio.evaluatedVolume(at: time), original.evaluatedVolume(at: time), accuracy: 0.000001)
            XCTAssertEqual(history.project.sequence.tracks[0].clips[0].evaluatedVolume(at: time), 0)
            XCTAssertEqual(history.project.sequence.tracks[0].clips[0].evaluatedTransform(at: time), original.evaluatedTransform(at: time))
        }
        history.undo(); XCTAssertEqual(history.project, initial)
        history.redo(); XCTAssertEqual(history.project.sequence.tracks[3].clips.first?.id, audio.id)
    }
    func testAudioSeparationRejectsLockedDestinationAtomically() throws {
        var initial = project(); initial.sequence.tracks[3].isLocked = true
        let video = initial.sequence.tracks[0], audio = initial.sequence.tracks[3]
        var history = EditorHistory(project: initial)
        XCTAssertThrowsError(try history.apply(.separateAudio(trackID: video.id, clipID: video.clips[0].id, destinationTrackID: audio.id)))
        XCTAssertEqual(history.project, initial); XCTAssertFalse(history.canUndo)
    }
    func testInsertionSplitsSourceExactlyAndRipplesOnlySelectedTrack() throws {
        let initial = project(), track = initial.sequence.tracks[0]
        let inserted = Clip(name: "삽입", assetID: initial.assets[0].id, duration: MediaTime(1, 1))
        var history = EditorHistory(project: initial)
        try history.apply(.insertClip(trackID: track.id, clip: inserted, at: MediaTime(2, 1)))
        let clips = history.project.sequence.tracks[0].clips
        XCTAssertEqual(clips.map(\.start), [.zero, MediaTime(2, 1), MediaTime(3, 1), MediaTime(5, 1)])
        XCTAssertEqual(clips.map(\.duration), [MediaTime(2, 1), MediaTime(1, 1), MediaTime(2, 1), MediaTime(4, 1)])
        XCTAssertEqual(clips[2].sourceStart, MediaTime(5, 1))
        XCTAssertEqual(clips[0].sourceDuration + clips[2].sourceDuration, track.clips[0].sourceDuration)
        XCTAssertEqual(history.project.sequence.tracks[2], initial.sequence.tracks[2])
        history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testOverwriteAcrossClipsPreservesUnaffectedSourceFragmentsAndDuration() throws {
        let initial = project(), track = initial.sequence.tracks[0]
        let inserted = Clip(name: "대체", assetID: initial.assets[0].id, duration: MediaTime(3, 1))
        var history = EditorHistory(project: initial)
        try history.apply(.overwriteClip(trackID: track.id, clip: inserted, at: MediaTime(2, 1)))
        let clips = history.project.sequence.tracks[0].clips
        XCTAssertEqual(clips.map(\.start), [.zero, MediaTime(2, 1), MediaTime(5, 1)])
        XCTAssertEqual(clips.map(\.duration), [MediaTime(2, 1), MediaTime(3, 1), MediaTime(3, 1)])
        XCTAssertEqual(clips[2].sourceStart, MediaTime(1, 1))
        XCTAssertEqual(history.project.sequence.duration, initial.sequence.duration)
        history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testTrimBakesEaseAndFadesAtExactOutputFramesAndUndo() throws {
        var initial = project(); initial.sequence.tracks[0].clips.removeLast()
        initial.sequence.tracks[0].clips[0].fadeIn = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].audioFadeOut = MediaTime(1, 1)
        initial.sequence.tracks[0].clips[0].keyframes = [TransformKeyframe(time: .zero, transform: ClipTransform(x: 0), volume: 0.4, interpolation: .ease), TransformKeyframe(time: MediaTime(4, 1), transform: ClipTransform(x: 100), volume: 0.9)]
        let track = initial.sequence.tracks[0], original = track.clips[0]
        var history = EditorHistory(project: initial)
        let offset = MediaTime(1, 2)
        try history.apply(.trimClip(trackID: track.id, clipID: original.id, newStart: offset, newSourceStart: original.sourceStart + original.playbackRate!.sourceDuration(for: offset), newDuration: MediaTime(3, 1)))
        let changed = history.project.sequence.tracks[0].clips[0]
        for index in 15..<105 {
            let time = MediaTime(Int64(index), 30), local = time - offset
            XCTAssertEqual(changed.evaluatedTransform(at: local).x, original.evaluatedTransform(at: time).x, accuracy: 0.000001)
            XCTAssertEqual(changed.evaluatedTransform(at: local).opacity, ClipTemporalEditor.envelope(at: time, duration: original.duration, fadeIn: original.fadeIn, fadeOut: original.fadeOut), accuracy: 0.000001)
            XCTAssertEqual(changed.evaluatedVolume(at: local), original.evaluatedVolume(at: time) * ClipTemporalEditor.envelope(at: time, duration: original.duration, fadeIn: original.audioFadeIn, fadeOut: original.audioFadeOut), accuracy: 0.000001)
        }
        XCTAssertNil(changed.fadeIn); XCTAssertNil(changed.audioFadeOut)
        history.undo(); XCTAssertEqual(history.project, initial)
    }
    func testTitleTrimAndSplitKeepZeroSourceAndBoundedAnimation() throws {
        var initial = Project()
        let clip = Clip(start: MediaTime(1, 1), duration: MediaTime(4, 1), title: Title(text: "종현의 한글 자막"), fadeIn: MediaTime(1, 1))
        initial.sequence.tracks[2].clips = [clip]
        let track = initial.sequence.tracks[2]
        var history = EditorHistory(project: initial)
        try history.apply(.trimClip(trackID: track.id, clipID: clip.id, newStart: MediaTime(3, 2), newSourceStart: .zero, newDuration: MediaTime(3, 1)))
        try history.apply(.split(trackID: track.id, clipID: clip.id, at: MediaTime(2, 1)))
        XCTAssertTrue(history.project.sequence.tracks[2].clips.allSatisfy { $0.sourceStart == .zero })
        XCTAssertEqual(history.project.sequence.tracks[2].clips[0].evaluatedTransform(at: .zero).opacity, 0.5, accuracy: 0.000001)
        history.undo(); history.undo(); XCTAssertEqual(history.project, initial)
        var tooLong = clip; tooLong.duration = MediaTime(2_000, 1)
        XCTAssertThrowsError(try ClipTemporalEditor.trimmed(tooLong, newStart: .zero, newSourceStart: .zero, newDuration: tooLong.duration, frameRate: FrameRate(), temporalSource: false))
        XCTAssertThrowsError(try ClipTemporalEditor.trimmed(clip, newStart: MediaTime(1_000_000_000_000_000, 1), newSourceStart: .zero, newDuration: MediaTime(1, 1), frameRate: FrameRate(numerator: 30_000, denominator: 1_001), temporalSource: false))
    }
}

final class CaptionEditingTests: XCTestCase {
    func testMergePreservesStyleCoversGapAndUsesZeroSource() throws {
        let first = Clip(start: MediaTime(1, 1), duration: MediaTime(2, 1), title: Title(text: "첫 번째 문장"))
        let second = Clip(start: MediaTime(4, 1), duration: MediaTime(2, 1), title: Title(text: "두 번째 문장"))
        let merged = try CaptionEditing.merged(first: first, second: second)
        XCTAssertEqual(merged.id, first.id); XCTAssertEqual(merged.start, first.start); XCTAssertEqual(merged.duration, MediaTime(5, 1))
        XCTAssertEqual(merged.title?.text, "첫 번째 문장\n두 번째 문장"); XCTAssertEqual(merged.sourceStart, .zero)
        var p = Project(); p.sequence.tracks[2].clips = [merged]
        try ProjectValidator.validate(p)
        var history = EditorHistory(project: p)
        try history.apply(.split(trackID: p.sequence.tracks[2].id, clipID: merged.id, at: MediaTime(3, 1)))
        XCTAssertTrue(history.project.sequence.tracks[2].clips.allSatisfy { $0.sourceStart == .zero })
    }
    func testMergeRejectsStyleMotionAndOverlapWithoutDroppingInformation() throws {
        let first = Clip(duration: MediaTime(2, 1), title: Title(text: "하나"))
        var second = Clip(start: MediaTime(2, 1), duration: MediaTime(2, 1), title: Title(text: "둘", colorHex: "FFFF00"))
        XCTAssertThrowsError(try CaptionEditing.merged(first: first, second: second))
        second.title?.colorHex = "FFFFFF"; second.fadeIn = MediaTime(1, 2)
        XCTAssertThrowsError(try CaptionEditing.merged(first: first, second: second))
        second.fadeIn = nil; second.start = MediaTime(1, 1)
        XCTAssertThrowsError(try CaptionEditing.merged(first: first, second: second))
    }
    func testCaptionShiftIsExactAndRejectsNegativeStartAtomically() throws {
        let clips = [Clip(start: MediaTime(1, 1000), title: Title(text: "한글")), Clip(start: MediaTime(30000, 1001), title: Title(text: "타이밍"))]
        let offset = MediaTime(1001, 30000)
        let shifted = try CaptionEditing.shifted(clips, by: offset)
        XCTAssertEqual(shifted[0].start, clips[0].start + offset)
        XCTAssertEqual(shifted[1].duration, clips[1].duration)
        XCTAssertEqual(try CaptionEditing.shifted(shifted, by: .zero - offset), clips)
        XCTAssertThrowsError(try CaptionEditing.shifted(clips, by: MediaTime(-1, 1)))
    }
    func testSubtitleDecoderSupportsKoreanUTFBOMsAndCP949Losslessly() throws {
        let text = "1\r\n00:00:00,000 --> 00:00:01,000\r\n종현의 첫 영상\r\n"
        XCTAssertEqual(try SubtitleTextDecoder.decode(Data([0xEF,0xBB,0xBF]) + Data(text.utf8)), text)
        XCTAssertEqual(try SubtitleTextDecoder.decode(Data([0xFF,0xFE]) + XCTUnwrap(text.data(using: .utf16LittleEndian))), text)
        XCTAssertEqual(try SubtitleTextDecoder.decode(Data([0xFE,0xFF]) + XCTUnwrap(text.data(using: .utf16BigEndian))), text)
        let cp949: [UInt8] = [0xC1,0xBE,0xC7,0xF6,0xC0,0xC7,0x20,0xC3,0xB9,0x20,0xBF,0xB5,0xBB,0xF3]
        XCTAssertEqual(try SubtitleTextDecoder.decode(Data(cp949)), "종현의 첫 영상")
        XCTAssertEqual(try SubtitleTextDecoder.decode(Data(cp949), encoding: .cp949), "종현의 첫 영상")
        XCTAssertThrowsError(try SubtitleTextDecoder.decode(Data([0xFF])))
        XCTAssertThrowsError(try SubtitleTextDecoder.decode(Data([0xFF,0xFE,0x00])))
        XCTAssertThrowsError(try SubtitleTextDecoder.decode(Data([0xFF,0xFE]) + XCTUnwrap(text.data(using: .utf16LittleEndian)), encoding: .utf8))
    }
}

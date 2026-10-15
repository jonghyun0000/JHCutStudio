import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import JHCutCore

// MARK: - Speed ramp, freeze frame and reverse (priority 3 after the Final Cut comparison)

extension EditorModel {
    private var generatedMediaFolder: URL { generatedMediaRoot }

    /// The selected video or audio clip when speed tools can work on it.
    var speedToolsSelection: (Track, Clip, MediaAsset)? {
        guard let (track, clip) = selected, clip.title == nil, let id = clip.assetID,
              let asset = project.assets.first(where: { $0.id == id }), asset.kind == .video || asset.kind == .audio else { return nil }
        return (track, clip, asset)
    }

    private func hasConnectedMedia(_ clip: Clip) -> Bool {
        project.sequence.tracks.flatMap(\.clips).contains { $0.connection?.parentID == clip.id && $0.title == nil }
    }

    // MARK: Speed ramp

    /// Turns the selected clip into a speed ramp (one undo step). `rates` come from `SpeedRampPlan`.
    func applySpeedRamp(rates: [PlaybackRate], mutesAudio: Bool, label: String) {
        guard !busyDocument else { return }
        guard let (track, clip, _) = speedToolsSelection else { error = "속도 램프는 선택한 영상 또는 오디오 클립에만 쓸 수 있습니다."; return }
        guard !track.isLocked else { error = "잠긴 트랙의 클립은 바꿀 수 없습니다. 잠금을 해제하세요."; return }
        guard !hasConnectedMedia(clip) else { error = "분리된 오디오가 연결돼 있어 속도 램프를 만들 수 없습니다. 오디오 연결을 해제하거나 삭제한 뒤 다시 시도하세요."; return }
        let before = clip.duration.seconds
        if perform(.speedRamp(trackID: track.id, clipID: clip.id, rates: rates, mutesAudio: mutesAudio)) {
            message = "\(label) 적용 · \(rates.count)조각으로 나눠 조각마다 속도를 바꿨습니다 · 길이 \(String(format: "%.1f", before))초 → 약 \(String(format: "%.1f", rampLength(rates, clip: clip)))초 · ⌘Z로 되돌릴 수 있습니다."
        }
    }

    /// Timeline length of the ramp: every equal source piece lasts (piece / speed).
    private func rampLength(_ rates: [PlaybackRate], clip: Clip) -> Double {
        let piece = clip.sourceDuration.seconds / Double(rates.count)
        return rates.reduce(0) { $0 + piece / max(0.0001, $1.multiplier) }
    }

    func applySpeedRamp(preset: SpeedRampPreset, pieces: Int, mutesAudio: Bool) {
        applySpeedRamp(rates: SpeedRampPlan.rates(preset, pieces: pieces), mutesAudio: mutesAudio, label: preset.label)
    }

    func applySpeedRamp(from start: Double, to end: Double, pieces: Int, mutesAudio: Bool) {
        guard SpeedRampPlan.speedRange.contains(start), SpeedRampPlan.speedRange.contains(end) else {
            error = String(format: "속도는 %g배~%g배 사이로 정하세요.", SpeedRampPlan.speedRange.lowerBound, SpeedRampPlan.speedRange.upperBound); return
        }
        applySpeedRamp(rates: SpeedRampPlan.rates(from: start, to: end, pieces: pieces), mutesAudio: mutesAudio, label: String(format: "%g배 → %g배", start, end))
    }

    /// Pieces that suit the selected clip.
    var suggestedRampPieces: Int {
        guard let (_, clip, _) = speedToolsSelection else { return 8 }
        return SpeedRampPlan.suggestedPieces(timelineSeconds: clip.duration.seconds)
    }

    // MARK: Freeze frame

    /// Why a freeze frame cannot be made at the playhead, or nil when it can.
    var freezeFrameProblem: String? {
        guard let (track, clip, asset) = speedToolsSelection, asset.kind == .video else { return "정지 화면은 선택한 영상 클립에서 만들 수 있습니다." }
        guard track.kind == .video else { return "정지 화면은 메인 영상 트랙의 클립에서 만들 수 있습니다." }
        guard !track.isLocked else { return "잠긴 트랙입니다. 잠금을 해제하세요." }
        let time = frameRate.time(forFrame: Int64((playhead * frameRate.fps).rounded()))
        guard time >= clip.start, time < clip.end else { return "재생 위치를 선택한 클립 안으로 옮기세요." }
        return nil
    }

    /// Takes the frame under the playhead of the selected clip and inserts it as a still of `seconds` at that point;
    /// the rest of the clip and everything after it moves later (one undo step).
    func makeFreezeFrame(seconds: Double) {
        guard !busyDocument else { return }
        if let problem = freezeFrameProblem { error = problem; return }
        guard FreezeFrame.secondsRange.contains(seconds) else {
            error = String(format: "정지 화면 길이는 %g~%g초 사이로 정하세요.", FreezeFrame.secondsRange.lowerBound, FreezeFrame.secondsRange.upperBound); return
        }
        guard let (track, clip, asset) = speedToolsSelection else { return }
        let at = frameRate.time(forFrame: Int64((playhead * frameRate.fps).rounded()))
        let snapshot = project, baseURL = mediaBaseURL, sourceDocumentURL = documentURL, folder = generatedMediaFolder
        let length = frameRate.time(forFrame: max(1, Int64((seconds * frameRate.fps).rounded())))
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; productivityStatus = "정지 화면 만드는 중…"
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            var written: URL?
            do {
                try validateAsyncJob(ticket)
                let identity = try await EditorSourceIdentity.capture(asset.resolvedURL(relativeTo: baseURL))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = folder.appendingPathComponent("정지-" + UUID().uuidString + ".png")
                written = png
                try await Self.extractRenderedFrame(project: snapshot, clip: clip, documentURL: baseURL, at: at, to: png)
                try Task.checkCancellation()
                guard project == snapshot, mediaBaseURL == baseURL, documentURL == sourceDocumentURL else { throw ProjectError("작업 중 프로젝트가 변경되었습니다. 오래된 결과를 잘못 적용하지 않도록 중단했습니다. 다시 실행하세요.") }
                var image = try await MediaImporter.inspect(url: png)
                guard image.supported else { throw ProjectError(image.issue ?? "정지 화면 이미지를 읽지 못했습니다.") }
                image.name = clip.name + " · 정지 화면"; image.duration = MediaTime(seconds: FreezeFrame.secondsRange.upperBound)
                let freezeSource = try? FreezeFrame.sourceTime(of: clip, at: at)
                let freezeRecord = try await GeneratedMediaRegistry.register(file: png, purpose: .freezeFrame, projectID: snapshot.id, jobID: ticket.id,
                                                                            sourceName: asset.name, sourceSHA256: asset.contentHash,
                                                                            sourceStart: freezeSource?.seconds)
                image.contentHash = freezeRecord.sha256
                // The PNG already contains the selected clip's evaluated appearance on
                // the sequence canvas. Applying its adjustments again would double them.
                var still = Clip(name: clip.name + " · 정지 화면", assetID: image.id, start: at, duration: length)
                // The isolated PNG bakes source appearance, not its interaction with lower tracks.
                still.blendMode = clip.blendMode
                try Task.checkCancellation()
                guard project == snapshot, mediaBaseURL == baseURL, documentURL == sourceDocumentURL else { throw ProjectError("작업 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                try await checkpointAsyncJob(ticket, "freeze.beforeApply")
                try await identity.validate(); try validateAsyncJob(ticket)
                if perform(.batch([.addAsset(image), .insertClip(trackID: track.id, clip: still, at: at)])) {
                    message = String(format: "정지 화면 %.1f초를 삽입했습니다 · 뒤 장면이 그만큼 밀렸습니다 · ⌘Z로 되돌릴 수 있습니다.", length.seconds)
                    selectedClipID = still.id; selectedClipIDs = [still.id]
                } else if let png = written { GeneratedMediaRegistry.discard(png) }
            } catch {
                if let written { GeneratedMediaRegistry.discard(written) }
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled { message = "정지 화면 만들기 취소됨 · 프로젝트는 바뀌지 않았습니다." }
                else { self.error = error.localizedDescription; message = "정지 화면을 만들지 못했습니다 · 프로젝트는 바뀌지 않았습니다." }
            }
        }
    }

    nonisolated static func extractRenderedFrame(project: Project, clip: Clip, documentURL: URL?, at time: MediaTime, to destination: URL) async throws {
        // Keep the original timeline origin: fractional frame phases and keyframe local
        // times must be identical to preview. Titles/overlays are independent layers.
        var isolated = project
        var selected = clip; selected.connection = nil; selected.blendMode = nil
        isolated.sequence.tracks = [Track(name: "정지 화면 원본", kind: .video, clips: [selected])]
        isolated.derivedSequences = nil
        let plan = try await TimelineRenderer.build(project: isolated, documentURL: documentURL, transparentBackground: true)
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: plan.composition)
        generator.videoComposition = plan.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: time.cmTime)
        try Task.checkCancellation()
        guard let target = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ProjectError("정지 화면 파일을 만들지 못했습니다.") }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw ProjectError("정지 화면 파일을 저장하지 못했습니다.") }
    }

    // MARK: Reverse

    /// Why the selected clip cannot be reversed, or nil when it can.
    var reverseProblem: String? {
        guard let (track, clip, asset) = speedToolsSelection, asset.kind == .video else { return "거꾸로 재생은 선택한 영상 클립에서 만들 수 있습니다." }
        guard !track.isLocked else { return "잠긴 트랙입니다. 잠금을 해제하세요." }
        guard clip.sourceDuration.seconds <= ReverseRenderer.maximumSeconds else { return "거꾸로 사본은 클립당 \(Int(ReverseRenderer.maximumSeconds))초까지 만들 수 있습니다. 클립을 나눈 뒤 각각 만드세요." }
        guard !hasConnectedMedia(clip) else { return "분리된 오디오가 연결돼 있어 거꾸로 만들 수 없습니다. 오디오 연결을 해제하거나 삭제하세요." }
        return nil
    }

    /// Writes a reversed copy of the selected clip's source range as a new file (the original is never touched) and
    /// points the clip at it (one undo step). Progress and cancel use the shared task area; cancelling leaves nothing.
    func reverseSelectedClip() {
        guard !busyDocument else { return }
        if let problem = reverseProblem { error = problem; return }
        guard let (track, clip, asset) = speedToolsSelection else { return }
        let snapshot = project, url = asset.resolvedURL(relativeTo: mediaBaseURL), folder = generatedMediaFolder
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; productivityStatus = "거꾸로 사본 만드는 중 · 0%"
        let begun = Date()
        let ticket = beginAsyncJob(.productivity)
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            let destination = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-거꾸로-" + UUID().uuidString + ".mp4")
            do {
                try validateAsyncJob(ticket)
                let identity = try await EditorSourceIdentity.capture(url)
                let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in self?.acceptProductivityProgress("거꾸로 사본 만드는 중 · \(Int(fraction * 100))%", ticket: ticket) }
                }
                asyncProgressObserver?("reverse", progress)
                var reversed = try await ReverseRenderer.render(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration, destination: destination, progress: progress)
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("작업 중 프로젝트가 변경되었습니다. 오래된 결과를 잘못 적용하지 않도록 중단했습니다. 다시 실행하세요.") }
                reversed.name = asset.name + " · 거꾸로"
                let reverseRecord = try await GeneratedMediaRegistry.register(file: destination, purpose: .reversed, projectID: snapshot.id, jobID: ticket.id,
                                                                             sourceName: asset.name, sourceSHA256: asset.contentHash,
                                                                             sourceStart: clip.sourceStart.seconds, sourceDuration: clip.sourceDuration.seconds)
                reversed.contentHash = reverseRecord.sha256
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("작업 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                var value = clip
                value.assetID = reversed.id; value.sourceStart = .zero
                // The copy covers exactly the clip's source range; the measured camera path belonged to the forward footage.
                value.stabilization = nil
                if reversed.duration < clip.sourceDuration { value.duration = try clip.duration.scaled(numerator: Int32(clamping: Int((reversed.duration.seconds * 1000).rounded())), denominator: Int32(clamping: Int((clip.sourceDuration.seconds * 1000).rounded()))) }
                var commands: [EditCommand] = [.addAsset(reversed), .updateClip(trackID: track.id, clip: value)]
                let originalEnd = try clip.sourceStart.adding(clip.sourceDuration)
                for captionTrack in snapshot.sequence.tracks {
                    for caption in captionTrack.clips where caption.connection?.parentID == clip.id {
                        guard caption.title != nil, let link = caption.connection else { throw ProjectError("연결된 오디오를 먼저 분리하세요.") }
                        let oldEnd = try link.sourceStart.adding(link.sourceDuration)
                        let begin = max(.zero, originalEnd - oldEnd)
                        let end = min(value.sourceDuration, originalEnd - link.sourceStart)
                        guard end > begin else { throw ProjectError("역재생 사본 범위에 연결 자막을 보존할 수 없습니다. 원본 클립을 유지했습니다.") }
                        var mapped = caption
                        let rate = value.playbackRate ?? PlaybackRate()
                        mapped.start = try value.start.adding(rate.timelineDuration(for: begin))
                        mapped.duration = rate.timelineDuration(for: end - begin)
                        mapped.connection = ClipConnection(parentID: value.id, sourceStart: begin, sourceDuration: end - begin, generatedText: link.generatedText)
                        commands.append(.updateClip(trackID: captionTrack.id, clip: mapped))
                    }
                }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("작업 중 프로젝트가 변경되었습니다. 다시 실행하세요.") }
                try await checkpointAsyncJob(ticket, "reverse.beforeApply")
                try await identity.validate(); try validateAsyncJob(ticket)
                if perform(.batch(commands)) {
                    message = String(format: "거꾸로 사본을 만들어 적용했습니다 (%.1f초 걸림) · 원본 영상은 그대로입니다 · ⌘Z로 되돌릴 수 있습니다.", Date().timeIntervalSince(begun))
                } else { GeneratedMediaRegistry.discard(destination) }
            } catch {
                GeneratedMediaRegistry.discard(destination)
                guard ownsAsyncJob(ticket) else { return }
                if Task.isCancelled || error is CancellationError { message = "거꾸로 사본 만들기 취소됨 · 프로젝트와 파일은 바뀌지 않았습니다." }
                else { self.error = error.localizedDescription; message = "거꾸로 사본을 만들지 못했습니다 · 프로젝트는 바뀌지 않았습니다." }
            }
            if ownsAsyncJob(ticket) { productivityStatus = message }
        }
    }
}

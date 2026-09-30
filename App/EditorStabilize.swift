import Foundation
import AppKit
import JHCutCore

// MARK: - Hand-shake stabilisation (priority 1 after 0.7)

extension EditorModel {
    /// The selected clip when it is a video clip that can be stabilised.
    var stabilizableSelection: (Track, Clip, MediaAsset)? {
        guard let (track, clip) = selected, clip.title == nil, let id = clip.assetID,
              let asset = project.assets.first(where: { $0.id == id }), asset.kind == .video else { return nil }
        return (track, clip, asset)
    }

    /// Measures the camera path of the selected clip's source range (read-only, cancellable) and
    /// stores it on the clip in one undo step. Strength and smoothing already set are kept.
    func analyzeStabilization() {
        guard !busyDocument else { return }
        guard let (track, clip, asset) = stabilizableSelection else { error = "손떨림 보정은 선택한 영상 클립에만 쓸 수 있습니다."; return }
        guard !track.isLocked else { error = "잠긴 트랙의 클립은 분석 결과를 저장할 수 없습니다. 잠금을 해제하세요."; return }
        guard clip.sourceDuration.seconds <= StabilizationAnalyzer.maximumSeconds else {
            error = "손떨림 분석은 클립당 \(Int(StabilizationAnalyzer.maximumSeconds / 60))분까지 가능합니다. 클립을 나눈 뒤 각각 분석하세요."; return
        }
        let snapshot = project, url = asset.resolvedURL(relativeTo: mediaBaseURL), previous = clip.stabilization
        pausePlayback(); stopAudition(); error = nil
        productivityBusy = true; productivityStatus = "손떨림 분석 중 · 0%"
        let begun = Date()
        productivityTask = Task {
            defer { productivityBusy = false; productivityTask = nil }
            do {
                var data = try await StabilizationAnalyzer.analyze(url: url, sourceStart: clip.sourceStart, duration: clip.sourceDuration) { [weak self] fraction in
                    Task { @MainActor in self?.productivityStatus = "손떨림 분석 중 · \(Int(fraction * 100))%" }
                }
                try Task.checkCancellation()
                guard project == snapshot else { throw ProjectError("분석 중 프로젝트가 변경되었습니다. 오래된 분석을 잘못 적용하지 않도록 중단했습니다. 다시 실행하세요.") }
                if let previous { data.strength = previous.strength; data.smoothing = previous.smoothing }
                var value = clip; value.stabilization = data
                if perform(.updateClip(trackID: track.id, clip: value)) {
                    message = "손떨림 분석 완료 · " + Self.describeStabilization(data, elapsed: Date().timeIntervalSince(begun)) + " · ⌘Z로 되돌릴 수 있습니다."
                    productivityStatus = message
                }
            } catch {
                if Task.isCancelled { message = "손떨림 분석 취소됨 · 클립은 바뀌지 않았습니다." }
                else { self.error = error.localizedDescription; message = "손떨림 분석 실패 · 클립은 바뀌지 않았습니다." }
                productivityStatus = message
            }
        }
    }

    /// Removes the stored path (one undo step).
    func removeStabilization() {
        guard !busyDocument, let (track, clip, _) = stabilizableSelection, clip.stabilization != nil, !track.isLocked else { return }
        var value = clip; value.stabilization = nil
        if perform(.updateClip(trackID: track.id, clip: value)) { message = "손떨림 보정을 제거했습니다. 원본 화면으로 돌아갑니다." }
    }

    static func describeStabilization(_ data: StabilizationData, elapsed: Double? = nil) -> String {
        var parts = [String(format: "%.0f초 구간", data.analyzedDuration)]
        if let plan = StabilizationPlan(data) {
            parts.append(plan.zoom < 1.005 ? "화면 확대 없음" : String(format: "화면 확대 %.2f배", plan.zoom))
            if plan.limitedSamples > 0 { parts.append(String(format: "보정 제한 %.0f%%", Double(plan.limitedSamples) / Double(data.count) * 100)) }
        } else if !data.enabled { parts.append("꺼짐") }
        if data.rejectedSteps > 0 { parts.append("건너뛴 프레임 \(data.rejectedSteps)개") }
        if let elapsed { parts.append(String(format: "분석 %.1f초", elapsed)) }
        return parts.joined(separator: " · ")
    }
}

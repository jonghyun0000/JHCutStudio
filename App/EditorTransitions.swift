import Foundation
import JHCutCore

// MARK: - Transitions and title animation (priority 2 after the Final Cut comparison)

extension EditorModel {
    /// Adds a transition between the selected main-track clip and the one after it (same overlap as the old dissolve).
    func addTransition(kind: TransitionKind, direction: TransitionDirection, seconds: Double) {
        guard !busyDocument, let (track, clip) = selected, track.kind == .video, clip.title == nil else { error = "전환은 메인 영상 트랙의 클립을 선택한 뒤 추가하세요."; return }
        guard seconds.isFinite, seconds > 0 else { error = "전환 길이를 확인하세요."; return }
        let duration = frameRate.time(forFrame: max(1, Int64((seconds * frameRate.fps).rounded())))
        if perform(.addTransition(trackID: track.id, clipID: clip.id, kind: kind, direction: direction, duration: duration)) {
            message = "\(kind.label) 전환 추가 · 다음 장면이 \(String(format: "%.1f", duration.seconds))초 앞당겨져 겹칩니다 · ⌘Z로 되돌릴 수 있습니다."
        }
    }

    /// Whether `clip` (on `track`) is the incoming clip of a transition, including 0.6-style dissolves.
    func transitionOf(_ clip: Clip, on track: Track) -> ClipTransition? {
        if let transition = clip.transition { return transition }
        if track.kind == .overlay, clip.title == nil, let fade = clip.fadeIn, fade > .zero, track.name.hasPrefix("디졸브") {
            return ClipTransition(kind: .dissolve, duration: fade)
        }
        return nil
    }

    /// Changes the kind/side of an existing transition without changing its length.
    func changeTransition(kind: TransitionKind, direction: TransitionDirection) {
        guard !busyDocument, let (track, original) = selected, let current = transitionOf(original, on: track), !track.isLocked else { return }
        var clip = original
        clip.transition = ClipTransition(kind: kind, direction: direction, duration: current.duration)
        // Dissolve is drawn by the fade-in; every other kind draws its own motion and must not also fade.
        clip.fadeIn = kind == .dissolve ? current.duration : nil
        guard clip != original else { return }
        if perform(.updateClip(trackID: track.id, clip: clip)) { message = "전환을 \(kind.label)(으)로 바꿨습니다." }
    }

    /// Sets (or clears, with nil/empty) the entrance/exit animation of the selected title or caption.
    func setTitleAnimation(_ animation: TitleAnimation?) {
        guard !busyDocument, let (track, original) = selected, original.title != nil, !track.isLocked else { return }
        var clip = original
        clip.titleAnimation = (animation?.isEmpty ?? true) ? nil : animation
        guard clip != original else { return }
        if let problem = clip.titleAnimation?.validationProblem(clipDuration: clip.duration) { error = problem; return }
        perform(.updateClip(trackID: track.id, clip: clip))
    }

    /// Applies the same animation to every visible, unlocked caption/title (one undo step). Captions shorter than the
    /// animation get proportionally shorter entrance and exit instead of being skipped.
    func applyTitleAnimationToAllCaptions(_ animation: TitleAnimation) {
        guard !busyDocument else { return }
        var commands: [EditCommand] = [], skipped = 0
        for track in project.sequence.tracks where track.kind == .title && !track.isHidden {
            guard !track.isLocked else { skipped += track.clips.count; continue }
            for original in track.clips where original.title != nil {
                var value = animation
                let total = (value.inKind == nil ? 0 : value.inSeconds) + (value.outKind == nil ? 0 : value.outSeconds)
                let room = original.duration.seconds * 0.8
                if total > room, total > 0 {
                    let factor = room / total
                    value.inSeconds = max(TitleAnimation.secondsRange.lowerBound, value.inSeconds * factor); value.outSeconds = max(TitleAnimation.secondsRange.lowerBound, value.outSeconds * factor)
                }
                var clip = original
                clip.titleAnimation = value.isEmpty ? nil : value
                if let problem = clip.titleAnimation?.validationProblem(clipDuration: clip.duration) { _ = problem; skipped += 1; continue }
                if clip != original { commands.append(.updateClip(trackID: track.id, clip: clip)) }
            }
        }
        guard !commands.isEmpty else { message = "적용할 자막이 없습니다." + (skipped > 0 ? " (잠긴 트랙·너무 짧은 자막 \(skipped)개 제외)" : ""); return }
        if perform(.batch(commands)) {
            message = "자막 \(commands.count)개에 글자 애니메이션 적용" + (skipped > 0 ? " · 잠긴 트랙·너무 짧은 자막 \(skipped)개 제외" : "") + " · ⌘Z 한 번으로 되돌릴 수 있습니다."
        }
    }
}

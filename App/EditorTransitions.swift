import Foundation
import JHCutCore

// MARK: - Transitions and title animation (priority 2 after the Final Cut comparison)

extension EditorModel {
    /// Adds a transition between the selected main-track clip and the one after it (same overlap as the old dissolve).
    func addTransition(kind: TransitionKind, direction: TransitionDirection, seconds: Double) {
        guard !busyDocument, let (track, clip) = selected, clip.title == nil,
              track.kind == .video || TransitionEditing.context(of: track, in: project.sequence) != nil else { error = "전환은 메인 영상 장면을 선택한 뒤 추가하세요."; return }
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { error = "전환 길이를 확인하세요."; return }
        let duration = frameRate.time(forFrame: max(1, Int64((seconds * frameRate.fps).rounded())))
        if perform(.addTransition(trackID: track.id, clipID: clip.id, kind: kind, direction: direction, duration: duration)) {
            message = "\(kind.label) 전환 추가 · 다음 장면이 \(String(format: "%.1f", duration.seconds))초 앞당겨져 겹칩니다 · ⌘Z로 되돌릴 수 있습니다."
        }
    }

    /// Whether `clip` (on `track`) is the incoming clip of a transition, including 0.6-style dissolves.
    func transitionOf(_ clip: Clip, on track: Track) -> ClipTransition? {
        if let context = TransitionEditing.context(of: track, in: project.sequence) { return context.effect }
        if let transition = clip.transition { return transition }
        if track.kind == .overlay, clip.title == nil, let fade = clip.fadeIn, fade > .zero, track.name.hasPrefix("디졸브") {
            return ClipTransition(kind: .dissolve, duration: fade)
        }
        return nil
    }

    /// Changes the kind/side of an existing transition without changing its length.
    func changeTransition(kind: TransitionKind, direction: TransitionDirection) {
        guard !busyDocument, let (track, original) = selected, let current = transitionOf(original, on: track), !track.isLocked else { return }
        if kind == current.kind && direction == current.direction { return }
        if perform(.changeTransitionAppearance(trackID: track.id, kind: kind, direction: direction)) { message = "전환을 \(kind.label)(으)로 바꿨습니다." }
    }
    func resizeTransition(seconds: Double) {
        guard !busyDocument, let (track, _) = selected, let context = TransitionEditing.context(of: track, in: project.sequence), !track.isLocked,
              seconds.isFinite, seconds > 0, seconds <= 3600 else { return }
        let duration = frameRate.time(forFrame: max(1, Int64((seconds * frameRate.fps).rounded())))
        let current = context.effect
        if perform(.updateTransition(trackID: track.id, kind: current.kind, direction: current.direction, duration: duration)) {
            message = String(format: "전환 길이 %.2f초 · 뒤 장면과 연결 자막을 함께 옮겼습니다 · ⌘Z로 되돌릴 수 있습니다.", duration.seconds)
        }
    }
    func removeTransition() {
        guard !busyDocument, let (track, _) = selected, !track.isLocked else { return }
        if perform(.removeTransition(trackID: track.id)) { message = "전환 제거 · 원래 메인 트랙과 사용자 오디오 페이드를 유지했습니다 · ⌘Z로 되돌릴 수 있습니다." }
    }

    /// Sets (or clears, with nil/empty) the entrance/exit animation of the selected title or caption.
    func setTitleAnimation(_ animation: TitleAnimation?) {
        guard !busyDocument, let (track, original) = selected, original.title != nil, !track.isLocked else { return }
        var clip = original
        let value = animation.map { Self.restartedTitleAnimation($0, duration: clip.duration) }
        clip.titleAnimation = (value?.isEmpty ?? true) ? nil : value
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
                var value = Self.restartedTitleAnimation(animation, duration: original.duration)
                let total = (value.inKind == nil ? 0 : value.inSeconds) + (value.outKind == nil ? 0 : value.outSeconds)
                let room = original.duration.seconds * 0.8
                if total > room, total > 0 {
                    let factor = room / total
                    value.inSeconds = value.inKind == nil ? value.inSeconds : value.inSeconds * factor
                    value.outSeconds = value.outKind == nil ? value.outSeconds : value.outSeconds * factor
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
    /// Manual changes start a fresh clock, expressed in current timeline seconds rather than
    /// the stored pre-trim/pre-speed reference clock. Very short fragments still accept a kind change.
    static func restartedTitleAnimation(_ animation: TitleAnimation, duration: MediaTime) -> TitleAnimation {
        var value = animation
        let hadClock = value.referenceDuration != nil || value.timeOffset != nil || value.timeScale != nil
        if hadClock {
            let scale = value.timeScale ?? 1
            value.inSeconds = min(3, value.inSeconds / scale); value.outSeconds = min(3, value.outSeconds / scale)
            let total = (value.inKind == nil ? 0 : value.inSeconds) + (value.outKind == nil ? 0 : value.outSeconds)
            if total > duration.seconds, total > 0 {
                let factor = duration.seconds * 0.8 / total
                if value.inKind != nil { value.inSeconds *= factor }; if value.outKind != nil { value.outSeconds *= factor }
            }
        }
        value.referenceDuration = nil; value.timeOffset = nil; value.timeScale = nil
        return value
    }
}

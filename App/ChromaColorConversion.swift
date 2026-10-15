import AppKit
import SwiftUI
import JHCutCore

/// ColorPicker may emit Display P3. Convert explicitly to gamma-encoded sRGB storage.
/// Out-of-gamut colors are clipped to the documented sRGB key gamut; alpha is ignored.
enum ChromaColorConversion {
    static func storing(_ color: NSColor, in original: ChromaKey) throws -> ChromaKey {
        guard let value = color.usingColorSpace(.sRGB) else { throw ProjectError("선택한 색을 sRGB로 변환하지 못했습니다.") }
        let channels = [value.redComponent, value.greenComponent, value.blueComponent].map(Double.init)
        guard channels.allSatisfy(\.isFinite) else { throw ProjectError("선택한 키 색이 올바르지 않습니다.") }
        var result = original
        result.keyRed = min(1, max(0, channels[0])); result.keyGreen = min(1, max(0, channels[1])); result.keyBlue = min(1, max(0, channels[2]))
        return result
    }
}

/// Local RGB draft. It never starts a render, mutates EditorModel, or owns a live gesture.
/// The monotonic context rejects history/document ABA, even a newly opened document with the same IDs.
@MainActor struct ChromaColorDraft {
    let id = UUID()
    let trackID: UUID
    let clipID: UUID
    private let context: EditorAsyncContext
    private(set) var key: ChromaKey
    private(set) var active = true

    static func begin(in model: EditorModel, trackID: UUID, clipID: UUID) -> Self? {
        guard !model.busyDocument, !model.isBuilding, model.selectedClipID == clipID,
              let track = model.project.sequence.tracks.first(where: { $0.id == trackID }), !track.isLocked,
              let clip = track.clips.first(where: { $0.id == clipID }), let key = clip.visual?.chromaKey else { return nil }
        return Self(trackID: trackID, clipID: clipID, context: model.asyncContext(), key: key)
    }
    func isCurrent(in model: EditorModel) -> Bool {
        active && !model.busyDocument && model.selectedClipID == clipID && model.contextMatches(context)
            && model.project.sequence.tracks.contains { $0.id == trackID && !$0.isLocked && $0.clips.contains { $0.id == clipID && $0.visual?.chromaKey != nil } }
    }
    @discardableResult mutating func select(_ color: NSColor, in model: EditorModel) throws -> Bool {
        guard isCurrent(in: model) else { return false }
        key = try ChromaColorConversion.storing(color, in: key)
        return true
    }
    mutating func cancel() { active = false }
    @discardableResult mutating func apply(to model: EditorModel) -> Bool {
        let owns = isCurrent(in: model)
        active = false
        guard owns, let track = model.project.sequence.tracks.first(where: { $0.id == trackID }),
              var clip = track.clips.first(where: { $0.id == clipID }), var latest = clip.visual?.chromaKey else { return false }
        // Only RGB belongs to this dialog. Never restore a stale whole-clip/key snapshot.
        latest.keyRed = key.keyRed; latest.keyGreen = key.keyGreen; latest.keyBlue = key.keyBlue
        clip.visual?.chromaKey = latest
        if track.clips.first(where: { $0.id == clipID }) == clip { return true }
        return model.perform(.updateClip(trackID: trackID, clip: clip))
    }
}

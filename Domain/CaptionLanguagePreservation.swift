import Foundation

/// Re-recognition must not orphan existing translations or discard a manual decision.
public enum CaptionLanguagePreservation {
    public static func shouldKeep(_ original: Clip, trackLocked: Bool, in sequence: Sequence) -> Bool {
        if trackLocked || original.title?.text != original.connection?.generatedText || original.captionMetadata?.languageManual == true || original.captionMetadata?.speakerManual == true { return true }
        let family = original.lineageID ?? original.id
        return sequence.tracks.contains { track in track.clips.contains {
            $0.captionMetadata?.translatedFrom == original.id || $0.captionMetadata?.translatedFrom == family
        } }
    }
}

import Foundation
import CryptoKit

/// Review is an explicit editor decision, never an automatic recognition-quality claim.
public enum CaptionReview {
    public static func digest(_ clip: Clip) -> String {
        let m = clip.captionMetadata
        var fields: [String] = [clip.title?.text ?? "", String(clip.start.value), String(clip.start.timescale),
                      String(clip.duration.value), String(clip.duration.timescale), m?.language ?? "",
                      m?.speaker ?? "", m?.speakerStatus ?? "", String(m?.speakerManual ?? false),
                      String(m?.languageNeedsReview ?? false), String(m?.languageManual ?? false)]
        if let connection = clip.connection {
            fields.append(connection.parentID.uuidString)
            fields.append("\(connection.sourceStart.value)/\(connection.sourceStart.timescale)")
            fields.append("\(connection.sourceDuration.value)/\(connection.sourceDuration.timescale)")
        } else { fields.append(contentsOf: ["", "", ""]) }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func isReviewed(_ clip: Clip) -> Bool { clip.captionMetadata?.reviewDigest == digest(clip) }
    public static func marking(_ original: Clip, reviewed: Bool) -> Clip {
        var clip = original
        if clip.captionMetadata == nil {
            clip.captionMetadata = CaptionMetadata(language: "unknown", originalLanguage: "unknown",
                originalText: clip.title?.text ?? "", generatedText: clip.title?.text ?? "")
        }
        let state = reviewed ? digest(clip) : nil
        clip.captionMetadata?.reviewDigest = state
        return clip
    }
}

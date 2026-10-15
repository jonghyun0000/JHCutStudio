import Foundation

/// Machine observations use the ORIGINAL media clock. None imply human verification.
public struct SourceLanguageObservation: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case audioProbe, recognizerWindow, text, manual }
    public enum State: String, Codable, Sendable { case supported, uncertain, specified }
    public var sourceStart: Double
    public var sourceEnd: Double
    public var language: String?
    public var candidateLanguage: String?
    /// Whisper's reported posterior or text detector evidence, never an accuracy percentage.
    public var measuredSpeechSeconds: Double?
    public var confidence: Double?
    public var method: Method
    public var state: State
    public var reason: String
    public init(start: Double, end: Double, language: String?, candidate: String? = nil, confidence: Double? = nil,
                method: Method, state: State, reason: String, measuredSpeechSeconds: Double? = nil) {
        sourceStart=start; sourceEnd=end; self.language=language; candidateLanguage=candidate
        self.measuredSpeechSeconds=measuredSpeechSeconds; self.confidence=confidence; self.method=method; self.state=state; self.reason=reason
    }
    public var isValid: Bool {
        sourceStart.isFinite && sourceEnd.isFinite && sourceStart >= 0 && sourceEnd > sourceStart &&
        sourceEnd <= 31_622_400 + 86_400 && (language == nil || CaptionLanguage(rawValue:language!) != nil) &&
        (candidateLanguage == nil || candidateLanguage!.utf8.count <= 12 && candidateLanguage!.allSatisfy { $0.isASCII && $0.isLetter }) &&
        (measuredSpeechSeconds == nil || measuredSpeechSeconds!.isFinite && measuredSpeechSeconds! >= 0 && measuredSpeechSeconds! <= sourceEnd-sourceStart+0.001) &&
        (confidence == nil || confidence!.isFinite && (0...1).contains(confidence!)) && reason.utf8.count <= 1024 &&
        (state != .supported || language != nil) &&
        (method != .audioProbe || state != .supported || sourceEnd-sourceStart >= 6 && (confidence ?? 0) >= 0.8 && (measuredSpeechSeconds ?? 0) >= 2) && (state != .specified || method == .manual && language != nil)
    }
}

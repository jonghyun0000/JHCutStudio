import Foundation
@preconcurrency import AVFoundation

/// Uses Apple's built-in color-conforming compositor, never re-tags HDR pixels as SDR.
/// Reference: developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf
public enum MediaPreparation {
    public struct AudioTrackInfo: Identifiable, Sendable {
        public let id: Int
        public let name: String
    }
    public static func audioTracks(in url: URL) async throws -> [AudioTrackInfo] {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        var result: [AudioTrackInfo] = []
        for (index, track) in tracks.enumerated() {
            let language = try await track.load(.extendedLanguageTag) ?? "언어 미표기"
            let descriptions = try await track.load(.formatDescriptions)
            let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 0
            result.append(AudioTrackInfo(id: index, name: "트랙 \(index + 1) · \(channels)채널 · \(language)"))
        }
        return result
    }
    public static func convertToSDR(url: URL, destination: URL, audioTrackIndex: Int = 0, timeRange: CMTimeRange? = nil) async throws -> MediaAsset {
        let source = AVURLAsset(url: url)
        let videos = try await source.loadTracks(withMediaType: .video)
        guard videos.count == 1, let video = videos.first else { throw MediaEngineError.unsupported("단일 영상 트랙을 선택하세요.") }
        let formats = try await video.load(.formatDescriptions)
        for format in formats {
            let ext = CMFormatDescriptionGetExtensions(format) as NSDictionary? ?? [:]
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String ?? ""
            guard !transfer.isEmpty, !transfer.lowercased().contains("log") else { throw MediaEngineError.unsupported("색상 정보가 없거나 Log 원본입니다. 카메라에 맞는 색 변환이 필요합니다.") }
        }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaEngineError.failed("변환용 영상 트랙을 만들지 못했습니다.") }
        let available = try await video.load(.timeRange), transform = try await video.load(.preferredTransform)
        let range = timeRange ?? available
        guard range.start >= available.start, range.end <= available.end, range.duration > .zero else { throw MediaEngineError.invalid("변환 범위가 원본 밖입니다.") }
        try target.insertTimeRange(range, of: video, at: .zero); target.preferredTransform = transform
        let audios = try await source.loadTracks(withMediaType: .audio)
        if !audios.isEmpty {
            guard audios.indices.contains(audioTrackIndex) else { throw MediaEngineError.invalid("선택한 오디오 트랙이 없습니다.") }
            let audio = audios[audioTrackIndex], audioRange = try await audio.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(range, otherRange: audioRange)
            if intersection.duration > .zero, let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try output.insertTimeRange(intersection, of: audio, at: intersection.start - range.start)
            }
        }
        let videoComposition = AVMutableVideoComposition(propertiesOf: composition)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw MediaEngineError.failed("SDR 변환기를 만들 수 없습니다.") }
        session.videoComposition = videoComposition
        try await export(session, destination: destination, type: .mp4)
        let result = try await MediaImporter.inspect(url: destination)
        guard result.supported else { try? FileManager.default.removeItem(at: destination); throw MediaEngineError.failed(result.issue ?? "변환한 SDR 사본을 검사하지 못했습니다.") }
        return result
    }
    public static func extractAudio(url: URL, trackIndex: Int, destination: URL) async throws -> MediaAsset {
        let source = AVURLAsset(url: url), tracks = try await source.loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(trackIndex) else { throw MediaEngineError.invalid("선택한 오디오 트랙이 없습니다.") }
        let composition = AVMutableComposition(), track = tracks[trackIndex]
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaEngineError.failed("오디오 트랙을 만들 수 없습니다.") }
        let range = try await track.load(.timeRange)
        try target.insertTimeRange(range, of: track, at: range.start)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw MediaEngineError.failed("오디오 추출기를 만들 수 없습니다.") }
        try await export(session, destination: destination, type: .m4a)
        return try await MediaImporter.inspect(url: destination)
    }
    private static func export(_ session: AVAssetExportSession, destination: URL, type: AVFileType) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MediaEngineError.failed("기존 파일을 보호하기 위해 새 변환 이름을 선택하세요.") }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".jhcut-convert-\(UUID().uuidString)." + destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: staging) }
        session.outputURL = staging; session.outputFileType = type
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in session.exportAsynchronously { continuation.resume() } }
            try Task.checkCancellation()
            guard session.status == .completed else { throw session.error ?? MediaEngineError.failed("미디어 변환 실패") }
        }, onCancel: { session.cancelExport() })
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

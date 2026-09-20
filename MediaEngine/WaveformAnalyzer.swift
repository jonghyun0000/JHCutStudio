import Foundation
import AVFoundation
import CryptoKit

/// Bounded, streaming channel-preserving peak-envelope analysis. Cache keys include identity, path, size, modification time, bins and analysis version.
public enum WaveformAnalyzer {
    private static let version = 2
    private static let cacheLimit = 16 * 1_024 * 1_024
    private struct Cached: Codable { let version: Int; let peaks: [Float] }
    public static func analyze(url: URL, bins: Int = 160) async throws -> [Float] {
        guard (1...4096).contains(bins) else { throw MediaEngineError.invalid("파형 해상도는 1~4096 구간이어야 합니다.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaEngineError.missing("파형 원본을 읽을 수 없습니다: \(url.lastPathComponent)") }
        try Task.checkCancellation()
        let cacheURL = try cachedURL(for: url, bins: bins)
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(Cached.self, from: data),
           cached.version == version, cached.peaks.count == bins, cached.peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
            return cached.peaks
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [Float](repeating: 0, count: bins) }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else { throw MediaEngineError.invalid("파형 원본 길이가 유효하지 않습니다.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaEngineError.failed("파형 오디오 디코더 구성에 실패했습니다.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaEngineError.failed("파형 오디오를 읽을 수 없습니다.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var peaks = [Float](repeating: 0, count: bins)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample), let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
                    throw MediaEngineError.failed("예상한 PCM 파형 형식이 아닙니다.")
                }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count > 0 else { return }
                // At most one decoder chunk is resident; the complete PCM stream is never accumulated.
                var chunk = [Float](repeating: 0, count: count)
                let result = chunk.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                guard result == kCMBlockBufferNoErr else { throw MediaEngineError.failed("PCM 파형 버퍼를 읽지 못했습니다.") }
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let channels = Int(format.mChannelsPerFrame)
                guard count % channels == 0, format.mSampleRate.isFinite, format.mSampleRate > 0, start.isFinite else {
                    throw MediaEngineError.invalid("오디오 PCM 형식 또는 시간이 유효하지 않습니다.")
                }
                for frame in 0..<(count / channels) {
                    var peak: Float = 0
                    for channel in 0..<channels {
                        let value = chunk[frame * channels + channel]
                        guard value.isFinite else { throw MediaEngineError.invalid("오디오에 유효하지 않은 샘플이 있습니다.") }
                        peak = max(peak, abs(value))
                    }
                    let time = start + Double(frame) / format.mSampleRate
                    let bin = max(0, min(bins - 1, Int(time / duration.seconds * Double(bins))))
                    peaks[bin] = max(peaks[bin], min(1, peak))
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? MediaEngineError.failed("파형 분석이 완료되지 않았습니다.") }
        if let data = try? JSONEncoder().encode(Cached(version: version, peaks: peaks)) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            trimCache(cacheURL.deletingLastPathComponent())
        }
        return peaks
    }
    private static func cachedURL(for url: URL, bins: Int) throws -> URL {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let identity = [url.standardizedFileURL.path, String(values.fileSize ?? -1), String(values.contentModificationDate?.timeIntervalSince1970 ?? -1),
                        String(describing: values.fileResourceIdentifier), String(bins), String(version)]
        let data = try JSONEncoder().encode(identity)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("JHCutStudio/Waveforms", isDirectory: true).appendingPathComponent(digest + ".json")
    }
    private static func trimCache(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where total > cacheLimit {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}

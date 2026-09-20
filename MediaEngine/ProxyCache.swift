import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CryptoKit

/// Disposable preview media. Project documents and exports continue to refer to the originals.
/// One generation runs per cache instance. Cancellation is cooperative and removes its entire scratch directory.
public actor ProxyCache {
    public let directory: URL
    private let limitBytes: Int64
    private var generating = false
    private var protectedPaths = Set<String>()
    private struct Entry: Codable {
        let version: Int
        let fingerprint: String
        let bytes: Int64
        let frameCount: Int
        let width: Int
        let height: Int
        var lastAccess: Date
    }
    public init(directory: URL? = nil, limitBytes: Int64 = 2_000_000_000) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JHCutStudio/Proxies", isDirectory: true)
        self.limitBytes = max(1, limitBytes)
    }
    /// Pin the URLs used by the currently published player plan before generating more proxies.
    public func setProtectedURLs(_ urls: [URL]) { protectedPaths = Set(urls.map { $0.standardizedFileURL.path }) }
    public func cachedURL(for sourceURL: URL) throws -> URL? {
        let key = try fingerprint(sourceURL)
        let url = mediaURL(key)
        guard let data = try? Data(contentsOf: metadataURL(key)), var entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, entry.fingerprint == key, entry.bytes > 0,
              fileSize(url) == entry.bytes else { return nil }
        entry.lastAccess = Date()
        try JSONEncoder().encode(entry).write(to: metadataURL(key), options: .atomic)
        return url
    }
    public func sizeBytes() throws -> Int64 { try entries().reduce(0) { $0 + fileSize($1.url) } }
    public func removeAll() throws {
        guard !generating else { throw MediaEngineError.failed("프록시 생성 중에는 캐시를 지울 수 없습니다.") }
        for entry in try entries() where !protectedPaths.contains(entry.url.standardizedFileURL.path) {
            try FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: metadataURL(entry.key))
        }
    }
    public func generate(for sourceURL: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        if let hit = try cachedURL(for: sourceURL) { progress(1); return hit }
        guard !generating else { throw MediaEngineError.failed("이 캐시에서 이미 프록시를 생성 중입니다. 완료 후 다시 시도하세요.") }
        generating = true
        defer { generating = false }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let key = try fingerprint(sourceURL)
        let info = try await MediaImporter.inspect(url: sourceURL)
        guard info.kind == .video, info.supported else { throw MediaEngineError.unsupported(info.issue ?? "프록시는 지원하는 SDR 영상에만 생성할 수 있습니다.") }
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaEngineError.invalid("영상 트랙이 없습니다.") }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let range = try await track.load(.timeRange)
        let frameRate = try await track.load(.nominalFrameRate)
        let timeScale = try await track.load(.naturalTimeScale)
        guard range.start.isNumeric, range.start >= .zero, range.duration.isNumeric, range.duration > .zero else {
            throw MediaEngineError.unsupported("프록시가 보존할 수 없는 영상 시간 범위입니다.")
        }
        let display = CGRect(origin: .zero, size: natural).applying(preferred)
        let size = Self.proxySize(display.size)
        let orientation = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
            .concatenating(preferred).concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent(".generating-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent("proxy.mp4")
        let cancellation = ProxyCancellation()
        let count = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try Self.transcode(asset: asset, track: track, range: range, frameRate: frameRate, timeScale: timeScale,
                                                                           size: size, orientation: orientation, url: temporary,
                                                                           cancellation: cancellation, progress: progress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        guard try fingerprint(sourceURL) == key else { throw MediaEngineError.failed("프록시 생성 중 원본이 바뀌었습니다. 다시 생성하세요.") }
        let bytes = fileSize(temporary)
        guard bytes > 0, bytes <= limitBytes else { throw MediaEngineError.failed("프록시 파일이 캐시 용량 제한을 초과합니다.") }
        let final = mediaURL(key)
        // A corrupted/truncated prior entry is replaceable; unrelated files are never touched.
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: temporary, to: final)
        let entry = Entry(version: 1, fingerprint: key, bytes: bytes, frameCount: count, width: Int(size.width), height: Int(size.height), lastAccess: Date())
        do {
            try JSONEncoder().encode(entry).write(to: metadataURL(key), options: .atomic)
            try evict(protecting: final)
        } catch {
            try? FileManager.default.removeItem(at: final)
            try? FileManager.default.removeItem(at: metadataURL(key))
            throw error
        }
        progress(1)
        return final
    }
    private func fingerprint(_ url: URL) throws -> String {
        // URL.resourceValues may retain a cached mtime on the same URL instance. Fetch fresh stat attributes.
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber, number.int64Value > 0,
              let modified = attributes[.modificationDate] as? Date else {
            throw MediaEngineError.missing("프록시 원본 파일이 없거나 비어 있습니다: \(url.lastPathComponent)")
        }
        let size = number.intValue
        let identifier = String(describing: attributes[.systemFileNumber])
        // Read bounded head/tail hashes too: catches same-size replacements on low-resolution filesystem clocks.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 65_536) ?? Data()
        try handle.seek(toOffset: UInt64(max(0, size - 65_536)))
        let tail = try handle.read(upToCount: 65_536) ?? Data()
        var hash = SHA256()
        hash.update(data: Data("proxy-v1|\(url.standardizedFileURL.path)|\(identifier)|\(size)|\(modified.timeIntervalSince1970)|".utf8))
        hash.update(data: head); hash.update(data: tail)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func mediaURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".mp4") }
    private func metadataURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
    private func fileSize(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    private func entries() throws -> [(key: String, url: URL, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let key = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "mp4", key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            let entry = (try? Data(contentsOf: metadataURL(key))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
            return (key, url, entry?.lastAccess ?? .distantPast)
        }
    }
    private func evict(protecting current: URL) throws {
        let candidates = try entries().sorted { $0.date < $1.date }
        var total = candidates.reduce(Int64(0)) { $0 + fileSize($1.url) }
        for entry in candidates where total > limitBytes && entry.url != current && !protectedPaths.contains(entry.url.standardizedFileURL.path) {
            let bytes = fileSize(entry.url)
            try FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: metadataURL(entry.key))
            total -= bytes
        }
        guard total <= limitBytes else { throw MediaEngineError.failed("사용 중인 프록시가 캐시 한도를 차지하고 있습니다. 다른 프로젝트를 닫거나 캐시 한도를 늘리세요.") }
    }
    private static func proxySize(_ display: CGSize) -> CGSize {
        let width = max(2, Int(abs(display.width).rounded())), height = max(2, Int(abs(display.height).rounded()))
        var a = width, b = height
        while b != 0 { let r = a % b; a = b; b = r }
        let unitW = width / a, unitH = height / a
        // Common camera aspect ratios can preserve aspect exactly while satisfying H.264's even dimensions.
        let multiple = min(a, min(1280 / unitW, 720 / unitH))
        let evenMultiple = multiple - (multiple % 2)
        if evenMultiple >= 2 { return CGSize(width: unitW * evenMultiple, height: unitH * evenMultiple) }
        let scale = min(1, min(1280.0 / Double(width), 720.0 / Double(height)))
        return CGSize(width: max(2, Int(Double(width) * scale) / 2 * 2), height: max(2, Int(Double(height) * scale) / 2 * 2))
    }
    private static func transcode(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, frameRate: Float, timeScale: CMTimeScale,
                                  size: CGSize, orientation: CGAffineTransform, url: URL,
                                  cancellation: ProxyCancellation, progress: @escaping @Sendable (Double) -> Void) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaEngineError.failed("프록시 영상 리더를 만들 수 없습니다.") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieTimeScale = timeScale
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoAllowFrameReorderingKey: false,
                                             AVVideoExpectedSourceFrameRateKey: max(1, frameRate)],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        input.mediaTimeScale = timeScale
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MediaEngineError.failed("프록시 인코더를 만들 수 없습니다.") }
        writer.add(input)
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
              kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw MediaEngineError.failed("프록시 버퍼 풀을 만들 수 없습니다.")
        }
        let attachments: [CFString: Any] = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
        let color = CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary)?.takeRetainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        var succeeded = false
        defer {
            if !succeeded {
                reader.cancelReading(); writer.cancelWriting()
                // cancelWriting can finish filesystem sidecar cleanup asynchronously.
                for _ in 0..<100 where writer.status == .writing { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        try cancellation.check()
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? MediaEngineError.failed("프록시 읽기/쓰기를 시작할 수 없습니다.") }
        writer.startSession(atSourceTime: .zero)
        var count = 0
        var previous: CMTime?
        var lastEnd = range.start
        var pending = output.copyNextSampleBuffer()
        while let sample = pending {
            try cancellation.check()
            let next = output.copyNextSampleBuffer()
            pending = next
            try autoreleasepool {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let declaredDuration = CMSampleBufferGetDuration(sample)
                // H.264/HEVC decoded samples often omit duration. Preserve their presentation schedule
                // using a bounded one-frame lookahead, and the track end for the final frame.
                let nextPTS = next.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? range.end
                let duration = declaredDuration.isNumeric && declaredDuration > .zero ? declaredDuration : nextPTS - pts
                guard pts.isNumeric, pts >= .zero, previous == nil || pts > previous!, duration.isNumeric, duration > .zero,
                      let source = CMSampleBufferGetImageBuffer(sample) else { throw MediaEngineError.unsupported("프록시는 증가하는 PTS와 유효한 영상 시간 범위가 필요합니다.") }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else { throw MediaEngineError.failed("프록시 프레임 메모리 할당 실패") }
                for (key, value) in attachments { CVBufferSetAttachment(buffer, key, value as CFTypeRef, .shouldPropagate) }
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, color, .shouldPropagate)
                var image = CIImage(cvPixelBuffer: source).transformed(by: orientation)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                image = image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
                context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: color)
                var format: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { throw MediaEngineError.failed("프록시 프레임 형식 오류") }
                var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                var encodedSample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &encodedSample) == noErr, let encodedSample else { throw MediaEngineError.failed("프록시 타임스탬프 구성 실패") }
                while !input.isReadyForMoreMediaData && writer.status == .writing { try cancellation.check(); Thread.sleep(forTimeInterval: 0.001) }
                guard input.append(encodedSample) else { throw writer.error ?? MediaEngineError.failed("프록시 프레임 쓰기 실패") }
                count += 1; previous = pts; lastEnd = pts + duration
                if count % 5 == 0 { progress(min(0.99, max(0, (pts - range.start).seconds / range.duration.seconds))) }
            }
        }
        guard reader.status == .completed, count > 0 else { throw reader.error ?? MediaEngineError.failed("프록시 원본을 끝까지 읽지 못했습니다.") }
        guard abs((lastEnd - range.end).seconds) <= 1.0 / Double(max(1, frameRate)) + 0.00001 else { throw MediaEngineError.unsupported("프레임 타이밍과 영상 범위가 일치하지 않아 프록시를 만들지 않았습니다.") }
        input.markAsFinished(); writer.endSession(atSourceTime: range.end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        while done.wait(timeout: .now() + 0.05) == .timedOut { try cancellation.check() }
        try cancellation.check()
        guard writer.status == .completed else { throw writer.error ?? MediaEngineError.failed("프록시 파일 마무리 실패") }
        succeeded = true
        return count
    }
}

private final class ProxyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
}

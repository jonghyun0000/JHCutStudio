import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

public enum MediaEngineError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    case missing(String)
    case failed(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let value), .unsupported(let value), .missing(let value), .failed(let value): return value
        case .cancelled: return "출력이 취소되었습니다."
        }
    }
}

public extension MediaTime {
    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    init(_ time: CMTime) { self.init(time.value, time.timescale) }
}

public enum MediaImporter {
    public static func inspect(url: URL) async throws -> MediaAsset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaEngineError.missing("미디어가 없습니다: \(url.lastPathComponent)") }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaEngineError.failed("미디어를 읽을 수 없습니다: \(url.lastPathComponent)") }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) {
            let info = try inspectImage(source: source, type: type as String, url: url)
            return MediaAsset(name: url.lastPathComponent, path: url.path, bookmark: bookmark, kind: .image,
                              duration: MediaTime(seconds: 3), width: info.width, height: info.height,
                              codec: info.codec, colorInfo: info.colorInfo, supported: info.issue == nil, issue: info.issue)
        }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw MediaEngineError.invalid("재생할 수 없는 미디어입니다: \(url.lastPathComponent)") }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else { throw MediaEngineError.invalid("유효한 미디어 길이가 없습니다.") }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        if let video = videos.first {
            let descriptions = try await video.load(.formatDescriptions)
            guard !descriptions.isEmpty else { throw MediaEngineError.invalid("영상 형식 정보가 없습니다.") }
            let codecNames = Array(Set(descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) })).sorted()
            let codec = codecNames.joined(separator: "/")
            var issue = descriptions.compactMap(videoIssue).first
            if videos.count > 1 || audios.count > 1 {
                issue = "여러 영상/오디오 트랙이 있는 입력은 트랙 선택 기능이 필요합니다. 사용할 트랙 하나로 변환하세요."
            }
            let metadata = descriptions.map { format -> String in
                let properties = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
                return [properties[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
                        properties[kCMFormatDescriptionExtension_TransferFunction] as? String,
                        properties[kCMFormatDescriptionExtension_YCbCrMatrix] as? String].compactMap { $0 }.joined(separator: " / ")
            }.filter { !$0.isEmpty }.joined(separator: " ; ")
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let displayRect = CGRect(origin: .zero, size: size).applying(transform)
            if issue == nil {
                // Metadata alone does not prove that this machine can decode the actual stream.
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                guard reader.canAdd(output) else { throw MediaEngineError.unsupported("영상 디코더를 구성할 수 없습니다: \(codec)") }
                reader.add(output)
                guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
                    throw MediaEngineError.invalid("첫 영상 프레임을 디코딩할 수 없습니다: \(reader.error?.localizedDescription ?? codec)")
                }
                reader.cancelReading()
            }
            return MediaAsset(name: url.lastPathComponent, path: url.path, bookmark: bookmark, kind: .video,
                              duration: MediaTime(duration), width: Int(abs(displayRect.width).rounded()), height: Int(abs(displayRect.height).rounded()),
                              hasAudio: !audios.isEmpty, codec: codec, colorInfo: metadata.isEmpty ? "색상 메타데이터 미표기" : metadata,
                              supported: issue == nil, issue: issue)
        }
        guard audios.count <= 1 else { throw MediaEngineError.unsupported("여러 오디오 트랙 중 하나를 선택해 변환한 파일이 필요합니다.") }
        guard !audios.isEmpty else { throw MediaEngineError.invalid("영상 또는 오디오 트랙이 없습니다.") }
        // The PCM reader verifies decoding support, rather than relying on a filename extension.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(output) else { throw MediaEngineError.unsupported("오디오 디코더를 구성할 수 없습니다.") }
        reader.add(output)
        guard reader.startReading(), output.copyNextSampleBuffer() != nil else { throw MediaEngineError.invalid("오디오를 디코딩할 수 없습니다: \(reader.error?.localizedDescription ?? "빈 데이터")") }
        reader.cancelReading()
        let formats = try await audios[0].load(.formatDescriptions)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "오디오"
        return MediaAsset(name: url.lastPathComponent, path: url.path, bookmark: bookmark, kind: .audio,
                          duration: MediaTime(duration), hasAudio: true, codec: codec, colorInfo: "오디오", supported: true)
    }
    /// EXIF orientation is applied once here, for both inspected dimensions and rendered image pixels.
    /// ImageIO downsamples directly rather than retaining a huge decoded source bitmap.
    public static func loadImage(url: URL, maxPixelSize: Int = 4096) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw MediaEngineError.invalid("이미지를 열 수 없습니다: \(url.lastPathComponent)")
        }
        let info = try inspectImage(source: source, type: type as String, url: url)
        if let issue = info.issue { throw MediaEngineError.unsupported(issue) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, max(info.width, info.height))),
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw MediaEngineError.invalid("이미지 방향 변환/디코딩에 실패했습니다.")
        }
        return image
    }
    private struct ImageInfo { let width: Int; let height: Int; let codec: String; let colorInfo: String; let issue: String? }
    private static func inspectImage(source: CGImageSource, type: String, url: URL) throws -> ImageInfo {
        let types = [UTType.png.identifier: "PNG", UTType.jpeg.identifier: "JPEG", UTType.heic.identifier: "HEIC"]
        guard let codec = types[type] else { throw MediaEngineError.unsupported("지원하는 정지 이미지는 PNG, JPEG, HEIC입니다.") }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int, rawWidth > 0, rawHeight > 0 else {
            throw MediaEngineError.invalid("이미지 크기를 읽을 수 없습니다.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let swapped = [5,6,7,8].contains(orientation)
        let profile = (properties[kCGImagePropertyProfileName] as? String) ?? ""
        let depth = (properties[kCGImagePropertyDepth] as? Int) ?? 0
        var issue: String?
        if max(rawWidth,rawHeight) > 30_000 || Int64(rawWidth) * Int64(rawHeight) > 100_000_000 {
            issue = "이미지는 1억 픽셀/축당 30,000픽셀 이하로 줄여 가져오세요. 렌더용 이미지는 최대 4096픽셀로 읽습니다."
        }
        if CGImageSourceGetCount(source) != 1 { issue = "여러 프레임/이미지가 포함된 파일은 단일 정지 이미지로 변환하세요." }
        var hdr = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        if #available(macOS 15.0, *) { hdr = hdr || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil }
        let normalized = profile.lowercased()
        if hdr || normalized.contains("2020") || normalized.contains("2100") || normalized.contains("hlg") || normalized.contains("pq") || normalized.contains("hdr") {
            issue = "HDR 이미지 또는 HDR gain map이 있습니다. 검증된 SDR 변환이 필요하며 자동 SDR 재표시는 하지 않습니다."
        } else if depth != 8 {
            issue = "8비트 SDR로 확인되지 않은 이미지입니다(심도 \(depth)). 명시적인 SDR 8비트 변환이 필요합니다."
        }
        var colorInfo = profile
        if issue == nil {
            guard let headerImage = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw MediaEngineError.invalid("이미지를 디코딩할 수 없습니다.")
            }
            let colorName = headerImage.colorSpace?.name as String? ?? ""
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let declaredSRGB = (exif?[kCGImagePropertyExifColorSpace] as? Int) == 1
            let knownColor = try explicitColorDeclaration(url: url, type: type) || declaredSRGB
            if !knownColor || headerImage.colorSpace == nil { issue = "이미지 색공간이 명시되지 않아 SDR 여부를 확인할 수 없습니다. sRGB 프로파일을 포함해 변환하세요." }
            colorInfo = profile.isEmpty ? colorName : profile
        }
        return ImageInfo(width: swapped ? rawHeight : rawWidth, height: swapped ? rawWidth : rawHeight,
                         codec: codec, colorInfo: "\(colorInfo.isEmpty ? "색공간 미표기" : colorInfo) / \(depth)bit / EXIF \(orientation)", issue: issue)
    }
    /// ImageIO supplies a default sRGB profile name for some untagged files. Inspect the actual
    /// color declaration instead of treating that inferred name as source metadata.
    private static func explicitColorDeclaration(url: URL, type: String) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func read(_ count: Int) throws -> [UInt8] { Array(try file.read(upToCount: count) ?? Data()) }
        func uint32(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
        if type == UTType.jpeg.identifier {
            guard try read(2) == [0xff,0xd8] else { return false }
            for _ in 0..<512 {
                let header = try read(4)
                guard header.count == 4, header[0] == 0xff else { return false }
                if header[1] == 0xda || header[1] == 0xd9 { return false }
                let length = Int(header[2]) * 256 + Int(header[3])
                guard length >= 2 else { return false }
                let data = try read(length - 2)
                if header[1] == 0xe2 && data.starts(with: Array("ICC_PROFILE\0".utf8)) { return true }
            }
            return false
        }
        if type == UTType.png.identifier {
            guard try read(8) == [137,80,78,71,13,10,26,10] else { return false }
            for _ in 0..<512 {
                let header = try read(8)
                guard header.count == 8 else { return false }
                let length = uint32(header[0..<4])
                let kind = String(bytes: header[4..<8], encoding: .ascii) ?? ""
                if kind == "iCCP" || kind == "sRGB" { return true }
                if kind == "cICP" {
                    let cicp = try read(4)
                    return cicp.count == 4 && [1,12].contains(cicp[0]) && [1,6,13].contains(cicp[1])
                }
                if kind == "IDAT" || kind == "IEND" { return false }
                try file.seek(toOffset: try file.offset() + length + 4)
            }
            return false
        }
        // HEIC's colr box contains an ICC profile or explicit NCLX color primaries/transfer.
        let fileSize = try file.seekToEnd()
        func boxes(start: UInt64, end: UInt64, depth: Int) throws -> Bool {
            guard depth < 8 else { return false }
            var offset = start
            for _ in 0..<4096 where offset + 8 <= end {
                try file.seek(toOffset: offset)
                let header = try read(8)
                guard header.count == 8 else { return false }
                var length = uint32(header[0..<4]); var headerLength: UInt64 = 8
                let kind = String(bytes: header[4..<8], encoding: .ascii) ?? ""
                if length == 1 { let extended = try read(8); guard extended.count == 8 else { return false }; length = uint32(extended[...]); headerLength = 16 }
                if length == 0 { length = end - offset }
                guard length >= headerLength, length <= end - offset else { return false }
                if kind == "colr" {
                    let colorType = String(bytes: try read(4), encoding: .ascii) ?? ""
                    if colorType == "prof" || colorType == "rICC" { return true }
                    if colorType == "nclx" {
                        let nclx = try read(7)
                        guard nclx.count == 7 else { return false }
                        let primaries = Int(nclx[0])*256+Int(nclx[1]), transfer = Int(nclx[2])*256+Int(nclx[3])
                        return [1,12].contains(primaries) && [1,6,13].contains(transfer)
                    }
                }
                if ["meta","iprp","ipco"].contains(kind), try boxes(start: offset + headerLength + (kind == "meta" ? 4 : 0), end: offset + length, depth: depth + 1) { return true }
                offset += length
            }
            return false
        }
        return try boxes(start: 0, end: fileSize, depth: 0)
    }
    private static func videoIssue(_ format: CMFormatDescription) -> String? {
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let supported: Set<FourCharCode> = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ]
        guard supported.contains(subtype) else { return "검증된 SDR H.264, HEVC, ProRes 422/422 HQ만 지원합니다. 현재 코덱: \(fourCC(subtype))." }
        let properties = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
        let primaries = properties[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transfer = properties[kCMFormatDescriptionExtension_TransferFunction] as? String
        let metadata = [primaries, transfer].compactMap { $0 }.joined(separator: " / ").lowercased()
        if metadata.contains("2084") || metadata.contains("2100") || metadata.contains("hlg") || metadata.contains("log") || metadata.contains("2020") ||
            properties[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] != nil || properties[kCMFormatDescriptionExtension_ContentLightLevelInfo] != nil {
            return "HDR·광색역·Log 입력은 검증된 SDR 변환이 필요합니다. 출력이 차단됩니다."
        }
        guard primaries != nil, transfer != nil else { return "영상 색상 메타데이터가 부족하여 SDR 여부를 확인할 수 없습니다. 색공간을 명시한 SDR 파일이 필요합니다." }
        guard transfer == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String || transfer == kCMFormatDescriptionTransferFunction_sRGB as String else {
            return "지원하지 않는 전달함수입니다: \(transfer ?? "미표기"). SDR 변환이 필요합니다."
        }
        if let aspect = properties[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary,
           let horizontal = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber,
           let vertical = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber,
           horizontal.doubleValue != vertical.doubleValue {
            return "비정사각 픽셀 입력은 아직 검증되지 않았습니다. 정사각 픽셀 SDR로 변환하세요."
        }
        return nil
    }
    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

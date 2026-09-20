import Foundation
import AVFoundation
import AppKit
import CoreText

struct FixtureSet {
    let videos: [URL]
    let endCard: URL
    let overlay: URL
    let bgm: URL
    let rotated: URL
}

enum ValidationFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let text): return text } }
}

enum Fixtures {
    static let colors: [CGColor] = [CGColor(red: 0.78, green: 0.10, blue: 0.08, alpha: 1), CGColor(red: 0.08, green: 0.66, blue: 0.12, alpha: 1), CGColor(red: 0.07, green: 0.14, blue: 0.78, alpha: 1)]

    static func generate(in folder: URL) async throws -> FixtureSet {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var videos: [URL] = []
        for index in 0..<3 {
            let subfolder = folder.appendingPathComponent("장면 \(index + 1)", isDirectory: true)
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let url = subfolder.appendingPathComponent("같은 이름 영상.mp4")
            try await video(to: url, scene: index + 1, color: colors[index], frames: 150)
            videos.append(url)
        }
        let endCard = folder.appendingPathComponent("종현 엔드 카드.png")
        try writePNG(to: endCard, width: 540, height: 960) { context in
            context.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.20, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 540, height: 960))
            drawText("JH CUT STUDIO", at: CGPoint(x: 55, y: 545), size: 44, context: context)
            drawText("종현의 다음 이야기", at: CGPoint(x: 62, y: 452), size: 36, context: context)
            drawText("END CARD · 12–15 s", at: CGPoint(x: 80, y: 370), size: 28, context: context)
        }
        let overlay = folder.appendingPathComponent("투명 PNG 오버레이.png")
        try writePNG(to: overlay, width: 220, height: 220) { context in
            context.clear(CGRect(x: 0, y: 0, width: 220, height: 220))
            context.setFillColor(CGColor(red: 0, green: 0.92, blue: 0.94, alpha: 1))
            context.fillEllipse(in: CGRect(x: 25, y: 25, width: 170, height: 170))
            context.setFillColor(CGColor(red: 0.02, green: 0.08, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 75, y: 76, width: 70, height: 70))
            drawText("JH", at: CGPoint(x: 81, y: 98), size: 34, context: context)
        }
        let bgm = folder.appendingPathComponent("테스트 BGM 440Hz.wav")
        try audio(to: bgm, seconds: 15)
        let rotated = folder.appendingPathComponent("회전 메타데이터 90도.mp4")
        try await video(to: rotated, scene: 4, color: CGColor(red: 0.7, green: 0.3, blue: 0.1, alpha: 1), frames: 30, width: 640, height: 360, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0))
        return FixtureSet(videos: videos, endCard: endCard, overlay: overlay, bgm: bgm, rotated: rotated)
    }

    static func video(to url: URL, scene: Int, color: CGColor, frames: Int, width: Int = 540, height: Int = 960, transform: CGAffineTransform = .identity) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw ValidationFailure.failed("Fixture video writer cannot add H.264 input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ValidationFailure.failed("Fixture writer start failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? ValidationFailure.failed("Fixture writer failed") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw ValidationFailure.failed("Fixture pixel buffer allocation failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw ValidationFailure.failed("Fixture bitmap context failed") }
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            drawText("SCENE \(scene)", at: CGPoint(x: 38, y: height / 2 + 56), size: 48, context: context)
            drawText(String(format: "FRAME %03d", frame), at: CGPoint(x: 38, y: height / 2 - 18), size: 35, context: context)
            drawText("SDR H.264 · 30 fps", at: CGPoint(x: 38, y: 56), size: 24, context: context)
            // A small moving marker makes source-time mapping errors visible beyond color alone.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 20 + (frame % 120) * 3, y: height - 70, width: 24, height: 24))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? ValidationFailure.failed("Fixture frame append failed") }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ValidationFailure.failed("Fixture writer did not complete") }
    }

    static func drawText(_ text: String, at point: CGPoint, size: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func writePNG(to url: URL, width: Int, height: Int, draw: (CGContext) -> Void) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ValidationFailure.failed("PNG context allocation failed") }
        draw(context)
        guard let image = context.makeImage() else { throw ValidationFailure.failed("PNG image allocation failed") }
        try savePNG(image, to: url)
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ValidationFailure.failed("PNG encoding failed") }
        try data.write(to: url, options: .atomic)
    }

    static func audio(to url: URL, seconds: Int) throws {
        let sampleRate = 48_000
        let samples = sampleRate * seconds
        let byteCount = samples * 2
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + byteCount)); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); ascii("data"); u32(UInt32(byteCount))
        for index in 0..<samples {
            let value = Int16(sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 0.4 * Double(Int16.max))
            u16(UInt16(bitPattern: value))
        }
        try data.write(to: url, options: .atomic)
    }
}

import Foundation
import AVFoundation
import CoreImage
import CoreText
import Vision

struct DecodedMovie {
    var width = 0
    var height = 0
    var videoCodec = ""
    var audioCodec = ""
    var nominalFrameRate: Float = 0
    var frameCount = 0
    var videoEndSeconds = 0.0
    var monotonic = true
    var audioRMS = 0.0
    var images: [Int: CGImage] = [:]
    var metrics: [String: Double] = [:]
}

enum MediaInspection {
    static func decode(_ url: URL) async throws -> DecodedMovie {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw ValidationFailure.failed("Output has no video track") }
        var result = DecodedMovie()
        let size = try await track.load(.naturalSize)
        result.width = Int(size.width); result.height = Int(size.height)
        result.nominalFrameRate = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)
        if let first = formats.first { result.videoCodec = fourCC(CMFormatDescriptionGetMediaSubType(first)) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ValidationFailure.failed("Output decoder failed to start") }
        let context = CIContext(options: [.cacheIntermediates: false])
        var lastPTS = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let frameDuration = CMSampleBufferGetDuration(sample).seconds
            if timestamp <= lastPTS { result.monotonic = false }
            lastPTS = timestamp
            if [30, 150, 270, 390].contains(result.frameCount), let buffer = CMSampleBufferGetImageBuffer(sample) {
                let image = CIImage(cvPixelBuffer: buffer)
                guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw ValidationFailure.failed("Decoded frame image creation failed") }
                result.images[result.frameCount] = cgImage
            }
            result.frameCount += 1
            result.videoEndSeconds = timestamp + (frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1 / 30)
        }
        guard reader.status == .completed else { throw reader.error ?? ValidationFailure.failed("Video decode did not complete") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioSamples = 0
        var audioFrames = 0
        var squares = 0.0
        var peak = 0.0
        var audioEnd = 0.0
        if let audio = audioTracks.first {
            let descriptions = try await audio.load(.formatDescriptions)
            if let first = descriptions.first { result.audioCodec = fourCC(CMFormatDescriptionGetMediaSubType(first)) }
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
            audioReader.add(audioOutput)
            guard audioReader.startReading() else { throw audioReader.error ?? ValidationFailure.failed("Audio decode failed to start") }
            while let sample = audioOutput.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let size = CMBlockBufferGetDataLength(block)
                var data = [UInt8](repeating: 0, count: size)
                let copyStatus = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
                guard copyStatus == kCMBlockBufferNoErr else { throw ValidationFailure.failed("Audio sample copy failed") }
                data.withUnsafeBytes { bytes in
                    for offset in stride(from: 0, to: size, by: 4) {
                        let value = Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
                        squares += value * value
                        peak = max(peak, abs(value))
                        audioSamples += 1
                    }
                }
                audioFrames += CMSampleBufferGetNumSamples(sample)
                audioEnd = max(audioEnd, CMSampleBufferGetPresentationTimeStamp(sample).seconds + CMSampleBufferGetDuration(sample).seconds)
            }
            guard audioReader.status == .completed else { throw audioReader.error ?? ValidationFailure.failed("Audio decode did not complete") }
        }
        result.audioRMS = audioSamples > 0 ? sqrt(squares / Double(audioSamples)) : 0
        result.metrics = ["containerDurationSeconds": duration.seconds, "decodedVideoFrames": Double(result.frameCount), "videoPresentationEndSeconds": result.videoEndSeconds, "audioDecodedSamplesPerChannel": Double(audioFrames), "audioPresentationEndSeconds": audioEnd, "audioRMS": result.audioRMS, "audioPeak": peak]
        return result
    }

    static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? String(value)
    }

    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let created = pixels.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard created else { throw ValidationFailure.failed("Image comparison context failed") }
        return pixels
    }

    static func compare(_ lhs: CGImage, _ rhs: CGImage) throws -> (mean: Double, p99: Double) {
        guard lhs.width == rhs.width && lhs.height == rhs.height else { throw ValidationFailure.failed("Preview and output frame dimensions differ") }
        let first = try rgba(lhs), second = try rgba(rhs)
        var total = 0.0
        var histogram = [Int](repeating: 0, count: 256)
        for offset in stride(from: 0, to: first.count, by: 4) {
            for channel in 0..<3 {
                let difference = abs(Int(first[offset + channel]) - Int(second[offset + channel]))
                total += Double(difference)
                histogram[difference] += 1
            }
        }
        let count = lhs.width * lhs.height * 3
        var cumulative = 0
        var percentile = 255
        for index in histogram.indices {
            cumulative += histogram[index]
            if Double(cumulative) >= Double(count) * 0.99 { percentile = index; break }
        }
        return (total / Double(count) / 255, Double(percentile) / 255)
    }

    static func averageColor(_ image: CGImage, normalizedRegion region: CGRect) throws -> [Double] {
        let data = try rgba(image)
        let startX = Int(region.minX * Double(image.width)), endX = Int(region.maxX * Double(image.width))
        let startY = Int(region.minY * Double(image.height)), endY = Int(region.maxY * Double(image.height))
        var sums = [Double](repeating: 0, count: 3)
        for y in startY..<endY { for x in startX..<endX { for channel in 0..<3 { sums[channel] += Double(data[(y * image.width + x) * 4 + channel]) } } }
        return sums.map { $0 / Double((endX - startX) * (endY - startY)) / 255 }
    }

    static func countCyanPixels(_ image: CGImage) throws -> Int {
        let data = try rgba(image)
        var count = 0
        for offset in stride(from: 0, to: data.count, by: 4) {
            if data[offset] < 70 && data[offset + 1] > 160 && data[offset + 2] > 160 { count += 1 }
        }
        return count
    }

    static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
    }

    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ValidationFailure.failed("Resize context allocation failed") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ValidationFailure.failed("Resize failed") }
        return result
    }

    static func contactSheet(preview: CGImage, exported: CGImage, frame: Int, to url: URL) throws {
        try Fixtures.writePNG(to: url, width: 1080, height: 1010) { context in
            context.setFillColor(CGColor(gray: 0.10, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 1010))
            context.draw(preview, in: CGRect(x: 0, y: 0, width: 540, height: 960))
            context.draw(exported, in: CGRect(x: 540, y: 0, width: 540, height: 960))
            Fixtures.drawText("PREVIEW · frame \(frame)", at: CGPoint(x: 18, y: 978), size: 23, context: context)
            Fixtures.drawText("DECODED MP4 · frame \(frame)", at: CGPoint(x: 558, y: 978), size: 23, context: context)
        }
    }
}

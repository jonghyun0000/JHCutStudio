import Foundation
import AVFoundation
import CoreImage
import CoreText

struct RenderLayer {
    let clip: Clip
    let trackID: CMPersistentTrackID?
    let image: CIImage?
    let orientation: CGAffineTransform
    /// Per-frame camera-shake correction for this clip, built once when the plan is built.
    var stabilization: StabilizationPlan? = nil
}

final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [RenderLayer]
    let canvas: CGSize
    init(range: CMTimeRange, layers: [RenderLayer], carrier: CMPersistentTrackID, canvas: CGSize) {
        timeRange = range; self.layers = layers; self.canvas = canvas
        requiredSourceTrackIDs = ([carrier] + layers.compactMap(\.trackID)).map { NSNumber(value: $0) }
    }
}

/// Shared by AVPlayerItem, AVAssetImageGenerator, and AVAssetReaderVideoCompositionOutput.
public final class TimelineCompositor: NSObject, AVVideoCompositing {
    private static let greenKey = CIColorKernel(source: "kernel vec4 key(__sample s, float strength) { vec3 rgb = unpremultiply(s).rgb; float excess = max(0.0, rgb.g - max(rgb.r, rgb.b)); float alpha = 1.0 - smoothstep(0.05, max(0.06, 1.0-strength), excess); return s * alpha; }")
    private let queue = DispatchQueue(label: "studio.jhcut.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
    // Match AVFoundation's video Rec.709 profile (HDTV), rather than the distinct generic graphics BT.709 ICC profile.
    private let colorSpace = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary)!.takeRetainedValue()
    public var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]() ]
    }
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? TimelineInstruction else {
                    request.finish(with: MediaEngineError.failed("잘못된 합성 명령입니다.")); return
                }
                guard let buffer = request.renderContext.newPixelBuffer() else {
                    request.finish(with: MediaEngineError.failed("영상 프레임 메모리를 확보하지 못했습니다.")); return
                }
                let bounds = CGRect(origin: .zero, size: instruction.canvas)
                var result = CIImage(color: .black).cropped(to: bounds)
                for layer in instruction.layers {
                    let source: CIImage
                    if let fixed = layer.image { source = fixed }
                    else if let trackID = layer.trackID, let frame = request.sourceFrame(byTrackID: trackID) {
                        var raw = CIImage(cvPixelBuffer: frame)
                        // Before the track rotation: the analysed path is in decoded-frame axes.
                        if let plan = layer.stabilization { raw = Self.stabilized(raw, plan: plan, clip: layer.clip, localSeconds: (request.compositionTime - layer.clip.start.cmTime).seconds) }
                        let oriented = raw.transformed(by: layer.orientation)
                        source = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
                    } else {
                        request.finish(with: MediaEngineError.failed("타임라인 영상 프레임을 디코딩하지 못했습니다: \(layer.clip.name)")); return
                    }
                    let localTime = MediaTime(request.compositionTime - layer.clip.start.cmTime)
                    let transform = layer.clip.evaluatedTransform(at: localTime)
                    var image = source
                    if let visual = layer.clip.visual {
                        let rect = image.extent
                        let crop = CGRect(x: rect.minX + rect.width * visual.cropLeft,
                                          y: rect.minY + rect.height * visual.cropBottom,
                                          width: rect.width * (1 - visual.cropLeft - visual.cropRight),
                                          height: rect.height * (1 - visual.cropTop - visual.cropBottom))
                        image = image.cropped(to: crop)
                        if visual.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": visual.exposure]) }
                        if visual.contrast != 1 || visual.saturation != 1 {
                            image = image.applyingFilter("CIColorControls", parameters: ["inputContrast": visual.contrast, "inputSaturation": visual.saturation])
                        }
                        if visual.temperature != nil || visual.tint != nil {
                            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: visual.temperature ?? 6500, y: visual.tint ?? 0)])
                        }
                        if visual.shadows != nil || visual.highlights != nil {
                            image = image.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25 + (visual.shadows ?? 0)), "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + (visual.highlights ?? 0)), "inputPoint4": CIVector(x: 1, y: 1)])
                        }
                        if let lut = visual.lut {
                            let data = lut.values.withUnsafeBytes { Data($0) }
                            image = image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": lut.size, "inputCubeData": data, "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
                        }
                        if let strength = visual.greenScreen, strength > 0 {
                            guard let keyed = Self.greenKey?.apply(extent: image.extent, arguments: [image, strength]) else { request.finish(with: MediaEngineError.failed("크로마키를 적용하지 못했습니다.")); return }
                            image = keyed
                        }
                        if visual.ellipseMask == true {
                            let extent = image.extent
                            let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.96, "inputRadius1": 1.0, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
                                .transformed(by: CGAffineTransform(scaleX: extent.width / 2, y: extent.height / 2))
                                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
                            image = image.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage(color: .clear).cropped(to: extent), "inputMaskImage": mask]).cropped(to: extent)
                        }
                    }
                    let input = image.extent
                    if layer.clip.title == nil {
                        let sx = bounds.width / input.width, sy = bounds.height / input.height
                        let fitted = (transform.fill ? max(sx, sy) : min(sx, sy)) * transform.scale
                        image = image.transformed(by: CGAffineTransform(translationX: -input.midX, y: -input.midY))
                            .transformed(by: CGAffineTransform(scaleX: fitted, y: fitted))
                            .transformed(by: CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
                            .transformed(by: CGAffineTransform(translationX: bounds.midX + transform.x, y: bounds.midY + transform.y))
                    } else {
                        // Title raster already uses normalized title coordinates on a full-size canvas.
                        image = image.transformed(by: CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
                            .transformed(by: CGAffineTransform(scaleX: transform.scale, y: transform.scale))
                            .transformed(by: CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
                            .transformed(by: CGAffineTransform(translationX: bounds.midX + transform.x, y: bounds.midY + transform.y))
                    }
                    let opacity = transform.opacity * ClipEnvelopes.fade(at: localTime.cmTime, duration: layer.clip.duration.cmTime, fadeIn: layer.clip.fadeIn?.cmTime, fadeOut: layer.clip.fadeOut?.cmTime)
                    if opacity < 1 {
                        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
                    }
                    result = image.composited(over: result).cropped(to: bounds)
                }
                context.render(result, to: buffer, bounds: bounds, colorSpace: colorSpace)
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                request.finish(withComposedVideoFrame: buffer)
            }
        }
    }
    /// Removes the measured shake: translate/rotate by the correction and zoom by the plan's constant
    /// factor so the frame edges never show. Coordinates are those of the decoded frame.
    static func stabilized(_ image: CIImage, plan: StabilizationPlan, clip: Clip, localSeconds: Double) -> CIImage {
        let rate = (clip.playbackRate ?? PlaybackRate()).multiplier
        let c = plan.correction(atSource: clip.sourceStart.seconds + max(0, localSeconds) * rate)
        let e = image.extent
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .transformed(by: CGAffineTransform(scaleX: plan.zoom, y: plan.zoom))
            .transformed(by: CGAffineTransform(rotationAngle: c.angle))
            .transformed(by: CGAffineTransform(translationX: e.midX + c.x * e.width, y: e.midY + c.y * e.height))
            .cropped(to: e)
    }
    public func cancelAllPendingVideoCompositionRequests() {
        // Queue drain guarantees no previous request survives completion of this cancellation call.
        queue.sync { }
    }
}

enum TitleRasterizer {
    static func image(title: Title, size: CGSize) throws -> CIImage {
        let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        guard names.contains(title.fontName) else {
            throw MediaEngineError.unsupported("설치되지 않은 글꼴입니다: \(title.fontName). 제목 속성에서 설치된 글꼴을 선택하세요.")
        }
        if let style = title.style { return try StyledTitleRasterizer.image(title: title, size: size, style: style) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaEngineError.failed("제목을 그릴 수 없습니다.")
        }
        let hex = title.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let rgb = UInt32(hex, radix: 16) ?? 0xFFFFFF
        let color = CGColor(colorSpace: space, components: [CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255, CGFloat(rgb & 255) / 255, 1])!
        let font = CTFontCreateWithName(title.fontName as CFString, title.fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            let setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate([setting], 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        let string = NSAttributedString(string: title.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let width = size.width * 0.88
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: string.length), nil,
                                                                    CGSize(width: width, height: size.height), nil)
        let rect = CGRect(x: size.width * title.x - width / 2, y: size.height * title.y - ceil(suggested.height) / 2,
                          width: width, height: ceil(suggested.height) + 4)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: string.length), CGPath(rect: rect, transform: nil), nil)
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 7, color: CGColor(gray: 0, alpha: 0.9))
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw MediaEngineError.failed("제목 이미지 생성에 실패했습니다.") }
        return CIImage(cgImage: image)
    }
}

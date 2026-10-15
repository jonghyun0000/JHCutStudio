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
    /// Drawn extent of the text, computed only for titles that use the typewriter reveal.
    var titleBounds: CGRect? = nil
    var outgoingFamily: UUID? = nil
}

final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let layers: [RenderLayer]
    let canvas: CGSize
    let transparentBackground: Bool
    init(range: CMTimeRange, layers: [RenderLayer], carrier: CMPersistentTrackID, canvas: CGSize, transparentBackground: Bool = false) {
        timeRange = range; self.layers = layers; self.canvas = canvas
        self.transparentBackground = transparentBackground
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
                let background = CIImage(color: instruction.transparentBackground ? .clear : .black).cropped(to: bounds)
                var groups: [(families: Set<UUID>, scene: BlendScene)] = []
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
                        if let key = visual.chromaKey {
                            guard visual.greenScreen == nil else { request.finish(with: ProjectError("중복된 크로마키 설정입니다.")); return }
                            do { image = try ChromaKeyRenderer.apply(to: image, key: key) }
                            catch { request.finish(with: error); return }
                        }
                        do { image = try ShapeMaskRenderer.apply(to: image, visual: visual) }
                        catch { request.finish(with: error); return }
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
                        if let animation = layer.clip.titleAnimation, !animation.isEmpty, let title = layer.clip.title {
                            let state = animation.state(at: localTime.seconds, clipDuration: layer.clip.duration.seconds)
                            // Scaling is about the title's own anchor (Title.x/y are fractions of the canvas, y up).
                            image = TransitionRenderer.animate(image, state: state, anchor: CGPoint(x: title.x * bounds.width, y: title.y * bounds.height), canvas: bounds, textBounds: layer.titleBounds)
                        }
                        image = image.transformed(by: CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
                            .transformed(by: CGAffineTransform(scaleX: transform.scale, y: transform.scale))
                            .transformed(by: CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
                            .transformed(by: CGAffineTransform(translationX: bounds.midX + transform.x, y: bounds.midY + transform.y))
                    }
                    let opacity = transform.opacity * ClipEnvelopes.fade(at: localTime.cmTime, duration: layer.clip.duration.cmTime, fadeIn: layer.clip.fadeIn?.cmTime, fadeOut: layer.clip.fadeOut?.cmTime)
                    if opacity < 1 {
                        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
                    }
                    let family = TransitionEditing.family(layer.clip)
                    let scene = BlendScene.clip(image, layer.clip.blendMode ?? .normal)
                    // Pair only the outgoing/incoming scenes. Decorative overlays are composed
                    // afterward at their own positions and never move with a push transition.
                    if let transition = layer.clip.transition, layer.clip.title == nil, transition.isActive(at: localTime), transition.independentFade == true || transition.kind != .dissolve || layer.clip.fadeIn == nil {
                        if let outgoing = layer.outgoingFamily, let index = groups.lastIndex(where: { $0.families.contains(outgoing) }) {
                            groups[index].scene = .transition(transition, transition.progress(at: localTime), scene, groups[index].scene)
                            groups[index].families.insert(family)
                        } else {
                            let clear = CIImage(color: .clear).cropped(to: bounds)
                            groups.append(([family], .transition(transition, transition.progress(at: localTime), scene, .clip(clear, .normal))))
                        }
                    } else {
                        groups.append(([family], scene))
                    }
                }
                let result: CIImage
                do {
                    result = try groups.reduce(background) { try $1.scene.render(over: $0, bounds: bounds) }
                } catch { request.finish(with: error); return }
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
        try StyledTitleRasterizer.image(title: title, size: size, style: StyledTitleRasterizer.style(for: title))
    }
}

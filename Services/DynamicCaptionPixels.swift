import Foundation
import CoreImage
import AVFoundation

/// Time-specific glyph mask and conservative footprint. Never supplies a static answer for an effect.
enum DynamicCaptionPixels {
    /// Remove only this title from a copy of the same instructions. Original plan remains immutable.
    static func background(plan: RenderPlan, clipID: UUID) throws -> AVAssetImageGenerator {
        guard let composition = plan.videoComposition.mutableCopy() as? AVMutableVideoComposition else { throw ProjectError("합성 참조를 복사할 수 없습니다.") }
        composition.instructions = try plan.videoComposition.instructions.map { raw in
            guard let instruction = raw as? TimelineInstruction,
                  let carrier = instruction.requiredSourceTrackIDs?.first as? NSNumber else { throw ProjectError("효과 합성 참조 형식이 지원되지 않습니다.") }
            return TimelineInstruction(range: instruction.timeRange, layers: instruction.layers.filter { $0.clip.id != clipID }, carrier: carrier.int32Value, canvas: instruction.canvas, transparentBackground: instruction.transparentBackground)
        }
        let generator = AVAssetImageGenerator(asset: plan.composition)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return generator
    }
    static func bounds(clip: Clip, time: Double, size: CGSize) throws -> CGRect? {
        guard let title = clip.title,
              var box = TitlePreviewRenderer.fullBounds(title: title, size: size) else { return nil }
        let local = MediaTime(seconds: time - clip.start.seconds)
        let transform = clip.evaluatedTransform(at: local)
        let state = clip.titleAnimation?.state(at: local.seconds, clipDuration: clip.duration.seconds) ?? .rest
        let opacity = transform.opacity * state.opacity * ClipEnvelopes.fade(at: local.cmTime, duration: clip.duration.cmTime, fadeIn: clip.fadeIn?.cmTime, fadeOut: clip.fadeOut?.cmTime)
        guard opacity > 0.01, state.reveal > 0 else { return nil }
        // Core Image works with y up; footprint APIs return y down.
        box.origin.y = size.height - box.maxY
        if state.reveal < 1 {
            let text = try CaptionLayout.bounds(of: title, width: Int(size.width), height: Int(size.height)) ?? box
            let soft = max(4, text.width * 0.03)
            let edge = text.minX + state.reveal * (text.width + soft)
            box = box.intersection(CGRect(x: box.minX, y: box.minY, width: max(0, edge - box.minX), height: box.height))
        }
        guard !box.isNull, !box.isEmpty else { return nil }
        let anchor = CGPoint(x: title.x * size.width, y: title.y * size.height)
        box = box.offsetBy(dx: -anchor.x, dy: -anchor.y).applying(CGAffineTransform(scaleX: state.scale, y: state.scale)).offsetBy(dx: anchor.x + state.offsetX * size.width, dy: anchor.y + state.offsetY * size.height)
        box = box.offsetBy(dx: -size.width / 2, dy: -size.height / 2)
            .applying(CGAffineTransform(scaleX: transform.scale, y: transform.scale))
            .applying(CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
            .offsetBy(dx: size.width / 2 + transform.x, dy: size.height / 2 + transform.y)
        return CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height)
    }

    static func glyphs(clip: Clip, time: Double, size: CGSize) throws -> CGImage {
        guard var title = clip.title else { throw ProjectError("자막 문구가 없습니다.") }
        var style = title.style ?? TextStyle(padding: 0, lineSpacing: 0)
        style.backgroundOpacity = 0; style.shadow = false; style.strokeWidth = 0; title.style = style
        var image = try TitleRasterizer.image(title: title, size: size)
        let canvas = CGRect(origin: .zero, size: size)
        let local = MediaTime(seconds: time - clip.start.seconds)
        if let animation = clip.titleAnimation, !animation.isEmpty {
            let text = clip.title.flatMap { try? CaptionLayout.bounds(of: $0, width: Int(size.width), height: Int(size.height)) }
            image = TransitionRenderer.animate(image, state: animation.state(at: local.seconds, clipDuration: clip.duration.seconds), anchor: CGPoint(x: title.x * size.width, y: title.y * size.height), canvas: canvas, textBounds: text)
        }
        let transform = clip.evaluatedTransform(at: local)
        image = image.transformed(by: CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY))
            .transformed(by: CGAffineTransform(scaleX: transform.scale, y: transform.scale))
            .transformed(by: CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
            .transformed(by: CGAffineTransform(translationX: canvas.midX + transform.x, y: canvas.midY + transform.y))
        let opacity = transform.opacity * ClipEnvelopes.fade(at: local.cmTime, duration: clip.duration.cmTime, fadeIn: clip.fadeIn?.cmTime, fadeOut: clip.fadeOut?.cmTime)
        image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        guard let result = context.createCGImage(image, from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ProjectError("효과 자막 표본을 만들 수 없습니다.") }
        return result
    }
}

import Foundation
import CoreImage
import CoreGraphics

/// Input images contain premultiplied alpha, including clip opacity, masks, and fades.
/// Core Image evaluates the separable blend and Porter-Duff source-over in the existing
/// extended-linear-sRGB context. No manual gamma conversion or second opacity gain is applied.
enum ClipBlendRenderer {
    static func compose(_ foreground: CIImage, over background: CIImage,
                        mode: ClipBlendMode, bounds: CGRect) throws -> CIImage {
        if mode == .normal { return foreground.composited(over: background).cropped(to: bounds) }
        let name: String
        switch mode {
        case .normal: name = "CISourceOverCompositing"
        case .multiply: name = "CIMultiplyBlendMode"
        case .screen: name = "CIScreenBlendMode"
        case .overlay: name = "CIOverlayBlendMode"
        case .darken: name = "CIDarkenBlendMode"
        case .lighten: name = "CILightenBlendMode"
        }
        guard let filter = CIFilter(name: name, parameters: [kCIInputImageKey: foreground,
                                                            kCIInputBackgroundImageKey: background]),
              let output = filter.outputImage else {
            throw MediaEngineError.failed("블렌드 모드를 적용할 수 없습니다: \(mode.label)")
        }
        return output.cropped(to: bounds)
    }
}

/// Transition-scene tree preserves the identity of each clip's blend mode through chained
/// transitions. Decorative groups still compose at their original track positions.
///
/// Semantics for a group containing a non-normal mode:
///  - outgoing and incoming scenes blend independently with the SAME lower-track canvas;
///  - transition opacity/wipe weights interpolate those scene results (premultiplied RGBA);
///  - slide/push/zoom move the source scene BEFORE its blend is evaluated against that fixed canvas;
///  - a scene's transparent pixels therefore reveal the lower-track canvas, not the other scene.
/// This avoids a mode switching its backdrop when a transition ends, or dragging the lower tracks.
/// All-normal groups take the original renderer path, including legacy alpha behavior.
/// Full-canvas byte equality is a regression gate; it must be established by executing the probe.
indirect enum BlendScene {
    case clip(CIImage, ClipBlendMode)
    case transition(ClipTransition, Double, BlendScene, BlendScene) // incoming, outgoing

    var hasBlend: Bool {
        switch self {
        case .clip(_, let mode): return mode != .normal
        case .transition(_, _, let incoming, let outgoing): return incoming.hasBlend || outgoing.hasBlend
        }
    }

    private func legacyImage(bounds: CGRect) -> CIImage {
        switch self {
        case .clip(let image, _): return image
        case .transition(let effect, let progress, let incoming, let outgoing):
            return TransitionRenderer.compose(effect, progress: progress,
                incoming: incoming.legacyImage(bounds: bounds), below: outgoing.legacyImage(bounds: bounds), bounds: bounds)
        }
    }

    func render(over background: CIImage, bounds: CGRect,
                transform: CGAffineTransform = .identity) throws -> CIImage {
        if !hasBlend {
            let legacy = legacyImage(bounds: bounds)
            // The identity branch preserves all old normal-composition pixels exactly.
            let placed = transform.isIdentity ? legacy : legacy.transformed(by: transform)
            return placed.composited(over: background).cropped(to: bounds)
        }
        switch self {
        case .clip(let image, let mode):
            return try ClipBlendRenderer.compose(image.transformed(by: transform),
                                                  over: background, mode: mode, bounds: bounds)
        case .transition(let effect, let progress, let incoming, let outgoing):
            let p = min(1, max(0, progress)), e = Easing.inOut(p)
            let dir = effect.direction.vector
            // Every descendant is evaluated on the unchanged lower-track background. A parent
            // spatial transition accumulates only source/mask transforms, never background transforms.
            func scene(_ node: BlendScene, movedBy local: CGAffineTransform = .identity) throws -> CIImage {
                try node.render(over: background, bounds: bounds, transform: local.concatenating(transform))
            }
            func mix(_ front: CIImage, _ back: CIImage, weight: Double) -> CIImage {
                // Weight lives in alpha, which is never colour-space converted.
                let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: weight)).cropped(to: bounds)
                return front.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: back,
                                                                              kCIInputMaskImageKey: mask]).cropped(to: bounds)
            }
            func masked(_ front: CIImage, _ back: CIImage, _ mask: CIImage) -> CIImage {
                front.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back,
                                                                    kCIInputMaskImageKey: mask]).cropped(to: bounds)
            }
            func coverage(_ node: BlendScene, _ local: CGAffineTransform) -> CIImage {
                // A positioned/oversized leaf may begin outside the canvas and move back in.
                // Do not clip its pixels OR transition coverage until after the motion.
                let extent: CGRect
                if case .clip(let image, _) = node { extent = bounds.union(image.extent) }
                else { extent = bounds } // A nested transition already owns a canvas result.
                return CIImage(color: .white).cropped(to: extent).transformed(by: local.concatenating(transform))
                    .composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
            }
            switch effect.kind {
            case .dissolve:
                return try mix(scene(incoming), scene(outgoing), weight: p)
            case .dipToBlack:
                let black = CIImage(color: .black).cropped(to: bounds).transformed(by: transform)
                    .composited(over: background).cropped(to: bounds)
                return try p < 0.5 ? mix(black, scene(outgoing), weight: p * 2)
                                  : mix(scene(incoming), black, weight: (p - 0.5) * 2)
            case .slide:
                let move = CGAffineTransform(translationX: dir.x * bounds.width * (1 - e), y: dir.y * bounds.height * (1 - e))
                return try masked(scene(incoming, movedBy: move), scene(outgoing), coverage(incoming, move))
            case .push:
                let out = CGAffineTransform(translationX: -dir.x * bounds.width * e, y: -dir.y * bounds.height * e)
                let move = CGAffineTransform(translationX: dir.x * bounds.width * (1 - e), y: dir.y * bounds.height * (1 - e))
                let bottom = try masked(scene(outgoing, movedBy: out), background, coverage(outgoing, out))
                return try masked(scene(incoming, movedBy: move), bottom, coverage(incoming, move))
            case .wipe:
                let length = abs(dir.x) > 0 ? bounds.width : bounds.height
                let soft = length * 0.06, travelled = e * (length + soft)
                let (origin, unit) = TransitionRenderer.wipeFrame(dir: dir, bounds: bounds)
                let p0 = CIVector(x: origin.x + unit.x * (travelled - soft), y: origin.y + unit.y * (travelled - soft))
                let p1 = CIVector(x: origin.x + unit.x * travelled, y: origin.y + unit.y * travelled)
                guard let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": p0, "inputPoint1": p1,
                      "inputColor0": CIColor.white, "inputColor1": CIColor.black])?.outputImage else {
                    throw MediaEngineError.failed("블렌드 장면의 와이프를 만들지 못했습니다.")
                }
                let mask = gradient.cropped(to: bounds).transformed(by: transform)
                    .composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
                return try masked(scene(incoming), scene(outgoing), mask)
            case .zoom:
                let scale = 1.35 - 0.35 * e
                let move = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: bounds.midX, y: bounds.midY))
                return try mix(scene(incoming, movedBy: move), scene(outgoing), weight: e)
            }
        }
    }
}

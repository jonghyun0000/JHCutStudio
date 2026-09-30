import Foundation
import CoreImage
import CoreGraphics

/// Draws the overlap of a transition and animated titles. Pure Core Image: the compositor passes
/// what is already on the canvas ("below") and the incoming picture already placed on the canvas.
enum TransitionRenderer {
    /// `progress` runs 0 → 1 across the transition. Dissolve is handled by the clip's fade-in and never gets here.
    static func compose(_ transition: ClipTransition, progress: Double, incoming: CIImage, below: CIImage, bounds: CGRect) -> CIImage {
        let p = min(1, max(0, progress)), e = Easing.inOut(p)
        let w = bounds.width, h = bounds.height
        let dir = transition.direction.vector
        func black(_ alpha: Double) -> CIImage { CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha)).cropped(to: bounds) }
        let backdrop = black(1)
        switch transition.kind {
        case .dissolve:
            return incoming.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)]).composited(over: below).cropped(to: bounds)
        case .dipToBlack:
            // First half: the outgoing picture sinks into black; second half: the incoming one rises out of it.
            if p < 0.5 { return black(min(1, p * 2)).composited(over: below).cropped(to: bounds) }
            return black(min(1, (1 - p) * 2)).composited(over: incoming.composited(over: backdrop)).cropped(to: bounds)
        case .slide:
            // The incoming picture slides over the outgoing one, which stays put.
            let moved = incoming.transformed(by: CGAffineTransform(translationX: dir.x * w * (1 - e), y: dir.y * h * (1 - e)))
            return moved.composited(over: below).cropped(to: bounds)
        case .push:
            // Both pictures move together: the outgoing one is pushed off the opposite side.
            let outgoing = below.transformed(by: CGAffineTransform(translationX: -dir.x * w * e, y: -dir.y * h * e))
            let moved = incoming.transformed(by: CGAffineTransform(translationX: dir.x * w * (1 - e), y: dir.y * h * (1 - e)))
            return moved.composited(over: outgoing.composited(over: backdrop)).cropped(to: bounds)
        case .wipe:
            // A soft edge travels from the chosen side; the incoming picture shows behind it.
            let soft = 0.06 * (abs(dir.x) > 0 ? w : h)
            let length = abs(dir.x) > 0 ? w : h
            let travelled = e * (length + soft)
            let (origin, unit) = wipeFrame(dir: dir, bounds: bounds)
            let p0 = CIVector(x: origin.x + unit.x * (travelled - soft), y: origin.y + unit.y * (travelled - soft))
            let p1 = CIVector(x: origin.x + unit.x * travelled, y: origin.y + unit.y * travelled)
            guard let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": p0, "inputPoint1": p1, "inputColor0": CIColor.white, "inputColor1": CIColor.black])?.outputImage else { return incoming.composited(over: below).cropped(to: bounds) }
            return incoming.composited(over: backdrop).applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": below, "inputMaskImage": gradient.cropped(to: bounds)]).cropped(to: bounds)
        case .zoom:
            // The incoming picture zooms in from 1.35× while it fades in.
            let s = 1.35 - 0.35 * e, c = CGPoint(x: bounds.midX, y: bounds.midY)
            let zoomed = incoming.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)).transformed(by: CGAffineTransform(scaleX: s, y: s)).transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
            return zoomed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: e)]).composited(over: below).cropped(to: bounds)
        }
    }

    /// Start point of the wipe edge (the side the picture comes from) and the unit vector it travels along.
    static func wipeFrame(dir: (x: Double, y: Double), bounds: CGRect) -> (origin: CGPoint, unit: CGPoint) {
        switch (dir.x, dir.y) {
        case (-1, 0): return (CGPoint(x: bounds.minX, y: bounds.midY), CGPoint(x: 1, y: 0))    // from the left, edge moves right
        case (1, 0): return (CGPoint(x: bounds.maxX, y: bounds.midY), CGPoint(x: -1, y: 0))
        case (0, 1): return (CGPoint(x: bounds.midX, y: bounds.maxY), CGPoint(x: 0, y: -1))    // from the top, edge moves down
        default: return (CGPoint(x: bounds.midX, y: bounds.minY), CGPoint(x: 0, y: 1))
        }
    }

    /// Applies a title animation state to a title raster laid out on the full canvas.
    /// `anchor` is the point (canvas pixels) the title scales about; `textBounds` is needed only for `reveal < 1`.
    static func animate(_ title: CIImage, state: TitleAnimation.State, anchor: CGPoint, canvas: CGRect, textBounds: CGRect?) -> CIImage {
        var image = title
        if state.reveal < 1 {
            if let box = textBounds {
                let soft = max(4, box.width * 0.03)
                let edge = box.minX + state.reveal * (box.width + soft)
                if let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: edge - soft, y: 0), "inputPoint1": CIVector(x: edge, y: 0), "inputColor0": CIColor.white, "inputColor1": CIColor.black])?.outputImage {
                    image = image.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage(color: .clear).cropped(to: canvas), "inputMaskImage": gradient.cropped(to: canvas)]).cropped(to: canvas)
                }
            } else { image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: state.reveal)]) }
        }
        if state.scale != 1 {
            image = image.transformed(by: CGAffineTransform(translationX: -anchor.x, y: -anchor.y)).transformed(by: CGAffineTransform(scaleX: state.scale, y: state.scale)).transformed(by: CGAffineTransform(translationX: anchor.x, y: anchor.y))
        }
        if state.offsetX != 0 || state.offsetY != 0 {
            image = image.transformed(by: CGAffineTransform(translationX: state.offsetX * canvas.width, y: state.offsetY * canvas.height))
        }
        if state.opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, state.opacity))])
        }
        return image
    }
}

import Foundation
import CoreImage
import CoreGraphics

/// Masks retain the input extent so fitting never stretches a newly smaller visible footprint.
/// Color, existing alpha and chroma key are multiplied by the shape coverage, never replaced.
enum ShapeMaskRenderer {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 shapeCoverage(__sample pixel, vec2 center, vec2 halfSize,
                                  float angle, float feather, float rectangle) {
            vec2 delta = destCoord() - center;
            float c = cos(angle);
            float s = sin(angle);
            vec2 local = vec2(c * delta.x + s * delta.y, -s * delta.x + c * delta.y) / halfSize;
            float radius = rectangle > 0.5 ? max(abs(local.x), abs(local.y)) : length(local);
            float coverage = feather > 0.0 ? 1.0 - smoothstep(1.0 - feather, 1.0, radius)
                                          : (radius <= 1.0 ? 1.0 : 0.0);
            return pixel * coverage;
        }
        """)

    static func apply(to source: CIImage, visual: VisualAdjustments) throws -> CIImage {
        if let shape = visual.shapeMask {
            guard visual.ellipseMask != true else { throw ProjectError("기존 타원과 새 도형 마스크가 중복되었습니다.") }
            if let problem = shape.validationProblem { throw ProjectError(problem) }
            let extent = source.extent
            guard !extent.isNull, !extent.isInfinite, extent.minX.isFinite, extent.minY.isFinite, extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0 else { throw ProjectError("마스크 원본 영상의 크기가 올바르지 않습니다.") }
            let center = CIVector(x: extent.minX + CGFloat(shape.centerX) * extent.width,
                                  y: extent.minY + CGFloat(shape.centerY) * extent.height)
            let halfSize = CIVector(x: CGFloat(shape.width) * extent.width / 2,
                                    y: CGFloat(shape.height) * extent.height / 2)
            let angle: Double = shape.rotation * .pi / 180
            let rectangle: Double = shape.kind == .rectangle ? 1 : 0
            guard let result = kernel?.apply(extent: extent, arguments: [source, center, halfSize, angle, shape.feather, rectangle]) else {
                throw MediaEngineError.failed("도형 마스크를 적용하지 못했습니다.")
            }
            return result.cropped(to: extent)
        }
        if visual.ellipseMask == true {
            // Original ellipse pipeline preserved: fixed normalized radii 0.96 -> 1,
            // independently scaled axes, then mask compositing. Do not migrate old flags.
            let extent = source.extent
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.96, "inputRadius1": 1.0, "inputColor0": CIColor.white, "inputColor1": CIColor.black])?.outputImage else {
                throw MediaEngineError.failed("기존 타원 마스크를 적용하지 못했습니다.")
            }
            let mask = gradient
                .transformed(by: CGAffineTransform(scaleX: extent.width / 2, y: extent.height / 2))
                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
            return source.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage(color: .clear).cropped(to: extent), "inputMaskImage": mask]).cropped(to: extent)
        }
        return source
    }
}

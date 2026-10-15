import Foundation
import CoreImage

/// New selected-color path only. The legacy green-screen kernel stays in TimelineCompositor.
/// Preserves cropped source extent and premultiplied alpha before masks, transforms and blend.
enum ChromaKeyRenderer {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 selectedColorKey(__sample pixel, vec3 key, float chromatic,
                                     float similarity, float softness, float spill) {
            if (pixel.a <= 0.0) { return vec4(0.0); }
            vec3 rgb = unpremultiply(pixel).rgb;
            vec3 positive = max(rgb, vec3(0.0));
            float keyDistance = 1.0;
            if (chromatic > 0.5) {
                float total = positive.r + positive.g + positive.b;
                float keyTotal = key.r + key.g + key.b;
                if (total > 0.000001) {
                    keyDistance = clamp(length(positive / total - key / keyTotal) / sqrt(2.0), 0.0, 1.0);
                }
            } else {
                keyDistance = clamp(length(positive - key) / sqrt(3.0), 0.0, 1.0);
            }
            float coverage = softness > 0.0 ? smoothstep(similarity, similarity + softness, keyDistance)
                                           : (keyDistance <= similarity ? 0.0 : 1.0);
            vec3 corrected = rgb;
            if (chromatic > 0.5 && spill > 0.0) {
                vec3 weights = vec3(0.2126, 0.7152, 0.0722);
                vec3 keyChroma = key - vec3(dot(key, weights));
                vec3 direction = keyChroma / length(keyChroma);
                vec3 sourceChroma = rgb - vec3(dot(rgb, weights));
                float projection = max(dot(sourceChroma, direction), 0.0);
                float start = similarity + softness;
                float end = min(1.0, start + 0.25);
                float influence = keyDistance <= start ? 1.0 : (keyDistance >= end ? 0.0 : 1.0 - smoothstep(start, end, keyDistance));
                corrected = max(rgb - spill * influence * projection * direction, vec3(0.0));
            }
            float alpha = pixel.a * coverage;
            return vec4(corrected * alpha, alpha);
        }
        """)
    static func apply(to source: CIImage, key: ChromaKey) throws -> CIImage {
        if let problem = key.validationProblem { throw ProjectError(problem) }
        let extent = source.extent
        guard !extent.isNull, !extent.isInfinite, extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw ProjectError("크로마키 원본 영상의 크기가 올바르지 않습니다.")
        }
        let values = key.linearRGB
        let color = CIVector(x: values[0], y: values[1], z: values[2])
        guard let result = kernel?.apply(extent: source.extent, arguments: [source, color, key.isChromatic ? 1.0 : 0.0, key.similarity, key.softness, key.spillReduction]) else {
            throw MediaEngineError.failed("선택 색 크로마키를 적용하지 못했습니다.")
        }
        return result.cropped(to: source.extent)
    }
}

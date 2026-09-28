import Foundation
import CoreGraphics

/// Where a caption's pixels actually land on the canvas, measured from the same rasteriser the
/// preview and export use — so “inside the safe area” means the drawn glyphs, stroke and
/// background box, not an estimate from font metrics.
public enum CaptionLayout {
    /// Share of each dimension that counts as safe (80% → 10% margin on every side).
    public static let safeFraction = 0.8

    public static func safeArea(width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        return CGRect(x: w * (1 - safeFraction) / 2, y: h * (1 - safeFraction) / 2, width: w * safeFraction, height: h * safeFraction)
    }

    /// Bounding box of visible pixels, top-left origin, in canvas pixels. nil for an empty raster.
    public static func bounds(of title: Title, width: Int, height: Int) throws -> CGRect? {
        let image = try TitlePreviewRenderer.image(title: title, size: CGSize(width: width, height: height))
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where pixels[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows are stored top-down in this context.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    public static func isInsideSafeArea(_ title: Title, width: Int, height: Int) throws -> Bool {
        guard let box = try bounds(of: title, width: width, height: height) else { return true }
        return safeArea(width: width, height: height).insetBy(dx: -1, dy: -1).contains(box)
    }

    /// Shrinks the font (never below `minimumFontSize`) until the caption fits the safe width,
    /// then moves it vertically into the safe area. Returns nil when it cannot fit even at the
    /// minimum size — the caller reports that caption instead of silently clipping it.
    public static func fitted(_ original: Title, width: Int, height: Int, minimumFontSize: Double = 24) throws -> Title? {
        var title = original
        let safe = safeArea(width: width, height: height)
        for _ in 0..<24 {
            guard let box = try bounds(of: title, width: width, height: height) else { return title }
            if box.width > safe.width + 1 || box.height > safe.height + 1 {
                guard title.fontSize > minimumFontSize else { return nil }
                let factor = max(0.6, min(0.95, Double(safe.width / max(1, box.width)), Double(safe.height / max(1, box.height))))
                title.fontSize = max(minimumFontSize, (title.fontSize * factor).rounded(.down))
                title.style?.strokeWidth *= factor; title.style?.padding *= factor
                continue
            }
            // Title.y is normalised with 0 at the bottom; pixel boxes are top-down.
            var shift = 0.0
            if box.minY < safe.minY { shift = Double(box.minY - safe.minY) }            // too high: move down (negative y)
            else if box.maxY > safe.maxY { shift = Double(box.maxY - safe.maxY) }       // too low: move up
            var dx = 0.0
            if box.minX < safe.minX { dx = Double(safe.minX - box.minX) } else if box.maxX > safe.maxX { dx = Double(safe.maxX - box.maxX) }
            if shift == 0 && dx == 0 { return title }
            title.y = min(1, max(0, title.y + shift / Double(height)))
            title.x = min(1, max(0, title.x + dx / Double(width)))
        }
        return try isInsideSafeArea(title, width: width, height: height) ? title : nil
    }
}

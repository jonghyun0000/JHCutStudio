import Foundation
import CoreGraphics
import CoreImage
import CoreText

public struct TitleLayoutInfo: Sendable {
    public let totalLines: Int
    public let visibleLines: Int
    public var wasTruncated: Bool { visibleLines < totalLines }
    public let lineLimit: Int
    public let lineTexts: [String]
    public let effectiveFontName: String
    public let usesFallbackFont: Bool
    public var exceedsLineLimit: Bool { lineLimit > 0 && totalLines > lineLimit }
}

/// Shares the exact Core Text rasterizer used in video preview and export.
public enum TitlePreviewRenderer {
    public static func image(title: Title, size: CGSize) throws -> CGImage {
        let raster = try TitleRasterizer.image(title: title, size: size)
        guard let result = CIContext().createCGImage(raster, from: raster.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw MediaEngineError.failed("제목 미리보기를 만들 수 없습니다.")
        }
        return result
    }
    public static func layout(title: Title, canvasWidth: Double) throws -> TitleLayoutInfo {
        let style = StyledTitleRasterizer.style(for: title)
        let lines = StyledTitleRasterizer.layout(title: title, width: StyledTitleRasterizer.wrapWidth(style: style, canvasWidth: canvasWidth))
        let font = StyledTitleRasterizer.fontName(for: title)
        return TitleLayoutInfo(totalLines: lines.count, visibleLines: lines.count, lineLimit: style.maxLines,
                               lineTexts: lines.map { (title.text as NSString).substring(with: NSRange(location: $0.range.location, length: $0.range.length)) },
                               effectiveFontName: font, usesFallbackFont: font != title.fontName)
    }
    /// Full conservative footprint BEFORE the canvas clips pixels, in top-left coordinates.
    public static func fullBounds(title: Title, size: CGSize) -> CGRect? {
        let plan = StyledTitleRasterizer.plan(title: title, size: size, style: StyledTitleRasterizer.style(for: title))
        guard let box = plan.bounds else { return nil }
        return CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height)
    }

}

/// Title.x anchors the left edge, center, or right edge according to alignment; Title.y centers the block.
/// maxLines is a review target. Every input grapheme is retained; overflow is diagnosed separately.
enum StyledTitleRasterizer {
    struct Line { let line: CTLine; let fillLine: CTLine; let range: CFRange; let width: CGFloat }
    private static let fonts = Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
    static func fontName(for title: Title) -> String { fonts.contains(title.fontName) ? title.fontName : "AppleSDGothicNeo-Bold" }
    static func style(for title: Title) -> TextStyle {
        title.style ?? TextStyle(padding: 0, lineSpacing: 0)
    }
    static func wrapWidth(style: TextStyle, canvasWidth: CGFloat) -> CGFloat {
        max(1, canvasWidth * (style.wrapWidthFraction ?? 0.88) - style.padding * 2)
    }
    struct Plan { let lines: [Line]; let positions: [CGPoint]; let textRect: CGRect; let bounds: CGRect? }
    static func plan(title: Title, size: CGSize, style: TextStyle) -> Plan {
        let lines = layout(title: title, width: wrapWidth(style: style, canvasWidth: size.width))
        let font = CTFontCreateWithName(fontName(for: title) as CFString, title.fontSize, nil)
        var metrics: [(CGFloat, CGFloat, CGFloat)] = []
        for line in lines {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            _ = CTLineGetTypographicBounds(line.line, &a, &d, &l)
            metrics.append((max(a, CTFontGetAscent(font)), max(d, CTFontGetDescent(font)), max(l, CTFontGetLeading(font))))
        }
        let height = metrics.reduce(0) { $0 + $1.0 + $1.1 + $1.2 } + CGFloat(max(0, lines.count - 1)) * style.lineSpacing
        // Do not cap the width of an indivisible grapheme or an over-wide glyph.
        let widest = lines.map(\.width).max() ?? 0
        let anchor = size.width * title.x
        let originX = style.alignment == .left ? anchor : style.alignment == .right ? anchor - widest : anchor - widest / 2
        let textRect = CGRect(x: originX, y: size.height * title.y - height / 2, width: widest, height: height)
        var positions: [CGPoint] = [], cursor = textRect.maxY
        var box: CGRect? = nil
        for (i, line) in lines.enumerated() {
            let x = style.alignment == .left ? textRect.minX : style.alignment == .right ? textRect.maxX - line.width : textRect.midX - line.width / 2
            let point = CGPoint(x: x, y: cursor - metrics[i].0)
            positions.append(point)
            let ink = CTLineGetBoundsWithOptions(line.line, [.useGlyphPathBounds]).offsetBy(dx: point.x, dy: point.y)
            if !ink.isEmpty, !ink.isNull { box = box.map { $0.union(ink) } ?? ink }
            cursor -= metrics[i].0 + metrics[i].1 + metrics[i].2 + style.lineSpacing
        }
        if let ink = box { box = ink.insetBy(dx: -style.strokeWidth, dy: -style.strokeWidth) }
        if style.backgroundOpacity > 0, !lines.isEmpty {
            let background = textRect.insetBy(dx: -style.padding, dy: -style.padding)
            box = box.map { $0.union(background) } ?? background
        }
        // Conservative shadow support, including fallback glyphs, before raster clipping.
        if style.shadow, let ink = box { box = ink.union(ink.offsetBy(dx: 0, dy: -3).insetBy(dx: -14, dy: -14)) }
        return Plan(lines: lines, positions: positions, textRect: textRect, bounds: box)
    }
    static func attributes(title: Title, style: TextStyle, includeStroke: Bool = true) -> [NSAttributedString.Key: Any] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName(for: title) as CFString, title.fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(title.colorHex, alpha: 1, space: space)
        ]
        if includeStroke && style.strokeWidth > 0 {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color(style.strokeHex, alpha: 1, space: space)
            // Core Text's negative percentage means fill AND outline.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -100 * style.strokeWidth / title.fontSize
        }
        return attributes
    }
    static func layout(title: Title, width: CGFloat) -> [Line] {
        let style = self.style(for: title)
        let string = NSAttributedString(string: title.text, attributes: attributes(title: title, style: style))
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let fillTypesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: title.text, attributes: attributes(title: title, style: style, includeStroke: false)))
        var start = 0
        var lines: [Line] = []
        while start < string.length {
            let source = title.text as NSString
            let suggested = CTTypesetterSuggestLineBreak(typesetter, start, max(1, width))
            let candidate = NSRange(location: start, length: min(max(1, suggested), string.length - start))
            // UTF-16 counts are not character counts. Never bisect a surrogate, ZWJ emoji or combining sequence.
            let composed = source.rangeOfComposedCharacterSequences(for: candidate)
            var end = min(string.length, composed.location + composed.length)
            let opening = Set("（［｛「『【〈《“‘(")
            let closing = Set("、。，．！？：；）］｝」』】〉》”’!?.,:;)")
            // Core Text supplies word boundaries. Back off a cluster for Japanese prohibited boundaries.
            while end < string.length, end > start {
                let previous = source.rangeOfComposedCharacterSequence(at: end - 1)
                let next = source.rangeOfComposedCharacterSequence(at: end)
                let a = source.substring(with: previous), b = source.substring(with: next)
                if a.contains("\n") || a.contains("\r") { break }
                guard a.first.map({ opening.contains($0) }) == true || b.first.map({ closing.contains($0) }) == true,
                      previous.location > start else { break }
                end = previous.location
            }
            let range = CFRange(location: start, length: end - start)
            let line = CTTypesetterCreateLine(typesetter, range)
            lines.append(Line(line: line, fillLine: CTTypesetterCreateLine(fillTypesetter, range), range: range, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
            start += range.length
        }
        return lines
    }
    static func image(title: Title, size: CGSize, style: TextStyle) throws -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaEngineError.failed("스타일 제목 버퍼를 만들 수 없습니다.")
        }
        let plan = plan(title: title, size: size, style: style)
        let textRect = plan.textRect
        if style.backgroundOpacity > 0 {
            let box = textRect.insetBy(dx: -style.padding, dy: -style.padding)
            context.setFillColor(color(style.backgroundHex, alpha: style.backgroundOpacity, space: space))
            context.addPath(CGPath(roundedRect: box, cornerWidth: min(16, style.padding), cornerHeight: min(16, style.padding), transform: nil))
            context.fillPath()
        }
        context.textMatrix = .identity
        if style.shadow { context.setShadow(offset: CGSize(width: 0, height: -3), blur: 7, color: CGColor(gray: 0, alpha: 0.9)) }
        for (index, entry) in plan.lines.enumerated() {
            let x = plan.positions[index].x, y = plan.positions[index].y
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(entry.line, context)
            if style.strokeWidth > 0 {
                // Fill again above the centered stroke so a thick outline does not hollow out Korean glyphs.
                context.saveGState()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(entry.fillLine, context)
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { throw MediaEngineError.failed("스타일 제목 이미지를 만들 수 없습니다.") }
        return CIImage(cgImage: image)
    }
    private static func color(_ hex: String, alpha: Double, space: CGColorSpace) -> CGColor {
        let rgb = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return CGColor(colorSpace: space, components: [CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255, CGFloat(rgb & 255) / 255, alpha])!
    }
}

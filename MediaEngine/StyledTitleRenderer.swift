import Foundation
import CoreGraphics
import CoreImage
import CoreText

public struct TitleLayoutInfo: Sendable {
    public let totalLines: Int
    public let visibleLines: Int
    public var wasTruncated: Bool { visibleLines < totalLines }
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
        let style = title.style ?? TextStyle()
        let lines = StyledTitleRasterizer.layout(title: title, width: canvasWidth * 0.88 - style.padding * 2)
        let limit = style.maxLines > 0 ? min(style.maxLines, lines.count) : lines.count
        return TitleLayoutInfo(totalLines: lines.count, visibleLines: limit)
    }
}

/// Title.x anchors the left edge, center, or right edge according to alignment; Title.y centers the block.
/// Overflow after maxLines is shown with a visible ellipsis, never silently discarded.
enum StyledTitleRasterizer {
    struct Line { let line: CTLine; let fillLine: CTLine; let range: CFRange; let width: CGFloat }
    static func attributes(title: Title, style: TextStyle, includeStroke: Bool = true) -> [NSAttributedString.Key: Any] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(title.fontName as CFString, title.fontSize, nil),
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
        let style = title.style ?? TextStyle()
        let string = NSAttributedString(string: title.text, attributes: attributes(title: title, style: style))
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let fillTypesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: title.text, attributes: attributes(title: title, style: style, includeStroke: false)))
        var start = 0
        var lines: [Line] = []
        while start < string.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, max(1, width)))
            let range = CFRange(location: start, length: min(count, string.length - start))
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
        let width = max(1, size.width * 0.88 - style.padding * 2)
        var lines = layout(title: title, width: width)
        let truncated = style.maxLines > 0 && lines.count > style.maxLines
        if truncated {
            lines = Array(lines.prefix(style.maxLines))
            let last = lines.removeLast()
            let remaining = (title.text as NSString).substring(with: NSRange(location: last.range.location, length: last.range.length)).trimmingCharacters(in: .newlines)
            let attrs = attributes(title: title, style: style)
            let full = CTLineCreateWithAttributedString(NSAttributedString(string: remaining + "…", attributes: attrs))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            let line = CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? token
            let fillAttrs = attributes(title: title, style: style, includeStroke: false)
            let fillFull = CTLineCreateWithAttributedString(NSAttributedString(string: remaining + "…", attributes: fillAttrs))
            let fillToken = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: fillAttrs))
            let fillLine = CTLineCreateTruncatedLine(fillFull, Double(width), .end, fillToken) ?? fillToken
            lines.append(Line(line: line, fillLine: fillLine, range: last.range, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
        }
        let font = CTFontCreateWithName(title.fontName as CFString, title.fontSize, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        let height = CGFloat(lines.count) * lineHeight + CGFloat(max(0, lines.count - 1)) * style.lineSpacing
        let widest = min(width, lines.map(\.width).max() ?? 0)
        let originX: CGFloat
        switch style.alignment {
        case .left: originX = size.width * title.x
        case .center: originX = size.width * title.x - widest / 2
        case .right: originX = size.width * title.x - widest
        }
        let textRect = CGRect(x: originX, y: size.height * title.y - height / 2, width: widest, height: height)
        if style.backgroundOpacity > 0 {
            let box = textRect.insetBy(dx: -style.padding, dy: -style.padding)
            context.setFillColor(color(style.backgroundHex, alpha: style.backgroundOpacity, space: space))
            context.addPath(CGPath(roundedRect: box, cornerWidth: min(16, style.padding), cornerHeight: min(16, style.padding), transform: nil))
            context.fillPath()
        }
        context.textMatrix = .identity
        if style.shadow { context.setShadow(offset: CGSize(width: 0, height: -3), blur: 7, color: CGColor(gray: 0, alpha: 0.9)) }
        for (index, entry) in lines.enumerated() {
            let x: CGFloat
            switch style.alignment {
            case .left: x = textRect.minX
            case .center: x = textRect.midX - entry.width / 2
            case .right: x = textRect.maxX - entry.width
            }
            let y = textRect.maxY - ascent - CGFloat(index) * (lineHeight + style.lineSpacing)
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

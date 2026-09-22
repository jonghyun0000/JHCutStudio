import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

// Asset ingestion conversion, not a relaxed importer: only reviewed CC0 pack files are
// converted to explicit 8-bit sRGB. The original file hash remains in sourceSHA256.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Library", isDirectory: true)
let manifest = root.appendingPathComponent("manifest.json")
var assets = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [[String: Any]]
var count = 0
for index in assets.indices {
    guard (assets[index]["id"] as? String)?.hasPrefix("expansion-") == true,
          assets[index]["category"] as? String != "music",
          let relative = assets[index]["relativePath"] as? String else { continue }
    let url = root.appendingPathComponent(relative)
    guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
          let image = CGImageSourceCreateImageAtIndex(source,0,nil),
          let color = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                                  space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot decode \(relative)") }
    context.interpolationQuality = .none
    context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    guard let converted = context.makeImage() else { fatalError("Cannot normalize \(relative)") }
    let data = NSMutableData()
    guard let target = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { fatalError("Cannot encode \(relative)") }
    CGImageDestinationAddImage(target,converted,[kCGImagePropertyProfileName:"sRGB IEC61966-2.1"] as CFDictionary)
    guard CGImageDestinationFinalize(target) else { fatalError("PNG encode failed") }
    try (data as Data).write(to:url)
    assets[index]["sha256"] = SHA256.hash(data:data as Data).map { String(format:"%02x",$0) }.joined()
    assets[index]["fileBytes"] = data.length
    assets[index]["processing"] = "Explicit 8-bit sRGB RGBA conversion at original dimensions; no resizing."
    var tags = assets[index]["tags"] as? [String] ?? []
    if !tags.contains("8비트 sRGB") { tags.append("8비트 sRGB") }
    assets[index]["tags"] = tags
    count += 1
}
try JSONSerialization.data(withJSONObject:assets,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:manifest)
print("Normalized \(count) images to explicit 8-bit sRGB, with source hashes retained")

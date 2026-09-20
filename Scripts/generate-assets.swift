import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main
struct GenerateAssets {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let width = 1080, height = 1920
    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
    }
    static func path(_ points: [CGPoint], closed: Bool = false) -> CGPath {
        let path = CGMutablePath(); if let first = points.first { path.move(to: first) }; for point in points.dropFirst() { path.addLine(to: point) }; if closed { path.closeSubpath() }; return path
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let library = root.appendingPathComponent("Resources/Library", isDirectory: true)
        let cache = root.appendingPathComponent("Build/asset-collection", isDirectory: true)
        var assets: [[String: Any]] = []
        for file in ["downloaded-assets.json", "original-audio.json"] {
            assets += try JSONSerialization.jsonObject(with: Data(contentsOf: cache.appendingPathComponent(file))) as! [[String: Any]]
        }
        func graphic(_ id: String, _ name: String, _ category: String, _ tags: [String], draw: (CGContext) -> Void) throws {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
            draw(context)
            let image = context.makeImage()!
            let relative = "Graphics/\(id).png", output = library.appendingPathComponent(relative)
            let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw AssetLibraryError.invalid("PNG 생성 실패: \(name)") }
            let data = try Data(contentsOf: output)
            assets.append(["id": "original-" + id, "name": name, "category": category, "relativePath": relative, "author": "JH CUT Studio · 로컬 절차 생성", "sourceURL": "local:Scripts/generate-assets.swift", "license": "CC0-1.0", "licenseURL": "https://creativecommons.org/publicdomain/zero/1.0/", "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "tags": tags + ["직접 제작", "PNG"], "origin": "original", "fileBytes": data.count, "width": width, "height": height])
        }
        let overlayNames = ["오른쪽 포커스 화살표", "부드러운 곡선 화살표", "중요 지점 원형 강조", "형광 브러시 밑줄", "네 모서리 프레임", "민트 캡슐 배지", "다크 하단 자막 바", "따뜻한 리본 배너", "열두 갈래 강조 배지", "작은 별빛 세트", "부드러운 말풍선", "물방울 포인트 장식", "둥근 테두리 프레임", "양쪽 괄호 강조", "가는 구분선", "반투명 테이프"]
        for i in 0..<16 {
            try graphic(String(format: "overlay-%02d", i + 1), overlayNames[i], "overlay", ["장식", "투명 배경", "강조"]) { c in
                c.setLineCap(.round); c.setLineJoin(.round)
                let mint = color(0x5FE1CB), warm = color(0xFFBC7A), cream = color(0xFFF5D8), dark = color(0x16202E, 0.91)
                c.setStrokeColor(mint); c.setFillColor(mint); c.setLineWidth(18)
                switch i {
                case 0:
                    c.addPath(path([CGPoint(x: 280, y: 960), CGPoint(x: 800, y: 960)])); c.strokePath()
                    c.addPath(path([CGPoint(x: 645, y: 1110), CGPoint(x: 800, y: 960), CGPoint(x: 645, y: 810)])); c.strokePath()
                case 1:
                    let p = CGMutablePath(); p.move(to: CGPoint(x: 270, y: 780)); p.addCurve(to: CGPoint(x: 800, y: 1110), control1: CGPoint(x: 260, y: 1090), control2: CGPoint(x: 610, y: 1120)); c.addPath(p); c.strokePath()
                    c.addPath(path([CGPoint(x: 660, y: 1220), CGPoint(x: 810, y: 1110), CGPoint(x: 680, y: 995)])); c.strokePath()
                case 2:
                    c.setStrokeColor(warm); c.setLineWidth(16); c.strokeEllipse(in: CGRect(x: 230, y: 650, width: 620, height: 620)); c.setLineWidth(3); c.strokeEllipse(in: CGRect(x: 207, y: 627, width: 666, height: 666))
                case 3:
                    c.setFillColor(color(0xFCEB6B, 0.8)); c.addPath(path([CGPoint(x: 140, y: 950), CGPoint(x: 920, y: 980), CGPoint(x: 950, y: 1040), CGPoint(x: 165, y: 1015)], closed: true)); c.fillPath()
                case 4:
                    for (x, y, sx, sy) in [(100.0, 130.0, 1.0, 1.0), (980, 130, -1, 1), (100, 1790, 1, -1), (980, 1790, -1, -1)] { c.addPath(path([CGPoint(x: x, y: y + sy * 130), CGPoint(x: x, y: y), CGPoint(x: x + sx * 130, y: y)])); c.strokePath() }
                case 5: c.addPath(CGPath(roundedRect: CGRect(x: 180, y: 850, width: 720, height: 220), cornerWidth: 110, cornerHeight: 110, transform: nil)); c.fillPath()
                case 6:
                    c.setFillColor(dark); c.addPath(CGPath(roundedRect: CGRect(x: 65, y: 200, width: 950, height: 190), cornerWidth: 32, cornerHeight: 32, transform: nil)); c.fillPath(); c.setFillColor(mint); c.fill(CGRect(x: 98, y: 240, width: 8, height: 110))
                case 7:
                    c.setFillColor(warm); c.addPath(path([CGPoint(x: 80, y: 1080), CGPoint(x: 1000, y: 1080), CGPoint(x: 940, y: 960), CGPoint(x: 1000, y: 840), CGPoint(x: 80, y: 840), CGPoint(x: 140, y: 960)], closed: true)); c.fillPath()
                case 8:
                    var points: [CGPoint] = []; for n in 0..<24 { let angle = CGFloat(n) * .pi / 12; let r: CGFloat = n % 2 == 0 ? 300 : 258; points.append(CGPoint(x: 540 + sin(angle) * r, y: 960 + cos(angle) * r)) }; c.setFillColor(warm); c.addPath(path(points, closed: true)); c.fillPath(); c.setStrokeColor(cream); c.setLineWidth(3); c.strokeEllipse(in: CGRect(x: 300, y: 720, width: 480, height: 480))
                case 9:
                    for (x,y,r) in [(380.0,1040.0,110.0),(690,850,70),(755,1150,40)] { c.setFillColor(cream); c.addPath(path([CGPoint(x: x, y: y+r),CGPoint(x:x+r * 0.25,y:y+r * 0.25),CGPoint(x:x+r,y:y),CGPoint(x:x+r * 0.25,y:y-r * 0.25),CGPoint(x:x,y:y-r),CGPoint(x:x-r * 0.25,y:y-r * 0.25),CGPoint(x:x-r,y:y),CGPoint(x:x-r * 0.25,y:y+r * 0.25)],closed:true));c.fillPath() }
                case 10:
                    c.setFillColor(color(0xFFF5D8,0.96)); c.addPath(CGPath(roundedRect: CGRect(x: 120, y: 760, width: 840, height: 420), cornerWidth: 85, cornerHeight: 85, transform: nil)); c.fillPath();c.addPath(path([CGPoint(x:240,y:780),CGPoint(x:230,y:650),CGPoint(x:410,y:790)],closed:true));c.fillPath()
                case 11:
                    for n in 0..<8 { let angle=CGFloat(n) * .pi / 4; let r=CGFloat(30+n*5);c.setFillColor(n%2==0 ? mint : warm);c.fillEllipse(in:CGRect(x:540+sin(angle)*230-r/2,y:960+cos(angle)*230-r/2,width:r,height:r)) }
                case 12: c.setStrokeColor(cream);c.setLineWidth(10);c.addPath(CGPath(roundedRect:CGRect(x:80,y:130,width:920,height:1660),cornerWidth:75,cornerHeight:75,transform:nil));c.strokePath()
                case 13:
                    c.setStrokeColor(warm);c.addPath(path([CGPoint(x:300,y:1220),CGPoint(x:230,y:1220),CGPoint(x:230,y:700),CGPoint(x:300,y:700)]));c.strokePath();c.addPath(path([CGPoint(x:780,y:1220),CGPoint(x:850,y:1220),CGPoint(x:850,y:700),CGPoint(x:780,y:700)]));c.strokePath()
                case 14: c.setStrokeColor(cream);c.setLineWidth(4);c.move(to:CGPoint(x:160,y:960));c.addLine(to:CGPoint(x:920,y:960));c.strokePath();c.setFillColor(mint);c.fillEllipse(in:CGRect(x:528,y:948,width:24,height:24))
                default:
                    c.translateBy(x:540,y:960);c.rotate(by:-.pi/36);c.setFillColor(color(0xF6DEC0,0.74));c.addPath(path([CGPoint(x:-380,y:-80),CGPoint(x:-350,y:-55),CGPoint(x:-380,y:-25),CGPoint(x:-350,y:0),CGPoint(x:-380,y:30),CGPoint(x:-355,y:60),CGPoint(x:-380,y:80),CGPoint(x:380,y:80),CGPoint(x:355,y:55),CGPoint(x:380,y:20),CGPoint(x:355,y:0),CGPoint(x:380,y:-35),CGPoint(x:350,y:-60),CGPoint(x:380,y:-80)],closed:true));c.fillPath()
                }
            }
        }
        let backgrounds: [(String, UInt32, UInt32)] = [("깊은 네이비",0x102031,0x223F52),("따뜻한 종이",0xF6E9D5,0xDFCEB3),("부드러운 민트",0xD8EFE6,0xA8D4C7),("보랏빛 저녁",0x302342,0x665577),("차분한 로즈",0xEEDBD8,0xBD9B9C),("노을의 온도",0xF7C595,0xCF817B),("맑은 블루",0xD6E5F0,0x99B6CF),("차콜 스튜디오",0x1D2026,0x3B424B)]
        for (i, item) in backgrounds.enumerated() {
            try graphic(String(format:"background-%02d",i+1),item.0,"background",["배경","그라데이션","세로"]) { c in
                let gradient=CGGradient(colorsSpace:space,colors:[color(item.1),color(item.2)] as CFArray,locations:nil)!
                c.drawLinearGradient(gradient,start:CGPoint(x:0,y:1920),end:CGPoint(x:1080,y:0),options:[])
                c.setFillColor(color(0xFFFFFF,0.04));c.fillEllipse(in:CGRect(x:430,y:1070,width:1050,height:1050));c.setFillColor(color(0xFFFFFF,0.035));c.fillEllipse(in:CGRect(x:-410,y:-510,width:1220,height:1220))
            }
        }
        let textureNames=["밝은 미세 입자","어두운 미세 입자","정밀 얇은 격자","대각선 리듬","부드러운 비네트","필름 모서리","하프톤 점 무늬","따뜻한 빛 번짐"]
        for i in 0..<8 {
            try graphic(String(format:"texture-%02d",i+1),textureNames[i],"texture",["질감","투명 배경","오버레이"]) { c in
                switch i {
                case 0,1:
                    var state: UInt64=1234+UInt64(i)
                    for _ in 0..<100_000 {state=state &* 6364136223846793005 &+ 1;let x=CGFloat(state%1080);state=state &* 6364136223846793005 &+ 1;let y=CGFloat(state%1920);c.setFillColor(color(i==0 ? 0xFFFFFF : 0x000000,0.06));c.fill(CGRect(x:x,y:y,width:1.5,height:1.5))}
                case 2:
                    c.setStrokeColor(color(0xB6DACA,0.24));c.setLineWidth(1);for x in stride(from:0,through:1080,by:60){c.move(to:CGPoint(x:x,y:0));c.addLine(to:CGPoint(x:x,y:1920))};for y in stride(from:0,through:1920,by:60){c.move(to:CGPoint(x:0,y:y));c.addLine(to:CGPoint(x:1080,y:y))};c.strokePath()
                case 3:
                    c.setStrokeColor(color(0xFFFFFF,0.12));c.setLineWidth(2);for x in stride(from:-1920,through:1080,by:50){c.move(to:CGPoint(x:x,y:0));c.addLine(to:CGPoint(x:x+1920,y:1920))};c.strokePath()
                case 4:
                    let g=CGGradient(colorsSpace:space,colors:[color(0x000000,0),color(0x000000,0.55)] as CFArray,locations:[0,1])!;c.drawRadialGradient(g,startCenter:CGPoint(x:540,y:960),startRadius:330,endCenter:CGPoint(x:540,y:960),endRadius:1100,options:.drawsAfterEndLocation)
                case 5:
                    c.setFillColor(color(0x0C1017,0.88));c.fill(CGRect(x:0,y:0,width:56,height:1920));c.fill(CGRect(x:1024,y:0,width:56,height:1920));c.setBlendMode(.clear);for y in stride(from:25,through:1880,by:80){c.addPath(CGPath(roundedRect:CGRect(x:15,y:y,width:26,height:45),cornerWidth:7,cornerHeight:7,transform:nil));c.fillPath();c.addPath(CGPath(roundedRect:CGRect(x:1039,y:y,width:26,height:45),cornerWidth:7,cornerHeight:7,transform:nil));c.fillPath()}
                case 6:
                    c.setFillColor(color(0xFFFFFF,0.15));for y in stride(from:0,through:1920,by:32){for x in stride(from:0,through:1080,by:32){c.fillEllipse(in:CGRect(x:x,y:y,width:4,height:4))}}
                default:
                    let g=CGGradient(colorsSpace:space,colors:[color(0xF7A170,0.55),color(0xF7A170,0)] as CFArray,locations:[0,1])!;c.drawRadialGradient(g,startCenter:CGPoint(x:-100,y:1400),startRadius:0,endCenter:CGPoint(x:-100,y:1400),endRadius:1250,options:[])
                }
            }
        }
        var evidence: [[String: Any]] = []
        for index in assets.indices {
            let location=library.appendingPathComponent(assets[index]["relativePath"] as! String)
            let category=assets[index]["category"] as! String
            if category=="sfx" || category=="music" {
                let asset=AVURLAsset(url:location), tracks=try await asset.loadTracks(withMediaType:.audio)
                guard let track=tracks.first else {throw AssetLibraryError.invalid("오디오 트랙 없음: \(location.lastPathComponent)")}
                let reader=try AVAssetReader(asset:asset)
                let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false])
                reader.add(output);guard reader.startReading() else {throw reader.error ?? AssetLibraryError.invalid("오디오 디코딩 실패")}
                var frames=0
                while let sample=output.copyNextSampleBuffer(){frames+=CMSampleBufferGetNumSamples(sample)}
                guard reader.status == .completed, frames>0 else {throw reader.error ?? AssetLibraryError.invalid("오디오 전체 디코딩 실패")}
                let duration=try await asset.load(.duration).seconds;assets[index]["duration"]=duration
                evidence.append(["id":assets[index]["id"]!,"decoded":true,"sampleFrames":frames,"duration":duration])
            } else {
                guard let source=CGImageSourceCreateWithURL(location as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw AssetLibraryError.invalid("PNG 디코딩 실패")}
                evidence.append(["id":assets[index]["id"]!,"decoded":true,"width":image.width,"height":image.height])
            }
        }
        let encoded=try JSONSerialization.data(withJSONObject:assets,options:[.prettyPrinted,.sortedKeys])
        try encoded.write(to:library.appendingPathComponent("manifest.json"),options:.atomic)
        let catalog=try AssetLibrary(rootURL:library);try catalog.verify()
        let bytes=assets.compactMap{$0["fileBytes"] as? Int}.reduce(0,+)
        let report:[String:Any]=["passed":true,"date":ISO8601DateFormatter().string(from:Date()),"count":assets.count,"mediaBytes":bytes,"nativeDecoder":"AVAssetReader PCM full decode / ImageIO PNG decode","sha256":"All assets verified by AssetLibrary.verify() using CryptoKit","assets":evidence]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:library.appendingPathComponent("validation.json"),options:.atomic)
        print("Asset library READY: \(catalog.assets.count) assets, \(bytes) media bytes, every audio sample/PNG decoded, SHA256 verified")
    }
}

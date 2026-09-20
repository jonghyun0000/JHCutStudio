import Foundation
import AVFoundation
import AppKit
import CoreText
import Darwin
import JHCutCore

@main
struct ValidationMain {
    static func main() async {
        do {
            if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--upgrade" {
                let directory = URL(fileURLWithPath: CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "Artifacts/Upgrade", isDirectory: true).standardizedFileURL
                try await UpgradeValidation.run(in: directory)
                return
            }
            if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--inspect" {
                let movie = try await MediaInspection.decode(URL(fileURLWithPath: CommandLine.arguments[2]))
                var values: [String: Any] = ["file": CommandLine.arguments[2], "width": movie.width, "height": movie.height, "videoCodec": movie.videoCodec, "audioCodec": movie.audioCodec, "fps": movie.nominalFrameRate, "monotonic": movie.monotonic, "metrics": movie.metrics]
                if let frame = movie.images[30] { values["frame30OCR"] = try MediaInspection.recognizeText(frame); values["frame30CyanPixels"] = try MediaInspection.countCyanPixels(frame) }
                if CommandLine.arguments.count >= 4 {
                    let proof = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
                    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
                    for (frame, image) in movie.images { try Fixtures.savePNG(image, to: proof.appendingPathComponent("decoded-frame-\(frame).png")) }
                    values["proofDirectory"] = proof.path
                }
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/G0", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await G0Validation.run(in: directory)
        } catch {
            fputs("Validation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

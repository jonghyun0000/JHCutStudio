#if LIBRARY_EXPANSION_PROBE
import Foundation
import AppKit
import AVFoundation
import ImageIO
import JHCutCore

@main struct LibraryExpansionProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Playback-Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try AssetLibrary(rootURL: URL(fileURLWithPath: "Resources/Library", isDirectory: true))
        try library.verify()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name,"passed": passed,"detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
        }
        check("All bundled file hashes", true, "\(library.assets.count) files")
        let additions = library.assets.filter { $0.id.hasPrefix("expansion-") }
        let songs = additions.filter { $0.category == .music }
        check("Eleven additional original 2–3 minute tracks", songs.count == 11 && songs.allSatisfy { (120...180).contains($0.duration ?? 0) })
        for song in songs {
            let file = try AVAudioFile(forReading: library.url(for: song))
            let format = file.processingFormat
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            var frames: Int64 = 0, peak: Float = 0
            while file.framePosition < file.length {
                try file.read(into: pcm)
                if pcm.frameLength == 0 { break }
                if let channels = pcm.floatChannelData {
                    for channel in 0..<Int(format.channelCount) {
                        for sample in 0..<Int(pcm.frameLength) { peak = max(peak, abs(channels[channel][sample])) }
                    }
                }
                frames += Int64(pcm.frameLength)
            }
            let duration = Double(frames) / format.sampleRate
            check("Decode complete song: \(song.name)", (120...180).contains(duration) && abs(duration - (song.duration ?? 0)) < 0.15 && peak > 0.01,
                  String(format: "%.3fs, %lld frames, peak %.4f", duration,frames,peak))
        }
        let graphics = additions.filter { $0.category != .music }
        for asset in graphics {
            guard let source = CGImageSourceCreateWithURL(library.url(for: asset) as CFURL,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
                  image.width == asset.width, image.height == asset.height else { throw ProjectError("Image decode failed: \(asset.id)") }
            let inspected = try await MediaImporter.inspect(url: library.url(for: asset))
            guard inspected.supported else { throw ProjectError("Importer rejected \(asset.id): \(inspected.issue ?? "unknown")") }
        }
        check("All added PNG files decode at declared dimensions", true, "\(graphics.count) images")
        let source = root.appendingPathComponent("playback-source.mp4")
        let media = try await MediaImporter.inspect(url: source)
        var project = Project(name: "Library insertion and output")
        project.sequence.width = 640; project.sequence.height = 360
        project.assets = [media]; project.sequence.tracks[0].clips = [Clip(assetID: media.id, duration: MediaTime(seconds: 6))]
        let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("library-probe-recovery")))
        model.bundledLibrary = library
        func settle() async throws {
            for _ in 0..<1200 {
                if !model.isImporting && !model.isBuilding { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ProjectError("Insertion/build timed out")
        }
        for song in songs {
            model.history = EditorHistory(project: project); model.playhead = 0
            model.insertLibraryAsset(song)
            try await settle()
            let clip = model.project.sequence.tracks.first(where: { $0.kind == .audio })?.clips.first
            let added = model.project.assets.first(where: { $0.id == clip?.assetID })
            check("Timeline insertion: \(song.name)", clip?.duration == MediaTime(seconds: 6) && clip?.volume == 0.25 && added?.provenance?.sha256 == song.sha256 && model.plan != nil)
        }
        let sticker = graphics.first { $0.tags.contains("픽셀 아트") }!
        model.insertLibraryAsset(sticker); try await settle()
        check("Pixel sticker has smaller default scale", model.selected?.1.transform.scale == 0.2, model.error ?? "")
        model.undo(); try await settle()
        let texture = graphics.first { $0.category == .texture }!
        model.insertLibraryAsset(texture); try await settle()
        check("Texture fills canvas by default", model.selected?.1.transform.fill == true)
        model.undo(); try await settle()
        let particle = graphics.first { $0.tags.contains("별") }!
        model.playhead = 1; model.insertLibraryAsset(particle); try await settle()
        let output = root.appendingPathComponent("music-and-overlay-\(UUID().uuidString.prefix(8)).mp4")
        guard let plan = model.plan else { throw ProjectError("Missing export plan") }
        try await ExportJob().export(plan: plan, to: output) { _ in }
        let exported = AVURLAsset(url: output)
        let duration = try await exported.load(.duration).seconds
        let audio = try await exported.loadTracks(withMediaType: .audio)
        let video = try await exported.loadTracks(withMediaType: .video)
        check("Music + transparent overlay exports to MP4", abs(duration-6)<0.04 && audio.count == 1 && video.count == 1, output.path)
        let reader = try AVAssetReader(asset: exported)
        guard let audioTrack = audio.first else { throw ProjectError("Exported soundtrack missing") }
        let stream = AVAssetReaderTrackOutput(track: audioTrack,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        reader.add(stream); guard reader.startReading() else { throw ProjectError("No exported audio decoder") }
        var samples = 0; var maximum: Float = 0
        while let buffer = stream.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let size = CMBlockBufferGetDataLength(block); var values = [Float](repeating: 0,count:size/4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:size,destination:$0.baseAddress!) }
            samples += values.count; maximum = max(maximum,values.map(abs).max() ?? 0)
        }
        check("Exported soundtrack decodes with audible signal", reader.status == .completed && samples > 48000 && maximum > 0.001,
              "\(samples) samples, peak \(maximum)")
        try ProjectStore.save(model.project,to:root.appendingPathComponent("library-demo.jhcut"))
        try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("library-checks.json"))
        if checks.contains(where:{ ($0["passed"] as? Bool) != true }) { exit(1) }
    }
}
#endif

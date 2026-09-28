import Foundation
import AVFoundation

public struct MixMeasurement: Codable, Sendable {
    public var integratedLUFS: Double?
    public var samplePeakDBFS: Double?
    public var frames: Int64
}
/// Stereo 48kHz K weighting and 400ms/75%-overlap gating, BS.1770 Annex 1.
/// This is not an EBU-certified meter. https://tech.ebu.ch/docs/tech/tech3343.pdf
public struct LoudnessMeter {
    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0*x+b1*x1+b2*x2-a1*y1-a2*y2
            x2=x1; x1=x; y2=y1; y1=y; return y
        }
    }
    private var shelf = (0..<2).map { _ in Biquad(b0: 1.53512485958697,b1: -2.69169618940638,b2: 1.19839281085285,a1: -1.69065929318241,a2: 0.73248077421585) }
    private var highpass = (0..<2).map { _ in Biquad(b0: 1,b1: -2,b2: 1,a1: -1.99004745483398,a2: 0.99007225036621) }
    private var ring = [Double](repeating: 0, count: 19200), cursor = 0, sum = 0.0, blocks: [Double] = [], peak = 0.0
    private var frames: Int64 = 0
    public init() {}
    public mutating func consume(stereo: [Float]) {
        for i in stride(from: 0, to: stereo.count - 1, by: 2) {
            var energy = 0.0
            for c in 0..<2 {
                let sample = Double(stereo[i+c]); peak = max(peak,abs(sample))
                let weighted = highpass[c].run(shelf[c].run(sample)); energy += weighted*weighted
            }
            sum += energy-ring[cursor]; ring[cursor]=energy; cursor=(cursor+1)%19200; frames += 1
            if frames >= 19200 && (frames-19200)%4800 == 0 { blocks.append(max(0,sum/19200)) }
        }
    }
    public var measurement: MixMeasurement {
        let absolute = blocks.filter { $0 > 0 && -0.691+10*log10($0) > -70 }
        var lufs: Double?
        if !absolute.isEmpty {
            let mean = absolute.reduce(0,+)/Double(absolute.count)
            let gated = absolute.filter { $0 > mean/10 }
            if !gated.isEmpty { lufs = -0.691+10*log10(gated.reduce(0,+)/Double(gated.count)) }
        }
        return MixMeasurement(integratedLUFS: lufs, samplePeakDBFS: peak > 0 ? 20*log10(peak) : nil, frames: frames)
    }
}
public struct MasteringResult: Sendable {
    public let url: URL
    public let before: MixMeasurement
    public let after: MixMeasurement
    /// 4x sample-rate-converted estimate; not a certified dBTP measurement.
    public let oversampledPeakDBFS: Double?
}
public enum MixMastering {
    public static func render(plan: RenderPlan, to destination: URL, targetLUFS: Double = -16, enhanceVoice: Bool = false) async throws -> MasteringResult {
        guard (-30 ... -9).contains(targetLUFS), !FileManager.default.fileExists(atPath: destination.path) else { throw ProjectError("목표 음량 또는 새 출력 경로를 확인하세요.") }
        let worker = Task.detached(priority: .userInitiated) { try bounce(plan: plan, destination: destination, target: targetLUFS, enhanceVoice: enhanceVoice) }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        do {
            var peak = 0.0
            _ = try await SourcePCM.read(url: destination, sourceStart: .zero, duration: nil, sampleRate: 192000, channels: 2) { chunk in
                for value in chunk.values { peak = max(peak,abs(Double(value))) }
            }
            return MasteringResult(url: destination, before: result.0, after: result.1, oversampledPeakDBFS: peak > 0 ? 20*log10(peak) : nil)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private static func bounce(plan: RenderPlan, destination: URL, target: Double, enhanceVoice: Bool) throws -> (MixMeasurement, MixMeasurement) {
        let tracks = plan.composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProjectError("믹싱할 소리가 없습니다.") }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        guard free > plan.duration.seconds*48000*2*4*2 + 64_000_000 else { throw ProjectError("믹싱 사본을 저장할 공간이 부족합니다.") }
        let raw = directory.appendingPathComponent(".mix-\(UUID().uuidString).caf"), staged = directory.appendingPathComponent(".master-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: staged) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var rawFile: AVAudioFile? = try AVAudioFile(forWriting: raw, settings: format.settings)
        let reader = try AVAssetReader(asset: plan.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: plan.duration)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:48000,AVNumberOfChannelsKey:2, AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
        output.audioMix = plan.audioMix; output.audioTimePitchAlgorithm = .spectral
        guard reader.canAdd(output) else { throw ProjectError("최종 오디오 믹스를 읽을 수 없습니다.") }; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProjectError("오디오 믹스 시작 실패") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var before = LoudnessMeter(), written: Int64 = 0
        func write(_ samples: [Float]) throws {
            guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count/2)) else { return }
            buffer.frameLength = buffer.frameCapacity
            for c in 0..<2 { for frame in 0..<samples.count/2 { buffer.floatChannelData![c][frame] = samples[frame*2+c] } }
            try rawFile!.write(from: buffer); before.consume(stereo: samples); written += Int64(samples.count/2)
        }
        let expectedFrames = Int64((plan.duration.seconds*48000).rounded())
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { throw ProjectError("PCM 버퍼가 없습니다.") }
                let byteCount = CMBlockBufferGetDataLength(block)
                var values = [Float](repeating: 0, count: byteCount/4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }
                guard status == kCMBlockBufferNoErr else { throw ProjectError("PCM 복사에 실패했습니다.") }
                let pts = max(0,Int64((CMSampleBufferGetPresentationTimeStamp(sample).seconds*48000).rounded()))
                while written < min(pts,expectedFrames) { try write([Float](repeating:0,count:Int(min(8192,min(pts,expectedFrames)-written))*2)) }
                let skip = min(values.count/2,Int(max(0,written-pts)))
                let frames = min(values.count/2-skip,Int(max(0,expectedFrames-written)))
                if frames > 0 { try write(Array(values[(skip*2)..<((skip+frames)*2)])) }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? ProjectError("최종 믹스 읽기 실패") }
        while written < expectedFrames { try Task.checkCancellation(); try write([Float](repeating:0,count:Int(min(8192,expectedFrames-written))*2)) }
        rawFile = nil
        let original = before.measurement
        let gain = pow(10,min(12,target-(original.integratedLUFS ?? target))/20)
        let input = try AVAudioFile(forReading: raw)
        var final: AVAudioFile? = try AVAudioFile(forWriting: staged, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var after = LoudnessMeter(), lastX = [Double](repeating:0,count:2), lastHP = lastX, low = lastX, detector=0.0, limiter=1.0
        let hpAlpha = exp(-2*Double.pi*80/48000), lowAlpha=exp(-2*Double.pi*1800/48000)
        let attack=exp(-1/(0.01*48000)), release=exp(-1/(0.12*48000)), ceiling=pow(10,-1.5/20)
        while input.framePosition < input.length {
            try Task.checkCancellation(); try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            var values=[Float](repeating:0,count:Int(buffer.frameLength)*2)
            for frame in 0..<Int(buffer.frameLength) {
                var samples=[Double](repeating:0,count:2)
                for c in 0..<2 {
                    var value=Double(buffer.floatChannelData![c][frame])
                    if enhanceVoice {
                        let hp=hpAlpha*(lastHP[c]+value-lastX[c]); lastX[c]=value;lastHP[c]=hp
                        low[c]=lowAlpha*low[c]+(1-lowAlpha)*hp
                        value=hp+0.18*(hp-low[c])
                    }
                    samples[c]=value
                }
                let peak=max(abs(samples[0]),abs(samples[1]))
                let smoothing = peak > detector ? attack : release
                detector=smoothing*detector+(1-smoothing)*peak
                var voiceGain=1.0
                if enhanceVoice {
                    let db=20*log10(max(1e-9,detector))
                    let compression=db > -18 ? pow(10,(-18+(db+18)/3-db)/20) : 1
                    let gate=min(1,max(0.05,detector/pow(10,-45.0/20)))
                    voiceGain=compression*gate
                }
                let requested=min(1,ceiling/max(1e-9,peak*gain*voiceGain))
                limiter=requested < limiter ? requested : release*limiter+(1-release)*requested
                for c in 0..<2 {
                    let value=Float(samples[c]*gain*voiceGain*limiter)
                    buffer.floatChannelData![c][frame]=value;values[frame*2+c]=value
                }
            }
            after.consume(stereo: values); try final!.write(from: buffer)
        }
        final=nil; try Task.checkCancellation()
        try FileManager.default.moveItem(at: staged, to: destination)
        return (original,after.measurement)
    }
}

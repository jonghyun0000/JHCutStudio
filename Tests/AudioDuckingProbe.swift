import Foundation
import JHCutCore

@main struct AudioDuckingProbe {
    static func main() async throws {
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/AudioDucking")
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let original = [(158.08,159.08),(159.08,159.48),(159.48,160.08)].map { (MediaTime(seconds:$0.0),MediaTime(seconds:$0.1)) }
        for start in [MediaTime.zero, MediaTime(seconds:145.02)] {
            var clip = Clip(start: start, duration: MediaTime(363826,2205))
            let points = try AudioAutomation.duck(clip:clip,speech:original + original,reductionDB:-12)
            check("Quantized control times are unique and strictly ordered: \(start.seconds)", zip(points,points.dropFirst()).allSatisfy{$0.time < $1.time})
            check("Exact endpoints and valid gains: \(start.seconds)", points.first?.time == .zero && points.last?.time == clip.duration && points.allSatisfy{$0.time >= .zero && $0.time <= clip.duration && $0.gain.isFinite && (0...1).contains($0.gain)})
            clip.ducking = points; var project = Project();project.sequence.tracks[3].clips=[clip]
            var accepted=true;do{try ConnectionEditing.validate(project.sequence)}catch{accepted=false}
            check("Saved automation passes existing strict validator: \(start.seconds)",accepted)
            let at=MediaTime(seconds:159.6)-start
            check("Speech attenuation retained: \(start.seconds)",abs(AudioAutomation.gain(points,at:at)-pow(10,-12.0/20))<0.00001)
        }
        let tiny=Clip(duration:MediaTime(1,44100))
        let points=try AudioAutomation.duck(clip:tiny,speech:[(.zero,tiny.duration)],reductionDB:-12)
        check("Sub-grid clip retains exact duration without out-of-range controls",points.count==2 && points.first?.time == .zero && points.last?.time == tiny.duration)
        let silent=Clip(duration:MediaTime(10,1))
        let silencePoints=try AudioAutomation.duck(clip:silent,speech:[],reductionDB:-12)
        check("No speech leaves unity gain",silencePoints.allSatisfy{$0.gain==1})
        let failures=rows.filter{$0["passed"] as? Bool != true}.count
        print("AUDIO_DUCKING_RESULT checks=\(rows.count) failures=\(failures)")
        if failures>0 {throw ProjectError("Audio ducking regression failed")}
    }
}

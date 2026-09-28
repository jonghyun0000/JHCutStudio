import Foundation

public enum AudioAutomation {
    public static func gain(_ points: [GainPoint]?, at time: MediaTime) -> Double {
        guard let points, !points.isEmpty else { return 1 }
        guard time > points[0].time else { return points[0].gain }
        var low = 0, high = points.count
        while low < high { let mid = (low + high) / 2; if points[mid].time <= time { low = mid + 1 } else { high = mid } }
        guard low < points.count else { return points.last!.gain }
        let a = points[low - 1], b = points[low]
        let f = (time - a.time).seconds / (b.time - a.time).seconds
        return a.gain + (b.gain - a.gain) * f
    }
    public static func duck(clip: Clip, speech: [(MediaTime, MediaTime)], reductionDB: Double, attack: Double = 0.15, release: Double = 0.4) throws -> [GainPoint] {
        guard reductionDB.isFinite, (-30...0).contains(reductionDB), attack.isFinite, release.isFinite, attack > 0, release > 0 else { throw ProjectError("감쇠는 -30~0dB, 반응 시간은 양수여야 합니다.") }
        let gain = pow(10, reductionDB / 20)
        let intervals = speech.filter { $0.1 > clip.start && $0.0 < clip.end }.map { (max(0, ($0.0 - clip.start).seconds), min(clip.duration.seconds, ($0.1 - clip.start).seconds)) }
        var times: Set<Double> = [0, clip.duration.seconds]
        for (begin, end) in intervals { times.formUnion([max(0, begin - attack), begin, end, min(clip.duration.seconds, end + release)]) }
        // Add intersection points between release and attack ramps, preserving the minimum envelope.
        let sorted = intervals.sorted { $0.0 < $1.0 }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.1 < b.0 && a.1 + release > b.0 - attack {
            let t = (attack * a.1 + release * b.0) / (attack + release)
            if t >= 0 && t <= clip.duration.seconds { times.insert(t) }
        }
        return times.sorted().map { t in
            let value = intervals.reduce(1.0) { current, interval in
                let (begin, end) = interval
                let envelope: Double
                if t < begin { envelope = 1 - (1 - gain) * max(0, 1 - (begin - t) / attack) }
                else if t <= end { envelope = gain }
                else { envelope = gain + (1 - gain) * min(1, (t - end) / release) }
                return min(current, envelope)
            }
            return GainPoint(time: MediaTime(seconds: t), gain: value)
        }
    }
}

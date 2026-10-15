import Foundation
import AppKit
import Darwin
@testable import JHCutCore

// Independent frozen stage-8 oracle; intentionally quadratic ONLY for short test inputs.
private enum Baseline {
    struct EditCell { var cost:Int; var s:Int; var d:Int; var i:Int }
    typealias Step = TranscriptEvaluation.Step
    static let matchThreshold = 0.5
    static func editCounts<T: Equatable>(reference: [T], hypothesis: [T]) -> EditCounts {
        typealias Cell = EditCell
        let m = hypothesis.count
        var previous = (0...m).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        var current = previous
        for (row, ref) in reference.enumerated() {
            current[0] = Cell(cost: row + 1, s: 0, d: row + 1, i: 0)
            for column in 1...max(1, m) where m > 0 {
                if hypothesis[column - 1] == ref { current[column] = previous[column - 1]; continue }
                let sub = previous[column - 1], del = previous[column], ins = current[column - 1]
                let best = min(sub.cost, del.cost, ins.cost)
                if sub.cost == best { current[column] = Cell(cost: best + 1, s: sub.s + 1, d: sub.d, i: sub.i) }
                else if del.cost == best { current[column] = Cell(cost: best + 1, s: del.s, d: del.d + 1, i: del.i) }
                else { current[column] = Cell(cost: best + 1, s: ins.s, d: ins.d, i: ins.i + 1) }
            }
            swap(&previous, &current)
        }
        let final = previous[m]
        return EditCounts(substitutions: final.s, deletions: final.d, insertions: final.i, referenceLength: reference.count)
    }

    static func similarity(_ a: String, _ b: String, language: String) -> Double {
        let x = TranscriptEvaluation.characters(a, language: language), y = TranscriptEvaluation.characters(b, language: language)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        let counts = editCounts(reference: x, hypothesis: y)
        return max(0, 1 - Double(counts.substitutions + counts.deletions + counts.insertions) / Double(max(x.count, y.count)))
    }

    static func align(reference: [String], hypothesis: [String], language: String, band: Int?) -> [Step]? {
        let n = reference.count, m = hypothesis.count
        // A pairing earns (similarity − threshold): below the threshold it costs more than
        // leaving both sides unpaired, so poor pairs are reported as missing + extra.
        let gap = 0.0
        var score = [[Double]](repeating: [Double](repeating: -.infinity, count: m + 1), count: n + 1)
        var back = [[Step?]](repeating: [Step?](repeating: nil, count: m + 1), count: n + 1)
        score[0][0] = 0
        let ratio = n > 0 ? Double(m) / Double(n) : 1
        func joined(_ list: [String], _ from: Int, _ count: Int) -> String { list[from..<(from + count)].joined(separator: " ") }
        for i in 0...n {
            for j in 0...m where score[i][j] > -.infinity {
                if let band, abs(Double(j) - Double(i) * ratio) > Double(band) { continue }
                let base = score[i][j]
                func relax(_ ni: Int, _ nj: Int, _ value: Double, _ step: Step) {
                    guard ni <= n, nj <= m, value > score[ni][nj] else { return }
                    score[ni][nj] = value; back[ni][nj] = step
                }
                if i < n { relax(i + 1, j, base - gap, .missing(i)) }
                if j < m { relax(i, j + 1, base - gap, .extra(j)) }
                for (a, b) in [(1, 1), (1, 2), (2, 1), (1, 3), (3, 1)] where i + a <= n && j + b <= m {
                    let sim = similarity(joined(reference, i, a), joined(hypothesis, j, b), language: language)
                    // Groupings must earn their place: a merge is scored like one pair plus a small
                    // penalty, so 1:1 wins when both explanations fit equally well.
                    relax(i + a, j + b, base + (sim - matchThreshold) - Double(a + b - 2) * 0.02, .match(i, a, j, b))
                }
            }
        }
        guard score[n][m] > -.infinity else { return nil }
        var steps: [Step] = [], i = n, j = m
        while i > 0 || j > 0 {
            guard let step = back[i][j] else { return nil }
            steps.append(step)
            switch step {
            case .match(let ri, _, let hj, _): i = ri; j = hj
            case .missing(let ri): i = ri
            case .extra(let hj): j = hj
            }
        }
        return steps.reversed()
    }

}

private final class ProgressEvents: @unchecked Sendable {
    private let lock=NSLock();private var events:[Double]=[]
    func append(_ x:Double) {lock.lock();events.append(x);lock.unlock()}
    var values:[Double] {lock.lock();defer {lock.unlock()};return events}
}
private final class Signal: @unchecked Sendable {
    private let lock=NSLock(); private var state=false
    func set() { lock.lock();state=true;lock.unlock() }
    var value:Bool { lock.lock();defer {lock.unlock()};return state }
}

@main struct EvaluationSafetyProbe {
    typealias E=TranscriptEvaluation
    static func fixture(_ minutes:Int,_ language:String) -> (TranscriptReference,[EvaluatedCaption]) {
        let n=minutes*15
        var units:[TranscriptReference.Unit]=[],caps:[EvaluatedCaption]=[]
        for i in 0..<n {
            let text:String,changed:String
            switch language {
            case "ko":text="오늘은 공원에서 영상 \(i) 장면을 촬영하고 친구와 산책합니다";changed=text.replacingOccurrences(of:"친구",with:"가족")
            case "ja":text="今日は公園で映像 \(i) を撮影して友達と散歩しています";changed=text.replacingOccurrences(of:"友達",with:"家族")
            default:text="today we record scene \(i) in the park and walk with friends";changed=text.replacingOccurrences(of:"friends",with:"family")
            }
            units.append(.init(text:text,start:Double(i*4),end:Double(i*4+3)))
            caps.append(.init(text:i%100 == 0 ? changed:text,start:Double(i*4)+0.1,end:Double(i*4+3)+0.1))
        }
        return (.init(url:URL(fileURLWithPath:"/declared-synthetic-reference.srt"),units:units),caps)
    }
    static func benchmark(_ minutes:Int,_ language:String,to root:URL) throws {
        let (ref,caps)=fixture(minutes,language),start=ProcessInfo.processInfo.systemUptime
        let report=try E.evaluate(captions:caps,reference:ref,language:language,sourceRange:0...Double(minutes*60),mediaDuration:Double(minutes*60))
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let data:[String:Any]=["minutes":minutes,"language":language,"synthetic":true,"units":ref.units.count,"elapsedSeconds":elapsed,"peakRSSMiB":Double(usage.ru_maxrss)/1048576,"status":report.status.rawValue,"cer":report.cer ?? NSNull(),"wer":report.wer ?? NSNull(),"matched":report.matchedSentences,"algorithm":report.algorithm ?? "","alignmentApproximate":report.alignmentApproximate ?? false]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("benchmark.json"))
        guard report.status == .scored,report.cer! > 0,report.wer! > 0,report.matchedSentences == ref.units.count,report.timing != nil,abs(report.timing!.medianAbsoluteStart-0.1) < 0.000001,elapsed < 30,Double(usage.ru_maxrss)/1048576 < 400 else { throw ProjectError("Long synthetic benchmark exceeded contract: \(data)") }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.count == 5,CommandLine.arguments[1] == "--benchmark" {
            try benchmark(Int(CommandLine.arguments[2])!,CommandLine.arguments[3],to:URL(fileURLWithPath:CommandLine.arguments[4]));return
        }
        _=NSApplication.shared
        let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/Stage9/EvaluationSafety")
        var rows:[[String:Any]]=[]
        func check(_ name:String,_ pass:Bool,_ detail:String="") {rows.append(["name":name,"passed":pass,"detail":detail]);print("\(pass ? "PASS":"FAIL") \(name) \(detail)")}
        func save() {try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))}
        defer {save()}
        var samples=[""]
        for length in 1...5 {for mask in 0..<(1<<length) {samples.append((0..<length).map {mask & (1<<$0) == 0 ? "a":"b"}.joined())}}
        var same=true
        for a in samples {for b in samples {if try E.editCounts(reference:Array(a),hypothesis:Array(b)) != Baseline.editCounts(reference:Array(a),hypothesis:Array(b)) {same=false}}}
        check("All 3969 short edit counts preserve baseline substitution deletion insertion ties",same)
        let longA=Array((0..<1200).map {Character(String(UnicodeScalar(97+$0%5)!))})
        var longB=longA;longB.insert("x",at:100);longB.remove(at:800);longB[900]="z"
        check("Adaptive band preserves full-table counts above one million cells",try E.editCounts(reference:longA,hypothesis:longB) == Baseline.editCounts(reference:longA,hypothesis:longB))
        let unequal=Array(longA[..<300])+Array(longA[600...])
        check("Large deletion band and transposed insertion preserve exact baseline counts",try E.editCounts(reference:longA,hypothesis:unequal) == Baseline.editCounts(reference:longA,hypothesis:unequal) && E.editCounts(reference:unequal,hypothesis:longA) == Baseline.editCounts(reference:unequal,hypothesis:longA))
        let opposite=Array(repeating:Character("z"),count:1200)
        check("Fully different adaptive band widens to exact full distance",try E.editCounts(reference:longA,hypothesis:opposite) == Baseline.editCounts(reference:longA,hypothesis:opposite))
        let alignmentCases:[([String],[String])]=[( ["hello world today","nice weather"],["hello","world today","nice weather"]),(["first scene","second scene","third scene"],["first scene","third scene"]),(["abc","def"],["xyz","uvw"]),(["a","b","c"],["abc"]),(["ab","cd"],["ax","ed"])]
        var aligned=true
        for (a,b) in alignmentCases {let result=try E.aligned(reference:a,hypothesis:b,language:"en",work:EvaluationWork(.init()));if result.steps != Baseline.align(reference:a,hypothesis:b,language:"en",band:nil) {aligned=false;print("ALIGNMENT_DIFFERENCE \(a) \(b) \(result.steps)")}}
        // Deterministic varied short split/merge/gap controls.
        var seed:UInt64=7
        func next(_ n:Int)->Int {seed=seed &* 6364136223846793005 &+ 1;return Int((seed>>32)%UInt64(n))}
        let vocabulary=["abc","bcd","abcdef","world today","hello","nice weather","a","x"]
        for _ in 0..<80 {
            let a=(0..<next(7)).map {_ in vocabulary[next(vocabulary.count)]},b=(0..<next(7)).map {_ in vocabulary[next(vocabulary.count)]}
            let result=try E.aligned(reference:a,hypothesis:b,language:"en",work:EvaluationWork(.init()))
            if result.steps != Baseline.align(reference:a,hypothesis:b,language:"en",band:nil) {aligned=false}
        }
        check("85 short sentence split merge gap alignments preserve stage8 baseline",aligned)
        let many=(0..<1200).map {"scene \($0) uniquely named"},omitted=Array(many[..<300])+Array(many[900...])
        let omission=try E.aligned(reference:many,hypothesis:omitted,language:"en",work:EvaluationWork(.init()))
        let missing=omission.steps.filter {if case .missing = $0 {return true};return false}.count
        check("600 sentence omission recovered with anchors without full matrix",missing == 600 && omission.approximate,omission.method)
        let repeats=try E.aligned(reference:Array(repeating:"a",count:200),hypothesis:Array(repeating:"z",count:130),language:"en",work:EvaluationWork(.init()))
        check("No-anchor unequal streams use bounded path and flag limited alignment",repeats.approximate && repeats.steps.count == 330,repeats.method)
        let ref=TranscriptReference(url:root.appendingPathComponent("r.srt"),units:[.init(text:"hello world",start:0,end:2)])
        let caps=[EvaluatedCaption(text:"hello world",start:0.1,end:2.1)]
        let good=try E.evaluate(captions:caps,reference:ref,language:"en",sourceRange:0...3,mediaDuration:3)
        check("Short perfect report exact scores timing and explicit algorithm",good.cer == 0 && good.wer == 0 && good.timing?.medianAbsoluteStart == 0.1 && good.alignmentApproximate == false && good.algorithm == "exact-adaptive-band-v1")
        let empty=try E.evaluate(captions:[],reference:ref,language:"en",sourceRange:0...3,mediaDuration:3)
        check("Empty hypothesis gives full deletion error not false zero",empty.cer == 1 && empty.wer == 1 && empty.missing.count == 1 && empty.timing == nil)
        let different=try E.evaluate(captions:[.init(text:"zzzzz",start:0,end:2)],reference:ref,language:"en",sourceRange:0...3,mediaDuration:3)
        check("Entirely different short text has positive scores and unmatched sentences",different.cer! > 0 && different.wer == 1 && different.missing.count == 1 && different.extra.count == 1)
        var partial=ref;partial.units.append(.init(text:"unbounded",start:nil,end:nil))
        let invalid=try E.evaluate(captions:caps,reference:partial,language:"en",sourceRange:0...3,mediaDuration:3)
        check("Partially timed reference is unscored without metrics",invalid.status == .unscored && invalid.cer == nil && invalid.wer == nil)
        var outside=ref;outside.units[0].end=30
        check("Timed reference beyond media duration is unscored",try E.evaluate(captions:caps,reference:outside,language:"en",sourceRange:0...3,mediaDuration:3).status == .unscored)
        check("Missing reference never creates CER or WER",try E.evaluate(captions:caps,reference:nil,language:"en",sourceRange:0...3,mediaDuration:3).cer == nil)
        let plain=TranscriptReference(url:ref.url,units:[.init(text:"hello world",start:nil,end:nil)])
        check("Untimed partial source range is unscored",try E.evaluate(captions:caps,reference:plain,language:"en",sourceRange:0...2.5,mediaDuration:10).status == .unscored)
        check("Nonfinite caption time is unscored",try E.evaluate(captions:[.init(text:"hello",start:.nan,end:2)],reference:ref,language:"en",sourceRange:0...3,mediaDuration:3).status == .unscored)
        let korean=TranscriptReference(url:ref.url,units:[.init(text:"안녕하세요",start:0,end:2)])
        let spacing=try E.evaluate(captions:[.init(text:"안녕 하세요",start:0,end:2)],reference:korean,language:"ko",sourceRange:0...3,mediaDuration:3)
        check("Korean CER ignores spacing while eojeol WER changes",spacing.cer == 0 && spacing.wer! > 0)
        check("Japanese NFKC and English punctuation policy preserved",try E.checkedCharacters("ＡＢＣ今日は",language:"ja") == E.characters("ABC今日は",language:"ja") && E.checkedWords("We're HERE!",language:"en") == ["we","re","here"])
        var limits=EvaluationLimits();limits.maximumWorkCells=20
        let bounded=try E.evaluate(captions:[.init(text:"zzzzzzzzzz",start:0,end:2)],reference:ref,language:"en",sourceRange:0...3,mediaDuration:3,limits:limits)
        check("Work exhaustion is unscored with no fake zero metric",bounded.status == .unscored && bounded.cer == nil && bounded.wer == nil && bounded.timing == nil)
        let (longReference,longCaptions)=fixture(120,"en")
        var differentCaptions=longCaptions
        for i in differentCaptions.indices {differentCaptions[i].text=String(repeating:"z",count:60)}
        limits=EvaluationLimits();limits.maximumWorkCells=5_000_000
        let dissimilarStart=ProcessInfo.processInfo.systemUptime
        let dissimilar=try E.evaluate(captions:differentCaptions,reference:longReference,language:"en",sourceRange:0...7200,mediaDuration:7200,limits:limits)
        let dissimilarSeconds=ProcessInfo.processInfo.systemUptime-dissimilarStart
        check("Entirely different 120 minute transcripts stop at work bound without approximate scores",dissimilar.status == .unscored && dissimilar.cer == nil && dissimilar.wer == nil && dissimilarSeconds < 10,String(format:"%.6fs",dissimilarSeconds))
        limits=EvaluationLimits();limits.maximumAlignmentCells=1
        check("Sentence memory limit is reported as unscored",try E.evaluate(captions:[.init(text:"hello friend",start:0,end:2)],reference:ref,language:"en",sourceRange:0...3,mediaDuration:3,limits:limits).status == .unscored)
        let progressEvents=ProgressEvents()
        _=try E.evaluate(captions:caps,reference:ref,language:"en",sourceRange:0...3,mediaDuration:3,progress:{progressEvents.append($0.fraction)})
        let fractions=progressEvents.values
        check("Evaluation progress is monotonic bounded and stops before publication",!fractions.isEmpty && fractions.first == 0 && fractions.last == 0.98 && zip(fractions,fractions.dropFirst()).allSatisfy {$0 <= $1})
        let encoded=try JSONEncoder().encode(good),fields=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        var oldFields=fields;oldFields.removeValue(forKey:"algorithm");oldFields.removeValue(forKey:"alignmentMethod");oldFields.removeValue(forKey:"alignmentApproximate")
        if var timing=oldFields["timing"] as? [String:Any] {
            timing.removeValue(forKey:"p95AbsoluteStart");timing.removeValue(forKey:"p95AbsoluteEnd");oldFields["timing"]=timing
        }
        let oldFormat=try JSONDecoder().decode(TranscriptEvaluationReport.self,from:JSONSerialization.data(withJSONObject:oldFields))
        check("Older reports without algorithm and p95 fields remain decodable",oldFormat.cer == good.cer && oldFormat.alignmentApproximate == nil && oldFormat.timing?.p95AbsoluteStart == nil && oldFormat.timing?.p95AbsoluteEnd == nil)
        limits=EvaluationLimits();limits.maximumCharacters=2
        check("Character input bound produces unscored report",try E.evaluate(captions:caps,reference:ref,language:"en",sourceRange:0...3,mediaDuration:3,limits:limits).status == .unscored)
        let huge=root.appendingPathComponent("oversized.txt");FileManager.default.createFile(atPath:huge.path,contents:nil)
        let handle=try FileHandle(forWritingTo:huge);try handle.truncate(atOffset:20_000_001);try handle.close()
        var rejected=false;do {_=try TranscriptReference.load(huge)} catch {rejected=true}
        check("Oversized reference refused before content allocation",rejected)
        let reports=root.appendingPathComponent("Reports"),old=try E.write(good,title:"old",to:reports,name:"same")
        let oldBytes=try Data(contentsOf:old.json),oldText=try Data(contentsOf:old.text)
        let second=try E.write(good,title:"new",to:reports,name:"same")
        check("Same basename creates separate complete bundle and preserves old bytes",try second.json != old.json && (try Data(contentsOf:old.json)) == oldBytes)
        second.discard()
        let writer=Task.detached {try E.write(good,title:"cancel",to:reports,name:"same",beforeCommit:{withUnsafeCurrentTask {$0?.cancel()}})}
        var writeCancelled=false;do {_=try await writer.value} catch is CancellationError {writeCancelled=true}
        check("Precommit cancel leaves no complete or pending new report and preserves previous",try writeCancelled && (try FileManager.default.contentsOfDirectory(atPath:reports.path)).count == 1 && (try Data(contentsOf:old.text)) == oldText)
        var fault=false;do {_=try E.write(good,title:"fault",to:reports,name:"same",beforeCommit:{throw ProjectError("injected failure")})} catch {fault=true}
        check("Write fault cleans own temporary bundle only",try fault && (try FileManager.default.contentsOfDirectory(atPath:reports.path)).count == 1)
        var collision:URL?,collisionFailed=false
        do {
            _=try E.write(good,title:"collision",to:reports,name:"same",beforeCommit:{
                let pending=try FileManager.default.contentsOfDirectory(at:reports,includingPropertiesForKeys:nil).first {$0.lastPathComponent.hasPrefix(".pending-evaluation-")}!
                let id=String(pending.lastPathComponent.dropFirst(".pending-evaluation-".count))
                let occupied=reports.appendingPathComponent("same-"+id+".report",isDirectory:true)
                try FileManager.default.createDirectory(at:occupied,withIntermediateDirectories:false)
                try Data("existing unrelated completed report".utf8).write(to:occupied.appendingPathComponent("sentinel"));collision=occupied
            })
        } catch {collisionFailed=true}
        let sentinel=try collision.map {try Data(contentsOf:$0.appendingPathComponent("sentinel"))}
        check("Commit collision preserves another completed bundle and removes only owned pending",try collisionFailed && sentinel == Data("existing unrelated completed report".utf8) && !(try FileManager.default.contentsOfDirectory(atPath:reports.path)).contains {$0.hasPrefix(".pending-evaluation-")})
        if let collision {try FileManager.default.removeItem(at:collision)}
        var pathRejected=false;do {_=try E.write(good,title:"bad",to:reports,name:"../bad")} catch {pathRejected=true}
        check("Report traversal name rejected",pathRejected)
        let started=Signal(),big=Array(repeating:Character("a"),count:200_000),other=Array(repeating:Character("z"),count:200_000)
        let computation=Task.detached { () throws -> EditCounts in
            var limits=EvaluationLimits();limits.maximumWorkCells=1_000_000_000
            return try E.countedDistance(reference:big,hypothesis:other,work:EvaluationWork(limits),progress:{value in if value > 0 {started.set()}})
        }
        let wait=ProcessInfo.processInfo.systemUptime
        while !started.value && ProcessInfo.processInfo.systemUptime-wait < 5 {try await Task.sleep(nanoseconds:1_000_000)}
        let cancelledAt=ProcessInfo.processInfo.systemUptime;computation.cancel()
        var stopped=false;do {_=try await computation.value} catch is CancellationError {stopped=true}
        let cancelSeconds=ProcessInfo.processInfo.systemUptime-cancelledAt
        check("Running inner edit loop cancels within two seconds",started.value && stopped && cancelSeconds < 2,String(format:"%.6fs",cancelSeconds))
        try await editorChecks(root,good,old,check:check)
        var benchmarks:[[String:Any]]=[]
        for minutes in [30,60,120] {for language in ["ko","ja","en"] {
            let destination=try ProbeWorkspace.prepare(defaultPath:"benchmark",path:root.appendingPathComponent("\(minutes)-\(language)").path)
            let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--benchmark",String(minutes),language,destination.path]
            let log=destination.appendingPathComponent("child.log");FileManager.default.createFile(atPath:log.path,contents:nil);let output=try FileHandle(forWritingTo:log);child.standardOutput=output;child.standardError=output
            try child.run();let begun=ProcessInfo.processInfo.systemUptime
            while child.isRunning && ProcessInfo.processInfo.systemUptime-begun < 45 {try await Task.sleep(nanoseconds:50_000_000)}
            if child.isRunning {child.terminate();kill(child.processIdentifier,SIGKILL)}
            while child.isRunning {try await Task.sleep(nanoseconds:10_000_000)};try output.close()
            let metrics=(try? JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("benchmark.json")))) as? [String:Any]
            check("\(minutes) minutes \(language) isolated RSS time exact nonzero metric benchmark",child.terminationStatus == 0 && metrics != nil,metrics.map {"\($0["elapsedSeconds"]!)s \($0["peakRSSMiB"]!)MiB"} ?? "see child.log")
            if let metrics {benchmarks.append(metrics)}
        }}
        try JSONSerialization.data(withJSONObject:["computeCancellationSeconds":cancelSeconds,"different120MinutesSeconds":dissimilarSeconds,"different120MinutesWorkCellsLimit":5_000_000,"benchmarks":benchmarks],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("measurements.json"))
        save();let failures=rows.filter {($0["passed"] as? Bool) != true}.count
        print("EVALUATION_SAFETY_RESULT checks=\(rows.count) failures=\(failures)");if failures > 0 {exit(1)}
    }
    @MainActor static func editorChecks(_ root:URL,_ good:TranscriptEvaluationReport,_ old:EvaluationReportFiles,check:(String,Bool,String)->Void) async throws {
        // Declared metadata-only media fixture: no playback or ASR accuracy claim.
        let media=root.appendingPathComponent("declared-media.mov");try Data("evaluation UI fixture; not real media".utf8).write(to:media)
        let asset=MediaAsset(name:"declared",path:media.path,kind:.video,duration:MediaTime(seconds:7200),hasAudio:true)
        let source=Clip(name:"source",assetID:asset.id,duration:asset.duration)
        var project=Project(name:"evaluation UI");project.assets=[asset];project.sequence.tracks[0].clips=[source]
        let titleIndex=project.sequence.tracks.firstIndex {$0.kind == .title}!
        let (reference,captions)=fixture(120,"en")
        for caption in captions {
            var clip=Clip(name:"caption",start:MediaTime(seconds:caption.start),duration:MediaTime(seconds:caption.end-caption.start),title:Title(text:caption.text))
            clip.connection=ClipConnection(parentID:source.id,sourceStart:clip.start,sourceDuration:clip.duration)
            clip.captionMetadata=CaptionMetadata(language:"en",originalLanguage:"en",originalText:caption.text,generatedText:caption.text)
            project.sequence.tracks[titleIndex].clips.append(clip)
        }
        let url=root.appendingPathComponent("long.srt")
        let cues=reference.units.map {CaptionCue(start:MediaTime(seconds:$0.start!),duration:MediaTime(seconds:$0.end!-$0.start!),text:$0.text)}
        try SRTCodec.serialize(cues).write(to:url,atomically:true,encoding:.utf8)
        let editor=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"))
        editor.history=EditorHistory(project:project);editor.selectedClipID=source.id;editor.selectedClipIDs=[source.id];editor.speechOptions.language="en";editor.reportsDirectory=root.appendingPathComponent("UIReports")
        editor.lastEvaluation=good;editor.lastEvaluationReportURL=old.text
        let oldData=try Data(contentsOf:old.text)
        editor.evaluateSelectedCaptions(referenceURL:url)
        let begun=ProcessInfo.processInfo.systemUptime
        while editor.productivityBusy && (editor.evaluationProgress ?? 0) <= 0.05 && ProcessInfo.processInfo.systemUptime-begun < 5 {try await Task.sleep(nanoseconds:1_000_000)}
        let wasRunning=editor.productivityBusy && (editor.evaluationProgress ?? 0) > 0.05
        let cancelledAt=ProcessInfo.processInfo.systemUptime;editor.cancelProductivity()
        while editor.productivityBusy && ProcessInfo.processInfo.systemUptime-cancelledAt < 3 {try await Task.sleep(nanoseconds:1_000_000)}
        let seconds=ProcessInfo.processInfo.systemUptime-cancelledAt
        check("Editor cancellation propagates to detached worker and clears progress under two seconds",wasRunning && !editor.productivityBusy && !editor.evaluationActive && editor.evaluationProgress == nil && seconds < 2,String(format:"%.6fs",seconds))
        let reports=(try? FileManager.default.contentsOfDirectory(atPath:editor.reportsDirectory.path)) ?? []
        check("Editor cancel preserves prior result file and creates no completed report",try editor.lastEvaluation == good && editor.lastEvaluationReportURL == old.text && (try Data(contentsOf:old.text)) == oldData && reports.isEmpty && editor.message.contains("취소됨"),editor.message)
        let status=editor.productivityStatus;try await Task.sleep(nanoseconds:100_000_000)
        check("Late progress callbacks cannot replace cancelled status",editor.productivityStatus == status,editor.productivityStatus)
        editor.evaluateSelectedCaptions(referenceURL:url)
        var changed=editor.project;changed.name="changed during evaluation";editor.history=EditorHistory(project:changed)
        let timeout=ProcessInfo.processInfo.systemUptime
        while editor.productivityBusy && ProcessInfo.processInfo.systemUptime-timeout < 35 {try await Task.sleep(nanoseconds:10_000_000)}
        check("Project changed during evaluation refuses publication and keeps prior report",try !editor.productivityBusy && !editor.evaluationActive && editor.evaluationJobID == nil && editor.error != nil && editor.project == changed && editor.lastEvaluation == good && editor.lastEvaluationReportURL == old.text && Data(contentsOf:old.text) == oldData && ((try? FileManager.default.contentsOfDirectory(atPath:editor.reportsDirectory.path)) ?? []).isEmpty,editor.error ?? "")
        let existing=Set((try? FileManager.default.contentsOfDirectory(atPath:editor.reportsDirectory.path)) ?? [])
        editor.error=nil;editor.evaluateSelectedCaptions(referenceURL:url)
        let progressTimeout=ProcessInfo.processInfo.systemUptime
        while editor.productivityBusy && (editor.evaluationProgress ?? 0) <= 0.05 && ProcessInfo.processInfo.systemUptime-progressTimeout < 5 {try await Task.sleep(nanoseconds:1_000_000)}
        let active=editor.productivityBusy
        try (String(contentsOf:url,encoding:.utf8)+"\n").write(to:url,atomically:true,encoding:.utf8)
        let finish=ProcessInfo.processInfo.systemUptime
        while editor.productivityBusy && ProcessInfo.processInfo.systemUptime-finish < 35 {try await Task.sleep(nanoseconds:10_000_000)}
        check("Reference changed during comparison refuses publication without overwriting old result",active && editor.error?.contains("바뀌었습니다") == true && editor.lastEvaluation == good && Set((try? FileManager.default.contentsOfDirectory(atPath:editor.reportsDirectory.path)) ?? []) == existing,editor.error ?? "")
        try JSONSerialization.data(withJSONObject:["editorCancellationSeconds":seconds],options:.prettyPrinted).write(to:root.appendingPathComponent("editor-measurements.json"))
    }
}

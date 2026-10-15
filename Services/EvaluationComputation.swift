import Foundation

public struct EvaluationLimits: Sendable {
    public var maximumWorkCells: Int64 = 100_000_000
    public var maximumAlignmentCells = 2_000_000
    public var maximumCharacters = 500_000
    public var maximumWords = 150_000
    public var maximumUnits = 20_000
    public var maximumTextBytes = 40_000_000
    public init() {}
    var isValid: Bool {
        (1...1_000_000_000).contains(maximumWorkCells) && (1...4_000_000).contains(maximumAlignmentCells) &&
        (1...500_000).contains(maximumCharacters) && (1...150_000).contains(maximumWords) &&
        (1...20_000).contains(maximumUnits) && (1...40_000_000).contains(maximumTextBytes)
    }
}
public struct EvaluationProgress: Sendable {
    public var fraction: Double
    public var phase: String
}
struct EvaluationWorkLimit: LocalizedError {
    var detail: String
    var errorDescription: String? { "평가 작업 한도를 넘었습니다(\(detail)). 더 짧은 구간과 시간 있는 대본으로 다시 평가하세요." }
}
final class EvaluationWork {
    let limits: EvaluationLimits
    var cells: Int64 = 0
    private let progress: (@Sendable (EvaluationProgress) -> Void)?
    private var lastFraction = -1.0
    private var lastPhase = ""
    private var lastNotice = -Double.infinity
    init(_ limits: EvaluationLimits, progress: (@Sendable (EvaluationProgress) -> Void)? = nil) throws {
        guard limits.isValid else { throw EvaluationWorkLimit(detail:"설정") }
        self.limits=limits; self.progress=progress
    }
    func consume(_ amount: Int) throws {
        try Task.checkCancellation()
        guard amount >= 0, Int64(amount) <= limits.maximumWorkCells-cells else { throw EvaluationWorkLimit(detail:"정확한 비교 계산량") }
        cells += Int64(amount)
    }
    func report(_ fraction: Double, _ phase: String, force: Bool = false) throws {
        try Task.checkCancellation()
        let value = max(lastFraction,min(1,max(0,fraction))), now=ProcessInfo.processInfo.systemUptime
        if force || phase != lastPhase || value == 1 || now-lastNotice >= 0.1 && value-lastFraction >= 0.002 {
            lastFraction=value; lastPhase=phase; lastNotice=now; progress?(EvaluationProgress(fraction:value,phase:phase))
        }
    }
}

extension TranscriptEvaluation {
    private struct CountCell {
        var cost: Int
        var s: Int
        var d: Int
        var i: Int
    }
    /// Exact distance: a band result is accepted only if cost <= width, which contains every
    /// optimal path. A work-limit exception never becomes an approximate CER/WER or zero score.
    static func countedDistance<T: Equatable>(reference: [T], hypothesis: [T], work: EvaluationWork,
                                               progress: ((Double) throws -> Void)? = nil) throws -> EditCounts {
        try Task.checkCancellation()
        guard reference.count <= work.limits.maximumCharacters, hypothesis.count <= work.limits.maximumCharacters else { throw EvaluationWorkLimit(detail:"비교 단위 수") }
        if reference == hypothesis { try progress?(1); return EditCounts(referenceLength:reference.count) }
        if reference.isEmpty { try progress?(1); return EditCounts(insertions:hypothesis.count,referenceLength:0) }
        if hypothesis.isEmpty { try progress?(1); return EditCounts(deletions:reference.count,referenceLength:reference.count) }
        // Place the shorter stream in columns; preserve ORIGINAL substitution/deletion/insertion
        // tie priority even after transposition, then map deletion/insertion counts back.
        let swapped = hypothesis.count > reference.count
        let refs = swapped ? hypothesis : reference, hyps = swapped ? reference : hypothesis
        let n=refs.count, m=hyps.count, inf=Int.max/4
        let product = Int64(n)*Int64(m)
        var width = product <= 1_000_000 ? max(n,m) : max(32,n-m)
        while true {
            try Task.checkCancellation()
            var lower=0, upper=min(m,width)
            var previous=(lower...upper).map { CountCell(cost:$0,s:0,d:0,i:$0) }
            for row in 1...n {
                let lo=max(0,row-width), hi=min(m,row+width)
                guard lo <= hi else { throw EvaluationWorkLimit(detail:"비교 대역") }
                try work.consume(hi-lo+1)
                var current=[CountCell](repeating:CountCell(cost:inf,s:0,d:0,i:0),count:hi-lo+1)
                func old(_ j: Int) -> CountCell { j >= lower && j <= upper ? previous[j-lower] : CountCell(cost:inf,s:0,d:0,i:0) }
                for column in lo...hi {
                    if column & 1023 == 0 { try Task.checkCancellation() }
                    if column == 0 { current[0]=CountCell(cost:row,s:0,d:row,i:0); continue }
                    if refs[row-1] == hyps[column-1] { current[column-lo]=old(column-1); continue }
                    let sub=old(column-1), del=old(column), ins=column > lo ? current[column-1-lo] : CountCell(cost:inf,s:0,d:0,i:0)
                    let best=min(sub.cost,del.cost,ins.cost)
                    if sub.cost == best { current[column-lo]=CountCell(cost:best+1,s:sub.s+1,d:sub.d,i:sub.i) }
                    else if !swapped && del.cost == best || swapped && ins.cost != best { current[column-lo]=CountCell(cost:best+1,s:del.s,d:del.d+1,i:del.i) }
                    else { current[column-lo]=CountCell(cost:best+1,s:ins.s,d:ins.d,i:ins.i+1) }
                }
                previous=current; lower=lo; upper=hi
                if row & 255 == 0 || row == n { try progress?(Double(row)/Double(n)) }
            }
            let final=previous[m-lower]
            if final.cost <= width || width >= max(n,m) {
                return EditCounts(substitutions:final.s,deletions:swapped ? final.i : final.d,insertions:swapped ? final.d : final.i,referenceLength:reference.count)
            }
            // Widen while bounded work remains; dissimilar long inputs are explicitly unscored.
            width=min(max(n,m),width*2)
        }
    }

    struct AlignmentResult { var steps: [Step]; var method: String; var approximate: Bool }
    private final class Scores {
        let row: Int, lower: Int
        var values: [Double]
        init(_ row: Int, _ lower: Int, _ count: Int) { self.row=row; self.lower=lower; values=Array(repeating:-.infinity,count:count) }
    }
    /// Long input: unique exact sentence anchors + LIS partition large omissions without a
    /// quadratic fallback. Gaps use actual compact bands; sentence matching is explicitly limited.
    static func aligned(reference: [String], hypothesis: [String], language: String, work: EvaluationWork) throws -> AlignmentResult {
        let n=reference.count,m=hypothesis.count
        if n == 0 { return AlignmentResult(steps:(0..<m).map { .extra($0) },method:"empty",approximate:false) }
        if m == 0 { return AlignmentResult(steps:(0..<n).map { .missing($0) },method:"empty",approximate:false) }
        var rn:[String]=[],hn:[String]=[]
        for (i,text) in reference.enumerated() { if i & 255 == 0 { try Task.checkCancellation() }; rn.append(try checkedNormalized(text,language:language)) }
        for (i,text) in hypothesis.enumerated() { if i & 255 == 0 { try Task.checkCancellation() }; hn.append(try checkedNormalized(text,language:language)) }
        if rn == hn { return AlignmentResult(steps:(0..<n).map { .match($0,1,$0,1) },method:"exact-identical-sentences",approximate:false) }
        if n <= 60 && m <= 60 {
            return AlignmentResult(steps:try compactAlignment(reference:reference,hypothesis:hypothesis,language:language,work:work,band:nil),method:"full-small",approximate:false)
        }
        var rIndices:[String:[Int]]=[:],hIndices:[String:[Int]]=[:]
        for (i,s) in rn.enumerated() { rIndices[s,default:[]].append(i) }
        for (j,s) in hn.enumerated() { hIndices[s,default:[]].append(j) }
        let candidates=rn.indices.compactMap { i -> (Int,Int)? in
            guard rIndices[rn[i]]?.count == 1, let js=hIndices[rn[i]],js.count == 1 else { return nil }; return (i,js[0])
        }
        var tails:[Int]=[], tailIndices:[Int]=[], predecessors=Array(repeating:-1,count:candidates.count)
        for (k,pair) in candidates.enumerated() {
            if k & 255 == 0 { try Task.checkCancellation() }
            var lo=0,hi=tails.count
            while lo < hi { let mid=(lo+hi)/2; if tails[mid] < pair.1 { lo=mid+1 } else { hi=mid } }
            if lo > 0 { predecessors[k]=tailIndices[lo-1] }
            if lo == tails.count { tails.append(pair.1); tailIndices.append(k) } else { tails[lo]=pair.1; tailIndices[lo]=k }
        }
        var anchors:[(Int,Int)]=[]
        if var k=tailIndices.last { while k >= 0 { anchors.append(candidates[k]); k=predecessors[k] } }; anchors.reverse()
        var steps:[Step]=[], ri=0,hj=0
        for (a,b) in anchors + [(n,m)] {
            try Task.checkCancellation()
            let rs=Array(reference[ri..<a]),hs=Array(hypothesis[hj..<b])
            let gap=try compactAlignment(reference:rs,hypothesis:hs,language:language,work:work,band:rs.count <= 60 && hs.count <= 60 ? nil : 30)
            for step in gap { switch step {
                case .missing(let i):steps.append(.missing(ri+i))
                case .extra(let j):steps.append(.extra(hj+j))
                case .match(let i,let x,let j,let y):steps.append(.match(ri+i,x,hj+j,y))
            } }
            if a < n && b < m { steps.append(.match(a,1,b,1)) }; ri=a+1;hj=b+1
            try work.report(0.70+0.25*Double(min(n,a+1))/Double(n),"문장과 시간 비교 중")
        }
        return AlignmentResult(steps:steps,method:anchors.isEmpty ? "compact-band-30" : "unique-anchor-partitions-band-30",approximate:true)
    }

    /// Only byte backpointers in the explored cells plus four score rows, never an n×m table.
    private static func compactAlignment(reference:[String],hypothesis:[String],language:String,work:EvaluationWork,band:Int?) throws -> [Step] {
        let n=reference.count,m=hypothesis.count
        if n == 0 { return (0..<m).map { .extra($0) } }; if m == 0 { return (0..<n).map { .missing($0) } }
        let ratio=Double(m)/Double(n)
        var lows:[Int]=[],highs:[Int]=[], cells=0
        for i in 0...n {
            if i & 255 == 0 { try Task.checkCancellation() }
            // Include neighbouring row centres so even very unequal streams have a gap path.
            let lo=band.map { max(0,Int(floor(Double(max(0,i-1))*ratio))-$0) } ?? 0
            let hi=band.map { min(m,Int(ceil(Double(min(n,i+1))*ratio))+$0) } ?? m
            let amount=hi-lo+1
            guard amount <= work.limits.maximumAlignmentCells-cells else { throw EvaluationWorkLimit(detail:"문장 대응 공간") }
            cells+=amount; lows.append(lo);highs.append(hi)
        }
        var back=lows.indices.map { Array<UInt8>(repeating:0,count:highs[$0]-lows[$0]+1) }
        var ring:[Scores?]=Array(repeating:nil,count:4)
        func ensure(_ row:Int) { if row <= n && ring[row%4]?.row != row { ring[row%4]=Scores(row,lows[row],highs[row]-lows[row]+1) } }
        ensure(0); ring[0]!.values[0]=0
        // Cache each 1/2/3 sentence grouping's normalized characters once per partition.
        func groups(_ list:[String]) throws -> [[[Character]]] {
            var result:[[[Character]]]=[]
            for i in list.indices { if i & 63 == 0 { try Task.checkCancellation() }; result.append(try (1...min(3,list.count-i)).map { try checkedCharacters(list[i..<(i+$0)].joined(separator:" "),language:language) }) }
            return result
        }
        let rg=try groups(reference),hg=try groups(hypothesis)
        for i in 0...n {
            for row in i...min(n,i+3) { ensure(row) }
            let current=ring[i%4]!
            try work.consume(highs[i]-lows[i]+1)
            for j in lows[i]...highs[i] {
                if j & 31 == 0 { try Task.checkCancellation() }
                let base=current.values[j-lows[i]]; if base == -.infinity { continue }
                func relax(_ ni:Int,_ nj:Int,_ value:Double,_ code:UInt8) {
                    guard ni <= n,nj >= lows[ni],nj <= highs[ni] else { return }
                    let row=ring[ni%4]!,k=nj-lows[ni]
                    if value > row.values[k] { row.values[k]=value;back[ni][k]=code }
                }
                if i < n { relax(i+1,j,base,1) };if j < m { relax(i,j+1,base,2) }
                for (a,b,code) in [(1,1,UInt8(3)),(1,2,4),(2,1,5),(1,3,6),(3,1,7)] where i+a <= n && j+b <= m {
                    let x=rg[i][a-1],y=hg[j][b-1],maximum=max(x.count,y.count)
                    let penalty=Double(a+b-2)*0.02
                    // Length alone can prove a pair cannot improve the zero-gap path.
                    if maximum > 0 && Double(abs(x.count-y.count))/Double(maximum) > 1-matchThreshold-penalty { continue }
                    let c=try countedDistance(reference:x,hypothesis:y,work:work)
                    let sim=maximum == 0 ? 1 : max(0,1-Double(c.substitutions+c.deletions+c.insertions)/Double(maximum))
                    if sim >= matchThreshold+penalty { relax(i+a,j+b,base+(sim-matchThreshold)-penalty,code) }
                }
            }
        }
        var steps:[Step]=[],i=n,j=m
        while i > 0 || j > 0 {
            if steps.count & 255 == 0 { try Task.checkCancellation() }
            let code=back[i][j-lows[i]]
            switch code {
            case 1: i-=1;steps.append(.missing(i))
            case 2: j-=1;steps.append(.extra(j))
            case 3: i-=1;j-=1;steps.append(.match(i,1,j,1))
            case 4: i-=1;j-=2;steps.append(.match(i,1,j,2))
            case 5: i-=2;j-=1;steps.append(.match(i,2,j,1))
            case 6: i-=1;j-=3;steps.append(.match(i,1,j,3))
            case 7: i-=3;j-=1;steps.append(.match(i,3,j,1))
            default: throw EvaluationWorkLimit(detail:"문장 대응 경로")
            }
        }
        return steps.reversed()
    }
}

import Foundation

/// Checks object-key uniqueness before Foundation discards duplicates. Syntax is then decoded
/// by Foundation; this bounded scanner never substitutes or normalizes reference values.
enum ReferenceJSONSafety {
    static func validate(_ data: Data) throws {
        var scanner = Scanner(bytes:Array(data))
        try scanner.value(depth:0)
        scanner.space()
        guard scanner.position == scanner.bytes.count else { throw ProjectError("정답 JSON의 뒤쪽 형식이 올바르지 않습니다.") }
    }
    private struct Scanner {
        let bytes:[UInt8]
        var position=0
        var nodes=0
        mutating func space() { while position < bytes.count,[9,10,13,32].contains(bytes[position]) { position+=1 } }
        mutating func take(_ byte:UInt8) throws {
            space();guard position < bytes.count,bytes[position] == byte else { throw ProjectError("정답 JSON 구조가 올바르지 않습니다.") };position+=1
        }
        mutating func string(key:Bool) throws -> String {
            try take(34);let start=position-1;var escaped=false
            while position < bytes.count {
                let byte=bytes[position];position+=1
                if byte == 92 {escaped=true;guard position < bytes.count else {break};position+=1}
                else if byte == 34 {
                    if !key {return ""}
                    if !escaped,let text=String(bytes:bytes[(start+1)..<(position-1)],encoding:.utf8) {return text}
                    guard let text=try JSONSerialization.jsonObject(with:Data(bytes[start..<position]),options:.fragmentsAllowed) as? String else {break}
                    return text
                }
            }
            throw ProjectError("정답 JSON 문자열이 올바르지 않습니다.")
        }
        mutating func value(depth:Int) throws {
            try Task.checkCancellation();nodes+=1;space()
            guard depth <= 64,nodes <= 400_000,position < bytes.count else {throw ProjectError("정답 JSON 깊이·항목 수·구조가 허용 범위를 넘습니다.")}
            switch bytes[position] {
            case 123:
                position+=1;space();var keys=Set<String>()
                if position < bytes.count,bytes[position] == 125 {position+=1;return}
                while true {
                    let key=try string(key:true)
                    guard keys.insert(key).inserted else {throw ProjectError("정답 JSON에 중복된 필드가 있습니다.")}
                    try take(58);try value(depth:depth+1);space()
                    if position < bytes.count,bytes[position] == 125 {position+=1;return}
                    try take(44)
                }
            case 91:
                position+=1;space()
                if position < bytes.count,bytes[position] == 93 {position+=1;return}
                while true {
                    try value(depth:depth+1);space()
                    if position < bytes.count,bytes[position] == 93 {position+=1;return}
                    try take(44)
                }
            case 34: _=try string(key:false)
            default:
                let start=position
                while position < bytes.count,![9,10,13,32,44,93,125].contains(bytes[position]) {position+=1}
                guard position > start else {throw ProjectError("정답 JSON 값이 올바르지 않습니다.")}
            }
        }
    }
}

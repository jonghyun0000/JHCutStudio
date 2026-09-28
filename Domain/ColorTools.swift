import Foundation
public struct CubeLUT: Codable, Equatable, Sendable {
    public var name: String
    public var size: Int
    public var values: [Float]
    public static func parse(_ text: String, name: String) throws -> CubeLUT {
        guard text.utf8.count <= 4_000_000 else { throw ProjectError("LUT 파일은 4MB 이하여야 합니다.") }
        var dimension = 0, values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("TITLE") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields[0] == "LUT_3D_SIZE" {
                guard dimension == 0, fields.count == 2, let size = Int(fields[1]), (2...33).contains(size) else { throw ProjectError("3D LUT 크기는 2~33만 지원합니다.") }
                dimension = size
            } else if fields[0] == "DOMAIN_MIN" || fields[0] == "DOMAIN_MAX" {
                let expected: Float = fields[0] == "DOMAIN_MIN" ? 0 : 1
                guard fields.count == 4, fields.dropFirst().allSatisfy({ Float($0) == expected }) else { throw ProjectError("LUT 입력 범위는 RGB 0~1이어야 합니다.") }
            } else {
                guard dimension > 0, fields.count == 3 else { throw ProjectError("지원하지 않는 LUT 형식입니다. 3D .cube 파일을 선택하세요.") }
                let rgb = fields.compactMap { Float($0) }
                guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ProjectError("LUT 값은 유한한 0~1 범위여야 합니다.") }
                values += rgb + [1]
                guard values.count <= dimension * dimension * dimension * 4 else { throw ProjectError("LUT 데이터가 선언 크기를 초과합니다.") }
            }
        }
        guard dimension > 0, values.count == dimension * dimension * dimension * 4 else { throw ProjectError("LUT 데이터가 부족합니다.") }
        return CubeLUT(name: name, size: dimension, values: values)
    }
}

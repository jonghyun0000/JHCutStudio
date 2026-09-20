import Foundation

@main
struct VerifyAssetLibrary {
    static func main() throws {
        let source=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "Resources/Library",isDirectory:true)
        let library=try AssetLibrary(rootURL:source);try library.verify()
        guard let first=library.assets.first else {throw AssetLibraryError.invalid("빈 라이브러리")}
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("JHCut-asset-check-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:temporary)}
        let manifest=temporary.appendingPathComponent("manifest.json")
        let encoder=JSONEncoder()
        var sample=first;sample.relativePath="sample.wav"
        try encoder.encode([sample]).write(to:manifest)
        try Data(contentsOf:library.url(for:first)).write(to:temporary.appendingPathComponent("sample.wav"))
        try AssetLibrary(rootURL:temporary).verify()
        try Data("corrupt test bytes".utf8).write(to:temporary.appendingPathComponent("sample.wav"))
        var caughtChecksum=false
        do{try AssetLibrary(rootURL:temporary).verify()}catch AssetLibraryError.checksum{caughtChecksum=true}
        guard caughtChecksum else{throw AssetLibraryError.invalid("변조 검증 누락")}
        sample.relativePath="../outside.wav";try encoder.encode([sample]).write(to:manifest)
        var caughtTraversal=false
        do{_ = try AssetLibrary(rootURL:temporary)}catch AssetLibraryError.invalid{caughtTraversal=true}
        guard caughtTraversal else{throw AssetLibraryError.invalid("경로 이탈 검증 누락")}
        sample.relativePath="symlink.wav";try encoder.encode([sample]).write(to:manifest)
        try FileManager.default.createSymbolicLink(at:temporary.appendingPathComponent("symlink.wav"),withDestinationURL:library.url(for:first))
        var caughtSymlink=false
        do{_ = try AssetLibrary(rootURL:temporary)}catch AssetLibraryError.invalid{caughtSymlink=true}
        guard caughtSymlink else{throw AssetLibraryError.invalid("심볼릭 링크 이탈 검증 누락")}
        sample.relativePath="sample.wav";try encoder.encode([sample,sample]).write(to:manifest)
        var caughtDuplicate=false
        do{_ = try AssetLibrary(rootURL:temporary)}catch AssetLibraryError.invalid{caughtDuplicate=true}
        guard caughtDuplicate else{throw AssetLibraryError.invalid("중복 ID 검증 누락")}
        print("PASS \(library.assets.count) SHA256 hashes, valid fixture, corruption, path traversal, escaping symlink, duplicate IDs; all temporary files removed")
    }
}

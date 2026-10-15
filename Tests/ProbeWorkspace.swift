import Foundation

/// Test outputs are fresh directories, never folders that a probe recursively deletes.
enum ProbeWorkspace {
    static func prepare(defaultPath: String, path: String? = nil) throws -> URL {
        let supplied = path ?? CommandLine.arguments.dropFirst().first
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let requested = supplied ?? repo.appendingPathComponent("Artifacts/Runs/Standalone-" + UUID().uuidString)
            .appendingPathComponent(URL(fileURLWithPath: defaultPath).lastPathComponent).path
        guard !requested.split(separator: "/").contains("..") else { throw failure("상위 폴더 경로를 출력으로 사용할 수 없습니다.") }
        let url = URL(fileURLWithPath: requested, isDirectory: true).standardizedFileURL
        var ancestor = url
        while ancestor.path != "/" {
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path),
               !(ancestor.path == "/var" && destination == "private/var") {
                throw failure("심볼릭 링크를 거치는 출력 경로는 허용하지 않습니다.")
            }
            ancestor.deleteLastPathComponent()
        }
        let resolved = url.resolvingSymlinksInPath()
        guard comparisonPath(url.path) == comparisonPath(resolved.path) else { throw failure("심볼릭 링크 출력 경로는 허용하지 않습니다.") }
        // Foundation can spell the same system temporary directory with either /var or
        // /private/var, even between these URL operations. Compare that one allowed alias
        // consistently; the ancestor walk above still rejects every other symlink.
        let artifactRoot = comparisonPath(repo.appendingPathComponent("Artifacts").path)
        let temporaryRoot = comparisonPath(FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path)
        let outputPath = comparisonPath(resolved.path)
        guard outputPath.hasPrefix(artifactRoot + "/") || outputPath.hasPrefix(temporaryRoot + "/") else {
            throw failure("검사 출력은 저장소 Artifacts 또는 현재 사용자 임시 폴더 안의 새 하위 폴더여야 합니다.")
        }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory) {
            guard directory.boolValue, try FileManager.default.contentsOfDirectory(atPath: resolved.path).isEmpty else {
                throw failure("기존 검사 결과가 있는 폴더를 덮어쓰지 않습니다. 새 출력 경로를 지정하세요.")
            }
        }
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try Data("JHCut probe workspace v1\n".utf8).write(to: resolved.appendingPathComponent(".jhcut-probe-workspace"), options: .atomic)
        return resolved
    }

    private static func comparisonPath(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "JHCut.ProbeWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

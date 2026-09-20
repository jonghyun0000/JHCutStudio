import Foundation

public enum ProjectStore {
    public static func backupURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("backup") }

    /// Writes a validated JSON document atomically. The previous valid bytes are kept in .backup.
    /// Source files are referenced only and are never copied, modified, or removed.
    public static func save(_ project: Project, to documentURL: URL) throws {
        guard documentURL.isFileURL else { throw ProjectError("프로젝트는 로컬 파일로 저장하세요.") }
        try ProjectValidator.validate(project)
        var document = project
        for index in document.assets.indices {
            let asset = document.assets[index]
            let absoluteURL = URL(fileURLWithPath: asset.path)
            // load() refreshes this fallback so Save As retains the already-resolved source.
            // A Save As destination is not the source document's base. Looking up an old
            // relative path here could silently bind a missing clip to another same-name file.
            let source = FileManager.default.fileExists(atPath: absoluteURL.path) ? absoluteURL : asset.resolvedURL(relativeTo: nil)
            document.assets[index].path = source.path
            document.assets[index].relativePath = relativePath(from: documentURL.deletingLastPathComponent(), to: source)
            if FileManager.default.fileExists(atPath: source.path), let bookmark = try? source.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                document.assets[index].bookmark = bookmark
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        if FileManager.default.fileExists(atPath: documentURL.path) {
            let previous = try Data(contentsOf: documentURL)
            try DocumentCompatibility.validate(previous)
            // A damaged current file must not replace the last known-good backup.
            let priorProject = try JSONDecoder().decode(Project.self, from: previous)
            try ProjectValidator.validate(priorProject)
            try previous.write(to: backupURL(for: documentURL), options: .atomic)
        }
        try data.write(to: documentURL, options: .atomic)
    }

    /// Never silently recovers a corrupt document. The UI can explicitly offer recover(from:).
    public static func load(from documentURL: URL) throws -> Project {
        guard documentURL.isFileURL else { throw ProjectError("로컬 프로젝트 파일을 선택하세요.") }
        let bytes = try Data(contentsOf: documentURL)
        try DocumentCompatibility.validate(bytes)
        var project = try JSONDecoder().decode(Project.self, from: bytes)
        try ProjectValidator.validate(project)
        for index in project.assets.indices {
            project.assets[index].path = project.assets[index].resolvedURL(relativeTo: documentURL).path
        }
        return project
    }

    /// Explicitly loads the previous saved version without overwriting either file.
    public static func recover(from documentURL: URL) throws -> Project {
        try load(from: backupURL(for: documentURL))
    }

    private static func relativePath(from directory: URL, to file: URL) -> String {
        let base = directory.standardizedFileURL.pathComponents
        let source = file.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(base.count, source.count), base[shared] == source[shared] { shared += 1 }
        return (Array(repeating: "..", count: base.count - shared) + source.dropFirst(shared)).joined(separator: "/")
    }
}

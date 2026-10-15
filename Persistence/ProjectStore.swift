import Foundation

public enum ProjectStore {
    public static func backupURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("backup") }
    /// Copy of the document as it was before 0.7-only fields were first saved into it.
    public static func legacyCopyURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-0.7") }

    public static func beforeCaptionRolesURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-caption-roles") }

    public static func beforeLanguageEvidenceURL(for documentURL:URL) -> URL {documentURL.appendingPathExtension("before-language-evidence")}

    public static func beforeTranslationRevisionURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-translation-revision") }

    public static func beforeSpeakerIdentityURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-speaker-identity") }

    public static func beforeCaptionReviewLayoutURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-caption-review-layout") }

    public static func beforeBlendModesURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-blend-modes") }

    public static func beforeShapeMasksURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-shape-masks") }

    public static func beforeChromaKeyURL(for documentURL: URL) -> URL { documentURL.appendingPathExtension("before-chroma-key") }

    /// Writes a validated JSON document atomically. The previous valid bytes are kept in .backup.
    /// Source files are referenced only and are never copied, modified, or removed.
    public static func save(_ project: Project, to documentURL: URL, phaseHandler: ((ProjectSavePhase) throws -> Void)? = nil) throws {
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
            // Persist protection before the document can escape through Save As or a Finder copy.
            // A later save failure may leave conservative protection; it must never publish an unsafe reference.
            try GeneratedMediaRegistry.protectForSavedDocument(source)
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
            // A failed immutable preservation must not be silently accepted on the next save.
            for copy in [legacyCopyURL(for: documentURL), beforeCaptionRolesURL(for: documentURL), beforeLanguageEvidenceURL(for: documentURL), beforeTranslationRevisionURL(for: documentURL), beforeSpeakerIdentityURL(for: documentURL), beforeCaptionReviewLayoutURL(for: documentURL), beforeBlendModesURL(for: documentURL), beforeShapeMasksURL(for: documentURL), beforeChromaKeyURL(for: documentURL)] where FileManager.default.fileExists(atPath: copy.path) {
                do {
                    let retained = try Data(contentsOf: copy); try DocumentCompatibility.validate(retained)
                    try ProjectValidator.validate(JSONDecoder().decode(Project.self, from: retained))
                } catch { throw ProjectError("보존한 이전 원본 사본이 손상되었습니다: \(copy.lastPathComponent). 현재 문서와 백업은 보존했습니다. 다른 이름으로 저장하세요.") }
            }
            try DocumentAtomicWrite.replace(previous, at: backupURL(for: documentURL)) { try phaseHandler?(.backupStaged) }
            try phaseHandler?(.backupCommitted)
            let beforeKey = beforeChromaKeyURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeKey.path), !DocumentCompatibility.usesChromaKey(previous), DocumentCompatibility.usesChromaKey(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeKey) { try phaseHandler?(.legacyStaged) }
            }
            let beforeMask = beforeShapeMasksURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeMask.path), !DocumentCompatibility.usesShapeMasks(previous), DocumentCompatibility.usesShapeMasks(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeMask) { try phaseHandler?(.legacyStaged) }
            }
            let beforeBlend = beforeBlendModesURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeBlend.path), !DocumentCompatibility.usesBlendModes(previous), DocumentCompatibility.usesBlendModes(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeBlend) { try phaseHandler?(.legacyStaged) }
            }
            let beforeReview = beforeCaptionReviewLayoutURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeReview.path), !DocumentCompatibility.usesCaptionReviewLayout(previous), DocumentCompatibility.usesCaptionReviewLayout(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeReview) { try phaseHandler?(.legacyStaged) }
            }
            let beforeSpeaker = beforeSpeakerIdentityURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeSpeaker.path), !DocumentCompatibility.usesSpeakerIdentity(previous), DocumentCompatibility.usesSpeakerIdentity(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeSpeaker) { try phaseHandler?(.legacyStaged) }
            }
            let beforeTranslation = beforeTranslationRevisionURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeTranslation.path), !DocumentCompatibility.usesTranslationRevision(previous), DocumentCompatibility.usesTranslationRevision(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeTranslation) { try phaseHandler?(.legacyStaged) }
            }
            let beforeLanguage = beforeLanguageEvidenceURL(for:documentURL)
            if !FileManager.default.fileExists(atPath:beforeLanguage.path),!DocumentCompatibility.usesLanguageEvidence(previous),DocumentCompatibility.usesLanguageEvidence(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeLanguage) { try phaseHandler?(.legacyStaged) }
            }
            let beforeRoles = beforeCaptionRolesURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: beforeRoles.path), !DocumentCompatibility.usesCaptionRoles(previous), DocumentCompatibility.usesCaptionRoles(data) {
                try DocumentAtomicWrite.preserve(previous, at: beforeRoles) { try phaseHandler?(.legacyStaged) }
            }
            // First save that adds 0.7-only fields: keep the older file permanently, because a 0.6
            // app cannot open the new one and .backup is replaced on the next save.
            let legacy = legacyCopyURL(for: documentURL)
            if !FileManager.default.fileExists(atPath: legacy.path), !DocumentCompatibility.usesKeysIntroducedIn07(previous), DocumentCompatibility.usesKeysIntroducedIn07(data) {
                try DocumentAtomicWrite.preserve(previous, at: legacy) { try phaseHandler?(.legacyStaged) }
            }
        }
        try DocumentAtomicWrite.replace(data, at: documentURL) { try phaseHandler?(.documentStaged) }
        try phaseHandler?(.documentCommitted)
    }

    /// Never silently recovers a corrupt document. The UI can explicitly offer recover(from:).
    public static func load(from documentURL: URL) throws -> Project {
        guard documentURL.isFileURL else { throw ProjectError("로컬 프로젝트 파일을 선택하세요.") }
        let bytes = try Data(contentsOf: documentURL)
        try DocumentCompatibility.validate(bytes)
        var project = try JSONDecoder().decode(Project.self, from: bytes)
        try ProjectValidator.validate(project)
        project.sequence = SpeakerEditing.migrating(project.sequence)
        if let versions = project.derivedSequences { project.derivedSequences = versions.map(SpeakerEditing.migrating) }
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

import Foundation
import AppKit
import JHCutCore

// MARK: - Generated media lifetime (step 16)

extension EditorModel {
    /// Everything that can still point at files in the generated-media folder: the open document, every Undo/Redo
    /// state, the saved file on disk, recovery copies and backups. Anything unreadable becomes a `gap`.
    func generatedMediaReferences() -> GeneratedMediaReferences {
        var references = GeneratedMediaReferences()
        references.add(assets: project.assets, documentURL: mediaBaseURL)
        for state in history.retainedProjects { references.add(assets: state.assets, documentURL: mediaBaseURL) }
        if let documentURL {
            if FileManager.default.fileExists(atPath: documentURL.path) { references.add(documentAt: documentURL, label: "저장된 문서") }
            else { references.gaps.append("저장된 문서 파일이 없습니다.") }
            for retained in [ProjectStore.backupURL(for: documentURL), ProjectStore.legacyCopyURL(for: documentURL),
                             ProjectStore.beforeCaptionRolesURL(for: documentURL), ProjectStore.beforeLanguageEvidenceURL(for: documentURL),
                             ProjectStore.beforeTranslationRevisionURL(for: documentURL), ProjectStore.beforeSpeakerIdentityURL(for: documentURL),
                             ProjectStore.beforeCaptionReviewLayoutURL(for: documentURL),
                             ProjectStore.beforeBlendModesURL(for: documentURL),
                             ProjectStore.beforeShapeMasksURL(for: documentURL),
                             ProjectStore.beforeChromaKeyURL(for: documentURL)] where FileManager.default.fileExists(atPath: retained.path) {
                references.add(documentAt: retained, label: "이전 저장 문서")
            }
        }
        do {
            for snapshot in try recoveryStore.allSnapshotsForMediaRetention() { references.add(assets: snapshot.project.assets, documentURL: snapshot.mediaBaseURL ?? snapshot.documentURL) }
        } catch { references.gaps.append("복구본을 읽을 수 없습니다.") }
        let backups = ProjectBackup.scan(root: backupRoot)
        for entry in backups.entries {
            for path in entry.manifest.mediaPaths { references.add(URL(fileURLWithPath: path)) }
            let prior = entry.folder.appendingPathComponent(entry.manifest.documentName + ".backup")
            if FileManager.default.fileExists(atPath: prior.path) {
                references.add(documentAt: prior, label: "백업의 이전 저장 문서", mediaBaseURL: URL(fileURLWithPath: entry.manifest.originalPath))
            }
        }
        if backups.rejected > 0 { references.gaps.append("읽을 수 없는 백업 \(backups.rejected)개가 있습니다.") }
        return references
    }

    /// Looks at the generated-media folder and reports what is in use, removable or uncertain. Changes nothing.
    func refreshGeneratedMedia() {
        generatedMediaScanTask?.cancel()
        let scanID = UUID(); generatedMediaScanID = scanID
        let context = asyncContext(), references = generatedMediaReferences(), folder = generatedMediaRoot
        generatedMediaReport = nil; generatedMediaStatus = "생성 파일 확인 중…"
        generatedMediaScanTask = Task { [weak self] in
            do {
                let report = try await GeneratedMediaCleanup.scan(folder: folder, projectID: context.project.id, references: references)
                guard let self, !Task.isCancelled, self.generatedMediaScanID == scanID,
                      self.contextMatches(context), self.generatedMediaRoot == folder else { return }
                self.generatedMediaReport = report
                self.generatedMediaStatus = report.items.isEmpty ? "앱이 만든 사본 파일이 없습니다." : report.summary
            } catch {
                guard let self, !Task.isCancelled, self.generatedMediaScanID == scanID,
                      self.contextMatches(context), self.generatedMediaRoot == folder else { return }
                self.generatedMediaStatus = "생성 파일을 확인하지 못했습니다: " + error.localizedDescription
            }
        }
    }

    /// Moves the removable files to the Trash after the user confirms. Uncertain and in-use files are never touched.
    func cleanGeneratedMedia(confirm: Bool = true) {
        guard !busyDocument, let report = generatedMediaReport, report.folder == generatedMediaRoot, !report.removable.isEmpty else { return }
        let items = report.removable
        if confirm {
            let alert = NSAlert()
            alert.messageText = "쓰지 않는 생성 파일 \(items.count)개를 휴지통으로 옮길까요?"
            alert.informativeText = "\(ByteCountFormatter.string(fromByteCount: report.bytes(of: items), countStyle: .file)). 이 프로젝트가 만들었고 현재 문서·되돌리기·복구본·백업이 쓰지 않는 파일만 옮깁니다. 저장 문서에 포함된 이력이 있거나 저장 이력을 확인할 수 없는 파일은 다른 복사본을 위해 보호합니다. 휴지통에서 되돌릴 수 있습니다."
            alert.addButton(withTitle: "휴지통으로 이동"); alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let folder = generatedMediaRoot, ticket = beginAsyncJob(.productivity)
        generatedMediaStatus = "생성 파일 정리 중…"; productivityStatus = generatedMediaStatus
        productivityTask = Task {
            defer { finishAsyncJob(ticket) }
            do {
                try validateAsyncJob(ticket)
                let result = try await GeneratedMediaCleanup.remove(items, folder: folder, projectID: ticket.context.project.id, references: {
                    try self.validateAsyncJob(ticket)
                    guard self.generatedMediaRoot == folder else { throw ProjectError("생성 파일 폴더가 변경되어 정리를 중단했습니다.") }
                    return self.generatedMediaReferences()
                }, beforeRevalidation: {
                    try await self.checkpointAsyncJob(ticket, "generatedMedia.beforeRevalidation")
                }, trash: generatedMediaTrash)
                guard ownsAsyncJob(ticket), contextMatches(ticket.context) else { return }
                message = "생성 파일 \(result.removed.count)개를 휴지통으로 옮겼습니다 · \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))" + (result.skipped.isEmpty ? "" : " · \(result.skipped.count)개는 건너뜀")
                refreshGeneratedMedia()
            } catch {
                guard ownsAsyncJob(ticket) else { return }
                if !Task.isCancelled { self.error = error.localizedDescription }
                generatedMediaStatus = Task.isCancelled ? "생성 파일 정리 취소" : "생성 파일 정리 중단 · 다시 확인해 주세요."
            }
        }
    }

    /// Plain-words reason shown for a missing file that the app made itself.
    func missingMediaHint(for asset: MediaAsset) -> String? {
        let suffixes = ["· 정지 화면", "· 거꾸로", "· SDR 사본", "· 오디오", "완성 믹스"]
        guard suffixes.contains(where: { asset.name.contains($0) }) else { return nil }
        return "앱이 만든 사본이라 원본에서 다시 만들 수 있습니다. ‘원본 모으기’로 만든 폴더에는 이 파일이 함께 들어 있습니다."
    }
}

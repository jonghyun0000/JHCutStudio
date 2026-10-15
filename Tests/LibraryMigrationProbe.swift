import Foundation
import AppKit
import JHCutCore

@main struct LibraryMigrationProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/LibraryMigration")
        let fm = FileManager.default, catalog = try AssetLibrary()
        let standardItem = catalog.assets.first { $0.category == .music && (120...180).contains($0.duration ?? 0) }!
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        for action in ["catalog", "cached-only", "existing", "changed-existing", "mismatch", "cancel", "edit", "document", "tamper", "restored", "legacy-normalized"] {
            let item = action == "legacy-normalized" ? catalog.compatibilityAssets.first! : standardItem
            let folder = root.appendingPathComponent(action), old = folder.appendingPathComponent("Old.app/Contents/Resources/Library/" + item.relativePath)
            try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: catalog.url(for: item), to: old)
            var asset = try await MediaImporter.inspect(url: old)
            asset.name = item.name; asset.contentHash = item.sha256
            asset.provenance = AssetProvenance(sourceURL: item.sourceURL, author: item.author, license: item.license, licenseURL: item.licenseURL, sha256: item.sha256)
            if action == "mismatch" { asset.contentHash = String(repeating: "a", count: 64); asset.provenance?.sha256 = asset.contentHash! }
            var project = Project(name: "Legacy " + action); project.assets = [asset]
            let ti = project.sequence.tracks.firstIndex { $0.kind == .audio }!
            project.sequence.tracks[ti].clips = [Clip(name: "Saved music", assetID: asset.id, duration: MediaTime(45, 1), volume: 0.25)]
            let document = folder.appendingPathComponent("Saved.jhcut"); try ProjectStore.save(project, to: document)
            let savedBytes = try Data(contentsOf: document)
            if action == "changed-existing" { try Data("owned changed original".utf8).write(to: old) }
            else if action != "existing" { try fm.removeItem(at: old) }
            let model = EditorModel(recoveryStore: RecoveryStore(directory: folder.appendingPathComponent("Recovery")), exportHistoryURL: folder.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: folder.appendingPathComponent("Proxies")))
            model.libraryMediaStore = LibraryMediaStore(directory: folder.appendingPathComponent("LibraryMedia"))
            model.generatedMediaRoot = folder.appendingPathComponent("Generated"); model.backupRoot = folder.appendingPathComponent("Backups")
            model.bundledLibrary = catalog
            if action == "cached-only" {
                _ = try await model.libraryMediaStore.retain(source: catalog.url(for: item), item: item)
                let empty = folder.appendingPathComponent("NewAppEmptyCatalog"); try fm.createDirectory(at: empty, withIntermediateDirectories: true)
                try Data("[]".utf8).write(to: empty.appendingPathComponent("manifest.json")); model.bundledLibrary = try AssetLibrary(rootURL: empty)
            }
            var reached = false
            model.asyncJobBarrier = { stage in
                guard stage == "library.restore.beforeApply" else { return }; reached = true
                switch action {
                case "cancel": model.cancelImport()
                case "edit": _ = model.perform(.rename("Changed while restoring"))
                case "document": model.invalidateAsyncJobs(); model.history = EditorHistory(project: Project(name: "Other document"))
                case "tamper":
                    let cached = try await model.libraryMediaStore.existing(sha256: item.sha256, fileExtension: old.pathExtension)!
                    try Data("owned tamper".utf8).write(to: cached)
                default: break
                }
            }
            if action == "restored" { model.openRestored(try ProjectStore.load(from: document), baseURL: document, note: "Owned recovery fixture") }
            else { model.load(document) }
            let task = model.importTask; check("Tracked legacy restoration job: " + action, task != nil)
            await task?.value
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while model.isBuilding {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProjectError("Restored preview build did not finish") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let migrated = model.project.assets.first { $0.id == asset.id }
            if ["catalog", "cached-only", "existing", "restored", "legacy-normalized"].contains(action) {
                guard let migrated else { throw ProjectError("Missing migrated asset") }
                let restoredHash = try await FileIdentity.sha256(URL(fileURLWithPath: migrated.path))
                if action == "legacy-normalized" {
                    check("Legacy raw bytes restored instead of the normalized replacement", !catalog.assets.contains { $0.sha256 == restoredHash } && migrated.path.hasSuffix(".mp3") && catalog.asset(matchingSHA256: restoredHash)?.id == item.id)
                }
                check("Exact source restored: " + action, reached && migrated.path.hasPrefix(folder.appendingPathComponent("LibraryMedia").path + "/") && fm.fileExists(atPath: migrated.path) && restoredHash == item.sha256)
                check("Timing and source attribution preserved: " + action, model.project.sequence == project.sequence && migrated.provenance == asset.provenance && migrated.contentHash == asset.contentHash && model.dirty)
                let beforeSave = try Data(contentsOf: document)
                check("Original saved bytes unchanged before explicit save: " + action, beforeSave == savedBytes)
                if action != "restored" {
                    model.save(); let reopened = try ProjectStore.load(from: document)
                    check("Explicit save retains durable source: " + action, reopened.assets.first?.path == migrated.path && !model.dirty)
                }
                model.undo(); check("Migration is one Undo operation: " + action, model.project.assets.first?.path != migrated.path)
                model.redo(); check("Migration Redo preserves same asset identity: " + action, model.project.assets.first?.id == asset.id && model.project.assets.first?.path == migrated.path)
            } else if action == "document" {
                check("Old restore result cannot alter a later document", reached && model.project.name == "Other document" && model.project.assets.isEmpty)
            } else {
                check("Rejected restore retains old source link: " + action, reached && migrated?.path == old.path && (action == "changed-existing" || !fm.fileExists(atPath: old.path)))
                if action == "edit" { check("Intervening edit is preserved", model.project.name == "Changed while restoring") }
                if action == "changed-existing" {
                    let originalBytes = try Data(contentsOf: old)
                    check("Changed existing original is preserved and never silently replaced", originalBytes == Data("owned changed original".utf8) && model.error != nil)
                }
                if action == "mismatch" { check("Same name with different provenance is never rebound", model.error != nil) }
            }
            check("Restoration job is idle: " + action, !model.isImporting && model.importJobID == nil)
            let currentBytes = try Data(contentsOf: document)
            if !["catalog", "cached-only", "existing", "legacy-normalized"].contains(action) { check("No implicit disk rewrite: " + action, currentBytes == savedBytes) }
            model.invalidateAsyncJobs(); model.pausePlayback()
        }
        let failures = checks.filter { $0["passed"] as? Bool != true }.count
        print("LIBRARY_MIGRATION_RESULT checks=\(checks.count) failures=\(failures)")
        if failures > 0 { throw ProjectError("Library migration failed \(failures) checks") }
    }
}

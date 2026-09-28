import Foundation
import AppKit
import CryptoKit
@testable import JHCutCore

/// Upgrade 10: install diagnostics, document migration safety copy, project backup/restore, versions.
@main struct DistributionProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Distribution", isDirectory: true).standardizedFileURL
  try? FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

  // ---- Diagnostics (fake environments; nothing is installed or downloaded) ----
  let real = WhisperConfiguration()
  let info = ["CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "8"]
  func env(bundle: String = "/Applications/JH CUT Studio.app", support: URL? = nil, whisper: WhisperConfiguration = real, major: Int = 26, free: Int64? = 50_000_000_000, pairs: [String]? = ["한국어→영어"]) -> StartupDiagnostics.Environment {
   StartupDiagnostics.Environment(bundleURL: URL(fileURLWithPath: bundle), infoDictionary: info, supportDirectory: support ?? root.appendingPathComponent("Support"),
                                  whisper: whisper, systemVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0), freeBytes: free, translationPairs: pairs)
  }
  let healthy = StartupDiagnostics.run(env())
  check("Healthy install has no errors", !healthy.hasErrors, healthy.items.map { "\($0.id):\($0.level.rawValue)" }.joined(separator: " "))
  let broken = StartupDiagnostics.run(env(whisper: WhisperConfiguration(runtimeURL: root.appendingPathComponent("missing/whisper-cli"))))
  check("Missing recogniser inside the app is an error with reinstall advice", broken.items.contains { $0.id == "runtime" && $0.level == .error && $0.advice.contains("다시 복사") })
  let noModel = StartupDiagnostics.run(env(whisper: WhisperConfiguration(modelURL: root.appendingPathComponent("none/ggml-base.bin"))))
  check("Missing model is guidance, not an error, and nothing is downloaded", noModel.items.contains { $0.id == "model" && $0.level == .info && $0.advice.contains("동의") } && !noModel.hasErrors
        && !FileManager.default.fileExists(atPath: root.appendingPathComponent("none/ggml-base.bin").path))
  check("No translation packs → where to install them", StartupDiagnostics.run(env(pairs: [])).items.contains { $0.id == "translation" && $0.advice.contains("번역 언어") })
  check("Older macOS → translation unavailable, captions still work", StartupDiagnostics.run(env(major: 15, pairs: nil)).items.contains { $0.id == "translation" && $0.advice.contains("macOS 26") })
  check("App run from a quarantine location → move to Applications", StartupDiagnostics.run(env(bundle: "/private/var/folders/xx/AppTranslocation/ABC/d/JH CUT Studio.app")).items.contains { $0.id == "translocation" && $0.level == .warning })
  // On the internal APFS disk: the external T7 volume does not enforce POSIX permissions.
  let locked = FileManager.default.temporaryDirectory.appendingPathComponent("jhcut-locked-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path); try? FileManager.default.removeItem(at: locked) }
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
  check("Unwritable settings folder is an error", StartupDiagnostics.run(env(support: locked.appendingPathComponent("JHCutStudio"))).items.contains { $0.id == "support" && $0.level == .error })
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
  check("Low disk space warned", StartupDiagnostics.run(env(free: 500_000_000)).items.contains { $0.id == "disk" && $0.level == .warning })
  let pairs = await CaptionTranslation.installedPairs()
  let current = StartupDiagnostics.run(.current(translationPairs: pairs))
  check("This Mac's install check runs", !current.items.isEmpty, current.text.replacingOccurrences(of: "\n", with: " | "))

  // ---- Migration: first save that adds 0.7-only fields keeps the older file ----
  let doc = root.appendingPathComponent("Old.jhcut")
  var project = Project(name: "0.6 문서")
  var title = Title(text: "자막"); title.y = 0.8
  var cap = Clip(name: "자막", start: .zero, duration: MediaTime(seconds: 2), title: title)
  cap.captionMetadata = CaptionMetadata(language: "ko", originalLanguage: "ko", originalText: "자막", generatedText: "자막")
  project.sequence.tracks[2].clips = [cap]
  try ProjectStore.save(project, to: doc)
  let oldBytes = try Data(contentsOf: doc)
  check("A document without new features stays 0.6-shaped", !DocumentCompatibility.usesKeysIntroducedIn07(oldBytes))
  project.glossary = [GlossaryEntry(source: "Minsu", target: "민수")]
  try ProjectStore.save(project, to: doc)
  let legacy = ProjectStore.legacyCopyURL(for: doc)
  check("First save with 0.7 fields keeps a before-0.7 copy", FileManager.default.fileExists(atPath: legacy.path) && (try? Data(contentsOf: legacy)) == oldBytes)
  check("The kept copy opens", (try? ProjectStore.load(from: legacy))?.glossary == nil)
  project.name = "다시 저장"; try ProjectStore.save(project, to: doc)
  check("Later saves never overwrite the before-0.7 copy", (try? Data(contentsOf: legacy)) == oldBytes)
  let fresh = root.appendingPathComponent("New.jhcut"); try ProjectStore.save(project, to: fresh); try ProjectStore.save(project, to: fresh)
  check("Documents created with 0.7 features get no legacy copy", !FileManager.default.fileExists(atPath: ProjectStore.legacyCopyURL(for: fresh).path))
  check("Unknown future schema is refused with a clear message", {
   var object = try! JSONSerialization.jsonObject(with: Data(contentsOf: doc)) as! [String: Any]; object["schemaVersion"] = 2
   let future = root.appendingPathComponent("Future.jhcut"); try! JSONSerialization.data(withJSONObject: object).write(to: future)
   do { _ = try ProjectStore.load(from: future); return false } catch { return error.localizedDescription.contains("버전") }
  }())

  // ---- Backups ----
  let backups = root.appendingPathComponent("Backups")
  let docDigest = try sha(doc)
  let folder = try ProjectBackup.create(documentURL: doc, root: backups, appVersion: "0.7.0")
  check("Backup folder holds document, automatic backup and manifest", ["Old.jhcut", "Old.jhcut.backup", "manifest.json"].allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
  check("No half-written staging folder left", ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).allSatisfy { !$0.hasPrefix(".staging") })
  _ = try ProjectBackup.create(documentURL: doc, root: backups, appVersion: "0.7.0")
  let entries = ProjectBackup.list(root: backups)
  check("Backups listed newest first", entries.count == 2 && entries[0].manifest.createdAt >= entries[1].manifest.createdAt)
  let restored = try ProjectBackup.restore(entries[1])
  check("Restore returns the saved project", restored.sequence == project.sequence && restored.glossary == project.glossary && restored.name == project.name)
  check("Original document untouched by backup and restore", try sha(doc) == docDigest)
  let tampered = entries[0].folder.appendingPathComponent("Old.jhcut")
  var bytes = try Data(contentsOf: tampered); bytes[bytes.count / 2] ^= 0x20; try bytes.write(to: tampered)
  check("Damaged backup is refused", (try? ProjectBackup.restore(entries[0])) == nil)
  var withMedia = project; withMedia.assets = [MediaAsset(name: "사라진 영상", path: root.appendingPathComponent("gone.mov").path, kind: .video, duration: MediaTime(seconds: 5))]
  let mediaDoc = root.appendingPathComponent("Media.jhcut"); try ProjectStore.save(withMedia, to: mediaDoc)
  let mediaFolder = try ProjectBackup.create(documentURL: mediaDoc, root: backups, appVersion: "0.7.0")
  let mediaEntry = ProjectBackup.list(root: backups).first { $0.folder.lastPathComponent == mediaFolder.lastPathComponent }
  check("Restore reports media that no longer exist", mediaEntry.map { ProjectBackup.missingMedia($0).count == 1 } == true)

  // Editor: restore opens as a new unsaved document, nothing overwritten.
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.backupRoot = backups
  model.load(doc)
  model.createProjectBackup()
  check("Editor backup of the open document", model.error == nil && model.message.contains("백업 완료"), model.error ?? model.message)
  model.refreshBackups()
  guard let newest = model.backupEntries.first(where: { $0.manifest.documentName == "Old.jhcut" && (try? ProjectBackup.restore($0)) != nil }) else { check("Editor lists backups", false); return }
  model.restoreBackup(newest)
  check("Editor restore opens an unsaved copy", model.documentURL == nil && model.project.sequence == project.sequence && model.message.contains("새 문서"), model.error ?? model.message)
  check("Original still intact after editor restore", try sha(doc) == docDigest)

  // ---- Versions ----
  let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil) as! [String: Any]
  let version = plist["CFBundleShortVersionString"] as? String ?? ""
  let readme = try String(contentsOf: URL(fileURLWithPath: "README.md"), encoding: .utf8), status = try String(contentsOf: URL(fileURLWithPath: "docs/STATUS.md"), encoding: .utf8)
  check("App version is 0.7.x", version.hasPrefix("0.7."), version)
  check("README and STATUS name the app version", readme.contains("JH CUT Studio \(version.split(separator: ".").prefix(2).joined(separator: "."))") && status.contains(version))

  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("DISTRIBUTION_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

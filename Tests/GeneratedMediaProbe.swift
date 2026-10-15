import Foundation
import AppKit
import AVFoundation
import CoreImage
import JHCutCore

/// Step 16: lifetime of generated media (freeze stills, reversed copies, SDR copies, mixes): records, reference
/// protection through Undo/Redo and saved documents, confirmed cleanup, collection without the generated folder,
/// and relinking that never accepts a different file with the same name.
@main struct GeneratedMediaProbe {
 static func makeVideo(_ url: URL, seconds: Double = 4) async throws {
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
   AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
  writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
  let ctx = CIContext(); let fps = 30.0
  for k in 0..<Int(seconds * fps) {
   while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
   let v = 24 + 200 * Double(k) / (seconds * fps)
   var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
   ctx.render(CIImage(color: CIColor(red: v / 255, green: v / 255, blue: v / 255)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)), to: buffer!)
   adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps)))
  }
  input.markAsFinished(); await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? ProjectError("검증 영상 생성 실패") }
 }
 static func luma(_ image: CGImage) -> Double {
  var px = [UInt8](repeating: 0, count: 4)
  let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return Double(px[0])
 }

 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/GeneratedMedia")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  let fm = FileManager.default

  let video = root.appendingPathComponent("source.mp4"); try await makeVideo(video)
  var source = try await MediaImporter.inspect(url: video); source.contentHash = try await FileIdentity.sha256(video)
  let sourceHash = source.contentHash
  let generated = root.appendingPathComponent("Generated"), trashDir = root.appendingPathComponent("FakeTrash")
  try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
  func fakeTrash(_ url: URL) throws { try fm.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent)) }
  func makeProject() -> Project {
   var p = Project(name: "생성물 수명"); p.sequence.width = 640; p.sequence.height = 360; p.assets = [source]
   p.sequence.tracks[0].clips = [Clip(name: "장면", assetID: source.id, start: .zero, duration: MediaTime(seconds: 4))]
   return p
  }
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  model.generatedMediaRoot = generated
  let base = makeProject(); model.history = EditorHistory(project: base)
  let document = root.appendingPathComponent("Doc/Project.jhcut")
  try fm.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
  try ProjectStore.save(base, to: document)
  model.documentURL = document; model.mediaBaseURL = document
  let clipID = base.sequence.tracks[0].clips[0].id
  func wait() async throws { while model.productivityBusy { try await Task.sleep(nanoseconds: 20_000_000) } }
  func generatedAssets() -> [MediaAsset] { model.project.assets.filter { $0.id != source.id } }
  func scan() async throws -> GeneratedMediaReport { try await GeneratedMediaCleanup.scan(folder: generated, projectID: base.id, references: model.generatedMediaReferences()) }

  // ---- Creation writes records ----
  model.selectedClipID = clipID; model.selectedClipIDs = [clipID]; model.playhead = 2
  model.makeFreezeFrame(seconds: 1); try await wait()
  model.selectedClipID = model.project.sequence.tracks[0].clips[0].id; model.selectedClipIDs = [model.selectedClipID!]
  model.reverseSelectedClip(); try await wait()
  var made = generatedAssets()
  check("Freeze frame and reverse copy were created", made.count == 2, "\(made.map(\.name)) \(model.error ?? "")")
  guard made.count == 2 else { print("GENERATED_MEDIA_RESULT aborted"); exit(1) }
  let freeze = made.first { $0.kind == .image }!, reversed = made.first { $0.kind == .video }!
  let freezeRecord = GeneratedMediaRegistry.record(for: URL(fileURLWithPath: freeze.path)), reverseRecord = GeneratedMediaRegistry.record(for: URL(fileURLWithPath: reversed.path))
  check("Each file has a record naming purpose, project and source", freezeRecord?.purpose == .freezeFrame && reverseRecord?.purpose == .reversed && freezeRecord?.projectID == base.id && reverseRecord?.projectID == base.id && reverseRecord?.sourceSHA256 == sourceHash && reverseRecord?.sourceDuration != nil)
  check("Record SHA-256 equals the file and the asset's content hash", try await FileIdentity.sha256(URL(fileURLWithPath: freeze.path)) == freezeRecord?.sha256 && freeze.contentHash == freezeRecord?.sha256 && reversed.contentHash == reverseRecord?.sha256)
  model.prepareMedia(audioOnly: false, sourceURL: video, outputDirectory: generated); try await wait()
  made = generatedAssets()
  let sdr = made.first { $0.name.contains("SDR 사본") }
  check("SDR copy is recorded with its hash", sdr != nil && GeneratedMediaRegistry.record(for: URL(fileURLWithPath: sdr!.path))?.purpose == .sdrCopy && sdr?.contentHash != nil, model.error ?? "")
  check("Missing generated files get a plain-words hint, imported media do not", model.missingMediaHint(for: freeze) != nil && model.missingMediaHint(for: reversed) != nil && model.missingMediaHint(for: source) == nil)

  // ---- Everything used by the open document is protected ----
  var report = try await scan()
  check("Files used by the open document are 'in use', none removable", report.inUse.count == 3 && report.removable.isEmpty && report.uncertain.isEmpty, report.summary)

  // ---- Undo keeps them referenced; clearing history releases only unsaved ones ----
  let withAll = model.project
  model.undo(); model.undo(); model.undo()
  check("After three undos the document no longer uses them", generatedAssets().isEmpty)
  report = try await scan()
  check("Undo/Redo still references them: nothing removable", report.inUse.count == 3 && report.removable.isEmpty, report.summary)
  model.redo(); model.redo(); model.redo()
  check("Redo works: files were not touched", model.project == withAll && made.allSatisfy { fm.fileExists(atPath: $0.path) })
  model.undo(); model.undo(); model.undo()
  model.history.clearHistory()
  report = try await scan()
  check("After history is released the unreferenced files become removable", report.removable.count == 3 && report.inUse.isEmpty, report.summary)

  // ---- A saved document that uses a file protects it ----
  var savedWithReverse = model.project
  savedWithReverse.assets.append(reversed)
  savedWithReverse.sequence.tracks[0].clips.append(Clip(name: "거꾸로", assetID: reversed.id, start: MediaTime(seconds: 4), duration: MediaTime(seconds: 2)))
  try ProjectStore.save(savedWithReverse, to: document)
  report = try await scan()
  check("A file referenced only by the saved document is protected", report.inUse.map { $0.url.lastPathComponent } == [URL(fileURLWithPath: reversed.path).lastPathComponent] && report.removable.count == 2, report.summary)
  // Recovery copy
  try model.recoveryStoreForProbe().save(project: savedWithReverse, documentURL: nil, mediaBaseURL: nil)

  // ---- Not vouched for → uncertain, never removable ----
  let legacy = generated.appendingPathComponent("legacy-copy.mp4"); try fm.copyItem(atPath: reversed.path, toPath: legacy.path)
  let foreignData = Data("foreign".utf8); let foreign = generated.appendingPathComponent("other-project.png"); try foreignData.write(to: foreign)
  _ = try await GeneratedMediaRegistry.register(file: foreign, purpose: .freezeFrame, projectID: UUID())
  let tampered = generated.appendingPathComponent("tampered.png"); try Data("original".utf8).write(to: tampered)
  _ = try await GeneratedMediaRegistry.register(file: tampered, purpose: .freezeFrame, projectID: base.id)
  try Data("changed after the record".utf8).write(to: tampered)
  report = try await scan()
  let uncertainNames = Set(report.uncertain.map { $0.url.lastPathComponent })
  check("No record / other project / changed bytes are uncertain", uncertainNames == ["legacy-copy.mp4", "other-project.png", "tampered.png"], "\(uncertainNames)")

  // ---- Confirmed cleanup removes exactly the removable ones ----
  let freezeURL = URL(fileURLWithPath: freeze.path), sdrURL = URL(fileURLWithPath: sdr!.path), reverseURL = URL(fileURLWithPath: reversed.path)
  let references = model.generatedMediaReferences()
  let removal = try await GeneratedMediaCleanup.remove(report.removable, folder: generated, projectID: base.id, references: { references }, trash: fakeTrash)
  check("Only the two unreferenced files were removed (with their records)", Set(removal.removed.map(\.lastPathComponent)) == [freezeURL.lastPathComponent, sdrURL.lastPathComponent]
        && !fm.fileExists(atPath: freezeURL.path) && !fm.fileExists(atPath: GeneratedMediaRegistry.sidecarURL(for: freezeURL).path), "\(removal.removed.map(\.lastPathComponent))")
  check("The saved document's file and every uncertain file are untouched", fm.fileExists(atPath: reverseURL.path) && fm.fileExists(atPath: legacy.path) && fm.fileExists(atPath: foreign.path) && fm.fileExists(atPath: tampered.path))
  // Late reference between scan and removal
  let late = generated.appendingPathComponent("late.png"); try Data("late".utf8).write(to: late)
  _ = try await GeneratedMediaRegistry.register(file: late, purpose: .freezeFrame, projectID: base.id)
  let lateScan = try await scan()
  var lateProject = model.project
  var lateAsset = freeze; lateAsset.path = late.path; lateAsset.relativePath = nil; lateAsset.id = UUID()
  lateProject.assets.append(lateAsset); model.history = EditorHistory(project: lateProject)
  let lateRemoval = try await GeneratedMediaCleanup.remove(lateScan.removable, folder: generated, projectID: base.id, references: { model.generatedMediaReferences() }, trash: fakeTrash)
  check("A file that became referenced after the scan is skipped", lateRemoval.removed.isEmpty && fm.fileExists(atPath: late.path) && !lateRemoval.skipped.isEmpty)
  // Live references must be checked after the asynchronous hash, not captured before it.
  let racing = generated.appendingPathComponent("reference-race.png")
  try Data("race".utf8).write(to: racing)
  _ = try await GeneratedMediaRegistry.register(file: racing, purpose: .freezeFrame, projectID: base.id)
  var liveReferences = GeneratedMediaReferences()
  let racingScan = try await GeneratedMediaCleanup.scan(folder: generated, projectID: base.id, references: liveReferences)
  let racingItems = racingScan.removable.filter { $0.url == racing }
  let racingRemoval = try await GeneratedMediaCleanup.remove(racingItems, folder: generated, projectID: base.id,
      references: { liveReferences }, beforeRevalidation: { liveReferences.add(racing) }, trash: fakeTrash)
  check("Reference added after hashing protects the file at final removal", racingItems.count == 1 && racingRemoval.removed.isEmpty && racingRemoval.skipped.count == 1 && fm.fileExists(atPath: racing.path))
  liveReferences = GeneratedMediaReferences()
  let gapRemoval = try await GeneratedMediaCleanup.remove(racingItems, folder: generated, projectID: base.id,
      references: { liveReferences }, beforeRevalidation: { liveReferences.gaps.append("unreadable after hashing") }, trash: fakeTrash)
  check("Reference read failure after hashing protects the file", gapRemoval.removed.isEmpty && gapRemoval.skipped.count == 1 && fm.fileExists(atPath: racing.path))

  // Exercise the actual app cleanup job. Mutate only isolated fixtures at its final checkpoint.
  for action in ["reference", "document", "cancel", "success"] {
   let isolated = root.appendingPathComponent("Cleanup-" + action)
   let owned = isolated.appendingPathComponent("Generated")
   try fm.createDirectory(at: owned, withIntermediateDirectories: true)
   let file = owned.appendingPathComponent("candidate.data"); try Data(action.utf8).write(to: file)
   let editor = EditorModel(recoveryStore: RecoveryStore(directory: isolated.appendingPathComponent("Recovery")), exportHistoryURL: isolated.appendingPathComponent("journal.json"))
   editor.history = EditorHistory(project: base); editor.generatedMediaRoot = owned
   _ = try await GeneratedMediaRegistry.register(file: file, purpose: .freezeFrame, projectID: base.id)
   editor.generatedMediaReport = try await GeneratedMediaCleanup.scan(folder: owned, projectID: base.id, references: editor.generatedMediaReferences())
   var trashed: [URL] = []; var checkpoint = false
   editor.generatedMediaTrash = { url in trashed.append(url); try fm.moveItem(at: url, to: isolated.appendingPathComponent(url.lastPathComponent)) }
   editor.asyncJobBarrier = { stage in
    guard stage == "generatedMedia.beforeRevalidation" else { return }; checkpoint = true
    switch action {
    case "reference":
     var changed = editor.project; var asset = source; asset.id = UUID(); asset.path = file.path; asset.relativePath = nil; asset.bookmark = nil
     changed.assets.append(asset); editor.history = EditorHistory(project: changed)
    case "document": editor.invalidateAsyncJobs(); editor.history = EditorHistory(project: Project(name: "Other document"))
    case "cancel": editor.cancelProductivity()
    default: break
    }
   }
   editor.cleanGeneratedMedia(confirm: false)
   let job = editor.productivityTask
   check("Cleanup owns a tracked cancellable job: " + action, job != nil && editor.productivityBusy)
   await job?.value
   await editor.generatedMediaScanTask?.value
   if action == "success" {
    check("App cleanup moves only the owned file and its record", checkpoint && trashed.count == 2 && !fm.fileExists(atPath: file.path) && !editor.productivityBusy)
   } else {
    check("App cleanup preserves file after " + action, checkpoint && trashed.isEmpty && fm.fileExists(atPath: file.path) && !editor.productivityBusy)
   }
  }
  // Older generations may retain assets that the latest project no longer uses.
  let retentionRoot = root.appendingPathComponent("Retention")
  let retentionFolder = retentionRoot.appendingPathComponent("Generated")
  try fm.createDirectory(at: retentionFolder, withIntermediateDirectories: true)
  let retainedFile = retentionFolder.appendingPathComponent("retained.data"); try Data("retained".utf8).write(to: retainedFile)
  _ = try await GeneratedMediaRegistry.register(file: retainedFile, purpose: .freezeFrame, projectID: base.id)
  var retainedAsset = source; retainedAsset.id = UUID(); retainedAsset.path = retainedFile.path; retainedAsset.relativePath = nil; retainedAsset.bookmark = nil
  var oldState = base; oldState.assets.append(retainedAsset)
  let retainedRecovery = RecoveryStore(directory: retentionRoot.appendingPathComponent("Recovery"))
  let retentionModel = EditorModel(recoveryStore: retainedRecovery, exportHistoryURL: retentionRoot.appendingPathComponent("journal.json"))
  retentionModel.history = EditorHistory(project: base); retentionModel.generatedMediaRoot = retentionFolder; retentionModel.backupRoot = retentionRoot.appendingPathComponent("Backups")
  try retainedRecovery.save(project: oldState, documentURL: nil, mediaBaseURL: nil)
  try retainedRecovery.save(project: base, documentURL: nil, mediaBaseURL: nil)
  check("Recovery picker remains deduplicated but retention includes both generations", try retainedRecovery.availableSnapshots().count == 1 && retainedRecovery.allSnapshotsForMediaRetention().count == 2)
  check("Previous recovery alone protects a generated file", retentionModel.generatedMediaReferences().paths.contains(GeneratedMediaReferences.canonical(retainedFile)))
  let goodPrevious = try Data(contentsOf: retainedRecovery.backupURL)
  try Data("corrupt previous".utf8).write(to: retainedRecovery.backupURL)
  let partialReferences = retentionModel.generatedMediaReferences()
  let partialReport = try await GeneratedMediaCleanup.scan(folder: retentionFolder, projectID: base.id, references: partialReferences)
  check("One damaged recovery blocks cleanup even with a valid current snapshot", try retainedRecovery.availableSnapshots().count == 1 && !partialReferences.gaps.isEmpty && partialReport.removable.isEmpty)
  try goodPrevious.write(to: retainedRecovery.backupURL)
  try retainedRecovery.clear()

  let retainedDocument = retentionRoot.appendingPathComponent("Saved.jhcut")
  try ProjectStore.save(oldState, to: retainedDocument); try ProjectStore.save(base, to: retainedDocument)
  retentionModel.documentURL = retainedDocument; retentionModel.mediaBaseURL = retainedDocument
  check("Previous saved document alone protects a generated file", retentionModel.generatedMediaReferences().paths.contains(GeneratedMediaReferences.canonical(retainedFile)))
  let legacySaved = ProjectStore.beforeCaptionRolesURL(for: retainedDocument)
  try fm.copyItem(at: ProjectStore.backupURL(for: retainedDocument), to: legacySaved)
  try ProjectStore.save(base, to: retainedDocument)
  check("Immutable migration copy alone protects a generated file", retentionModel.generatedMediaReferences().paths.contains(GeneratedMediaReferences.canonical(retainedFile)))
  try fm.removeItem(at: legacySaved)

  try ProjectStore.save(oldState, to: retainedDocument); try ProjectStore.save(base, to: retainedDocument)
  _ = try ProjectBackup.create(documentURL: retainedDocument, root: retentionModel.backupRoot, appVersion: "retention-probe")
  retentionModel.documentURL = nil; retentionModel.mediaBaseURL = nil
  let backupEntry = ProjectBackup.list(root: retentionModel.backupRoot).first!
  check("Backup prior generation protects media absent from latest manifest", !backupEntry.manifest.mediaPaths.contains(retainedFile.path) && retentionModel.generatedMediaReferences().paths.contains(GeneratedMediaReferences.canonical(retainedFile)))
  // Saved copies are not enumerable: once published, a generated file stays protected.
  let publishedFolder = root.appendingPathComponent("Published/Generated")
  try fm.createDirectory(at: publishedFolder, withIntermediateDirectories: true)
  let publishedFile = publishedFolder.appendingPathComponent("saved-copy.data"); try Data("saved copy".utf8).write(to: publishedFile)
  _ = try await GeneratedMediaRegistry.register(file: publishedFile, purpose: .freezeFrame, projectID: base.id)
  let unreferenced = GeneratedMediaReferences()
  let publishedScan = try await GeneratedMediaCleanup.scan(folder: publishedFolder, projectID: base.id, references: unreferenced)
  var publishedProject = base; var publishedAsset = retainedAsset; publishedAsset.id = UUID(); publishedAsset.path = publishedFile.path
  publishedProject.assets.append(publishedAsset)
  let otherDocument = root.appendingPathComponent("Published/Elsewhere.jhcut")
  try ProjectStore.save(publishedProject, to: otherDocument)
  let finderCopy = root.appendingPathComponent("Published/FinderCopy.jhcut"); try fm.copyItem(at: otherDocument, to: finderCopy)
  try fm.removeItem(at: otherDocument)
  let publishedRemoval = try await GeneratedMediaCleanup.remove(publishedScan.removable, folder: publishedFolder, projectID: base.id, references: { unreferenced }, trash: fakeTrash)
  let reopenedFinderCopy = try ProjectStore.load(from: finderCopy)
  check("Save As and an unknown Finder copy protect the file with no live document references", publishedScan.removable.count == 1 && publishedRemoval.removed.isEmpty && fm.fileExists(atPath: publishedFile.path) && reopenedFinderCopy.assets.contains { $0.path == publishedFile.path })
  try fm.removeItem(at: finderCopy)
  check("Deleting a known document cannot clear protection of possible copies", GeneratedMediaRegistry.record(for: publishedFile)?.publishedToDocument == true)

  let duringHash = publishedFolder.appendingPathComponent("saved-during-hash.data"); try Data("late save".utf8).write(to: duringHash)
  _ = try await GeneratedMediaRegistry.register(file: duringHash, purpose: .freezeFrame, projectID: base.id)
  let duringScan = try await GeneratedMediaCleanup.scan(folder: publishedFolder, projectID: base.id, references: unreferenced)
  let duringRemoval = try await GeneratedMediaCleanup.remove(duringScan.removable, folder: publishedFolder, projectID: base.id, references: { unreferenced }, beforeRevalidation: { try GeneratedMediaRegistry.protectForSavedDocument(duringHash) }, trash: fakeTrash)
  check("Publication after hashing is protected even without a live reference", duringScan.removable.count == 1 && duringRemoval.removed.isEmpty && duringRemoval.skipped.count == 1 && fm.fileExists(atPath: duringHash.path))

  let recordEncoder = JSONEncoder(); recordEncoder.dateEncodingStrategy = .iso8601
  for version in [1, 3] {
   let file = publishedFolder.appendingPathComponent("schema-\(version).data"); try Data("unknown history".utf8).write(to: file)
   var record = try await GeneratedMediaRegistry.register(file: file, purpose: .freezeFrame, projectID: base.id); record.schemaVersion = version
   try recordEncoder.encode(record).write(to: GeneratedMediaRegistry.sidecarURL(for: file))
   let result = try await GeneratedMediaCleanup.scan(folder: publishedFolder, projectID: base.id, references: unreferenced)
   check("Unknown publication history is never removable: schema \(version)", result.uncertain.contains { $0.url == file } && !result.removable.contains { $0.url == file })
  }
  let wrongSize = publishedFolder.appendingPathComponent("wrong-size.data"); try Data("size".utf8).write(to: wrongSize)
  var wrongRecord = try await GeneratedMediaRegistry.register(file: wrongSize, purpose: .freezeFrame, projectID: base.id); wrongRecord.byteCount += 1
  try recordEncoder.encode(wrongRecord).write(to: GeneratedMediaRegistry.sidecarURL(for: wrongSize))
  let wrongSizeReport = try await GeneratedMediaCleanup.scan(folder: publishedFolder, projectID: base.id, references: unreferenced)
  check("Matching digest with inconsistent byte count is uncertain", wrongSizeReport.uncertain.contains { $0.url == wrongSize })
  for mutation in ["bytes", "replace", "symlink"] {
   let folder = root.appendingPathComponent("LateContent-" + mutation); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
   let file = folder.appendingPathComponent("candidate.data"); try Data("original".utf8).write(to: file)
   _ = try await GeneratedMediaRegistry.register(file: file, purpose: .freezeFrame, projectID: base.id)
   let report = try await GeneratedMediaCleanup.scan(folder: folder, projectID: base.id, references: unreferenced)
   let target = root.appendingPathComponent("outside-" + mutation + ".data"); try Data("external".utf8).write(to: target)
   var trashCalls = 0
   let removal = try await GeneratedMediaCleanup.remove(report.removable, folder: folder, projectID: base.id, references: { unreferenced }, beforeRevalidation: {
    switch mutation {
    case "bytes": try Data("modified".utf8).write(to: file)
    case "replace": try fm.removeItem(at: file); try Data("original".utf8).write(to: file)
    default: try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: target)
    }
   }, trash: { _ in trashCalls += 1 })
   let outsideBytes = try Data(contentsOf: target)
   check("Late file mutation never reaches Trash: " + mutation, report.removable.count == 1 && removal.removed.isEmpty && removal.skipped.count == 1 && trashCalls == 0 && fm.fileExists(atPath: file.path) && outsideBytes == Data("external".utf8))
  }
  // Unreadable saved document → nothing removable
  try fm.moveItem(at: document, to: document.deletingLastPathComponent().appendingPathComponent("moved.jhcut"))
  let gapReport = try await scan()
  check("With a reference source unreadable nothing is offered for removal", gapReport.removable.isEmpty && !model.generatedMediaReferences().gaps.isEmpty, gapReport.summary)
  try fm.moveItem(at: document.deletingLastPathComponent().appendingPathComponent("moved.jhcut"), to: document)

  // ---- Collection without the generated folder ----
  var collectable = model.project
  collectable.assets = [source, reversed]
  collectable.sequence.tracks[0].clips = [Clip(name: "장면", assetID: source.id, start: .zero, duration: MediaTime(seconds: 2)),
                                          Clip(name: "거꾸로", assetID: reversed.id, start: MediaTime(seconds: 2), duration: MediaTime(seconds: 2))]
  var stillAsset = freeze
  // The still was moved to the fake trash above: bring it back as a plain file so it can be collected too.
  let stillCopy = root.appendingPathComponent("StillCopy/still.png"); try fm.createDirectory(at: stillCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fm.copyItem(at: trashDir.appendingPathComponent(freezeURL.lastPathComponent), to: stillCopy)
  stillAsset.path = stillCopy.path; stillAsset.relativePath = nil
  collectable.assets.append(stillAsset)
  collectable.sequence.tracks[0].clips.append(Clip(name: "정지", assetID: stillAsset.id, start: MediaTime(seconds: 4), duration: MediaTime(seconds: 1)))
  let collected = root.appendingPathComponent("Collected")
  let collectedDocument = try ProjectCollector.collect(project: collectable, documentURL: nil, to: collected)
  check("Generated files were collected with verified hashes", fm.fileExists(atPath: collected.appendingPathComponent("Collection.json").path) && collectedDocument.lastPathComponent == "Project.jhcut")
  let moved = root.appendingPathComponent("Moved/Collected")
  try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fm.moveItem(at: collected, to: moved)
  try fm.removeItem(at: generated); try fm.removeItem(at: stillCopy.deletingLastPathComponent())
  let movedDocument = moved.appendingPathComponent("Project.jhcut")
  let reopened = try ProjectStore.load(from: movedDocument)
  let allPresent = reopened.assets.allSatisfy { fm.fileExists(atPath: $0.resolvedURL(relativeTo: movedDocument).path) }
  check("Moved collection opens with the generated folder gone: every media file resolves inside it", allPresent && reopened.assets.count == 3)
  let output = root.appendingPathComponent("collected-out.mp4")
  try await ExportJob().export(plan: try await TimelineRenderer.build(project: reopened, documentURL: movedDocument), to: output) { _ in }
  let outAsset = try await MediaImporter.inspect(url: output)
  check("Output from the moved collection has the full length", abs(outAsset.duration.seconds - 5) < 0.2, String(format: "%.2f s", outAsset.duration.seconds))
  let gen = AVAssetImageGenerator(asset: AVURLAsset(url: output)); gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
  let stillPicture = luma(try gen.copyCGImage(at: CMTime(seconds: 4.5, preferredTimescale: 600), actualTime: nil))
  let reversedStart = luma(try gen.copyCGImage(at: CMTime(seconds: 2.1, preferredTimescale: 600), actualTime: nil))
  let reversedEnd = luma(try gen.copyCGImage(at: CMTime(seconds: 3.9, preferredTimescale: 600), actualTime: nil))
  // The reversed copy holds source 0–2 s (brightness 24 → 124), so it runs bright → dark; the still is source 2 s (≈124).
  check("Collected reverse clip runs bright to dark and the still shows its source frame", reversedStart > reversedEnd + 60 && abs(stillPicture - 127) < 25, String(format: "reverse %.0f → %.0f, still %.0f", reversedStart, reversedEnd, stillPicture))

  // ---- Collector refuses a file whose bytes changed after it was recorded ----
  let changed = root.appendingPathComponent("Changed/media.mp4"); try fm.createDirectory(at: changed.deletingLastPathComponent(), withIntermediateDirectories: true)
  try fm.copyItem(at: video, to: changed)
  var changedAsset = source; changedAsset.path = changed.path; changedAsset.relativePath = nil; changedAsset.bookmark = nil
  var changedProject = makeProject(); changedProject.assets = [changedAsset]
  let handle = try FileHandle(forWritingTo: changed); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
  let refusedTarget = root.appendingPathComponent("RefusedCollection")
  var refused = false
  do { _ = try ProjectCollector.collect(project: changedProject, documentURL: nil, to: refusedTarget) } catch { refused = true }
  check("Changed file is refused and no half-written folder is left", refused && !fm.fileExists(atPath: refusedTarget.path))

  // ---- Relinking: same name + different bytes is never connected ----
  let relinkFolder = root.appendingPathComponent("RelinkFolder"); try fm.createDirectory(at: relinkFolder, withIntermediateDirectories: true)
  var lost = reversed; lost.path = root.appendingPathComponent("Gone/\(reverseURL.lastPathComponent)").path; lost.relativePath = nil
  try fm.copyItem(at: moved.appendingPathComponent(reopened.assets.first { $0.kind == .video && $0.id == reversed.id }!.relativePath!), to: relinkFolder.appendingPathComponent(reverseURL.lastPathComponent))
  let exact = try await FolderRelinking.replacements(for: [lost], folder: relinkFolder)
  check("Same name and same bytes: connected", exact.count == 1 && exact[0].id == lost.id)
  try fm.removeItem(at: relinkFolder.appendingPathComponent(reverseURL.lastPathComponent))
  try await makeVideo(relinkFolder.appendingPathComponent(reverseURL.lastPathComponent), seconds: 3)
  let wrong = try await FolderRelinking.replacements(for: [lost], folder: relinkFolder)
  check("Same name but different bytes: not connected", wrong.isEmpty)

  check("Source video is byte-identical after everything", try await FileIdentity.sha256(video) == sourceHash)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("GENERATED_MEDIA_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}
extension EditorModel {
 @MainActor func recoveryStoreForProbe() -> RecoveryStore { recoveryStore }
}

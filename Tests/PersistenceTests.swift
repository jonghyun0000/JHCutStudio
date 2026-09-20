import XCTest
@testable import JHCutCore

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("JH CUT 저장 테스트 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    private func writeMedia(in folder: URL, name: String = "같은 이름.png") throws -> MediaAsset {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return MediaAsset(name: name, path: url.path, kind: .image)
    }
    func testSaveLoadRelativePathsKoreanNamesAndSameNameMedia() throws {
        var project = Project(name: "종현의 첫 영상")
        project.assets = [try writeMedia(in: directory.appendingPathComponent("가 폴더")), try writeMedia(in: directory.appendingPathComponent("나 폴더"))]
        project.sequence.tracks[0].clips = [Clip(assetID: project.assets[0].id)]
        project.sequence.tracks[1].clips = [Clip(assetID: project.assets[1].id)]
        project.sequence.tracks[2].clips = [Clip(title: Title(text: "한글 이름 · 띄어쓰기"))]
        let url = directory.appendingPathComponent("종현 프로젝트.jhcut")
        try ProjectStore.save(project, to: url)
        let loaded = try ProjectStore.load(from: url)
        XCTAssertEqual(loaded.name, project.name)
        XCTAssertEqual(loaded.sequence, project.sequence)
        XCTAssertEqual(loaded.assets.map(\.relativePath), ["가 폴더/같은 이름.png", "나 폴더/같은 이름.png"])
        XCTAssertNotEqual(loaded.assets[0].resolvedURL(relativeTo: url), loaded.assets[1].resolvedURL(relativeTo: url))
    }
    func testMovedFolderFindsRelativeSourcesBeforeOldAbsolutePaths() throws {
        let original = directory.appendingPathComponent("원본"), moved = directory.appendingPathComponent("복사본")
        var project = Project()
        project.assets = [try writeMedia(in: original.appendingPathComponent("미디어"))]
        let url = original.appendingPathComponent("작업.jhcut")
        try ProjectStore.save(project, to: url)
        try FileManager.default.copyItem(at: original, to: moved)
        let movedDocument = moved.appendingPathComponent("작업.jhcut")
        let loaded = try ProjectStore.load(from: movedDocument)
        XCTAssertEqual(loaded.assets[0].path, moved.appendingPathComponent("미디어/같은 이름.png").path)
        let newURL = directory.appendingPathComponent("다른 이름.jhcut")
        try ProjectStore.save(loaded, to: newURL)
        XCTAssertEqual(try ProjectStore.load(from: newURL).assets[0].relativePath, "복사본/미디어/같은 이름.png")
    }
    func testAtomicBackupAndExplicitRecoveryPreserveLastGoodDocument() throws {
        let url = directory.appendingPathComponent("작업.jhcut")
        var project = Project(name: "첫 번째")
        try ProjectStore.save(project, to: url)
        let firstBytes = try Data(contentsOf: url)
        project.name = "두 번째"
        try ProjectStore.save(project, to: url)
        XCTAssertEqual(try Data(contentsOf: ProjectStore.backupURL(for: url)), firstBytes)
        XCTAssertEqual(try ProjectStore.load(from: url).name, "두 번째")
        try Data("{손상된 문서".utf8).write(to: url)
        XCTAssertThrowsError(try ProjectStore.load(from: url))
        XCTAssertThrowsError(try ProjectStore.save(project, to: url))
        XCTAssertEqual(try Data(contentsOf: ProjectStore.backupURL(for: url)), firstBytes)
        XCTAssertEqual(try ProjectStore.recover(from: url).name, "첫 번째")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{손상된 문서")
    }
    func testFailedValidationOrWriteCannotOverwriteExistingDocument() throws {
        let url = directory.appendingPathComponent("작업.jhcut")
        let project = Project(name: "유지")
        try ProjectStore.save(project, to: url)
        let before = try Data(contentsOf: url)
        var invalid = project; invalid.sequence.width = -1
        XCTAssertThrowsError(try ProjectStore.save(invalid, to: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try ProjectStore.save(project, to: directory.appendingPathComponent("없는 폴더/작업.jhcut")))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testMissingMediaRemainsVisibleForRelinkingAndDoesNotPreventOpening() throws {
        var project = Project()
        project.assets = [MediaAsset(name: "외장 영상.mp4", path: directory.appendingPathComponent("없는 영상.mp4").path, kind: .video, duration: MediaTime(5, 1))]
        project.sequence.tracks[0].clips = [Clip(assetID: project.assets[0].id)]
        let url = directory.appendingPathComponent("누락.jhcut")
        try ProjectStore.save(project, to: url)
        let loaded = try ProjectStore.load(from: url)
        XCTAssertEqual(loaded.assets[0].id, project.assets[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: loaded.assets[0].resolvedURL(relativeTo: url).path))
    }
    func testSaveAsDoesNotRelinkMissingSourceToUnrelatedSameNameFile() throws {
        let originalFolder = directory.appendingPathComponent("원본")
        let destinationFolder = directory.appendingPathComponent("새 위치")
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        let missing = originalFolder.appendingPathComponent("같은 이름.png")
        _ = try writeMedia(in: destinationFolder)
        var project = Project()
        project.assets = [MediaAsset(name: missing.lastPathComponent, path: missing.path, relativePath: "같은 이름.png", kind: .image)]
        let savedAs = destinationFolder.appendingPathComponent("작업.jhcut")
        try ProjectStore.save(project, to: savedAs)
        let loaded = try ProjectStore.load(from: savedAs)
        XCTAssertEqual(loaded.assets[0].path, missing.path)
        XCTAssertEqual(loaded.assets[0].relativePath, "../원본/같은 이름.png")
    }
}

final class CollectionAndCompatibilityTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("JH 수집 \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func makeAsset(_ name: String, bytes: [UInt8]) throws -> MediaAsset {
        let source = folder.appendingPathComponent("원본", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = source.appendingPathComponent(name); try Data(bytes).write(to: url)
        return MediaAsset(name: name, path: url.path, kind: .image)
    }
    func testPortableCollectionCopiesOriginalsDeduplicatesAndIncludesDerivedOnlyAssets() throws {
        var project = Project(name: "휴대용 프로젝트")
        project.assets = [try makeAsset("동일 내용 하나.png", bytes: [1,2,3]), try makeAsset("동일 내용 둘.png", bytes: [1,2,3]), try makeAsset("파생 전용.png", bytes: [4,5,6])]
        project.sequence.tracks[0].clips = [Clip(assetID: project.assets[0].id)]
        var derived = JHCutCore.Sequence(name: "가로 버전", width: 1920, height: 1080)
        derived.tracks[0].clips = [Clip(assetID: project.assets[2].id)]
        project.derivedSequences = [derived]
        let destination = folder.appendingPathComponent("수집 폴더")
        let url = try ProjectCollector.collect(project: project, to: destination)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: project.assets[0].path)), Data([1,2,3]))
        let loaded = try ProjectStore.load(from: url)
        XCTAssertEqual(loaded.assets[0].relativePath, loaded.assets[1].relativePath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Media").path).count, 2)
        XCTAssertEqual(loaded.derivedSequences, project.derivedSequences)
        XCTAssertTrue(loaded.assets.allSatisfy { FileManager.default.fileExists(atPath: $0.resolvedURL(relativeTo: url).path) })
        let manifest = try JSONDecoder().decode(ProjectCollectionManifest.self, from: Data(contentsOf: destination.appendingPathComponent("Collection.json")))
        XCTAssertEqual(manifest.media.count, 3); XCTAssertEqual(manifest.media[0].sha256, manifest.media[1].sha256)
        XCTAssertThrowsError(try ProjectCollector.collect(project: project, to: destination))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("원본"))
        let moved = folder.appendingPathComponent("이동한 수집 폴더")
        try FileManager.default.moveItem(at: destination, to: moved)
        let movedURL = moved.appendingPathComponent("Project.jhcut")
        XCTAssertTrue(try ProjectStore.load(from: movedURL).assets.allSatisfy { FileManager.default.fileExists(atPath: $0.resolvedURL(relativeTo: movedURL).path) })
    }
    func testFailedCollectionCleansOnlyOwnedStagingAndLeavesOriginals() throws {
        var project = Project()
        let source = try makeAsset("유지.png", bytes: [7,8,9])
        project.assets = [source, MediaAsset(name: "없는 원본", path: folder.appendingPathComponent("missing.png").path, kind: .image)]
        let destination = folder.appendingPathComponent("실패할 수집")
        let unrelated = folder.appendingPathComponent("유지할 파일.txt"); try Data([10]).write(to: unrelated)
        XCTAssertThrowsError(try ProjectCollector.collect(project: project, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path)), Data([7,8,9]))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([10]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".jhcut-collect-") })
    }
    func testUnknownNestedEditingFieldsCannotBeSilentlyOpenedOrOverwritten() throws {
        var project = Project(); project.sequence.tracks[2].clips = [Clip(title: Title(text: "기존 자막"))]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        var sequence = try XCTUnwrap(json["sequence"] as? [String: Any])
        var tracks = try XCTUnwrap(sequence["tracks"] as? [[String: Any]])
        var clips = try XCTUnwrap(tracks[2]["clips"] as? [[String: Any]])
        clips[0]["futureWarp"] = ["intensity": 0.5]
        tracks[2]["clips"] = clips; sequence["tracks"] = tracks; json["sequence"] = sequence
        let bytes = try JSONSerialization.data(withJSONObject: json), url = folder.appendingPathComponent("새 버전.jhcut")
        try bytes.write(to: url)
        XCTAssertThrowsError(try ProjectStore.load(from: url)) { XCTAssertTrue($0.localizedDescription.contains("futureWarp")) }
        XCTAssertThrowsError(try ProjectStore.save(project, to: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}

extension CollectionAndCompatibilityTests {
    func testCancelledCollectionNeverCommitsDestinationOrChangesOriginal() throws {
        let source = try makeAsset("취소 테스트.png", bytes: [1,2,3])
        var project = Project(); project.assets = [source]
        let destination = folder.appendingPathComponent("취소할 수집")
        let gate = DispatchSemaphore(value: 0)
        let completed = expectation(description: "cancelled collector")
        let worker = Task.detached { gate.wait(); return try ProjectCollector.collect(project: project, to: destination) }
        worker.cancel(); gate.signal()
        Task {
            do { _ = try await worker.value; XCTFail("Cancelled collection must throw") }
            catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path)), Data([1,2,3]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".jhcut-collect-") })
    }
}

/// Runs on the repository's actual volume, not Foundation's APFS temporaryDirectory.
/// Scripts/test-domain.sh supplies the location so an external ExFAT workspace is covered.
final class WorkspaceVolumeCollectionTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["JHCUT_COLLECTION_TEST_ROOT"] else {
            throw XCTSkip("Set JHCUT_COLLECTION_TEST_ROOT to test the destination filesystem")
        }
        folder = URL(fileURLWithPath: path).appendingPathComponent("workspace-collection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { if let folder { try FileManager.default.removeItem(at: folder) } }
    private func project(byteCount: Int = 4096) throws -> Project {
        let source = folder.appendingPathComponent("한글 원본.png")
        try Data(repeating: 0x5a, count: byteCount).write(to: source)
        var project = Project(name: "외장 볼륨 수집")
        project.assets = [MediaAsset(name: "한글 원본", path: source.path, kind: .image)]
        project.sequence.tracks[0].clips = [Clip(assetID: project.assets[0].id)]
        return project
    }
    private func assertNoStaging() throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".jhcut-collect-") })
    }
    func testActualWorkspaceVolumePortableCollectionAndExistingDestinationProtection() throws {
        var project = try project()
        var duplicate = project.assets[0]; duplicate.id = UUID(); duplicate.name = "중복 원본"
        project.assets.append(duplicate)
        var derived = project.sequence; derived.id = UUID(); derived.name = "파생 시퀀스"
        derived.tracks[0].clips[0].assetID = duplicate.id
        project.derivedSequences = [derived]
        let destination = folder.appendingPathComponent("실제 볼륨 수집")
        let url = try ProjectCollector.collect(project: project, to: destination)
        let loaded = try ProjectStore.load(from: url)
        XCTAssertEqual(loaded.derivedSequences, project.derivedSequences)
        XCTAssertEqual(loaded.assets[0].relativePath, loaded.assets[1].relativePath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Media").path).count, 1)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ProjectCollector.collect(project: project, to: destination))
        XCTAssertEqual(try Data(contentsOf: url), before)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: project.assets[0].path))
        XCTAssertEqual(try Data(contentsOf: loaded.assets[0].resolvedURL(relativeTo: url)), Data(repeating: 0x5a, count: 4096))
        try assertNoStaging()
        print("WORKSPACE_COLLECTION_VOLUME \(folder.deletingLastPathComponent().path)")
    }
    func testRacingCollectorsHaveExactlyOneWinnerAndNeverMixProjects() throws {
        let first = try project()
        var second = first; second.id = UUID(); second.name = "다른 수집 요청"
        let projects = [first, second]
        for iteration in 0..<12 {
            let destination = folder.appendingPathComponent("경쟁-\(iteration)")
            let lock = NSLock()
            var successes: [Int] = [], failures = 0
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                do {
                    _ = try ProjectCollector.collect(project: projects[index], to: destination)
                    lock.lock(); successes.append(index); lock.unlock()
                } catch { lock.lock(); failures += 1; lock.unlock() }
            }
            XCTAssertEqual(successes.count, 1); XCTAssertEqual(failures, 1)
            let winner = try XCTUnwrap(successes.first)
            let document = try ProjectStore.load(from: destination.appendingPathComponent("Project.jhcut"))
            let manifest = try JSONDecoder().decode(ProjectCollectionManifest.self, from: Data(contentsOf: destination.appendingPathComponent("Collection.json")))
            XCTAssertEqual(document.id, projects[winner].id)
            XCTAssertEqual(manifest.projectID, document.id)
        }
        try assertNoStaging()
    }
    func testActualVolumeFailureLeavesNoDestinationAndPreservesUnrelatedData() throws {
        var project = try project()
        project.assets.append(MediaAsset(name: "누락", path: folder.appendingPathComponent("missing.png").path, kind: .image))
        let unrelated = folder.appendingPathComponent("유지.txt"); try Data([8,9]).write(to: unrelated)
        let destination = folder.appendingPathComponent("실패")
        XCTAssertThrowsError(try ProjectCollector.collect(project: project, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([8,9]))
        try assertNoStaging()
    }
    func testExFATCancellationDuringPublicationPreservesForeignFiles() throws {
        let format = try folder.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription ?? ""
        guard format.localizedCaseInsensitiveContains("exfat") else { throw XCTSkip("ExFAT-specific exclusive-copy publication test") }
        let project = try project(byteCount: 64 * 1024 * 1024)
        let destination = folder.appendingPathComponent("중간 취소")
        let worker = Task.detached { try ProjectCollector.collect(project: project, to: destination) }
        // Wait until fallback has exclusively reserved the visible destination. The main test
        // thread then supplies unrelated data and cancels while the large media is copying.
        let deadline = Date().addingTimeInterval(15)
        var copyingAllocatedMedia = false
        while Date() < deadline {
            let media = destination.appendingPathComponent("Media")
            if let names = try? FileManager.default.contentsOfDirectory(atPath: media.path), let name = names.first,
               let attributes = try? FileManager.default.attributesOfItem(atPath: media.appendingPathComponent(name).path),
               let size = attributes[.size] as? Int, size >= 1_048_576 {
                copyingAllocatedMedia = true; break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard copyingAllocatedMedia else { worker.cancel(); return XCTFail("Fallback media was not being copied") }
        let foreign = destination.appendingPathComponent("다른 프로세스.txt")
        try Data([31,32]).write(to: foreign, options: .withoutOverwriting)
        worker.cancel()
        let completed = expectation(description: "cancel during actual ExFAT publication")
        Task {
            do { _ = try await worker.value; XCTFail("Mid-publication cancellation must throw") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
        XCTAssertEqual(try Data(contentsOf: foreign), Data([31,32]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [foreign.lastPathComponent])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: project.assets[0].path)[.size] as? Int, 64 * 1024 * 1024)
        try assertNoStaging()
    }
}

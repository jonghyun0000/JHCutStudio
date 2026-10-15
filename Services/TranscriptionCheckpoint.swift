import Foundation
import CryptoKit
import Darwin

/// Everything that can change what Whisper returns for a window. Two runs share completed windows
/// only when every field matches, so a checkpoint can never leak results from another project,
/// another file, another trim, or another recognition setting into this one.
public struct TranscriptionCheckpointKey: Codable, Equatable, Sendable {
    public static let formatVersion = 3
    public var format: Int = TranscriptionCheckpointKey.formatVersion
    public var projectID: UUID
    public var clipID: UUID
    /// Full SHA-256 of the media file as it exists when the run starts.
    public var mediaSHA256: String
    public var sourceStart: MediaTime
    public var duration: MediaTime
    public var windowSeconds: Double
    public var language: String
    public var channel: Int
    public var glossary: String
    public var accurate: Bool
    public var languageRepairEnabled: Bool?
    public var modelSHA256: String
    public var engine: String
    /// Voice-activity skipping changes which windows reach Whisper, so it is part of the identity.
    public var skipsSilence: Bool
    public var voiceActivityPolicy: String?

    public init(projectID: UUID, clipID: UUID, mediaSHA256: String, sourceStart: MediaTime, duration: MediaTime,
                windowSeconds: Double, options: SpeechOptions, modelSHA256: String, engine: String = LocalTranscription.pipelineVersion,
                skipsSilence: Bool = false, voiceActivityPolicy: VoiceActivityPolicy = .conservative) {
        self.projectID = projectID; self.clipID = clipID; self.mediaSHA256 = mediaSHA256
        self.sourceStart = sourceStart; self.duration = duration; self.windowSeconds = windowSeconds
        self.language = options.language; self.channel = options.channel; self.glossary = options.glossary; self.accurate = options.accurate
        self.languageRepairEnabled = options.languageRepairEnabled
        self.modelSHA256 = modelSHA256; self.engine = engine; self.skipsSilence = skipsSilence
        self.voiceActivityPolicy = skipsSilence ? voiceActivityPolicy.rawValue : nil
    }

    /// Stable directory name. Sorted-key JSON makes the digest independent of property order.
    public var identifier: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public var windowCount: Int {
        guard duration > .zero, duration.seconds <= RecognitionCacheSafety.maximumDuration, windowSeconds.isFinite, (30...3600).contains(windowSeconds) else { return 0 }
        let n = (duration.seconds / windowSeconds).rounded(.up)
        return n.isFinite && n >= 1 && n <= Double(RecognitionCacheSafety.maximumWindows) ? Int(n) : 0
    }
    public var isValid: Bool {
        (1...Self.formatVersion).contains(format) && windowCount > 0 && sourceStart >= .zero && sourceStart.seconds <= RecognitionCacheSafety.maximumStart &&
        (try? sourceStart.adding(duration)) != nil && (try? sourceStart.adding(MediaTime(1,60_000))) != nil && (try? duration.adding(MediaTime(1,60_000))) != nil && RecognitionCacheSafety.hashIsValid(mediaSHA256) && RecognitionCacheSafety.hashIsValid(modelSHA256) &&
        ["ko","en","ja","auto"].contains(language) && (-1...31).contains(channel) && glossary.count <= 500 && engine.utf8.count <= 256 &&
        (!skipsSilence ? voiceActivityPolicy == nil : (voiceActivityPolicy == nil && format == 1 || VoiceActivityPolicy(rawValue:voiceActivityPolicy ?? "") != nil))
    }
    public var isReusable: Bool { isValid && format == Self.formatVersion && languageRepairEnabled != nil && engine == LocalTranscription.pipelineVersion }
    func bounds(for index: Int) -> (start:MediaTime,duration:MediaTime)? {
        guard isValid, index >= 0, index < windowCount else { return nil }
        let offset = MediaTime(seconds:Double(index)*windowSeconds)
        guard let start = try? sourceStart.adding(offset), let remaining = try? duration.subtracting(offset), remaining > .zero else { return nil }
        return (start,min(remaining,MediaTime(seconds:windowSeconds)))
    }
}

/// One completed recognition window. Cue times are absolute source times, exactly as returned by
/// `LocalTranscription.transcribe`.
public struct TranscriptionWindowResult: Codable, Equatable, Sendable {
    public var index: Int
    public var sourceStart: MediaTime
    public var duration: MediaTime
    public var cues: [CaptionCue]
    public var language: String
    public var channel: Int
    public var elapsedSeconds: Double
    /// True when voice-activity analysis found no speech and Whisper was not run for this window.
    public var skippedWithoutSpeech: Bool
    public var completedAt: Date
    /// Repetition-guard results for this window (absent in checkpoints written before the guard).
    public var inputSignature: String?
    public var audioSelection: AudioChannelSelection?
    public var repeatedCuesRemoved: Int?
    public var repetitionSuspects: [Double]?
    /// Coverage-repair results for this window (absent in older checkpoints).
    public var coverageRepairs: Int?
    public var recoveredCues: Int?
    public var languageObservations: [SourceLanguageObservation]?
    public var languageRepairAttempts: [LanguageRepairAttempt]?
    public var languageRepairCost: LanguageRepairCost?
    public init(index: Int, sourceStart: MediaTime, duration: MediaTime, cues: [CaptionCue], language: String, channel: Int,
                elapsedSeconds: Double, skippedWithoutSpeech: Bool = false, completedAt: Date = Date()) {
        self.index = index; self.sourceStart = sourceStart; self.duration = duration; self.cues = cues; self.language = language
        self.channel = channel; self.elapsedSeconds = elapsedSeconds; self.skippedWithoutSpeech = skippedWithoutSpeech; self.completedAt = completedAt
    }
    enum CodingKeys: String, CodingKey { case index, sourceStart, duration, cues, language, channel, elapsedSeconds, skippedWithoutSpeech, completedAt, inputSignature, audioSelection, repeatedCuesRemoved, repetitionSuspects, coverageRepairs, recoveredCues, languageObservations, languageRepairAttempts, languageRepairCost }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        index = try c.decode(Int.self,forKey:.index); sourceStart = try c.decode(MediaTime.self,forKey:.sourceStart); duration = try c.decode(MediaTime.self,forKey:.duration)
        cues = try RecognitionCacheSafety.array(CaptionCue.self,key:"cues",decoder:decoder,maximum:RecognitionCacheSafety.maximumCues)
        language = try c.decode(String.self,forKey:.language); channel = try c.decode(Int.self,forKey:.channel); elapsedSeconds = try c.decode(Double.self,forKey:.elapsedSeconds)
        skippedWithoutSpeech = try c.decode(Bool.self,forKey:.skippedWithoutSpeech); completedAt = try c.decode(Date.self,forKey:.completedAt)
        inputSignature = try c.decodeIfPresent(String.self,forKey:.inputSignature); audioSelection = try c.decodeIfPresent(AudioChannelSelection.self,forKey:.audioSelection)
        repeatedCuesRemoved = try c.decodeIfPresent(Int.self,forKey:.repeatedCuesRemoved)
        repetitionSuspects = c.contains(.repetitionSuspects) ? try RecognitionCacheSafety.array(Double.self,key:"repetitionSuspects",decoder:decoder,maximum:RecognitionCacheSafety.maximumCues) : nil
        languageObservations = c.contains(.languageObservations) ? try RecognitionCacheSafety.array(SourceLanguageObservation.self,key:"languageObservations",decoder:decoder,maximum:128) : nil
        languageRepairAttempts = c.contains(.languageRepairAttempts) ? try RecognitionCacheSafety.array(LanguageRepairAttempt.self,key:"languageRepairAttempts",decoder:decoder,maximum:8) : nil
        languageRepairCost = try c.decodeIfPresent(LanguageRepairCost.self,forKey:.languageRepairCost)
        coverageRepairs = try c.decodeIfPresent(Int.self,forKey:.coverageRepairs); recoveredCues = try c.decodeIfPresent(Int.self,forKey:.recoveredCues)
    }
    func isValid(for key: TranscriptionCheckpointKey, index expected: Int) -> Bool {
        guard let bounds = key.bounds(for:expected), index == expected, sourceStart == bounds.start, duration == bounds.duration,
              elapsedSeconds.isFinite, (0...604_800).contains(elapsedSeconds), completedAt.timeIntervalSince1970.isFinite,
              channel >= 0, channel < 32, cues.count <= RecognitionCacheSafety.maximumCues,
              RecognitionCacheSafety.hashIsValid(inputSignature ?? ""),
              skippedWithoutSpeech ? (key.skipsSilence && cues.isEmpty && language.isEmpty) : (["ko","en","ja"].contains(language) && audioSelection?.matches(requestedChannel:key.channel) == true && audioSelection?.primary == channel),
              [repeatedCuesRemoved,coverageRepairs,recoveredCues].allSatisfy({ $0 == nil || (0...RecognitionCacheSafety.maximumCues).contains($0!) }) else { return false }
        guard let end = try? sourceStart.adding(duration) else { return false }
        guard (languageObservations?.count ?? 0) <= 128, (languageRepairAttempts?.count ?? 0) <= 8,
              languageObservations?.allSatisfy({$0.isValid && $0.sourceStart >= sourceStart.seconds-0.001 && $0.sourceEnd <= end.seconds+0.001}) ?? true,
              languageRepairAttempts?.allSatisfy({$0.isValid && $0.sourceStart >= sourceStart.seconds-0.001 && $0.sourceEnd <= end.seconds+0.001}) ?? true,
              languageRepairCost?.isValid ?? true else {return false}
        var previous = sourceStart, textBytes = 0
        for cue in cues {
            guard cue.start >= previous, cue.start >= sourceStart, cue.duration > .zero, let cueEnd = try? cue.start.adding(cue.duration), cueEnd <= end,
                  !cue.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, cue.text.utf8.count <= 16_384 else { return false }
            textBytes += cue.text.utf8.count; guard textBytes <= 1_048_576 else { return false }; previous = cue.start
        }
        guard (repetitionSuspects?.count ?? 0) <= cues.count else { return false }
        return repetitionSuspects?.allSatisfy { $0.isFinite && $0 >= sourceStart.seconds && $0 < end.seconds } ?? true
    }
}

public struct TranscriptionCheckpointSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var key: TranscriptionCheckpointKey
    public var completedWindows: Int
    public var totalWindows: Int
    public var bytes: Int64
    public var updatedAt: Date
}

/// Disk store for completed windows. It never reads or writes a project document, so a checkpoint
/// cannot overwrite editing: results reach the timeline only through the editor's own
/// snapshot-guarded batch command.
public struct TranscriptionCheckpointStore: Sendable {
    public let root: URL
    public let policy: TranscriptionCachePolicy
    public init(root: URL? = nil, policy: TranscriptionCachePolicy = .init()) {
        self.root = root ?? (FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("JHCutStudio/Checkpoints",isDirectory:true)
        self.policy = policy
    }
    public func directory(for key: TranscriptionCheckpointKey) -> URL { root.appendingPathComponent(key.identifier,isDirectory:true) }
    private func manifestURL(_ key: TranscriptionCheckpointKey) -> URL { directory(for:key).appendingPathComponent("manifest.json") }
    private func windowURL(_ key: TranscriptionCheckpointKey, _ index: Int) -> URL { directory(for:key).appendingPathComponent(String(format:"window-%05d.json",index)) }
    private func entries(_ folder: URL, maximum: Int = 4096) throws -> [URL] {
        guard RecognitionCacheSafety.directoryIsSafe(folder) else { throw ProjectError("인식 캐시 폴더 형식이 올바르지 않습니다.") }
        guard let e = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:nil,options:[]) else { return [] }
        var result: [URL] = []
        while let url = e.nextObject() as? URL { e.skipDescendants(); guard result.count < maximum else { throw ProjectError("인식 캐시 파일 개수가 허용 한도를 넘습니다.") }; result.append(url) }
        return result
    }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        guard root.isFileURL, policy.maximumBytes > 0, policy.maximumBytes <= 1_099_511_627_776, (1...2048).contains(policy.maximumFolders), policy.quarantineBytes >= 0, policy.quarantineBytes <= 1_099_511_627_776, (0...2048).contains(policy.quarantineFiles), policy.completedRetentionDays.isFinite, (0...3650).contains(policy.completedRetentionDays), policy.unfinishedRetentionDays.isFinite, (0...3650).contains(policy.unfinishedRetentionDays) else { throw ProjectError("인식 캐시 설정이 올바르지 않습니다.") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard RecognitionCacheSafety.directoryIsSafe(root) else { throw ProjectError("인식 캐시 폴더의 링크는 사용할 수 없습니다.") }
        let fd = open(root.appendingPathComponent(".store.lock").path,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProjectError("인식 캐시 잠금을 만들 수 없습니다.") }
        var lockStat = stat(); guard fstat(fd,&lockStat) == 0, lockStat.st_mode & S_IFMT == S_IFREG else { close(fd); throw ProjectError("인식 캐시 잠금 형식이 올바르지 않습니다.") }
        defer { close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw ProjectError("인식 캐시를 잠글 수 없습니다.") }
        defer { flock(fd,LOCK_UN) }
        return try body()
    }
    private func leaseURL(_ key: TranscriptionCheckpointKey) -> URL { root.appendingPathComponent(".leases",isDirectory:true).appendingPathComponent(key.identifier) }
    private func leaseDescriptor(_ key: TranscriptionCheckpointKey) throws -> Int32 {
        let dir = root.appendingPathComponent(".leases",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        guard RecognitionCacheSafety.directoryIsSafe(dir) else { throw ProjectError("인식 캐시 잠금 폴더가 올바르지 않습니다.") }
        let fd = open(leaseURL(key).path,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ProjectError("인식 작업 보호 잠금을 만들 수 없습니다.") }
        var lockStat = stat(); guard fstat(fd,&lockStat) == 0, lockStat.st_mode & S_IFMT == S_IFREG else { close(fd); throw ProjectError("인식 작업 보호 잠금 형식이 올바르지 않습니다.") }
        return fd
    }
    public func beginSession(for key: TranscriptionCheckpointKey) throws -> TranscriptionCacheLease {
        try withLock {
            guard key.isReusable else { throw ProjectError("현재 인식 설정에 사용할 수 없는 체크포인트입니다.") }
            let fd = try leaseDescriptor(key)
            guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); throw TranscriptionCacheError.activeSession }
            _ = try? maintainLocked(protecting:[key.identifier],now:Date())
            return TranscriptionCacheLease(fd,root:root.path,key:key.identifier)
        }
    }
    private func inactiveDescriptor(_ key: TranscriptionCheckpointKey) -> Int32? {
        guard let fd = try? leaseDescriptor(key) else { return nil }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }
    private func bytes(_ folder: URL) -> Int64 {
        guard let files = try? entries(folder) else { return Int64.max / 4 }
        return files.reduce(0) { total,url in
            var s = stat(); guard lstat(url.path,&s) == 0 else { return total }
            // Checkpoints have a flat layout. Unknown nested directories cannot hide disk usage.
            if s.st_mode & S_IFMT == S_IFDIR { return Int64.max / 4 }
            let amount = max(0,Int64(s.st_size)); return total > Int64.max / 4 - amount ? Int64.max / 4 : total + amount
        }
    }
    private func quarantine(_ url: URL) {
        guard FileManager.default.fileExists(atPath:url.path) || (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true else { return }
        let dir = root.appendingPathComponent(".corrupt",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            guard RecognitionCacheSafety.directoryIsSafe(dir) else { return }
            try FileManager.default.moveItem(at:url,to:dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            trimQuarantine()
        } catch { /* An unwritable cache is ignored; never fall back to media/project paths. */ }
    }
    private func trimQuarantine() {
        let dir = root.appendingPathComponent(".corrupt",isDirectory:true)
        guard let files = try? entries(dir) else { return }
        let ordered = files.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        func size(_ url: URL) -> Int64 { if RecognitionCacheSafety.directoryIsSafe(url) { return bytes(url) }; var s = stat(); return lstat(url.path,&s) == 0 ? min(Int64.max/4,max(0,Int64(s.st_size))) : 0 }
        var total = ordered.reduce(Int64(0)) { min(Int64.max/2,$0 + size($1)) }, count = ordered.count
        for url in ordered where total > policy.quarantineBytes || count > policy.quarantineFiles {
            let amount = size(url); if (try? FileManager.default.removeItem(at:url)) != nil { total -= amount; count -= 1 }
        }
    }
    private func manifest(_ key: TranscriptionCheckpointKey, repair: Bool = true) -> Bool {
        let folder = directory(for:key)
        guard FileManager.default.fileExists(atPath:folder.path) else { return false }
        guard RecognitionCacheSafety.directoryIsSafe(folder), let data = try? RecognitionCacheSafety.read(manifestURL(key),maximum:RecognitionCacheSafety.manifestBytes),
              let stored = try? RecognitionCacheSafety.decoder().decode(TranscriptionCheckpointKey.self,from:data), stored.isValid, stored == key else {
            if repair { quarantine(folder) }; return false
        }
        return true
    }
    private func window(_ index: Int, key: TranscriptionCheckpointKey, signature: String? = nil) -> TranscriptionWindowResult? {
        let url = windowURL(key,index)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard let data = try? RecognitionCacheSafety.read(url,maximum:RecognitionCacheSafety.windowBytes),
              let result = try? RecognitionCacheEnvelope.decode(TranscriptionWindowResult.self,data:data,key:key), result.isValid(for:key,index:index),
              signature == nil || result.inputSignature == signature else { quarantine(url); return nil }
        return result
    }
    private func completedLocked(for key: TranscriptionCheckpointKey, signature: String? = nil) -> [Int:TranscriptionWindowResult] {
        guard key.isReusable, manifest(key), let files = try? entries(directory(for:key)) else { return [:] }
        var result: [Int:TranscriptionWindowResult] = [:]
        var loadedBytes: Int64 = 0, loadedCues = 0
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("window-"), name.hasSuffix(".json"), let index = Int(name.dropFirst(7).dropLast(5)), index >= 0, index < key.windowCount,
                  name == windowURL(key,index).lastPathComponent else { continue }
            var fileStat = stat(); let fileBytes = lstat(file.path,&fileStat) == 0 ? max(0,Int64(fileStat.st_size)) : 0
            // Disk capacity alone cannot bound decoded objects from externally injected files.
            if fileBytes <= RecognitionCacheSafety.windowBytes && loadedBytes > RecognitionCacheSafety.maximumLoadedWindowBytes - fileBytes { continue }
            if let value = window(index,key:key,signature:signature), loadedCues <= RecognitionCacheSafety.maximumLoadedCues - value.cues.count {
                result[index] = value; loadedBytes += min(Int64(RecognitionCacheSafety.windowBytes),fileBytes); loadedCues += value.cues.count
            }
        }
        return result
    }
    public func completedWindows(for key: TranscriptionCheckpointKey, inputSignature: String? = nil) -> [Int:TranscriptionWindowResult] {
        (try? withLock { completedLocked(for:key,signature:inputSignature) }) ?? [:]
    }
    private func prepare(_ key: TranscriptionCheckpointKey) throws {
        guard key.isReusable else { throw ProjectError("인식 체크포인트 설정·범위가 올바르지 않습니다.") }
        if !manifest(key) {
            let folder = directory(for:key)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            guard RecognitionCacheSafety.directoryIsSafe(folder) else { throw ProjectError("인식 캐시 폴더 링크를 사용할 수 없습니다.") }
            try RecognitionCacheSafety.encoder().encode(key).write(to:manifestURL(key),options:.atomic)
        }
    }
    private func write<T: Encodable>(_ value: T, key: TranscriptionCheckpointKey, url: URL, maximum: Int) throws {
        try prepare(key)
        let data = try RecognitionCacheEnvelope.encode(value,key:key,maximum:maximum)
        _ = try maintainLocked(protecting:[key.identifier],now:Date())
        let total = try totalBytes()
        var old = stat(); let oldBytes = lstat(url.path,&old) == 0 ? min(total,max(0,Int64(old.st_size))) : 0
        guard summariesLocked().count <= policy.maximumFolders, total - oldBytes <= policy.maximumBytes - Int64(data.count) else { throw ProjectError("인식 캐시 용량 한도에 도달했습니다. 자막 생성은 계속되며 사용하지 않는 기록을 정리할 수 있습니다.") }
        try data.write(to:url,options:.atomic)
    }
    public func save(_ value: TranscriptionWindowResult, for key: TranscriptionCheckpointKey) throws {
        try withLock {
            guard value.isValid(for:key,index:value.index) else { throw ProjectError("완료된 인식 창의 범위·채널·자막이 올바르지 않습니다.") }
            try prepare(key)
            if let existing = window(value.index,key:key) {
                var a = existing, b = value; a.elapsedSeconds=0; b.elapsedSeconds=0; a.completedAt = .distantPast; b.completedAt = .distantPast
                guard a == b else { throw ProjectError("이미 저장된 인식 창과 새 결과가 충돌했습니다. 기존 결과는 보존했습니다.") }; return
            }
            try write(value,key:key,url:windowURL(key,value.index),maximum:RecognitionCacheSafety.windowBytes)
        }
    }
    public func voiceActivity(for key: TranscriptionCheckpointKey) -> VoiceActivityReport? {
        try? withLock {
            guard key.isReusable, key.skipsSilence, manifest(key) else { return nil }
            let url = directory(for:key).appendingPathComponent("voice-activity.json")
            guard FileManager.default.fileExists(atPath:url.path) else { return nil }
            guard let data = try? RecognitionCacheSafety.read(url,maximum:RecognitionCacheSafety.activityBytes),
                  let report = try? RecognitionCacheEnvelope.decode(VoiceActivityReport.self,data:data,key:key), activityMatches(report,key:key) else { quarantine(url); return nil }
            return report
        }
    }
    private func activityMatches(_ report: VoiceActivityReport, key: TranscriptionCheckpointKey) -> Bool {
        report.isValid && report.version == VoiceActivityReport.version && key.skipsSilence && report.requestedChannel == key.channel && report.policy.rawValue == key.voiceActivityPolicy &&
        abs(report.sourceStart-key.sourceStart.seconds) < 0.0001 && abs(report.duration-key.duration.seconds) < 0.0001
    }
    public func saveVoiceActivity(_ report: VoiceActivityReport, for key: TranscriptionCheckpointKey) throws {
        try withLock { guard activityMatches(report,key:key) else { throw ProjectError("말소리 분석 캐시가 이번 원본 범위·채널·정책과 다릅니다.") }; try write(report,key:key,url:directory(for:key).appendingPathComponent("voice-activity.json"),maximum:RecognitionCacheSafety.activityBytes) }
    }
    private func summariesLocked(projectID: UUID? = nil, clipIDs: Set<UUID>? = nil) -> [TranscriptionCheckpointSummary] {
        guard let folders = try? entries(root) else { return [] }
        return folders.compactMap { folder in
            guard RecognitionCacheSafety.hashIsValid(folder.lastPathComponent), RecognitionCacheSafety.directoryIsSafe(folder) else { return nil }
            guard let data = try? RecognitionCacheSafety.read(folder.appendingPathComponent("manifest.json"),maximum:RecognitionCacheSafety.manifestBytes),
                  let key = try? RecognitionCacheSafety.decoder().decode(TranscriptionCheckpointKey.self,from:data), key.isValid, key.identifier == folder.lastPathComponent else { quarantine(folder); return nil }
            if let projectID, key.projectID != projectID { return nil }; if let clipIDs, !clipIDs.contains(key.clipID) { return nil }
            let complete = key.isReusable ? completedLocked(for:key).count : 0
            let updated = (try? folder.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return TranscriptionCheckpointSummary(id:key.identifier,key:key,completedWindows:complete,totalWindows:key.windowCount,bytes:bytes(folder),updatedAt:updated)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func summaries(projectID: UUID? = nil, clipIDs: Set<UUID>? = nil) -> [TranscriptionCheckpointSummary] {
        (try? withLock { summariesLocked(projectID:projectID,clipIDs:clipIDs) }) ?? []
    }
    private func totalBytes() throws -> Int64 {
        try entries(root).filter { RecognitionCacheSafety.hashIsValid($0.lastPathComponent) && RecognitionCacheSafety.directoryIsSafe($0) }.reduce(0) { min(Int64.max/2,$0 + bytes($1)) }
    }
    private func maintainLocked(protecting protected: Set<String>, now: Date) throws -> TranscriptionCacheMaintenance {
        trimQuarantine()
        // Failed/finished sessions with no manifest must not leave unlimited lease files.
        let leaseDir = root.appendingPathComponent(".leases",isDirectory:true)
        if let leases = try? entries(leaseDir) {
            for url in leases where RecognitionCacheSafety.hashIsValid(url.lastPathComponent) && !protected.contains(url.lastPathComponent) && !FileManager.default.fileExists(atPath:root.appendingPathComponent(url.lastPathComponent).path) {
                let fd = open(url.path,O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                if fd >= 0 {
                    var value = stat()
                    if fstat(fd,&value) == 0, value.st_mode & S_IFMT == S_IFREG, flock(fd,LOCK_EX | LOCK_NB) == 0 { try? FileManager.default.removeItem(at:url); flock(fd,LOCK_UN) }
                    close(fd)
                }
            }
        }
        var result = TranscriptionCacheMaintenance()
        var records = summariesLocked().sorted { a,b in
            let obsoleteA = !a.key.isReusable, obsoleteB = !b.key.isReusable
            if obsoleteA != obsoleteB { return obsoleteA }
            let fullA = a.completedWindows == a.totalWindows, fullB = b.completedWindows == b.totalWindows
            return fullA != fullB ? fullA : a.updatedAt < b.updatedAt
        }
        var total = records.reduce(Int64(0)) { min(Int64.max/2,$0 + $1.bytes) }, count = records.count
        for record in records {
            if protected.contains(record.id) { result.protectedFolders += 1; continue }
            guard let fd = inactiveDescriptor(record.key) else { result.protectedFolders += 1; continue }
            defer { flock(fd,LOCK_UN); close(fd) }
            let days = record.completedWindows == record.totalWindows ? policy.completedRetentionDays : policy.unfinishedRetentionDays
            let expired = !record.key.isReusable || now.timeIntervalSince(record.updatedAt) > max(0,days) * 86_400
            if expired || total > policy.maximumBytes || count > policy.maximumFolders {
                try FileManager.default.removeItem(at:directory(for:record.key)); try? FileManager.default.removeItem(at:leaseURL(record.key))
                total -= record.bytes; count -= 1; result.removedFolders += 1
            }
        }
        records.removeAll() // Release decoded metadata before reporting.
        result.remainingBytes = max(0,total); return result
    }
    @discardableResult public func maintain(now: Date = Date()) throws -> TranscriptionCacheMaintenance { try withLock { try maintainLocked(protecting:[],now:now) } }
    public func remove(_ key: TranscriptionCheckpointKey) throws {
        try withLock {
            guard key.isValid, let fd = inactiveDescriptor(key) else { throw ProjectError("사용 중인 인식 기록은 작업이 끝난 뒤 삭제할 수 있습니다.") }
            defer { flock(fd,LOCK_UN); close(fd) }
            if FileManager.default.fileExists(atPath:directory(for:key).path) { try FileManager.default.removeItem(at:directory(for:key)) }
            try? FileManager.default.removeItem(at:leaseURL(key))
        }
    }
    @discardableResult public func removeAll(projectID: UUID? = nil, clipIDs: Set<UUID>? = nil) throws -> Int {
        let records = summaries(projectID:projectID,clipIDs:clipIDs)
        var removed = 0
        for record in records { do { try remove(record.key); removed += 1 } catch { if projectID != nil || clipIDs != nil { throw error } } }
        if projectID == nil && clipIDs == nil { try withLock { let dir=root.appendingPathComponent(".corrupt"); if RecognitionCacheSafety.directoryIsSafe(dir) { try FileManager.default.removeItem(at:dir) } } }
        return removed
    }
}

/// Resume bookkeeping handed to `transcribeLong`. `onWindowSaved` lets the editor surface a
/// failed checkpoint write without failing recognition: a checkpoint is a speed-up, never a
/// precondition for producing captions.
public struct TranscriptionCheckpointSession: Sendable {
    public let store: TranscriptionCheckpointStore
    public let key: TranscriptionCheckpointKey
    public let lease: TranscriptionCacheLease?
    public init(store: TranscriptionCheckpointStore, key: TranscriptionCheckpointKey, lease: TranscriptionCacheLease? = nil) { self.store = store; self.key = key; self.lease = lease }
}

/// Digests are recomputed over the whole file. A persistent stat/sample cache cannot prove
/// identity after a middle-of-file change or corrupted cache JSON; it is never trusted for reuse.
public actor MediaFingerprintCache {
    public static let shared = MediaFingerprintCache()
    public init(persistURL: URL? = nil) { /* Older on-disk hints are deliberately not loaded. */ }
    public func sha256(of url: URL) async throws -> String {
        let before = try Self.stat(url)
        let digest = try await FileIdentity.sha256(url)
        guard try Self.stat(url) == before else { throw ProjectError("해시 계산 중 원본 파일이 바뀌었습니다. 파일 복사가 끝난 뒤 다시 실행하세요.") }
        return digest
    }
    public static func stat(_ url: URL) throws -> String {
        guard url.isFileURL else { throw ProjectError("원본 미디어 파일을 확인할 수 없습니다.") }
        let fd = open(url.path,O_RDONLY | O_CLOEXEC); guard fd >= 0 else { throw ProjectError("원본 미디어 파일을 확인할 수 없습니다.") }; defer { close(fd) }
        var value = Darwin.stat()
        guard fstat(fd,&value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw ProjectError("원본 미디어 파일을 확인할 수 없습니다.") }
        return "\(value.st_dev)|\(value.st_ino)|\(value.st_size)|\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)|\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
}

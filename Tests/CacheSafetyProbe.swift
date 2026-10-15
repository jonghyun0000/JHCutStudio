import Foundation
import AppKit
import AVFoundation
import Darwin
@testable import JHCutCore

/// Failure injection checks integrity and recovery, never recognition accuracy.
@main struct CacheSafetyProbe {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath:"Artifacts/Stage8/CacheSafety")
        let fm = FileManager.default
        var rows: [[String:Any]] = []
        func check(_ name: String, _ ok: Bool) { rows.append(["name":name,"passed":ok]); print("\(ok ? "PASS" : "FAIL") \(name)") }
        defer { try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json")) }
        func refused(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        var options = SpeechOptions(); options.language = "ko"
        let key = TranscriptionCheckpointKey(projectID:UUID(),clipID:UUID(),mediaSHA256:String(repeating:"a",count:64),sourceStart:MediaTime(seconds:10),duration:MediaTime(seconds:65),windowSeconds:30,options:options,modelSHA256:String(repeating:"b",count:64))
        let signature = try RecognitionInputSignature.make(regions:nil,evidence:nil,selection:nil)
        let selection = AudioChannelSelection(primary:0,secondary:nil,channelCount:1)
        func window(_ index: Int, key: TranscriptionCheckpointKey) -> TranscriptionWindowResult {
            let b = key.bounds(for:index)!
            var w = TranscriptionWindowResult(index:index,sourceStart:b.start,duration:b.duration,cues:[CaptionCue(start:b.start,duration:MediaTime(seconds:1),text:"창 \(index)")],language:"ko",channel:0,elapsedSeconds:1,completedAt:Date(timeIntervalSince1970:1_780_000_000))
            w.inputSignature = signature; w.audioSelection = selection; return w
        }
        let store = TranscriptionCheckpointStore(root:root.appendingPathComponent("Cache"))
        let fixtures = (0..<3).map { window($0,key:key) }
        for w in fixtures { try store.save(w,for:key) }
        check("Three exact windows with five-second tail load",store.completedWindows(for:key).count == 3 && fixtures[2].duration.seconds == 5)
        let file = store.directory(for:key).appendingPathComponent("window-00001.json")
        let good = try Data(contentsOf:file)
        func payload(_ mutate: (inout [String:Any]) -> Void) throws -> Data {
            var json = try JSONSerialization.jsonObject(with:RecognitionCacheSafety.encoder().encode(fixtures[1])) as! [String:Any]
            mutate(&json)
            let data = try JSONSerialization.data(withJSONObject:json,options:.sortedKeys)
            return try RecognitionCacheSafety.encoder().encode(RecognitionCacheEnvelope(keyIdentifier:key.identifier,checksum:RecognitionCacheSafety.digest(data),payload:data))
        }
        func damage(_ name: String, data: Data) throws {
            try data.write(to:file)
            let loaded = store.completedWindows(for:key)
            check(name,loaded[1] == nil && loaded[0] == fixtures[0] && loaded[2] == fixtures[2] && !fm.fileExists(atPath:file.path))
            try good.write(to:file)
        }
        try damage("Truncated file quarantined; other windows preserved",data:Data("{partial".utf8))
        var envelope = try RecognitionCacheSafety.decoder().decode(RecognitionCacheEnvelope.self,from:good)
        envelope.checksum = String(repeating:"0",count:64)
        try damage("Wrong checksum refused",data:RecognitionCacheSafety.encoder().encode(envelope))
        envelope.checksum = RecognitionCacheSafety.digest(envelope.payload); envelope.keyIdentifier = String(repeating:"c",count:64)
        try damage("Another source envelope refused",data:RecognitionCacheSafety.encoder().encode(envelope))
        for (name, field, value) in [("Wrong window index","index",2 as Any),("Unsupported reported language","language","zh" as Any),("Invalid channel","channel",99 as Any),("Negative elapsed","elapsedSeconds",-1 as Any),("Missing signature","inputSignature",NSNull() as Any),("Huge text","cues",[["id":UUID().uuidString,"start":try JSONSerialization.jsonObject(with:JSONEncoder().encode(MediaTime(seconds:40))),"duration":try JSONSerialization.jsonObject(with:JSONEncoder().encode(MediaTime(seconds:1))),"text":String(repeating:"x",count:16385)]] as Any)] {
            try damage(name,data:payload { $0[field] = value })
        }
        try damage("Wrong source start refused",data:payload { $0["sourceStart"] = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(MediaTime(seconds:41))) })
        try damage("Wrong tail duration refused",data:payload { $0["duration"] = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(MediaTime(seconds:5))) })
        try damage("Cue outside own window refused",data:payload { $0["cues"] = try! JSONSerialization.jsonObject(with:JSONEncoder().encode([CaptionCue(start:MediaTime(seconds:70),duration:MediaTime(seconds:1),text:"다른 창")])) })
        try damage("Unsorted cues refused",data:payload { $0["cues"] = try! JSONSerialization.jsonObject(with:JSONEncoder().encode([CaptionCue(start:MediaTime(seconds:42),duration:MediaTime(seconds:1),text:"뒤"),CaptionCue(start:MediaTime(seconds:41),duration:MediaTime(seconds:1),text:"앞")])) })
        try damage("Excessive cue array refused before construction",data:payload { $0["cues"] = Array(repeating:($0["cues"] as! [Any])[0],count:10001) })
        try damage("Invalid channel object refused before native indexing",data:payload { $0["audioSelection"] = ["primary":4,"channelCount":1] })
        try damage("Nonfinite elapsed JSON refused",data:payload { $0["elapsedSeconds"] = "NaN" })
        try Data().write(to:file)
        let sparse = try FileHandle(forWritingTo:file); try sparse.truncate(atOffset:UInt64(RecognitionCacheSafety.windowBytes+1)); try sparse.close()
        check("Oversized sparse file refused before allocation",store.completedWindows(for:key)[1] == nil)
        try good.write(to:file)
        try fm.removeItem(at:file); let outside = root.appendingPathComponent("outside.json"); try good.write(to:outside)
        try fm.createSymbolicLink(at:file,withDestinationURL:outside)
        check("Window symlink quarantined without modifying target",try store.completedWindows(for:key)[1] == nil && Data(contentsOf:outside) == good)
        try good.write(to:file)
        let pipeRoot = fm.temporaryDirectory.appendingPathComponent("JHCutStage8-FIFO-" + UUID().uuidString)
        defer { try? fm.removeItem(at:pipeRoot) }
        let pipeStore = TranscriptionCheckpointStore(root:pipeRoot)
        try pipeStore.save(fixtures[1],for:key)
        let pipeURL = pipeStore.directory(for:key).appendingPathComponent("window-00001.json")
        try fm.removeItem(at:pipeURL); guard mkfifo(pipeURL.path,0o600) == 0 else { throw ProjectError("FIFO fixture failed: \(errno)") }
        check("Named pipe refused without blocking read",pipeStore.completedWindows(for:key)[1] == nil)
        let wrongSig = try RecognitionInputSignature.make(regions:[10...20],evidence:nil,selection:nil)
        check("Changed VAD mask rejects all mismatched window signatures",store.completedWindows(for:key,inputSignature:wrongSig).isEmpty)
        for w in fixtures { try store.save(w,for:key) }
        let manifest = store.directory(for:key).appendingPathComponent("manifest.json")
        var stale = key; stale.mediaSHA256 = String(repeating:"d",count:64)
        try RecognitionCacheSafety.encoder().encode(stale).write(to:manifest)
        check("Stale manifest quarantines untrusted folder",store.completedWindows(for:key).isEmpty && !fm.fileExists(atPath:store.directory(for:key).path))
        for w in fixtures { try store.save(w,for:key) }
        check("Fresh atomic save repairs manifest damage",store.completedWindows(for:key).count == 3)
        var conflict = fixtures[0]; conflict.cues[0].text = "충돌"
        check("Conflicting valid result preserves first completed window",refused { try store.save(conflict,for:key) } && store.completedWindows(for:key)[0] == fixtures[0])
        var invalidKey = key; invalidKey.windowSeconds = .nan
        var languageKey = key; languageKey.language = "ja"
        check("Requested language bound to separate cache identity",languageKey.identifier != key.identifier && store.completedWindows(for:languageKey).isEmpty)
        check("NaN window setting returns zero without integer trap",invalidKey.windowCount == 0 && !invalidKey.isValid)
        invalidKey = key; invalidKey.duration = MediaTime(seconds:86401)
        check("Selected range longer than 24h rejected",!invalidKey.isValid)

        // VAD decode must validate BEFORE building ClosedRange from untrusted JSON.
        var vadKey = key; vadKey.skipsSilence = true; vadKey.voiceActivityPolicy = VoiceActivityPolicy.conservative.rawValue
        let vad = VoiceActivityReport(sourceStart:10,duration:65,segments:[VoiceActivitySegment(kind:.speech,start:10,end:75,confidence:0.9)],speechRegions:[10...75],classifierAvailable:true,analysisSeconds:1,channelSelection:selection)
        try store.saveVoiceActivity(vad,for:vadKey)
        check("Valid bound VAD report reloads",store.voiceActivity(for:vadKey) == vad)
        let vadURL = store.directory(for:vadKey).appendingPathComponent("voice-activity.json")
        let vadGood = try Data(contentsOf:vadURL)
        let vadCases: [(String,(inout [String:Any])->Void)] = [
            ("Reversed VAD range",{ $0["regions"] = [["start":30,"end":20]] }),
            ("Overlapping VAD ranges",{ $0["regions"] = [["start":10,"end":40],["start":30,"end":50]] }),
            ("Outside VAD range",{ $0["regions"] = [["start":10,"end":76]] }),
            ("Reversed segment",{ $0["segments"] = [["kind":"speech","start":30,"end":20,"confidence":0.9]] }),
            ("Nonfinite segment",{ $0["segments"] = [["kind":"speech","start":"NaN","end":20,"confidence":0.9]] }),
            ("Invalid confidence",{ $0["segments"] = [["kind":"speech","start":10,"end":20,"confidence":2]] }),
            ("Wrong requested channel",{ $0["requestedChannel"] = 0 }),
            ("Wrong VAD source start",{ $0["sourceStart"] = 11 }),
            ("Nonfinite VAD duration",{ $0["duration"] = "Infinity" }),
            ("Unsorted segments",{ $0["segments"] = [["kind":"speech","start":30,"end":40,"confidence":0.9],["kind":"speech","start":10,"end":20,"confidence":0.9]] }),
            ("Wrong VAD policy",{ $0["policy"] = "fast" }),
            ("Old VAD version",{ $0["version"] = 2 }),
            ("Excessive VAD regions",{ $0["regions"] = Array(repeating:["start":10,"end":20],count:65537) }),
            ("Excessive VAD segments",{ $0["segments"] = Array(repeating:["kind":"speech","start":10,"end":20,"confidence":0.9] as [String:Any],count:131073) })]
        for (name,mutate) in vadCases {
            var object = try JSONSerialization.jsonObject(with:RecognitionCacheSafety.encoder().encode(vad)) as! [String:Any]; mutate(&object)
            let body = try JSONSerialization.data(withJSONObject:object)
            try RecognitionCacheSafety.encoder().encode(RecognitionCacheEnvelope(keyIdentifier:vadKey.identifier,checksum:RecognitionCacheSafety.digest(body),payload:body)).write(to:vadURL)
            check(name + " refused safely",store.voiceActivity(for:vadKey) == nil && !fm.fileExists(atPath:vadURL.path)); try vadGood.write(to:vadURL)
        }
        var programmatic = vad; programmatic.segments[0].end = 9
        check("Invalid programmatic segment cannot trap confidentSpeech",programmatic.confidentSpeech.isEmpty && !programmatic.isValid)

        // Concurrent writers and retention: kernel lease protects jobs, global lock protects writes.
        let lease = try store.beginSession(for:key)
        check("Same-key session rejected while active",refused { _ = try store.beginSession(for:key) })
        let otherLease = try store.beginSession(for:vadKey); otherLease.finish()
        check("Different-key session allowed",!otherLease.matches(store:store,key:vadKey))
        var orphanKey = key; orphanKey.clipID = UUID()
        let orphanLease = try store.beginSession(for:orphanKey); orphanLease.finish()
        _ = try store.maintain()
        check("Finished session without manifest removes orphan lease",!fm.fileExists(atPath:store.root.appendingPathComponent(".leases/" + orphanKey.identifier).path))
        check("Active cache cannot be deleted",refused { try store.remove(key) })
        _ = try store.removeAll()
        check("Manual clear preserves active session folder",store.completedWindows(for:key).count == 3)
        let future = Date().addingTimeInterval(100*86400)
        let kept = try store.maintain(now:future)
        check("Retention preserves active job",kept.protectedFolders >= 1 && store.completedWindows(for:key).count == 3)
        lease.finish(); let cleaned = try store.maintain(now:future)
        check("Released job eligible for expired cleanup",cleaned.removedFolders >= 1 && store.completedWindows(for:key).isEmpty)
        let concurrent = TranscriptionCheckpointStore(root:root.appendingPathComponent("Concurrent"))
        let saved = await withTaskGroup(of:Bool.self,returning:Bool.self) { group in
            for w in fixtures { group.addTask { do { try concurrent.save(w,for:key); return true } catch { return false } } }
            var ok = true; for await item in group { ok = ok && item }; return ok
        }
        check("Concurrent distinct window atomic writes all survive",saved && concurrent.completedWindows(for:key).count == 3)
        var policy = TranscriptionCachePolicy(); policy.maximumFolders = 1
        let bounded = TranscriptionCheckpointStore(root:root.appendingPathComponent("Bounded"),policy:policy)
        try bounded.save(fixtures[0],for:key); try bounded.save(window(0,key:vadKey),for:vadKey)
        check("Folder budget prunes inactive older cache",bounded.summaries().count == 1 && bounded.completedWindows(for:vadKey).count == 1)
        policy = TranscriptionCachePolicy(); policy.maximumBytes = 100
        let tiny = TranscriptionCheckpointStore(root:root.appendingPathComponent("Tiny"),policy:policy)
        check("Payload exceeding capacity refused",refused { try tiny.save(fixtures[0],for:key) } && tiny.completedWindows(for:key).isEmpty)
        policy.completedRetentionDays = .nan
        let badPolicy = TranscriptionCheckpointStore(root:root.appendingPathComponent("InvalidPolicy"),policy:policy)
        check("Nonfinite retention rejected",refused { _ = try badPolicy.maintain() })
        let retention = TranscriptionCheckpointStore(root:root.appendingPathComponent("Retention"))
        for w in fixtures { try retention.save(w,for:key) }; try retention.save(window(0,key:vadKey),for:vadKey)
        let forty = Date().addingTimeInterval(-40*86400)
        for k in [key,vadKey] { try fm.setAttributes([.modificationDate:forty],ofItemAtPath:retention.directory(for:k).path) }
        _ = try retention.maintain()
        check("Completed 30-day expiry; unfinished 90-day retention",retention.completedWindows(for:key).isEmpty && retention.completedWindows(for:vadKey).count == 1)
        var oldKey = key; oldKey.engine = "obsolete pipeline"
        let oldDir = retention.directory(for:oldKey); try fm.createDirectory(at:oldDir,withIntermediateDirectories:true)
        try RecognitionCacheSafety.encoder().encode(oldKey).write(to:oldDir.appendingPathComponent("manifest.json"))
        _ = try retention.maintain()
        check("Old pipeline retired without reusing windows",!fm.fileExists(atPath:oldDir.path))
        var manyKey = key; manyKey.duration = MediaTime(seconds:330)
        let manyStore = TranscriptionCheckpointStore(root:root.appendingPathComponent("ManyCues"))
        for i in 0..<11 { var w = window(i,key:manyKey); w.cues=Array(repeating:w.cues[0],count:10_000); try manyStore.save(w,for:manyKey) }
        let manyLoaded = manyStore.completedWindows(for:manyKey)
        check("Decoded aggregate capped at 100k cues across windows",manyLoaded.count == 10 && manyLoaded.values.reduce(0) { $0 + $1.cues.count } == 100_000)
        let corrupt = store.root.appendingPathComponent(".corrupt")
        check("Quarantine bounded by file count",((try? fm.contentsOfDirectory(atPath:corrupt.path)) ?? []).count <= store.policy.quarantineFiles)
        let linkRoot = root.appendingPathComponent("LinkedRoot"); try fm.createSymbolicLink(at:linkRoot,withDestinationURL:concurrent.root)
        let linked = TranscriptionCheckpointStore(root:linkRoot)
        check("Cache root symlink refused without target deletion",refused { try linked.remove(key) } && concurrent.completedWindows(for:key).count == 3)

        // Full media identity cannot use old stat/sample/persisted hints.
        let identityFile = root.appendingPathComponent("identity.bin")
        try Data(repeating:0x31,count:262144).write(to:identityFile)
        let persisted = root.appendingPathComponent("bad-fingerprint.json"); try Data("{corrupt".utf8).write(to:persisted)
        let fingerprints = MediaFingerprintCache(persistURL:persisted)
        let digest1 = try await fingerprints.sha256(of:identityFile), modified = try identityFile.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
        let handle = try FileHandle(forWritingTo:identityFile); try handle.seek(toOffset:131072); try handle.write(contentsOf:Data([0x32])); try handle.close()
        try fm.setAttributes([.modificationDate:modified],ofItemAtPath:identityFile.path)
        check("Middle byte replacement with same size/mtime/head/tail changes full SHA",try await fingerprints.sha256(of:identityFile) != digest1)
        var fractionalKey = key; fractionalKey.sourceStart = MediaTime(1,2_147_483_647); fractionalKey.duration = MediaTime(65,1)
        check("Nonrepresentable subtitle time grid rejected before arithmetic",!fractionalKey.isValid)
        var missingFailed = false; do { _ = try await fingerprints.sha256(of:root.appendingPathComponent("missing.mov")) } catch { missingFailed = true }
        check("Missing media hash throws without URL fallback",missingFailed)

        // Extract real PCM, invoke declared fixed-output recognizer, cancel/resume/check corrupt redo.
        let audio = root.appendingPathComponent("70s.wav"), format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        do {
        let audioFile = try AVAudioFile(forWriting:audio,settings:format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!; buffer.frameLength=16000
        for second in 0..<70 { for i in 0..<16000 { buffer.floatChannelData![0][i] = Float(sin(Double(second*16000+i)*0.1))*0.1 }; try audioFile.write(from:buffer) }
        }
        let modelBytes = Data("TEST ONLY cache safety".utf8), modelURL = root.appendingPathComponent("mock-model.bin"); try modelBytes.write(to:modelURL)
        let spec = WhisperModelSpec(name:"TEST ONLY",fileName:modelURL.lastPathComponent,downloadURL:modelURL,byteCount:Int64(modelBytes.count),sha256:RecognitionCacheSafety.digest(modelBytes),license:"test",licenseURL:modelURL,recommendedFreeBytes:0)
        let runtime = root.appendingPathComponent("mock-recognizer.sh")
        try #"""
        #!/bin/bash
        while [[ $# -gt 0 ]]; do if [[ "$1" == "-of" ]]; then out="$2"; fi; shift; done
        printf '1\n00:00:00,100 --> 00:00:00,800\n고정 출력\n\n2\n00:00:04,900 --> 00:00:06,000\n끝 범위\n\n' > "$out.srt"
        printf '{"result":{"language":"ko"},"transcription":[{"text":"고정 출력","offsets":{"from":100,"to":800}},{"text":"끝 범위","offsets":{"from":4900,"to":6000}}]}' > "$out.json"
        """#.write(to:runtime,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:runtime.path)
        let config = WhisperConfiguration(runtimeURL:runtime,modelURL:modelURL,modelSpec:spec)
        let digest = try await fingerprints.sha256(of:audio), duration = MediaTime(3_120_001,48_000)
        let asrKey = TranscriptionCheckpointKey(projectID:UUID(),clipID:UUID(),mediaSHA256:digest,sourceStart:.zero,duration:duration,windowSeconds:30,options:options,modelSHA256:spec.sha256)
        let asrStore = TranscriptionCheckpointStore(root:root.appendingPathComponent("ASR")), session = TranscriptionCheckpointSession(store:asrStore,key:asrKey)
        let task = Task.detached { try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:session,detail:{ d in if d.windowIndex == 1 { withUnsafeCurrentTask { $0?.cancel() } } }) }
        var cancelled = false; do { _ = try await task.value } catch is CancellationError { cancelled = true }
        check("Cancel saves only fully completed extraction window",cancelled && asrStore.completedWindows(for:asrKey).keys.sorted() == [0])
        let resumed = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:session)
        let clean = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30)
        let cleanSRT = try SRTCodec.serialize(clean.cues)
        check("Fractional tail cue never exceeds exact selected source end",resumed.cues.allSatisfy { (try? $0.start.adding($0.duration)) ?? MediaTime(seconds:999) <= duration } && asrStore.completedWindows(for:asrKey)[2]?.duration == asrKey.bounds(for:2)?.duration)
        check("Resume reuses one; computes remaining two",resumed.reusedWindows == 1 && resumed.computedWindows == 2)
        check("Cancel/resume SRT equals clean fixed-output run",try SRTCodec.serialize(resumed.cues) == cleanSRT)
        let beforeRepair = asrStore.completedWindows(for:asrKey)
        try Data("{cut".utf8).write(to:asrStore.directory(for:asrKey).appendingPathComponent("window-00001.json"))
        let repaired = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:session)
        check("Only damaged window recomputed",repaired.computedWindows == 1 && repaired.reusedWindows == 2 && asrStore.completedWindows(for:asrKey)[0] == beforeRepair[0] && asrStore.completedWindows(for:asrKey)[2] == beforeRepair[2])
        check("Repair SRT equals clean fixed-output run",try SRTCodec.serialize(repaired.cues) == cleanSRT)
        try cleanSRT.write(to:root.appendingPathComponent("clean.srt"),atomically:true,encoding:.utf8)
        try SRTCodec.serialize(repaired.cues).write(to:root.appendingPathComponent("repaired.srt"),atomically:true,encoding:.utf8)
        var mismatched = asrKey; mismatched.mediaSHA256 = key.mediaSHA256
        var mismatchFailed = false; do { _ = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:TranscriptionCheckpointSession(store:asrStore,key:mismatched)) } catch { mismatchFailed = true }
        check("Stale source SHA session rejected before reuse",mismatchFailed && asrStore.completedWindows(for:mismatched).isEmpty)
        let held = try asrStore.beginSession(for:asrKey)
        var busyFailed = false; do { _ = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:session) } catch is TranscriptionCacheError { busyFailed = true }
        check("Recognition refuses another active same-key session",busyFailed); held.finish()
        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag(), blocked = root.appendingPathComponent("blocked-root"); try Data("not directory".utf8).write(to:blocked)
        let survived = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:TranscriptionCheckpointSession(store:TranscriptionCheckpointStore(root:blocked),key:asrKey),onCheckpointError:{ _ in flag.value=true })
        check("Unavailable cache reports warning and still returns captions",try flag.value && SRTCodec.serialize(survived.cues) == cleanSRT)
        var mutationKey = asrKey; mutationKey.clipID=UUID()
        let mutationSession = TranscriptionCheckpointSession(store:asrStore,key:mutationKey)
        var mutationFailed = false
        do { _ = try await LocalTranscription.transcribeLong(url:audio,duration:duration,configuration:config,options:options,windowSeconds:30,checkpoint:mutationSession,detail:{ d in if d.windowIndex == 1 { let h = try? FileHandle(forWritingTo:audio); try? h?.seekToEnd(); try? h?.write(contentsOf:Data([0])); try? h?.close() } }) } catch { mutationFailed = true }
        check("Source mutation during run fails before next window publication",mutationFailed && asrStore.completedWindows(for:mutationKey).keys.sorted() == [0])

        // UI only advertises exact current media and options, with asynchronous hash guards.
        let asset = try await MediaImporter.inspect(url:audio)
        var project = Project(name:"Cache UI"); project.assets=[asset]
        let clip = Clip(name:"source",assetID:asset.id,duration:duration); project.sequence.tracks[0].clips=[clip]
        let editor = EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"))
        editor.history=EditorHistory(project:project); editor.selectedClipID=clip.id; editor.selectedClipIDs=[clip.id]; editor.speechOptions=options; editor.skipNonSpeech=false; editor.speechWindowSeconds=30; editor.checkpointStore=store; editor.mediaFingerprints=fingerprints
        let uiKey = TranscriptionCheckpointKey(projectID:project.id,clipID:clip.id,mediaSHA256:try await fingerprints.sha256(of:audio),sourceStart:.zero,duration:duration,windowSeconds:30,options:options,modelSHA256:editor.speechModelSpec.sha256)
        try store.save(window(0,key:uiKey),for:uiKey)
        editor.refreshCheckpointSummaries(); await editor.checkpointRefreshTask?.value
        check("Panel advertises verified exact-source partial resume",editor.selectedClipCheckpoints.count == 1)
        editor.speechOptions.glossary="different"
        check("Settings change hides reuse but preserves deletable record",editor.selectedClipCheckpoints.isEmpty && editor.selectedCheckpointRecords.count == 1)
        editor.speechOptions=options
        let mutate = try FileHandle(forWritingTo:audio); try mutate.seekToEnd(); try mutate.write(contentsOf:Data([1])); try mutate.close()
        check("Same-path media change immediately hides stale reuse",editor.selectedClipCheckpoints.isEmpty)
        editor.refreshCheckpointSummaries(); editor.selectedClipIDs=[]; editor.selectedClipID=nil; editor.refreshCheckpointSummaries(); await editor.checkpointRefreshTask?.value
        check("Cancelled refresh cannot publish stale selection hash",editor.checkpointMediaHashes.isEmpty && editor.selectedClipCheckpoints.isEmpty)
        editor.selectedClipID=clip.id; editor.selectedClipIDs=[clip.id]
        let missingURL = root.appendingPathComponent("missing-original.wav")
        var missingProject = project; missingProject.assets[0].path = missingURL.path; missingProject.assets[0].bookmark=nil; missingProject.assets[0].relativePath=nil
        editor.history=EditorHistory(project:missingProject)
        editor.refreshCheckpointSummaries(); await editor.checkpointRefreshTask?.value
        check("Missing source has no path-based resume advertisement",editor.checkpointMediaHashes.isEmpty && editor.selectedClipCheckpoints.isEmpty)
        editor.checkCaptionsAgainstVoiceActivity(); await editor.productivityTask?.value
        check("VAD hash failure surfaces error without populating memory cache",editor.error != nil && editor.voiceActivityCache.isEmpty)
        check("External target file preserved across all cleanup",try Data(contentsOf:outside) == good)
        let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
        print("CACHE_SAFETY_RESULT checks=\(rows.count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}

import Foundation
import AppKit
import AVFoundation
@testable import JHCutCore

@main struct SpeakerSafetyProbe {
    static func pcm(_ url: URL, channels: Int, simultaneous: Bool = false, identical: Bool = false, allChannels: Bool = false) throws {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!; buffer.frameLength = 16000
        for c in 0..<channels { for i in 0..<16000 {
            let active = (allChannels && i / (16000/channels) == c) || channels == 1 || identical || (!allChannels && c == channels-2 && (i < 8000 || simultaneous)) || (!allChannels && c == channels-1 && (i >= 8000 || simultaneous))
            let frequency = identical ? 0.11 : (c == channels-1 ? 0.19 : 0.11)
            buffer.floatChannelData![c][i] = active ? Float(sin(Double(i)*frequency))*0.4 : 0
        } }
        var settings = format.settings; settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: buffer)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "SpeakerSafety")
        var rows: [[String:Any]] = [], measurements: [[String:Any]] = []
        func check(_ name: String, _ passed: Bool) { rows.append(["name":name,"passed":passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        defer {
            try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))
            try? JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("channel-measurements.json"))
        }
        func model(_ project: Project) -> EditorModel {
            let m = EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent(UUID().uuidString)),exportHistoryURL:root.appendingPathComponent("journal.json"))
            m.history = EditorHistory(project:project); m.autoCaptionImportedVideos = false; m.translateAfterTranscription = false; m.refreshTranscriptionStatus(); m.speechOptions.language = "ko"
            return m
        }
        func select(_ m: EditorModel, _ id: UUID) { m.selectedClipID = id; m.selectedClipIDs = [id] }
        func settle(_ m: EditorModel) async throws {
            let deadline = Date().addingTimeInterval(20)
            while m.productivityBusy || m.productivityTask != nil { guard Date() < deadline else { throw ProjectError("Speaker timeout") }; try await Task.sleep(nanoseconds:10_000_000) }
        }
        func project(_ url: URL, name: String = "recording") -> (Project,Clip) {
            let asset = MediaAsset(name:name,path:url.path,kind:.audio,duration:MediaTime(2,1),hasAudio:true)
            var p = Project(name:"Speaker safety"); p.assets = [asset]
            let clip = Clip(name:name,assetID:asset.id,duration:MediaTime(2,1)); p.sequence.tracks[3].clips = [clip]
            return (p,clip)
        }
        for n in [9,16,32] {
            let url = root.appendingPathComponent("high-\(n).caf"); try pcm(url,channels:n)
            let layout = try await SpeakerSeparation.channelLayout(url:url,sourceStart:.zero,duration:MediaTime(2,1))
            let result = try await SpeakerSeparation.analyze(url:url,sourceStart:.zero,duration:MediaTime(2,1),ranges:[0...0.99,1...1.99])
            check("\(n)-channel layout preserves high native indices", Set(layout.activeChannels) == [n-2,n-1] && layout.isSeparated)
            check("\(n)-channel assignments never collapse to H", result.status == .separated && result.assignments.map(\.channelIndex) == [n-2,n-1] && Set(result.assignments.compactMap(\.speaker)).count == 2)
            check("\(n)-channel order is separate from labels", layout.recognitionChannels.enumerated().allSatisfy { $0.offset == $0.element.ordinal && $0.element.label == SpeakerSeparation.label(for:$0.element.index) })
            let (p,clip) = project(url); let m = model(p); select(m,clip.id); var requested: [Int] = []
            m.speakerTranscriptionProvider = { channel in requested.append(channel); return [CaptionCue(start:MediaTime(seconds:channel == n-2 ? 0 : 1),duration:MediaTime(1,1),text:"채널 \(channel)")] }
            m.transcribeSpeakersByChannel(); try await settle(m)
            check("\(n)-channel music/tones without mic confirmation assign no people", m.project == p && requested.isEmpty && m.speakerStatus.contains("불확실"))
            m.channelSpeakerMappingConfirmed = true; m.transcribeSpeakersByChannel(); try await settle(m)
            let captions = m.captionClips
            check("\(n)-channel EditorModel visits every selected native channel", requested == layout.activeChannels && captions.count == 2 && m.error == nil)
            check("\(n)-channel recording-scoped IDs map to native indices", Set(captions.compactMap { $0.captionMetadata?.speaker }) == Set([n-2,n-1].map { SpeakerIdentity.channel(sourceID:clip.assetID!,index:$0) }))
            let saved = m.project; m.undo(); check("\(n)-channel operation is one Undo", m.project == p); m.redo(); check("\(n)-channel Redo keeps identities", m.project == saved)
            measurements.append(["channels":n,"activeNativeIndices":layout.activeChannels,"maxCorrelation":layout.maxCorrelation,"assignmentChannels":result.assignments.compactMap(\.channelIndex),"marginDB":result.assignments.map(\.marginDB),"scope":"synthetic PCM routing; not speech recognition accuracy"])
        }
        let allURL = root.appendingPathComponent("all-32.caf"); try pcm(allURL,channels:32,allChannels:true)
        let (allProject,allParent) = project(allURL), allModel = model(allProject); select(allModel,allParent.id); allModel.channelSpeakerMappingConfirmed = true
        var allRequests: [Int] = []
        allModel.speakerTranscriptionProvider = { channel in allRequests.append(channel); return [CaptionCue(start:MediaTime(seconds:Double(channel)/16),duration:MediaTime(1,16),text:"native \(channel)")] }
        allModel.transcribeSpeakersByChannel(); try await settle(allModel)
        check("All 32 active channels are recognised without an eight-channel cap", Set(allRequests) == Set(0..<32) && allRequests.count == 32 && allModel.captionClips.count == 32 && (allModel.project.sequence.speakers ?? []).count == 32)
        check("Labels A-Z-AA-AF are unique for all 32 native channels", Set((0..<32).map(SpeakerSeparation.label)).count == 32 && SpeakerSeparation.label(for:31) == "AF")
        let signalCues = [CaptionCue(start:.zero,duration:MediaTime(2,1),text:"internal pause preserved")]
        let tightened = try await SpeakerSeparation.tightenedToChannelSignal(signalCues,url:root.appendingPathComponent("high-32.caf"),channel:31,sourceStart:.zero,duration:MediaTime(2,1))
        check("Native channel silence trims only the leading cue edge", tightened.count == 1 && tightened[0].start.seconds >= 0.84 && tightened[0].start.seconds <= 1 && tightened[0].start + tightened[0].duration == MediaTime(2,1))
        let quietCue = [CaptionCue(start:.zero,duration:MediaTime(1,1),text:"quiet cue requires review")]
        check("Wholly quiet or low-signal cue is retained rather than deleted", try await SpeakerSeparation.tightenedToChannelSignal(quietCue,url:root.appendingPathComponent("high-32.caf"),channel:0,sourceStart:.zero,duration:MediaTime(2,1)) == quietCue)
        let tooMany = root.appendingPathComponent("too-many.caf"); try pcm(tooMany,channels:33)
        do { _ = try await SpeakerSeparation.channelLayout(url:tooMany,sourceStart:.zero,duration:MediaTime(2,1)); check("More than 32 channels rejects instead of truncating",false) } catch { check("More than 32 channels rejects instead of truncating",true) }
        let simultaneous = root.appendingPathComponent("overlap.caf"); try pcm(simultaneous,channels:2,simultaneous:true)
        let overlap = try await SpeakerSeparation.analyze(url:simultaneous,sourceStart:.zero,duration:MediaTime(2,1),ranges:[0...0.99,1...1.99])
        check("Simultaneous independent signals remain unknown for mixed cues", overlap.status == .uncertain && overlap.assignments.allSatisfy { $0.speaker == nil && $0.channelIndex == nil && $0.marginDB < 6 })
        measurements.append(["fixture":"simultaneous tones","knownOverlapSeconds":2,"unknownCount":overlap.assignments.count,"marginDB":overlap.assignments.map(\.marginDB),"scope":"routing ambiguity; not simultaneous-human ground truth"])
        let identical = root.appendingPathComponent("identical.caf"); try pcm(identical,channels:2,identical:true)
        let identicalLayout = try await SpeakerSeparation.channelLayout(url:identical,sourceStart:.zero,duration:MediaTime(2,1))
        check("Identical stereo cannot pass independence gate", !identicalLayout.isSeparated && identicalLayout.maxCorrelation > 0.999)
        let mono = root.appendingPathComponent("mono.caf"); try pcm(mono,channels:1)
        let monoResult = try await SpeakerSeparation.analyze(url:mono,sourceStart:.zero,duration:MediaTime(2,1),ranges:[0...1])
        check("Mono remains unavailable without a voice diarization model", monoResult.status == .unavailable && monoResult.assignments.allSatisfy { $0.speaker == nil })
        do { _ = try await SpeakerSeparation.analyze(url:mono,sourceStart:.zero,duration:MediaTime(2,1),ranges:[0...3]); check("Out of source ranges reject",false) } catch { check("Out of source ranges reject",true) }

        // Legacy A on two independent recordings must clone presentation and retain translation links.
        let (first, parent1) = project(root.appendingPathComponent("high-9.caf"),name:"first")
        var p = first
        let asset2 = MediaAsset(name:"second",path:identical.path,kind:.audio,duration:MediaTime(2,1),hasAudio:true)
        p.assets.append(asset2); let parent2 = Clip(name:"second",assetID:asset2.id,start:MediaTime(3,1),duration:MediaTime(2,1)); p.sequence.tracks[3].clips.append(parent2)
        func original(_ parent: Clip, label: String) -> Clip {
            var c = CaptionEditing.automaticClips(cues:[CaptionCue(start:.zero,duration:MediaTime(2,1),text:"안녕하세요")],source:parent,style:Title(text:""))[0]
            c.captionMetadata = CaptionMetadata(language:"ko",originalLanguage:"ko",originalText:"안녕하세요",generatedText:"안녕하세요"); c.captionMetadata?.speaker = label; c.captionMetadata?.speakerStatus = "separated"
            return c
        }
        let c1 = original(parent1,label:"A"), c2 = original(parent2,label:"A")
        let t1 = try CaptionTranslationEditing.translated(c1,text:"Hello",sourceLanguage:"ko",targetLanguage:"en",bilingual:false)
        let t2 = try CaptionTranslationEditing.translated(c2,text:"Hello second",sourceLanguage:"ko",targetLanguage:"en",bilingual:false)
        p.sequence.tracks[2].clips = [c1,c2]; p.sequence.tracks.append(Track(name:"Translations",kind:.title,clips:[t1,t2]))
        p.sequence.speakers = [SpeakerProfile(id:"A",name:"진행자",colorHex:"FFE55B")]
        let oldURL = root.appendingPathComponent("legacy.jhcut"); try ProjectStore.save(p,to:oldURL); let oldBytes = try Data(contentsOf:oldURL)
        let migrated = try ProjectStore.load(from:oldURL)
        let id1 = SpeakerIdentity.channel(sourceID:parent1.assetID!,index:0), id2 = SpeakerIdentity.channel(sourceID:asset2.id,index:0)
        func get(_ project: Project,_ id: UUID) -> Clip { project.sequence.tracks.flatMap(\.clips).first { $0.id == id }! }
        check("Legacy A names/colours clone into isolated recording identities", id1 != id2 && Set((migrated.sequence.speakers ?? []).map(\.id)) == [id1,id2] && migrated.sequence.speakers!.allSatisfy { $0.name == "진행자" && $0.colorHex == "FFE55B" })
        check("Legacy migration binds each translation to its own source speaker", get(migrated,t1.id).captionMetadata?.speaker == id1 && get(migrated,t2.id).captionMetadata?.speaker == id2)
        check("Migration is idempotent with no timing changes", SpeakerEditing.migrating(migrated.sequence) == migrated.sequence && get(migrated,c1.id).connection == c1.connection)
        try ProjectStore.save(migrated,to:oldURL)
        check("First identity save preserves exact permanent legacy bytes", try Data(contentsOf:ProjectStore.beforeSpeakerIdentityURL(for:oldURL)) == oldBytes)
        try ProjectStore.save(migrated,to:oldURL)
        check("Later saves cannot overwrite permanent speaker backup", try Data(contentsOf:ProjectStore.beforeSpeakerIdentityURL(for:oldURL)) == oldBytes)
        check("Scoped identity save/reopen is exact", try ProjectStore.load(from:oldURL).sequence == migrated.sequence)
        let m = model(migrated)
        m.updateSpeaker(id1,name:"동일 표시 이름",colorHex:"7FD8FF"); m.updateSpeaker(id2,name:"동일 표시 이름",colorHex:"FF9E7A")
        check("Rename/recolour updates original and exact translation only", get(m.project,c1.id).title?.colorHex == "7FD8FF" && get(m.project,t1.id).title?.colorHex == "7FD8FF" && get(m.project,c2.id).title?.colorHex == "FF9E7A" && get(m.project,t2.id).title?.colorHex == "FF9E7A")
        let coloured = m.project; m.splitCaptionTracksBySpeaker()
        let splitTracks = m.project.sequence.tracks.filter { $0.name.hasPrefix("화자 · ") }
        check("Identical display names create separate tracks by identity", splitTracks.count == 2 && splitTracks.allSatisfy { Set($0.clips.compactMap { $0.captionMetadata?.speaker }).count == 1 })
        let splitProject = m.project; m.splitCaptionTracksBySpeaker(); check("Repeated track split is idempotent", m.project == splitProject)
        m.undo(); check("Track split is one Undo preserving full source graph", m.project == coloured); m.redo()
        select(m,c1.id); m.createSpeakerForSelection(name:"직접 지정")
        let manual = m.project, manualID = get(manual,c1.id).captionMetadata!.speaker!
        check("Manual new speaker updates source and translation with exact IDs", manualID != id1 && get(manual,c1.id).captionMetadata?.speakerManual == true && get(manual,t1.id).captionMetadata?.speaker == manualID && get(manual,t2.id).captionMetadata?.speaker == id2)
        m.undo(); check("Manual assignment is one Undo", m.project == splitProject); m.redo()
        m.mergeSpeakers(manualID,into:id1)
        check("Manual merge updates linked captions and removes only merged profile", get(m.project,c1.id).captionMetadata?.speaker == id1 && get(m.project,t1.id).captionMetadata?.speaker == id1 && m.project.sequence.speakers?.contains { $0.id == manualID } == false && get(m.project,c2.id).captionMetadata?.speaker == id2)
        m.undo(); check("Merge Undo restores exact manual profile", m.project == manual); m.redo()
        let merged = m.project; m.mergeSpeakers(id1,into:id2)
        check("Cross-recording speaker merge rejected atomically", m.project == merged && m.error != nil)
        m.error = nil; select(m,t1.id); m.assignSpeakerToSelected(nil)
        let cleared = m.project
        check("Selecting translation clears its own original and translation only", get(cleared,c1.id).captionMetadata?.speaker == nil && get(cleared,t1.id).captionMetadata?.speaker == nil && get(cleared,c1.id).captionMetadata?.speakerManual == true && get(cleared,c2.id).captionMetadata?.speaker == id2)
        check("Manual clear is protected from future ASR replacement", CaptionLanguagePreservation.shouldKeep(get(cleared,c1.id),trackLocked:false,in:cleared.sequence))
        m.undo(); check("Clear Undo restores identities and presentation", m.project == merged); m.redo()
        var locked = merged; let ti = locked.sequence.tracks.firstIndex { $0.clips.contains { $0.id == t1.id } }!; locked.sequence.tracks[ti].isLocked = true
        m.history = EditorHistory(project:locked); select(m,c1.id); m.assignSpeakerToSelected(nil)
        check("Locked linked translation rejects manual assignment atomically", m.project == locked && m.error != nil)
        m.error = nil; m.updateSpeaker(id1,name:"cannot update",colorHex:"FFFFFF")
        check("Locked linked caption rejects profile rename/recolour atomically", m.project == locked && m.error != nil)
        m.history = EditorHistory(project:merged); m.error = nil; select(m,c1.id); m.assignSpeakerToSelected(id2)
        check("Cross-recording manual assignment rejects atomically", m.project == merged && m.error != nil)

        // Temporal edits keep scoped speaker IDs while translation IDs follow their exact cue pieces.
        var h = EditorHistory(project:merged)
        try h.apply(.split(trackID:merged.sequence.tracks[3].id,clipID:parent1.id,at:MediaTime(1,1)))
        let pieces = h.project
        check("Parent split keeps speaker identity on all source and translation pieces", pieces.sequence.tracks.flatMap(\.clips).filter { $0.captionMetadata?.speaker == id1 }.count == 4 && CaptionQuery.entries(in:pieces.sequence,role:.translation).allSatisfy { entry in CaptionTranslationTracking.source(for:entry.clip,in:pieces.sequence)?.captionMetadata?.speaker == entry.clip.captionMetadata?.speaker })
        h.undo(); check("Split Undo restores speaker graph", h.project == merged)
        try h.apply(.duplicate(trackID:merged.sequence.tracks[3].id,clipID:parent1.id))
        check("Duplicating a recording preserves its channel namespace", h.project.sequence.tracks.flatMap(\.clips).filter { $0.captionMetadata?.speaker == id1 }.count == 4)
        h = EditorHistory(project:merged); try h.apply(.deriveSequence(name:"speaker copy",width:640,height:360))
        check("Derived sequence keeps recording identity and translation mapping", h.project.sequence.speakers == merged.sequence.speakers && CaptionQuery.entries(in:h.project.sequence,role:.translation).allSatisfy { CaptionTranslationTracking.source(for:$0.clip,in:h.project.sequence)?.captionMetadata?.speaker == $0.clip.captionMetadata?.speaker })
        var one = get(merged,c1.id), two = one; two.id = UUID(); two.start = one.end; two.captionMetadata?.speaker = manualID
        do { _ = try CaptionEditing.merged(first:one,second:two); check("Caption merge rejects different speakers",false) } catch { check("Caption merge rejects different speakers",true) }
        two.captionMetadata?.speaker = one.captionMetadata?.speaker
        check("Caption merge keeps shared speaker identity", try CaptionEditing.merged(first:one,second:two).captionMetadata?.speaker == id1)

        // Cancellation, retry and document conflict use a delayed provider; real PCM layout remains active.
        let (jobProject, jobClip) = project(root.appendingPathComponent("high-32.caf")); let job = model(jobProject); select(job,jobClip.id); job.channelSpeakerMappingConfirmed = true
        var entered = false
        job.speakerTranscriptionProvider = { channel in entered = true; try await Task.sleep(nanoseconds:2_000_000_000); return [CaptionCue(start:.zero,duration:MediaTime(1,1),text:"채널 \(channel)")] }
        job.transcribeSpeakersByChannel()
        let deadline = Date().addingTimeInterval(10)
        while !entered && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        job.cancelProductivity(); try await settle(job)
        check("Cancel after channel work starts preserves entire document", entered && job.project == jobProject && !job.transcriptionActive && job.productivityTask == nil)
        job.speakerTranscriptionProvider = { channel in [CaptionCue(start:MediaTime(seconds:channel == 30 ? 0 : 1),duration:MediaTime(1,1),text:"재시작 \(channel)")] }
        job.transcribeSpeakersByChannel(); try await settle(job)
        check("Retry after cancellation installs exactly once without duplicates", job.captionClips.count == 2 && job.error == nil)
        job.undo(); check("Retry is one Undo", job.project == jobProject)
        entered = false; job.speakerTranscriptionProvider = { channel in entered = true; try await Task.sleep(nanoseconds:100_000_000); return [CaptionCue(start:.zero,duration:MediaTime(1,1),text:"경합")] }
        job.transcribeSpeakersByChannel()
        while !entered { try await Task.sleep(nanoseconds:10_000_000) }
        var changed = job.project; changed.name = "Edited during job"; job.history = EditorHistory(project:changed); try await settle(job)
        check("Document change during channel recognition rejects obsolete result", job.project == changed && job.error != nil && !job.productivityBusy)
        // Confirmation never leaks to another recording.
        job.history = EditorHistory(project:migrated); select(job,parent2.id)
        check("Mic confirmation is scoped to the selected recording", !job.channelSpeakerMappingConfirmed)
        var invalid = migrated; invalid.sequence.speakers![0].id = "channel|\(parent1.assetID!.uuidString)|32"
        do { try ProjectValidator.validate(invalid); check("Out of range persisted identity rejected",false) } catch { check("Out of range persisted identity rejected",true) }
        invalid = migrated; invalid.sequence.speakers!.append(invalid.sequence.speakers![0])
        do { try ProjectValidator.validate(invalid); check("Duplicate speaker profile IDs rejected",false) } catch { check("Duplicate speaker profile IDs rejected",true) }
        var inconsistent = migrated
        let wrongTrack = inconsistent.sequence.tracks.firstIndex { $0.clips.contains { $0.id == c1.id } }!, wrongCue = inconsistent.sequence.tracks[wrongTrack].clips.firstIndex { $0.id == c1.id }!
        inconsistent.sequence.tracks[wrongTrack].clips[wrongCue].captionMetadata?.speaker = id2
        do { try ProjectValidator.validate(inconsistent); check("Persisted cross-recording identity rejects",false) } catch { check("Persisted cross-recording identity rejects",true) }
        job.history = EditorHistory(project:jobProject); select(job,jobClip.id); job.error = nil
        var calls = 0
        job.speakerTranscriptionProvider = { channel in calls += 1; if calls == 2 { throw ProjectError("Injected second-channel failure") }; return [CaptionCue(start:.zero,duration:MediaTime(1,1),text:"first channel")] }
        job.transcribeSpeakersByChannel(); try await settle(job)
        check("Second-channel failure never publishes partial captions or profiles", calls == 2 && job.project == jobProject && job.error != nil)
        // Manual clear survives both analysis and replacement, not just a policy helper.
        let protected = model(cleared); select(protected,parent1.id); protected.channelSpeakerMappingConfirmed = true
        protected.speakerTranscriptionProvider = { channel in [CaptionCue(start:.zero,duration:MediaTime(2,1),text:"replacement")] }
        protected.transcribeSpeakersByChannel(); try await settle(protected)
        check("Re-recognition retains manually cleared cue and its translation", get(protected.project,c1.id) == get(cleared,c1.id) && get(protected.project,t1.id) == get(cleared,t1.id))
        protected.separateSpeakers(); try await settle(protected)
        check("Channel analysis cannot undo an explicit manual clear", get(protected.project,c1.id).captionMetadata?.speaker == nil && get(protected.project,c1.id).captionMetadata?.speakerManual == true)
        var ambiguous = migrated
        let ambTrack = ambiguous.sequence.tracks.firstIndex { $0.clips.contains { $0.id == c1.id } }!, ambCue = ambiguous.sequence.tracks[ambTrack].clips.firstIndex { $0.id == c1.id }!
        var descendant = get(ambiguous,c1.id); descendant.id = UUID(); descendant.lineageID = c1.id
        ambiguous.sequence.tracks[ambTrack].clips[ambCue] = descendant
        descendant.id = UUID(); ambiguous.sequence.tracks[ambTrack].clips.append(descendant)
        let ambModel = model(ambiguous); select(ambModel,t1.id); ambModel.assignSpeakerToSelected(nil)
        check("Ambiguous legacy translation selection cannot relabel multiple sources", ambModel.project == ambiguous && ambModel.error != nil)
        select(ambModel,descendant.id); ambModel.assignSpeakerToSelected(nil)
        check("Ambiguous related translation blocks partial original relabeling", ambModel.project == ambiguous && ambModel.error != nil)
        let swappedURL = root.appendingPathComponent("changed-source.caf"); try pcm(swappedURL,channels:32)
        let (swapProject,swapClip) = project(swappedURL), swapped = model(swapProject); select(swapped,swapClip.id); swapped.channelSpeakerMappingConfirmed = true
        entered = false; swapped.speakerTranscriptionProvider = { channel in entered = true; try await Task.sleep(nanoseconds:100_000_000); return [CaptionCue(start:.zero,duration:MediaTime(1,1),text:"changing source")] }
        swapped.transcribeSpeakersByChannel()
        while !entered { try await Task.sleep(nanoseconds:10_000_000) }
        try pcm(swappedURL,channels:2,identical:true); try await settle(swapped)
        check("Source file replacement during recognition rejects obsolete routing", swapped.project == swapProject && swapped.error != nil)
        let failures = rows.filter { $0["passed"] as? Bool != true }.count
        print("SPEAKER_SAFETY_RESULT checks=\(rows.count) failures=\(failures)"); if failures > 0 { exit(1) }
    }
}

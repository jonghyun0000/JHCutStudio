#if PRODUCTIVITY_APP_PROBE
import Foundation
import AppKit
import AVFoundation
import CoreImage
import JHCutCore

@MainActor final class AsyncProbeGate {
    var reached = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { reached = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func awaitReached() async throws {
        for _ in 0..<2000 { if reached { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw ProjectError("비동기 검사 장벽에 도달하지 못했습니다.")
    }
}
@main struct EditorProductivityProbe {
    static func audio(_ url: URL, peak: Float = 0.25) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!; buffer.frameLength = 288000
        for i in 0..<288000 { buffer.floatChannelData![0][i] = i < 62400 ? 0 : peak * Float(sin(Double(i) * 2 * .pi * 440 / 48000)) }
        try file.write(from: buffer)
    }
    static func video(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90, AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            context.render(CIImage(color: CIColor(red: Double(frame)/30, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90)), to: buffer!)
            guard adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? ProjectError("검사 영상 쓰기 실패") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProjectError("검사 영상 생성 실패") }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/EditorProductivity")
        let baseAudio = root.appendingPathComponent("base.wav"), baseVideo = root.appendingPathComponent("base.mp4")
        try audio(baseAudio); try await video(baseVideo)
        var rows: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
        func make(_ name: String, isVideo: Bool = false) async throws -> (EditorModel, URL) {
            let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent(isVideo ? "source.mp4" : "source.wav")
            try FileManager.default.copyItem(at: isVideo ? baseVideo : baseAudio, to: source)
            let model = EditorModel(recoveryStore: RecoveryStore(directory: folder.appendingPathComponent("Recovery")), exportHistoryURL: folder.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: folder.appendingPathComponent("Proxies")))
            model.autoCaptionImportedVideos = false; model.generatedMediaRoot = folder.appendingPathComponent("Generated"); model.reportsDirectory = folder.appendingPathComponent("Reports")
            model.libraryMediaStore = LibraryMediaStore(directory: folder.appendingPathComponent("LibraryMedia"))
            var project = Project(name: name); project.sequence.width = 320; project.sequence.height = 180
            let asset = try await MediaImporter.inspect(url: source)
            let clip = isVideo ? Clip(name: "video", assetID: asset.id, duration: MediaTime(1,1)) : Clip(name: "Trim at 2x", assetID: asset.id, start: MediaTime(5,1), sourceStart: MediaTime(seconds:0.75), duration: MediaTime(seconds:0.625), playbackRate: PlaybackRate(numerator:2))
            project.assets = [asset]; project.sequence.tracks[isVideo ? 0 : 3].clips = [clip]
            model.history = EditorHistory(project: project); model.selectedClipID = clip.id; model.selectedClipIDs = [clip.id]; model.playhead = 0.3
            return (model, source)
        }
        func library(_ model: EditorModel, _ source: URL) async throws -> LibraryAsset {
            let item = LibraryAsset(id: "test", name: "테스트 소재", category: .sfx, relativePath: source.lastPathComponent, author: "Probe", sourceURL: "local", license: "test", licenseURL: "local", sha256: try await FileIdentity.sha256(source))
            try JSONEncoder().encode([item]).write(to: source.deletingLastPathComponent().appendingPathComponent("manifest.json"))
            model.bundledLibrary = try AssetLibrary(rootURL: source.deletingLastPathComponent()); return item
        }
        func changed(_ model: EditorModel, _ action: String) {
            switch action {
            case "edit": _ = model.perform(.rename("edited while awaiting"))
            case "document": model.documentURL = root.appendingPathComponent("other.jhcut")
            case "base": model.mediaBaseURL = root.appendingPathComponent("other-base.jhcut")
            case "ABA": let value = model.project; _ = model.perform(.rename("temporary")); model.history = EditorHistory(project: value)
            case "other": model.history = EditorHistory(project: Project(name: "other document"))
            default: break
            }
        }
        func countGenerated(_ model: EditorModel) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: model.generatedMediaRoot.path).filter { !$0.hasPrefix(".") }.count) ?? 0 }
        do {
        do {
            let (model, source) = try await make("normal-analysis")
            let clip = model.selected!.1
            check("Selected audio resolved", model.selectedSound != nil)
            model.analyzeSound(); await model.productivityTask?.value
            check("Source offset and rate-adjusted duration retained", model.audioResult?.frameCount == 60000 && model.audioResult?.sourceStart == clip.sourceStart && model.audioResult?.duration == MediaTime(seconds:1.25))
            check("Completed analysis context/source current and idle", model.analysisMatchesSelection && !model.productivityBusy && model.productivityTask == nil && model.productivityJobID == nil)
            if let silence = model.audioResult?.silenceRegions.first { model.seekSilence(silence); let expected = ((clip.start.seconds + (silence.start.seconds - clip.sourceStart.seconds)/2)*30).rounded()/30; check("Silence seek retains rate mapping", abs(model.playhead-expected)<0.00001) } else { check("Silence seek retains rate mapping", false) }
            let before = model.project; model.normalizePeak(); await model.productivityTask?.value
            check("Valid normalization applies to original clip", model.project != before && model.selected!.1.volume > 1)
            model.undo(); check("Normalization single undo restores project", model.project == before)
            model.analyzeSound(); let task = model.productivityTask; model.cancelProductivity(); await task?.value
            check("Analysis cancellation clears busy/task/result", !model.productivityBusy && model.audioResult == nil && model.productivityTask == nil)
            model.transcriptionReady = false; let current = model.project; model.transcribeSelection(); check("Unavailable transcription leaves project unchanged", model.project == current && !model.productivityBusy)
            _ = source
        }
        for action in ["edit", "document", "base", "ABA", "other"] {
            let (model, _) = try await make("library-"+action); let source = model.project.assets[0].resolvedURL(relativeTo:nil); let item = try await library(model, source)
            let gate = AsyncProbeGate(); model.asyncJobBarrier = { if $0 == "library.beforeApply" { await gate.wait() } }
            model.insertLibraryAsset(item); let task = model.importTask
            check("Library task tracked "+action, task != nil)
            try await gate.awaitReached(); changed(model,action); let expected = model.project; gate.release(); await task?.value
            check("Library refuses stale "+action, model.project == expected && !model.isImporting && model.importJobID == nil)
        }
        for cancel in [true, false] {
            let (model, source) = try await make(cancel ? "library-cancel" : "library-source"); let item = try await library(model,source); let before = model.project
            let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="library.beforeApply" {await gate.wait()}}
            model.insertLibraryAsset(item);let task=model.importTask;try await gate.awaitReached()
            if cancel {model.cancelImport()} else {try audio(source,peak:0.5)}
            gate.release();await task?.value
            check(cancel ? "Library cancellation prevents insertion" : "Library source replacement prevents insertion",model.project==before && !model.isImporting)
        }
        do {
            let (model, source)=try await make("library-retained-tamper");let item=try await library(model,source);let before=model.project
            let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="library.beforeApply" {await gate.wait()}}
            model.insertLibraryAsset(item);let task=model.importTask;try await gate.awaitReached()
            let stored=try await model.libraryMediaStore.retain(source:source,item:item)
            try Data("tampered retained copy".utf8).write(to:stored)
            gate.release();await task?.value
            check("Retained copy replacement prevents insertion",model.project==before && !model.isImporting && model.error != nil)
        }
        do {
            let (model, source)=try await make("library-success");let item=try await library(model,source);let before=model.project
            model.insertLibraryAsset(item);await model.importTask?.value
            check("Normal library insertion one asset and one clip",model.project.assets.count==2 && model.project.sequence.tracks.flatMap(\.clips).count==2)
            model.undo();check("Library insertion single undo",model.project==before)
        }
        do {
            let (model,source)=try await make("missing-caption-model",isVideo:true)
            let before=model.project; model.transcriptionReady=false; model.message="Imported video"
            model.captionImportedVideos(model.project.assets)
            check("Missing caption model preserves document and explains editing remains available",model.project==before && !model.busyDocument && model.productivityTask==nil && model.message.contains("모델 없이도"))
            model.addAsset(model.project.assets[0]);let added=model.project.sequence.tracks.flatMap(\.clips).count
            model.undo()
            check("Missing caption model allows ordinary video placement and undo",added==before.sequence.tracks.flatMap(\.clips).count+1 && model.project==before && model.error==nil,source.lastPathComponent)
        }
        for action in ["edit","base","document","ABA"] {
            let (model,source)=try await make("import-"+action);let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="import.beforeApply" {await gate.wait()}}
            model.importFiles([source]);let task=model.importTask;try await gate.awaitReached();changed(model,action);let expected=model.project;gate.release();await task?.value
            check("File import refuses stale "+action,model.project==expected && !model.isImporting)
        }
        do {
            let (model,source)=try await make("import-success");let before=model.project;model.importFiles([source]);await model.importTask?.value
            check("Normal file import source hash recorded",model.project.assets.count==2 && model.project.assets.last?.contentHash != nil)
            model.undo();check("File import one undo",model.project==before)
        }
        for action in ["edit","base","document","ABA","other","source"] {
            let (model,source)=try await make("audio-"+action);let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="audio.beforeApply" {await gate.wait()}}
            model.analyzeSound();let task=model.productivityTask;try await gate.awaitReached()
            if action=="source" {try audio(source,peak:0.5)} else {changed(model,action)}
            let expected=model.project;gate.release();await task?.value
            check("Audio analysis refuses stale "+action,model.audioResult==nil && model.project==expected && !model.productivityBusy)
        }
        do {
            let (model,source)=try await make("audio-source-after");model.analyzeSound();await model.productivityTask?.value;let before=model.project
            try audio(source,peak:0.5);check("Replaced source invalidates displayed analysis",!model.analysisMatchesSelection)
            model.normalizePeak();await model.productivityTask?.value;check("Stale gain never applied",model.project==before)
        }
        for action in ["edit","document","source","cancel"] {
            let (model,source)=try await make("normalize-"+action);model.analyzeSound();await model.productivityTask?.value
            let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="normalize.beforeApply" {await gate.wait()}}
            model.normalizePeak();let task=model.productivityTask;try await gate.awaitReached()
            if action=="source" {try audio(source,peak:0.5)} else if action=="cancel" {model.cancelProductivity()} else {changed(model,action)}
            let expected=model.project;gate.release();await task?.value
            check("Normalization refuses stale "+action,model.project==expected && !model.productivityBusy)
        }
        do {
            let (model,_)=try await make("ownership-overlap");let oldGate=AsyncProbeGate(),newGate=AsyncProbeGate()
            model.asyncJobBarrier={if $0=="audio.beforeApply" {await oldGate.wait()}};model.analyzeSound();let oldTask=model.productivityTask;let oldTicket=EditorAsyncTicket(id:model.productivityJobID!,kind:.productivity,context:model.asyncContext());try await oldGate.awaitReached()
            model.playing=true;model.togglePlay();check("Pause allowed while analysis suspended",!model.playing)
            model.cancelProductivity();model.resetProductivityState();model.asyncJobBarrier={if $0=="audio.beforeApply" {await newGate.wait()}};model.analyzeSound();let newTask=model.productivityTask;try await newGate.awaitReached();let newID=model.productivityJobID
            model.productivityStatus="new job";oldGate.release();await oldTask?.value;model.acceptProductivityProgress("late old progress",ticket:oldTicket)
            check("Old catch/defer cannot clear newer task",model.productivityBusy && model.productivityTask != nil && model.productivityJobID==newID && model.productivityStatus=="new job")
            newGate.release();await newTask?.value;check("New job completes after prior cancellation",model.audioResult != nil && !model.productivityBusy)
        }
        do {
            let (model,_)=try await make("recovery-context");let gate=AsyncProbeGate()
            model.asyncJobBarrier={if $0=="audio.beforeApply" {await gate.wait()}};model.analyzeSound();let oldTask=model.productivityTask;try await gate.awaitReached()
            var restored=model.project;restored.name="explicit recovery"
            let snapshot=RecoverySnapshot(project:restored,documentURL:nil,mediaBaseURL:nil)
            try model.applyRecoverySnapshot(snapshot)
            check("Recovery entry invalidates prior job before same-ID restore",model.project==restored && !model.productivityBusy && model.productivityJobID==nil && model.audioResult==nil && model.savedData==nil)
            model.message="restored document";gate.release();await oldTask?.value
            check("Recovered document unaffected by old analysis completion",model.project==restored && model.message=="restored document" && !model.productivityBusy && model.audioResult==nil)
        }
        for operation in ["reverse","freeze","prepare","mix","proxy"] {
            for action in ["document","base","source","cancel"] {
                let (model,source)=try await make(operation+"-"+action,isVideo:operation != "mix");let before=model.project
                if operation=="mix" { model.plan=try await TimelineRenderer.build(project:model.project,documentURL:nil) }
                let gate=AsyncProbeGate();model.asyncJobBarrier={if $0==operation+".beforeApply" {await gate.wait()}}
                var retainedProgress: (@Sendable(Double)->Void)?;model.asyncProgressObserver={_,callback in retainedProgress=callback}
                var progressHandled=0;model.asyncProgressHandled={_ in progressHandled += 1}
                switch operation {
                case "reverse": model.reverseSelectedClip()
                case "freeze": model.makeFreezeFrame(seconds:0.5)
                case "prepare": model.prepareMedia(audioOnly:false,sourceURL:source,outputDirectory:model.generatedMediaRoot)
                case "mix": model.masterMix(outputDirectory:model.generatedMediaRoot)
                default: model.generateProxies()
                }
                let task=operation=="proxy" ? model.proxyTask:model.productivityTask
                guard task != nil else { throw ProjectError(operation + " did not start: " + (model.error ?? "no error") ) }
                do { try await gate.awaitReached() } catch { throw ProjectError(operation + " did not reach barrier: " + (model.error ?? model.productivityStatus)) }
                if action=="cancel" {if operation=="proxy" {model.cancelProxy()} else {model.cancelProductivity()}} else if action=="source" {try Data(repeating:0,count:128).write(to:source)} else {changed(model,action)}
                gate.release();await task?.value
                check(operation+" refuses "+action,model.project==before && !model.productivityBusy && !model.proxyBusy)
                if operation=="proxy" {check("Stale proxy mapping not published "+action,model.proxyURLs.isEmpty && !model.proxyEnabled)} else {check(operation+" unreferenced owned output removed "+action,countGenerated(model)==0)}
                if operation=="reverse", let callback=retainedProgress {
                    let ticket=model.beginAsyncJob(.productivity);model.productivityStatus="new reverse job";let oldCount=progressHandled;callback(0.5)
                    for _ in 0..<2000 {if progressHandled>oldCount {break};try await Task.sleep(nanoseconds:1_000_000)}
                    check("Real reverse callback handled "+action,progressHandled>oldCount)
                    check("Real reverse callback cannot overwrite new job "+action,model.productivityStatus=="new reverse job" && model.productivityJobID==ticket.id)
                    model.finishAsyncJob(ticket)
                }
            }
        }
        do {
            let (model,_)=try await make("mix-normal");model.plan=try await TimelineRenderer.build(project:model.project,documentURL:nil);let before=model.project
            model.masterMix(outputDirectory:model.generatedMediaRoot);await model.productivityTask?.value
            check("Normal master mix adds independent sequence",model.project.derivedSequences?.count==1 && model.project.assets.count==2 && countGenerated(model)==1,model.error ?? "")
            model.undo();check("Master mix one undo",model.project==before)
        }
        do {
            let (model,_)=try await make("proxy-normal",isVideo:true);model.generateProxies();await model.proxyTask?.value
            check("Normal proxy published with source identity",model.proxyEnabled && model.proxyURLs.count==1 && !model.proxyBusy,model.error ?? "")
            let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="proxy.beforeClear" {await gate.wait()}};model.clearProxies();let task=model.proxyTask;try await gate.awaitReached();model.cancelProxy();gate.release();await task?.value
            check("Cancelled proxy clear preserves active mapping",model.proxyEnabled && model.proxyURLs.count==1)
        }
        for operation in ["translation","evaluation"] {
            for action in ["edit","document","base","ABA","cancel","source","reference"] {
                if operation == "translation" && (action == "source" || action == "reference") { continue }
                let (model,source)=try await make(operation+"-"+action)
                let parent=model.selected!.1
                var caption=Clip(name:"원문",start:parent.start,duration:parent.duration,title:Title(text:"hello world"))
                caption.captionRole = .original;caption.captionGroupID=parent.id
                caption.connection=ClipConnection(parentID:parent.id,sourceStart:parent.sourceStart,sourceDuration:parent.sourceDuration)
                caption.captionMetadata=CaptionMetadata(language:"en",originalLanguage:"en",originalText:"hello world",generatedText:"hello world")
                var project=model.project;project.sequence.tracks[2].clips=[caption];model.history=EditorHistory(project:project)
                let reference=source.deletingLastPathComponent().appendingPathComponent("reference.srt")
                try "1\n00:00:00,750 --> 00:00:02,000\nhello world\n".write(to:reference,atomically:false,encoding:.utf8)
                model.translationProvider={texts,_,_ in texts.map{_ in "안녕하세요"}};model.translationTargetLanguage="ko"
                let gate=AsyncProbeGate();model.asyncJobBarrier={if $0==operation+".beforeApply" {await gate.wait()}}
                if operation == "translation" {model.translateCaptionTracks(scope:.all)} else {model.evaluateSelectedCaptions(referenceURL:reference)}
                let task=model.productivityTask
                do {try await gate.awaitReached()} catch {throw ProjectError(operation+" failed before barrier: "+(model.error ?? model.productivityStatus))}
                if action == "cancel" {model.cancelProductivity()} else if action == "source" {try audio(source,peak:0.5)} else if action == "reference" {try "different reference".write(to:reference,atomically:false,encoding:.utf8)} else {changed(model,action)}
                let expected=model.project;gate.release();await task?.value
                check(operation+" final boundary refuses "+action,model.project==expected && !model.productivityBusy && !model.translationActive && !model.evaluationActive)
                if operation == "evaluation" {check("Rejected evaluation discards only owned report "+action,model.lastEvaluation==nil && model.lastEvaluationReportURL==nil && ((try? FileManager.default.contentsOfDirectory(atPath:model.reportsDirectory.path).count) ?? 0)==0)}
            }
        }
        for action in ["edit","document","cancel"] {
            let (model,_)=try await make("collection-"+action);let destination=root.appendingPathComponent("Collected-"+action)
            let gate=AsyncProbeGate();model.asyncJobBarrier={if $0=="collection.beforeWork" {await gate.wait()}}
            model.collectProject(destinationURL:destination,revealsResult:false);let task=model.productivityTask;try await gate.awaitReached()
            check("Collection waits for context before starting "+action,!FileManager.default.fileExists(atPath:destination.path))
            if action=="cancel" {model.cancelProductivity()} else {changed(model,action)}
            let expected=model.project;gate.release();await task?.value
            check("Stale/cancelled collection never launches worker "+action,model.project==expected && !model.productivityBusy && !FileManager.default.fileExists(atPath:destination.path))
        }
        do {
            let (model,_)=try await make("collection-normal");let destination=root.appendingPathComponent("Collected-normal")
            let before=model.project;model.collectProject(destinationURL:destination,revealsResult:false);await model.productivityTask?.value
            check("Normal collection preserves current project and succeeds",model.project==before && FileManager.default.fileExists(atPath:destination.path) && model.message.contains("원본 수집 완료"),model.error ?? "")
        }
        do {
            let folder=root.appendingPathComponent("BackupOrder");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let doc=folder.appendingPathComponent("document.jhcut");try ProjectStore.save(Project(name:"backup"),to:doc)
            let backups=folder.appendingPathComponent("Backups")
            for _ in 0..<3 {_ = try ProjectBackup.create(documentURL:doc,root:backups,appVersion:"probe")}
            let entries=ProjectBackup.list(root:backups)
            check("Backups persist precise numeric timestamp",entries.count==3 && entries.allSatisfy{$0.manifest.createdAtEpoch != nil})
            check("Precise backup timestamps sorted newest first",zip(entries,entries.dropFirst()).allSatisfy{$0.manifest.preciseCreatedAt >= $1.manifest.preciseCreatedAt})
            check("Picker labels distinguish rapid backups",Set(entries.map(\.pickerLabel)).count==3)
            // Force a single legacy second with distinct subsecond epochs, independent of host speed.
            for (index,entry) in entries.enumerated() {
                let p=entry.folder.appendingPathComponent("manifest.json");var object=try JSONSerialization.jsonObject(with:Data(contentsOf:p)) as! [String:Any]
                object["createdAt"]="2026-10-08T00:00:00Z";object["createdAtEpoch"]=1791417600.0+Double(index)*0.01
                try JSONSerialization.data(withJSONObject:object).write(to:p)
            }
            let sorted=ProjectBackup.list(root:backups);check("Same-second backups use preserved fraction",sorted.map(\.folder)==entries.reversed().map(\.folder))
            for entry in entries {
                let p=entry.folder.appendingPathComponent("manifest.json");var object=try JSONSerialization.jsonObject(with:Data(contentsOf:p)) as! [String:Any];object.removeValue(forKey:"createdAtEpoch");try JSONSerialization.data(withJSONObject:object).write(to:p)
            }
            let legacy=ProjectBackup.list(root:backups);check("Legacy tied timestamps use deterministic folder ordering",legacy.count==3 && legacy.map(\.id)==legacy.map(\.id).sorted())
            check("Legacy manifests remain restorable",(try? ProjectBackup.restore(legacy[0])) != nil)
        }
        } catch {check("Probe execution",false,error.localizedDescription)}
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
        print("APP_PRODUCTIVITY_RESULT checks=\(rows.count) failures=\(rows.filter{($0["passed"] as? Bool) != true}.count)")
        exit(rows.allSatisfy{($0["passed"] as? Bool)==true} ? 0:1)
    }
}
#endif

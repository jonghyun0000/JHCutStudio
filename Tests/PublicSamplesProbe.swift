import Foundation
import AppKit
import AVFoundation
import CryptoKit
import CoreImage
import JHCutCore

// Procedural sample authoring. No network, camera footage, speech or external asset.
@main struct PublicSamplesProbe {
    @MainActor static func settle(_ model: EditorModel) async throws {
        for _ in 0..<2000 {
            if !model.isBuilding && !model.isImporting && !model.productivityBusy && !model.isExporting {
                try await Task.sleep(nanoseconds: 30_000_000)
                if !model.isBuilding && !model.isImporting && !model.productivityBusy && !model.isExporting { return }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProjectError("Sample operation timed out")
    }
    static func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    static func graphic(_ url: URL, index: Int, portrait: Bool, dialogue: Bool) throws {
        let w = portrait ? 1080 : 1920, h = portrait ? 1920 : 1080
        try Fixtures.writePNG(to: url, width: w, height: h) { c in
            let palettes: [[CGFloat]] = [[0.04,0.08,0.14],[0.06,0.13,0.20],[0.12,0.08,0.19]]
            let p = palettes[index]
            c.setFillColor(CGColor(red:p[0],green:p[1],blue:p[2],alpha:1)); c.fill(CGRect(x:0,y:0,width:w,height:h))
            c.setStrokeColor(CGColor(gray:1,alpha:0.06)); c.setLineWidth(1)
            for x in stride(from:0,to:w,by:80) { c.move(to:CGPoint(x:x,y:0)); c.addLine(to:CGPoint(x:x,y:h)) }
            for y in stride(from:0,to:h,by:80) { c.move(to:CGPoint(x:0,y:y)); c.addLine(to:CGPoint(x:w,y:y)) }; c.strokePath()
            let accents: [CGColor] = [CGColor(red:0.15,green:0.90,blue:0.80,alpha:1),CGColor(red:0.35,green:0.60,blue:1,alpha:1),CGColor(red:0.95,green:0.50,blue:0.38,alpha:1)]
            c.setFillColor(accents[index]); c.fill(CGRect(x:80,y:h-150,width:90,height:8))
            Fixtures.drawText("JH CUT / SAMPLE 0\(index+1)",at:CGPoint(x:80,y:h-125),size:30,context:c)
            if dialogue {
                for person in 0..<2 {
                    let x = CGFloat(100+person*900)
                    c.setFillColor(CGColor(gray:0.13+Double(person)*0.035,alpha:1)); c.fill(CGRect(x:x,y:260,width:820,height:570))
                    c.setFillColor(accents[person]); c.fillEllipse(in:CGRect(x:x+310,y:560,width:200,height:200))
                    c.fill(CGRect(x:x+240,y:370,width:340,height:150))
                    Fixtures.drawText(person == 0 ? "SPEAKER A" : "SPEAKER B",at:CGPoint(x:x+270,y:300),size:30,context:c)
                }
            } else if portrait {
                c.setStrokeColor(accents[index]); c.setLineWidth(30)
                c.strokeEllipse(in:CGRect(x:190,y:560,width:700,height:700))
                c.setFillColor(accents[(index+1)%3]); c.fill(CGRect(x:380,y:750,width:320,height:320))
                Fixtures.drawText(["CUT", "CREATE", "SHARE"][index],at:CGPoint(x:160,y:1350),size:105,context:c)
                Fixtures.drawText("YOUR NEXT STORY",at:CGPoint(x:170,y:460),size:42,context:c)
            } else {
                c.setFillColor(accents[index]); c.fill(CGRect(x:1150,y:280,width:490,height:490))
                c.setFillColor(CGColor(gray:0.06,alpha:1)); c.fillEllipse(in:CGRect(x:1260,y:390,width:270,height:270))
                Fixtures.drawText(["CREATE TOGETHER", "BUILD YOUR STORY", "SEE YOU NEXT TIME"][index],at:CGPoint(x:100,y:600),size:58,context:c)
                Fixtures.drawText("COMMUNITY / OPEN STUDIO",at:CGPoint(x:100,y:490),size:32,context:c)
                Fixtures.drawText("FICTIONAL EVENT · PROCEDURAL ART",at:CGPoint(x:100,y:310),size:26,context:c)
            }
            Fixtures.drawText("GENERATED GRAPHICS / NO RECORDED PEOPLE",at:CGPoint(x:80,y:65),size:portrait ? 21 : 24,context:c)
        }
    }
    static func chord(_ url: URL, seconds: Int, index: Int) throws {
        let rate=48000, count=rate*seconds
        var data=Data()
        func ascii(_ s:String){data.append(contentsOf:s.utf8)}
        func u16(_ n:UInt16){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        func u32(_ n:UInt32){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        ascii("RIFF");u32(UInt32(36+count*2));ascii("WAVEfmt ");u32(16);u16(1);u16(1);u32(UInt32(rate));u32(UInt32(rate*2));u16(2);u16(16);ascii("data");u32(UInt32(count*2))
        let notes=[[261.6256,329.6276,391.9954],[220.0,261.6256,329.6276],[196.0,246.9417,293.6648]][index]
        for n in 0..<count {
            let t=Double(n)/Double(rate), edge=min(1,min(t/0.3,(Double(seconds)-t)/0.4))
            let value=notes.enumerated().reduce(0.0){$0+sin(2 * .pi * $1.element * t)*0.08/(1+Double($1.offset)*0.2)}*edge
            u16(UInt16(bitPattern:Int16(value*Double(Int16.max))))
        };try data.write(to:url)
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _=NSApplication.shared
        guard CommandLine.arguments.count==2 else { throw ProjectError("Pass a NEW output directory") }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL, fm=FileManager.default
        guard !fm.fileExists(atPath:root.path) else {throw ProjectError("Refusing existing output directory")}
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let work=root.appendingPathComponent("PrivateWorking"), packs=root.appendingPathComponent("PublicSamples"), relocation=root.appendingPathComponent("Relocated")
        for dir in [work,packs,relocation]{try fm.createDirectory(at:dir,withIntermediateDirectories:true)}
        var checks:[[String:Any]]=[],results:[[String:Any]]=[]
        func check(_ name:String,_ pass:Bool,_ detail:String="") throws {
            checks.append(["name":name,"passed":pass,"detail":detail]);print("\(pass ? "PASS":"FAIL") \(name) \(detail)")
            guard pass else{throw ProjectError(name+": "+detail)}
        }
        defer {try? JSONSerialization.data(withJSONObject:["checks":checks,"results":results,"scope":"Procedural media; actual EditorModel API editing/import/save/reopen/export. No native pointer, ASR, real speaker or real footage acceptance."],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))}
        for (index,slug) in ["01-vertical-story","02-community-promo","03-dialogue-layout"].enumerated() {
            print("BEGIN_SAMPLE \(slug)")
            let folder=work.appendingPathComponent(slug);try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let portrait=index==0,dialogue=index==2,segment=Double(index==0 ? 5:(index==1 ? 7:6))
            var inputs:[URL]=[]
            for scene in 0..<3 {let url=folder.appendingPathComponent("art-\(scene+1).png");try graphic(url,index:scene,portrait:portrait,dialogue:dialogue);inputs.append(url)}
            let audio=folder.appendingPathComponent("generated-test-chord.wav");try chord(audio,seconds:Int(segment*3),index:index);inputs.append(audio)
            let originals=try Dictionary(uniqueKeysWithValues:inputs.map{($0.lastPathComponent,try sha($0))})
            let model=EditorModel(recoveryStore:RecoveryStore(directory:folder.appendingPathComponent("Recovery")),exportHistoryURL:folder.appendingPathComponent("journal.json"),proxyCache:ProxyCache(directory:folder.appendingPathComponent("Proxy")))
            model.autoCaptionImportedVideos=false;model.generatedMediaRoot=folder.appendingPathComponent("Generated");model.backupRoot=folder.appendingPathComponent("Backups");model.reportsDirectory=folder.appendingPathComponent("Reports")
            var base=Project(name:["세로 이야기 · Vertical Story","오픈 스튜디오 · Community Promo","대화 자막 레이아웃 · Dialogue Layout"][index]);base.sequence.width=portrait ? 1080:1920;base.sequence.height=portrait ? 1920:1080
            model.history=EditorHistory(project:base);model.importFiles(inputs);await model.importTask?.value;try await settle(model)
            try check(slug+" import",model.project.assets.count==4,model.error ?? "")
            let videoID=model.project.sequence.tracks.first{$0.kind == .video}!.id,titleID=model.project.sequence.tracks.first{$0.kind == .title}!.id,audioID=model.project.sequence.tracks.first{$0.kind == .audio}!.id
            var clips:[Clip]=[]
            for scene in 0..<3 {
                let asset=model.project.assets.first{$0.name == inputs[scene].lastPathComponent}!
                var clip=Clip(name:"Graphic scene \(scene+1)",assetID:asset.id,start:MediaTime(seconds:Double(scene)*segment),duration:MediaTime(seconds:segment),transform:ClipTransform(scale:1.015))
                clip.keyframes=[TransformKeyframe(time:.zero,transform:clip.transform),TransformKeyframe(time:clip.duration,transform:ClipTransform(x:Double((scene-1)*14),scale:1.06),interpolation:.ease)]
                clips.append(clip)
            }
            try check(slug+" edit transaction",model.perform(.batch(clips.map{.addClip(trackID:videoID,clip:$0)})))
            try await settle(model);let before=model.project
            try check(slug+" split",model.perform(.split(trackID:videoID,clipID:clips[0].id,at:MediaTime(seconds:2))))
            model.undo();try check(slug+" Undo exact",model.project==before);model.redo();model.undo();try check(slug+" Redo then Undo",model.project==before)
            if !dialogue {for source in clips.prefix(2){model.selectClip(source.id);model.addTransition(kind:.dissolve,direction:.fromRight,seconds:0.5)};try check(slug+" two transitions",model.project.sequence.tracks.filter{$0.transitionContext != nil}.count==2)}
            let seconds=model.project.sequence.duration.seconds
            var style=TextStyle(strokeWidth:1,backgroundHex:"071321",backgroundOpacity:0.84,padding:portrait ? 28:18,shadow:false,maxLines:2);style.wrapWidthFraction=0.86
            let heading=Title(text:portrait ? "나만의 이야기를 시작해요" : (dialogue ? "대화 자막 레이아웃 예제" : "함께 만드는 오픈 스튜디오"),fontSize:portrait ? 63:62,x:0.5,y:portrait ? 0.18:0.10,style:style)
            try check(slug+" title",model.perform(.addClip(trackID:titleID,clip:Clip(name:"Editable heading",duration:MediaTime(seconds:seconds),title:heading))))
            let captionTrack=Track(name:"수동 예문 · Manual example captions",kind:.title)
            try check(slug+" caption track",model.perform(.addTrack(captionTrack)))
            let texts=dialogue ? ["A: 오늘은 어떤 영상을 만들까요?","B: 각자의 이야기를 한 장면씩 모아 봐요.","A: 좋아요. 함께 다음 장면을 만들어 봐요."] : (portrait ? ["장면을 자르고, 흐름을 연결하고","내 이야기에 제목을 더해요","편집 가능한 무료 예제 프로젝트"] : ["이 행사는 예제로 만든 가상의 행사입니다","그래픽과 제목, 전환을 직접 수정해 보세요","날짜·장소·참가비가 없는 디자인 예제입니다"])
            let group=UUID()
            for n in 0..<3 {
                let start=Double(n)*seconds/3
                var title=Title(text:texts[n],fontSize:portrait ? 53:48,x:0.5,y:portrait ? 0.83:0.86,style:style)
                if dialogue{title.colorHex=n==1 ? "74B5FF":"58E2CF"}
                var caption=Clip(name:"수동 예문",start:MediaTime(seconds:start),duration:MediaTime(seconds:seconds/3),title:title);caption.captionRole = .original;caption.captionGroupID=group
                try check(slug+" caption \(n+1)",model.perform(.addClip(trackID:captionTrack.id,clip:caption)))
            }
            let audioAsset=model.project.assets.first{$0.name==audio.lastPathComponent}!
            try check(slug+" test chord",model.perform(.addClip(trackID:audioID,clip:Clip(name:"SYNTHETIC TEST CHORD / NO SPEECH",assetID:audioAsset.id,duration:MediaTime(seconds:seconds),volume:0.45,audioFadeIn:MediaTime(seconds:0.3),audioFadeOut:MediaTime(seconds:0.4)))))
            try await settle(model)
            let authored=model.project,document=folder.appendingPathComponent("Authored.jhcut");model.documentURL=document;model.save()
            try check(slug+" actual app save",fm.fileExists(atPath:document.path),model.error ?? "")
            let reloaded=try ProjectStore.load(from:document);try check(slug+" save timeline exact",reloaded.sequence==authored.sequence)
            let collected=packs.appendingPathComponent(slug),collectedDoc=try ProjectCollector.collect(project:reloaded,documentURL:document,to:collected)
            // Public distribution must not expose ProjectCollector's absolute fallback path.
            var portable=try JSONDecoder().decode(Project.self,from:Data(contentsOf:collectedDoc))
            for i in portable.assets.indices {guard let relative=portable.assets[i].relativePath,!relative.hasPrefix("/"),!relative.contains("..") else{throw ProjectError("Invalid relative media")};portable.assets[i].path=relative;portable.assets[i].bookmark=nil}
            try ProjectValidator.validate(portable)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            try encoder.encode(portable).write(to:collectedDoc,options:.atomic)
            let raw=String(decoding:try Data(contentsOf:collectedDoc),as:UTF8.self)
            try check(slug+" public paths",!raw.contains("/Volumes/") && !raw.contains("/Users/") && !raw.contains("/var/") && !raw.contains("\"bookmark\""))
            let moved=relocation.appendingPathComponent("different-parent-"+slug);try fm.copyItem(at:collected,to:moved)
            let movedDoc=moved.appendingPathComponent("Project.jhcut"),movedProject=try ProjectStore.load(from:movedDoc)
            try check(slug+" relocation resolves inside new parent",movedProject.assets.allSatisfy{$0.path.hasPrefix(moved.path+"/Media/") && fm.fileExists(atPath:$0.path)})
            // A distinct EditorModel must load only from the relocated disk document.
            let reopened=EditorModel(recoveryStore:RecoveryStore(directory:folder.appendingPathComponent("ReopenRecovery")),exportHistoryURL:folder.appendingPathComponent("reopen-journal.json"),proxyCache:ProxyCache(directory:folder.appendingPathComponent("ReopenProxy")))
            reopened.reportsDirectory=folder.appendingPathComponent("ReopenReports");reopened.autoCaptionImportedVideos=false;reopened.load(movedDoc);try await settle(reopened)
            try check(slug+" actual app reopen",reopened.documentURL==movedDoc && reopened.project.sequence==portable.sequence,reopened.error ?? "")
            let movie=collected.appendingPathComponent("Result.mp4")
            reopened.exportQueue.append(QueuedExport(project:reopened.project,baseURL:movedDoc,url:movie,codec:.h264,bitRate:8_000_000));reopened.startNextExport();await reopened.exportTask?.value;try await settle(reopened)
            try check(slug+" actual app export",fm.fileExists(atPath:movie.path) && reopened.exportQueue.first?.status=="완료",reopened.error ?? "")
            let decoded=try await MediaInspection.decode(movie)
            try check(slug+" all frames decoded",decoded.frameCount==Int((seconds*30).rounded()) && decoded.monotonic && abs(decoded.videoEndSeconds-seconds)<0.002,"frames=\(decoded.frameCount),end=\(decoded.videoEndSeconds)")
            try check(slug+" raster and codecs",decoded.width==base.sequence.width && decoded.height==base.sequence.height && decoded.videoCodec=="avc1" && ["aac ","mp4a"].contains(decoded.audioCodec))
            try check(slug+" decoded nonclipping test audio",decoded.audioRMS>0.01 && (decoded.metrics["audioPeak"] ?? 2)<0.95,"RMS=\(decoded.audioRMS)")
            let proof=collected.appendingPathComponent("Frames");try fm.createDirectory(at:proof,withIntermediateDirectories:true)
            guard let plan=reopened.plan else{throw ProjectError("Missing reopened preview")}
            let generator=AVAssetImageGenerator(asset:plan.composition);generator.videoComposition=plan.videoComposition;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            var frameRecords:[[String:Any]]=[]
            for frame in [30,150,270,390] where frame<decoded.frameCount {
                guard let image=decoded.images[frame] else{throw ProjectError("Missing proof frame")}
                let (preview,_)=try await generator.image(at:CMTime(value:Int64(frame),timescale:30));let diff=try MediaInspection.compare(preview,image)
                try check(slug+" preview/export frame \(frame)",diff.mean<0.035 && diff.p99<0.20,"MAE=\(diff.mean),p99=\(diff.p99)")
                try Fixtures.savePNG(image,to:proof.appendingPathComponent("frame-\(frame).png"))
                frameRecords.append(["frame":frame,"meanAbsoluteRGBError":diff.mean,"p99RGBError":diff.p99])
            }
            try check(slug+" original bytes unchanged",try inputs.allSatisfy{try sha($0)==originals[$0.lastPathComponent]})
            let result:[String:Any]=["slug":slug,"title":portable.name,"project":"Project.jhcut","movie":"Result.mp4","durationSeconds":seconds,"width":decoded.width,"height":decoded.height,"frames":decoded.frameCount,"decode":decoded.metrics,"previewComparisons":frameRecords,"audio":"Synthetic mathematical test chord. No music recording or speech. Not an ASR demo.","captions":"Manually authored fictional Korean example text; not generated by speech recognition."]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:collected.appendingPathComponent("Verification.json"))
            results.append(result)
        }
        print("PUBLIC_SAMPLES_RESULT checks=\(checks.count) failures=\(checks.filter { ($0["passed"] as? Bool) != true }.count)")
    }
}

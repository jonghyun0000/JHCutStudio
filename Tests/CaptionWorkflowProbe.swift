import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import JHCutCore

@main struct CaptionWorkflowProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared
        let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/CaptionWorkflow")
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { checks.append(["name": name, "passed": ok, "detail": detail]); print("\(ok ? "PASS" : "FAIL") \(name) \(detail)") }
        defer { try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
        let long = Title(text: String(repeating: "긴 자막 누락 재현\n", count: 40), fontSize: 42, x: 0.5, y: 0.5, style: TextStyle(shadow: false, maxLines: 2))
        let longInfo = try TitlePreviewRenderer.layout(title: long, canvasWidth: 1080)
        check("No ellipsis or max-line text loss", !longInfo.wasTruncated && longInfo.visibleLines == 40 && longInfo.lineTexts.joined() == long.text && longInfo.exceedsLineLimit)
        check("Truncated-raster false pass rejected", try !CaptionLayout.isInsideSafeArea(long, width: 1080, height: 1920))
        check("Explicit lines cannot fit below minimum", try CaptionLayout.fitted(long, width: 1080, height: 1920, minimumFontSize: 42) == nil)
        let bodies = ["한국어 어절 경계를 유지하며 긴 자막을 모두 표시합니다. 사용자가 넣은 줄바꿈\n마지막 문장도 남습니다.",
                      "日本語の「字幕」を確認します。句読点、括弧（テスト）も読みやすく表示します。\n最後の文です。",
                      "English words retain their boundaries and every sentence is rendered.\nFinal line remains visible.",
                      "가족 👨‍👩‍👧‍👦 깃발 🇰🇷 café e\u{301} 👍🏽 日本語 한국어 final"]
        for (w,h) in [(720,1280),(1280,720),(720,720)] {
            for (i,body) in bodies.enumerated() {
                var title = Title(text: body, fontSize: 48, x: 0.5, y: 0.06, style: TextStyle(strokeWidth: 3, backgroundOpacity: 0.8, padding: 22, shadow: true))
                let fit = try CaptionLayout.fitted(title, width: w, height: h)
                check("Fit \(w)x\(h) language \(i)", fit != nil && fit!.fontSize >= 24 && fit!.text == body)
                guard let fit else { continue }
                let info = try TitlePreviewRenderer.layout(title: fit, canvasWidth: Double(w))
                check("Full text/explicit newline \(w)x\(h) language \(i)", info.lineTexts.joined() == body && !info.wasTruncated)
                let pixels = try CaptionLayout.bounds(of: fit, width: w, height: h)
                let full = TitlePreviewRenderer.fullBounds(title: fit, size: CGSize(width: w,height: h))
                check("Full footprint contains actual pixels \(w)x\(h) language \(i)", pixels != nil && full != nil && full!.insetBy(dx: -2,dy: -2).contains(pixels!))
                check("Safe glyphs/stroke/background \(w)x\(h) language \(i)", try CaptionLayout.isInsideSafeArea(fit,width:w,height:h))
                try Fixtures.savePNG(TitlePreviewRenderer.image(title: fit, size: CGSize(width:w,height:h)), to: root.appendingPathComponent("layout-\(w)x\(h)-\(i).png"))
                title.style?.wrapWidthFraction = .nan
                var invalid = Project(name:"Invalid wrap"); invalid.sequence.tracks[2].clips = [Clip(name:"Title", duration:MediaTime(2,1),title:title)]
                var rejected = false; do { try ProjectValidator.validate(invalid) } catch { rejected = true }
                check("Invalid persisted wrapping rejected \(w)x\(h)-\(i)", rejected)
            }
        }
        for text in ["👨‍👩‍👧‍👦e\u{301}🇯🇵👍🏽", "（日本語の字幕）句読点、確認。"] {
            let title = Title(text:text,fontSize:60,style:TextStyle(padding:0,shadow:false))
            let info = try TitlePreviewRenderer.layout(title:title,canvasWidth:8)
            check("Tiny wrap preserves grapheme \(text)", info.lineTexts.joined() == text && info.lineTexts.allSatisfy { !$0.isEmpty && $0.count >= 1 && !$0.contains("�") })
            let boundaries = Set(text.indices.map { text[..<$0].utf16.count }).union([text.utf16.count])
            var count = 0
            check("Tiny wrap uses composed boundaries \(text)", info.lineTexts.allSatisfy { line in count += line.utf16.count; return boundaries.contains(count) })
        }
        let japanese = try TitlePreviewRenderer.layout(title:Title(text:bodies[1],fontSize:42,style:TextStyle(shadow:false)),canvasWidth:420)
        check("Japanese prohibited line boundaries", japanese.lineTexts.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in:.whitespacesAndNewlines)
            let headOK = trimmed.first.map { !"、。，．！？）］｝」』】〉》".contains($0) } ?? true
            let tailOK = trimmed.last.map { !"（［｛「『【〈《".contains($0) } ?? true
            return headOK && tailOK
        }, japanese.lineTexts.joined(separator:" | "))
        let fallback = Title(text:"없는 글꼴 · 日本語 emoji 👍🏽",fontName:"JHCut-Missing-Font-Stage8",fontSize:40,x:0.5,y:0.5)
        let fallbackInfo = try TitlePreviewRenderer.layout(title:fallback,canvasWidth:720)
        _ = try TitlePreviewRenderer.image(title:fallback,size:CGSize(width:720,height:720))
        check("Missing font has explicit render fallback", fallbackInfo.usesFallbackFont && fallbackInfo.effectiveFontName == "AppleSDGothicNeo-Bold" && fallback.fontName == "JHCut-Missing-Font-Stage8")
        var outside = Clip(name:"자막",duration:MediaTime(2,1),title:Title(text:"화면 밖 자막\n마지막 줄",fontSize:300,x:0.5,y:0,style:TextStyle(shadow:false)))
        outside.captionRole = .original
        check("Canvas-clipped full footprint reported", try CaptionReadability.assess(outside,width:640,height:360)!.outsideCanvas)
        var blocked = Project(name:"Blocked export"); blocked.sequence.width=640;blocked.sequence.height=360;blocked.sequence.tracks[2].clips=[outside]
        let blockedURL=root.appendingPathComponent("must-not-exist.mp4")
        var exportRejected=false
        do { try await ExportJob().export(plan:TimelineRenderer.build(project:blocked),to:blockedURL) {_ in} } catch { exportRejected=error.localizedDescription.contains("화면 밖") }
        check("Clipped caption export rejected before publication",exportRejected && !FileManager.default.fileExists(atPath:blockedURL.path))
        var tiny=Clip(name:"자막",duration:MediaTime(seconds:0.2),title:Title(text:"👨‍👩‍👧‍👦 e\u{301} 🇰🇷 👍🏽",fontSize:24))
        tiny.captionMetadata=CaptionMetadata(language:"en",originalLanguage:"en",originalText:tiny.title!.text,generatedText:tiny.title!.text)
        let rate=try CaptionReadability.assess(tiny,width:720,height:720)!
        check("Grapheme reading units ignore whitespace",rate.characters == 4 && rate.shortCue && rate.tooFast && rate.limit == 17)
        for (lang,limit) in [("ko",12.0),("ja",10.0),("en",17.0)] {
            tiny.captionMetadata?.language=lang
            check("Language reading heuristic \(lang)", try CaptionReadability.assess(tiny,width:720,height:720)!.limit == limit)
        }
        var p=Project(name:"Stage8 caption workflow"); p.sequence.width=1280;p.sequence.height=720
        let group=UUID()
        func caption(_ text:String,_ start:Double,_ duration:Double=2) -> Clip {
            var c=Clip(name:"자막",start:MediaTime(seconds:start),duration:MediaTime(seconds:duration),title:Title(text:text,fontSize:42,x:0.5,y:0.3,style:TextStyle(shadow:false)))
            c.captionRole = .original;c.captionGroupID=group
            c.captionMetadata=CaptionMetadata(language:"ko",originalLanguage:"ko",originalText:text,generatedText:text);return c
        }
        let a=caption("검수 문구\n원문 두 번째 줄",0), b=caption("검수 다음 문구",2), c=caption("범위 밖 검수 문구",4)
        var hidden=caption("숨긴 검수 문구",6);hidden.captionHidden=true
        let locked=caption("잠긴 검수 문구",8)
        var decorative=caption("검수 장식 제목",10);decorative.captionRole = .title;decorative.captionGroupID=nil;decorative.captionMetadata=nil
        p.sequence.tracks[2].clips=[a,b,c,hidden,decorative]
        p.sequence.tracks.append(Track(name:"Locked",kind:.title,clips:[locked],isLocked:true))
        let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"))
        model.history=EditorHistory(project:p);model.captionOperationScope="selection";model.selectedClipID=a.id;model.selectedClipIDs=[a.id,b.id,hidden.id,locked.id,decorative.id]
        model.replaceCaptionText(find:"검수",replacement:"교정",preview:true)
        check("Replacement preview is read-only and scoped",model.project == p && model.captionEditProposal?.changes.count == 2)
        check("Apply preview one atomic edit",model.applyCaptionProposal())
        let after=model.project
        check("No edits outside visible editable captions",after.sequence.tracks[2].clips.first {$0.id==c.id} == c && after.sequence.tracks[2].clips.first {$0.id==hidden.id} == hidden && after.sequence.tracks[2].clips.first {$0.id==decorative.id} == decorative && after.sequence.tracks.last!.clips[0] == locked)
        model.undo();check("Preview application undo",model.project == p);model.redo();check("Preview application redo",model.project == after)
        model.replaceCaptionText(find:"교정",replacement:"수정",preview:true);model.captionOperationScope="all"
        check("Scope changed since preview rejected",!model.applyCaptionProposal() && model.project == after)
        model.captionOperationScope="selection";model.replaceCaptionText(find:"교정",replacement:"수정",preview:true)
        model.updateCaption(a.id,text:"다른 수정");let changed=model.project
        check("Document changed since preview rejected",!model.applyCaptionProposal() && model.project == changed)
        model.history=EditorHistory(project:p);model.error=nil
        model.updateCaption(hidden.id,text:"숨김 변조");model.updateCaption(locked.id,text:"잠금 변조");model.updateCaption(c.id,text:"범위 변조");model.updateCaption(decorative.id,text:"제목 변조")
        check("Inline edit rejects hidden locked title outside scope",model.project == p)
        model.selectedClipIDs=[a.id];model.markCaptionReviewed(a.id,reviewed:true)
        let reviewed=model.project.sequence.tracks[2].clips.first {$0.id==a.id}!
        check("Explicit review mark",CaptionReview.isReviewed(reviewed))
        model.updateCaption(a.id,text:"편집 후 재검수\n새 줄");let revised=model.project.sequence.tracks[2].clips.first {$0.id==a.id}!
        check("Text edit invalidates review without removing text",!CaptionReview.isReviewed(revised) && revised.title!.text.contains("\n"))
        model.undo();check("Undo restores review decision",CaptionReview.isReviewed(model.project.sequence.tracks[2].clips.first {$0.id==a.id}!))
        var timing=reviewed;timing.duration=MediaTime(3,1);check("Timing changes invalidate review",!CaptionReview.isReviewed(timing))
        var styling=reviewed;styling.title?.colorHex="FF0000";check("Cosmetic changes retain text review",CaptionReview.isReviewed(styling))
        let document=root.appendingPathComponent("stage8-workflow.jhcut");try ProjectStore.save(model.project,to:document)
        let reopened=try ProjectStore.load(from:document)
        check("Review save/reopen equality",reopened == model.project)
        let cues=[CaptionCue(start:a.start,duration:a.duration,text:a.title!.text),CaptionCue(start:b.start,duration:b.duration,text:b.title!.text)]
        let srt=try SRTCodec.serialize(cues);try srt.write(to:root.appendingPathComponent("roundtrip.srt"),atomically:true,encoding:.utf8)
        let parsed=try SRTCodec.parse(srt)
        check("Multiline SRT roundtrip",parsed.map(\.text) == cues.map(\.text) && parsed.map(\.start) == cues.map(\.start))
        model.history=EditorHistory(project:p);model.selectedClipIDs=[a.id,b.id];model.selectedClipID=a.id
        model.mergeNextCaption(preview:true);check("Merge preview retains document",model.project == p && model.captionEditProposal?.changes.count == 2)
        check("Merge applies explicitly",model.applyCaptionProposal() && model.project.sequence.tracks[2].clips.first!.title!.text == a.title!.text+"\n"+b.title!.text)
        model.undo();check("Merge atomic undo",model.project == p)
        model.selectedClipIDs=[a.id];model.playhead=1
        model.previewCaptionSplit(characterOffset:3);check("Text split preview is read-only",model.project == p && model.captionEditProposal?.changes.count == 2)
        check("Text split explicit application",model.applyCaptionProposal())
        let pieces=model.project.sequence.tracks[2].clips.filter { $0.id==a.id || $0.lineageID==a.id }.sorted {$0.start<$1.start}
        check("Text split preserves exact graphemes and range",pieces.count == 2 && pieces.map {$0.title!.text}.joined()==a.title!.text && pieces[0].start==a.start && pieces[1].end==a.end)
        model.undo();check("Text split atomic undo",model.project == p)
        model.offsetCaptions(0.25,preview:true);check("Timing preview is read-only",model.project == p && model.captionEditProposal?.changes.count == 1)
        check("Timing preview applies only selection",model.applyCaptionProposal() && model.project.sequence.tracks[2].clips.first!.start==MediaTime(seconds:0.25) && model.project.sequence.tracks[2].clips[1] == b)
        model.undo();check("Timing atomic undo",model.project == p)
        let flags=model.captionReviewFlags(a,report:try CaptionReadability.assess(a,width:1280,height:720))
        check("Review filters expose pending and unknown speaker",flags.contains("pending") && flags.contains("speaker"))
        var uncertain=a;uncertain.captionMetadata?.languageNeedsReview=true
        check("Language uncertainty review filter",model.captionReviewFlags(uncertain,report:nil).contains("language"))
        var translated=a;translated.id=UUID();translated.captionRole = .translation
        translated.captionMetadata?.translatedFrom=a.id;translated.captionMetadata?.language="en";translated.captionMetadata?.originalLanguage="ko"
        translated.title?.text="English comparison\nSecond line remains";translated.captionMetadata?.generatedText=translated.title!.text
        var comparison=p;comparison.sequence.tracks[2].clips.append(translated)
        model.history=EditorHistory(project:comparison);model.captionOperationScope="all";model.selectedClipID=translated.id;model.selectedClipIDs=[translated.id]
        check("Exact original comparison",model.captionOriginal(for:translated)?.id == a.id)
        check("Legacy/stale translation review filter",model.captionReviewFlags(translated,report:nil).contains("translation"))
        model.playhead=8;model.seekCaptionOriginal(translated)
        check("Review origin seek selects original timeline time",model.selectedClipID == a.id && model.playhead == a.start.seconds)
        model.selectedClipID=a.id;model.selectedClipIDs=[a.id];model.playhead=1;model.previewCaptionSplit(characterOffset:3)
        check("Text split refuses linked original atomically",model.captionEditProposal == nil && model.project == comparison && model.error?.contains("번역") == true)
        // GUI uses this own, non-private project; review model checks do not claim GUI usability.
        try ProjectStore.save(comparison,to:root.appendingPathComponent("gui-fixture.jhcut"))
        var unfitProject=Project(name:"Unfit warning");var unfitClip=a;unfitClip.title=long
        unfitProject.sequence.tracks[2].clips=[unfitClip]
        model.history=EditorHistory(project:unfitProject);model.captionOperationScope="all";model.selectedClipID=unfitClip.id;model.selectedClipIDs=[unfitClip.id]
        check("Unfit no-op reports failure without clipping",!model.applyCaptionBatch(CaptionBatchChange(),fitSafeArea:true) && model.project==unfitProject && model.message.contains("맞출 수 없는"))
        let legacyURL=root.appendingPathComponent("legacy-stage7.jhcut")
        try ProjectStore.save(p,to:legacyURL);let legacyBytes=try Data(contentsOf:legacyURL)
        var upgraded=p;upgraded.sequence.tracks[2].clips[0]=CaptionReview.marking(a,reviewed:true)
        upgraded.sequence.tracks[2].clips[0].title?.style?.wrapWidthFraction=0.76
        try ProjectStore.save(upgraded,to:legacyURL)
        let permanent=ProjectStore.beforeCaptionReviewLayoutURL(for:legacyURL)
        check("Pre-stage8 permanent copy",try Data(contentsOf:permanent)==legacyBytes)
        try ProjectStore.save(upgraded,to:legacyURL)
        check("Permanent copy survives later saves",try Data(contentsOf:permanent)==legacyBytes)
        check("Review/wrapping fields reopen",try ProjectStore.load(from:legacyURL)==upgraded)
        // Actual preview/export comparison includes entry, stable text and exit, with two languages.
        var animated=Project(name:"Multilingual animated output");animated.sequence.width=640;animated.sequence.height=360
        var ko=caption("한국어 전체 문장\n마지막 줄 보존",0,2);ko.title?.fontSize=28;ko.title?.y=0.65
        ko.titleAnimation=TitleAnimation(inKind:.slideUp,outKind:.typewriter,inSeconds:0.4,outSeconds:0.4)
        var en=caption("English translation\nEvery line retained",0,2);en.captionRole = .translation;en.title?.fontSize=28;en.title?.y=0.25;en.title?.colorHex="FFE55B"
        en.captionMetadata?.translatedFrom=ko.id;en.captionMetadata?.language="en";en.titleAnimation=TitleAnimation(inKind:.fade,outKind:.slideDown,inSeconds:0.4,outSeconds:0.4)
        animated.sequence.tracks[2].clips=[ko,en]
        let plan=try await TimelineRenderer.build(project:animated),movie=root.appendingPathComponent("animated-multilingual.mp4")
        try await ExportJob().export(plan:plan,to:movie) {_ in}
        let preview=AVAssetImageGenerator(asset:plan.composition);preview.videoComposition=plan.videoComposition
        let output=AVAssetImageGenerator(asset:AVURLAsset(url:movie))
        for generator in [preview,output] {generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero}
        for frame in [1,6,15,30,48,54,58] {
            let time=CMTime(value:Int64(frame),timescale:30)
            let x=try await preview.image(at:time).image,y=try await output.image(at:time).image
            let diff=try MediaInspection.compare(x,y)
            check("Animated preview/export frame \(frame)",diff.mean<0.035 && diff.p99<0.2,"MAE=\(diff.mean),p99=\(diff.p99)")
            try Fixtures.savePNG(y,to:root.appendingPathComponent("animated-frame-\(frame).png"))
        }
        let decoded=try await MediaInspection.decode(movie)
        check("Actual multilingual export 60 frames",decoded.frameCount == 60 && abs(decoded.videoEndSeconds-2)<0.001)
        print("CAPTION_WORKFLOW_RESULT checks=\(checks.count) failures=\(checks.filter { ($0["passed"] as? Bool) != true }.count)")
        if checks.contains(where:{($0["passed"] as? Bool) != true}) { throw ProjectError("Caption workflow regressions failed") }
    }
}

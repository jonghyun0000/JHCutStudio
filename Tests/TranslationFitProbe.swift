import Foundation
import AppKit
import JHCutCore

// Authored fixture and deterministic translation adapter validate presentation mechanics only.
// They are never a reference transcript or a semantic translation quality score.
@main struct TranslationFitProbe {
 @MainActor static func main() async throws {
  setbuf(stdout,nil); _ = NSApplication.shared
  let root=try ProbeWorkspace.prepare(defaultPath:"Artifacts/TranslationFit")
  var checks:[[String:Any]]=[]
  func check(_ name:String,_ passed:Bool) { checks.append(["name":name,"passed":passed]);print("\(passed ? "PASS":"FAIL") \(name)") }
  defer {try? JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("checks.json"))}
  let model=EditorModel(recoveryStore:RecoveryStore(directory:root.appendingPathComponent("Recovery")),exportHistoryURL:root.appendingPathComponent("journal.json"))
  model.autoCaptionImportedVideos=false;model.translateAfterTranscription=false
  model.translationTargetLanguage="en";model.translationSourceLanguage="ko";model.bilingualTranslation=true
  let originalText="- 형이 많이 깔아줬어."
  let englishText="- My older brother gave me a lot of compliments."
  var original=Clip(name:"자동 자막",start:MediaTime(seconds:2.1812833333),duration:MediaTime(seconds:1.0387166667),title:Title(text:originalText,fontName:"AppleSDGothicNeo-Bold",fontSize:58,x:0.5,y:0.15,style:TextStyle(strokeWidth:3,backgroundOpacity:0,padding:20,maxLines:4,lineSpacing:8)))
  original.captionRole = .original
  original.captionMetadata=CaptionMetadata(language:"ko",originalLanguage:"ko",originalText:originalText,generatedText:originalText)
  var fixture=Project(name:"Authored bilingual fit mechanics")
  fixture.sequence.width=1080;fixture.sequence.height=1920;fixture.sequence.tracks[2].clips=[original]
  var requests=0
  model.translationBatchProvider={ input,_,_ in requests += 1;return input.map {CaptionTranslationResponse(id:$0.id,text:englishText)} }
  func settle() async throws {
   let deadline=Date().addingTimeInterval(30)
   while model.productivityBusy || model.productivityTask != nil || model.isBuilding {
    if Date()>deadline {throw ProjectError("Translation-fit timeout")}
    try await Task.sleep(nanoseconds:10_000_000)
   }
   if let error=model.error {throw ProjectError(error)}
  }
  func translated()->Clip? {CaptionQuery.entries(in:model.project.sequence,role:.translation).first?.clip}
  let unfitted=try CaptionTranslationEditing.translated(original,text:englishText,sourceLanguage:"ko",targetLanguage:"en",bilingual:true)
  check("Actual bilingual font58/y.15 fixture starts outside safe area",try CaptionReadability.assess(unfitted,width:1080,height:1920)?.outsideSafeArea == true)
  model.history=EditorHistory(project:fixture);model.translateCaptionTracks();try await settle()
  guard let fitted=translated(),let title=fitted.title else {throw ProjectError("Translation missing")}
  check("New generated bilingual caption fits full glyph safe bounds",try CaptionLayout.isInsideSafeArea(title,width:1080,height:1920))
  check("All text and explicit newline retained",title.text == originalText+"\n"+englishText)
  check("Exact time and source linkage retained",fitted.start==original.start && fitted.duration==original.duration && fitted.captionMetadata?.translatedFrom==original.id)
  check("Translation metadata preserves generated text",fitted.captionMetadata?.generatedText==title.text && fitted.captionMetadata?.originalText==originalText)
  check("Font minimum retained",title.fontSize>=24)
  check("Fitting does not hide reading-speed warning",try CaptionReadability.assess(fitted,width:1080,height:1920)?.tooFast == true)
  let generated=model.project
  model.undo();check("Undo returns exact original project",model.project==fixture)
  model.redo();check("Redo returns exact fitted project",model.project==generated)
  let document=root.appendingPathComponent("fitted.jhcut");try ProjectStore.save(generated,to:document)
  check("Saved/reloaded geometry and metadata match",try ProjectStore.load(from:document)==generated)
  let count=requests;model.translateCaptionTracks();try await settle()
  check("Current translations reused without presentation mutation",requests==count && model.project==generated)
  guard let entry=CaptionQuery.entries(in:model.project.sequence,role:.translation).first else {throw ProjectError("Missing editable translation")}
  var manual=entry.clip;manual.title?.text="직접 편집\nManual edit";manual.title?.y=0.03;manual.title?.fontSize=62
  _=model.perform(.updateClip(trackID:entry.track.id,clip:manual));try await settle()
  let manualProject=model.project;model.translateCaptionTracks();try await settle()
  check("Manual text/font/outside positioning preserved exactly",model.project==manualProject && translated()==manual)
  model.history=EditorHistory(project:fixture);model.fitNewTranslatedCaptions=false;model.translateCaptionTracks();try await settle()
  check("Option off preserves prior generated presentation",translated()?.title==unfitted.title)
  model.productivityTask?.cancel();model.player.replaceCurrentItem(with:nil)
  if checks.contains(where:{$0["passed"] as? Bool != true}) {exit(1)}
 }
}

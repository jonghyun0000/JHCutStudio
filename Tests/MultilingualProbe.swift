import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import JHCutCore

@main struct MultilingualProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Multilingual-0.6", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") {
   rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
  }
  func saveResults() throws { try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  func makeModel(_ name: String) -> EditorModel {
   EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery-" + name)), exportHistoryURL: root.appendingPathComponent("journal-" + name + ".json"))
  }
  func settle(_ model: EditorModel) async throws {
   let deadline = Date().addingTimeInterval(360)
   while model.isImporting || model.productivityBusy || model.importTask != nil {
    guard Date() < deadline else { model.cancelProductivity(); model.cancelImport(); throw ProjectError("Probe timeout") }
    try await Task.sleep(nanoseconds: 50_000_000)
   }
  }
  let scripts = [
   "ko": "안녕하세요. 오늘은 공원에서 영상을 촬영합니다. 날씨가 좋아서 친구와 함께 산책을 하고 있습니다. 잠시 후에는 카페에서 따뜻한 차를 마실 예정입니다.",
   "ja": "こんにちは。今日は公園で動画を撮影しています。",
   "en": "Hello everyone. Today we are filming a video in the park. The weather is beautiful, so I am taking a walk with my friend. Later we will visit a cafe and have a cup of warm tea."
  ]
  let voices = ["ko": "Yuna", "ja": "Kyoko", "en": "Samantha"]
  var sources: [URL] = []
  do {
   for language in ["ko","ja","en"] {
    let audio = root.appendingPathComponent(language + ".aiff")
    if !FileManager.default.fileExists(atPath: audio.path) {
     let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
     process.arguments = ["-v", voices[language]!, "-r", "155", "-o", audio.path, scripts[language]!]
     try process.run()
     let deadline = Date().addingTimeInterval(30)
     while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
     guard !process.isRunning else { process.terminate(); throw ProjectError("Speech fixture timed out") }
     guard process.terminationStatus == 0 else { throw ProjectError("Speech fixture failed") }
    }
    let file = root.appendingPathComponent(language + "-speech.mp4")
    if !FileManager.default.fileExists(atPath: file.path) {
     let asset = try await MediaImporter.inspect(url: audio)
     var fixture = Project(name: language + " known speech"); fixture.sequence.width = 640; fixture.sequence.height = 360; fixture.assets = [asset]
     let ti = fixture.sequence.tracks.firstIndex { $0.kind == .audio }!
     fixture.sequence.tracks[ti].clips = [Clip(assetID: asset.id, duration: asset.duration)]
     try await ExportJob().export(plan: TimelineRenderer.build(project: fixture), to: file) { _ in }
    }
    sources.append(file)
   }
   let model = makeModel("main")
   var initial = Project(name: "한일영 자동 감지·번역 검증"); initial.sequence.width = 640; initial.sequence.height = 360
   model.history = EditorHistory(project: initial)
   check("Import captions, translation and language auto-detection default on", model.autoCaptionImportedVideos && model.translateAfterTranscription && model.speechOptions.language == "auto" && model.translationTargetLanguage == "ko")
   model.importFiles(sources); try await settle(model)
   check("Import-to-caption-to-translation pipeline completes", model.error == nil && !model.captionClips.isEmpty, model.error ?? model.message)
   let originals = model.captionClips.filter { $0.captionMetadata?.translatedFrom == nil }
   let translations = model.captionClips.filter { $0.captionMetadata?.translatedFrom != nil }
   for language in ["ko","ja","en"] {
    let asset = model.project.assets.first { $0.name.hasPrefix(language + "-speech") }
    let parent = model.project.sequence.tracks.flatMap(\.clips).first { $0.assetID == asset?.id && $0.title == nil }
    let cues = originals.filter { $0.connection?.parentID == parent?.id }
    check("Actual \(language) voice detected and captioned", !cues.isEmpty && cues.allSatisfy { $0.captionMetadata?.language == language }, cues.map { $0.title!.text }.joined(separator: " | "))
    check("\(language) cues stay within source clip", parent != nil && !cues.isEmpty && cues.allSatisfy { $0.start >= parent!.start && $0.end <= parent!.end })
   }
   check("Every original has a separate Korean target cue", originals.count > 0 && translations.count == originals.count && translations.allSatisfy { $0.captionMetadata?.language == "ko" })
   check("Translation retains original text, timing and source attachment", translations.allSatisfy { translated in
    guard let original = originals.first(where: { $0.id == translated.captionMetadata?.translatedFrom }) else { return false }
    return translated.captionMetadata?.originalText == original.title?.text && translated.start == original.start && translated.duration == original.duration && translated.connection?.parentID == original.connection?.parentID
   })
   check("Visible SRT exports only the target captions", model.exportableCaptionClips.count == translations.count && model.exportableCaptionClips.allSatisfy { $0.captionMetadata?.translatedFrom != nil })
   model.subtitleExportScope = "original"; check("Original SRT scope preserves all three languages", model.exportableCaptionClips.count == originals.count)
   model.subtitleExportScope = "visible"
   let cues = model.exportableCaptionClips.map { CaptionCue(start: $0.start, duration: $0.duration, text: $0.title!.text) }
   let srt = try SRTCodec.serialize(cues)
   try srt.write(to: root.appendingPathComponent("translated-ko.srt"), atomically: true, encoding: .utf8)
   check("Translated SRT round trip", try SRTCodec.parse(srt).map(\.text) == cues.map(\.text))
   let captioned = model.project
   let projectURL = root.appendingPathComponent("Multilingual.jhcut")
   try ProjectStore.save(captioned, to: projectURL)
   let loaded = try ProjectStore.load(from: projectURL)
   check("Save/reopen retains original and translation metadata", loaded.sequence == captioned.sequence)
   model.undo(); check("Translation undo leaves original captions", model.captionClips.count == originals.count && model.exportableCaptionClips.count == originals.count)
   model.redo(); check("Translation redo restores document", model.project == captioned)
   if let videoTrack = model.project.sequence.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }), let parent = videoTrack.clips.last {
    let before = model.captionClips.filter { $0.connection?.parentID == parent.id }
    model.perform(.move(trackID: videoTrack.id, clipID: parent.id, to: parent.start + MediaTime(5,1)))
    check("Original and translation follow moved video", !before.isEmpty && before.allSatisfy { old in model.captionClips.contains { $0.id == old.id && $0.start == old.start + MediaTime(5,1) } })
    model.undo()
   }
   let beforeRepeat = model.project.sequence.tracks.count
   if let first = translations.first { model.updateCaption(first.id, text: "직접 수정한 번역을 보존합니다.") }
   model.translateCaptionTracks(); try await settle(model)
   check("Repeat translation preserves manual correction and reuses track", model.error == nil && model.project.sequence.tracks.count == beforeRepeat && model.captionClips.contains { $0.title?.text == "직접 수정한 번역을 보존합니다." })
   model.history = EditorHistory(project: captioned); model.bilingualTranslation = true; model.translationTargetLanguage = "en"
   model.translateCaptionTracks(); try await settle(model)
   let english = model.exportableCaptionClips
   check("Changing target creates visible English track", model.error == nil && english.count == originals.count && english.allSatisfy { $0.captionMetadata?.language == "en" })
   check("Bilingual mode stores original plus translation", english.filter { $0.captionMetadata?.originalLanguage != "en" }.allSatisfy { $0.title!.text.hasPrefix($0.captionMetadata!.originalText + "\n") })
   model.showOriginalCaptionTracks(); check("Show originals restores originals without deleting translations", model.exportableCaptionClips.count == originals.count && model.exportableCaptionClips.allSatisfy { $0.captionMetadata?.translatedFrom == nil } && model.captionClips.count > originals.count)
   // Regenerate a source whose original track is hidden: visibility updates must not overwrite new cues.
   model.history = EditorHistory(project: captioned); model.translateAfterTranscription = false; model.error = nil
   if let parent = model.project.sequence.tracks.flatMap(\.clips).first(where: { $0.assetID != nil && $0.title == nil }) {
    let priorIDs = Set(originals.filter { $0.connection?.parentID == parent.id }.map(\.id))
    model.selectClip(parent.id); model.transcribeSelection(); try await settle(model)
    let regenerated = model.captionClips.filter { $0.connection?.parentID == parent.id && $0.captionMetadata?.translatedFrom == nil }
    check("Regeneration on hidden original track keeps new cues", model.error == nil && !regenerated.isEmpty && regenerated.allSatisfy { !priorIDs.contains($0.id) })
   }
   // Fault injection tests editor atomicity only; real Apple translations are tested above and below.
   model.history = EditorHistory(project: captioned); model.translationTargetLanguage = "ja"; model.error = nil
   let beforeFailure = model.project
   model.translationProvider = { _,_,_ in throw ProjectError("Injected translation failure") }
   model.translateCaptionTracks(); try await settle(model)
   check("Provider failure preserves entire document", model.project == beforeFailure && model.error?.contains("Injected") == true)
   model.error = nil; model.translationProvider = { texts,_,_ in try await Task.sleep(nanoseconds: 5_000_000_000); return texts }
   model.translateCaptionTracks(); model.cancelProductivity(); try await settle(model)
   check("Cancel preserves original and prior translations", model.project == beforeFailure && !model.translationActive && model.error == nil)
   model.translationProvider = { texts,_,_ in try await Task.sleep(nanoseconds: 200_000_000); return texts }
   model.translateCaptionTracks(); var changed = beforeFailure; changed.name = "Changed while translating"; model.history = EditorHistory(project: changed)
   try await settle(model)
   check("Stale translation cannot overwrite newer edits", model.project == changed && model.error?.contains("프로젝트가 변경") == true)
   model.history = EditorHistory(project: captioned); model.error = nil
   model.translationProvider = { _,_,_ in [] }; model.translateCaptionTracks(); try await settle(model)
   check("Missing response cannot partially replace captions", model.project == captioned && model.error != nil)
   let disabled = makeModel("disabled"); disabled.autoCaptionImportedVideos = false
   disabled.importFiles([sources[0]]); try await settle(disabled)
   check("Import automation can be disabled", disabled.project.assets.count == 1 && disabled.project.sequence.tracks.flatMap(\.clips).isEmpty)
   for source in ["ko","ja","en"] { for target in ["ko","ja","en"] where source != target {
    let result = try await CaptionTranslation.translate([scripts[source]!], from: source, to: target)
    check("Actual Apple \(source)→\(target) translation", result.count == 1 && !result[0].isEmpty && result[0] != scripts[source]!, result.joined())
   } }
   let batch = (0..<33).map { "Today I have \($0 + 1) apples." }
   let batchResult = try await CaptionTranslation.translate(batch, from: "en", to: "ko")
   check("Batch boundary retains all 33 response positions", batchResult.count == 33 && batchResult.enumerated().allSatisfy { $0.element.contains(String($0.offset + 1)) })
   let identical = try await CaptionTranslation.translate(["안녕하세요"],from:"ko",to:"ko")
   check("Same-language translation is identity", identical == ["안녕하세요"])
   do { _ = try await CaptionTranslation.translate([""],from:"en",to:"ko"); check("Empty text rejected",false) } catch { check("Empty text rejected",true) }
   do { _ = try await CaptionTranslation.translate(["Hello"],from:"xx",to:"ko"); check("Unsupported language rejected",false) } catch { check("Unsupported language rejected",true) }
   let output = root.appendingPathComponent("translated-output-" + UUID().uuidString.prefix(8) + ".mp4")
   let plan = try await TimelineRenderer.build(project: captioned)
   try await ExportJob().export(plan: plan, to: output) { _ in }
   let media = try await MediaImporter.inspect(url: output)
   check("Translated video exports with audio and full duration", media.hasAudio && abs(media.duration.seconds - captioned.sequence.duration.seconds) < 0.05, output.path)
   if let cue = translations.first(where: { $0.captionMetadata?.originalLanguage == "ja" }) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output)); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(at: CMTime(seconds: cue.start.seconds + cue.duration.seconds / 2, preferredTimescale: 600), actualTime: nil)
    let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("translated-frame.png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
    var pixels = [UInt8](repeating:0,count:640*360*4)
    let context = CGContext(data:&pixels,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image,in:CGRect(x:0,y:0,width:640,height:360))
    let bright = stride(from:0,to:pixels.count,by:4).filter { pixels[$0] > 90 && pixels[$0+1] > 90 }.count
    check("Visible translated captions burned into video", bright > 100, "\(bright) bright pixels")
   }
   try saveResults()
   if rows.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
  } catch { check("Unexpected error", false, error.localizedDescription); try saveResults(); exit(1) }
 }
}

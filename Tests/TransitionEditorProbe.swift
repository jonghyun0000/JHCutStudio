import Foundation
import AppKit
import JHCutCore

/// Editor flows for transitions and title animation: selection rules, changing the kind, 0.6-style dissolves,
/// locked tracks, applying one animation to every caption in a single undo step.
@main struct TransitionEditorProbe {
 @MainActor static func main() async throws {
  setbuf(stdout, nil); _ = NSApplication.shared
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/TransitionEditor", isDirectory: true).standardizedFileURL
  try? FileManager.default.removeItem(at: root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }

  let png = root.appendingPathComponent("s.png")
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  try rep.representation(using: .png, properties: [:])!.write(to: png)
  var asset = try await MediaImporter.inspect(url: png); asset.duration = MediaTime(seconds: 4)
  func makeProject() -> Project {
   var p = Project(name: "전환 편집"); p.sequence.width = 640; p.sequence.height = 360; p.assets = [asset]
   p.sequence.tracks[0].clips = (0..<3).map { Clip(name: "장면\($0 + 1)", assetID: asset.id, start: MediaTime(seconds: Double($0) * 4), duration: MediaTime(seconds: 4)) }
   return p
  }
  let model = EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"))
  var project = makeProject(); model.history = EditorHistory(project: project)
  let first = project.sequence.tracks[0].clips[0]
  // Selection rules
  model.selectedClipID = nil; model.selectedClipIDs = []
  model.addTransition(kind: .wipe, direction: .fromLeft, seconds: 1)
  check("Nothing selected: refused with a message", model.error != nil && model.project == project, model.error ?? ""); model.error = nil
  model.selectedClipID = first.id; model.selectedClipIDs = [first.id]
  model.addTransition(kind: .wipe, direction: .fromLeft, seconds: 1)
  let overlap = model.project.sequence.tracks.flatMap(\.clips).first { $0.name == "장면2" }!
  check("Selected clip: transition added to the next clip", overlap.transition?.kind == .wipe && overlap.transition?.direction == .fromLeft && overlap.start == MediaTime(seconds: 3), model.message)
  check("Message explains the overlap in plain words", model.message.contains("와이프") && model.message.contains("앞당겨"), model.message)
  model.undo(); check("One undo removes it", model.project == project)
  model.redo()
  // Change kind on the incoming clip
  let overlayTrack = model.project.sequence.tracks.first { $0.kind == .overlay && $0.clips.contains { $0.name == "장면2" } }!
  model.selectedClipID = overlap.id; model.selectedClipIDs = [overlap.id]
  check("The incoming clip is recognised as a transition", model.transitionOf(overlap, on: overlayTrack)?.kind == .wipe)
  model.changeTransition(kind: .slide, direction: .fromTop)
  var changed = model.project.sequence.tracks.flatMap(\.clips).first { $0.name == "장면2" }!
  check("Kind and side change, length stays", changed.transition == ClipTransition(kind: .slide, direction: .fromTop, duration: MediaTime(seconds: 1)) && changed.fadeIn == nil)
  model.changeTransition(kind: .dissolve, direction: .fromRight)
  changed = model.project.sequence.tracks.flatMap(\.clips).first { $0.name == "장면2" }!
  check("Back to dissolve restores the fade-in", changed.transition?.kind == .dissolve && changed.fadeIn == MediaTime(seconds: 1))
  model.undo(); model.undo()
  check("Two changes = two undo steps", model.project.sequence.tracks.flatMap(\.clips).first { $0.name == "장면2" }?.transition?.kind == .wipe)
  // 0.6-style dissolve (no `transition`, fade-in only, track named 디졸브)
  var legacy = makeProject(); var h = EditorHistory(project: legacy)
  try h.apply(.crossDissolve(trackID: legacy.sequence.tracks[0].id, clipID: legacy.sequence.tracks[0].clips[0].id, duration: MediaTime(seconds: 0.5)))
  legacy = h.project
  for t in legacy.sequence.tracks.indices { for c in legacy.sequence.tracks[t].clips.indices { legacy.sequence.tracks[t].clips[c].transition = nil }; if legacy.sequence.tracks[t].kind == .overlay { legacy.sequence.tracks[t].name = "디졸브 · 장면2" } }
  model.history = EditorHistory(project: legacy)
  let old = legacy.sequence.tracks.flatMap(\.clips).first { $0.name == "장면2" }!, oldTrack = legacy.sequence.tracks.first { $0.kind == .overlay }!
  model.selectedClipID = old.id; model.selectedClipIDs = [old.id]
  check("A 0.6 dissolve is recognised", model.transitionOf(old, on: oldTrack)?.kind == .dissolve)
  model.changeTransition(kind: .push, direction: .fromRight)
  check("It can be changed to another kind", model.project.sequence.tracks.flatMap(\.clips).first { $0.name == "장면2" }?.transition?.kind == .push)
  // Locked track
  var locked = makeProject(); locked.sequence.tracks[0].isLocked = true; model.history = EditorHistory(project: locked)
  model.selectedClipID = locked.sequence.tracks[0].clips[0].id; model.selectedClipIDs = [model.selectedClipID!]
  model.addTransition(kind: .zoom, direction: .fromRight, seconds: 0.5)
  check("Locked main track: refused, nothing changes", model.project == locked && model.error != nil, model.error ?? ""); model.error = nil
  // Overlong
  model.history = EditorHistory(project: makeProject()); model.selectedClipID = model.project.sequence.tracks[0].clips[0].id; model.selectedClipIDs = [model.selectedClipID!]
  model.addTransition(kind: .wipe, direction: .fromLeft, seconds: 9)
  check("Longer than the clips: refused with the reason", model.error?.contains("짧은") == true, model.error ?? ""); model.error = nil

  // Title animation
  var tp = Project(name: "자막 애니메이션"); tp.sequence.width = 640; tp.sequence.height = 360; tp.assets = [asset]
  tp.sequence.tracks[0].clips = [Clip(name: "배경", assetID: asset.id, duration: MediaTime(seconds: 4))]
  let style = TitleSizing.title(for: TitlePreset.builtIns[0], width: 640, height: 360)
  func caption(_ text: String, _ start: Double, _ seconds: Double) -> Clip { var t = style; t.text = text; return Clip(name: "자막", start: MediaTime(seconds: start), duration: MediaTime(seconds: seconds), title: t) }
  tp.sequence.tracks[2].clips = [caption("첫 번째", 0, 1.5), caption("두 번째", 1.5, 0.4), caption("세 번째", 2, 1)]
  var hidden = Track(name: "숨긴 자막", kind: .title, isHidden: true); hidden.clips = [caption("숨김", 0, 1)]
  var lockedTitles = Track(name: "잠긴 자막", kind: .title, isLocked: true); lockedTitles.clips = [caption("잠김", 3, 0.8)]
  tp.sequence.tracks += [hidden, lockedTitles]
  model.history = EditorHistory(project: tp)
  let titleClip = tp.sequence.tracks[2].clips[0]
  model.selectedClipID = titleClip.id; model.selectedClipIDs = [titleClip.id]
  model.setTitleAnimation(TitleAnimation(inKind: .pop, outKind: .fade, inSeconds: 0.4, outSeconds: 0.3))
  check("Animation set on the selected caption", model.project.sequence.tracks[2].clips[0].titleAnimation == TitleAnimation(inKind: .pop, outKind: .fade, inSeconds: 0.4, outSeconds: 0.3))
  model.undo(); check("Setting it is one undo step", model.project.sequence.tracks[2].clips[0].titleAnimation == nil)
  model.setTitleAnimation(TitleAnimation(inKind: .fade, inSeconds: 9))
  check("Overlong animation refused with the reason", model.error != nil && model.project.sequence.tracks[2].clips[0].titleAnimation == nil, model.error ?? ""); model.error = nil
  model.setTitleAnimation(TitleAnimation())
  check("An empty animation is stored as none", model.project.sequence.tracks[2].clips[0].titleAnimation == nil)
  let before = model.project
  model.applyTitleAnimationToAllCaptions(TitleAnimation(inKind: .slideUp, outKind: .fade, inSeconds: 0.5, outSeconds: 0.5))
  let clips = model.project.sequence.tracks[2].clips
  check("Every visible unlocked caption got the animation", clips.allSatisfy { $0.titleAnimation?.inKind == .slideUp }, model.message)
  check("A 0.4 s caption gets proportionally shorter animations instead of being skipped", { let short = clips[1].titleAnimation!; return short.inSeconds + short.outSeconds <= 0.4 * 0.8 + 1e-6 && short.inSeconds >= 0.05 }())
  check("Hidden and locked tracks are untouched", model.project.sequence.tracks[4].clips[0].titleAnimation == nil && model.project.sequence.tracks[5].clips[0].titleAnimation == nil)
  check("Message reports the skipped locked caption", model.message.contains("제외"), model.message)
  model.undo(); check("Applying to all is a single undo step", model.project == before)
  model.redo()
  let doc = root.appendingPathComponent("Animated.jhcut")
  try ProjectStore.save(model.project, to: doc)
  check("Save/reopen keeps every animation", try ProjectStore.load(from: doc).sequence == model.project.sequence)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("TRANSITION_EDITOR_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

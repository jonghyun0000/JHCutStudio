import Foundation
import JHCutCore

@main struct ConnectedEditingProbe {
 static func main() throws {
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.5/Connected")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var checks: [[String: Any]] = []
  func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)") }
  let asset = MediaAsset(name: "Source", path: "/fixture/source.mov", kind: .video, duration: MediaTime(60,1), width: 1920, height: 1080, hasAudio: true)
  let source = Clip(name: "Speech", assetID: asset.id, start: MediaTime(2,1), sourceStart: MediaTime(10,1), duration: MediaTime(6,1))
  let cues = [CaptionCue(start: MediaTime(11,1), duration: MediaTime(4,1), text: "이동과 분할 뒤에도 싱크 유지")]
  var p = Project(); p.assets = [asset]; p.sequence.tracks[0].clips = [source]
  p.sequence.tracks[2].clips = CaptionEditing.automaticClips(cues: cues, source: source, style: TitlePreset.builtIns[0].title)
  let tid = p.sequence.tracks[0].id, captionID = p.sequence.tracks[2].clips[0].id
  var h = EditorHistory(project: p)
  try h.apply(.separateAudio(trackID: tid, clipID: source.id))
  let separated = h.project
  do { try h.apply(.separateAudio(trackID: tid, clipID: source.id)); check("Repeated audio separation refused", false) } catch { check("Repeated audio separation refused", h.project == separated) }
  try h.apply(.move(trackID: tid, clipID: source.id, to: MediaTime(7,1)))
  check("Move keeps caption sync", h.project.sequence.tracks[2].clips[0].start == MediaTime(8,1))
  check("Move keeps detached dialogue sync", h.project.sequence.tracks[3].clips[0].start == MediaTime(7,1))
  h.undo(); check("Undo restores connected state", h.project == separated); h.redo()
  try ProjectStore.save(h.project, to: root.appendingPathComponent("connected.jhcut"))
  let loaded = try ProjectStore.load(from: root.appendingPathComponent("connected.jhcut"))
  check("Connections survive document round trip", loaded.sequence == h.project.sequence)
  h = EditorHistory(project: separated)
  try h.apply(.split(trackID: tid, clipID: source.id, at: MediaTime(5,1)))
  check("Split divides spanning caption", h.project.sequence.tracks[2].clips.count == 2)
  check("Split divides connected audio", h.project.sequence.tracks[3].clips.count == 2)
  let right = h.project.sequence.tracks[0].clips[1]
  try h.apply(.move(trackID: tid, clipID: right.id, to: MediaTime(10,1)))
  check("Right fragment caption follows independently", h.project.sequence.tracks[2].clips.map(\.start).sorted() == [MediaTime(3,1),MediaTime(10,1)])
  h = EditorHistory(project: separated)
  try h.apply(.setRate(trackID: tid, clipID: source.id, rate: PlaybackRate(numerator: 2)))
  check("Caption speed mapping", h.project.sequence.tracks[2].clips[0].start == MediaTime(5,2) && h.project.sequence.tracks[2].clips[0].duration == MediaTime(2,1))
  check("Audio speed mapping", h.project.sequence.tracks[3].clips[0].playbackRate?.multiplier == 2 && h.project.sequence.tracks[3].clips[0].duration == MediaTime(3,1))
  h = EditorHistory(project: separated)
  try h.apply(.trimClip(trackID: tid, clipID: source.id, newStart: MediaTime(4,1), newSourceStart: MediaTime(12,1), newDuration: MediaTime(3,1)))
  check("Trim clips caption to retained source", h.project.sequence.tracks[2].clips[0].start == MediaTime(4,1) && h.project.sequence.tracks[2].clips[0].duration == MediaTime(3,1))
  h = EditorHistory(project: separated)
  var locked = separated.sequence.tracks[2]; locked.isLocked = true
  try h.apply(.updateTrack(locked)); let lockedProject = h.project
  do { try h.apply(.move(trackID: tid, clipID: source.id, to: MediaTime(8,1))); check("Locked dependency rejects atomically", false) } catch { check("Locked dependency rejects atomically", h.project == lockedProject) }
  h = EditorHistory(project: separated)
  var independent = h.project.sequence.tracks[2].clips[0]; independent.connection = nil
  try h.apply(.updateClip(trackID: p.sequence.tracks[2].id, clip: independent))
  try h.apply(.move(trackID: tid, clipID: source.id, to: MediaTime(8,1)))
  check("Explicit unlink preserves independent caption", h.project.sequence.tracks[2].clips[0].start == MediaTime(3,1))
  h = EditorHistory(project: separated)
  try h.apply(.duplicate(trackID: tid, clipID: source.id))
  check("Duplicate copies connected caption and audio", h.project.sequence.tracks[2].clips.count == 2 && h.project.sequence.tracks[3].clips.count == 2)
  try h.apply(.deriveSequence(name: "Landscape", width: 1920, height: 1080))
  try ProjectValidator.validate(h.project)
  let ids = Set(h.project.sequence.tracks.flatMap(\.clips).map(\.id))
  check("Derived sequence connections use new IDs", h.project.sequence.tracks.flatMap(\.clips).allSatisfy { $0.connection.map { ids.contains($0.parentID) } ?? true })
  h = EditorHistory(project: separated)
  try h.apply(.delete(trackID: tid, clipID: source.id, ripple: false))
  check("Delete source removes connected dependents", h.project.sequence.tracks.flatMap(\.clips).isEmpty)
  var ripple = p
  var other = Track(name: "Sync", kind: .overlay, clips: [Clip(assetID: asset.id, start: MediaTime(10,1), duration: MediaTime(2,1))]); other.syncLocked = true
  ripple.sequence.tracks.append(other)
  h = EditorHistory(project: ripple)
  try h.apply(.delete(trackID: tid, clipID: source.id, ripple: true))
  check("Sync-locked track participates in ripple", h.project.sequence.tracks.last!.clips[0].start == MediaTime(4,1))
  let preset = TitlePreset.builtIns[0]
  check("Builtin style scales with canvas", abs(TitleSizing.title(for: preset, width: 640, height: 360).fontSize - 58.0/3) < 0.001)
  var custom = preset; custom.id = "custom"; custom.referenceShortEdge = 360; custom.title.fontSize = 20
  check("Saved custom style scales from authored canvas", TitleSizing.title(for: custom, width: 3840, height: 2160).fontSize == 120)
  let music = Clip(start: .zero, duration: MediaTime(10,1), keyframes: [TransformKeyframe(time: MediaTime(3,1), transform: ClipTransform(), volume: 0.5)])
  let points = try AudioAutomation.duck(clip: music, speech: [(MediaTime(2,1),MediaTime(4,1))], reductionDB: -12)
  check("Ducking leaves silence full volume", abs(AudioAutomation.gain(points, at: MediaTime(1,1))-1) < 0.001)
  check("Ducking attenuates speech interval", abs(AudioAutomation.gain(points, at: MediaTime(3,1))-pow(10,-12.0/20)) < 0.001)
  check("Ducking releases after speech", abs(AudioAutomation.gain(points, at: MediaTime(5,1))-1) < 0.001)
  var duplicateIDs = p; duplicateIDs.sequence.tracks[2].clips[0].id = source.id
  do { try ProjectValidator.validate(duplicateIDs); check("Duplicate IDs throw instead of trap", false) } catch { check("Duplicate IDs throw instead of trap", true) }
  var dangling = p; dangling.sequence.tracks[2].clips[0].connection?.parentID = UUID()
  do { try ProjectValidator.validate(dangling); check("Dangling connections rejected", false) } catch { check("Dangling connections rejected", true) }
  var nested = separated
  let dialogue = nested.sequence.tracks[3].clips[0]
  nested.sequence.tracks[2].clips = CaptionEditing.automaticClips(cues: cues, source: dialogue, style: TitlePreset.builtIns[0].title)
  h = EditorHistory(project: nested)
  try h.apply(.split(trackID: tid, clipID: source.id, at: MediaTime(5,1)))
  check("Caption on separated dialogue follows nested split", h.project.sequence.tracks[2].clips.count == 2)
  let nestedRight = h.project.sequence.tracks[0].clips[1]
  try h.apply(.split(trackID: tid, clipID: nestedRight.id, at: MediaTime(6,1)))
  check("Repeated nested split retains exactly three caption fragments", h.project.sequence.tracks[2].clips.count == 3 && h.project.sequence.tracks[3].clips.count == 3)
  let last = h.project.sequence.tracks[0].clips.last!
  try h.apply(.move(trackID: tid, clipID: last.id, to: MediaTime(10,1)))
  check("Repeated split tail moves only its own caption", h.project.sequence.tracks[2].clips.map(\.start).sorted() == [MediaTime(3,1),MediaTime(5,1),MediaTime(10,1)])
  h.undo(); h.redo(); try ProjectValidator.validate(h.project)
  check("Nested split undo redo maintains valid links", true)
  do { _ = try AudioAutomation.duck(clip: music, speech: [], reductionDB: -12, release: .infinity); check("Infinite ducking release rejected", false) } catch { check("Infinite ducking release rejected", true) }
  _ = captionID
  try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
  if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
 }
}

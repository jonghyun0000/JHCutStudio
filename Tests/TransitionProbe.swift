import Foundation
import AVFoundation
import CoreImage
import AppKit
@testable import JHCutCore

/// Priority 2: transitions and title animation, measured on rendered frames.
@main struct TransitionProbe {
 struct Frame { let w: Int, h: Int, px: [UInt8]
  func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }
  func isBlue(_ x: Int, _ y: Int) -> Bool { let c = rgb(x, y); return c.2 > c.0 + 60 }
  func luma(_ x: Int, _ y: Int) -> Int { let c = rgb(x, y); return (c.0 * 30 + c.1 * 59 + c.2 * 11) / 100 }
  /// Bounding box of pixels brighter than `threshold` (top-left origin).
  func bright(_ threshold: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, peak: Int)? {
   var minX = w, maxX = -1, minY = h, maxY = -1, peak = 0
   for y in 0..<h { for x in 0..<w { let l = luma(x, y); if l > threshold { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }; peak = max(peak, l) } }
   return maxX < 0 ? nil : (minX, maxX, minY, maxY, peak)
  }
  func maxDifference(_ o: Frame) -> Int { var m = 0; for i in 0..<min(px.count, o.px.count) where i % 4 != 3 { m = max(m, abs(Int(px[i]) - Int(o.px[i]))) }; return m }
 }

 /// The compositor blends in linear light (as it always has), so halfway values are linear averages converted back to sRGB.
 static func lin(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
 static func srgb(_ l: Double) -> Double { (l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055) * 255 }
 static func frame(_ plan: RenderPlan, at t: Double) throws -> Frame {
  let g = AVAssetImageGenerator(asset: plan.composition); g.videoComposition = plan.videoComposition
  g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
  let cg = try g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
  let w = cg.width, h = cg.height; var px = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  return Frame(w: w, h: h, px: px)
 }
 static func png(_ url: URL, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws {
  let w = 640, h = 360; var px = [UInt8](repeating: 255, count: w * h * 4)
  for y in 0..<h { for x in 0..<w { let c = color(x, y); px[(y * w + x) * 4] = c.0; px[(y * w + x) * 4 + 1] = c.1; px[(y * w + x) * 4 + 2] = c.2 } }
  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try rep.representation(using: .png, properties: [:])!.write(to: url)
 }

 static func main() async throws {
  setbuf(stdout, nil)
  let root = try ProbeWorkspace.prepare(defaultPath: "Artifacts/Upgrade-0.7/Transitions")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], metrics: [String: Any] = [:]
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  defer { try? JSONSerialization.data(withJSONObject: ["checks": rows, "metrics": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }

  // ---- Pure math ----
  check("Easing endpoints", Easing.inOut(0) == 0 && Easing.inOut(1) == 1 && abs(Easing.inOut(0.5) - 0.5) < 1e-9 && Easing.backOut(0) < 0.01 && abs(Easing.backOut(1) - 1) < 1e-9 && (0..<100).contains { Easing.backOut(Double($0) / 100) > 1.01 })
  let fade = TitleAnimation(inKind: .fade, outKind: .fade, inSeconds: 0.5, outSeconds: 0.5)
  check("Title state: hidden at start, rest in the middle, hidden at the end", fade.state(at: 0, clipDuration: 3).opacity == 0 && fade.state(at: 1.5, clipDuration: 3) == .rest && fade.state(at: 3, clipDuration: 3).opacity == 0 && abs(fade.state(at: 0.25, clipDuration: 3).opacity - 0.5) < 1e-9)
  check("Exit is the entrance played backwards", abs(fade.state(at: 2.75, clipDuration: 3).opacity - 0.5) < 1e-9)
  check("Animation longer than the clip is refused", TitleAnimation(inKind: .fade, outKind: .fade, inSeconds: 2, outSeconds: 2).validationProblem(clipDuration: MediaTime(seconds: 3)) != nil && fade.validationProblem(clipDuration: MediaTime(seconds: 3)) == nil && TitleAnimation(inKind: .fade, inSeconds: 9).validationProblem(clipDuration: MediaTime(seconds: 30)) != nil)

  // ---- Frames: two scenes with a known layout ----
  let a = root.appendingPathComponent("A.png"), b = root.appendingPathComponent("B.png"), night = root.appendingPathComponent("night.png")
  try png(a) { x, _ in (220, UInt8(x * 200 / 639), UInt8(x * 200 / 639)) }   // red on the left, pale on the right
  try png(b) { _, _ in (0, 0, 220) }
  try png(night) { _, _ in (0, 0, 0) }
  var assetA = try await MediaImporter.inspect(url: a), assetB = try await MediaImporter.inspect(url: b)
  assetA.duration = MediaTime(seconds: 2); assetB.duration = MediaTime(seconds: 2)
  func project(_ kind: TransitionKind?, _ direction: TransitionDirection = .fromRight, duration: Double = 1) throws -> Project {
   var p = Project(name: "전환"); p.sequence.width = 640; p.sequence.height = 360; p.assets = [assetA, assetB]
   p.sequence.tracks[0].clips = [Clip(name: "A", assetID: assetA.id, start: .zero, duration: MediaTime(seconds: 2)), Clip(name: "B", assetID: assetB.id, start: MediaTime(seconds: 2), duration: MediaTime(seconds: 2))]
   guard let kind else { return p }
   var h = EditorHistory(project: p)
   try h.apply(.addTransition(trackID: p.sequence.tracks[0].id, clipID: p.sequence.tracks[0].clips[0].id, kind: kind, direction: direction, duration: MediaTime(seconds: duration)))
   return h.project
  }
  func frames(_ p: Project, _ times: [Double]) async throws -> [Frame] { let plan = try await TimelineRenderer.build(project: p); return try times.map { try frame(plan, at: $0) } }
  let plain = try await frames(try project(nil), [0.5, 2.5])
  let aOnly = plain[0], bOnly = plain[1]
  // Overlap is t = 1…2; p = t − 1.
  for kind in TransitionKind.allCases {
   let f = try await frames(try project(kind), [1.0, 1.5, 2.5])
   check("\(kind.label): starts on the outgoing picture", f[0].maxDifference(aOnly) <= 6, "difference \(f[0].maxDifference(aOnly))")
   check("\(kind.label): ends on the incoming picture", f[2].maxDifference(bOnly) <= 6)
  }
  let mid = { (kind: TransitionKind, dir: TransitionDirection) async throws -> Frame in try await frames(try project(kind, dir), [1.5])[0] }
  // Dissolve: halfway blend.
  let dis = try await mid(.dissolve, .fromRight); let cd = dis.rgb(320, 180), ca = aOnly.rgb(320, 180)
  check("Dissolve: halfway is the linear-light average of both pictures", abs(Double(cd.0) - srgb((lin(ca.0) + lin(0)) / 2)) < 6 && abs(Double(cd.2) - srgb((lin(ca.2) + lin(220)) / 2)) < 6, "\(cd) from A \(ca) and B (0,0,220)")
  // Legacy dissolve (0.6 documents: fade-in only, no `transition`) renders exactly the same.
  var legacy = try project(.dissolve)
  for t in legacy.sequence.tracks.indices {
   legacy.sequence.tracks[t].transitionContext = nil
   for c in legacy.sequence.tracks[t].clips.indices {
    if legacy.sequence.tracks[t].clips[c].name == "B" { legacy.sequence.tracks[t].clips[c].fadeIn = MediaTime(seconds: 1) }
    legacy.sequence.tracks[t].clips[c].transition = nil; legacy.sequence.tracks[t].clips[c].transitionAudioFades = nil
   }
  }
  let legacyFrame = try await frames(legacy, [1.5])[0]
  check("0.6-style dissolve (fade-in only) renders identically", legacyFrame.maxDifference(dis) <= 1, "difference \(legacyFrame.maxDifference(dis))")
  // Dip to black
  let dip = try await frames(try project(.dipToBlack), [1.25, 1.5, 1.75])
  check("Dip to black: black in the middle, half-dark outgoing/incoming on the way", dip[1].bright(12) == nil && abs(Double(dip[0].rgb(60, 180).0) - srgb(lin(aOnly.rgb(60, 180).0) / 2)) < 6 && abs(Double(dip[2].rgb(320, 180).2) - srgb(lin(bOnly.rgb(320, 180).2) / 2)) < 6, "middle brightest \(dip[1].bright(0)?.peak ?? 0)")
  // Wipe / slide / push from each side at p = 0.5
  for (dir, blueAt, aAt) in [(TransitionDirection.fromLeft, (100, 180), (540, 180)), (.fromRight, (540, 180), (100, 180)), (.fromTop, (320, 50), (320, 310)), (.fromBottom, (320, 310), (320, 50))] {
   let w = try await mid(.wipe, dir)
   check("Wipe \(dir.label): incoming behind the edge, outgoing ahead of it", w.isBlue(blueAt.0, blueAt.1) && !w.isBlue(aAt.0, aAt.1), "blue@\(blueAt) \(w.rgb(blueAt.0, blueAt.1)) A@\(aAt) \(w.rgb(aAt.0, aAt.1))")
   let s = try await mid(.slide, dir)
   check("Slide \(dir.label): incoming covers its half, outgoing stays put", s.isBlue(blueAt.0, blueAt.1) && !s.isBlue(aAt.0, aAt.1) && (dir == .fromLeft || dir == .fromRight ? s.rgb(aAt.0, aAt.1).1 == aOnly.rgb(aAt.0, aAt.1).1 : true) && (dir == .fromTop || dir == .fromBottom ? s.maxDifference(aOnly) > 0 : true), "")
   let p = try await mid(.push, dir)
   check("Push \(dir.label): incoming covers its half", p.isBlue(blueAt.0, blueAt.1) && !p.isBlue(aAt.0, aAt.1))
  }
  // Slide keeps A where it was; push moves A: A's colour gradient tells the difference (x = 100 shows A at x = 100 vs x = 420).
  let slideR = try await mid(.slide, .fromRight), pushR = try await mid(.push, .fromRight)
  check("Slide leaves the outgoing picture in place", abs(slideR.rgb(100, 180).1 - aOnly.rgb(100, 180).1) <= 6, "G \(slideR.rgb(100, 180).1) vs \(aOnly.rgb(100, 180).1)")
  check("Push moves the outgoing picture with the incoming one", abs(pushR.rgb(100, 180).1 - aOnly.rgb(420, 180).1) <= 12, "G \(pushR.rgb(100, 180).1) ≈ A at x=420: \(aOnly.rgb(420, 180).1)")
  // Zoom dissolve
  let zm = try await mid(.zoom, .fromRight)
  check("Zoom dissolve: halfway shows both pictures", zm.rgb(320, 180).2 > 60 && zm.rgb(320, 180).0 > 40, "\(zm.rgb(320, 180))")
  // Soft wipe edge: a band where neither picture is pure
  let wipeMid = try await mid(.wipe, .fromLeft)
  // Pixels that match neither the outgoing picture at that spot nor the incoming blue: the blended band.
  var transitionPixels = 0
  for x in 0..<640 {
   let c = wipeMid.rgb(x, 180), o = aOnly.rgb(x, 180)
   let awayFromA = abs(c.0 - o.0) + abs(c.1 - o.1) + abs(c.2 - o.2) > 40, awayFromB = abs(c.0) + abs(c.1) + abs(c.2 - 220) > 40
   if awayFromA && awayFromB { transitionPixels += 1 }
  }
  check("Wipe edge is soft (a blended band, not a hard cut)", transitionPixels >= 10 && transitionPixels <= 80, "\(transitionPixels) px")

  // ---- Editing ----
  let base = try project(nil); let track = base.sequence.tracks[0]
  var history = EditorHistory(project: base)
  try history.apply(.addTransition(trackID: track.id, clipID: track.clips[0].id, kind: .push, direction: .fromLeft, duration: MediaTime(seconds: 0.8)))
  let incoming = history.project.sequence.tracks.flatMap(\.clips).first { $0.name == "B" }!
  check("Transition stores its overlap separately from native audio fades", incoming.transition == ClipTransition(kind: .push, direction: .fromLeft, duration: MediaTime(seconds: 0.8)) && incoming.start == MediaTime(seconds: 1.2) && incoming.fadeIn == nil && incoming.audioFadeIn == nil && incoming.transitionAudioFades?.first?.duration == MediaTime(seconds: 0.8))
  check("Overlay track is named after the transition", history.project.sequence.tracks.contains { $0.kind == .overlay && $0.name.hasPrefix("밀어내기") })
  check("Timeline is shortened by the overlap", history.project.sequence.duration == MediaTime(seconds: 3.2))
  history.undo(); check("One undo removes the transition", history.project == base)
  history.redo(); check("Redo brings it back", history.project.sequence.tracks.flatMap(\.clips).contains { $0.transition?.kind == .push })
  let doc = root.appendingPathComponent("Transition.jhcut")
  try ProjectStore.save(history.project, to: doc)
  check("Save/reopen keeps the transition", try ProjectStore.load(from: doc).sequence == history.project.sequence)
  var refused = 0
  var h2 = EditorHistory(project: base)
  if (try? h2.apply(.addTransition(trackID: track.id, clipID: track.clips[1].id, kind: .wipe, direction: .fromLeft, duration: MediaTime(seconds: 1)))) == nil { refused += 1 }   // last clip: nothing after it
  if (try? h2.apply(.addTransition(trackID: track.id, clipID: track.clips[0].id, kind: .wipe, direction: .fromLeft, duration: MediaTime(seconds: 2)))) == nil { refused += 1 }   // not shorter than the clips
  if (try? h2.apply(.addTransition(trackID: track.id, clipID: track.clips[0].id, kind: .wipe, direction: .fromLeft, duration: .zero))) == nil { refused += 1 }
  check("Impossible transitions are refused and change nothing", refused == 3 && h2.project == base)
  var forged = history.project; forged.sequence.tracks[2].clips = [Clip(name: "제목", duration: MediaTime(seconds: 2), title: Title(text: "x"))]; forged.sequence.tracks[2].clips[0].transition = ClipTransition(kind: .wipe, duration: MediaTime(seconds: 1))
  check("A title cannot carry a transition", (try? ProjectValidator.validate(forged)) == nil)

  // ---- Title animation ----
  var night2 = try await MediaImporter.inspect(url: night); night2.duration = MediaTime(seconds: 3)
  func titleProject(_ animation: TitleAnimation?) -> Project {
   var p = Project(name: "글자"); p.sequence.width = 640; p.sequence.height = 360; p.assets = [night2]
   p.sequence.tracks[0].clips = [Clip(name: "밤", assetID: night2.id, duration: MediaTime(seconds: 3))]
   var title = Title(text: "ANIMATION", fontName: "Helvetica-Bold", fontSize: 60, colorHex: "FFFFFF", x: 0.5, y: 0.5)
   title.style = TextStyle(); title.style?.strokeWidth = 0; title.style?.backgroundOpacity = 0
   var clip = Clip(name: "제목", start: .zero, duration: MediaTime(seconds: 3), title: title); clip.titleAnimation = animation
   p.sequence.tracks[2].clips = [clip]
   return p
  }
  let steady = try await frames(titleProject(nil), [1.5])[0]
  let base0 = steady.bright(60)!
  let baseWidth = Double(base0.maxX - base0.minX), baseCenterY = Double(base0.minY + base0.maxY) / 2, baseCenterX = Double(base0.minX + base0.maxX) / 2
  check("Steady title is visible and centred", base0.peak > 200 && abs(baseCenterX - 320) < 30 && abs(baseCenterY - 180) < 30, "bbox \(base0)")
  let none = try await frames(titleProject(TitleAnimation()), [1.5])[0]
  check("An empty animation renders exactly like no animation", none.maxDifference(steady) == 0)
  let fadeF = try await frames(titleProject(fade), [0.25, 1.5, 2.75, 2.999])
  check("Fade in: half opacity at half progress (linear light)", abs(Double(fadeF[0].bright(5)?.peak ?? 0) - srgb(0.5 * lin(base0.peak))) < 8, "peak \(fadeF[0].bright(5)?.peak ?? 0) of \(base0.peak)")
  check("Fade: full brightness between the animations, identical to the steady title", fadeF[1].maxDifference(steady) <= 1)
  check("Fade out: half at half, gone at the end", abs(Double(fadeF[2].bright(5)?.peak ?? 0) - srgb(0.5 * lin(base0.peak))) < 8 && (fadeF[3].bright(20) == nil))
  func box(_ animation: TitleAnimation, at t: Double) async throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int, peak: Int)? { try await frames(titleProject(animation), [t])[0].bright(14) }
  let up = try await box(TitleAnimation(inKind: .slideUp, inSeconds: 1), at: 0.3)!
  check("Slide up: starts lower and rises", Double(up.minY + up.maxY) / 2 > baseCenterY + 12, String(format: "centre y %.1f vs steady %.1f", Double(up.minY + up.maxY) / 2, baseCenterY))
  let down = try await box(TitleAnimation(inKind: .slideDown, inSeconds: 1), at: 0.3)!
  check("Slide down: starts higher", Double(down.minY + down.maxY) / 2 < baseCenterY - 12)
  let left = try await box(TitleAnimation(inKind: .slideLeft, inSeconds: 1), at: 0.3)!
  check("Slide from the left: starts further left", Double(left.minX + left.maxX) / 2 < baseCenterX - 20)
  let pop = try await box(TitleAnimation(inKind: .pop, inSeconds: 1), at: 0.2)!
  let popRatio = Double(pop.maxX - pop.minX) / baseWidth
  check("Pop: smaller at the start (about 0.88× at 20 %) and about the same centre", popRatio > 0.78 && popRatio < 0.97 && abs(Double(pop.minX + pop.maxX) / 2 - baseCenterX) < 8, String(format: "width %.2f× steady", popRatio))
  let zoom = try await box(TitleAnimation(inKind: .zoom, inSeconds: 1), at: 0.5)!
  let zoomRatio = Double(zoom.maxX - zoom.minX) / baseWidth
  check("Zoom: larger at the start (about 1.25× at half) about its own centre", zoomRatio > 1.15 && zoomRatio < 1.36 && abs(Double(zoom.minX + zoom.maxX) / 2 - baseCenterX) < 10, String(format: "width %.2f× steady", zoomRatio))
  let type = try await box(TitleAnimation(inKind: .typewriter, inSeconds: 1), at: 0.5)!
  let typeShare = Double(type.maxX - type.minX) / baseWidth
  check("Typewriter: about half of the text revealed from the left at half progress", typeShare > 0.35 && typeShare < 0.65 && type.minX <= base0.minX + 4, String(format: "%.0f%% revealed", typeShare * 100))
  let typeDone = try await box(TitleAnimation(inKind: .typewriter, inSeconds: 1), at: 1.6)
  check("Typewriter: whole text after the animation", typeDone.map { abs(Double($0.maxX - $0.minX) - baseWidth) < 3 } == true)
  // Persistence
  var pTitle = titleProject(TitleAnimation(inKind: .pop, outKind: .fade, inSeconds: 0.4, outSeconds: 0.6))
  let docT = root.appendingPathComponent("Title.jhcut"); try ProjectStore.save(pTitle, to: docT)
  check("Save/reopen keeps the title animation", try ProjectStore.load(from: docT).sequence == pTitle.sequence)
  pTitle.sequence.tracks[0].clips[0].titleAnimation = TitleAnimation(inKind: .fade)
  check("Title animation on a video clip is refused", (try? ProjectValidator.validate(pTitle)) == nil)
  var undoHistory = EditorHistory(project: titleProject(nil)); let tid = undoHistory.project.sequence.tracks[2].id
  var animated = undoHistory.project.sequence.tracks[2].clips[0]; animated.titleAnimation = TitleAnimation(inKind: .zoom)
  try undoHistory.apply(.updateClip(trackID: tid, clip: animated)); undoHistory.undo()
  check("Setting the animation is one undo step", undoHistory.project.sequence.tracks[2].clips[0].titleAnimation == nil)
  // ---- Temporal edits preserve the original effect clock, measured on actual rendered pixels ----
  let samples = [0.25, 1.0, 1.2, 1.5, 1.8, 2.2, 2.75]
  for kind in TransitionKind.allCases {
   let original = try project(kind); let expected = try await frames(original, samples)
   var h = EditorHistory(project: original)
   for name in ["A", "B"] {
    for time in name == "A" ? [0.5, 1.6] : [1.4, 2.4] {
     let track = h.project.sequence.tracks.first { $0.clips.contains { $0.name == name && $0.start.seconds < time && $0.end.seconds > time } }!
     let clip = track.clips.first { $0.name == name && $0.start.seconds < time && $0.end.seconds > time }!
     try h.apply(.split(trackID: track.id, clipID: clip.id, at: MediaTime(seconds: time)))
    }
   }
   let actual = try await frames(h.project, samples), error = zip(expected, actual).map { $0.maxDifference($1) }.max()!
   check("\(kind.label): splits before/during/after the transition preserve pixels", error <= 2, "max RGB difference \(error)")
   let track = h.project.sequence.tracks.first { $0.transitionContext != nil }!
   check("\(kind.label): late fragments do not replay the entrance", track.clips.last?.transition == nil && track.transitionContext != nil)
   let saved = root.appendingPathComponent("Split-\(kind.rawValue).jhcut"); try ProjectStore.save(h.project, to: saved)
   let loaded = try ProjectStore.load(from: saved)
   check("\(kind.label): split effect save/reopen", loaded.sequence == h.project.sequence)
   while h.canUndo { h.undo() }; check("\(kind.label): split undo restores original", h.project == original)
  }
  var trimmedHistory = EditorHistory(project: try project(.push))
  let trimTrack = trimmedHistory.project.sequence.tracks.first { $0.transitionContext != nil }!, trimClip = trimTrack.clips[0]
  let retainedTimes = [1.3, 1.5, 1.9, 2.3, 2.75]
  let retainedExpected = try await frames(trimmedHistory.project, retainedTimes)
  try trimmedHistory.apply(.trimClip(trackID: trimTrack.id, clipID: trimClip.id, newStart: MediaTime(seconds: 1.25), newSourceStart: .zero, newDuration: MediaTime(seconds: 1.75)))
  let retainedActual = try await frames(trimmedHistory.project, retainedTimes)
  check("Head trim preserves transition phase and retained pixels", zip(retainedExpected, retainedActual).allSatisfy { $0.maxDifference($1) <= 2 })
  try trimmedHistory.apply(.changeTransitionAppearance(trackID: trimTrack.id, kind: .wipe, direction: .fromLeft))
  let phaseClip = trimmedHistory.project.sequence.tracks.first { $0.id == trimTrack.id }!.clips[0]
  check("Changing kind after trim preserves phase and placement", phaseClip.start == MediaTime(seconds: 1.25) && phaseClip.transition?.offset == MediaTime(seconds: 0.25) && phaseClip.transition?.duration == MediaTime(seconds: 1))
  for kind in TitleAnimationKind.allCases {
   let original = titleProject(TitleAnimation(inKind: kind, outKind: .fade, inSeconds: 1, outSeconds: 0.5))
   let times = [0.2, 0.4, 0.6, 1.5, 2.6, 2.8], expected = try await frames(original, times)
   var h = EditorHistory(project: original)
   for t in [0.4, 2.7] {
    let track = h.project.sequence.tracks.first { $0.kind == .title }!, clip = track.clips.first { $0.start.seconds < t && $0.end.seconds > t }!
    try h.apply(.split(trackID: track.id, clipID: clip.id, at: MediaTime(seconds: t)))
   }
   let actual = try await frames(h.project, times), error = zip(expected, actual).map { $0.maxDifference($1) }.max()!
   check("Title \(kind.label): split preserves entrance and exit pixels", error <= 2, "max RGB difference \(error)")
   var tr = EditorHistory(project: original); let track = original.sequence.tracks.first { $0.kind == .title }!
   try tr.apply(.trimClip(trackID: track.id, clipID: track.clips[0].id, newStart: MediaTime(seconds: 0.4), newSourceStart: .zero, newDuration: MediaTime(seconds: 2.6)))
   let actualTrim = try await frames(tr.project, Array(times.dropFirst()))
   check("Title \(kind.label): trim keeps original clock", zip(expected.dropFirst(), actualTrim).allSatisfy { $0.maxDifference($1) <= 2 })
   let saved = root.appendingPathComponent("Title-split-\(kind.rawValue).jhcut"); try ProjectStore.save(h.project, to: saved)
   check("Title \(kind.label): temporal fields survive save", try ProjectStore.load(from: saved).sequence == h.project.sequence)
  }
  // An ordinary overlay between A and B stays above their composed pair, rather than being pushed away.
  let greenURL = root.appendingPathComponent("logo.png"); try png(greenURL) { _, _ in (0, 230, 0) }
  let greenAsset = try await MediaImporter.inspect(url: greenURL)
  var decorated = try project(.push); decorated.assets.append(greenAsset)
  var logo = Clip(name: "Logo", assetID: greenAsset.id, duration: MediaTime(seconds: 3)); logo.transform.scale = 0.12
  let decoration = Track(name: "Decoration", kind: .overlay, clips: [logo])
  decorated.sequence.tracks.insert(decoration, at: 1)
  let logoFrames = try await frames(decorated, [0.5, 1.25, 1.5, 1.75, 2.5])
  func greenPixels(_ frame: Frame) -> Set<Int> {
   Set(stride(from: 0, to: frame.px.count, by: 4).filter { i in frame.px[i + 1] > 150 && frame.px[i] < 40 && frame.px[i + 2] < 40 })
  }
  let logoMask = greenPixels(logoFrames[0])
  check("Push leaves an unrelated decorative overlay fixed", !logoMask.isEmpty && logoFrames.allSatisfy { greenPixels($0) == logoMask }, "logo pixels \(logoMask.count)")
  var oldTrim = EditorHistory(project: legacy)
  let oldIncomingTrack = legacy.sequence.tracks.first { $0.kind == .overlay && !$0.clips.isEmpty }!
  try oldTrim.apply(.split(trackID: oldIncomingTrack.id, clipID: oldIncomingTrack.clips[0].id, at: MediaTime(seconds: 1.4)))
  let oldFrame = try await frames(oldTrim.project, [1.5])[0]
  check("Legacy dissolve split adopts the pair without changing pixels", oldFrame.maxDifference(dis) <= 2 && oldTrim.project.sequence.tracks.first { $0.id == oldIncomingTrack.id }?.transitionContext != nil)
  oldTrim.undo(); check("Legacy split undo restores the exact old representation", oldTrim.project == legacy)

  // Actual video assets enable speed edits; a connected animated caption follows B's source clock.
  let videoAURL = root.appendingPathComponent("speed-A.mp4"), videoBURL = root.appendingPathComponent("speed-B.mp4")
  var sourceA = try project(nil); sourceA.sequence.tracks[0].clips = [sourceA.sequence.tracks[0].clips[0]]
  var sourceB = try project(nil); var onlyB = sourceB.sequence.tracks[0].clips[1]; onlyB.start = .zero; sourceB.sequence.tracks[0].clips = [onlyB]
  try await ExportJob().export(plan: TimelineRenderer.build(project: sourceA), to: videoAURL) { _ in }
  try await ExportJob().export(plan: TimelineRenderer.build(project: sourceB), to: videoBURL) { _ in }
  let videoA = try await MediaImporter.inspect(url: videoAURL), videoB = try await MediaImporter.inspect(url: videoBURL)
  var speedBase = try project(nil); speedBase.assets = [videoA, videoB]
  speedBase.sequence.tracks[0].clips[0].assetID = videoA.id; speedBase.sequence.tracks[0].clips[1].assetID = videoB.id
  let sceneB = speedBase.sequence.tracks[0].clips[1]
  speedBase.sequence.tracks[0].clips.append(Clip(name: "C", assetID: videoA.id, start: MediaTime(seconds: 4), duration: MediaTime(seconds: 2)))
  var caption = titleProject(nil).sequence.tracks[2].clips[0]; caption.duration = MediaTime(seconds: 0.8); caption.start = MediaTime(seconds: 2.5)
  caption.connection = ClipConnection(parentID: sceneB.id, sourceStart: MediaTime(seconds: 0.5), sourceDuration: MediaTime(seconds: 0.8))
  caption.titleAnimation = TitleAnimation(inKind: .typewriter, outKind: .fade, inSeconds: 0.4, outSeconds: 0.2)
  speedBase.sequence.tracks[2].clips = [caption]
  var speed = EditorHistory(project: speedBase); let main = speedBase.sequence.tracks[0]
  try speed.apply(.addTransition(trackID: main.id, clipID: main.clips[0].id, kind: .push, direction: .fromRight, duration: MediaTime(seconds: 0.5)))
  let speedTrack = speed.project.sequence.tracks.first { $0.clips.contains { $0.id == sceneB.id } }!
  try speed.apply(.addTransition(trackID: speedTrack.id, clipID: sceneB.id, kind: .wipe, direction: .fromLeft, duration: MediaTime(seconds: 0.5)))
  let speedOriginal = speed.project, expectedCaptionPixel = try await frames(speedOriginal, [2.2])[0]
  try speed.apply(.setRate(trackID: speedTrack.id, clipID: sceneB.id, rate: PlaybackRate(numerator: 2)))
  let retimedB = speed.project.sequence.tracks.flatMap(\.clips).first { $0.id == sceneB.id }!, retimedCaption = speed.project.sequence.tracks.flatMap(\.clips).first { $0.connection?.parentID == sceneB.id && $0.title != nil }!
  check("2x middle scene keeps both transition windows aligned", retimedB.start == MediaTime(seconds: 1.75) && retimedB.end == MediaTime(seconds: 2.75) && speed.project.sequence.tracks.flatMap(\.clips).first { $0.name == "C" }?.start == MediaTime(seconds: 2.25))
  check("Connected caption animation follows source speed", retimedCaption.start == MediaTime(seconds: 2) && retimedCaption.duration == MediaTime(seconds: 0.4) && retimedCaption.titleAnimation?.timeScale == 2)
  let captionPixel = try await frames(speed.project, [2.1])[0]
  check("2x connected animated caption matches the same source instant in pixels", captionPixel.maxDifference(expectedCaptionPixel) <= 3, "difference \(captionPixel.maxDifference(expectedCaptionPixel))")
  speed.undo(); check("Speed with transitions and caption is one undo step", speed.project == speedOriginal)
  try speed.apply(.setRate(trackID: speedTrack.id, clipID: sceneB.id, rate: PlaybackRate(numerator: 4)))
  let fastC = speed.project.sequence.tracks.first { $0.clips.contains { $0.name == "C" } }!
  check("4x middle scene shortens the next transition to prevent a three-way overlap", fastC.clips[0].start == MediaTime(seconds: 2) && fastC.transitionContext?.effect.duration == MediaTime(seconds: 0.375))
  let gapFrames = try await frames(speed.project, [1.9, 2.0, 2.2, 2.4, 3.0])
  check("Retimed chain has no black gap at either boundary", gapFrames.allSatisfy { frame in stride(from: 0, to: frame.px.count, by: 4).contains { max(frame.px[$0], frame.px[$0 + 1], frame.px[$0 + 2]) > 100 } })
  let speedDoc = root.appendingPathComponent("Retimed-chain.jhcut"); try ProjectStore.save(speed.project, to: speedDoc)
  check("Retimed transition and caption clocks survive save/reopen", try ProjectStore.load(from: speedDoc).sequence == speed.project.sequence)
  try speed.apply(.deriveSequence(name: "Vertical", width: 360, height: 640))
  check("Derived sequence remaps transition scene and owner identities", (try? ProjectValidator.validate(speed.project)) != nil && speed.project.sequence.tracks.compactMap(\.transitionContext).allSatisfy { $0.originTrackID == speed.project.sequence.tracks[0].id })

  // A phase-aligned tone makes equal-power errors and doubled native fades audible/measurable.
  let toneURL = root.appendingPathComponent("tone.wav")
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
  try autoreleasepool {
   let toneFile = try AVAudioFile(forWriting: toneURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
   let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!; buffer.frameLength = 96_000
   for i in 0..<96_000 { buffer.floatChannelData![0][i] = 0.2 * Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) }
   try toneFile.write(from: buffer)
  }
  let toneAsset = try await MediaImporter.inspect(url: toneURL)
  var audioBase = try project(nil); audioBase.assets.append(toneAsset)
  for parent in audioBase.sequence.tracks[0].clips {
   var child = Clip(name: "Tone-\(parent.name)", assetID: toneAsset.id, start: parent.start, duration: parent.duration)
   child.connection = ClipConnection(parentID: parent.id, sourceStart: .zero, sourceDuration: parent.duration)
   child.audioFadeIn = MediaTime(seconds: 0.2); child.audioFadeOut = MediaTime(seconds: 0.3)
   audioBase.sequence.tracks[3].clips.append(child)
  }
  var audio = EditorHistory(project: audioBase)
  try audio.apply(.addTransition(trackID: audioBase.sequence.tracks[0].id, clipID: audioBase.sequence.tracks[0].clips[0].id, kind: .dissolve, direction: .fromRight, duration: MediaTime(seconds: 1)))
  check("Connected sound keeps native fades while adding managed crossfade", audio.project.sequence.tracks[4].clips.allSatisfy { $0.audioFadeIn == MediaTime(seconds: 0.2) && $0.audioFadeOut == MediaTime(seconds: 0.3) && $0.transitionAudioFades?.count == 1 })
  let toneOutput = root.appendingPathComponent("transition-tone.mp4")
  try await ExportJob().export(plan: TimelineRenderer.build(project: audio.project), to: toneOutput) { _ in }
  var energies: [Double] = [], sampleRate = 48_000.0
  _ = try await SourcePCM.readStable(url: toneOutput, sourceStart: .zero, duration: nil) { chunk in
   sampleRate = chunk.sampleRate
   for frame in 0..<(chunk.values.count / chunk.channels) { let value = Double(chunk.values[frame * chunk.channels]); energies.append(value * value) }
  }
  func rms(_ begin: Double, _ end: Double) -> Double {
   let range = Int(begin * sampleRate)..<min(energies.count, Int(end * sampleRate)); return sqrt(energies[range].reduce(0, +) / Double(range.count))
  }
  let outsideRMS = rms(0.5, 0.6), midpointRMS = rms(1.45, 1.55)
  check("Actual audio crossfade avoids doubled amplitude at the midpoint", outsideRMS > 0.05 && abs(midpointRMS / outsideRMS - 1) < 0.05, "outside RMS \(outsideRMS), midpoint RMS \(midpointRMS)")
  var tail = EditorHistory(project: audio.project)
  let tailTrack = tail.project.sequence.tracks.first { $0.transitionContext != nil }!, tailClip = tailTrack.clips[0]
  let tailExpected = try await frames(tail.project, [1.2, 1.4])
  try tail.apply(.trimClip(trackID: tailTrack.id, clipID: tailClip.id, newStart: tailClip.start, newSourceStart: .zero, newDuration: MediaTime(seconds: 0.6)))
  let tailActual = try await frames(tail.project, [1.2, 1.4])
  check("Tail trim during an effect preserves retained transition pixels", zip(tailExpected, tailActual).allSatisfy { $0.maxDifference($1) <= 2 })
  let restoredOutgoing = tail.project.sequence.tracks.flatMap(\.clips).first { $0.name == "Tone-A" }!
  check("Clipped effect restores outgoing native gain outside its retained window", abs(ClipEnvelopes.audioVolume(clip: restoredOutgoing, at: MediaTime(seconds: 1.65).cmTime) - 1) < 0.001)
  check("Clipped effect keeps its original progress inside the retained window", abs(ClipEnvelopes.audioVolume(clip: restoredOutgoing, at: MediaTime(seconds: 1.4).cmTime) - 0.6) < 0.001)
  let clippedTone = root.appendingPathComponent("clipped-transition-tone.mp4")
  try await ExportJob().export(plan: TimelineRenderer.build(project: tail.project), to: clippedTone) { _ in }
  energies = []
  _ = try await SourcePCM.readStable(url: clippedTone, sourceStart: .zero, duration: nil) { chunk in
   sampleRate = chunk.sampleRate
   for frame in 0..<(chunk.values.count / chunk.channels) { let value = Double(chunk.values[frame * chunk.channels]); energies.append(value * value) }
  }
  let afterClippedRMS = rms(1.63, 1.67)
  check("Actual output restores normal audio after a clipped transition", abs(afterClippedRMS / outsideRMS - 1) < 0.03, "normal RMS \(outsideRMS), after clipped effect \(afterClippedRMS)")
  tail.undo(); check("Tail trim undo restores the complete transition and audio", tail.project == audio.project)
  let audioTrack = audio.project.sequence.tracks.first { $0.transitionContext != nil }!
  try audio.apply(.removeTransition(trackID: audioTrack.id))
  check("Removing the transition restores exact connected audio metadata and placement", audio.project.sequence == audioBase.sequence)
  let restoredTone = root.appendingPathComponent("restored-tone.mp4")
  try await ExportJob().export(plan: TimelineRenderer.build(project: audio.project), to: restoredTone) { _ in }
  check("Restored connected audio exports with original duration", abs(try await AVURLAsset(url: restoredTone).load(.duration).seconds - 4) < 0.05)

  // ---- Real iPhone footage (read-only copies): transitions between two different real clips ----
  let realAURL = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_0047.mov").standardizedFileURL, realBURL = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov").standardizedFileURL
  let digestA = try await FileIdentity.sha256(realAURL), digestB = try await FileIdentity.sha256(realBURL)
  let realA = try await MediaImporter.inspect(url: realAURL), realB = try await MediaImporter.inspect(url: realBURL)
  func realProject() -> Project {
   var p = Project(name: "실사 전환"); p.sequence.width = 1080; p.sequence.height = 1920; p.assets = [realA, realB]
   var a = Clip(name: "A", assetID: realA.id, sourceStart: MediaTime(seconds: 240), duration: MediaTime(seconds: 10)); a.transform.fill = true
   var b = Clip(name: "B", assetID: realB.id, start: MediaTime(seconds: 10), sourceStart: MediaTime(seconds: 120), duration: MediaTime(seconds: 10)); b.transform.fill = true
   p.sequence.tracks[0].clips = [a, b]
   return p
  }
  let realPlain = try await TimelineRenderer.build(project: realProject())
  // Overlap is 9.2…10.0 s after the change. At transitioned time t: A is at its own t, B at t − 9.2 → plain time 10 + (t − 9.2).
  let plainA = { (t: Double) throws -> Frame in try frame(realPlain, at: t) }, plainB = { (t: Double) throws -> Frame in try frame(realPlain, at: 10 + (t - 9.2)) }
  var realRows: [[String: Any]] = []
  for (kind, direction) in [(TransitionKind.push, TransitionDirection.fromRight), (.wipe, .fromLeft), (.dipToBlack, .fromRight), (.zoom, .fromRight)] {
   var h = EditorHistory(project: realProject()); let t0 = h.project.sequence.tracks[0]
   try h.apply(.addTransition(trackID: t0.id, clipID: t0.clips[0].id, kind: kind, direction: direction, duration: MediaTime(seconds: 0.8)))
   let plan = try await TimelineRenderer.build(project: h.project)
   let out = root.appendingPathComponent("real-\(kind.rawValue).mp4"); try? FileManager.default.removeItem(at: out)
   let started = Date()
   try await ExportJob().export(plan: plan, to: out) { _ in }
   let seconds = Date().timeIntervalSince(started)
   let measured = try await OutputQuality.measure(out)
   let report = try await OutputQuality.check(output: out, expectation: OutputExpectation.from(project: h.project, plan: plan))
   // Overlap is 9.2…10.0 s: the frame in the middle mixes both pictures; before and after are pure.
   let midFrame = try frame(plan, at: 9.6), beforeFrame = try frame(plan, at: 9.0), afterFrame = try frame(plan, at: 10.6)
   let dMidA = midFrame.maxDifference(try plainA(9.6)), dMidB = midFrame.maxDifference(try plainB(9.6))
   let dBefore = beforeFrame.maxDifference(try plainA(9.0)), dAfter = afterFrame.maxDifference(try plainB(10.6))
   check("Real footage, \(kind.label): exported length is 19.2 s with audio", abs(measured.duration - 19.2) < 0.1 && measured.audioTracks == 1, String(format: "%.2f s, audio %d, export %.1f s", measured.duration, measured.audioTracks, seconds))
   check("Real footage, \(kind.label): output check passes", report.passed, report.summary)
   check("Real footage, \(kind.label): middle differs from both scenes, ends are pure", dMidA > 40 && dMidB > 40 && dBefore <= 8 && dAfter <= 8, "mid vs A \(dMidA), vs B \(dMidB); before vs A \(dBefore); after vs B \(dAfter)")
   realRows.append(["kind": kind.rawValue, "exportSeconds": seconds, "durationSeconds": measured.duration])
  }
  metrics["realTransitions"] = realRows
  // Real footage with animated captions: the pop starts small and settles.
  do {
   var p = Project(name: "실사 자막"); p.sequence.width = 1080; p.sequence.height = 1920; p.assets = [realB]
   var v = Clip(name: "B", assetID: realB.id, sourceStart: MediaTime(seconds: 120), duration: MediaTime(seconds: 6)); v.transform.fill = true
   p.sequence.tracks[0].clips = [v]
   var title = TitleSizing.title(for: TitlePreset.builtIns[0], width: 1080, height: 1920); title.text = "자막 애니메이션 확인"
   var cap = Clip(name: "자막", start: MediaTime(seconds: 1), duration: MediaTime(seconds: 4), title: title)
   p.sequence.tracks[2].clips = [cap]
   let video = p; var noCaption = p; noCaption.sequence.tracks[2].clips = []
   _ = video
   let bare = try await frames(noCaption, [1.15, 3.0, 4.999])
   let still = try await frames(p, [3.0])[0]
   cap.titleAnimation = TitleAnimation(inKind: .pop, outKind: .fade, inSeconds: 0.6, outSeconds: 0.5)
   p.sequence.tracks[2].clips = [cap]
   let popped = try await frames(p, [1.15, 3.0, 4.999])
   check("Real footage + pop caption: settles to the steady caption", popped[1].maxDifference(still) <= 2, "difference \(popped[1].maxDifference(still))")
   // The caption is what differs from the same moment without any caption.
   func captionPixels(_ with: Frame, _ without: Frame, _ threshold: Int = 60) -> (count: Int, minX: Int, maxX: Int) {
    var count = 0, minX = with.w, maxX = -1
    for y in 0..<with.h { for x in 0..<with.w { let a = with.rgb(x, y), b = without.rgb(x, y); if abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) > threshold { count += 1; minX = min(minX, x); maxX = max(maxX, x) } } }
    return (count, minX, maxX)
   }
   let steadyCap = captionPixels(popped[1], bare[1]), earlyCap = captionPixels(popped[0], bare[0]), lateCap = captionPixels(popped[2], bare[2])
   check("Real footage + pop caption: caption found in the steady frame", steadyCap.count > 2000 && steadyCap.maxX > steadyCap.minX, "\(steadyCap.count) px")
   let ratio = Double(earlyCap.maxX - earlyCap.minX) / Double(max(1, steadyCap.maxX - steadyCap.minX))
   check("Real footage + pop caption: smaller at the start of the entrance (about 0.93× at 25 %)", ratio > 0.8 && ratio < 0.99, String(format: "%.2f× the steady width", ratio))
   check("Real footage + fade-out caption: mostly gone in the last frames", Double(lateCap.count) < Double(steadyCap.count) * 0.5, "\(lateCap.count) px of \(steadyCap.count)")
  }
  let finalA = try await FileIdentity.sha256(realAURL), finalB = try await FileIdentity.sha256(realBURL)
  check("Real source copies never modified", finalA == digestA && finalB == digestB)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("TRANSITION_RESULT checks=\(rows.count) failures=\(failures)")
  if failures > 0 { exit(1) }
 }
}

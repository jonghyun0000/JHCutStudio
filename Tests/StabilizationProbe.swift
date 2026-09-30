import Foundation
import AVFoundation
import CoreImage
import Vision
@testable import JHCutCore

/// Priority 1: hand-shake stabilisation. Synthetic shake with a KNOWN path measures the estimator
/// and the renderer; real iPhone footage (a read-only COPY) measures residual jitter before/after.
@main struct StabilizationProbe {
 // Known camera path (CI axes: x right, y up, angle CCW) at time t.
 static func truth(_ t: Double) -> (x: Double, y: Double, a: Double) {
  (0.012 * sin(2 * .pi * 2.3 * t) + 0.006 * sin(2 * .pi * 5.1 * t + 1), 0.010 * sin(2 * .pi * 3.1 * t + 0.5) + 0.005 * sin(2 * .pi * 6.7 * t), 0.02 * sin(2 * .pi * 1.7 * t))
 }
 static func main() async throws {
  setbuf(stdout, nil)
  let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Artifacts/Upgrade-0.7/Stabilization", isDirectory: true).standardizedFileURL
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = [], metrics: [String: Any] = [:]
  func check(_ name: String, _ passed: Bool, _ detail: String = "") { rows.append(["name": name, "passed": passed, "detail": detail]); print("\(passed ? "PASS" : "FAIL") \(name) \(detail)") }
  func save() { try? JSONSerialization.data(withJSONObject: ["checks": rows, "metrics": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json")) }
  defer { save() }

  // ---- Pure math ----
  let aspect = 16.0 / 9.0
  check("No correction needs no zoom", StabilizationPlan.requiredZoom(.init(x: 0, y: 0, angle: 0), aspect: aspect) == 1)
  check("Translation of 5% needs 10% zoom", abs(StabilizationPlan.requiredZoom(.init(x: 0.05, y: 0, angle: 0), aspect: aspect) - 1.1) < 1e-9)
  check("Rotation needs more zoom on a wide frame than the same shift", StabilizationPlan.requiredZoom(.init(x: 0, y: 0, angle: 0.05), aspect: aspect) > 1.05)
  let quiet = StabilizationData(step: 1.0 / 30, analyzedStart: .zero, frameWidth: 640, frameHeight: 360, x: [Float](repeating: 0.1, count: 90), y: [Float](repeating: -0.05, count: 90), angle: [Float](repeating: 0.2, count: 90))
  let quietPlan = StabilizationPlan(quiet)!
  check("A steady offset (pure pan/drift) is not corrected", abs(quietPlan.correction(atSource: 1).x) < 1e-6 && abs(quietPlan.zoom - 1) < 1e-9)
  var shaky = quiet; shaky.x = (0..<90).map { Float(0.02 * sin(Double($0) * 1.9)) }; shaky.y = shaky.x; shaky.angle = shaky.x
  let shakyPlan = StabilizationPlan(shaky)!
  check("Shake gives a correction and a zoom within the cap", shakyPlan.zoom > 1 && shakyPlan.zoom <= StabilizationPlan.maximumZoom, String(format: "zoom %.3f", shakyPlan.zoom))
  var wild = shaky; wild.x = (0..<90).map { Float(0.3 * sin(Double($0) * 1.9)) }
  let wildPlan = StabilizationPlan(wild)!
  check("Excessive shake is limited to the zoom cap, never beyond", wildPlan.zoom == StabilizationPlan.maximumZoom && wildPlan.limitedSamples > 0)
  check("A gentle shake reports no limited frames", shakyPlan.limitedSamples == 0, "\(shakyPlan.limitedSamples)")
  var off = shaky; off.enabled = false; var zero = shaky; zero.strength = 0
  check("Disabled or zero-strength data makes no plan", StabilizationPlan(off) == nil && StabilizationPlan(zero) == nil)
  var bad = shaky; bad.y = [1, 2]
  check("Damaged path is refused", bad.validationProblem != nil && StabilizationPlan(bad) == nil)
  check("Coverage test", shaky.covers(MediaTime(seconds: 0.5), duration: MediaTime(seconds: 2)) && !shaky.covers(MediaTime(seconds: 2), duration: MediaTime(seconds: 3)) && !shaky.covers(MediaTime(seconds: 1), duration: MediaTime(seconds: 2.5)))
  var strong = shaky; strong.strength = 1; var soft = shaky; soft.strength = 0.3
  let cs = StabilizationPlan(strong)!.correction(atSource: 0.7), cw = StabilizationPlan(soft)!.correction(atSource: 0.7)
  check("Strength scales the correction", abs(cw.x) < abs(cs.x) * 0.5 + 1e-9 && abs(cs.x) > 0)

  // ---- Synthetic shake with a known path ----
  let still = try await realFrame(root)
  let fps = 30.0, seconds = 8.0, frames = Int(fps * seconds)
  let flat = root.appendingPathComponent("synthetic-shake.mp4"), portrait = root.appendingPathComponent("synthetic-shake-portrait.mp4")
  try await makeShake(still, to: flat, frames: frames, fps: fps, rotate: false)
  try await makeShake(still, to: portrait, frames: frames, fps: fps, rotate: true)
  let flatDigest = try await FileIdentity.sha256(flat)
  let t0 = Date()
  let asset = try await MediaImporter.inspect(url: flat)
  let data = try await StabilizationAnalyzer.analyze(url: flat, sourceStart: .zero, duration: asset.duration)
  metrics["analysisSecondsFor8sClip"] = Date().timeIntervalSince(t0)
  check("Analysis produces one sample per 1/30 s", abs(data.count - frames) <= 2 && data.validationProblem == nil, "\(data.count) samples for \(frames) frames")
  // Compare with the truth (relative to the first frame).
  let t00 = truth(0)
  var ex = 0.0, ey = 0.0, ea = 0.0, n = 0
  for i in 0..<min(data.count, frames) {
   let t = truth(Double(i) / fps)
   ex += pow((Double(data.x[i]) - (t.x - t00.x)) * 640, 2); ey += pow((Double(data.y[i]) - (t.y - t00.y)) * 360, 2); ea += pow((Double(data.angle[i]) - (t.a - t00.a)) * 180 / .pi, 2); n += 1
  }
  let rmsX = sqrt(ex / Double(n)), rmsY = sqrt(ey / Double(n)), rmsA = sqrt(ea / Double(n))
  metrics["pathErrorRMS"] = ["xPixels": rmsX, "yPixels": rmsY, "angleDegrees": rmsA]
  // Diagnosis: what matters for stabilising is the fast part of the path, not slow drift.
  func fast(_ x: [Float], _ y: [Float], _ a: [Float]) -> [StabilizationPlan.Correction] {
   let d = StabilizationData(step: 1.0 / 30, analyzedStart: .zero, frameWidth: 640, frameHeight: 360, x: x, y: y, angle: a, rejectedSteps: 0)
   var probe = d; probe.smoothing = 0.5; let plan = StabilizationPlan(probe, unlimited: true)!
   return (0..<d.count).map { plan.correction(atSource: Double($0) / 30) }
  }
  let m = min(data.count, frames)
  let truthPath = (0..<m).map { truth(Double($0) / fps) }
  let estFast = fast(Array(data.x[0..<m]), Array(data.y[0..<m]), Array(data.angle[0..<m]))
  let truthFast = fast(truthPath.map { Float($0.x) }, truthPath.map { Float($0.y) }, truthPath.map { Float($0.a) })
  var fx = 0.0, fy = 0.0, fa = 0.0, sxx = 0.0, sxy = 0.0
  for i in 0..<m {
   fx += pow((estFast[i].x - truthFast[i].x) * 640, 2); fy += pow((estFast[i].y - truthFast[i].y) * 360, 2); fa += pow((estFast[i].angle - truthFast[i].angle) * 180 / .pi, 2)
   sxx += truthFast[i].x * truthFast[i].x; sxy += truthFast[i].x * estFast[i].x
  }
  let fastX = sqrt(fx / Double(m)), fastY = sqrt(fy / Double(m)), fastA = sqrt(fa / Double(m))
  let truthFastRMS = sqrt(truthFast.reduce(0.0) { $0 + pow($1.x * 640, 2) } / Double(m))
  metrics["fastPartError"] = ["xPixels": fastX, "yPixels": fastY, "angleDegrees": fastA, "truthFastXRMSPixels": truthFastRMS, "xAmplitudeRatio": sxy / sxx]
  print(String(format: "  diagnosis: total error x %.2f px; fast-part error x %.2f px (truth fast part %.2f px RMS), amplitude ratio %.3f, y %.2f px, angle %.3f°", rmsX, fastX, truthFastRMS, sxy / sxx, fastY, fastA))
  check("Estimated fast motion matches the known shake (what stabilisation removes)", fastX < truthFastRMS * 0.25 && fastY < 1.0 && fastA < 0.15, String(format: "fast-part RMS error x %.2f px (truth %.2f px), y %.2f px, angle %.3f°", fastX, truthFastRMS, fastY, fastA))
  check("Estimated path matches the known shake (including slow drift)", rmsX < 4 && rmsY < 3 && rmsA < 0.6, String(format: "RMS error x %.2f px, y %.2f px, angle %.3f°  (shake amplitude ≈ 11 px / 5 px / 1.1°)", rmsX, rmsY, rmsA))
  let plan = StabilizationPlan(data)!
  metrics["zoom"] = plan.zoom; metrics["limitedSamples"] = plan.limitedSamples

  func jitter(_ d: StabilizationData) -> Double { // RMS px of the path minus its own 0.5 s Gaussian smooth, in decoded-frame pixels
   var probe = d; probe.smoothing = 0.5
   let c = StabilizationPlan(probe, unlimited: true)!
   var sum = 0.0
   for i in 0..<d.count { let corr = c.correction(atSource: d.analyzedStart.seconds + Double(i) * d.step); sum += pow(corr.x * Double(d.frameWidth), 2) + pow(corr.y * Double(d.frameHeight), 2) }
   return sqrt(sum / Double(d.count))
  }
  // Render + export with the correction, then measure the exported video with the same estimator.
  func exportStabilized(_ media: URL, portraitOrientation: Bool, settings: (inout StabilizationData) -> Void, name: String) async throws -> (URL, Double, Double) {
   let a = try await MediaImporter.inspect(url: media)
   var d = try await StabilizationAnalyzer.analyze(url: media, sourceStart: .zero, duration: a.duration); settings(&d)
   var p = Project(name: name); p.sequence.width = portraitOrientation ? 360 : 640; p.sequence.height = portraitOrientation ? 640 : 360
   var clip = Clip(name: "흔들림", assetID: a.id, duration: a.duration); clip.transform.fill = true
   clip.stabilization = d; p.assets = [a]; p.sequence.tracks[0].clips = [clip]
   let out = root.appendingPathComponent("\(name).mp4"); try? FileManager.default.removeItem(at: out)
   try await ExportJob().export(plan: TimelineRenderer.build(project: p), to: out) { _ in }
   var plain = p; plain.sequence.tracks[0].clips[0].stabilization = nil
   let control = root.appendingPathComponent("\(name)-control.mp4"); try? FileManager.default.removeItem(at: control)
   try await ExportJob().export(plan: TimelineRenderer.build(project: plain), to: control) { _ in }
   let after = try await StabilizationAnalyzer.analyze(url: out, sourceStart: .zero, duration: try await MediaImporter.inspect(url: out).duration)
   let before = try await StabilizationAnalyzer.analyze(url: control, sourceStart: .zero, duration: try await MediaImporter.inspect(url: control).duration)
   return (out, jitter(before), jitter(after))
  }
  let (outFlat, beforeFlat, afterFlat) = try await exportStabilized(flat, portraitOrientation: false, settings: { $0.smoothing = 0.8 }, name: "stabilized-flat")
  metrics["syntheticFlat"] = ["jitterBeforePx": beforeFlat, "jitterAfterPx": afterFlat]
  check("Synthetic shake: exported jitter drops by at least 80%", afterFlat < beforeFlat * 0.2, String(format: "%.2f px → %.2f px (%.0f%% less)", beforeFlat, afterFlat, (1 - afterFlat / beforeFlat) * 100))
  let (_, beforeP, afterP) = try await exportStabilized(portrait, portraitOrientation: true, settings: { $0.smoothing = 0.8 }, name: "stabilized-portrait")
  metrics["syntheticPortraitTrack"] = ["jitterBeforePx": beforeP, "jitterAfterPx": afterP]
  check("Rotated (portrait) track: jitter also drops by at least 80%", afterP < beforeP * 0.2, String(format: "%.2f px → %.2f px", beforeP, afterP))
  let (_, _, afterHalf) = try await exportStabilized(flat, portraitOrientation: false, settings: { $0.strength = 0.5; $0.smoothing = 0.8 }, name: "stabilized-half")
  check("Half strength removes about half of the jitter", afterHalf > afterFlat && afterHalf < beforeFlat * 0.75 && afterHalf > beforeFlat * 0.25, String(format: "%.2f px (full %.2f, none %.2f)", afterHalf, afterFlat, beforeFlat))
  let darkOut = try await darkEdgeShare(outFlat), darkControl = try await darkEdgeShare(root.appendingPathComponent("stabilized-flat-control.mp4"))
  check("Stabilised frames show no black borders", darkOut <= darkControl + 0.01, String(format: "dark edge pixels %.2f%% (unstabilised %.2f%%)", darkOut * 100, darkControl * 100))

  // ---- Real iPhone footage (read-only copies) ----
  var realDigests: [String: String] = [:]
  var realRows: [[String: Any]] = []
  func realClip(_ file: String) async throws -> (URL, MediaAsset) {
   let url = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/\(file).mov").standardizedFileURL
   if realDigests[file] == nil { realDigests[file] = try await FileIdentity.sha256(url) }
   return (url, try await MediaImporter.inspect(url: url))
  }
  func exportClip(_ project: Project, _ name: String) async throws -> URL {
   let out = root.appendingPathComponent("\(name).mp4"); try? FileManager.default.removeItem(at: out)
   try await ExportJob().export(plan: TimelineRenderer.build(project: project), to: out) { _ in }
   return out
  }
  // (1) Camera fixed on a stand, large subject moving (batting cage). The old whole-frame estimator read the batter as camera
  //     motion (path drifted up to 14 % of the frame height); a correct stabiliser must leave the background where it is.
  for (file, start) in [("IMG_0047", 240.0), ("IMG_0047", 420.0)] {
   let (real, realAsset) = try await realClip(file)
   let s0 = Date()
   var d = try await StabilizationAnalyzer.analyze(url: real, sourceStart: MediaTime(seconds: start), duration: MediaTime(seconds: 20))
   let analysisSeconds = Date().timeIntervalSince(s0); d.smoothing = 0.8
   var p = Project(name: "실사 고정 카메라"); p.sequence.width = 1080; p.sequence.height = 1920
   var clip = Clip(name: "실사", assetID: realAsset.id, sourceStart: MediaTime(seconds: start), duration: MediaTime(seconds: 20)); clip.transform.fill = true
   clip.stabilization = d; p.assets = [realAsset]; p.sequence.tracks[0].clips = [clip]
   let tag = "fixed-\(file)-\(Int(start))"
   let out = try await exportClip(p, "\(tag)-stabilized")
   var plain = p; plain.sequence.tracks[0].clips[0].stabilization = nil
   let control = try await exportClip(plain, "\(tag)-control")
   let planReal = StabilizationPlan(d)!
   let before = try await independentMetrics(control), after = try await independentMetrics(out)
   let maxCorrection = (0..<d.count).map { i -> Double in let c = planReal.correction(atSource: d.analyzedStart.seconds + Double(i) * d.step); return hypot(c.x * 1080, c.y * 1920) }.max() ?? 0
   let row: [String: Any] = ["case": "fixed camera, moving subject", "clip": file, "segment": "\(Int(start))–\(Int(start + 20))s", "analysisSeconds": analysisSeconds, "analysisRealtimeFactor": 20 / analysisSeconds, "zoom": planReal.zoom,
                             "largestCorrectionPx1080": maxCorrection, "rejectedSteps": d.rejectedSteps, "pathJitterBeforePx": before.path, "pathJitterAfterPx": after.path, "frameNoiseBeforePx480": before.noise, "frameNoiseAfterPx480": after.noise]
   realRows.append(row)
   print(String(format: "  fixed camera %@ %ds: largest correction %.2f px (of 1080), zoom %.3f, path jitter %.2f → %.2f px, frame noise %.3f → %.3f, analysis %.1fs", file, Int(start), maxCorrection, planReal.zoom, before.path, after.path, before.noise, after.noise, analysisSeconds))
   check("Fixed camera + moving subject \(file) \(Int(start))s: background is not moved (largest correction < 3 px of 1080, zoom < 1.03)", maxCorrection < 3 && planReal.zoom < 1.03, "\(row)")
   check("Fixed camera \(file) \(Int(start))s: exported jitter not increased", after.path <= before.path + 0.75 && after.noise < 0.3, String(format: "%.2f → %.2f px", before.path, after.path))
  }
  // (2) Real content with a KNOWN shake added: keyframes through the normal renderer make the shaky version.
  for (file, start) in [("IMG_0047", 240.0), ("IMG_9211", 120.0)] {
   let (real, realAsset) = try await realClip(file)
   var shakyProject = Project(name: "실사 흔들림 합성"); shakyProject.sequence.width = 1080; shakyProject.sequence.height = 1920
   var clip = Clip(name: "실사", assetID: realAsset.id, sourceStart: MediaTime(seconds: start), duration: MediaTime(seconds: 20)); clip.transform.fill = true; clip.transform.scale = 1.15
   clip.keyframes = (0...600).map { k in
    let t = truth(Double(k) / 30)
    return TransformKeyframe(time: MediaTime(Int64(k), 30), transform: ClipTransform(x: t.x * 1080, y: t.y * 1920, scale: 1.15, rotation: t.a * 180 / .pi, opacity: 1, fill: true))
   }
   shakyProject.assets = [realAsset]; shakyProject.sequence.tracks[0].clips = [clip]
   var originalProject = shakyProject; originalProject.sequence.tracks[0].clips[0].keyframes = nil
   let tag = "shaken-\(file)-\(Int(start))"
   let shaky = try await exportClip(shakyProject, "\(tag)-shaky"), original = try await exportClip(originalProject, "\(tag)-original")
   let shakyAsset = try await MediaImporter.inspect(url: shaky)
   let s0 = Date()
   var d = try await StabilizationAnalyzer.analyze(url: shaky, sourceStart: .zero, duration: shakyAsset.duration); d.smoothing = 0.8
   let analysisSeconds = Date().timeIntervalSince(s0)
   // Path accuracy against the known shake, on the part that matters (fast motion), in export pixels.
   let m = min(d.count, 600)
   let truthPath = (0..<m).map { truth(Double($0) / 30) }
   func fastPart(_ x: [Float], _ y: [Float], _ a: [Float]) -> [StabilizationPlan.Correction] {
    var probe = StabilizationData(step: 1.0 / 30, analyzedStart: .zero, frameWidth: 1080, frameHeight: 1920, x: x, y: y, angle: a); probe.smoothing = 0.5
    let plan = StabilizationPlan(probe, unlimited: true)!
    return (0..<x.count).map { plan.correction(atSource: Double($0) / 30) }
   }
   let est = fastPart(Array(d.x[0..<m]), Array(d.y[0..<m]), Array(d.angle[0..<m])), tru = fastPart(truthPath.map { Float($0.x) }, truthPath.map { Float($0.y) }, truthPath.map { Float($0.a) })
   var errSum = 0.0, truthSum = 0.0
   for i in 0..<m { errSum += pow((est[i].x - tru[i].x) * 1080, 2) + pow((est[i].y - tru[i].y) * 1920, 2); truthSum += pow(tru[i].x * 1080, 2) + pow(tru[i].y * 1920, 2) }
   let fastErr = sqrt(errSum / Double(m)), fastTruth = sqrt(truthSum / Double(m))
   // Stabilise the shaky export and measure everything on the exported files with the independent estimator.
   var p = Project(name: "실사 안정화"); p.sequence.width = 1080; p.sequence.height = 1920
   var sc = Clip(name: "흔들림", assetID: shakyAsset.id, duration: shakyAsset.duration); sc.transform.fill = true; sc.stabilization = d
   p.assets = [shakyAsset]; p.sequence.tracks[0].clips = [sc]
   let fixed = try await exportClip(p, "\(tag)-stabilized")
   let mShaky = try await independentMetrics(shaky), mFixed = try await independentMetrics(fixed), mOriginal = try await independentMetrics(original)
   let planShaky = StabilizationPlan(d)!
   let row: [String: Any] = ["case": "real content + known shake", "clip": file, "segment": "\(Int(start))–\(Int(start + 20))s", "analysisSeconds": analysisSeconds, "fastPathErrorPx": fastErr, "fastPathTruthRMSPx": fastTruth,
                             "zoom": planShaky.zoom, "limitedShare": Double(planShaky.limitedSamples) / Double(d.count), "originalJitterPx": mOriginal.path, "shakyJitterPx": mShaky.path, "stabilizedJitterPx": mFixed.path, "frameNoiseShaky": mShaky.noise, "frameNoiseStabilized": mFixed.noise]
   realRows.append(row)
   print(String(format: "  known shake on real %@ %ds: estimated fast motion error %.2f px (shake %.2f px RMS); jitter original %.2f, shaky %.2f → stabilised %.2f px; zoom %.3f", file, Int(start), fastErr, fastTruth, mOriginal.path, mShaky.path, mFixed.path, planShaky.zoom))
   check("Known shake on real \(file) \(Int(start))s: estimated motion within 25% of the shake", fastErr < fastTruth * 0.25, String(format: "%.2f px error vs %.2f px shake", fastErr, fastTruth))
   // The independent estimator also reads bogus jitter from the moving subject even in the ORIGINAL footage (camera fixed). Shake and that
   // measurement floor are independent, so they add in quadrature: shake = √(shaky² − original²), residual = √(max(0, stabilised² − original²)).
   let shakeQ = sqrt(max(0, mShaky.path * mShaky.path - mOriginal.path * mOriginal.path)), residualQ = sqrt(max(0, mFixed.path * mFixed.path - mOriginal.path * mOriginal.path))
   realRows[realRows.count - 1]["shakeAboveFloorPx"] = shakeQ; realRows[realRows.count - 1]["residualAboveFloorPx"] = residualQ
   check("Known shake on real \(file) \(Int(start))s: at least 75% of the shake removed (measured above the footage's own floor)", shakeQ > 10 && residualQ <= shakeQ * 0.25, String(format: "shake %.2f px (truth RMS %.2f) → residual %.2f px; raw jitter %.2f → %.2f, original %.2f", shakeQ, fastTruth, residualQ, mShaky.path, mFixed.path, mOriginal.path))
   check("Known shake on real \(file) \(Int(start))s: stabilised is no worse than the original footage", mFixed.path <= mOriginal.path + 1.0, String(format: "%.2f vs %.2f px", mFixed.path, mOriginal.path))
  }
  // (3) A steady clip (concert, phone on a stand): stabilising must add no visible noise.
  do {
   let (real, realAsset) = try await realClip("IMG_0140")
   let d0 = try await StabilizationAnalyzer.analyze(url: real, sourceStart: MediaTime(seconds: 300), duration: MediaTime(seconds: 20)); var d = d0; d.smoothing = 0.8
   var p = Project(name: "실사 고정"); p.sequence.width = 1080; p.sequence.height = 1920
   var clip = Clip(name: "실사", assetID: realAsset.id, sourceStart: MediaTime(seconds: 300), duration: MediaTime(seconds: 20)); clip.transform.fill = true; clip.stabilization = d
   p.assets = [realAsset]; p.sequence.tracks[0].clips = [clip]
   let out = try await exportClip(p, "steady-IMG_0140-stabilized"); var plain = p; plain.sequence.tracks[0].clips[0].stabilization = nil
   let control = try await exportClip(plain, "steady-IMG_0140-control")
   let before = try await independentMetrics(control), after = try await independentMetrics(out)
   let plan = StabilizationPlan(d)!
   realRows.append(["case": "steady footage", "clip": "IMG_0140", "zoom": plan.zoom, "pathJitterBeforePx": before.path, "pathJitterAfterPx": after.path, "frameNoiseBeforePx480": before.noise, "frameNoiseAfterPx480": after.noise])
   check("Steady footage: nothing to correct, no added noise", plan.zoom < 1.01 && after.noise <= before.noise + 0.05, String(format: "zoom %.3f, jitter %.2f → %.2f px, noise %.3f → %.3f", plan.zoom, before.path, after.path, before.noise, after.noise))
  }
  metrics["realFootage"] = realRows
  let real = URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov").standardizedFileURL

  // ---- Save / reopen, cancel, source untouched ----
  var project = Project(name: "안정화 저장"); project.sequence.width = 640; project.sequence.height = 360
  var savedClip = Clip(name: "흔들림", assetID: asset.id, duration: asset.duration); savedClip.stabilization = data
  project.assets = [asset]; project.sequence.tracks[0].clips = [savedClip]
  let doc = root.appendingPathComponent("Stabilized.jhcut")
  try ProjectStore.save(project, to: doc)
  let reopened = try ProjectStore.load(from: doc)
  check("Save/reopen keeps the measured path exactly", reopened.sequence.tracks[0].clips[0].stabilization == data)
  metrics["storedPathBytesFor8s"] = (try? Data(contentsOf: doc).count) ?? 0
  var forged = try JSONSerialization.jsonObject(with: Data(contentsOf: doc)) as! [String: Any]
  var seq = forged["sequence"] as! [String: Any]; var tracks = seq["tracks"] as! [[String: Any]]; var clips = tracks[0]["clips"] as! [[String: Any]]
  var st = clips[0]["stabilization"] as! [String: Any]; st["surprise"] = 1; clips[0]["stabilization"] = st; tracks[0]["clips"] = clips; seq["tracks"] = tracks; forged["sequence"] = seq
  let forgedURL = root.appendingPathComponent("Forged.jhcut"); try JSONSerialization.data(withJSONObject: forged).write(to: forgedURL)
  check("Unknown fields inside the stabilisation block are refused", (try? ProjectStore.load(from: forgedURL)) == nil)
  var titleClip = Clip(name: "제목", start: .zero, duration: MediaTime(seconds: 2), title: Title(text: "x")); titleClip.stabilization = data
  var wrong = project; wrong.sequence.tracks[2].clips = [titleClip]
  check("Stabilisation on a title clip is refused", (try? ProjectValidator.validate(wrong)) == nil)
  let cancelTask = Task { try await StabilizationAnalyzer.analyze(url: real, sourceStart: .zero, duration: MediaTime(seconds: 120)) }
  try await Task.sleep(nanoseconds: 1_500_000_000); cancelTask.cancel()
  var cancelled = false
  do { _ = try await cancelTask.value } catch is CancellationError { cancelled = true } catch {}
  check("Analysis can be cancelled and returns nothing", cancelled)
  var refusedLong = false
  do { _ = try await StabilizationAnalyzer.analyze(url: real, sourceStart: .zero, duration: MediaTime(seconds: 601)) } catch { refusedLong = error.localizedDescription.contains("10분") }
  check("Over-long clip is refused with a clear message", refusedLong)
  var unchanged = true
  for (file, digest) in realDigests { if try await FileIdentity.sha256(URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/\(file).mov")) != digest { unchanged = false } }
  let flatAfter = try await FileIdentity.sha256(flat)
  check("Source media never modified", unchanged && flatAfter == flatDigest)
  let failures = rows.filter { ($0["passed"] as? Bool) != true }.count
  print("STABILIZATION_RESULT checks=\(rows.count) failures=\(failures)")
  save(); if failures > 0 { exit(1) }
 }

 /// One upright frame of a real iPhone clip (copy), scaled to fill 640×360.
 static func realFrame(_ root: URL) async throws -> CIImage {
  let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: "Artifacts/Upgrade-0.7/RealCopies/IMG_9211.mov")))
  g.appliesPreferredTrackTransform = true; g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
  let cg = try g.copyCGImage(at: CMTime(seconds: 500, preferredTimescale: 600), actualTime: nil)
  let ci = CIImage(cgImage: cg)
  let s = max(640 / ci.extent.width, 360 / ci.extent.height)
  return ci.transformed(by: CGAffineTransform(scaleX: s, y: s)).transformed(by: CGAffineTransform(translationX: 320 - ci.extent.width * s / 2, y: 180 - ci.extent.height * s / 2)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
 }

 static func makeShake(_ still: CIImage, to url: URL, frames: Int, fps: Double, rotate: Bool) async throws {
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000], AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
  if rotate { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
  writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
  let ctx = CIContext(); let c = CGPoint(x: 320, y: 180)
  for k in 0..<frames {
   while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
   let t = truth(Double(k) / fps)
   // 1.2× base zoom keeps the shifted picture inside the frame.
   let image = still.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)).transformed(by: CGAffineTransform(scaleX: 1.2, y: 1.2))
    .transformed(by: CGAffineTransform(rotationAngle: t.a)).transformed(by: CGAffineTransform(translationX: c.x + t.x * 640, y: c.y + t.y * 360)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
   var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
   ctx.render(image, to: buffer!)
   adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps)))
  }
  input.markAsFinished(); await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? StabilizationError("synthetic video failed") }
 }

 /// Two numbers from Vision's TRANSLATIONAL registration (a different estimator than the homographic one the stabiliser uses):
 /// `path` = RMS px of the cumulative path minus its own 0.5 s Gaussian smooth, in exported-frame pixels;
 /// `noise` = RMS px (at 480 px wide) of each frame-to-frame step minus the mean of its four neighbours.
 static func independentMetrics(_ url: URL) async throws -> (path: Double, noise: Double) {
  let asset = AVURLAsset(url: url); let track = try await asset.loadTracks(withMediaType: .video)[0]
  let size = try await track.load(.naturalSize), reader = try AVAssetReader(asset: asset)
  let scale = 480 / max(size.width, size.height), bw = Int(size.width * scale), bh = Int(size.height * scale)
  let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: bw, kCVPixelBufferHeightKey as String: bh])
  reader.add(out); reader.startReading()
  var prev: CVPixelBuffer?, deltas: [(Double, Double)] = []
  while let s = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) {
   try autoreleasepool {
    if let p = prev {
     let r = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: p); try VNImageRequestHandler(cvPixelBuffer: pb).perform([r])
     if let t = (r.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform { deltas.append((Double(t.tx), Double(t.ty))) } else { deltas.append((0, 0)) }
    }
    prev = pb
   }
  }
  var sum = 0.0, n = 0
  for i in 2..<max(2, deltas.count - 2) {
   let mx = (deltas[i - 2].0 + deltas[i - 1].0 + deltas[i + 1].0 + deltas[i + 2].0) / 4, my = (deltas[i - 2].1 + deltas[i - 1].1 + deltas[i + 1].1 + deltas[i + 2].1) / 4
   sum += pow(deltas[i].0 - mx, 2) + pow(deltas[i].1 - my, 2); n += 1
  }
  var x: [Float] = [0], y: [Float] = [0], cx = 0.0, cy = 0.0
  for d in deltas { cx += d.0 / Double(bw); cy += d.1 / Double(bh); x.append(Float(cx)); y.append(Float(cy)) }
  let data = StabilizationData(step: 1.0 / 30, analyzedStart: .zero, frameWidth: Int(size.width), frameHeight: Int(size.height), x: x, y: y, angle: [Float](repeating: 0, count: x.count))
  var probe = data; probe.smoothing = 0.5
  let plan = StabilizationPlan(probe, unlimited: true)!
  var path = 0.0
  for i in 0..<data.count { let c = plan.correction(atSource: Double(i) / 30); path += pow(c.x * size.width, 2) + pow(c.y * size.height, 2) }
  return (sqrt(path / Double(data.count)), sqrt(sum / Double(max(1, n))))
 }

 /// Share of near-black pixels in the outer 3 px band, averaged over six frames.
 static func darkEdgeShare(_ url: URL) async throws -> Double {
  let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
  var total = 0.0
  for k in 1...6 {
   let cg = try g.copyCGImage(at: CMTime(seconds: Double(k) * 1.1, preferredTimescale: 600), actualTime: nil)
   let w = cg.width, h = cg.height; var px = [UInt8](repeating: 0, count: w * h * 4)
   let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
   ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
   var dark = 0, count = 0
   for y in 0..<h { for x in 0..<w where x < 3 || y < 3 || x >= w - 3 || y >= h - 3 { count += 1; if Int(px[(y * w + x) * 4]) + Int(px[(y * w + x) * 4 + 1]) + Int(px[(y * w + x) * 4 + 2]) < 24 { dark += 1 } } }
   total += Double(dark) / Double(count)
  }
  return total / 6
 }
}

import Foundation
import AVFoundation
import Darwin
import JHCutCore

@main struct MediaSafety05Probe {
 static func main() async throws {
  let root = URL(fileURLWithPath: "Artifacts/Upgrade-0.5/MediaSafety-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var rows: [[String: Any]] = []
  func check(_ name: String, _ ok: Bool) { rows.append(["name": name, "passed": ok]); print("\(ok ? "PASS" : "FAIL") \(name)") }
  let source = root.appendingPathComponent("stereo.wav")
  let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!; buffer.frameLength = 32000
  for i in 0..<32000 { buffer.floatChannelData![0][i] = Float(0.7 * sin(Double(i) * 2 * .pi * 400 / 16000)); buffer.floatChannelData![1][i] = Float(0.05 * sin(Double(i) * 2 * .pi * 900 / 16000)) }
  do { let writer = try AVAudioFile(forWriting: source, settings: format.settings); try writer.write(from: buffer) }
  let quiet = try await LocalTranscription.previewChannel(url: source, sourceStart: .zero, duration: MediaTime(2,1), channel: 1)
  let automatic = try await LocalTranscription.previewChannel(url: source, sourceStart: .zero, duration: MediaTime(2,1), channel: -1)
  let quietURL = root.appendingPathComponent("quiet.wav"), loudURL = root.appendingPathComponent("auto.wav")
  try quiet.data.write(to: quietURL); try automatic.data.write(to: loudURL)
  let quietAnalysis = try await AudioAnalysis.analyze(url: quietURL), loudAnalysis = try await AudioAnalysis.analyze(url: loudURL)
  check("Quiet dialogue channel can override loud music channel", quiet.channel == 1 && automatic.channel == 0 && (quietAnalysis.peakDBFS ?? 0) < (loudAnalysis.peakDBFS ?? 0) - 20)
  do { _ = try await LocalTranscription.previewChannel(url: source, sourceStart: .zero, duration: MediaTime(2,1), channel: 7); check("Missing channel rejected", false) } catch { check("Missing channel rejected", true) }
  var original = try await MediaImporter.inspect(url: source); original.contentHash = try await FileIdentity.sha256(source)
  original.path = root.appendingPathComponent("missing/stereo.wav").path
  var mismatch = original; mismatch.id = UUID(); mismatch.contentHash = String(repeating: "0", count: 64)
  var unknown = original; unknown.id = UUID(); unknown.contentHash = nil
  let matches = try await FolderRelinking.replacements(for: [original, mismatch, unknown], folder: root)
  check("Folder reconnect matches only identical bytes and preserves ID", matches.count == 1 && matches[0].id == original.id && matches[0].contentHash == original.contentHash)
  check("Same-name mismatch and unknown identity remain manual", !matches.contains { $0.id == mismatch.id || $0.id == unknown.id })
  let cacheRoot = root.appendingPathComponent("cache"), external = root.appendingPathComponent("keep")
  try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
  try Data("keep".utf8).write(to: external.appendingPathComponent("sentinel"))
  try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
  func scratch(_ pid: Int32?) throws -> URL {
   let url = cacheRoot.appendingPathComponent(".generating-" + UUID().uuidString)
   try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
   if let pid { try String(pid).write(to: url.appendingPathComponent("owner.pid"), atomically: true, encoding: .utf8) }; return url
  }
  var absent: Int32 = 999999; while kill(absent,0) != -1 || errno != ESRCH { absent += 1 }
  let abandoned = try scratch(absent), live = try scratch(getpid()), unowned = try scratch(nil)
  let link = cacheRoot.appendingPathComponent(".generating-" + UUID().uuidString)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
  let removed = try await ProxyCache(directory: cacheRoot).cleanAbandoned()
  check("Only dead-owner proxy scratch is deleted", removed == 1 && !FileManager.default.fileExists(atPath: abandoned.path) && FileManager.default.fileExists(atPath: live.path) && FileManager.default.fileExists(atPath: unowned.path))
  check("Proxy cleanup preserves symlink target", FileManager.default.fileExists(atPath: external.appendingPathComponent("sentinel").path))
  try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("checks.json"))
  print("Evidence: " + root.path)
  if rows.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
 }
}

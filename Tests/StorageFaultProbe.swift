import Foundation
import JHCutCore
@main struct StorageFaultProbe {
 static func main() async throws {
  let mode=CommandLine.arguments[1],root=URL(fileURLWithPath:CommandLine.arguments[2]),url=root.appendingPathComponent("project.jhcut")
  switch mode {
  case "seed":
    var p=Project(name:"saved-one");try ProjectStore.save(p,to:url);p.name="saved-two";try ProjectStore.save(p,to:url)
    try RecoveryStore(directory:root.appendingPathComponent("Recovery")).save(project:p,documentURL:url,mediaBaseURL:url)
  case "full":
    var p=try ProjectStore.load(from:url);p.name="must-not-replace-good-copy"
    var failed=false
    do {try ProjectStore.save(p,to:url)} catch {failed=true;print("Save failed as expected: \(error.localizedDescription)")}
    guard failed,try ProjectStore.load(from:url).name == "saved-two",try ProjectStore.recover(from:url).name.hasPrefix("saved-") else {throw ProjectError("Full disk did not preserve saved document")}
    print("PASS real ENOSPC preserves current and valid backup")
  case "crash":
    var p=try ProjectStore.load(from:url)
    for index in 0..<10000 {
      p.name="cycle-\(index)"
      try Data("writing".utf8).write(to:root.appendingPathComponent("writing"))
      try ProjectStore.save(p,to:url)
      try RecoveryStore(directory:root.appendingPathComponent("Recovery")).save(project:p,documentURL:url,mediaBaseURL:url)
    }
  case "verify":
    _=try ProjectStore.load(from:url);_=try ProjectStore.recover(from:url)
    let recovery=RecoveryStore(directory:root.appendingPathComponent("Recovery"))
    guard try !recovery.availableSnapshots().isEmpty else {throw ProjectError("Recovery missing")}
    print("PASS killed writer leaves readable saved document, backup, recovery")
  case "prepare-media":
    let outside=URL(fileURLWithPath:CommandLine.arguments[3])
    let asset=try await MediaImporter.inspect(url:root.appendingPathComponent("clip.mp4"))
    var p=Project(name:"Disposable volume reconnection");p.sequence.width=640;p.sequence.height=360;p.assets=[asset]
    p.sequence.tracks[0].clips=[Clip(assetID:asset.id,duration:MediaTime(2,1))]
    try ProjectStore.save(p,to:outside.appendingPathComponent("reconnect.jhcut"))
  case "offline":
    let outside=URL(fileURLWithPath:CommandLine.arguments[3]),document=outside.appendingPathComponent("reconnect.jhcut")
    let before=try Data(contentsOf:document),p=try ProjectStore.load(from:document)
    var rejected=false
    do {_=try await TimelineRenderer.build(project:p)} catch {rejected=true}
    guard rejected,try Data(contentsOf:document)==before else {throw ProjectError("Offline source was not rejected or document changed")}
    print("PASS detached disposable volume is rejected without changing document")
  case "resumed":
    let outside=URL(fileURLWithPath:CommandLine.arguments[3])
    let p=try ProjectStore.load(from:outside.appendingPathComponent("reconnect.jhcut")),plan=try await TimelineRenderer.build(project:p)
    let output=outside.appendingPathComponent("reconnected-\(UUID().uuidString).mp4")
    try await ExportJob().export(plan:plan,to:output){_ in}
    guard try await MediaImporter.inspect(url:output).supported else {throw ProjectError("Reconnected export failed inspection")}
    print("PASS remounted disposable source exports a readable video")
  default:throw ProjectError("Unknown test mode")
  }
 }
}

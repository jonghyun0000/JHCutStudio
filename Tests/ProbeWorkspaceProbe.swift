import Foundation
@main struct ProbeWorkspaceProbe {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("JHCut-Workspace-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var failures = 0, count = 0
        func check(_ name: String, _ value: Bool) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func refused(_ path: String) -> Bool { do { _ = try ProbeWorkspace.prepare(defaultPath: "", path: path); return false } catch { return true } }
        let first = try ProbeWorkspace.prepare(defaultPath: "", path: base.appendingPathComponent("first").path)
        let sentinel = first.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
        check("Nonempty output refused", refused(first.path))
        check("Existing evidence preserved", try Data(contentsOf: sentinel) == Data("keep".utf8))
        check("Home refused", refused(fm.homeDirectoryForCurrentUser.path))
        check("Repository refused", refused(fm.currentDirectoryPath))
        check("Filesystem root refused", refused("/"))
        check("Original media refused", refused("/Volumes/Example/OriginalMedia"))
        check("Parent traversal refused", refused(base.path + "/first/../escape"))
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: first)
        check("Symlink output refused", refused(link.appendingPathComponent("child").path))
        let second = try ProbeWorkspace.prepare(defaultPath: "", path: base.appendingPathComponent("second").path)
        check("Distinct runs preserve each other", first != second && fm.fileExists(atPath: sentinel.path))
        check("Workspace marker written", fm.fileExists(atPath: second.appendingPathComponent(".jhcut-probe-workspace").path))
        // Exercise actual filesystem aliases, rather than only comparing normalized strings.
        let privateBase = base.path.hasPrefix("/var/") ? "/private" + base.path : base.path
        guard privateBase.hasPrefix("/private/var/") else { throw NSError(domain: "JHCut.WorkspaceFixture", code: 1) }
        let aliasBase = String(privateBase.dropFirst("/private".count))
        let privateOutput = try ProbeWorkspace.prepare(defaultPath: "", path: privateBase + "/private-alias-output")
        let privateSentinel = privateOutput.appendingPathComponent("preserve.txt")
        try Data("alias evidence".utf8).write(to: privateSentinel)
        check("Private var temporary output is accepted", fm.fileExists(atPath: aliasBase + "/private-alias-output/.jhcut-probe-workspace"))
        let aliasOutput = try ProbeWorkspace.prepare(defaultPath: "", path: aliasBase + "/var-alias-output")
        check("Var temporary output is accepted", fm.fileExists(atPath: privateBase + "/var-alias-output/.jhcut-probe-workspace") && aliasOutput != privateOutput)
        check("Alternate spelling cannot overwrite existing evidence", refused(aliasBase + "/private-alias-output"))
        check("Alias refusal preserves exact prior bytes", try Data(contentsOf: privateSentinel) == Data("alias evidence".utf8))
        let outside = "JHCut-forbidden-" + UUID().uuidString
        check("Private var outside user temporary root refused", refused("/private/var/" + outside))
        check("Var alias outside user temporary root refused", refused("/var/" + outside))
        print("WORKSPACE_RESULT checks=\(count) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

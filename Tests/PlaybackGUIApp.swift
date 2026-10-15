#if PLAYBACK_GUI_PROBE
import SwiftUI
import AppKit
import JHCutCore

// Separate app identity and recovery directory: GUI verification cannot overwrite user recovery.
@main struct PlaybackGUIApp: App {
    @StateObject private var model: EditorModel
    @State private var loaded = false
    init() {
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "JHCutQARoot") as! String)
        _model = StateObject(wrappedValue: EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json"), proxyCache: ProxyCache(directory: root.appendingPathComponent("ProxyCache"))))
    }
    var body: some Scene {
        WindowGroup("JH CUT · Playback QA") {
            EditorView(model:model).preferredColorScheme(.dark).frame(minWidth:1000,minHeight:700)
                .onAppear {
                    guard !loaded else { return }; loaded = true
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps:true)
                    model.load(URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "JHCutQAProject") as! String))
                }
        }.defaultSize(width:1400,height:920)
    }
}
#endif

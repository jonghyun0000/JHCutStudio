#if CAPTION_WORKFLOW_GUI
import SwiftUI
import AppKit
import JHCutCore

/// Uses the product EditorView with an isolated document, recovery slot and export journal.
@main struct CaptionWorkflowGUIApp: App {
    @StateObject private var model: EditorModel
    @State private var loaded = false
    init() {
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "JHCutQARoot") as! String, isDirectory: true)
        _model = StateObject(wrappedValue: EditorModel(recoveryStore: RecoveryStore(directory: root.appendingPathComponent("Recovery")), exportHistoryURL: root.appendingPathComponent("journal.json")))
    }
    var body: some Scene {
        WindowGroup("JH CUT · Caption Workflow QA") {
            EditorView(model: model).preferredColorScheme(.dark).frame(minWidth: 1200, minHeight: 860)
                .onAppear {
                    guard !loaded else { return }; loaded = true
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.load(URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "JHCutQAProject") as! String))
                }
        }.defaultSize(width: 1500, height: 1050)
    }
}
#endif

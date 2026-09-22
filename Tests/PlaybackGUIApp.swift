#if PLAYBACK_GUI_PROBE
import SwiftUI
import AppKit
import JHCutCore

// Separate app identity and recovery directory: GUI verification cannot overwrite user recovery.
@main struct PlaybackGUIApp: App {
    @StateObject private var model = EditorModel(recoveryStore: RecoveryStore(directory: URL(fileURLWithPath: "/Volumes/T7/GPT/JHCutStudio/Artifacts/Playback-Library/gui-recovery")))
    var body: some Scene {
        WindowGroup("JH CUT · Playback QA") {
            EditorView(model:model).preferredColorScheme(.dark).frame(minWidth:1000,minHeight:700)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps:true)
                    model.load(URL(fileURLWithPath:"/Volumes/T7/GPT/JHCutStudio/Artifacts/Playback-Library/library-demo-long.jhcut"))
                }
        }.defaultSize(width:1400,height:920)
    }
}
#endif

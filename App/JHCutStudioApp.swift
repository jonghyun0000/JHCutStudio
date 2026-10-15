import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var editor: EditorModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor else { return .terminateNow }
        if editor.busyDocument {
            let alert = NSAlert(); alert.messageText = UIL10n.text("파일 작업이 진행 중입니다.")
            alert.informativeText = UIL10n.text("진행 중인 가져오기·출력·분석·프록시 작업을 완료하거나 취소한 뒤 종료하세요."); alert.runModal()
            return .terminateCancel
        }
        return editor.permitDiscard() ? .terminateNow : .terminateCancel
    }
}

@main
struct JHCutStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = EditorModel()
    @State private var showingLicenses = false
    @StateObject private var uiLanguage = AppUILanguage()
    var body: some Scene {
        WindowGroup("JH CUT Studio") {
            EditorView(model: model).preferredColorScheme(.dark)
                .environment(\.locale, uiLanguage.locale)
                .frame(minWidth: 1000, minHeight: 700)
                .sheet(isPresented: $showingLicenses) { LicenseInformationView() }
                .onAppear {
                    delegate.editor = model
                    if let index = CommandLine.arguments.firstIndex(of: "--project"), CommandLine.arguments.count > index + 1 {
                        model.load(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    } else { model.checkRecoveryOnLaunch() }
                    // Read-only install check; only problems that stop a feature raise an alert.
                    model.runDiagnostics(alertOnError: true)
                }
                .onOpenURL { model.load($0) }
        }
        .defaultSize(width: 1400, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(UIL10n.text("라이선스 및 소재 출처…")) { showingLicenses = true }
            }
            CommandGroup(replacing: .newItem) {
                Button(UIL10n.text("새 프로젝트")) { model.newProject() }.keyboardShortcut("n")
                Button(UIL10n.text("프로젝트 열기…")) { model.openProject() }.keyboardShortcut("o")
                Button(UIL10n.text("미디어 가져오기…")) { model.chooseMedia() }.keyboardShortcut("i")
            }
            CommandGroup(replacing: .saveItem) {
                Button(UIL10n.text("저장")) { model.save() }.keyboardShortcut("s")
                Button(UIL10n.text("다른 이름으로 저장…")) { model.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .undoRedo) {
                Button(UIL10n.text("타임라인 실행취소")) { model.undo() }.disabled(!model.history.canUndo || model.isExporting)
                Button(UIL10n.text("타임라인 재실행")) { model.redo() }.disabled(!model.history.canRedo || model.isExporting)
            }
            CommandMenu("앱 언어 / App Language") {
                Picker("앱 언어 / App Language", selection: $uiLanguage.selection) {
                    Text(verbatim: "한국어").tag("ko")
                    Text(verbatim: "English").tag("en")
                }
                Divider()
                Text(UIL10n.text("영어 UI는 현재 일부 화면과 오류 안내에만 적용됩니다."))
            }
            CommandMenu(UIL10n.text("타임라인")) {
                Button(model.playing ? UIL10n.text("일시정지") : UIL10n.text("재생")) { model.togglePlay() }
                    .disabled(!model.playing && (model.plan == nil || model.isBuilding))
                Button(UIL10n.text("재생 정지")) { model.pausePlayback(); model.stopAudition() }
                Divider()
                Button(UIL10n.text("재생 진단 시작")) { model.startPlaybackObservation() }
                    .disabled(model.plan == nil || model.isBuilding || model.playbackObservationChangeRequiresPause())
                Button(UIL10n.text("상세 오디오 진단 시작")) { model.startPlaybackObservation(mode: .trackPostEffects) }
                    .disabled(model.plan == nil || model.isBuilding || model.playbackObservationChangeRequiresPause(mode: .trackPostEffects))
                Button(UIL10n.text("재생 진단 저장…")) { model.savePlaybackObservation() }.disabled(model.playbackObservation == nil)
                Divider()
                Button(UIL10n.text("플레이헤드에서 분할")) { model.split() }.keyboardShortcut("b").disabled(model.selected == nil || model.isExporting)
                Button(UIL10n.text("선택 클립 복제")) { model.duplicateSelection() }.keyboardShortcut("d").disabled(model.selected == nil || model.isExporting)
                Button(UIL10n.text("선택 항목 삭제")) { model.remove() }.disabled(model.selected == nil || model.isExporting)
                Button(UIL10n.text("리플 삭제 · 현재 트랙")) { model.remove(ripple: true) }.disabled(model.selected == nil || model.isExporting)
                Button(UIL10n.text("한국어 제목 추가")) { model.addTitle() }.disabled(model.isExporting)
                Divider()
                Button(UIL10n.text("영상 출력…")) { model.exportVideo() }.keyboardShortcut("e").disabled(model.plan == nil || model.isExporting)
            }
        }
    }
}

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
            let alert = NSAlert(); alert.messageText = "파일 작업이 진행 중입니다."
            alert.informativeText = "진행 중인 가져오기·출력·분석·프록시 작업을 완료하거나 취소한 뒤 종료하세요."; alert.runModal()
            return .terminateCancel
        }
        return editor.permitDiscard() ? .terminateNow : .terminateCancel
    }
}

@main
struct JHCutStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = EditorModel()
    var body: some Scene {
        WindowGroup("JH CUT Studio") {
            EditorView(model: model).preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 700)
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
            CommandGroup(replacing: .newItem) {
                Button("새 프로젝트") { model.newProject() }.keyboardShortcut("n")
                Button("프로젝트 열기…") { model.openProject() }.keyboardShortcut("o")
                Button("미디어 가져오기…") { model.chooseMedia() }.keyboardShortcut("i")
            }
            CommandGroup(replacing: .saveItem) {
                Button("저장") { model.save() }.keyboardShortcut("s")
                Button("다른 이름으로 저장…") { model.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .undoRedo) {
                Button("타임라인 실행취소") { model.undo() }.disabled(!model.history.canUndo || model.isExporting)
                Button("타임라인 재실행") { model.redo() }.disabled(!model.history.canRedo || model.isExporting)
            }
            CommandMenu("타임라인") {
                Button("플레이헤드에서 분할") { model.split() }.keyboardShortcut("b").disabled(model.selected == nil || model.isExporting)
                Button("선택 클립 복제") { model.duplicateSelection() }.keyboardShortcut("d").disabled(model.selected == nil || model.isExporting)
                Button("선택 항목 삭제") { model.remove() }.disabled(model.selected == nil || model.isExporting)
                Button("리플 삭제 · 현재 트랙") { model.remove(ripple: true) }.disabled(model.selected == nil || model.isExporting)
                Button("한국어 제목 추가") { model.addTitle() }.disabled(model.isExporting)
                Divider()
                Button("영상 출력…") { model.exportVideo() }.keyboardShortcut("e").disabled(model.plan == nil || model.isExporting)
            }
        }
    }
}

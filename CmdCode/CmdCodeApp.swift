import AppKit
import CmdCodeCore
import SwiftData
import SwiftUI

@main
struct CmdCodeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let container: ModelContainer
    @State private var model: AppModel
    #if DEBUG
    private var snapshotSeed: Snapshot.Seed?
    #endif

    init() {
        let container: ModelContainer
        do {
            #if DEBUG
            let inMemory = Snapshot.outputDirectory != nil
            #else
            let inMemory = false
            #endif
            container = try Persistence.makeContainer(inMemory: inMemory)
        } catch {
            fatalError("无法打开数据库 \(Persistence.defaultStoreURL.path)：\(error)")
        }
        self.container = container
        let library = Library(context: container.mainContext)
        _model = State(initialValue: AppModel(library: library))
        #if DEBUG
        if Snapshot.outputDirectory != nil {
            snapshotSeed = try? Snapshot.seed(library)
        }
        #endif
    }

    var body: some Scene {
        // 单窗口；关闭即退出（见 AppDelegate）。
        Window("CmdCode", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.model = model }
                #if DEBUG
                .task {
                    if let dir = Snapshot.outputDirectory, let seed = snapshotSeed {
                        await Snapshot.run(model: model, seed: seed, directory: dir)
                    }
                }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建服务器") { model.sheet = .newServer(group: nil) }
                    .keyboardShortcut("n")
                Button("搜索") { model.openSearch() }
                    .keyboardShortcut("k")
            }
            CommandGroup(before: .windowArrangement) {
                Button("上一个标签") { model.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("下一个标签") { model.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// 没有菜单栏图标、不常驻后台：关闭主窗口即退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 还有命令在运行、或有文件没保存时先确认；退出会结束命令（相当于关闭终端窗口）、丢弃未保存的修改。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let running = model.runningSessionCount
        let unsaved = model.unsavedFileNames
        let transfers = model.activeTransferNames
        guard running > 0 || !unsaved.isEmpty || !transfers.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        var details: [String] = []
        if running > 0 {
            alert.messageText = "还有 \(running) 个命令正在运行"
            details.append("退出后这些命令会被结束，远端的前台进程也会随之停止。")
        }
        if !unsaved.isEmpty {
            if running == 0 { alert.messageText = "还有 \(unsaved.count) 个文件没有保存" }
            details.append("以下文件的修改会丢失：\n" + unsaved.joined(separator: "\n"))
        }
        if !transfers.isEmpty {
            if running == 0 && unsaved.isEmpty { alert.messageText = "还有 \(transfers.count) 个文件正在传输" }
            details.append("以下传输会被取消：\n" + transfers.joined(separator: "\n"))
        }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            model.hangUpAll()
            return .terminateNow
        }
        // 关窗口触发的退出被取消时，把窗口重新打开；会话都还在。
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            model.reopenWindow?()
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.hangUpAll()
    }
}

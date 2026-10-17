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
                Button("搜索") { model.isSearching = true }
                    .keyboardShortcut("k")
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

    /// 还有命令在运行时先确认；退出会结束它们（相当于关闭终端窗口）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.runningSessionCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有 \(model.runningSessionCount) 个命令正在运行"
        alert.informativeText = "退出后这些命令会被结束，远端的前台进程也会随之停止。"
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

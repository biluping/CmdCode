import AppKit
import CmdCodeCore
import SwiftData
import SwiftUI

@main
struct CmdCodeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
        } catch {
            fatalError("无法打开数据库 \(Persistence.defaultStoreURL.path)：\(error)")
        }
        self.container = container
        _model = State(initialValue: AppModel(library: Library(context: container.mainContext)))
    }

    var body: some Scene {
        // 单窗口；关闭即退出（见 AppDelegate）。
        Window("CmdCode", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 没有菜单栏图标、不常驻后台：关闭主窗口即退出。已经打开的终端窗口不受影响。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

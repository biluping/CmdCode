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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 没有菜单栏图标、不常驻后台：关闭主窗口即退出。已经打开的终端窗口不受影响。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

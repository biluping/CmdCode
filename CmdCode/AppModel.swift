import CmdCodeCore
import Foundation
import Observation
import SwiftData

enum SidebarSelection: Hashable {
    case credentials
    case server(PersistentIdentifier)
}

/// 弹出的编辑表单。
enum SheetRoute: Identifiable {
    case newServer(group: ServerGroup?)
    case editServer(Server)
    case newCommand(Server)
    case editCommand(ServerCommand)
    case newGroup
    case renameGroup(ServerGroup)

    var id: String {
        switch self {
        case .newServer(let g): "newServer-\(String(describing: g?.persistentModelID))"
        case .editServer(let s): "editServer-\(s.persistentModelID)"
        case .newCommand(let s): "newCommand-\(s.persistentModelID)"
        case .editCommand(let c): "editCommand-\(c.persistentModelID)"
        case .newGroup: "newGroup"
        case .renameGroup(let g): "renameGroup-\(g.persistentModelID)"
        }
    }
}

/// 需要用户确认的删除操作。
enum PendingDeletion {
    case group(ServerGroup)
    case server(Server, commandNames: [String])
    case command(ServerCommand)
}

/// 界面状态与动作。所有数据修改都走 `Library`，执行走 `CommandRunner`。
@MainActor
@Observable
final class AppModel {
    let library: Library
    let runner: CommandRunner

    var selection: SidebarSelection?
    var sheet: SheetRoute?
    var pendingDeletion: PendingDeletion?
    /// 等待确认的执行。
    var pendingExecution: ExecutionPlan?
    var errorMessage: String?
    var sshpassMissing: Bool

    init(library: Library, runner: CommandRunner = CommandRunner()) {
        self.library = library
        self.runner = runner
        // 启动时清理遗留的临时脚本（比如上次终端没能成功打开时），并检测 sshpass。
        runner.store.cleanUpLeftovers()
        sshpassMissing = runner.locator.locate() == nil
    }

    // MARK: 执行

    func run(_ command: ServerCommand) {
        perform { try prepare(command.executionPlan()) }
    }

    func testConnection(_ server: Server) {
        perform { try prepare(server.testConnectionPlan()) }
    }

    private func prepare(_ plan: ExecutionPlan) {
        if plan.requiresConfirmation {
            pendingExecution = plan
        } else {
            execute(plan)
        }
    }

    func execute(_ plan: ExecutionPlan) {
        pendingExecution = nil
        Task {
            do {
                try await runner.run(plan)
            } catch {
                show(error)
            }
        }
    }

    // MARK: 删除

    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        perform {
            switch pending {
            case .group(let g):
                try library.deleteGroup(g)
            case .server(let s, _):
                if selection == .server(s.persistentModelID) { selection = nil }
                try library.deleteServer(s)
            case .command(let c):
                try library.deleteCommand(c)
            }
        }
    }

    func requestDelete(_ s: Server) {
        pendingDeletion = .server(s, commandNames: library.commandsDeleted(with: s).map(\.name))
    }

    // MARK: 其他

    func duplicate(_ s: Server) {
        perform {
            let copy = try library.duplicateServer(s)
            selection = .server(copy.persistentModelID)
        }
    }

    func duplicate(_ c: ServerCommand) {
        perform { try library.duplicateCommand(c) }
    }

    func move(_ s: Server, to g: ServerGroup?) {
        perform { try library.moveServer(s, to: g) }
    }

    /// 执行一个可能出错的动作，出错时弹出提示。
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { show(error) }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

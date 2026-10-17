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
    case newCredential
    case editCredential(Credential)

    var id: String {
        switch self {
        case .newServer(let g): "newServer-\(String(describing: g?.persistentModelID))"
        case .editServer(let s): "editServer-\(s.persistentModelID)"
        case .newCommand(let s): "newCommand-\(s.persistentModelID)"
        case .editCommand(let c): "editCommand-\(c.persistentModelID)"
        case .newGroup: "newGroup"
        case .renameGroup(let g): "renameGroup-\(g.persistentModelID)"
        case .newCredential: "newCredential"
        case .editCredential(let c): "editCredential-\(c.persistentModelID)"
        }
    }
}

/// 需要用户确认的删除操作。
enum PendingDeletion {
    case group(ServerGroup)
    case server(Server, commandNames: [String])
    case command(ServerCommand)
    case credential(Credential)
}

/// 普通提示框。
struct AppAlert {
    var title: String
    var message: String
}

/// 界面状态与动作。所有数据修改都走 `Library`，执行走 `CommandRunner`。
@MainActor
@Observable
final class AppModel {
    let library: Library
    let runner: CommandRunner

    var selection: SidebarSelection?
    var sheet: SheetRoute?
    /// ⌘K 搜索浮层是否显示。
    var isSearching = false
    var searchQuery = ""
    var pendingDeletion: PendingDeletion?
    /// 等待确认的执行。
    var pendingExecution: ExecutionPlan?
    var alert: AppAlert?
    /// 底部的短暂提示，比如“已在终端中打开”。
    var toast: String?
    /// 左侧栏的展开状态。不持久化，每次启动全部折叠。
    var expandedSections: Set<SidebarSection.ID> = []
    var expandedServers: Set<PersistentIdentifier> = []
    var sshpassMissing: Bool
    let clipboard: SecretClipboard

    init(library: Library, runner: CommandRunner = CommandRunner(), clipboard: SecretClipboard = SecretClipboard()) {
        self.library = library
        self.runner = runner
        self.clipboard = clipboard
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
                showToast("已在终端中打开 · \(plan.title)")
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
            case .credential(let c):
                try library.deleteCredential(c)
            }
        }
    }

    func requestDelete(_ s: Server) {
        pendingDeletion = .server(s, commandNames: library.commandsDeleted(with: s).map(\.name))
    }

    /// 还有服务器在用的凭据直接提示，不进入删除确认。
    func requestDelete(_ c: Credential) {
        let users = library.servers(using: c)
        if users.isEmpty {
            pendingDeletion = .credential(c)
        } else {
            alert = AppAlert(title: "无法删除凭据“\(c.name)”",
                             message: LibraryError.credentialInUse(serverNames: users.map(\.name)).errorDescription ?? "")
        }
    }

    // MARK: 其他

    func copyPassword(_ c: Credential) {
        clipboard.copy(c.password)
    }

    /// 选中服务器，并在左侧栏展开到它所在的位置。
    func showServer(_ s: Server) {
        selection = .server(s.persistentModelID)
        expandedSections.insert(s.group.map { .group($0.persistentModelID) } ?? .ungrouped)
        expandedServers.insert(s.persistentModelID)
    }

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }

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
        alert = AppAlert(title: "出错了",
                         message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}

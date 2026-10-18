import CmdCodeCore
import Foundation
import Observation
import SwiftData

enum SidebarSelection: Hashable {
    case credentials
    /// 右侧显示内嵌终端。
    case terminal
    case server(PersistentIdentifier)
    /// 服务器的远程文件浏览。
    case files(PersistentIdentifier)
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

/// 左侧栏里正在拖动的内容。
enum DragItem {
    case group(ServerGroup)
    case server(Server)
    case command(ServerCommand)
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
    /// 确认后要替换掉的会话（“重新运行”时）。
    @ObservationIgnored private var pendingReplacement: TerminalSession.ID?
    /// 内嵌终端的会话，按打开顺序。
    var sessions: [TerminalSession] = []
    var activeSessionID: TerminalSession.ID?
    /// 主窗口被关闭后重新打开它（由界面注入）。
    @ObservationIgnored var reopenWindow: (() -> Void)?
    /// 远程文件浏览的状态，按服务器保存。
    var fileBrowsers: [PersistentIdentifier: FileBrowserModel] = [:]
    /// 生成远程文件客户端（截图自检时换成本地假的 sshpass）。
    @ObservationIgnored var makeFileClient: (SSHTarget) throws -> RemoteFileClient = { try RemoteFileClient(target: $0) }
    var alert: AppAlert?
    /// 底部的短暂提示，比如“已复制密码”。
    var toast: String?
    /// 左侧栏的展开状态。不持久化，每次启动全部折叠。
    var expandedSections: Set<SidebarSection.ID> = []
    var expandedServers: Set<PersistentIdentifier> = []
    /// 正在原地重命名的分组。
    var renamingGroup: PersistentIdentifier?
    /// 正在拖动的内容（拖动只在左侧栏内部进行，不需要真正序列化）。
    @ObservationIgnored var dragging: DragItem?
    var sshpassMissing: Bool
    let clipboard: SecretClipboard

    init(library: Library, runner: CommandRunner = CommandRunner(), clipboard: SecretClipboard = SecretClipboard()) {
        self.library = library
        self.runner = runner
        self.clipboard = clipboard
        sshpassMissing = runner.locator.locate() == nil
    }

    // MARK: 执行

    func run(_ command: ServerCommand) {
        perform { try prepare(command.executionPlan()) }
    }

    func testConnection(_ server: Server) {
        perform { try prepare(server.testConnectionPlan()) }
    }

    /// 登录服务器：在内嵌终端里打开一个交互 shell。
    func login(_ server: Server) {
        perform { try prepare(server.loginPlan()) }
    }

    private func prepare(_ plan: ExecutionPlan, replacing: TerminalSession.ID? = nil) {
        if plan.requiresConfirmation {
            pendingReplacement = replacing
            pendingExecution = plan
        } else {
            execute(plan, replacing: replacing)
        }
    }

    /// 确认框点了“执行”。
    func confirmExecution(_ plan: ExecutionPlan) {
        let replacing = pendingReplacement
        pendingReplacement = nil
        execute(plan, replacing: replacing)
    }

    /// 在内嵌终端里新开一个标签执行；`replacing` 指定时原位替换那个标签（重新运行）。
    private func execute(_ plan: ExecutionPlan, replacing: TerminalSession.ID? = nil) {
        pendingExecution = nil
        perform {
            let session = TerminalSession(plan: plan, invocation: try runner.invocation(for: plan))
            open(session, replacing: replacing)
        }
    }

    func open(_ session: TerminalSession, replacing: TerminalSession.ID? = nil) {
        if let replacing, let index = sessions.firstIndex(where: { $0.id == replacing }) {
            sessions[index].hangUp()
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        activeSessionID = session.id
        selection = .terminal
        session.start()
    }

    // MARK: 远程文件

    /// 打开服务器的文件浏览页；已经打开过的保留原来的目录。
    func openFiles(_ server: Server) {
        perform {
            let client = try makeFileClient(server.sshTarget())
            let id = server.persistentModelID
            if let browser = fileBrowsers[id] {
                browser.client = client
            } else {
                fileBrowsers[id] = FileBrowserModel(
                    client: client, serverName: server.name,
                    initialDirectory: ScriptBuilder.normalizedWorkingDirectory(server.workingDirectory))
            }
            selection = .files(id)
        }
    }

    // MARK: 终端会话

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID } ?? sessions.last
    }

    var runningSessionCount: Int {
        sessions.filter(\.state.isRunning).count
    }

    /// 重新运行：生产环境照常先确认，确认后在原标签里重新开始。
    func rerun(_ session: TerminalSession) {
        guard let plan = session.plan else { return }
        prepare(plan, replacing: session.id)
    }

    func close(_ session: TerminalSession) {
        session.hangUp()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if activeSessionID == session.id {
            activeSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
        if sessions.isEmpty, selection == .terminal { selection = nil }
    }

    /// 关闭所有已结束的标签。
    func closeFinished() {
        for s in sessions where !s.state.isRunning { close(s) }
    }

    /// 退出应用前结束所有会话。
    func hangUpAll() {
        sessions.forEach { $0.hangUp() }
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
                if selection == .server(s.persistentModelID) || selection == .files(s.persistentModelID) { selection = nil }
                fileBrowsers[s.persistentModelID] = nil
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

    // MARK: 拖动排序

    /// 放到分组标题上：分组插到它前面（“未分组”即最后）；服务器放进这个分组的最后。
    func drop(_ item: DragItem, onSection target: ServerGroup?, spot: DropSpot) {
        perform {
            switch item {
            case .group(let g):
                let groups = library.groups()
                let index = target.flatMap { t in groups.firstIndex { $0 === t } } ?? groups.count
                try library.moveGroup(g, to: index)
            case .server(let s):
                try library.moveServer(s, to: target)
                expandedSections.insert(target.map { .group($0.persistentModelID) } ?? .ungrouped)
            case .command:
                break
            }
        }
    }

    /// 服务器放到另一台服务器的上方/下方，可以跨分组。
    func drop(_ item: DragItem, onServer target: Server, spot: DropSpot) {
        guard case .server(let s) = item else { return }
        perform {
            let siblings = library.servers(in: target.group)
            guard let index = siblings.firstIndex(where: { $0 === target }) else { return }
            try library.moveServer(s, to: target.group, at: spot == .below ? index + 1 : index)
        }
    }

    /// 命令放到同一台服务器里另一条命令的上方/下方。
    func drop(_ item: DragItem, onCommand target: ServerCommand, spot: DropSpot) {
        guard case .command(let c) = item, let server = target.server else { return }
        perform {
            guard let index = server.sortedCommands.firstIndex(where: { $0 === target }) else { return }
            try library.moveCommand(c, to: spot == .below ? index + 1 : index)
        }
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

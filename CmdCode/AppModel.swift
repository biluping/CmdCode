import CmdCodeCore
import Foundation
import Observation
import SwiftData

enum SidebarSelection: Hashable {
    case credentials
    /// 右侧显示标签页（终端和远程文件）。
    case tabs
    case server(PersistentIdentifier)
}

/// 右侧的一个标签：一次命令执行的终端，或一台服务器的远程文件。
enum WorkspaceTab: Identifiable {
    case terminal(TerminalSession)
    case files(FileBrowserModel)

    var id: UUID {
        switch self {
        case .terminal(let s): s.id
        case .files(let b): b.id
        }
    }

    var session: TerminalSession? {
        if case .terminal(let s) = self { s } else { nil }
    }

    var browser: FileBrowserModel? {
        if case .files(let b) = self { b } else { nil }
    }
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
    /// 右侧的标签，按打开顺序。
    var tabs: [WorkspaceTab] = []
    var activeTabID: UUID?
    /// 等待确认关闭的标签：关闭单个、关闭其他、关闭已结束的终端都先确认。
    var pendingTabClose: [WorkspaceTab]?
    /// 主窗口被关闭后重新打开它（由界面注入）。
    @ObservationIgnored var reopenWindow: (() -> Void)?
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
    /// 每次拖动放置后加一，左侧栏可拖动的行用它当 id 重建（见 `treeDraggable`）。
    var dropGeneration = 0
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
        if let replacing, let index = tabs.firstIndex(where: { $0.id == replacing }) {
            tabs[index].session?.hangUp()
            tabs[index] = .terminal(session)
        } else {
            tabs.append(.terminal(session))
        }
        activeTabID = session.id
        selection = .tabs
        session.start()
    }

    // MARK: 远程文件

    var fileBrowsers: [FileBrowserModel] { tabs.compactMap(\.browser) }

    func fileBrowser(for server: Server) -> FileBrowserModel? {
        fileBrowsers.first { $0.serverID == server.persistentModelID }
    }

    /// 打开服务器的文件标签；每台服务器一个，已经打开的切过去，目录和编辑内容都保留。
    func openFiles(_ server: Server) {
        perform {
            let client = try makeFileClient(server.sshTarget())
            if let browser = fileBrowser(for: server) {
                browser.client = client
                browser.isProduction = server.isProduction
                activeTabID = browser.id
            } else {
                let browser = FileBrowserModel(
                    client: client, serverID: server.persistentModelID, serverName: server.name,
                    isProduction: server.isProduction,
                    initialDirectory: ScriptBuilder.normalizedWorkingDirectory(server.workingDirectory))
                browser.notify = { [weak self] in self?.showToast($0) }
                tabs.append(.files(browser))
                activeTabID = browser.id
            }
            selection = .tabs
        }
    }

    /// 有未保存修改的文件，退出前提醒。
    var unsavedFileNames: [String] {
        fileBrowsers.filter(\.isDirty).compactMap { b in
            b.openedPath.map { "\(b.serverName)：\($0)" }
        }
    }

    /// 正在上传下载的文件，退出前提醒。
    var activeTransferNames: [String] {
        fileBrowsers.compactMap { b in b.transfer.map { "\(b.serverName)：\($0.name)" } }
    }

    // MARK: 标签

    var sessions: [TerminalSession] { tabs.compactMap(\.session) }

    var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID } ?? tabs.last
    }

    /// 关闭标签：先确认。
    func close(_ tab: WorkspaceTab) {
        requestClose([tab])
    }

    /// 关闭其他标签：先确认。
    func closeOthers(than tab: WorkspaceTab) {
        requestClose(tabs.filter { $0.id != tab.id })
    }

    /// 关闭所有已结束的终端：先确认。
    func closeFinished() {
        requestClose(sessions.filter { !$0.state.isRunning }.map { .terminal($0) })
    }

    private func requestClose(_ list: [WorkspaceTab]) {
        guard !list.isEmpty else { return }
        pendingTabClose = list
    }

    /// 确认关闭：终端结束远端进程，文件取消传输、放弃未保存的修改。
    func confirmTabClose() {
        guard let list = pendingTabClose else { return }
        pendingTabClose = nil
        for tab in list {
            switch tab {
            case .terminal(let s): s.hangUp()
            case .files(let b): b.cancelTransfer()
            }
            removeTab(tab.id)
        }
    }

    /// 切换到相邻的标签（⌘⇧[ / ⌘⇧]）。
    func selectAdjacentTab(_ offset: Int) {
        guard !tabs.isEmpty, let current = activeTab,
              let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
        selection = .tabs
    }

    private func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let b = tabs[index].browser {
            // 文件标签关了就不再需要这台服务器的复用连接。
            let client = b.client
            Task.detached { client.closeSharedConnection() }
        }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if tabs.isEmpty, selection == .tabs { selection = nil }
    }

    var runningSessionCount: Int {
        sessions.filter(\.state.isRunning).count
    }

    /// 重新运行：生产环境照常先确认，确认后在原标签里重新开始。
    func rerun(_ session: TerminalSession) {
        guard let plan = session.plan else { return }
        prepare(plan, replacing: session.id)
    }


    /// 退出应用前结束所有会话和传输。
    func hangUpAll() {
        sessions.forEach { $0.hangUp() }
        fileBrowsers.forEach { $0.cancelTransfer() }
        RemoteFileClient.closeAllSharedConnections()
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
                if let b = fileBrowser(for: s) {
                    b.cancelTransfer()
                    removeTab(b.id)
                }
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

    /// 放到分组标题上：分组插到它前面或后面（“未分组”即最后）；服务器放进这个分组的最后。
    func drop(_ item: DragItem, onSection target: ServerGroup?, spot: DropSpot) {
        perform {
            switch item {
            case .group(let g):
                let groups = library.groups()
                guard let index = target.flatMap({ t in groups.firstIndex { $0 === t } }) else {
                    try library.moveGroup(g, to: groups.count)   // 拖到“未分组”上：排到最后
                    return
                }
                try library.moveGroup(g, to: spot == .below ? index + 1 : index)
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

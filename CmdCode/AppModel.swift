import CmdCodeCore
import Foundation
import Observation
import SwiftUI
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

/// 新开的终端或文件标签放在哪里。
enum TabPlacement {
    case append
    /// 原位替换（重新运行、重连）。
    case replace(UUID)
    /// 放在这个标签后面（复制标签）。
    case after(UUID)
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
    /// 每次按 ⌘K 加一，浮层据此把焦点放回输入框（浮层已打开时也生效）。
    private(set) var searchFocusRequest = 0
    var pendingDeletion: PendingDeletion?
    /// 等待确认的执行。
    var pendingExecution: ExecutionPlan?
    /// 确认后新标签放在哪里（“重新运行”替换原标签，“复制标签”放在原标签后面）。
    @ObservationIgnored private var pendingPlacement: TabPlacement = .append
    /// 等待确认的执行属于哪台服务器（终端右键“浏览文件”用）。
    @ObservationIgnored private var pendingServerID: PersistentIdentifier?
    /// 右侧的标签，按打开顺序。
    var tabs: [WorkspaceTab] = []
    var activeTabID: UUID?
    /// 等待确认关闭的标签：关闭单个、关闭其他、关闭全部、关闭已结束的终端都先确认。
    var pendingTabClose: [WorkspaceTab]?
    /// 主窗口被关闭后重新打开它（由界面注入）。
    @ObservationIgnored var reopenWindow: (() -> Void)?
    /// 生成远程文件客户端（截图自检时换成本地假的 ssh）。
    @ObservationIgnored var makeFileClient: (SSHTarget) throws -> RemoteFileClient = { RemoteFileClient(target: $0) }
    var alert: AppAlert?
    /// 底部的短暂提示，比如“已复制密码”。
    var toast: String?
    /// 左侧栏是否显示（⌃⌘S 或顶部的侧栏按钮切换）。不持久化，每次启动都显示。
    var isSidebarVisible = true
    /// 主窗口是否置顶。不持久化，每次启动恢复为普通窗口。
    var isWindowPinned = false
    /// 左侧栏的展开状态。不持久化，每次启动全部折叠。
    var expandedSections: Set<SidebarSection.ID> = []
    var expandedServers: Set<PersistentIdentifier> = []
    /// 左侧栏搜索框里的关键词；不为空时只显示匹配的服务器和命令，并全部展开。
    var sidebarFilter = ""
    /// ⌘K 打开过的服务器：左侧栏展开到它并高亮（右侧显示标签页时）。
    var locatedServer: PersistentIdentifier?
    /// 每次定位加一，左侧栏据此滚动到 `locatedServer`。
    private(set) var locateRequest = 0
    /// 正在原地重命名的分组。
    var renamingGroup: PersistentIdentifier?
    /// 正在拖动的内容（拖动只在左侧栏内部进行，不需要真正序列化）。
    @ObservationIgnored var dragging: DragItem?
    /// 每次拖动放置后加一，左侧栏可拖动的行用它当 id 重建（见 `treeDraggable`）。
    var dropGeneration = 0
    let clipboard: SecretClipboard

    init(library: Library, runner: CommandRunner = CommandRunner(), clipboard: SecretClipboard = SecretClipboard()) {
        self.library = library
        self.runner = runner
        self.clipboard = clipboard
    }

    // MARK: 执行

    func run(_ command: ServerCommand) {
        perform { try prepare(command.executionPlan(), serverID: command.server?.persistentModelID) }
    }

    /// 登录服务器：在内嵌终端里打开一个交互 shell。给了 `directory` 时登录到这个目录。
    func login(_ server: Server, directory: String? = nil) {
        perform { try prepare(server.loginPlan(directory: directory), serverID: server.persistentModelID) }
    }

    /// 这台服务器还在运行的终端标签里最后打开的那个（文件标签“切到终端”用）。
    func terminal(for server: Server) -> TerminalSession? {
        sessions.last { $0.serverID == server.persistentModelID && $0.state.isRunning }
    }

    /// 文件标签的终端按钮：有运行中的终端就切过去（不往里输入任何东西），没有就新开一个登录到 `directory`。
    func openTerminal(_ server: Server, directory: String?) {
        if let session = terminal(for: server) {
            activeTabID = session.id
            selection = .tabs
        } else {
            login(server, directory: directory)
        }
    }

    private func prepare(_ plan: ExecutionPlan, serverID: PersistentIdentifier?, placement: TabPlacement = .append) {
        if plan.requiresConfirmation {
            pendingPlacement = placement
            pendingServerID = serverID
            pendingExecution = plan
        } else {
            execute(plan, serverID: serverID, placement: placement)
        }
    }

    /// 确认框点了“执行”。
    func confirmExecution(_ plan: ExecutionPlan) {
        let placement = pendingPlacement
        let serverID = pendingServerID
        pendingPlacement = .append
        pendingServerID = nil
        execute(plan, serverID: serverID, placement: placement)
    }

    /// 在内嵌终端里开一个标签执行。
    private func execute(_ plan: ExecutionPlan, serverID: PersistentIdentifier?, placement: TabPlacement = .append) {
        pendingExecution = nil
        perform {
            let session = TerminalSession(plan: plan, invocation: try runner.invocation(for: plan))
            session.serverID = serverID
            open(session, placement: placement)
        }
    }

    func open(_ session: TerminalSession, placement: TabPlacement = .append) {
        if case .replace(let id) = placement, let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].session?.hangUp()
            tabs[index] = .terminal(session)
        } else {
            insert(.terminal(session), placement: placement)
        }
        activeTabID = session.id
        selection = .tabs
        session.start()
    }

    /// 新标签放到末尾，或者放在 `.after` 指定的标签后面（找不到时放末尾）。
    private func insert(_ tab: WorkspaceTab, placement: TabPlacement) {
        if case .after(let id) = placement, let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    // MARK: 远程文件

    var fileBrowsers: [FileBrowserModel] { tabs.compactMap(\.browser) }

    func fileBrowser(for server: Server) -> FileBrowserModel? {
        fileBrowsers.first { $0.serverID == server.persistentModelID }
    }

    /// 打开服务器的文件标签；已经打开的切过去（“复制标签”复制出来的有多个时切到第一个），目录和编辑内容都保留。
    /// 给了 `directory`（终端右键“浏览文件”）时跳到这个目录，打开中的文件不受影响。
    func openFiles(_ server: Server, directory: String? = nil) {
        perform {
            let client = try makeFileClient(server.sshTarget())
            if let browser = fileBrowser(for: server) {
                browser.client = client
                browser.isProduction = server.isProduction
                if let directory { browser.go(to: directory) }
                activeTabID = browser.id
            } else {
                addFileBrowser(client: client, serverID: server.persistentModelID, serverName: server.name,
                               isProduction: server.isProduction,
                               directory: directory ?? ScriptBuilder.normalizedWorkingDirectory(server.workingDirectory))
            }
            selection = .tabs
        }
    }

    private func addFileBrowser(client: RemoteFileClient, serverID: PersistentIdentifier, serverName: String,
                                isProduction: Bool, directory: String?, placement: TabPlacement = .append) {
        let browser = FileBrowserModel(client: client, serverID: serverID, serverName: serverName,
                                       isProduction: isProduction, initialDirectory: directory)
        browser.notify = { [weak self] in self?.showToast($0) }
        browser.remoteChanged = { [weak self] id, dir in self?.refreshFileBrowsers(serverID: id, directory: dir) }
        insert(.files(browser), placement: placement)
        activeTabID = browser.id
    }

    /// 别的标签往这台服务器的 `directory` 里写了文件（服务器间发送）：正显示这个目录的文件标签刷新列表。
    private func refreshFileBrowsers(serverID: PersistentIdentifier, directory: String) {
        for b in fileBrowsers where b.serverID == serverID && b.listing?.path == directory && !b.isListing {
            b.go(to: directory)
        }
    }

    /// 服务器间发送文件的目标：所有服务器；目录默认取它已打开的文件标签当前所在的目录，否则是工作目录（空表示家目录）。
    func sendTargets() -> [FileSendTarget] {
        library.allServers().compactMap { s in
            guard let client = try? makeFileClient(s.sshTarget()) else { return nil }
            let dir = fileBrowser(for: s)?.listing?.path ?? ScriptBuilder.normalizedWorkingDirectory(s.workingDirectory)
            return FileSendTarget(serverID: s.persistentModelID, serverName: s.name, isProduction: s.isProduction,
                                  client: client, directory: dir ?? "")
        }
    }

    // MARK: 复制标签

    /// 标签右键“复制标签”：在原标签后面再开一个同样的。
    /// 登录终端从远端 shell 最后所在的目录重新登录；命令终端再执行一次（照常先确认）；文件标签打开同一个目录。
    func duplicate(_ tab: WorkspaceTab) {
        switch tab {
        case .terminal(let session):
            guard var plan = session.plan else { return }
            if session.isLogin, let dir = ScriptBuilder.normalizedWorkingDirectory(session.currentDirectory) {
                plan.workingDirectory = dir
            }
            prepare(plan, serverID: session.serverID, placement: .after(session.id))
        case .files(let b):
            addFileBrowser(client: b.client, serverID: b.serverID, serverName: b.serverName,
                           isProduction: b.isProduction, directory: b.listing?.path ?? b.initialDirectory,
                           placement: .after(b.id))
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

    /// ⌘W：右侧显示标签页时关闭当前标签（先确认），⌘K 浮层打开时关闭浮层，其他情况不做事——不关窗口。
    func closeActiveTab() {
        if isSearching {
            isSearching = false
            searchQuery = ""
        } else if selection == .tabs, let tab = activeTab {
            close(tab)
        }
    }

    /// 关闭全部标签：先确认。
    func closeAll() {
        requestClose(tabs)
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

    /// 拖动标签调整顺序：把 `from` 位置的标签挪到 `to`。
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        tabs.insert(tabs.remove(at: from), at: to)
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
        let closed = tabs.remove(at: index)
        if let b = closed.browser, !fileBrowsers.contains(where: { $0.serverID == b.serverID }) {
            // 这台服务器的文件标签都关了，就不再需要它的复用连接。
            let client = b.client
            Task.detached { client.closeSharedConnection() }
        }
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
        prepare(plan, serverID: session.serverID, placement: .replace(session.id))
    }

    /// 等待确认的重连（还连着时重连会断开当前连接）。
    var pendingReconnect: TerminalSession?

    /// 登录终端的重连：在原标签里重新登录，回到远端 shell 最后所在的目录。还连着时先确认。
    func reconnect(_ session: TerminalSession) {
        guard session.isLogin else { return }
        if session.state.isRunning { pendingReconnect = session } else { confirmReconnect(session) }
    }

    func confirmReconnect(_ session: TerminalSession) {
        pendingReconnect = nil
        guard var plan = session.plan, tabs.contains(where: { $0.id == session.id }) else { return }
        if let dir = ScriptBuilder.normalizedWorkingDirectory(session.currentDirectory) { plan.workingDirectory = dir }
        prepare(plan, serverID: session.serverID, placement: .replace(session.id))
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
                for b in fileBrowsers where b.serverID == s.persistentModelID {
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

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.2)) { isSidebarVisible.toggle() }
    }

    /// 打开 ⌘K 搜索浮层并聚焦输入框。
    func openSearch() {
        isSearching = true
        searchFocusRequest += 1
    }

    /// 选中服务器，并在左侧栏展开到它所在的位置。
    func showServer(_ s: Server) {
        selection = .server(s.persistentModelID)
        expandedSections.insert(s.group.map { .group($0.persistentModelID) } ?? .ungrouped)
        expandedServers.insert(s.persistentModelID)
    }

    /// ⌘K 登录服务器或执行命令后，左侧栏展开到这台服务器、滚动过去并高亮。
    /// 搜索框里的关键词会让它被过滤掉时，清空关键词。
    func locate(_ s: Server) {
        let matcher = SearchMatcher(sidebarFilter)
        if !matcher.isEmpty, !matcher.matches(server: s), !s.commands.contains(where: { matcher.matches(command: $0) }) {
            sidebarFilter = ""
        }
        expandedSections.insert(s.group.map { .group($0.persistentModelID) } ?? .ungrouped)
        expandedServers.insert(s.persistentModelID)
        locatedServer = s.persistentModelID
        locateRequest += 1
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

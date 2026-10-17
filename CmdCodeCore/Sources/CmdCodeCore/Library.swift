import Foundation
import SwiftData

public enum LibraryError: Error, Equatable, LocalizedError {
    case emptyField(String)
    case invalidPort
    case missingCredential
    /// 凭据仍被这些服务器使用，不能删除。
    case credentialInUse(serverNames: [String])
    case serverHasNoCredential(serverName: String)

    public var errorDescription: String? {
        switch self {
        case .emptyField(let field): "\(field)不能为空"
        case .invalidPort: "端口必须在 1–65535 之间"
        case .missingCredential: "请选择登录凭据"
        case .credentialInUse(let names): "请先修改以下服务器的凭据：\n" + names.joined(separator: "\n")
        case .serverHasNoCredential(let name): "服务器“\(name)”没有配置登录凭据"
        }
    }
}

/// 左侧栏的一个分组。`group == nil` 表示“未分组”。
public struct SidebarSection: Identifiable {
    public enum ID: Hashable {
        case group(PersistentIdentifier)
        case ungrouped
    }

    public var group: ServerGroup?
    public var servers: [Server]

    public var id: ID { group.map { .group($0.persistentModelID) } ?? .ungrouped }
    public var title: String { group?.name ?? Library.ungroupedTitle }
    public var serverCount: Int { servers.count }

    /// 由已排好序的分组和服务器组装左侧栏：分组按给定顺序，“未分组”固定在最后。
    /// 界面用 `@Query` 拿到数据后调用它，保持自动刷新。
    public static func make(groups: [ServerGroup], servers: [Server]) -> [SidebarSection] {
        var byGroup: [PersistentIdentifier: [Server]] = [:]
        var ungrouped: [Server] = []
        for s in servers {
            if let g = s.group { byGroup[g.persistentModelID, default: []].append(s) } else { ungrouped.append(s) }
        }
        return groups.map { SidebarSection(group: $0, servers: byGroup[$0.persistentModelID] ?? []) }
            + [SidebarSection(group: nil, servers: ungrouped)]
    }
}

public struct SearchResults {
    public var servers: [Server] = []
    public var commands: [ServerCommand] = []

    public var isEmpty: Bool { servers.isEmpty && commands.isEmpty }
}

/// 所有数据操作的入口：增删改、删除规则、左侧栏数据、搜索。每次修改后立即保存。
@MainActor
public struct Library {
    nonisolated public static let ungroupedTitle = "未分组"
    nonisolated public static let copySuffix = " 副本"

    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    private func save() throws {
        try context.save()
    }

    private func fetchSorted<T: PersistentModel>(
        _ type: T.Type, where predicate: Predicate<T>? = nil, by sort: SortDescriptor<T>
    ) -> [T] {
        let descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: [sort])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 凭据

    public func credentials() -> [Credential] {
        fetchSorted(Credential.self, by: SortDescriptor(\.createdAt))
    }

    @discardableResult
    public func createCredential(_ draft: CredentialDraft) throws -> Credential {
        try draft.validate()
        let c = Credential(name: draft.name, username: draft.username, password: draft.password, note: draft.note)
        context.insert(c)
        try save()
        return c
    }

    public func updateCredential(_ c: Credential, with draft: CredentialDraft) throws {
        try draft.validate()
        c.name = draft.name
        c.username = draft.username
        c.password = draft.password
        c.note = draft.note
        try save()
    }

    /// 使用这条凭据的服务器，按创建顺序。
    public func servers(using c: Credential) -> [Server] {
        c.servers.sorted { $0.createdAt < $1.createdAt }
    }

    /// 只要还有服务器在用就拒绝删除。
    public func deleteCredential(_ c: Credential) throws {
        let users = servers(using: c)
        guard users.isEmpty else { throw LibraryError.credentialInUse(serverNames: users.map(\.name)) }
        context.delete(c)
        try save()
    }

    // MARK: - 分组

    public func groups() -> [ServerGroup] {
        fetchSorted(ServerGroup.self, by: SortDescriptor(\.createdAt))
    }

    @discardableResult
    public func createGroup(name: String) throws -> ServerGroup {
        try requireName(name)
        let g = ServerGroup(name: name)
        context.insert(g)
        try save()
        return g
    }

    public func renameGroup(_ g: ServerGroup, to name: String) throws {
        try requireName(name)
        g.name = name
        try save()
    }

    /// 组里的服务器移到“未分组”，服务器本身不删。
    public func deleteGroup(_ g: ServerGroup) throws {
        for s in g.servers { s.group = nil }
        context.delete(g)
        try save()
    }

    private func requireName(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw LibraryError.emptyField("名称") }
    }

    // MARK: - 服务器

    public func allServers() -> [Server] {
        fetchSorted(Server.self, by: SortDescriptor(\.createdAt))
    }

    public func servers(in g: ServerGroup?) -> [Server] {
        if let g { return g.servers.sorted { $0.createdAt < $1.createdAt } }
        return fetchSorted(Server.self, where: #Predicate { $0.group == nil }, by: SortDescriptor(\.createdAt))
    }

    @discardableResult
    public func createServer(_ draft: ServerDraft) throws -> Server {
        try draft.validate()
        let s = Server(name: draft.name, host: draft.host)
        context.insert(s)
        apply(draft, to: s)
        try save()
        return s
    }

    public func updateServer(_ s: Server, with draft: ServerDraft) throws {
        try draft.validate()
        apply(draft, to: s)
        try save()
    }

    private func apply(_ d: ServerDraft, to s: Server) {
        s.name = d.name
        s.group = d.group
        s.host = d.host.trimmingCharacters(in: .whitespacesAndNewlines)
        s.port = d.port
        s.credential = d.credential
        s.workingDirectory = d.workingDirectory
        s.isProduction = d.isProduction
        s.note = d.note
    }

    public func moveServer(_ s: Server, to g: ServerGroup?) throws {
        s.group = g
        try save()
    }

    /// 复制服务器及其全部命令，名称加“ 副本”，放在同一分组。
    @discardableResult
    public func duplicateServer(_ s: Server) throws -> Server {
        var draft = ServerDraft(s)
        draft.name += Self.copySuffix
        let copy = Server(name: draft.name, host: draft.host)
        context.insert(copy)
        apply(draft, to: copy)
        for c in s.sortedCommands {
            let cc = makeCommand(CommandDraft(c))
            cc.server = copy
        }
        try save()
        return copy
    }

    /// 删除服务器时会一并删除的命令，用于确认框。
    public func commandsDeleted(with s: Server) -> [ServerCommand] {
        s.sortedCommands
    }

    /// 删除服务器，连同它的所有命令。
    public func deleteServer(_ s: Server) throws {
        for c in s.commands { context.delete(c) }
        context.delete(s)
        try save()
    }

    // MARK: - 命令

    @discardableResult
    public func createCommand(_ draft: CommandDraft, on s: Server) throws -> ServerCommand {
        try draft.validate()
        let c = makeCommand(draft)
        c.server = s
        try save()
        return c
    }

    public func updateCommand(_ c: ServerCommand, with draft: CommandDraft) throws {
        try draft.validate()
        c.name = draft.name
        c.content = draft.content
        c.workingDirectory = draft.workingDirectory
        c.confirmBeforeRun = draft.confirmBeforeRun
        try save()
    }

    @discardableResult
    public func duplicateCommand(_ c: ServerCommand) throws -> ServerCommand {
        var draft = CommandDraft(c)
        draft.name += Self.copySuffix
        let copy = makeCommand(draft)
        copy.server = c.server
        try save()
        return copy
    }

    public func deleteCommand(_ c: ServerCommand) throws {
        context.delete(c)
        try save()
    }

    private func makeCommand(_ d: CommandDraft) -> ServerCommand {
        let c = ServerCommand(name: d.name, content: d.content, workingDirectory: d.workingDirectory,
                              confirmBeforeRun: d.confirmBeforeRun)
        context.insert(c)
        return c
    }

    // MARK: - 左侧栏

    /// 分组按创建顺序，“未分组”固定在最后。
    public func sidebarSections() -> [SidebarSection] {
        SidebarSection.make(groups: groups(), servers: allServers())
    }

    // MARK: - 搜索

    /// 按服务器名、IP、命令名、命令内容模糊搜索：忽略大小写，空格分隔的每个词都要出现。
    public func search(_ query: String) -> SearchResults {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return SearchResults() }
        func matches(_ fields: String...) -> Bool {
            let haystack = fields.joined(separator: "\n").lowercased()
            return tokens.allSatisfy(haystack.contains)
        }
        var results = SearchResults()
        for s in allServers() {
            if matches(s.name, s.host) { results.servers.append(s) }
            for c in s.sortedCommands where matches(c.name, c.content) { results.commands.append(c) }
        }
        return results
    }
}

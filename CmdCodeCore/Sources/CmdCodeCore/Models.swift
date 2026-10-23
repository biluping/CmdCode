import Foundation
import SwiftData

/// 登录凭据。多台服务器可以引用同一条，改一次密码全部生效。
/// 密码按需求明文保存在本地数据库里。
@Model
public final class Credential {
    public var name: String
    public var username: String
    public var password: String
    public var note: String
    public var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Server.credential)
    public var servers: [Server] = []

    public init(name: String, username: String, password: String, note: String = "") {
        self.name = name
        self.username = username
        self.password = password
        self.note = note
        self.createdAt = CreationClock.next()
    }
}

/// 单层分组。“未分组”不是一条记录，而是 `server.group == nil`，所以天然删不掉。
@Model
public final class ServerGroup {
    public var name: String
    public var createdAt: Date
    /// 拖动排序后的位置，小的在前；相同时按创建时间。旧数据迁移后都是 0，即保持创建顺序。
    public var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Server.group)
    public var servers: [Server] = []

    public init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.createdAt = CreationClock.next()
        self.sortOrder = sortOrder
    }

    /// 侧栏和下拉框里的顺序。
    public static let displayOrder = [SortDescriptor(\ServerGroup.sortOrder), SortDescriptor(\ServerGroup.createdAt)]
}

@Model
public final class Server {
    public var name: String
    public var host: String
    public var port: Int
    /// 空字符串表示未配置。
    public var workingDirectory: String
    public var isProduction: Bool
    public var note: String
    public var createdAt: Date
    /// 在所属分组内的位置（拖动排序），相同时按创建时间。
    public var sortOrder: Int = 0
    /// 不用密码库、直接填在服务器上的用户名和密码。引用了凭据（`credential != nil`）时为空。
    public var username: String = ""
    public var password: String = ""

    /// 密码库里的凭据；为 nil 时用上面直接填的用户名和密码。
    public var credential: Credential?
    public var group: ServerGroup?

    @Relationship(deleteRule: .cascade, inverse: \ServerCommand.server)
    public var commands: [ServerCommand] = []

    public init(
        name: String,
        host: String,
        port: Int = 22,
        workingDirectory: String = "",
        isProduction: Bool = false,
        note: String = ""
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.workingDirectory = workingDirectory
        self.isProduction = isProduction
        self.note = note
        self.createdAt = CreationClock.next()
    }

    /// 按排序位置排列的命令（拖动排序），相同时按创建顺序。
    public var sortedCommands: [ServerCommand] {
        commands.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    /// 登录用的用户名：引用凭据时取凭据的，否则取直接填的；都没有返回 nil。
    public var loginUsername: String? {
        if let credential { return credential.username }
        return username.isEmpty ? nil : username
    }

    /// 同一分组内服务器的顺序。
    public static let displayOrder = [SortDescriptor(\Server.sortOrder), SortDescriptor(\Server.createdAt)]
}

/// 绑定在一台服务器上的固定命令。
@Model
public final class ServerCommand {
    public var name: String
    /// 支持多行，原样执行。
    public var content: String
    /// 空字符串表示沿用服务器的工作目录。
    public var workingDirectory: String
    public var createdAt: Date
    /// 在所属服务器内的位置（拖动排序），相同时按创建时间。
    public var sortOrder: Int = 0

    public var server: Server?

    public init(name: String, content: String, workingDirectory: String = "") {
        self.name = name
        self.content = content
        self.workingDirectory = workingDirectory
        self.createdAt = CreationClock.next()
    }

    /// 命令自己的工作目录优先，否则用服务器的；都没有返回 nil。
    public var effectiveWorkingDirectory: String? {
        ScriptBuilder.normalizedWorkingDirectory(workingDirectory)
            ?? ScriptBuilder.normalizedWorkingDirectory(server?.workingDirectory)
    }
}

/// 生成严格递增的创建时间，保证“按创建顺序排列”在同一微秒内创建多条记录时也稳定。
enum CreationClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = Date.distantPast

    static func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        last = now > last ? now : last.addingTimeInterval(0.000_001)
        return last
    }
}

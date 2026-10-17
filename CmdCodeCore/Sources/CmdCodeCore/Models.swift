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

    @Relationship(deleteRule: .nullify, inverse: \Server.group)
    public var servers: [Server] = []

    public init(name: String) {
        self.name = name
        self.createdAt = CreationClock.next()
    }
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

    /// 按创建顺序排列的命令。
    public var sortedCommands: [ServerCommand] {
        commands.sorted { $0.createdAt < $1.createdAt }
    }
}

/// 绑定在一台服务器上的固定命令。
@Model
public final class ServerCommand {
    public var name: String
    /// 支持多行，原样执行。
    public var content: String
    /// 空字符串表示沿用服务器的工作目录。
    public var workingDirectory: String
    public var confirmBeforeRun: Bool
    public var createdAt: Date

    public var server: Server?

    public init(name: String, content: String, workingDirectory: String = "", confirmBeforeRun: Bool = false) {
        self.name = name
        self.content = content
        self.workingDirectory = workingDirectory
        self.confirmBeforeRun = confirmBeforeRun
        self.createdAt = CreationClock.next()
    }

    /// 生产环境服务器上的命令强制确认。
    public var requiresConfirmation: Bool {
        confirmBeforeRun || (server?.isProduction ?? false)
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

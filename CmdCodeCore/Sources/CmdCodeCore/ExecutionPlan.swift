import Foundation

/// 从数据模型得到的“要执行什么”，交给 `CommandRunner`。不持有模型对象，可以跨线程传递。
public struct ExecutionPlan: Sendable, Equatable {
    public var target: SSHTarget
    public var command: String
    public var workingDirectory: String?
    public var requiresConfirmation: Bool
    public var serverName: String
    /// 命令名；测试连接时是“测试连接”。
    public var commandName: String
    public var isProduction: Bool
    /// 命令结束后留在远端的交互 shell 里。登录服务器时命令为空、这里为 true。
    public var stayInShell: Bool

    /// 确认框和终端标签上显示的标题，比如“232 - lims 主服务 / 构建”。
    public var title: String { "\(serverName) / \(commandName)" }

    public init(target: SSHTarget, command: String, workingDirectory: String?, requiresConfirmation: Bool,
                serverName: String, commandName: String, isProduction: Bool = false, stayInShell: Bool = false) {
        self.target = target
        self.command = command
        self.workingDirectory = workingDirectory
        self.requiresConfirmation = requiresConfirmation
        self.serverName = serverName
        self.commandName = commandName
        self.isProduction = isProduction
        self.stayInShell = stayInShell
    }
}

extension Server {
    public func sshTarget() throws -> SSHTarget {
        guard let c = credential else { throw LibraryError.serverHasNoCredential(serverName: name) }
        return SSHTarget(host: host, port: port, username: c.username, password: c.password)
    }

    /// 测试连接：`whoami && pwd`，有工作目录就先 cd。不需要确认。
    public func testConnectionPlan() throws -> ExecutionPlan {
        ExecutionPlan(
            target: try sshTarget(),
            command: ScriptBuilder.testConnectionCommand(),
            workingDirectory: ScriptBuilder.normalizedWorkingDirectory(workingDirectory),
            requiresConfirmation: false,
            serverName: name, commandName: "测试连接", isProduction: isProduction)
    }

    /// 登录服务器：有工作目录就先 cd，然后进入交互 shell。不需要确认。
    public func loginPlan() throws -> ExecutionPlan {
        ExecutionPlan(
            target: try sshTarget(),
            command: "",
            workingDirectory: ScriptBuilder.normalizedWorkingDirectory(workingDirectory),
            requiresConfirmation: false,
            serverName: name, commandName: "登录", isProduction: isProduction, stayInShell: true)
    }
}

extension ServerCommand {
    public func executionPlan() throws -> ExecutionPlan {
        guard let server else { throw LibraryError.serverHasNoCredential(serverName: "") }
        return ExecutionPlan(
            target: try server.sshTarget(),
            command: content,
            workingDirectory: effectiveWorkingDirectory,
            // 命令一律先确认，执行完留在远端 shell 里。
            requiresConfirmation: true,
            serverName: server.name, commandName: name, isProduction: server.isProduction,
            stayInShell: true)
    }
}

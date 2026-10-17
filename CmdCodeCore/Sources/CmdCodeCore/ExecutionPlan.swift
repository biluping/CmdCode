import Foundation

/// 从数据模型得到的“要执行什么”，交给 `CommandRunner`。不持有模型对象，可以跨线程传递。
public struct ExecutionPlan: Sendable, Equatable {
    public var target: SSHTarget
    public var command: String
    public var workingDirectory: String?
    public var requiresConfirmation: Bool
    /// 确认框里显示的标题，比如“232 - lims 主服务 / 构建”。
    public var title: String
}

extension Server {
    func sshTarget() throws -> SSHTarget {
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
            title: "\(name) / 测试连接")
    }
}

extension ServerCommand {
    public func executionPlan() throws -> ExecutionPlan {
        guard let server else { throw LibraryError.serverHasNoCredential(serverName: "") }
        return ExecutionPlan(
            target: try server.sshTarget(),
            command: content,
            workingDirectory: effectiveWorkingDirectory,
            requiresConfirmation: requiresConfirmation,
            title: "\(server.name) / \(name)")
    }
}

extension CommandRunner {
    @discardableResult
    public func run(_ plan: ExecutionPlan) async throws -> URL {
        try await run(target: plan.target, command: plan.command, workingDirectory: plan.workingDirectory)
    }
}

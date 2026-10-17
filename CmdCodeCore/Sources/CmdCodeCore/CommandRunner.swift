import Foundation

public enum CommandRunnerError: Error, Equatable, LocalizedError {
    case sshpassNotFound

    public var errorDescription: String? {
        switch self {
        case .sshpassNotFound: SSHPassLocator.installHint
        }
    }
}

/// 执行入口：把执行计划变成可以直接启动的 ssh 进程参数。
public struct CommandRunner: Sendable {
    public var locator: SSHPassLocator

    public init(locator: SSHPassLocator = SSHPassLocator()) {
        self.locator = locator
    }

    public func invocation(for plan: ExecutionPlan) throws -> SSHInvocation {
        guard let sshpass = locator.locate() else { throw CommandRunnerError.sshpassNotFound }
        return ScriptBuilder.sshInvocation(
            target: plan.target, sshpassPath: sshpass,
            command: plan.command, workingDirectory: plan.workingDirectory,
            stayInShell: plan.stayInShell)
    }
}

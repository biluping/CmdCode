import Foundation

/// 执行入口：把执行计划变成可以直接启动的 ssh 进程参数。
public struct CommandRunner: Sendable {
    /// askpass 脚本所在目录。
    public var askPassDirectory: String

    public init(askPassDirectory: String = AskPass.defaultDirectory) {
        self.askPassDirectory = askPassDirectory
    }

    public func invocation(for plan: ExecutionPlan) throws -> SSHInvocation {
        ScriptBuilder.sshInvocation(
            target: plan.target, askPassPath: try AskPass.prepare(in: askPassDirectory),
            command: plan.command, workingDirectory: plan.workingDirectory,
            stayInShell: plan.stayInShell)
    }
}

import Foundation

/// 一次 SSH 登录所需的信息。
public struct SSHTarget: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(host: String, port: Int = 22, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// 生成交给 Terminal.app 执行的临时脚本。全部是纯函数，不碰文件系统。
///
/// 转义策略（见需求文档 3.4「命令怎么拼」）：
/// - 命令内容和工作目录拼成内层脚本后编码为 base64，到远端再解码执行，避免多层引号嵌套。
/// - 其余值（密码、用户名、主机、端口、sshpass 路径）只经过一层 `shq()`。
public enum ScriptBuilder {

    /// 单引号转义：前后加单引号，并把 `'` 替换为 `'\''`。
    public static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 规范化工作目录：空白视为未配置。
    public static func normalizedWorkingDirectory(_ dir: String?) -> String? {
        guard let dir, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return dir
    }

    /// 内层脚本：有工作目录时第一行是 `cd -- <dir> || exit 1`，之后是原样的命令内容。
    ///
    /// 用单独一行的 `|| exit 1` 而不是 `cd … && 命令`，保证多行命令在 cd 失败时一行都不执行。
    public static func innerScript(command: String, workingDirectory: String?) -> String {
        guard let dir = normalizedWorkingDirectory(workingDirectory) else { return command }
        return "cd -- \(shq(dir)) || exit 1\n" + command
    }

    /// UTF-8 编码后的 base64，不换行。
    public static func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// 远端命令：`bash -lc "$(printf %s <base64> | base64 -d)"`。
    ///
    /// 只含固定文本和 base64 字符；不占用 stdin，所以 vim、top 等交互程序可用。
    public static func remoteCommand(command: String, workingDirectory: String?) -> String {
        let encoded = base64(innerScript(command: command, workingDirectory: workingDirectory))
        return "bash -lc \"$(printf %s \(encoded) | base64 -d)\""
    }

    /// 测试连接用的命令。
    public static func testConnectionCommand() -> String {
        "whoami && pwd"
    }

    /// 完整的本地 `.command` 脚本内容。
    public static func localScript(
        target: SSHTarget,
        sshpassPath: String,
        command: String,
        workingDirectory: String?
    ) -> String {
        let remote = remoteCommand(command: command, workingDirectory: workingDirectory)
        return """
        #!/bin/bash
        rm -f -- "$0"
        trap : INT
        export SSHPASS=\(shq(target.password))
        \(shq(sshpassPath)) -e ssh -t -p \(shq(String(target.port))) \\
          -o ConnectTimeout=10 -o ServerAliveInterval=30 \\
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \\
          \(shq(target.username))@\(shq(target.host)) \(shq(remote))
        echo
        echo "\(finishedMessage)"
        read

        """
    }

    /// 脚本结束时提示的文字。
    public static let finishedMessage = "[已结束，按回车关闭窗口]"
}

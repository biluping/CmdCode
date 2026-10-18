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

/// 生成远端执行的命令和 ssh 启动参数。全部是纯函数，不碰文件系统。
///
/// 转义策略（见需求文档 3.4「命令怎么拼」）：
/// - 命令内容和工作目录拼成内层脚本后编码为 base64，到远端再解码执行，避免多层引号嵌套。
/// - 其余值（密码、用户名、主机、端口）作为独立的参数或环境变量传给 ssh，不经过 shell。
public struct SSHInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// 需要额外设置的环境变量（目前只有 SSHPASS）。
    public var environment: [String: String]
}

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

    /// 留在 shell 时最后执行的一行：换成远端用户的登录 shell，继续交互。
    public static let loginShellLine = #"exec "${SHELL:-bash}" -l"#

    /// 内层脚本：有工作目录时第一行是 `cd -- <dir> || exit 1`，之后是原样的命令内容。
    ///
    /// 用单独一行的 `|| exit 1` 而不是 `cd … && 命令`，保证多行命令在 cd 失败时一行都不执行。
    ///
    /// `stayInShell` 为 true 时命令结束后进入登录 shell：命令放在子 bash 里执行，外层忽略 Ctrl-C，
    /// 这样不管命令正常结束、出错退出还是被 Ctrl-C 中断（比如 `tail -f`），都会留在 shell 里。
    /// 命令为空时直接进入 shell（登录服务器）。
    public static func innerScript(command: String, workingDirectory: String?, stayInShell: Bool = false) -> String {
        var lines: [String] = []
        if let dir = normalizedWorkingDirectory(workingDirectory) {
            lines.append("cd -- \(shq(dir)) || exit 1")
        }
        if !stayInShell {
            lines.append(command)
        } else {
            if !command.isEmpty {
                lines.append("trap : INT")
                lines.append("bash -lc \(shq(command))")
            }
            lines.append(loginShellLine)
        }
        return lines.joined(separator: "\n")
    }

    /// UTF-8 编码后的 base64，不换行。
    public static func base64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// 远端命令：`bash -lc "$(printf %s <base64> | base64 -d)"`。
    ///
    /// 只含固定文本和 base64 字符；不占用 stdin，所以 vim、top 等交互程序可用。
    public static func remoteCommand(command: String, workingDirectory: String?, stayInShell: Bool = false) -> String {
        remoteCommand(script: innerScript(command: command, workingDirectory: workingDirectory, stayInShell: stayInShell))
    }

    /// 任意内层脚本对应的远端命令。远程文件操作用它直接传自己生成的脚本，并且用非登录 shell（`bash -c`），
    /// 省掉加载 /etc/profile、~/.bash_profile 的时间；文件脚本只用基础命令，不依赖 profile 里的 PATH。
    public static func remoteCommand(script: String, loginShell: Bool = true) -> String {
        "bash -\(loginShell ? "l" : "")c \"$(printf %s \(base64(script)) | base64 -d)\""
    }

    /// 测试连接用的命令。
    public static func testConnectionCommand() -> String {
        "whoami && pwd"
    }

    /// 启动 ssh 所需的程序、参数和环境变量，直接交给伪终端（pty）运行，不经过 shell。
    ///
    /// - 密码只放在环境变量 `SSHPASS` 里，不出现在参数中，也不写入任何文件。
    /// - 用 `-l 用户名` 和 `--` 分隔主机，主机或用户名里的特殊字符都不会被当成选项。
    /// - `-t` 强制分配远端终端，交互程序（vim、top）和 Ctrl-C 都能正常工作。
    public static func sshInvocation(
        target: SSHTarget,
        sshpassPath: String,
        command: String,
        workingDirectory: String?,
        stayInShell: Bool = false
    ) -> SSHInvocation {
        sshInvocation(
            target: target, sshpassPath: sshpassPath,
            remoteCommand: remoteCommand(command: command, workingDirectory: workingDirectory, stayInShell: stayInShell),
            allocateTTY: true)
    }

    /// 同上，远端命令已经拼好。`allocateTTY` 为 false 时用 `-T`：不分配远端终端，
    /// stdin/stdout 是干净的字节流，远程文件读写用这种方式。
    ///
    /// `controlPath` 不为 nil 时开启连接复用（ControlMaster）：第一次照常连接认证，之后的 ssh 走这条连接，
    /// 不再握手和认证；空闲 `controlPersist` 秒后主连接自己退出。
    public static func sshInvocation(
        target: SSHTarget,
        sshpassPath: String,
        remoteCommand: String,
        allocateTTY: Bool,
        controlPath: String? = nil,
        controlPersist: Int = 300
    ) -> SSHInvocation {
        var arguments = [
            "-e", "ssh", allocateTTY ? "-t" : "-T",
            "-p", String(target.port),
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
        ]
        if let controlPath {
            arguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=\(controlPersist)",
            ]
        }
        arguments += ["-l", target.username, "--", target.host, remoteCommand]
        return SSHInvocation(executable: sshpassPath, arguments: arguments,
                             environment: ["SSHPASS": target.password])
    }
}

import Foundation

public enum AskPassError: Error, Equatable, LocalizedError {
    case cannotPrepare(String)

    public var errorDescription: String? {
        switch self {
        case .cannotPrepare(let message): "无法准备密码脚本：\(message)"
        }
    }
}

/// 用 ssh 自带的 SSH_ASKPASS 机制送密码（见需求文档 3.4「密码怎么给 ssh」）。
///
/// ssh 要密码时自己运行 askpass 脚本，读它输出的一行。脚本里没有密码，密码只在环境变量里，
/// 不进参数、不落盘。不用 sshpass：它盯着终端输出猜时机再“打字”，实测约 5% 的登录密码会被拒。
public enum AskPass {
    /// 运行目录：askpass 脚本和远程文件的连接复用 socket 都放这里。
    /// 用 /tmp 下的短路径：macOS 的 socket 路径上限是 104 字节。
    public static let defaultDirectory = "/tmp/cmdcode-\(getuid())"
    public static let scriptName = "askpass"
    /// 密码所在的环境变量。
    public static let passwordVariable = "CMDCODE_SSH_PASSWORD"

    /// ssh 运行它时第一个参数是提示文字。只回答密码提示（password / Password:）；
    /// 私钥口令等其他提示返回失败，ssh 会跳过那把私钥。
    public static let script = """
        #!/bin/sh
        case "$1" in
        *assword*) printf '%s\\n' "$\(passwordVariable)" ;;
        *) exit 1 ;;
        esac

        """

    /// 传给 ssh 的环境变量。`SSH_ASKPASS_REQUIRE=force`：有终端也一律走 askpass（OpenSSH 8.4 起支持）。
    public static func environment(scriptPath: String, password: String) -> [String: String] {
        ["SSH_ASKPASS": scriptPath, "SSH_ASKPASS_REQUIRE": "force", passwordVariable: password]
    }

    /// 确保运行目录（0700，属于当前用户）和脚本（0700，内容正确）都在，返回脚本路径。
    @discardableResult
    public static func prepare(in directory: String = defaultDirectory) throws -> String {
        try prepareDirectory(directory)
        let path = directory + "/" + scriptName
        let fm = FileManager.default
        do {
            if fm.contents(atPath: path) != Data(script.utf8) {
                try? fm.removeItem(atPath: path)
                try Data(script.utf8).write(to: URL(fileURLWithPath: path))
            }
            let attrs = try fm.attributesOfItem(atPath: path)
            if (attrs[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            }
        } catch {
            throw AskPassError.cannotPrepare("\(path)：\(error.localizedDescription)")
        }
        return path
    }

    /// 目录不存在就建；已存在的必须属于当前用户（防止别人预先建好目录换掉脚本），权限收紧到 0700。
    public static func prepareDirectory(_ directory: String) throws {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: directory) {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            let attrs = try fm.attributesOfItem(atPath: directory)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw AskPassError.cannotPrepare("\(directory) 不属于当前用户")
            }
            if (attrs[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            }
        } catch let error as AskPassError {
            throw error
        } catch {
            throw AskPassError.cannotPrepare("\(directory)：\(error.localizedDescription)")
        }
    }
}

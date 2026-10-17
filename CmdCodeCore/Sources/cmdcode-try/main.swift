import CmdCodeCore
import Foundation

let usage = """
用法：
  swift run cmdcode-try --host <主机> --user <用户名> [--port 22] [--dir <工作目录>] (--cmd <命令> | --test)

密码优先读环境变量 CMDCODE_PASSWORD，没有就在终端里提示输入（不回显）。
--cmd 里可以用 \\n 表示换行，方便试多行命令。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var options: [String: String] = [:]
var isTest = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--test": isTest = true
    case "--host", "--user", "--port", "--dir", "--cmd":
        guard let value = args.popFirst() else { fail("\(arg) 缺少值\n\n\(usage)") }
        options[arg] = value
    case "-h", "--help": print(usage); exit(0)
    default: fail("未知参数：\(arg)\n\n\(usage)")
    }
}

guard let host = options["--host"], let user = options["--user"] else { fail(usage) }
guard isTest || options["--cmd"] != nil else { fail(usage) }
guard let port = Int(options["--port"] ?? "22") else { fail("端口必须是数字") }

let password: String
if let env = ProcessInfo.processInfo.environment["CMDCODE_PASSWORD"] {
    password = env
} else if let typed = getpass("\(user)@\(host) 的密码：") {
    password = String(cString: typed)
} else {
    fail("没有读到密码")
}

let target = SSHTarget(host: host, port: port, username: user, password: password)
let runner = CommandRunner()
let removed = runner.store.cleanUpLeftovers()
if removed > 0 { print("清理了 \(removed) 个遗留脚本") }

do {
    let url: URL
    if isTest {
        url = try await runner.testConnection(target: target, workingDirectory: options["--dir"])
    } else {
        let command = options["--cmd"]!.replacingOccurrences(of: "\\n", with: "\n")
        url = try await runner.run(target: target, command: command, workingDirectory: options["--dir"])
    }
    print("已交给终端打开：\(url.lastPathComponent)")
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}

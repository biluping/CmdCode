import CmdCodeCore
import Foundation

let usage = """
在当前终端里通过 ssh 执行一条命令（开发调试用）。

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
let command = isTest ? ScriptBuilder.testConnectionCommand() : options["--cmd"]!.replacingOccurrences(of: "\\n", with: "\n")
let plan = ExecutionPlan(target: target, command: command,
                         workingDirectory: ScriptBuilder.normalizedWorkingDirectory(options["--dir"]),
                         requiresConfirmation: false, serverName: host, commandName: isTest ? "测试连接" : "命令")

do {
    // 在当前终端里直接运行 ssh（继承标准输入输出），效果和应用内终端一致。
    let invocation = try CommandRunner().invocation(for: plan)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: invocation.executable)
    process.arguments = invocation.arguments
    process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { $1 }
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}

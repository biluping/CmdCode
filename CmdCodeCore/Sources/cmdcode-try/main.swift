import CmdCodeCore
import Foundation

let usage = """
在当前终端里通过 ssh 执行一条命令（开发调试用）。

用法：
  swift run cmdcode-try --host <主机> --user <用户名> [--port 22] [--dir <工作目录>] (--cmd <命令> | --test)
  swift run cmdcode-try --host <主机> --user <用户名> [--port 22] (--ls <目录> | --cat <文件> | --put <文件>)
  swift run cmdcode-try --host <主机> --user <用户名> [--port 22] (--download <远程文件> | --upload <本地文件>) --to <路径> [--force]

--ls 列目录，--cat 读文件，--put 把标准输入的内容写回文件（先读一次拿校验值，再带冲突检测写入）。
--download 下载到本地路径，--upload 上传到远程路径（--force 允许覆盖已有文件）。

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
    case "--force": options["--force"] = "1"
    case "--host", "--user", "--port", "--dir", "--cmd", "--ls", "--cat", "--put", "--download", "--upload", "--to":
        guard let value = args.popFirst() else { fail("\(arg) 缺少值\n\n\(usage)") }
        options[arg] = value
    case "-h", "--help": print(usage); exit(0)
    default: fail("未知参数：\(arg)\n\n\(usage)")
    }
}

guard let host = options["--host"], let user = options["--user"] else { fail(usage) }
let fileOptions = ["--ls", "--cat", "--put", "--download", "--upload"].filter { options[$0] != nil }
guard isTest || options["--cmd"] != nil || !fileOptions.isEmpty else { fail(usage) }
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

// 远程文件操作：不经过终端，直接用 RemoteFileClient。
if let op = fileOptions.first, let path = options[op] {
    do {
        let client = RemoteFileClient(target: target)
        switch op {
        case "--ls":
            let listing = try await client.list(directory: path)
            print(listing.path)
            for e in listing.entries {
                let kind = switch e.kind { case .directory: "d"; case .file: "-"; case .other: "?" }
                print("\(kind)\(e.isSymlink ? "l" : " ")\(e.isWritable ? "w" : " ") \(String(e.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.modified.formatted(date: .numeric, time: .shortened))  \(e.name)")
            }
        case "--cat":
            let content = try await client.read(path: path)
            FileHandle.standardError.write(Data("[cksum \(content.checksum)，\(content.isWritable ? "可写" : "只读")，\(content.text == nil ? "非文本" : "文本")]\n".utf8))
            FileHandle.standardOutput.write(content.data)
        case "--download", "--upload":
            guard let to = options["--to"] else { fail("缺少 --to") }
            let start = Date()
            let progress: @Sendable (Int64, Int64) -> Void = { done, total in
                FileHandle.standardError.write(Data("\r\(done) / \(total) 字节".utf8))
            }
            if op == "--download" {
                try await client.download(path: path, to: URL(fileURLWithPath: to), progress: progress)
            } else {
                try await client.upload(from: URL(fileURLWithPath: path), to: to,
                                        overwrite: options["--force"] != nil, progress: progress)
            }
            print("\n完成，用时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")
        default:
            let opened = try await client.read(path: path)
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let checksum = try await client.write(data, to: path, expectedChecksum: opened.checksum)
            print("已写入 \(data.count) 字节，新 cksum \(checksum)")
        }
        exit(0)
    } catch {
        fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
}
let command = isTest ? ScriptBuilder.testConnectionCommand() : options["--cmd"]!.replacingOccurrences(of: "\\n", with: "\n")
let plan = ExecutionPlan(target: target, command: command,
                         workingDirectory: ScriptBuilder.normalizedWorkingDirectory(options["--dir"]),
                         requiresConfirmation: false, serverName: host, commandName: isTest ? "测试连接" : "命令")

do {
    // 当前进程直接换成 ssh（继承终端和标准输入输出），效果和应用内终端一致。
    // 不用 Process 起子进程：子进程不在终端的前台进程组，ssh -t 设置终端时会被系统暂停。
    let invocation = try CommandRunner().invocation(for: plan)
    for (key, value) in invocation.environment { setenv(key, value, 1) }
    let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
    execv(invocation.executable, argv)
    fail("无法启动 \(invocation.executable)：\(String(cString: strerror(errno)))")
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}

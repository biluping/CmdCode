import Foundation

/// 远程目录里的一个条目。
public struct RemoteFileEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case directory, file, other
    }

    public var name: String
    /// 符号链接按指向的目标算类型；链接断了算 `.other`。
    public var kind: Kind
    public var isSymlink: Bool
    public var isWritable: Bool
    public var size: Int64
    public var modified: Date

    public var id: String { name }

    public init(name: String, kind: Kind, isSymlink: Bool, isWritable: Bool, size: Int64, modified: Date) {
        self.name = name
        self.kind = kind
        self.isSymlink = isSymlink
        self.isWritable = isWritable
        self.size = size
        self.modified = modified
    }
}

public struct RemoteDirectoryListing: Sendable, Equatable {
    /// 远端 `pwd` 得到的绝对路径。
    public var path: String
    /// 目录在前，再按名称排序。
    public var entries: [RemoteFileEntry]
}

public struct RemoteFileContent: Sendable, Equatable {
    public var path: String
    public var data: Data
    /// 打开时远端 `cksum` 的输出，保存时用来检测冲突。
    public var checksum: String
    public var isWritable: Bool

    public init(path: String, data: Data, checksum: String, isWritable: Bool) {
        self.path = path
        self.data = data
        self.checksum = checksum
        self.isWritable = isWritable
    }

    /// 能当文本编辑时返回内容：不含 NUL 字节且是合法 UTF-8。
    public var text: String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum RemoteFileError: Error, Equatable, LocalizedError {
    case notRegularFile(String)
    case notWritable(String)
    case tooLarge(path: String, size: Int64)
    /// 打开之后文件被别人改过。
    case conflict(String)
    /// 上传时目标已存在且没有允许覆盖。
    case alreadyExists(String)
    /// 本地文件读写失败等。
    case local(String)
    case timeout
    case badOutput
    /// 其他失败：远端（或 ssh）的退出码和 stderr。
    case remote(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let p): "不是普通文件：\(p)"
        case .notWritable(let p): "没有写权限：\(p)"
        case .tooLarge(let p, let size):
            "文件太大（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))），不能打开：\(p)\n超过 5 MB 的文件可以下载到本地查看。"
        case .conflict(let p): "文件在打开后被修改过：\(p)"
        case .alreadyExists(let p): "文件已存在：\(p)"
        case .local(let message): message
        case .timeout: "操作超时"
        case .badOutput: "远端返回的内容无法解析"
        case .remote(let status, let message): message.isEmpty ? "执行失败（退出码 \(status)）" : message
        }
    }
}

/// 远程文件操作的内层脚本和输出解析。全部是纯函数，脚本经 `ScriptBuilder.remoteCommand(script:)` 发到远端。
///
/// 约定的退出码：20 不是普通文件，21 文件太大（stdout 是大小），22 冲突，23 没有写权限，24 文件已存在。
public enum RemoteFileScript {
    public static let maxReadBytes: Int64 = 5 * 1024 * 1024

    static let statusNotRegular: Int32 = 20
    static let statusTooLarge: Int32 = 21
    static let statusConflict: Int32 = 22
    static let statusNotWritable: Int32 = 23
    static let statusExists: Int32 = 24

    /// 列目录：先输出 `$PWD`，再每个条目一条“类型 链接 可写 大小 修改时间 名称”，记录以 NUL 结尾。
    /// 目录为空时列登录用户的家目录。
    public static func list(directory: String?) -> String {
        let cd = ScriptBuilder.normalizedWorkingDirectory(directory).map { "cd -- \(ScriptBuilder.shq($0)) || exit 1" }
            ?? "cd || exit 1"
        return """
        \(cd)
        [ -r . ] && [ -x . ] || { echo "没有权限读取目录：$PWD" >&2; exit 1; }
        shopt -s dotglob nullglob
        if stat -c %s / >/dev/null 2>&1; then _gnu=1; else _gnu=; fi
        printf '%s\\0' "$PWD"
        if [ -n "$_gnu" ]; then
          # GNU：所有条目一次 stat（每个条目 fork 一次，上千个文件就要一秒多）。按顺序输出“大小 时间 名字”，
          # 名字对不上的（列完之后被删了）记 0 0，留着这条给后面的条目比对。
          _ok=(); for f in *; do [ -e "$f" ] && _ok+=("$f"); done
          exec 3< <([ ${#_ok[@]} -gt 0 ] && printf '%s\\0' "${_ok[@]}" | xargs -0 stat -L --printf '%s %Y %n\\0' -- 2>/dev/null)
          _rec=; _have=
        fi
        for f in *; do
          if [ -L "$f" ]; then l=1; else l=0; fi
          if [ -d "$f" ]; then t=d; elif [ -f "$f" ]; then t=f; else t=o; fi
          if [ -w "$f" ]; then w=1; else w=0; fi
          m=
          if [ -n "$_gnu" ]; then
            if [ -e "$f" ]; then
              [ -n "$_have" ] || { IFS= read -r -d '' _rec <&3 && _have=1; }
              if [ -n "$_have" ] && [ "${_rec#* * }" = "$f" ]; then m=${_rec%% * *}; _r2=${_rec#* }; m="$m ${_r2%% *}"; _have=; fi
            fi
          else
            m=$(stat -L -f '%z %m' -- "$f" 2>/dev/null)
          fi
          printf '%s %s %s %s %s\\0' "$t" "$l" "$w" "${m:-0 0}" "$f"
        done
        """
    }

    /// 读文件：第一行是否可写（1/0），第二行 `cksum`，之后是 base64 内容。
    public static func read(path: String, maxBytes: Int64 = maxReadBytes) -> String {
        """
        f=\(ScriptBuilder.shq(path))
        [ -e "$f" ] || { echo "文件不存在：$f" >&2; exit 1; }
        [ -f "$f" ] || { echo "不是普通文件：$f" >&2; exit \(statusNotRegular); }
        [ -r "$f" ] || { echo "没有读权限：$f" >&2; exit 1; }
        s=$(wc -c < "$f") || exit 1
        s=${s//[!0-9]/}
        if [ "$s" -gt \(maxBytes) ]; then printf '%s' "$s"; exit \(statusTooLarge); fi
        if [ -w "$f" ]; then w=1; else w=0; fi
        c=$(cksum < "$f") || exit 1
        printf '%s\\n%s\\n' "$w" "$c"
        base64 < "$f"
        """
    }

    /// 写文件：内容从 stdin 读进远端临时文件，核对字节数后 `cat` 覆盖原文件（权限、属主、inode 不变），
    /// 最后输出新的 `cksum`。`expectedChecksum` 为 nil 时不检查冲突（强制覆盖）。
    public static func write(path: String, byteCount: Int, expectedChecksum: String?) -> String {
        """
        f=\(ScriptBuilder.shq(path))
        e=\(ScriptBuilder.shq(expectedChecksum ?? ""))
        [ -f "$f" ] || { echo "不是普通文件：$f" >&2; exit \(statusNotRegular); }
        [ -w "$f" ] || { echo "没有写权限：$f" >&2; exit \(statusNotWritable); }
        if [ -n "$e" ] && [ "$(cksum < "$f")" != "$e" ]; then echo "文件在打开后被修改过：$f" >&2; exit \(statusConflict); fi
        t=$(mktemp "${TMPDIR:-/tmp}/cmdcode.XXXXXX") || exit 1
        trap 'rm -f "$t"' EXIT
        cat > "$t" || exit 1
        n=$(wc -c < "$t"); n=${n//[!0-9]/}
        [ "$n" = \(byteCount) ] || { echo "内容没有传完整（收到 $n 字节，应为 \(byteCount)），未写入" >&2; exit 1; }
        cat -- "$t" > "$f" || exit 1
        cksum < "$f"
        """
    }

    /// 下载：第一行输出文件大小，接着用 `head -c` 正好输出这么多字节（文件在下载中变长也不影响核对）。
    public static func download(path: String) -> String {
        """
        f=\(ScriptBuilder.shq(path))
        [ -e "$f" ] || { echo "文件不存在：$f" >&2; exit 1; }
        [ -f "$f" ] || { echo "不是普通文件：$f" >&2; exit \(statusNotRegular); }
        [ -r "$f" ] || { echo "没有读权限：$f" >&2; exit 1; }
        s=$(wc -c < "$f") || exit 1
        s=${s//[!0-9]/}
        printf '%s\\n' "$s"
        [ "$s" = 0 ] && exit 0
        exec head -c "$s" -- "$f"
        """
    }

    /// 上传：内容从 stdin 收到临时文件（目标目录可写就放在目标目录，否则放 /tmp），核对字节数后 `cat` 写到目标。
    /// 目标已存在时覆盖不改变权限和属主；新文件按远端 umask 创建。
    public static func upload(path: String, byteCount: Int64, overwrite: Bool) -> String {
        """
        f=\(ScriptBuilder.shq(path))
        d=$(dirname -- "$f")
        [ -d "$d" ] || { echo "目录不存在：$d" >&2; exit 1; }
        if [ -e "$f" ] || [ -L "$f" ]; then
          \(overwrite ? ":" : "echo \"文件已存在：$f\" >&2; exit \(statusExists)")
          [ -f "$f" ] || { echo "不是普通文件：$f" >&2; exit \(statusNotRegular); }
          [ -w "$f" ] || { echo "没有写权限：$f" >&2; exit \(statusNotWritable); }
        else
          [ -w "$d" ] || { echo "没有写权限：$d" >&2; exit \(statusNotWritable); }
        fi
        if [ -w "$d" ]; then t=$(mktemp "$d/.cmdcode-upload.XXXXXX"); else t=$(mktemp "${TMPDIR:-/tmp}/cmdcode.XXXXXX"); fi || exit 1
        trap 'rm -f "$t"' EXIT
        cat > "$t" || exit 1
        n=$(wc -c < "$t"); n=${n//[!0-9]/}
        [ "$n" = \(byteCount) ] || { echo "内容没有传完整（收到 $n 字节，应为 \(byteCount)），未写入" >&2; exit 1; }
        cat -- "$t" > "$f" || exit 1
        """
    }

    /// 删除文件：普通文件、符号链接（只删链接本身）和其他非目录条目；目录不删。
    /// 删除要求所在目录可写，和文件本身的写权限无关。
    public static func delete(path: String) -> String {
        """
        f=\(ScriptBuilder.shq(path))
        [ -e "$f" ] || [ -L "$f" ] || { echo "文件不存在：$f" >&2; exit 1; }
        if [ -d "$f" ] && [ ! -L "$f" ]; then echo "是目录，不能删除：$f" >&2; exit 1; fi
        d=$(dirname -- "$f")
        [ -w "$d" ] || { echo "没有写权限：$d" >&2; exit \(statusNotWritable); }
        rm -f -- "$f"
        """
    }

    public static func parseListing(_ data: Data) throws -> RemoteDirectoryListing {
        var records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        // 每条记录都以 NUL 结尾，最后一段是空的。
        guard records.count >= 2, records.removeLast().isEmpty else { throw RemoteFileError.badOutput }
        let path = records.removeFirst()
        let entries = try records.map { record -> RemoteFileEntry in
            let parts = record.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false)
            guard parts.count == 6, let size = Int64(parts[3]), let mtime = TimeInterval(parts[4]) else {
                throw RemoteFileError.badOutput
            }
            let kind: RemoteFileEntry.Kind = switch parts[0] {
            case "d": .directory
            case "f": .file
            default: .other
            }
            return RemoteFileEntry(name: String(parts[5]), kind: kind, isSymlink: parts[1] == "1",
                                   isWritable: parts[2] == "1", size: size,
                                   modified: Date(timeIntervalSince1970: mtime))
        }
        return RemoteDirectoryListing(path: path, entries: entries.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    public static func parseRead(_ data: Data, path: String) throws -> RemoteFileContent {
        let lines = data.split(separator: UInt8(ascii: "\n"), maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2 else { throw RemoteFileError.badOutput }
        let body = lines.count == 3 ? Data(lines[2]) : Data()
        let trimmed = body.filter { $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "\r") }
        guard let content = trimmed.isEmpty ? Data() : Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            throw RemoteFileError.badOutput
        }
        return RemoteFileContent(path: path, data: content,
                                 checksum: String(decoding: lines[1], as: UTF8.self),
                                 isWritable: lines[0].elementsEqual("1".utf8))
    }

    /// 绝对路径拼接：`/` + `etc` → `/etc`。
    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// 上级目录；已经是根目录时返回 nil。
    public static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// 在一台服务器上做远程文件操作。每个操作单独起一次 `ssh -T`，不写本地临时文件。
public struct RemoteFileClient: Sendable {
    public var target: SSHTarget
    public var sshPath: String
    public var timeout: TimeInterval
    /// 连接复用的控制 socket 目录；nil 表示每次新建连接（测试用的假 ssh 不认 ssh 参数）。
    public var controlDirectory: String?
    /// askpass 脚本所在目录。
    public var askPassDirectory: String

    /// 控制 socket 和 askpass 脚本放在同一个运行目录里。
    public static let defaultControlDirectory = AskPass.defaultDirectory

    /// 真实服务器用：系统 ssh，开启连接复用。
    public init(target: SSHTarget) {
        self.init(target: target, sshPath: ScriptBuilder.sshPath, controlDirectory: Self.defaultControlDirectory)
    }

    public init(target: SSHTarget, sshPath: String, timeout: TimeInterval = 30, controlDirectory: String? = nil,
                askPassDirectory: String = AskPass.defaultDirectory) {
        self.target = target
        self.sshPath = sshPath
        self.timeout = timeout
        self.controlDirectory = controlDirectory
        self.askPassDirectory = askPassDirectory
    }

    /// `%C` 是 ssh 自己算的“本机+主机+端口+用户”哈希，换了主机、端口或用户就是另一条连接。
    var controlPath: String? { controlDirectory.map { "\($0)/%C" } }

    /// 关掉这台服务器的复用连接（关文件标签时）。没有连接时什么也不做。
    public func closeSharedConnection() {
        guard let controlPath else { return }
        Self.exitMaster(["-o", "ControlPath=\(controlPath)", "-p", String(target.port),
                         "-l", target.username, "--", target.host])
    }

    /// 关掉目录里所有复用连接（退出应用时）。
    public static func closeAllSharedConnections(in directory: String = defaultControlDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name != AskPass.scriptName {
            exitMaster(["-o", "ControlPath=\(directory)/\(name)", "--", "cmdcode"])
        }
    }

    /// `ssh -O exit` 只和本机的主连接进程通信，不连服务器、不需要密码，很快返回。
    private static func exitMaster(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-O", "exit", "-o", "LogLevel=QUIET"] + arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    /// 建目录并只留给自己（0700），别的用户不能借用这些已认证的连接。
    private func prepareControlDirectory() throws {
        guard let controlDirectory else { return }
        do {
            try AskPass.prepareDirectory(controlDirectory)
        } catch {
            throw RemoteFileError.local("无法复用连接：\(error.localizedDescription)")
        }
    }

    public func list(directory: String?) async throws -> RemoteDirectoryListing {
        let r = try await run(RemoteFileScript.list(directory: directory), options: ProcessOptions(timeout: timeout))
        try check(r, path: directory ?? "~")
        return try RemoteFileScript.parseListing(r.stdout)
    }

    public func read(path: String) async throws -> RemoteFileContent {
        let r = try await run(RemoteFileScript.read(path: path), options: ProcessOptions(timeout: timeout))
        if r.status == RemoteFileScript.statusTooLarge {
            throw RemoteFileError.tooLarge(path: path, size: Int64(String(decoding: r.stdout, as: UTF8.self)) ?? 0)
        }
        try check(r, path: path)
        return try RemoteFileScript.parseRead(r.stdout, path: path)
    }

    /// 写回文件，返回新的校验值。`expectedChecksum` 为 nil 表示不检查冲突，直接覆盖。
    public func write(_ data: Data, to path: String, expectedChecksum: String?) async throws -> String {
        let script = RemoteFileScript.write(path: path, byteCount: data.count, expectedChecksum: expectedChecksum)
        let r = try await run(script, options: ProcessOptions(input: .data(data), timeout: timeout))
        try check(r, path: path)
        return String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 删除文件（不能删目录）。没有权限时报 `.notWritable`，路径是所在目录。
    public func delete(path: String) async throws {
        let r = try await run(RemoteFileScript.delete(path: path), options: ProcessOptions(timeout: timeout))
        if r.status == RemoteFileScript.statusNotWritable {
            throw RemoteFileError.notWritable(RemoteFileScript.parent(of: path) ?? path)
        }
        try check(r, path: path)
    }

    // MARK: 上传下载

    /// 下载远程文件到本地。先写到同目录的临时文件，传完并核对字节数后再替换目标文件，中途失败不留半截文件。
    /// `progress` 大约每 0.2 秒回调一次（已传字节数，总字节数），在后台线程。
    public func download(path: String, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).cmdcode-\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw RemoteFileError.local("无法写入：\(destination.deletingLastPathComponent().path)")
        }
        defer { try? fm.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        let sink = DownloadSink(handle: handle)
        var options = ProcessOptions()
        options.stdoutSink = { try sink.receive($0) }
        options.counter = sink.counter
        options.progress = progress
        let r = try await run(RemoteFileScript.download(path: path), options: options)
        try handle.close()
        try check(r, path: path)
        guard let total = sink.total, sink.counter.bytes == total else {
            throw RemoteFileError.local("下载不完整（收到 \(sink.counter.bytes) 字节），已放弃")
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
    }

    /// 上传本地文件到远程路径。目标已存在时：`overwrite` 为 false 报 `.alreadyExists`，为 true 用 `cat` 覆盖（权限、属主不变）。
    public func upload(from source: URL, to path: String, overwrite: Bool,
                       progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let size = try (FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let counter = TransferCounter(total: size)
        var options = ProcessOptions()
        options.input = .file(source)
        options.counter = counter
        options.progress = progress
        let r = try await run(RemoteFileScript.upload(path: path, byteCount: size, overwrite: overwrite), options: options)
        try check(r, path: path)
    }

    private func check(_ r: ProcessResult, path: String) throws {
        switch r.status {
        case 0: return
        case RemoteFileScript.statusNotRegular: throw RemoteFileError.notRegularFile(path)
        case RemoteFileScript.statusNotWritable: throw RemoteFileError.notWritable(path)
        case RemoteFileScript.statusConflict: throw RemoteFileError.conflict(path)
        case RemoteFileScript.statusExists: throw RemoteFileError.alreadyExists(path)
        default:
            let message = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteFileError.remote(status: r.status, message: message)
        }
    }

    private func run(_ script: String, options: ProcessOptions = ProcessOptions()) async throws -> ProcessResult {
        try prepareControlDirectory()
        let askPassPath: String
        do {
            askPassPath = try AskPass.prepare(in: askPassDirectory)
        } catch {
            throw RemoteFileError.local(error.localizedDescription)
        }
        let invocation = ScriptBuilder.sshInvocation(
            target: target, sshPath: sshPath, askPassPath: askPassPath,
            remoteCommand: ScriptBuilder.remoteCommand(script: script, loginShell: false), allocateTTY: false,
            controlPath: controlPath)
        var env = invocation.environment
        // askpass 脚本用 /bin/sh 和 printf，给个基本的 PATH。
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        let canceller = ProcessCanceller()
        var options = options
        options.canceller = canceller
        let environment = env
        let finalOptions = options
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        try ProcessResult.run(invocation.executable, invocation.arguments,
                                              environment: environment, options: finalOptions)
                    })
                }
            }
        } onCancel: {
            canceller.cancel()
        }
    }
}

// MARK: - 进程

/// 进程的标准输入来源。
enum ProcessInput: Sendable {
    case data(Data)
    /// 按块读本地文件送进去，不整个读进内存。
    case file(URL)
}

struct ProcessOptions: Sendable {
    var input: ProcessInput?
    /// 设置后 stdout 交给它处理（下载写文件），不收在内存里。抛错会结束进程。
    var stdoutSink: (@Sendable (Data) throws -> Void)?
    /// nil 表示不限时（上传下载）。
    var timeout: TimeInterval?
    /// 传输字节计数：上传时由写 stdin 的线程累加，下载时由 `stdoutSink` 累加。
    var counter: TransferCounter?
    var progress: (@Sendable (Int64, Int64) -> Void)?
    var canceller: ProcessCanceller?
}

final class TransferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _total: Int64

    init(total: Int64 = 0) { _total = total }

    var bytes: Int64 { lock.withLock { _bytes } }
    var total: Int64 {
        get { lock.withLock { _total } }
        set { lock.withLock { _total = newValue } }
    }

    func add(_ n: Int) { lock.withLock { _bytes += Int64(n) } }
}

/// 取消时结束进程。进程还没启动就取消的，启动后立即结束。
final class ProcessCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func attach(_ p: Process) {
        let cancelNow = lock.withLock { () -> Bool in
            process = p
            return cancelled
        }
        if cancelNow { p.terminate() }
    }

    func cancel() {
        let p = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        p?.terminate()
    }
}

/// 下载的 stdout：第一行是文件大小，之后是文件内容，直接写进本地文件。
private final class DownloadSink: @unchecked Sendable {
    let handle: FileHandle
    let counter = TransferCounter()
    private var header = Data()
    private(set) var total: Int64?

    init(handle: FileHandle) { self.handle = handle }

    /// 只在 stdout 的读取回调里串行调用。
    func receive(_ chunk: Data) throws {
        var body = chunk
        if total == nil {
            header.append(chunk)
            guard let newline = header.firstIndex(of: UInt8(ascii: "\n")) else { return }
            guard let size = Int64(String(decoding: header[..<newline], as: UTF8.self)) else {
                throw RemoteFileError.badOutput
            }
            total = size
            counter.total = size
            body = Data(header[header.index(after: newline)...])
            header = Data()
        }
        guard !body.isEmpty else { return }
        try handle.write(contentsOf: body)
        counter.add(body.count)
    }
}

struct ProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32

    /// 同步运行一个进程。会阻塞当前线程，别在主线程调用。
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    options: ProcessOptions) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = options.input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        // 远端提前退出（冲突、文件已存在）时管道读端已关，再写会收到 SIGPIPE 让整个应用退出；改成写入报错。
        if let inPipe { _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }

        let buffers = OutputBuffers()
        let eof = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            eof.enter()
            pipe.fileHandleForReading.readabilityHandler = { [weak process] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    eof.leave()
                } else if isOut, let sink = options.stdoutSink {
                    do { try sink(chunk) } catch {
                        buffers.fail(error)
                        process?.terminate()
                    }
                } else {
                    buffers.append(chunk, toOut: isOut)
                }
            }
        }

        try process.run()
        options.canceller?.attach(process)
        if let inPipe, let input = options.input {
            DispatchQueue.global().async {
                writeInput(input, to: inPipe.fileHandleForWriting, counter: options.counter)
            }
        }
        let timer = options.timeout.map { timeout in
            let item = DispatchWorkItem { [weak process] in
                buffers.markTimedOut()
                process?.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            return item
        }
        let ticker = options.progress.map { progress in
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + 0.2, repeating: 0.2)
            t.setEventHandler { if let c = options.counter { progress(c.bytes, c.total) } }
            t.resume()
            return t
        }
        process.waitUntilExit()
        timer?.cancel()
        ticker?.cancel()
        // 数据在进程退出前已写完；管道写端偶尔会被同时启动的其他子进程继承而迟迟等不到 EOF，最多再等 1 秒。
        _ = eof.wait(timeout: .now() + 1)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let c = options.counter { options.progress?(c.bytes, c.total) }

        if options.canceller?.isCancelled == true { throw CancellationError() }
        let (out, err, timedOut, failure) = buffers.snapshot()
        if let failure { throw failure }
        if timedOut { throw RemoteFileError.timeout }
        return ProcessResult(stdout: out, stderr: err, status: process.terminationStatus)
    }

    private static func writeInput(_ input: ProcessInput, to handle: FileHandle, counter: TransferCounter?) {
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        switch input {
        case .data(let data):
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                guard (try? handle.write(contentsOf: data[offset..<end])) != nil else { return }
                counter?.add(end - offset)
                offset = end
            }
        case .file(let url):
            guard let reader = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? reader.close() }
            while let chunk = try? reader.read(upToCount: chunkSize), !chunk.isEmpty {
                guard (try? handle.write(contentsOf: chunk)) != nil else { return }
                counter?.add(chunk.count)
            }
        }
    }
}

private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false
    private var failure: Error?

    func append(_ chunk: Data, toOut: Bool) {
        lock.withLock { if toOut { out.append(chunk) } else { err.append(chunk) } }
    }

    func markTimedOut() { lock.withLock { timedOut = true } }

    func fail(_ error: Error) { lock.withLock { if failure == nil { failure = error } } }

    func snapshot() -> (Data, Data, Bool, Error?) { lock.withLock { (out, err, timedOut, failure) } }
}

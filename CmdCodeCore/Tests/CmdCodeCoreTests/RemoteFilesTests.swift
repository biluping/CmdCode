import Foundation
import Testing
@testable import CmdCodeCore

/// 远程文件往返测试：假的 ssh 用本地 bash 执行远端命令（stdin 原样传过去），代替真实服务器。
@Suite("RemoteFiles")
struct RemoteFilesTests {

    private func makeClient(base: String) throws -> RemoteFileClient {
        let fake = base + "/fake ssh"
        try """
        #!/bin/bash
        export HOME=\(ScriptBuilder.shq(base))
        for last; do :; done
        exec /bin/bash -c "$last"

        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake)
        return RemoteFileClient(target: SSHTarget(host: "h", username: "u", password: "p"), sshPath: fake,
                                askPassDirectory: base + "/rt")
    }

    // MARK: 列目录

    @Test("列目录：特殊文件名、隐藏文件、链接、目录在前")
    func listDirectory() async throws {
        let base = try Shell.makeTempDir()
        let dir = base + "/it's 目录 $x"
        try Shell.mkdir(dir + "/sub dir")
        let names = ["a b.conf", "it's", "中文.cfg", ".hidden", "line\nbreak", "  lead", "$(no)"]
        for n in names { try Data("12345".utf8).write(to: URL(fileURLWithPath: dir + "/" + n)) }
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: "sub dir")
        try FileManager.default.createSymbolicLink(atPath: dir + "/dangling", withDestinationPath: "nowhere")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir + "/it's")

        let listing = try await makeClient(base: base).list(directory: dir)
        #expect(listing.path == dir)
        #expect(Set(listing.entries.map(\.name)) == Set(names + ["sub dir", "link", "dangling"]))
        #expect(listing.entries.prefix(2).allSatisfy { $0.kind == .directory })

        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        let conf = try #require(byName["a b.conf"])
        #expect(conf.kind == .file && conf.size == 5 && conf.isWritable && !conf.isSymlink)
        #expect(abs(conf.modified.timeIntervalSinceNow) < 600)
        #expect(byName["it's"]?.isWritable == false)
        #expect(byName["link"]?.kind == .directory && byName["link"]?.isSymlink == true)
        #expect(byName["dangling"]?.kind == .other && byName["dangling"]?.isSymlink == true)
        #expect(byName["sub dir"]?.isSymlink == false)
    }

    @Test("不填目录时列家目录；空目录")
    func listHomeAndEmpty() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        #expect(try await client.list(directory: nil).path == base)
        try Shell.mkdir(base + "/empty")
        let empty = try await client.list(directory: base + "/empty")
        #expect(empty.entries.isEmpty)
    }

    @Test("目录不存在时报 cd 的错误")
    func listMissingDirectory() async throws {
        let base = try Shell.makeTempDir()
        await #expect {
            try await makeClient(base: base).list(directory: base + "/nope")
        } throws: { error in
            guard case .remote(_, let message) = error as? RemoteFileError else { return false }
            return message.contains("nope")
        }
    }

    // MARK: 读写

    @Test("读写往返：内容逐字节一致，权限和 inode 不变，链接不被替换")
    func readWriteRoundTrip() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        let path = base + "/my 'conf'.cfg"
        try Data("aaa\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        let link = base + "/link.cfg"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)

        let opened = try await client.read(path: link)
        #expect(opened.text == "aaa\n")
        #expect(opened.isWritable)

        let text = "# 中文注释\r\nkey='v\"a$l`ue'\n\n\ttab\\end\n$(echo no)\nEOF\n末尾无换行"
        let checksum = try await client.write(Data(text.utf8), to: link, expectedChecksum: opened.checksum)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attrs[.posixPermissions] as? Int == 0o640)
        #expect(attrs[.systemFileNumber] as? Int == inode)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == path)

        let reopened = try await client.read(path: path)
        #expect(reopened.text == text)
        #expect(reopened.checksum == checksum)
    }

    @Test("任意字节（含 NUL）原样读出，不当文本")
    func binaryContent() async throws {
        let base = try Shell.makeTempDir()
        let bytes = Data((0...255).map { UInt8($0) } + Array(repeating: 0x41, count: 200_000))
        try bytes.write(to: URL(fileURLWithPath: base + "/bin"))
        let content = try await makeClient(base: base).read(path: base + "/bin")
        #expect(content.data == bytes)
        #expect(content.text == nil)
    }

    @Test("写空内容")
    func writeEmpty() async throws {
        let base = try Shell.makeTempDir()
        let path = base + "/f"
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let client = try makeClient(base: base)
        let opened = try await client.read(path: path)
        _ = try await client.write(Data(), to: path, expectedChecksum: opened.checksum)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
        #expect(try await client.read(path: path).text == "")
    }

    @Test("打开后被别人改过：拒绝写入；不带校验值时强制覆盖")
    func conflict() async throws {
        let base = try Shell.makeTempDir()
        let path = base + "/f.cfg"
        try Data("v1".utf8).write(to: URL(fileURLWithPath: path))
        let client = try makeClient(base: base)
        let opened = try await client.read(path: path)
        try Data("v2 by someone".utf8).write(to: URL(fileURLWithPath: path))

        await #expect(throws: RemoteFileError.conflict(path)) {
            try await client.write(Data("mine".utf8), to: path, expectedChecksum: opened.checksum)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "v2 by someone")

        _ = try await client.write(Data("mine".utf8), to: path, expectedChecksum: nil)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "mine")
    }

    @Test("只读文件、目录、太大的文件")
    func errors() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        let ro = base + "/ro"
        try Data("r".utf8).write(to: URL(fileURLWithPath: ro))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro)
        let opened = try await client.read(path: ro)
        #expect(!opened.isWritable)
        await #expect(throws: RemoteFileError.notWritable(ro)) {
            try await client.write(Data("w".utf8), to: ro, expectedChecksum: opened.checksum)
        }

        await #expect(throws: RemoteFileError.notRegularFile(base)) { try await client.read(path: base) }

        let big = base + "/big"
        let size = RemoteFileScript.maxReadBytes + 1
        try Data(count: Int(size)).write(to: URL(fileURLWithPath: big))
        await #expect(throws: RemoteFileError.tooLarge(path: big, size: size)) { try await client.read(path: big) }
    }

    // MARK: 上传下载

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test("下载：二进制内容逐字节一致，覆盖已有文件，不留临时文件，进度到 100%")
    func download() async throws {
        let base = try Shell.makeTempDir()
        let remote = base + "/远程 it's.bin"
        let bytes = randomData(3_000_000)
        try bytes.write(to: URL(fileURLWithPath: remote))
        let localDir = base + "/本地 目录"
        try Shell.mkdir(localDir)
        let dest = URL(fileURLWithPath: localDir + "/a.bin")
        try Data("old".utf8).write(to: dest)

        let last = TransferCounter()
        try await makeClient(base: base).download(path: remote, to: dest) { done, total in
            last.total = total
            last.add(Int(done - last.bytes))
        }
        #expect(try Data(contentsOf: dest) == bytes)
        #expect(last.bytes == 3_000_000 && last.total == 3_000_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: localDir) == ["a.bin"])
    }

    @Test("下载空文件；下载不存在的文件不产生本地文件")
    func downloadEdgeCases() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        try Data().write(to: URL(fileURLWithPath: base + "/empty"))
        try Shell.mkdir(base + "/out")
        try await client.download(path: base + "/empty", to: URL(fileURLWithPath: base + "/out/empty"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: base + "/out/empty")).isEmpty)

        await #expect(throws: RemoteFileError.self) {
            try await client.download(path: base + "/nope", to: URL(fileURLWithPath: base + "/out/nope"))
        }
        await #expect(throws: RemoteFileError.notRegularFile(base)) {
            try await client.download(path: base, to: URL(fileURLWithPath: base + "/out/dir"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base + "/out") == ["empty"])
    }

    @Test("上传新文件；已存在时不覆盖；允许覆盖时权限和 inode 不变")
    func upload() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        let local = URL(fileURLWithPath: base + "/local.bin")
        let bytes = randomData(2_000_000)
        try bytes.write(to: local)
        let dir = base + "/远程 $dir"
        try Shell.mkdir(dir)

        let target = dir + "/新 'file'.bin"
        try await client.upload(from: local, to: target, overwrite: false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["新 'file'.bin"])

        let existing = dir + "/app.conf"
        try Data("old".utf8).write(to: URL(fileURLWithPath: existing))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: existing)
        let inode = try FileManager.default.attributesOfItem(atPath: existing)[.systemFileNumber] as? Int
        // 远端在读 stdin 之前就退出，2MB 写不进去：不能因为 SIGPIPE 崩溃。
        await #expect(throws: RemoteFileError.alreadyExists(existing)) {
            try await client.upload(from: local, to: existing, overwrite: false)
        }
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old")

        try await client.upload(from: local, to: existing, overwrite: true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: existing)) == bytes)
        let attrs = try FileManager.default.attributesOfItem(atPath: existing)
        #expect(attrs[.posixPermissions] as? Int == 0o640)
        #expect(attrs[.systemFileNumber] as? Int == inode)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir)) == ["新 'file'.bin", "app.conf"])
    }

    @Test("上传到只读文件、不存在的目录")
    func uploadErrors() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        let local = URL(fileURLWithPath: base + "/local")
        try randomData(500_000).write(to: local)
        let ro = base + "/ro"
        try Data("r".utf8).write(to: URL(fileURLWithPath: ro))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro)
        await #expect(throws: RemoteFileError.notWritable(ro)) {
            try await client.upload(from: local, to: ro, overwrite: true)
        }
        await #expect {
            try await client.upload(from: local, to: base + "/nope/x", overwrite: false)
        } throws: { error in
            guard case .remote(_, let message) = error as? RemoteFileError else { return false }
            return message.contains("目录不存在")
        }
    }

    @Test("删除：特殊文件名、只删链接本身；目录、不存在、目录不可写时报错")
    func delete() async throws {
        let base = try Shell.makeTempDir()
        let client = try makeClient(base: base)
        let dir = base + "/删 $dir"
        try Shell.mkdir(dir + "/sub")
        let file = dir + "/it's \"x\".conf"
        try Data("a".utf8).write(to: URL(fileURLWithPath: file))
        let target = dir + "/target"
        try Data("t".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: target)
        try FileManager.default.createSymbolicLink(atPath: dir + "/broken", withDestinationPath: dir + "/nope")
        try FileManager.default.createSymbolicLink(atPath: dir + "/dirlink", withDestinationPath: dir + "/sub")

        try await client.delete(path: file)
        try await client.delete(path: dir + "/link")
        try await client.delete(path: dir + "/broken")
        try await client.delete(path: dir + "/dirlink")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir)) == ["sub", "target"])

        await #expect {
            try await client.delete(path: dir + "/sub")
        } throws: { error in
            guard case .remote(_, let message) = error as? RemoteFileError else { return false }
            return message.contains("是目录")
        }
        await #expect {
            try await client.delete(path: dir + "/nope")
        } throws: { error in
            guard case .remote(_, let message) = error as? RemoteFileError else { return false }
            return message.contains("文件不存在")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        await #expect(throws: RemoteFileError.notWritable(dir)) {
            try await client.delete(path: target)
        }
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test("保存大内容遇到冲突时不会因 SIGPIPE 崩溃")
    func bigWriteConflict() async throws {
        let base = try Shell.makeTempDir()
        let path = base + "/f"
        try Data("v1".utf8).write(to: URL(fileURLWithPath: path))
        await #expect(throws: RemoteFileError.conflict(path)) {
            try await makeClient(base: base).write(randomData(1_000_000), to: path, expectedChecksum: "0 0")
        }
    }

    @Test("取消下载：抛 CancellationError，不留文件")
    func cancelDownload() async throws {
        let base = try Shell.makeTempDir()
        try randomData(1_000_000).write(to: URL(fileURLWithPath: base + "/big"))
        try Shell.mkdir(base + "/out")
        let client = try makeClient(base: base)
        let task = Task {
            try await client.download(path: base + "/big", to: URL(fileURLWithPath: base + "/out/big"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base + "/out").isEmpty)
    }

    // MARK: 纯函数

    @Test func pathHelpers() {
        #expect(RemoteFileScript.join("/", "etc") == "/etc")
        #expect(RemoteFileScript.join("/etc", "nginx") == "/etc/nginx")
        #expect(RemoteFileScript.parent(of: "/etc/nginx") == "/etc")
        #expect(RemoteFileScript.parent(of: "/etc") == "/")
        #expect(RemoteFileScript.parent(of: "/") == nil)
    }

    @Test("解析 GNU 和 BSD 风格的输出是同一格式")
    func parseListing() throws {
        let raw = "/root\0f 0 1 4 1700000000 test.cfg\0d 1 0 0 0 a b\0"
        let listing = try RemoteFileScript.parseListing(Data(raw.utf8))
        #expect(listing.path == "/root")
        #expect(listing.entries.map(\.name) == ["a b", "test.cfg"])
        #expect(listing.entries[1].modified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(throws: RemoteFileError.badOutput) { try RemoteFileScript.parseListing(Data("garbage".utf8)) }
    }

    @Test("无终端调用用 -T，原有执行仍是 -t")
    func ttyFlag() {
        let t = SSHTarget(host: "h", username: "u", password: "p")
        #expect(ScriptBuilder.sshInvocation(target: t, askPassPath: "/x", remoteCommand: "c", allocateTTY: false)
            .arguments.first == "-T")
        #expect(ScriptBuilder.sshInvocation(target: t, askPassPath: "/x", command: "c", workingDirectory: nil)
            .arguments.first == "-t")
    }

    @Test("连接复用：给了 controlPath 才加 ControlMaster 参数，且在主机之前；文件操作用非登录 shell")
    func connectionReuse() throws {
        let t = SSHTarget(host: "h", username: "u", password: "p")
        let plain = ScriptBuilder.sshInvocation(target: t, askPassPath: "/x", remoteCommand: "c", allocateTTY: false)
        #expect(!plain.arguments.contains { $0.hasPrefix("Control") })
        let shared = ScriptBuilder.sshInvocation(target: t, askPassPath: "/x", remoteCommand: "c", allocateTTY: false,
                                                  controlPath: "/tmp/d/%C")
        #expect(shared.arguments.contains("ControlMaster=auto"))
        #expect(shared.arguments.contains("ControlPath=/tmp/d/%C"))
        #expect(shared.arguments.contains("ControlPersist=300"))
        let dashes = try #require(shared.arguments.firstIndex(of: "--"))
        #expect(shared.arguments.firstIndex(of: "ControlMaster=auto")! < dashes)
        #expect(shared.arguments.suffix(2) == ["h", "c"])
        #expect(ScriptBuilder.remoteCommand(script: "x", loginShell: false).hasPrefix("bash -c "))
        #expect(ScriptBuilder.remoteCommand(script: "x").hasPrefix("bash -lc "))
        // socket 路径留够余量：目录 + 40 位哈希 + ssh 建 socket 时临时加的后缀，要在 104 字节以内。
        #expect(RemoteFileClient.defaultControlDirectory.utf8.count + 1 + 40 + 20 < 104)
    }
}

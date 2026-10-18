import Foundation
import Testing
@testable import CmdCodeCore

/// 远程文件往返测试：假的 sshpass 用本地 bash 执行远端命令（stdin 原样传过去），代替真实服务器。
@Suite("RemoteFiles")
struct RemoteFilesTests {

    private func makeClient(base: String) throws -> RemoteFileClient {
        let fake = base + "/fake sshpass"
        try """
        #!/bin/bash
        export HOME=\(ScriptBuilder.shq(base))
        for last; do :; done
        exec /bin/bash -c "$last"

        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake)
        return RemoteFileClient(target: SSHTarget(host: "h", username: "u", password: "p"), sshpassPath: fake)
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
        #expect(ScriptBuilder.sshInvocation(target: t, sshpassPath: "/x", remoteCommand: "c", allocateTTY: false)
            .arguments.prefix(3) == ["-e", "ssh", "-T"])
        #expect(ScriptBuilder.sshInvocation(target: t, sshpassPath: "/x", command: "c", workingDirectory: nil)
            .arguments.prefix(3) == ["-e", "ssh", "-t"])
    }
}

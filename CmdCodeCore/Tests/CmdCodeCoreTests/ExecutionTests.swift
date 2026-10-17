import Foundation
import Testing
@testable import CmdCodeCore

/// 记录被打开的脚本，或者模拟打开失败。
final class FakeOpener: ScriptOpener, @unchecked Sendable {
    var opened: [URL] = []
    var openedContents: [String] = []
    var failure: (any Error)?

    func open(_ scriptURL: URL) async throws {
        if let failure { throw failure }
        opened.append(scriptURL)
        openedContents.append(try String(contentsOf: scriptURL, encoding: .utf8))
    }
}

struct FakeError: Error {}

private func makeExecutable(_ path: String) throws {
    try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

private func permissions(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
}

@Suite("sshpass 检测")
struct SSHPassLocatorTests {
    @Test func picksFirstExecutableCandidate() throws {
        let dir = try Shell.makeTempDir()
        let plain = dir + "/not-executable"
        let exec1 = dir + "/exec1"
        let exec2 = dir + "/exec2"
        try "x".write(toFile: plain, atomically: true, encoding: .utf8)
        try makeExecutable(exec1)
        try makeExecutable(exec2)

        let locator = SSHPassLocator(candidates: [dir + "/missing", plain, exec1, exec2])
        #expect(locator.locate() == exec1)
    }

    @Test func returnsNilWhenNothingFound() throws {
        let dir = try Shell.makeTempDir()
        #expect(SSHPassLocator(candidates: [dir + "/a", dir + "/b"]).locate() == nil)
    }

    @Test func defaultCandidatesMatchRequirements() {
        #expect(SSHPassLocator.defaultCandidates == ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"])
    }
}

@Suite("临时脚本")
struct TempScriptStoreTests {
    @Test func writesScriptWith700AndRandomName() throws {
        let store = TempScriptStore(directory: URL(fileURLWithPath: try Shell.makeTempDir()))
        let a = try store.write("echo a")
        let b = try store.write("echo b")

        #expect(a != b)
        #expect(a.pathExtension == "command")
        #expect(a.lastPathComponent.hasPrefix("cmdcode-"))
        #expect(try permissions(a) == 0o700)
        #expect(try String(contentsOf: a, encoding: .utf8) == "echo a")
    }

    @Test func cleanUpRemovesOnlyOurScripts() throws {
        let dir = try Shell.makeTempDir()
        let store = TempScriptStore(directory: URL(fileURLWithPath: dir))
        let ours1 = try store.write("1")
        let ours2 = try store.write("2")
        let otherCommand = dir + "/someone-else.command"
        let otherPrefix = dir + "/cmdcode-notes.txt"
        try "x".write(toFile: otherCommand, atomically: true, encoding: .utf8)
        try "x".write(toFile: otherPrefix, atomically: true, encoding: .utf8)

        #expect(store.cleanUpLeftovers() == 2)
        #expect(!FileManager.default.fileExists(atPath: ours1.path))
        #expect(!FileManager.default.fileExists(atPath: ours2.path))
        #expect(FileManager.default.fileExists(atPath: otherCommand))
        #expect(FileManager.default.fileExists(atPath: otherPrefix))
    }
}

@Suite("CommandRunner")
struct CommandRunnerTests {
    let target = SSHTarget(host: "10.0.144.232", username: "root", password: "secret'pw")

    private func makeRunner(opener: FakeOpener, sshpassExists: Bool = true) throws -> (CommandRunner, String) {
        let dir = try Shell.makeTempDir()
        let sshpass = dir + "/sshpass"
        if sshpassExists { try makeExecutable(sshpass) }
        let runner = CommandRunner(
            locator: SSHPassLocator(candidates: [sshpass]),
            store: TempScriptStore(directory: URL(fileURLWithPath: dir)),
            opener: opener)
        return (runner, sshpass)
    }

    @Test func writesScriptAndOpensIt() async throws {
        let opener = FakeOpener()
        let (runner, sshpass) = try makeRunner(opener: opener)
        let url = try await runner.run(target: target, command: "./build.sh", workingDirectory: "/usr/local/app/lims")

        #expect(opener.opened == [url])
        let expected = ScriptBuilder.localScript(target: target, sshpassPath: sshpass,
                                                 command: "./build.sh", workingDirectory: "/usr/local/app/lims")
        #expect(opener.openedContents == [expected])
        #expect(try permissions(url) == 0o700)
    }

    @Test func failsWithoutSshpassAndWritesNothing() async throws {
        let opener = FakeOpener()
        let (runner, _) = try makeRunner(opener: opener, sshpassExists: false)
        await #expect(throws: CommandRunnerError.sshpassNotFound) {
            try await runner.run(target: target, command: "ls", workingDirectory: nil)
        }
        #expect(opener.opened.isEmpty)
        #expect(runner.store.cleanUpLeftovers() == 0)
        #expect(CommandRunnerError.sshpassNotFound.errorDescription == "请先执行 `brew install sshpass`")
    }

    @Test func removesScriptWhenOpenFails() async throws {
        let opener = FakeOpener()
        opener.failure = FakeError()
        let (runner, _) = try makeRunner(opener: opener)
        await #expect(throws: FakeError.self) {
            try await runner.run(target: target, command: "ls", workingDirectory: nil)
        }
        #expect(runner.store.cleanUpLeftovers() == 0)
    }

    @Test func testConnectionRunsWhoamiAndPwd() async throws {
        let opener = FakeOpener()
        let (runner, sshpass) = try makeRunner(opener: opener)
        try await runner.testConnection(target: target, workingDirectory: "/opt/app")
        let expected = ScriptBuilder.localScript(target: target, sshpassPath: sshpass,
                                                 command: "whoami && pwd", workingDirectory: "/opt/app")
        #expect(opener.openedContents == [expected])
    }
}

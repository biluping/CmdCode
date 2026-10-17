import Foundation
import Testing
@testable import CmdCodeCore

private func makeExecutable(_ path: String) throws {
    try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
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

@Suite("CommandRunner")
struct CommandRunnerTests {
    let plan = ExecutionPlan(
        target: SSHTarget(host: "10.0.144.232", port: 2233, username: "root", password: "secret'pw"),
        command: "./build.sh", workingDirectory: "/usr/local/app/lims",
        requiresConfirmation: false, serverName: "232", commandName: "构建")

    @Test func buildsInvocationWithLocatedSshpass() throws {
        let dir = try Shell.makeTempDir()
        let sshpass = dir + "/sshpass"
        try makeExecutable(sshpass)
        let runner = CommandRunner(locator: SSHPassLocator(candidates: [sshpass]))

        let invocation = try runner.invocation(for: plan)
        #expect(invocation == ScriptBuilder.sshInvocation(
            target: plan.target, sshpassPath: sshpass, command: "./build.sh", workingDirectory: "/usr/local/app/lims"))
    }

    @Test func failsWithoutSshpass() throws {
        let dir = try Shell.makeTempDir()
        let runner = CommandRunner(locator: SSHPassLocator(candidates: [dir + "/sshpass"]))
        #expect(throws: CommandRunnerError.sshpassNotFound) { try runner.invocation(for: plan) }
        #expect(CommandRunnerError.sshpassNotFound.errorDescription == "请先执行 `brew install sshpass`")
    }
}

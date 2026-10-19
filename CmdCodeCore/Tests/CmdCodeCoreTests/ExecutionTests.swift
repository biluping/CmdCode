import Foundation
import Testing
@testable import CmdCodeCore

@Suite("askpass")
struct AskPassTests {
    @Test("准备目录和脚本：权限 0700，被改过的内容和权限会恢复")
    func preparesScript() throws {
        let dir = try Shell.makeTempDir() + "/rt"
        let path = try AskPass.prepare(in: dir)
        #expect(path == dir + "/askpass")
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(fm.contents(atPath: path) == Data(AskPass.script.utf8))

        try "#!/bin/sh\necho hacked\n".write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        try AskPass.prepare(in: dir)
        #expect(fm.contents(atPath: path) == Data(AskPass.script.utf8))
        #expect((try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try fm.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("脚本只回答密码提示，原样输出特殊字符；私钥口令等其他提示返回失败")
    func scriptAnswersPasswordPrompts() throws {
        let base = try Shell.makeTempDir()
        let path = try AskPass.prepare(in: base + "/rt")
        let password = #"p@ss'w"o$rd `x` $(y) \ %s 中文"#
        let env = Shell.cleanEnv(home: base).merging(AskPass.environment(scriptPath: path, password: password)) { $1 }
        for prompt in ["root@10.0.144.232's password: ", "Password: ", "(root@h) Password:"] {
            let r = try Shell.run(path, [prompt], cwd: base, env: env)
            #expect(r.stdout == password + "\n")
            #expect(r.status == 0)
        }
        let key = try Shell.run(path, ["Enter passphrase for key '/Users/u/.ssh/id_rsa': "], cwd: base, env: env)
        #expect(key.stdout.isEmpty)
        #expect(key.status != 0)
    }

    @Test func environment() {
        #expect(AskPass.environment(scriptPath: "/a", password: "p")
                == ["SSH_ASKPASS": "/a", "SSH_ASKPASS_REQUIRE": "force", "CMDCODE_SSH_PASSWORD": "p"])
    }
}

@Suite("CommandRunner")
struct CommandRunnerTests {
    let plan = ExecutionPlan(
        target: SSHTarget(host: "10.0.144.232", port: 2233, username: "root", password: "secret'pw"),
        command: "./build.sh", workingDirectory: "/usr/local/app/lims",
        requiresConfirmation: false, serverName: "232", commandName: "构建")

    @Test("用系统 ssh，并准备好 askpass 脚本")
    func buildsInvocationWithAskPass() throws {
        let dir = try Shell.makeTempDir() + "/rt"
        let invocation = try CommandRunner(askPassDirectory: dir).invocation(for: plan)
        #expect(invocation == ScriptBuilder.sshInvocation(
            target: plan.target, askPassPath: dir + "/askpass",
            command: "./build.sh", workingDirectory: "/usr/local/app/lims"))
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(FileManager.default.isExecutableFile(atPath: dir + "/askpass"))
    }
}

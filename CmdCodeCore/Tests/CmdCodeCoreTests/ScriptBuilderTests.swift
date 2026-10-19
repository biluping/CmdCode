import Foundation
import Testing
@testable import CmdCodeCore

struct RoundTripCase: CustomTestStringConvertible, Sendable {
    var name: String
    var command: String
    /// 相对于测试临时目录的工作目录；nil 表示不配置。
    var workingDirectory: String? = nil

    var testDescription: String { name }
}

let roundTripCases: [RoundTripCase] = [
    .init(name: "单引号", command: #"echo 'it'\''s' "a'b" 'x'"#),
    .init(name: "双引号", command: #"echo "he said \"hi\"" '"single-wrapped"'"#),
    .init(name: "美元符", command: #"X=5; echo $X "$X" '$X' \$X ${X}0; echo "${X:-d}""#),
    .init(name: "命令替换", command: #"echo "$(echo nested $(echo deeper))" '$(not run)'"#),
    .init(name: "反引号", command: "echo `echo back` \"`echo dq`\" '`no`'"),
    .init(name: "heredoc", command: """
        cat <<'EOF'
        $NOT_EXPANDED 'q' "d" `no` $(no)
        EOF
        cat <<EOF
        expanded $((1+2)) "quoted"
        EOF
        """),
    .init(name: "heredoc 结尾无换行", command: "cat <<EOF\nend\nEOF"),
    .init(name: "中文", command: "echo 你好，世界 && echo '中文 引号' \"双引号中文\""),
    .init(name: "含空格的工作目录", command: "pwd; ls", workingDirectory: "dir with spaces"),
    .init(name: "含单引号和美元符的工作目录", command: "pwd", workingDirectory: "it's $HOME dir"),
    .init(name: "中文工作目录", command: "pwd", workingDirectory: "工作 目录"),
    .init(name: "末尾无换行", command: "echo a"),
    .init(name: "末尾多个换行", command: "echo a\n\n\n"),
    .init(name: "空行", command: "echo a\n\n\necho b\n"),
    .init(name: "多行与退出码", command: "echo one\necho two\nexit 3"),
    .init(name: "反斜杠与特殊字符", command: #"printf '%s\n' 'a\tb' "c\\d" 'e!f' '#hash' "semi;colon" 'p|q&r<>'"#),
    .init(name: "多行带工作目录", command: "echo first\npwd\necho last", workingDirectory: "w"),
]

@Suite("ScriptBuilder")
struct ScriptBuilderTests {

    // MARK: shq

    @Test("shq 经 bash 解析后还原原字符串", arguments: [
        "", "plain", "a b", "it's", "''", "a'b'c", #"$HOME `x` $(y) "z" \n \\"#, "中文 '引号'", "line1\nline2", "!",
    ])
    func shqRoundTrip(_ s: String) throws {
        let dir = try Shell.makeTempDir()
        let r = try Shell.run("/bin/bash", ["-c", "printf %s \(ScriptBuilder.shq(s))"],
                              cwd: dir, env: Shell.cleanEnv(home: dir))
        #expect(r.status == 0)
        #expect(r.stdout == s)
    }

    // MARK: 内层脚本 / 远端命令

    @Test func innerScriptWithoutWorkingDirectory() {
        #expect(ScriptBuilder.innerScript(command: "ls", workingDirectory: nil) == "ls")
        #expect(ScriptBuilder.innerScript(command: "ls", workingDirectory: "  ") == "ls")
    }

    @Test func innerScriptWithWorkingDirectory() {
        #expect(ScriptBuilder.innerScript(command: "a\nb", workingDirectory: "/usr/local/app")
                == "cd -- '/usr/local/app' || exit 1\na\nb")
    }

    @Test func remoteCommandOnlyContainsSafeCharacters() {
        let remote = ScriptBuilder.remoteCommand(command: #"echo '"$(x)"' `y`"#, workingDirectory: "/it's")
        let prefix = #"bash -lc "$(printf %s "#
        let suffix = #" | base64 -d)""#
        #expect(remote.hasPrefix(prefix))
        #expect(remote.hasSuffix(suffix))
        let payload = remote.dropFirst(prefix.count).dropLast(suffix.count)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        #expect(payload.unicodeScalars.allSatisfy(allowed.contains))
        #expect(!remote.contains("'"))
    }

    // MARK: 往返测试：用本地 bash -c 代替 ssh

    @Test("生成的远端命令与直接执行结果一致", arguments: roundTripCases)
    func roundTrip(_ c: RoundTripCase) throws {
        let base = try Shell.makeTempDir()
        let home = base + "/home"
        let elsewhere = base + "/elsewhere"
        try Shell.mkdir(home)
        try Shell.mkdir(elsewhere)
        let env = Shell.cleanEnv(home: home)

        var directCwd = base + "/run"
        var workingDirectory: String?
        if let rel = c.workingDirectory {
            directCwd = base + "/" + rel
            workingDirectory = directCwd
            try Shell.mkdir(directCwd)
            try Data().write(to: URL(fileURLWithPath: directCwd + "/file.txt"))
        } else {
            try Shell.mkdir(directCwd)
        }

        let expected = try Shell.run("/bin/bash", ["-c", c.command], cwd: directCwd, env: env)

        let remote = ScriptBuilder.remoteCommand(command: c.command, workingDirectory: workingDirectory)
        // 有工作目录时从别的目录出发，验证 cd 生效；否则和直接执行在同一目录。
        let actual = try Shell.run("/bin/bash", ["-c", remote],
                                   cwd: workingDirectory == nil ? directCwd : elsewhere, env: env)

        #expect(actual.stdout == expected.stdout)
        #expect(actual.status == expected.status)
        #expect(actual.stderr == expected.stderr)
    }

    @Test("工作目录不存在时不执行任何一行命令")
    func missingWorkingDirectoryRunsNothing() throws {
        let base = try Shell.makeTempDir()
        let marker = base + "/marker"
        let command = "echo line1\ntouch \(ScriptBuilder.shq(marker))\necho line3"
        let remote = ScriptBuilder.remoteCommand(command: command, workingDirectory: base + "/does not exist")
        let r = try Shell.run("/bin/bash", ["-c", remote], cwd: base, env: Shell.cleanEnv(home: base))

        #expect(r.status == 1)
        #expect(r.stdout == "")
        #expect(r.stderr.contains("does not exist"))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    // MARK: 留在 shell / 登录

    /// 用一个假的登录 shell 代替远端用户的 shell，打印它在哪个目录、带了什么参数。
    private func runStayingInShell(command: String, workingDirectory: String?,
                                   shellScript: String = "echo \"SHELL $PWD $*\"") throws -> (Shell.Result, String) {
        let base = try Shell.makeTempDir()
        let work = base + "/my work"
        try Shell.mkdir(work)
        let fakeShell = base + "/fake-shell"
        try "#!/bin/bash\n\(shellScript)\n".write(toFile: fakeShell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShell)
        var env = Shell.cleanEnv(home: base)
        env["SHELL"] = fakeShell
        let remote = ScriptBuilder.remoteCommand(command: command, workingDirectory: workingDirectory.map { _ in work },
                                                 stayInShell: true)
        return (try Shell.run("/bin/bash", ["-c", remote], cwd: base, env: env), work)
    }

    @Test("登录：先 cd 到工作目录，再进入登录 shell")
    func loginEntersShell() throws {
        let (r, work) = try runStayingInShell(command: "", workingDirectory: "x")
        #expect(r.stdout == "SHELL \(work) -l\n")
        #expect(r.status == 0)
    }

    @Test("留在 shell：命令出错退出后仍进入 shell")
    func stayInShellAfterFailure() throws {
        let (r, work) = try runStayingInShell(command: "echo 'it''s'\nexit 3\necho never", workingDirectory: "x")
        #expect(r.stdout == "its\nSHELL \(work) -l\n")
    }

    @Test func innerScriptStayingInShell() {
        let tail = ScriptBuilder.reportDirectoryLine + "\n" + ScriptBuilder.loginShellLine
        #expect(ScriptBuilder.innerScript(command: "a'b", workingDirectory: nil, stayInShell: true)
                == "trap : INT\nbash -lc 'a'\\''b'\n" + tail)
        #expect(ScriptBuilder.innerScript(command: "", workingDirectory: "/d", stayInShell: true)
                == "cd -- '/d' || exit 1\n" + tail)
    }

    @Test("登录 shell 拿到的 PROMPT_COMMAND 用 OSC 7 上报当前目录，命令本身不受影响")
    func loginShellReportsDirectory() throws {
        let (r, work) = try runStayingInShell(command: "echo \"[$PROMPT_COMMAND]\"", workingDirectory: "x",
                                              shellScript: "cd \"$PWD/../my work\"; eval \"$PROMPT_COMMAND\"")
        let osc = r.stdout.components(separatedBy: "\u{1b}]7;").last?.components(separatedBy: "\u{07}").first
        #expect(r.stdout.hasPrefix("[]\n"))
        #expect(osc.flatMap(ScriptBuilder.reportedDirectory) == work)
    }

    @Test func reportedDirectory() {
        #expect(ScriptBuilder.reportedDirectory("file://web01/usr/local/my app") == "/usr/local/my app")
        #expect(ScriptBuilder.reportedDirectory("file:///root") == "/root")
        #expect(ScriptBuilder.reportedDirectory("file://h/a%20b/%E4%B8%AD") == "/a b/中")
        #expect(ScriptBuilder.reportedDirectory("file://h") == nil)
        #expect(ScriptBuilder.reportedDirectory("/tmp") == nil)
    }

    // MARK: ssh 启动参数端到端

    @Test("ssh 参数：密码只走环境变量、命令结果与直接执行一致")
    func invocationEndToEnd() throws {
        let base = try Shell.makeTempDir()
        let work = base + "/my work"
        try Shell.mkdir(work)
        let passOut = base + "/pass.out"
        let argsOut = base + "/args.out"

        // 假的 ssh：像真 ssh 一样运行 askpass 拿密码并记录下来，记录参数，
        // 然后用 bash -c 执行最后一个参数（代替远端登录 shell）。
        let fakeSSH = base + "/fake ssh"
        try """
        #!/bin/bash
        [ "$SSH_ASKPASS_REQUIRE" = force ] && "$SSH_ASKPASS" "ro'ot@10.0.144.232's password: " > "$FAKE_PASS_OUT"
        printf '%s\\n' "$@" > "$FAKE_ARGS_OUT"
        for last; do :; done
        exec /bin/bash -c "$last"

        """.write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH)
        let askPass = try AskPass.prepare(in: base + "/rt")

        let password = #"p@ss'w"o$rd `x` $(y) \ 中文"#
        let target = SSHTarget(host: "10.0.144.232", port: 2222, username: "ro'ot", password: password)
        let command = "pwd\necho \"it's $((6*7))\"\ncat <<'EOF'\n$raw\nEOF"
        let invocation = ScriptBuilder.sshInvocation(target: target, sshPath: fakeSSH, askPassPath: askPass,
                                                     command: command, workingDirectory: work)
        #expect(invocation.executable == fakeSSH)
        #expect(invocation.environment == AskPass.environment(scriptPath: askPass, password: password))
        #expect(!invocation.arguments.contains { $0.contains("p@ss") })

        var env = Shell.cleanEnv(home: base)
        env["FAKE_PASS_OUT"] = passOut
        env["FAKE_ARGS_OUT"] = argsOut
        env.merge(invocation.environment) { $1 }
        let r = try Shell.run(invocation.executable, invocation.arguments, cwd: base, env: env)

        let expected = try Shell.run("/bin/bash", ["-c", command], cwd: work, env: Shell.cleanEnv(home: base))
        #expect(r.stdout == expected.stdout)
        #expect(r.status == expected.status)
        #expect(try String(contentsOfFile: passOut, encoding: .utf8) == password + "\n")

        let args = try String(contentsOfFile: argsOut, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(args.prefix(3)) == ["-t", "-p", "2222"])
        #expect(args.contains("StrictHostKeyChecking=no"))
        #expect(args.contains("NumberOfPasswordPrompts=1"))
        // 用户名和主机是独立参数，主机前有 -- 防止被当成选项
        let l = try #require(args.firstIndex(of: "-l"))
        #expect(Array(args[l...(l + 3)]) == ["-l", "ro'ot", "--", "10.0.144.232"])
    }

    @Test("主机以 - 开头也不会被 ssh 当成选项")
    func hostIsNotParsedAsOption() {
        let inv = ScriptBuilder.sshInvocation(target: SSHTarget(host: "-oProxyCommand=x", username: "u", password: "p"),
                                              askPassPath: "/x/askpass", command: "ls", workingDirectory: nil)
        let dash = inv.arguments.firstIndex(of: "--")!
        #expect(inv.arguments[dash + 1] == "-oProxyCommand=x")
    }
}

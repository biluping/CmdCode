#if DEBUG
import AppKit
import CmdCodeCore
import SwiftData

/// 开发用：`CmdCode -snapshot <目录>` 用内存数据库和示例数据，把几个典型界面渲染成 PNG 后退出。
/// 窗口由 App 自己绘制到位图，不需要屏幕录制权限。
@MainActor
enum Snapshot {
    static var outputDirectory: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-snapshot"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    struct Seed {
        var lims232: Server
        var lims135: Server
        var build: ServerCommand
    }

    static func seed(_ lib: Library) throws -> Seed {
        let test = try lib.createCredential(CredentialDraft(name: "测试环境 root", username: "root", password: "Test@2026", note: "LIMS / ELN 测试机通用"))
        let prod = try lib.createCredential(CredentialDraft(name: "生产 deploy", username: "deploy", password: "Prod#Secret"))
        try lib.createCredential(CredentialDraft(name: "备用账号", username: "admin", password: "x"))

        let limsTest = try lib.createGroup(name: "LIMS 测试")
        let limsProd = try lib.createGroup(name: "LIMS 生产")
        let eln = try lib.createGroup(name: "ELN")

        let s232 = try lib.createServer(ServerDraft(name: "232 - lims 主服务", group: limsTest, host: "10.0.144.232", port: 2233,
                                                    credential: test, workingDirectory: "/usr/local/app/lims", note: "主测试环境，每天构建"))
        let build = try lib.createCommand(CommandDraft(name: "构建", content: "./build.sh\necho \"done at $(date)\""), on: s232)
        try lib.createCommand(CommandDraft(name: "看日志", content: "tail -f logs/lims.log", workingDirectory: "/var/log/lims"), on: s232)
        try lib.createCommand(CommandDraft(name: "重启服务", content: "systemctl restart lims && systemctl status lims"), on: s232)
        try lib.createServer(ServerDraft(name: "233 - lims 备机", group: limsTest, host: "10.0.144.233", credential: test))

        let s135 = try lib.createServer(ServerDraft(name: "135 - lims", group: limsProd, host: "10.0.144.135",
                                                    credential: prod, workingDirectory: "/opt/lims", isProduction: true))
        try lib.createCommand(CommandDraft(name: "看日志", content: "tail -f logs/lims.log"), on: s135)

        for i in 1...3 {
            try lib.createServer(ServerDraft(name: "ELN 节点 \(i)", group: eln, host: "10.0.145.\(10 + i)", credential: test))
        }
        try lib.createServer(ServerDraft(name: "跳板机", host: "10.0.0.2", credential: test))
        return Seed(lims232: s232, lims135: s135, build: build)
    }

    static func run(model: AppModel, seed: Seed, directory: String) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        window.setContentSize(NSSize(width: 1180, height: 760))

        let (filesDir, fakeSSH) = makeFileFixture()
        model.makeFileClient = { RemoteFileClient(target: $0, sshPath: fakeSSH) }
        let scenes: [(String, () -> Void)] = [
            ("01-welcome", { model.selection = nil }),
            ("02-server", {
                model.showServer(seed.lims135)
                model.showServer(seed.lims232)
            }),
            ("03-production", { model.showServer(seed.lims135) }),
            ("04-credentials", { model.selection = .credentials }),
            ("05-search-empty", { model.isSearching = true }),
            ("06-search-lims", { model.searchQuery = "lims" }),
            ("07-form-server", {
                model.isSearching = false
                model.searchQuery = ""
                model.showServer(seed.lims232)
                model.sheet = .editServer(seed.lims232)
            }),
            ("08-form-command", { model.sheet = .editCommand(seed.build) }),
            ("11-confirm", { model.pendingExecution = try? seed.build.executionPlan() }),
            ("12-confirm-production", {
                model.pendingExecution = nil
                model.pendingExecution = try? seed.lims135.sortedCommands.first?.executionPlan()
            }),
            ("13-rename-group", {
                model.pendingExecution = nil
                model.selection = nil
                model.renamingGroup = model.library.groups().first?.persistentModelID
            }),
            ("14-files", {
                model.renamingGroup = nil
                model.openFiles(seed.lims232)
                let browser = model.fileBrowser(for: seed.lims232)
                browser?.go(to: filesDir)
                browser?.read(filesDir + "/application.yml")
            }),
            ("15-files-error", {
                model.fileBrowser(for: seed.lims232)?.go(to: "/usr/local/app/不存在")
            }),
            ("16-files-reopen", {
                let browser = model.fileBrowser(for: seed.lims232)
                browser?.go(to: filesDir)
                browser?.read(filesDir + "/application.yml")
            }),
            ("16-files-dirty", {
                let browser = model.fileBrowser(for: seed.lims232)
                browser?.draft.replace("root: INFO", with: "root: WARN")
                browser?.transfer = .init(kind: .upload, name: "lims-web-2.3.1.jar", done: 9_400_000, total: 24_800_000)
            }),
            ("17-files-conflict", {
                // 模拟别人在打开之后改了文件
                try? "changed by someone\n".write(toFile: filesDir + "/application.yml", atomically: false, encoding: .utf8)
                model.fileBrowser(for: seed.lims232)?.requestSave()
            }),
            ("18-files-upload-overwrite", {
                let browser = model.fileBrowser(for: seed.lims232)
                browser?.conflictPending = false
                browser?.transfer = nil
                browser?.pendingUpload = .init(source: URL(fileURLWithPath: "/tmp/application.yml"),
                                               target: filesDir + "/application.yml", exists: true)
            }),
            ("19-files-closed", {
                let browser = model.fileBrowser(for: seed.lims232)
                browser?.pendingUpload = nil
                browser?.requestClose()
                browser?.confirmDiscard()
            }),
            ("09-toast", { model.showToast("已复制密码，60 秒后自动清除") }),
            ("10-terminal", {
                model.renamingGroup = nil
                if model.sessions.isEmpty {
                    model.open(demoSession("看日志", server: "135 - lims", production: true,
                                           script: "for i in 1 2 3; do echo \"$(date +%T) INFO  request handled in ${i}2ms\"; done; sleep 600"))
                    model.open(demoSession("重启服务", server: "232 - lims 主服务", production: false,
                                           script: "echo 'Job for lims.service failed.'; exit 3"))
                    let build = demoSession("构建", server: "232 - lims 主服务", production: false, script: buildLog)
                    build.serverID = seed.lims232.persistentModelID  // 显示“浏览文件”按钮
                    model.open(build)
                }
                model.selection = .tabs
            }),
            ("20-tabs-files", {
                model.openFiles(seed.lims232)
                let browser = model.fileBrowser(for: seed.lims232)
                browser?.read(filesDir + "/build.sh")
            }),
            ("21-tabs-files-dirty", {
                model.fileBrowser(for: seed.lims232)?.draft += "echo deployed\n"
            }),
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            for (name, apply) in scenes {
                if model.sheet != nil || (model.pendingExecution != nil && !name.hasPrefix("12")) {
                    model.sheet = nil
                    model.pendingExecution = nil
                    try? await Task.sleep(for: .milliseconds(500))
                }
                apply()
                try? await Task.sleep(for: .milliseconds(700))
                capture(window, to: "\(directory)/\(name)-\(suffix).png")
                if let sheet = window.attachedSheet {
                    capture(sheet, to: "\(directory)/\(name)-sheet-\(suffix).png")
                }
            }
            model.sheet = nil
            model.toast = nil
            // 下一轮外观重新创建终端会话
            model.hangUpAll()
            model.tabs.removeAll()
            try? await Task.sleep(for: .milliseconds(500))
        }
        model.hangUpAll()
        model.tabs.removeAll()
        NSApp.terminate(nil)
    }

    /// 远程文件页用的示例：本地临时目录 + 假的 ssh（用本地 bash 执行远端命令）。
    private static func makeFileFixture() -> (directory: String, ssh: String) {
        let fm = FileManager.default
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("cmdcode-snapshot-files")
        try? fm.removeItem(atPath: base)
        let dir = base + "/lims"
        for sub in ["conf", "logs", "lib"] { try? fm.createDirectory(atPath: dir + "/" + sub, withIntermediateDirectories: true) }
        let files: [(String, String)] = [
            ("application.yml", """
            server:
              port: 8080
              servlet:
                context-path: /lims

            spring:
              datasource:
                url: jdbc:mysql://10.0.144.135:3306/lims?useUnicode=true&characterEncoding=utf8
                username: lims
                password: ${DB_PASSWORD}
              redis:
                host: 10.0.144.232
                port: 6379

            logging:
              level:
                root: INFO
                com.lims: DEBUG   # 排查问题时临时打开

            """),
            ("build.sh", "#!/bin/bash\nset -e\ngit pull\nmvn -q package -DskipTests\n"),
            (".env", "DB_PASSWORD=change-me\n"),
            ("README.md", "# lims\n"),
        ]
        for (name, text) in files { try? text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        try? Data(count: 2_400_000).write(to: URL(fileURLWithPath: dir + "/lims.jar"))
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir + "/README.md")
        try? fm.createSymbolicLink(atPath: dir + "/current.log", withDestinationPath: "logs/lims.log")

        let fake = base + "/fake-ssh"
        try? "#!/bin/bash\nfor last; do :; done\nexec /bin/bash -c \"$last\"\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake)
        return (dir, fake)
    }

    private static func demoSession(_ command: String, server: String, production: Bool, script: String) -> TerminalSession {
        TerminalSession(serverName: server, commandName: command, isProduction: production,
                        address: "root@10.0.144.232:2233", workingDirectory: "/usr/local/app/lims", plan: nil,
                        launch: .init(executable: "/bin/bash", arguments: ["-c", script], environment: [:]))
    }

    /// 模拟一段带颜色的构建输出。
    private static let buildLog = #"""
    printf '\033[1;34m==>\033[0m 拉取代码\n'
    printf 'Already up to date.\n'
    printf '\033[1;34m==>\033[0m mvn -q package -DskipTests\n'
    for m in lims-common lims-core lims-web lims-api; do printf '[\033[32mINFO\033[0m] Building %-12s \033[2m......\033[0m \033[32mSUCCESS\033[0m\n' $m; done
    printf '[\033[33mWARN\033[0m] lims-web: 3 deprecation warnings\n'
    printf '\033[1;34m==>\033[0m 重启服务\n'
    printf 'lims.service: \033[1;32mactive (running)\033[0m since %s\n' "$(date '+%F %T')"
    printf '\033[1;32mBUILD SUCCESS\033[0m  total time 42.3s\n'
    printf 'done at %s\n' "$(date)"
    sleep 600
    """#

    private static func capture(_ window: NSWindow, to path: String) {
        // 取 contentView 的父视图，带上隐藏标题栏后的红黄绿按钮。
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif

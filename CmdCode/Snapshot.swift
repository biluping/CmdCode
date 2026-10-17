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
        try lib.createCommand(CommandDraft(name: "重启服务", content: "systemctl restart lims && systemctl status lims", confirmBeforeRun: true), on: s232)
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
            ("09-toast", { model.showToast("已复制密码，60 秒后自动清除") }),
            ("10-terminal", {
                if model.sessions.isEmpty {
                    model.open(demoSession("看日志", server: "135 - lims", production: true,
                                           script: "for i in 1 2 3; do echo \"$(date +%T) INFO  request handled in ${i}2ms\"; done; sleep 600"))
                    model.open(demoSession("重启服务", server: "232 - lims 主服务", production: false,
                                           script: "echo 'Job for lims.service failed.'; exit 3"))
                    model.open(demoSession("构建", server: "232 - lims 主服务", production: false, script: buildLog))
                }
                model.selection = .terminal
            }),
        ]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            for (name, apply) in scenes {
                if model.sheet != nil {
                    model.sheet = nil
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
            model.sessions.removeAll()
            try? await Task.sleep(for: .milliseconds(500))
        }
        model.hangUpAll()
        model.sessions.removeAll()
        NSApp.terminate(nil)
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

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
            ("09-toast", { model.showToast("已在终端中打开 · 232 - lims 主服务 / 构建") }),
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
            try? await Task.sleep(for: .milliseconds(500))
        }
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, to path: String) {
        // 取 contentView 的父视图，带上隐藏标题栏后的红黄绿按钮。
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif

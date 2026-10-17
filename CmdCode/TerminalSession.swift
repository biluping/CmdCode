import AppKit
import CmdCodeCore
import Foundation
import Observation
import SwiftTerm

/// 一次命令执行：一个伪终端里的 ssh 进程，以及显示它的终端视图。
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        /// 退出码；被信号结束时为 nil。
        case exited(Int32?)
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    struct Launch {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    let id = UUID()
    let serverName: String
    let commandName: String
    let isProduction: Bool
    /// 状态栏显示的连接信息，比如 root@10.0.144.232:2233。
    let address: String
    let workingDirectory: String?
    /// 重新运行时使用；预览用的会话没有。
    let plan: ExecutionPlan?

    private(set) var state: State = .running
    private(set) var startedAt = Date()
    private(set) var endedAt: Date?

    @ObservationIgnored let view: CmdTerminalView
    @ObservationIgnored private let launch: Launch
    @ObservationIgnored private var delegate: Delegate?

    var title: String { "\(serverName) / \(commandName)" }

    init(serverName: String, commandName: String, isProduction: Bool, address: String,
         workingDirectory: String?, plan: ExecutionPlan?, launch: Launch) {
        self.serverName = serverName
        self.commandName = commandName
        self.isProduction = isProduction
        self.address = address
        self.workingDirectory = workingDirectory
        self.plan = plan
        self.launch = launch
        self.view = CmdTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    }

    /// 从执行计划创建：会话标题取 “服务器 / 命令”。
    convenience init(plan: ExecutionPlan, invocation: SSHInvocation) {
        self.init(serverName: plan.serverName, commandName: plan.commandName, isProduction: plan.isProduction,
                  address: "\(plan.target.username)@\(plan.target.host):\(plan.target.port)",
                  workingDirectory: plan.workingDirectory, plan: plan,
                  launch: Launch(executable: invocation.executable, arguments: invocation.arguments,
                                 environment: invocation.environment))
    }

    func start() {
        let delegate = Delegate(session: self)
        self.delegate = delegate
        view.processDelegate = delegate
        startedAt = Date()
        // sshpass 通过 PATH 找 ssh；终端默认环境里不带 PATH，这里补上系统路径。
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        env += launch.environment.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: env)
    }

    /// 结束会话：给整个进程组发 SIGHUP，和关闭终端窗口的效果一样，远端前台进程随之结束。
    func hangUp() {
        guard state.isRunning, let process = view.process else { return }
        let pid = process.shellPid
        if pid > 0 { kill(-pid, SIGHUP) }
        process.terminate()
    }

    /// 发送 Ctrl-C。
    func interrupt() {
        guard state.isRunning else { return }
        view.send([0x03])
    }

    fileprivate func finish(_ newState: State) {
        guard state.isRunning else { return }
        state = newState
        endedAt = Date()
        let note: String
        switch newState {
        case .exited(let code?): note = "已结束 · 退出码 \(code)"
        case .exited(nil): note = "已结束"
        case .failed(let message): note = "启动失败：\(message)"
        case .running: return
        }
        view.feed(text: "\r\n\u{1b}[2m[\(note)]\u{1b}[0m\r\n")
    }

    private final class Delegate: LocalProcessTerminalViewDelegate {
        weak var session: TerminalSession?

        init(session: TerminalSession) {
            self.session = session
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            session?.finish(.exited(exitCode))
        }

        func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            session?.finish(.failed("\(error)"))
        }
    }
}

/// 外观跟随应用浅色/深色模式的终端视图。
final class CmdTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        optionAsMetaKey = true
        // 不画系统的焦点框，终端区域本身就是焦点所在。
        focusRingType = .none
        applyPalette()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    /// 切换标签时视图会离开再回到窗口，期间外观可能已经变了，回来时重新套用配色。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPalette()
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var appliedDark: Bool?

    private func applyPalette() {
        let dark = isDark
        guard dark != appliedDark else { return }
        appliedDark = dark
        let palette = dark ? TerminalPalette.dark : TerminalPalette.light
        nativeBackgroundColor = palette.background
        nativeForegroundColor = palette.foreground
        caretColor = palette.caret
        selectedTextBackgroundColor = palette.selection
        installColors(palette.ansi.map(Self.color))
        needsDisplay = true
    }

    private static func color(_ hex: UInt32) -> SwiftTerm.Color {
        func channel(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) * 257 }
        return SwiftTerm.Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}

/// 终端配色：16 色 ANSI 调色板，浅色背景下也保证黄色、白色等可读。
private struct TerminalPalette {
    var background: NSColor
    var foreground: NSColor
    var caret: NSColor
    var selection: NSColor
    var ansi: [UInt32]

    static let light = TerminalPalette(
        background: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        foreground: NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1),
        caret: .controlAccentColor,
        selection: NSColor.controlAccentColor.withAlphaComponent(0.2),
        ansi: [
            0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0550AE, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x1A7F37, 0x9A6700, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
        ])

    static let dark = TerminalPalette(
        background: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        foreground: NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        caret: .controlAccentColor,
        selection: NSColor.controlAccentColor.withAlphaComponent(0.35),
        ansi: [
            0x1E1E1E, 0xF14C4C, 0x23D18B, 0xE5E510, 0x3B8EEA, 0xBC3FBC, 0x29B8DB, 0xCCCCCC,
            0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
        ])
}

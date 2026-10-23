import AppKit
import CmdCodeCore
import Foundation
import Observation
import SwiftData
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
    /// 所属服务器，终端右键“浏览文件”用；预览用的会话没有。
    @ObservationIgnored var serverID: PersistentIdentifier?
    /// 远端 shell 最近一次上报的当前目录（OSC 7，见 `ScriptBuilder.reportDirectoryLine`）。
    @ObservationIgnored private(set) var currentDirectory: String?

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
        // 终端默认环境里不带 PATH，askpass 脚本要用到基本命令，这里补上系统路径。
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
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            session?.currentDirectory = directory.flatMap(ScriptBuilder.reportedDirectory)
        }

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
    /// 右键菜单的“浏览文件”；为 nil 时不显示这一项。
    var onBrowseFiles: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        optionAsMetaKey = true
        // 不画系统的焦点框，终端区域本身就是焦点所在。
        focusRingType = .none
        setCursorStyle(.steadyBlock)
        // SwiftTerm 默认只留 500 行回滚，日志一多往上翻很快就到顶。
        changeScrollback(Self.scrollbackLines)
        applyPalette()
    }

    /// 终端回滚保留的行数。
    static let scrollbackLines = 10_000

    /// 光标一律不闪烁：闪烁是无限循环的 CoreAnimation 动画，全屏时终端内容要等它才上屏，
    /// 每次按键延迟 150–300ms。远端程序（如 vim）要求闪烁样式时，换成同形状的不闪烁样式。
    override nonisolated func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let steady: CursorStyle = switch newStyle {
        case .blinkBlock, .steadyBlock: .steadyBlock
        case .blinkUnderline, .steadyUnderline: .steadyUnderline
        case .blinkBar, .steadyBar: .steadyBar
        }
        super.cursorStyleChanged(source: source, newStyle: steady)
    }

    /// 右键菜单：复制、粘贴、浏览文件。远端程序开了鼠标上报（如 vim、htop）时右键交给它，不弹菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // 不要系统的“服务”子菜单。
        menu.allowsContextMenuPlugIns = false
        let copy = menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = getSelection()?.isEmpty == false
        menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "v").target = self
        if onBrowseFiles != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: "浏览文件", action: #selector(browseFiles), keyEquivalent: "").target = self
        }
        menu.items.forEach { $0.tag = Self.ownMenuItemTag }
        return menu
    }

    private static let ownMenuItemTag = 0x434D44

    /// 终端视图实现了文字输入协议，系统会往右键菜单里加“自动填充”等项，弹出前把不是自己加的都去掉。
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items.reversed() where item.tag != Self.ownMenuItemTag {
            menu.removeItem(item)
        }
    }

    @objc private func browseFiles() {
        onBrowseFiles?()
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

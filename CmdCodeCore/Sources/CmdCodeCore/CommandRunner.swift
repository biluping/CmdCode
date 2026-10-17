import AppKit
import Foundation

/// 把脚本交给某个程序打开。抽成协议是为了测试时不真的弹出终端。
public protocol ScriptOpener: Sendable {
    func open(_ scriptURL: URL) async throws
}

/// 用系统自带的 Terminal.app 打开脚本（等同于 `open -a Terminal <脚本>`），不需要自动化授权。
public struct TerminalOpener: ScriptOpener {
    public static let bundleIdentifier = "com.apple.Terminal"

    public init() {}

    public func open(_ scriptURL: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw CommandRunnerError.terminalNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([scriptURL], withApplicationAt: terminal, configuration: configuration)
    }
}

public enum CommandRunnerError: Error, Equatable, LocalizedError {
    case sshpassNotFound
    case terminalNotFound

    public var errorDescription: String? {
        switch self {
        case .sshpassNotFound: SSHPassLocator.installHint
        case .terminalNotFound: "找不到系统自带的“终端”应用"
        }
    }
}

/// 执行入口：生成脚本 → 写入临时目录 → 交给终端打开。
public struct CommandRunner: Sendable {
    public var locator: SSHPassLocator
    public var store: TempScriptStore
    public var opener: any ScriptOpener

    public init(
        locator: SSHPassLocator = SSHPassLocator(),
        store: TempScriptStore = TempScriptStore(),
        opener: any ScriptOpener = TerminalOpener()
    ) {
        self.locator = locator
        self.store = store
        self.opener = opener
    }

    /// 在终端里执行一条命令。返回写出的脚本路径（脚本启动后会自己删除）。
    @discardableResult
    public func run(target: SSHTarget, command: String, workingDirectory: String?) async throws -> URL {
        guard let sshpass = locator.locate() else { throw CommandRunnerError.sshpassNotFound }
        let script = ScriptBuilder.localScript(
            target: target, sshpassPath: sshpass, command: command, workingDirectory: workingDirectory)
        let url = try store.write(script)
        do {
            try await opener.open(url)
        } catch {
            // 终端没打开，脚本不会自删，这里删掉，密码不留在磁盘上。
            store.remove(url)
            throw error
        }
        return url
    }

    /// 测试连接：和执行命令走同一套流程。
    @discardableResult
    public func testConnection(target: SSHTarget, workingDirectory: String?) async throws -> URL {
        try await run(target: target, command: ScriptBuilder.testConnectionCommand(),
                      workingDirectory: workingDirectory)
    }
}

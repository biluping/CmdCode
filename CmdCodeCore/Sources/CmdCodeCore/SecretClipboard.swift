import AppKit

/// 复制密码到剪贴板，一段时间后自动清除。
///
/// 只有剪贴板内容还是我们复制的那份时才清除：用户在这期间复制了别的东西，就不去动它。
@MainActor
public final class SecretClipboard {
    public static let defaultClearDelay: Duration = .seconds(60)
    /// 约定俗成的类型，告诉剪贴板管理器这是隐私内容，不要记录到历史里。
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard
    private let clearDelay: Duration
    private var clearTask: Task<Void, Never>?

    public init(pasteboard: NSPasteboard = .general, clearDelay: Duration = SecretClipboard.defaultClearDelay) {
        self.pasteboard = pasteboard
        self.clearDelay = clearDelay
    }

    public func copy(_ secret: String) {
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
        let ours = pasteboard.changeCount

        clearTask?.cancel()
        clearTask = Task { [weak self, clearDelay] in
            try? await Task.sleep(for: clearDelay)
            guard !Task.isCancelled, let self else { return }
            if self.pasteboard.changeCount == ours {
                self.pasteboard.clearContents()
            }
        }
    }
}

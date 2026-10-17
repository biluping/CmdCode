import AppKit
import Testing
@testable import CmdCodeCore

@MainActor
@Suite("剪贴板自动清除")
struct SecretClipboardTests {
    /// 每个测试用独立的剪贴板，不碰系统剪贴板。
    let pasteboard = NSPasteboard.withUniqueName()

    @Test func defaultDelayIs60Seconds() {
        #expect(SecretClipboard.defaultClearDelay == .seconds(60))
    }

    @Test("复制后到时间自动清除")
    func clearsAfterDelay() async throws {
        let clipboard = SecretClipboard(pasteboard: pasteboard, clearDelay: .milliseconds(200))
        clipboard.copy("p@ss")
        #expect(pasteboard.string(forType: .string) == "p@ss")
        #expect(pasteboard.types?.contains(SecretClipboard.concealedType) == true)

        try await Task.sleep(for: .milliseconds(600))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("期间用户复制了别的内容就不清除")
    func keepsOtherContent() async throws {
        let clipboard = SecretClipboard(pasteboard: pasteboard, clearDelay: .milliseconds(200))
        clipboard.copy("p@ss")
        pasteboard.clearContents()
        pasteboard.setString("别的内容", forType: .string)

        try await Task.sleep(for: .milliseconds(600))
        #expect(pasteboard.string(forType: .string) == "别的内容")
    }

    @Test("再次复制重新计时")
    func copyAgainRestartsTimer() async throws {
        let clipboard = SecretClipboard(pasteboard: pasteboard, clearDelay: .milliseconds(400))
        clipboard.copy("first")
        try await Task.sleep(for: .milliseconds(250))
        clipboard.copy("second")
        try await Task.sleep(for: .milliseconds(250))
        #expect(pasteboard.string(forType: .string) == "second")

        try await Task.sleep(for: .milliseconds(500))
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

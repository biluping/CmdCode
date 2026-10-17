import Foundation

/// 查找 sshpass 的绝对路径，写进脚本里，避免终端里的 PATH 不一致。
public struct SSHPassLocator: Sendable {
    public static let defaultCandidates = ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]
    public static let installHint = "请先执行 `brew install sshpass`"

    public var candidates: [String]

    public init(candidates: [String] = SSHPassLocator.defaultCandidates) {
        self.candidates = candidates
    }

    /// 返回第一个存在且可执行的路径；都没有则返回 nil。
    public func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

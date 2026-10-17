import Foundation

/// 在临时目录里写 `.command` 脚本，并在启动时清理遗留脚本。
public struct TempScriptStore: Sendable {
    public static let filePrefix = "cmdcode-"
    public static let fileExtension = "command"

    public var directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    /// 写入脚本，文件名带随机串，权限 700。
    ///
    /// 用 `open(O_CREAT | O_EXCL, 0700)` 一步创建，文件从诞生起就只有当前用户可读，
    /// 不存在先写内容再改权限的时间窗口。
    public func write(_ script: String) throws -> URL {
        let url = directory.appendingPathComponent(
            "\(Self.filePrefix)\(UUID().uuidString).\(Self.fileExtension)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o700)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(script.utf8))
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        // umask 可能去掉了部分权限位，这里再确认一次。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 删除遗留的脚本（比如终端没能成功打开时），返回删除的个数。
    @discardableResult
    public func cleanUpLeftovers() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(Self.filePrefix) && name.hasSuffix("." + Self.fileExtension) {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }
}

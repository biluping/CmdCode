import CmdCodeCore
import Foundation
import Observation
import SwiftData

/// 服务器间发送文件的目标服务器（由 `AppModel.sendTargets` 生成）。
struct FileSendTarget: Identifiable {
    let serverID: PersistentIdentifier
    let serverName: String
    let isProduction: Bool
    let client: RemoteFileClient
    /// 默认目标目录；空表示登录用户的家目录。
    var directory: String

    var id: PersistentIdentifier { serverID }
}

/// 一台服务器的远程文件标签：当前目录、正在查看的文件、上传下载。切换到别的标签再回来时保留。
@MainActor
@Observable
final class FileBrowserModel: Identifiable {
    let id = UUID()
    let serverID: PersistentIdentifier
    /// 每次进入文件页时按服务器当前的凭据重新生成，改了密码也能用。
    var client: RemoteFileClient
    let serverName: String
    /// 生产环境服务器保存前要确认。同样每次进入文件页时刷新。
    var isProduction: Bool
    /// 首次打开的目录：服务器的工作目录，没配置就是登录用户的家目录（nil）。
    let initialDirectory: String?

    private(set) var listing: RemoteDirectoryListing?
    private(set) var isListing = false
    private(set) var listError: String?
    /// 路径栏里的文字，可以编辑后回车跳转。
    var pathInput = ""

    private(set) var openedPath: String?
    private(set) var content: RemoteFileContent?
    private(set) var isReading = false
    private(set) var readError: String?

    /// 编辑器里的文字；和 `content.text` 不同就是有未保存的修改。
    var draft = ""
    private(set) var isSaving = false
    var saveError: String?
    /// 保存时发现文件在打开后被别人改过，等用户决定覆盖还是重新载入。
    var conflictPending = false
    /// 生产环境：等用户确认保存。
    var productionSavePending = false
    /// 有未保存的修改时要做的动作，等用户确认放弃修改。
    var pendingDiscard: DiscardAction?
    /// 保存成功等提示（由 AppModel 接到底部提示条）。
    @ObservationIgnored var notify: (String) -> Void = { _ in }
    /// 往别的服务器（或本服务器另一个目录）写了文件之后通知 AppModel，让显示那个目录的文件标签刷新。
    @ObservationIgnored var remoteChanged: (PersistentIdentifier, String) -> Void = { _, _ in }

    /// 正在进行的上传或下载，同一时间只有一个。
    var transfer: Transfer?
    /// 上传前要用户确认（覆盖已有文件、生产环境）。
    var pendingUpload: PendingUpload?
    var transferError: (title: String, message: String)?
    /// 等用户确认删除的文件路径。
    var pendingDelete: String?
    var deleteError: String?

    struct Transfer {
        enum Kind {
            case upload, download
            /// 发到另一台服务器：先下载到本机临时文件，再上传过去。
            case send(to: String)
        }
        var kind: Kind
        var name: String
        var done: Int64 = 0
        var total: Int64
        /// 发送时：已经下载完、正在上传。
        var sending = false

        /// “正在上传 a.txt”这样的说明。
        var description: String {
            switch kind {
            case .upload: "正在上传 \(name)"
            case .download: "正在下载 \(name)"
            case .send(let server): "正在把 \(name) 发到 \(server)（\(sending ? "第 2 步，上传" : "第 1 步，下载到本机")）"
            }
        }
    }

    /// 发送前要用户确认（覆盖已有文件、目标是生产环境）。
    struct PendingSend {
        var source: String
        var target: FileSendTarget
        /// 目标的绝对路径。
        var targetPath: String
        var exists: Bool
    }

    struct PendingUpload {
        var source: URL
        var target: String
        var exists: Bool
    }

    enum DiscardAction {
        case open(String)
        case reload
        case close
    }

    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var transferTask: Task<Void, Never>?

    init(client: RemoteFileClient, serverID: PersistentIdentifier, serverName: String, isProduction: Bool,
         initialDirectory: String?) {
        self.client = client
        self.serverID = serverID
        self.serverName = serverName
        self.isProduction = isProduction
        self.initialDirectory = initialDirectory
        pathInput = initialDirectory ?? "~"
    }

    /// 第一次显示时加载初始目录。
    func start() {
        if listing == nil && !isListing && listError == nil { go(to: initialDirectory) }
    }

    /// 打开目录；nil 表示家目录。后发起的请求会让先前未完成的结果作废。
    func go(to directory: String?) {
        listTask?.cancel()
        isListing = true
        listError = nil
        let client = client
        listTask = Task {
            do {
                let result = try await client.list(directory: directory)
                guard !Task.isCancelled else { return }
                listing = result
                pathInput = result.path
            } catch {
                guard !Task.isCancelled else { return }
                listError = Self.message(error)
                // 路径栏保留出错的路径，方便改了再试。
                pathInput = directory ?? "~"
            }
            isListing = false
        }
    }

    /// 路径栏回车：`~` 或留空表示家目录。
    func goToInput() {
        let path = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        go(to: path.isEmpty || path == "~" ? nil : path)
    }

    func goUp() {
        guard let path = listing?.path, let parent = RemoteFileScript.parent(of: path) else { return }
        go(to: parent)
    }

    var canGoUp: Bool {
        listing.map { RemoteFileScript.parent(of: $0.path) != nil } ?? false
    }

    /// 刷新目录；打开的文件没改过就一起重新读，改过就保留编辑内容。
    func refresh() {
        go(to: listing?.path ?? initialDirectory)
        if let openedPath, !isDirty { read(openedPath) }
    }

    /// 点了列表里的条目：目录进入，文件打开查看。
    func open(_ entry: RemoteFileEntry) {
        guard let dir = listing?.path else { return }
        let path = RemoteFileScript.join(dir, entry.name)
        switch entry.kind {
        case .directory: go(to: path)
        case .file: requestOpen(path)
        case .other: break
        }
    }

    // MARK: 编辑与保存

    var isDirty: Bool {
        guard let text = content?.text else { return false }
        return draft != text
    }

    /// 能编辑：是文本文件且有写权限。
    var isEditable: Bool {
        content.map { $0.isWritable && $0.text != nil } ?? false
    }

    /// 打开另一个文件；当前文件有未保存的修改时先确认。
    func requestOpen(_ path: String) {
        guard path != openedPath || content == nil else { return }
        if isDirty { pendingDiscard = .open(path) } else { read(path) }
    }

    /// 从服务器重新载入当前文件；有未保存的修改时先确认。
    func requestReload() {
        guard openedPath != nil else { return }
        if isDirty { pendingDiscard = .reload } else if let openedPath { read(openedPath) }
    }

    func confirmDiscard() {
        guard let action = pendingDiscard else { return }
        pendingDiscard = nil
        switch action {
        case .open(let path): read(path)
        case .reload: if let openedPath { read(openedPath) }
        case .close: close()
        }
    }

    /// 关闭当前文件；有未保存的修改时先确认放弃。
    func requestClose() {
        guard openedPath != nil, !isSaving else { return }
        if isDirty { pendingDiscard = .close } else { close() }
    }

    private func close() {
        readTask?.cancel()
        openedPath = nil
        content = nil
        draft = ""
        readError = nil
        isReading = false
    }

    /// 撤销所有修改，回到打开时的内容。
    func revert() {
        if let text = content?.text { draft = text }
    }

    /// 保存（⌘S）。生产环境服务器先确认。
    func requestSave() {
        guard isEditable, isDirty, !isSaving else { return }
        if isProduction { productionSavePending = true } else { save() }
    }

    /// 写回服务器。`force` 为 true 时不检查冲突，直接覆盖。
    func save(force: Bool = false) {
        guard let content, isEditable, !isSaving else { return }
        let data = Data(draft.utf8)
        let path = content.path
        let expected = force ? nil : content.checksum
        isSaving = true
        saveError = nil
        let client = client
        Task {
            do {
                let checksum = try await client.write(data, to: path, expectedChecksum: expected)
                if openedPath == path {
                    self.content = RemoteFileContent(path: path, data: data, checksum: checksum, isWritable: true)
                }
                notify("已保存 \((path as NSString).lastPathComponent)")
                // 大小、修改时间变了，刷新一下列表。
                if let dir = listing?.path, (path as NSString).deletingLastPathComponent == dir { go(to: dir) }
            } catch RemoteFileError.conflict {
                conflictPending = true
            } catch {
                saveError = Self.message(error)
            }
            isSaving = false
        }
    }

    /// 冲突后选择“重新载入”：放弃自己的修改，读服务器上的新版本。
    func reloadAfterConflict() {
        conflictPending = false
        if let openedPath { read(openedPath) }
    }

    // MARK: 删除

    /// 删除文件前先确认（目录不能删）。
    func requestDelete(_ path: String) {
        guard !isSaving else { return }
        pendingDelete = path
    }

    /// 确认后删除；删的是正在查看的文件就一起关掉（未保存的修改随之放弃，确认框里已提示）。
    func delete(_ path: String) {
        pendingDelete = nil
        let client = client
        Task {
            do {
                try await client.delete(path: path)
                notify("已删除 \((path as NSString).lastPathComponent)")
                if openedPath == path { close() }
            } catch {
                deleteError = Self.message(error)
            }
            if let dir = listing?.path { go(to: dir) }
        }
    }

    // MARK: 上传下载

    func download(_ path: String, to destination: URL) {
        guard transfer == nil else { return }
        let name = (path as NSString).lastPathComponent
        transfer = Transfer(kind: .download, name: name, total: 0)
        let client = client
        transferTask = Task {
            do {
                try await client.download(path: path, to: destination, progress: progressHandler())
                notify("已下载到 \(destination.path)")
            } catch is CancellationError {
            } catch {
                transferError = ("下载失败", Self.message(error))
            }
            transfer = nil
        }
    }

    /// 选好本地文件后：传到当前目录下的同名文件。已存在或生产环境时先确认。
    func requestUpload(_ source: URL) {
        guard transfer == nil, let listing else { return }
        let name = source.lastPathComponent
        let pending = PendingUpload(source: source, target: RemoteFileScript.join(listing.path, name),
                                    exists: listing.entries.contains { $0.name == name })
        if pending.exists || isProduction { pendingUpload = pending } else { upload(pending) }
    }

    /// 从 Finder 拖进目录列表的文件：一次只传一个、不传目录，其余和“上传”按钮一样。
    @discardableResult
    func requestDroppedUpload(_ urls: [URL]) -> Bool {
        guard listing != nil else { return false }
        let files = urls.filter(\.isFileURL)
        guard files.count == 1, let source = files.first else {
            transferError = ("不能上传", files.isEmpty ? "只能拖入本地文件。" : "一次只能上传一个文件。")
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            transferError = ("不能上传", "\(source.lastPathComponent) 是目录，不支持上传目录。")
            return false
        }
        guard transfer == nil else {
            transferError = ("不能上传", "正在传输 \(transfer?.name ?? "")，等它结束后再上传。")
            return false
        }
        requestUpload(source)
        return true
    }

    func upload(_ pending: PendingUpload) {
        pendingUpload = nil
        guard transfer == nil else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: pending.source.path)[.size] as? NSNumber)?.int64Value ?? 0
        transfer = Transfer(kind: .upload, name: pending.source.lastPathComponent, total: size)
        let client = client
        transferTask = Task {
            do {
                try await client.upload(from: pending.source, to: pending.target, overwrite: pending.exists,
                                        progress: progressHandler())
                notify("已上传 \(pending.source.lastPathComponent)")
            } catch is CancellationError {
            } catch RemoteFileError.alreadyExists {
                // 列表过时：其实已经有同名文件了，改为询问是否覆盖。
                pendingUpload = PendingUpload(source: pending.source, target: pending.target, exists: true)
            } catch {
                transferError = ("上传失败", Self.message(error))
            }
            transfer = nil
            if let dir = listing?.path { go(to: dir) }
            // 覆盖了正在查看的文件：没改过就重新读。
            if pending.target == openedPath, !isDirty { read(pending.target) }
        }
    }

    // MARK: 服务器间发送

    /// 正在选择发到哪台服务器的文件路径（显示选择目标的面板）。
    var choosingSendTarget: String?
    /// 发送的确认框：覆盖已有文件或目标是生产环境时。
    var pendingSend: PendingSend?
    /// 正在检查目标目录（发送前）。
    private(set) var isCheckingSend = false

    /// 选好目标服务器和目录后：先列一下目标目录（`directory` 为空时是家目录），确认目录存在、看有没有同名文件。
    func requestSend(_ path: String, to target: FileSendTarget, directory: String) {
        guard transfer == nil, !isCheckingSend else { return }
        let name = (path as NSString).lastPathComponent
        let dir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        isCheckingSend = true
        Task {
            defer { isCheckingSend = false }
            do {
                let listing = try await target.client.list(directory: dir.isEmpty || dir == "~" ? nil : dir)
                let pending = PendingSend(source: path, target: target, targetPath: RemoteFileScript.join(listing.path, name),
                                          exists: listing.entries.contains { $0.name == name })
                if target.serverID == serverID, pending.targetPath == path {
                    transferError = ("不能发送", "目标就是这个文件本身：\(path)")
                } else if pending.exists || target.isProduction {
                    pendingSend = pending
                } else {
                    send(pending)
                }
            } catch {
                transferError = ("发送失败", "\(target.serverName)：\(Self.message(error))")
            }
        }
    }

    /// 下载到本机临时目录，再上传到目标服务器，最后删掉临时文件。目标已存在时覆盖（确认框里已问过）。
    func send(_ pending: PendingSend) {
        pendingSend = nil
        guard transfer == nil else { return }
        let name = (pending.source as NSString).lastPathComponent
        transfer = Transfer(kind: .send(to: pending.target.serverName), name: name, total: 0)
        let client = client
        transferTask = Task {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmdcode-send-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let local = temp.appendingPathComponent(name)
                try await client.download(path: pending.source, to: local, progress: progressHandler())
                try Task.checkCancellation()
                transfer?.sending = true
                transfer?.done = 0
                try await pending.target.client.upload(from: local, to: pending.targetPath, overwrite: pending.exists,
                                                       progress: progressHandler())
                notify("已发到 \(pending.target.serverName)：\(pending.targetPath)")
                if let dir = RemoteFileScript.parent(of: pending.targetPath) { remoteChanged(pending.target.serverID, dir) }
            } catch is CancellationError {
            } catch RemoteFileError.alreadyExists {
                transferError = ("发送失败", "\(pending.target.serverName) 上已经有 \(pending.targetPath)，请重新发送并确认覆盖。")
            } catch {
                transferError = ("发送失败", Self.message(error))
            }
            transfer = nil
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
    }

    private func progressHandler() -> @Sendable (Int64, Int64) -> Void {
        { [weak self] done, total in
            Task { @MainActor in
                self?.transfer?.done = done
                if total > 0 { self?.transfer?.total = total }
            }
        }
    }

    func read(_ path: String) {
        readTask?.cancel()
        openedPath = path
        content = nil
        draft = ""
        readError = nil
        isReading = true
        let client = client
        readTask = Task {
            do {
                let result = try await client.read(path: path)
                guard !Task.isCancelled else { return }
                content = result
                draft = result.text ?? ""
            } catch {
                guard !Task.isCancelled else { return }
                readError = Self.message(error)
            }
            isReading = false
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

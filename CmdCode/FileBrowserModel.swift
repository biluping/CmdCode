import CmdCodeCore
import Foundation
import Observation

/// 一台服务器的远程文件浏览状态：当前目录、正在查看的文件。切换到别的页面再回来时保留。
@MainActor
@Observable
final class FileBrowserModel {
    /// 每次进入文件页时按服务器当前的凭据重新生成，改了密码也能用。
    var client: RemoteFileClient
    let serverName: String
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

    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?

    init(client: RemoteFileClient, serverName: String, initialDirectory: String?) {
        self.client = client
        self.serverName = serverName
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

    func refresh() {
        go(to: listing?.path ?? initialDirectory)
        if let openedPath { read(openedPath) }
    }

    /// 点了列表里的条目：目录进入，文件打开查看。
    func open(_ entry: RemoteFileEntry) {
        guard let dir = listing?.path else { return }
        let path = RemoteFileScript.join(dir, entry.name)
        switch entry.kind {
        case .directory: go(to: path)
        case .file: read(path)
        case .other: break
        }
    }

    func read(_ path: String) {
        readTask?.cancel()
        openedPath = path
        content = nil
        readError = nil
        isReading = true
        let client = client
        readTask = Task {
            do {
                let result = try await client.read(path: path)
                guard !Task.isCancelled else { return }
                content = result
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

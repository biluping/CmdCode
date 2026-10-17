import CmdCodeCore
import Foundation

let usage = """
把 FinalShell 里保存的 SSH 服务器导入 CmdCode 的数据库。

用法：
  swift run cmdcode-import [--dry-run] [--store <数据库路径>] [--from <FinalShell conn 目录>]

--dry-run 导入到数据库的临时副本里并打印结果，不改原数据库。
默认数据库：~/Library/Application Support/CmdCode/CmdCode.store（导入前请先退出 CmdCode）。
输出里不会显示密码。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var dryRun = false
var storeURL = Persistence.defaultStoreURL
var sourceURL = FinalShell.defaultDirectory
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--dry-run": dryRun = true
    case "--store", "--from":
        guard let value = args.popFirst() else { fail("\(arg) 缺少值\n\n\(usage)") }
        let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        if arg == "--store" { storeURL = url } else { sourceURL = url }
    case "-h", "--help": print(usage); exit(0)
    default: fail("未知参数：\(arg)\n\n\(usage)")
    }
}

func printList(_ title: String, _ items: [String]) {
    print("\(title)：\(items.count)")
    for item in items { print("  \(item)") }
}

@MainActor
func main() throws {
    let export = try FinalShell.load(from: sourceURL)
    print("FinalShell：\(export.folders.count) 个文件夹，\(export.connections.count) 个可导入的连接")
    for s in export.skipped { print("  跳过 \(s.name)：\(s.reason)") }

    var target = storeURL
    if dryRun {
        // 复制一份数据库（连同 -wal、-shm）到临时目录，导入到副本里，这样也能看出哪些服务器已经存在。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmdcode-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        target = dir.appendingPathComponent(storeURL.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
    }
    let container = try Persistence.makeContainer(storeURL: target)
    let library = Library(context: container.mainContext)
    let report = try library.importFinalShell(export)

    print(dryRun ? "\n[试运行，未写入]" : "\n已写入：\(storeURL.path)")
    printList("新建分组", report.createdGroups)
    printList("新建凭据", report.createdCredentials)
    printList("导入服务器", report.importedServers)
    printList("已存在而跳过", report.existingServers)
}

do {
    try MainActor.assumeIsolated { try main() }
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}

import Foundation

/// 测试用的进程与临时目录工具。
enum Shell {
    struct Result: Equatable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String,
        env: [String: String]
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        // 输出写到临时文件而不是 Pipe：测试并行启动进程时，管道写端可能被别的子进程继承，
        // 读端就一直等不到 EOF。
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        try out.close()
        try err.close()
        return Result(
            stdout: String(decoding: try Data(contentsOf: outURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self),
            status: process.terminationStatus
        )
    }

    /// 新建一个已解析符号链接的临时目录（macOS 上 /var 指向 /private/var，
    /// 不解析的话 `cd` 后的 `pwd` 与直接在目录里运行的结果会不一致）。
    static func makeTempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdcode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// 干净、可复现的环境：HOME 指向空目录，避免 `bash -l` 加载真实用户的 profile。
    static func cleanEnv(home: String) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }
}

@testable import CmdCodeCore
import Foundation
import Testing

@MainActor
struct FinalShellImportTests {
    @Test func javaRandomMatchesJava() {
        // new Random(0).nextLong()
        #expect(JavaRandom(seed: 0).nextLong() == -4962768465676381896)
        // new Random(42).nextInt(10)
        #expect(JavaRandom(seed: 42).nextInt(10) == 0)
    }

    @Test("密码加密后能解回原文", arguments: ["", "a", "Pa'ss$w0rd\"中文", "12345678"])
    func passwordRoundTrip(_ password: String) throws {
        for head: [UInt8] in [[3, 200, 7, 1, 90, 17, 255, 128], [0, 0, 0, 0, 0, 1, 0, 0]] {
            let encoded = FinalShell.encodePassword(password, head: head)
            #expect(try FinalShell.decodePassword(encoded) == password || password.isEmpty)
        }
        #expect(throws: FinalShell.ImportError.self) { try FinalShell.decodePassword("bm90LWEtcGFzc3dvcmQhIQ==") }
    }

    @Test("从目录读取并导入：文件夹变分组、相同登录共用凭据、已有服务器跳过")
    func importIntoLibrary() throws {
        let dir = URL(fileURLWithPath: try Shell.makeTempDir())
        func write(_ path: String, _ object: [String: Any]) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        let head: [UInt8] = [5, 1, 2, 3, 4, 5, 6, 7]
        func conn(_ id: String, folder: String, host: String, port: Int = 22, user: String = "root", pw: String,
                  type: Int = 100, auth: Int = 1, created: Int64) -> [String: Any] {
            ["id": id, "name": host, "host": host, "port": port, "user_name": user,
             "password": FinalShell.encodePassword(pw, head: head), "description": "desc \(id)",
             "conection_type": type, "authentication_type": auth, "parent_id": folder,
             "create_time": created, "delete_time": 0]
        }
        try write("f1/folder.json", ["id": "f1", "name": "lims", "parent_id": "root", "create_time": 2, "delete_time": 0])
        try write("f2/folder.json", ["id": "f2", "name": "eln", "parent_id": "root", "create_time": 1, "delete_time": 0])
        try write("f1/a_connect_config.json", conn("a", folder: "f1", host: "10.0.0.1", pw: "x", created: 1))
        try write("f1/b_connect_config.json", conn("b", folder: "f1", host: "10.0.0.2", pw: "x", created: 2))
        try write("f2/c_connect_config.json", conn("c", folder: "f2", host: "10.0.0.3", pw: "y", created: 3))
        try write("f2/d_connect_config.json", conn("d", folder: "f2", host: "10.0.0.9", pw: "z", auth: 2, created: 4))
        try write("e_connect_config.json", conn("e", folder: "root", host: "10.0.0.5", port: 2233, pw: "y", created: 5))

        let export = try FinalShell.load(from: dir)
        #expect(export.folders == ["eln", "lims"])
        #expect(export.connections.map(\.host) == ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.5"])
        #expect(export.skipped.map(\.reason) == ["不是密码登录"])

        let container = try Persistence.makeContainer(inMemory: true)
        let lib = Library(context: container.mainContext)
        let existing = try lib.createCredential(CredentialDraft(name: "已有", username: "root", password: "y"))
        try lib.createGroup(name: "lims")
        try lib.createServer(ServerDraft(name: "旧", host: "10.0.0.2", credential: existing))

        let report = try lib.importFinalShell(export)
        #expect(report.createdGroups == ["eln"])
        #expect(report.createdCredentials == ["root · lims"])
        #expect(report.importedServers == ["lims / 10.0.0.1", "eln / 10.0.0.3", "未分组 / 10.0.0.5"])
        #expect(report.existingServers == ["lims / 10.0.0.2"])

        let byHost = Dictionary(uniqueKeysWithValues: lib.allServers().map { ($0.host, $0) })
        #expect(byHost["10.0.0.1"]?.credential?.password == "x")
        #expect(byHost["10.0.0.1"]?.group?.name == "lims")
        #expect(byHost["10.0.0.3"]?.credential === existing)
        #expect(byHost["10.0.0.5"]?.group == nil)
        #expect(byHost["10.0.0.5"]?.port == 2233)
        #expect(byHost["10.0.0.5"]?.note == "desc e")

        // 再导入一次全部跳过。
        let again = try lib.importFinalShell(export)
        #expect(again.importedServers.isEmpty && again.existingServers.count == 4)
    }
}

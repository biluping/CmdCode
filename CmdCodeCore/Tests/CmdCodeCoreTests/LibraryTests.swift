import Foundation
import SwiftData
import Testing
@testable import CmdCodeCore

@MainActor
@Suite("数据层")
struct LibraryTests {
    let container: ModelContainer
    let lib: Library

    init() throws {
        container = try Persistence.makeContainer(inMemory: true)
        lib = Library(context: container.mainContext)
    }

    private func credential(_ name: String = "测试 root", password: String = "pw") throws -> Credential {
        try lib.createCredential(CredentialDraft(name: name, username: "root", password: password))
    }

    private func server(_ name: String, host: String = "10.0.144.232", credential c: Credential,
                        group: ServerGroup? = nil, production: Bool = false, dir: String = "") throws -> Server {
        try lib.createServer(ServerDraft(name: name, group: group, host: host, port: 2233, credential: c,
                                         workingDirectory: dir, isProduction: production))
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try lib.context.fetchCount(FetchDescriptor<T>())
    }

    // MARK: 存储

    @Test("写入文件数据库后重新打开能读出")
    func persistsToDisk() throws {
        let url = URL(fileURLWithPath: try Shell.makeTempDir()).appendingPathComponent("sub/CmdCode.store")
        // 容器必须在使用 context 期间保持存活，否则 SwiftData 会直接崩溃。
        do {
            let container = try Persistence.makeContainer(storeURL: url)
            let lib = Library(context: container.mainContext)
            let c = try lib.createCredential(CredentialDraft(name: "c", username: "u", password: "p"))
            try lib.createServer(ServerDraft(name: "s", host: "h", credential: c))
        }
        let container = try Persistence.makeContainer(storeURL: url)
        let reopened = Library(context: container.mainContext)
        #expect(reopened.allServers().map(\.name) == ["s"])
        #expect(reopened.allServers().first?.credential?.password == "p")
    }

    @Test func defaultStoreLocation() {
        #expect(Persistence.defaultStoreURL.path.hasSuffix("Library/Application Support/CmdCode/CmdCode.store"))
    }

    // MARK: 凭据

    @Test func credentialValidation() throws {
        #expect(throws: LibraryError.emptyField("名称")) {
            try lib.createCredential(CredentialDraft(name: "  ", username: "root", password: "p"))
        }
        #expect(throws: LibraryError.emptyField("用户名")) {
            try lib.createCredential(CredentialDraft(name: "n", username: "", password: "p"))
        }
        #expect(throws: LibraryError.emptyField("密码")) {
            try lib.createCredential(CredentialDraft(name: "n", username: "root", password: ""))
        }
        #expect(try count(Credential.self) == 0)
    }

    @Test("多台服务器共用凭据，改一次密码全部生效")
    func sharedCredential() throws {
        let c = try credential(password: "old")
        let a = try server("232", credential: c)
        let b = try server("233", host: "10.0.144.233", credential: c)
        #expect(lib.servers(using: c).map(\.name) == ["232", "233"])

        var draft = CredentialDraft(c)
        draft.password = "new"
        try lib.updateCredential(c, with: draft)

        #expect(try a.loginPlan().target.password == "new")
        #expect(try b.loginPlan().target.password == "new")
    }

    @Test("被引用的凭据删不掉，并列出服务器")
    func credentialInUseCannotBeDeleted() throws {
        let c = try credential()
        let other = try credential("其他")
        let a = try server("232", credential: c)
        let b = try server("233", credential: c)

        #expect(throws: LibraryError.credentialInUse(serverNames: ["232", "233"])) {
            try lib.deleteCredential(c)
        }
        #expect(try count(Credential.self) == 2)

        for s in [a, b] {
            var d = ServerDraft(s)
            d.credential = other
            try lib.updateServer(s, with: d)
        }
        try lib.deleteCredential(c)
        #expect(lib.credentials().map(\.name) == ["其他"])
        #expect(LibraryError.credentialInUse(serverNames: ["232"]).errorDescription == "请先修改以下服务器的凭据：\n232")
    }

    // MARK: 服务器

    @Test func serverValidation() throws {
        let c = try credential()
        #expect(throws: LibraryError.emptyField("名称")) { try lib.createServer(ServerDraft(host: "h", credential: c)) }
        #expect(throws: LibraryError.emptyField("主机")) { try lib.createServer(ServerDraft(name: "n", host: " ", credential: c)) }
        #expect(throws: LibraryError.invalidPort) { try lib.createServer(ServerDraft(name: "n", host: "h", port: 0, credential: c)) }
        #expect(throws: LibraryError.invalidPort) { try lib.createServer(ServerDraft(name: "n", host: "h", port: 65536, credential: c)) }
        #expect(throws: LibraryError.missingCredential) { try lib.createServer(ServerDraft(name: "n", host: "h")) }
        #expect(try count(Server.self) == 0)
        #expect(ServerDraft().port == 22)
    }

    @Test("删除服务器连同命令一起删除")
    func deleteServerCascades() throws {
        let c = try credential()
        let s = try server("232", credential: c)
        let keep = try server("233", credential: c)
        try lib.createCommand(CommandDraft(name: "构建", content: "./build.sh"), on: s)
        try lib.createCommand(CommandDraft(name: "看日志", content: "tail -f log"), on: s)
        try lib.createCommand(CommandDraft(name: "别删", content: "ls"), on: keep)

        #expect(lib.commandsDeleted(with: s).map(\.name) == ["构建", "看日志"])
        try lib.deleteServer(s)

        #expect(lib.allServers().map(\.name) == ["233"])
        #expect(try count(ServerCommand.self) == 1)
        #expect(lib.servers(using: c).map(\.name) == ["233"])
    }

    @Test("复制服务器带上命令，复制命令放在同一服务器")
    func duplicate() throws {
        let c = try credential()
        let g = try lib.createGroup(name: "LIMS 测试")
        let s = try server("232", credential: c, group: g, production: true, dir: "/opt")
        try lib.createCommand(CommandDraft(name: "a", content: "echo a"), on: s)
        try lib.createCommand(CommandDraft(name: "b", content: "echo b", workingDirectory: "/tmp"), on: s)

        let copy = try lib.duplicateServer(s)
        #expect(copy.name == "232 副本")
        #expect(copy.group === g)
        #expect(copy.credential === c)
        #expect(copy.isProduction && copy.workingDirectory == "/opt" && copy.port == 2233)
        #expect(copy.sortedCommands.map(\.name) == ["a", "b"])
        #expect(copy.sortedCommands.map(\.workingDirectory) == ["", "/tmp"])
        #expect(s.commands.count == 2)

        let cmd = try lib.duplicateCommand(s.sortedCommands[0])
        #expect(cmd.name == "a 副本" && cmd.server === s)
        #expect(s.sortedCommands.map(\.name) == ["a", "b", "a 副本"])
    }

    // MARK: 分组与左侧栏

    @Test("删除分组后服务器归入未分组")
    func deleteGroupMovesServersToUngrouped() throws {
        let c = try credential()
        let g = try lib.createGroup(name: "ELN")
        let s = try server("eln", credential: c, group: g)
        try lib.deleteGroup(g)

        #expect(lib.groups().isEmpty)
        #expect(s.group == nil)
        #expect(lib.servers(in: nil).map(\.name) == ["eln"])
    }

    @Test("左侧栏按创建顺序，未分组固定最后")
    func sidebarOrder() throws {
        let c = try credential()
        try server("loose1", credential: c)
        let test = try lib.createGroup(name: "LIMS 测试")
        let prod = try lib.createGroup(name: "LIMS 生产")
        try server("232", credential: c, group: test)
        try server("135", credential: c, group: prod, production: true)
        try server("233", credential: c, group: test)
        let loose2 = try server("loose2", credential: c)

        try lib.moveServer(loose2, to: prod)
        try lib.renameGroup(test, to: "测试")

        let sections = lib.sidebarSections()
        #expect(sections.map(\.title) == ["测试", "LIMS 生产", "未分组"])
        #expect(sections.map { $0.servers.map(\.name) } == [["232", "233"], ["135", "loose2"], ["loose1"]])
        #expect(sections.map(\.serverCount) == [2, 2, 1])
        #expect(throws: LibraryError.emptyField("名称")) { try lib.createGroup(name: "") }
    }

    @Test("拖动排序：分组移动到指定位置，未分组仍在最后")
    func moveGroup() throws {
        let a = try lib.createGroup(name: "A")
        let b = try lib.createGroup(name: "B")
        let c = try lib.createGroup(name: "C")
        let d = try lib.createGroup(name: "D")
        func order() -> [String] { lib.groups().map(\.name) }

        try lib.moveGroup(d, to: 0)            // 拖到最前
        #expect(order() == ["D", "A", "B", "C"])
        try lib.moveGroup(d, to: 4)            // 拖到最后
        #expect(order() == ["A", "B", "C", "D"])
        try lib.moveGroup(a, to: 2)            // 向下拖到 C 之前
        #expect(order() == ["B", "A", "C", "D"])
        try lib.moveGroup(c, to: 1)            // 向上拖到 A 之前
        #expect(order() == ["B", "C", "A", "D"])
        try lib.moveGroup(b, to: 1)            // 放回原位不变
        #expect(order() == ["B", "C", "A", "D"])
        try lib.moveGroup(c, to: 99)           // 越界按最后处理
        #expect(order() == ["B", "A", "D", "C"])

        // 新建的分组排在最后，左侧栏“未分组”始终最后
        try lib.createGroup(name: "E")
        #expect(order() == ["B", "A", "D", "C", "E"])
        #expect(lib.sidebarSections().map(\.title) == ["B", "A", "D", "C", "E", "未分组"])
        _ = (a, b, c, d)
    }

    @Test("拖动排序：服务器组内调整顺序、跨分组移动")
    func moveServer() throws {
        let c = try credential()
        let g1 = try lib.createGroup(name: "G1")
        let g2 = try lib.createGroup(name: "G2")
        let a = try server("a", credential: c, group: g1)
        let b = try server("b", credential: c, group: g1)
        let x = try server("x", credential: c, group: g1)
        let p = try server("p", credential: c, group: g2)
        let u = try server("u", credential: c)
        func names(_ g: ServerGroup?) -> [String] { lib.servers(in: g).map(\.name) }

        try lib.moveServer(x, to: g1, at: 0)              // 组内拖到最前
        #expect(names(g1) == ["x", "a", "b"])
        try lib.moveServer(a, to: g2, at: 0)              // 跨组插到 p 之前
        #expect(names(g1) == ["x", "b"])
        #expect(names(g2) == ["a", "p"])
        try lib.moveServer(u, to: g2)                     // 拖到分组标题：排到最后
        #expect(names(g2) == ["a", "p", "u"])
        #expect(names(nil).isEmpty)
        try lib.moveServer(b, to: nil)                    // 移到未分组
        #expect(names(nil) == ["b"])
        #expect(lib.sidebarSections().map { $0.servers.map(\.name) } == [["x"], ["a", "p", "u"], ["b"]])

        // 新建的服务器排在组内最后；编辑时换分组也排到最后
        try server("y", credential: c, group: g1)
        #expect(names(g1) == ["x", "y"])
        var d = ServerDraft(x)
        d.group = g2
        try lib.updateServer(x, with: d)
        #expect(names(g2) == ["a", "p", "u", "x"])
        _ = p
    }

    @Test("拖动排序：命令在服务器内调整顺序，新建和复制排在最后")
    func moveCommand() throws {
        let s = try server("232", credential: try credential())
        let one = try lib.createCommand(CommandDraft(name: "1", content: "echo 1"), on: s)
        let two = try lib.createCommand(CommandDraft(name: "2", content: "echo 2"), on: s)
        let three = try lib.createCommand(CommandDraft(name: "3", content: "echo 3"), on: s)
        func names() -> [String] { s.sortedCommands.map(\.name) }

        try lib.moveCommand(three, to: 0)
        #expect(names() == ["3", "1", "2"])
        try lib.moveCommand(three, to: 2)                 // 向下拖到 2 之前
        #expect(names() == ["1", "3", "2"])
        try lib.moveCommand(one, to: 3)                   // 拖到最后
        #expect(names() == ["3", "2", "1"])
        try lib.duplicateCommand(two)
        #expect(names() == ["3", "2", "1", "2 副本"])

        let copy = try lib.duplicateServer(s)             // 复制服务器保持命令顺序
        #expect(copy.sortedCommands.map(\.name) == ["3", "2", "1", "2 副本"])
        _ = two
    }

    @Test("排序位置会保存到数据库")
    func groupOrderPersists() throws {
        let url = URL(fileURLWithPath: try Shell.makeTempDir()).appendingPathComponent("CmdCode.store")
        do {
            let container = try Persistence.makeContainer(storeURL: url)
            let lib = Library(context: container.mainContext)
            try lib.createGroup(name: "A")
            let b = try lib.createGroup(name: "B")
            try lib.moveGroup(b, to: 0)
        }
        let container = try Persistence.makeContainer(storeURL: url)
        #expect(Library(context: container.mainContext).groups().map(\.name) == ["B", "A"])
    }

    @Test func emptyLibraryStillShowsUngrouped() {
        #expect(lib.sidebarSections().map(\.title) == ["未分组"])
    }

    // MARK: 命令与执行计划

    @Test func commandValidation() throws {
        let s = try server("232", credential: try credential())
        #expect(throws: LibraryError.emptyField("名称")) { try lib.createCommand(CommandDraft(content: "ls"), on: s) }
        #expect(throws: LibraryError.emptyField("命令内容")) { try lib.createCommand(CommandDraft(name: "n", content: "\n "), on: s) }
    }

    @Test("生产环境强制确认，命令工作目录覆盖服务器的")
    func executionPlan() throws {
        let c = try credential(password: "p'w")
        let dev = try server("232", credential: c, dir: "/usr/local/app/lims")
        let prod = try server("135", credential: c, production: true)

        let build = try lib.createCommand(CommandDraft(name: "构建", content: "./build.sh\necho done"), on: dev)
        let plan = try build.executionPlan()
        #expect(plan == ExecutionPlan(
            target: SSHTarget(host: "10.0.144.232", port: 2233, username: "root", password: "p'w"),
            command: "./build.sh\necho done", workingDirectory: "/usr/local/app/lims",
            requiresConfirmation: true, serverName: "232", commandName: "构建", stayInShell: true))

        var d = CommandDraft(build)
        d.workingDirectory = "/tmp"
        try lib.updateCommand(build, with: d)
        #expect(try build.executionPlan().workingDirectory == "/tmp")

        // 命令一律先确认、执行完留在远端 shell，不分是否生产环境。
        let log = try lib.createCommand(CommandDraft(name: "看日志", content: "tail -f x"), on: prod)
        #expect(try log.executionPlan().requiresConfirmation)
        #expect(try log.executionPlan().stayInShell)
        #expect(try log.executionPlan().workingDirectory == nil)

        let login = try dev.loginPlan()
        #expect(login.command == "" && login.stayInShell && !login.requiresConfirmation)
        #expect(login.workingDirectory == "/usr/local/app/lims")
        #expect(try dev.loginPlan(directory: "/var/log").workingDirectory == "/var/log")
        #expect(try dev.loginPlan(directory: " ").workingDirectory == "/usr/local/app/lims")
        #expect(try log.executionPlan().isProduction)
        #expect(try log.executionPlan().title == "135 / 看日志")
    }

    // MARK: 搜索

    @Test("按服务器名、IP、命令名、命令内容搜索")
    func search() throws {
        let c = try credential()
        let lims = try server("232 - LIMS 主服务", host: "10.0.144.232", credential: c)
        let eln = try server("ELN", host: "10.0.144.70", credential: c)
        try lib.createCommand(CommandDraft(name: "构建", content: "cd /opt && ./build.sh"), on: lims)
        try lib.createCommand(CommandDraft(name: "看日志", content: "tail -f /var/log/lims.log"), on: lims)
        try lib.createCommand(CommandDraft(name: "重启", content: "systemctl restart eln"), on: eln)

        func names(_ q: String) -> ([String], [String]) {
            let r = lib.search(q)
            return (r.servers.map(\.name), r.commands.map(\.name))
        }
        #expect(names("lims") == (["232 - LIMS 主服务"], ["看日志"]))
        #expect(names("144.70") == (["ELN"], []))
        #expect(names("构建") == ([], ["构建"]))
        #expect(names("BUILD.SH") == ([], ["构建"]))
        #expect(names("restart eln") == ([], ["重启"]))
        #expect(names("tail nomatch") == ([], []))
        #expect(lib.search("   ").isEmpty)
    }
}

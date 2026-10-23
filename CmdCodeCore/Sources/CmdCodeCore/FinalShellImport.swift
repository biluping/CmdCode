import CommonCrypto
import CryptoKit
import Foundation

/// 读取 FinalShell 保存的连接（`~/Library/FinalShell/conn`），用于一次性导入。
///
/// 目录结构：每个文件夹一个子目录，里面有 `folder.json` 和若干 `*_connect_config.json`。
/// 密码是 FinalShell 自己的 DES 加密：base64 解码后前 8 字节是随机头，由它派生密钥解密其余部分。
public enum FinalShell {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/FinalShell/conn")
    }

    public struct Connection: Equatable {
        public var name: String
        public var host: String
        public var port: Int
        public var username: String
        public var password: String
        public var description: String
        /// 所在文件夹名；在根目录时为 nil。
        public var folder: String?
        public var createTime: Int64
    }

    public struct Export {
        /// 文件夹名，按创建时间。
        public var folders: [String] = []
        public var connections: [Connection] = []
        /// 跳过的连接和原因（非 SSH、密钥登录、密码解不开）。
        public var skipped: [(name: String, reason: String)] = []
    }

    public enum ImportError: Error, LocalizedError {
        case badPassword

        public var errorDescription: String? { "密码无法解密" }
    }

    // MARK: 读取

    public static func load(from directory: URL = defaultDirectory) throws -> Export {
        var folderNames: [String: (name: String, created: Int64)] = [:]
        var raw: [[String: Any]] = []
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "json",
                  let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            else { continue }
            if (object["delete_time"] as? Int64 ?? 0) != 0 { continue }
            if url.lastPathComponent == "folder.json" {
                if let id = object["id"] as? String, let name = object["name"] as? String {
                    folderNames[id] = (name, object["create_time"] as? Int64 ?? 0)
                }
            } else if object["host"] != nil {
                raw.append(object)
            }
        }

        var export = Export()
        export.folders = folderNames.values.sorted { ($0.created, $0.name) < ($1.created, $1.name) }.map(\.name)
        for o in raw {
            let name = o["name"] as? String ?? ""
            guard o["conection_type"] as? Int == 100 else { export.skipped.append((name, "不是 SSH 连接")); continue }
            guard o["authentication_type"] as? Int == 1 else { export.skipped.append((name, "不是密码登录")); continue }
            let password: String
            do { password = try decodePassword(o["password"] as? String ?? "") } catch {
                export.skipped.append((name, "密码无法解密")); continue
            }
            export.connections.append(Connection(
                name: name,
                host: (o["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                port: o["port"] as? Int ?? 22,
                username: o["user_name"] as? String ?? "",
                password: password,
                description: (o["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                folder: (o["parent_id"] as? String).flatMap { folderNames[$0]?.name },
                createTime: o["create_time"] as? Int64 ?? 0))
        }
        export.connections.sort { ($0.createTime, $0.name) < ($1.createTime, $1.name) }
        return export
    }

    // MARK: 密码

    public static func decodePassword(_ encoded: String) throws -> String {
        if encoded.isEmpty { return "" }
        guard let data = Data(base64Encoded: encoded), data.count > 8 else { throw ImportError.badPassword }
        let bytes = [UInt8](data)
        let head = Array(bytes[0..<8])
        guard let plain = des(CCOperation(kCCDecrypt), Array(bytes[8...]), key: key(head: head)),
              let text = String(bytes: plain, encoding: .utf8)
        else { throw ImportError.badPassword }
        return text
    }

    /// 与 `decodePassword` 相反，只用于测试。
    static func encodePassword(_ password: String, head: [UInt8]) -> String {
        let cipher = des(CCOperation(kCCEncrypt), Array(password.utf8), key: key(head: head)) ?? []
        return Data(head + cipher).base64EncodedString()
    }

    /// 由 8 字节头派生 DES 密钥（FinalShell 的算法，依赖 `java.util.Random`）。
    static func key(head: [UInt8]) -> [UInt8] {
        let h = head.map { Int64(Int8(bitPattern: $0)) }
        let divisor = Int64(JavaRandom(seed: h[5]).nextInt(127))
        let random = JavaRandom(seed: 3680984568597093857 / max(divisor, 1))
        for _ in 0..<max(h[0], 0) { _ = random.nextLong() }
        let r2 = JavaRandom(seed: random.nextLong())
        let longs: [Int64] = [h[4], r2.nextLong(), h[7], h[3], r2.nextLong(), h[1], random.nextLong(), h[2]]
        var buffer: [UInt8] = []
        for l in longs { withUnsafeBytes(of: l.bigEndian) { buffer += $0 } }
        return Array(Insecure.MD5.hash(data: buffer).prefix(8))
    }

    /// DES/ECB/PKCS5Padding。
    private static func des(_ op: CCOperation, _ input: [UInt8], key: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, input, input.count, &output, output.count, &moved)
        return status == kCCSuccess ? Array(output.prefix(moved)) : nil
    }
}

/// `java.util.Random` 的实现（48 位线性同余）。
final class JavaRandom {
    private var seed: Int64
    private static let multiplier: Int64 = 0x5DEECE66D
    private static let mask: Int64 = (1 << 48) - 1

    init(seed: Int64) {
        self.seed = (seed ^ Self.multiplier) & Self.mask
    }

    private func next(_ bits: Int) -> Int32 {
        seed = (seed &* Self.multiplier &+ 0xB) & Self.mask
        return Int32(truncatingIfNeeded: seed >> (48 - bits))
    }

    func nextLong() -> Int64 {
        (Int64(next(32)) << 32) &+ Int64(next(32))
    }

    func nextInt(_ bound: Int32) -> Int32 {
        if bound & -bound == bound {
            return Int32(truncatingIfNeeded: (Int64(bound) * Int64(next(31))) >> 31)
        }
        var bits: Int32
        var value: Int32
        repeat {
            bits = next(31)
            value = bits % bound
        } while bits &- value &+ (bound - 1) < 0
        return value
    }
}

// MARK: - 写入数据库

public struct FinalShellImportReport {
    public var createdGroups: [String] = []
    public var createdCredentials: [String] = []
    public var importedServers: [String] = []
    /// 已存在（主机、端口、用户名都相同）而跳过的服务器。
    public var existingServers: [String] = []
}

extension Library {
    /// 导入 FinalShell 连接：
    /// - 文件夹变成同名分组（已有同名分组就沿用），根目录的连接放进“未分组”；
    /// - 用户名 + 密码相同的连接共用一条凭据（已有相同凭据就沿用）；
    /// - 服务器名用 FinalShell 里的名称（多个连接同名时加上 `:端口`），描述放进备注；
    ///   主机、端口、用户名都相同的已有服务器跳过。
    @discardableResult
    public func importFinalShell(_ export: FinalShell.Export) throws -> FinalShellImportReport {
        var report = FinalShellImportReport()

        var groupsByName = Dictionary(groups().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in export.folders where groupsByName[name] == nil {
            groupsByName[name] = try createGroup(name: name)
            report.createdGroups.append(name)
        }

        struct Login: Hashable { var username: String; var password: String }
        var credentialsByLogin = Dictionary(credentials().map { (Login(username: $0.username, password: $0.password), $0) },
                                            uniquingKeysWith: { a, _ in a })
        var credentialNames = Set(credentials().map(\.name))

        struct Address: Hashable { var host: String; var port: Int; var username: String }
        var existing = Set(allServers().map {
            Address(host: $0.host, port: $0.port, username: $0.loginUsername ?? "")
        })

        let nameCounts = Dictionary(export.connections.map { ($0.name, 1) }, uniquingKeysWith: +)

        for c in export.connections {
            var serverName = c.name.isEmpty ? c.host : c.name
            if nameCounts[c.name, default: 0] > 1 { serverName += ":\(c.port)" }
            let address = Address(host: c.host, port: c.port, username: c.username)
            let label = [c.folder ?? Library.ungroupedTitle, serverName].joined(separator: " / ")
            guard !existing.contains(address) else { report.existingServers.append(label); continue }

            let login = Login(username: c.username, password: c.password)
            let credential: Credential
            if let found = credentialsByLogin[login] {
                credential = found
            } else {
                // 凭据名：用户名 · 首次出现的文件夹，重名时加序号。
                let base = "\(c.username) · \(c.folder ?? Library.ungroupedTitle)"
                var name = base
                var n = 2
                while credentialNames.contains(name) { name = "\(base) \(n)"; n += 1 }
                credential = try createCredential(CredentialDraft(name: name, username: c.username, password: c.password,
                                                                  note: "从 FinalShell 导入"))
                credentialsByLogin[login] = credential
                credentialNames.insert(name)
                report.createdCredentials.append(name)
            }

            try createServer(ServerDraft(
                name: serverName,
                group: c.folder.flatMap { groupsByName[$0] },
                host: c.host, port: c.port, credential: credential, note: c.description))
            existing.insert(address)
            report.importedServers.append(label)
        }
        return report
    }
}

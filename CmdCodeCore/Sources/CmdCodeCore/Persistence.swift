import Foundation
import SwiftData

public enum Persistence {
    public static let schema = Schema([Credential.self, ServerGroup.self, Server.self, ServerCommand.self])

    /// `~/Library/Application Support/CmdCode/CmdCode.store`
    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("CmdCode", isDirectory: true)
            .appendingPathComponent("CmdCode.store")
    }

    /// 打开（必要时创建）数据库。`inMemory` 用于测试和预览。
    public static func makeContainer(storeURL: URL = defaultStoreURL, inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

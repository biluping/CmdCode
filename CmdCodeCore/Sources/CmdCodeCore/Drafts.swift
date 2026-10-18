import Foundation

/// 编辑表单用的草稿。界面只改草稿，保存时由 `Library` 校验后写回模型。

public struct CredentialDraft: Equatable {
    public var name = ""
    public var username = ""
    public var password = ""
    public var note = ""

    public init(name: String = "", username: String = "", password: String = "", note: String = "") {
        self.name = name
        self.username = username
        self.password = password
        self.note = note
    }

    public init(_ c: Credential) {
        self.init(name: c.name, username: c.username, password: c.password, note: c.note)
    }

    func validate() throws(LibraryError) {
        try requireNonBlank(name, "名称")
        try requireNonBlank(username, "用户名")
        try requireNonEmpty(password, "密码")
    }
}

public struct ServerDraft {
    public var name = ""
    public var group: ServerGroup?
    public var host = ""
    public var port = 22
    public var credential: Credential?
    public var workingDirectory = ""
    public var isProduction = false
    public var note = ""

    public init(
        name: String = "",
        group: ServerGroup? = nil,
        host: String = "",
        port: Int = 22,
        credential: Credential? = nil,
        workingDirectory: String = "",
        isProduction: Bool = false,
        note: String = ""
    ) {
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.credential = credential
        self.workingDirectory = workingDirectory
        self.isProduction = isProduction
        self.note = note
    }

    public init(_ s: Server) {
        self.init(name: s.name, group: s.group, host: s.host, port: s.port, credential: s.credential,
                  workingDirectory: s.workingDirectory, isProduction: s.isProduction, note: s.note)
    }

    func validate() throws(LibraryError) {
        try requireNonBlank(name, "名称")
        try requireNonBlank(host, "主机")
        guard (1...65535).contains(port) else { throw .invalidPort }
        guard credential != nil else { throw .missingCredential }
    }
}

public struct CommandDraft: Equatable {
    public var name = ""
    public var content = ""
    public var workingDirectory = ""

    public init(name: String = "", content: String = "", workingDirectory: String = "") {
        self.name = name
        self.content = content
        self.workingDirectory = workingDirectory
    }

    public init(_ c: ServerCommand) {
        self.init(name: c.name, content: c.content, workingDirectory: c.workingDirectory)
    }

    func validate() throws(LibraryError) {
        try requireNonBlank(name, "名称")
        try requireNonBlank(content, "命令内容")
    }
}

private func requireNonBlank(_ value: String, _ field: String) throws(LibraryError) {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyField(field) }
}

private func requireNonEmpty(_ value: String, _ field: String) throws(LibraryError) {
    if value.isEmpty { throw .emptyField(field) }
}

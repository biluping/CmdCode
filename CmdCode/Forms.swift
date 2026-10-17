import CmdCodeCore
import SwiftData
import SwiftUI

/// 表单通用外壳：标题、内容、底部的取消/保存按钮和错误提示。
private struct FormShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let error: String?
    let save: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 16)
            Form { content }
                .formStyle(.grouped)
            HStack {
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 520)
    }
}

// MARK: - 服务器

struct ServerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ServerGroup.createdAt) private var groups: [ServerGroup]
    @Query(sort: \Credential.createdAt) private var credentials: [Credential]

    let server: Server?
    @State private var draft: ServerDraft
    @State private var error: String?
    @State private var creatingCredential = false

    init(server: Server?, presetGroup: ServerGroup?) {
        self.server = server
        _draft = State(initialValue: server.map(ServerDraft.init) ?? ServerDraft(group: presetGroup))
    }

    var body: some View {
        FormShell(title: server == nil ? "新建服务器" : "编辑服务器", error: error, save: save) {
            TextField("名称", text: $draft.name, prompt: Text("比如：232 - lims 主服务"))
            Picker("分组", selection: $draft.group) {
                Text(Library.ungroupedTitle).tag(nil as ServerGroup?)
                ForEach(groups) { Text($0.name).tag($0 as ServerGroup?) }
            }
            TextField("主机", text: $draft.host, prompt: Text("10.0.144.232"))
            TextField("端口", value: $draft.port, format: .number.grouping(.never))
            HStack {
                Picker("登录凭据", selection: $draft.credential) {
                    Text("请选择").tag(nil as Credential?)
                    ForEach(credentials) { Text("\($0.name)（\($0.username)）").tag($0 as Credential?) }
                }
                Button("新建…") { creatingCredential = true }
            }
            TextField("工作目录", text: $draft.workingDirectory, prompt: Text("可选，绝对路径，比如 /usr/local/app/lims"))
            Toggle("生产环境", isOn: $draft.isProduction)
            TextField("备注", text: $draft.note, axis: .vertical)
                .lineLimit(2...4)
        }
        .sheet(isPresented: $creatingCredential) {
            CredentialForm(credential: nil) { draft.credential = $0 }
                .environment(model)
        }
    }

    private func save() {
        do {
            if let server {
                try model.library.updateServer(server, with: draft)
            } else {
                let s = try model.library.createServer(draft)
                model.selection = .server(s.persistentModelID)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 命令

struct CommandForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let server: Server?
    let command: ServerCommand?
    @State private var draft: CommandDraft
    @State private var error: String?

    init(server: Server?, command: ServerCommand?) {
        self.server = server
        self.command = command
        _draft = State(initialValue: command.map(CommandDraft.init) ?? CommandDraft())
    }

    private var isProduction: Bool { server?.isProduction ?? false }

    var body: some View {
        FormShell(title: command == nil ? "新建命令" : "编辑命令", error: error, save: save) {
            if let server {
                LabeledContent("服务器", value: server.name)
            }
            TextField("名称", text: $draft.name, prompt: Text("比如：构建、看日志"))
            VStack(alignment: .leading, spacing: 6) {
                Text("命令内容")
                TextEditor(text: $draft.content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                Text("支持多行，原样执行，不做任何替换")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("工作目录", text: $draft.workingDirectory, prompt: Text("可选，填了就覆盖服务器的工作目录"))
            // 生产环境强制确认且不能关闭。
            Toggle("执行前确认", isOn: isProduction ? .constant(true) : $draft.confirmBeforeRun)
                .disabled(isProduction)
            if isProduction {
                Text("生产环境服务器的命令总是需要确认").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        do {
            if let command {
                try model.library.updateCommand(command, with: draft)
            } else if let server {
                try model.library.createCommand(draft, on: server)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 凭据

struct CredentialForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let credential: Credential?
    var onSaved: (Credential) -> Void = { _ in }
    @State private var draft: CredentialDraft
    @State private var error: String?
    @State private var revealPassword = false

    init(credential: Credential?, onSaved: @escaping (Credential) -> Void = { _ in }) {
        self.credential = credential
        self.onSaved = onSaved
        _draft = State(initialValue: credential.map(CredentialDraft.init) ?? CredentialDraft())
    }

    var body: some View {
        FormShell(title: credential == nil ? "新建凭据" : "编辑凭据", error: error, save: save) {
            TextField("名称", text: $draft.name, prompt: Text("比如：测试环境 root"))
            TextField("用户名", text: $draft.username)
            HStack {
                if revealPassword {
                    TextField("密码", text: $draft.password)
                } else {
                    SecureField("密码", text: $draft.password)
                }
                Button { revealPassword.toggle() } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealPassword ? "隐藏密码" : "显示密码")
            }
            TextField("备注", text: $draft.note, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    private func save() {
        do {
            let saved: Credential
            if let credential {
                try model.library.updateCredential(credential, with: draft)
                saved = credential
            } else {
                saved = try model.library.createCredential(draft)
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 分组

struct GroupNameForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let group: ServerGroup?
    @State private var name: String
    @State private var error: String?

    init(group: ServerGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
    }

    var body: some View {
        FormShell(title: group == nil ? "新建分组" : "重命名分组", error: error, save: save) {
            TextField("名称", text: $name, prompt: Text("比如：LIMS 测试"))
        }
    }

    private func save() {
        do {
            if let group {
                try model.library.renameGroup(group, to: name)
            } else {
                try model.library.createGroup(name: name)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

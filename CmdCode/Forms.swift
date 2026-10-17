import CmdCodeCore
import SwiftData
import SwiftUI

/// 表单通用外壳：标题区、字段区、底部的错误提示与取消/保存按钮。
private struct FormShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String? = nil
    let error: String?
    let save: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(Theme.body).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(spacing: 8) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(Theme.small)
                        .foregroundStyle(Theme.danger)
                        .labelStyle(TightLabelStyle())
                        .lineLimit(2)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Theme.subtleFill)
        }
        .frame(width: 500)
        .background(Theme.content)
    }
}

/// 外观与输入框一致的下拉选择。
private struct ThemedPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var placeholder = "请选择"

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack {
                Text(options.first { $0.value == selection }?.title ?? placeholder)
                    .foregroundStyle(options.contains { $0.value == selection } ? .primary : Theme.faint)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(Theme.body)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// 带说明文字的开关行。
private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyMedium)
                Text(detail).font(Theme.small).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card()
    }
}

private func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

// MARK: - 服务器

struct ServerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(sort: ServerGroup.displayOrder) private var groups: [ServerGroup]
    @Query(sort: \Credential.createdAt) private var credentials: [Credential]

    let server: Server?
    @State private var draft: ServerDraft
    @State private var portText: String
    @State private var error: String?
    @State private var creatingCredential = false

    init(server: Server?, presetGroup: ServerGroup?) {
        self.server = server
        let draft = server.map(ServerDraft.init) ?? ServerDraft(group: presetGroup)
        _draft = State(initialValue: draft)
        _portText = State(initialValue: String(draft.port))
    }

    var body: some View {
        FormShell(title: server == nil ? "新建服务器" : "编辑服务器",
                  subtitle: "通过 SSH 用户名 + 密码登录", error: error, save: save) {
            FormField(title: "名称") {
                ThemedTextField(placeholder: "比如：232 - lims 主服务", text: $draft.name)
            }
            HStack(alignment: .top, spacing: 12) {
                FormField(title: "主机") {
                    ThemedTextField(placeholder: "10.0.144.232", text: $draft.host, monospaced: true)
                }
                FormField(title: "端口") {
                    ThemedTextField(placeholder: "22", text: $portText, monospaced: true)
                }
                .frame(width: 96)
            }
            HStack(alignment: .top, spacing: 12) {
                FormField(title: "登录凭据") {
                    HStack(spacing: 6) {
                        ThemedPicker(options: credentials.map { ($0 as Credential?, "\($0.name) · \($0.username)") },
                                     selection: $draft.credential)
                        Button { creatingCredential = true } label: { Image(systemName: "plus") }
                            .buttonStyle(IconButtonStyle(size: 30))
                            .help("新建凭据")
                    }
                }
                FormField(title: "分组") {
                    ThemedPicker(options: [(nil as ServerGroup?, Library.ungroupedTitle)]
                                    + groups.map { ($0 as ServerGroup?, $0.name) },
                                 selection: $draft.group)
                }
                .frame(width: 170)
            }
            FormField(title: "工作目录", hint: "可选，绝对路径；执行命令前会先 cd 进去") {
                ThemedTextField(placeholder: "/usr/local/app/lims", text: $draft.workingDirectory, monospaced: true)
            }
            ToggleRow(title: "生产环境", detail: "红色显示，所有命令执行前强制确认",
                      isOn: $draft.isProduction, tint: Theme.danger)
            FormField(title: "备注") {
                ThemedTextField(placeholder: "可选", text: $draft.note)
            }
        }
        .sheet(isPresented: $creatingCredential) {
            CredentialForm(credential: nil) { draft.credential = $0 }
                .environment(model)
        }
    }

    private func save() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
            error = LibraryError.invalidPort.errorDescription
            return
        }
        draft.port = port
        do {
            if let server {
                try model.library.updateServer(server, with: draft)
            } else {
                let s = try model.library.createServer(draft)
                model.showServer(s)
            }
            dismiss()
        } catch {
            self.error = message(for: error)
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
    @FocusState private var editorFocused: Bool

    init(server: Server?, command: ServerCommand?) {
        self.server = server
        self.command = command
        _draft = State(initialValue: command.map(CommandDraft.init) ?? CommandDraft())
    }

    private var isProduction: Bool { server?.isProduction ?? false }

    var body: some View {
        FormShell(title: command == nil ? "新建命令" : "编辑命令",
                  subtitle: server.map { "服务器：\($0.name)" }, error: error, save: save) {
            FormField(title: "名称") {
                ThemedTextField(placeholder: "比如：构建、看日志", text: $draft.name)
            }
            FormField(title: "命令内容", hint: "支持多行，原样执行，不做任何替换") {
                TextEditor(text: $draft.content)
                    .font(Theme.mono)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(6)
                    .frame(height: 150)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(editorFocused ? Color.accentColor.opacity(0.7) : Theme.borderStrong,
                                          lineWidth: editorFocused ? 1.5 : 1))
            }
            FormField(title: "工作目录", hint: "可选，填了就覆盖服务器的工作目录") {
                ThemedTextField(placeholder: server?.workingDirectory.isEmpty == false ? "沿用服务器：\(server!.workingDirectory)" : "/usr/local/app",
                                text: $draft.workingDirectory, monospaced: true)
            }
            // 生产环境强制确认且不能关闭。
            ToggleRow(title: "执行前确认",
                      detail: isProduction ? "生产环境服务器的命令总是需要确认" : "点击后先弹出确认框再执行",
                      isOn: isProduction ? .constant(true) : $draft.confirmBeforeRun)
                .disabled(isProduction)
            ToggleRow(title: "执行完留在 shell",
                      detail: "命令结束或按 Ctrl-C 后不断开，继续在服务器上输入命令",
                      isOn: $draft.stayInShell)
        }
    }

    private func save() {
        do {
            if let command {
                try model.library.updateCommand(command, with: draft)
            } else if let server {
                try model.library.createCommand(draft, on: server)
                model.expandedServers.insert(server.persistentModelID)
            }
            dismiss()
        } catch {
            self.error = message(for: error)
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
        FormShell(title: credential == nil ? "新建凭据" : "编辑凭据",
                  subtitle: "多台服务器可以共用，改一次密码全部生效", error: error, save: save) {
            FormField(title: "名称") {
                ThemedTextField(placeholder: "比如：测试环境 root", text: $draft.name)
            }
            FormField(title: "用户名") {
                ThemedTextField(placeholder: "root", text: $draft.username, monospaced: true)
            }
            FormField(title: "密码") {
                HStack(spacing: 6) {
                    ThemedTextField(placeholder: "", text: $draft.password, monospaced: true, secure: !revealPassword)
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help(revealPassword ? "隐藏密码" : "显示密码")
                }
            }
            FormField(title: "备注") {
                ThemedTextField(placeholder: "可选", text: $draft.note)
            }
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
            self.error = message(for: error)
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
            FormField(title: "名称") {
                ThemedTextField(placeholder: "比如：LIMS 测试", text: $name)
            }
        }
    }

    private func save() {
        do {
            if let group {
                try model.library.renameGroup(group, to: name)
            } else {
                let g = try model.library.createGroup(name: name)
                model.expandedSections.insert(.group(g.persistentModelID))
            }
            dismiss()
        } catch {
            self.error = message(for: error)
        }
    }
}

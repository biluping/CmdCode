import CmdCodeCore
import SwiftData
import SwiftUI

/// 密码管理：凭据列表、使用情况、显示/复制密码。
struct CredentialsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Credential.createdAt) private var credentials: [Credential]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("密码管理").font(.title2.bold())
                    Spacer()
                    Button("新建凭据", systemImage: "plus") { model.sheet = .newCredential }
                }
                Text("密码明文保存在本机数据库中，仅适合个人电脑使用。")
                    .font(.caption).foregroundStyle(.secondary)

                if credentials.isEmpty {
                    ContentUnavailableView("还没有凭据", systemImage: "key",
                                           description: Text("新建一条凭据后，服务器就可以引用它登录"))
                        .padding(.top, 40)
                }
                ForEach(credentials) { CredentialCard(credential: $0) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("密码管理")
    }
}

private struct CredentialCard: View {
    @Environment(AppModel.self) private var model
    let credential: Credential

    @State private var revealed = false
    @State private var showUsers = false
    @State private var copied = false

    private var users: [Server] { model.library.servers(using: credential) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.name).bold()
                    Text(credential.username).foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑") { model.sheet = .editCredential(credential) }
                Button(role: .destructive) { model.requestDelete(credential) } label: {
                    Image(systemName: "trash")
                }
                .help("删除")
            }

            password

            if !credential.note.isEmpty {
                Text(credential.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            usage
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var password: some View {
        HStack(spacing: 8) {
            Text("密码").foregroundStyle(.secondary)
            Text(revealed ? credential.password : String(repeating: "•", count: 10))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(revealed ? "隐藏" : "显示")
            Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("复制，60 秒后自动清除")
            if copied {
                Text("已复制，60 秒后从剪贴板清除").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var usage: some View {
        let users = users
        if users.isEmpty {
            Text("未被使用").font(.callout).foregroundStyle(.secondary)
        } else {
            DisclosureGroup("被 \(users.count) 台服务器使用", isExpanded: $showUsers) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(users) { server in
                        Button(server.name) { model.showServer(server) }
                            .buttonStyle(.link)
                            .foregroundStyle(server.isProduction ? Color.red : Color.accentColor)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func copy() {
        model.copyPassword(credential)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            copied = false
        }
    }
}

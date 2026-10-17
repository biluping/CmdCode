import CmdCodeCore
import SwiftData
import SwiftUI

/// 密码管理：凭据列表、使用情况、显示/复制密码。
struct CredentialsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Credential.createdAt) private var credentials: [Credential]

    var body: some View {
        Page(headerTitle: "密码管理") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("密码管理").font(Theme.title)
                Text("多台服务器可以共用一条凭据，改一次密码全部生效。密码明文保存在本机数据库中，仅适合个人电脑使用。")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "凭据", count: credentials.count) {
                    Button { model.sheet = .newCredential } label: { Label("新建", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle())
                }
                if credentials.isEmpty {
                    EmptyHint(text: "还没有凭据，新建一条后服务器就可以引用它登录")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(credentials.enumerated()), id: \.element.id) { index, credential in
                            if index > 0 { CardDivider() }
                            CredentialRow(credential: credential)
                        }
                    }
                    .card()
                }
            }
        }
    }
}

private struct CredentialRow: View {
    @Environment(AppModel.self) private var model
    let credential: Credential

    @State private var revealed = false
    @State private var expanded = false
    @State private var copied = false
    @State private var hovering = false

    private var users: [Server] { model.library.servers(using: credential) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                IconTile(systemImage: "key")
                VStack(alignment: .leading, spacing: 3) {
                    Text(credential.name).font(Theme.bodyMedium)
                    HStack(spacing: 6) {
                        Text(credential.username).font(Theme.mono)
                        Text("·").foregroundStyle(Theme.faint)
                        Text(users.isEmpty ? "未被使用" : "被 \(users.count) 台服务器使用")
                    }
                    .font(Theme.small)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                password
                Menu {
                    Button("编辑") { model.sheet = .editCredential(credential) }
                    Divider()
                    Button("删除", role: .destructive) { model.requestDelete(credential) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

            if expanded { details }
        }
        .background(hovering && !expanded ? Theme.hover : .clear)
        .onHover { hovering = $0 }
    }

    private var password: some View {
        HStack(spacing: 2) {
            Text(revealed ? credential.password : String(repeating: "•", count: 8))
                .font(Theme.mono)
                .foregroundStyle(revealed ? .primary : .secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
                .padding(.trailing, 4)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(IconButtonStyle())
                .help(revealed ? "隐藏" : "显示")
            Button { copy() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Theme.success : .secondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("复制，60 秒后自动从剪贴板清除")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !credential.note.isEmpty {
                Text(credential.note).font(Theme.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if users.isEmpty {
                Text("没有服务器使用这条凭据").font(Theme.small).foregroundStyle(Theme.faint)
            } else {
                Text("使用这条凭据的服务器").font(Theme.small).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(users) { server in
                        Button { model.showServer(server) } label: {
                            Label(server.name, systemImage: "server.rack")
                        }
                        .buttonStyle(PillButtonStyle(tint: server.isProduction ? Theme.danger : .primary))
                    }
                }
            }
        }
        .padding(.leading, 56)
        .padding(.trailing, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy() {
        model.copyPassword(credential)
        model.showToast("已复制密码，60 秒后自动清除")
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// 自动换行的横向排列。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

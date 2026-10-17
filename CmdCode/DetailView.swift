import CmdCodeCore
import SwiftData
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    var body: some View {
        switch model.selection {
        case .credentials:
            CredentialsView()
        case .server(let id):
            if let server = context.model(for: id) as? Server, !server.isDeleted {
                ServerDetailView(server: server)
            } else {
                WelcomeView()
            }
        case nil:
            WelcomeView()
        }
    }
}

/// 页面骨架：顶部栏 + 居中限宽的可滚动内容。
struct Page<Actions: View, Content: View>: View {
    let headerTitle: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: headerTitle) { actions }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) { content }
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 欢迎页

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "CmdCode") { EmptyView() }
            VStack(spacing: 18) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.faint)
                VStack(spacing: 6) {
                    Text("选择一台服务器").font(.system(size: 17, weight: .semibold))
                    Text("在左侧展开服务器，点击命令即可在终端里执行")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    shortcut("搜索服务器和命令", "⌘K")
                    shortcut("新建服务器", "⌘N")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func shortcut(_ title: String, _ key: String) -> some View {
        HStack(spacing: 24) {
            Text(title).font(Theme.body).foregroundStyle(.secondary)
            Spacer()
            KeyCap(text: key)
        }
        .frame(width: 220)
    }
}

// MARK: - 服务器详情

struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        Page(headerTitle: [server.group?.name ?? Library.ungroupedTitle, server.name].joined(separator: " / ")) {
            Button { model.testConnection(server) } label: {
                Label("测试连接", systemImage: "bolt")
            }
            .buttonStyle(PillButtonStyle())
            Button { model.sheet = .editServer(server) } label: { Image(systemName: "pencil") }
                .buttonStyle(IconButtonStyle())
                .help("编辑")
            Menu {
                Button("复制服务器") { model.duplicate(server) }
                Divider()
                Button("删除服务器", role: .destructive) { model.requestDelete(server) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
        } content: {
            header
            info
            commands
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(server.isProduction ? Theme.danger : .secondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(server.isProduction ? Theme.danger.opacity(0.1) : Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(server.name).font(Theme.title)
                    if server.isProduction {
                        Chip(text: "生产环境", systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
                    }
                }
                Text(sshAddress)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var sshAddress: String {
        "\(server.credential?.username ?? "?")@\(server.host):\(server.port)"
    }

    private var info: some View {
        VStack(spacing: 0) {
            infoRow("主机", "\(server.host)", mono: true)
            CardDivider()
            infoRow("端口", "\(server.port)", mono: true)
            CardDivider()
            infoRow("登录凭据", server.credential.map { "\($0.name) · \($0.username)" } ?? "未配置")
            CardDivider()
            infoRow("分组", server.group?.name ?? Library.ungroupedTitle)
            CardDivider()
            infoRow("工作目录", server.workingDirectory.isEmpty ? "—" : server.workingDirectory, mono: !server.workingDirectory.isEmpty)
            if !server.note.isEmpty {
                CardDivider()
                infoRow("备注", server.note)
            }
        }
        .card()
    }

    private func infoRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(mono ? Theme.mono : Theme.body)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "命令", count: server.commands.count) {
                Button { model.sheet = .newCommand(server) } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            }
            if server.commands.isEmpty {
                EmptyHint(text: "还没有命令")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(server.sortedCommands.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { CardDivider() }
                        CommandCardRow(command: command)
                    }
                }
                .card()
            }
        }
    }
}

private struct CommandCardRow: View {
    @Environment(AppModel.self) private var model
    let command: ServerCommand
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemImage: "terminal")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(command.name).font(Theme.bodyMedium)
                    if command.requiresConfirmation {
                        Chip(text: "执行前确认", tint: .orange)
                    }
                    if let dir = ScriptBuilder.normalizedWorkingDirectory(command.workingDirectory) {
                        Chip(text: dir, systemImage: "folder")
                    }
                }
                Text(summary)
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { model.run(command) } label: { Label("运行", systemImage: "play.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .opacity(hovering ? 1 : 0)
            Menu {
                Button("编辑") { model.sheet = .editCommand(command) }
                Button("复制") { model.duplicate(command) }
                Divider()
                Button("删除", role: .destructive) { model.pendingDeletion = .command(command) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.run(command) }
        .contextMenu {
            Button("执行") { model.run(command) }
            Button("编辑") { model.sheet = .editCommand(command) }
            Button("复制") { model.duplicate(command) }
        }
    }

    /// 多行命令显示第一行，并标出总行数。
    private var summary: String {
        let lines = command.content.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return "" }
        return lines.count > 1 ? "\(first)  … 共 \(lines.count) 行" : String(first)
    }
}

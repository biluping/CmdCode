import CmdCodeCore
import SwiftData
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    var body: some View {
        switch model.selection {
        case .credentials:
            ContentUnavailableView("密码管理", systemImage: "key", description: Text("下一步实现"))
        case .server(let id):
            if let server = context.model(for: id) as? Server, !server.isDeleted {
                ServerDetailView(server: server)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("选择一台服务器", systemImage: "server.rack",
                               description: Text("在左侧展开服务器，点击命令即可在终端里执行"))
    }
}

/// 服务器详情和命令列表。
struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                info
                commands
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(server.name)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(server.name)
                .font(.title2.bold())
                .foregroundStyle(server.isProduction ? Color.red : Color.primary)
            if server.isProduction {
                Text("生产环境")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.15), in: Capsule())
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("测试连接", systemImage: "bolt.horizontal") { model.testConnection(server) }
            Button("编辑", systemImage: "pencil") { model.sheet = .editServer(server) }
        }
    }

    private var info: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("主机", "\(server.host):\(server.port)")
            row("登录凭据", server.credential.map { "\($0.name)（\($0.username)）" } ?? "未配置")
            row("分组", server.group?.name ?? Library.ungroupedTitle)
            row("工作目录", server.workingDirectory.isEmpty ? "—" : server.workingDirectory)
            if !server.note.isEmpty { row("备注", server.note) }
        }
        .textSelection(.enabled)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("命令").font(.headline)
                Spacer()
                Button("新建命令", systemImage: "plus") { model.sheet = .newCommand(server) }
            }
            if server.commands.isEmpty {
                Text("还没有命令").foregroundStyle(.secondary)
            }
            ForEach(server.sortedCommands) { command in
                CommandRow(command: command)
            }
        }
    }
}

private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let command: ServerCommand

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { model.run(command) } label: { Image(systemName: "play.fill") }
                .help("执行")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(command.name).bold()
                    if command.requiresConfirmation {
                        Image(systemName: "exclamationmark.shield").foregroundStyle(.orange).help("执行前确认")
                    }
                }
                Text(command.content)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let dir = ScriptBuilder.normalizedWorkingDirectory(command.workingDirectory) {
                    Label(dir, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("编辑") { model.sheet = .editCommand(command) }
            Button(role: .destructive) { model.pendingDeletion = .command(command) } label: {
                Image(systemName: "trash")
            }
            .help("删除")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("执行") { model.run(command) }
            Button("编辑") { model.sheet = .editCommand(command) }
            Button("复制") { model.duplicate(command) }
        }
    }
}

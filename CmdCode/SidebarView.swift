import CmdCodeCore
import SwiftData
import SwiftUI

/// 左侧栏：分组 → 服务器 → 命令。展开状态不记忆，每次启动全部折叠。
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ServerGroup.createdAt) private var groups: [ServerGroup]
    @Query(sort: \Server.createdAt) private var servers: [Server]

    @State private var expandedSections: Set<SidebarSection.ID> = []
    @State private var expandedServers: Set<PersistentIdentifier> = []

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Button { model.sheet = .newServer(group: nil) } label: {
                    Label("新建服务器", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Label("密码管理", systemImage: "key")
                    .tag(SidebarSelection.credentials)
            }

            Section {
                ForEach(SidebarSection.make(groups: groups, servers: servers)) { section in
                    sectionRow(section)
                }
            } header: {
                HStack {
                    Text("服务器")
                    Spacer()
                    Button { model.sheet = .newGroup } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless)
                        .help("新建分组")
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: 分组

    private func sectionRow(_ section: SidebarSection) -> some View {
        let isExpanded = expandedSections.contains(section.id)
        return DisclosureGroup(isExpanded: toggle(section.id, in: $expandedSections)) {
            ForEach(section.servers) { serverRow($0) }
        } label: {
            HStack {
                Label(section.title, systemImage: "folder")
                Spacer()
                if !isExpanded {
                    Text("\(section.serverCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contextMenu { groupMenu(section.group) }
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: ServerGroup?) -> some View {
        Button("新建服务器") { model.sheet = .newServer(group: group) }
        // “未分组”不能重命名和删除。
        if let group {
            Button("重命名") { model.sheet = .renameGroup(group) }
            Divider()
            Button("删除", role: .destructive) { model.pendingDeletion = .group(group) }
        }
    }

    // MARK: 服务器

    private func serverRow(_ server: Server) -> some View {
        DisclosureGroup(isExpanded: toggle(server.persistentModelID, in: $expandedServers)) {
            ForEach(server.sortedCommands) { commandRow($0) }
        } label: {
            Label(server.name, systemImage: "server.rack")
                .foregroundStyle(server.isProduction ? Color.red : Color.primary)
                .contextMenu { serverMenu(server) }
        }
        .tag(SidebarSelection.server(server.persistentModelID))
    }

    @ViewBuilder
    private func serverMenu(_ server: Server) -> some View {
        Button("新建命令") { model.sheet = .newCommand(server) }
        Button("编辑") { model.sheet = .editServer(server) }
        Button("复制") { model.duplicate(server) }
        Menu("移动到分组") {
            ForEach(groups) { g in
                Button(g.name) { model.move(server, to: g) }
                    .disabled(server.group === g)
            }
            Divider()
            Button(Library.ungroupedTitle) { model.move(server, to: nil) }
                .disabled(server.group == nil)
        }
        Divider()
        Button("删除", role: .destructive) { model.requestDelete(server) }
    }

    // MARK: 命令

    private func commandRow(_ command: ServerCommand) -> some View {
        // 点击即执行；需要确认时 AppModel 会先弹出确认框。
        Button { model.run(command) } label: {
            Label(command.name, systemImage: "play.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("执行") { model.run(command) }
            Button("编辑") { model.sheet = .editCommand(command) }
            Button("复制") { model.duplicate(command) }
            Divider()
            Button("删除", role: .destructive) { model.pendingDeletion = .command(command) }
        }
    }

    private func toggle<ID: Hashable>(_ id: ID, in set: Binding<Set<ID>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }
}

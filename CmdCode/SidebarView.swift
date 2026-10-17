import CmdCodeCore
import SwiftData
import SwiftUI

/// 左侧栏：顶部操作 + 分组 → 服务器 → 命令 三层树 + 底部状态。
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ServerGroup.createdAt) private var groups: [ServerGroup]
    @Query(sort: \Server.createdAt) private var servers: [Server]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 留给红黄绿按钮的位置
            HStack {
                Spacer()
            }
            .frame(height: 44)
            .background(WindowDragArea())

            VStack(spacing: 2) {
                Button { model.sheet = .newServer(group: nil) } label: {
                    Label("新建服务器", systemImage: "plus")
                }
                .buttonStyle(SidebarProminentButtonStyle())
                .padding(.bottom, 6)

                SidebarItem(icon: "magnifyingglass", title: "搜索") {
                    KeyCap(text: "⌘K")
                } action: {
                    model.isSearching = true
                }

                SidebarItem(icon: "key", title: "密码管理", selected: model.selection == .credentials) {
                    EmptyView()
                } action: {
                    model.selection = .credentials
                }

                SidebarItem(icon: "terminal", title: "终端", selected: model.selection == .terminal) {
                    if model.runningSessionCount > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.success).frame(width: 6, height: 6)
                            Text("\(model.runningSessionCount)")
                        }
                        .font(Theme.small)
                        .foregroundStyle(.secondary)
                        .help("\(model.runningSessionCount) 个命令正在运行")
                    } else if !model.sessions.isEmpty {
                        Text("\(model.sessions.count)").font(Theme.small).foregroundStyle(Theme.faint)
                    }
                } action: {
                    model.selection = .terminal
                }
            }
            .padding(.horizontal, 10)

            HStack {
                Text("服务器")
                    .font(Theme.small)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.sheet = .newGroup } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("新建分组")
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 18)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(SidebarSection.make(groups: groups, servers: servers)) { section in
                        SectionRows(section: section, groups: groups)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.sshpassMissing ? Color.orange : Theme.success)
                .frame(width: 7, height: 7)
            Text(model.sshpassMissing ? "未安装 sshpass" : "sshpass 已就绪")
                .font(Theme.small)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(servers.count) 台服务器")
                .font(Theme.small)
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help(model.sshpassMissing ? SSHPassLocator.installHint : "")
    }
}

// MARK: - 顶部条目

/// 侧栏顶部的“新建服务器”：带描边的整行按钮。
private struct SidebarProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentBody(configuration: configuration)
    }

    private struct ProminentBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.body)
                .labelStyle(SidebarLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Theme.selected : hovering ? Theme.card.opacity(0.9) : Theme.card.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 13))
                .frame(width: 16)
            configuration.title
        }
    }
}

private struct SidebarItem<Trailing: View>: View {
    let icon: String
    let title: String
    var selected = false
    @ViewBuilder var trailing: Trailing
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title).font(Theme.body)
                Spacer()
                trailing
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .rowHighlight(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 树

/// 树里的一行：缩进 + 展开箭头 + 图标 + 标题 + 右侧附加信息。
private struct TreeRow<Trailing: View>: View {
    var depth: Int
    var isExpanded: Bool?
    let icon: String
    var iconTint: Color = .secondary
    let title: String
    var titleTint: Color = .primary
    var selected = false
    @ViewBuilder var trailing: Trailing
    var onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let isExpanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                        .onTapGesture { onToggle?() }
                } else {
                    Color.clear
                }
            }
            .frame(width: 12, height: 12)

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconTint)
                .frame(width: 16)
            Text(title)
                .font(Theme.body)
                .foregroundStyle(titleTint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.leading, 6 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 28)
        .rowHighlight(selected: selected)
    }
}

private struct SectionRows: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection
    let groups: [ServerGroup]

    private var isExpanded: Bool { model.expandedSections.contains(section.id) }

    var body: some View {
        TreeRow(depth: 0, isExpanded: isExpanded, icon: section.group == nil ? "tray" : "folder",
                title: section.title) {
            if !isExpanded {
                Text("\(section.serverCount)")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                    .monospacedDigit()
            }
        } onToggle: { toggle() }
        .onTapGesture { toggle() }
        .contextMenu { groupMenu }
        .animation(.easeOut(duration: 0.12), value: isExpanded)

        if isExpanded {
            ForEach(section.servers) { ServerRows(server: $0, groups: groups) }
            if section.servers.isEmpty {
                Text("没有服务器")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                    .padding(.leading, 40)
                    .frame(height: 26)
            }
        }
    }

    private func toggle() {
        if isExpanded { model.expandedSections.remove(section.id) } else { model.expandedSections.insert(section.id) }
    }

    @ViewBuilder
    private var groupMenu: some View {
        Button("新建服务器") { model.sheet = .newServer(group: section.group) }
        // “未分组”不能重命名和删除。
        if let group = section.group {
            Button("重命名") { model.sheet = .renameGroup(group) }
            Divider()
            Button("删除", role: .destructive) { model.pendingDeletion = .group(group) }
        }
    }
}

private struct ServerRows: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let groups: [ServerGroup]

    private var id: PersistentIdentifier { server.persistentModelID }
    private var isExpanded: Bool { model.expandedServers.contains(id) }
    private var isSelected: Bool { model.selection == .server(id) }

    var body: some View {
        TreeRow(depth: 1, isExpanded: isExpanded, icon: "server.rack",
                iconTint: server.isProduction ? Theme.danger : .secondary,
                title: server.name, titleTint: server.isProduction ? Theme.danger : .primary,
                selected: isSelected) {
            if server.isProduction {
                Text("生产").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.danger)
            }
        } onToggle: { toggle() }
        .onTapGesture {
            // 第一次点击选中并展开；已选中时再点切换展开。
            if isSelected { toggle() } else {
                model.selection = .server(id)
                model.expandedServers.insert(id)
            }
        }
        .contextMenu { serverMenu }

        if isExpanded {
            ForEach(server.sortedCommands) { CommandRow(command: $0) }
            if server.commands.isEmpty {
                Button { model.sheet = .newCommand(server) } label: {
                    Label("新建命令", systemImage: "plus")
                        .font(Theme.small)
                        .foregroundStyle(Theme.faint)
                        .labelStyle(TightLabelStyle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 62)
                .frame(height: 26)
            }
        }
    }

    private func toggle() {
        if isExpanded { model.expandedServers.remove(id) } else { model.expandedServers.insert(id) }
    }

    @ViewBuilder
    private var serverMenu: some View {
        Button("新建命令") { model.sheet = .newCommand(server) }
        Button("测试连接") { model.testConnection(server) }
        Divider()
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
}

private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let command: ServerCommand
    @State private var hovering = false

    var body: some View {
        // 点击即执行；需要确认时 AppModel 会先弹出确认框。
        Button { model.run(command) } label: {
            TreeRow(depth: 2, isExpanded: nil, icon: hovering ? "play.fill" : "play",
                    iconTint: hovering ? .accentColor : Theme.faint, title: command.name) {
                if command.requiresConfirmation {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("执行前确认")
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(command.content)
        .contextMenu {
            Button("执行") { model.run(command) }
            Divider()
            Button("编辑") { model.sheet = .editCommand(command) }
            Button("复制") { model.duplicate(command) }
            Divider()
            Button("删除", role: .destructive) { model.pendingDeletion = .command(command) }
        }
    }
}

import CmdCodeCore
import SwiftData
import SwiftUI

/// 左侧栏：顶部操作 + 分组 → 服务器 → 命令 三层树 + 底部状态。
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: ServerGroup.displayOrder) private var groups: [ServerGroup]
    @Query(sort: Server.displayOrder) private var servers: [Server]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 留给红黄绿按钮的位置
            HStack {
                Spacer()
            }
            .frame(height: 44)
            .background(WindowDragArea())

            VStack(spacing: 2) {
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

                SidebarItem(icon: "rectangle.stack", title: "标签页", selected: model.selection == .tabs) {
                    if model.runningSessionCount > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.success).frame(width: 6, height: 6)
                            Text("\(model.runningSessionCount)")
                        }
                        .font(Theme.small)
                        .foregroundStyle(.secondary)
                        .help("\(model.runningSessionCount) 个命令正在运行")
                    } else if !model.tabs.isEmpty {
                        Text("\(model.tabs.count)").font(Theme.small).foregroundStyle(Theme.faint)
                    }
                } action: {
                    model.selection = .tabs
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
                    .focusable(false)
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
            // 列表空白处右键；分组和服务器行有自己的菜单。
            .contextMenu {
                Button("新建服务器") { model.sheet = .newServer(group: nil) }
                Button("新建分组") { model.sheet = .newGroup }
            }

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
        // 不接收键盘焦点：否则窗口一打开焦点落在第一项上，会画出蓝色焦点环。
        .focusable(false)
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
    /// 不为 nil 时用它替代标题（原地重命名）。
    var titleEditor: AnyView? = nil
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
            if let titleEditor {
                titleEditor
            } else {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(titleTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.leading, 6 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 28)
        .rowHighlight(selected: selected)
    }
}

// MARK: - 拖动排序

/// 拖到某一行上时的放置位置：上方、下方，或放进去（服务器拖到分组标题上）。
enum DropSpot {
    case above, below, into
}

/// 树的通用放置处理：根据拖动的内容和鼠标在行内的位置决定放在哪，松手时交给 `perform`。
private struct TreeDropDelegate: DropDelegate {
    let model: AppModel
    /// 返回放置位置；nil 表示这一行不接受这次拖动。
    let spot: (DragItem, _ y: CGFloat) -> DropSpot?
    @Binding var indicator: DropSpot?
    let perform: (DragItem, DropSpot) -> Void

    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: indicator == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { indicator = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            indicator = nil
            model.dragging = nil
        }
        guard let item = model.dragging, let spot = indicator else { return false }
        withAnimation(.easeOut(duration: 0.15)) { perform(item, spot) }
        return true
    }

    private func update(_ info: DropInfo) {
        indicator = model.dragging.flatMap { spot($0, info.location.y) }
    }
}

private extension View {
    /// 拖动来源：开始拖动时记下拖的是什么。
    func treeDraggable(_ model: AppModel, _ item: @escaping () -> DragItem) -> some View {
        onDrag {
            model.dragging = item()
            return NSItemProvider(object: "cmdcode-sidebar" as NSString)
        }
    }

    /// 放置位置的提示：上/下方一条强调色细线，放进去时整行描边高亮。
    func dropIndicator(_ spot: DropSpot?, indent: CGFloat) -> some View {
        overlay {
            switch spot {
            case .above?:
                VStack { line(indent); Spacer() }
            case .below?:
                VStack { Spacer(); line(indent) }
            case .into?:
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                    .allowsHitTesting(false)
            case nil:
                EmptyView()
            }
        }
    }

    private func line(_ indent: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 6, height: 6)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .padding(.leading, indent)
        .frame(height: 6)
        .offset(y: 0)
        .allowsHitTesting(false)
    }
}

/// 鼠标在一行的上半部分还是下半部分。
private func half(_ y: CGFloat) -> DropSpot { y < 14 ? .above : .below }

// MARK: - 分组

private struct SectionRows: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection
    let groups: [ServerGroup]

    @State private var dropSpot: DropSpot?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var isExpanded: Bool { model.expandedSections.contains(section.id) }
    private var isRenaming: Bool {
        guard let group = section.group else { return false }
        return model.renamingGroup == group.persistentModelID
    }

    var body: some View {
        TreeRow(depth: 0, isExpanded: isExpanded, icon: section.group == nil ? "tray" : "folder",
                title: section.title, titleEditor: isRenaming ? AnyView(nameEditor) : nil) {
            if !isExpanded && !isRenaming {
                Text("\(section.serverCount)")
                    .font(Theme.small)
                    .foregroundStyle(Theme.faint)
                    .monospacedDigit()
            }
        } onToggle: { toggle() }
        .onTapGesture { if !isRenaming { toggle() } }
        .contextMenu { groupMenu }
        .modifier(GroupDragSource(group: section.group))
        .onDrop(of: [.text], delegate: TreeDropDelegate(model: model, spot: spot, indicator: $dropSpot) { item, spot in
            model.drop(item, onSection: section.group, spot: spot)
        })
        .dropIndicator(dropSpot, indent: 6)
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

    /// 分组拖到分组上：插到它前面（拖到“未分组”上即排到最后）。服务器拖到分组上：放进这个分组。
    private func spot(_ item: DragItem, _ y: CGFloat) -> DropSpot? {
        switch item {
        case .group(let g): g === section.group ? nil : .above
        case .server: .into
        case .command: nil
        }
    }

    private var nameEditor: some View {
        TextField("分组名称", text: $draftName)
            .textFieldStyle(.plain)
            .font(Theme.body)
            .focused($nameFocused)
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
            .onSubmit { commitRename() }
            .onExitCommand { model.renamingGroup = nil }
            .onChange(of: nameFocused) { if !nameFocused { commitRename() } }
            .onAppear {
                draftName = section.group?.name ?? ""
                DispatchQueue.main.async { nameFocused = true }
            }
    }

    private func startRenaming() {
        guard let group = section.group else { return }
        model.renamingGroup = group.persistentModelID
    }

    private func commitRename() {
        guard isRenaming, let group = section.group else { return }
        model.renamingGroup = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 名字为空或没变就当作取消
        guard !name.isEmpty, name != group.name else { return }
        model.perform { try model.library.renameGroup(group, to: name) }
    }

    private func toggle() {
        if isExpanded { model.expandedSections.remove(section.id) } else { model.expandedSections.insert(section.id) }
    }

    @ViewBuilder
    private var groupMenu: some View {
        Button("新建服务器") { model.sheet = .newServer(group: section.group) }
        // “未分组”不能重命名和删除。
        if section.group != nil {
            Button("重命名") { startRenaming() }
            Divider()
            Button("删除", role: .destructive) { model.pendingDeletion = .group(section.group!) }
        }
    }
}

/// “未分组”不能拖动，其他分组可以。
private struct GroupDragSource: ViewModifier {
    @Environment(AppModel.self) private var model
    let group: ServerGroup?

    func body(content: Content) -> some View {
        if let group {
            content.treeDraggable(model) { .group(group) }
        } else {
            content
        }
    }
}

// MARK: - 服务器

private struct ServerRows: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let groups: [ServerGroup]
    @State private var dropSpot: DropSpot?

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
        .treeDraggable(model) { .server(server) }
        .onDrop(of: [.text], delegate: TreeDropDelegate(model: model, spot: spot, indicator: $dropSpot) { item, spot in
            model.drop(item, onServer: server, spot: spot)
        })
        .dropIndicator(dropSpot, indent: 22)

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

    /// 服务器拖到服务器上：插到它前面或后面（展开时只能插到前面，避免插进它的命令中间）。
    private func spot(_ item: DragItem, _ y: CGFloat) -> DropSpot? {
        guard case .server(let s) = item, s !== server else { return nil }
        return isExpanded ? .above : half(y)
    }

    private func toggle() {
        if isExpanded { model.expandedServers.remove(id) } else { model.expandedServers.insert(id) }
    }

    @ViewBuilder
    private var serverMenu: some View {
        Button("新建命令") { model.sheet = .newCommand(server) }
        Button("登录服务器") { model.login(server) }
        Button("浏览文件") { model.openFiles(server) }
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

// MARK: - 命令

private struct CommandRow: View {
    @Environment(AppModel.self) private var model
    let command: ServerCommand
    @State private var hovering = false
    @State private var dropSpot: DropSpot?

    var body: some View {
        TreeRow(depth: 2, isExpanded: nil, icon: hovering ? "play.fill" : "play",
                iconTint: hovering ? .accentColor : Theme.faint, title: command.name) {
            EmptyView()
        }
        // 点击后先弹出确认框，确认了才执行。
        .onTapGesture { model.run(command) }
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
        .treeDraggable(model) { .command(command) }
        .onDrop(of: [.text], delegate: TreeDropDelegate(model: model, spot: spot, indicator: $dropSpot) { item, spot in
            model.drop(item, onCommand: command, spot: spot)
        })
        .dropIndicator(dropSpot, indent: 38)
    }

    /// 只能在同一台服务器内调整命令顺序。
    private func spot(_ item: DragItem, _ y: CGFloat) -> DropSpot? {
        guard case .command(let c) = item, c !== command, c.server === command.server else { return nil }
        return half(y)
    }
}

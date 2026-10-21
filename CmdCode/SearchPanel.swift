import CmdCodeCore
import SwiftData
import SwiftUI

/// ⌘K 命令面板：按服务器名、IP、命令名、命令内容搜索；没输入时显示常用操作。
/// ↑↓ 选择，回车：命令直接执行（确认规则照常），服务器在右侧显示详情；Esc 关闭。
struct SearchPanel: View {
    @Environment(AppModel.self) private var model
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private static let limit = 50

    private enum Action: CaseIterable {
        case newServer, credentials, newGroup, newCredential

        var title: String {
            switch self {
            case .newServer: "新建服务器"
            case .credentials: "密码管理"
            case .newGroup: "新建分组"
            case .newCredential: "新建凭据"
            }
        }

        var icon: String {
            switch self {
            case .newServer: "plus"
            case .credentials: "key"
            case .newGroup: "folder.badge.plus"
            case .newCredential: "person.badge.key"
            }
        }

        var shortcut: String? { self == .newServer ? "⌘N" : nil }
    }

    private enum Item: Identifiable {
        case server(Server)
        case command(ServerCommand)
        case action(Action)

        var id: String {
            switch self {
            case .server(let s): "s-\(s.persistentModelID.hashValue)"
            case .command(let c): "c-\(c.persistentModelID.hashValue)"
            case .action(let a): "a-\(a)"
            }
        }
    }

    private struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    private var query: String { model.searchQuery }
    private var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var sections: [Section] {
        if isEmptyQuery {
            return [Section(title: "操作", items: Action.allCases.map(Item.action))]
        }
        let results = model.library.search(query)
        return [
            Section(title: "服务器", items: results.servers.prefix(Self.limit).map(Item.server)),
            Section(title: "命令", items: results.commands.prefix(Self.limit).map(Item.command)),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        @Bindable var model = model
        let sections = sections
        let items = sections.flatMap(\.items)

        VStack(spacing: 0) {
            TextField("搜索服务器、IP、命令…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onSubmit { activate(items) }
                .onKeyPress(.downArrow) { move(1, count: items.count) }
                .onKeyPress(.upArrow) { move(-1, count: items.count) }
                .padding(.horizontal, 18)
                .frame(height: 52)

            Rectangle().fill(Theme.border).frame(height: 1)

            if items.isEmpty {
                Text("没有匹配的服务器或命令")
                    .font(Theme.body)
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                resultList(sections: sections, items: items)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(width: 620)
        .background(VisualEffectBackground(material: .popover, blending: .withinWindow))
        .background(Theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        // 刚出现时输入框可能还没进窗口（终端等 AppKit 视图仍占着焦点），放到下一轮再聚焦。
        .onAppear { focusField() }
        .onChange(of: model.searchFocusRequest) { focusField() }
        .onChange(of: query) { selectedIndex = 0 }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func resultList(sections: [Section], items: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(Theme.small)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.items) { item in
                            let index = items.firstIndex { $0.id == item.id } ?? 0
                            row(item, selected: index == selectedIndex)
                                .id(item.id)
                                .onHover { if $0 { selectedIndex = index } }
                                .onTapGesture {
                                    selectedIndex = index
                                    activate(items)
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) {
                if items.indices.contains(selectedIndex) {
                    proxy.scrollTo(items[selectedIndex].id)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .server(let server):
                icon("server.rack", tint: server.isProduction ? Theme.danger : .secondary)
                Text(server.name)
                    .foregroundStyle(server.isProduction ? Theme.danger : .primary)
                Spacer(minLength: 12)
                Text(verbatim: "\(server.host):\(server.port)").font(Theme.mono).foregroundStyle(.secondary)
            case .command(let command):
                icon("play.fill", tint: selected ? .accentColor : .secondary)
                Text(command.name)
                Text(firstLine(command.content))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let server = command.server {
                    Text(server.name)
                        .font(Theme.small)
                        .foregroundStyle(server.isProduction ? Theme.danger : .secondary)
                        .lineLimit(1)
                }
            case .action(let action):
                icon(action.icon, tint: .secondary)
                Text(action.title)
                Spacer()
                if let shortcut = action.shortcut { KeyCap(text: shortcut) }
            }
        }
        .font(Theme.body)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .frame(width: 18)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "选择")
            hint("↵", "执行 / 打开")
            hint("esc", "关闭")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(text).font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        return .handled
    }

    private func activate(_ items: [Item]) {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        close()
        switch item {
        case .server(let s): model.showServer(s)
        case .command(let c): model.run(c)
        case .action(.newServer): model.sheet = .newServer(group: nil)
        case .action(.credentials): model.selection = .credentials
        case .action(.newGroup): model.sheet = .newGroup
        case .action(.newCredential): model.sheet = .newCredential
        }
    }

    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func close() {
        model.isSearching = false
        model.searchQuery = ""
    }
}

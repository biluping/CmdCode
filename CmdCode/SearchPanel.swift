import CmdCodeCore
import SwiftData
import SwiftUI

/// ⌘K 搜索浮层：按服务器名、IP、命令名、命令内容搜索。
/// ↑↓ 选择，回车：命令直接执行（确认规则照常），服务器在右侧显示详情；Esc 关闭。
struct SearchPanel: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private static let limit = 50

    private enum Item: Identifiable {
        case server(Server)
        case command(ServerCommand)

        var id: PersistentIdentifier {
            switch self {
            case .server(let s): s.persistentModelID
            case .command(let c): c.persistentModelID
            }
        }
    }

    var body: some View {
        let results = model.library.search(query)
        let servers = Array(results.servers.prefix(Self.limit))
        let commands = Array(results.commands.prefix(Self.limit))
        // 键盘导航用的扁平列表：服务器在前，命令在后，与显示顺序一致。
        let items = servers.map(Item.server) + commands.map(Item.command)

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索服务器名、IP、命令名、命令内容", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { activate(items) }
                    .onKeyPress(.downArrow) { move(1, count: items.count) }
                    .onKeyPress(.upArrow) { move(-1, count: items.count) }
            }
            .padding(14)

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                if items.isEmpty {
                    Text("没有匹配的服务器或命令")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                } else {
                    resultList(servers: servers, commands: commands, items: items)
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func resultList(servers: [Server], commands: [ServerCommand], items: [Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !servers.isEmpty {
                        header("服务器")
                        ForEach(Array(servers.enumerated()), id: \.element.id) { offset, server in
                            row(index: offset, items: items) { serverLabel(server) }
                        }
                    }
                    if !commands.isEmpty {
                        header("命令")
                        ForEach(Array(commands.enumerated()), id: \.element.id) { offset, command in
                            row(index: servers.count + offset, items: items) { commandLabel(command) }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 380)
            .onChange(of: selectedIndex) {
                if items.indices.contains(selectedIndex) {
                    proxy.scrollTo(items[selectedIndex].id)
                }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private func row<Label: View>(index: Int, items: [Item], @ViewBuilder label: () -> Label) -> some View {
        label()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .id(items[index].id)
            .onHover { if $0 { selectedIndex = index } }
            .onTapGesture {
                selectedIndex = index
                activate(items)
            }
    }

    private func serverLabel(_ server: Server) -> some View {
        HStack {
            Image(systemName: "server.rack")
            Text(server.name).foregroundStyle(server.isProduction ? Color.red : Color.primary)
            Spacer()
            Text("\(server.host):\(server.port)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func commandLabel(_ command: ServerCommand) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "play.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                Text(firstLine(command.content))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let server = command.server {
                Text(server.name)
                    .font(.callout)
                    .foregroundStyle(server.isProduction ? Color.red : Color.secondary)
            }
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
        }
    }

    private func close() {
        model.isSearching = false
    }
}

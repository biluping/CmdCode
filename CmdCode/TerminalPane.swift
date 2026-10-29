import AppKit
import CmdCodeCore
import SwiftData
import SwiftUI

/// 右侧的标签页：顶部标签栏，下面是当前标签的内容——终端（带底部状态栏）或远程文件。
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            tabBar
            switch model.activeTab {
            case .terminal(let session):
                TerminalHost(session: session, browseFiles: browseFiles(for: session))
                    .id(session.id)
                    .padding(.leading, 10)
                    .padding(.top, 6)
                    .background(Theme.content)
                StatusBar(session: session)
            case .files(let browser):
                if let server = server(for: browser) {
                    FileBrowserView(server: server, browser: browser)
                        .id(browser.id)
                } else {
                    empty
                }
            case nil:
                empty
            }
        }
        .alert(tabCloseTitle, isPresented: isPresent($model.pendingTabClose)) {
            // 回车确认关闭，Esc 取消（破坏性按钮默认不响应回车，要显式指定）。
            Button("关闭", role: .destructive) { model.confirmTabClose() }
                .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: {
            Text(tabCloseMessage)
        }
        .alert("重新连接“\(model.pendingReconnect?.serverName ?? "")”？", isPresented: isPresent($model.pendingReconnect),
               presenting: model.pendingReconnect) { session in
            Button("重新连接", role: .destructive) { model.confirmReconnect(session) }
                .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("终端还连着服务器，重连会断开当前连接并结束远端进程。")
        }
    }

    /// 终端右键“浏览文件”：打开这个会话所属服务器的文件标签，跳到终端当前所在的目录。
    private func browseFiles(for session: TerminalSession) -> (() -> Void)? {
        guard let id = session.serverID else { return nil }
        return { [context, model] in
            guard let server = context.model(for: id) as? Server, !server.isDeleted else { return }
            model.openFiles(server, directory: session.currentDirectory)
        }
    }

    private func server(for browser: FileBrowserModel) -> Server? {
        guard let server = context.model(for: browser.serverID) as? Server, !server.isDeleted else { return nil }
        return server
    }

    private var tabCloseTitle: String {
        guard let list = model.pendingTabClose else { return "" }
        guard list.count == 1, let tab = list.first else { return "关闭 \(list.count) 个标签？" }
        switch tab {
        case .terminal(let s): return "关闭“\(s.title)”？"
        case .files(let b): return "关闭“\(b.serverName)”的文件标签？"
        }
    }

    private var tabCloseMessage: String {
        guard let list = model.pendingTabClose else { return "" }
        var lines: [String] = []
        let running = list.compactMap(\.session).filter(\.state.isRunning)
        if running.count == 1 {
            lines.append("“\(running[0].title)”还连着服务器，关闭会断开并结束远端进程。")
        } else if running.count > 1 {
            lines.append("\(running.count) 个终端还连着服务器，关闭会断开并结束远端进程。")
        }
        for b in list.compactMap(\.browser) {
            if b.isDirty, let path = b.openedPath { lines.append("\(path) 的修改还没有保存，关闭后会丢失。") }
            if let t = b.transfer { lines.append("\(t.description)，关闭会取消传输。") }
        }
        if lines.isEmpty, list.contains(where: { $0.session != nil }) { lines.append("终端输出不会保留。") }
        return lines.joined(separator: "\n")
    }

    // MARK: 标签栏

    private var tabBar: some View {
        HStack(spacing: 6) {
            CollapsedSidebarLeading()
                .padding(.leading, 16)
                .padding(.trailing, -8)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    TabStrip()
                        .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: model.activeTabID) {
                    if let id = model.activeTabID { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Spacer(minLength: 0)
            switch model.activeTab {
            case .terminal(let session): actions(for: session)
            case .files(let browser): actions(for: browser)
            case nil: EmptyView()
            }
        }
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// 终端标签右上角：命令终端有重新运行，登录终端有重连；都有浏览文件。和文件标签一样都用图标。
    @ViewBuilder
    private func actions(for session: TerminalSession) -> some View {
        if let plan = session.plan, !plan.command.isEmpty {
            Button { model.rerun(session) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle())
                .help("重新运行")
        }
        if session.isLogin {
            Button { model.reconnect(session) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(IconButtonStyle())
                .help(session.state.isRunning ? "重新连接（会断开当前连接，先确认）" : "重新连接")
        }
        if let browse = browseFiles(for: session) {
            Button(action: browse) { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle())
                .help("浏览文件（跳到终端当前所在的目录）")
        }
        moreMenu(closing: .terminal(session))
    }

    @ViewBuilder
    private func actions(for browser: FileBrowserModel) -> some View {
        if let server = server(for: browser) {
            Button { model.openTerminal(server, directory: browser.listing?.path) } label: { Image(systemName: "terminal") }
                .buttonStyle(IconButtonStyle())
                .help(model.terminal(for: server) == nil ? "登录服务器（新开终端标签）" : "切到这台服务器的终端标签")
            moreMenu(closing: .files(browser)) {
                Button("新开终端登录") { model.login(server, directory: browser.listing?.path) }
                Divider()
            }
        } else {
            moreMenu(closing: .files(browser))
        }
    }

    private func moreMenu(closing tab: WorkspaceTab, @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        Menu {
            extra()
            Button("关闭当前标签") { model.close(tab) }
            Button("关闭全部标签") { model.closeAll() }
            Button("关闭已结束的终端") { model.closeFinished() }
                .disabled(!model.sessions.contains { !$0.state.isRunning })
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("还没有打开的标签").font(.system(size: 15, weight: .semibold))
            Text("在左侧点击命令会打开终端标签，在服务器上选“浏览文件”会打开文件标签")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 标签

/// 一排标签，可以左右拖动调整顺序：拖着的标签跟着鼠标走，中心越过相邻标签的中线就和它交换位置。
/// 用 DragGesture 而不是 onDrag：后者在 macOS 上同一个视图第二次拖动时不再调用闭包（见 `treeDraggable`）。
private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @State private var frames: [UUID: CGRect] = [:]
    @State private var draggingID: UUID?
    /// 拖动开始时标签的左边缘，以及之后因交换位置而在布局中移动的距离。
    @State private var startMinX: CGFloat = 0
    @State private var shift: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// 鼠标还按着（松手后的落位动画期间为 false）。
    @State private var isDragging = false

    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(model.tabs) { tab in
                let dragging = draggingID == tab.id
                TabItem(tab: tab, isActive: tab.id == model.activeTab?.id)
                    .id(tab.id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabStrip")) } action: { frames[tab.id] = $0 }
                    .offset(x: dragging ? offset : 0)
                    .zIndex(dragging ? 1 : 0)
                    .opacity(dragging ? 0.85 : 1)
                    // 拖着的标签在布局里换位和偏移量同时变化、互相抵消，不做动画；相邻标签让位时有动画。
                    .transaction { if dragging && isDragging { $0.animation = nil } }
                    .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("tabStrip"))
                        .onChanged { drag(tab.id, translation: $0.translation.width) }
                        .onEnded { _ in endDrag() })
            }
        }
        .coordinateSpace(.named("tabStrip"))
    }

    private func drag(_ id: UUID, translation: CGFloat) {
        guard let frame = frames[id] else { return }
        if !isDragging || draggingID != id {
            draggingID = id
            isDragging = true
            startMinX = frame.minX
            shift = 0
            model.activeTabID = id
        }
        offset = translation - shift
        guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        let center = startMinX + frame.width / 2 + translation
        if index + 1 < model.tabs.count, let next = frames[model.tabs[index + 1].id], center > next.midX {
            withAnimation(.easeOut(duration: 0.15)) {
                model.moveTab(from: index, to: index + 1)
                shift += next.width + Self.spacing
                offset = translation - shift
            }
        } else if index > 0, let prev = frames[model.tabs[index - 1].id], center < prev.midX {
            withAnimation(.easeOut(duration: 0.15)) {
                model.moveTab(from: index, to: index - 1)
                shift -= prev.width + Self.spacing
                offset = translation - shift
            }
        }
    }

    private func endDrag() {
        isDragging = false
        withAnimation(.easeOut(duration: 0.15)) { offset = 0 }
        // 落位动画结束后再取消“拖动中”的样式。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !isDragging { draggingID = nil }
        }
    }
}

private struct TabItem: View {
    @Environment(AppModel.self) private var model
    let tab: WorkspaceTab
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            switch tab {
            case .terminal(let session):
                StatusDot(state: session.state)
                if session.isLogin {
                    // 登录终端不写“登录”两个字，用终端图标表示，标签上只留服务器名。
                    kindIcon("terminal")
                    nameLabel(session.serverName, production: session.isProduction)
                } else {
                    Text(session.commandName)
                        .font(isActive ? Theme.bodyMedium : Theme.body)
                        .lineLimit(1)
                    serverLabel(session.serverName, production: session.isProduction)
                }
            case .files(let browser):
                kindIcon(browser.transfer == nil ? "folder" : "arrow.up.arrow.down")
                nameLabel(browser.serverName, production: browser.isProduction)
                if browser.isDirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .help("有未保存的修改")
                }
            }
            Button { model.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering || isActive ? 1 : 0)
            .help(closeHelp)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .frame(maxWidth: 280)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isActive ? Theme.selected : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.activeTabID = tab.id }
        .help(title)
        .contextMenu {
            if let session = tab.session, let plan = session.plan, !plan.command.isEmpty {
                Button("重新运行") { model.rerun(session) }
                Divider()
            }
            if let session = tab.session, session.isLogin {
                Button("重新连接") { model.reconnect(session) }
                Divider()
            }
            Button("复制标签") { model.duplicate(tab) }
                .disabled(tab.session.map { $0.plan == nil } ?? false)
            Divider()
            Button("关闭") { model.close(tab) }
            Button("关闭其他标签") { model.closeOthers(than: tab) }
            Button("关闭全部标签") { model.closeAll() }
        }
    }

    /// 标签类型的图标：登录终端、文件。
    private func kindIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 14)
    }

    /// 没有命令名的标签（登录终端、文件）：服务器名当标题。
    private func nameLabel(_ name: String, production: Bool) -> some View {
        Text(name)
            .font(isActive ? Theme.bodyMedium : Theme.body)
            .foregroundStyle(production ? Theme.danger : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func serverLabel(_ name: String, production: Bool) -> some View {
        Text(name)
            .font(Theme.small)
            .foregroundStyle(production ? Theme.danger : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var title: String {
        switch tab {
        case .terminal(let s): s.isLogin ? "\(s.serverName)（登录终端）" : s.title
        case .files(let b): "\(b.serverName)（文件）" + (b.listing.map { "：\($0.path)" } ?? "")
        }
    }

    private var closeHelp: String {
        switch tab {
        case .terminal(let s): s.state.isRunning ? "关闭并结束远端进程（会先确认）" : "关闭（会先确认）"
        case .files(let b): b.isDirty ? "关闭（有未保存的修改，会先确认）" : "关闭（会先确认）"
        }
    }
}

/// 运行状态：运行中绿点，成功灰色对勾，失败红色。
/// 绿点不做呼吸动画：SwiftUI 的无限动画会让整个窗口每帧重算重绘，空闲时也占三成 CPU。
struct StatusDot: View {
    let state: TerminalSession.State

    var body: some View {
        Group {
            switch state {
            case .running:
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
            case .exited(0):
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            case .exited, .failed:
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
            }
        }
        .frame(width: 10)
    }
}

// MARK: - 状态栏

private struct StatusBar: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 14) {
            Label(session.address, systemImage: "network")
                .foregroundStyle(session.isProduction ? Theme.danger : .secondary)
            if let dir = session.workingDirectory {
                Label(dir, systemImage: "folder")
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusText(now: context.date))
                    .monospacedDigit()
            }
        }
        .font(Theme.small)
        .foregroundStyle(.secondary)
        .labelStyle(TightLabelStyle())
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.subtleFill)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func statusText(now: Date) -> String {
        switch session.state {
        case .running:
            return "运行中 · \(duration(now.timeIntervalSince(session.startedAt))) · Ctrl-C 中断"
        case .exited(let code):
            let took = duration((session.endedAt ?? now).timeIntervalSince(session.startedAt))
            return code.map { "已结束 · 退出码 \($0) · 用时 \(took)" } ?? "已结束 · 用时 \(took)"
        case .failed(let message):
            return "启动失败：\(message)"
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 终端视图宿主

/// 把会话的终端视图放进 SwiftUI。视图本身由会话持有，切换标签时滚动记录和进程都不受影响。
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let browseFiles: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = session.view
        view.onBrowseFiles = browseFiles
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.view.onBrowseFiles = browseFiles
    }
}

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
            Button("关闭", role: .destructive) { model.confirmTabClose() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(tabCloseMessage)
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
            if let t = b.transfer { lines.append("\(t.name) 正在\(t.kind == .upload ? "上传" : "下载")，关闭会取消传输。") }
        }
        if lines.isEmpty, list.contains(where: { $0.session != nil }) { lines.append("终端输出不会保留。") }
        return lines.joined(separator: "\n")
    }

    // MARK: 标签栏

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            TabItem(tab: tab, isActive: tab.id == model.activeTab?.id)
                                .id(tab.id)
                        }
                    }
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

    @ViewBuilder
    private func actions(for session: TerminalSession) -> some View {
        if session.plan != nil {
            Button { model.rerun(session) } label: { Label("重新运行", systemImage: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle())
        }
        moreMenu(closing: .terminal(session))
    }

    @ViewBuilder
    private func actions(for browser: FileBrowserModel) -> some View {
        if let server = server(for: browser) {
            Button { model.showServer(server) } label: { Image(systemName: "server.rack") }
                .buttonStyle(IconButtonStyle())
                .help("服务器详情")
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
                Text(session.commandName)
                    .font(isActive ? Theme.bodyMedium : Theme.body)
                    .lineLimit(1)
                serverLabel(session.serverName, production: session.isProduction)
            case .files(let browser):
                Image(systemName: browser.transfer == nil ? "folder.fill" : "arrow.up.arrow.down.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 10)
                Text("文件")
                    .font(isActive ? Theme.bodyMedium : Theme.body)
                    .lineLimit(1)
                serverLabel(browser.serverName, production: browser.isProduction)
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
            if let session = tab.session, session.plan != nil {
                Button("重新运行") { model.rerun(session) }
                Divider()
            }
            Button("关闭") { model.close(tab) }
            Button("关闭其他标签") { model.closeOthers(than: tab) }
        }
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
        case .terminal(let s): s.title
        case .files(let b): "\(b.serverName) / 文件" + (b.listing.map { "：\($0.path)" } ?? "")
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

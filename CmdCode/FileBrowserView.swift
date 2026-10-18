import AppKit
import CmdCodeCore
import SwiftUI

/// 服务器的远程文件页：上面路径栏，左边目录列表，右边只读查看文件内容。
struct FileBrowserView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @Bindable var browser: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: [server.name, "文件"].joined(separator: " / ")) {
                Button { model.showServer(server) } label: {
                    Label("服务器详情", systemImage: "server.rack")
                }
                .buttonStyle(PillButtonStyle())
                Button { model.login(server) } label: {
                    Label("登录服务器", systemImage: "terminal")
                }
                .buttonStyle(PillButtonStyle())
            }
            pathBar
            HSplitView {
                DirectoryList(browser: browser)
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 480)
                FilePreview(browser: browser)
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .onAppear { browser.start() }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(IconButtonStyle())
                .disabled(!browser.canGoUp)
                .help("上级目录")
            Button { browser.go(to: nil) } label: { Image(systemName: "house") }
                .buttonStyle(IconButtonStyle())
                .help("家目录")
            TextField("路径", text: $browser.pathInput)
                .textFieldStyle(.plain)
                .font(Theme.mono)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .onSubmit { browser.goToInput() }
            Group {
                if browser.isListing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle())
                        .help("刷新")
                }
            }
            .frame(width: 26)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - 目录列表

private struct DirectoryList: View {
    let browser: FileBrowserModel

    var body: some View {
        Group {
            if let error = browser.listError {
                VStack(alignment: .leading, spacing: 10) {
                    Label("打开目录失败", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.bodyMedium)
                        .foregroundStyle(Theme.danger)
                    Text(error)
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("重试") { browser.goToInput() }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let listing = browser.listing {
                if listing.entries.isEmpty {
                    EmptyHint(text: "空目录").padding(16)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(listing.entries) { entry in
                                EntryRow(entry: entry,
                                         selected: browser.openedPath == RemoteFileScript.join(listing.path, entry.name)) {
                                    browser.open(entry)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .opacity(browser.isListing ? 0.5 : 1)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct EntryRow: View {
    let entry: RemoteFileEntry
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 18)
                .overlay(alignment: .bottomTrailing) {
                    if entry.isSymlink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .offset(x: 3, y: 2)
                    }
                }
            Text(entry.name)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.kind == .other ? Theme.faint : .primary)
            if entry.kind == .file && !entry.isWritable {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.faint)
                    .help("没有写权限")
            }
            Spacer(minLength: 6)
            if entry.kind == .file {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .rowHighlight(selected: selected)
        .onTapGesture(perform: action)
        .help(tooltip)
    }

    private var icon: String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .file: "doc.text"
        case .other: entry.isSymlink ? "link" : "questionmark.square.dashed"
        }
    }

    private var tooltip: String {
        let time = entry.modified.formatted(date: .numeric, time: .shortened)
        return switch entry.kind {
        case .directory: "\(entry.name)\n修改时间 \(time)"
        case .file: "\(entry.name)\n\(entry.size) 字节 · 修改时间 \(time)"
        case .other: entry.isSymlink ? "\(entry.name)\n链接目标不存在" : "\(entry.name)\n不是普通文件或目录"
        }
    }
}

// MARK: - 文件内容

private struct FilePreview: View {
    let browser: FileBrowserModel

    var body: some View {
        if let path = browser.openedPath {
            VStack(spacing: 0) {
                header(path)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.faint)
                Text("点击左侧的文件查看内容").font(Theme.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(Theme.mono)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if let c = browser.content {
                if !c.isWritable { Chip(text: "只读", systemImage: "lock.fill") }
                Text(ByteCountFormatter.string(fromByteCount: Int64(c.data.count), countStyle: .file))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if browser.isReading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        if let error = browser.readError {
            message(error, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        } else if let c = browser.content {
            if let text = c.text {
                ReadOnlyTextView(text: text)
            } else {
                message("不是文本文件，无法显示", systemImage: "doc.questionmark", tint: .secondary)
            }
        } else {
            Color.clear
        }
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 22)).foregroundStyle(tint)
            Text(text).font(Theme.body).foregroundStyle(.secondary).textSelection(.enabled)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 只读、可选中的等宽文本，不自动折行（配置文件按原样对齐），可横向滚动。
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        // 关闭自动折行：文本容器无限宽，视图随内容横向伸展。
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scroll(.zero)
    }
}

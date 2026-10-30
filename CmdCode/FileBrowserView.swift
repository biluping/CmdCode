import AppKit
import CmdCodeCore
import SwiftData
import SwiftUI

/// 文件标签的内容（标签栏由 `TerminalPane` 提供）：上面路径栏，左边目录列表，右边查看和编辑文件内容。
struct FileBrowserView: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @Bindable var browser: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            HSplitView {
                DirectoryList(browser: browser)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 400)
                FilePreview(browser: browser)
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
            if let transfer = browser.transfer {
                TransferBar(transfer: transfer) { browser.cancelTransfer() }
            }
        }
        .onAppear { browser.start() }
        .sheet(item: Binding(get: { browser.choosingSendTarget.map(SendRequest.init) },
                             set: { browser.choosingSendTarget = $0?.path })) { request in
            SendFileSheet(path: request.path, sourceServerID: browser.serverID, targets: model.sendTargets()) { target, dir in
                browser.requestSend(request.path, to: target, directory: dir)
            }
        }
        .alert(sendTitle, isPresented: isPresent($browser.pendingSend), presenting: browser.pendingSend) { pending in
            Button(pending.exists ? "覆盖" : "发送", role: .destructive) { browser.send(pending) }
                .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text(pending.exists
                 ? "\(pending.target.serverName) 上已有 \(pending.targetPath)，覆盖后原内容无法恢复（权限和属主保持不变）。"
                 : "\(pending.target.serverName)：\(pending.targetPath)")
        }
        .alert("放弃未保存的修改？", isPresented: isPresent($browser.pendingDiscard)) {
            Button("放弃修改", role: .destructive) { browser.confirmDiscard() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(browser.openedPath ?? "") 的修改还没有保存，放弃后无法恢复。")
        }
        .alert("文件在打开后被修改过", isPresented: $browser.conflictPending) {
            Button("覆盖服务器上的版本", role: .destructive) { browser.save(force: true) }
            Button("重新载入（放弃我的修改）") { browser.reloadAfterConflict() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务器上的 \(browser.openedPath ?? "") 已经和你打开时不一样了，可能有别人改过。")
        }
        .alert("保存到生产环境服务器？", isPresented: $browser.productionSavePending) {
            Button("保存", role: .destructive) { browser.save() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(server.name)：\(browser.openedPath ?? "")")
        }
        .alert(uploadTitle, isPresented: isPresent($browser.pendingUpload), presenting: browser.pendingUpload) { pending in
            Button(pending.exists ? "覆盖" : "上传", role: .destructive) { browser.upload(pending) }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text(pending.exists
                 ? "\(server.name) 上已有 \(pending.target)，覆盖后原内容无法恢复（权限和属主保持不变）。"
                 : "\(server.name)：\(pending.target)")
        }
        .alert(browser.transferError?.title ?? "", isPresented: isPresent($browser.transferError)) {
            Button("好") {}
        } message: {
            Text(browser.transferError?.message ?? "")
        }
        .alert("保存失败", isPresented: isPresent($browser.saveError)) {
            Button("好") {}
        } message: {
            Text(browser.saveError ?? "")
        }
        .alert(deleteTitle, isPresented: isPresent($browser.pendingDelete), presenting: browser.pendingDelete) { path in
            Button("删除", role: .destructive) { browser.delete(path) }
            Button("取消", role: .cancel) {}
        } message: { path in
            Text(deleteMessage(path))
        }
        .alert("删除失败", isPresented: isPresent($browser.deleteError)) {
            Button("好") {}
        } message: {
            Text(browser.deleteError ?? "")
        }
    }

    private var sendTitle: String {
        guard let pending = browser.pendingSend else { return "" }
        let name = (pending.targetPath as NSString).lastPathComponent
        if pending.exists {
            return pending.target.isProduction ? "覆盖生产环境服务器上的“\(name)”？" : "覆盖“\(name)”？"
        }
        return "发送到生产环境服务器？"
    }

    private var deleteTitle: String {
        guard let path = browser.pendingDelete else { return "" }
        let name = (path as NSString).lastPathComponent
        return browser.isProduction ? "删除生产环境服务器上的“\(name)”？" : "删除“\(name)”？"
    }

    private func deleteMessage(_ path: String) -> String {
        var text = "\(server.name)：\(path)\n删除后无法恢复。"
        if path == browser.openedPath && browser.isDirty { text += "\n这个文件还有未保存的修改，会一起丢失。" }
        return text
    }

    private var uploadTitle: String {
        guard let pending = browser.pendingUpload else { return "" }
        let name = (pending.target as NSString).lastPathComponent
        if pending.exists { return browser.isProduction ? "覆盖生产环境服务器上的“\(name)”？" : "覆盖“\(name)”？" }
        return "上传到生产环境服务器？"
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
            Button {
                if let url = FilePanels.chooseUploadSource() { browser.requestUpload(url) }
            } label: { Label("上传", systemImage: "arrow.up.doc") }
                .buttonStyle(PillButtonStyle())
                .disabled(browser.listing == nil || browser.transfer != nil)
                .help("上传本地文件到当前目录")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - 目录列表

private struct DirectoryList: View {
    @Bindable var browser: FileBrowserModel
    /// 正有文件拖到列表上方。
    @State private var isDropTargeted = false

    @ViewBuilder private func menu(for entry: RemoteFileEntry, in directory: String) -> some View {
        let path = RemoteFileScript.join(directory, entry.name)
        if entry.kind == .file {
            Button("打开") { browser.open(entry) }
            Button("下载…") {
                if let url = FilePanels.chooseDownloadDestination(name: entry.name) { browser.download(path, to: url) }
            }
            .disabled(browser.transfer != nil)
            Button("发送到其他服务器…") { browser.choosingSendTarget = path }
                .disabled(browser.transfer != nil || browser.isCheckingSend)
            Divider()
        }
        Button("复制路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        // 目录不能删；指向目录的链接可以（只删链接本身）。
        if entry.kind != .directory || entry.isSymlink {
            Divider()
            Button("删除…", role: .destructive) { browser.requestDelete(path) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DirectorySearchField(text: $browser.nameFilter)
                .padding(8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
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
                    let entries = browser.visibleEntries
                    if entries.isEmpty {
                        EmptyHint(text: listing.entries.isEmpty ? "空目录" : "没有匹配的文件或目录").padding(16)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(entries) { entry in
                                    EntryRow(entry: entry,
                                             selected: browser.openedPath == RemoteFileScript.join(listing.path, entry.name)) {
                                        browser.open(entry)
                                    }
                                    .contextMenu { menu(for: entry, in: listing.path) }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // 从 Finder 拖文件进来上传到当前目录。
            .dropDestination(for: URL.self) { urls, _ in
                browser.requestDroppedUpload(urls)
            } isTargeted: { isDropTargeted = $0 && browser.listing != nil }
            .overlay { if isDropTargeted { dropHint } }
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                Label("松开上传到当前目录", systemImage: "arrow.up.doc")
                    .font(Theme.bodyMedium)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(4)
            .allowsHitTesting(false)
    }
}

/// 当前目录的文件名搜索：Esc 或右侧按钮清空。
private struct DirectorySearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
            TextField("搜索当前目录", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.faint)
                .focusable(false)
                .help("清空")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Theme.border))
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
    @Bindable var browser: FileBrowserModel

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
                .layoutPriority(-1)
            if let c = browser.content {
                if !c.isWritable { Chip(text: "只读", systemImage: "lock.fill").fixedSize() }
                if browser.isDirty { Chip(text: "未保存", tint: .orange).fixedSize() }
                Text(ByteCountFormatter.string(fromByteCount: Int64(c.data.count), countStyle: .file))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if browser.isReading || browser.isSaving { ProgressView().controlSize(.small) }
            Button {
                if let url = FilePanels.chooseDownloadDestination(name: (path as NSString).lastPathComponent) {
                    browser.download(path, to: url)
                }
            } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(IconButtonStyle())
                .help("下载到本地")
                .disabled(browser.transfer != nil)
            Button { browser.choosingSendTarget = path } label: { Image(systemName: "paperplane") }
                .buttonStyle(IconButtonStyle())
                .help("发送到其他服务器")
                .disabled(browser.transfer != nil || browser.isCheckingSend)
            Button { browser.requestDelete(path) } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle())
                .help("删除这个文件（会先确认）")
                .disabled(browser.isSaving)
            if browser.content != nil || browser.readError != nil {
                Button { browser.requestReload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .help("从服务器重新载入")
                    .disabled(browser.isReading || browser.isSaving)
            }
            if browser.isEditable {
                Button("还原") { browser.revert() }
                    .buttonStyle(PillButtonStyle())
                    .fixedSize()
                    .disabled(!browser.isDirty || browser.isSaving)
                    .help("撤销所有修改")
                Button { browser.requestSave() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle(tint: browser.isProduction ? Theme.danger : .accentColor))
                    .keyboardShortcut("s")
                    .fixedSize()
                    .disabled(!browser.isDirty || browser.isSaving)
                    .help(browser.isProduction ? "保存到生产环境服务器（会先确认）" : "保存到服务器（⌘S）")
            }
            Button { browser.requestClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help(browser.isDirty ? "关闭文件（放弃未保存的修改）" : "关闭文件")
                .disabled(browser.isSaving)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        if let error = browser.readError {
            message(error, systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        } else if let c = browser.content {
            if c.text != nil {
                CodeTextView(text: $browser.draft, isEditable: browser.isEditable && !browser.isSaving)
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

// MARK: - 上传下载

private struct TransferBar: View {
    let transfer: FileBrowserModel.Transfer
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text(transfer.description)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: transfer.total > 0 ? min(Double(transfer.done) / Double(transfer.total), 1) : 0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            Text("\(bytes(transfer.done)) / \(bytes(transfer.total))")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("取消", action: onCancel)
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var icon: String {
        switch transfer.kind {
        case .upload: "arrow.up.circle"
        case .download: "arrow.down.circle"
        case .send: "paperplane.circle"
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - 发送到其他服务器

private struct SendRequest: Identifiable {
    let path: String
    var id: String { path }
}

/// 选择目标服务器和目录。目录默认取目标服务器已打开的文件标签所在目录，否则是它的工作目录，空表示家目录。
private struct SendFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let path: String
    let sourceServerID: PersistentIdentifier
    let targets: [FileSendTarget]
    let onSend: (FileSendTarget, String) -> Void
    @State private var selected: PersistentIdentifier?
    @State private var directory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发送到其他服务器").font(.system(size: 15, weight: .semibold))
            Text(path)
                .font(Theme.mono)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("目标服务器").font(Theme.bodyMedium)
                Picker("目标服务器", selection: $selected) {
                    ForEach(targets) { t in
                        Text(t.serverID == sourceServerID ? "\(t.serverName)（当前服务器）" : t.serverName)
                            .foregroundStyle(t.isProduction ? Theme.danger : .primary)
                            .tag(Optional(t.serverID))
                    }
                }
                .labelsHidden()
                .onChange(of: selected) { directory = target?.directory ?? "" }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("目标目录").font(Theme.bodyMedium)
                TextField("留空表示家目录", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono)
                    .onSubmit(submit)
                Text("先下载到本机临时目录再上传过去，传完删除临时文件；同名文件会先确认是否覆盖。")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            if target?.isProduction == true {
                Label("目标是生产环境服务器，发送前会再确认一次", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.small)
                    .foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("发送", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            // 默认选第一台别的服务器。
            selected = (targets.first { $0.serverID != sourceServerID } ?? targets.first)?.serverID
            directory = target?.directory ?? ""
        }
    }

    private var target: FileSendTarget? {
        targets.first { $0.serverID == selected }
    }

    private func submit() {
        guard let target else { return }
        dismiss()
        onSend(target, directory)
    }
}

/// 选择本地文件的系统面板。
@MainActor
enum FilePanels {
    static func chooseDownloadDestination(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "下载到"
        panel.nameFieldStringValue = name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseUploadSource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择要上传的文件"
        panel.prompt = "上传"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 等宽文本编辑器：不自动折行（配置文件按原样对齐），可横向滚动；关掉智能引号等自动替换，
/// 免得把配置里的 `"` 换成中文引号。没有写权限时只读。
private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isEditable = isEditable
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        // 大文件只排版可见部分，打开和滚动都不卡。
        view.layoutManager?.allowsNonContiguousLayout = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
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
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        view.isEditable = isEditable
        // 只有外部换了内容（打开别的文件、重新载入、还原）才覆盖，打字时不动光标。
        if view.string != text {
            view.string = text
            if let storage = view.textStorage { view.undoManager?.removeAllActions(withTarget: storage) }
            view.scroll(.zero)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

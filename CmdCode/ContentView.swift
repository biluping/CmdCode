import CmdCodeCore
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            DetailView()
        }
        .sheet(item: $model.sheet) { route in
            SheetContent(route: route)
                .environment(model)
        }
        .alert("未安装 sshpass", isPresented: $model.sshpassMissing) {
            Button("好") {}
        } message: {
            Text(SSHPassLocator.installHint)
        }
        .alert(model.alert?.title ?? "", isPresented: isPresent($model.alert), presenting: model.alert) { _ in
            Button("好") {}
        } message: { Text($0.message) }
        .alert(executionTitle, isPresented: isPresent($model.pendingExecution),
               presenting: model.pendingExecution) { plan in
            Button("执行") { model.execute(plan) }
            Button("取消", role: .cancel) {}
        } message: { plan in
            Text("\(plan.target.username)@\(plan.target.host):\(plan.target.port)\n\n\(preview(plan.command))")
        }
        .alert(deletionTitle, isPresented: isPresent($model.pendingDeletion),
               presenting: model.pendingDeletion) { _ in
            Button("删除", role: .destructive) { model.confirmDeletion() }
            Button("取消", role: .cancel) {}
        } message: { Text(deletionMessage($0)) }
    }

    private var executionTitle: String {
        guard let plan = model.pendingExecution else { return "" }
        return "确认执行“\(plan.title)”？"
    }

    private var deletionTitle: String {
        switch model.pendingDeletion {
        case .group(let g): "删除分组“\(g.name)”？"
        case .server(let s, _): "删除服务器“\(s.name)”？"
        case .command(let c): "删除命令“\(c.name)”？"
        case .credential(let c): "删除凭据“\(c.name)”？"
        case nil: ""
        }
    }

    private func deletionMessage(_ pending: PendingDeletion) -> String {
        switch pending {
        case .group: return "组里的服务器会移到“\(Library.ungroupedTitle)”，服务器本身不会删除。"
        case .server(_, let names):
            return names.isEmpty ? "这台服务器没有命令。" : "以下命令会一起删除：\n" + names.joined(separator: "\n")
        case .command, .credential: return "删除后无法恢复。"
        }
    }

    /// 确认框里只预览命令的前几行。
    private func preview(_ command: String) -> String {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(8).joined(separator: "\n")
        return lines.count > 8 ? head + "\n…" : head
    }
}

/// 把可选值包装成 alert 需要的 `isPresented`。
@MainActor
func isPresent<T>(_ binding: Binding<T?>) -> Binding<Bool> {
    // Binding 的闭包要求 Sendable；这里只在主线程上读写，安全。
    nonisolated(unsafe) let binding = binding
    return Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
}

private struct SheetContent: View {
    let route: SheetRoute

    var body: some View {
        switch route {
        case .newServer(let g): ServerForm(server: nil, presetGroup: g)
        case .editServer(let s): ServerForm(server: s, presetGroup: nil)
        case .newCommand(let s): CommandForm(server: s, command: nil)
        case .editCommand(let c): CommandForm(server: c.server, command: c)
        case .newGroup: GroupNameForm(group: nil)
        case .renameGroup(let g): GroupNameForm(group: g)
        case .newCredential: CredentialForm(credential: nil)
        case .editCredential(let c): CredentialForm(credential: c)
        }
    }
}

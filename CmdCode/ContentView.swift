import CmdCodeCore
import SwiftData
import SwiftUI

/// 主窗口：无标题栏，左侧磨砂侧栏，右侧白色内容区。
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    static let sidebarWidth: CGFloat = 264

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Self.sidebarWidth)
                .background(VisualEffectBackground(material: .sidebar))
            Rectangle().fill(Theme.border).frame(width: 1)
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.content)
        }
        .ignoresSafeArea()
        .overlay {
            if model.isSearching {
                ZStack(alignment: .top) {
                    // 点击浮层外的区域关闭。
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { model.isSearching = false }
                    SearchPanel()
                        .padding(.top, 72)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isSearching)
        .onAppear { model.reopenWindow = { openWindow(id: "main") } }
        .animation(.spring(duration: 0.3), value: model.toast)
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
        .sheet(isPresented: isPresent($model.pendingExecution)) {
            if let plan = model.pendingExecution {
                ExecutionConfirmView(plan: plan) {
                    model.confirmExecution(plan)
                } onCancel: {
                    model.pendingExecution = nil
                }
            }
        }
        .alert(deletionTitle, isPresented: isPresent($model.pendingDeletion),
               presenting: model.pendingDeletion) { _ in
            Button("删除", role: .destructive) { model.confirmDeletion() }
            Button("取消", role: .cancel) {}
        } message: { Text(deletionMessage($0)) }
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

}

private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            Text(text).font(Theme.body).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(VisualEffectBackground(material: .popover, blending: .withinWindow))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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

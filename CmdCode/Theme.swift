import AppKit
import SwiftUI

/// 全局视觉规范：中性灰阶、细描边、圆角、紧凑行高。颜色都基于系统语义色，自动适配深色模式。
enum Theme {
    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 10

    /// 内容区底色（浅色模式下是白色）。
    static let content = Color(nsColor: .textBackgroundColor)
    static let card = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.09)
    static let borderStrong = Color.primary.opacity(0.15)
    static let hover = Color.primary.opacity(0.05)
    static let selected = Color.primary.opacity(0.085)
    static let subtleFill = Color.primary.opacity(0.04)
    static let faint = Color.primary.opacity(0.4)
    static let danger = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)

    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let title = Font.system(size: 20, weight: .semibold)
}

// MARK: - 磨砂背景

/// 系统的半透明材质（侧栏、浮层用）。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - 悬停与选中

/// 圆角的悬停/选中底色，侧栏和列表行通用。
struct RowHighlight: ViewModifier {
    var isSelected = false
    var radius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(isSelected ? Theme.selected : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHighlight(selected: Bool = false, radius: CGFloat = 6) -> some View {
        modifier(RowHighlight(isSelected: selected, radius: radius))
    }

    /// 带描边的卡片容器。
    func card(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }
}

/// 鼠标悬停时才显示的内容（比如行尾的操作按钮）。
struct HoverReveal<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: - 按钮

/// 胶囊形描边按钮，比如“+ 新建”“编辑”。
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        var body: some View {
            configuration.label
                .font(Theme.body)
                .labelStyle(TightLabelStyle())
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(isEnabled ? tint : tint.opacity(0.45))
                .background(shape.fill(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : Theme.card))
                .overlay(shape.strokeBorder(Theme.borderStrong))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// 主操作按钮：强调色填充。
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium)
            .foregroundStyle(.white)
            .labelStyle(TightLabelStyle())
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

/// 只有图标的小按钮，悬停时出现底色。
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, tint: tint)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let tint: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.primary : tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// 图标与文字间距更紧凑的 Label。
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 12, weight: .medium))
            configuration.title
        }
    }
}

// MARK: - 输入框

/// 圆角描边输入框，聚焦时描边变成强调色。
struct FieldStyle: ViewModifier {
    var focused: Bool
    var monospaced = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? Theme.mono : Theme.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Theme.borderStrong,
                                  lineWidth: focused ? 1.5 : 1))
    }
}

/// 表单里的一项：上方是标题和说明，下方是输入控件。
struct FormField<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.bodyMedium)
            content
            if let hint {
                Text(hint).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 自带聚焦状态的单行输入框。
struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var secure = false
    @FocusState private var focused: Bool

    private var prompt: Text {
        Text(placeholder).foregroundStyle(Theme.faint)
    }

    var body: some View {
        Group {
            if secure {
                SecureField(text: $text, prompt: prompt) { Text(placeholder) }
            } else {
                TextField(text: $text, prompt: prompt) { Text(placeholder) }
            }
        }
        .focused($focused)
        .modifier(FieldStyle(focused: focused, monospaced: monospaced))
    }
}

// MARK: - 小部件

/// 快捷键角标，比如 ⌘K。
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
    }
}

/// 小标签，比如“生产环境”“分组名”。
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.1)))
    }
}

/// 分区标题：“命令 3”。
struct SectionTitle<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let count {
                Text("\(count)").font(.system(size: 14)).foregroundStyle(Theme.faint)
            }
            Spacer()
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// 列表行左侧的方形图标底座。
struct IconTile: View {
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(tint == .secondary ? Theme.subtleFill : tint.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }
}

/// 内容区顶部栏：标题 + 右侧操作。高度与窗口标题栏对齐，可以拖动窗口。
struct ContentHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            CollapsedSidebarLeading()
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            actions
            WindowPinButton()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 显示/隐藏左侧栏的按钮（⌃⌘S）。
struct SidebarToggleButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .help(model.isSidebarVisible ? "隐藏侧栏（⌃⌘S）" : "显示侧栏（⌃⌘S）")
    }
}

/// 主窗口置顶开关：开启后用浮动窗口层级，显示在其他普通窗口上方。
struct WindowPinButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.isWindowPinned.toggle() } label: {
            Image(systemName: model.isWindowPinned ? "pin.fill" : "pin")
        }
        .buttonStyle(IconButtonStyle(tint: model.isWindowPinned ? .accentColor : .secondary))
        .focusable(false)
        .help(model.isWindowPinned ? "取消窗口置顶" : "窗口置顶")
    }
}

/// 把 SwiftUI 里的置顶状态同步到它所在的主窗口，并关掉系统的拖动移窗。
/// 无标题栏窗口顶部那一条，系统会把拖动直接当成移动窗口，抢在标签的 DragGesture 前面（侧栏收起时标签拖不动）；
/// 移动窗口改由 `WindowDragArea` 自己处理。
struct WindowLevelController: NSViewRepresentable {
    let isPinned: Bool

    func makeNSView(context: Context) -> NSView { ControllerView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ControllerView)?.isPinned = isPinned
    }

    private final class ControllerView: NSView {
        var isPinned = false { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.level = isPinned ? .floating : .normal
            window?.isMovable = false
        }
    }
}

/// 侧栏隐藏时放在内容区顶部栏最左边：先让出红黄绿按钮的位置，再放显示侧栏的按钮。
struct CollapsedSidebarLeading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.isSidebarVisible {
            SidebarToggleButton()
                .padding(.leading, 64)
                .padding(.trailing, 4)
        }
    }
}

/// 空状态：一行浅色文字，和 BaoCode 的 “Nothing here yet” 一样克制。
struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

// MARK: - 拖动窗口

/// 隐藏标题栏后，用它来充当可以拖动窗口的区域；双击缩放窗口，和系统标题栏行为一致。
/// 窗口本身不可移动（见 `WindowLevelController`），这里跟着鼠标挪窗口。用 SwiftUI 手势而不是 NSView 的 mouseDown：
/// 垫在 SwiftUI 内容背后的 NSView 收不到鼠标事件。
struct WindowDragArea: View {
    /// 拖动开始时鼠标和窗口的屏幕位置。
    @State private var start: (mouse: NSPoint, origin: NSPoint)?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard let window = NSApp.keyWindow else { return }
                    let mouse = NSEvent.mouseLocation
                    // 手势移过一点才开始，起点要扣掉已经移动的距离（屏幕坐标 y 向上）。
                    let start = start ?? (NSPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height),
                                          window.frame.origin)
                    self.start = start
                    window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                                  y: start.origin.y + mouse.y - start.mouse.y))
                }
                .onEnded { _ in start = nil })
    }
}

/// 卡片内部行与行之间的细线。
struct CardDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, inset)
    }
}

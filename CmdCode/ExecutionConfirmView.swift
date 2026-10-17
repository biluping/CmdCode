import CmdCodeCore
import SwiftUI

/// 执行前的确认面板：说明在哪台服务器、哪个目录执行什么命令。生产环境用红色强调。
struct ExecutionConfirmView: View {
    let plan: ExecutionPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var tint: Color { plan.isProduction ? Theme.danger : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 14) {
                details
                command
                if plan.isProduction {
                    Label("这是生产环境服务器，请确认命令无误后再执行。", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.small)
                        .foregroundStyle(Theme.danger)
                        .labelStyle(TightLabelStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)

            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) { Label("执行", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(tint: tint))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Theme.subtleFill)
        }
        .frame(width: 500)
        .background(Theme.content)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: plan.isProduction ? "exclamationmark.triangle.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "确认执行“\(plan.commandName)”？")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(verbatim: plan.serverName)
                        .font(Theme.body)
                        .foregroundStyle(plan.isProduction ? Theme.danger : .secondary)
                    if plan.isProduction {
                        Chip(text: "生产环境", tint: Theme.danger)
                    }
                }
            }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            row("连接", "\(plan.target.username)@\(plan.target.host):\(plan.target.port)")
            CardDivider()
            row("工作目录", plan.workingDirectory ?? "—")
        }
        .card()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            // verbatim：避免把端口等数字格式化成 “2,233”
            Text(verbatim: value)
                .font(Theme.mono)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var command: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("命令").font(Theme.small).foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: plan.command)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }
}

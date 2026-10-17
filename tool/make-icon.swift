// 生成 CmdCode 的应用图标（1024×1024 PNG）。
// 用法：swift tool/make-icon.swift <输出路径.png>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let size = 1024
let canvas = CGFloat(size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("无法创建位图") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS 图标规范：主体是 824×824 的圆角方块，四周留白 100。
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 深色渐变底
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(red: 0.17, green: 0.20, blue: 0.27, alpha: 1).cgColor,
             NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

// 顶部标题栏的三个小圆点，像一个终端窗口
let dots: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
for (i, color) in dots.enumerated() {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: body.minX + 80 + CGFloat(i) * 70, y: body.maxY - 120, width: 44, height: 44))
}
ctx.restoreGState()

// 提示符 “>_”
let prompt = NSAttributedString(string: ">_", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 400, weight: .bold),
    .foregroundColor: NSColor(red: 0.36, green: 0.90, blue: 0.55, alpha: 1),
])
let textSize = prompt.size()
prompt.draw(at: CGPoint(x: (canvas - textSize.width) / 2, y: body.minY + 150))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("无法编码 PNG") }
try png.write(to: URL(fileURLWithPath: output))
print("已生成 \(output)")

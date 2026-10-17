// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmdCodeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmdCodeCore", targets: ["CmdCodeCore"]),
    ],
    targets: [
        .target(name: "CmdCodeCore"),
        // 开发期试用：不写界面，直接验证“生成脚本 → 终端打开 → 远端执行”整条链路。
        .executableTarget(name: "cmdcode-try", dependencies: ["CmdCodeCore"]),
        .testTarget(name: "CmdCodeCoreTests", dependencies: ["CmdCodeCore"]),
    ]
)

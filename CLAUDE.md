# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

CmdCode 是一个 macOS 14+ 的 SwiftUI 原生应用：管理服务器和凭据，给每台服务器配置固定命令，点击后在应用内嵌终端（SwiftTerm）里通过系统 `ssh` 执行；还能浏览、编辑、上传下载服务器上的文件（同样走 `ssh`，不用 SFTP）。密码经 ssh 自带的 `SSH_ASKPASS` 提供，不依赖 sshpass。完整需求与设计决定见 `需求文档.md`，改行为前先对照它（改了行为要同步更新文档）。界面文案、注释、提交信息都用中文。

## 常用命令

```bash
# 核心库测试（Swift Testing，不是 XCTest）
cd CmdCodeCore && swift test
# 跑单个测试套件 / 用例
cd CmdCodeCore && swift test --filter ScriptBuilderTests
cd CmdCodeCore && swift test --filter "LibraryTests/serverValidation"

# Debug 构建 App
xcodebuild -project CmdCode.xcodeproj -scheme CmdCode -configuration Debug -derivedDataPath build/DerivedData -skipPackagePluginValidation build

# 打包：先跑测试，再 Release 构建 + ad-hoc 签名 + 生成 build/dist/CmdCode-<版本>.dmg；--install 另装到 /Applications
tool/package.sh [--install]

# 界面自检：Debug 版用内存数据库和示例数据把几个典型界面渲染成 PNG 后退出（见 CmdCode/Snapshot.swift）
build/DerivedData/Build/Products/Debug/CmdCode.app/Contents/MacOS/CmdCode -snapshot /tmp/shots

# 开发工具（在 CmdCodeCore 下）
swift run cmdcode-try --host <主机> --user <用户> [--dir <目录>] --cmd <命令>              # 不经界面直接试一次 ssh 执行
swift run cmdcode-try --host <主机> --user <用户> [--port 22] (--ls <目录> | --cat <文件> | --put <文件>)              # 试远程文件读写（--put 读标准输入）
swift run cmdcode-try --host <主机> --user <用户> [--port 22] (--download <远程> | --upload <本地>) --to <路径> [--force]  # 试上传下载
swift run cmdcode-import --dry-run                                                       # 从 FinalShell 导入服务器（正式导入前先退出 CmdCode）
```

运行时不需要额外安装任何东西：用系统 `/usr/bin/ssh`（需 OpenSSH 8.4+ 支持 `SSH_ASKPASS_REQUIRE`）。不要再引入 sshpass——它靠盯终端输出猜时机“打”密码，实测约 5% 登录被拒（需求文档 3.4「密码怎么给 ssh」）。

## 架构

两层：**`CmdCodeCore`**（本地 Swift 包，所有可测试的逻辑）和 **`CmdCode/`**（App 界面，只做展示和交互）。`CmdCode.xcodeproj` 是手写的工程，用文件系统同步组，`CmdCode/` 下新增的 Swift 文件会自动加入目标；依赖 `CmdCodeCore`（本地包引用）和 SwiftTerm（远程包）。App Sandbox 关闭（要在 pty 里起 ssh 进程），签名为 ad-hoc（`CODE_SIGN_IDENTITY = "-"`），只在本机用，不做 Developer ID / 公证。

### CmdCodeCore

- `Models.swift` / `Persistence.swift`：SwiftData 模型 `Credential`、`ServerGroup`、`Server`、`ServerCommand`；库文件在 `~/Library/Application Support/CmdCode/CmdCode.store`。密码明文存库里（设计如此，不用钥匙串）。
- `Library.swift`：**所有数据修改的唯一入口**（增删改、拖动排序、复制、搜索、左侧栏分组组装 `SidebarSection.make`）。删除规则在这里实现：被引用的凭据不能删（`LibraryError.credentialInUse`）、删服务器级联删命令、删分组把服务器移到“未分组”（`group == nil`，固定排最后）。排序靠模型上的顺序字段，`Library.reorder` 统一重编号。
- `Drafts.swift`：表单用的值类型草稿（`ServerDraft`、`CommandDraft`、`CredentialDraft`），校验后由 `Library` 写入模型。
- 执行链路：`ServerCommand.executionPlan()` / `Server.testConnectionPlan()` / `Server.loginPlan()` → `ExecutionPlan`（不持有模型对象、`Sendable`）→ `CommandRunner.invocation(for:)` → `ScriptBuilder.sshInvocation` 产出 `SSHInvocation`（可执行文件路径、参数数组、环境变量）。
- `ScriptBuilder.swift`：转义的核心。内层脚本 = 可选的 `cd -- <shq(目录)> || exit 1` + 命令原文（留在 shell 时再加 `trap : INT`、`bash -lc`、`exec "${SHELL:-bash}" -l`；命令和登录都留在 shell），整体 base64 后拼成 `bash -lc "$(printf %s <b64> | base64 -d)"` 作为 ssh 最后一个参数。密码只走环境变量 `CMDCODE_SSH_PASSWORD`，由 `AskPass` 的脚本（`/tmp/cmdcode-<uid>/askpass`，脚本本身不含密码）交给 ssh，不进参数、不落盘；`NumberOfPasswordPrompts=1`，密码错只试一次。不要改成 `cd && 命令` 或经 stdin 喂脚本——原因见需求文档 3.4。
- `ScriptBuilderTests` 是往返测试：用本地 `bash -c` 代替 ssh，对比执行结果与直接执行原命令是否一致（`Tests/.../Shell.swift` 是辅助）。改 `ScriptBuilder` 必须保证这些用例全过，新增转义场景时加用例。
- `RemoteFiles.swift`：远程文件的列目录、读、写（需求文档 3.5）。同样经 `ScriptBuilder.remoteCommand(script:)` 发脚本，但用 `ssh -T`（不分配终端），写入内容走 stdin，远端 `cat` 覆盖原文件以保留权限和 inode，保存时比对 `cksum` 防冲突。上传下载走同样的通道，流式读写本地文件（不进内存），支持进度和取消。文件操作用非登录 shell，并开启 ssh 连接复用（ControlMaster，socket 在 `/tmp/cmdcode-<uid>/`，关文件标签和退出应用时 `ssh -O exit`）。测试用假的 ssh 在本地 bash 上往返（它不认 ssh 参数，测不到连接复用；本机是 BSD `stat`，列目录的 GNU 分支只能在真实 Linux 服务器上验证）。
- `AskPass.swift`：askpass 脚本的生成与校验（目录必须属于当前用户、0700）和 ssh 所需环境变量。
- 其他：`SecretClipboard`（复制密码 60 秒后清除）、`FinalShellImport`（解析 FinalShell 的 conn 目录，供 `cmdcode-import` 用）。

### CmdCode（App）

- `CmdCodeApp.swift`：启动时建 `ModelContainer` 和 `Library`，`-snapshot` 参数时改用内存库并跑 `Snapshot`。
- `AppModel.swift`：`@Observable` 的界面状态与动作中心——左侧栏选择（`SidebarSelection`）、弹出表单（`SheetRoute`）、执行确认、右侧标签页（`tabs`）。数据改动一律调用 `Library`，执行一律调用 `CommandRunner`。
- 右侧标签页：`AppModel.tabs` 是 `WorkspaceTab`（`.terminal(TerminalSession)` 或 `.files(FileBrowserModel)`）的数组，`TerminalPane.swift` 画统一的标签栏并按类型显示内容。
- `TerminalSession.swift`：每次执行一个 `TerminalSession`（SwiftTerm 视图 + pty 里的 ssh 进程）；关闭标签给进程组发 SIGHUP。右键菜单（复制、粘贴、浏览文件）在 `CmdTerminalView.menu(for:)`；浏览文件跳到远端 shell 经 OSC 7 上报的当前目录（`ScriptBuilder.reportDirectoryLine`）。输出不保存。
- `FileBrowserModel.swift` / `FileBrowserView.swift`：文件标签，通常每台服务器一个（按 `serverID` 查找；“复制标签”可以复制出多个，复用连接等这台服务器的文件标签全关了才关），切走再回来保留目录和编辑内容。服务器间发送文件是先下载到本机临时目录再上传（`FileBrowserModel.send`）。`-snapshot` 时 `AppModel.makeFileClient` 换成本地假 ssh。
- `SidebarView.swift`：三层树（分组 → 服务器 → 命令）、拖动排序、右键菜单、原地重命名分组。`DetailView` 是服务器详情，`CredentialsView` 是密码管理，`SearchPanel` 是 ⌘K 搜索，`ExecutionConfirmView` 是执行确认面板（所有命令都先确认，生产环境红色强调），`Forms.swift` 是各编辑表单，`Theme.swift` 是统一的颜色和控件样式。

## 工作方式

用户偏好小步推进：一次只做一个功能，做完跑相关测试（UI 改动用 `-snapshot` 截图自查），让用户实测确认后再提交。`-snapshot` 截图用 `cacheDisplay` 渲染，拍不到图层背景、胶囊描边处会出现假竖线，属截图假象。

# F1 · 终端路径点击定位到文件导航

> 精简 PRD（敏捷需求流程）
> 作者：PM | 日期：2026-04-14 | 状态：草稿

## 1. 需求描述

**现状**：在终端视图中点击（或 Ghostty link-handler 触发）输出中的文件/目录路径时，默认行为是 `NSWorkspace.shared.open()`，即打开系统默认的外部程序（如 TextEdit、Finder、Xcode）。

**目标**：当路径位于当前文件浏览器根目录（`FileExplorerStore.rootPath`）下时，改为在 app 内的 File Explorer 面板中定位并选中该节点；面板未打开时自动打开；路径不在根目录下则保持原外部打开行为；⌘ 修饰键点击仍走外部打开作为逃生通道（如 Ghostty 未透传修饰键，则保留仅基础行为变更，修饰键支持可视为扩展）。

## 2. 验收标准（AC）

| ID | 场景 | 期望结果 |
|----|------|---------|
| AC-1 | 点击终端输出中的项目内文件路径（rootPath 下），File Explorer 已打开 | 该文件在 Outline 中展开祖先 + 高亮选中 + 滚动到可见；不触发 NSWorkspace.open |
| AC-2 | 点击终端输出中的项目内文件路径，File Explorer 未打开 | 自动打开 File Explorer 面板，之后同 AC-1 |
| AC-3 | 点击终端输出中的项目内目录路径 | 该目录被展开并选中，目录自身可见 |
| AC-4 | 点击终端输出中的**项目外**绝对路径（不在 rootPath 下） | 走原行为：`NSWorkspace.shared.open()` 打开外部程序 |
| AC-5 | 点击 `http(s)://` URL 等非文件 URL | 不受影响，走原有 embeddedBrowser / external 分支 |
| AC-6 | 路径中包含空格、中文字符、符号（需先 URL-decode） | 解析后仍能正确定位（reveal 使用文件系统真实路径） |
| AC-7 | 路径对应节点已从磁盘删除 | fallback 到 `NSWorkspace.shared.open()`（由其负责错误反馈），不报 Swift 崩溃 |
| AC-8 | `FileExplorerStore.rootPath` 为空（未打开项目） | 所有 file:// 点击走原外部行为 |

## 3. 影响范围

| 文件 | 改动要点 |
|------|---------|
| `Sources/GhosttyTerminalView.swift` | `GHOSTTY_ACTION_OPEN_URL` 分支：识别 file:// 且属于项目内路径时，广播 `com.cmux.revealInFileExplorer` 通知；否则走原路径 |
| `Sources/FileExplorerStore.swift` | 新增 `reveal(path:)` API：展开祖先链、加载子节点、返回命中的 node；若路径不在根目录下则返回 nil |
| `Sources/FileExplorerView.swift` 或 `FileExplorerState.swift` | 监听 `com.cmux.revealInFileExplorer`：确保面板可见 → 调 `store.reveal` → 在 NSOutlineView 中 selectRow + scrollRowToVisible |

## 4. 接口变更

- 新增 `Notification.Name("com.cmux.revealInFileExplorer")`，userInfo `{"path": String}`。
- `FileExplorerStore` 新增 `func reveal(path: String) -> FileExplorerNode?`：保证路径祖先都被展开、子节点已加载，返回命中节点。若路径不在 `rootPath` 下返回 nil。
- `FileExplorerState` 如无 `show()`，新增强制展开方法；或在 reveal 监听处直接调 `toggle()`（若当前未显示）。

## 5. 页面交互

- 无新增 UI 元素，无视觉改动。
- 行为：终端点击路径 → File Explorer 面板打开/保持 → Outline 展开路径链 → 选中命中行 → 滚动到可见。
- 选中样式复用 `FileExplorerRowView.drawSelection`。

## 6. 非目标 / Out of Scope

- 不改变 `http(s)://`、`mailto:` 等非 file URL 的处理链。
- 不新增 Settings 开关（默认开启；若未来需要关闭入口再开 Feature）。
- 不引入「打开 app 内编辑器」能力（仅定位到文件树，不编辑）。

## 7. 埋点

`#if DEBUG` 环境下在 `dlog` 输出：
- `link.openURL file target=reveal path=<path>` 或 `link.openURL file target=external path=<path>`。
- 不新增生产埋点。

## 8. 约束 & 注意

- Ghostty 传入的是 `file:///absolute/path` 格式 URL，需 `url.path` 取出并做 `(path as NSString).standardizingPath`。
- rootPath 可能是符号链接解析过的；判断「路径属于 rootPath」需先双向 standardize 再前缀比较。
- `FileExplorerStore` 懒加载子节点：reveal 需自顶向下逐层展开并等待子节点加载完成后再继续。
- 不允许破坏现有典型链接（http/https/ssh/git）行为。

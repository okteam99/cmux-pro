# F1 · Test Plan & Cases

## Test Plan

| 层级 | 范围 |
|------|------|
| Unit (cmuxTests) | `FileExplorerStore.reveal(path:)` 行为、路径归属判断辅助函数 |
| Unit (cmuxTests) | `resolveTerminalOpenURLTarget` 对 `file://` URL 的分类（新增 `.revealInExplorer` case 或通过通知验证） |
| Manual / Debug | Ghostty OPEN_URL 回调分发（点击路径 → 观察 dlog + outline 状态） |

无 UI/Browser E2E（改动不涉及页面视觉或跨进程交互）。

## BDD Cases

### Case 1 — 点击项目内文件路径 · 面板已打开（AC-1, AC-6）
- **Given** `FileExplorerStore.rootPath == /Users/x/proj`，面板已展开，存在文件 `/Users/x/proj/Sources/Foo Bar.swift`
- **When** Ghostty 回调传入 `file:///Users/x/proj/Sources/Foo%20Bar.swift`
- **Then** `FileExplorerStore.reveal` 返回该节点；`expandedPaths` 包含 `/Users/x/proj/Sources`；未调用 `NSWorkspace.shared.open`；`dlog` 打印 `target=reveal`

### Case 2 — 点击项目内文件路径 · 面板未打开（AC-2）
- **Given** rootPath 同上，`FileExplorerState.isVisible == false`
- **When** 回调同上
- **Then** `FileExplorerState.isVisible == true`；AC-1 行为全部满足

### Case 3 — 点击项目内目录路径（AC-3）
- **Given** rootPath 同上，目录 `/Users/x/proj/Sources/Panels` 存在
- **When** 回调传入 `file:///Users/x/proj/Sources/Panels`
- **Then** 该目录被加入 `expandedPaths`；reveal 返回目录节点；未调用外部 open

### Case 4 — 点击项目外路径（AC-4）
- **Given** rootPath == `/Users/x/proj`
- **When** 回调传入 `file:///Users/x/other/file.txt`
- **Then** `reveal` 返回 nil；调用 `NSWorkspace.shared.open`；`dlog` 打印 `target=external`

### Case 5 — 点击 http URL（AC-5）
- **Given** 任意 rootPath
- **When** 回调传入 `https://example.com`
- **Then** 不走 file 分支；走原 `embeddedBrowser / external` 逻辑；File Explorer 状态不变

### Case 6 — 不存在的路径（AC-7）
- **Given** rootPath 同上；`/Users/x/proj/deleted.swift` 不存在于磁盘
- **When** 回调传入 `file:///Users/x/proj/deleted.swift`
- **Then** `reveal` 返回 nil（祖先加载后未找到节点）；fallback 到 `NSWorkspace.shared.open`；无崩溃

### Case 7 — 空 rootPath（AC-8）
- **Given** `FileExplorerStore.rootPath == ""`
- **When** 回调传入任意 `file://` URL
- **Then** 走 `NSWorkspace.shared.open`；未触发 reveal 通知

## 单元测试文件

新增 `cmuxTests/FileExplorerRevealTests.swift`：覆盖 Case 1、3、4、6、7（Case 2/5 涉及 AppKit 状态/Ghostty 回调，保留人工验证）。

## 规制

- 不测试源码文本/签名（符合 CLAUDE.md「测试策略」）。
- 使用临时目录 + `FileManager` 构造真实文件系统状态，不 mock。

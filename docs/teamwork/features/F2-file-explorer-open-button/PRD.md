# F2 · 文件导航面板 · 行内「打开」按钮

> 精简 PRD（敏捷需求流程）
> 作者：PM | 日期：2026-04-14

## 1. 需求描述

当前选中一个 FileExplorer 行后，没有办法用按钮直接「打开」；用户只能依赖右键菜单的「Open in Default Editor / Reveal in Finder」或其他途径。

本需求为**选中态行**增加一个行内「打开」图标：
- **文件**：点击图标 / 双击行 → 若扩展名是 `.md/.markdown`，走内置 MarkdownPanel（`Workspace.newMarkdownSurface`）打开为新 tab；否则走 `NSWorkspace.shared.open`（系统默认程序）
- **目录**：点击图标 / 双击行 → 展开/折叠（和现有的单击行为一致）

## 2. 验收标准（AC）

| ID | 场景 | 期望 |
|----|------|------|
| AC-1 | 选中 `README.md` 行 → 行尾出现 open 图标 → 点击 | 当前 workspace 的 focused pane 中新增 markdown tab，渲染 README.md 内容 |
| AC-2 | 选中 `Package.swift` 行 → 行尾出现 open 图标 → 点击 | 调用 `NSWorkspace.shared.open(URL(fileURLWithPath:))`；不新开 markdown tab |
| AC-3 | 选中 `Sources/`（目录）行 → 行尾出现 open 图标 → 点击 | 该目录被展开（折叠）；不调用任何外部 open |
| AC-4 | 双击 `.md` 行 | 同 AC-1 |
| AC-5 | 双击 `.swift` 行 | 同 AC-2 |
| AC-6 | 双击目录行 | 同 AC-3（展开/折叠） |
| AC-7 | 未选中任何行 | 行内图标不存在于任何行 |
| AC-8 | hover 行（未选中） | 不显示 open 图标（仅选中行显示） |
| AC-9 | 扩展名大小写 `.MD` / `.Markdown` | 按 markdown 识别（大小写不敏感） |
| AC-10 | 文件名包含空格、中文 | 正常打开，不崩溃 |

## 3. 影响范围

| 文件 | 改动要点 |
|------|---------|
| `Sources/FileExplorerView.swift` | `FileExplorerCellView`：增加 `openButton` 子视图，默认隐藏；selected 时显示。`Coordinator`：outlineView 的 `target/doubleAction` 配置；open 按钮点击转发到 Coordinator。 |
| `Sources/FileExplorerStore.swift` | 无需改动（选中态由 NSOutlineView 内建管理）。 |
| `Sources/FileExplorerView.swift`（同上）→ `Workspace` 调用 | 新增 `FileExplorerOpenRequestHandler`：持有 workspace 的弱引用，Coordinator 调用它；或直接用 NotificationCenter（`com.cmux.fileExplorerOpenRequest` + `path`），由 Workspace 侧监听 |

## 4. 接口变更

- 新增 `Notification.Name("com.cmux.fileExplorerOpenRequest")`，userInfo `{"path": String}`。
- 由 `WorkspaceView`（或拥有 workspace 引用的上层）监听。Handler 实现：
  ```
  if path endsWith .md/.markdown (case-insensitive):
      workspace.newMarkdownSurface(inPane: focusedPaneId, filePath: path)
  else:
      NSWorkspace.shared.open(URL(fileURLWithPath: path))
  ```
- 目录不走这个通知（FileExplorerView 内部直接调用 `outlineView.expandItem` / `collapseItem` 即可）。

## 5. 页面交互

- 在 `FileExplorerCellView` 的右端（loadingIndicator 所在位置左侧），增加 `openButton`（`NSButton`，`bezelStyle=.recessed`，图标 `arrow.up.forward.square`，size ≈ 14pt）。
- 默认 `isHidden=true`；当行处于选中状态时 `isHidden=false`。
- 目录：按钮始终可见（复用 expand/collapse）；或隐藏（让用户直接点 disclosure triangle）。**决策：目录也显示 open 图标**，和文件一致，点击 = 展开/折叠，视觉一致。
- 双击：`NSOutlineView.doubleAction` = 触发 Coordinator 的 `handleOpenRequest(for: node)`。

## 6. 非目标

- 不新增 Settings 开关。
- 不改变已有右键菜单（`Open in Default Editor` 仍然走 `NSWorkspace.open`）。
- 不引入自定义 markdown 关联程序偏好。

## 7. 埋点

`#if DEBUG`：`fileExplorer.open path=<path> route=markdown|external|expand`。

## 8. 注意

- `openButton` 要放在 NSTableRowView 的选中态 contract 内：按钮点击不能清除选中。用 `isContinuous=false` 且在 action 里不重置 selection。
- `FileExplorerCellView` 已用 `Equatable` 优化 — 检查新增 state 不会破坏。（实际该优化在 SwiftUI 的 TabItemView，不是 FileExplorerCellView，无影响）。
- 需避免新增依赖 `EnvironmentObject` 导致 performance regression（遵循 CLAUDE.md 的 typing-latency 说明；本改动不在 typing path）。

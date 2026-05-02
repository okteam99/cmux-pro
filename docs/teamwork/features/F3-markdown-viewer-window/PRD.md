# F3 · Markdown 新窗口阅读器 + Mermaid 支持

> Feature 流程 · PRD
> 作者：PM | 日期：2026-04-14 | 状态：草稿待评审

## 1. 背景与目标

### 1.1 背景
- F2 已实现 File Explorer 选中行内「打开」按钮，`.md` 当前会在当前 workspace 的 focused pane 中打开为 MarkdownPanel tab（使用 `MarkdownUI` 渲染）。
- 用户反馈两点：
  1. 文档类内容与终端共用 tab 区挤占空间，希望作为独立窗口浏览
  2. `MarkdownUI` 不支持 Mermaid（`graph TD` 等），而 cmux 项目内外的 md 广泛使用 Mermaid 描述架构图

### 1.2 目标
1. File Explorer 中点击 `.md` 的「打开」按钮 / 双击 `.md` 行 → 弹出**独立 macOS 窗口**渲染 md
2. 渲染引擎升级为 WKWebView + 客户端 JS（`marked.js` + `mermaid.js`），支持 Mermaid 图
3. **收敛路线**：File Explorer 默认入口改为新窗口；tab 版 MarkdownPanel **本期冻结**（不再暴露新入口，仍可通过内部 API / 会话恢复存在），下一迭代视新窗口稳定度决定完全下线。不保留"双入口并存"的心智分裂

### 1.3 非目标
- 不改变 tab 版 MarkdownPanel 的渲染栈
- 不支持 md 编辑（原因：viewer 定位只读，md 编辑器生态已充分，cmux 不进入该赛道）
- 不支持导出 PDF
- 不支持导出 Mermaid SVG/PNG（本期；但预留 JS 侧 `cmux.exportMermaidSVG(nodeId)` 接口占位，P1 视反馈实装）
- 不支持文档共享 / 协同阅读（viewer 是单机只读工具）
- 不引入可配置的 mermaid 主题（固定一套跟随 light/dark）
- 不支持跨文件导航（点击文档内 md 链接 → 系统默认处理 / 外部浏览器；非新增 viewer 窗口）
- 不支持字号缩放 / ⌘+ ⌘- zoom（本期视为非目标）
- 不接入 command palette / recent files 入口（仅 File Explorer 入口）
- 本期不在 Debug 菜单加「Markdown Viewer Tuning」排版调参窗口（UI token 在 UI.md 定稿后硬编码）
- **本期不抽离 `MarkdownFileSource`**：新窗口自行实现最小 watcher，**完全不改动** `Sources/Panels/MarkdownPanel.swift`（保持 tab 版冻结的字面含义，避免需要为 tab 版补一套回归测试）

### 1.4 竞争定位与目标用户

**目标用户（TA）**：cmux 重度使用者，在项目仓库内阅读 README / ARCHITECTURE / RFC / 设计文档，这些文档常含 Mermaid 架构图 / 流程图。

**差异化定位**：

| 工具 | 本 viewer 差异点 |
|------|-----------------|
| macOS Quick Look（空格预览） | Quick Look 不支持 Mermaid；本 viewer 支持且跟随 cmux appearance |
| Typora / Obsidian | 外部应用需上下文切换；本 viewer 由 cmux File Explorer 直接唤起，保留 CWD / Git 语境 |
| VS Code Markdown Preview | 需开 VS Code；对仅在终端工作的用户冗余 |
| 既有 tab 版 MarkdownPanel | tab 版与终端挤占 tab 区，且不支持 Mermaid |

**「一站式」的含义**：一站式价值来自**工作环境（文件系统 / CWD / Git 上下文）连续**，而非「所有东西同一个窗口」。独立 NSWindow 由 cmux 唤起、持有、监听文件变更、跟随 appearance，不削弱一站式。

## 2. 用户场景

| 场景 | 步骤 |
|------|------|
| 阅读项目文档 | 在 File Explorer 选中 `README.md` → 点击 open 图标 → 独立窗口弹出，渲染 md，Mermaid 图正常显示 |
| 阅读架构设计（含 Mermaid） | 同上；`graph TD / sequenceDiagram / flowchart` 等均被渲染成 SVG |
| 多文档并读 | 连续打开多个 md → 每个 md 独占一个窗口；每次相同 md 打开则聚焦到已有窗口（而非开多个） |
| 文档更新 | 磁盘上 md 被外部编辑器修改 → 窗口自动刷新（沿用 MarkdownPanel 的文件监听语义） |
| 深色模式 | 主题跟随系统 / cmux appearance；Mermaid 图配色随之切换 |

## 3. 验收标准（AC）

### 3.1 入口与窗口

| ID | 场景 | 期望 |
|----|------|------|
| AC-1 | File Explorer 双击 / 点击 open 图标打开 `.md` | 弹出独立 NSWindow（非 tab），标题栏显示文件名 |
| AC-2 | 同一 md 再次被请求打开 | 聚焦已有窗口而非新开一个 |
| AC-3 | 关闭窗口 | 文件监听停止，内存释放 |
| AC-4 | 窗口大小/位置 | 初始 900×700 居中；**全局共用一份记忆**（关闭最后一个 viewer 时记录大小/位置，下次任一文件打开沿用；不按文件独立记忆）；**多屏 fallback**：恢复前校验 `origin` 是否落在 `NSScreen.screens` 覆盖范围内，若屏已断开则回退居中（Designer 建议 3） |
| AC-5 | 最小化 / 全屏 | 正常响应 macOS 标准行为 |
| AC-6 | 非 md 文件（通过其他入口错误进入） | 该入口内部已拦截，不会触达此窗口（窗口仅 md） |

### 3.2 渲染

| ID | 场景 | 期望 |
|----|------|------|
| AC-7 | 基础 md（标题、列表、表格、代码块、引用、链接、图片、分隔线） | 正确渲染 |
| AC-8 | 代码块含语言标签（swift/python/js 等） | 语法高亮（使用 highlight.js 或 Prism，推荐 highlight.js） |
| AC-9 | ` ```mermaid ... ``` ` | 渲染为 SVG 图 |
| AC-10 | ` ```graph TD ... ``` `（裸 mermaid 语法放在 mermaid 标签下） | 同上 |
| AC-11 | Mermaid 多种类型（graph/flowchart/sequenceDiagram/classDiagram/gantt 等） | 均正常渲染 |
| AC-12 | Mermaid 渲染错误（语法错） | 代码块处显示错误提示，不崩溃整个页面。错误文案使用本地化 key `markdownViewer.mermaid.error`（英文 default：`Failed to render Mermaid diagram.`），中英日三语 |
| AC-13 | 文档含 HTML（`<br>`、`<details>` 等） | 不破坏布局，按 HTML 语义渲染（marked 默认允许） |
| AC-14 | 深色模式 | 文本、背景、代码块、Mermaid 图自动切换 |
| AC-15 | 文本选中 + 复制 | 可选中可复制 |
| AC-16 | 内部链接 `#anchor` | 滚动到锚点 |
| AC-17 | 外部链接 `https://…` | 调用 `NSWorkspace.shared.open`（系统浏览器），不在窗口内导航 |
| AC-18 | 相对路径链接 `./foo.md` | 用 `NSWorkspace.shared.open` 打开系统默认（不跳转 viewer，避免多文件堆栈 / 返回栈 / 状态机复杂度；刻意设计，非能力缺陷） |

### 3.3 动态更新与容错

| ID | 场景 | 期望 |
|----|------|------|
| AC-19 | 文件在磁盘上被修改 | 窗口内容 1-2s 内自动刷新（新窗口自己实现 watcher，**不复用** MarkdownPanel）；**刷新后保留滚动位置**（JS 契约见下方「AC-19 滚动恢复契约」） |
| AC-20 | 文件被删除 | 显示「文件已删除」提示；若后续重新出现则恢复 |
| AC-21 | 文件大小阈值 | ≤ 2MB 直接渲染；2-10MB 显示加载指示器后渲染；> 10MB 仅渲染前 10MB 并在顶部显示「文件过大，已截断」提示（本地化） |
| AC-22 | 文件编码非 UTF-8（ISO Latin-1 等） | 先 UTF-8 解码；失败则用 `String(data:encoding:.isoLatin1)` 再试；仍失败则显示「File unavailable」错误态。行为等价于 MarkdownPanel.loadFileContent 但代码独立实现（符合 R-3 A 方案的非抽离策略） |

**AC-19 滚动恢复契约**：

```
文件变更 → 整页 rerender（最简实现）
  - 前：JS 记录 `{ anchorId, offsetInAnchor }`
    · anchorId = 最接近视口顶部的 <h1..h6> 的 id（由 marked 根据 heading slug 生成）
    · offsetInAnchor = (视口顶 y - anchorEl.getBoundingClientRect().top) / viewportHeight
    · 若文档无 heading，fallback 记录 `{ scrollTopRatio: scrollTop / scrollHeight }`
  - 渲染完成后：
    · 优先 `document.getElementById(anchorId)?.scrollIntoView({block:"start"})` 再 `scrollBy(0, offsetInAnchor * viewportHeight)`
    · anchorId 不存在（文档大改）→ fallback 到 `scrollTop = scrollTopRatio * scrollHeight`
  - 埋点：`markdownViewer.fileReload strategy=anchor|ratio path=<path>`
```

### 3.4 性能

| ID | 场景 | 期望 | 测量方法 |
|----|------|------|----------|
| AC-23 | 首次打开 md 窗口（app 启动后第一次打开 viewer） | 基础 md 首屏渲染 ≤ 500ms（含 WKProcessPool 冷启动） | XCTest `measure {}` 块 + signpost `viewer.firstOpen` 区间 |
| AC-24 | 再次打开任一 md（WKProcessPool 已复用） | 首屏渲染 ≤ 200ms | XCTest `measure {}` + signpost `viewer.warmOpen`；强制条件是**上一个 viewer 关闭后 5 分钟内再开**（AC-31） |
| AC-25 | 单个 Mermaid 图（中等复杂度 < 30 节点） | 渲染 ≤ 300ms | 在 WKWebView `evaluateJavaScript` 里注入计时代码，返回 ms 后 Swift 侧断言 |

**WKProcessPool 复用策略**：`MarkdownViewerWindowManager.shared` 持有一个全局 `WKProcessPool` 实例，所有 viewer WKWebView 共享。最后一个 viewer 关闭时 **不释放 ProcessPool**（靠应用进程生命周期自然回收），保证 AC-24 热启动。

### 3.5 构建产物与依赖完整性

| ID | 场景 | 期望 |
|----|------|------|
| AC-26 | 构建产物 viewer 资源大小 | `Resources/MarkdownViewer/vendor/` 总大小 ≤ 5MB（给 full mermaid + marked + highlight 留足空间且失控保护） |
| AC-27 | 依赖完整性 | 构建 / release pretag 阶段运行 `verify-markdown-viewer-vendor.sh`；vendor 文件 sha256 与 `vendor.lock.json` 一致；任何 diff → 脚本 exit 1 |
| AC-28 | 非 file 子资源阻断 | md 中 `<img src="https://…">` 不产生网络请求（WKWebView decidePolicyFor 拦截）；**DOM 层**替换为可见的灰调占位文本 `🚫 External image blocked: <url>`（xcstrings key `markdownViewer.externalImage.blocked`），避免用户疑惑渲染 bug |
| AC-32 | md 内本地图片（按 R-2 方案 1） | `<img src="./logo.png">` 在文档中**降级为可点击链接文字**（带警告 icon），点击 → `NSWorkspace.shared.open` |

### 3.6 窗口管理与 AppKit 行为

| ID | 场景 | 期望 |
|----|------|------|
| AC-D1 | viewer 窗口在 macOS `Window` 菜单 | 标准列出，标题=文件名 |
| AC-D2 | ⌘W 快捷键 | 仅关闭当前 viewer 窗口；主 cmux 窗口 / 其他 viewer 不受影响 |
| AC-D3 | fullscreen / Spaces | 进入/退出 fullscreen 不影响主 cmux 窗口焦点；Spaces 切换后 `showWindow(for:)` 仍能聚焦已有窗口 |
| AC-D4 | Quit 行为 | 所有 viewer 关闭**不会**让 app 退出（由主应用持有 lifecycle，与现有 cmux 多窗口策略一致） |
| AC-D5 | ⌘F 查找 | 本期不自行实现 find UI；由 WKWebView 默认 find（macOS 10.15+）承担；cmux 不拦截 ⌘F 的 responder chain |
| AC-31 | WebView 进程复用 | 关闭最后一个 viewer 窗口后 5 分钟内再次打开，命中 AC-24 热启动路径（`WKProcessPool` 未释放即可） |

**Shortcut policy 说明**：本期**不新增** KeyboardShortcutSettings 条目；⌘W 由 AppKit 标准 `performClose:` / responder chain 承接，不走 cmux 自定义 shortcut routing。

## 4. 影响范围

**目录调整（按架构师建议，A-1）**：新模块与 `Sources/Panels/` 同级，避免污染 Panel 语义。

| 模块 | 改动 |
|------|------|
| `Sources/MarkdownViewer/`（新） | `MarkdownViewerWindowManager.swift`（单例 Manager，持 `[String: MarkdownViewerWindowController]` + 全局 `WKProcessPool`）<br>`MarkdownViewerWindowController.swift`（每窗口 1 实例，`NSWindowController` 子类，持有 `WKWebView` + `MarkdownViewerFileSource`）<br>`MarkdownViewerWebBridge.swift`（`WKScriptMessageHandler`：openExternal / mermaidRenderError / fileReloadAck / viewportStateSync）<br>`MarkdownViewerFileSource.swift`（新窗口**独立的**最小 watcher：`@Published content`、`isFileUnavailable`、`DispatchSourceFileSystemObject` + atomic-save reattach；**不 import MarkdownPanel**） |
| `Resources/MarkdownViewer/`（新，folder reference） | `viewer.html` / `viewer.js` / `viewer.css`<br>`vendor/` 子目录：`marked@14.1.3.min.js` / `mermaid@10.9.3.umd.min.js` / `highlight@11.10.0.min.js`<br>`vendor.lock.json`：记录每个文件的 `sha256`（检入仓库） |
| `Sources/Panels/MarkdownPanel.swift` | **零改动**（R-3 A 方案：tab 版真正冻结） |
| `Sources/Workspace.swift` | `openFileFromExplorer` 中 `.md` 分支改为调用 `MarkdownViewerWindowManager.shared.showWindow(for: filePath)`；返回值语义更新：`true = 已路由 (新窗口或 tab，均视为 cmux 已接管)`，`false = 外部程序打开`。调用方不应依赖「返回值意味着创建了 tab」 |
| `Sources/cmuxApp.swift` | 无需变化（通知路由已存在） |
| `Resources/Localizable.xcstrings` | 新增 key（完整清单见下方） |
| `scripts/verify-markdown-viewer-vendor.sh`（新） | 计算 vendor 文件 sha256 对比 `vendor.lock.json`；CI + release-pretag-guard 调用 |
| `scripts/fetch-markdown-viewer-vendor.sh`（新） | 一次性下载并 commit vendor 目录（首次 setup 用） |
| `scripts/release-pretag-guard.sh` | 追加一步：执行 `verify-markdown-viewer-vendor.sh` |

**xcstrings 新增 key 清单**（Designer / RD 按此表一次性录入 en/zh-Hans/ja 三语）：

| key | en default | 说明 |
|-----|-----------|------|
| `markdownViewer.window.titleFallback` | `Markdown Viewer` | 窗口标题 fallback（文件路径为空时） |
| `markdownViewer.file.unavailable` | `Unable to read file: %@` | AC-20 / AC-22 文件不可读 |
| `markdownViewer.file.deleted` | `The file has been deleted.` | AC-20 删除态 |
| `markdownViewer.file.deleted.hint` | `Waiting for the file to reappear…` | AC-20 删除态副标题 |
| `markdownViewer.file.truncated` | `File too large — showing first 10MB only.` | AC-21 截断提示 |
| `markdownViewer.file.empty` | `(empty)` | 空文件 |
| `markdownViewer.mermaid.error` | `Failed to render Mermaid diagram.` | AC-12 Mermaid 渲染错误 |
| `markdownViewer.mermaid.loading` | `Rendering diagram…` | Mermaid 渲染中占位文案（避免 CLS） |
| `markdownViewer.codeblock.copy` | `Copy` | 代码块复制按钮 label |
| `markdownViewer.codeblock.copied` | `Copied` | 复制成功反馈 |
| `markdownViewer.codeblock.copy.aria` | `Copy code to clipboard` | a11y 标签 |
| `markdownViewer.localImage.hint` | `(local image · click to open)` | AC-32 本地图片降级文本 |
| `markdownViewer.localImage.tooltip` | `Open in default app` | AC-32 hover tooltip |
| `markdownViewer.externalImage.blocked` | `🚫 External image blocked: %@` | AC-28 外网图片拦截后的可见降级（Designer 建议 2） |

**xcodeproj**：`Resources/MarkdownViewer/` 整目录以 **folder reference（蓝色文件夹）** 加入 Copy Bundle Resources phase，`vendor/` 保持结构。Swift 侧用 `Bundle.main.url(forResource:"viewer", withExtension:"html", subdirectory:"MarkdownViewer")` 读取。

## 5. 接口变更

### 5.1 Manager / Controller 拆分（架构师 A-2）

- **`MarkdownViewerWindowManager`**（纯 Manager，**不继承** `NSWindowController`）：
  - `static let shared: MarkdownViewerWindowManager`
  - `let processPool: WKProcessPool`（全局共享，保证 AC-24 热启动）
  - `private var controllers: [String: MarkdownViewerWindowController]`（path → controller）
  - `func showWindow(for filePath: String)`：命中 existing → `makeKeyAndOrderFront`；未命中 → 创建新 Controller 并注册
  - `func detach(_ controller: MarkdownViewerWindowController)`：controller 在 `windowWillClose` 中回调，从 dict 删除
- **`MarkdownViewerWindowController`**（每窗口 1 实例，继承 `NSWindowController`, `NSWindowDelegate`）：
  - `init(filePath: String, processPool: WKProcessPool, manager: MarkdownViewerWindowManager)`
  - `windowWillClose(_:)`：调用 `MarkdownViewerFileSource.close()`（cancel watcher）→ teardown WKWebView → `manager.detach(self)`
- **`MarkdownViewerFileSource`**（新，独立于 MarkdownPanel）：`init(filePath:)` / `@Published content: String` / `@Published isFileUnavailable: Bool` / `func close()` / `DispatchSourceFileSystemObject` + atomic-save reattach（最多 6 次 × 0.5s，参考但不 import MarkdownPanel）

### 5.2 WKWebView 资源读权限（R-2）

**本期采用「方案 1」**：`loadFileURL(viewerHTML, allowingReadAccessTo: viewerResourceDir)` 仅授权 `Resources/MarkdownViewer/` 目录。

后果与处理：
- md 正文以**字符串**形式通过 `evaluateJavaScript` / initial HTML 注入注水，不作为 `<iframe>` 或 `<script src>` 加载
- md 内 `<img src="./logo.png">` 等相对/绝对 file:// 本地图片：**降级为可点击链接**，点击 → bridge → `NSWorkspace.shared.open`（原因：不授权仓库根目录，避免 WKWebView 获得超出 viewer 资源目录的读权限）
- md 内 base64 data URI 图片：正常渲染（无权限风险）
- 外网图片：被 A-5 的规则拦截（见下方）

### 5.3 非 file:// 子资源阻断（架构师 A-5）

- `WKWebViewConfiguration.setURLSchemeHandler` **不注册**任何远程 scheme
- `WKNavigationDelegate.webView(_:decidePolicyFor:)`：对非 `about:` / 非 viewer 自身 `file://` 的任何 navigation / subresource → cancel
- 并注册一条 `WKContentRuleList`：`{"trigger":{"url-filter":".*","load-type":["third-party","first-party"]},"action":{"type":"block"}}` 对 `http(s):` / `ws(s):` / `ftp:` / `data:` 以外的 scheme 双保险
- AC-17 外链用户主动点击 → 走 bridge → `NSWorkspace.shared.open`，不受此规则影响（不是 WebView 自身导航，而是 JS bridge 消息）

### 5.4 JS ↔ Native Bridge

| JS 调用 | Native handler 线程 | 动作 |
|---------|-------------------|------|
| `cmux.openExternal(url)` | main actor | `NSWorkspace.shared.open(URL(string: url))` |
| `cmux.mermaidRenderError(count, messages)` | off-main 解析，main dlog | 记录错误计数（DEBUG） |
| `cmux.fileReloadAck({strategy, anchorId?})` | off-main | 记录 AC-19 分支命中 |
| `cmux.viewportStateSync(state)` | off-main | 保存滚动锚点供 rerender 后恢复（如实现要求 native 协助） |
| `cmux.exportMermaidSVG(nodeId)` | main actor | **本期占位，不实装**（bridge 存在但 native 返回 NOT_IMPLEMENTED）|

**线程规则**：涉及 AppKit 的（`openExternal` / `exportMermaidSVG`）必须 main actor；遥测/计数类（`mermaidRenderError`、`fileReloadAck`、`viewportStateSync`）默认 off-main，符合 CLAUDE.md「Socket command threading policy」精神。

## 6. 交付物清单

- PRD（本文件）
- UI 设计稿（Designer 产出，HTML 预览）
- Test Plan + Cases（QA 产出，BDD 格式）
- 技术方案 TC（RD 产出）
- 源码 + 单元/集成测试
- PM 功能验收报告

## 7. 埋点

所有埋点调用必须包裹 `#if DEBUG` / `#endif`（CLAUDE.md）；通过 `dlog` 走 `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`。

### AC × 埋点交叉索引

| 埋点事件 | 触发 AC | 格式 |
|---------|--------|------|
| `markdownViewer.open` | AC-1 / AC-2 | `path=<p> action=new\|focus-existing` |
| `markdownViewer.webNav` | AC-17 | `url=<u> action=open-external` |
| `markdownViewer.fileReload` | AC-19 | `path=<p> strategy=anchor\|ratio` |
| `markdownViewer.fileMissing` | AC-20 | `path=<p> phase=deleted\|reappeared` |
| `markdownViewer.fileTruncated` | AC-21 | `path=<p> size=<bytes>` |
| `markdownViewer.mermaid` | AC-9/10/11 | `renderErrors=<n> path=<p>` |
| `markdownViewer.mermaid.used` | AC-9 | `path=<p> count=<n>`（含 mermaid 图的文档计数） |

> 注：cmux 本期无生产匿名遥测管道。若后续引入，`markdownViewer.open` 与 `markdownViewer.mermaid.used` 升级为生产事件以验证 ROI。

## 8. 风险 & 约束

- **App Transport Security**：WKWebView 加载 `file://` HTML + 本地 JS，需正确设置 `loadFileURL(_:allowingReadAccessTo:)`，避免跨域阻止
- **Mermaid 版本**：固定到当前 LTS（如 10.x），避免自动升级 breaking
- **bundle 体积方案**（用户 2026-04-14 裁定：**全量本地打包**）：

  | 方案 | 体积 | 离线 | 复杂度 | 本期选择 |
  |------|------|------|--------|----------|
  | **全量本地打包 mermaid (UMD)** | ~4MB | 是 | 低 | ✅ 本期 |
  | 精简打包（仅 flowchart/sequence/class/gantt） | ~1.5-2MB | 是 | 低 | 备选 fallback：仅当全量引起 App Store 审核或冷启动实测回归时再切 |
  | 按需下载 mermaid.js | ~0 | **否** | 高 | — |
  | 放弃 Mermaid，走系统默认 | 0 | 是 | 无 | — |

  选「全量本地打包」理由：保证所有 Mermaid 子类型（gantt / pie / stateDiagram / mindmap / journey 等）可用，避免因裁剪导致意外 case 失败。4MB 增量已接受。

- **依赖版本锁**（A-3）：
  - `mermaid@10.9.3` UMD bundle（全量）
  - `marked@14.1.3`
  - `highlight.js@11.10.0`
  - 锁文件：`Resources/MarkdownViewer/vendor.lock.json`（字段：`name` / `version` / `sha256` / `sourceUrl`）
  - CI + `scripts/release-pretag-guard.sh` 调用 `scripts/verify-markdown-viewer-vendor.sh`：对 `vendor/*.js` 计算 sha256 与 lock 文件对比，任何 diff → 先显式改 lock（人工 review 升级）

- **离线保证**：全部 JS 本地化，**不从 CDN 拉取**；依赖锁版本 + SRI hash
- **依赖维护 owner**：RD 负责，在 Release 流程中每季度 check mermaid / marked / highlight 安全公告；升版前跑 viewer 烟雾测试（Mermaid 所有支持的 diagram 子类型 + 基础 md AC）
- **多窗口泄漏**：关闭窗口时必须释放 MarkdownFileSource + cancel watcher（参考 MarkdownPanel.close）
- **多窗口内存**：每个 viewer 持有独立 WKWebView（~30-50MB 常驻）；≤ 10 同开窗口可接受，超过后 PM 观察用户反馈决定是否复用 WebView
- **Mermaid 大图**：> 5000 节点 SVG 可能导致滚动卡顿，本期不优化，观察用户反馈
- **JS 供应链安全**：依赖锁版本 + SRI hash；升级需人工 diff + 烟雾测试（owner 见上）
- **主题切换**：监听 `NSApp.effectiveAppearance` → post message to web，web 调整 `document.documentElement.className = "dark"`

## 9. 用户裁定（2026-04-14）

| ID | 分歧 | 用户决议 |
|----|------|---------|
| D-1 | 战略方向 | **独立新窗口**（按用户原始指令，PM 方案） |
| D-2 | bundle 方案 | **全量本地打包**（~4MB，覆盖所有 Mermaid 子类型） |
| D-3 | tab 版收敛 | **本期冻结**（保留代码，不暴露新入口，下一迭代再评估下线） |

详情见 `discuss/PL-FEEDBACK-R1.md` + `discuss/PM-REPLY-R1.md`。

## 10. 测试策略

遵循 CLAUDE.md「测试质量政策」：**禁止测源码文本 / plist 字段 / 单纯的 key 存在性**。所有 AC 必须通过**运行期可观察行为**验证。

| AC | 测试层级 | 落地方式 |
|----|---------|---------|
| AC-1 / AC-2 | Unit + UITest | 调用 `Manager.showWindow(for:)` 两次同路径，断言 `controllers.count == 1`；窗口 `isKeyWindow == true` |
| AC-3 | Unit | 关闭窗口后 `weak` 引用 Controller / FileSource 均为 nil（dealloc 检测） |
| AC-4 / 窗口记忆 | UITest | 启动 app → 打开 A.md → resize/move → 关闭 → 打开 B.md → 断言 `window.frame == previous frame` |
| AC-7 / AC-8 / AC-13 / AC-14 / AC-15 / AC-16 | UITest + evaluateJavaScript | 打开 fixture md → `evaluateJavaScript("document.querySelectorAll('h1, h2, table, pre, blockquote').length")` 断言结构；dark mode 切换后断言 `document.documentElement.className == "dark"` |
| AC-9 / AC-10 / AC-11 | UITest | 每个 mermaid 子类型一份 fixture → `document.querySelectorAll('svg.mermaid').length >= 1`；断言 SVG 非空（`innerHTML.length > 100`） |
| AC-12 | UITest + bridge | 注入故意语法错的 mermaid → 断言 bridge 收到 `mermaidRenderError` 消息 + 错误文案命中 xcstrings 值 |
| AC-17 | UITest + mock | 替换 `NSWorkspace` 调用为可观测 stub；点击外链后断言 stub 被调用 |
| AC-19 | UITest | 外部写入修改 fixture → 轮询 1-2s → 断言内容更新 + scroll 位置变化（锚点 id 保留或 scrollTopRatio 近似） |
| AC-20 | UITest | 删除文件 → 断言 UI 显示 `markdownViewer.file.deleted` 文案；重新写回 → 内容恢复 |
| AC-21 | UITest | 构造 12MB md fixture → 打开后断言 `viewer.js` 侧 `content.length == 10MB` + 顶部截断 banner 可见 |
| AC-22 | Unit | 构造 ISO-Latin-1 编码 md（非 UTF-8）→ `MarkdownViewerFileSource.content` 非空 |
| AC-23 / AC-24 / AC-25 | XCTest measure | `measure(metrics: [XCTCPUMetric(), XCTClockMetric()])` 块包裹打开流程；signpost 区间断言 p50 ≤ 目标 |
| AC-23 + typing latency 回归 | XCTest measure | 新增基线：主窗口 heavy typing（模拟 `yes` 输出 + 键入）+ 5 viewer 同开大 md；断言 keystroke-to-glyph latency 不劣于 baseline（RD 建议 B-3） |
| AC-26 | CI | `scripts/verify-markdown-viewer-vendor.sh` + `du -b` 脚本断言 vendor 目录 ≤ 5MB |
| AC-27 | CI / release-pretag-guard | `verify-markdown-viewer-vendor.sh` 返回 0 |
| AC-28 | UITest | md fixture 含 `<img src="https://example.com/x.png">` → 打开后断言 `WKNavigationDelegate` 拦截计数 ≥ 1 |
| AC-31 | UITest | 打开 → 关闭 → 立即再打开，断言冷启动时间符合 AC-24 热启动档 |
| AC-32 | UITest | md fixture 含 `<img src="./logo.png">` → DOM 中渲染为 `<a class="markdownViewer-localImage">`（非 `<img>`） |
| AC-D1 ~ AC-D5 | UITest | macOS Window 菜单截屏 / ⌘W keyDown 注入后断言只关当前 viewer / fullscreen 后主窗口 frame 不变 |

### 测试基础设施（TC 阶段产出）

1. **WKWebView JS 断言 helper**：封装 `@MainActor func jsEval(_ script: String) async throws -> Any?` 便于 test 中做 DOM 断言
2. **fixtures 目录**：`cmuxUITests/Fixtures/MarkdownViewer/` 下放基础 md / mermaid 各子类型 / 大文件 / 编码异常 / 本地图片等固定样本
3. **性能测量**：`OSSignpostID` + XCTest measure（参考 cmux 既有 `KeyboardLatencyTests` 之类的实现，若无则新建）
4. **Vendor lock fixture**：`vendor.lock.json` 首次生成走 `fetch-markdown-viewer-vendor.sh`

---

## PMO 备注

- **Designer 范围**：新窗口顶层布局（有无 toolbar、文件名位置、分割线样式）、页面主题（字体/颜色/间距）、Mermaid 图容器样式、错误提示样式
- **QA 范围**：基础 md 渲染、Mermaid 所有子类型、深色模式、文件监听、外链、相对链接、错误文件
- **依赖**：需下载 marked.js / mermaid.js / highlight.js 到 Resources 目录

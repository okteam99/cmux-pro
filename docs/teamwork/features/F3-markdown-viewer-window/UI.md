# F3 · UI 设计

> Feature 流程 · UI
> 作者：Designer | 日期：2026-04-14 | 状态：定稿待 QA / TC 并行
> 依据：`PRD.md`（2026-04-14 定稿）+ `review/PRD-REVIEW.md`（A-9 已回应）
> 风格参考：`Sources/Panels/MarkdownPanelView.swift` 的 `cmuxMarkdownTheme` / `filePathHeader` / focus flash（本窗口在 WKWebView 内以 CSS 重建，不复用 SwiftUI theme）

---

## 0. 设计原则

1. **标准 macOS 窗口**，零自定义 chrome；标题栏即 traffic light + 文件名，无 toolbar（AC-D1 / PRD §1.3 非目标：不加 toolbar）。
2. **阅读优先**：正文最大宽度约 760px，居中，两侧留白；默认字号 15px / 行高 1.65。
3. **与 tab 版观感一致**：背景、代码块、引用色板沿用 `cmuxMarkdownTheme` 色阶（仅换渲染栈，不换视觉语言）。
4. **深色模式单源**：所有 token 用 CSS 变量声明，`html.dark` 翻转。Mermaid 用 `default` / `dark` 主题同步切换（AC-14）。
5. **所有可见文案走 xcstrings**。WKWebView HTML 的占位文案由 Swift 侧在注水前替换；`__MARKDOWN_VIEWER_STRINGS__` placeholder → localized 字典 JSON 注入。

---

## 1. 窗口规格

| 属性 | 值 | 依据 |
|---|---|---|
| NSWindow style | `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView? = false]` | AC-1 / AC-D1 |
| 标题栏样式 | 标准（非 transparent，非 unifiedCompact） | AC-D1 |
| 标题文本 | 文件名（basename），空则 `markdownViewer.window.titleFallback` | PRD §4 xcstrings |
| 初始尺寸 | 900 × 700 | AC-4 |
| 最小尺寸 | 480 × 360 | Designer 定（保证 breadcrumb 不截断） |
| 初始位置 | 主屏居中（首次） | AC-4 |
| 记忆 | 全局单份 frame（最后一个 viewer 关闭时存入 UserDefaults `cmux.markdownViewer.windowFrame`） | AC-4 |
| ⌘W | AppKit 标准 `performClose:` → 只关当前 viewer | AC-D2 |
| fullscreen | 标准按钮启用 | AC-D3 |
| Window 菜单 | 自动列入（`NSWindow.isExcludedFromWindowsMenu = false`） | AC-D1 |

**窗口标题格式**：文件 basename（不含路径）。`Window` 菜单项走同一字符串。tooltip（鼠标悬停标题栏）可显示完整路径（macOS 标准 `⌘+click title bar` 行为，免实现）。

---

## 2. 布局

### 2.1 ASCII 示意（light 模式）

```
┌─────────────────────────────────────────────────────────────────────┐
│ ● ● ●    README.md                                                   │  ← 标准 titlebar, 28px (AC-D1)
├─────────────────────────────────────────────────────────────────────┤
│ ⚠ File too large — showing first 10MB only.                          │  ← AC-21 banner（仅截断时），高 28px
├─────────────────────────────────────────────────────────────────────┤
│  /Users/liam/apps/okok/cmux-pro/README.md                            │  ← path breadcrumb（AC-1 可视化文件名上下文）
│                                                                      │    高 32px，12px 等宽字体，.secondary 色
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│    # cmux                                                            │
│                                                                      │
│    一站式终端 + AI 环境。                                              │
│                                                                      │
│    ## 架构                                                            │
│                                                                      │
│    ┌───────────────────────────────────────┐                         │
│    │ [Mermaid SVG, 居中, 最大宽度 720px]    │                         │
│    │  graph TD                              │                         │
│    │  A --> B --> C                         │                         │
│    └───────────────────────────────────────┘                         │
│                                                                      │
│    ```swift                                                          │
│    let x = 1     // highlight.js                                     │
│    ```                                                               │
│                                                                      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
         ↑                                                     ↑
     左右各 56px padding         内容 max-width 760px (760 + 2*56 = 872 < 900 ok)
```

### 2.2 分层

| 层 | 元素 | 高度 |
|---|---|---|
| L0 | NSWindow titlebar | 系统 28px |
| L1（可选） | 大文件截断 banner（AC-21） | 28px（仅截断时出现） |
| L2 | 文件路径 breadcrumb | 32px（始终可见；**A-9 回应**：文件路径由 UI 显式展示而非仅标题栏） |
| L3 | WKWebView 滚动容器（md 正文） | 剩余全部 |

L1、L2 在 WKWebView 内以 `<header class="viewer-chrome">` sticky 实现，不是 SwiftUI 叠层——这样可随 md 滚动表现而不破坏 WKWebView 内的 find UI（AC-D5）。L1 视情况 `display: none`。

### 2.3 Padding / 正文宽度

- 内容容器 `main.viewer-content`：`max-width: 760px; margin: 0 auto; padding: 32px 56px 96px;`
- 滚动 gutter 由系统渲染，不自定义 scrollbar 样式（降低维护面）。

---

## 3. 排版规范

所有 token 均声明为 CSS 变量（见 §7）。以下只给选择器 + 语义；具体色值看 §7。

| 元素 | 字体 | 大小 / 行高 | 颜色 | 备注 |
|---|---|---|---|---|
| `body` | `-apple-system, "SF Pro Text", "Helvetica Neue"` | 15px / 1.65 | `--fg` | 基准 |
| `h1` | 同上 + `-apple-system UI display` | 30px / 1.25，margin-top 0，margin-bottom 16px | `--fg-strong` | 加 8px 底 border，颜色 `--divider-strong` |
| `h2` | 同 | 24px / 1.3，mt 32px mb 12px | `--fg-strong` | 加 1px 底 border `--divider` |
| `h3` | 同 | 19px / 1.35，mt 24px mb 8px | `--fg-strong` | — |
| `h4` | 同 | 16px / 1.4，mt 20px mb 6px | `--fg-strong` | — |
| `h5` | 同 | 14px / 1.4，mt 16px mb 4px | `--fg-strong` | — |
| `h6` | 同 | 13px / 1.4，mt 16px mb 4px | `--fg-muted` | uppercase, tracking 0.5px |
| `p` | 同 | 15px / 1.7，mb 14px | `--fg` | — |
| `ul`, `ol` | 同 | 15px / 1.7，pl 28px，mb 14px | `--fg` | bullets 随 `--fg-muted` |
| `li + li` | — | mt 4px | — | — |
| `blockquote` | 同 | 15px / 1.7 | `--fg-muted` | `border-left: 3px solid --accent-soft`, `padding: 4px 16px`, `background: --bg-soft`, `margin: 14px 0` |
| `hr` | — | h 1px，margin 24px 0 | `--divider` | — |
| `a` | 同 | 15px | `--link` | 无下划线；`:hover` 下划线 |
| `a:visited` | — | — | `--link` | 不区分 visited（WKWebView 限制 + 设计取舍） |
| `code`（inline） | `"SF Mono", "Menlo", "Consolas", monospace` | 13px | `--code-inline-fg` / bg `--code-inline-bg` | `padding: 1px 5px; border-radius: 4px` |
| `pre > code` | 同 | 13px / 1.55 | `--code-block-fg` / bg `--code-block-bg` | `padding: 14px 16px; border-radius: 8px; overflow-x: auto` |
| `pre` 语言标签 | 同 | 11px uppercase tracking 0.5px | `--fg-muted` | 绝对定位右上角 `top:8px; right:12px; opacity:0.6` |
| `table` | 同 | 14px | `--fg` | 全宽，`border-collapse: collapse`，外边框 1px `--divider` |
| `th` | 同 | 14px bold | `--fg-strong` / bg `--bg-soft` | padding 8px 12px |
| `td` | 同 | 14px | `--fg` | padding 8px 12px，行 border-bottom `--divider` |
| `img` | — | 最大宽度 100% | — | **仅 data: URI 允许**；本地 file:// 降级为 §8 链接 |
| `kbd` | monospace | 12px | `--fg-strong` / bg `--bg-soft` | 1px solid `--divider`, radius 4, padding 1px 4px |
| `details > summary` | body | 15px | `--fg` | `cursor: pointer`，triangle 随系统 |

### 3.1 代码块细节（AC-7 / AC-8）

- 语言标签来自 ```` ```swift ```` 的 info string；渲染为 `<pre data-lang="swift">…</pre>` 并通过伪元素显示。
- **复制按钮（推荐实现）**：`pre` 右上角 hover 时浮出 `Copy` 按钮，28×24，`--fg-muted` 图标 + 1px border；点击后变 `Copied`（2s 后恢复）。**无下文的 xcstrings key**（本期属 UI chrome，不在 PRD xcstrings 清单中）→ 新增 key：
  - `markdownViewer.codeblock.copy` default `Copy`
  - `markdownViewer.codeblock.copied` default `Copied`
  - `markdownViewer.codeblock.copy.aria` default `Copy code to clipboard`
  
  ⚠ **Designer → PM 建议 1**：这三个 key 未在 PRD §4 xcstrings 清单中。若 PM 不接受扩展，则复制按钮降级为非目标并删除；当前 UI 预览按扩展后设计。
- **行号**：默认**不显示**。行号在长代码块中价值中等但会引入列对齐/复制粘贴污染问题。不加。
- 语法高亮 class 命名走 highlight.js `hljs-*` 默认 class。color token 另见 §7 `--hl-*`。

### 3.2 focus flash 类比

tab 版在 panel 获得焦点时有 3px accent 描边 + 淡淡 shadow 闪一下。**新窗口不复用**：窗口级焦点由 macOS 自身呈现（key window / inactive 区别），WKWebView 内部再叠加描边会干扰系统习惯。

---

## 4. Mermaid 容器（3 态）

容器 `div.mermaid-wrap`：

```
.mermaid-wrap {
  margin: 20px auto;
  padding: 16px;
  max-width: 720px;
  border: 1px solid var(--divider);
  border-radius: 10px;
  background: var(--bg-soft);
  text-align: center;
  min-height: 80px;         /* 占位高，避免 CLS */
  display: flex;
  align-items: center;
  justify-content: center;
  position: relative;
}
.mermaid-wrap > svg { max-width: 100%; height: auto; }
```

### 4.1 loading 态（渲染前 / 大图）

```
┌────────────────────────────────────────────┐
│                                            │
│           ◐  Rendering diagram…            │   ← 灰色小旋转圈 + 文案
│                                            │
└────────────────────────────────────────────┘
```

- 旋转圈：12px inline SVG，`stroke: var(--fg-muted)`，CSS animation 1s linear infinite。
- 文案 key：`markdownViewer.mermaid.loading` default `Rendering diagram…`（⚠ Designer → PM 建议 2：新增 key；或省略文字只留 spinner，省一个 key）。

### 4.2 success 态

SVG 居中；容器不变。dark 模式下 mermaid 主题自动切 `dark`，SVG 内节点色/文本色自动跟随（不需要后处理）。

### 4.3 error 态（AC-12）

```
┌────────────────────────────────────────────┐   ← border 换为 --danger-border
│ ⚠  Failed to render Mermaid diagram.       │   ← 文案 markdownViewer.mermaid.error
│                                            │
│    ```mermaid                              │   ← fallback：把原始 code block 以
│    grph TD                                 │      <pre> 原样展示（AC-12「不崩溃」）
│    A -> B                                  │
│    ```                                     │
└────────────────────────────────────────────┘
```

```
.mermaid-wrap.is-error {
  border-color: var(--danger-border);
  background: var(--danger-bg);
  text-align: left;
  flex-direction: column;
  align-items: stretch;
  padding: 12px 14px;
}
.mermaid-wrap.is-error .msg { color: var(--danger-fg); font-size: 13px; margin-bottom: 8px; }
.mermaid-wrap.is-error pre { background: var(--code-block-bg); margin: 0; }
```

Bridge 消息：JS 捕获 mermaid 渲染 error 后 `cmux.mermaidRenderError({count, messages})`（PRD §5.4），DOM 侧切入 error 态。

---

## 5. 交互行为

| 交互 | 行为 | AC |
|---|---|---|
| 左键点击正文 `a[href^="http"]` | JS 阻止默认；`cmux.openExternal(href)` → native `NSWorkspace.shared.open` | AC-17 |
| 左键点击 `a[href^="#"]` | 正常锚点滚动（WKWebView 原生） | AC-16 |
| 左键点击 `a[href^="./"]` / `a[href^="/"]` / `a[href^="file://"]` | `cmux.openExternal(resolvedFileURL)` → 系统默认应用打开 | AC-18 |
| 左键点击本地图片降级链接（见 §8） | 同上（system open） | AC-32 |
| 文本选中 | WKWebView 默认 | AC-15 |
| ⌘C | WKWebView 默认 copy | AC-15 |
| ⌘A | WKWebView 默认 select all | AC-15 |
| **⌘F** | **非目标**：不做自定义 find UI；由 WKWebView 默认行为决定（不承诺亦不禁止）。**Designer 确认：不渲染任何 find bar / SurfaceSearchOverlay** | AC-D5（**A-9 回应**） |
| **⌘+ / ⌘- / ⌘0** 字号缩放 | **非目标**（PRD §1.3 排除）。Designer 确认：CSS 无 `zoom`，不响应、不设置快捷键 | PRD §1.3（**A-9 回应**） |
| 滚动 | WKWebView 原生；**rerender 保留位置**（AC-19 滚动恢复契约，无 UI 显式提示） | AC-19 |
| ⌘W | AppKit 标准，关当前 viewer；不影响主窗口 / 其他 viewer | AC-D2 |
| fullscreen | 标准绿灯按钮 | AC-D3 |
| 窗口失焦 / 重新聚焦 | 系统默认，无额外视觉；标题栏自动变浅（macOS inactive state） | AC-D1 |
| Mermaid SVG 拖拽 | 不支持（非目标） | — |
| Mermaid SVG 右键 | WKWebView 默认菜单（Copy Image / Save Image 等） | — |
| 代码块 hover | 右上角浮出 Copy 按钮（详见 §3.1） | 扩展 |
| 代码块 Copy 按钮点击 | 写入 pasteboard；按钮 2s 内变 Copied | 扩展 |

**A-9 明确排除项（Designer 自查）**：⌘F 自定义 find UI、⌘± 字号缩放、toolbar、字体 picker、阅读模式切换。

---

## 6. 错误 / 空态

**A-9 回应：共 5 种状态**（原 UI 只覆盖 2 种，补足 3 种）。

| # | 状态 | 触发 | UI | xcstrings key |
|---|---|---|---|---|
| 1 | 正常渲染 | 默认 | 见 §2/§3 | — |
| 2 | 空文件 | 文件存在，size == 0 | 居中灰色大字「`(empty)`」，icon `􀈿` | `markdownViewer.file.empty` |
| 3 | 文件不可读（编码失败 / 权限） | AC-22 UTF-8 + ISO Latin-1 均失败 | 居中：icon 40px + title + 文件路径 monospace + hint | `markdownViewer.file.unavailable` |
| 4 | **文件被删除**（AC-20） | watcher 检测到 unlink | 居中：`🗑️` 40px + `The file has been deleted.` + 小字提示：`Waiting for the file to reappear…`（新 key `markdownViewer.file.deleted.hint` default `Waiting for the file to reappear…`，⚠ Designer → PM 建议 3） | `markdownViewer.file.deleted` |
| 4b | **文件重现恢复**（AC-20 回归） | watcher 发现重建文件 | 无显式通知；直接渲染新内容，滚动位置按 AC-19 恢复（首次重现 scrollTopRatio=0） | — |
| 5 | **大文件截断**（AC-21） | size > 10MB | 顶部 28px 黄色 banner；下方正常渲染前 10MB | `markdownViewer.file.truncated` |

### 6.1 居中空态布局（#2 / #3 / #4）

```
.viewer-empty {
  position: absolute; inset: 0;
  display: flex; flex-direction: column;
  align-items: center; justify-content: center;
  gap: 12px;
  color: var(--fg-muted);
  padding: 32px;
}
.viewer-empty .icon { font-size: 40px; }
.viewer-empty .title { font-size: 15px; color: var(--fg); }
.viewer-empty .path { font-family: "SF Mono", monospace; font-size: 12px; }
.viewer-empty .hint { font-size: 12px; }
```

### 6.2 截断 banner（#5 / AC-21）

见 §9。

---

## 7. 颜色 token 表（完整 light / dark 对照）

**全部 CSS 变量**；声明在 `:root`（light），被 `html.dark` 覆盖（dark）。色值对齐 `MarkdownPanelView` 的灰阶与 accent，除非注明。

| token | 语义 | light | dark | 对齐源 |
|---|---|---|---|---|
| `--bg` | 窗口/正文底 | `#FAFAFA`（对齐 `NSColor(white:0.98)`） | `#1F1F1F`（对齐 `NSColor(white:0.12)`） | MarkdownPanelView.backgroundColor |
| `--bg-soft` | 代码块/表头/引用底 | `#EDEDED` | `#2B2B2B` | MarkdownPanelView codeBlock bg |
| `--bg-raise` | Mermaid 容器、banner 内容承托 | `#FFFFFF` | `#242424` | 新 |
| `--fg` | 正文 | `#1E1E1E` | `#EAEAEA` | `.primary` 近似 |
| `--fg-strong` | 标题 | `#000000` | `#FFFFFF` | MarkdownPanelView heading |
| `--fg-muted` | breadcrumb / 引用 / 行号 / 次要 | `#666666` | `#A0A0A0` | `.secondary` |
| `--divider` | 表格 / h2 底线 / Mermaid border | `#E0E0E0` | `#333333` | 新 |
| `--divider-strong` | h1 底线 | `#C8C8C8` | `#444444` | 新 |
| `--accent` | 链接 / focus 描边 | `#0A7BFF`（对齐 cmuxAccentColor 近似） | `#4FA3FF` | cmuxAccentColor |
| `--accent-soft` | blockquote 左边条 | `#0A7BFF` at 55% sat | `#4FA3FF` at 55% | 新 |
| `--link` | `a` 文本 | `#0A63DF` | `#6EB5FF` | 新（同 accent 分阶） |
| `--code-inline-fg` | inline code 文本 | `#6A1F9E`（紫） | `#E5A8FF` | MarkdownPanelView inline code (0.6,0.2,0.7 / 0.85,0.6,0.95) |
| `--code-inline-bg` | inline code 底 | `#EBE8EB` | `#2E2E2E` | MarkdownPanelView inline code bg |
| `--code-block-fg` | 块代码默认文本 | `#333333` | `#E6E6E6` | MarkdownPanelView |
| `--code-block-bg` | 块代码底 | `#EDEDED` | `#141414` | MarkdownPanelView code block bg (0.93 / 0.08) |
| `--table-row-alt` | 表格 zebra（可选） | `#F4F4F4` | `#262626` | 新 |
| `--banner-warn-bg` | 截断 banner 底 | `#FFF4D6` | `#3A3420` | PRD AC-21 约定 |
| `--banner-warn-fg` | 截断 banner 文字 | `#6B4E00` | `#F5D877` | 新 |
| `--banner-warn-border` | 截断 banner 下边 | `#EBD48A` | `#5A4E20` | 新 |
| `--danger-bg` | Mermaid error 底 | `#FFECEC` | `#3A1F1F` | 新 |
| `--danger-fg` | Mermaid error 文字 | `#B3261E` | `#FF9E9A` | 新 |
| `--danger-border` | Mermaid error 边 | `#E9A7A2` | `#6B2F2B` | 新 |
| `--hl-keyword` | highlight.js keyword | `#A71D5D` | `#F97583` | highlight.js github theme 参考 |
| `--hl-string` | 字符串 | `#0A3069` | `#9ECBFF` | 同 |
| `--hl-comment` | 注释 | `#6A737D` | `#8B949E` | 同 |
| `--hl-number` | 数字 | `#005CC5` | `#79B8FF` | 同 |
| `--hl-type` | 类型 / 类名 | `#6F42C1` | `#B392F0` | 同 |
| `--hl-function` | 函数名 | `#6F42C1` | `#B392F0` | 同 |

**Mermaid theme**：
- light 模式：`mermaid.initialize({ theme: "default", securityLevel: "strict", fontFamily: "-apple-system, SF Pro Text, sans-serif" })`
- dark 模式：`mermaid.initialize({ theme: "dark", ... })`
- 主题切换：`NSApp.effectiveAppearance` 变化 → Swift `postMessage("themeChanged", "dark"|"light")` → JS 重新 `mermaid.initialize` + re-render 所有已缓存的 mermaid DOM 节点（不 reload 整页）。

---

## 8. 本地图片降级样式（AC-32）

md 中 `<img src="./logo.png">` / 任何非 data: URI 的本地图片：Swift 在 marked post-processing 里（或 JS 端 post-processing）把 `<img>` 替换为：

```html
<a class="local-image" href="file:///abs/path/to/logo.png"
   data-external="true" title="Open in default app">
  <svg class="local-image-icon" …>🔗 + 📎</svg>
  <span class="local-image-label">logo.png</span>
  <span class="local-image-hint">(local image · click to open)</span>
</a>
```

CSS：

```
.local-image {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 2px 8px;
  border-radius: 6px;
  background: var(--bg-soft);
  color: var(--link);
  text-decoration: none;
  font-size: 14px;
  border: 1px dashed var(--divider);
}
.local-image:hover { text-decoration: underline; background: var(--bg-raise); }
.local-image-icon { width: 14px; height: 14px; color: var(--fg-muted); }
.local-image-label { font-family: "SF Mono", monospace; font-size: 13px; }
.local-image-hint { color: var(--fg-muted); font-size: 12px; }
```

**交互**：点击 → JS `event.preventDefault()` → `cmux.openExternal(href)`。

**文案 xcstrings**（⚠ Designer → PM 建议 1 同条合并）：
- `markdownViewer.localImage.hint` default `(local image · click to open)`
- `markdownViewer.localImage.tooltip` default `Open in default app`

---

## 9. 大文件截断 banner（AC-21）

```
┌─────────────────────────────────────────────────────────────────────┐
│ ⚠  File too large — showing first 10MB only.                         │  ← light: #FFF4D6 bg, #6B4E00 fg
└─────────────────────────────────────────────────────────────────────┘
```

```
.truncate-banner {
  position: sticky; top: 0; z-index: 5;
  height: 28px;
  display: flex; align-items: center; gap: 8px;
  padding: 0 16px;
  background: var(--banner-warn-bg);
  color: var(--banner-warn-fg);
  border-bottom: 1px solid var(--banner-warn-border);
  font-size: 12px;
  font-weight: 500;
}
.truncate-banner .icon { font-size: 13px; }
```

- Swift 侧决定 `document.body.classList.add('is-truncated')`，banner 节点通过 `hidden` toggle。
- 文案：`markdownViewer.file.truncated` default `File too large — showing first 10MB only.`
- banner 不可被用户关闭（设计取舍：信息持续有效）。

---

## 10. AC × UI 设计交叉索引

| AC | UI 设计决策 | 位置 |
|---|---|---|
| AC-1 | 标准 NSWindow + titlebar 显示 basename + breadcrumb 显示完整路径 | §1 / §2 |
| AC-2 | UI 无影响（Manager 聚焦已有窗口，视觉上等同用户切窗） | — |
| AC-3 | UI 无影响 | — |
| AC-4 | 无可见 UI，但在 §1 说明 window frame 全局复用 | §1 |
| AC-5 | 使用系统标准按钮 | §1 |
| AC-6 | UI 无影响 | — |
| AC-7 | §3 排版规范覆盖全部基础元素 | §3 |
| AC-8 | `pre[data-lang]` + highlight.js hljs-* class + §7 `--hl-*` | §3.1 / §7 |
| AC-9 | `.mermaid-wrap` success 态 | §4.2 |
| AC-10 | 同 AC-9（JS 层识别 `graph TD` 裸 mermaid 语法，容器样式相同） | §4.2 |
| AC-11 | 容器大小自适应，`max-width: 720px`，gantt / mindmap 内部 SVG 自行布局 | §4 |
| AC-12 | `.mermaid-wrap.is-error` + fallback `<pre>` | §4.3 |
| AC-13 | HTML 元素样式覆盖（`details/summary`、`kbd`、`br`） | §3 |
| AC-14 | 所有 color token 双态；mermaid theme `default` ↔ `dark` 联动 | §7 |
| AC-15 | WKWebView 默认 selection；正文 `user-select: text` 不禁用 | §5 |
| AC-16 | 默认锚点滚动 | §5 |
| AC-17 | JS 劫持 `a[href^="http"]` → bridge | §5 |
| AC-18 | JS 劫持 `a[href^="./"]` / file:// → bridge | §5 |
| AC-19 | UI 不抖动：sticky header 不参与 scroll position 计算；rerender 期间 body opacity 不变（不做白屏 flash） | §5 / §6.1 |
| AC-20 | 状态 #4（删除态）+ 状态 #4b（静默恢复） | §6 |
| AC-21 | `.truncate-banner` sticky 顶部 | §9 |
| AC-22 | UI 透明；若最终仍失败 → 状态 #3 | §6 |
| AC-23 / AC-24 / AC-25 | UI 无影响（性能由渲染栈决定），Mermaid loading 态规避 CLS | §4.1 |
| AC-26 / AC-27 | CI / 构建相关，UI 无影响 | — |
| AC-28 | UI 透明（WKWebView 拦截不进入 DOM）。图片空位 Designer 建议显示为 §8 同款降级链接但标为 `(external blocked)`——⚠ Designer → PM 建议 3（可选） | — |
| AC-32 | §8 本地图片降级 | §8 |
| AC-D1 | 标准 titlebar，Window 菜单自动 | §1 |
| AC-D2 | UI 透明（AppKit 原生） | §1 |
| AC-D3 | 系统 fullscreen，无 viewer 内部 UI 反应 | §1 |
| AC-D4 | UI 透明 | — |
| AC-D5 | UI 不提供 find bar；留给 WKWebView 默认（**A-9 明确**） | §5 |
| AC-31 | UI 透明 | — |

---

## 11. 非 UI 目标（明确排除，A-9 闭环）

- 自定义 toolbar / 二级 navigation
- ⌘F 自定义 find bar（使用 WKWebView 默认，AC-D5）
- ⌘+ / ⌘- / ⌘0 字号缩放（PRD §1.3）
- 多文档 tab / 侧边栏 TOC
- 文档大纲 / 目录跳转面板
- 打印 / 导出 PDF / 导出 Mermaid SVG（本期 bridge 占位，UI 无入口）
- Debug 菜单 Tuning 窗口（PRD §1.3；token 硬编码到 CSS 即可）
- Reading mode / Sepia 等阅读器主题切换
- 搜索 / recent files 面板（PRD §1.3）
- Find-in-page 快捷栏 / 阅读进度条 / 字数统计
- 共享 / 协同光标（PRD §1.3）

---

## 12. Designer → PM 建议（最多 3 条）

1. **xcstrings 扩展**：PRD §4 xcstrings 清单只覆盖了错误/提示类 6 条。本 UI 需要新增最多 6 条 chrome 文案（`codeblock.copy` / `codeblock.copied` / `codeblock.copy.aria` / `mermaid.loading` / `localImage.hint` / `localImage.tooltip` / `file.deleted.hint`）。建议 PM 在 PRD §4 追加，或裁掉代码块复制按钮 + loading 文案以保持 clean。默认按「追加」设计，PREVIEW 使用这些文案。
2. **AC-28 外网图被拦截时的 DOM 视觉**：PRD 仅要求运行期拦截，但 md 正文此处会留下「什么都没有」的诡异空缺。建议显式降级为「🚫 external image blocked: https://…」的链接样式（同 §8 但灰调），否则用户会怀疑渲染 bug。若 PM 不接受，仍按「完全不渲染」实现，Designer 不反对。
3. **AC-4 窗口记忆漂移**：全局单份 frame 在多显示器切换场景会出现记忆位置落到不可见屏幕的 corner case。建议 RD 在 `showWindow` 时校验 `NSScreen.screens` 包含保存的 origin，否则回退居中。这是 RD 的实现细节，但 UI 侧需要知道可能首次显示不是保存的位置。

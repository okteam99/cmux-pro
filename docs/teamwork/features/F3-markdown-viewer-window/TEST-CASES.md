# F3 · Test Cases

> Feature 流程 · Test Cases (BDD)
> 作者：QA | 日期：2026-04-14 | 状态：草稿待 QA Lead 评审
> 依据：`PRD.md` §3 AC、`UI.md` §6/§10、`TEST-PLAN.md`
> 约束：`CLAUDE.md` 测试质量政策（禁止测源码文本 / plist 字段 / AST fragment）

> **约定**：
> - `ViewerManager` = `MarkdownViewerWindowManager.shared`
> - `jsEval(controller, script)` 见 TEST-PLAN §3.1
> - `BridgeRecorder` 见 TEST-PLAN §3.2
> - `StubExternalOpener` 见 TEST-PLAN §3.3
> - Fixture 路径见 TEST-PLAN §3.4
> - 所有 UITest 启动 app 使用 `./scripts/reload.sh --tag qa-f3` 产出的 tagged build，禁止 untagged app

---

## 基础与窗口（CASE 1–10）

### CASE 1 · AC-1 · File Explorer 打开 `.md` 弹出独立 NSWindow

**层级**：Unit

**Given**
- `ViewerManager.controllers` 字典为空
- fixture `basic/README.md` 已就绪

**When**
- 调用 `ViewerManager.showWindow(for: fixtureURL.path)`（main actor）

**Then**
- `ViewerManager.controllers.count == 1`
- 返回的 controller `window != nil`，且 `window.styleMask.contains(.titled)` / `.closable` / `.miniaturizable` / `.resizable` 均为 true
- `window.title` 以 `README.md` 结尾（basename 命中），非 xcstrings fallback
- 打开埋点 `markdownViewer.open action=new path=<p>` 在 debug log ring buffer 中可检索（通过 `DebugEventLog.shared.snapshot()` seam）

**Fixture**：`cmuxUITests/Fixtures/MarkdownViewer/basic/README.md`

**备注**：Unit 层只验证 Manager 状态与 NSWindow 属性，不渲染 DOM；DOM 渲染在 Case 10 验证。未断言源码文本。

---

### CASE 2 · AC-1 · 窗口标题在文件无 basename 时回退

**层级**：Unit

**Given**
- 构造 fictive path `"/"`（basename 为空）

**When**
- 调用 `ViewerManager.showWindow(for: "/")`（允许 controller 创建，文件不可读进入错误态；本 case 只看 title）

**Then**
- `window.title` 非空且等于 `String(localized: "markdownViewer.window.titleFallback", defaultValue: "Markdown Viewer")` 的 runtime 求值结果
- 断言通过调用 `Bundle.main.localizedString` 获取**运行期值**（非读 xcstrings 文件）

**备注**：验证本地化 fallback 的运行时行为，不扫 xcstrings 文件。

---

### CASE 3 · AC-2 · 同一 md 二次请求聚焦既有窗口

**层级**：Unit

**Given**
- 已对 `basic/README.md` 调用一次 `showWindow`，controller A 存在
- `NSApp.windows.filter { $0 == controllerA.window }.count == 1`

**When**
- 再次调用 `ViewerManager.showWindow(for: fixtureURL.path)`

**Then**
- `ViewerManager.controllers.count == 1`（未新建）
- 返回 controller `===` 之前的 controller A
- `controllerA.window.isKeyWindow == true`（makeKeyAndOrderFront 生效）
- debug log 中存在 `action=focus-existing`

---

### CASE 4 · AC-2 · 不同路径打开创建独立窗口

**层级**：Unit

**Given**
- fixtures `basic/README.md` 与 `basic/anchors.md`

**When**
- 分别调用 `showWindow(for: A)` 与 `showWindow(for: B)`

**Then**
- `ViewerManager.controllers.count == 2`
- 两 controller 持有不同 `WKWebView` 实例（`===` 比较非同）

---

### CASE 5 · AC-3 · 关闭窗口释放资源

**层级**：Unit

**Given**
- 打开 `basic/README.md`，持 `weak var weakController`、`weak var weakSource`、`weak var weakWebView`

**When**
- 调用 `controller.window.performClose(nil)` 触发 `windowWillClose`
- 主 runloop spin 1 次让 dealloc 发生

**Then**
- `weakController == nil`
- `weakSource == nil`（`MarkdownViewerFileSource` watcher 已 cancel 并释放）
- `weakWebView == nil`
- `ViewerManager.controllers[path] == nil`

**备注**：dealloc 检测。`FileWatcherDriver` 的 tmpdir 也需被清理（在 teardown 验证 `DispatchSourceFileSystemObject` 的 `isCancelled` 为 true 的替代断言，即打开时持有的 fd 已被 close，可通过 `lsof` 过 runloop 后间接观察；若不稳定则保留 weak nil 检查为主断言）。

---

### CASE 6 · AC-4 · 初次打开窗口尺寸 900×700 且居中

**层级**：UITest

**Given**
- 清空 `UserDefaults` 中 `cmux.markdownViewer.windowFrame`（test suiteName）

**When**
- 启动 app，打开 `basic/README.md`

**Then**
- `controller.window.frame.size == CGSize(width: 900, height: 700)`
- `|window.frame.midX - screen.visibleFrame.midX| < 1.0`（居中容差）

---

### CASE 7 · AC-4 · 关闭后全局记忆在下次任一文件打开时生效；多屏断开回退居中

**层级**：UITest

**Given**
- 打开 `basic/README.md`，拖拽 resize 到 1200×800，移动到 (100, 100)；关闭窗口
- UserDefaults 写入完成（`UserDefaults.standard.synchronize()` 后 frame 被持久化）

**When（子用例 A · 屏存在）**
- 打开 `basic/anchors.md`（不同文件）

**Then（A）**
- 新窗口 `frame.size == CGSize(1200, 800)`
- `frame.origin` 约等于 (100, 100)（±2 px 容差）

**When（子用例 B · 屏断开模拟）**
- teardown 后手动改 UserDefaults 的 frame origin 为 `(99999, 99999)`（超出任何 screen）
- 再次打开 `basic/anchors.md`

**Then（B）**
- 新窗口 frame 回退为居中（与 Case 6 同条件）
- 不抛异常，不出现窗口不可见

**备注**：覆盖 PRD AC-4 的「多屏 fallback」分支。

---

### CASE 8 · AC-5 · 最小化与全屏按钮响应标准行为

**层级**：UITest

**Given**
- 打开 `basic/README.md` 窗口

**When / Then（minimize）**
- 调用 `window.miniaturize(nil)` → `window.isMiniaturized == true`
- 调用 `window.deminiaturize(nil)` → `window.isMiniaturized == false`

**When / Then（fullscreen）**
- 调用 `window.toggleFullScreen(nil)` → 等待 `NSWindow.didEnterFullScreenNotification`
- `window.styleMask.contains(.fullScreen) == true`
- 再次 toggle → `.fullScreen` 翻转为 false

**备注**：动画帧不断言；只看 styleMask 翻转（见 TEST-PLAN §4.2）。

---

### CASE 9 · AC-6 · 非 md 文件 path 直接调用 Manager 被拒绝

**层级**：Unit

**Given**
- 构造 fixture `basic/not-markdown.png`

**When**
- 调用 `ViewerManager.showWindow(for: "...not-markdown.png")`

**Then**
- 要么方法 precondition 失败抛 `ViewerError.unsupportedExtension`（期望行为），要么 controllers 不新增（取决于 RD 实现选择，两者之一即可）
- `ViewerManager.controllers.count == 0`
- 不抛崩溃性异常

**备注**：PRD 说「入口已拦截」；本 case 验证 Manager 层有防御式 guard，即便入口 bug 也不会触达渲染。

---

### CASE 10 · AC-7 · 基础 md 结构元素渲染到位（DOM 断言）

**层级**：UITest

**Given**
- 打开 `basic/README.md`（含 h1/h2/h3、ul、ol、table、pre、blockquote、hr、a、img data: URI）

**When**
- `await waitUntilReady()`

**Then**
- `jsEval("document.querySelectorAll('h1').length") >= 1`
- `jsEval("document.querySelectorAll('h2').length") >= 1`
- `jsEval("document.querySelectorAll('ul, ol').length") >= 2`
- `jsEval("document.querySelectorAll('table thead th').length") >= 1`
- `jsEval("document.querySelectorAll('pre > code').length") >= 1`
- `jsEval("document.querySelectorAll('blockquote').length") >= 1`
- `jsEval("document.querySelectorAll('hr').length") >= 1`
- `jsEval("document.querySelector('main.viewer-content') !== null") == true`（正文容器存在）

**Fixture**：`basic/README.md`

---

## 渲染（CASE 11–25）

### CASE 11 · AC-7 · Breadcrumb 显示完整文件路径（UI §2 L2）

**层级**：UITest

**Given**
- 打开 `basic/README.md`，fixture 绝对路径为 `P`

**When / Then**
- `jsEval("document.querySelector('.viewer-chrome .breadcrumb')?.textContent")` 包含 `P` 的绝对路径子串
- 文本元素的 computed style `font-family` 含 `"SF Mono"` 或 `"monospace"` 之一

---

### CASE 12 · AC-7 · 内容最大宽度 760px / 外侧 padding 56px

**层级**：UITest

**Given**
- 打开 `basic/README.md`，窗口 1200px 宽

**When / Then**
- `jsEval("getComputedStyle(document.querySelector('main.viewer-content')).maxWidth")` 等于 `"760px"`
- padding-left / padding-right 等于 `"56px"`

**备注**：验证运行时 CSS computed style，不读 css 文件文本。

---

### CASE 13 · AC-7 · 基础 md 内链接渲染为 `<a>` 元素

**层级**：UITest

**Given**
- 打开 `basic/README.md`

**When / Then**
- `jsEval("document.querySelectorAll('a[href]').length") >= 1`
- 外链 `a[href^="http"]` 至少 1 个

---

### CASE 14 · AC-8 · 代码块语法高亮（highlight.js 注入 hljs class）

**层级**：UITest

**Given**
- 打开 `basic/code-langs.md`（swift/python/js/go/rust 各一块）

**When / Then**
- `jsEval("document.querySelectorAll('pre > code.hljs').length") >= 5`
- `jsEval("document.querySelectorAll('pre > code .hljs-keyword').length") >= 1`
- `jsEval("document.querySelectorAll('pre[data-lang=\"swift\"]').length") >= 1`

**Fixture**：`basic/code-langs.md`

---

### CASE 15 · AC-9 · ` ```mermaid ` 代码块渲染为 SVG

**层级**：UITest

**Given**
- 打开 `mermaid/graph.md`（含一个 ` ```mermaid graph TD A-->B-->C ``` `）

**When**
- `await waitUntilReady()`；再 poll 至 `document.querySelector('.mermaid-wrap svg')` 出现（≤ 3s）

**Then**
- `jsEval("document.querySelectorAll('.mermaid-wrap svg').length") >= 1`
- `jsEval("document.querySelector('.mermaid-wrap svg').innerHTML.length") > 100`
- `jsEval("document.querySelector('.mermaid-wrap').classList.contains('is-error')") == false`

---

### CASE 16 · AC-10 · ` ```graph ` 裸 mermaid 代码块按 PRD 规范放入 `.mermaid-wrap`

**层级**：UITest

**Given**
- 打开 `mermaid/naked-graph.md`（info string 为 ` ```graph ` 而非 `mermaid`）

**When / Then**
- `jsEval("document.querySelectorAll('.mermaid-wrap svg').length") >= 1`（JS 侧识别并升级）

**备注**：PRD AC-10 正文已澄清「裸 mermaid 语法放在 mermaid 标签下」，但 case 仍覆盖常见 info string `graph` / `flowchart` 的兜底识别。

---

### CASE 17 · AC-11 · flowchart 子类型渲染

**层级**：UITest

**Fixture**：`mermaid/flowchart.md`

**Then**：`document.querySelectorAll('.mermaid-wrap svg').length >= 1` 且 `innerHTML.length > 100`

---

### CASE 18 · AC-11 · sequenceDiagram 子类型渲染

**层级**：UITest

**Fixture**：`mermaid/sequence.md`

**Then**：同 Case 17 断言模式

---

### CASE 19 · AC-11 · classDiagram 子类型渲染

**层级**：UITest

**Fixture**：`mermaid/class.md`

**Then**：同 Case 17 断言模式

---

### CASE 20 · AC-11 · gantt 子类型渲染

**层级**：UITest

**Fixture**：`mermaid/gantt.md`

**Then**：同 Case 17 断言模式

---

### CASE 21 · AC-11 · pie / stateDiagram 子类型渲染

**层级**：UITest

**Fixture**：`mermaid/pie.md`、`mermaid/state.md`（两个独立 test method）

**Then**：每个 fixture 均满足 `svg.length >= 1 && innerHTML.length > 100`

---

### CASE 22 · AC-11 · mindmap / journey 子类型渲染

**层级**：UITest

**Fixture**：`mermaid/mindmap.md`、`mermaid/journey.md`

**Then**：同 Case 21

**备注**：Case 17–22 共同覆盖 PRD AC-11 + bundle 策略 §8「全量本地打包」承诺（gantt/pie/state/mindmap/journey 需可用）。

---

### CASE 23 · AC-12 · Mermaid 语法错显示错误态 + fallback 原文 + bridge 消息

**层级**：UITest + Bridge

**Given**
- 打开 `mermaid/broken.md`（内容 `grph TD\nA -> B`）
- `BridgeRecorder` 已注册

**When**
- `await waitUntilReady()` + poll `.mermaid-wrap.is-error` 出现（≤ 3s）

**Then**
- `jsEval("document.querySelectorAll('.mermaid-wrap.is-error').length") == 1`
- `.mermaid-wrap.is-error pre` 存在，其 `textContent` 包含原始 `grph TD` 字符串
- `.mermaid-wrap.is-error .msg` 的 `textContent` 等于运行期求值的 `String(localized: "markdownViewer.mermaid.error")`（en：`Failed to render Mermaid diagram.`）
- `BridgeRecorder.waitForMessage("mermaidRenderError")` 在 2s 内收到，payload `count >= 1`
- 同页非 mermaid 元素（如 h1）仍正常渲染（未整页崩溃）

**备注**：通过 DOM 实际 textContent 验证 xcstrings 本地化命中，而非读 xcstrings 文件。

---

### CASE 24 · AC-13 · 内嵌 HTML `<br>` / `<details>` / `<kbd>` 正常渲染

**层级**：UITest

**Fixture**：`basic/html-inline.md`

**Then**
- `jsEval("document.querySelectorAll('br').length") >= 1`
- `jsEval("document.querySelectorAll('details > summary').length") >= 1`
- 点击 `summary` 后 `details.open == true`（通过 `jsEval("document.querySelector('details').click(); document.querySelector('details').open")`）
- `jsEval("document.querySelectorAll('kbd').length") >= 1`

---

### CASE 25 · AC-14 · 深色模式切换：文本 / 代码 / Mermaid 同步

**层级**：UITest

**Given**
- 打开 `mermaid/graph.md`，系统 appearance 初始为 light

**When**
- 通过 `NSApp.appearance = NSAppearance(named: .darkAqua)` 触发 effectiveAppearance change
- 等待 bridge `themeChanged` 处理完成（BridgeRecorder 等 `themeApplied` 消息；若无该消息则 poll DOM class）

**Then**
- `jsEval("document.documentElement.classList.contains('dark')") == true`
- `jsEval("getComputedStyle(document.body).backgroundColor")` 变化，且与 light 前值不等
- `jsEval("document.querySelectorAll('.mermaid-wrap svg').length") >= 1`（Mermaid 仍存在，rerender 完成）
- 切回 light：`document.documentElement.classList.contains('dark') == false`

---

## 交互与链接（CASE 26–29）

### CASE 26 · AC-15 · 文本可选中复制

**层级**：UITest

**Given**
- 打开 `basic/README.md`

**When**
- `jsEval("window.getSelection().removeAllRanges(); const r = document.createRange(); r.selectNodeContents(document.querySelector('h1')); window.getSelection().addRange(r); document.execCommand('copy'); window.getSelection().toString()")`

**Then**
- 返回字符串非空且等于 h1 textContent
- pasteboard （`NSPasteboard.general.string(forType:.string)`）等于同一 h1 textContent

---

### CASE 27 · AC-16 · 内部锚点 `#anchor` 滚动

**层级**：UITest

**Given**
- 打开 `basic/anchors.md`（含 `## Section B` 且正文有 `[jump](#section-b)`）

**When**
- `jsEval("window.scrollTo(0,0); document.querySelector('a[href=\"#section-b\"]').click()")`
- 等待 50ms

**Then**
- `jsEval("window.scrollY") > 0`
- 被滚到视口顶部附近的元素 `document.elementFromPoint(50, 80)` 的祖先链中包含 `h2#section-b`

---

### CASE 28 · AC-17 · 外链走 NSWorkspace.open（stub 验证）

**层级**：UITest（注入 DEBUG seam 后可 Unit 化，取 UITest 保真）

**Given**
- 打开 `basic/external-link.md`
- controller 注入 `StubExternalOpener`

**When**
- `jsEval("document.querySelector('a[href^=\"https://\"]').click()")`

**Then**
- `stubOpener.openedURLs.count == 1`
- `stubOpener.openedURLs.first?.absoluteString` == fixture 中的 https URL
- WKWebView 当前 URL 未变化（`jsEval("location.href")` 仍为 `file://.../viewer.html`）
- debug log 含 `markdownViewer.webNav action=open-external`

---

### CASE 29 · AC-18 · 相对路径链接走 NSWorkspace（不开 viewer）

**层级**：UITest

**Given**
- 打开 `basic/relative-link.md`（含 `[rel](./other.md)`）
- 注入 `StubExternalOpener`

**When**
- `jsEval("document.querySelector('a[href=\"./other.md\"]').click()")`

**Then**
- `stubOpener.openedURLs.count == 1`，URL scheme 为 `file`
- `ViewerManager.controllers.count == 1`（未新开 viewer，刻意设计）

---

## 动态更新与容错（CASE 30–35）

### CASE 30 · AC-19 · 外部修改触发自动刷新且保留滚动位置（anchor 策略）

**层级**：UITest

**Given**
- 打开一个 20 KB 长 md，含多级 heading
- `jsEval("document.querySelector('h2:nth-of-type(3)').scrollIntoView({block:'start'})")`
- 记录 `scrollYBefore = jsEval("window.scrollY")`

**When**
- 外部写入（`FileWatcherDriver.rewrite`）在文档末尾追加一段文字，保持所有 heading id 不变

**Then**
- 2 秒内 `jsEval("document.body.textContent.includes('<追加标记>')")` 变为 true
- `jsEval("window.scrollY")` 与 `scrollYBefore` 偏差 ≤ 50 px
- Bridge 收到 `fileReloadAck`，其 `strategy == "anchor"`
- debug log 含 `markdownViewer.fileReload strategy=anchor`

**备注**：容差 50px 见 TEST-PLAN §5 R-9。

---

### CASE 31 · AC-19 · heading 全改时回落 ratio 策略

**层级**：UITest

**Given**
- 同 Case 30 前置，但外部写入**替换**整个文件为完全不同 heading 的内容

**When / Then**
- Bridge 收到 `fileReloadAck`，其 `strategy == "ratio"`
- 新文档渲染完成（h1 textContent 已变化）
- 滚动位置按 `scrollTopRatio` 比例恢复（`|actualRatio - expectedRatio| < 0.05`）

---

### CASE 32 · AC-20 · 文件删除后 UI 显示删除态 + 恢复后静默重渲染

**层级**：Unit + UITest

**Given**（Unit 段）
- `MarkdownViewerFileSource(filePath: tmpPath)` 已初始化，`content` 非空
- `isFileUnavailable == false`

**When**（Unit）
- `FileManager.default.removeItem(atPath: tmpPath)`

**Then**（Unit）
- `@Published isFileUnavailable` 在 1s 内变 true（Combine sink 断言）

**When**（UITest 段）
- 打开 viewer → 删除文件

**Then**（UITest）
- 2s 内 `jsEval("document.querySelector('.viewer-empty')?.textContent")` 包含运行期求值的 `String(localized:"markdownViewer.file.deleted")` 值
- debug log 含 `markdownViewer.fileMissing phase=deleted`

**When**（UITest 恢复段）
- 重新写回文件内容

**Then**
- `jsEval("document.querySelector('.viewer-empty')")` 为 null，正文重渲染
- debug log 含 `phase=reappeared`
- 首次恢复滚动位置为顶部（`window.scrollY == 0`，对齐 UI §6 状态 #4b）

---

### CASE 33 · AC-20 · atomic save（rename 替换）不误判为删除

**层级**：Unit

**Given**
- `MarkdownViewerFileSource` 监听 `tmpPath`

**When**
- 通过 `FileWatcherDriver.atomicReplace(content: "新内容")`（写临时文件 + rename over）

**Then**
- `isFileUnavailable` 始终保持 `false`（reattach 最多 6 次 × 0.5s 生效）
- `content` 在 3s 内更新为「新内容」

---

### CASE 34 · AC-21 · 大文件截断 banner 与 10MB 上限

**层级**：UITest

**Given**
- `gen.sh` 生成 `edgecase/large-12mb.md`（12 MB，ASCII 填充）

**When**
- 打开该 fixture；`await waitUntilReady()`

**Then**
- `jsEval("document.body.classList.contains('is-truncated')") == true`
- `jsEval("document.querySelector('.truncate-banner')")` 存在且 `textContent` 命中运行期 `String(localized:"markdownViewer.file.truncated")`
- `jsEval("window.__viewerContentByteLength")` 等于 `10 * 1024 * 1024`（Swift 侧注入该全局变量作为测试 seam）
- debug log 含 `markdownViewer.fileTruncated size=12582912`

---

### CASE 35 · AC-22 · ISO Latin-1 编码文件可读

**层级**：Unit

**Given**
- `gen.sh` 生成 `edgecase/iso-latin1.md`：字节 `Caf\xe9` 对应「Café」的 Latin-1

**When**
- `MarkdownViewerFileSource(filePath: latin1Path)` 完成初始加载

**Then**
- `content` 非空且包含 Unicode `"Café"`（`\u{00E9}`）
- `isFileUnavailable == false`

**备注**：验证 PRD AC-22 的 UTF-8 → Latin-1 回退路径。

---

## 性能（CASE 36–38）

### CASE 36 · AC-23 · 首次打开 md 窗口首屏渲染 ≤ 500ms（p50）

**层级**：XCTest-Performance

**Given**
- 每次 iteration 前强制 tear down manager（释放 ProcessPool；本测通过 `Manager.__test_resetForColdStart()` seam）

**When**
- `measure(metrics: [XCTClockMetric()])` 包裹：
  - `Manager.showWindow(for: basicReadmePath)`
  - `await waitForBridgeMessage("viewerReady")`

**Then**
- p50 ≤ 500 ms（在 CI VM 乘 1.5 容忍 = 750 ms）
- signpost `viewer.firstOpen` 的 duration `OSSignpostIntervalBegin/End` 一致

**Fixture**：`basic/README.md`（基础 md，不含 mermaid）

**备注**：符合 PRD §3.4 AC-23 描述；CI flakiness 用 `measureMetrics` 多次采样 p50 对抗。

---

### CASE 37 · AC-24 · 热启动再开 ≤ 200ms（p50）

**层级**：XCTest-Performance

**Given**
- 首先跑一次 `Manager.showWindow` 预热 ProcessPool 并关闭窗口
- 5 分钟内（测试过程实际为秒级）再次打开

**When**
- `measure {}` 包裹新的打开过程

**Then**
- p50 ≤ 200 ms（CI VM ×1.5 = 300 ms）
- signpost `viewer.warmOpen` 存在
- 本次 ProcessPool 未重新分配（通过 seam `Manager.__test_processPoolIdentity` 断言前后同一 object identity）

**备注**：同时覆盖 AC-31 的必要条件；Case 46 做完整覆盖。

---

### CASE 38 · AC-25 · 单 Mermaid 图（< 30 节点）渲染 ≤ 300ms

**层级**：XCTest-Performance

**Given**
- `mermaid/graph.md` 扩展到 ~25 节点（fixture 提供 `mermaid/medium-graph.md`）

**When**
- Web JS 侧在 mermaid render 前后 `performance.now()`，通过 bridge 回报 `mermaidRenderDurationMs`
- Swift 侧 `measure` 包住「打开 → 收到 duration 消息」链路（或仅断言 duration）

**Then**
- 所有采样中，`mermaidRenderDurationMs` p50 ≤ 300 ms（CI VM 容忍 450 ms）

**备注**：不使用 wall-clock 单次；measure 样本 N ≥ 5。

---

## 构建产物（CASE 39–40）

### CASE 39 · AC-26 · vendor 目录总大小 ≤ 5MB（CI）

**层级**：CI-Script（GitHub Actions 步骤 + pretag-guard）

**Given**
- 工作树 clean；`Resources/MarkdownViewer/vendor/` 存在

**When**
- CI 执行 `scripts/verify-markdown-viewer-vendor.sh`（脚本内部 `du -sb` 并比对阈值 `5242880`）

**Then**
- 体积 ≤ 5 × 1024 × 1024 → exit 0；超过 → exit 1 并打印当前体积

**备注**：只看脚本 exit code；不在 XCTest 里读 Info.plist / pbxproj。

---

### CASE 40 · AC-27 · vendor 完整性（sha256 对 `vendor.lock.json`）

**层级**：CI-Script + Unit 对脚本行为的黑盒验证

**Given**
- `cmuxTests/MarkdownViewer/VendorLockScriptTests` 复制 `Resources/MarkdownViewer/` 与 `vendor.lock.json` 到 tmpdir

**When（子用例 A · 干净）**
- 运行 `verify-markdown-viewer-vendor.sh` 指向 tmpdir

**Then（A）**
- `terminationStatus == 0`，stderr 为空

**When（子用例 B · 篡改）**
- 向 tmpdir 内某 vendor js 追加一个字节

**Then（B）**
- `terminationStatus == 1`，stderr 非空，含被篡改文件名（通过 Process.pipe 读取）

**备注**：不断言 lock 文件字段名存在性；只验证脚本对 runtime 差异的响应。

---

## 资源权限与图片（CASE 41–42）

### CASE 41 · AC-28 · 外网 `<img src="https://…">` 不产生网络请求 + DOM 降级为占位

**层级**：UITest

**Given**
- 打开 `edgecase/images-mixed.md`
- 注入一个 `WKContentRuleList` 命中计数器 seam（或使用 `WKNavigationDelegate` DEBUG hook 记录被 cancel 的请求）

**When**
- `await waitUntilReady()`

**Then**
- 拦截计数器 ≥ 1（针对 `https://example.com/*`）
- `jsEval("document.querySelectorAll('img[src^=\"https://\"]').length") == 0`（被替换）
- 存在 placeholder 元素（class 例如 `.external-image-blocked` 或 `.local-image[data-blocked]`，按 RD 落定）的 `textContent` 命中运行期 `String(localized: "markdownViewer.externalImage.blocked")` 模板填入 URL 后的结果
- data: URI 图片仍然以 `<img>` 呈现：`jsEval("document.querySelectorAll('img[src^=\"data:\"]').length") >= 1`

---

### CASE 42 · AC-32 · 本地图片 `<img src="./logo.png">` 降级为可点击链接

**层级**：UITest

**Given**
- 打开 `edgecase/images-mixed.md`（含 `<img src="./logo.png">`）
- 注入 `StubExternalOpener`

**When / Then（DOM 降级）**
- `jsEval("document.querySelectorAll('img[src=\"./logo.png\"]').length") == 0`
- `jsEval("document.querySelectorAll('a.local-image').length") >= 1`
- 降级链接 `textContent` 命中 `String(localized: "markdownViewer.localImage.hint")`
- `title` 属性命中 `String(localized: "markdownViewer.localImage.tooltip")`

**When / Then（点击行为）**
- `jsEval("document.querySelector('a.local-image').click()")`
- `stubOpener.openedURLs.count == 1`，scheme 为 `file`，路径指向 `logo.png` 的绝对 `file://` URL

---

## 窗口管理（CASE 43–45, 47, 48）

### CASE 43 · AC-D1 · Window 菜单列出 viewer（标题为 basename）

**层级**：UITest

**Given**
- 打开 `basic/README.md`

**When / Then**
- `window.isExcludedFromWindowsMenu == false`
- `NSApp.windows.contains(where: { $0 == controller.window })` == true
- Window 菜单（`NSApp.mainMenu?.item(withTitle: "Window")`）存在一个 menu item，其 title 以 `"README.md"` 结尾
- 关闭窗口后，该 menu item 在 1 runloop 内消失

**备注**：Window 菜单由 AppKit 自动维护，只断言非排除 + 存在/消失翻转，不验证菜单 HTML/源码。

---

### CASE 44 · AC-D2 · ⌘W 只关当前 viewer

**层级**：UITest

**Given**
- 主 cmux 窗口 `mainWindow` visible；打开 viewer A 与 viewer B；focused window = viewer A

**When**
- 调用 `viewerA.window.performClose(nil)`（等价 ⌘W；见 TEST-PLAN §5 R-4）

**Then**
- `viewerA.window` 已关闭（Manager.controllers 不再包含其 path）
- `viewerB.window.isVisible == true`
- `mainWindow.isVisible == true`

---

### CASE 45 · AC-D3 · viewer 进 fullscreen 不影响主 cmux 窗口

**层级**：UITest

**Given**
- 主 cmux 窗口可见，记录其 `mainFrameBefore`
- 打开 viewer A，使其成为 key window

**When**
- `viewerA.window.toggleFullScreen(nil)` 进入 fullscreen，等待通知

**Then**
- `viewerA.window.styleMask.contains(.fullScreen) == true`
- `mainWindow.frame == mainFrameBefore`
- `mainWindow.isVisible == true`（未被 hide/minimize）
- 退出 fullscreen 后 `mainWindow.frame` 仍不变

**备注**：Spaces 切换段退化为 main window 不受影响断言（TEST-PLAN §4.3）。

---

### CASE 46 · AC-31 · WebView 进程复用：关闭再开命中热启动档

**层级**：XCTest-Performance + 对象恒等断言

**Given**
- 启动 app；打开 + 关闭一次 viewer 预热

**When**
- `let poolBefore = Manager.__test_processPoolIdentity`
- 再次打开 viewer → 等 `viewerReady`
- `let poolAfter = Manager.__test_processPoolIdentity`
- 打开耗时用 `measure {}` 采样

**Then**
- `poolBefore === poolAfter`（同一 WKProcessPool 对象）
- 打开 p50 ≤ AC-24 阈值（200 ms；CI 容忍 300 ms）

---

### CASE 47 · AC-D4 · 关闭所有 viewer 后 app 不退出

**层级**：UITest

**Given**
- 主 cmux 窗口可见；打开 viewer A 与 viewer B

**When**
- 依次关闭 A、B

**Then**
- `ViewerManager.controllers.count == 0`
- `NSApp.isRunning == true`
- `mainWindow.isVisible == true`
- `NSApp.windows.count >= 1`（至少主窗口还在）

---

### CASE 48 · AC-D5 · ⌘F smoke（不承诺不禁止）

**层级**：UITest

**Given**
- 打开 `basic/README.md`

**When**
- 合成 `NSEvent` keyDown modifierFlags `.command`, characters `"f"`，post 到 viewer window
- 等待 200ms

**Then**
- 不崩溃；viewer window 仍 key
- viewer 不自行渲染任何 find bar（断言 `jsEval("document.querySelectorAll('.cmux-find-bar, .surface-search-overlay').length") == 0`）
- 是否出现 WKWebView 默认 find UI 不做断言（设计明确不承诺）

---

## 附：AC 覆盖矩阵（自检）

| AC | Case IDs |
|----|---------|
| AC-1 | 1, 2 |
| AC-2 | 3, 4 |
| AC-3 | 5 |
| AC-4 | 6, 7 |
| AC-5 | 8 |
| AC-6 | 9 |
| AC-7 | 10, 11, 12, 13 |
| AC-8 | 14 |
| AC-9 | 15 |
| AC-10 | 16 |
| AC-11 | 17, 18, 19, 20, 21, 22 |
| AC-12 | 23 |
| AC-13 | 24 |
| AC-14 | 25 |
| AC-15 | 26 |
| AC-16 | 27 |
| AC-17 | 28 |
| AC-18 | 29 |
| AC-19 | 30, 31 |
| AC-20 | 32, 33 |
| AC-21 | 34 |
| AC-22 | 35 |
| AC-23 | 36 |
| AC-24 | 37 |
| AC-25 | 38 |
| AC-26 | 39 |
| AC-27 | 40 |
| AC-28 | 41 |
| AC-31 | 46 |
| AC-32 | 42 |
| AC-D1 | 43 |
| AC-D2 | 44 |
| AC-D3 | 45 |
| AC-D4 | 47 |
| AC-D5 | 48 |

**未覆盖 AC**：无。

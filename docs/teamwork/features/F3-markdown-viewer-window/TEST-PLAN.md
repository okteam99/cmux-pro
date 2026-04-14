# F3 · Test Plan

> Feature 流程 · Test Plan
> 作者：QA | 日期：2026-04-14 | 状态：草稿待 QA Lead 评审
> 权威依据：`PRD.md`（§3 AC、§10 测试策略）+ `UI.md`（§6 状态、§7 token、§10 AC 交叉索引）
> 强约束：`CLAUDE.md` 「测试质量政策」+「Testing policy」+「Socket command threading policy」

---

## 1. 策略总览

### 1.1 测试哲学

所有 case 验证**运行期可观察行为**：
- SwiftUI / AppKit 状态（`NSWindow.frame`、`isKeyWindow`、`NSApp.windows.count`）
- WKWebView DOM 状态（通过 `evaluateJavaScript` 读取 `document.querySelectorAll(...).length` / `innerHTML` / `classList`）
- JS ↔ Native bridge 消息（`WKScriptMessageHandler` 捕获）
- 文件系统副作用（fixture 写入 → watcher 触发 → DOM 更新）
- XCTest `measure {}` 指标 + `OSSignpost` 区间
- CI 脚本 exit code

**明确不做**：
- 读 `Sources/MarkdownViewer/*.swift` 源码文本做 grep 断言
- 读 `Resources/MarkdownViewer/viewer.html` / `viewer.js` 做字符串断言
- 读 `Resources/Localizable.xcstrings` 断言 key 存在
- 读 `Info.plist` / `project.pbxproj` / `.xcconfig`
- 读 `vendor.lock.json` 字段存在性；只断言脚本 exit code

### 1.2 执行模型（CLAUDE.md Testing policy）

| 层级 | 执行位置 | 触发 |
|------|---------|------|
| Unit (`cmuxTests/MarkdownViewer/`) | CI 或本地 `xcodebuild -scheme cmux-unit` | 每次 PR |
| UITest (`cmuxUITests/MarkdownViewer/`) | 仅 CI（`gh workflow run test-e2e.yml`） | PR / merge |
| XCTest Performance | 仅 CI | PR / nightly |
| CI 脚本 (`verify-markdown-viewer-vendor.sh`) | GitHub Actions + `release-pretag-guard.sh` | PR / tag |

QA 本地**绝不运行** UI / E2E / python socket 测试；仅通过 `gh run watch` 观察 CI 结果。

---

## 2. 测试层级分配（AC × Layer）

| AC | Unit | UITest | XCTest-Perf | CI-Script | Case IDs |
|----|:----:|:------:|:-----------:|:---------:|---------|
| AC-1  | ✓ | ✓ |   |   | 1, 2 |
| AC-2  | ✓ | ✓ |   |   | 3, 4 |
| AC-3  | ✓ |   |   |   | 5 |
| AC-4  |   | ✓ |   |   | 6, 7 |
| AC-5  |   | ✓ |   |   | 8 |
| AC-6  | ✓ |   |   |   | 9 |
| AC-7  |   | ✓ |   |   | 10, 11, 12, 13 |
| AC-8  |   | ✓ |   |   | 14 |
| AC-9  |   | ✓ |   |   | 15 |
| AC-10 |   | ✓ |   |   | 16 |
| AC-11 |   | ✓ |   |   | 17, 18, 19, 20, 21, 22 |
| AC-12 |   | ✓ |   |   | 23 |
| AC-13 |   | ✓ |   |   | 24 |
| AC-14 |   | ✓ |   |   | 25 |
| AC-15 |   | ✓ |   |   | 26 |
| AC-16 |   | ✓ |   |   | 27 |
| AC-17 |   | ✓ |   |   | 28 |
| AC-18 |   | ✓ |   |   | 29 |
| AC-19 |   | ✓ |   |   | 30, 31 |
| AC-20 | ✓ | ✓ |   |   | 32, 33 |
| AC-21 |   | ✓ |   |   | 34 |
| AC-22 | ✓ |   |   |   | 35 |
| AC-23 |   |   | ✓ |   | 36 |
| AC-24 |   |   | ✓ |   | 37 |
| AC-25 |   |   | ✓ |   | 38 |
| AC-26 |   |   |   | ✓ | 39 |
| AC-27 |   |   |   | ✓ | 40 |
| AC-28 |   | ✓ |   |   | 41 |
| AC-31 |   |   | ✓ |   | 46 |
| AC-32 |   | ✓ |   |   | 42 |
| AC-D1 |   | ✓ |   |   | 43 |
| AC-D2 |   | ✓ |   |   | 44 |
| AC-D3 |   | ✓ |   |   | 45 |
| AC-D4 |   | ✓ |   |   | 47 |
| AC-D5 |   | ✓ |   |   | 48 |

合计：48 cases 覆盖 34 AC。

---

## 3. 测试基础设施需求

### 3.1 WKWebView JS 断言 helper

新建 `cmuxUITests/MarkdownViewer/Support/ViewerJSEval.swift`：

```
@MainActor
func jsEval(_ controller: MarkdownViewerWindowController,
            _ script: String,
            timeout: TimeInterval = 2.0) async throws -> Any?
```

- 内部包 `WKWebView.evaluateJavaScript` 为 async/await
- 自带 `waitUntilReady()`：轮询 `document.readyState === "complete"` 且 `window.__viewerReady === true`（viewer.js 在全部脚本注入完成后 set）
- 超时抛 `ViewerJSEvalError.timeout`

Manager 侧暴露测试 seam：
```
#if DEBUG
extension MarkdownViewerWindowManager {
    func __test_controller(for path: String) -> MarkdownViewerWindowController? { ... }
}
#endif
```

### 3.2 Bridge 消息捕获

新建 `cmuxUITests/MarkdownViewer/Support/BridgeRecorder.swift`：
- `MarkdownViewerWebBridge` DEBUG-only 协议注入点，允许测试注册 `onMessage: (name, payload) -> Void`
- 断言 bridge 消息时通过 `BridgeRecorder().waitForMessage(name:timeout:)` 返回 payload

### 3.3 NSWorkspace stub

`cmuxTests/MarkdownViewer/Support/WorkspaceOpener.swift`：
- 引入协议 `ExternalOpening { func open(_ url: URL) -> Bool }`
- 默认实现 = `NSWorkspace.shared.open(_:)` 的包装
- 测试注入 `StubExternalOpener`（记录 `openedURLs: [URL]`）
- Controller 初始化接受 `ExternalOpening` 依赖（DEBUG 测试 seam）

### 3.4 Fixtures 目录

`cmuxUITests/Fixtures/MarkdownViewer/`：

| 子目录 / 文件 | 用途 | 覆盖 AC |
|---|---|---|
| `basic/README.md` | 标题 / 列表 / 表格 / blockquote / hr | AC-7 |
| `basic/code-langs.md` | swift / python / js / go / rust 代码块 | AC-8 |
| `basic/html-inline.md` | `<br>` / `<details>` / `<kbd>` | AC-13 |
| `basic/anchors.md` | 多级 heading + `[link](#anchor)` | AC-16 |
| `basic/external-link.md` | `[ext](https://example.com)` | AC-17 |
| `basic/relative-link.md` | `[rel](./other.md)` | AC-18 |
| `mermaid/graph.md` | `graph TD A-->B` | AC-9, AC-11 |
| `mermaid/flowchart.md` | `flowchart LR` | AC-11 |
| `mermaid/sequence.md` | `sequenceDiagram` | AC-11 |
| `mermaid/class.md` | `classDiagram` | AC-11 |
| `mermaid/gantt.md` | `gantt` | AC-11 |
| `mermaid/pie.md` | `pie` | AC-11 |
| `mermaid/state.md` | `stateDiagram-v2` | AC-11 |
| `mermaid/mindmap.md` | `mindmap` | AC-11 |
| `mermaid/journey.md` | `journey` | AC-11 |
| `mermaid/naked-graph.md` | 裸 `graph TD` 无 mermaid 标签？ → 按 PRD AC-10 规范放在 ` ```mermaid` 下 | AC-10 |
| `mermaid/broken.md` | 故意语法错 `grph TD\nA -> B` | AC-12 |
| `edgecase/empty.md` | 0 字节 | UI §6 状态 #2 |
| `edgecase/large-12mb.md` | 生成脚本产出 12 MB md | AC-21 |
| `edgecase/iso-latin1.md` | 含 `\xe9` 非 UTF-8 字节；生成 fixture | AC-22 |
| `edgecase/images-mixed.md` | `<img src="https://...">` + `<img src="./logo.png">` + `<img src="data:image/png;base64,...">` | AC-28, AC-32 |

**大文件 / 编码异常 fixture 生成**：`cmuxUITests/Fixtures/MarkdownViewer/gen.sh`（CI 测试启动前执行，避免 12 MB binary 入仓）。

### 3.5 性能测量基础设施

- 新增 `cmuxUITests/MarkdownViewer/Performance/MarkdownViewerPerfTests.swift`
- 使用 `XCTMeasureOptions()`; `metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]`
- Signpost：`OSLog(subsystem: "com.manaflow.cmux", category: .pointsOfInterest)`
  - `viewer.firstOpen` 区间（Manager 注册起 → bridge `viewerReady` 消息）
  - `viewer.warmOpen` 区间（同上，但 ProcessPool 已存在）
  - `viewer.mermaidRender` 区间（JS 侧 `performance.mark` → bridge 回报 ms）
- 断言策略：`measure` 多次取样，p50 ≤ 目标；避免 wall-clock 单次 flaky

### 3.6 Vendor lock 校验

- Case 39 / 40 断言 `scripts/verify-markdown-viewer-vendor.sh` 在受控篡改下 exit code 正确（0 / 1）
- `cmuxTests/MarkdownViewer/VendorLockScriptTests.swift`：XCTest 以 `Process` 启动脚本，比对 `terminationStatus`
  - 前置：copy `Resources/MarkdownViewer/` 到 tmp；copy `vendor.lock.json` 到 tmp；正向运行返回 0；篡改某 vendor 文件字节后返回 1
- 不 grep `vendor.lock.json` 内容，仅判断 exit code 与 stderr 非空

### 3.7 文件 watcher 测试 helper

`cmuxTests/MarkdownViewer/Support/FileWatcherDriver.swift`：
- 创建 tmpdir，写入初始 md
- 暴露 `rewrite(content:)` / `delete()` / `atomicReplace(content:)`（mimic Vim / VSCode save）
- 单测层面直接注入 `MarkdownViewerFileSource(filePath:)` 验证 `@Published` 流

---

## 4. 不可测 / 部分可测 AC 说明

### 4.1 AC-D5（⌘F 查找）—— 部分可测

PRD/UI 明确声明「不承诺不禁止」，QA 只能验证**未禁用**（WKWebView 默认路径未被代码阻断）。做法：注入 `NSEvent.keyDown(⌘F)`，断言不会抛异常 / 不会劫持菜单；**不断言** find bar 是否出现（系统实现，非 cmux 职责）。Case 48 仅做 smoke assert。

### 4.2 AC-5（最小化 / 全屏）—— UI 半自动化

macOS `toggleFullScreen` 动画异步 + Spaces 切换在 CI VM 内不稳定。Case 8 限制在「按钮可响应」级：断言 `window.styleMask.contains(.fullScreen)` 翻转；不尝试验证动画帧。

### 4.3 AC-D3（Spaces 切换）—— 不可直接 E2E

Spaces API 私有，无法在 XCTest 内切换。Case 45 分成两段：
- 段 A：`toggleFullScreen` 成功切换 styleMask（可验证）
- 段 B：「Spaces 切换后 showWindow 仍聚焦已有窗口」→ 退化为**主 cmux window 焦点不受 viewer fullscreen 影响**的代理断言（`NSApp.mainWindow` 在 viewer 进 fullscreen 后仍为 cmux 主窗 OR cmux 主窗 frame 不变）

### 4.4 AC-D4（Quit 行为）—— 间接验证

无法在同一进程内 assert app 退出与否。Case 47 退化为：关闭最后一个 viewer → `NSApp.isRunning == true` 且主窗口 `isVisible == true`；真正的 terminate 语义由 cmux 现有 app lifecycle 保障（非本 Feature 新引入，引用既有 AppDelegate 行为）。

### 4.5 AC-23 / AC-24 / AC-25 性能阈值

XCTest `measure` 给出分布而非单次；实际 gate 取 **p50 ≤ 目标** 而非 max。CI VM 相对 M 系 Mac 慢 ~1.5×，测试中使用 `XCTPerformanceMetric_WallClockTime` baseline 上浮 50% 容忍（文档化于 Case 36–38 备注）。

### 4.6 AC-31（ProcessPool 复用）—— 黑盒观察

无法直接 assert `WKProcessPool` 生命周期（无公共 API）。Case 46 通过**热启动耗时 ≤ AC-24 阈值**作为 ProcessPool 被复用的**必要条件**；若测试通过，等价于 AC-31 满足。

### 4.7 AC-26（vendor 体积 ≤ 5MB）

通过 CI 脚本 `du -b Resources/MarkdownViewer/vendor` ≤ 5_242_880 断言。不读 Info.plist / pbxproj。

---

## 5. 风险项

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| R-1 | WKWebView 异步加载竞态：viewer.html 加载 → mermaid CDN-free 初始化 → 文档注水三步串行 | UITest 轮询超时 flaky | 统一使用 `window.__viewerReady` 信号 + `jsEval` helper 2s timeout + 重试 1 次 |
| R-2 | 12 MB fixture 导致 CI 磁盘 / runtime 压力 | CI 变慢 / OOM | fixture 在 setup 时由 `gen.sh` 按需生成并在 teardown 清理；不入仓 |
| R-3 | Mermaid 子类型在不同版本渲染 SVG 结构不同 | 断言 `querySelector('svg')` 可能 false positive | 仅断言 `svg` 存在 + `innerHTML.length > 100` + `class` 含 `mermaid`；不断言内部节点结构 |
| R-4 | UITest 的 ⌘W keyDown 注入可能被 XCTest Runner 拦截 | Case 44 flaky | 直接调用 `window.performClose(nil)`（AppKit 标准入口，等价语义） |
| R-5 | 全局窗口 frame 记忆依赖 UserDefaults 持久化 | test 间污染 | 每个 UITest 启动使用独立 `UserDefaults.suiteName`；teardown 清理 |
| R-6 | 性能 case 在 CI 首次运行 baseline 为空 | 看似 pass 但实际无 gate | baseline 首次写入后要求 QA Lead review；阈值写在测试常量里做硬断言兜底 |
| R-7 | `verify-markdown-viewer-vendor.sh` 依赖 `shasum` 命令 | CI 缺 coreutils 时崩 | 脚本首行 `command -v shasum` 前置检查 + 失败消息 |
| R-8 | AC-22 ISO Latin-1 fixture 在 git 跨平台 checkout 可能被 normalize | 编码测试 false | fixture 存成 base64 + gen.sh 解码写入 tmpdir |
| R-9 | AC-19 rerender 后 scroll anchor 恢复在动态高度 Mermaid 下可能漂移 | flaky | 断言 scroll 位置容差 ±50px；记录 strategy 命中（anchor vs ratio）以便复查 |

---

## 6. 质量自检清单

- [x] 所有 AC（含 AC-1..AC-32 + AC-D1..AC-D5 + AC-31）都有至少 1 个 case
- [x] 无「grep / 读源码文本」断言
- [x] 无读 `Info.plist` / `project.pbxproj` / `.xcconfig` / `Localizable.xcstrings` 字段存在性的断言
- [x] xcstrings 验证通过「运行期 DOM 文本命中值」而非 key 存在性（e.g. Case 23 读 DOM `.mermaid-wrap.is-error .msg` 的 `textContent`）
- [x] 性能 AC 使用 `measure {}` + `XCTClockMetric`，不用 wall-clock 单次
- [x] Fixtures 路径明确（§3.4 全部列出）
- [x] Mermaid 子类型 fixtures 覆盖 PRD AC-11 的 graph / flowchart / sequenceDiagram / classDiagram / gantt + 加上 pie / state / mindmap / journey（Case 15, 17–22）
- [x] 测试代码不 `open` 未 tagged `cmux DEV.app`；UITest 使用 `XCUIApplication.launchArguments` 注入 tagged 参数
- [x] 所有 bridge 线程策略符合 CLAUDE.md「Socket command threading policy」——telemetry off-main，UI 动作 main
- [x] 不在单测中尝试 end-to-end 启动 app；端到端路径全部走 UITest 层

---

## 7. 交付节奏

1. **TC 阶段（RD）**：落实 §3.1–§3.6 所述 `__test_controller`、`ExternalOpening` 协议、bridge DEBUG 钩子、`gen.sh`、`verify-markdown-viewer-vendor.sh`
2. **Case 编写**：Unit 先行（Case 1, 3, 5, 9, 32, 35），UITest 并行，Performance 最后
3. **Gating**：PR 必过 Unit + CI 脚本；UITest / Performance 进 nightly 但对 main 合并要求 green

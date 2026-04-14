# F3 · PRD 技术评审

> Reviewer：RD + 架构师（合议） | 日期：2026-04-14 | 针对 PRD 草稿 + UI.md + R1 讨论

## 总体结论

**CONDITIONAL-PASS** — PRD 结构完整、AC 细度合格，三项用户裁定（独立窗口 / 全量 mermaid / tab 版冻结）已解除最大路径分歧，技术路线可落地。但存在若干**必须在进入 Dev 之前解决**的实现层盲点（MarkdownFileSource 抽离边界、WKWebView 加载 file:// 的读权限根目录、资源体积 4MB 而非 PRD 陈述的 1.5-2MB 精简、测试策略违反 CLAUDE.md 的风险、Debug 菜单 / 快捷键未覆盖），不宜直接并行 Designer / QA / Dev。建议 PM 按下方「行动清单」修订 PRD 后再 kick off。

---

## RD 视角

### R-1 PRD 与 PM-REPLY 在 bundle 方案上口径不一致
- **严重度**：🔴 Blocker
- **描述**：用户裁定（PRD §1 头部、§8、§9 D-2）写的是**全量本地打包 ~4MB**；但 PM-REPLY-R1 §PL-3-2 与「收敛状态」里写「PM 默认选精简打包 1.5-2MB」。PRD 最终态取用户裁定（全量），但 §8 风险表的表头仍保留四个方案的对比，且「精简打包」一行未标注「未选」的说明措辞与 PRD §1.2、§9 的「已选全量」互相矛盾的观感较弱但依然存在。Dev / QA 会对照 PRD 验收「bundle 大小是否 ≤ 2MB」，产生错误预期。
- **建议**：PRD §8 表格顶部加一句裁定引用：「用户 2026-04-14 裁定：**全量本地打包**」；精简打包一行「本期选择」列显式写「否（备选 fallback，若 4MB 引起 App Store 审核或冷启动回归时再切）」。同时把 §1.3 非目标或 §8 新增「bundle 体积验收：构建产物中 viewer 资源目录 ≤ 5MB（full mermaid + marked + highlight）」作为显式 AC。
- **需 PM 更新 PRD 章节**：§8（风险表）+ 新增 AC（见下方补充 AC-26）

### R-2 `loadFileURL(_:allowingReadAccessTo:)` 的读权限根目录未定
- **严重度**：🟡 Major
- **描述**：PRD §5 只提到"WKWebView 加载本地 HTML + file:// JS"，§8 风险里只点到 ATS 一句话，但未说明 `allowingReadAccessTo` 的范围。两个候选：
  1. 只授权 `Resources/MarkdownViewer/`（最小权限，安全）。此时 md 内容不能用 `<img src="./logo.png">` 等相对路径引用用户仓库内的图片资源，体验不完整。
  2. 授权 md 文件所在的目录（读取到仓库内图片）。此时需要一条白名单策略，且当用户打开系统级目录（`~/Documents/foo.md`）时授予 WKWebView 对整个 `~/Documents` 的读权限——需要评估泄露面。
  PRD 未决策，直接开 Dev 会出现「Mermaid ok 但 md 里的本地图片不显示」或「权限过度」两种分岔。
- **建议**：PRD §5 或 §8 补一段「资源加载策略」：本期采用**方案 1（只授权 viewer 资源目录 + 把 md 原文作为字符串注入）**，md 内的本地图片用 `file://` 绝对路径时通过 bridge 申请单文件读权限（或直接渲染为链接 fallback）。如选方案 2，需明确白名单边界并在风险表列出。
- **需 PM 更新 PRD 章节**：§5 或 §8（新增「WKWebView 读权限策略」小节）

### R-3 `MarkdownFileSource` 抽离对 tab 版"冻结"的影响未说明
- **严重度**：🟡 Major
- **描述**：PRD §4 与 §5 都说要从 `MarkdownPanel.swift` 抽 `MarkdownFileSource`（文件路径 + 内容 + 更新订阅 + watcher 重连策略）。但用户裁定 tab 版本期**冻结**——冻结的含义是「不再暴露新入口」，不等于「代码零改动」。抽 `MarkdownFileSource` 等于对 tab 版做重构，改动 `MarkdownPanel.swift` 的 watcher / encoding fallback 路径（MarkdownPanel.swift:86-169 整块）。这有两个后果：
  1. tab 版的行为被间接改动（watcher 回调线程路径、reattach 逻辑共用），冻结含义被破坏。
  2. 抽离没有配套的 tab 版回归测试，CI 保护缺失。
- **建议**：明确二选一：
  - **A（推荐）**：本期**不抽 `MarkdownFileSource`**，新窗口自己实现一个最小 watcher（参考 MarkdownPanel 但代码独立），避免触碰 tab 版；待下一迭代 tab 版下线时顺手删老代码。
  - **B**：允许抽，但 PRD 明示「tab 版需伴随重构，必须保留原 behavior」，并要求 Dev 提供 `MarkdownPanelTests` 覆盖 watcher / atomic-save / encoding fallback / reattach 这 4 条路径后再合并。
- **需 PM 更新 PRD 章节**：§4、§5（接口变更）

### R-4 AC-19「保留滚动位置」可落地性存疑
- **严重度**：🟡 Major
- **描述**：PRD AC-19 写「优先按文档行/标题锚点恢复；若结构大改锚点消失，fallback 到 scroll-top 百分比」。实现层面这要求：
  1. 渲染前后在 JS 里维护 heading → DOM offset 映射，并挑选当前视口内最近的 heading 作为锚点；
  2. 文件刷新是「整页 rerender」还是「diff patch」？PRD 未说。如果是整页 rerender（最简单），页面重建期间滚动条会抖到顶，需要在 JS 里先保存 sentinel、rerender 完再恢复；
  3. 若文档无 heading（全是段落），fallback 成「scroll-top 百分比」在短文档中抖动不明显，但长文档里段落密度不均会跳到错位置。
- **建议**：PRD 把 AC-19 落到 JS 侧具体契约：「整页 rerender 前，JS 记录最接近视口顶部的 heading id + 视口顶在该 heading 内的偏移百分比；rerender 后优先 scrollIntoView 到同 id，再叠加偏移；id 不存在则 fallback 到整页百分比」。否则 QA 无法从黑盒角度写出确定性断言，RD 可能自选任意策略通过。
- **需 PM 更新 PRD 章节**：§3.3 AC-19

### R-5 测试策略与 CLAUDE.md「测试质量政策」冲突风险
- **严重度**：🟡 Major
- **描述**：CLAUDE.md 明确禁止「只读源码文本 / 只断言 key 或 plist 是否存在」的测试。PRD §3 多条 AC 的默认落地容易跌进这个坑：
  - AC-9/10/11 Mermaid 渲染：Mermaid 在 WKWebView 里跑，Swift 测试很难直接拿到 SVG DOM 断言「是否渲染为 SVG」。若写成「读 viewer.html 源码里有 `mermaid.initialize`」就违规。
  - AC-12 本地化 key：不能写成「grep xcstrings 看 `markdownViewer.mermaid.error` 存在」。
  - AC-4 窗口记忆：需要观察 UserDefaults 值变化 + 窗口真实 frame。
- **建议**：PRD §6 或新增 §10「测试策略」明确以下可落地的测试断面，并告知 QA：
  - Mermaid：在 WKWebView 里 `evaluateJavaScript("document.querySelectorAll('svg').length")` 断言节点数（runtime DOM 观察，非源码）。
  - AC-12 本地化：让 bridge 返回的错误 payload 文本能被 Swift 读到（E2E 注入错误 mermaid），断言文本内容。
  - AC-4 窗口记忆：UITest / 单元测试启动两次 controller，关窗 → 重开 → 断言 `window.frame` 继承。
  - AC-23/24/25 性能：用 `signpost` + XCTest measure 而不是 wall-clock 断言。
- **需 PM 更新 PRD 章节**：§6（交付物） + §3.4（给每个性能 AC 注明测量方法）

### R-6 WKScriptMessageHandler 线程与 Socket 命令线程政策
- **严重度**：🟢 Minor
- **描述**：CLAUDE.md「Socket command threading policy」虽针对 socket 命令，但其精神（默认 off-main、显式理由才 main）对 JS ↔ native bridge 同样适用。PRD §5 的 `window.cmux.onLinkClick(url) → NSWorkspace.shared.open` 涉及 AppKit，必然要 main；`mermaidRenderError` / `viewportState` 等遥测类可以 off-main 解析。PRD 未提及。
- **建议**：PRD §5 或新增一小节说明：「bridge 命令中唯 `openExternal` / `exportMermaidSVG` 必须 main actor，其余计数/错误上报默认 off-main」。并要求 dlog 调用按 CLAUDE.md 包 `#if DEBUG`。
- **需 PM 更新 PRD 章节**：§5

### R-7 AC-22「编码 fallback」行为未具体化
- **严重度**：🟢 Minor
- **描述**：MarkdownPanel.swift:86-102 的 fallback 策略是 UTF-8 → ISO Latin-1（失败则 isFileUnavailable）。PRD AC-22 写「沿用 MarkdownPanel 的 fallback 策略」，但如果 R-3 选 A（不抽 MarkdownFileSource），则"沿用"需要重新实现一遍。需要明确是否接受重复代码。
- **建议**：R-3 选 A 时，AC-22 直接嵌入具体算法描述，避免 Dev 误读为「import MarkdownPanel 的私有方法」。
- **需 PM 更新 PRD 章节**：§3.3 AC-22

### R-8 AC-23/24/25 性能 AC 可达性与测量边界模糊
- **严重度**：🟢 Minor
- **描述**：
  - AC-23「≤500ms 冷启动，不含首次 process warm-up」：WKWebView 进程首次启动通常 200-400ms（本地实测），叠加 marked + mermaid 解析（mermaid 全量 ~4MB parse 30-80ms）、首次渲染 ~50ms，500ms 勉强达标但没有余量。"不含首次 process warm-up" 的边界在哪里——应用启动即预热还是首次打开 viewer 启动？如选后者，"首次" 已经含 warm-up。
  - AC-24「≤200ms 热启动」：同一 `WKProcessPool` 复用可达；单窗口关闭后 WebView 释放则进程可能被回收。PRD 未定义 WebView 复用策略。
  - AC-25「≤300ms Mermaid 单图」：mermaid 全量首次 render 含 JS 解析，实测常见 200-500ms，边缘。
- **建议**：PRD §3.4 每条加注「测量方法」和「WebView 复用策略」。推荐：应用启动时异步预热 off-screen WKWebView 进程（main-thread 冷启动无感），关闭最后一个 viewer 时保留进程池。把「WKProcessPool 全局复用」写入 §4 或 §5。
- **需 PM 更新 PRD 章节**：§3.4、§4 / §5

### R-9 肯定项（Did right）
- §1.4 竞争定位章节与 §9 三项裁定对齐，把"为什么做"说清楚了。
- AC 覆盖了基础 md / Mermaid 渲染 / 动态更新 / 错误态 / 性能 / 窗口记忆，是较完整的矩阵。
- §8 明确「不走 CDN、锁版本 + SRI」并指定 owner，符合 CLAUDE.md 供应链风险的默认姿态。
- `MarkdownFileSource` 抽象方向正确（虽然落地节奏要再斟酌 → R-3）。
- 埋点字段名已给定 + 用 `dlog` 风格，与项目现有约定一致（前提是实际实现走 `Sources/.../DebugEventLog.swift`）。

---

## 架构师视角

### A-1 目录层级 `Sources/Panels/MarkdownViewer/` 过度分层
- **严重度**：🟢 Minor
- **描述**：PRD §4 把 Window Controller 放 `Sources/Panels/`，bridge 和资源放 `Sources/Panels/MarkdownViewer/`。但 Window Controller 本身不是 Panel（它不实现 `Panel` 协议，不属于 tab / workspace 体系）。放到 `Sources/Panels/` 会污染语义。`MarkdownViewer/` 子目录又只放一个 bridge，层级性价比低。
- **建议**：新建 `Sources/MarkdownViewer/`（与 `Sources/Panels/` 同级），内部扁平存放：
  ```
  Sources/MarkdownViewer/
    MarkdownViewerWindowController.swift
    MarkdownViewerWebBridge.swift
    MarkdownFileSource.swift   # 若选 R-3 B 方案则抽到此处
  Resources/MarkdownViewer/
    viewer.html / viewer.js / viewer.css / vendor/*.js
  ```
- **需 PM 更新 PRD 章节**：§4

### A-2 NSWindowController 单例 + 多窗口管理语义不清
- **严重度**：🟡 Major
- **描述**：PRD §5 写 `static let shared: MarkdownViewerWindowController`（单例 · 管理所有窗口）。但 `NSWindowController` 的契约是「1:1 持有一个 window」。若一个 controller 管多个窗口，类型要么是自定义 manager（不继承 NSWindowController），要么每个窗口一个 controller 实例 + 外层 Manager 单例。PRD 把两者混一了。
- **建议**：改成：
  - `MarkdownViewerWindowManager.shared`（纯 manager，非 NSWindowController，持 `[String: MarkdownViewerWindowController]`）；
  - `MarkdownViewerWindowController` 每个窗口一个实例，继承 `NSWindowController`，`windowWillClose` 里回调 manager 释放自己；
  - `showWindow(for:)` 走 Manager → 命中 existing 则 `makeKeyAndOrderFront`，未命中则 new。
  同时明确：窗口关闭 → `MarkdownFileSource.close()`（cancel watcher，参考 MarkdownPanel.close）→ WKWebView teardown → Manager dictionary 删除 entry。
- **需 PM 更新 PRD 章节**：§5

### A-3 mermaid / marked / highlight 版本锁与 SRI 机制未定
- **严重度**：🟡 Major
- **描述**：PRD §8 写「依赖锁版本 + SRI hash」，但：
  - Mermaid 版本 PRD 只说「10.x LTS」，没锁到 patch（例如 10.9.3）；
  - SRI 在 bundle 内不是 HTML `<script integrity>` 的意义（本地 file:// 天然无 CDN 篡改），SRI 在这里的真实价值是「CI 校验 `Resources/MarkdownViewer/vendor/mermaid.min.js` 未被误改」；
  - Mermaid 本身依赖 d3 / dagre 子图，全量包是 UMD 打包产物还是 ESM 散装？PRD 未指定。全量 UMD 体积更大（PRD 写 ~4MB 与官方全量 UMD 约 3.1MB gz 后 + marked + highlight 合理对齐）。
  - CI 对 vendor 目录的 hash 校验脚本缺失。
- **建议**：
  - PRD §8 锁定具体版本号（例如 `mermaid@10.9.3 UMD bundle`, `marked@14.x`, `highlight.js@11.x`）；
  - 引入脚本 `scripts/verify-markdown-viewer-vendor.sh`：对 `Resources/MarkdownViewer/vendor/*.js` 计算 sha256 → 对照 checked-in 清单；
  - Release pretag guard（`scripts/release-pretag-guard.sh`）里调用该脚本；
  - 新增 AC-27（见下方补充）。
- **需 PM 更新 PRD 章节**：§8

### A-4 pbxproj / Copy Bundle Resources phase 改动面未评估
- **严重度**：🟡 Major
- **描述**：新资源目录 `Resources/MarkdownViewer/` 需加入 Xcode target 的 Copy Bundle Resources phase。若按文件逐一 add，4-5 个 JS 大文件 + html/css 会造成 pbxproj diff 膨胀；按目录 folder reference（蓝色文件夹）添加更干净但会失去 Xcode 内文件索引。PRD 未决策。另外：`xcstrings` 新 key 也需 Designer/RD 同步录入（符号名空间约定）。
- **建议**：PRD §4 明确采用 **folder reference** 方式加入 `Resources/MarkdownViewer/` 整目录；`vendor/` 子目录作为 folder reference，源代码内通过 `Bundle.main.url(forResource:"viewer", withExtension:"html", subdirectory:"MarkdownViewer")` 访问。xcstrings 新增 key 列表集中写入 §4，由 Designer / RD 按此清单一次性录入三语文案。
- **需 PM 更新 PRD 章节**：§4

### A-5 非 sandbox 下 `file://` 加载没有 ATS 阻断，但需禁止 Web 内容远程请求
- **严重度**：🟢 Minor
- **描述**：cmux.entitlements 无 `com.apple.security.app-sandbox`（已确认），WKWebView 加载本地 file:// 无权限阻断。但 md 中可能 `<img src="https://...">`，WKWebView 默认会 fetch。这带来两类风险：
  1. 用户阅读文档时产生不可预期的外网请求（PRD §8 强调「离线保证」与此冲突）；
  2. 恶意 md 可嵌入 tracking pixel。
- **建议**：PRD §8 或 §5 明确「在 WKWebView `WKContentRuleListStore` 注册一条规则：阻断所有非 file:// / data: 的网络请求（图片、iframe、fetch）」，或在 `WKNavigationDelegate.decidePolicyFor` 里 cancel 非 file URL 的子资源加载。AC-17 的外链走 bridge 不受影响。
- **需 PM 更新 PRD 章节**：§5 或 §8

### A-6 与 Ghostty / AppKit 互操作 — 菜单、快捷键、生命周期
- **严重度**：🟡 Major
- **描述**：PRD 完全未涉及：
  - **菜单**：新窗口是否出现在 macOS 标准 `Window` 菜单？AppDelegate / KeyboardShortcutSettings 有无需要注册的快捷键（CLAUDE.md「Shortcut policy」要求每个新快捷键进 KeyboardShortcutSettings + 配置文件 + 文档）？⌘W 在新窗口里由谁实现？
  - **Debug 菜单**：CLAUDE.md 提到 Debug menu 支持「可视迭代」。viewer 排版 token（UI.md §3、§7）天然是 Debug 窗口可调的对象，但 PRD 未考虑。
  - **Fullscreen / Spaces**：独立窗口进入 fullscreen 会占一个 Space。若主 cmux 窗口已 fullscreen，viewer fullscreen 的切换会在 Spaces 间跳转，可能打断用户终端交互。
  - **Quit 行为**：所有 viewer 关闭是否等同于 quit app（若 cmux 主窗口也已关）？依赖 `NSApp.terminateAfterLastWindowClosed` 的默认与 cmux 既有行为需确认。
- **建议**：PRD §3 或新增 §3.5 补充 AC：
  - 新窗口出现在 Window 菜单；
  - ⌘W 关闭仅当前 viewer，不影响主 cmux 窗口；
  - ⌘F 触发 Find（WKWebView 内建 find 或 SurfaceSearchOverlay 规范）—— 如不做也要在非目标里写明；
  - fullscreen / Spaces 行为：延用 macOS 默认，不做特殊 routing；
  - quit 不受 viewer 数量影响（由主应用持有 app lifecycle）。
  KeyboardShortcutSettings 若新增快捷键，列清单。
- **需 PM 更新 PRD 章节**：§3 新增 §3.5

### A-7 Command Palette / 全局入口缺失
- **严重度**：🟢 Minor
- **描述**：PRD 入口唯一写 File Explorer。但 cmux 有 command palette（若存在）/ recent files 类入口，独立窗口 viewer 是否可以被搜索到？用户按过一次 viewer 后想再打开最近的 md 是否有快捷方式？PRD 没明确是否纳入本期。
- **建议**：PRD §1.3 非目标显式补「本期不接入 command palette / recent files；仅 File Explorer 入口」；或 §3 增 AC「recent markdown viewer files」列表。取舍留给 PM。
- **需 PM 更新 PRD 章节**：§1.3 或 §3

### A-8 可观测性（dlog）与既有系统对齐
- **严重度**：🟢 Minor
- **描述**：PRD §7 字段名用 `markdownViewer.*`。CLAUDE.md 规定 dlog 在 DEBUG 才启用、必须 `#if DEBUG` 包裹每处调用。PRD 未明确 viewer bridge 发来的 JS 侧事件如何映射到 dlog（bridge 里接到消息时 dlog 一条）。AC-17 / AC-20 这类事件 RD 容易遗漏埋点。
- **建议**：PRD §7 与 AC 条目做 cross-reference：AC-1 → `markdownViewer.open`；AC-17 → `markdownViewer.webNav action=open-external`；AC-19 → `markdownViewer.fileReload`（新）；AC-20 → `markdownViewer.fileMissing`（新）；AC-12 → `markdownViewer.mermaid renderErrors=`。
- **需 PM 更新 PRD 章节**：§7

### A-9 UI.md 与 PRD 的不一致点
- **严重度**：🟢 Minor
- **描述**：UI.md §5 交互表没包含「⌘F 查找」「⌘+ / ⌘- 字号调节」；§6 错误态只覆盖「文件不存在 / 空」两条，PRD AC-20「文件被删除 → 重现恢复」的"重现后"态 UI 与 AC-21「> 10MB 截断提示」在 UI.md 无对应。
- **建议**：UI.md 补：
  - 错误/空态表新增「文件被删除后等待重现」「大文件截断顶部条」两行；
  - §5 交互表增加「⌘F 文档内查找」（用 WKWebView 内置 find UI 或 cmux 统一的 SurfaceSearchOverlay 视为非目标则显式写明）；
  - 建议字号缩放本期非目标，UI.md 不写即可但 PRD §1.3 补一句。
- **需 PM 更新 PRD 章节**：UI.md §5/§6；PRD §1.3

### A-10 肯定项（Did right）
- 目录结构分层（虽然 A-1 提议调整）显示出模块化意识。
- §5 接口变更粒度合适，MarkdownFileSource 的 `@Published content` + `isFileUnavailable` 直接复用 tab 版状态模型，SwiftUI / AppKit 互通无障碍。
- 预留 `cmux.exportMermaidSVG` 占位接口做 P1，符合「差异化机会但非本期」的正确取舍。
- §8「多窗口 ≤ 10 可接受 / 超过观察」给出工程化的软上限，避免过早优化。
- AC-4「全局共用一份窗口记忆」是合理的简化（每文件记忆是过度工程）。

---

## 行动清单

### 必须修改（Blocker）
1. **R-1**：PRD §8 bundle 方案与 PM-REPLY 口径统一到「全量本地打包」；精简打包明确降级为 fallback 备选。新增 bundle 体积 AC。

### 建议修改（Major）
1. **R-2**：PRD §5/§8 补「WKWebView 读权限根目录策略」。
2. **R-3**：二选一（推荐不抽 MarkdownFileSource，tab 版真正冻结）并写入 §4/§5。
3. **R-4**：AC-19 把滚动位置恢复的 JS 契约写死（heading id + 偏移百分比）。
4. **R-5**：§6 或新增 §10 列出每条 AC 的测量方式，避免测试触发 CLAUDE.md 反模式。
5. **A-2**：§5 把单例拆为 `MarkdownViewerWindowManager.shared` + 每窗口 `MarkdownViewerWindowController`。
6. **A-3**：§8 锁定 mermaid/marked/highlight 的具体 patch 版本 + 引入 hash 校验脚本 + 接入 release-pretag-guard。
7. **A-4**：§4 明确 folder reference 引入方式与 xcstrings key 清单。
8. **A-6**：新增 §3.5 覆盖 Window 菜单、⌘W、fullscreen、quit 行为。

### 可选优化（Minor）
1. **R-6**：§5 明示 bridge 消息的线程归属。
2. **R-7**：AC-22 如选 R-3 方案 A，嵌入具体 fallback 算法。
3. **R-8**：§3.4 注明性能测量方法与 WKProcessPool 复用策略。
4. **A-1**：目录从 `Sources/Panels/MarkdownViewer/` 改为 `Sources/MarkdownViewer/`（与 Panels 同级）。
5. **A-5**：§5/§8 禁止非 file:// 子资源请求的实现路径。
6. **A-7**：§1.3 明确不接入 command palette / recent files。
7. **A-8**：§7 埋点字段与 AC 做 cross-reference。
8. **A-9**：UI.md 补错误/空态行；PRD §1.3 排除字号缩放。

---

## 对 AC 的补充建议

以下为现 PRD 未覆盖但属于运行期可见行为的建议新增 AC：

| ID（建议） | 场景 | 期望 |
|---|---|---|
| AC-26 | 构建产物 viewer 资源大小 | `Resources/MarkdownViewer/vendor/` 总大小 ≤ 5MB（给 full mermaid + marked + highlight 留足空间但避免失控）；CI 构建后断言 |
| AC-27 | 依赖完整性校验 | 构建/release pretag 阶段，对 vendor JS 计算 sha256 对比 lock 清单；任何 diff 必须先改 lock 再通过 |
| AC-28 | 非 file 子资源阻断 | md 中 `<img src="https://…">` 不产生网络请求（离线 E2E 断言 WKWebView `URLSchemeHandler` / rule list 拦截） |
| AC-29 | Window 菜单与 ⌘W | viewer 窗口出现在 macOS Window 菜单；⌘W 只关当前 viewer；主 cmux 窗口与其他 viewer 不受影响 |
| AC-30 | fullscreen / Spaces | viewer 进入/退出 fullscreen 不影响主 cmux 窗口焦点；在 Spaces 切换后仍能被 `showWindow(for:)` 聚焦 |
| AC-31 | WebView 进程复用 | 关闭最后一个 viewer 窗口后 5 分钟内再次打开，命中 AC-24 热启动路径（证明 WKProcessPool 被复用） |
| AC-32 | md 内本地图片 | （取决于 R-2 决策）若选「只授权 viewer 资源目录」：`<img src="./logo.png">` 降级为可点击链接调用 NSWorkspace；若选「授权 md 目录」：本地图片正常显示 |
| AC-33 | debug 菜单入口 | DEBUG 构建下 Debug Windows 菜单包含「Markdown Viewer Tuning」条目以便即时调排版 token（或显式写明本期不做） |

---

## 落地前置

进入 Dev 前必须确认：

1. **bundle 方案锁定**：用户裁定已是「全量」，PRD 文字需收口为一致表述（R-1）。
2. **mermaid / marked / highlight 具体版本与下载脚本**：落到 `scripts/fetch-markdown-viewer-vendor.sh`（新脚本）或 README 指示 RD 手工一次性下载并 commit 到仓库；lock 文件 `Resources/MarkdownViewer/vendor.lock.json` 带 sha256（A-3）。
3. **WKWebView 资源读权限策略**：方案 1 vs 方案 2 拍板（R-2）。
4. **MarkdownFileSource 抽离节奏**：A vs B 拍板（R-3）。若选 A，则本期不改 `Sources/Panels/MarkdownPanel.swift`；若选 B，补 tab 版回归测试。
5. **WindowController 架构**：A-2 提议的 Manager + per-window Controller 拆分成共识。
6. **pbxproj 改法**：folder reference 或逐文件，由 RD 选择并在 TC（后续交付物）写明（A-4）。
7. **Window 菜单 / 快捷键 / 配置条目**：KeyboardShortcutSettings 是否需要新增条目（CLAUDE.md Shortcut policy）；若需要，settings.json schema + 配置文档同步更新（A-6）。
8. **xcstrings key 清单**：至少包含 `markdownViewer.mermaid.error` / `markdownViewer.file.deleted` / `markdownViewer.file.truncated` / `markdownViewer.file.empty` 等；三语文案 Designer 与 PM 提交前确认。
9. **测试基础设施**：
   - WKWebView 内 DOM 断言方案（`evaluateJavaScript` 帮助器）；
   - 性能 AC（AC-23/24/25）使用 XCTest measure 或自定义 signpost 工具；
   - 大文件 fixture（≥ 10MB md）；
   - Mermaid 各子类型 fixture（graph/flowchart/sequenceDiagram/classDiagram/gantt/pie/state/mindmap/journey）。
10. **可观测性**：viewer bridge 路径的 dlog 调用点列表（配合 §7 与 AC 的 cross-reference）。

---

## 一句话收敛建议

本 PRD **可以在补齐 Blocker（R-1）+ 6 条 Major（R-2/R-3/R-4/R-5、A-2/A-3/A-4/A-6）后进入 TC + Design + QA 并行**；Minor 项允许随 TC 回填。

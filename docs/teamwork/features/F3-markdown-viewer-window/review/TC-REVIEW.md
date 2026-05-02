# F3 · TC 方案评审

> Reviewer：架构师 | 日期：2026-04-14 | 针对 TC.md（1236 行，TC-v1）
> 权威依据：`PRD.md`（2026-04-14 定稿）+ `UI.md` + `review/PRD-REVIEW.md`（10 项落地前置）+ `TEST-PLAN.md`（48 cases）
> 强约束：`CLAUDE.md`（socket/bridge 线程、typing latency、test quality、shortcut policy、submodule、dlog `#if DEBUG`）

---

## 总体结论

**CONDITIONAL-PASS**

TC 整体结构清楚、对 PRD 的 14 个章节映射完整、类型签名精确到可直接翻译成 Swift 骨架，PRD-REVIEW 的 10 项落地前置有 9 项被覆盖。但存在 **3 处 Blocker** 必须在 Dev kick-off 前修；另有 6 处 Major 会在 Dev 中段触发返工（资源加载契约、ContentRuleList JSON 与 PRD A-5 口径、watcher 线程归属改名、test seam 覆盖不完整、feature flag / 回滚开关缺失、pbxproj 步骤非脚本化）。TC 已暴露 3 条 PRD 未覆盖项（附录 B）写得诚实，但其中第 1 条（`viewportStateSync` 仅 dlog）会导致 QA Case 30/31 的 `anchorId` 断言逻辑悬空，需 PM 现在就闭环。

建议：RD 按「必须修改」修订后再进入 Task 1；Task 4 的 `viewer.js` 开工前先补充 §5.3 的「ready 信号 + viewport bridge payload」契约，否则 UITest helper 会和 JS 脱节。

---

## 各维度发现

### A. TC 与 PRD 一致性

#### A-1 `viewportStateSync` 被降级为「仅 dlog」与 QA TEST-PLAN Case 30/31 契约冲突
- 严重度：🔴 Blocker
- 描述：TC §6.2 表格把 `viewportStateSync` 的动作写成「本期选择**仅 dlog**，native 不缓存」（TC 行 667），并在附录 B 第 1 条自陈「native 不缓存，JS 在同 tick 里先 capture 再 restore」。但：
  1. PRD §5.4 明确列出该消息为 bridge 五消息之一，TEST-PLAN Case 30 需要断言「scroll 位置变化 + anchorId 保留或 scrollTopRatio 近似」(TEST-PLAN 行 64) —— 若 native 不存，UITest 无法从 Swift 侧拿 anchorId 做断言，只能通过 JS 内部 state 检查，这会让 Bridge Recorder（TEST-PLAN §3.2）失去一个被设计使用的消息。
  2. 真正的问题在于：文件 rerender 是由 **FileSource `$state` → debounce 120ms → `evaluateJavaScript("boot")`** 驱动（TC §10.3），而 JS 的 `capturePrevViewport()` 在 `boot()` 入口做（TC §5.3 `boot` 伪码行 516）。如果 JS 在 boot 开始时才 capture，此时 `payload.content` 已经是新内容，但 DOM **尚未 replace**——这段确实可以自持。但一旦 **用户在窗口失焦 5 分钟后回来、`effectiveAppearance` 切 dark → `applyTheme()`**，DOM 不 replace，state 不丢，**此时 viewport 不需恢复**；所以 JS 自持确实够用。结论：功能层面成立，但 TC 没说清楚「JS 自持机制在跨 rerender 之间 state 活在哪儿（全局变量 vs closure）」。若 window 被 `cmux.boot` 递归替换整个 `<main>` 后，全局变量是否保留？若依赖 closure 则需要在 viewer.js 顶层维护 `let lastViewportSnapshot = null`。
- 建议：要么把 §6.2 改成「native 缓存最近一次 snapshot 到 `controller.lastViewportSnapshot`（main hop），boot payload 的 `restoreHint` 由 native 注入」，要么在 §5.3 `viewer.js` 职责处显式写「顶层 `let lastViewportSnapshot = null`；`captureViewport()` 在 `boot(payload)` 第 1 行调用前先读；`boot()` 完成后 `lastViewportSnapshot = captureViewport()`」，并把 `viewportStateSync` 彻底从协议中删除或改成「native 仅 dlog，协议保留给未来 multi-window sync」。附录 B 第 1 条要同步修订。
- 需 RD 修改 TC 章节：§5.3（boot 伪码补 snapshot 保留机制）+ §6.2（决策收口）+ 附录 B.1

#### A-2 `WKContentRuleList` JSON 与 PRD A-5 期望的「阻断一切非 file/data/about」不一致
- 严重度：🔴 Blocker
- 描述：PRD §5.3 / PRD-REVIEW A-5 的规则本意是「对 `http(s): / ws(s): / ftp: / data:` 之外的 scheme 双保险阻断」——即**默认 block**，白名单少数 scheme。但 TC §4.3 的 JSON（TC 行 362-368）写成「对 `^https?://` / `^wss?://` / `^ftp://` / `^data:` block」，是**白名单反向**：只列了 4 个要 block 的 scheme，却没覆盖 `chrome://`、`javascript:`、`file://` 作为跨目录跳转等潜在攻击面。更严重的是：
  1. 规则对 `data:` 的 `script` / `fetch` / `websocket` 拦截，但 `document` / `image` 不拦，而 mermaid SVG 内部可能用 `data:` URL 引用字体 —— 当前规则对 mermaid 字体加载放行是对的，但没注释；未来 mermaid 升级若引入 `data:` `script` 嵌入，会被意外拦截（注意 mermaid 10.9.3 有 `securityLevel: 'strict'` 兜底，但是 TC §5.3 的 mermaid 初始化代码里已设置，可以缓解）。
  2. `javascript:` scheme 未被规则显式阻断（依赖 §4.4 的 `decidePolicyFor` 默认 cancel 分支），但 `decidePolicyFor` 对非 linkActivated 的子资源 `javascript:` 不一定会触发——历史上 WKWebView 对 `javascript:` URL 的策略处理有边界问题。
- 建议：把 §4.3 JSON 改为「缺省 block 一切、显式 allow file:/data:/about:」的语义，或至少加上 `javascript:` 显式 block：
  ```json
  { "trigger": { "url-filter": "^javascript:" }, "action": { "type": "block" } },
  { "trigger": { "url-filter": "^(?!(file:|about:|data:)).*" }, "action": { "type": "block" } }
  ```
  并在 TC 里注释「白名单 scheme：file / about / data / blob（mermaid）」。同时确认 mermaid 10.9.3 `securityLevel: 'strict'` 足以阻止用户 md 里嵌 `onclick` 行为，TC §9.3 的 try/catch 兜底不影响该安全层。
- 需 RD 修改 TC 章节：§4.3 JSON + §4.4 注释补齐

#### A-3 Bridge 协议缺 `viewerReady` 消息，TEST-PLAN §3.1 的 helper 无法落地
- 严重度：🔴 Blocker
- 描述：TC §6.1 列了 6 条消息（openExternal / mermaidRenderError / fileReloadAck / viewportStateSync / copyCode / exportMermaidSVG），但 TEST-PLAN §3.1 / R-1 要求一个 `window.__viewerReady` 信号或 `viewerReady` bridge 消息，用于 UITest helper 等待首次 boot 完成。TC 没提供：
  - §5.3 `boot(payload)` 完成后没有 post `{kind:"viewerReady"}`，也没有在 `window.__viewerReady = true`。
  - §6.1 BridgeMsg 联合类型里没有 `viewerReady`。
  - §3.1 时序图最后一步是 `evaluate "window.cmux.boot(payload)"` 就结束了，缺 ack。
  后果：所有 48 个 UITest case 在「await viewer ready」这一步都会用轮询 + 超时 heuristic，flaky。
- 建议：§5.3 `boot()` 末尾（即 `fileReloadAck` 同一位置）post `{kind:"viewerReady", firstBoot: true}`，同时在 window 上 set `window.__viewerReady = true`（两个信道都给，helper 可任选）。§6.1 / §6.2 加入消息条目，线程归属 off-main（仅 dlog + 通知 BridgeRecorder）。§3.1 时序图末尾加一步「didFinish → boot → JS post viewerReady → native dlog」。
- 需 RD 修改 TC 章节：§3.1 + §5.3 + §6.1 + §6.2

### A-4 Manager/Controller/Bridge/FileSource 拆分精确落地
- 严重度：🟢 Minor
- 描述：TC §1 / §2 与 PRD §5.1 的四类拆分精确对应，`Manager` 不继承 `NSWindowController`、`Controller` 继承 `NSWindowController` + `NSWindowDelegate` + `WKNavigationDelegate`，拆分无模糊。MarkdownViewerPayload / Strings / ContentRules 的额外文件属合理辅助。
- 建议：无，这是肯定项。
- 需 RD 修改 TC 章节：—

### A-5 xcstrings 14 key 接入完整
- 严重度：🟢 Minor
- 描述：TC §11.1 表格 14 key 与 PRD §4 清单一一对应；Swift 侧 `MarkdownViewerStrings.all()` 用 `String(localized: String.LocalizationValue($0))` 拼字典，JS 侧通过 bootstrap user script 一次性注入。`markdownViewer.mermaid.loading` 是 UI.md §6 补的，TC 已收编。
- 建议：无；但 `MarkdownViewerStrings` 的 `static let keys: [String]` 与 xcstrings 的真实 key 列表手动同步，容易漂移。可在 Task 6 加一个 lint：`xcstrings` 存在但 `keys` 数组没有的 key → warning（非 blocker）。
- 需 RD 修改 TC 章节：—（可选在 §11 加注）

---

### B. 可实现性 / 执行可行性

#### B-1 Task 5 同时包含 2 新 Swift 类 + Workspace.swift 改造 + pbxproj 改造，review 密度过高
- 严重度：🟡 Major
- 描述：TC §13 Task 5 一次合并 `MarkdownViewerWindowController.swift`（~250 行）+ `MarkdownViewerWindowManager.swift`（~150 行）+ `Workspace.swift` 改 `openFileFromExplorer`（~15 行）+ `GhosttyTabs.xcodeproj/project.pbxproj`（~80 行 diff：新 2 Swift group + 1 folder ref）。同时 AC 覆盖 AC-1/2/3/4/5/6/24/31/D1-D5（12 个 AC）。单 PR ~500 行代码 + ~80 行 pbxproj diff + 12 个 AC 手工验收，超出 TC §13 自声明「≤ 300 行」的上限，reviewer 认知负担大。
- 建议：Task 5 一分为二：
  - Task 5a：新建 `MarkdownViewerWindowController` + `Manager` 类 + pbxproj group 挂载（AC-4 frame 持久化可后移）。无入口接入，不能被触发，仅构造函数 + windowDidLoad 冒烟。
  - Task 5b：改 `Workspace.openFileFromExplorer` + 首次注水 payload + frame 记忆。AC-1/2/4/31 等集中这层。
  - Task 5c（可合入 5b）：pbxproj folder reference（仅资源目录）。
  依赖图更新 `5a → 5b` 线性。
- 需 RD 修改 TC 章节：§13 Task 分解

#### B-2 pbxproj folder reference 只给「Xcode UI 步骤」没有 CLI 脚本，Dev 不可 reproducible
- 严重度：🟡 Major
- 描述：TC §7.1 给出的是 Xcode.app 手动步骤（右键 → New Group from Folder / Add Files / Options 勾选 Create folder references）。问题：
  1. CI 无法验证「pbxproj diff 是否合规」——folder reference 的 `lastKnownFileType = folder;` 与逐文件 add 的 diff 在视觉上不同，reviewer 漏掉某个文件没被纳入 Copy Bundle Resources 也不会报错。
  2. 多 dev 环境（有的用 Xcode 15、有的 16）右键菜单翻译不同，步骤描述易歧义。
  3. CLAUDE.md 要求 reproducible build，没有 CLI 工具做等价操作。
- 建议：TC §7.1 补充：
  - 推荐使用 `xcodegen` 或 `tuist`（若无则承认 pbxproj 手工维护），但至少给一个 `ruby/xcodeproj gem` 的快速 snippet：
    ```ruby
    require 'xcodeproj'
    project = Xcodeproj::Project.open('GhosttyTabs.xcodeproj')
    target = project.targets.find { |t| t.name == 'cmux' }
    # ...add folder reference to Resources/MarkdownViewer
    project.save
    ```
  - PR 验收：`ls "$APP/Contents/Resources/MarkdownViewer/viewer.html"` 存在 + `ls "$APP/Contents/Resources/MarkdownViewer/vendor/mermaid.min.js"` 存在，作为 UITest 冒烟前置。
- 需 RD 修改 TC 章节：§7.1

#### B-3 `verify-markdown-viewer-vendor.sh` 依赖 python3 但未声明版本 / 未做 shebang 兜底
- 严重度：🟢 Minor
- 描述：TC §7.3 脚本用 `python3 - ... <<PY ... PY`。GitHub Actions macos-14 默认 python3 是 3.12，脚本 OK；但 `release-pretag-guard.sh` 被用户本地运行时可能 python3 指向 3.7（旧系统 Python）。`hashlib` / `json` 是标准库，不成问题；但 `f-string` + 海象运算符无使用，兼容到 3.6 即可。主要风险是：macOS Big Sur 之前无 `python3`（已被系统 Python 2 取代）。CLAUDE.md 测试策略是 GitHub Actions CI，风险小。
- 建议：TC §7.3 脚本开头 `command -v python3 >/dev/null || { echo "python3 required"; exit 2; }`；TEST-PLAN R-7 的 shasum 预检可以移植到这里。
- 需 RD 修改 TC 章节：§7.3

#### B-4 Watcher reattach 6×0.5s 与 atomic-save 语义兼容性未覆盖「先 `.rename` 后 create」的 vim `:w` fallback
- 严重度：🟡 Major
- 描述：TC §3.4 沿用 MarkdownPanel 的策略。但 MarkdownPanel.swift:120-134 的原始实现：`.delete` / `.rename` 时**先 `loadContent` 再判断**，若文件仍可读（atomic save 已完成）则立即 reattach。vim 的 `:w` 过程：
  1. 写 `.~1~` backup
  2. `rename` 原文件到 backup
  3. `rename` 新文件到原名
  步骤 2 与 3 之间有极短时间窗（μs 级，但 DispatchSource 事件可能落在窗内）原文件 inode 已消失、新文件尚未 rename 进来。若 event 落在这个窗口内：
  - MarkdownPanel 会 `loadContent` → file not found → `scheduleReattach(1)` → 500ms 后重试。
  - TC §3.4 的实现「若仍 unavailable → scheduleReattach」行为一致。
  但 VS Code 的 atomic save 用 `rename(tmp, target)` 一步到位，此时 `.rename` event 触发时原 inode 被新 inode 替换，`open(filePath, O_EVTONLY)` 的 fd 指向旧 inode 的 DispatchSource 会收到 `.delete` flag，需要立即 close fd 并 reopen。TC §2.4 `MarkdownViewerFileSource` 的 `fd: Int32 = -1` + `stopWatcher` → `startWatcher` 循环应能处理，但 TC §2.4 没有显式说明 `stopWatcher` 会 close `fd`。MarkdownPanel 靠 `source.setCancelHandler { Darwin.close(fd) }`（MarkdownPanel.swift:143-145）保证，TC 需要复刻该 cancel handler。
- 建议：TC §2.4 的 `MarkdownViewerFileSource` 伪码补 `stopWatcher` 的实现细节：
  ```swift
  private func stopWatcher() {
      watchSource?.cancel()         // cancel handler close(fd) 见 MarkdownPanel.swift:143
      watchSource = nil
      fd = -1                       // 由 cancel handler close
  }
  ```
  并在 §3.4 加注「vim `:w` 的 rename 窗口 → `.delete` flag → 走 reattach 循环；VS Code atomic-save → 同样 `.delete` → 立即 reopen」。
- 需 RD 修改 TC 章节：§2.4 + §3.4

#### B-5 WKProcessPool 「app quit 前不释放」在 UITest 后进程不清理问题
- 严重度：🟡 Major
- 描述：TC §10.1 定「Manager 在首次 showWindow 时创建 `WKProcessPool`，整个进程生命周期保留」。UITest 用 XCUIApplication 启动 tagged app → 多个 viewer case 顺序执行 → tearDown 不会释放 pool → 下一 case 开始时 `__test_processPoolIdentity`（QA seam 请求）应当返回同一个 pool 以验证 AC-31。但 TEST-PLAN §3.1 / Case 46 要求测试「关闭最后一个 viewer 后 5 分钟内再打开 → 命中 AC-24 热启动」。UITest 内部不会真的等 5 分钟，只能依赖「立即再开」路径。若 TC 没暴露 seam 观察 pool identity，Case 46 的判定退化为「热开启时间 ≤ 200ms」（这是 TEST-PLAN §4.6 说的间接断言），pool 是否复用无法直接证明。
- 建议：TC §2.1 Manager 暴露 DEBUG-only seam：
  ```swift
  #if DEBUG
  extension MarkdownViewerWindowManager {
      var __test_processPoolIdentity: ObjectIdentifier { ObjectIdentifier(processPool) }
      func __test_resetProcessPool() { processPool = WKProcessPool() }   // 仅测试隔离
  }
  #endif
  ```
  Case 46 断言两次开 viewer 之间 `__test_processPoolIdentity` 相等。
- 需 RD 修改 TC 章节：§2.1 + §13 Task 5 / Task 7（seam 声明）

#### B-6 Task 间依赖图「Task 2 与 Task 3 可并行」但两者都依赖 pbxproj 在 Task 5 才动
- 严重度：🟢 Minor
- 描述：Task 2 / 3 新增 Swift 文件，但 pbxproj 的 Compile Sources 阶段加入在 Task 5 才做。意味着 Task 2 / 3 的 PR 里 Swift 文件**不会被编译**，CI 的单测阶段无法验证「文件能 compile」。
- 建议：要么 Task 1 就加入 `Sources/MarkdownViewer/` group（空目录 + 占位 Swift），后续 Task 往里加文件时自动被 compile；要么 Task 2 / 3 / 4 的 PR 都跟 pbxproj 小改动。推荐前者：Task 1 的 artifact 里加一个 `MarkdownViewer/.keep.swift`（内容：`// placeholder, remove in Task 2`）和 pbxproj group。
- 需 RD 修改 TC 章节：§13 Task 1 + 依赖图

---

### C. 线程 / 性能契约

#### C-1 Bridge off-main 解析之后的「main dispatch 分界」实施细节模糊
- 严重度：🟡 Major
- 描述：TC §3.3 把 `openExternal` / `copyCode` / `exportMermaidSVG` 定义为「off-main parse → main dispatch 动作」，其余留在 parseQueue。问题：
  1. `route(_ msg:)` 在 parseQueue 里执行，内部对 `openExternal` 需要 `DispatchQueue.main.async { NSWorkspace.shared.open(...) }`。但 `controller` 在 parseQueue 里被读取是否需要锁？`bridge.controller` weak 声明，Swift 对 weak 引用在非 main 线程读取 race-free 吗？`weak var controller: MarkdownViewerWindowController?` 的 weak 引用读取是 thread-safe 的（runtime 保证），但 controller 的任何方法调用都是 `@MainActor`，从 parseQueue 直接 `controller?.handleOpenExternal(...)` 会触发 actor isolation 错误（Swift 6 strict concurrency）。
  2. TC §2.3 的 `route(_:)` 没写实现；如果是直接 call `controller?.handleXxx(...)`，编译失败。
- 建议：TC §2.3 `route(_:)` 伪码补全：
  ```swift
  private func route(_ msg: BridgeMessage) {
      switch msg {
      case .openExternal, .copyCode, .exportMermaidSVG:
          Task { @MainActor [weak self] in
              guard let ctrl = self?.controller else { return }
              // dispatch to ctrl.handleXxx
          }
      case .mermaidRenderError(let n, let messages):
          #if DEBUG
          dlog("markdownViewer.mermaid renderErrors=\(n) ...")
          #endif
      // ...
      }
  }
  ```
  明示 `Task { @MainActor }` / `MainActor.assumeIsolated` 跨越边界。
- 需 RD 修改 TC 章节：§2.3 + §3.3

#### C-2 AC-23/24/25 性能目标缺「实测基线」与「降级触发阈值的自动化」
- 严重度：🟡 Major
- 描述：TC §10.1 讲了「本期不做启动预热，若 AC-23 冷启动实测 > 500ms 再开 `enablePoolPrewarm` feature flag」。但：
  1. 「实测」的采集时机？TEST-PLAN Case 36 (XCTest measure) 在 nightly 运行，若突破阈值，谁决策开 flag？
  2. Flag 的默认值 / 读入位置 / 生命周期未定义。如果是 `UserDefaults`，key 名字？环境变量？CLAUDE.md 的 shortcut policy 有类似条目要求，feature flag 应在 `settings.json`。
  3. §14.2 重复描述了 prewarm，但 `CMUX_MARKDOWN_VIEWER_PREWARM=1` 环境变量与 §10.1 的 `enablePoolPrewarm` 默认 flag 两个名字不一致。
- 建议：TC §10.1 + §14.2 统一：
  - Flag 名：`CMUX_MARKDOWN_VIEWER_PREWARM`（仅环境变量，DEBUG / 实验用）。
  - 默认 OFF。实测超标走 §14.2 降级路径。
  - §10.1 明写「若 Case 36 连续 3 次 p50 > 500ms，开 issue + 翻开 flag」。
- 需 RD 修改 TC 章节：§10.1 + §14.2

#### C-3 Typing latency 回归（PRD RD B-3）没进入 Task 7 的显式场景
- 严重度：🟡 Major
- 描述：CLAUDE.md「Typing-latency-sensitive paths」列出 3 个主场景（hitTest / TabItemView / TerminalSurface.forceRefresh），新 WKWebView 进程共用 WebKit 主进程 CPU，会不会影响终端 typing？PRD §10 测试策略中的「AC-23 + typing latency 回归」明确要求一组基线（主窗口 heavy typing + 5 viewer 同开大 md）。TC 附录 B.3 自陈「未做基准测量」。Task 7 只说「对齐 PRD §10」，没列出这组基线 case。
- 建议：TC §13 Task 7 明示一个 sub-case（编号衔接 TEST-PLAN）：「场景：打开 5 个 viewer + 终端 `yes > /dev/null` 运行 60s + 键入 1000 次 → 断言 keystroke-to-glyph p95 latency 与 cmux-pro baseline 差 < 10%」。baseline 数据从 KeyboardLatencyTests（若无则新建）拿。
- 需 RD 修改 TC 章节：§13 Task 7 + §10.1

### C-4 WKProcessPool 预热决策已明确，不算 gap
- 严重度：🟢 Minor
- 描述：TC §10.1 显式选择「持久复用，不启动预热」，并给出降级路径。决策清晰。
- 建议：无。
- 需 RD 修改 TC 章节：—

---

### D. 错误 / 边界

#### D-1 10MB 截断「UTF-8 字符边界」未处理
- 严重度：🟡 Major
- 描述：TC §9.1 `handle.read(upToCount: byteLimit)` 返回前 10 × 1024 × 1024 字节，但 UTF-8 多字节字符（中文 3 字节、emoji 4 字节）在截断边界可能断成非法序列 → `String(data:encoding:.utf8)` 返回 nil → 然后 fallback 到 ISO-Latin-1 → 得到乱码。用户期望「前 10MB 正常显示」，实际看到尾部几字节乱码。
- 建议：§9.1 补「UTF-8 安全截断」：从 byteLimit 位置向前扫描，找到合法的 UTF-8 start byte（首字节 & 0xC0 != 0x80）作为真实截断点。或直接用 `String(decoding:data, as: UTF8.self)` 的 lossy 模式然后剪掉末尾 U+FFFD 序列。前者更精确：
  ```swift
  func safeUTF8Truncate(_ data: Data, limit: Int) -> Data {
      if data.count <= limit { return data }
      var end = limit
      while end > 0 && (data[end] & 0xC0) == 0x80 { end -= 1 }   // backtrack to lead byte
      return data.prefix(end)
  }
  ```
- 需 RD 修改 TC 章节：§9.1

#### D-2 编码 fallback 的「都失败」路径未落到 UI 明确态
- 严重度：🟢 Minor
- 描述：TC §9.1 `publish(.unavailable(reason: .encoding))` → JS 侧 §5.3 `state=unavailable, reason=encoding` → 展示「`Unable to read file: %@`」。但 xcstrings 的 `markdownViewer.file.unavailable` 只有一个 key，区分不了「编码坏」vs「IO 错」vs「文件不存在」。UI.md §6 也没分态。用户体验上：编码坏 ≠ 文件丢失。
- 建议：要么接受当前口径（所有 unavailable 统一提示），要么新增 key `markdownViewer.file.unavailable.encoding`。建议前者（不膨胀 key），但 §5.3 `showEmptyState("markdownViewer.file.unavailable", path=payload.filePath)` 的 reason 应附加到 dlog：`markdownViewer.fileUnavailable path=<p> reason=<r>`。
- 需 RD 修改 TC 章节：§5.3 + §12 埋点表

#### D-3 Mermaid 单 block 错误不影响其他 block — 实现正确，但 AC-12 文案细节疑问
- 严重度：🟢 Minor
- 描述：TC §9.3 每 block try/catch 独立，正确。但 `errors.slice(0, 3)` 只回报前 3 条（TC §6.2 表格 validator 也说「截断到首 3 条」）。PRD AC-12 没限制 3 条，若文档里 10 个 mermaid 全挂，用户只看到 3 条 dlog，剩余被吞。
- 建议：保留前 3 条回传 bridge（避免 dlog 膨胀），但 JS 侧每块 `.is-error` 容器内本地显示完整错误 message（不经 bridge）。TC §9.3 已这么做（`wrapEl.innerHTML = ... <pre>${escapeHtml(...)}</pre>`），是对的；只需 §6.2 注释「messages 截断到 3 条仅影响 dlog；UI 全量显示」。
- 需 RD 修改 TC 章节：§6.2 注释

#### D-4 Symlink / hardlink 的 canonicalKey 规范化
- 严重度：🟡 Major
- 描述：TC §2.1 `canonicalKey(_:)` 注释「URL.standardizedFileURL.path」。`standardizedFileURL` 解析 `..` / `.` 但**不** resolve symlink。若用户两次打开 `~/proj/README.md` 和 `~/proj-symlink/README.md`（后者是 `~/proj` 的 symlink），会被视为两个 key → 开两个窗口指向同一物理文件 → watcher 重复 + AC-2 违反（同一 md 不应开两个）。
- 建议：canonical 用 `resolvingSymlinksInPath()`：
  ```swift
  private func canonicalKey(_ path: String) -> String {
      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
  ```
  并在 §14 风险表列「APFS clone / iCloud 同步目录 → 文件 inode 变动更频繁，watcher reattach 次数可能增加」，影响程度未知但 TC 认可「6 次 × 0.5s 是实验值」足以覆盖常见情况。
- 需 RD 修改 TC 章节：§2.1 + §14

#### D-5 Spaces / fullscreen 下的 `showWindow(for:)` 聚焦行为
- 严重度：🟡 Major
- 描述：TC §2.1 的 hit-existing 分支只 call `makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: false)`（行 94）。若该 viewer 已在另一个 Space（用户把 viewer 拖到 Space 2，当前在 Space 1），`makeKeyAndOrderFront` 不会自动 Space 切换。AC-D3 要求「Spaces 切换后 `showWindow(for:)` 仍能聚焦已有窗口」。
- 建议：§2.1 hit-existing 分支补 `controller.window?.orderFrontRegardless()` 或 `NSApp.activate(ignoringOtherApps: true)` + 设置 `window.collectionBehavior.insert(.moveToActiveSpace)` 在 window 构造时。TEST-PLAN §4.3 也承认 Case 45 无法直接断言 Space 切换，但至少 styleMask 翻转 + `mainWindow` 独立性可被测。
- 需 RD 修改 TC 章节：§2.1 + §2.2（window 构造时的 `collectionBehavior`）

---

### E. 测试基础设施

#### E-1 TC 未显式声明 `__test_processPoolIdentity` / `__test_controller(for:)` seam
- 严重度：🟡 Major
- 描述：TEST-PLAN §3.1 明确要求 Manager 暴露 `__test_controller(for:)` DEBUG-only seam；TEST-PLAN Case 46 间接依赖 pool identity seam（见本评审 B-5）。TC §2.1 / §2.5 未列出任何 `#if DEBUG` test seam。
- 建议：TC §2.1 末尾 / §11 附近加一小节「DEBUG-only test seams」，列全：
  ```swift
  #if DEBUG
  extension MarkdownViewerWindowManager {
      var __test_activeControllers: [String: MarkdownViewerWindowController] { controllers }
      func __test_controller(for path: String) -> MarkdownViewerWindowController? {
          controllers[canonicalKey(path)]
      }
      var __test_processPoolIdentity: ObjectIdentifier { ObjectIdentifier(processPool) }
  }
  extension MarkdownViewerWebBridge {
      static var __test_onMessage: ((BridgeMessage) -> Void)?
  }
  #endif
  ```
- 需 RD 修改 TC 章节：§2.1 + §2.3 + §13 Task 5

#### E-2 Bridge Recorder 要求「bridge 消息的副本 callback」，TC 未规划
- 严重度：🟡 Major
- 描述：TEST-PLAN §3.2 需要 `BridgeRecorder().waitForMessage(name:timeout:)`，对应 TC 必须在 bridge `route(_:)` 里 tap 一个 DEBUG-only 回调。TC §2.3 `MarkdownViewerWebBridge` 只有 `controller: weak` + `parseQueue`，无 seam。
- 建议：Bridge seam（见 E-1 的 `__test_onMessage`），在 `route(_:)` 入口：
  ```swift
  #if DEBUG
  Self.__test_onMessage?(msg)
  #endif
  ```
- 需 RD 修改 TC 章节：§2.3

#### E-3 Mermaid 子类型 fixtures 清单 Task 7 引用 TEST-PLAN §3.4 列表，不再独立列
- 严重度：🟢 Minor
- 描述：TC §13 Task 7 列出 fixtures：`mermaid_{graph,sequence,class,gantt,pie,state,mindmap,journey}.md` —— 与 TEST-PLAN §3.4 的 `flowchart` 比少一项。
- 建议：加回 `mermaid_flowchart.md`（共 9 子类型），与 TEST-PLAN Case 17-22 对齐。
- 需 RD 修改 TC 章节：§13 Task 7

---

### F. CLAUDE.md 规范对齐

#### F-1 dlog `#if DEBUG` 包裹已在 §12 声明，但 §5.3 JS 侧 bridge `postMessage({kind:"mermaidRenderError",...})` 无 DEBUG 边界
- 严重度：🟢 Minor
- 描述：JS 不存在 `#if DEBUG` 概念，bridge 消息总在发送，native 侧接到后走 parseQueue → dlog。native 的 dlog 已 `#if DEBUG` 包裹（TC §12 声明），因此生产 build 里 bridge 消息会被 native 静默 drop（parseQueue 仅 dlog）。合规。
- 建议：§12 加一句「JS 端不区分 DEBUG / RELEASE，bridge 消息的副作用全部走 native parseQueue 内的 `#if DEBUG` dlog；release build 等价于 no-op」。明示规范即可。
- 需 RD 修改 TC 章节：§12

#### F-2 Task 7 的 TEST 代码要求测**运行期行为**而非源码文本，TC 已明示
- 严重度：🟢 Minor
- 描述：TC §13 Task 7 注明「不可测源码文本 / plist 字段」。TEST-PLAN §1.1 / §6 的自检清单也严格对齐。合规。
- 建议：无。
- 需 RD 修改 TC 章节：—

#### F-3 Shortcut policy：本 feature 不引入 cmux-owned shortcut，PRD §3.6 已声明，TC 未再确认
- 严重度：🟢 Minor
- 描述：PRD §3.6 明确「本期不新增 KeyboardShortcutSettings 条目；⌘W 由 AppKit 标准 performClose: 承接」。TC 全文未提快捷键；`MarkdownViewerMenu.swift`（可选）只挂 `toggleCollectionBehavior`，不注册全局快捷键。合规。
- 建议：TC §14 风险表加一行「若未来在 viewer 内加 cmux-owned shortcut（⌘+/⌘- zoom、⌘F 自定义 find），需走 KeyboardShortcutSettings + settings.json + docs 三连」。占位即可。
- 需 RD 修改 TC 章节：§14

#### F-4 Socket threading policy 精神已贯彻
- 严重度：🟢 Minor
- 描述：TC §3.3 / §6.2 区分了 telemetry（off-main）vs UI 动作（main），与 CLAUDE.md「socket command threading policy」同步。
- 建议：无。
- 需 RD 修改 TC 章节：—

---

### G. Dev Chain 安全性

#### G-1 Task 链没有 feature flag / kill switch，问题出现无法快速回滚
- 严重度：🟡 Major
- 描述：TC §14.1 / §14.2 有「Mermaid 精简包」「prewarm」两个降级路径，但都是代码修改 + 重编译级别，不能运行时关闭。最大风险：Task 5 上线后 `Workspace.openFileFromExplorer` 的 `.md` 分支永久切到 viewer。若 viewer 触发 crash、typing latency 回归、文件 watcher 死循环，主仓库的 rollback 需要 revert PR。
- 建议：TC §8 入口改造处加 feature flag：
  ```swift
  if isMarkdown {
      if FeatureFlags.markdownViewerEnabled {           // 默认 true；可通过 env 或 settings.json 关闭
          MarkdownViewerWindowManager.shared.showWindow(for: filePath)
      } else if let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first {
          _ = newMarkdownSurface(inPane: paneId, filePath: filePath, focus: true)  // 旧 tab 路径兜底
      }
      return true
  }
  ```
  Flag 可由 `CMUX_MARKDOWN_VIEWER_DISABLED=1` 关闭。上线 2 周后 flag 删除。这同时满足 CLAUDE.md「update-config skill」设置透明 + 允许用户快速禁用 viewer。
- 需 RD 修改 TC 章节：§8 + §14

#### G-2 Task 每个独立过 CI 的可行性
- 严重度：🟢 Minor
- 描述：Task 1（脚本 + vendor）可独立 CI 跑 `verify-markdown-viewer-vendor.sh`；Task 2-6 若解决 B-6（Task 1 占位 pbxproj group），每个 Task 新增的 Swift 文件都能 compile。Task 7 依赖前 6 完成。链条健康。
- 建议：无（实现 B-6 后闭环）。
- 需 RD 修改 TC 章节：—

#### G-3 Pbxproj 巨量 diff 反复
- 严重度：🟢 Minor
- 描述：Task 1（若按 B-6 加 group）+ Task 5（folder reference）+ Task 7（测试文件）三次改 pbxproj。每次 diff 难审。若全部集中在 Task 5，B-1 已指出认知负担。
- 建议：接受 3 次小改 pbxproj，每次 ≤ 20 行 diff；PR 描述里贴出 `git diff project.pbxproj | wc -l` 让 reviewer 快速判断。
- 需 RD 修改 TC 章节：§13 PR 模板（可选）

---

## 行动清单

### 必须修改（Blocker）
1. **A-1**：§5.3 `viewer.js` 顶层保留 `lastViewportSnapshot`（或 native 缓存，二选一），并决策 `viewportStateSync` 是否彻底从协议中删除；附录 B.1 同步修订。
2. **A-2**：§4.3 `WKContentRuleList` JSON 改为「缺省 block + 白名单 file/about/data/blob」；显式 block `javascript:`。
3. **A-3**：bridge 协议新增 `viewerReady` 消息 + `window.__viewerReady` 全局变量；§3.1 时序图末尾、§5.3 boot 尾部、§6.1 / §6.2 全部补齐。

### 建议修改（Major）
1. **B-1**：Task 5 拆成 5a（Manager/Controller 骨架）+ 5b（入口接入 + frame 记忆）。
2. **B-2**：§7.1 pbxproj 操作补 CLI snippet（xcodeproj gem 或 xcodegen），不要只给 Xcode.app 步骤。
3. **B-4**：§2.4 补 `stopWatcher` close(fd) 细节 + §3.4 vim/VS Code atomic-save 边界注释。
4. **B-5**：§2.1 暴露 `__test_processPoolIdentity` / `__test_controller(for:)` seam。
5. **C-1**：§2.3 `route(_:)` 补全 `Task { @MainActor }` 跨越边界，解决 Swift 6 concurrency。
6. **C-2**：§10.1 与 §14.2 的 prewarm flag 统一名字 + 触发条件。
7. **C-3**：§13 Task 7 加 typing latency 回归场景 case。
8. **D-1**：§9.1 UTF-8 字符边界截断算法。
9. **D-4**：§2.1 `canonicalKey` 用 `resolvingSymlinksInPath()`。
10. **D-5**：§2.1 hit-existing 分支补 `collectionBehavior.moveToActiveSpace` + `orderFrontRegardless`。
11. **E-1**：§2.1 / §2.3 / §13 Task 5 显式声明 test seams。
12. **E-2**：§2.3 bridge 消息 tap 回调。
13. **G-1**：§8 入口加 feature flag `CMUX_MARKDOWN_VIEWER_DISABLED` 兜底旧 tab 路径 2 周。

### 可选优化（Minor）
1. **B-3**：§7.3 脚本 python3 预检。
2. **B-6**：Task 1 增加 pbxproj group 占位，让 Task 2 / 3 / 4 的 Swift 能进 compile phase。
3. **D-2**：§5.3 `showEmptyState` 的 `reason` 写入 dlog。
4. **D-3**：§6.2 注明 `messages.slice(0,3)` 仅影响 dlog。
5. **E-3**：§13 Task 7 fixtures 加 `mermaid_flowchart.md`。
6. **F-1**：§12 注「JS 端不做 DEBUG 区分，效果等价」。
7. **F-3**：§14 风险表加 shortcut policy 提醒。
8. **G-3**：§13 PR 模板里提示 pbxproj diff 行数。

---

## 落地前置

进入 Dev Task 1 前必须确认：

1. **A-1 viewport 策略拍板**（RD 主决，PM 知会）：viewport 恢复到底走 JS 自持 or native 缓存 —— 结论写进 TC §5.3 / §6.2，附录 B.1 同步。
2. **A-2 ContentRuleList 语义**（RD 实验）：先用 `WKContentRuleListStore.default().compileContentRuleList(...)` 编译新 JSON，验证 mermaid 10.9.3 所有子类型 SVG 不被误杀（特别是 gantt / sequence 内部可能 fetch web font）。
3. **A-3 viewerReady 信号**（RD + QA）：约定 post message schema，BridgeRecorder helper 与之对齐。
4. **C-1 Swift 6 concurrency**（RD）：当前项目是否已开 `SWIFT_STRICT_CONCURRENCY=complete`？若否，`Task { @MainActor }` 的跨越边界可用 `DispatchQueue.main.async` 简化；若是，必须用 structured concurrency。
5. **D-4 canonicalKey**（RD）：测试 `~/proj-symlink` 链接到 `~/proj` 的 `README.md`，两次 `showWindow` 是否复用同一 controller。
6. **E-1 / E-2 test seams**（RD + QA）：QA Lead 签字认可 seams 契约，写入 TEST-PLAN §3.1。
7. **G-1 feature flag**（PM + RD）：flag 生命周期（2 周 or 1 个版本）+ 关闭方式（env var 还是 settings.json）拍板。
8. **B-2 pbxproj 工具**（RD）：选定 xcodeproj gem / manual edit / xcodegen，并在 repo 里放一个 `scripts/regenerate-markdown-viewer-pbxproj.rb` 或等价物。

---

## 肯定项（Did right）

- **PRD-REVIEW 10 项落地前置覆盖率高**：bundle 体积 AC-26（R-1）、folder reference（A-4）、Manager/Controller 拆分（A-2）、xcstrings key 清单（A-4）、vendor lock + pretag guard（A-3）、AC-19 滚动契约（R-4）、测试策略不踩 test quality 红线（R-5）、bridge 线程分层（R-6）、编码 fallback 具体算法（R-7）、WKProcessPool 复用（R-8）都在 TC 里有明确对应章节，10 项只有第 1 项 viewport 策略存在盲点。
- **类型签名精确**：§2.1–§2.5 的 Swift 伪码参数类型、访问级、线程归属清楚，RD 可直接生成 Xcode 骨架。
- **关闭时序 10 步强制顺序**：§3.2 的 `isClosing=true` → `fileSource.close()` → teardown 序列与 WKWebView / DispatchSource / KVO 三类资源的释放顺序完全对。这是历史上新手最容易搞错的地方。
- **vendor 脚本 + lock + pretag guard 三连**：§7.2 / §7.3 / §7.5 端到端闭环，CI 能独立跑，不依赖仓库外环境。
- **附录 B 暴露 TC 落地过程中发现的 PRD 未覆盖项**：3 条自陈（viewport native 缓存 / Workspace 返回值语义 / typing latency 基线）诚实，不回避。其中第 2、3 条可以在 PRD 轻量补；第 1 条进本评审 A-1 Blocker。
- **§11 xcstrings 14 key 与 PRD 完全对齐**：数量、文案、三语初稿齐备，Task 6 直接录入。
- **§14 回滚路径具体**：mermaid 精简包、prewarm flag、FileSource 对照矩阵三个方向都可执行，不是口号。

---

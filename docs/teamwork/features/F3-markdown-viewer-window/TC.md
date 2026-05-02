# F3 · Markdown Viewer 窗口 + Mermaid · 技术方案（TC）

> Feature 流程 · TC
> 作者：RD / 架构师 | 日期：2026-04-14 | 状态：TC-v1 待 Dev kick-off
> 上游：`PRD.md`（2026-04-14 定稿，CONDITIONAL-PASS 已全量闭环）+ `UI.md`（2026-04-14 定稿）+ `review/PRD-REVIEW.md`（落地前置 10 项）
> 约束：`CLAUDE.md`（socket/bridge 线程策略、typing latency、test quality、shortcut policy、submodule、dlog `#if DEBUG`）

本文档按照用户要求的 14 节顺序给出落地蓝图。允许 Swift-like / JS-like 伪码；类型签名精确到参数类型，但不求完整可编译。每处约束后括号标注 AC 编号以便追溯。

---

## 1. 模块与文件清单

新目录与 `Sources/Panels/` 同级（A-1 决议）。

### 1.1 Swift 源

| 路径 | 职责 | 线程 | 关键符号 |
|---|---|---|---|
| `Sources/MarkdownViewer/MarkdownViewerWindowManager.swift` | 单例 Manager；全局 `WKProcessPool`；path → Controller map；去重聚焦 | `@MainActor` | `static let shared`, `processPool`, `showWindow(for:)`, `detach(_:)`, `lastSavedFrame` |
| `Sources/MarkdownViewer/MarkdownViewerWindowController.swift` | `NSWindowController` 子类；持 `WKWebView` + `FileSource`；window frame 记忆；主题切换监听 | `@MainActor` | `init(filePath:processPool:manager:)`, `windowWillClose(_:)`, navigation delegate 回调 |
| `Sources/MarkdownViewer/MarkdownViewerWebBridge.swift` | `WKScriptMessageHandler`；消息分发；off-main 解析 + main-actor 调度 | mix（入口 main，解析 off-main） | `userContentController(_:didReceive:)` |
| `Sources/MarkdownViewer/MarkdownViewerFileSource.swift` | 最小 watcher：load / reattach / encoding fallback / 10MB 截断；不 import `MarkdownPanel` | 主要 main actor；watcher 回调 off-main → main-hop | `@Published content`, `@Published state`, `close()` |
| `Sources/MarkdownViewer/MarkdownViewerPayload.swift` | 结构化注水 payload；JSON encode 供 JS 消费 | pure value type | `struct MarkdownViewerPayload: Encodable` |
| `Sources/MarkdownViewer/MarkdownViewerStrings.swift` | xcstrings 读取 + 构造 JS 侧 L10n 字典 | pure value type | `enum MarkdownViewerStrings`, `static func all() -> [String: String]` |
| `Sources/MarkdownViewer/MarkdownViewerContentRules.swift` | `WKContentRuleList` JSON 提供者 + lazy compile + 缓存 | async main | `static func sharedRuleList() async throws -> WKContentRuleList` |
| `Sources/MarkdownViewer/MarkdownViewerMenu.swift`（可选） | 让 window 出现在 `Window` 菜单（`NSWindow.isExcludedFromWindowsMenu = false` 默认即可）；本文件仅在需要挂 `toggleCollectionBehavior` 时新增 | main | — |

### 1.2 Resources（folder reference，A-4）

| 路径 | 说明 |
|---|---|
| `Resources/MarkdownViewer/viewer.html` | 静态骨架；含 `__MARKDOWN_VIEWER_STRINGS__` / `__MARKDOWN_VIEWER_INITIAL__` placeholder（由 Swift 首次 load 时替换） |
| `Resources/MarkdownViewer/viewer.css` | UI.md §3/§7 token → CSS 变量一一映射 |
| `Resources/MarkdownViewer/viewer.js` | 渲染管线：marked 解析 → DOM patch → highlight.js → mermaid 懒初始化 → 滚动恢复；bridge proxy |
| `Resources/MarkdownViewer/vendor/marked.min.js` | 固定 `marked@14.1.3` |
| `Resources/MarkdownViewer/vendor/mermaid.min.js` | 固定 `mermaid@10.9.3` UMD（全量） |
| `Resources/MarkdownViewer/vendor/highlight.min.js` | 固定 `highlight.js@11.10.0` common languages bundle |
| `Resources/MarkdownViewer/vendor.lock.json` | `{name, version, filename, sha256, sourceUrl, bytes}[]` |

### 1.3 脚本

| 路径 | 职责 |
|---|---|
| `scripts/fetch-markdown-viewer-vendor.sh` | 一次性 / 升级时从官方 release 拉取 JS 产物并写 lock |
| `scripts/verify-markdown-viewer-vendor.sh` | CI/release-pretag 调用：sha256 对比 lock；任一 mismatch exit 1；`du -b` 断言 ≤ 5MB（AC-26） |

### 1.4 修改点

| 路径 | 改动 |
|---|---|
| `Sources/Workspace.swift` | `openFileFromExplorer(filePath:)` 的 `.md` 分支：`newMarkdownSurface(inPane:filePath:focus:)` → `MarkdownViewerWindowManager.shared.showWindow(for:)`。非 md 分支**不变** |
| `Resources/Localizable.xcstrings` | 追加 PRD §4 / UI.md §3 · §4 · §6 · §8 的 14 个 key（en / zh-Hans / ja） |
| `scripts/release-pretag-guard.sh` | 追加一行调用 `verify-markdown-viewer-vendor.sh` |
| `GhosttyTabs.xcodeproj/project.pbxproj` | `Sources/MarkdownViewer/` 逐文件加入 compile；`Resources/MarkdownViewer/` 作为 folder reference 加入 Copy Bundle Resources |

> 明确：`Sources/Panels/MarkdownPanel.swift` / `MarkdownPanelView.swift` / `MarkdownContent.swift` **零改动**（R-3 方案 A 决议）。

---

## 2. 类型与接口细化

### 2.1 `MarkdownViewerWindowManager`

```swift
@MainActor
final class MarkdownViewerWindowManager: NSObject {
    static let shared = MarkdownViewerWindowManager()

    // 公共
    private(set) var processPool = WKProcessPool()   // 全局复用（AC-24 / AC-31）；var 以便 DEBUG test reset
    private(set) var activeControllers: Int { controllers.count }

    // 内部
    private var controllers: [String: MarkdownViewerWindowController] = [:]
    private var lastSavedFrame: NSRect?         // AC-4：全局单份
    private let defaultsKey = "cmux.markdownViewer.windowFrame"

    // Public API
    @discardableResult
    func showWindow(for filePath: String) -> MarkdownViewerWindowController
    func detach(_ controller: MarkdownViewerWindowController)          // windowWillClose 回调
    func currentFrameSuggestion() -> NSRect                             // AC-4 多屏 fallback

    // Internal
    private func canonicalKey(_ path: String) -> String                 // 见下（← 修订自 TC-REVIEW D-4）
    private func persistFrame(_ frame: NSRect)                          // UserDefaults
    private func loadFrameFromDefaults() -> NSRect?
    private func screenVisibility(for origin: NSPoint) -> Bool          // NSScreen.screens 遍历
}
```

**canonicalKey 规范化（← 修订自 TC-REVIEW D-4）**：

`standardizedFileURL` 不 resolve symlink，`~/proj/README.md` 和 `~/proj-symlink/README.md`（symlink 指向同一文件）会被视为不同 key，违反 AC-2。固定实现：

```swift
private func canonicalKey(_ path: String) -> String {
    URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()        // 解 symlink + ~
        .standardizedFileURL              // 吃掉 ../ 与 ./
        .path
}
```

副作用在 §14 风险表补：APFS clone / iCloud 同步目录 inode 变动更频繁，可能触发更多 reattach。

关键点：
- `showWindow(for:)` 命中 existing（AC-2，**← 修订自 TC-REVIEW D-5**）：
  ```swift
  if let ctrl = controllers[canonicalKey(filePath)] {
      ctrl.window?.collectionBehavior.insert(.moveToActiveSpace)   // AC-D3 Spaces 切换跟随
      ctrl.window?.makeKeyAndOrderFront(nil)
      ctrl.window?.orderFrontRegardless()                           // 兜底：跨 Space 聚焦
      NSApp.activate(ignoringOtherApps: false)                      // 不抢 app focus（CLAUDE.md socket focus policy 同口径）
      return ctrl
  }
  ```
  注：`collectionBehavior.insert` 幂等；`orderFrontRegardless` 仅影响该窗口 level，不破坏 AppKit key window 语义。
- 未命中：先 `currentFrameSuggestion()` 拿 frame → 创建 controller → `controllers[canonicalKey(filePath)] = controller` → `controller.showWindow(nil)`。
- `detach`：在回调里更新 `lastSavedFrame = controller.window?.frame` → 写 `UserDefaults` → `controllers.removeValue(forKey:)`；**不** 释放 `processPool`（AC-24 / AC-31，§10.1）。

### 2.1.1 DEBUG-only test seams（← 修订自 TC-REVIEW B-5 / E-1）

UITest helper（TEST-PLAN §3.1）+ Case 46（pool identity）需要 Manager 对外可观测。全部包裹 `#if DEBUG`，release 零体积：

```swift
#if DEBUG
extension MarkdownViewerWindowManager {
    /// Case 46：断言两次 showWindow 之间 pool 是同一实例（AC-24）。
    var __test_processPoolIdentity: ObjectIdentifier { ObjectIdentifier(processPool) }

    /// UITest 隔离：下一个 case 开始前强制 reset pool，避免上一个 case 的 webView state 污染。
    func __test_teardownPool() {
        processPool = WKProcessPool()
    }

    /// TEST-PLAN §3.1 R-2：按 path 拿 controller 做断言。
    func __test_controller(for path: String) -> MarkdownViewerWindowController? {
        controllers[canonicalKey(path)]
    }

    /// 整体快照。
    var __test_activeControllers: [String: MarkdownViewerWindowController] { controllers }
}
#endif
```

QA Lead 在 TEST-PLAN §3.1 签字锁定这些 API 名字后再改动；改名需同步 TEST-PLAN。

### 2.2 `MarkdownViewerWindowController`

```swift
@MainActor
final class MarkdownViewerWindowController: NSWindowController,
    NSWindowDelegate, WKNavigationDelegate {

    let filePath: String
    private weak var manager: MarkdownViewerWindowManager?
    private let fileSource: MarkdownViewerFileSource
    private let bridge: MarkdownViewerWebBridge
    private var webView: WKWebView!
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    init(filePath: String,
         processPool: WKProcessPool,
         manager: MarkdownViewerWindowManager,
         initialFrame: NSRect)

    // Lifecycle
    override func windowDidLoad()                       // 构造 WKWebView，load viewer.html
    func windowWillClose(_ note: Notification)          // teardown 顺序见 §3
    func windowDidBecomeKey(_ note: Notification)       // key-window dlog

    // WKNavigationDelegate
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
    func webView(_ webView: WKWebView,
                 didFinish navigation: WKNavigation!)   // 注水首次 render

    // Bridge 回调（由 MarkdownViewerWebBridge 反转）
    func handleOpenExternal(_ urlString: String)
    func handleMermaidRenderError(count: Int, messages: [String])
    func handleFileReloadAck(strategy: String, anchorId: String?)
    func handleViewportStateSync(_ state: [String: Any])

    // Theme
    private func observeAppearance()
    private func postThemeMessage(isDark: Bool)         // evaluateJavaScript("window.cmux.applyTheme(...)")
}
```

### 2.3 `MarkdownViewerWebBridge`

```swift
@MainActor
final class MarkdownViewerWebBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "cmux"                     // window.webkit.messageHandlers.cmux.postMessage
    weak var controller: MarkdownViewerWindowController?

    private let parseQueue = DispatchQueue(
        label: "com.cmux.markdownViewer.bridge",
        qos: .userInitiated
    )

    nonisolated func userContentController(_ ucc: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        // 主线程快速拿 body → 立即 hop 到 parseQueue
        let body = message.body
        parseQueue.async { [weak self] in
            guard let msg = Self.decode(body) else { return }
            self?.route(msg)                            // main 分派见下
        }
    }

    // internal
    private static func decode(_ raw: Any) -> BridgeMessage?
    private func route(_ msg: BridgeMessage)            // 按 kind 决定是否 DispatchQueue.main.async
}

enum BridgeMessage {
    case openExternal(url: String)
    case mermaidRenderError(count: Int, messages: [String])
    case fileReloadAck(strategy: String, anchorId: String?)
    case viewportStateSync(anchorId: String?, offsetInAnchor: Double?, scrollTopRatio: Double?)
    case copyCode(text: String)
    case exportMermaidSVG(nodeId: String)               // 本期占位
}
```

### 2.4 `MarkdownViewerFileSource`

```swift
enum MarkdownViewerFileState: Equatable {
    case loading
    case loaded(content: String, truncated: Bool, isEmpty: Bool)
    case unavailable(reason: Reason)                    // .encoding / .missing / .io
    case deleted

    enum Reason { case encoding, missing, io }
}

final class MarkdownViewerFileSource: ObservableObject {
    @Published private(set) var state: MarkdownViewerFileState = .loading
    let filePath: String
    private static let byteLimit: Int = 10 * 1024 * 1024      // AC-21

    // lifecycle
    init(filePath: String)
    func close()                                        // cancel watcher + flag

    // internals
    private nonisolated(unsafe) var watchSource: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var isClosed = false
    private let queue = DispatchQueue(
        label: "com.cmux.markdownViewer.fs",
        qos: .utility
    )
    private static let maxReattach = 6
    private static let reattachDelay: TimeInterval = 0.5

    private func loadContent()                          // see §9
    private func startWatcher()
    private func scheduleReattach(attempt: Int)
    private func stopWatcher()
}
```

### 2.5 Public / Internal 分层

| 层 | 暴露对象 | 访问级 |
|---|---|---|
| App 入口 | `MarkdownViewerWindowManager.shared.showWindow(for:)` | `public` (within module) |
| 调试 / 埋点 | dlog 事件字符串常量 | `internal` |
| 其他（Controller / Bridge / FileSource / Payload / ContentRules） | 仅在 `MarkdownViewer/` 内部协作 | `internal` / `fileprivate` |

外部入口仅一个函数：`showWindow(for:)`。所有其他类型不暴露给 `Sources/` 其他模块。

---

## 3. 生命周期与线程

### 3.1 时序图（ASCII）

```
Workspace.openFileFromExplorer(.md)
  │
  ▼ (main actor)
Manager.showWindow(for: path)
  ├── hit existing? yes → controller.window.makeKeyAndOrderFront  [END]
  └── no:
       ├── frame = currentFrameSuggestion()    (AC-4 + 多屏 fallback)
       ├── controller = MarkdownViewerWindowController(
       │       filePath, processPool, manager, initialFrame: frame)
       ├── controllers[canonicalKey] = controller
       ├── controller.showWindow(nil)
       │    └─ Controller.windowDidLoad
       │         ├─ build WKWebView (config 详见 §4)
       │         ├─ bridge.controller = self
       │         ├─ FileSource = MarkdownViewerFileSource(filePath)
       │         ├─ subscribe FileSource.$state → updateWebView(state)
       │         ├─ observe effectiveAppearance (KVO)
       │         └─ webView.loadFileURL(viewer.html, allowingReadAccessTo: resourceDir)
       │              └─ didFinish → evaluate "window.cmux.boot(payload)"
```

### 3.2 关闭时序（`windowWillClose`）

严格顺序，**禁止重排**：

```
1. isClosing = true              // 阻止未来 evaluateJavaScript 入队
2. fileSource.close()             // cancel DispatchSource → close(fd)
3. cancellables.removeAll()       // 断开 Combine 订阅
4. appearanceObservation?.invalidate()
5. webView.configuration.userContentController
        .removeScriptMessageHandler(forName: MarkdownViewerWebBridge.handlerName)
6. webView.navigationDelegate = nil
7. webView.stopLoading()
8. webView.removeFromSuperview()
9. manager?.detach(self)          // 从 dict 删除 + 持久化 frame
10. dlog("markdownViewer.close path=\(filePath)")
```

`detach` 只做字典删除 + 持久化；不持有 controller 强引用故 ARC 可回收。

### 3.3 Thread 归属汇总

| 活动 | Queue |
|---|---|
| Manager / Controller 所有公共 API | `@MainActor` |
| WKWebView, NSWindow 操作 | `@MainActor` |
| FileSource DispatchSource 回调 | `queue`（`com.cmux.markdownViewer.fs`） → `DispatchQueue.main.async` hop |
| Bridge parse & dedupe | `parseQueue`（`com.cmux.markdownViewer.bridge`） |
| Bridge → Controller 回调 | 分路由：`openExternal` / `copyCode` / `exportMermaidSVG` 走 `DispatchQueue.main.async`；`mermaidRenderError` / `fileReloadAck` / `viewportStateSync` 停留在 parseQueue（仅 dlog + 内存变量） |

### 3.4 Watcher reattach（AC-20）

沿用 `MarkdownPanel` 语义（R-3 方案 A「参考但独立实现」）：

- `.delete` / `.rename` event：`stopWatcher` → `loadContent`。
  - 若仍 unavailable：`scheduleReattach(attempt: 1)`，最多 6 次 × 0.5s（3s 总窗口）。
  - 若已可读（原子保存）：直接 `startWatcher()` 重连新 inode。
- `.write` / `.extend`：单次 `loadContent()`。
- Reattach 成功（文件重现）：state 从 `.deleted` → `.loaded`，JS 侧按 AC-19 恢复滚动（首次 ratio=0，因 DOM 全新）。

---

## 4. WKWebView 配置

### 4.1 配置构造

```swift
private func makeWebView(processPool: WKProcessPool) -> WKWebView {
    let prefs = WKPreferences()
    prefs.javaScriptCanOpenWindowsAutomatically = false
    // macOS 11+ 用 WKWebpagePreferences 控制 JS 开关；默认开即可
    let webpagePrefs = WKWebpagePreferences()
    webpagePrefs.allowsContentJavaScript = true

    let ucc = WKUserContentController()
    ucc.add(bridge, name: MarkdownViewerWebBridge.handlerName)

    // Inject l10n + boot helpers BEFORE viewer.js runs
    let bootstrap = makeBootstrapUserScript()               // §5.1
    ucc.addUserScript(bootstrap)

    let config = WKWebViewConfiguration()
    config.processPool = processPool                        // AC-24 / AC-31
    config.preferences = prefs
    config.defaultWebpagePreferences = webpagePrefs
    config.userContentController = ucc
    config.suppressesIncrementalRendering = false
    config.mediaTypesRequiringUserActionForPlayback = .all
    // 禁止 WebView 自行打开 popup
    config.limitsNavigationsToAppBoundDomains = false

    // ContentRuleList 双保险（A-5）
    if let rules = cachedRules { config.userContentController.add(rules) }

    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = self
    view.uiDelegate = nil                                    // 不打开 new window
    view.allowsBackForwardNavigationGestures = false
    view.setValue(false, forKey: "drawsBackground")          // 背景由 CSS 控制
    return view
}
```

### 4.2 loadFileURL

```swift
let bundle = Bundle.main
guard
    let htmlURL = bundle.url(forResource: "viewer",
                              withExtension: "html",
                              subdirectory: "MarkdownViewer"),
    let resourceDir = htmlURL.deletingLastPathComponent()
                              .resolvingSymlinksInPath() as URL?
else { fatalError("MarkdownViewer resources missing") }

webView.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
```

**读权限仅授予 `Resources/MarkdownViewer/`**（R-2 方案 1）。md 原文以字符串注水，不 `file://` 加载。用户 md 所在目录不授权。

### 4.3 WKContentRuleList（A-5）

`MarkdownViewerContentRules.sharedRuleList()` 返回编译好的规则，JSON：

```json
[
  { "trigger": { "url-filter": "^https?://",       "resource-type": ["image","raw","font","media","script","style-sheet","fetch","websocket"] }, "action": { "type": "block" } },
  { "trigger": { "url-filter": "^wss?://",         "resource-type": ["fetch","websocket","raw"] },                                               "action": { "type": "block" } },
  { "trigger": { "url-filter": "^ftp://",          "resource-type": ["raw","fetch"] },                                                            "action": { "type": "block" } },
  { "trigger": { "url-filter": "^data:",           "resource-type": ["fetch","websocket","script"] },                                             "action": { "type": "block" } }
]
```

说明：
- `data:` 的图片（`image`）不拦截（md 内 base64 png 需要）。
- `file:` / `about:` 未列入 → 默认放行。
- 通过 `WKContentRuleListStore.default().compileContentRuleList(...)` 首次编译，缓存到内存（非持久化，避免启动 IO）。

### 4.4 decidePolicyFor 决策树

```swift
func webView(_ wv: WKWebView,
             decidePolicyFor action: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url
    let type = action.navigationType

    // 1. 顶层导航：仅允许首次 viewer.html
    if action.targetFrame?.isMainFrame == true, type == .other,
       url?.scheme == "file",
       url?.lastPathComponent == "viewer.html" {
        return decisionHandler(.allow)
    }

    // 2. 用户点击链接（anchor / external）→ 交给 bridge
    if type == .linkActivated {
        if let u = url {
            // 锚点（#fragment）JS 已自行滚动，这里仅在真的 navigation 时出现
            if u.scheme == "file", u.fragment != nil,
               u.deletingFragment() == wv.url?.deletingFragment() {
                return decisionHandler(.allow)            // 同文档锚点，AC-16
            }
            controller?.handleOpenExternal(u.absoluteString)  // AC-17 / AC-18
        }
        return decisionHandler(.cancel)
    }

    // 3. 子资源：仅 file: / about: / data: 允许
    if let scheme = url?.scheme {
        switch scheme {
        case "file", "about", "data": return decisionHandler(.allow)
        default:
            #if DEBUG
            dlog("markdownViewer.block scheme=\(scheme) url=\(url?.absoluteString ?? "")")
            #endif
            return decisionHandler(.cancel)                // AC-28 拦截
        }
    }

    decisionHandler(.cancel)
}
```

---

## 5. JS 模块

### 5.1 Bootstrap user script（Swift 侧）

```swift
private func makeBootstrapUserScript() -> WKUserScript {
    let strings = MarkdownViewerStrings.all()              // [key: localized]
    let json = try! JSONEncoder().encode(strings)
    let injected = String(data: json, encoding: .utf8)!

    let src = """
    window.cmux = window.cmux || {};
    window.cmux.strings = \(injected);
    window.cmux.l10n = function(key, fallback){
        return (window.cmux.strings[key] ?? fallback ?? key);
    };
    window.cmux.postMessage = function(obj){
        try { window.webkit.messageHandlers.cmux.postMessage(obj); } catch(e) {}
    };
    """
    return WKUserScript(source: src,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true)
}
```

### 5.2 `viewer.html` 骨架

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Markdown Viewer</title>
  <link rel="stylesheet" href="viewer.css">
  <script src="vendor/marked.min.js"></script>
  <script src="vendor/highlight.min.js"></script>
  <!-- mermaid 延迟注入：viewer.js 首次遇到 mermaid block 才动态 append -->
</head>
<body>
  <header class="viewer-chrome">
    <div class="truncate-banner" hidden>
      <span class="icon">⚠</span>
      <span class="msg" data-l10n-key="markdownViewer.file.truncated"></span>
    </div>
    <div class="breadcrumb" id="viewer-breadcrumb"></div>
  </header>
  <main id="viewer-content" class="viewer-content"></main>
  <div id="viewer-empty" class="viewer-empty" hidden></div>
  <script src="viewer.js"></script>
</body>
</html>
```

### 5.3 `viewer.js` 职责

对外 API（暴露在 `window.cmux` 下）：

```js
window.cmux.boot(payload)            // 首次 / 后续 rerender 入口
window.cmux.applyTheme("dark"|"light")
window.cmux.renderMarkdown(text, filePath, options)  // internal use
window.cmux.restoreViewport(state)   // 滚动恢复（anchor/ratio）
window.cmux.captureViewport()        // return {anchorId, offsetInAnchor, scrollTopRatio}
```

payload shape（由 Swift 构造）：
```js
{
  filePath: "/abs/path/to/README.md",
  displayName: "README.md",
  content: "...",          // 可能 truncated，已做 10MB 限制
  truncated: false,
  isEmpty: false,
  state: "loaded" | "deleted" | "unavailable",
  reason?: "encoding" | "missing" | "io",
  theme: "light" | "dark",
  restoreHint?: { anchorId: "...", offsetInAnchor: 0.1, scrollTopRatio: 0.42 }
}
```

#### 渲染管线

```
boot(payload):
  applyTheme(payload.theme)
  setBreadcrumb(payload.filePath)
  toggleTruncateBanner(payload.truncated)
  switch payload.state:
    .deleted → showEmptyState("markdownViewer.file.deleted",
                              hint="markdownViewer.file.deleted.hint")
    .unavailable → showEmptyState("markdownViewer.file.unavailable", path=payload.filePath)
    .loaded, isEmpty → showEmptyState("markdownViewer.file.empty")
    .loaded, !isEmpty →
       const pre = capturePrevViewport()     // 若已有旧 DOM，保存锚点
       const html = marked.parse(payload.content, { gfm: true, breaks: false })
       const fragment = sanitizeAndPostProcess(html, payload.filePath)
                         //  - 本地 <img> → <a class="local-image"> (AC-32)
                         //  - 外链 <img src="https?://"> → 注释占位 (AC-28)
                         //  - <a href="http(s)"> / relative → data-external=1
       #viewer-content.replaceChildren(fragment)
       runHighlightOnCodeBlocks()
       maybeInitMermaidAndRender()          // 懒加载
       restoreViewport(payload.restoreHint ?? pre)
       postMessage({ kind:"fileReloadAck",
                     strategy: usedAnchor?"anchor":"ratio",
                     anchorId: usedId })
```

#### Mermaid 懒初始化

```js
let mermaidReady = null;
function maybeInitMermaidAndRender() {
  const blocks = document.querySelectorAll('pre > code.language-mermaid, pre > code[data-bare-mermaid]');
  if (blocks.length === 0) return;

  if (!mermaidReady) {
    mermaidReady = new Promise((resolve) => {
      const s = document.createElement('script');
      s.src = 'vendor/mermaid.min.js';
      s.onload = () => {
        window.mermaid.initialize({
          startOnLoad: false,
          theme: currentTheme === 'dark' ? 'dark' : 'default',
          securityLevel: 'strict',
          fontFamily: '-apple-system, "SF Pro Text", sans-serif'
        });
        resolve();
      };
      document.head.appendChild(s);
    });
  }

  mermaidReady.then(() => renderMermaidBlocks(blocks));
}
```

`renderMermaidBlocks`：每块 try/catch，失败 → 容器加 `.is-error` + fallback `<pre>` + `postMessage({kind:"mermaidRenderError", count, messages})`。

#### Highlight

- `hljs.highlightAuto(code)` or `hljs.highlight(code, {language})`（若 info string 指定）。
- 语言标签取自 `<code>` 的 `language-xxx` class；渲染为 `pre::before` 伪元素。

#### 滚动恢复

```js
function captureViewport() {
  const headings = document.querySelectorAll('#viewer-content h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]');
  let anchor = null, minTop = -Infinity;
  for (const h of headings) {
    const top = h.getBoundingClientRect().top;
    if (top <= 0 && top > minTop) { minTop = top; anchor = h; }
  }
  if (anchor) {
    const rect = anchor.getBoundingClientRect();
    return {
      anchorId: anchor.id,
      offsetInAnchor: (0 - rect.top) / Math.max(1, window.innerHeight)
    };
  }
  return {
    scrollTopRatio: window.scrollY / Math.max(1, document.body.scrollHeight)
  };
}

function restoreViewport(state) {
  if (!state) return 'none';
  if (state.anchorId) {
    const el = document.getElementById(state.anchorId);
    if (el) {
      el.scrollIntoView({ block: 'start' });
      window.scrollBy(0, (state.offsetInAnchor ?? 0) * window.innerHeight);
      return 'anchor';
    }
  }
  if (state.scrollTopRatio != null) {
    window.scrollTo(0, state.scrollTopRatio * document.body.scrollHeight);
    return 'ratio';
  }
  return 'none';
}
```

### 5.4 `viewer.css`

Light token 映射（片段）：

```css
:root {
  --bg:#FAFAFA; --bg-soft:#EDEDED; --bg-raise:#FFFFFF;
  --fg:#1E1E1E; --fg-strong:#000; --fg-muted:#666;
  --divider:#E0E0E0; --divider-strong:#C8C8C8;
  --accent:#0A7BFF; --accent-soft:rgba(10,123,255,.55);
  --link:#0A63DF;
  --code-inline-fg:#6A1F9E; --code-inline-bg:#EBE8EB;
  --code-block-fg:#333;     --code-block-bg:#EDEDED;
  --banner-warn-bg:#FFF4D6; --banner-warn-fg:#6B4E00; --banner-warn-border:#EBD48A;
  --danger-bg:#FFECEC;      --danger-fg:#B3261E;      --danger-border:#E9A7A2;
  --hl-keyword:#A71D5D; --hl-string:#0A3069; --hl-comment:#6A737D;
  --hl-number:#005CC5; --hl-type:#6F42C1;   --hl-function:#6F42C1;
}
html.dark {
  --bg:#1F1F1F; --bg-soft:#2B2B2B; --bg-raise:#242424;
  --fg:#EAEAEA; --fg-strong:#FFF; --fg-muted:#A0A0A0;
  --divider:#333; --divider-strong:#444;
  --accent:#4FA3FF; --accent-soft:rgba(79,163,255,.55);
  --link:#6EB5FF;
  --code-inline-fg:#E5A8FF; --code-inline-bg:#2E2E2E;
  --code-block-fg:#E6E6E6;  --code-block-bg:#141414;
  --banner-warn-bg:#3A3420; --banner-warn-fg:#F5D877; --banner-warn-border:#5A4E20;
  --danger-bg:#3A1F1F;      --danger-fg:#FF9E9A;      --danger-border:#6B2F2B;
  --hl-keyword:#F97583; --hl-string:#9ECBFF; --hl-comment:#8B949E;
  --hl-number:#79B8FF;  --hl-type:#B392F0;  --hl-function:#B392F0;
}
```

UI.md §3 / §4 / §6 / §8 / §9 中 CSS 片段全部直接搬运到 `viewer.css`。

---

## 6. Bridge 消息协议

### 6.1 统一 schema

所有消息均为 JS 对象（`postMessage` body 为 object）：

```ts
type BridgeMsg =
  | { kind: "openExternal",        url: string }
  | { kind: "mermaidRenderError",  count: number, messages: string[] }
  | { kind: "fileReloadAck",       strategy: "anchor"|"ratio"|"none", anchorId?: string }
  | { kind: "viewportStateSync",   anchorId?: string, offsetInAnchor?: number, scrollTopRatio?: number }
  | { kind: "copyCode",            text: string }
  | { kind: "exportMermaidSVG",    nodeId: string }   // 本期占位，native 返回 NOT_IMPLEMENTED dlog
```

### 6.2 消息表

| kind | 线程 | Validator | 动作 | 失败处理 |
|---|---|---|---|---|
| `openExternal` | main | 必填 url；scheme ∈ `http/https/file/mailto`；其余 reject | `NSWorkspace.shared.open(URL)`；dlog `markdownViewer.webNav url=<u> action=open-external` | scheme 非白名单 → dlog drop，不弹 alert |
| `mermaidRenderError` | off-main（parseQueue） | count: Int ≥ 0；messages: [String]，截断到首 3 条 | dlog `markdownViewer.mermaid renderErrors=<n> path=<p>` | 字段缺失 → drop |
| `fileReloadAck` | off-main | strategy ∈ {anchor, ratio, none} | dlog `markdownViewer.fileReload path=<p> strategy=<s>` | drop |
| `viewportStateSync` | off-main | at least one of anchorId / scrollTopRatio | 覆盖 `controller.lastViewportSnapshot`（由 `handleViewportStateSync` main-hop 写入 controller）；**为避免 race，当前策略：JS 在 rerender 前自持，native 不必存**——本期选择**仅 dlog**，native 不缓存 | — |
| `copyCode` | main | text length ≤ 256KB | `NSPasteboard.general.clearContents(); setString(text, forType: .string)`；dlog | text 超限 → truncate + warn |
| `exportMermaidSVG` | main | nodeId 非空 | dlog `markdownViewer.exportMermaidSVG.notImplemented nodeId=<id>` | 始终返回（本期占位） |

### 6.3 错误 handling

- decode 失败：parseQueue 内静默 drop + dlog（DEBUG）。
- 非预期 kind：drop。
- `handleOpenExternal` 中 URL(string:) 为 nil：drop + dlog。

### 6.4 反向通道（Native → JS）

Swift 通过 `webView.evaluateJavaScript("window.cmux.<fn>(<arg>)", completionHandler:)`：

| 场景 | JS 调用 | 时机 |
|---|---|---|
| 首次渲染 / rerender | `window.cmux.boot(payload)` | `webView(didFinish:)` 后 + FileSource.$state 变化 |
| 主题切换 | `window.cmux.applyTheme("dark")` | `effectiveAppearance` KVO |
| truncate banner toggle | 通过 `boot(payload.truncated)` 一次性 | — |

所有 `evaluateJavaScript` 调用前检查 `isClosing`。

---

## 7. 资源管理与 Build 配置

### 7.1 pbxproj 改动（步骤化）

1. 在 Xcode 打开 `GhosttyTabs.xcodeproj`。
2. 右键 `Sources/` group → `New Group from Folder` → 选 `Sources/MarkdownViewer/`（确保是 group 而非 folder ref，这样 Swift 源文件可被 compile phase 拾取）。结果：每个 `.swift` 加入 cmux target 的 Compile Sources。
3. 右键 `Resources/` group → `Add Files to "cmux"...` → 选 `Resources/MarkdownViewer/` → **Options**：勾选 `Create folder references`（蓝色文件夹）、`Add to targets: cmux`。结果：`MarkdownViewer/` 整个子树进入 Copy Bundle Resources，保留目录结构（`vendor/`、`viewer.html` 等），运行时通过 `Bundle.main.url(forResource:withExtension:subdirectory:"MarkdownViewer")` 访问。
4. 验证：`xcodebuild -target cmux -showBuildSettings | grep -E '(COMPILE_SOURCES|COPY_PHASE_STRIP)'` 无异；构建后 `ls "$APP/Contents/Resources/MarkdownViewer/"` 应含 `viewer.html` + `vendor/`。
5. commit pbxproj diff；PR reviewer 注意 folder ref 的 `lastKnownFileType = folder;` 字段。

### 7.2 `scripts/fetch-markdown-viewer-vendor.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/Resources/MarkdownViewer/vendor"
LOCK="$ROOT/Resources/MarkdownViewer/vendor.lock.json"
mkdir -p "$DST"

fetch() {
  local name="$1" version="$2" url="$3" out="$4"
  echo "Fetching $name@$version → $out"
  curl -fsSL -o "$DST/$out" "$url"
}

fetch marked      14.1.3  "https://cdn.jsdelivr.net/npm/marked@14.1.3/marked.min.js"                   marked.min.js
fetch mermaid     10.9.3  "https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js"           mermaid.min.js
fetch highlightjs 11.10.0 "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/highlight.min.js" highlight.min.js

python3 - "$DST" "$LOCK" <<'PY'
import hashlib, json, os, sys
dst, lock = sys.argv[1], sys.argv[2]
entries = [
  ("marked",      "14.1.3",  "marked.min.js",    "https://cdn.jsdelivr.net/npm/marked@14.1.3/marked.min.js"),
  ("mermaid",     "10.9.3",  "mermaid.min.js",   "https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js"),
  ("highlightjs", "11.10.0", "highlight.min.js", "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/highlight.min.js"),
]
out = []
for name, ver, fn, url in entries:
  p = os.path.join(dst, fn)
  with open(p, "rb") as f: data = f.read()
  out.append({
    "name": name, "version": ver, "filename": fn,
    "sha256": hashlib.sha256(data).hexdigest(),
    "sourceUrl": url, "bytes": len(data),
  })
with open(lock, "w") as f: json.dump(out, f, indent=2, sort_keys=True)
print("wrote", lock)
PY
echo "Done. Commit Resources/MarkdownViewer/vendor/* and vendor.lock.json."
```

### 7.3 `scripts/verify-markdown-viewer-vendor.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/Resources/MarkdownViewer/vendor"
LOCK="$ROOT/Resources/MarkdownViewer/vendor.lock.json"
[[ -d "$DIR" && -f "$LOCK" ]] || { echo "markdown-viewer vendor missing" >&2; exit 1; }

python3 - "$DIR" "$LOCK" <<'PY'
import hashlib, json, os, sys
dir_, lock = sys.argv[1], sys.argv[2]
with open(lock) as f: entries = json.load(f)
TOTAL_LIMIT = 5 * 1024 * 1024      # AC-26
total = 0
fail = False
for e in entries:
    p = os.path.join(dir_, e["filename"])
    if not os.path.isfile(p):
        print(f"MISSING: {p}", file=sys.stderr); fail = True; continue
    with open(p, "rb") as f: data = f.read()
    got = hashlib.sha256(data).hexdigest()
    if got != e["sha256"]:
        print(f"MISMATCH {e['filename']}: want {e['sha256']} got {got}", file=sys.stderr)
        fail = True
    if len(data) != e["bytes"]:
        print(f"SIZE MISMATCH {e['filename']}: want {e['bytes']} got {len(data)}", file=sys.stderr)
        fail = True
    total += len(data)
if total > TOTAL_LIMIT:
    print(f"TOTAL {total} exceeds {TOTAL_LIMIT} (AC-26)", file=sys.stderr)
    fail = True
if fail: sys.exit(1)
print(f"markdown-viewer vendor ok, total={total}B")
PY
```

### 7.4 `vendor.lock.json` 示例

```json
[
  {
    "name": "marked", "version": "14.1.3", "filename": "marked.min.js",
    "sha256": "<FILL_AFTER_FETCH>", "bytes": 0,
    "sourceUrl": "https://cdn.jsdelivr.net/npm/marked@14.1.3/marked.min.js"
  },
  {
    "name": "mermaid", "version": "10.9.3", "filename": "mermaid.min.js",
    "sha256": "<FILL_AFTER_FETCH>", "bytes": 0,
    "sourceUrl": "https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js"
  },
  {
    "name": "highlightjs", "version": "11.10.0", "filename": "highlight.min.js",
    "sha256": "<FILL_AFTER_FETCH>", "bytes": 0,
    "sourceUrl": "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/highlight.min.js"
  }
]
```

`bytes` / `sha256` 由首次 `fetch-markdown-viewer-vendor.sh` 运行产生，人工 commit。

### 7.5 release-pretag-guard 挂载

当前 `scripts/release-pretag-guard.sh` 只有一行 sparkle 检查。追加：

```bash
"$ROOT_DIR/scripts/verify-markdown-viewer-vendor.sh"
```

放在 sparkle 检查之后（顺序无依赖，但先验体积）。

---

## 8. 入口改造

### 8.1 Workspace.swift 差异

当前（`Sources/Workspace.swift:9276-9285`）：

```swift
@discardableResult
func openFileFromExplorer(filePath: String) -> Bool {
    let ext = (filePath as NSString).pathExtension.lowercased()
    let isMarkdown = ext == "md" || ext == "markdown"
    if isMarkdown, let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first {
        _ = newMarkdownSurface(inPane: paneId, filePath: filePath, focus: true)
        return true
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
    return false
}
```

改为：

```swift
@discardableResult
func openFileFromExplorer(filePath: String) -> Bool {
    let ext = (filePath as NSString).pathExtension.lowercased()
    let isMarkdown = ext == "md" || ext == "markdown"
    if isMarkdown {
        MarkdownViewerWindowManager.shared.showWindow(for: filePath)
        #if DEBUG
        dlog("markdownViewer.open path=\(filePath) source=fileExplorer")
        #endif
        return true        // 注意：语义从 "panel was created" 变为 "we handled it"。
                           // 当前唯一 caller (cmuxApp.swift:357) 不检查返回值，安全。
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
    return false
}
```

`newMarkdownSurface(inPane:filePath:focus:)` 及 `installMarkdownPanelSubscription(_:)` **保留**（session restore / 内部 API 仍可用；冻结含义：无新入口调用）。

### 8.2 `cmuxApp.swift`

无需修改（observer 已存在；`workspace.openFileFromExplorer(filePath:)` 继续调用）。

---

## 9. 错误与容错

### 9.1 10MB 截断（AC-21）

`FileHandle` 零拷贝分段读：

```swift
private func loadContent() {
    guard !isClosed else { return }

    let fm = FileManager.default
    guard fm.fileExists(atPath: filePath) else {
        publish(.deleted); return
    }
    let attr = try? fm.attributesOfItem(atPath: filePath)
    let size = (attr?[.size] as? NSNumber)?.intValue ?? 0
    let isEmpty = (size == 0)
    let truncated = size > Self.byteLimit

    do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }
        let data: Data = try {
            if truncated {
                if #available(macOS 11, *) {
                    return try handle.read(upToCount: Self.byteLimit) ?? Data()
                } else {
                    return handle.readData(ofLength: Self.byteLimit)
                }
            } else {
                if #available(macOS 11, *) {
                    return try handle.readToEnd() ?? Data()
                } else {
                    return handle.readDataToEndOfFile()
                }
            }
        }()
        let text = String(data: data, encoding: .utf8)
                 ?? String(data: data, encoding: .isoLatin1)      // AC-22
        guard let content = text else {
            publish(.unavailable(reason: .encoding)); return
        }
        publish(.loaded(content: content, truncated: truncated, isEmpty: isEmpty))
        #if DEBUG
        if truncated { dlog("markdownViewer.fileTruncated path=\(filePath) size=\(size)") }
        #endif
    } catch {
        publish(.unavailable(reason: .io))
    }
}

private func publish(_ new: MarkdownViewerFileState) {
    DispatchQueue.main.async { [weak self] in
        guard let self, !self.isClosed else { return }
        self.state = new
    }
}
```

### 9.2 编码 fallback（AC-22）

见上：UTF-8 → ISO Latin-1 → `.encoding` 失败态。**不 import `MarkdownPanel`**（R-3 方案 A）。

### 9.3 Mermaid 渲染错误（AC-12）

JS 侧：

```js
async function renderMermaidBlocks(blocks) {
  const errors = [];
  for (const code of blocks) {
    const wrap = code.closest('pre').replaceWith(makeMermaidWrap()); // 每块替换为容器
    const wrapEl = /* 新容器 */;
    try {
      const { svg } = await window.mermaid.render(genId(), code.textContent);
      wrapEl.innerHTML = svg;
    } catch (e) {
      wrapEl.classList.add('is-error');
      wrapEl.innerHTML =
        `<div class="msg">${window.cmux.l10n("markdownViewer.mermaid.error")}</div>` +
        `<pre>${escapeHtml(code.textContent)}</pre>`;
      errors.push(String(e?.message ?? e));
    }
  }
  if (errors.length) {
    window.cmux.postMessage({ kind:"mermaidRenderError", count: errors.length, messages: errors.slice(0, 3) });
  }
}
```

每块独立 try/catch → 一个错块不影响其他块（AC-12「不崩溃整个页面」）。

### 9.4 Watcher reattach

见 §3.4。实现参考 `Sources/Panels/MarkdownPanel.swift:107-168`（**读**不改）。

---

## 10. 性能落地

### 10.1 WKProcessPool 预热（AC-23 / AC-24）

**本期做「持久复用」，不做「启动预热」**：

- Manager 在首次 `showWindow` 时创建 `WKProcessPool`，整个进程生命周期保留。
- 关闭最后一个 viewer 时不释放 pool（pool 不持有 WebView，内存 ~0）。
- **不**在 app 启动 idle time 跑 off-screen webview（avoid 首屏风险 + typing latency）。降级方案：若 AC-23 冷启动实测 > 500ms，再开启 `enablePoolPrewarm` 默认关 feature flag，idle 一段 secs 后 create-and-destroy 一个隐藏 WebView。

### 10.2 Mermaid 懒初始化（AC-25）

见 §5.3：只有首次遇到 mermaid block 才 `document.createElement('script')` 动态加载 `vendor/mermaid.min.js` 并 `initialize`。无 mermaid 的 md 不承担 4MB 解析成本。

### 10.3 Rerender 节流

FileSource `@Published state` 变化 → Controller `debounce(for: .milliseconds(120))` 合并后调用 `evaluateJavaScript("cmux.boot(...)")`。避免外部编辑器保存连发多次 write event。

```swift
fileSource.$state
  .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
  .sink { [weak self] state in self?.pushPayload(for: state) }
  .store(in: &cancellables)
```

120ms 取值理由：用户可接受 ≤ 200ms 的更新延迟；对连续 `write` 合并收益大。

### 10.4 大文档渲染

- `marked.parse` 单线程 sync：10MB 极值估算 200-400ms。AC-21 截断到 10MB 已是上界。
- mermaid 单图 < 30 节点：< 300ms（AC-25 内可达）。
- DOM 替换用 `replaceChildren(fragment)` 单次批量，避免多次 layout thrash。

---

## 11. 本地化接入

### 11.1 xcstrings 录入

14 个 key（PRD §4 + UI.md §4/§8 扩展，合并去重）：

| key | en | zh-Hans | ja |
|---|---|---|---|
| `markdownViewer.window.titleFallback` | Markdown Viewer | Markdown 预览 | Markdown ビューア |
| `markdownViewer.file.unavailable` | Unable to read file: %@ | 无法读取文件：%@ | ファイルを読み込めません：%@ |
| `markdownViewer.file.deleted` | The file has been deleted. | 文件已被删除。 | ファイルが削除されました。 |
| `markdownViewer.file.deleted.hint` | Waiting for the file to reappear… | 等待文件重新出现… | ファイルの復元を待機中… |
| `markdownViewer.file.truncated` | File too large — showing first 10MB only. | 文件过大 — 仅展示前 10MB。 | ファイルが大きすぎます — 先頭 10MB のみ表示。 |
| `markdownViewer.file.empty` | (empty) | （空文件） | （空） |
| `markdownViewer.mermaid.error` | Failed to render Mermaid diagram. | Mermaid 图渲染失败。 | Mermaid 図のレンダリングに失敗しました。 |
| `markdownViewer.mermaid.loading` | Rendering diagram… | 正在渲染图… | 図を描画中… |
| `markdownViewer.codeblock.copy` | Copy | 复制 | コピー |
| `markdownViewer.codeblock.copied` | Copied | 已复制 | コピー済み |
| `markdownViewer.codeblock.copy.aria` | Copy code to clipboard | 将代码复制到剪贴板 | コードをクリップボードにコピー |
| `markdownViewer.localImage.hint` | (local image · click to open) | （本地图片 · 点击打开） | （ローカル画像・クリックして開く） |
| `markdownViewer.localImage.tooltip` | Open in default app | 在默认应用中打开 | 既定のアプリで開く |
| `markdownViewer.externalImage.blocked` | 🚫 External image blocked: %@ | 🚫 已阻止外链图片：%@ | 🚫 外部画像をブロック：%@ |

（以上日/中译文为 Designer / PM 最终审校前的初稿；录入时以 xcstrings 正式版为准。）

### 11.2 Swift 侧

`MarkdownViewerStrings.all()` 组装字典：

```swift
enum MarkdownViewerStrings {
    static let keys: [String] = [
        "markdownViewer.window.titleFallback",
        "markdownViewer.file.unavailable",
        "markdownViewer.file.deleted",
        "markdownViewer.file.deleted.hint",
        "markdownViewer.file.truncated",
        "markdownViewer.file.empty",
        "markdownViewer.mermaid.error",
        "markdownViewer.mermaid.loading",
        "markdownViewer.codeblock.copy",
        "markdownViewer.codeblock.copied",
        "markdownViewer.codeblock.copy.aria",
        "markdownViewer.localImage.hint",
        "markdownViewer.localImage.tooltip",
        "markdownViewer.externalImage.blocked",
    ]
    static func all() -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, String(localized: String.LocalizationValue($0))) })
    }
    // Swift 侧直接使用
    static var windowTitleFallback: String {
        String(localized: "markdownViewer.window.titleFallback", defaultValue: "Markdown Viewer")
    }
    // ... 其他按需
}
```

### 11.3 JS 侧

一次性注入（§5.1 bootstrap user script）：`window.cmux.strings = {...}`，`window.cmux.l10n(key, fallback)` 就近查表，无跨线程调用。

---

## 12. 埋点接入

所有调用点包裹 `#if DEBUG` / `#endif`，通过 `dlog(...)`（`vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`）。

| 事件 | 触发位置 | 函数 | AC |
|---|---|---|---|
| `markdownViewer.open` | `Workspace.openFileFromExplorer` | if isMarkdown branch 尾部 | AC-1 |
| `markdownViewer.open action=focus-existing` | `MarkdownViewerWindowManager.showWindow` | hit-existing 分支 | AC-2 |
| `markdownViewer.open action=new` | 同上 | new-controller 分支 | AC-1 |
| `markdownViewer.close` | `MarkdownViewerWindowController.windowWillClose` | 关闭时 | AC-3 |
| `markdownViewer.webNav action=open-external` | `MarkdownViewerWebBridge.route(.openExternal)` → `Controller.handleOpenExternal` | main-actor 入口 | AC-17 |
| `markdownViewer.fileReload` | `Controller.handleFileReloadAck` | JS ack 回调 | AC-19 |
| `markdownViewer.fileMissing phase=deleted` | `FileSource.publish(.deleted)` → main hop | deleted 切换 | AC-20 |
| `markdownViewer.fileMissing phase=reappeared` | `FileSource.scheduleReattach` 成功路径 | reappear | AC-20 |
| `markdownViewer.fileTruncated` | `FileSource.loadContent` 判定 truncated | 截断分支 | AC-21 |
| `markdownViewer.mermaid renderErrors=<n>` | `Controller.handleMermaidRenderError` | bridge | AC-12 |
| `markdownViewer.mermaid.used count=<n>` | `Controller` rerender 后由 JS 通过 `fileReloadAck` 携带计数（扩展 payload）或独立消息；本期统一放 `fileReloadAck` 的可选字段 | boot 完成 | AC-9 |
| `markdownViewer.block scheme=<s>` | `decidePolicyFor` cancel 分支 | — | AC-28 |
| `markdownViewer.exportMermaidSVG.notImplemented` | `Controller.handleExportMermaidSVG` | 占位 | — |

每处调用示例：

```swift
#if DEBUG
dlog("markdownViewer.fileReload path=\(filePath) strategy=\(strategy)")
#endif
```

---

## 13. 开发任务分解（Dev Chain）

粒度：7 个 task，每个可独立提交，单 task 改动量 ≤ 300 行（估算）。

### Task 1 — `Vendor 依赖落地 + 校验脚本`
- 文件：`Resources/MarkdownViewer/vendor/{marked,mermaid,highlight}.min.js`（新 binaries）、`Resources/MarkdownViewer/vendor.lock.json`（新）、`scripts/fetch-markdown-viewer-vendor.sh`（新）、`scripts/verify-markdown-viewer-vendor.sh`（新）、`scripts/release-pretag-guard.sh`（改：加一行）
- 依赖：无
- 对应 AC：AC-26 / AC-27
- 提交 artifact：3 个 vendor js、lock 文件、2 个脚本、release-pretag 更新
- 检验：运行 `./scripts/verify-markdown-viewer-vendor.sh` exit 0

### Task 2 — `WKContentRuleList + Bridge 骨架`
- 文件：`Sources/MarkdownViewer/MarkdownViewerContentRules.swift`（新）、`Sources/MarkdownViewer/MarkdownViewerWebBridge.swift`（新，空壳 + 消息 decode）、`Sources/MarkdownViewer/MarkdownViewerPayload.swift`（新）、`Sources/MarkdownViewer/MarkdownViewerStrings.swift`（新）
- 依赖：Task 1（lock 文件定位到 bundle）
- 对应 AC：AC-28（rule list 装载）、AC-12 bridge 消息路由准备、本地化 payload
- 不涉及 UI

### Task 3 — `FileSource（watcher + 10MB + encoding）`
- 文件：`Sources/MarkdownViewer/MarkdownViewerFileSource.swift`（新）
- 依赖：无（参考 MarkdownPanel，但不 import）
- 对应 AC：AC-19 / AC-20 / AC-21 / AC-22
- Unit test 占位（Task 6 补）

### Task 4 — `Viewer 前端（HTML/CSS/JS） + 注水协议`
- 文件：`Resources/MarkdownViewer/viewer.html`、`viewer.css`、`viewer.js`（全部新，folder reference 已由 pbxproj 纳入）
- 依赖：Task 1（vendor 可用）、Task 2（payload schema + bridge）
- 对应 AC：AC-7 / AC-8 / AC-9 / AC-10 / AC-11 / AC-12 / AC-13 / AC-14 / AC-15 / AC-16 / AC-17 / AC-18 / AC-19 / AC-32
- 注意：xcstrings 注入 + mermaid 懒加载 + 滚动恢复

### Task 5 — `WindowController + Manager + 入口改造`
- 文件：`Sources/MarkdownViewer/MarkdownViewerWindowController.swift`（新）、`Sources/MarkdownViewer/MarkdownViewerWindowManager.swift`（新）、`Sources/Workspace.swift`（改 `openFileFromExplorer`）、`GhosttyTabs.xcodeproj/project.pbxproj`（改：Compile Sources + Copy Bundle Resources）
- 依赖：Task 2, 3, 4
- 对应 AC：AC-1 / AC-2 / AC-3 / AC-4 / AC-5 / AC-6 / AC-24 / AC-31 / AC-D1 / AC-D2 / AC-D3 / AC-D4 / AC-D5

### Task 6 — `xcstrings 录入 + 埋点`
- 文件：`Resources/Localizable.xcstrings`（追加 14 key × 3 lang）；各 Swift 文件的 `#if DEBUG` `dlog` 调用点（Controller / Manager / FileSource / Workspace / Bridge）
- 依赖：Task 5
- 对应 AC：AC-12（文案） + §7 埋点 cross-reference 全量

### Task 7 — `测试 + fixtures`
- 文件：`cmuxUITests/MarkdownViewer/*`（新）、`cmuxUITests/Fixtures/MarkdownViewer/*`（basic.md / mermaid_{graph,sequence,class,gantt,pie,state,mindmap,journey}.md / huge_12mb.md / bad_encoding.md / local_image.md / external_image.md）、`cmuxTests/MarkdownViewerFileSourceTests.swift`（新，单元测）
- 依赖：Task 5, 6
- 对应 AC：AC-1 ~ AC-32 全量的 test coverage（测试策略对齐 PRD §10）
- 注意：**不可** 测源码文本 / plist 字段（CLAUDE.md test quality policy）

### 依赖图

```
Task 1 ──┐
Task 2 ──┼─► Task 4 ──┐
Task 3 ──┘            ├─► Task 5 ──► Task 6 ──► Task 7
                      │
          (独立可并)   │
```

Task 2 与 Task 3 可并行；Task 4 依赖 2；Task 5 汇合。

---

## 14. 风险 & 回滚

### 14.1 Mermaid 全量 bundle 引起 App Store 审核问题

**回退路径**：
1. 切换到 mermaid 官方 "mermaid-mini" 或自行 tree-shake 的精简 bundle（~1.5-2MB，仅 flowchart/sequence/class/gantt）。
2. 更新 `vendor.lock.json` 锁定新文件；`fetch-markdown-viewer-vendor.sh` 改 URL。
3. `viewer.js` 对不支持子类型的 mermaid block 走 `.is-error` 路径 + fallback `<pre>`（等于 AC-12 的错误分支）。
4. 新增 xcstrings key `markdownViewer.mermaid.subtypeUnsupported`（仅回退时）。
5. 触发方式：App Store review 拒审邮件 / 实测冷启动 > 500ms 回归（Task 7 signpost 告警）。

### 14.2 WKWebView 冷启动 > 500ms（AC-23 超标）

**降级：启动 idle 预热**：
1. 在 `cmuxApp.swift` `applicationDidFinishLaunching` 之后加入 `DispatchQueue.main.asyncAfter(deadline: .now() + 5)` 调用 `MarkdownViewerWindowManager.shared.prewarmProcessPool()`。
2. `prewarmProcessPool()` 构造一个 off-screen `WKWebView(frame: .zero, configuration: ...)` with the shared pool，`loadFileURL("about:blank", ...)`，`didFinish` 后释放 webview（pool 保留）。
3. 5 秒延迟保证不影响首次 typing latency 与 Ghostty 初始化。
4. 默认关（feature flag `CMUX_MARKDOWN_VIEWER_PREWARM=1` 先灰度），实测达标后开启。

### 14.3 FileSource 行为与 MarkdownPanel 不一致

**QA 对照矩阵**（Task 7 必测项）：

| 场景 | MarkdownPanel 期望 | MarkdownViewerFileSource 期望 | 备注 |
|---|---|---|---|
| 首次加载 UTF-8 | content = 文件文本 | 同 | — |
| 首次加载非 UTF-8（Win-1252） | ISO-Latin-1 decode | 同 | — |
| 编辑器原子保存 | 1-2s 内刷新 | 同 | reattach 策略一致 |
| rm 文件 | `isFileUnavailable=true` | `.deleted` | 语义等价 |
| 删除后重建 | 6×0.5s 内 reappear | 同 | 常量一致 |
| 超 10MB 文件 | 全部加载（Panel 无截断） | 截断到 10MB + banner | **差异**：Viewer 额外规则 |
| 文件锁 / 权限失败 | `isFileUnavailable=true` | `.unavailable(.io)` | 语义等价 |
| close() 后再收到 write 事件 | 忽略 | 忽略（`isClosed` 门）| — |

如 QA 在对照中发现不一致（除 10MB 差异外），Task 3 必须修复 FileSource 到与 MarkdownPanel 对齐，不改 MarkdownPanel。

### 14.4 其他次级风险

| 风险 | 触发条件 | 缓解 |
|---|---|---|
| 多屏 frame 漂移（UI.md §12 建议 3） | NSScreen 断开 | `Manager.currentFrameSuggestion` 校验 origin visibility，否则居中 |
| `WKScriptMessageHandler` retain cycle | bridge 强引 controller | bridge.controller 为 `weak` |
| webView teardown 遗漏 handler remove | close 顺序错 | §3.2 强制 10 步顺序 + code review checklist |
| copy 按钮 xcstrings key 被 PM 裁掉 | PRD 未收编 3 个 codeblock key | 降级为非目标，`.is-copy-disabled` CSS class 隐藏按钮；JS 不再挂 hover handler |
| vendor lock 未 commit 即跑 CI | 新 dev 忘记 fetch | `verify-markdown-viewer-vendor.sh` 显式 `MISSING` 退出 + README 提示 |

---

## 附录 A · AC × 实现交叉索引（速查）

| AC | 实现位置 |
|---|---|
| AC-1 | §8 Workspace + §2.1 Manager + §2.2 Controller |
| AC-2 | §2.1 Manager.showWindow hit-existing |
| AC-3 | §3.2 windowWillClose 10 步 |
| AC-4 | §2.1 Manager frame 持久化 + currentFrameSuggestion 多屏校验 |
| AC-5 | §4.1 styleMask 标准 |
| AC-6 | §8 ext 分支 |
| AC-7 / AC-8 | §5 viewer.js + §5.4 CSS |
| AC-9 ~ AC-11 | §5.3 mermaid 懒初始化 + 多子类型 render |
| AC-12 | §9.3 try/catch per block + bridge 消息 |
| AC-13 | marked GFM + HTML 默认允许；CSS § details/summary |
| AC-14 | §5.1 bootstrap theme + §2.2 applyTheme |
| AC-15 / AC-16 | §4.4 decidePolicyFor fragment allow |
| AC-17 / AC-18 | §4.4 linkActivated → bridge openExternal |
| AC-19 | §5.3 captureViewport / restoreViewport + §10.3 debounce |
| AC-20 | §3.4 reattach + §9.1 publish(.deleted) |
| AC-21 | §9.1 10MB 截断 + UI banner toggle |
| AC-22 | §9.2 encoding fallback |
| AC-23 / AC-24 / AC-25 | §10 + §14.2 降级 |
| AC-26 / AC-27 | §7 verify 脚本 |
| AC-28 | §4.3 ContentRuleList + §4.4 decidePolicyFor |
| AC-31 | §10.1 pool 不释放 |
| AC-32 | §5.3 sanitizeAndPostProcess 本地 img 降级 + UI.md §8 |
| AC-D1 ~ AC-D5 | §2.2 Controller 继承 NSWindowController + styleMask |

---

## 附录 B · TC 落地过程中发现、PRD 未覆盖的必要改动

以下 3 条在 RD/架构师落地拆解中暴露，建议 PM 补进 PRD（或接受 TC 裁定）：

1. **bridge `viewportStateSync` 的 native 侧存储策略未在 PRD §5.4 说明**。本 TC 定的是「仅 dlog，native 不缓存，滚动恢复完全由 JS 在 rerender 前自持」。原因是 rerender 由 `state` → `debounce` → `evaluateJavaScript("boot")` 驱动，JS 在同一 tick 里先 capture 再 restore，不需要穿 bridge。若 PM 希望「窗口关闭前 dump 一份到 UserDefaults 以便下次打开同文件恢复滚动位置」，需补 AC 与 TC 增量。
2. **`openFileFromExplorer` 返回值语义变化**：原函数返回「是否在 workspace 内创建了 panel」，改造后 md 分支返回「是否被 viewer 处理」。当前唯一 caller（`Sources/cmuxApp.swift:357`）丢弃返回值，安全。但若未来扩展（e.g. CLI `cmux open`）依赖「true = tab 已创建」语义，需要重新定义。建议 PM 在 §4 加一行「返回值语义说明」。
3. **WKWebView 的 typing latency 评估缺失**：CLAUDE.md 把 typing latency 列为一级关注。新窗口虽独立，但在多 viewer + 主窗口终端 heavy typing 场景下，WebKit 主进程共用 CPU 可能影响终端响应。本 TC 未做基准测量，建议在 Task 7 QA 阶段额外加一组「主窗口跑 `yes` + 5 个 viewer 窗口打开大 md 文档」场景下的 keystroke latency 对照基线。若回归显著，§14.1 的"精简 mermaid"与§10.1 的"不启动预热"两个决定都要复议。

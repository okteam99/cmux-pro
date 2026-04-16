import AppKit
import Bonsplit
import Combine
import WebKit

/// Window controller for a single Markdown viewer instance. One per file
/// path; tracked by `MarkdownViewerWindowManager`.
@MainActor
final class MarkdownViewerWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    let filePath: String
    private unowned let manager: MarkdownViewerWindowManager
    private let webView: WKWebView
    private let bridge: MarkdownViewerWebBridge
    private let fileSource: MarkdownViewerFileSource

    private var cancellables: Set<AnyCancellable> = []
    private var isViewerReady = false
    private var pendingStateDispatch: Bool = false

    init(
        filePath: String,
        processPool: WKProcessPool,
        manager: MarkdownViewerWindowManager
    ) {
        self.filePath = filePath
        self.manager = manager
        self.fileSource = MarkdownViewerFileSource(filePath: filePath)
        self.bridge = MarkdownViewerWebBridge()

        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences = prefs

        let contentController = WKUserContentController()
        contentController.add(bridge, name: MarkdownViewerWebBridge.messageHandlerName)
        configuration.userContentController = contentController

        let initialFrame = MarkdownViewerFrameMemory.loadIfValid()
            ?? NSRect(x: 0, y: 0, width: 900, height: 700)

        self.webView = WKWebView(
            frame: NSRect(origin: .zero, size: initialFrame.size),
            configuration: configuration
        )
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = (filePath as NSString).lastPathComponent.isEmpty
            ? String(localized: "markdownViewer.window.titleFallback", defaultValue: "Markdown Viewer")
            : (filePath as NSString).lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = webView
        if MarkdownViewerFrameMemory.loadIfValid() == nil {
            window.center()
        }

        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        bridge.onMessage = { [weak self] message in
            self?.handleBridgeMessage(message)
        }

        installContentRuleList { [weak self] in
            self?.loadViewer()
        }
        installFileSourceObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Resources

    private func loadViewer() {
        guard let resourceDir = Bundle.main.url(
            forResource: "MarkdownViewer",
            withExtension: nil
        ) ?? Bundle.main.resourceURL?.appendingPathComponent("MarkdownViewer", isDirectory: true) else {
            #if DEBUG
            dlog("markdownViewer.load error=missing-resource-dir")
            #endif
            return
        }
        let htmlURL = resourceDir.appendingPathComponent("viewer.html")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
    }

    private func installContentRuleList(_ completion: @escaping () -> Void) {
        let store = WKContentRuleListStore.default()
        store?.compileContentRuleList(
            forIdentifier: MarkdownViewerContentRules.identifier,
            encodedContentRuleList: MarkdownViewerContentRules.json
        ) { [weak self] list, error in
            if let list {
                self?.webView.configuration.userContentController.add(list)
            } else if let error {
                #if DEBUG
                dlog("markdownViewer.contentRuleList error=\(error.localizedDescription)")
                #endif
            }
            completion()
        }
    }

    private func installFileSourceObservers() {
        fileSource.$reloadToken
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleDispatchState()
            }
            .store(in: &cancellables)

        // When theme changes at the app level, push to JS.
        NSApp.publisher(for: \.effectiveAppearance)
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleDispatchState()
            }
            .store(in: &cancellables)
    }

    // MARK: - State dispatch

    private func scheduleDispatchState() {
        guard isViewerReady else {
            pendingStateDispatch = true
            return
        }
        dispatchState()
    }

    private func dispatchState() {
        let themeIsDark = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let payload: [String: Any] = [
            "filePath": fileSource.filePath,
            "content": fileSource.content,
            "isFileUnavailable": fileSource.isFileUnavailable,
            "isTruncated": fileSource.isTruncated,
            "theme": themeIsDark ? "dark" : "light",
            "l10n": Self.localizationStrings(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.cmux.applyState(\(json));"
        webView.evaluateJavaScript(script, completionHandler: nil)
        #if DEBUG
        dlog("markdownViewer.open path=\(fileSource.filePath) action=\(isViewerReady ? "refresh" : "initial")")
        #endif
    }

    private static func localizationStrings() -> [String: String] {
        [
            "markdownViewer.window.titleFallback": String(localized: "markdownViewer.window.titleFallback", defaultValue: "Markdown Viewer"),
            "markdownViewer.file.unavailable": String(localized: "markdownViewer.file.unavailable", defaultValue: "Unable to read file: %@"),
            "markdownViewer.file.deleted": String(localized: "markdownViewer.file.deleted", defaultValue: "The file has been deleted."),
            "markdownViewer.file.deleted.hint": String(localized: "markdownViewer.file.deleted.hint", defaultValue: "Waiting for the file to reappear…"),
            "markdownViewer.file.truncated": String(localized: "markdownViewer.file.truncated", defaultValue: "File too large — showing first 10MB only."),
            "markdownViewer.file.empty": String(localized: "markdownViewer.file.empty", defaultValue: "(empty)"),
            "markdownViewer.mermaid.error": String(localized: "markdownViewer.mermaid.error", defaultValue: "Failed to render Mermaid diagram."),
            "markdownViewer.mermaid.loading": String(localized: "markdownViewer.mermaid.loading", defaultValue: "Rendering diagram…"),
            "markdownViewer.diagram.expand": String(localized: "markdownViewer.diagram.expand", defaultValue: "Expand diagram"),
            "markdownViewer.diagram.close": String(localized: "markdownViewer.diagram.close", defaultValue: "Close diagram preview"),
            "markdownViewer.diagram.zoomIn": String(localized: "markdownViewer.diagram.zoomIn", defaultValue: "Zoom in"),
            "markdownViewer.diagram.zoomOut": String(localized: "markdownViewer.diagram.zoomOut", defaultValue: "Zoom out"),
            "markdownViewer.diagram.resetZoom": String(localized: "markdownViewer.diagram.resetZoom", defaultValue: "Reset zoom"),
            "markdownViewer.codeblock.copy": String(localized: "markdownViewer.codeblock.copy", defaultValue: "Copy"),
            "markdownViewer.codeblock.copied": String(localized: "markdownViewer.codeblock.copied", defaultValue: "Copied"),
            "markdownViewer.codeblock.copy.aria": String(localized: "markdownViewer.codeblock.copy.aria", defaultValue: "Copy code to clipboard"),
            "markdownViewer.localImage.hint": String(localized: "markdownViewer.localImage.hint", defaultValue: "(local image · click to open)"),
            "markdownViewer.localImage.tooltip": String(localized: "markdownViewer.localImage.tooltip", defaultValue: "Open in default app"),
            "markdownViewer.externalImage.blocked": String(localized: "markdownViewer.externalImage.blocked", defaultValue: "🚫 External image blocked: %@"),
        ]
    }

    // MARK: - Bridge dispatch

    private func handleBridgeMessage(_ message: MarkdownViewerBridgeMessage) {
        switch message {
        case .viewerReady:
            isViewerReady = true
            if pendingStateDispatch || fileSource.reloadToken > 0 {
                pendingStateDispatch = false
                dispatchState()
            } else {
                dispatchState()
            }
        case .openExternal(let url):
            let resolved = resolveExternalURL(url)
            if resolved.isFileURL, Self.isMarkdownFile(resolved.path) {
                #if DEBUG
                dlog("markdownViewer.webNav url=\(resolved) action=open-in-viewer")
                #endif
                MarkdownViewerWindowManager.shared.showWindow(for: resolved.path)
            } else {
                #if DEBUG
                dlog("markdownViewer.webNav url=\(resolved) action=open-external")
                #endif
                NSWorkspace.shared.open(resolved)
            }
        case .mermaidRenderError(let count, _):
            #if DEBUG
            dlog("markdownViewer.mermaid renderErrors=\(count) path=\(fileSource.filePath)")
            #endif
        case .fileReloadAck(let strategy, _):
            #if DEBUG
            dlog("markdownViewer.fileReload path=\(fileSource.filePath) strategy=\(strategy)")
            #endif
        case .viewportStateSync:
            // JS self-owned; Swift side does nothing beyond DEBUG trace.
            break
        case .copyCode(let text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case .unknown(let kind):
            #if DEBUG
            dlog("markdownViewer.bridge unknown=\(kind)")
            #endif
        }
    }

    /// Resolve a URL coming from the web layer. Relative `file://` paths /
    /// bare filenames are interpreted relative to the markdown file's
    /// directory so AC-32 local image click lands on the right asset.
    private func resolveExternalURL(_ url: URL) -> URL {
        if url.scheme == "file" {
            // Relative file-URL: normalise against markdown dir
            let baseDir = (fileSource.filePath as NSString).deletingLastPathComponent
            let fragment = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if fragment.isEmpty {
                return url
            }
            // Heuristic: if the path already exists as-is, keep; else join with baseDir
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let joined = (baseDir as NSString).appendingPathComponent(fragment)
            return URL(fileURLWithPath: joined)
        }
        if url.scheme == nil || url.scheme?.isEmpty == true {
            // Raw relative path
            let baseDir = (fileSource.filePath as NSString).deletingLastPathComponent
            let joined = (baseDir as NSString).appendingPathComponent(url.path)
            return URL(fileURLWithPath: joined)
        }
        return url
    }

    private static func isMarkdownFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            MarkdownViewerFrameMemory.save(frame)
        }
        fileSource.close()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: MarkdownViewerWebBridge.messageHandlerName
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        cancellables.removeAll()
        manager.detach(self)
    }

    // MARK: - WKNavigationDelegate (second line of defence beyond content rules)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let allowedSchemes: Set<String> = ["file", "about", "data"]
        if navigationAction.navigationType == .linkActivated {
            if url.isFileURL, Self.isMarkdownFile(url.path) {
                #if DEBUG
                dlog("markdownViewer.webNav url=\(url) action=open-in-viewer(decidePolicy)")
                #endif
                MarkdownViewerWindowManager.shared.showWindow(for: url.path)
            } else {
                #if DEBUG
                dlog("markdownViewer.webNav url=\(url) action=open-external(decidePolicy)")
                #endif
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        if allowedSchemes.contains(scheme) {
            decisionHandler(.allow)
        } else {
            #if DEBUG
            dlog("markdownViewer.webNav url=\(url) action=blocked(scheme=\(scheme))")
            #endif
            decisionHandler(.cancel)
        }
    }
}

import AppKit
import SwiftUI
import WebKit

/// SwiftUI host for a single Pro sidebar tab's WKWebView. Each `ProSidebarMode`
/// loads its own `index.html` from `Resources/ProSidebar/<folder>/`.
///
/// Tabs are kept hidden (rather than destroyed) when the user switches away,
/// so DOM state (scroll position, expanded folders, etc.) persists across
/// tab toggles.
struct ProSidebarWebHost: NSViewRepresentable {
    let mode: ProSidebarMode
    let defaultRootProvider: () -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, defaultRootProvider: defaultRootProvider)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.webView
        context.coordinator.loadIfNeeded()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Mode is fixed per host instance; nothing to update.
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let mode: ProSidebarMode
        let bridge: ProSidebarWebBridge
        let webView: WKWebView
        private var didLoad = false

        init(mode: ProSidebarMode, defaultRootProvider: @escaping () -> String?) {
            self.mode = mode
            let bridge = ProSidebarWebBridge()
            bridge.defaultRootProvider = defaultRootProvider
            self.bridge = bridge

            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(bridge, name: ProSidebarWebBridge.messageHandlerName)
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.setValue(false, forKey: "drawsBackground")
            self.webView = webView

            super.init()
            bridge.webView = webView
            webView.navigationDelegate = self
        }

        func loadIfNeeded() {
            guard !didLoad else { return }
            didLoad = true

            guard let resourceDir = Bundle.main.resourceURL?
                .appendingPathComponent("ProSidebar", isDirectory: true) else {
                #if DEBUG
                cmuxDebugLog("proSidebar.load error=missing-resource-dir mode=\(mode.rawValue)")
                #endif
                return
            }
            let entry = resourceDir
                .appendingPathComponent(mode.resourceFolder, isDirectory: true)
                .appendingPathComponent("index.html")
            webView.loadFileURL(entry, allowingReadAccessTo: resourceDir)
        }

        // MARK: - WKNavigationDelegate

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
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            if ["file", "about", "data"].contains(scheme) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

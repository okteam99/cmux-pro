import AppKit
import Bonsplit
import WebKit

/// Messages posted from the viewer web layer to the native side via
/// `window.webkit.messageHandlers.cmux.postMessage(...)`.
enum MarkdownViewerBridgeMessage {
    case viewerReady
    case openExternal(URL)
    case mermaidRenderError(count: Int, messages: [String])
    case fileReloadAck(strategy: String, anchorId: String?)
    case viewportStateSync(anchorId: String?, offsetInAnchor: Double?, scrollTopRatio: Double?)
    case copyCode(text: String)
    case unknown(kind: String)
}

/// WKScriptMessageHandler implementation for the Markdown viewer.
/// Parsing runs on the WebKit delivery thread; UI-touching work is hopped to
/// the main actor explicitly (see handler callbacks).
final class MarkdownViewerWebBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "cmux"

    /// Optional recorder used by tests to observe bridge messages.
    var debugRecorder: ((MarkdownViewerBridgeMessage) -> Void)?

    /// Delivered on the main actor. Callers must dispatch to the main queue
    /// before touching AppKit state.
    var onMessage: ((MarkdownViewerBridgeMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName else { return }
        let parsed = Self.parse(message.body)
        debugRecorder?(parsed)

        switch parsed {
        case .openExternal, .copyCode, .viewerReady:
            // AppKit-affecting or lifecycle-critical: deliver on main.
            DispatchQueue.main.async { [onMessage] in
                onMessage?(parsed)
            }
        case .mermaidRenderError, .fileReloadAck, .viewportStateSync, .unknown:
            // Telemetry: stay off-main, caller decides whether to hop.
            onMessage?(parsed)
        }
    }

    static func parse(_ body: Any) -> MarkdownViewerBridgeMessage {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String else {
            return .unknown(kind: "<malformed>")
        }
        switch kind {
        case "viewerReady":
            return .viewerReady
        case "openExternal":
            if let urlString = dict["url"] as? String,
               let url = URL(string: urlString) {
                return .openExternal(url)
            }
            return .unknown(kind: "openExternal-malformed")
        case "mermaidRenderError":
            let count = (dict["count"] as? Int) ?? 0
            let messages = (dict["messages"] as? [String]) ?? []
            return .mermaidRenderError(count: count, messages: messages)
        case "fileReloadAck":
            let strategy = (dict["strategy"] as? String) ?? "unknown"
            let anchorId = dict["anchorId"] as? String
            return .fileReloadAck(strategy: strategy, anchorId: anchorId)
        case "viewportStateSync":
            let anchorId = dict["anchorId"] as? String
            let offset = dict["offsetInAnchor"] as? Double
            let ratio = dict["scrollTopRatio"] as? Double
            return .viewportStateSync(anchorId: anchorId, offsetInAnchor: offset, scrollTopRatio: ratio)
        case "copyCode":
            let text = (dict["text"] as? String) ?? ""
            return .copyCode(text: text)
        default:
            return .unknown(kind: kind)
        }
    }
}

/// Content rule list that blocks any subresource whose URL scheme is not
/// `file` / `about` / `data`. Prevents the web layer from making network
/// requests (e.g. `<img src="https://...">`) while leaving local assets and
/// native-routed external links unaffected.
///
/// Whitelist-style rules: default block-all, then ignore-previous for
/// allowed schemes.
enum MarkdownViewerContentRules {
    static let json: String = """
    [
      { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^file:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^about:" }, "action": { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^data:" }, "action": { "type": "ignore-previous-rules" } }
    ]
    """

    static let identifier = "com.cmux.markdownViewer.blockNetwork"
}

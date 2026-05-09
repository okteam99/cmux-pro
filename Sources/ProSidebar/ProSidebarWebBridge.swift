import AppKit
import WebKit

/// Messages posted from a Pro sidebar tab's web layer to the native side via
/// `window.webkit.messageHandlers.cmuxProSidebar.postMessage(...)`.
///
/// The first version only supports `ping` to validate the round trip. Real
/// file-system handlers (`listDir`, `readFile`, `watchPath`, ...) land in
/// follow-up commits and add cases here.
enum ProSidebarBridgeMessage {
    case ready(mode: String)
    case ping(payload: String, replyId: String)
    case unknown(kind: String)
}

/// Reply payload sent back to a JS caller awaiting a `replyId`.
struct ProSidebarBridgeReply {
    let replyId: String
    let body: [String: Any]
}

@MainActor
final class ProSidebarWebBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "cmuxProSidebar"

    /// Set by the host so handlers can post replies back to the web layer.
    weak var webView: WKWebView?

    /// Hop to main; AppKit work happens here.
    var onMessage: ((ProSidebarBridgeMessage) -> Void)?

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName else { return }
        let parsed = Self.parse(message.body)
        Task { @MainActor [weak self] in
            self?.dispatch(parsed)
        }
    }

    private func dispatch(_ message: ProSidebarBridgeMessage) {
        // Built-in handlers first; anything unhandled is forwarded to onMessage.
        switch message {
        case let .ping(payload, replyId):
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "echo": payload,
            ]))
        default:
            break
        }
        onMessage?(message)
    }

    /// Send a JSON-serializable reply to a JS caller awaiting `replyId`.
    func send(reply: ProSidebarBridgeReply) {
        guard let webView else { return }
        guard
            let bodyData = try? JSONSerialization.data(withJSONObject: reply.body, options: []),
            let bodyJSON = String(data: bodyData, encoding: .utf8)
        else { return }

        let escaped = reply.replyId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window.__cmuxProSidebarResolve && window.__cmuxProSidebarResolve(\"\(escaped)\", \(bodyJSON));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    nonisolated static func parse(_ body: Any) -> ProSidebarBridgeMessage {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String else {
            return .unknown(kind: "<malformed>")
        }
        switch kind {
        case "ready":
            return .ready(mode: (dict["mode"] as? String) ?? "")
        case "ping":
            let payload = (dict["payload"] as? String) ?? ""
            let replyId = (dict["replyId"] as? String) ?? ""
            return .ping(payload: payload, replyId: replyId)
        default:
            return .unknown(kind: kind)
        }
    }
}

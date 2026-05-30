import AppKit
import WebKit

/// Messages posted from a Pro sidebar tab's web layer to the native side via
/// `window.webkit.messageHandlers.cmuxProSidebar.postMessage(...)`.
enum ProSidebarBridgeMessage {
    case ready(mode: String)
    case ping(payload: String, replyId: String)
    case getDefaultRoot(replyId: String)
    case getWorkspaceId(replyId: String)
    case chooseDirectory(initialPath: String?, replyId: String)
    case listGitWorktrees(rootPath: String, replyId: String)
    case listDir(path: String, includeHidden: Bool, replyId: String)
    case openFile(path: String, replyId: String)
    case revealInFinder(path: String, replyId: String)
    case openInBrowser(filePath: String, rootPath: String, replyId: String)
    case getGitStatus(rootPath: String, replyId: String)
    case unknown(kind: String)
}

extension Notification.Name {
    static let proSidebarWorkspaceDidChange = Notification.Name("cmux.proSidebar.workspaceDidChange")
}

/// Reply payload sent back to a JS caller awaiting a `replyId`.
struct ProSidebarBridgeReply {
    let replyId: String
    let body: [String: Any]
}

@MainActor
final class ProSidebarWebBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "cmuxProSidebar"

    /// The default root directory the Files tab should bind to on first load.
    /// Sourced from the active workspace's file explorer root.
    var defaultRootProvider: (() -> String?)?

    /// Returns the current workspace UUID string. JS namespaces its
    /// localStorage state by this so per-session views don't bleed.
    var currentWorkspaceIdProvider: (() -> String?)?

    /// Set by the host so handlers can post replies back to the web layer.
    weak var webView: WKWebView?

    private var workspaceObserver: NSObjectProtocol?

    override init() {
        super.init()
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: .proSidebarWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let id = (note.userInfo?["workspaceId"] as? String) ?? ""
            self.notifyWorkspaceChange(id: id)
        }
    }

    deinit {
        if let workspaceObserver {
            NotificationCenter.default.removeObserver(workspaceObserver)
        }
    }

    private func notifyWorkspaceChange(id: String) {
        guard let webView else { return }
        let escaped = id
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window.dispatchEvent(new CustomEvent('cmux:workspaceDidChange', {detail:{id:\"\(escaped)\"}}));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Forwarded for tab-specific reactions; built-in handlers are dispatched
    /// before this fires.
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
        switch message {
        case let .ping(payload, replyId):
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "echo": payload,
            ]))
        case let .getDefaultRoot(replyId):
            let path = defaultRootProvider?() ?? ""
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "path": path,
            ]))
        case let .getWorkspaceId(replyId):
            let id = currentWorkspaceIdProvider?() ?? ""
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "id": id,
            ]))
        case let .chooseDirectory(initialPath, replyId):
            let chosen = Self.openDirectoryPicker(initialPath: initialPath)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "path": chosen ?? NSNull(),
            ]))
        case let .listGitWorktrees(rootPath, replyId):
            let worktrees = Self.fetchGitWorktrees(at: rootPath)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "worktrees": worktrees,
            ]))
        case let .listDir(path, includeHidden, replyId):
            let entries = Self.listDirectory(at: path, includeHidden: includeHidden)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "entries": entries,
            ]))
        case let .openFile(path, replyId):
            Self.openFile(at: path)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
            ]))
        case let .revealInFinder(path, replyId):
            Self.revealInFinder(at: path)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
            ]))
        case let .openInBrowser(filePath, rootPath, replyId):
            LocalFileServer.shared.openInBrowser(filePath: filePath, rootPath: rootPath)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
            ]))
        case let .getGitStatus(rootPath, replyId):
            let statuses = Self.fetchGitStatus(at: rootPath)
            send(reply: ProSidebarBridgeReply(replyId: replyId, body: [
                "ok": true,
                "statuses": statuses,
            ]))
        default:
            break
        }
        onMessage?(message)
    }

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
            return .ping(
                payload: (dict["payload"] as? String) ?? "",
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "getDefaultRoot":
            return .getDefaultRoot(replyId: (dict["replyId"] as? String) ?? "")
        case "getWorkspaceId":
            return .getWorkspaceId(replyId: (dict["replyId"] as? String) ?? "")
        case "chooseDirectory":
            return .chooseDirectory(
                initialPath: dict["initialPath"] as? String,
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "listGitWorktrees":
            return .listGitWorktrees(
                rootPath: (dict["rootPath"] as? String) ?? "",
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "listDir":
            return .listDir(
                path: (dict["path"] as? String) ?? "",
                includeHidden: (dict["includeHidden"] as? Bool) ?? false,
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "openFile":
            return .openFile(
                path: (dict["path"] as? String) ?? "",
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "revealInFinder":
            return .revealInFinder(
                path: (dict["path"] as? String) ?? "",
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "openInBrowser":
            return .openInBrowser(
                filePath: (dict["filePath"] as? String) ?? "",
                rootPath: (dict["rootPath"] as? String) ?? "",
                replyId: (dict["replyId"] as? String) ?? ""
            )
        case "getGitStatus":
            return .getGitStatus(
                rootPath: (dict["rootPath"] as? String) ?? "",
                replyId: (dict["replyId"] as? String) ?? ""
            )
        default:
            return .unknown(kind: kind)
        }
    }

    // MARK: - Native handlers

    @MainActor
    private static func openDirectoryPicker(initialPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = String(
            localized: "proSidebar.directoryPicker.message",
            defaultValue: "Choose a folder for the cmux Pro File Root"
        )
        panel.prompt = String(
            localized: "proSidebar.directoryPicker.prompt",
            defaultValue: "Choose"
        )
        if let initialPath, !initialPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: initialPath)
        }
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url?.path
    }

    /// Run `git worktree list --porcelain` in the given directory. Returns a
    /// flat array of `[{path, branch, head}]`. Empty array when the directory
    /// is not a git repository.
    nonisolated static func fetchGitWorktrees(at rootPath: String) -> [[String: String]] {
        guard !rootPath.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", rootPath, "worktree", "list", "--porcelain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return [] }

        var results: [[String: String]] = []
        var current: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            if line.isEmpty {
                if !current.isEmpty {
                    results.append(current)
                    current = [:]
                }
                continue
            }
            if line.hasPrefix("worktree ") {
                current["path"] = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                current["head"] = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                current["branch"] = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                current["branch"] = ""
            }
        }
        if !current.isEmpty {
            results.append(current)
        }
        return results
    }

    /// Read directory contents. Hidden entries (leading `.`) are excluded by
    /// default. Each entry is `{name, isDir}`. Sorted: directories first,
    /// then files, both case-insensitive alphabetical.
    nonisolated static func listDirectory(at path: String, includeHidden: Bool) -> [[String: Any]] {
        guard !path.isEmpty else { return [] }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let url = URL(fileURLWithPath: path)
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        struct Entry {
            let name: String
            let isDir: Bool
            let isSymlink: Bool
        }
        var entries: [Entry] = []
        entries.reserveCapacity(contents.count)
        for entry in contents {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            entries.append(Entry(
                name: entry.lastPathComponent,
                isDir: values?.isDirectory ?? false,
                isSymlink: values?.isSymbolicLink ?? false
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir && !rhs.isDir }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return entries.map { entry in
            [
                "name": entry.name,
                "isDir": entry.isDir,
                "isSymlink": entry.isSymlink,
            ]
        }
    }

    /// Run `git status --porcelain --untracked-files=all` in the given root.
    /// Returns a `[relativePath: code]` map where code is `"modified"` for
    /// any tracked change (M / A / D / R / C / U / T / staged variants) or
    /// `"untracked"` for `??`. Ignored entries are excluded. Empty when
    /// `rootPath` is not a git repository.
    nonisolated static func fetchGitStatus(at rootPath: String) -> [String: String] {
        guard !rootPath.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git", "-C", rootPath,
            // Disable C-style escaping for non-ASCII paths so paths with CJK
            // (or any byte > 0x7e) come back as UTF-8. Without this git wraps
            // such paths in double quotes with octal escapes and folder
            // colors stop propagating below the first non-ASCII segment.
            "-c", "core.quotePath=false",
            // `--ignored=matching` adds `!! <path>` lines for ignored
            // files/dirs so the file tree can dim them. `matching` mode is
            // mandatory here: the default `traditional` mode, when combined
            // with `--untracked-files=all` (below), lists every individual
            // file inside ignored directories — so a repo with `node_modules`
            // produces hundreds of thousands of paths and this synchronous
            // git call freezes the app on startup. `matching` reports an
            // ignored directory that matches a gitignore pattern as a single
            // entry without recursing into it.
            "status", "--porcelain", "--ignored=matching", "--untracked-files=all",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return [:]
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            // porcelain v1 line: "XY <path>"  (3-char prefix then path; rename: "XY old -> new")
            guard line.count >= 4 else { continue }
            let prefix = line.prefix(2)
            let pathPart = String(line.dropFirst(3))
            if prefix == "??" {
                let path = stripQuotedPath(pathPart)
                result[path] = "untracked"
            } else if prefix == "!!" {
                var path = stripQuotedPath(pathPart)
                // Ignored directories come back with a trailing `/`; normalize
                // so the JS side can key them by absolute path.
                if path.hasSuffix("/") { path = String(path.dropLast()) }
                result[path] = "ignored"
            } else {
                if let arrowRange = pathPart.range(of: " -> ") {
                    let newPath = stripQuotedPath(String(pathPart[arrowRange.upperBound...]))
                    result[newPath] = "modified"
                } else {
                    let path = stripQuotedPath(pathPart)
                    result[path] = "modified"
                }
            }
        }
        return result
    }

    /// porcelain v1 quotes paths containing special chars with C-style escapes
    /// inside double quotes. Strip surrounding quotes for the common case;
    /// escape sequences inside the path are left intact (a future iteration
    /// can decode them properly).
    nonisolated private static func stripQuotedPath(_ raw: String) -> String {
        guard raw.first == "\"" && raw.last == "\"" && raw.count >= 2 else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    /// Open a file from the Pro sidebar. Markdown routes to the in-app
    /// `MarkdownViewerWindowManager`; everything else falls back to the
    /// system default app via `NSWorkspace`.
    @MainActor
    static func openFile(at path: String) {
        let lower = (path as NSString).pathExtension.lowercased()
        if lower == "md" || lower == "markdown" {
            MarkdownViewerWindowManager.shared.showWindow(for: path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Reveal a file or folder in Finder with it pre-selected. Works for both
    /// files and directories.
    @MainActor
    static func revealInFinder(at path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

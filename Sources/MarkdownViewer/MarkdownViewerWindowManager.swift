import AppKit
import WebKit

/// App-wide manager for Markdown viewer windows. Owns a shared
/// `WKProcessPool` so that the second + N-th viewer opens benefit from a
/// warmed Web Content Process (see PRD AC-24 / AC-31).
///
/// Not a `NSWindowController`; each live window is represented by its own
/// `MarkdownViewerWindowController` registered here keyed by canonical path.
@MainActor
final class MarkdownViewerWindowManager: NSObject {
    static let shared = MarkdownViewerWindowManager()

    /// Shared WebKit process pool. Lives for the lifetime of the application
    /// process; intentionally never released so warm opens stay warm.
    let processPool = WKProcessPool()

    /// Feature flag: disable to route .md opens back through
    /// `newMarkdownSurface` (legacy tab version). Enabled by default.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "markdownViewer.enabled") as? Bool ?? true
    }

    private var controllers: [String: MarkdownViewerWindowController] = [:]

    override private init() {
        super.init()
    }

    /// Open or focus the viewer window for the given file path. If a viewer
    /// already exists for the canonicalized path, brings it forward; else
    /// creates a new one.
    @discardableResult
    func showWindow(for filePath: String) -> MarkdownViewerWindowController {
        let key = Self.canonicalKey(for: filePath)
        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = MarkdownViewerWindowController(
            filePath: filePath,
            processPool: processPool,
            manager: self
        )
        controllers[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Called by a controller in `windowWillClose` to release its entry.
    func detach(_ controller: MarkdownViewerWindowController) {
        let key = Self.canonicalKey(for: controller.filePath)
        if controllers[key] === controller {
            controllers.removeValue(forKey: key)
        }
    }

    /// Canonicalize a path for dictionary keying so symlinks / trailing
    /// slashes don't produce duplicate windows.
    static func canonicalKey(for filePath: String) -> String {
        URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
    }

    // MARK: - Test seams (DEBUG only)

    #if DEBUG
    var __test_processPoolIdentity: ObjectIdentifier {
        ObjectIdentifier(processPool)
    }

    func __test_controller(for filePath: String) -> MarkdownViewerWindowController? {
        controllers[Self.canonicalKey(for: filePath)]
    }

    func __test_activeWindowCount() -> Int {
        controllers.count
    }

    func __test_teardownAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
    }
    #endif
}

/// Persistence of the last-used viewer window frame. Shared by every
/// viewer window regardless of file (PRD AC-4).
enum MarkdownViewerFrameMemory {
    private static let key = "markdownViewer.lastFrame"

    static func save(_ frame: NSRect) {
        let arr: [CGFloat] = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        UserDefaults.standard.set(arr, forKey: key)
    }

    /// Load the remembered frame if its origin still falls on an attached
    /// screen. Returns nil when no memory exists or the origin is off-screen
    /// (multi-monitor disconnection fallback).
    static func loadIfValid() -> NSRect? {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [CGFloat], arr.count == 4 else {
            return nil
        }
        let frame = NSRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        let origin = NSPoint(x: arr[0], y: arr[1])
        let onScreen = NSScreen.screens.contains { $0.frame.contains(origin) }
        return onScreen ? frame : nil
    }
}

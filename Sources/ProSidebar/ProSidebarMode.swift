import Foundation

/// Tabs available in the cmux Pro right sidebar. Owned entirely by the fork —
/// add new cases freely; upstream's `RightSidebarMode` is not touched.
enum ProSidebarMode: String, CaseIterable, Identifiable {
    case fileRoot
    case fileWorkTree

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fileRoot: return String(localized: "proSidebar.mode.fileRoot", defaultValue: "File Root")
        case .fileWorkTree: return String(localized: "proSidebar.mode.fileWorkTree", defaultValue: "File WorkTree")
        }
    }

    var symbolName: String {
        switch self {
        case .fileRoot: return "folder"
        case .fileWorkTree: return "arrow.triangle.branch"
        }
    }

    /// HTML entry point under `Resources/ProSidebar/<feature>/index.html`.
    var resourceFolder: String {
        switch self {
        case .fileRoot: return "fileRoot"
        case .fileWorkTree: return "fileWorkTree"
        }
    }
}

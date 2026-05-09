import Foundation

/// Tabs available in the cmux Pro right sidebar. Owned entirely by the fork —
/// add new cases freely; upstream's `RightSidebarMode` is not touched.
enum ProSidebarMode: String, CaseIterable, Identifiable {
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files: return String(localized: "proSidebar.mode.files", defaultValue: "Files")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        }
    }

    /// HTML entry point under `Resources/ProSidebar/<feature>/index.html`.
    var resourceFolder: String {
        switch self {
        case .files: return "files"
        }
    }
}

import Foundation

/// Feature flag for the cmux Pro right sidebar (`Sources/ProSidebar/`).
///
/// Default-on so the fork's webview-based right sidebar replaces the upstream
/// `RightSidebarPanelView`. Users can flip the flag in `defaults` to fall back
/// to the upstream sidebar for comparison or bug isolation:
///
///     defaults write com.okteam99.cmuxpro proSidebar.enabled -bool false
enum ProSidebarFlags {
    private static let key = "proSidebar.enabled"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

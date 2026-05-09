import SwiftUI

/// Top-level cmux Pro right sidebar container. Renders a tab strip and the
/// active tab's webview. Owned entirely by the fork — upstream's
/// `RightSidebarPanelView` is unwired when `ProSidebarFlags.enabled` is true.
struct ProSidebarContainerView: View {
    let titlebarHeight: CGFloat
    /// Resolves the current workspace's root path. Called every time a tab
    /// asks `getDefaultRoot`, so workspace switches are reflected live.
    let defaultRootProvider: () -> String?

    @State private var selectedMode: ProSidebarMode = .fileRoot

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
                .frame(height: titlebarHeight)
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(ProSidebarMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 9, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selectedMode == mode
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.clear)
                    )
                    .foregroundColor(selectedMode == mode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            ForEach(ProSidebarMode.allCases) { mode in
                ProSidebarWebHost(
                    mode: mode,
                    defaultRootProvider: defaultRootProvider
                )
                .opacity(selectedMode == mode ? 1 : 0)
                .allowsHitTesting(selectedMode == mode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

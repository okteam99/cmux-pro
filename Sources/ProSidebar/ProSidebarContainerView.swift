import SwiftUI

/// Top-level cmux Pro right sidebar container. Renders a tab strip (initially
/// just one entry) and the active tab's webview. Owned entirely by the fork —
/// upstream's `RightSidebarPanelView` is unwired when `ProSidebarFlags.enabled`
/// is true.
struct ProSidebarContainerView: View {
    let titlebarHeight: CGFloat

    @State private var selectedMode: ProSidebarMode = .files

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
        HStack(spacing: 4) {
            ForEach(ProSidebarMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbolName)
                        Text(mode.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
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
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var content: some View {
        // Each tab keeps its own webview alive in a ZStack and toggles
        // visibility, so DOM state survives tab switches.
        ZStack {
            ForEach(ProSidebarMode.allCases) { mode in
                ProSidebarWebHost(mode: mode)
                    .opacity(selectedMode == mode ? 1 : 0)
                    .allowsHitTesting(selectedMode == mode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

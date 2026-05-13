import SwiftUI

/// Top-level cmux Pro right sidebar container. Renders a tab strip and the
/// active tab's webview. Owned entirely by the fork — upstream's
/// `RightSidebarPanelView` is unwired when `ProSidebarFlags.enabled` is true.
struct ProSidebarContainerView: View {
    let titlebarHeight: CGFloat
    /// Resolves the current workspace's root path. Called every time a tab
    /// asks `getDefaultRoot`, so workspace switches are reflected live.
    let defaultRootProvider: () -> String?
    /// Resolves the current workspace UUID string so JS can namespace its
    /// localStorage by session.
    let currentWorkspaceIdProvider: () -> String?

    @State private var selectedMode: ProSidebarMode = .fileRoot
    @State private var activeWorkspaceUuid: String = ""

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
                .frame(height: titlebarHeight)
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncFromCurrentWorkspace() }
        .onReceive(NotificationCenter.default.publisher(for: .proSidebarWorkspaceDidChange)) { _ in
            syncFromCurrentWorkspace()
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(ProSidebarMode.allCases) { mode in
                Button {
                    selectedMode = mode
                    persistSelectedMode(mode)
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
                    defaultRootProvider: defaultRootProvider,
                    currentWorkspaceIdProvider: currentWorkspaceIdProvider
                )
                .opacity(selectedMode == mode ? 1 : 0)
                .allowsHitTesting(selectedMode == mode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The `currentWorkspaceIdProvider` returns a composite `workspaceUuid` or
    // `workspaceUuid:panelUuid`. The tab choice is intentionally workspace-
    // scoped (not panel-scoped) so splitting/refocusing panels inside the same
    // workspace keeps the user's tab selection.
    private func currentWorkspaceUuid() -> String {
        let composite = currentWorkspaceIdProvider() ?? ""
        return composite.split(separator: ":").first.map(String.init) ?? composite
    }

    private func storageKey(for workspaceUuid: String) -> String {
        "ProSidebar.selectedMode.\(workspaceUuid)"
    }

    private func loadSelectedMode(for workspaceUuid: String) -> ProSidebarMode {
        guard !workspaceUuid.isEmpty,
              let raw = UserDefaults.standard.string(forKey: storageKey(for: workspaceUuid)),
              let mode = ProSidebarMode(rawValue: raw) else {
            return .fileRoot
        }
        return mode
    }

    private func persistSelectedMode(_ mode: ProSidebarMode) {
        let uuid = currentWorkspaceUuid()
        guard !uuid.isEmpty else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey(for: uuid))
    }

    private func syncFromCurrentWorkspace() {
        let uuid = currentWorkspaceUuid()
        guard uuid != activeWorkspaceUuid else { return }
        activeWorkspaceUuid = uuid
        selectedMode = loadSelectedMode(for: uuid)
    }
}

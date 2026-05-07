# FileExplorer Current-State Audit

## 1. Entry Points

### Keyboard Shortcut
- **Primary entry point:** Keyboard shortcut `Cmd+Option+B`
- **Citation:** `Sources/KeyboardShortcutSettings.swift:239-240`
  ```
  case .toggleFileExplorer:
      return StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
  ```
- **Label:** "Toggle File Explorer" (`Sources/KeyboardShortcutSettings.swift:131`)

### Shortcut Handling
- **Trigger location:** `Sources/AppDelegate.swift:11072-11078`
  ```swift
  if matchConfiguredShortcut(event: event, action: .toggleFileExplorer) {
      DispatchQueue.main.async { [weak self] in
          self?.fileExplorerState?.toggle()
      }
      return true
  }
  ```

### Menu Item
- **Status:** No visible menu bar menu item found. The action is only accessible via keyboard shortcut and programmatic `fileExplorerState.toggle()` calls.
- **Search result:** No `Menu("File Explorer")` or similar menu structure found in cmuxApp.swift or ContentView.swift.

### CLI / Socket Command
- **Status:** Not found. No socket command handler for file explorer toggle exists.

### Toolbar/Sidebar Button
- **Status:** No visible button exists. The FileExplorerState is passed to `SidebarFooterButtons` (`Sources/ContentView.swift:11221-11231`), but the footer buttons struct only renders help and update controls, not a file explorer toggle button.
- **Citation:** `Sources/ContentView.swift:11229-11240`
  ```swift
  private struct SidebarFooterButtons: View {
      @ObservedObject var updateViewModel: UpdateViewModel
      @ObservedObject var fileExplorerState: FileExplorerState
      let onSendFeedback: () -> Void
      
      var body: some View {
          HStack(spacing: 4) {
              SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
              UpdatePill(model: updateViewModel)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
  }
  ```

## 2. UI Shape & Placement

### Layout Structure
- **Placement:** Right-side drawer panel
- **Coexistence:** Coexists with the terminal panel; does NOT replace it
- **Citation:** `Sources/ContentView.swift:2763-2788`
  ```swift
  private var terminalContentWithSidebarDropOverlay: some View {
      let explorerVisible = fileExplorerState.isVisible
      return HStack(spacing: 0) {
          terminalContent                    // Terminal on left
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          if explorerVisible {
              Divider()                       // Visual separator
          }
          FileExplorerPanelView(...)          // Explorer on right
              .frame(width: explorerVisible ? fileExplorerWidth : 0)
              .clipped()
              .allowsHitTesting(explorerVisible)
      }
  }
  ```

### Width & Resizable
- **Default width:** 220 pixels
- **Citation:** `Sources/ContentView.swift:1847`
  ```swift
  @State private var fileExplorerWidth: CGFloat = 220
  ```
- **Persistence:** Width is persisted to UserDefaults under key `"fileExplorer.width"`
- **Citation:** `Sources/FileExplorerStore.swift:428-429`
  ```swift
  @Published var width: CGFloat {
      didSet { UserDefaults.standard.set(Double(width), forKey: "fileExplorer.width") }
  }
  ```
- **Resizable:** Yes, via a resize handle
- **Citation:** `Sources/ContentView.swift:2800-2806`
  ```swift
  private var fileExplorerResizerHandle: some View {
      sidebarResizerHandleOverlay(
          .explorerDivider,
          width: SidebarResizeInteraction.totalHitWidth,
          availableWidth: observedWindow?.contentView?.bounds.width ?? 1920
      )
  }
  ```

### Toggleable
- **State object:** `FileExplorerState` with `isVisible` @Published property
- **Citation:** `Sources/FileExplorerStore.swift:424-426`
  ```swift
  final class FileExplorerState: ObservableObject {
      @Published var isVisible: Bool {
          didSet { UserDefaults.standard.set(isVisible, forKey: "fileExplorer.isVisible") }
      }
  ```
- **Toggle method:** `FileExplorerState.setVisible(_:)` called via `toggle()`
- **Citation:** `Sources/FileExplorerStore.swift:454-478`

## 3. Functional Scope

### Browse/Expand Directories
- **NSOutlineView** displays hierarchical file tree with expand/collapse disclosure triangles
- **Citation:** `Sources/FileExplorerView.swift:10-300` (NSOutlineViewDataSource implementation)

### Open Files
- **Context menu:** Right-click menu includes "Open in Default Editor"
- **Citation:** `Sources/FileExplorerView.swift:227-235`
  ```swift
  if !node.isDirectory && isLocal {
      let openItem = NSMenuItem(
          title: String(localized: "fileExplorer.contextMenu.openDefault", 
                       defaultValue: "Open in Default Editor"),
          action: #selector(contextMenuOpenInDefaultEditor(_:)),
          keyEquivalent: ""
      )
  ```

### Drag-Drop
- **Files can be dragged to terminal:** Files dragged from explorer to terminal pass full file paths
- **Citation:** `Sources/FileExplorerView.swift:210-214`
  ```swift
  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
      guard let node = item as? FileExplorerNode, !node.isDirectory else { return nil }
      guard store.provider is LocalFileExplorerProvider else { return nil }
      return NSURL(fileURLWithPath: node.path)
  }
  ```

### Right-Click Context Menu
- Available actions:
  - "Open in Default Editor" (files only, local provider)
  - "Reveal in Finder" (local provider only)
  - "Copy Path" (all)
  - "Copy Relative Path" (all)
- **Citation:** `Sources/FileExplorerView.swift:216-298`

### Search/Filter
- **Hidden files toggle:** Can show/hide dotfiles via `showHiddenFiles` property
- **Citation:** `Sources/FileExplorerStore.swift:439-441`
  ```swift
  @Published var showHiddenFiles: Bool {
      didSet { UserDefaults.standard.set(showHiddenFiles, forKey: "fileExplorer.showHidden") }
  }
  ```
- **No full-text search:** Search functionality not present in the code.

### Root Directory Logic
- **Local:** Uses the currently focused terminal panel's working directory
- **SSH:** When an SSH session is active, uses the remote session's working directory
- **Citation:** `Sources/ContentView.swift:2980-3026`
  ```swift
  private func syncFileExplorerToFocusedTerminal() {
      let dir = focusedDirectory ?? ""
      let config = sshSessionConfig
      if config != nil {
          // SSH provider setup and sync
      } else {
          if !(fileExplorerStore.provider is LocalFileExplorerProvider) {
              fileExplorerStore.setProvider(LocalFileExplorerProvider())
          }
          fileExplorerStore.setRootPath(dir)
      }
  }
  ```

### Integration with Terminal
- **"cd to here":** Not directly visible, but explorer syncs to focused panel's CWD automatically
- **"Reveal in explorer":** "Reveal in Finder" menu item available for local files
- **Auto-sync:** File explorer root automatically updates when terminal focus changes
- **Citation:** `Sources/ContentView.swift:2880-2905` (syncFileExplorerToFocusedTerminal is called on tab changes)

### SSH Support
- **Remote browsing:** Full support via `SSHFileExplorerProvider`
- **Citation:** `Sources/FileExplorerStore.swift:283-406`
- **Features:** Lists remote directories via SSH, supports git status for remote repos

## 4. Mount Points & State Management

### State Objects
- **cmuxApp.swift (app root):**
  - `@StateObject private var fileExplorerState = FileExplorerState()`
  - Citation: `Sources/cmuxApp.swift:142`
  - Passed to ContentView via `.environmentObject(fileExplorerState)` at line 328

- **AppDelegate.swift:**
  - `weak var fileExplorerState: FileExplorerState?`
  - Citation: `Sources/AppDelegate.swift:2278`
  - Set from cmuxApp at line 339

- **ContentView.swift:**
  - `@EnvironmentObject var fileExplorerState: FileExplorerState` (line 1834)
  - `@StateObject private var fileExplorerStore = FileExplorerStore()` (line 1846)
  - Citation: `Sources/ContentView.swift:1834, 1846`

### View Hierarchy Integration
- **Stored in view tree:** Always present but width set to 0 when hidden
- **Citation:** `Sources/ContentView.swift:2778-2781`
  ```swift
  FileExplorerPanelView(store: fileExplorerStore, state: fileExplorerState)
      .frame(width: explorerVisible ? fileExplorerWidth : 0)
      .clipped()
      .allowsHitTesting(explorerVisible)
  ```
- **No transaction animation:** Explicitly disabled to avoid layout flicker
- **Citation:** `Sources/ContentView.swift:2789`
  ```swift
  .transaction { $0.animation = nil }
  ```

### Visibility Control
- **Controlled by:** `fileExplorerState.isVisible` boolean
- **User preference persistence:** Stored in UserDefaults under `"fileExplorer.isVisible"`
- **Width persistence:** UserDefaults key `"fileExplorer.width"`
- **Hidden files preference:** UserDefaults key `"fileExplorer.showHidden"`
- **Citation:** `Sources/FileExplorerStore.swift:424-451`

### Content Sync Logic
- **Sync trigger:** Runs in ContentView's periodic timer when selected tab or focused panel changes
- **Citation:** `Sources/ContentView.swift:2880-2905` (implicit timer-based sync)
- **Caller:** Calls `syncFileExplorerToFocusedTerminal()` to update root path based on focused terminal

## 5. Gap vs. User Request

### User Request Summary
"Add a file browser feature — a folder icon; clicking it expands a file navigator on the right side."

### Current State
1. **Folder icon:** Does NOT exist as a dedicated button
   - The word "folder" appears only in a draggable folder display of the focused directory (line 2856-2860), not as a clickable toggle button
   - Citation: `Sources/ContentView.swift:2856-2860`
     ```swift
     // Draggable folder icon + focused command name
     if let directory = focusedDirectory {
         DraggableFolderIcon(directory: directory)
     }
     ```
   - This icon is for drag-drop interaction, not for toggling the explorer

2. **Navigator on right side:** Already exists
   - Citation: Lines 2763-2788 show the explorer panel rendered on the right via HStack layout

3. **Expand/collapse behavior:** Partially exists
   - File explorer itself exists and has Cmd+Option+B shortcut to toggle
   - But NO visible button in the UI to trigger this toggle
   - Users must use the keyboard shortcut or programmatically trigger it

### Missing Element
**A visible, clickable folder button/icon in the toolbar or sidebar footer that toggles the FileExplorer.**

The functionality is 95% complete — the only gap is the **entry point button**. The user's request specifically asks for "click folder icon → expand navigator," but there is no clickable folder icon button in the UI today.

### Discrepancy Summary
- **What exists:** Right-side file navigator, SSH support, drag-drop, git status, style customization
- **What's missing:** A visual button (folder icon) to toggle visibility; users must use Cmd+Option+B or no UI entry point exists

## 6. Recommendation for Next Flow

### Feature Type: **Micro** (icon/text tweak only, ≤ 3 files)

**Rationale:**
The FileExplorer feature is 99% built. The gap is purely a UI entry point — adding a single folder icon button to the sidebar footer or toolbar. This requires:

1. **Add button to `SidebarFooterButtons`** (ContentView.swift): Insert a Button with folder icon that calls `fileExplorerState.toggle()`
2. **Optional: Add to AppDelegate menu** (if menu bar item desired): Wire toggleFileExplorer action to a menu item in the View menu
3. **Optional: Keyboard shortcut hint display**: Ensure the shortcut hint displays near the button

**Estimated scope:** 1–2 files, <50 lines of code total. The underlying FileExplorer system is production-ready and fully functional; it just needs a visible, user-discoverable trigger.

**Do NOT do a big reshape.** Simply add a button and wire it to the existing `fileExplorerState.toggle()` mechanism that AppDelegate already calls. The infrastructure is complete.


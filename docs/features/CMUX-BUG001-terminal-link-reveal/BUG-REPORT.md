# BUG-001: 点击终端文件链接后未在文件浏览器自动选中（工作区内文件）

## 现象
- 用户在终端输出中 cmd+click 或点击超链接一个工作区内的文件路径
- 预期：文件浏览器自动展开父目录 + 选中该文件 + 滚动到可见位置
- 实际：文件没有被选中（至少对嵌套较深的文件复现）

## 根因分析

### 核心流程
1. 终端点击 → `GhosttyTerminalView.openResolvedTerminalPath(path)` (Sources/GhosttyTerminalView.swift:7432)
2. 路径属于工作区 → 发送 `com.cmux.revealInFileExplorer` 通知
3. `FileExplorerView.Coordinator.handleRevealRequest(path)` (Sources/FileExplorerView.swift:79)
4. `await store.reveal(path)` 展开 `store.expandedPaths` 中所有祖先目录 + 返回目标 Node
5. `selectAndScroll(to: node)` 执行：
   ```swift
   outlineView.reloadData()
   self.restoreExpansionState(self.store.expandedPaths, in: outlineView)
   let row = outlineView.row(forItem: node)
   guard row >= 0 else { return }   // ← 深层文件在此处静默返回
   outlineView.selectRowIndexes(...)
   outlineView.scrollRowToVisible(row)
   ```

### 🔴 Bug：`restoreExpansionState` 不递归（Sources/FileExplorerView.swift:126-133）

```swift
private func restoreExpansionState(_ expandedPaths: Set<String>, in outlineView: NSOutlineView) {
    for row in 0..<outlineView.numberOfRows {        // ← 范围在循环前一次性求值
        guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
        if expandedPaths.contains(node.path) && outlineView.isExpandable(node) {
            outlineView.expandItem(node)             // ← 展开后新增的 row 不被迭代
        }
    }
}
```

**复现**：点击 `Sources/Panels/MarkdownPanel.swift`（嵌套 2+ 层）时：
- reloadData 后只显示根目录子项（若之前未展开过 Sources）
- 循环迭代顶层 rows，找到 `Sources` → expandItem(Sources) → 新增 Sources 的子 row
- 循环范围已固定（捕获了 reloadData 后的 numberOfRows），不会迭代新增的 `Sources/Panels`
- 结果：`Panels` 未被展开 → `MarkdownPanel.swift` 不在 outline view 的 row 列表里
- `row(forItem: node)` 返回 -1 → `guard row >= 0 else { return }` 静默返回
- 用户看到：文件没有被选中

**单层文件（直接在根下）**：不触发此 bug，因为没有祖先目录需要展开。这解释了为什么"有时候能选中有时候不能"。

## 影响范围
- 终端 cmd+click 文件路径（经 `openResolvedTerminalPath`）
- 终端 Ghostty OSC 8 超链接（经 GHOSTTY_ACTION_OPEN_URL）
- 两者都走同一个 `revealInFileExplorer` 通知 + 同一个 `selectAndScroll`，因此修一处即可

## 修复方案

将 `restoreExpansionState` 的 for-range 改为 while-loop，动态读取 numberOfRows 以迭代展开新增的 rows：

```swift
private func restoreExpansionState(_ expandedPaths: Set<String>, in outlineView: NSOutlineView) {
    var row = 0
    while row < outlineView.numberOfRows {
        if let node = outlineView.item(atRow: row) as? FileExplorerNode,
           expandedPaths.contains(node.path),
           outlineView.isExpandable(node),
           !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
            // numberOfRows 增长，继续迭代刚添加的子行（row + 1 开始）
        }
        row += 1
    }
}
```

`!outlineView.isItemExpanded(node)` 防止已展开时重复调用 expandItem（幂等保护）。

## Bug 级别
**简单 Bug**：
- 单点 bug，根因明确，修复局部（1 个函数，5 行左右改动）
- 无架构影响、无数据迁移、无 API 变更
- 不涉及 UI 设计

## 变更记录
| 日期 | 变更 |
|------|------|
| 2026-04-16 | RD Bug 排查完成 |

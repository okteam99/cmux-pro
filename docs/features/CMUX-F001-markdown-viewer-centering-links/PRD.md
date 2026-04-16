# Markdown 阅读器：内容居中 + 内部链接在阅读器内打开

## 状态
草稿

## 背景
Markdown 阅读器当前存在两个体验问题：
1. 宽表格/代码块溢出 `.content` 容器（max-width: 820px），视觉上破坏了页面居中效果
2. 点击 MD 文件内的 `.md` 链接时，通过 `NSWorkspace.shared.open()` 打开（系统默认程序），而不是在阅读器内打开

## 功能需求

### P0 (必须)
- 内容容器添加 `overflow-x: auto`，让溢出内容在居中容器内水平滚动，保持视觉居中
- `.md` / `.markdown` 文件链接点击后在阅读器内打开新窗口（复用 `MarkdownViewerWindowManager.showWindow(for:)`），而非通过系统默认程序

## 交付预期（用户视角）

| 变化 | 验证方式 |
|------|----------|
| 宽表格/代码块在居中容器内水平滚动，不再溢出到右侧 | 打开含宽表格的 .md 文件，缩小窗口观察内容区域 |
| 点击 .md 链接在阅读器新窗口打开，而非系统默认程序 | 在阅读器中打开含 .md 链接的文件，点击链接 |

## 验收标准
- [ ] AC-1: 宽表格（>820px）在 `.content` 容器内水平滚动，容器本身保持页面居中
- [ ] AC-2: 宽代码块在 `.content` 容器内水平滚动
- [ ] AC-3: 点击 `.md` / `.markdown` 链接在阅读器窗口打开，不调用系统默认程序
- [ ] AC-4: 点击非 `.md` 链接（如 `.txt`、`http://`）行为不变，仍通过系统打开
- [ ] AC-5: 已打开的 `.md` 文件再次点击链接，聚焦已有窗口而非重复打开（复用现有 WindowManager 去重逻辑）

## 影响范围
- `Resources/MarkdownViewer/viewer.css` — CSS 溢出处理
- `Sources/MarkdownViewer/MarkdownViewerWindowController.swift` — 链接路由逻辑

## 变更记录
| 日期 | 变更 |
|------|------|
| 2026-04-16 | 初稿 |

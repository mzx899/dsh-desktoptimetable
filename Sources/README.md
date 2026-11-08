# Sources

这里只有**一套源码**。

A / B 不是两个源码目录，而是同一套代码里的两种渲染模式：

- **B（默认）**：`DesktopTimetable/UI/WebCardRenderer.swift` 的 live 分支，网页直接上屏。
- **A（回退）**：同一文件的 `snapshot()` + `UI/TimetableCardView.swift`，快照贴图。
- 切换：`RenderMode`，环境变量 `DT_SNAPSHOT=1` 强制 A。

因此：

- 不要新建 `Sources/A方案/`、`Sources/B方案/`，否则会复制代码并破坏 SwiftPM 构建。
- 两套模式的完整位置和运行方式见 `docs/渲染模式A-B.md`。
- 根目录只保留一个 `DesktopTimetable.app`（B）。

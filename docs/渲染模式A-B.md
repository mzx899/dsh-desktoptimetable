# 渲染模式 A / B

更新时间：2026-10-24

## 结论先行

A 和 B **不是两套源码**，而是同一份源码里的两条互斥渲染管线：

- **B（默认）**：WKWebView 直接上屏，零 `takeSnapshot`。
- **A（回退）**：WKWebView 渲染后 `takeSnapshot`，把图贴到原生 `TimetableCardView`。

因此源码只有一个 `Sources/`，根目录只保留一个 `DesktopTimetable.app`。
不要新建 `A方案/`、`B方案/` 源码或 App 目录——那会重复代码，并且让构建产物和源码混在一起。

## 源码位置

| 内容 | 文件 |
|---|---|
| 模式选择 | `Sources/DesktopTimetable/UI/WebCardRenderer.swift` → `RenderMode` / `liveMode` |
| B：网页直接上屏 | `WebCardRenderer.swift` 的 live 分支 |
| B：透明边距点击穿透 | `Sources/DesktopTimetable/UI/LiveModeSupport.swift` |
| B：网页悬停模拟 | `Sources/DesktopTimetable/App/AppDelegate.swift` 的全局鼠标监控 + `Resources/Timetable.js` |
| A：快照管线 | `WebCardRenderer.snapshot()` |
| A：原生贴图/命中测试 | `Sources/DesktopTimetable/UI/TimetableCardView.swift` |
| 两者共用的界面 | `Resources/Timetable.html`、`Timetable.css`、`Timetable.js` |

切换逻辑：

```swift
enum RenderMode {
    static let live: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["DT_SNAPSHOT"] == "1" { return false }  // A
        if env["DT_LIVE"] == "1" { return true }      // B
        return true                                   // 默认 B
    }()
}
```

## 怎么运行

```bash
make app          # 编译到 build/DesktopTimetable.app
make run          # 默认 B
make run-a        # 强制 A（DT_SNAPSHOT=1）
make install      # 只同步根目录 DesktopTimetable.app
make test
```

直接运行二进制时：

```bash
# B
./DesktopTimetable.app/Contents/MacOS/DesktopTimetable

# A
DT_SNAPSHOT=1 ./DesktopTimetable.app/Contents/MacOS/DesktopTimetable
```

## 目录约定

```
DesktopTimetable/
├── DesktopTimetable.app   # 唯一 App（B，双击启动）
├── Sources/               # 唯一源码；A/B 都在这里
├── Resources/             # 网页界面、图标、Info.plist
├── Tests/
├── docs/
│   ├── 渲染模式A-B.md
│   ├── screenshot.png
│   └── archive/           # 手动数据备份，不属于源码
├── Makefile
├── Package.swift
└── README.md
```

`build/`、`.build/` 是编译缓存，可随时 `make clean` 删除重建，不属于源码。

// swift-tools-version:5.9
import PackageDescription

// 说明：仓库的官方构建/测试入口是 `make`（见 Makefile），
// 只需要 Command Line Tools 就能编译，不依赖完整 Xcode。
// 这份 Package.swift 供使用 Xcode / SwiftPM 的人导入工程，只声明可执行目标。
// 测试是一个自带断言的运行器（Tests/main.swift），用 `make test` 执行。
let package = Package(
    name: "DesktopTimetable",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "DesktopTimetable",
            path: "Sources/DesktopTimetable"
        )
    ]
)

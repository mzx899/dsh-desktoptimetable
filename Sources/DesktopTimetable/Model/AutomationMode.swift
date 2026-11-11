import Foundation

/// 自动化模式识别。
///
/// 这些模式下**绝不**请求通知权限、注册登录项、发送真实通知：
///   · `--verify-*`（各种自检）
///   · `--render-card`（离屏出图）
///   · `--import`（命令行导入）
///   · `--dump-layout`（打印界面层级）
///   · 测试运行（可执行文件名以 `tests` 结尾，或 `DT_LIVE_TEST=1`）
///
/// 理由：自检会反复启�� app，任何一次「请求权限」「注册登录项」都会在
/// 用户机器上留下副作用（授权弹窗、指向 build 目录的失效登录项）。
enum AutomationMode {

    /// 会触发副作用的命令行开关。
    ///
    /// **每一个 `--verify-*` 都必须在这里登记**（`Tests/main.swift` 有一条断言盯着这件事）。
    ///
    /// 为什么这么要紧：自检会真的调起 app，`AppDelegate.reloadData()` 最后会调
    /// `refreshReminderSchedule()`。不在这个列表里 → 护栏不生效 → 走到
    /// `reminderScheduler.clearAll()`，**清掉同一个 bundle id 下用户真实排好的上课提醒**。
    /// （临时数据目录里 `reminder.enabled` 默认是 false，于是必然走到 clearAll。）
    static let automationFlags: [String] = [
        "--verify-timetables",
        "--verify-web-render",
        "--verify-snapshot-mode",
        "--verify-switch-refresh",
        "--verify-override-flow",
        "--verify-preview-refresh",
        "--verify-panel-scroll",
        "--verify-panel-sections",
        "--verify-panel-animation",
        "--verify-panel-click",
        // 设置面板「第一次打开在左下角」的回归自检（2026-11-11）。
        // 不登记的话它会以非自动化模式运行 → `reloadData()` 走到
        // `refreshReminderSchedule()` → 清掉用户真实排好的上课提醒。
        "--verify-settings-first-open",
        "--shot-panel-mid",
        // 设置面板出图入口。不登记的话它会以**非自动化模式**运行：
        // `reloadData()` 走到 `refreshReminderSchedule()` → 清掉用户真实排好的提醒。
        "--shot-settings",
        "--verify-finder-reveal",
        "--verify-wheel-routing",
        "--verify-reminder-plan",
        "--verify-settings-card",
        "--verify-data-buttons",
        "--verify-diary",
        "--verify-todo-digest",
        "--shot-import-diff",
        "--verify-period-save",
        "--verify-lead-custom",
        "--verify-hover",
        "--verify-card-scale",
        "--verify-scale-panel",
        "--verify-slider-scale",
        "--verify-scale-drag-edge",
        "--verify-collapse",
        "--verify-collapse-panel",
        "--verify-week-arrow",
        "--verify-import-flow",
        "--verify-focus-flow",
        "--verify-pin-flow",
        "--verify-day-panel",
        "--verify-day-panel-click",
        "--verify-todo-focus",
        "--verify-completed-reminders",
        "--verify-typing",
        "--render-card",
        "--shot-card-scale",
        // 网页层出图（缩放后的卡片）—— 它同样会走完整启动链路，必须按自动化跑。
        "--shot-web-card",
        "--render-pin",
        // 日期覆盖层的出图入口。不登记的话它们会以**非自动化模式**运行：
        // `reloadData()` 走到 `refreshReminderSchedule()` → 清掉用户真实排好的提醒。
        "--render-day-panel",
        "--shot-day-panel",
        "--import",
        "--dump-layout",
    ]

    /// 是不是自动化模式（纯函数，可单测）。
    ///
    /// - Parameter arguments: 通常传 `CommandLine.arguments`。
    static func isAutomation(arguments: [String]) -> Bool {
        // 命令行开关
        for flag in automationFlags where arguments.contains(flag) {
            return true
        }
        // 测试运行器（`make test` 产出 `build/tests`）
        if let exe = arguments.first, exe.hasSuffix("/tests") || exe.hasSuffix("tests") {
            // 可执行文件名恰好叫 tests —— 但 `--verify-*` 之外的普通测试
            // 也属于自动化，进一步用「没有 GUI 事件循环」来区分意义不大，
            // 这里直接按自动化处理（测试里不会真的发通知）。
            return true
        }
        // live 测试环境变量
        if let v = ProcessInfo.processInfo.environment["DT_LIVE_TEST"], v == "1" {
            return true
        }
        return false
    }

    /// 当前进程是不是自动化模式。
    static var isCurrentProcessAutomation: Bool {
        isAutomation(arguments: CommandLine.arguments)
    }
}

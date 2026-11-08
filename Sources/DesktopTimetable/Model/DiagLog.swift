import Foundation
import os

/// 统一的诊断日志（**只写系统日志，不改任何数据**）。
///
/// ⚠️ 为什么不用 `NSLog`：这个 app 是 LSUIElement，用户正常启动（`open`）时
/// `NSLog` 的输出**进不了统一日志** —— 实测 `log show --process DesktopTimetable`
/// 只能看到系统框架的日志，看不到 `[DesktopTimetable] …`。
/// 排查「有时成功、有时失败」这类问题就没有任何证据。
///
/// `os.Logger` + `privacy: .public` 一定会进统一日志，参数也不会被打码。
/// 读取方式：
///
///     /usr/bin/log show --last 30m --info \
///       --predicate 'subsystem == "com.desktoptimetable.diag"'
enum DiagLog {

    private static let logger = Logger(subsystem: "com.desktoptimetable.diag",
                                       category: "daypanel")

    /// 记一条诊断日志。
    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

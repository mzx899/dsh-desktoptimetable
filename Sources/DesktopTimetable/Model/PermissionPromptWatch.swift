import Foundation

/// 「系统权限弹框还开着的时候，课表不要淡出」的保持状态。
///
/// ## 为什么需要（2026-11-05）
///
/// 日历 / 提醒事项 / 定位 / 通知的授权框都是**系统进程**弹的窗口：
/// 层级比课表高、位置常在屏幕中间。用户把鼠标移过去点「允许 / 不允许」时：
///
///   · 指针离开了卡片矩形 → 原生判定「没悬停」→ 淡到 `minOpacity`；
///   · 弹框又比课表高 → 就算指针还在卡片矩形里也会被判成「被盖住」。
///
/// 用户设的是 `minOpacity = 0`，于是「淡下去」= **整张课表完全消失**。
/// 用户的原话：「点访问权的时候，课表还在」。
///
/// 所以真正的需求不是改 hover 判定，而是：**弹框期间不按指针状态决定可见性**，
/// 直接把课表钉在可见状态，等弹框结束（拿到授权回调）再恢复正常判定。
///
/// 用法：弹系统框之前 `begin("定位")`，拿到回调之后 `end("定位")`。
/// 多个框可能并行（日历 + 提醒事项），所以按**原因**分别记账，
/// 全部结束才解除保持。
enum PermissionPromptWatch {

    /// 一次保持最长多久（用户可能很久不点弹框，别把课表一直亮着）。
    ///
    /// ⚠️ **这个上限必须真的生效**（2026-11-05 修）：日历 + 提醒事项是**并行**
    /// 请求的，macOS 有时只弹一个框、另一个请求**永远不回调**（`DayPanelController`
    /// 里早写过这个坑）。没有逐项兜底时，那一笔 `begin` 就再也等不到 `end` ——
    /// 用户看到的是「修改完 / 取消后，鼠标移到课表外面，课表不消失」。
    ///
    /// 取 **10 秒**：和 `DayPanelController.requestAccess` 的收尾超时一致
    /// （10 秒内没回调就当作没回应）。正常点「允许」都在 1~2 秒内，
    /// 拿不到回调时最多亮 10 秒就会自己回落。
    static let defaultHoldSec: TimeInterval = 10

    /// 保持状态变化时回调（进入 / 退出）。`AppDelegate` 用它立刻重算一次 hover，
    /// 免得「弹框弹出来了、课表还在等下一次鼠标移动」。
    static var onStateChanged: ((Bool) -> Void)?

    /// 正在等回应的弹框原因（`"日历"` / `"提醒事项"` / `"定位"` / `"通知"`）。
    private static var reasons: Set<String> = []

    /// 这批弹框的保持截止时间。
    private static var holdUntil: Date = .distantPast

    /// 每个原因各自的兜底定时器（见 `begin(_:seconds:now:)`）。
    private static var expiryTimers: [String: DispatchWorkItem] = [:]

    // MARK: - 状态查询

    /// 现在要不要强制课表保持可见。
    static func isHolding(now: Date = Date()) -> Bool {
        !reasons.isEmpty && now < holdUntil
    }

    /// 正在等回应的弹框原因（自检 / 日志用）。
    static var activeReasons: [String] { reasons.sorted() }

    // MARK: - 记账

    /// 即将弹一个系统权限框 → 记一笔（可并行多个）。
    ///
    /// 同时给这一笔排一个**兜底超时**：到点还没 `end` 就自己销掉，
    /// 避免「请求挂住 → 课表一直亮着」。
    ///
    /// - Parameters:
    ///   - reason: 弹框原因，用中文短名（`"定位"` / `"日历"` …），只用于日志。
    ///   - seconds: 这次保持的最长时间。
    ///   - now: 注入时间（自检用）。
    static func begin(_ reason: String,
                      seconds: TimeInterval = defaultHoldSec,
                      now: Date = Date()) {
        let wasHolding = isHolding(now: now)
        reasons.insert(reason)
        holdUntil = now.addingTimeInterval(seconds)
        // 同一个原因重复 begin（例如用户连点两次添加）→ 以最后一次为准。
        expiryTimers[reason]?.cancel()
        let item = DispatchWorkItem {
            guard reasons.contains(reason) else { return }
            reasons.remove(reason)
            expiryTimers[reason] = nil
            if reasons.isEmpty { holdUntil = .distantPast }
            // 超时也要通知「退出保持」：否则课表要等下一次鼠标移动 / 10 秒
            // 巡检才回落，用户会看到「弹框早没了、课表还亮着」。
            onStateChanged?(false)
        }
        expiryTimers[reason] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        if !wasHolding { onStateChanged?(true) }
    }

    /// 某个权限框已经有回应了 → 销掉这一笔。
    ///
    /// 没记过账的原因直接忽略（例如系统根本不会弹框、走的是「已经授权」分支）。
    static func end(_ reason: String, now: Date = Date()) {
        guard reasons.remove(reason) != nil else { return }
        expiryTimers[reason]?.cancel()
        expiryTimers[reason] = nil
        if reasons.isEmpty {
            holdUntil = .distantPast
            onStateChanged?(false)
        }
    }

    /// 全部销掉（兜底：一批请求里有的挂住时用）。
    static func endAll(now: Date = Date()) {
        guard !reasons.isEmpty else { return }
        reasons.removeAll()
        for (_, timer) in expiryTimers { timer.cancel() }
        expiryTimers.removeAll()
        holdUntil = .distantPast
        onStateChanged?(false)
    }
}


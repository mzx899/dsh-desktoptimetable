import AppKit

/// 把 app 激活，并让 `w` 真的拿到 key window —— **一直重试到拿到为止**。
///
/// 为什么必须重试：
/// 1. **激活是异步的**：`NSApp.activate` 调用完那一瞬间 `NSApp.isActive` 还是 false，
///    要等事件循环转一圈才生效。
/// 2. **app 没真正激活时 `makeKeyAndOrderFront` 拿不到 key**：窗口看得见，但点击和
///    键盘都进不去 —— 正是用户报的「面板还在但点不动」。
/// 3. **accessory（LSUIElement）app 抢前台不一定一次成功**：实测 8 次里有 2 次
///    `isActive` 始终是 false；app 刚启动那会儿尤其容易被拒。
///
/// 为什么必须设终止条件（否则重试本身变成 bug 制造机）：
/// 每次重试都调 `makeKeyAndOrderFront` —— 窗口被关掉之后，**还在排队的重试会把它
/// 重新弹出来**。用户看到的就是「我点了应用，窗口关了，过一秒又自己冒出来」。
/// 终止条件：
/// - **拿到 key** → 成功，停。
/// - **调用方作废**（token 变了）→ 同一窗口被重新打开时，作废上一轮的重试。
/// - **窗口曾经摆到前面、现在又不见了** → 停。这条让「关掉的窗口被重试弹回来」
///   在结构上不可能发生，不依赖任何计数器。
/// - **预算用完** → 停（调用方负责提示）。
///
/// ⚠️ 「窗口不见了」这条**不能一开始就判**：调用方往往在窗口还没显示时就调进来
/// （`show()` 里激活），那时 `isVisible` 还是 false。所以只有**已经摆到前面过一次**
/// 之后才拿它当终止条件。
///
/// - Parameters:
///   - w: 要拿 key 的窗口。
///   - token: 本轮的令牌（调用方自增，用来作废在途重试）。
///   - currentToken: 读调用方当前令牌；返回的数与 `token` 不同说明本轮已作废。
///   - budget: 总预算（秒）。预算内拿不到 key 就放弃（调用方要负责提示）。
///   - onReady: 拿到 key（或预算用尽）之后回调一次。
func activateWindowAndTakeKey(
    _ w: NSWindow,
    token: Int,
    currentToken: @escaping () -> Int,
    budget: TimeInterval = 10,
    onReady: (() -> Void)? = nil
) {
    // 退避间隔（秒）：给系统时间把前台让出来。逐次拉长，最后一档 1.3s。
    let backoff: [TimeInterval] = [0.12, 0.2, 0.32, 0.5, 0.7, 0.9, 1.1, 1.3]
    let deadline = Date().addingTimeInterval(budget)
    var attempt = 0
    var ordered = false   // 是否已经摆到前面过

    func tryOnce() {
        // 已经拿到 key —— 收工。
        if w.isKeyWindow {
            onReady?()
            return
        }
        // 调用方作废了本轮（又打开了一次）—— 停。
        if token != currentToken() {
            return
        }
        // 预算用完 —— 停。
        if Date() >= deadline {
            onReady?()
            return
        }
        // 曾经摆到前面、现在又不见了（被关掉了）—— 停，别把它弹回来。
        if ordered && !w.isVisible {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        ordered = true

        let delay = backoff[min(attempt, backoff.count - 1)]
        attempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            tryOnce()
        }
    }

    tryOnce()
}

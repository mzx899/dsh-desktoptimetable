import AppKit

/// 模式 B（网页直接上屏）专用的辅助代码。
///
/// 模式 B 让 WKWebView 直接上屏显示，网页自己处理所有交互。
/// 这里解决「桌面层 + 非激活 + 非 key 窗口」下才出现的一个问题：
/// 卡片外的 90pt 投影边距不能吞掉点击 —— 用 hitTest 返回 nil 让点击穿透。
///
/// 悬停不走这里：桌面层窗口收不到 mouseMoved，CSS :hover 不触发，
/// 由 AppDelegate 的全局鼠标监控 → ttLiveHover(x,y) → 网页 .tt-hover 类桥接。
///
/// 这些辅助只在模式 B 下启用；不启用时完全不影响原有行为。

// MARK: - 边距点击穿透

/// 内容容器：卡片矩形以外的点一律不接管（hitTest 返回 nil），
/// 事件会继续往窗口下面传，桌面图标 / 下层窗口照常能点到。
final class LiveContainerView: NSView {

    /// 允许接收鼠标的区域（窗口坐标系）。默认是卡片矩形。
    var passthroughRect: NSRect = TimetableLayout.cardRect

    /// 日期覆盖层那一列的矩形（窗口坐标系，可选）。
    ///
    /// 折叠态下面板会从卡片底下伸出来，那一列也要算「在课表上」——
    /// 否则鼠标移进面板就被判成「离开了课表」：课表开始淡出、点击也穿透到桌面。
    var panelRect: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inCard = passthroughRect.contains(point)
        let inPanel = panelRect?.contains(point) ?? false
        guard inCard || inPanel else { return nil }
        return super.hitTest(point)
    }
}

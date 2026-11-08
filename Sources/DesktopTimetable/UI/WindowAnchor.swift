import AppKit

/// 「后续窗口以课表位置为锚点」的中心算法。
///
/// 规则（来自需求）：
///   · 所有 App 窗口（设置面板及其收放态、课程编辑器、确认 / 提示对话框、
///     导入相关窗口……）的**中心**都以**课表窗口当前中心**为准；
///   · 「当前」包括用户拖动后、以及固定后的最新位置；
///   · 按课表位置算出来的窗口如果超出屏幕可见区，**夹回可见区内**；
///   · 多显示器时以**课表所在的那块屏**为准。
///
/// 这套算法是纯计算，可以单测；真正摆窗口的地方只负责调用它。
enum WindowAnchor {

    /// 课表当前的锚点（屏幕坐标）。
    ///
    /// 由 AppDelegate 提供 —— 它是唯一知道课表窗口在哪的人。
    /// 没有课表窗口时（渲染自检等）退回主屏中心。
    static var provider: () -> NSPoint = {
        NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) }
            ?? .zero
    }

    /// 算出某个尺寸的窗口应该放在哪里（**左上角**原点）。
    ///
    /// - Parameters:
    ///   - size: 窗口尺寸。
    ///   - anchor: 锚点（默认取课表当前中心）。
    /// - Returns: 窗口原点（屏幕坐标系）。
    static func origin(forSize size: NSSize, anchor: NSPoint? = nil) -> NSPoint {
        let a = anchor ?? provider()
        let vf = visibleFrame(for: a)
        return origin(forSize: size, centeredAt: a, in: vf)
    }

    /// 算出某个尺寸的窗口应该放在哪里（**左上角**原点），锚点与可见区都给定。
    ///
    /// 纯计算：中心对齐锚点 → 再夹回可见区。
    static func origin(forSize size: NSSize, centeredAt center: NSPoint,
                       in visibleFrame: NSRect) -> NSPoint {
        var x = center.x - size.width / 2
        var y = center.y - size.height / 2

        // 夹回可见区：窗口必须完整可见（放不下就贴边）。
        let maxX = visibleFrame.maxX - size.width
        let maxY = visibleFrame.maxY - size.height
        x = maxX < visibleFrame.minX ? visibleFrame.minX : min(max(x, visibleFrame.minX), maxX)
        y = maxY < visibleFrame.minY ? visibleFrame.minY : min(max(y, visibleFrame.minY), maxY)
        return NSPoint(x: x, y: y)
    }

    /// 锚点所在屏幕的可见区。
    ///
    /// 多显示器：以**课表所在的那块屏**为准 —— 课表在第二块屏上，
    /// 弹窗就该出现在第二块屏上，而不是主屏。
    static func visibleFrame(for anchor: NSPoint) -> NSRect {
        let screen = TimetablePinState.screen(forPoint: anchor)
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 把窗口摆到「以课表为中心」的位置。
    ///
    /// 这是**所有**后续窗口的统一入口 —— 取代了原来「一律居中到屏幕正中」的逻辑。
    static func place(_ window: NSWindow, anchor: NSPoint? = nil) {
        let a = anchor ?? provider()
        let vf = visibleFrame(for: a)
        let origin = origin(forSize: window.frame.size, centeredAt: a, in: vf)
        window.setFrameOrigin(origin)
    }
}

import AppKit

/// 在任意屏幕位置弹出一个 NSMenu，且**不激活 App**。
///
/// 为什么不用 `NSMenu.popUp(positioning:at:in:)` 直接挂在桌面卡片窗口上：
/// 桌面卡片窗口是 level −1 的非激活面板，挂在它上面的菜单会被别的窗口盖住，
/// 而且菜单事件在 App 未激活时可能收不到。
///
/// 这里用一个临时的浮动面板（NSPanel，level .floating）当「菜单宿主」：
///  · 面板本身 1×1、透明、忽略鼠标，只用来给菜单一个定位参照；
///  · 菜单在面板坐标系里弹出，屏幕上就落在指定位置；
///  · 面板是 nonactivatingPanel，所以弹菜单不会把别的 App 的焦点抢走。
///
/// 菜单项的 target/action 由调用方自己设置（`ScheduleEditorController`），
/// 本类只负责「弹出来」。
enum MenuPresenter {

    /// 自动化测试用：菜单弹出来后的回调（记录菜单内容）。
    static var onMenuBuilt: ((NSMenu) -> Void)?
    /// 自动化测试用：只构造菜单，不真的弹（避免测试进程被模态菜单卡住）。
    static var suppressPresentation = false
    /// 自动化测试用：最近一次构造的菜单（用来模拟点击某一项）。
    static var lastMenu: NSMenu?

    /// 自动化测试用：最近一次「菜单可见性」通知（true = 打开，false = 关闭）。
    ///
    /// ⚠️ `present()` 在 `suppressPresentation` 为真时**不会**置位（它提前返回），
    /// 所以自检要验「置位 / 清位」这一对通知，用这个记录。
    static var lastVisibilityEvents: [Bool] = []

    /// **菜单打开期间**的回调（true = 菜单开着，false = 已关闭）。
    ///
    /// ⚠️ **为什么需要这个**（2026-11 修「点删除时整个日历闪一下」）：
    ///
    /// 菜单是用一个临时的 `NSPanel`（level .floating）当宿主的。菜单一弹出，
    /// **指针就移到菜单上了** —— 而菜单在课表卡片的矩形之外。
    /// 于是原生侧的「指针是否在卡片上」判定翻转 → 判定「指针离开了课表」
    /// → 网页把**日期覆盖层收走了**（用户看到「闪一下」）。
    ///
    /// 课程右键菜单从 1.0.x 起就有这个问题，但**课表卡片本身不响应**
    /// 「指针离开」，所以看不出来；只有**日期覆盖层**会跟着收走。
    ///
    /// 这里在弹菜单前通知网页「菜单开着」，菜单关闭后再通知一次 ——
    /// 网页在这期间**不因指针离开而收覆盖层**。
    ///
    /// 由 `AppDelegate` 装上（它才有网页渲染器）。
    static var onMenuVisibilityChanged: ((Bool) -> Void)?

    /// 菜单**当前是否开着**（诊断用）。
    static var isMenuShowing = false

    /// 弹出菜单（同步阻塞到菜单关闭）。
    ///
    /// - Parameters:
    ///   - menu: 要弹的菜单（调用方已经设置好 target/action）。
    ///   - screenPoint: 屏幕坐标（AppKit 坐标，原点在左下）。
    ///   - opensLeft: **菜单往左弹**（默认往右弹）。
    ///
    ///     ⚠️ 为什么要这个（2026-11 修「点删除后整个日历闪一下」）：
    ///
    ///     菜单往右弹时，菜单项落在**指针的右边**。日期覆盖层在课表的
    ///     **最后一列**（最靠右），菜单往右弹就会**超出卡片右边缘**
    ///     （实测超出约 60pt，还会被屏幕边切掉）。
    ///
    ///     菜单一关，宿主面板消失 → 指针停在菜单原处 → 那个位置
    ///     **在卡片矩形之外** → 原生判定「指针离开了课表」→
    ///     **整个课表 6 秒淡到 22%**（用户看到「闪一下」/「课表不见了」）。
    ///
    ///     往左弹的话，菜单项落在指针左边（还在卡片里），
    ///     指针始终在卡片矩形内 → 课表不会淡出。
    ///
    ///     课程右键菜单不用这个 —— 它弹在卡片**中部**，往右弹也还在卡片里。
    static func present(_ menu: NSMenu, at screenPoint: NSPoint, opensLeft: Bool = false) {
        lastMenu = menu
        onMenuBuilt?(menu)

        // ⚠️ **先通知网页「菜单开着」**，再弹菜单。
        //
        // 菜单弹出的那一瞬间指针就会离开卡片 —— 通知必须**早于**弹菜单，
        // 否则网页会先收到「指针离开」把覆盖层收走（用户看到「点删除时闪一下」）。
        //
        // ⚠️ 这一对通知**成对出现**：`defer` 保证「菜单关了」一定会发，
        // 哪怕弹菜单过程中抛了异常 —— 否则网页的标志会永远停在 true，
        // 覆盖层就再也收不起来了。
        onMenuVisibilityChanged?(true)
        isMenuShowing = true
        lastVisibilityEvents.append(true)
        defer {
            isMenuShowing = false
            onMenuVisibilityChanged?(false)
            lastVisibilityEvents.append(false)
        }

        if suppressPresentation { return }

        // ⚠️ **往左弹**：把定位点往左挪「菜单宽度 - 一点」，
        // 菜单的**左边缘**就落在指针左边（`popUp` 的 at 点是菜单左上角）。
        //
        // 不这么做的话，最右列的菜单会伸出卡片右边缘 —— 菜单一关，
        // 指针就落在卡片外面 → 整个课表淡出（用户看到「闪一下」）。
        var origin = screenPoint
        if opensLeft {
            let width = menu.size.width
            if width > 1 { origin.x -= (width - 6) }
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        // 菜单的定位点用宿主面板的坐标系（0,0 = 屏幕上的弹出点）。
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: panel.contentView!)

        panel.orderOut(nil)
    }
}

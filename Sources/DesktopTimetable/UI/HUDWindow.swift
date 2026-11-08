import AppKit

/// HUD 面板窗口的统一样式。
///
/// 关键点是 `.fullSizeContentView` —— **少了它，窗口顶部会留一条 32pt 的透明标题栏**：
///
///   · 交通灯浮在那条带上。它背后是桌面/别的窗口，和下面 HUD 面板不是一个颜色，
///     看上去按钮和面板**脱节**，中间还有一条明显的横向断层；
///   · 窗口的**顶部圆角被那条方形带盖掉** —— 上直角、下圆角，四个角不一致，
///     边框看着就是坏的。
///
/// 加上它，内容视图铺满整个窗口，HUD 材质从交通灯一路铺到窗口底部，
/// 四个圆角一致，红绿灯落在材质上 —— 和「课表设置」面板完全一致。
///
/// 参考实现：`SettingsWindowController.buildWindow()`。
enum HUDWindow {

    /// 建一个 HUD 面板窗口。
    ///
    /// - Parameters:
    ///   - title: 窗口标题（`titleVisibility = .hidden`，所以不显示出来）。
    ///   - size: 内容尺寸 —— 因为内容视图铺满整个窗口，它就是**窗口尺寸**。
    ///   - miniaturizable: 是否带最小化按钮。
    ///   - showsFullScreen: 是否显示全屏按钮。
    ///     固定尺寸的表单弹窗里那个按钮永远是**灰的（不可用）**，
    ///     看上去像一个渲染坏了的灰点 —— 直接藏掉。
    static func make(title: String,
                     size: NSSize,
                     miniaturizable: Bool = true,
                     showsFullScreen: Bool = false) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if miniaturizable { mask.insert(.miniaturizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: mask,
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        // 层级抬到 .floating：设置面板也是这一层，弹窗后开的自然排在它前面；
        // 而且 accessory App 在非前台时，正常层级的窗口会排到别的 App 后面。
        window.level = .floating
        if !showsFullScreen {
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        centerOnScreen(window)
        return window
    }

    /// 把窗口摆到**以课表为中心的锚点**上。
    ///
    /// ⚠️ 以前这里是「一律居中到屏幕正中间」——
    /// 课表拖到屏幕左下角时，弹窗却出现在屏幕正中，两者离得老远。
    /// 现在所有后续窗口都以**课表窗口当前中心**为锚点
    /// （见 `WindowAnchor`），并夹回所在屏幕的可见区。
    ///
    /// 为什么不直接 `window.center()`：这台机器（macOS 26）上 `center()` 会把窗口
    /// 摆到偏上 170pt 的位置 —— 实测 213 高的窗口该在 y=395，`center()` 给了 565。
    /// 而且 `center()` 摆的是**屏幕**中心，不是课表中心。
    static func centerOnScreen(_ window: NSWindow, near mouse: NSPoint? = nil) {
        let size = window.frame.size
        // 锚点：课表当前中心（`WindowAnchor.provider` 由 AppDelegate 接线）。
        // `mouse` 参数保留是为了兼容老调用点 —— 现在**不再**用鼠标位置决定落点，
        // 只用它决定「多屏时落在哪块屏」这件事（锚点所在屏优先）。
        let anchor = WindowAnchor.provider()
        let vf = WindowAnchor.visibleFrame(for: anchor)
        window.setFrameOrigin(WindowAnchor.origin(forSize: size, centeredAt: anchor, in: vf))
    }

    /// 「窗口摆在哪」的**纯计算**（可单测）。
    ///
    /// 规则：
    ///   · 水平永远居中；
    ///   · 垂直居中 —— 但窗口比可见区还高时，**上边缘对齐可见区顶部**
    ///     （不然底边会掉到屏幕外面去）。
    ///
    /// 多屏时由调用方决定用哪块屏的 `visibleFrame`
    /// （设置面板用「面板自己所在的屏」，不用「鼠标所在的屏」——
    ///  扩张动画期间鼠标可能已经移到别的屏上了）。
    static func centeredOrigin(size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        let x = visibleFrame.midX - size.width / 2
        let y = size.height >= visibleFrame.height
            ? visibleFrame.maxY - size.height
            : visibleFrame.midY - size.height / 2
        return NSPoint(x: x, y: y)
    }

    /// 铺上 HUD 材质层 + 内容层，返回内容层（调用方往里塞自己的视图）。
    ///
    /// 材质层铺满整个内容视图 = 铺满整个窗口，所以顶部不会有透明带。
    @discardableResult
    static func installContent(in window: NSWindow, root: NSView) -> NSView {
        guard let content = window.contentView else { return root }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(effect)

        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: content.topAnchor),
            effect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        return root
    }

    /// 交通灯占用的区域（内容视图坐标系，原点在左上）。
    ///
    /// 内容视图铺满窗口后，红绿灯就浮在内容层的左上角 ——
    /// 自绘标题/内容必须避开这块，否则会压在一起。
    static let trafficLightBand = CGFloat(24)
    /// 交通灯最后一个按钮的右边缘（x）。红绿灯区约 x = 13…67。
    static let trafficLightRight = CGFloat(67)

    /// 在材质层上压一层深色底。
    ///
    /// HUD 材质在浅色系统下是「浅底 + 黑字」，而且很透 ——
    /// 弹窗压在白色背景（白墙、白文档、浅色 App）上几乎看不清文字。
    /// 压一层 `α 0.82` 的深色：几乎不透明，但还留一点材质的质感。
    ///
    /// - Parameters:
    ///   - window：目标窗口。
    ///   - root：内容层（深色底要插在它**下面**，否则会把内容盖住）。
    @discardableResult
    static func installDarkBackdrop(in window: NSWindow,
                                     below root: NSView,
                                     alpha: CGFloat = 0.82) -> NSView? {
        guard let content = window.contentView else { return nil }
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.10,
                                                  blue: 0.12, alpha: alpha).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backdrop, positioned: .below, relativeTo: root)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        return backdrop
    }
}

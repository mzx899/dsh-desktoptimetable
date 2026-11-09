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
        // 边缘「假光」：压在内容**最上层**（不吃鼠标事件）。
        installRimLight(in: window)
        return root
    }

    /// 弹窗的圆角（跟窗口自身的圆角走，这里只是画假光用的近似值）。
    static let rimRadius: CGFloat = 12

    /// 边缘假光（2026-11-09）。
    ///
    /// 用户原话：「在边缘处打点假光，然后整个的颜色不要那么的深，
    /// 稍微有一点点毛玻璃质感」。
    ///
    /// 做法（纯视觉，不碰布局）：
    ///   1. 一圈 1pt 的白色描边 —— 上亮下暗（渐变），像玻璃边缘反光；
    ///   2. 顶部再叠一层很淡的内高光渐变（从 α 0.10 收到 0），
    ///      让顶边看起来是「亮的」，底边是「沉的」；
    ///   3. `hitTest` 返回 nil —— 只是一层光，不能挡点击。
    private static func installRimLight(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let rim = HUDGlassRimView()
        rim.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rim)
        NSLayoutConstraint.activate([
            rim.topAnchor.constraint(equalTo: content.topAnchor),
            rim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
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
    ///
    /// ⚠️ 2026-11-09 调整：以前是 `α 0.82` 的近实心黑，用户反馈
    /// 「整个的颜色不要那么的深，稍微有一点点毛玻璃质感」——
    /// 现在改成**上浅下深的竖向渐变**（`α 0.62` 冷灰 → `α 0.70` 更深）：
    /// 毛玻璃透得上来，又不像纯黑那样「一块实心板」。
    ///
    /// - Parameters:
    ///   - window：目标窗口。
    ///   - root：内容层（深色底要插在它**下面**，否则会把内容盖住）。
    @discardableResult
    static func installDarkBackdrop(in window: NSWindow,
                                     below root: NSView,
                                     alpha: CGFloat = 0.86) -> NSView? {
        guard let content = window.contentView else { return nil }
        let backdrop = HUDGlassBackdropView(tintAlpha: alpha)
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

/// 弹窗边缘的「假光」层：一圈上亮下暗的描边 + 顶部内高光。
///
/// 弹窗的深色玻璃底：竖向渐变的冷灰 + 顶部一道很淡的提亮。
///
/// 用独立类（而不是在 `installDarkBackdrop` 里塞几个 `CAGradientLayer`）是因为
/// **图层必须有 frame**：直接 `addSublayer` 不设 frame 的渐变是**零尺寸、画不出来**
/// （2026-11-09 第一版就是这个毛病 —— 出图只有一条硬边带，没有渐变）。
/// 这里统一在 `layout()` 里铺满 bounds。
final class HUDGlassBackdropView: NSView {

    private let base = CAGradientLayer()
    private let glow = CAGradientLayer()

    init(tintAlpha alpha: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = HUDWindow.rimRadius

        // 底色：上（略亮、偏冷）→ 下（更深），假玻璃的厚度感。
        base.colors = [
            NSColor(srgbRed: 0.12, green: 0.14, blue: 0.20, alpha: alpha).cgColor,
            NSColor(srgbRed: 0.09, green: 0.11, blue: 0.16, alpha: alpha + 0.02).cgColor,
            NSColor(srgbRed: 0.06, green: 0.08, blue: 0.12, alpha: alpha + 0.04).cgColor,
        ]
        base.locations = [0, 0.5, 1]
        base.startPoint = CGPoint(x: 0.5, y: 1)
        base.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(base)

        // 「光从上下来」：顶部再叠一层极淡的白色渐变。
        glow.colors = [
            NSColor.white.withAlphaComponent(0.055).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor,
        ]
        glow.locations = [0, 0.5, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(glow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        glow.frame = bounds
        CATransaction.commit()
    }
}

/// 单独一个视图（而不是直接改 backdrop 的 border）是因为它要压在最上层：
/// 底下的内容（图标 / 卡片）不能把光盖掉，而且它自己不接点击。
///
/// ⚠️ 用 **CALayer 渐变 + 描边遮罩**，不用 `draw(_:)` 的 `destinationOut`：
/// 后者在弹窗这种「内容层已经被 AppKit 摊平成 layer」的层级里会把环一起擦掉
/// （2026-11-09 实测：出图只剩一条很淡的顶带宽，四周没有边）。
final class HUDGlassRimView: NSView {

    private let rimGradient = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let topGlow = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = HUDWindow.rimRadius

        // 外圈：上亮（α 0.40）→ 中（0.18）→ 下（0.10）。
        rimGradient.colors = [
            NSColor.white.withAlphaComponent(0.45).cgColor,
            NSColor.white.withAlphaComponent(0.26).cgColor,
            NSColor.white.withAlphaComponent(0.14).cgColor,
        ]
        rimGradient.locations = [0, 0.45, 1]
        // CALayer 的 y 轴朝上：y=1 是顶边。
        rimGradient.startPoint = CGPoint(x: 0.5, y: 1)
        rimGradient.endPoint = CGPoint(x: 0.5, y: 0)
        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1.2
        rimGradient.mask = rimMask
        layer?.addSublayer(rimGradient)

        // 顶部内高光：从上往下淡出（假玻璃的「光从上面来」）。
        topGlow.colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.035).cgColor,
            NSColor.clear.cgColor,
        ]
        topGlow.locations = [0, 0.45, 1]
        topGlow.startPoint = CGPoint(x: 0.5, y: 1)
        topGlow.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(topGlow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不吃鼠标事件：它只是一层光。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rimGradient.frame = b
        topGlow.frame = b
        let ring = CGRect(x: 0.7, y: 0.7, width: b.width - 1.4, height: b.height - 1.4)
        rimMask.path = CGPath(roundedRect: ring,
                              cornerWidth: HUDWindow.rimRadius,
                              cornerHeight: HUDWindow.rimRadius,
                              transform: nil)
        CATransaction.commit()
    }
}

import AppKit

/// 课表左上角的**图钉按钮**。
///
/// 两种状态**只有「空心 / 实心」这一个区别**：
///   · **空心** —— 未固定（课表可以拖动）
///   · **实心** —— 已固定（位置锁住，拖不动）
///
/// 用同一套 SF Symbol 的两种字重形态（`pin` / `pin.fill`）：
/// 形状、大小、颜色、位置完全一致，只有内部填没填满。
/// 以前是两张不同的 PNG + 白/黑染色，缩到 17pt 时既糊又对不齐，
/// 而且 PNG 没打进 .app，运行时其实一直走的是 `pin.slash` 兜底
/// （空心还多一道斜杠，根本不像同一枚图钉）。
///
/// 位置：卡片左上角、标题「我的课表」的**右边**，与标题同一条水平线
/// （垂直居中对齐）—— 不压标题文字，也不占标题块后面的空白。
final class PushPinButton: NSView {

    /// 按钮的点击回调（带当前固定状态）。
    var onToggle: ((Bool) -> Void)?

    /// 是否已固定。
    var isPinned: Bool = false {
        didSet {
            guard isPinned != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 图标边长（pt）。
    static let iconSize: CGFloat = 17
    /// 按钮热区边长（pt）—— 比图标略大，点起来不费劲。
    static let buttonSize: CGFloat = 20
    /// 图钉与标题文字之间的间距（pt）。
    static let gapToTitle: CGFloat = 8

    /// 标题文字在窗口里的左边距：卡片内边距 18 + `.top` 内边距 2。
    static let titleLeftInset: CGFloat = 20
    /// 标题行中心距卡片上沿的距离（CSS 实测：`.ttl` 中心在卡片顶下 36pt）。
    static let titleCenterFromCardTop: CGFloat = 36
    /// 标题块固定宽度（CSS `.brand { width: 210px }`）。
    /// 超过这个宽度的标题会被省略号裁掉，图钉就摆在裁剪边缘之后。
    static let maxTitleWidth: CGFloat = 210

    /// 两种状态共用的颜色 —— **只换形状，不换颜色**。
    ///
    /// 卡片本身是深色底，图钉固定用浅色；再配一圈很淡的阴影，
    /// 深浅壁纸下都能看清。
    private static let tint: NSColor = NSColor(calibratedWhite: 0.97, alpha: 0.96)

    /// 视觉是否交给网页层画（2026-11-08）。
    ///
    /// 图钉原来是原生控件，缩放时它和卡片里的标题文字各自按自己的节奏刷新 ——
    /// 跨进程（WKWebView）永远差一帧，看起来就是「图钉闪 / 跟不上标题」。
    /// 现在**视觉**由网页里的 `<img class="ttlpin">` 画（和标题同一个 DOM、
    /// 同一个 transform），这个原生按钮只留作**透明点击热区**（以及自检用的矩形）。
    var drawsInWeb = false

    /// 缩放系数（跟随课表卡片大小）。
    ///
    /// 图钉是**原生控件**，不会跟着 `pageZoom` / CSS transform 缩放 ——
    /// 卡片缩到 70% 时图钉还是原尺寸，看起来会比卡片大一圈（比例不对）。
    /// 由 `layoutPinButton()` 每次按 `TimetableLayout.scale` 设进来。
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 缓存的「基础尺寸」图标（17pt，不随 scale 变）。
    ///
    /// ⚠️ **缩放拖动时每帧重新生成 symbol 太贵**（`NSImage(systemSymbolName:)`
    /// + `withSymbolConfiguration` 每帧一次，实测会让图钉掉帧、看起来「闪」、
    /// 和卡片里的标题文字不同步）。这里只按「空心 / 实心」缓存一次，
    /// 绘制时按 `scale` 缩放画进 bounds（一次普通位图 blit）。
    private var cachedBaseIcon: NSImage?
    private var cachedBaseIconPinned: Bool?

    private func baseIcon() -> NSImage? {
        if let img = cachedBaseIcon, cachedBaseIconPinned == isPinned { return img }
        let img = icon(pinned: isPinned, scale: 1)
        cachedBaseIcon = img
        cachedBaseIconPinned = isPinned
        return img
    }

    /// 按固定状态取图标。
    ///
    /// 两个 symbol 用**同一套配置**（字号 / 字重 / 放大比例都相同），
    /// 所以切换时只有「空 → 实」，不会跳大小、跳位置。
    private func icon(pinned: Bool, scale: CGFloat? = nil) -> NSImage? {
        let name = pinned ? "pin.fill" : "pin"
        guard let base = NSImage(systemSymbolName: name,
                                 accessibilityDescription: "固定课表") else { return nil }
        let s = scale ?? self.scale
        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize * s,
                                                 weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Self.tint]))
        return base.withSymbolConfiguration(config)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 缩放拖动时窗口在逐帧移动：走图层（合成器搬运）比每次重画整块窗口稳，
        // 图钉本身只有一小块，layer 化之后不再跟着窗口重绘闪一下。
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    /// 标题文字的宽度（pt）—— 用网页同一套字号 / 字重 / 字距量出来。
    ///
    /// CSS `.ttl`：15px、600、letter-spacing 0.2px；标题块最宽 210px 后省略。
    /// `scale` 与卡片缩放一致（网页里的字号也会 ×scale）。
    static func titleWidth(_ title: String, scale: CGFloat = 1) -> CGFloat {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 15 * scale, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: 0.2 * scale]
        let width = (trimmed as NSString).size(withAttributes: attrs).width
        return min(width, maxTitleWidth * scale)
    }

    /// 图钉在**交互层 / 窗口坐标系**里的矩形。
    ///
    /// 放在卡片左上角、标题文字的右边，并与标题行垂直居中对齐。
    /// 位置随标题文字宽度走 —— 改名后图钉仍紧贴在标题右侧。
    /// `scale` = 卡片缩放：尺寸和间距一起等比，保持与卡片一致的比例。
    static func rect(inCard cardRect: NSRect, title: String, scale: CGFloat = 1) -> NSRect {
        let s = max(0.1, scale)
        let size = buttonSize * s
        let x = cardRect.minX + (titleLeftInset + gapToTitle) * s
            + titleWidth(title, scale: s)
        let centerY = cardRect.maxY - titleCenterFromCardTop * s
        return NSRect(x: x, y: centerY - size / 2, width: size, height: size)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 视觉已经交给网页层（和标题同一条流水线）→ 原生这层不画。
        guard !drawsInWeb else { return }
        // 用缓存的基础图标缩放绘制（拖动缩放时每帧只做一次 blit）。
        guard let img = baseIcon() else { return }
        let box = min(Self.iconSize * scale, bounds.width, bounds.height)
        let size = img.size
        guard size.width > 0, size.height > 0 else { return }
        let fit = min(box / size.width, box / size.height)
        let drawSize = NSSize(width: size.width * fit, height: size.height * fit)
        let target = NSRect(x: bounds.midX - drawSize.width / 2,
                            y: bounds.midY - drawSize.height / 2,
                            width: drawSize.width, height: drawSize.height)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3 * scale
        shadow.shadowOffset = .zero
        shadow.set()
        img.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 交互

    /// 悬停时显示可点击光标。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // 点一下就切换：空心 → 实心（固定），实心 → 空心（解锁）。
        isPinned.toggle()
        onToggle?(isPinned)
    }

    // MARK: - 自检

    /// 自检用：按钮当前的固定状态。
    var testIsPinned: Bool { isPinned }

    /// 网页层用的图钉图片（PNG → data URI）。
    ///
    /// 视觉搬进网页后，图标还是用同一套 SF Symbol —— 由原生渲染成 2x PNG
    /// 以 data URI 注入网页，保证和「原来的图钉」长得一模一样。
    static func pngDataURI(pinned: Bool) -> String? {
        let probe = PushPinButton(frame: .zero)
        probe.isPinned = pinned
        // 2x 渲染：视网膜屏上不糊；网页里按 17px 显示。
        guard let img = probe.icon(pinned: pinned, scale: 2),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // ⚠️ 必须是完整的 data URI：只给 base64 会被当成相对 URL，图直接裂。
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// 自检用：把某种状态的图钉**图标**渲染出来（不含按钮热区）。
    static func renderIconForTest(pinned: Bool) -> NSImage? {
        let probe = PushPinButton(frame: .zero)
        probe.isPinned = pinned
        return probe.icon(pinned: pinned)
    }

    /// 自检用：图里「实心」像素**占整张画布的比例**（0…1）。
    ///
    /// 两种 symbol 的画布一样大，所以密度直接反映「填了多少」——
    /// 实心明显高于空心。
    static func inkDensityForTest(of image: NSImage) -> Double {
        let pixels = pixelsForTest(of: image)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        let total = rep.pixelsWide * rep.pixelsHigh
        guard total > 0 else { return 0 }
        return Double(pixels) / Double(total)
    }

    /// 自检用：数一数图里有多少个「实心」像素（alpha 超过一半的）。
    static func pixelsForTest(of image: NSImage) -> Int {
        // 用 PNG 往返 —— TIFF 会带上 alpha 预乘，阈值判断容易不准。
        guard let png = image.tiffRepresentation.flatMap({ tiff in
            NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }), let rep = NSBitmapImageRep(data: png) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y),
                   color.alphaComponent > 0.5 {
                    count += 1
                }
            }
        }
        return count
    }
}

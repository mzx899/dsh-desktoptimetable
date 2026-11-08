import AppKit

/// 课程颜色选择器 —— 编辑器课程级区域里的「颜色」那一行。
///
/// 结构：最左「自动（按课名）」+ 12 个预设色圆点 + 最右「自定义颜色」，一行放得下。
/// 最右的色块点开系统色池，可选任意 `#rrggbb`。
/// 选中态是**圆环 + 对勾**（圆点太小放不下对勾时退化成圆环），
/// 每个选项都有 tooltip（自动色的含义 / 色名 + 色值 / 自定义色）。
///
/// 颜色值本身由 `ColorHex` 统一解析（唯一真源），这里只管画和点，
/// 不自己判断颜色合不合法。
///
/// 宽度不够时先压色块之间的间距、再压色块直径（最小 11pt），
/// 绝不撑破 460 宽的编辑器窗口。
final class CourseColorPickerView: NSView {

    /// 控件高度（编辑器里就占这么高）。
    static let rowHeight: CGFloat = 26

    /// 当前选中的颜色；`nil` = 自动（按课名自动配色）。
    private(set) var selectedHex: String?

    /// 选中项变了（编辑器用它清掉旧错误提示）。
    var onChange: (() -> Void)?

    private let chipText = "自动（按课名）"
    private let chipFont = NSFont.systemFont(ofSize: 10.5)

    /// 「自动」胶囊的框。
    private var chipRect: NSRect = .zero
    /// 12 个预设色块的框（下标和 `ColorHex.presets` 对齐）。
    private var swatchRects: [NSRect] = []
    /// 最右「自定义颜色」色块的框。
    private var customRect: NSRect = .zero
    /// tooltip 标签 → 文案。
    private var toolTipStrings: [NSView.ToolTipTag: String] = [:]
    /// 系统色池当前是不是挂在自身上（关闭编辑器时要摘掉）。
    private var colorPanelAttached = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // 宽度由行给它（和文本字段一样：拉伸填满剩余宽度）。
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    // MARK: - 选中

    /// 设置选中项（`nil` = 自动）。程序设置，不触发 `onChange`。
    func setSelected(_ hex: String?) {
        let new = ColorHex.normalized(hex)
        guard new != selectedHex else { return }
        selectedHex = new
        needsDisplay = true
    }

    /// 当前选中的是不是「不在 12 个预设里」的自定义色。
    private var customHex: String? {
        guard let h = selectedHex, !ColorHex.presetHexes.contains(h) else { return nil }
        return h
    }

    /// 真正的选中动作：变了才通知。
    private func choose(_ hex: String?, notify: Bool) {
        let new = ColorHex.normalized(hex)
        guard new != selectedHex else { return }
        selectedHex = new
        needsDisplay = true
        if notify { onChange?() }
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 0, b.height > 0 else {
            chipRect = .zero
            swatchRects = []
            return
        }

        // 12 个预设 + 1 个「自定义颜色」。
        let count = ColorHex.presets.count + 1
        let chipH = min(b.height - 2, 22)
        let chipW = min(120, ceil(textWidth(chipText, font: chipFont) + 12))
        chipRect = NSRect(x: 0, y: (b.height - chipH) / 2, width: chipW, height: chipH)

        let gapAfterChip: CGFloat = 8
        let preferredGap: CGFloat = 4.5
        let minGap: CGFloat = 2
        let available = max(0, b.width - chipW - gapAfterChip)

        // 色块直径：按行高定上限，再按剩余宽度压下来（最小 11）。
        // 优先保住「间距」—— 色块挤成一排时，宁可小一点也要留呼吸感。
        var size = min(20, max(14, b.height - 6))
        var gap = preferredGap
        if count > 0 {
            let fit = (available - gap * CGFloat(count - 1)) / CGFloat(count)
            if fit < size {
                size = max(11, fit)
                if size <= 11.001 {
                    // 缩到最小还放不下 → 只能继续压间距
                    gap = count > 1
                        ? max(minGap, (available - CGFloat(count) * 11) / CGFloat(count - 1))
                        : 0
                }
            } else if count > 1 {
                // 有富余就把间距撑开一点（最多 8），视觉上更透气
                gap = min(8, (available - CGFloat(count) * size) / CGFloat(count - 1))
            }
        }

        var x = chipW + gapAfterChip
        var rects: [NSRect] = []
        rects.reserveCapacity(count)
        for _ in 0..<count {
            rects.append(NSRect(x: x, y: (b.height - size) / 2, width: size, height: size))
            x += size + gap
        }
        // 最后一个留给「自定义」；前面 12 个仍是预设色。
        customRect = rects.last ?? .zero
        swatchRects = Array(rects.dropLast())

        // tooltip：自动色的含义 / 每个色块的色名 + 色值 / 自定义色。
        removeAllToolTips()
        toolTipStrings.removeAll()
        let chipTag = addToolTip(chipRect, owner: self, userData: nil)
        toolTipStrings[chipTag] = "自动（按课名）：颜色跟着课名走"
        for (i, preset) in ColorHex.presets.enumerated() where swatchRects.indices.contains(i) {
            let tag = addToolTip(swatchRects[i], owner: self, userData: nil)
            toolTipStrings[tag] = "\(preset.name) \(preset.hex.uppercased())"
        }
        let customTag = addToolTip(customRect, owner: self, userData: nil)
        toolTipStrings[customTag] = customHex
            .map { "自定义 \($0.uppercased())" } ?? "自定义颜色…"
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawChip()
        for (i, rect) in swatchRects.enumerated() where ColorHex.presets.indices.contains(i) {
            let hex = ColorHex.presets[i].hex
            drawSwatch(hex: hex, in: rect, selected: selectedHex == hex)
        }
        drawCustomSwatch(in: customRect)
    }

    /// 最右的「自定义颜色」色块。
    ///
    /// - 已经选了自定义色 → 直接画成那个颜色（选中态和预设色一致）；
    /// - 没选 → 画一圈彩虹环 + 白色加号，表示「可以自己调」。
    private func drawCustomSwatch(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        if let hex = customHex {
            drawSwatch(hex: hex, in: rect, selected: true)
            return
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let lineWidth = max(2, rect.width * 0.19)
        let radius = max(0, (min(rect.width, rect.height) - lineWidth) / 2)
        let count = ColorHex.presets.count
        guard radius > 0, count > 0 else { return }

        // 一整圈平均切成 12 段，用预设色描边 → 看起来像色轮。
        let step = 360 / CGFloat(count)
        for (i, preset) in ColorHex.presets.enumerated() {
            let start = CGFloat(i) * step - 90
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: start, endAngle: start + step + 1)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .butt
            TimetablePalette.color(hex: preset.hex).setStroke()
            arc.stroke()
        }

        // 外圈细描边，和预设色块保持一致。
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.12).setStroke()
        border.stroke()

        // 中间一个白色加号。
        let arm = rect.width * 0.18
        let plus = NSBezierPath()
        plus.lineWidth = max(1.2, rect.width * 0.075)
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: center.x - arm, y: center.y))
        plus.line(to: NSPoint(x: center.x + arm, y: center.y))
        plus.move(to: NSPoint(x: center.x, y: center.y - arm))
        plus.line(to: NSPoint(x: center.x, y: center.y + arm))
        NSColor.white.withAlphaComponent(0.92).setStroke()
        plus.stroke()
    }

    /// 最左的「自动（按课名）」胶囊。
    private func drawChip() {
        guard chipRect.width > 0 else { return }
        let selected = selectedHex == nil
        let path = NSBezierPath(roundedRect: chipRect,
                                xRadius: chipRect.height / 2,
                                yRadius: chipRect.height / 2)
        (selected ? TimetablePalette.UI.accent.withAlphaComponent(0.24)
                  : NSColor.white.withAlphaComponent(0.06)).setFill()
        path.fill()
        (selected ? TimetablePalette.UI.accent.withAlphaComponent(0.90)
                  : NSColor.white.withAlphaComponent(0.14)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: chipFont,
            .foregroundColor: selected ? NSColor.white : NSColor.secondaryLabelColor,
        ]
        let size = (chipText as NSString).size(withAttributes: attrs)
        let tw = min(size.width, chipRect.width)
        let textRect = NSRect(x: chipRect.midX - tw / 2,
                              y: chipRect.midY - size.height / 2,
                              width: tw,
                              height: size.height)
        (chipText as NSString).draw(in: textRect, withAttributes: attrs)
    }

    /// 一个圆形色块；选中时加白色圆环 + 对勾。
    private func drawSwatch(hex: String, in rect: NSRect, selected: Bool) {
        let circle = NSBezierPath(ovalIn: rect)
        TimetablePalette.color(hex: hex).setFill()
        circle.fill()

        if selected {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.6, dy: 1.6))
            ring.lineWidth = 1.6
            NSColor.white.withAlphaComponent(0.96).setStroke()
            ring.stroke()
            drawCheckmark(in: rect.insetBy(dx: 3.8, dy: 3.8))
        } else {
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor.white.withAlphaComponent(0.12).setStroke()
            border.stroke()
        }
    }

    /// 白色对勾（太小的圆点就跳过，靠圆环表示选中）。
    private func drawCheckmark(in rect: NSRect) {
        guard rect.width > 5, rect.height > 5 else { return }
        let p = NSBezierPath()
        p.lineWidth = max(1.2, rect.width * 0.16)
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: rect.minX + rect.width * 0.20, y: rect.midY + rect.height * 0.02))
        p.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.24))
        p.line(to: NSPoint(x: rect.minX + rect.width * 0.82, y: rect.maxY - rect.height * 0.20))
        NSColor.white.setStroke()
        p.stroke()
    }

    private func textWidth(_ s: String, font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - 点击

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if chipRect.contains(p) {
            choose(nil, notify: true)
            return
        }
        for (i, rect) in swatchRects.enumerated() where rect.contains(p) {
            guard ColorHex.presets.indices.contains(i) else { return }
            choose(ColorHex.presets[i].hex, notify: true)
            return
        }
        if customRect.contains(p) {
            presentColorPanel()
        }
    }

    // MARK: - 系统取色器

    /// 打开 macOS 色池，选任意颜色。
    ///
    /// 色池是**全 app 共享**的：挂在 self 上，编辑器关闭时摘掉，
    /// 否则窗口释放后色池还可能回调到这里。
    private func presentColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        // 编辑器本身是 .floating，色池也要抬到同一层，否则会被压在编辑器后面。
        panel.level = .floating
        panel.title = "课程颜色"
        if let hex = customHex, let rgb = ColorHex.rgb(hex) {
            panel.color = NSColor(srgbRed: rgb.r / 255, green: rgb.g / 255,
                                  blue: rgb.b / 255, alpha: 1)
        } else if let first = ColorHex.presets.first, let rgb = ColorHex.rgb(first.hex) {
            panel.color = NSColor(srgbRed: rgb.r / 255, green: rgb.g / 255,
                                  blue: rgb.b / 255, alpha: 1)
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        colorPanelAttached = true
        NSApp.activate(ignoringOtherApps: true)
        // 系统色池默认会落在屏幕左下角；按编辑器所在屏幕摆到正中间。
        // 显示前后各调一次：面板首次出现时可能会自己调整尺寸/位置。
        let anchor = window.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) }
        HUDWindow.centerOnScreen(panel, near: anchor)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        HUDWindow.centerOnScreen(panel, near: anchor)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let hex = Self.hexString(from: sender.color) else { return }
        choose(hex, notify: true)
    }

    /// NSColor → `#rrggbb`。统一转到 sRGB，忽略 alpha。
    ///
    /// 色池可能返回 Display P3 / 命名色 / 带 alpha 的颜色；
    /// 课程的存储格式只有 6 位十六进制，所以这里做一次收口。
    static func hexString(from color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int {
            Int((min(max(v, 0), 1) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x",
                      byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    private func detachColorPanel() {
        guard colorPanelAttached else { return }
        colorPanelAttached = false
        // NSColorPanel 只有 setTarget/setAction，没有 target getter；
        // 同一时间只会有一个课程编辑器，这里直接摘掉即可。
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        // 编辑器都关了，别把色池单独留在屏幕上。
        panel.orderOut(nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { detachColorPanel() }
    }

    deinit {
        detachColorPanel()
    }

    // MARK: - 测试钩子

    /// 选项数量（含最左的「自动」和最右的「自定义」）。
    var testOptionCount: Int { ColorHex.presets.count + 2 }

    /// 当前选中项的下标（0 = 自动，1...12 = 预设色，13 = 自定义）。
    var testSelectedIndex: Int {
        guard let h = selectedHex else { return 0 }
        if let i = ColorHex.presets.firstIndex(where: { $0.hex == h }) {
            return i + 1
        }
        return ColorHex.presets.count + 1
    }

    /// 当前选中项的文案（排查用）。
    var testSelectedLabel: String {
        guard let h = selectedHex else { return chipText }
        if let i = ColorHex.presets.firstIndex(where: { $0.hex == h }) {
            return "\(ColorHex.presets[i].name) \(h)"
        }
        return "自定义 \(h)"
    }

    /// 当前选中的是不是自定义色（不在 12 个预设里）。
    var testCustomSelected: Bool { customHex != nil }

    /// 「自定义」色块的框（布局测试用）。
    var testCustomRect: NSRect { customRect }

    /// 按索引选中（0 = 自动）。程序设置，不触发 `onChange`。
    ///
    /// 自定义项不在这里打开色池（测试环境没有交互）——
    /// 用 `testSelectCustomHex(_:)` 直接指定一个自定义色。
    func testSelectOption(at index: Int) {
        if index <= 0 { setSelected(nil); return }
        let i = index - 1
        guard ColorHex.presets.indices.contains(i) else { return }
        setSelected(ColorHex.presets[i].hex)
    }

    /// 按 hex 选中（`nil` / 非法值 = 自动）。
    func testSelectHex(_ hex: String?) {
        setSelected(hex)
    }

    /// 模拟用户在色池里选了一个自定义色（会触发 `onChange`）。
    func testSelectCustomHex(_ hex: String) {
        choose(hex, notify: true)
    }

    /// 模拟用户点某个选项（会触发 `onChange`）。
    ///
    /// 自定义项在真实界面会打开系统色池；测试里不打开，请用
    /// `testSelectCustomHex(_:)`。
    func testTapOption(at index: Int) {
        if index <= 0 { choose(nil, notify: true); return }
        let i = index - 1
        guard ColorHex.presets.indices.contains(i) else { return }
        choose(ColorHex.presets[i].hex, notify: true)
    }

    /// 每个选项在控件里的位置（布局测试用）。
    var testOptionRects: [NSRect] { [chipRect] + swatchRects + [customRect] }

    /// 「自动」胶囊的框。
    var testChipRect: NSRect { chipRect }

    /// 每个选项的 tooltip 文案（按选项顺序，下标 0 = 自动）。
    var testToolTipTexts: [String] { toolTipStrings.sorted { $0.key < $1.key }.map(\.value) }
}

/// 色块的 tooltip 由自己按区域回答（AppKit 的 tooltip 协议）。
extension CourseColorPickerView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipStrings[tag] ?? ""
    }
}

import AppKit
import CoreImage

/// 桌面课表卡片。
///
/// 自绘（`draw(_:)`）+ 手动命中测试，不依赖子视图，
/// 这样玻璃质感、圆角、阴影都能按像素控制。
///
/// 所有度量、字号、颜色都对齐旧版 web 版（Übersicht widget）的 CSS 规范，
/// 迁移后视觉保持一致。
final class TimetableCardView: NSView {

    // MARK: - 数据

    var state = TimetableState() {
        didSet { needsDisplay = true }
    }
    var config = AppearanceConfig([:]) {
        didSet { needsDisplay = true }
    }

    /// 顶栏标题与副标题。
    var titleText = "本周课表" {
        didSet { needsDisplay = true }
    }
    var subtitleText = "" {
        didSet { needsDisplay = true }
    }

    /// 当前选中的课程（非 nil 时在卡片内弹出详情浮层）。
    var selectedCourse: Course? {
        didSet { needsDisplay = true }
    }

    // MARK: - 回调

    var onOpenSettings: (() -> Void)?
    var onWeekChange: ((Int?) -> Void)?
    var onSelectCourse: ((Course) -> Void)?
    /// 鼠标进出卡片（用于渐隐 / 变实动画）。
    var onHoverChange: ((Bool) -> Void)?

    // MARK: - 交互状态

    enum Hotspot: Equatable {
        case none
        case prevWeek, nextWeek, weekChip, gear, closeSheet, sheetBody
        case course(Course)
    }

    /// 网页渲染器给出的整窗快照（可选）。非空时直接贴图，不再走原生绘制。
    /// 用 layer.contents 而不是 draw(_:) 贴图：少一次位图拷贝，GPU 合成更省。
    var webSnapshot: NSImage? {
        didSet {
            needsDisplay = true
            guard let img = webSnapshot,
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                layer?.contents = nil
                return
            }
            wantsLayer = true
            let scale = img.size.width > 0 ? CGFloat(cg.width) / img.size.width : 2
            layer?.contentsScale = scale
            layer?.contentsGravity = .resize
            layer?.contents = cg
        }
    }

    /// 卡片是否由网页渲染器接管交互（接管后原生只做转发）
    var usesWebRenderer = false

    /// 指针事件回调（点，坐标为视图坐标系）
    var onPointerEvent: ((NSPoint, Bool) -> Void)?
    /// 右键回调（视图坐标系 + 命中的格子；格子为空表示点在网格外）。
    var onRightClick: ((NSPoint, SlotHit?) -> Void)?

    /// 命中的格子（day 1…7，block 0…4）。
    struct SlotHit {
        var day: Int
        var block: Int
    }

    /// 命中测试：把视图坐标换算成「星期 + 节次块」。
    ///
    /// 复用现有点击命中用的布局几何（`TimetableLayout`），
    /// 不另造一套坐标换算 —— 这套几何与网页 CSS 网格是同一套像素规范
    /// （`grid-template-rows: 38px repeat(10, 54px)`，一门课占两行），
    /// 所以 A 模式（贴的是网页快照）命中的格子与 B 模式一致。
    ///
    /// 行用「时间段行」判定（每 54pt 一行，行间 6pt 的缝不算命中），
    /// 两行合起来是一个 block（节次块）。
    ///
    /// - Returns: 命中的格子；点在网格外返回 nil。
    func slotHit(at point: NSPoint) -> SlotHit? {
        // 列：星期
        var day: Int?
        for d in 1...7 {
            let (x, w) = TimetableLayout.dayColumn(day: d)
            if point.x >= x && point.x < x + w { day = d; break }
        }
        guard let day else { return nil }

        // 行：时间段 → 节次块
        for p in 0..<Schedule.periods.count {
            let r = TimetableLayout.periodRect(period: p)
            if point.y >= r.minY && point.y < r.maxY {
                return SlotHit(day: day, block: p / 2)
            }
        }
        return nil
    }

    /// 网页模式下鼠标按下的位置（用于区分点击与拖拽）
    private var webPressOrigin: NSPoint?

    private var hotspot: Hotspot = .none
    private var pressed: Hotspot = .none
    private var mouseInside = false

    /// 卡片在视图里的矩形（视图比卡片大，四周留出投影空间）。
    private var cardRect: NSRect { TimetableLayout.cardRect }

    /// 状态条所占的矩形（与 drawStatusBar() 里的算法保持一致）。
    private var statusBarRect: NSRect {
        let inset = TimetableLayout.cardBorder + TimetableLayout.cardPaddingH
        return NSRect(x: cardRect.minX + inset,
                      y: cardRect.maxY - TimetableLayout.cardBorder
                          - TimetableLayout.cardPaddingTop
                          - TimetableLayout.topBarHeight
                          - TimetableLayout.statusBarHeight,
                      width: cardRect.width - inset * 2,
                      height: TimetableLayout.statusBarHeight)
    }

    /// 状态条左侧那个脉冲点。
    private var statusDotRect: NSRect {
        let rect = statusBarRect
        return NSRect(x: rect.minX + 12, y: rect.midY - 3.5, width: 7, height: 7)
    }

    /// 脉冲动画时**需要重画的那一小块**。
    ///
    /// 呼吸圈从 7px 的点扩散到 14px（spread 最大 7px），线宽 1.5px，
    /// 所以要往四周各留 8px 才够覆盖上一帧的残留。
    private var pulseDirtyRect: NSRect {
        statusDotRect.insetBy(dx: -8, dy: -8)
    }

    // MARK: - 测试用命中区域

    /// 齿轮按钮的命中矩形（测试用）
    var gearRectForTest: NSRect { topBarGeometry().gear }
    /// 下一周箭头的命中矩形（测试用）
    var nextArrowRectForTest: NSRect { topBarGeometry().next }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 刻意不用 layer-backed：layer-backed 视图里 CGContext.setShadow 画的
        // 投影会被 layer 的边界裁掉，卡片看起来就像贴在桌面上、浮不起来。
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: TimetableLayout.windowWidth, height: TimetableLayout.windowHeight)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        if webSnapshot != nil { return }   // 网页快照由 layer.contents 负责显示
        // 卡片本体：投影 + 半透明玻璃底 + 1px 描边
        // （CSS: box-shadow 0 24px 60px rgba(0,0,0,.38) + border 1px rgba(255,255,255,.10)）
        drawSoftShadow()

        let path = NSBezierPath(roundedRect: cardRect, xRadius: TimetableLayout.cardRadius,
                                yRadius: TimetableLayout.cardRadius)
        TimetablePalette.UI.cardBackground.setFill()
        path.fill()

        TimetablePalette.UI.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 顶部内高光（CSS: inset 0 1px 0 rgba(255,255,255,.07)）
        let hi = NSBezierPath()
        let r = TimetableLayout.cardRadius
        hi.move(to: NSPoint(x: cardRect.minX + r, y: cardRect.maxY - 1))
        hi.line(to: NSPoint(x: cardRect.maxX - r, y: cardRect.maxY - 1))
        hi.lineWidth = 1
        NSColor.white.withAlphaComponent(0.07).setStroke()
        hi.stroke()

        drawTopBar()
        drawStatusBar()
        drawGrid()

        if let selected = selectedCourse {
            drawDetailOverlay(selected)
        }
    }

    // MARK: 投影

    /// 阴影参数（对应 CSS `box-shadow: 0 24px 60px rgba(0,0,0,.38)`）。
    ///
    /// AppKit 里 CGContext 的阴影和 CALayer 的阴影都靠不住（layer-backed 会被裁、
    /// masksToBounds 会吃掉），所以这里按高斯剖面一层层手工画：
    /// 把模糊后的圆角矩形拆成 N 圈，每圈填两圈密度之差，视觉上就是连续渐变。
    private static let shadowSigma: CGFloat = 30       // ≈ CSS blur(60px) / 2
    private static let shadowOffsetY: CGFloat = -24     // CSS 的 24px 向下
    private static let shadowAlpha: CGFloat = 0.38
    private static let shadowSteps = 40

    /// 高斯半平面密度：离边缘越远越淡。
    private static func shadowDensity(at distance: CGFloat) -> CGFloat {
        let x = distance / (shadowSigma * 1.41421356)
        return shadowAlpha * 0.5 * erfc(x)
    }

    private func drawSoftShadow() {
        let sigma = Self.shadowSigma
        let maxSpread = sigma * 3
        var previous = Self.shadowDensity(at: 0)

        NSGraphicsContext.saveGraphicsState()
        for i in 1...Self.shadowSteps {
            let spread = maxSpread * CGFloat(i) / CGFloat(Self.shadowSteps)
            let density = Self.shadowDensity(at: spread)
            let alpha = previous - density
            previous = density
            guard alpha > 0.001 else { continue }

            let shape = cardRect.insetBy(dx: -spread, dy: -spread)
                .offsetBy(dx: 0, dy: Self.shadowOffsetY)
            let path = NSBezierPath(roundedRect: shape,
                                    xRadius: TimetableLayout.cardRadius + spread,
                                    yRadius: TimetableLayout.cardRadius + spread)
            NSColor.black.withAlphaComponent(alpha).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 顶栏

    /// 顶栏里各块内容的矩形。
    ///
    /// 绘制和鼠标命中判定必须用同一份几何，否则「看得见的按钮点不到」。
    struct TopBarGeometry {
        var contentLeft: CGFloat = 0
        var contentRight: CGFloat = 0
        var contentTop: CGFloat = 0
        var contentHeight: CGFloat = 0
        var leftWidth: CGFloat = 0
        var clockTextWidth: CGFloat = 0
        var gear: NSRect = .zero
        var clockRight: CGFloat = 0
        var group: NSRect = .zero
        var prev: NSRect = .zero
        var next: NSRect = .zero
        var chip: NSRect = .zero
        var stack: NSRect = .zero
        var nowButton: NSRect = .zero
    }

    /// CSS: .top { padding: 2px 2px 13px; display:flex; align-items:center; justify-content:space-between; gap:16px }
    private func topBarGeometry() -> TopBarGeometry {
        var g = TopBarGeometry()
        let inset = TimetableLayout.cardBorder + TimetableLayout.cardPaddingH
        // 图钉在卡片**外面**（左侧留白里），不占顶栏空间 —— 标题保持原位置。
        g.contentLeft = cardRect.minX + inset + 2
        g.contentRight = cardRect.maxX - inset - 2
        g.contentTop = cardRect.maxY - TimetableLayout.cardBorder
            - TimetableLayout.cardPaddingTop - TimetableLayout.topBarPaddingTop
        g.contentHeight = TimetableLayout.topContentHeight
        let contentWidth = g.contentRight - g.contentLeft

        let ttlFont = Font.semibold(15)
        let subFont = Font.regular(10.5)
        g.leftWidth = max(measure(titleText, ttlFont, tracking: 0.2),
                          measure(subtitleText, subFont, tracking: 0.2))

        let tnumFont = Font.light(19)
        let tdateFont = Font.regular(10.5)
        g.clockTextWidth = max(measure(Self.clockText(), tnumFont, tracking: 0.5),
                               measure(Self.dateText(), tdateFont))
        let gearSize: CGFloat = 29          // CSS: 27px + 1px 边框 ×2
        let rightWidth = g.clockTextWidth + 12 + gearSize
        // NSRect 的 y 是底边（y 向上）。齿轮在内容区里垂直居中：
        // 底边 = 内容区底部 + (内容高 - 齿轮高) / 2。
        g.gear = NSRect(x: g.contentRight - gearSize,
                        y: g.contentTop - g.contentHeight + (g.contentHeight - gearSize) / 2,
                        width: gearSize, height: gearSize)
        g.clockRight = g.gear.minX - 12

        let nowBtnFont = Font.medium(10)
        let nowBtnWidth = measure("回到本周", nowBtnFont) + 18 + 2
        let arrowSize: CGFloat = 26          // CSS: 24px + 1px 边框 ×2
        let stackWidth: CGFloat = 132
        let groupWidth = arrowSize + 8 + stackWidth + 8 + arrowSize + 8 + nowBtnWidth

        let free = contentWidth - g.leftWidth - groupWidth - rightWidth
        let gap = max(16, free / 2)
        let groupX = g.contentLeft + g.leftWidth + gap
        g.group = NSRect(x: groupX, y: g.contentTop - g.contentHeight,
                         width: groupWidth, height: g.contentHeight)
        let wk = weekGroupRects(in: g.group, arrowSize: arrowSize,
                                chipWidth: 68, stackWidth: stackWidth,
                                nowButtonWidth: nowBtnWidth)
        g.prev = wk.prev; g.next = wk.next; g.chip = wk.chip
        g.stack = wk.stack; g.nowButton = wk.nowButton
        return g
    }

    private func drawTopBar() {
        let g = topBarGeometry()

        // ---- 左：标题 + 副标题 ----
        let ttlFont = Font.semibold(15)
        let subFont = Font.regular(10.5)
        let ttlLine = TimetableLayout.Line.ttl
        let subLine = TimetableLayout.Line.sub
        let titleBlockH = ttlLine + 4 + subLine
        let titleTop = g.contentTop - (g.contentHeight - titleBlockH) / 2
        drawText(titleText,
                 in: NSRect(x: g.contentLeft, y: titleTop - ttlLine, width: 320, height: ttlLine),
                 font: ttlFont, color: TimetablePalette.UI.text, tracking: 0.2)
        drawText(subtitleText,
                 in: NSRect(x: g.contentLeft, y: titleTop - ttlLine - 4 - subLine,
                            width: 320, height: subLine),
                 font: subFont, color: TimetablePalette.UI.fg(0.44), tracking: 0.2)

        // ---- 右：时钟 + 日期 + 齿轮 ----
        let tnumFont = Font.light(19)
        let tdateFont = Font.regular(10.5)
        let tnumLine = TimetableLayout.Line.tnum
        let tdateLine = TimetableLayout.Line.tdate
        let clockBlockH = tnumLine + 2 + tdateLine
        let clockTop = g.contentTop - (g.contentHeight - clockBlockH) / 2
        drawText(Self.clockText(),
                 in: NSRect(x: g.clockRight - g.clockTextWidth, y: clockTop - tnumLine,
                            width: g.clockTextWidth, height: tnumLine),
                 font: tnumFont, color: TimetablePalette.UI.text, align: .right, tracking: 0.5)
        drawText(Self.dateText(),
                 in: NSRect(x: g.clockRight - g.clockTextWidth,
                            y: clockTop - tnumLine - 2 - tdateLine,
                            width: g.clockTextWidth, height: tdateLine),
                 font: tdateFont, color: TimetablePalette.UI.fg(0.44), align: .right)

        drawGear(in: g.gear, highlighted: hotspot == .gear)

        // ---- 中：周次组（space-between 排布）----
        drawWeekGroup(in: g.group, arrowSize: 26, stackWidth: 132,
                      chipWidth: 68, nowButtonWidth: g.nowButton.width)
    }

    private func drawWeekGroup(in rect: NSRect, arrowSize: CGFloat,
                               stackWidth: CGFloat, chipWidth: CGFloat,
                               nowButtonWidth: CGFloat) {
        let wk = weekGroupRects(in: rect, arrowSize: arrowSize,
                                chipWidth: chipWidth, stackWidth: stackWidth,
                                nowButtonWidth: nowButtonWidth)

        let prevEnabled = !state.isAllWeeks && state.baseWeek > 1
        drawArrow("◀", in: wk.prev, enabled: prevEnabled, highlighted: hotspot == .prevWeek)
        let nextEnabled = !state.isAllWeeks && state.baseWeek < state.maxWeek
        drawArrow("▶", in: wk.next, enabled: nextEnabled, highlighted: hotspot == .nextWeek)

        // chip（CSS: .wkchip 宽 68 固定，padding 5px 0）
        let chipFont = Font.medium(11)
        let chipRect = wk.chip
        let isNow = state.isCurWeek
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 9, yRadius: 9)
        if isNow {
            TimetablePalette.UI.accent.withAlphaComponent(0.14).setFill()
        } else {
            NSColor.white.withAlphaComponent(hotspot == .weekChip ? 0.13 : 0.07).setFill()
        }
        chipPath.fill()
        (isNow ? TimetablePalette.UI.accent.withAlphaComponent(0.42)
               : NSColor.white.withAlphaComponent(0.09)).setStroke()
        chipPath.lineWidth = 1
        chipPath.stroke()
        let chipText = state.isAllWeeks ? "全部周次" : (isNow ? "本周" : "第 \(state.baseWeek) 周")
        drawText(chipText,
                 in: NSRect(x: chipRect.minX, y: chipRect.minY + 6,
                            width: chipRect.width, height: TimetableLayout.Line.chip),
                 font: chipFont,
                 color: isNow ? .white : TimetablePalette.UI.fg(0.84), align: .center)

        // 日期（CSS: .wkdate 9.5px 居中）
        let dateFont = Font.regular(9.5)
        let dateLine = TimetableLayout.Line.wkdate
        let dateText = state.isAllWeeks
            ? WeekMath.semesterRangeText(state.semesterStart, maxWeek: state.maxWeek)
            : WeekMath.weekDateText(state.baseWeek, semesterStart: state.semesterStart)
        drawText(dateText,
                 in: NSRect(x: wk.stack.minX, y: wk.stack.minY, width: stackWidth, height: dateLine),
                 font: dateFont, color: TimetablePalette.UI.fg(0.40), align: .center, tracking: 0.2)

        // 回到本周（ghost 时不画，但保留占位，避免整组宽度跳变）
        if !state.isAllWeeks && state.currentWeek != nil {
            let b = wk.nowButton
            let path = NSBezierPath(roundedRect: b, xRadius: 8, yRadius: 8)
            TimetablePalette.UI.accent.withAlphaComponent(0.12).setFill()
            path.fill()
            TimetablePalette.UI.accent.withAlphaComponent(0.30).setStroke()
            path.lineWidth = 1
            path.stroke()
            let font = Font.medium(10)
            let lh = lineHeight(font)
            drawText("回到本周",
                     in: NSRect(x: b.minX, y: b.midY - lh / 2, width: b.width, height: lh),
                     font: font, color: TimetablePalette.UI.accent, align: .center)
        }
    }

    /// 周次组里各个元素的矩形（绘制与命中测试共用）。
    private func weekGroupRects(in rect: NSRect, arrowSize: CGFloat,
                                 chipWidth: CGFloat, stackWidth: CGFloat,
                                 nowButtonWidth: CGFloat) -> (
        prev: NSRect, next: NSRect, chip: NSRect, stack: NSRect, nowButton: NSRect) {

        // CSS: .wkgroup { display:flex; align-items:center; gap:8px }
        //       .wkstack { flex-direction:column; gap:4px; width:132px }
        //       .wkchip  { width:68px }  ← 在 132 宽的 stack 里居中
        let midY = rect.midY
        let stackH = TimetableLayout.topContentHeight          // 45 = chip 28 + gap 4 + 日期 13
        let chipH = TimetableLayout.Line.chip + 10 + 2          // 28
        let prev = NSRect(x: rect.minX, y: midY - arrowSize / 2,
                          width: arrowSize, height: arrowSize)
        let stack = NSRect(x: prev.maxX + 8, y: midY - stackH / 2,
                           width: stackWidth, height: stackH)
        let chip = NSRect(x: stack.minX + (stackWidth - chipWidth) / 2,
                          y: stack.maxY - chipH, width: chipWidth, height: chipH)
        let next = NSRect(x: stack.maxX + 8, y: midY - arrowSize / 2,
                          width: arrowSize, height: arrowSize)
        let nowButton = NSRect(x: next.maxX + 8, y: midY - 11,
                               width: nowButtonWidth, height: 22)
        return (prev, next, chip, stack, nowButton)
    }

    private func drawArrow(_ glyph: String, in rect: NSRect, enabled: Bool,
                           highlighted: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let bg = highlighted && enabled
            ? TimetablePalette.UI.accent.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(0.06)
        bg.setFill()
        path.fill()
        (highlighted && enabled
         ? TimetablePalette.UI.accent.withAlphaComponent(0.38)
         : NSColor.white.withAlphaComponent(0.08)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let color: NSColor = !enabled
            ? TimetablePalette.UI.fg(0.28)
            : (highlighted ? .white : TimetablePalette.UI.fg(0.62))
        let font = Font.regular(9)
        let lh = lineHeight(font)
        drawText(glyph, in: NSRect(x: rect.minX, y: rect.midY - lh / 2,
                                   width: rect.width, height: lh),
                 font: font, color: color, align: .center)
    }

    private func drawGear(in rect: NSRect, highlighted: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        (highlighted ? TimetablePalette.UI.accent.withAlphaComponent(0.18)
         : NSColor.white.withAlphaComponent(0.06)).setFill()
        path.fill()
        (highlighted ? TimetablePalette.UI.accent.withAlphaComponent(0.38)
         : NSColor.white.withAlphaComponent(0.08)).setStroke()
        path.lineWidth = 1
        path.stroke()

        if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let symbol = img.withSymbolConfiguration(cfg) ?? img
            symbol.isTemplate = true
            let color = highlighted ? NSColor.white : TimetablePalette.UI.fg(0.60)
            symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [color])
            )!.draw(in: rect.insetBy(dx: 6.5, dy: 6.5))
        }
    }

    // MARK: 状态条

    private func drawStatusBar() {
        let st = state.status
        let inset = TimetableLayout.cardBorder + TimetableLayout.cardPaddingH
        let rect = NSRect(x: cardRect.minX + inset,
                          y: cardRect.maxY - TimetableLayout.cardBorder
                              - TimetableLayout.cardPaddingTop
                              - TimetableLayout.topBarHeight
                              - TimetableLayout.statusBarHeight,
                          width: cardRect.width - inset * 2,
                          height: TimetableLayout.statusBarHeight)

        let path = NSBezierPath(roundedRect: rect, xRadius: TimetableLayout.statusBarRadius,
                                yRadius: TimetableLayout.statusBarRadius)
        if st.isLive {
            // CSS: linear-gradient(90deg, rgba(79,140,255,.20), rgba(165,119,255,.10))
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            path.addClip()
            let colors = [TimetablePalette.UI.accent.withAlphaComponent(0.20).cgColor,
                          TimetablePalette.UI.accent2.withAlphaComponent(0.10).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                ctx?.drawLinearGradient(gradient,
                                        start: CGPoint(x: rect.minX, y: rect.midY),
                                        end: CGPoint(x: rect.maxX, y: rect.midY),
                                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx?.restoreGState()
            TimetablePalette.UI.accent.withAlphaComponent(0.36).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.05).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.07).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        // 脉冲点（CSS: 2.4s 呼吸圈动画）
        let dotRect = statusDotRect
        drawPulse(in: dotRect, live: st.isLive)

        // 文案
        let stxtFont = Font.semibold(12)
        let stxtLine = TimetableLayout.Line.stxt
        drawText(st.text,
                 in: NSRect(x: dotRect.maxX + 9, y: rect.midY - stxtLine / 2,
                            width: 420, height: stxtLine),
                 font: stxtFont, color: TimetablePalette.UI.text, tracking: 0.2)

        let smetaFont = Font.regular(10.5)
        let smetaLine = TimetableLayout.Line.smeta
        let metaW = measure(st.meta, smetaFont, tracking: 0.2) + 2
        drawText(st.meta,
                 in: NSRect(x: rect.maxX - 12 - metaW, y: rect.midY - smetaLine / 2,
                            width: metaW, height: smetaLine),
                 font: smetaFont, color: TimetablePalette.UI.fg(0.50), align: .right, tracking: 0.2)
    }

    /// 呼吸点：绿色实心圆 + 扩散的圆环（对应 CSS 的 box-shadow 动画）。
    private func drawPulse(in rect: NSRect, live: Bool) {
        let dot = NSBezierPath(ovalIn: rect)
        (live ? TimetablePalette.UI.green : TimetablePalette.UI.fg(0.26)).setFill()
        dot.fill()

        let phase = live ? pulsePhase : 0
        guard phase > 0 else { return }
        // CSS keyframes: 0% spread 0 / alpha .55 → 70% spread 7px / alpha 0 → 100% alpha 0
        let t = min(phase / 0.7, 1)
        let spread = 7 * t
        let alpha = live ? 0.55 * (1 - t) : 0.05 * (1 - t)
        guard alpha > 0.005 else { return }
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -spread, dy: -spread))
        ring.lineWidth = 1.5
        (live ? TimetablePalette.UI.green : TimetablePalette.UI.fg(1)).withAlphaComponent(alpha).setStroke()
        ring.stroke()
    }

    /// 脉冲动画相位（0…1），由外部定时器推进。
    private var pulseClock: CFTimeInterval = 0

    func advancePulse(by dt: TimeInterval) {
        pulseClock += dt
        let period: CFTimeInterval = 2.4
        pulsePhase = (pulseClock.truncatingRemainder(dividingBy: period)) / period
        // **只重画脉冲点那一小块，不要整张卡重画。**
        //
        // 呼吸圈动的是一个 7px 的点，但 `needsDisplay = true` 会让 AppKit
        // 重新绘制整个视图：投影 + 玻璃底 + 顶栏 + 状态条 + 网格 + 23 门课。
        // 24fps 下这就是每 ~41ms 一次全卡重绘 —— 实测主线程每次被卡住
        // ~270–300ms（TT-BEAT 连续记 25 次，最大 301ms）。
        //
        // 用 setNeedsDisplay(_:) 局部失效，只重画状态条左侧那一小块，
        // 代价降到可以忽略。
        setNeedsDisplay(pulseDirtyRect)
    }

    private var pulsePhase: Double = 0

    // MARK: 网格

    private func drawGrid() {
        let baseWeek = state.baseWeek
        let map = state.courseMap

        let header = TimetableLayout.headerRect
        let baseMonday = WeekMath.dayDate(baseWeek, semesterStart: state.semesterStart, day: 1)
        let baseMonth = baseMonday.map { WeekMath.calendar.component(.month, from: $0) } ?? 1

        // 表头：星期 + 日期
        for day in 1...7 {
            let (x, w) = TimetableLayout.dayColumn(day: day)
            let rect = NSRect(x: x, y: header.minY, width: w, height: header.height)
            let date = WeekMath.dayDate(baseWeek, semesterStart: state.semesterStart, day: day)
            let isToday = date.map { WeekMath.calendar.isDate($0, inSameDayAs: state.now) } ?? false

            let dayName = Schedule.dayNames[day - 1]
            let nameFont = Font.medium(10.5)
            let nameLine = lineHeight(nameFont)
            let nameW = measure(dayName, nameFont, tracking: 0.6)
            // 今天是：星期名后面跟一个蓝点（CSS: .hdrow 里的 .dot）
            let dotSize: CGFloat = 4
            let groupW = isToday ? nameW + 4 + dotSize : nameW
            let groupX = rect.midX - groupW / 2

            drawText(dayName,
                     in: NSRect(x: groupX, y: header.minY + 20, width: nameW + 2, height: nameLine),
                     font: nameFont,
                     color: isToday ? .white : TimetablePalette.UI.fg(0.42),
                     tracking: 0.6)
            if isToday {
                let dot = NSBezierPath(ovalIn: NSRect(x: groupX + nameW + 4,
                                                      y: header.minY + 20 + (nameLine - dotSize) / 2,
                                                      width: dotSize, height: dotSize))
                TimetablePalette.UI.accent.setFill()
                dot.fill()
            }

            var numText = ""
            if let date {
                let m = WeekMath.calendar.component(.month, from: date)
                let d = WeekMath.calendar.component(.day, from: date)
                numText = m != baseMonth ? "\(m).\(d)" : "\(d)"
            }
            let numFont = Font.semibold(12)
            let numLine = lineHeight(numFont)
            drawText(numText,
                     in: NSRect(x: rect.minX, y: header.minY + 3, width: rect.width, height: numLine),
                     font: numFont,
                     color: isToday ? TimetablePalette.UI.accent : TimetablePalette.UI.fg(0.62),
                     align: .center, tracking: 0.3)
        }

        // 左上角：月份（CSS: .mon + .monu）
        let corner = NSRect(x: TimetableLayout.gridOrigin.x, y: header.minY,
                            width: TimetableLayout.timeColumnWidth, height: header.height)
        let monFont = Font.semibold(15)
        let monLine = lineHeight(monFont)
        let monuFont = Font.regular(9.5)
        let monuLine = lineHeight(monuFont)
        drawText("\(baseMonth)",
                 in: NSRect(x: corner.minX, y: corner.minY + 17, width: corner.width, height: monLine),
                 font: monFont, color: TimetablePalette.UI.fg(0.74), align: .center)
        drawText("月",
                 in: NSRect(x: corner.minX, y: corner.minY + 5, width: corner.width, height: monuLine),
                 font: monuFont, color: TimetablePalette.UI.fg(0.40), align: .center, tracking: 0.2)

        // 时间列（CSS: .tn 序号 → .ts 开始 → .te 结束，右对齐，垂直居中）
        for p in 0..<TimetableLayout.periodCount {
            let rect = TimetableLayout.timeColumnRect(period: p)
            let tnFont = Font.semibold(10)
            let tsFont = Font.medium(10)
            let teFont = Font.regular(8.5)
            let tnLine = lineHeight(tnFont)
            let tsLine = lineHeight(tsFont)
            let teLine = lineHeight(teFont)
            let contentH = tnLine + 1 + tsLine + 1 + teLine
            var y = rect.maxY - (rect.height - contentH) / 2

            drawText("\(p + 1)",
                     in: NSRect(x: rect.minX, y: y - tnLine, width: rect.width - 3, height: tnLine),
                     font: tnFont, color: TimetablePalette.UI.fg(0.55), align: .right, tracking: 0.3)
            y -= tnLine + 1
            drawText(Schedule.periods[p].start,
                     in: NSRect(x: rect.minX, y: y - tsLine, width: rect.width - 3, height: tsLine),
                     font: tsFont, color: TimetablePalette.UI.fg(0.66), align: .right)
            y -= tsLine + 1
            drawText(Schedule.periods[p].end,
                     in: NSRect(x: rect.minX, y: y - teLine, width: rect.width - 3, height: teLine),
                     font: teFont, color: TimetablePalette.UI.fg(0.26), align: .right)
        }

        // 课程格
        let conflictSlots = state.conflictSlots
        for day in 1...7 {
            for p in 0..<TimetableLayout.periodCount {
                let block = p / 2
                let course = map["\(day)-\(block)"]
                guard let course else {
                    let rect = TimetableLayout.periodRect(period: p)
                    let cell = NSRect(x: rect.minX, y: rect.minY,
                                      width: rect.width, height: rect.height)
                    let path = NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10)
                    NSColor.white.withAlphaComponent(0.02).setFill()
                    path.fill()
                    NSColor.white.withAlphaComponent(0.045).setStroke()
                    path.lineWidth = 1
                    let dashes: [CGFloat] = [3, 3]
                    path.setLineDash(dashes, count: 2, phase: 0)
                    path.stroke()
                    path.setLineDash([], count: 0, phase: 0)
                    continue
                }
                guard p % 2 == 0 else { continue }   // 一门课只画一次（跨 2 行）
                drawCourse(course, day: day, block: block)
                // 冲突标记：同一格有多门课时给出可见提示
                if conflictSlots.contains("\(day)-\(block)") {
                    drawConflictMarker(day: day, block: block)
                }
            }
        }
    }

    /// 冲突格右上角的小圆点（⚠ 的轻量替代）。
    private func drawConflictMarker(day: Int, block: Int) {
        let rect = TimetableLayout.courseRect(block: block, day: day)
        let d: CGFloat = 7
        let dotRect = NSRect(x: rect.maxX - d - 8, y: rect.maxY - d - 8, width: d, height: d)
        let dot = NSBezierPath(ovalIn: dotRect)
        NSColor(srgbRed: 0.95, green: 0.62, blue: 0.18, alpha: 0.95).setFill()
        dot.fill()
        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5))
        NSColor(srgbRed: 0.95, green: 0.62, blue: 0.18, alpha: 0.35).setStroke()
        ring.lineWidth = 1
        ring.stroke()
    }

    private func drawCourse(_ course: Course, day: Int, block: Int) {
        let rect = TimetableLayout.courseRect(block: block, day: day)
        let isNow = state.currentCourse.map { $0.name == course.name && $0.day == day } ?? false
        let active = state.runsThisWeek(course)
        let accent = TimetablePalette.accent(for: course)

        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

        // 正在上的课：同色外发光（CSS: 0 0 0 1px rgba(...,0.55), 0 10px 30px rgba(...,0.32)）
        if isNow {
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.setShadow(offset: .zero, blur: 30,
                           color: accent.withAlphaComponent(0.32).cgColor)
            accent.withAlphaComponent(0.24).setFill()
            path.fill()
            ctx?.restoreGState()
            accent.withAlphaComponent(0.55).setStroke()
        } else {
            accent.withAlphaComponent(0.095).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.08).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        let alpha = active ? 1.0 : 0.26

        // ---- 内容块（CSS: flex column + justify-content:center，整块垂直居中）----
        let nameFont = Font.semibold(11)
        let nameLineHeight = nameFont.pointSize * 1.24
        let nameLines = Self.wrappedLineCount(course.name, font: nameFont,
                                              width: rect.width - 25, maxLines: 2)
        let nameH = nameLineHeight * CGFloat(nameLines)

        let locFont = Font.regular(9)
        let locLine = locFont.pointSize * 1.3
        let wkFont = Font.regular(8.5)
        let wkLine = wkFont.pointSize * 1.3
        let notFont = Font.regular(8.5)
        let notLine = notFont.pointSize * 1.3

        var contentH = nameH + 4 + locLine + 2 + wkLine
        if !active { contentH += 2 + notLine }

        let textX = rect.minX + 16
        let textW = rect.width - 25
        var y = rect.maxY - (rect.height - contentH) / 2

        // 左侧色条（CSS: .bar 2x10，margin-top 2）
        let bar = NSRect(x: rect.minX + 9, y: y + 2, width: 2, height: 10)
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
        accent.withAlphaComponent(0.9 * alpha).setFill()
        barPath.fill()

        // 课程名（最多两行）
        drawWrapped(course.name,
                    in: NSRect(x: textX, y: y - nameH, width: textW, height: nameH),
                    font: nameFont,
                    color: TimetablePalette.UI.text.withAlphaComponent(alpha),
                    maxLines: 2, lineHeight: nameLineHeight)
        y -= nameH + 4

        // 地点
        drawText(course.briefLoc,
                 in: NSRect(x: textX, y: y - locLine, width: rect.width - 24, height: locLine),
                 font: locFont,
                 color: TimetablePalette.UI.fg(0.46).withAlphaComponent(alpha))
        y -= locLine + 2

        // 教师 · 周次
        let wk = "\(course.briefTeacher) · \(course.weeksLabel) 周"
        drawText(wk,
                 in: NSRect(x: textX, y: y - wkLine, width: rect.width - 24, height: wkLine),
                 font: wkFont,
                 color: TimetablePalette.UI.fg(0.28).withAlphaComponent(alpha))
        y -= wkLine + 2

        // 非本周
        if !active {
            drawText("非本周",
                     in: NSRect(x: textX, y: y - notLine, width: rect.width - 24, height: notLine),
                     font: notFont,
                     color: TimetablePalette.UI.fg(0.34).withAlphaComponent(alpha))
        }
    }

    // MARK: 详情浮层（CSS: .ovl + .sheet）

    private func drawDetailOverlay(_ course: Course) {
        // 遮罩（CSS: rgba(8,9,13,.62)）
        NSColor(srgbRed: 8 / 255, green: 9 / 255, blue: 13 / 255, alpha: 0.62).setFill()
        cardRect.fill()

        let sheet = detailSheetRect(for: course)
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setShadow(offset: CGSize(width: 0, height: -26), blur: 70,
                       color: NSColor.black.withAlphaComponent(0.6).cgColor)
        let path = NSBezierPath(roundedRect: sheet, xRadius: 18, yRadius: 18)
        NSColor(srgbRed: 30 / 255, green: 33 / 255, blue: 42 / 255, alpha: 0.96).setFill()
        path.fill()
        ctx?.setShadow(offset: .zero, blur: 0, color: nil)
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        let accent = TimetablePalette.accent(for: course)
        let padX: CGFloat = 22
        let padTop: CGFloat = 20
        var y = sheet.maxY - padTop

        // 顶部：色点 + 名称 + 代码 + 关闭
        let dotSize: CGFloat = 9
        let dot = NSBezierPath(ovalIn: NSRect(x: sheet.minX + padX, y: y - 15, width: dotSize, height: dotSize))
        accent.setFill()
        dot.fill()

        let nameFont = Font.semibold(17)
        let nameLine = lineHeight(nameFont)
        drawText(course.name,
                 in: NSRect(x: sheet.minX + padX + 10 + dotSize, y: y - nameLine,
                            width: sheet.width - padX * 2 - 20 - dotSize - 30, height: nameLine),
                 font: nameFont, color: TimetablePalette.UI.text, tracking: 0.2)
        let codeFont = Font.regular(10.5)
        let codeLine = lineHeight(codeFont)
        drawText("课程代码 \(course.code.isEmpty ? "—" : course.code)",
                 in: NSRect(x: sheet.minX + padX + 10 + dotSize, y: y - nameLine - 4 - codeLine,
                            width: sheet.width - padX * 2 - 20 - dotSize - 30, height: codeLine),
                 font: codeFont, color: TimetablePalette.UI.fg(0.38), tracking: 0.3)
        y -= nameLine + 4 + codeLine + 16

        // 关闭按钮
        let closeSize: CGFloat = 24
        let closeRect = NSRect(x: sheet.maxX - padX - closeSize, y: y + nameLine + 4 - closeSize + 6,
                               width: closeSize, height: closeSize)
        drawCloseButton(in: closeRect, highlighted: hotspot == .closeSheet)

        // 明细行
        let rows: [(String, String)] = [
            ("上课时间", "\(Schedule.dayNames[course.day - 1])　第 \(course.block * 2 + 1)–\(course.block * 2 + 2) 节　\(TimetableLayout.courseTimeText(block: course.block))"),
            ("任课教师", course.teacher.isEmpty ? "—" : course.teacher),
            ("上课地点", course.loc.isEmpty ? "—" : course.loc),
            ("上课周次", "第 \(course.weeksLabel) 周"),
        ]
        for (key, value) in rows {
            let rowH: CGFloat = 38
            let row = NSRect(x: sheet.minX + padX, y: y - rowH, width: sheet.width - padX * 2, height: rowH)
            let rowPath = NSBezierPath(roundedRect: row, xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.035).setFill()
            rowPath.fill()
            NSColor.white.withAlphaComponent(0.05).setStroke()
            rowPath.lineWidth = 1
            rowPath.stroke()

            let kFont = Font.regular(11)
            let kLine = lineHeight(kFont)
            drawText(key,
                     in: NSRect(x: row.minX + 12, y: row.midY - kLine / 2, width: 90, height: kLine),
                     font: kFont, color: TimetablePalette.UI.fg(0.42), tracking: 0.3)

            let vFont = Font.medium(12)
            let vLine = lineHeight(vFont)
            drawText(value,
                     in: NSRect(x: row.minX + 100, y: row.midY - vLine / 2,
                                width: row.width - 112, height: vLine),
                     font: vFont, color: TimetablePalette.UI.text, align: .right)
            y -= rowH + 8
        }
    }

    /// 详情面板的矩形（CSS: .sheet 宽 430，卡片内居中）。
    private func detailSheetRect(for course: Course) -> NSRect {
        let width: CGFloat = 430
        let rowsH: CGFloat = 4 * 38 + 3 * 8
        let height: CGFloat = 20 + 18 + 16 + 4 + 18 + rowsH + 18
        let x = cardRect.midX - width / 2
        let y = cardRect.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func drawCloseButton(in rect: NSRect, highlighted: Bool) {
        let path = NSBezierPath(ovalIn: rect)
        (highlighted ? NSColor.white.withAlphaComponent(0.18)
         : NSColor.white.withAlphaComponent(0.08)).setFill()
        path.fill()
        let font = Font.regular(13)
        let lh = lineHeight(font)
        drawText("✕", in: NSRect(x: rect.minX, y: rect.midY - lh / 2, width: rect.width, height: lh),
                 font: font, color: highlighted ? .white : TimetablePalette.UI.fg(0.75), align: .center)
    }

    // MARK: - 命中测试

    private func hotspot(at point: NSPoint) -> Hotspot {
        // 详情浮层打开时，只有关闭按钮可点
        if let course = selectedCourse {
            let sheet = detailSheetRect(for: course)
            let closeSize: CGFloat = 24
            let closeRect = NSRect(x: sheet.maxX - 22 - closeSize,
                                   y: sheet.maxY - 20 - 18 - 16 - 4 - 18 + 6,
                                   width: closeSize, height: closeSize)
            if closeRect.contains(point) { return .closeSheet }
            // 面板本身点不动（CSS: .sheet 的 onClick 阻止冒泡），点遮罩才关闭
            if sheet.contains(point) { return .sheetBody }
            return .none
        }

        let g = topBarGeometry()
        if g.prev.contains(point) { return .prevWeek }
        if g.next.contains(point) { return .nextWeek }
        if g.chip.contains(point) { return .weekChip }
        if g.nowButton.contains(point) && state.currentWeek != nil { return .weekChip }
        if g.gear.contains(point) { return .gear }

        let map = state.courseMap
        for day in 1...7 {
            for block in 0...TimetableState.maxBlock {
                guard let c = map["\(day)-\(block)"] else { continue }
                if TimetableLayout.courseRect(block: block, day: day).contains(point) {
                    return .course(c)
                }
            }
        }
        return .none
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if usesWebRenderer {
            // 只记按下位置，真正的点击在 mouseUp 发一次。
            // （之前 down+up 各发一次：第一次打开课程浮层，第二次点在刚出现的
            //   遮罩上把它关掉 —— 视觉上就是「点了没反应」。）
            webPressOrigin = p
            return
        }
        if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
            FileHandle.standardError.write("TT mouseDown p=\(p) hotspot=\(hotspot(at: p))\n".data(using:.utf8)!)
        }
        pressed = hotspot(at: p)
        needsDisplay = true
    }

    /// 右键（A 模式：快照贴图，网页收不到右键事件，由原生做命中测试）。
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 命中测试复用现有点击命中的布局几何（TimetableLayout），
        // 这套几何与网页 CSS 网格是同一套像素规范，所以两种模式结果一致。
        let hit = slotHit(at: p)
        if usesWebRenderer {
            onRightClick?(p, hit)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if usesWebRenderer {
            // 按下和抬起位置一致才算一次点击（否则是拖拽，不该触发）
            let origin = webPressOrigin ?? p
            webPressOrigin = nil
            if hypot(p.x - origin.x, p.y - origin.y) < 4 {
                onPointerEvent?(p, true)
            }
            return
        }
        let up = hotspot(at: p)
        let was = pressed
        pressed = .none
        needsDisplay = true

        // 详情浮层打开时：点遮罩关闭，点关闭按钮关闭，面板内部不响应。
        // 这段必须在下面的 guard 之前 —— 遮罩的命中结果是 .none，
        // 如果先被 guard 拦掉，点遮罩就永远关不掉浮层。
        if selectedCourse != nil {
            if up == .closeSheet || up == .none { selectedCourse = nil }
            return
        }

        // 按下时没命中任何东西 → 什么都不做
        guard was != .none else { return }
        // 按下和松开的不是同一个东西 → 取消（避免拖动时误触发）
        guard was == up else { return }

        switch up {
        case .prevWeek:
            shiftWeek(-1)
        case .nextWeek:
            shiftWeek(1)
        case .weekChip:
            if state.isAllWeeks {
                onWeekChange?(state.currentWeek)
            } else {
                onWeekChange?(nil)          // 切到「全部周次」
            }
        case .gear:
            onOpenSettings?()
        case .course(let c):
            onSelectCourse?(c)
        case .none, .closeSheet, .sheetBody:
            break
        }
    }

    private func shiftWeek(_ delta: Int) {
        if state.isAllWeeks {
            onWeekChange?(delta > 0 ? 1 : state.maxWeek)
            return
        }
        let next = min(state.maxWeek, max(1, state.baseWeek + delta))
        onWeekChange?(next)
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // 桌面层窗口几乎不会成为 key window，用 activeAlways 才能收到悬停事件
        let area = NSTrackingArea(rect: bounds,
                                   options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if usesWebRenderer { onPointerEvent?(p, false) }
        let h = hotspot(at: p)
        if h != hotspot {
            hotspot = h
            needsDisplay = true
            NSCursor.pointingHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if usesWebRenderer { onPointerEvent?(NSPoint(x: -99, y: -99), false) }
        if hotspot != .none {
            hotspot = .none
            needsDisplay = true
        }
        if mouseInside {
            mouseInside = false
            onHoverChange?(false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if usesWebRenderer { onPointerEvent?(convert(event.locationInWindow, from: nil), false) }
        if !mouseInside {
            mouseInside = true
            onHoverChange?(true)
        }
    }

    // MARK: - 绘制工具

    private func drawText(_ s: String, in rect: NSRect, font: NSFont,
                          color: NSColor, align: NSTextAlignment = .left,
                          tracking: CGFloat = 0) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        if tracking != 0 { attrs[.kern] = tracking }
        s.draw(in: rect, withAttributes: attrs)
    }

    /// 最多 `maxLines` 行的文本（对应 CSS 的 `-webkit-line-clamp`）。
    private func drawWrapped(_ s: String, in rect: NSRect, font: NSFont,
                              color: NSColor, maxLines: Int, lineHeight: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = .left
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        // 用 NSString.draw(in:) 而不是 NSLayoutManager：
        // 后者在非翻转视图里以「基线」为锚点，文字会整体比目标矩形高出一截。
        s.draw(in: rect, withAttributes: attrs)
    }

    /// 文本按宽度折行后占几行。
    static func wrappedLineCount(_ s: String, font: NSFont, width: CGFloat, maxLines: Int) -> Int {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        let storage = NSTextStorage(string: s, attributes: attrs)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let range = layout.glyphRange(for: container)
        guard range.length > 0 else { return 1 }
        let lines = Int((layout.usedRect(for: container).height / (font.pointSize * 1.24)).rounded(.up))
        return max(1, min(maxLines, lines))
    }

    private func measure(_ s: String, _ font: NSFont, tracking: CGFloat = 0) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attrs[.kern] = tracking }
        return (s as NSString).size(withAttributes: attrs).width
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    static func clockText(_ date: Date = Date()) -> String {
        let c = WeekMath.calendar
        let h = c.component(.hour, from: date)
        let m = c.component(.minute, from: date)
        return String(format: "%02d:%02d", h, m)
    }

    static func dateText(_ date: Date = Date()) -> String {
        let c = WeekMath.calendar
        let m = c.component(.month, from: date) + 1
        let d = c.component(.day, from: date)
        let wd = c.component(.weekday, from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "\(m)月\(d)日 \(names[wd - 1])"
    }
}

/// 字体速写（对应 CSS 的 font-size / font-weight）。
enum Font {
    static func regular(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .regular) }
    static func medium(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .medium) }
    static func semibold(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    static func light(_ size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .light)
    }
    /// 等宽数字（CSS: font-variant-numeric: tabular-nums）。
    static func tabular(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

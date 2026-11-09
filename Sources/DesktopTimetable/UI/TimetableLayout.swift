import AppKit

/// 课表卡片的布局度量。
///
/// 数值与旧版 web 版（Übersicht widget）保持一致，迁移后视觉不变。
///
/// 网格结构（对应 CSS `grid-template-rows: 38px repeat(10, 54px); gap: 6px`）：
/// - 第 0 行是表头（星期 + 日期）
/// - 第 1...10 行是时间段，一门课占连续 2 行
///
/// ⚠️ **缩放约定**（2026-11 加）：
/// 卡片大小可由设置面板的滑块调整，实现方式是**整体等比缩放**
/// （`scale` 系数）。所有尺寸都从 `scale` 派生，
/// 调用方**不要**再写死 968 / 782 这类数字 —— 一律走这里的计算属性。
///
/// - 缩放锚点是**卡片中心**：缩放前后卡片中心在屏幕上的位置不变。
/// - `shadowMargin`（投影留白）**跟着 scale 缩放** —— 不缩的话，
///   窗口框中心就不再等于卡片中心，「保持中心」这条保证会破。
enum TimetableLayout {
    // MARK: - 缩放

    /// 当前的缩放系数（1.0 = 原尺寸）。
    ///
    /// 只在**主线程**读写（和现在所有布局访问一致）。
    /// 改它之后必须调 `apply(scale:)`，让派生量跟上。
    private(set) static var scale: CGFloat = 1.0

    /// 设置缩放系数。
    ///
    /// ⚠️ **缩放一变就作废 `cardRectOverride`**：
    /// 它是「卡片在窗口坐标系里的矩形」，是按**当时的 scale / 窗口位置**
    /// 算出来的。缩放一变它就过期了；继续拿它去夹屏（`DesktopWindow.move`）
    /// 会让卡片「离屏幕边还有一段就拖不动」甚至被顶出屏幕 ——
    /// 这正是 1.3.1 之后「缩放后拖不到边缘」的根因，这里加一道结构性护栏：
    /// 过期就自动退回「画布居中」的矩形，由调用方在重排后再写新的覆盖值。
    ///
    /// - Parameter value: 新的缩放系数（调用方应先用 `CardScalePolicy` 夹取）。
    static func apply(scale value: CGFloat) {
        let v = max(0.1, value)
        if abs(v - scale) > 0.0001 {
            cardRectOverride = nil
        }
        scale = v
    }

    /// 恢复原始尺寸（测试用）。
    static func resetScale() {
        cardRectOverride = nil
        scale = 1.0
        collapse = 0
    }

    // MARK: - 折叠（收起课表网格）

    /// 折叠进度：0 = 展开，1 = 完全收起。
    ///
    /// 折叠只收掉「表头以下」的网格（10 个时间段），
    /// 顶栏 / 状态条 / 表头都留着；卡片**顶边不动**，从底部收上去。
    ///
    /// ⚠️ 常驻画布 / 缩放上限**不跟着折叠变**（见 `baseCardHeight` 的注释）：
    /// 折叠后卡片更矮，但画布还是按展开档建，窗口不用动 → 不会闪 / 不会裁。
    private(set) static var collapse: CGFloat = 0

    /// 折叠时收掉的网格高度（scale = 1，CSS px）。
    ///
    /// 网格总高 638 = 表头 38 + 10 行 ×54 + 10 个间距 ×6；
    /// 收起后只剩表头 38，所以收掉 600。
    static let collapseBodyHeight: CGFloat = 600

    /// 设置折叠进度（0...1）。
    ///
    /// 和 `apply(scale:)` 一样：状态一变，旧的可见矩形就过期了 ——
    /// 调用方要在设完之后**立刻写新的覆盖值**（`cardRectOverride`）。
    static func setCollapse(_ value: CGFloat) {
        let v = max(0, min(1, value))
        if abs(v - collapse) > 0.0001 {
            cardRectOverride = nil
        }
        collapse = v
    }

    // MARK: - 卡片（原始尺寸，缩放的基准）

    /// 卡片的**原始**宽度（scale = 1 时的值）。
    static let baseCardWidth: CGFloat = 968
    /// 卡片四周留给投影的空白（原始值）。
    static let baseShadowMargin: CGFloat = 90

    /// 卡片的原始尺寸（scale = 1 时）—— 用来算屏幕放不放得下。
    static var baseCardSize: CGSize {
        CGSize(width: baseCardWidth, height: baseCardHeight)
    }

    /// 卡片的原始高度（scale = 1 时，**展开态**）。
    ///
    /// ⚠️ 这个值**不是常数** —— 卡片高度随时间段数量变，
    /// 所以不能写死在 `maxScale` 之类的公式里，要用 `baseCardHeight`。
    ///
    /// ⚠️ 这里必须是**展开态**高度：缩放上限 / 常驻画布都按展开卡片算，
    /// 折叠只影响「卡片自己多高」，不能把画布和缩放上限一起缩小。
    static var baseCardHeight: CGFloat { expandedCardHeight(atScale: 1) }

    /// 网页里 `.card` 的**浏览器实测**尺寸（CSS px，与缩放无关）。
    ///
    /// 网页的卡片高度是内容撑出来的 773，而原生公式算的是 773（已减 9 的
    /// `browserCorrection`）—— 两边必须用同一份数，否则缩放后毛玻璃 /
    /// 拖动的「可见卡片矩形」会和网页差 1~2pt。
    static let webCardSize = CGSize(width: baseCardWidth, height: 773)

    // MARK: - 卡片（当前缩放下的尺寸）

    /// 卡片宽度（随缩放变化）。
    ///
    /// ⚠️ **取整**：窗口尺寸最终是整数点（AppKit 的窗口尺寸只能是整数），
    /// 卡片宽高也取整，「算出来的」和「实际的」才完全一致。
    static var cardWidth: CGFloat { (baseCardWidth * scale).rounded() }

    /// 卡片四周留给投影的空白（随缩放变化）。
    ///
    /// ⚠️ **必须跟着 scale 缩放**：窗口框 = 卡片 + 四周留白，
    /// 留白不对称的话「窗口中心 = 卡片中心」就不成立，
    /// 「缩放时保持卡片中心不动」这条保证会破。
    ///
    /// ⚠️ **取整**：窗口尺寸最终是整数点（AppKit 的窗口尺寸只能是整数），
    /// 所以这里的留白也要取整 —— 否则「算出来的卡片位置」和
    /// 「窗口里实际的卡片位置」差零点几，缩放几次之后卡片中心会漂一两磅。
    static var shadowMargin: CGFloat { (baseShadowMargin * scale).rounded() }

    static let cardBorder: CGFloat = 1          // CSS: border 1px
    static let cardPaddingTop: CGFloat = 16
    static let cardPaddingH: CGFloat = 18
    static let cardPaddingBottom: CGFloat = 18
    static let cardRadius: CGFloat = 20

    /// 卡片圆角（随缩放变化）。
    ///
    /// 毛玻璃层是原生视图（不是网页），它的 `cornerRadius` 不会跟着
    /// `pageZoom` / CSS transform 走 —— 必须自己乘。不乘的话，
    /// 缩小档位玻璃的圆角比卡片大（四角露出一圈玻璃），放大档位则反过来。
    static var cardRadiusScaled: CGFloat { cardRadius * scale }

    /// 可见卡片矩形的覆盖值（拖动/缩放后卡片不一定还在画布正中）。
    /// 图钉、毛玻璃、点击穿透、悬停、设置锚点都以这份为准。
    static var cardRectOverride: NSRect?

    /// 卡片在窗口里的矩形。
    static var cardRect: NSRect { cardRectOverride ?? canvasCardRect }

    /// 窗口尺寸 = 常驻画布尺寸（不随 scale 变）。
    static var windowWidth: CGFloat { canvasSize.width }
    static var windowHeight: CGFloat { canvasSize.height }

    // MARK: - 常驻画布（2026-11 结构改造的地基）

    /// 常驻画布的上限缩放（按当前屏幕算出来的最大档）。
    ///
    /// 画布永远按「最大档卡片 + 四周留白」做，卡片在画布里居中缩放：
    /// - 缩放只改网页 transform（窗口尺寸不变、位置跟着卡片中心走）
    ///   → 松手 / 关面板都不会闪；
    /// - 画布足够大，卡片贴边放大也不会被 webView / 窗口裁掉。
    ///
    /// 目前只做度量，尚未切换窗口行为（见 docs/方案-课表尺寸调节.md）。
    private(set) static var canvasMaxScale: CGFloat = 1.0

    /// 常驻画布的尺寸（pt）。
    static var canvasSize: NSSize {
        let s = canvasMaxScale
        let w = (baseCardWidth * s).rounded() + (baseShadowMargin * s).rounded() * 2
        let h = (baseCardHeight * s).rounded() + (baseShadowMargin * s).rounded() * 2
        return NSSize(width: w, height: h)
    }

    /// 设置常驻画布的上限档（启动 / 换屏时调）。
    static func configureCanvas(maxScale: CGFloat) {
        canvasMaxScale = max(0.1, maxScale)
    }

    /// 卡片在常驻画布里的矩形。
    ///
    /// - 展开时就是「居中」；
    /// - 折叠时**顶边不动**（和展开时同一条顶边），高度变矮 ——
    ///   所以 y 不是居中，而是 `展开顶边 - 当前高度`。
    static var canvasCardRect: NSRect {
        currentCardRect(scale: scale, containerSize: canvasSize)
    }

    /// 当前可见卡片在容器坐标系里的矩形（x 居中、顶边 = 展开时的顶边）。
    static func currentCardRect(scale s: CGFloat, containerSize: CGSize) -> NSRect {
        let w = baseCardWidth * s
        let h = expandedCardHeight(atScale: s) - collapseBodyHeight * collapse * s
        let expandedTop = (containerSize.height + expandedCardHeight(atScale: s)) / 2
        return NSRect(x: (containerSize.width - w) / 2,
                      y: expandedTop - h,
                      width: w, height: h)
    }

    /// 未缩放时窗口的尺寸（= 网页层用 layer transform 缩小前的宿主尺寸）。
    ///
    /// 缩小档位网页视图保持这个尺寸不动，由宿主 layer 做 scale；
    /// 所以它必须是常数，不能跟着 `scale` 变。
    static var baseWindowSize: NSSize {
        NSSize(width: baseCardWidth + baseShadowMargin * 2,
               height: baseCardHeight + baseShadowMargin * 2)
    }

    // 顶栏
    /// CSS `.top { padding: 2px 2px 13px }`
    static let topBarPaddingTop: CGFloat = 2
    static let topBarPaddingBottom: CGFloat = 13
    /// 顶栏里三块内容（标题 / 周次组 / 时钟）共同的高度，
    /// 对应 CSS `.wkstack` 的实际高度（chip 28 + gap 4 + 日期 13 = 45）。
    static let topContentHeight: CGFloat = 45
    static var topBarHeight: CGFloat { topBarPaddingTop + topContentHeight + topBarPaddingBottom }

    // 状态条
    static let statusBarHeight: CGFloat = 37
    static let statusBarMarginBottom: CGFloat = 11
    static let statusBarRadius: CGFloat = 12

    // 网格
    static let gap: CGFloat = 6
    static let timeColumnWidth: CGFloat = 58
    static let headerRowHeight: CGFloat = 38
    static let periodRowHeight: CGFloat = 54

    /// CSS 里各元素的行高（浏览器实测的盒高，AppKit 的自然行高偏小，
    /// 直接用自然行高会让整块内容比旧版矮一截）。
    enum Line {
        static let ttl: CGFloat = 21      // .ttl 15px/600
        static let sub: CGFloat = 15      // .sub 10.5px
        static let chip: CGFloat = 16     // .wkchip 11px
        static let wkdate: CGFloat = 13   // .wkdate 9.5px
        static let tnum: CGFloat = 26     // .tnum 19px/300
        static let tdate: CGFloat = 15    // .tdate 10.5px
        static let stxt: CGFloat = 17     // .stxt 12px/600
        static let smeta: CGFloat = 15    // .smeta 10.5px
    }

    /// 时间段数量（一节课占 2 段）。
    static var periodCount = Schedule.periods.count

    // MARK: - 缩放后的尺寸
    //
    // ⚠️ **所有尺寸都乘 scale** —— 内部组件（padding / 行高 / 间距）也不例外。
    //
    // 原因：网页层是「CSS 原尺寸 + pageZoom 整体缩放」，
    // 所以原生这边的几何必须也是 **scale=1 布局的等比放大**，
    // 两边才会在同一个位置上对齐。
    //
    // 如果只放大外框（cardWidth / cardHeight）而不放大内部组件，
    // 原生算出的「某一天在某一行」的矩形就和网页里的实际位置对不上 ——
    // 表现是「原生菜单弹在隔壁那一格」。

    /// 内边距（缩放后）。
    static var cardPaddingTopScaled: CGFloat { cardPaddingTop * scale }
    static var cardPaddingHScaled: CGFloat { cardPaddingH * scale }
    static var cardPaddingBottomScaled: CGFloat { cardPaddingBottom * scale }
    static var cardBorderScaled: CGFloat { cardBorder * scale }
    static var gapScaled: CGFloat { gap * scale }
    static var timeColumnWidthScaled: CGFloat { timeColumnWidth * scale }
    static var headerRowHeightScaled: CGFloat { headerRowHeight * scale }
    static var periodRowHeightScaled: CGFloat { periodRowHeight * scale }
    static var topBarHeightScaled: CGFloat { topBarHeight * scale }
    static var statusBarHeightScaled: CGFloat { statusBarHeight * scale }
    static var statusBarMarginBottomScaled: CGFloat { statusBarMarginBottom * scale }

    /// 10 个时间段占的总高（含 9 个行间距，缩放后）。
    static var dataHeight: CGFloat {
        (CGFloat(periodCount) * periodRowHeight + CGFloat(periodCount - 1) * gap) * scale
    }

    /// 星期列宽（缩放后）。
    static var dayColumnWidth: CGFloat {
        let gridWidth = cardWidth - (cardBorderScaled + cardPaddingHScaled) * 2
        return (gridWidth - timeColumnWidthScaled - gapScaled * 7) / 7
    }

    /// 网格总高（表头 + 10 行 + 10 个间距，缩放后）。
    static var gridHeight: CGFloat {
        headerRowHeightScaled + dataHeight + gapScaled
    }

    /// 卡片**当前**高度（折叠后变矮）。
    static var cardHeight: CGFloat {
        cardHeight(atScale: scale).rounded()
    }

    /// 卡片**当前**高度（按给定缩放 + 当前折叠进度）。
    static func cardHeight(atScale s: CGFloat) -> CGFloat {
        expandedCardHeight(atScale: s) - collapseBodyHeight * collapse * s
    }

    /// 卡片**展开态**高度（按给定缩放算）。
    ///
    /// ⚠️ 内部每一项都**单独**乘 `s` —— 不能先算好「scale=1 的高度」再乘 `s`，
    /// 那样 `gridHeight` 会被缩放两次（它内部已经乘过一遍了）。
    static func expandedCardHeight(atScale s: CGFloat) -> CGFloat {
        // 浏览器实测 `.card` 的 `getBoundingClientRect().height` 比这套
        // 盒模型公式少 9px（scale=1 时 773 vs 782）。常驻画布下卡片必须
        // 和网页卡片严格对齐，否则原生毛玻璃会上下各多出 4.5×s 的一条，
        // 放大后看起来就是「边缘只剩毛玻璃」。
        let browserCorrection: CGFloat = 9
        return cardBorder * 2 * s + cardPaddingTop * s + topBarHeight * s
            + statusBarHeight * s + statusBarMarginBottom * s
            + gridHeight(atScale: s) + cardPaddingBottom * s
            - browserCorrection * s
    }

    /// 网格总高（按给定缩放算）。
    static func gridHeight(atScale s: CGFloat) -> CGFloat {
        let data = (CGFloat(periodCount) * periodRowHeight + CGFloat(periodCount - 1) * gap) * s
        return headerRowHeight * s + data + gap * s
    }

    /// 网格左下角（窗口坐标系，y 向上；卡片本身从 shadowMargin 开始）。
    ///
    /// 网格是卡片的最后一块内容，所以它的**下沿**就是卡片的内容区下沿
    /// （cardPaddingBottom）。上面的顶栏 / 状态条都是往下叠的，
    /// 不能从顶栏高度倒推 —— 那样算出来的网格会整体压在顶栏和状态条上。
    static var gridOrigin: CGPoint {
        CGPoint(x: shadowMargin + cardBorderScaled + cardPaddingHScaled,
                y: shadowMargin + cardBorderScaled + cardPaddingBottomScaled)
    }

    /// 第 `period` 个时间段（0 = 08:00 第一节）的矩形。
    static func periodRect(period: Int) -> NSRect {
        let x = gridOrigin.x + timeColumnWidthScaled + gapScaled
        let w = dayColumnWidth
        let y = gridOrigin.y + dataHeight
            - CGFloat(period + 1) * periodRowHeightScaled
            - CGFloat(period) * gapScaled
        return NSRect(x: x, y: y, width: w, height: periodRowHeightScaled)
    }

    /// 表头行的矩形。
    static var headerRect: NSRect {
        // 折叠态：网格被裁到只剩表头一行，表头贴着卡片底部
        //（下面只留 cardPaddingBottom 的留白）—— 展开公式算出来的位置
        // 已经在卡片外面了，不能再直接用。
        let bottom: CGFloat
        if collapse > 0.5 {
            bottom = cardRect.minY + cardPaddingBottomScaled
        } else {
            bottom = gridOrigin.y + dataHeight + gapScaled
        }
        return NSRect(x: gridOrigin.x, y: bottom,
                      width: cardWidth - cardPaddingHScaled * 2, height: headerRowHeightScaled)
    }

    /// 时间列（第 0 列）的矩形。
    static func timeColumnRect(period: Int) -> NSRect {
        let y = gridOrigin.y + dataHeight
            - CGFloat(period + 1) * periodRowHeightScaled
            - CGFloat(period) * gapScaled
        return NSRect(x: gridOrigin.x, y: y,
                      width: timeColumnWidthScaled, height: periodRowHeightScaled)
    }

    /// 日期覆盖层的矩形（窗口坐标系）：某一列、从表头底边一直到网格底边。
    ///
    /// 折叠态下面板会从卡片底下伸出来，原生要把这一列也算进「在课表上」
    /// （悬停不淡出、点击不穿透）。展开态它本来就落在卡片里，多算一次无副作用。
    static func dayPanelRect(day: Int) -> NSRect {
        let col = dayColumn(day: day)
        let top = headerRect.minY          // 表头底边
        // 展开态：到网格底边；折叠态：网格被裁掉了，面板按**满列高**往下伸
        // （会伸出卡片，靠网页里的 `.card.collapsed { overflow: visible }` 放行）。
        let height: CGFloat
        if collapse > 0.5 {
            height = dataHeight + gapScaled
        } else {
            height = top - gridOrigin.y
        }
        return NSRect(x: col.x, y: top - height, width: col.width, height: height)
    }

    /// 某一天（1=周一 ... 7=周日）的列 x 坐标与宽度。
    static func dayColumn(day: Int) -> (x: CGFloat, width: CGFloat) {
        let x = gridOrigin.x + timeColumnWidthScaled + gapScaled
            + CGFloat(day - 1) * (dayColumnWidth + gapScaled)
        return (x, dayColumnWidth)
    }

    /// 一门课在网格里占的矩形（跨 2 个时间段）。
    static func courseRect(block: Int, day: Int) -> NSRect {
        let bottomPeriod = block * 2 + 1
        let (x, w) = dayColumn(day: day)
        let y = gridOrigin.y + dataHeight
            - CGFloat(bottomPeriod + 1) * periodRowHeightScaled
            - CGFloat(bottomPeriod) * gapScaled
        return NSRect(x: x, y: y, width: w, height: periodRowHeightScaled * 2 + gapScaled)
    }

    /// 一门课的时间文本（"08:00–08:45"）。
    static func courseTimeText(block: Int) -> String {
        guard block * 2 + 1 < Schedule.periods.count else { return "" }
        let start = Schedule.periods[block * 2].start
        let end = Schedule.periods[block * 2 + 1].end
        return "\(start)–\(end)"
    }
}

import AppKit

/// 卡片上的**交互层** —— 盖在画面（网页 / 原生卡片）之上。
///
/// 它解决两件事：
///
///   1. **拖动整张课表**。画面层（WKWebView）自己会吃掉鼠标事件，
///      网页里没有「窗口」的概念，拖不动。这里的交互层负责：
///      按下 → 移动超阈值 → 把位移转成窗口位移 → 夹回屏幕。
///   2. **把没拖动的点击转交回画面层**，这样点课程、点齿轮、
///      点周次箭头全都照旧работа —— 交互层只在「确实拖了」的时候拦下事件。
///
/// 图钉是**它的子视图**，所以图钉永远在最上面，点击优先给图钉。
///
/// 固定（图钉为实心）时：交互层完全不接管命中测试（`hitTest` 返回 nil），
/// 点击直接落到画面层，拖动完全无效。
final class CardInteractionView: NSView {

    /// 拖动回调：**窗口应该到的目标原点**（屏幕坐标，绝对值）。
    ///
    /// 报绝对值而不是增量 —— 增量和「当前窗口原点」相加会把位移重复计算
    /// （拖动过程中窗口自己也在动），窗口就会跑得比鼠标快得多。
    var onDragTo: ((NSPoint) -> Void)?
    /// 一次「没拖动的点击」—— 位置是**交互层**坐标系（原点左下）。
    var onClick: ((NSPoint) -> Void)?
    /// 悬停回调（屏幕坐标）。
    var onHover: ((NSPoint?) -> Void)?
    /// 一次拖动结束（鼠标松开）—— 用来把新位置写盘。
    var onDragEnd: (() -> Void)?

    /// 是否允许拖动（固定后置 false）。
    var allowsDragging: Bool = true {
        didSet {
            if allowsDragging != oldValue {
                // 状态变了 → 清理进行中的拖动，避免「松手时不复位」。
                if !allowsDragging { cancelDrag() }
            }
        }
    }

    /// 卡片左上角的图钉按钮（交互层的子视图 → 永远在最上面）。
    let pinButton = PushPinButton(frame: .zero)

    /// 当前课表标题 —— 图钉紧贴在它右边，所以标题变了要重新摆。
    private(set) var pinTitle: String = "我的课表"

    /// 判定「算拖动」的阈值（pt）。
    private static let dragThreshold: CGFloat = 4

    private var pressOrigin: NSPoint?
    private var dragOriginScreen: NSPoint?
    /// 拖动**开始时**窗口的原点。
    ///
    /// 算鼠标屏幕坐标的基准 —— 窗口在拖动过程中自己也在动，
    /// 用「当前」原点换算会把窗口移动的距离重复算进去（位移越滚越大）。
    private var dragWindowOrigin: NSPoint?
    private var isDragging = false
    private var cursorPushed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        setupPinButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
        setupPinButton()
    }

    private func setupPinButton() {
        pinButton.autoresizingMask = [.none]
        addSubview(pinButton)
        layoutPinButton()
    }

    /// 按卡片矩形摆好图钉的位置（标题右侧，与标题行平行）。
    ///
    /// 图钉是原生控件，尺寸 / 间距也要跟着卡片缩放一起乘
    /// （`TimetableLayout.scale`），否则卡片缩小时图钉比例会变大。
    func layoutPinButton() {
        layoutPinButton(inCard: TimetableLayout.cardRect, scale: TimetableLayout.scale)
    }

    /// 按**指定的卡片矩形**摆图钉（拖动缩放期间卡片在窗口里的位置
    /// 由 CSS transform 的 translate 决定，不等于 `TimetableLayout.cardRect`）。
    func layoutPinButton(inCard cardRect: NSRect, scale: CGFloat) {
        pinButton.scale = scale
        pinButton.frame = PushPinButton.rect(inCard: cardRect,
                                             title: pinTitle,
                                             scale: scale)
        // 图钉必须是最后一个子视图 → 点击优先给它。
        if let idx = subviews.firstIndex(of: pinButton), idx != subviews.count - 1 {
            pinButton.removeFromSuperview()
            addSubview(pinButton)
        }
    }

    /// 更新标题文字并按新宽度重新摆放图钉。
    func setPinTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        pinTitle = trimmed.isEmpty ? "本周课表" : trimmed
        layoutPinButton()
    }

    /// 固定状态同步给图钉。
    func setPinned(_ pinned: Bool) {
        pinButton.isPinned = pinned
        allowsDragging = !pinned
    }

    // MARK: - 命中测试

    override func hitTest(_ point: NSPoint) -> NSView? {
        // ⚠️ **图钉那块区域一律不接管**（2026-11）：图钉的视觉已经画在网页卡片里
        // （`.ttlpin`，和标题同一个 DOM），点击要让给**网页里的那张图** ——
        // 这样「看到的位置 = 能点的位置」，不会再出现「图钉点不动」。
        //
        // 网页里的 `<img class="ttlpin">` 自己挂了 onclick → `post('pinToggle')`，
        // 原生只负责切固定状态。
        if pinButton.frame.contains(point) { return nil }
        // 固定时交互层完全不接管 —— 点哪儿都落到画面层去。
        guard allowsDragging else { return nil }
        return super.hitTest(point)
    }

    // MARK: - 拖动

    private func cancelDrag() {
        pressOrigin = nil
        dragOriginScreen = nil
        dragWindowOrigin = nil
        isDragging = false
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        pressOrigin = p
        // 起点用**事件的屏幕坐标**换算，不用 `NSEvent.mouseLocation` ——
        // 合成事件不会真的挪动系统光标，只有事件自己的坐标是准的。
        dragOriginScreen = window?.convertPoint(toScreen: event.locationInWindow)
            ?? NSEvent.mouseLocation
        // 记住拖动**开始时**窗口的原点 —— 用来算「窗口应该到的绝对位置」。
        dragWindowOrigin = window?.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard allowsDragging, let origin = pressOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isDragging {
            // 超过阈值才算拖动，否则算点击（点课程、点齿轮都要照旧生效）。
            guard hypot(p.x - origin.x, p.y - origin.y) >= Self.dragThreshold else { return }
            isDragging = true
            if !cursorPushed { NSCursor.closedHand.push(); cursorPushed = true }
        }
        guard let start = dragOriginScreen else { return }

        // 鼠标**现在**的屏幕坐标。
        //
        // ⚠️ 必须用**当前**窗口原点来换算 `locationInWindow`：
        // 这个坐标是相对「事件到达时窗口在哪」的，而窗口全程跟着鼠标在动。
        // 之前用「拖动开始时的窗口原点」相加，等于把窗口已经走过的距离
        // 又减了一遍 —— 真机实测鼠标拖 200×120pt，窗口只走 104×62pt，
        // 手感就是「粘滞、跟不上鼠标」。
        let now = window?.convertPoint(toScreen: event.locationInWindow)
            ?? NSEvent.mouseLocation

        // 报的是**目标原点**（绝对值），不是「相对上一次」的增量。
        // 绝对值不会把窗口已经移动的距离重复计算。
        let base = dragWindowOrigin ?? window?.frame.origin ?? .zero
        onDragTo?(NSPoint(x: base.x + (now.x - start.x),
                          y: base.y + (now.y - start.y)))
    }

    override func mouseUp(with event: NSEvent) {
        let dragged = isDragging
        defer { cancelDrag() }
        guard allowsDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        if dragged {
            // 拖完立刻记下新位置 —— 不用等退出 App 才写盘。
            onDragEnd?()
        } else {
            // 没拖动 → 这是一次普通点击，转交回画面层。
            onClick?(p)
        }
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // 桌面层窗口几乎不会成为 key window，用 activeAlways 才能收到悬停事件。
        let area = NSTrackingArea(rect: bounds,
                                   options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    // MARK: - 自检

    /// 自检用：图钉当前的固定状态。
    var testIsPinned: Bool { pinButton.testIsPinned }
    /// 自检用：图钉当前的固定状态（与上面同一个，供外部读取）。
    var testPinIsPinned: Bool { pinButton.testIsPinned }
    /// 自检用：图钉在容器坐标系里的矩形。
    var testPinRect: NSRect { pinButton.frame }
    /// 自检用：当前是否允许拖动。
    var testAllowsDragging: Bool { allowsDragging }
    /// 自检用：当前是否处于拖动态。
    var testIsDragging: Bool { isDragging }
}

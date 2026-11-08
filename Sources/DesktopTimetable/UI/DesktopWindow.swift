import AppKit

/// 桌面层窗口。
///
/// 层级设在「桌面图标」之上、普通应用窗口之下，
/// 所以课表永远待在桌面最底层，被其它窗口盖住也仍然存在。
final class DesktopWindow: NSWindow {

    static let levelKey = "desktopWindowLevelOffset"

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 拖动由我们自己做（见 `CardInteractionView`），
        // 所以这里**不**用系统的「拖窗口背景」——
        // 背景一旦可拖，鼠标拖到卡片**外面**的投影空白区也会把窗口拖走，
        // 而那片区域本来就该「点击穿透」给桌面。
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 初始不可见，避免显示瞬间的白闪
        alphaValue = 0

        // 普通窗口之下、桌面窗口之上。层级口径只留一份
        // （`HoverCoverPolicy.cardWindowLevel`，最终由 `AppDelegate` 再设一次）——
        // hover 判定要靠它区分「挡住课表的窗口」和「在课表下面的桌面窗口」，
        // 两边各写一份迟早会飘。
        level = NSWindow.Level(rawValue: HoverCoverPolicy.cardWindowLevel)

        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
    }

    /// 把窗口放到屏幕上的默认位置（靠左上，避开菜单栏）。
    ///
    /// 窗口比卡片大（四周留了投影空间），所以定位要以**卡片**为准：
    /// 卡片的左上角对齐旧版 widget 的 left:272px / top:40px。
    func moveToDefaultPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // 旧版 widget 的 CSS 是 position:absolute; top:40px; left:272px，
        // 相对的是 Übersicht 的画布顶 —— 也就是菜单栏下沿，所以用 visibleFrame.maxY。
        let full = screen.frame
        let visible = screen.visibleFrame
        // ⚠️ 卡片在窗口里是**居中**的（常驻画布），不是贴在 90pt 留白角上：
        // 用 `cardRect.minX/minY` 换算，否则默认位置会把卡片顶出屏幕上沿
        // 六十几磅（实测 61.5pt）。
        let card = TimetableLayout.cardRect
        let cardX = min(full.minX + 272, full.maxX - card.width - 20)
        // 旧版 Übersicht 的画布是从**菜单栏下沿**开始的（不是屏幕顶），
        // CSS 的 top:40px 是相对画布顶，也就是菜单栏下沿往下 40pt。
        let cardTop = visible.maxY - 40
        let x = cardX - card.minX
        let y = cardTop - card.height - card.minY
        setFrameOrigin(NSPoint(x: max(visible.minX + 20 - card.minX, x), y: y))
    }

    /// 允许窗口原点跑到屏幕外。
    ///
    /// 常驻画布比屏幕大（1296×1076 vs 1512×896），卡片在画布里居中。
    /// 默认的 `constrainFrameRect` 会把窗口框往屏幕里顶，卡片就永远
    /// 贴不到屏幕边缘、中间总隔着一段画布留白。
    /// 这里原样返回：窗口框可以出一部分屏幕，卡片（可见部分）仍然被
    /// `move(to:)` 按可见区夹住。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - 位置记忆 / 固定

    /// 是否已固定（图钉为实心）。固定后拖动无效。
    var isPinned: Bool = false

    /// 把窗口移动到指定位置，并**夹回所在屏幕的可见区**。
    ///
    /// ⚠️ 夹的是**卡片**，不是窗口框。
    ///
    /// 窗口比卡片大得多（四周留了 90pt 的投影留白，窗口 1148×962、
    /// 卡片 968×782）。这台机器的屏幕可见区只有 1512×937 ——
    /// 窗口框**比屏幕还高**，按窗口框夹的话，课表永远会被顶到屏幕上沿，
    /// 而且「完整可见」这条要求根本不可能满足。
    ///
    /// 用户看到的是卡片，所以按卡片夹：
    ///   · 卡片要完整落在可见区里；
    ///   · 卡片放不下时（屏幕太小）以可见区**左上角**为准，至少左上角在屏幕里。
    ///
    /// - Parameter origin: 目标原点（屏幕坐标系，窗口框的左下角）。
    func move(to origin: NSPoint, clampingTo screen: NSScreen?) {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else {
            setFrameOrigin(origin)
            return
        }
        let vf = target.visibleFrame
        let card = TimetableLayout.cardRect
        // 卡片左上角在屏幕坐标系里的位置 = 窗口原点 + 卡片在窗口里的偏移。
        let cardOrigin = NSPoint(x: origin.x + card.minX, y: origin.y + card.minY)
        let clampedCard = TimetablePinState.clampOrigin(cardOrigin,
                                                         size: card.size,
                                                         visibleFrame: vf)
        // 用 setFrame 而不是 setFrameOrigin：setFrame 会走
        // `constrainFrameRect`（已覆盖成原样返回），窗口才能真的把原点
        // 放到屏幕外，让卡片贴到屏幕边缘。setFrameOrigin 在部分系统上
        // 仍会被窗口服务器顶回屏幕内，导致卡片永远隔一段画布留白。
        let frameToSet = NSRect(x: clampedCard.x - card.minX,
                                y: clampedCard.y - card.minY,
                                width: frame.width,
                                height: frame.height)
        setFrame(frameToSet, display: true)
    }

    /// 把窗口挪到**某个点所在的那块屏幕**上的指定位置（多显示器）。
    ///
    /// 拖动跨屏时要用它：目标位置落在哪块屏，就用哪块屏的可见区来夹。
    func move(to origin: NSPoint, onScreenContaining point: NSPoint) {
        let screen = TimetablePinState.screen(forPoint: point) ?? NSScreen.main
        move(to: origin, clampingTo: screen)
    }

    /// 课表**卡片**在屏幕坐标系里的矩形（不含四周的投影留白）。
    ///
    /// 后续窗口以课表位置为锚点时，用的是**卡片**的中心 ——
    /// 不是那个 1148×962 的窗口框（窗口框中心会偏左上，因为四周留了 90pt 阴影空间）。
    var cardFrameOnScreen: NSRect {
        convertToScreen(TimetableLayout.cardRect)
    }

    /// 课表**卡片**的中心（屏幕坐标系）。
    ///
    /// 所有后续窗口（设置面板、编辑器、确认框……）都以这个点为锚点。
    var cardCenterOnScreen: NSPoint {
        let f = cardFrameOnScreen
        return NSPoint(x: f.midX, y: f.midY)
    }

    // MARK: - 文本输入模式

    /// 现在是不是在等用户打字（网页里的 `<input>` 拿到了焦点）。
    ///
    /// ⚠️ 这个窗口默认是 **`.nonactivatingPanel`** ——
    /// 它**永远不能成为 key window**，于是 WKWebView 也**永远拿不到键盘焦点**，
    /// 网页里的输入框能点开、能显示，但**打不进字**。
    ///
    /// 所以输入框获得焦点时，临时把这个开关打开：
    ///   · `canBecomeKey` 返回 true → 窗口能拿 key；
    ///   · 原生再调 `makeKey` → WKWebView 里的 `<input>` 真的能收到按键。
    ///
    /// 输入结束（失焦 / 回车 / Esc）再关掉，恢复成「点不到就穿透」的桌面挂件行为。
    var textInputMode = false

    /// 能不能成为 key window。
    ///
    /// `.nonactivatingPanel` 默认返回 false（点了也不会激活 App），
    /// 这正是「桌面挂件不抢用户前台焦点」的关键 ——
    /// 所以只在**文本输入模式**下才放开。
    override var canBecomeKey: Bool { textInputMode }

    /// 能不能成为 main window（同样只在文本输入模式下放开）。
    override var canBecomeMain: Bool { textInputMode }

    /// **文本输入时要接管键盘的那个视图**（就是 WKWebView）。
    ///
    /// ⚠️⚠️ **这是「打不上字」的真正根因**（2026-11 修）。
    ///
    /// 桌面卡片的**鼠标事件全被 `CardInteractionView` 截走了**
    /// （它在 WKWebView **上面**，为了做拖动 + 图钉），
    /// 没拖动的点击再以 `forwardClick` 合成一个 JS 事件转发给网页 ——
    /// 也就是说 **WKWebView 从来没收到过真正的鼠标点击**。
    ///
    /// 后果：WKWebView **永远拿不到 first responder**，
    /// 于是**即使窗口成了 key window，按键也进不到网页里**
    /// （实测：全项目没有任何一处对桌面窗口的 webView 调过 `makeFirstResponder`）。
    ///
    /// 所以进入文本输入模式时，除了「窗口变成 key」，
    /// 还必须**显式把 first responder 交给 webView**。
    weak var textInputTarget: NSView?

    /// 文本框能接管键盘之后的回调（自检用）。
    var onTextInputReady: ((Bool) -> Void)?

    /// 重试令牌：每次切换模式自增，作废在途的重试。
    private var textInputToken = 0

    /// 打开 / 关闭文本输入模式。
    ///
    /// - Parameter active: true = 用户正在输入，要能打字。
    func setTextInputMode(_ active: Bool) {
        guard active != textInputMode else { return }
        textInputMode = active
        textInputToken += 1
        if active {
            takeKeyForTextInput(token: textInputToken, attempt: 0)
        } else {
            // 还原成「点不到就穿透」的桌面挂件：
            // 把第一响应者收回来，再把 key 交还给之前的窗口。
            if let target = textInputTarget, firstResponder === target {
                makeFirstResponder(nil)
            }
            firstResponderReady = false
            resignKey()
        }
    }

    /// 自检用：窗口是不是已经拿到 key、并且把键盘交给了 webView。
    private(set) var firstResponderReady = false

    /// 反复尝试「激活 App → 拿 key → 把 first responder 交给 webView」。
    ///
    /// ⚠️ **必须重试**：`NSApp.activate` 是**异步**的 ——
    /// 实测（Finder 在前台时）单次调用后 `isKeyWindow` 立刻还是 false，
    /// 要等约 0.8s 才变 true。只调一次的写法正好覆盖不到用户立刻打字的那一下，
    /// 于是「有时候打不上字」。
    private func takeKeyForTextInput(token: Int, attempt: Int) {
        guard textInputMode, token == textInputToken else { return }

        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
        makeKey()
        // ⚠️ 关键的一步：把键盘交给 webView（窗口是 key 只是前提）。
        if let target = textInputTarget {
            makeFirstResponder(target)
        }

        let responderOK = textInputTarget.map { firstResponder === $0 } ?? true
        let ready = isKeyWindow && responderOK
        if ready {
            if !firstResponderReady {
                firstResponderReady = true
                onTextInputReady?(true)
            }
            return
        }
        guard attempt < 12 else {
            onTextInputReady?(false)
            return
        }
        let delay = min(0.08 * Double(attempt + 1), 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.takeKeyForTextInput(token: token, attempt: attempt + 1)
        }
    }
}

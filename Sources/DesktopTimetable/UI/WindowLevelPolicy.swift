import AppKit

/// 窗口层级策略：**我们的窗口只在「自己是前台 App」时压在别人上面**。
///
/// ## 为什么需要
///
/// 设置面板 / 弹窗原来是硬编码 `.floating`。副作用是：用户把课表设置开着，
/// 再去用别的软件，设置面板**仍然浮在人家窗口上面**（用户反馈）。
///
/// ## 规则
///
///   · 本 App 是当前前台 → 这些窗口用 `.floating`（否则点齿轮打开设置时，
///     因为本 App 不会变成前台，窗口会掉到别的 App 后面 —— 这是当初抬层的原因）；
///   · 前台换成了别的 App → 降回 `.normal`，跟着普通窗口一起被盖住；
///   · 课表卡片窗口（桌面层）**不参与**，它有自己的层级（见 `HoverCoverPolicy`）。
enum WindowLevelPolicy {

    private static let raisedLevel: NSWindow.Level = .floating
    private static let normalLevel: NSWindow.Level = .normal

    /// 注册过的窗口（弱引用，窗口销毁不影响）。
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    /// 当前是不是「抬起」状态。
    private(set) static var isRaised = true

    /// 把窗口纳入策略（建窗时调一次）。
    static func register(_ window: NSWindow) {
        windows.add(window)
        window.level = isRaised ? raisedLevel : normalLevel
    }

    /// 前台 App 变了 → 抬起 / 放下。
    ///
    /// ⚠️ 不要只处理 `isVisible` 的窗口：刚刚建出来还没 orderFront 的窗口
    /// （比如自检里）也要跟着改，否则它第一次显示时还是旧层级。
    static func setRaised(_ raised: Bool) {
        isRaised = raised
        for window in windows.allObjects {
            window.level = raised ? raisedLevel : normalLevel
        }
    }

    /// 当前前台 App 是不是我们。
    static func syncWithFrontmostApp() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        setRaised(front == ProcessInfo.processInfo.processIdentifier)
    }
}

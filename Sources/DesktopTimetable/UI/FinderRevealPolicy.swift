import AppKit

/// 「在访达中显示」时，设置面板给访达窗口**让路**的策略。
///
/// # 背景（实测，不是推测）
///
/// 设置面板是 `.floating` 层级，访达窗口是普通层级。macOS 画窗口时
/// **层级高的永远排在前面，跨 App 也不例外** —— 所以「在访达中显示」打开的
/// 访达窗口，只要设置面板还停在 `.floating`，就一定被盖住。
/// 实测：面板 460×700，访达窗口 920×436，大半个访达窗口在面板底下，
/// 用户点了「在访达中显示」什么也看不见。
///
/// 公开 API 改不了别的 App 的窗口层级（那是私有 API 的地盘），
/// 唯一的办法是让**面板自己让开**。
///
/// # 让开要做两件事，缺一不可
///
/// 1. **降层**到 `.normal` —— 访达窗口才能排在它前面。
/// 2. **收起**（`orderOut`）—— 不是可选项。只降层的话面板仍然看得见、
///    用户一点它，App 立刻回到前台，在途的激活重试又把它顶回前面，
///    访达窗口重新被盖住 —— 这个 bug 会原地复活。
///    收起之后面板不在屏幕上，点不到，也就不会复活。
///
/// # 恢复时机
///
/// 访达揭示只有两个「回来」的入口，两处都走同一个恢复函数：
/// - `applicationDidBecomeActive`：用户切回本 App（只恢复层级，不主动弹面板）。
/// - `show()`：用户从菜单栏/卡片重新打开设置面板（恢复层级 + 显示）。
///
/// 抽成独立类型是为了**单测**：层级取值是纯函数，不依赖真实窗口。
enum FinderRevealPolicy {

    /// 平时设置面板自己的层级：浮层（浮在别的 App 的普通窗口之上）。
    static let restingLevel: NSWindow.Level = .floating

    /// 访达展示期间面板所处的层级：普通层（和访达窗口同级）。
    static let yieldingLevel: NSWindow.Level = .normal

    /// 给定「此刻是否正让路给访达」，面板该用哪个层级。
    ///
    /// 单一事实来源：让路和要回来两处都走它，避免两边的层级写歪。
    static func level(yielding: Bool) -> NSWindow.Level {
        yielding ? yieldingLevel : restingLevel
    }
}

/// 「在访达中显示」要做的几步，顺序固定。
enum FinderRevealStep: Equatable {
    /// 让路：面板降层 + 收起。
    case yieldPanel
    /// 在访达里选中并显示这个文件。
    case selectFile(path: String, root: String)
    /// 显式激活访达，把访达窗口提到最前。
    case activateFinder

    /// 这一步会不会动到**用户桌面**（弹访达窗口 / 抢前台）。
    ///
    /// 自检要真的跑一遍「让路」（它只改本 app 自己的窗口，不打扰用户），
    /// 但不能真的弹访达窗口 —— 用这个标记把两者分开。
    var touchesUserDesktop: Bool {
        switch self {
        case .yieldPanel: return false
        case .selectFile, .activateFinder: return true
        }
    }
}

/// 把「在访达中显示」拆成固定顺序的几步。
///
/// 单独抽出来是为了能单测这个**顺序** —— 顺序错了肉眼看不出来，
/// 用户那边就是「访达窗口还是被盖住」。
enum FinderRevealCoordinator {

    /// 三步，顺序是刻意的 —— 换顺序 bug 就回来：
    /// 1. `yieldPanel`：先让路。访达窗口是普通层、面板是浮层，
    ///    不先降层收起，访达窗口起来的第一眼就在面板底下。
    /// 2. `selectFile`：选中并显示目标文件。
    /// 3. `activateFinder`：显式把访达提到最前（`selectFile` 不保证）。
    static func steps(path: String, root: String) -> [FinderRevealStep] {
        [.yieldPanel, .selectFile(path: path, root: root), .activateFinder]
    }
}

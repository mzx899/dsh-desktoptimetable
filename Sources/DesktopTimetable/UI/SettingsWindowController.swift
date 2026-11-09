import AppKit
import UniformTypeIdentifiers

// ============================================================
/// 滚动视图的文档视图：**顶端在原点**。
///
/// 关键坑：默认的 `NSView` 是**非 flipped** 的 —— 它的原点在**左下角**。
/// `NSScrollView` 的裁剪区原点是 (0,0) 时，看到的是文档的**底部**那一段，
/// 于是「设置面板」一打开就停在最下面（退出应用那块），滚也回不去。
/// 把文档视图翻过来（`isFlipped == true`）后，原点 (0,0) 才是左上角。
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// ============================================================
/// 动画速度倍率（调试用；正常是 1）。
///
/// 存在这里而不是散在各处，是为了让「扩张 / 收缩」两条路径用同一个倍率 ——
/// 只调一条的话，中间态会变成「一边动一边不动」。
final class AnimationSpeed {
    static let shared = AnimationSpeed()
    /// 1 = 正常速度；调大 = 慢放（给中途截图留时间）。
    var factor: Double = 1
}

// ============================================================
/// **内容装得下就藏滚动条**的滚动视图。
///
/// 用户要求：「一个页面可以显示完，右边就不用加拖杆了」。
///
/// 为什么不能直接改 `verticalScroller.isHidden`：
/// NSScrollView 在每次布局时都会**自己**决定滚动条该不该显示
/// （`hasVerticalScroller` 为真就显示），把我们的隐藏改回去。
/// 所以这里在它布局**之后**再藏一次 —— 谁最后说话谁赢。
final class AutoHideScrollView: NSScrollView {

    /// 内容高度是否超过视口（超过 → 要滚动条）。
    private var needsScroller = true

    /// 设定「内容是否超出」，并立刻应用一次。
    func setNeedsScroller(_ needs: Bool) {
        needsScroller = needs
        updateScrollerVisibility()
    }

    /// 把滚动条按当前状态显隐。
    ///
    /// ⚠️ **装得下时要整个关掉滚动条**（`hasVerticalScroller = false`），
    /// 而不是只把 `verticalScroller.isHidden` 设成 true：
    /// overlay 滚动条的淡入淡出由 NSScrollView 自己管 —— 拖动滑杆、
    /// 布局变化、鼠标经过时，系统仍会把它**短暂淡回来**，我们的隐藏
    /// 要等下一次布局才生效，于是用户会看到「闪一下又消失」。
    /// 直接把滚动条从滚动视图上摘掉，系统就没有东西可闪了。
    func updateScrollerVisibility() {
        hasVerticalScroller = needsScroller
        verticalScroller?.isHidden = !needsScroller
    }

    /// 布局完之后再藏一次 —— 盖掉 NSScrollView 自己的设置。
    override func layout() {
        super.layout()
        updateScrollerVisibility()
    }
}

// ============================================================
/// 分类页顶部的「返回」按钮（自绘）。
///
/// 为什么不用 `NSButton`：macOS 26 的 `NSButton` 内部是 SwiftUI 宿主视图，
/// 自带一条高度几百点的内部约束 —— 放进「四边钉死」的容器里，
/// 按钮会被撑到半个窗口高，自己跑到窗外（用户反馈「返回键被裁掉」）。
/// 自绘的版本尺寸完全由我们说了算。
final class HeaderBackButton: NSView {

    /// 点它 → 返回首页。
    var onTap: (() -> Void)?

    /// 这个按钮要返回的板块（自检用：确认板块名和按钮配套）。
    var section: SettingsSection?

    /// 图标（chevron.left，纯色）。
    private let icon = NSImageView()
    /// 文字（「返回」）。
    private let label = NSTextField(labelWithString: "返回")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // 半透明圆角底，和面板的卡片一个调子。
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor

        // **必须声明成按钮** ——
        // 否则辅助功能（VoiceOver）和自动化测试都认不出它是个按钮：
        // AXPress 不会触发，VoiceOver 也不念。
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("返回")
        setAccessibilityValue("返回")
        setAccessibilityTitle("返回")

        // 图标
        let image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回")
        image?.isTemplate = true
        icon.image = image
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        addSubview(icon)

        // 文字
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10),
            icon.heightAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    /// 辅助功能的「按下」（AXPress / VoiceOver 走这条路径）。
    override func accessibilityPerformPress() -> Bool {
        onTap?()
        return true
    }

    /// 鼠标进入 → 底色亮一点。
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
}

// ============================================================
/// 设置面板窗口控制器。
///
/// UI 层整体搬自旧版「课表设置」程序（`课表设置.app`），
/// 保证和旧版长得一模一样；数据读写换成新工程的
/// `ScheduleStore` / `AppearanceConfig`。
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var window: NSWindow!
    var config = AppearanceConfig([:])
    var courses: [Course] = []
    var selectedWeek = 1
    /// 学期配置里的总周数
    var semesterMaxWeek = SemesterConfig.defaultMaxWeek
    /// 生效的总周数（配置值与数据最大周次取大）
    var maxWeek = SemesterConfig.defaultMaxWeek

    /// 新增：设置面板自身的不透明度
    var panelOpRow: SliderRow!

    var fadeInRow: SliderRow!
    var fadeOutRow: SliderRow!
    var minOpRow: SliderRow!
    var maxOpRow: SliderRow!
    /// 课表卡片大小（缩放系数）。
    var cardScaleRow: SliderRow!

    var weekLabel: NSTextField!
    var weekDateLabel: NSTextField!
    var infoLabel: NSTextField!
    var statusLabel: NSTextField!
    var tableView: NSTableView!
    /// 课程时间自定义列表（课表板块 · 课程预览下方）
    var periodEditor: PeriodTimesEditor!
    var semesterPicker: NSDatePicker!
    var semesterInfoLabel: NSTextField!

    var semesterStart = Date()

    /// 学期总周数输入框
    var maxWeekField: NSTextField!
    /// 提示信息（周次缺失 / 超出学期周数 / 数据异常）
    var dataNoticeLabel: NSTextField!

    // ---------- 面板尺寸常量 ----------
    /// 面板宽度（点）。比原来的 520 宽 60pt：滑杆右侧的数值列
    /// （"3.0 s" / "100%"）离右边缘太近，视觉上被挤住。
    static let panelWidth: CGFloat = 580

    /// overlay 滚动条占用的「沟」宽（点）。
    ///
    /// macOS 的滚动条是 **overlay** 样式：浮在内容之上，不占布局空间。
    /// 原来滚动视图的 trailing 边和滑杆数值列的右缘只差 15pt，
    /// 滚动条一浮现就正好压在数值上（用户反馈「右边有点折挡」）。
    /// 给文档视图留出这条沟，滚动条就落在空白里，永远不挡内容。
    static let scrollerGutter: CGFloat = 16

    // ---------- 面板尺寸常量（两级结构）----------

    /// 收起态（板块首页）的窗口尺寸。
    ///
    /// 首页只有 4 个板块按钮，所以是个**小长条** —— 不是一整页长列表。
    static let collapsedSize = NSSize(width: 580, height: 152)

    /// 展开态（分类设置页）的窗口尺寸。
    ///
    /// 高度会被**屏幕可见区**夹住（见 `expandedSize(on:)`）——
    /// 窗口不能超出屏幕可用区域，超出的内容在页面内部滚动。
    static let expandedSize = NSSize(width: 580, height: 700)

    /// 窗口尺寸动画时长（秒）。
    static let resizeAnimationDuration: TimeInterval = 0.28

    /// 动画时长倍率（调试用）。
    ///
    /// 设成 1 = 正常速度。调大是为了给**中途截图**留时间 ——
    /// 0.28s 的动画太快，`screencapture` 根本来不及拍到中间帧。
    /// 正常运行时是 1（`AnimationSpeed.shared.factor` 默认 1）。
    static var animationSpeedFactor: Double {
        get { AnimationSpeed.shared.factor }
        set { AnimationSpeed.shared.factor = newValue }
    }

    /// 展开态下，分类页顶部「返回 + 板块名」那一行占的高度（点）。
    ///
    /// 这一行在**红绿灯正下方**（红绿灯占 y≈13…32），
    /// 所以整条标题带 = 红绿灯高度 + 这一行的高度。
    static let sectionHeaderHeight: CGFloat = 72

    /// 展开态的内容区上下留白（滚动视图边距 + 状态栏 + 一点余量）。
    static let contentPadding: CGFloat = 46

    /// 展开态顶部**整条标题带**占的高度（点）。
    ///
    /// 内容高度必须**加上这一整条** —— 少了它，窗口会比内容还矮，
    /// 卡片会被裁掉（用户反馈「系统」板块只有一张卡时窗口没变高）。
    ///
    /// 这一条包含：红绿灯（y≈13…32）+ 「返回 / 板块名」那一行（y≈38…60）。
    static var expandedHeaderHeight: CGFloat { sectionHeaderHeight }

    /// 数据源
    ///
    /// - `store`：外观配置用的（`config.json` 是全局的，所有课表共用）。
    /// - `timetableStore`：多课表仓库（阶段 3）。课程数据从「当前课表」读。
    private let store: ScheduleStore
    private let timetableStore: TimetableStore?

    /// 统一设置层（外观 + 提醒 / 笔记 / 桌宠）。
    ///
    /// **所有设置写盘都必须走它** —— 不在 UI 里自己拼字典写文件。
    /// 它负责「读旧文件 → 只改自己负责的字段 → 原子写回」，
    /// 这样别的窗口/模块刚改过的值不会被这里的陈旧副本覆盖。
    private let settingsStore: SettingsStore
    /// 当前设置（每次 `reload()` 都从磁盘重读，不拿上次打开时的旧副本）。
    private(set) var appSettings = AppSettings()
    /// 系统通知调度器（自动化模式下不会碰真实系统 API）。
    private let reminderScheduler: ClassReminderScheduler
    /// 登录项控制器（状态以系统为准）。
    private let loginItems: LoginItemController
    /// 提醒设置变了（让 AppDelegate 立刻重排通知）。
    var onReminderSettingsChanged: (() -> Void)?

    // 「提醒与启动」卡片里的控件
    private var reminderSwitch: NSButton!
    private var loginSwitch: NSButton!
    /// 日期覆盖层的设置卡片（接入系统日历 / 提醒事项）。
    private var dayPanelSettingsCard: DayPanelSettingsCard?
    private var leadPopup: NSPopUpButton!
    /// 下拉框当前的结构（条目 ↔ 分钟数的对应关系）。
    ///
    /// action 里要靠它把「选中了第几项」换算成分钟数 —— 不能拿标题反推：
    /// 当前值是自定义时列表会多一项，标题反推就错位了。
    private var leadPopupItems = LeadMinutesChoice.PopupItems(
        titles: [], minutes: [], customEntryIndex: -1, selectedIndex: -1)
    private var loginStatusLabel: NSTextField!
    private var notificationStatusLabel: NSTextField!
    private var testReminderButton: NSButton!
    /// 「打开通知设置」按钮（未授权时也要留着这个入口）。
    private var openNotifyButton: NSButton!
    /// 「去系统设置允许」（仅 `requiresApproval` 时显示）。
    private var loginApprovalButton: NSButton!
    /// 最近一次读到的**通知授权状态**（异步读，缓存下来给按钮用）。
    ///
    /// `nil` = **还没读到**（面板刚打开、查询还在路上）。
    ///
    /// 为什么要缓存：授权状态是异步查的。如果每次刷新都按「未知」处理，
    /// 按钮会先置灰再点亮 —— 闪一下。所以这里存住上一次的结果，
    /// 新的查询回来再更新。**还没读到时不动按钮**（不预判授权与否），
    /// 避免刚打开面板就看到按钮闪一下。
    private var notificationsAuthorized: Bool?
    /// 进程内缓存的上一次授权结果（面板会反复开关，缓存后不必每次重查）。
    ///
    /// 没有它的话，每次打开面板都会先按「未知」置灰、等异步查询回来再点亮 ——
    /// 打开面板的一瞬间按钮会闪一下。
    private static var lastKnownNotificationsAuthorized: Bool?
    /// 面板内容栈（自检探针要按顺序数卡片）。
    ///
    /// ⚠️ 两级结构之后**一个长列表变成了 4 个栈**（每个板块一个）：
    /// `contentStack` 保留下来当「当前可见板块的栈」，自检探针照旧能用；
    /// 各个板块自己的栈放在 `sectionStacks` 里。
    private var contentStack: NSStackView?

    // ---------- 两级结构：板块首页 → 分类设置页 ----------

    /// 面板当前的状态。
    ///
    /// - `home`：收起态 —— 只显示 4 个板块按钮。
    /// - `section(...)`：展开态 —— 显示某个板块的设置卡片。
    private(set) var panelState: PanelState = .home

    /// 面板的状态机。
    enum PanelState: Equatable {
        /// 收起态（板块首页）。
        case home
        /// 展开态（某个板块的设置页）。
        case section(SettingsSection)
    }

    /// 每个板块一个内容栈（卡片按板块分堆）。
    private var sectionStacks: [SettingsSection: NSStackView] = [:]

    /// 板块首页（4 个板块按钮）。
    private var homeScreen: SettingsHomeScreen?

    /// 分类页顶部的「返回」按钮。
    private var backButton: HeaderBackButton?

    /// 分类页顶部的板块名。
    private var sectionTitleLabel: NSTextField?

    /// 分类页顶部的「返回 + 板块名」两个视图（收起态一起隐藏）。
    private var sectionHeaderViews: [NSView] = []

    /// 顶部的标题（收起态显示「课表设置」，展开态显示板块名）。
    private var titleLabel: NSTextField?

    /// 收起态下放在 root 上的**占位视图** —— 收起时首页按钮要显示在窗口里，
    /// 而滚动视图的文档视图在收起态没有内容，所以首页单独放在 root 上。
    private var homeContainer: NSView?

    /// root 的宽/高约束（要随状态动态改，所以存下来）。
    private var rootWidthConstraint: NSLayoutConstraint?
    private var rootHeightConstraint: NSLayoutConstraint?
    /// 滚动文档的高度约束 —— 跟**当前显示的板块**绑定（换板块时重绑）。
    private var docHeightConstraint: NSLayoutConstraint?

    /// 窗口尺寸动画的代号 —— 新的 resize 会让旧动画的收尾作废。
    private var resizeGeneration = 0
    /// 逐帧驱动窗口尺寸动画的定时器（见 `resize`）。
    private var resizeTimer: Timer?
    /// 收放动画的**中心锚点**。
    ///
    /// 为什么不每次都从 `window.frame.midX/midY` 重新算中心：
    /// 窗口框会被系统按像素取整，高度是奇数时 `midY` 会落在 .5 上，
    /// 取整后中心会悄悄挪 0.5pt。连着展开/收起几次，
    /// 长条就会一点点往下漂（自检里 4 个板块切完就漂了 1.5pt）。
    /// 所以锚定第一次的中心，后续动画都用它；只有用户**真的拖动**了窗口
    /// （中心变化超过 2pt）才换新锚点 —— 保证点了板块就在原地展开。
    private var resizeCenterAnchor: NSPoint?

    /// 当前课表的数据仓库（没有课表时为 nil）。
    private var repository: ScheduleRepository? {
        timetableStore?.activeRepository()
    }
    /// 设置变化时的回调（让桌面卡片立刻生效）
    private let onChange: () -> Void
    /// 「课表卡片大小」变了 → 交给桌面那边重排。
    ///
    /// 参数：目标缩放系数、是否写盘（拖动中 false，松手 true）。
    var onCardScaleChange: ((Double, Bool) -> Void)?
    /// 菜单栏图标是否真的显示出来了（macOS 26 的系统级白名单会藏掉它）
    var statusItemVisibleProvider: (() -> Bool)?

    /// 「课表」卡片的摘要文字（当前课表 + 共几份 + 预览里选中了哪份）。
    private var timetableSummaryLabel: NSTextField!

    /// 「课表」卡片里的课表预览（可滚动、单击选中）。
    private var timetablePreviewList: TimetablePreviewList!
    /// 「应用当前课表」蓝色按钮（选中份 == 当前份时置灰）。
    private var timetableApplyBtn: NSButton!
    /// 面板的不透明底（盖在毛玻璃材质之上；滑杆 100% 时盖实 → 面板变实心）。
    private var panelBackdrop: NSView?
    /// 面板的滚动视图（重开时把滚动位置归零）。
    private var panelScrollView: NSScrollView?

    /// 自检用：面板滚动状态（文档视图 frame / 是否 flipped / 裁剪区原点）。
    var debugScrollState: String {
        guard let s = panelScrollView, let d = s.documentView else { return "没有滚动视图" }
        let clip = s.contentView
        let stack = d.subviews.first
        return "doc=\(d.frame) docFlipped=\(d.isFlipped) clipOrigin=\(clip.bounds.origin) "
            + "clipFlipped=\(clip.isFlipped) clipSize=\(clip.bounds.size) "
            + "stack=\(stack?.frame ?? .zero) stackFlip=\(stack?.isFlipped ?? false)"
    }

    /// 自检用：面板的文档视图必须是 **flipped**（顶端在原点）。
    ///
    /// 非 flipped 的文档视图原点在左下角，滚动视图裁剪区原点 (0,0) 时
    /// 显示的是文档**底部**那段 —— 面板一打开就停在「退出应用」那截。
    /// 这条返回 `true` 才说明面板会从顶部开始显示。
    var panelOpensAtTop: Bool {
        guard let d = panelScrollView?.documentView else { return false }
        return d.isFlipped
    }

    /// 自检用：面板里所有**内层**滚动视图（滚轮应当交给外层面板的那几张）。
    ///
    /// 「课表预览」和「课程预览表格」都嵌在面板的外层滚动视图里，
    /// 鼠标停在它们上面时，滚轮会被内层吃掉，外层面板就推不动了。
    /// 这两张必须都是 `WheelForwardingScrollView`。
    var innerScrollViews: [WheelForwardingScrollView] {
        var found: [WheelForwardingScrollView] = []
        func walk(_ view: NSView) {
            if let s = view as? WheelForwardingScrollView { found.append(s) }
            for sub in view.subviews { walk(sub) }
        }
        if let root = window.contentView { walk(root) }
        return found
    }

    /// 自检用：外层面板滚动视图里**嵌着**的所有滚动视图（不管什么类型）。
    ///
    /// 这一条是关键：只看「已经是对的类型」会漏掉回归 ——
    /// 万一有人把某个内层改回普通 `NSScrollView`，只扫类型是发现不了的。
    /// 这里从外层的文档视图往下扫，**所有**嵌套的滚动视图都得过一遍。
    var nestedScrollViews: [NSScrollView] {
        guard let outer = panelScrollView, let doc = outer.documentView else { return [] }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let s = view as? NSScrollView, s !== outer { found.append(s) }
            for sub in view.subviews { walk(sub) }
        }
        walk(doc)
        return found
    }

    /// 自检用：内层滚动视图的滚轮行为是否正确。
    ///
    /// 设置面板里有两种内层滚动视图，规则不同：
    ///   · **转发型**（课表预览 / 课程预览表格）：滚轮一律交给外层面板，
    ///     否则鼠标停在这两块上时外层面板推不动；
    ///   · **自滚型**（课程时间自定义列表）：这是用户要的「内置滚动窗口」，
    ///     滚轮先滚列表自己；列表到底后 AppKit 的嵌套滚动会交给外层面板。
    ///
    /// 判定条件：
    ///   1. 除了课程时间自定义列表，其余嵌着的滚动视图**全部**是
    ///      `WheelForwardingScrollView`（漏掉一个就会重新出现「内层吃掉滚轮」）；
    ///   2. 每个内层滚动视图的 `enclosingScrollView` 都指向面板的外层滚动视图；
    ///   3. 转发型：造一个滚轮事件丢进去，自己**不滚**，转交计数 +1；
    ///   4. 自滚型：同样的滚轮事件丢进去，**自己滚**（证明「内置滚动窗口」可用）。
    var innerScrollForwardsToOuter: Bool {
        guard let outer = panelScrollView else { return false }
        let nested = nestedScrollViews
        let periodScrolling = periodEditor?.scrollViewForTest
        let completedScrolling = completedRowScrollViewForTest
        let selfScrolling = [periodScrolling, completedScrolling].compactMap { $0 }
        // 课表预览 + 课程预览表格 + 作息列表 + 已完成提醒列表
        guard nested.count >= 4 else { return false }
        // 1) 只允许两张「自滚型」是普通滚动视图，其余必须转发型
        for s in nested where !selfScrolling.contains(where: { $0 === s }) {
            if !(s is WheelForwardingScrollView) { return false }
        }
        guard let periodScrolling, nested.contains(where: { $0 === periodScrolling }) else {
            return false
        }
        // 2) 每个内层都要认得出外层
        for inner in nested where inner.enclosingScrollView !== outer { return false }
        // 3) 转发型：内层不动，转交计数 +1
        guard let event = Self.makeScrollEvent(delta: -40) else { return false }
        for inner in nested where !selfScrolling.contains(where: { $0 === inner }) {
            guard let fwd = inner as? WheelForwardingScrollView else { return false }
            let innerBefore = inner.contentView.bounds.origin.y
            let countBefore = fwd.forwardedWheelCount
            inner.scrollWheel(with: event)
            if inner.contentView.bounds.origin.y != innerBefore { return false }
            if fwd.forwardedWheelCount != countBefore + 1 { return false }
        }
        // 4) 自滚型：有可滚内容时要真的推动它自己的内容。
        //    已完成列表在未展开 / 空列表时没有内容，跳过「真的滚」这一条
        //    （它的内部滚动由 `--verify-completed-reminders` 用 210 条数据验证）。
        for scrolling in selfScrolling {
            let documentHeight = scrolling.documentView?.frame.height ?? 0
            let visibleHeight = scrolling.contentView.bounds.height
            guard documentHeight > visibleHeight + 1 else { continue }
            let before = scrolling.contentView.bounds.origin.y
            scrolling.scrollWheel(with: event)
            if scrolling.contentView.bounds.origin.y == before { return false }
        }
        return true
    }

    /// 自检用：已完成列表的内层滚动视图。
    var completedRowScrollViewForTest: NSScrollView? {
        completedRowView?.listScrollViewForTest
    }

    /// 自检用：已完成行本身（真实点击 / 探针）。
    var completedRowForTest: CompletedRemindersRow? { completedRowView }

    /// 造一个程序合成的滚轮事件（自检用，不经过系统 HID）。
    static func makeScrollEvent(delta: Int32) -> NSEvent? {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: 0, wheel2: delta, wheel3: 0)
        cg?.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(delta))
        cg?.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
        cg?.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(delta))
        guard let cg else { return nil }
        return NSEvent(cgEvent: cg)
    }
    /// 预览里当前选中的课表（还没应用）。
    private var selectedTimetableID: String?

    // MARK: - 日记板块状态（2026-11-10）

    /// 日记存储（和日期覆盖层共用同一份 `diary.json`）。
    private let diaryStore = DiaryStore()
    private var diaryEntries: [DiaryEntry] = []
    private var selectedDiaryID: String?
    private var diarySummaryLabel: NSTextField!
    private var diaryListStack: NSStackView?
    private var diaryScrollView: NSScrollView?
    private var diaryEditButton: NSButton?
    private var diaryDeleteButton: NSButton?

    /// 课表集合变了（新建 / 重命名 / 删除 / 切换）—— 上层要立刻刷新桌面卡片。
    var onTimetablesChanged: (() -> Void)?

    /// 打开课表管理面板（由 AppDelegate 提供）。
    var onManageTimetables: (() -> Void)?
    /// 走统一的导入流程（新建 / 覆盖 / 取消三选一）。
    var onImportRequested: (() -> Void)?
    /// 退出整个 app（由 AppDelegate 负责收尾：关桌面窗口、停定时器）。
    var onQuitRequested: (() -> Void)?
    /// 设置面板关闭（用来把「拖动专用画布」恢复成正常窗口）。
    var onPanelClosed: (() -> Void)?

    init(store: ScheduleStore = ScheduleStore(),
         timetableStore: TimetableStore? = nil,
         settingsStore: SettingsStore? = nil,
         reminderScheduler: ClassReminderScheduler? = nil,
         loginItems: LoginItemController? = nil,
         onChange: @escaping () -> Void) {
        self.store = store
        self.timetableStore = timetableStore
        self.settingsStore = settingsStore ?? SettingsStore(configDirectory: store.configDirectory)
        self.reminderScheduler = reminderScheduler ?? ClassReminderScheduler()
        self.loginItems = loginItems ?? LoginItemController()
        self.onChange = onChange
        super.init()
        reload()
    }

    /// 从磁盘重新读一份数据（每次打开面板都调）
    ///
    /// 设置也**每次都重读** —— 不能拿着上次打开面板时的旧副本去保存，
    /// 那会把别的模块（提醒调度器 / 菜单栏）这期间改的值覆盖回去。
    func reload() {
        appSettings = settingsStore.load()
        config = appSettings.appearance.asAppearanceConfig
        guard let repo = repository else {
            courses = []
            semesterStart = Date()
            semesterMaxWeek = SemesterConfig.defaultMaxWeek
            maxWeek = SemesterConfig.defaultMaxWeek
            selectedWeek = currentWeek()
            notices = ["当前没有课表，请先在「课表」里新建或导入一份。"]
            // 空课表状态下预览也要刷新 —— 否则删掉最后一份后列表还挂着旧条目。
            updateTimetableSummary()
            refreshTimetablePreview()
            if window != nil { refreshPreview() }
            return
        }
        let loaded = repo.load()
        courses = loaded.courses
        semesterStart = loaded.semester.start
        semesterMaxWeek = loaded.semester.maxWeek
        maxWeek = loaded.semester.effectiveMaxWeek(for: loaded.courses)
        selectedWeek = currentWeek()
        notices = loaded.notices + loaded.anomalies
        if let err = loaded.error { notices.insert("课表数据读取失败：\(err)", at: 0) }
        updateTimetableSummary()
        refreshTimetablePreview()
        // **课程预览也要马上换成新课表的内容** ——
        // 以前只刷了「课表」摘要和课表列表，课程预览表格还挂着旧课表的行，
        // 要等用户自己切周次或重开面板才更新。
        if window != nil { refreshPreview() }
    }

    /// 数据提示（周次缺失 / 数据异常 / 超出学期周数）
    var notices: [String] = []

    /// 面板摆在哪。
    ///
    /// 以前是「跟着鼠标走」—— 出现在光标下方。鼠标在屏幕左边时面板会被
    /// 顶到最左侧，看着就像「弹到边上去了」。
    /// 现在一律摆在**课表窗口当前中心**（`WindowAnchor`）——
    /// 课表拖到哪儿，面板就跟到哪儿；超出屏幕可见区时夹回来。
    ///
    /// `mouse` 参数保留是为了兼容老调用点，不再决定落点。
    func positionWindow(mouse: NSPoint?) {
        guard let win = window else { return }
        // 以课表中心为锚点（多屏时用课表所在的那块屏）。
        HUDWindow.centerOnScreen(win, near: mouse)
    }

    /// 让设置面板重新对准**当前的课表中心**。
    ///
    /// 缩放时卡片中心可能被「夹进屏幕可见区」而移动；面板不会跟着动，
    /// 用户松手后就会看到「卡片和面板错位」。缩放结束后调一次这里，
    /// 面板回到新的卡片中心（同时更新收放动画的锚点）。
    func alignToCardCenter() {
        guard let win = window, win.isVisible else { return }
        WindowAnchor.place(win)
        resizeCenterAnchor = NSPoint(x: win.frame.midX, y: win.frame.midY)
    }

    // 显示 / 提到最前
    func show(relativeTo mouse: NSPoint?) {
        if window == nil { buildWindow() }
        // ⚠️ **面板的层级保持 `.floating`**（压得住别的 App 的窗口）。
        //
        // 「自检时面板一直悬在用户窗口前面」的解法**不是**改层级 ——
        // `--verify-finder-reveal` 专门验「让路时是 .normal、恢复后是 .floating」，
        // 改层级会把那条自检弄坏。
        //
        // 真正的解法是**自检退出前把面板收走**（`closeForAutomationCleanup()`）——
        // `exit()` 不会走 app 的正常收尾流程，面板会一直挂在那儿。
        // 之前为了「在访达中显示」让过路 → 先摆回浮层（必须排在摆到前面之前）。
        restoreFinderRevealIfNeeded()
        // 又打开了 → 之前那次「被关掉」不算数。
        panelClosed = false
        reload()
        syncUI()
        // 每次打开都回到**收起态**（板块首页）——
        // 上次停在哪个板块不算数，关掉再开就是首页。
        resetToHome()
        // 日期覆盖层的授权状态是**异步**读回来的，打开时要刷新一次
        // （上次读到的可能是几秒前的状态）。
        refreshDayPanelRows()
        positionWindow(mouse: mouse)
        // 重新摆到屏幕中间后，以这个中心为后续收放动画的锚点。
        if let f = window?.frame {
            resizeCenterAnchor = NSPoint(x: f.midX, y: f.midY)
        }
        applyPanelOpacity()
        // 每次打开都从最上面开始（上次滚到哪儿的不算数）
        panelScrollView?.contentView.scroll(to: .zero)
        panelScrollView?.reflectScrolledClipView(panelScrollView!.contentView)
        // 面板必须到**最前**且**拿到 key**：
        // 本 app 是 accessory（LSUIElement），光 `NSApp.activate` 不会把窗口
        // 提到别的 App 上面 —— 实测面板排在豆包 / Hermes 后面（用户说
        // 「每次打开都在最下面」）。而且在 app 还没真正激活时
        // `makeKeyAndOrderFront` 拿不到 key —— 面板看得见却点不动。
        // 统一交给 activateAndTakeKey：它会重试到真的拿到 key 为止。
        // ⚠️ **自动化模式下也要 activate** ——
        //
        // `--verify-focus-flow` 这一项专门验「面板能不能拿到 key window」，
        // 不激活它就跑不了（app 不是前台时，拿不到 key）。
        //
        // 「遮挡用户窗口」的解法**不是**「不激活」——
        // 那是 `--verify-focus-flow` 需要的机制。
        // 真正的解法是**自检结束后把面板收走**（见 `closeForAutomationCleanup()`）：
        // `exit()` 不会走 app 的正常收尾流程，面板会一直悬在用户窗口前面。
        activateAndTakeKey(window) { [weak self] in
            self?.scrollPanelToTop()
        }
        scrollPanelToTop()
    }

    /// 回到收起态（板块首页）—— **不动画**，立刻生效。
    ///
    /// 打开面板时调用：不管上次停在哪个板块，这次都从首页开始。
    private func resetToHome() {
        // 重开面板时把可能还在跑的收放动画掐掉 —— 否则它会继续改窗口尺寸，
        // 和这里的「回到收起态」抢。
        resizeGeneration += 1
        resizeTimer?.invalidate()
        resizeTimer = nil
        // 中心锚点作废：show() 摆正窗口后会重新取。
        resizeCenterAnchor = nil
        panelState = .home
        // 分类页全部藏起来。
        for stack in sectionStacks.values {
            stack.isHidden = true
            stack.alphaValue = 0
        }
        // 首页显示、大标题显示、分类页头部藏起来。
        homeContainer?.isHidden = false
        homeContainer?.alphaValue = 1
        for v in sectionHeaderViews { v.isHidden = true; v.alphaValue = 0 }
        titleLabel?.isHidden = false
        titleLabel?.alphaValue = 1
        // 滚动视图整体收起（收起态只显示首页）。
        panelScrollView?.isHidden = true
        panelScrollView?.alphaValue = 1
        // 窗口尺寸回到收起态（小长条）。
        rootHeightConstraint?.constant = Self.collapsedSize.height
        if let win = window {
            win.setContentSize(Self.collapsedSize)
            win.layoutIfNeeded()
        }
    }

    /// 把焦点（key window）和数据还给面板。
    ///
    /// 差异合并页是独立 `.floating` 窗口，关掉之后 AppKit **不会**自动把 key 还给
    /// 设置面板 —— 用户看到的现象是「设置面板还在，但所有按钮都不响应」。
    /// 所以关窗后显式调这里：重读数据 + 重新到最前 + 拿回 key。
    ///
    /// ⚠️ **面板不可见时不能直接 return** —— 那样就什么都不做：
    /// 数据不刷新（用户看到「导入成功了，列表还是老的」），
    /// 焦点也不回来（按钮像「没反应」）。面板被隐藏时先把它**重新摆出来**再激活。
    /// 唯一的例外是面板已经**被关掉**（不在 `NSApp.windows` 里）——
    /// 那说明用户自己关的，不该硬拽回来。
    func restoreFocus() {
        guard let w = window else { return }
        // 同 show()：让路期间降过层，先摆回浮层再激活。
        restoreFinderRevealIfNeeded()
        if !w.isVisible {
            // 被关掉了（用户主动关的）→ 不硬拽回来。
            guard !panelClosed else { return }
            // 只是被隐藏了 → 摆出来再激活。
            w.orderFrontRegardless()
        }
        reload()
        activateAndTakeKey(w)
    }

    /// 把 app 激活 + 让 `w` 拿到 key window。
    ///
    /// 「面板看得见但点不动」几乎都出在这里，所以这段逻辑要**稳**：
    ///
    /// 1. **激活是异步的**：`NSApp.activate` 调用完那一瞬间 `NSApp.isActive`
    ///    还是 false，得等事件循环转一圈才生效。
    /// 2. **在 app 还没真正激活时调 `makeKeyAndOrderFront`，窗口拿不到 key**。
    ///    窗口会显示出来，但点击和键盘都进不去 —— 正是用户报的现象。
    /// 3. accessory（LSUIElement）app 的激活**不一定一次成功**：
    ///    实测 8 次里有 2 次 `isActive` 始终是 false（跟别的 app 抢前台时更明显）；
    ///    app 刚启动那会儿尤其容易被拒（系统还没把它登记成可激活的 GUI app）。
    ///
    /// 所以这里做**重试 + 退避**：每次尝试都重新激活 + 抢 key，
    /// 间隔逐次拉长 —— 给系统时间把前台让出来。
    ///
    /// - Parameter onReady: 拿到 key 之后回调（可为空）。
    func activateAndTakeKey(_ w: NSWindow, budget: TimeInterval = 10, onReady: (() -> Void)? = nil) {
        activationToken += 1
        let token = activationToken
        // 真正的重试逻辑在 WindowActivation.swift —— 设置面板和差异页共用一份。
        activateWindowAndTakeKey(w, token: token, currentToken: { [weak self] in
            self?.activationToken ?? token
        }, budget: budget, onReady: onReady)
    }

    /// 把面板内容滚回最上面。
    ///
    /// 要滚两次：面板刚 show 的时候内容还没布局完（文档视图高度还是 0），
    /// 这时滚是白滚；等布局跑完再滚一次才是真的到顶。
    /// 另外 `initialFirstResponder = nil` 是为了不让 AppKit 自动把焦点给
    /// 「开学日期」那个 NSDatePicker —— 它一旦拿到焦点，系统会自动把
    /// 滚动视图滚到它那儿，面板就又落到最下面了。
    private func scrollPanelToTop() {
        guard let scroll = panelScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        DispatchQueue.main.async { [weak self] in
            guard let s = self?.panelScrollView else { return }
            let c = s.contentView
            c.scroll(to: .zero)
            s.reflectScrolledClipView(c)
        }
    }

    /// 自检 / 截图用：把面板内容滚到最下面（看长板块的底部卡片）。
    func scrollPanelToBottomForTest() {
        guard let scroll = panelScrollView, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxY = max(0, doc.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(clip)
    }

    /// 自检 / 截图用：把面板内容滚回最上面。
    func panelScrollToTopForTest() {
        guard let scroll = panelScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
    }

    /// 面板不透明度 → (窗口 alpha, 实心底 alpha)（用户定稿的映射）
    ///
    /// - 50% → (1.0, 0)：完全不透明 + 保留毛玻璃质感（= 现在的 100% 的样子）
    /// - 100% → (1.0, 1)：实心，一点透明感都没有
    /// - 20%–50% 之间 → 窗口整体变透明
    static func panelOpacityMapping(_ opacity: Double) -> (windowAlpha: CGFloat, solid: CGFloat) {
        let v = CGFloat(opacity)
        return (min(1, max(0, v * 2)), max(0, min(1, (v - 0.5) / 0.5)))
    }

    /// 设置面板「系统」板块最底部显示的版本号。
    ///
    /// 唯一来源是 App bundle 的 `Info.plist`（Makefile 的 VERSION 写进去的），
    /// **不要在代码里写死版本号** —— 那样每次发版都会忘。
    /// 裸可执行文件（自检 / 出图）没有 Info.plist 时退回「桌面课表」。
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = ((info?["CFBundleShortVersionString"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty else { return "桌面课表" }
        let build = ((info?["CFBundleVersion"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if build.isEmpty || build == short {
            return "桌面课表 · 版本 \(short)"
        }
        return "桌面课表 · 版本 \(short)（build \(build)）"
    }

    /// 面板不透明度（用户定稿的映射）：
    ///
    /// - **50%** = 现在的 100% 的样子（完全不透明，但还带着毛玻璃质感）；
    /// - **100%** = **实心**，一点透明感都没有（不透明底把毛玻璃盖死）；
    /// - 20%–50% 之间是整体变透明（窗口 alpha）。
    ///
    /// 以前 `alphaValue = panelOpacity`，到 100% 也只是「不透明但仍是玻璃」，
    /// 看着还是半透明的 —— 这就是用户说的「100% 还带透明质感」。
    func applyPanelOpacity() {
        guard let win = window else { return }
        let m = Self.panelOpacityMapping(config.panelOpacity)
        win.alphaValue = m.windowAlpha
        panelBackdrop?.alphaValue = m.solid
    }

    /// 把 store 里的最新值同步到界面上
    func syncUI() {
        fadeInRow.setValue(config.fadeInSec)
        fadeOutRow.setValue(config.fadeOutSec)
        minOpRow.setValue(config.minOpacity)
        maxOpRow.setValue(config.maxOpacity)
        panelOpRow.setValue(config.panelOpacity)
        // 卡片大小：上限跟着当前屏幕走（换了屏幕 / 拔了外接屏后可能放不下）。
        let scaleMax = min(CardScalePolicy.maxScale, CardScalePolicy.currentMaxScale())
        cardScaleRow.setMaxValue(scaleMax)
        cardScaleRow.setSubtitle("缩放桌面上的课表 · 范围 70%–"
            + CardScalePolicy.percentText(scaleMax))
        cardScaleRow.setValue(min(config.cardScale, scaleMax))
        semesterPicker.dateValue = semesterStart
        maxWeekField.stringValue = String(semesterMaxWeek)
        syncReminderControls()
        periodEditor?.times = appSettings.periods.times
        updateInfo()
        refreshPreview()
    }

    /// 「发送测试提醒」按钮**能不能点**（纯决策，可单测）。
    ///
    /// 三个条件缺一不可：
    ///   · 提醒开关已打开 —— 没开就没必要发测试提醒；
    ///   · 系统通知**已授权** —— 没授权的话点了必然失败（`sendTestReminder` 会报错），
    ///     与其让用户点了才看到错误，不如直接置灰；
    ///   · 非自动化模式 —— 自检 / 导入 / 测试进程里绝不能发真通知。
    static func testReminderAvailability(reminderEnabled: Bool,
                                         notificationsAuthorized: Bool,
                                         isAutomation: Bool) -> Bool {
        reminderEnabled && notificationsAuthorized && !isAutomation
    }

    /// 按当前状态刷新「发送测试提醒」按钮的可用性。
    ///
    /// 授权状态优先用本次读到的；还没读到就用进程缓存的。
    /// **两都没有**（第一次打开面板）→ 置灰（安全默认：没确认授权就别让用户点）。
    private func updateTestReminderAvailability() {
        guard testReminderButton != nil else { return }
        let authorized = notificationsAuthorized ?? Self.lastKnownNotificationsAuthorized ?? false
        testReminderButton.isEnabled = Self.testReminderAvailability(
            reminderEnabled: appSettings.reminder.enabled,
            notificationsAuthorized: authorized,
            isAutomation: AutomationMode.isCurrentProcessAutomation)
    }

    /// 把提醒 / 登录项的当前状态同步到控件上。
    ///
    /// 全部以**磁盘上的设置 + 系统状态**为准：
    ///   · 提醒开关 / 提前分钟 ← `settings.json`；
    ///   · 登录项开关 ← 系统（`SMAppService`），不存本地 bool。
    func syncReminderControls() {
        guard reminderSwitch != nil else { return }
        reminderSwitch.state = appSettings.reminder.enabled ? .on : .off
        leadPopup.isEnabled = appSettings.reminder.enabled
        rebuildLeadPopup(minutes: appSettings.reminder.leadMinutes)
        refreshNotificationStatus()
        refreshLoginItemStatus()
        updateTestReminderAvailability()
    }

    /// 按当前生效的分钟数重铺下拉框，并选中对应的那一项。
    ///
    /// 结构由 `LeadMinutesChoice` 说了算：候选值 + （当前值不是候选时）多一项
    /// 「提前 12 分钟（自定义）」+ 最后一项「自定义…」。
    ///
    /// 为什么每次都**重铺**而不是追加一项：
    ///   · 追加会让同一个自定义值重复出现（面板每同步一次就多一项）；
    ///   · 项数在 7 / 8 之间变，追加没法保证选中项对得上。
    private func rebuildLeadPopup(minutes: Int) {
        guard leadPopup != nil else { return }
        let items = LeadMinutesChoice.popupItems(currentMinutes: minutes)
        leadPopup.removeAllItems()
        for title in items.titles { leadPopup.addItem(withTitle: title) }
        leadPopup.selectItem(at: items.selectedIndex)
        leadPopupItems = items
    }

    static func leadTitle(_ minutes: Int) -> String {
        LeadMinutesChoice.title(for: minutes)
    }

    /// 系统通知授权状态 → 状态行文案。
    private func refreshNotificationStatus() {
        guard notificationStatusLabel != nil else { return }
        // 一次查询同时拿「授权了没」和「文案」—— 两次查询会出现中间态。
        reminderScheduler.authorizationState { [weak self] authorized, text in
            DispatchQueue.main.async {
                guard let self, self.notificationStatusLabel != nil else { return }
                self.notificationsAuthorized = authorized
                Self.lastKnownNotificationsAuthorized = authorized
                self.notificationStatusLabel.stringValue = "通知权限：\(text)"
                // 未授权时给一个「去设置」的入口（已拒绝时不要反复弹系统框）。
                self.notificationStatusLabel.textColor = text.contains("未授权")
                    ? NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.95)
                    : NSColor.white.withAlphaComponent(0.42)
                // 授权状态回来了 → 刷新「发送测试提醒」按钮的可用性。
                self.updateTestReminderAvailability()
            }
        }
    }

    /// 登录项状态 → 开关 + 状态行文案。
    private func refreshLoginItemStatus() {
        guard loginSwitch != nil else { return }
        let state = loginItems.currentState()
        let desc = LoginItemState.describe(state)
        loginSwitch.state = state.isOn ? .on : .off
        loginSwitch.isEnabled = LoginItemController.isSupported
            && !AutomationMode.isCurrentProcessAutomation
        loginStatusLabel.stringValue = "\(desc.text) · \(desc.detail)"
        loginApprovalButton?.isHidden = !LoginItemState.showsApprovalButton(state)
        loginStatusLabel.textColor = {
            switch state {
            case .failed: return NSColor.systemRed.withAlphaComponent(0.9)
            case .requiresApproval, .unsupportedOS:
                return NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.95)
            default: return NSColor.white.withAlphaComponent(0.42)
            }
        }()
    }

    // MARK: - 提醒与启动：动作

    /// 只刷新「状态行」（通知权限 / 登录项），不动面板里用户正在编辑的控件。
    ///
    /// app 切回前台时用 —— 用户可能刚在系统设置里改过权限。
    func refreshReminderStatusRows() {
        guard reminderSwitch != nil else { return }
        refreshNotificationStatus()
        refreshLoginItemStatus()
    }

    /// 上课提醒开关。
    @objc func reminderToggled() {
        let on = reminderSwitch.state == .on
        do {
            appSettings = try settingsStore.update { $0.reminder.enabled = on }
        } catch {
            // 保存失败必须让用户看见，并且把界面回滚到真实状态
            reminderSwitch.state = appSettings.reminder.enabled ? .on : .off
            presentSaveError("提醒设置未保存：\(error.localizedDescription)")
            return
        }
        leadPopup.isEnabled = on
        updateTestReminderAvailability()
        if on {
            // 首次打开提醒开关 → 请求 .alert + .sound（已拒绝过就不再弹系统框）。
            reminderScheduler.requestAuthorizationIfNeeded { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshNotificationStatus()
                    if !granted {
                        self.statusLabel.stringValue = "系统通知未授权，提醒不会弹出"
                    } else {
                        self.statusLabel.stringValue = "上课提醒已开启"
                    }
                    self.onReminderSettingsChanged?()
                }
            }
        } else {
            statusLabel.stringValue = "上课提醒已关闭 · 待发通知已清空"
            onReminderSettingsChanged?()
        }
        refreshNotificationStatus()
        onChange()
    }

    /// 提前分钟数。
    @objc func leadMinutesChanged(_ sender: Any?) {
        let idx = leadPopup.indexOfSelectedItem
        guard idx >= 0 else { return }
        // 最后一项是「自定义…」→ 弹输入框，让用户自己填分钟数。
        if idx == leadPopupItems.customEntryIndex {
            presentCustomLeadDialog()
            return
        }
        // 其余项的分钟数按**下拉框当前的结构**取 —— 不解析标题。
        guard let minutes = leadPopupItems.minutes[idx] else { return }
        applyLeadMinutes(minutes)
    }

    /// 「自定义…」→ 弹输入框让用户填分钟数。
    ///
    /// 弹窗是模态的：期间设置面板点不动，面板的 Esc / 点外面关面板都会让路
    /// （那两处都判了 `NSApp.modalWindow != nil`）。
    private func presentCustomLeadDialog() {
        let current = appSettings.reminder.leadMinutes
        if let minutes = LeadMinutesDialog.run(current: current) {
            applyLeadMinutes(minutes)
        } else {
            // 取消：刚才那一下选中「自定义…」不算数，下拉框恢复原样。
            rebuildLeadPopup(minutes: appSettings.reminder.leadMinutes)
        }
    }

    /// 存下提前分钟数，并让下拉框跟着变（填了非候选值会多出一项）。
    private func applyLeadMinutes(_ minutes: Int) {
        do {
            appSettings = try settingsStore.update { $0.reminder.leadMinutes = minutes }
        } catch {
            rebuildLeadPopup(minutes: appSettings.reminder.leadMinutes)
            presentSaveError("提前提醒未保存：\(error.localizedDescription)")
            return
        }
        rebuildLeadPopup(minutes: appSettings.reminder.leadMinutes)
        // 0 分钟说「上课时提醒」—— 「提前 0 分钟提醒」读着别扭。
        statusLabel.stringValue = minutes == 0
            ? "上课时提醒"
            : "提前 \(minutes) 分钟提醒"
        onReminderSettingsChanged?()
    }

    /// 从「提前 12 分钟」「上课时提醒」里解析分钟数（纯函数）。
    static func parseLeadTitle(_ title: String) -> Int? {
        LeadMinutesChoice.parseTitle(title)
    }

    /// 开机自启开关。
    @objc func loginItemToggled() {
        let want = loginSwitch.state == .on
        let state = loginItems.setEnabled(want)
        let desc = LoginItemState.describe(state)
        if case .failed(let message) = state {
            // 失败必须让用户看见 —— 开关回到真实状态，不假装成功
            refreshLoginItemStatus()
            presentSaveError("登录自启没有生效：\(message)")
            return
        }
        loginStatusLabel.stringValue = "\(desc.text) · \(desc.detail)"
        refreshLoginItemStatus()
        statusLabel.stringValue = "登录自启：\(desc.text)"
    }

    /// 「去系统设置允许」按钮。
    @objc func openLoginItemSettings() {
        loginItems.openSystemSettings()
    }

    /// 「打开通知设置」按钮。
    @objc func openNotificationSettings() {
        reminderScheduler.openSystemNotificationSettings()
    }

    /// 「发送测试提醒」。
    @objc func sendTestReminder() {
        reminderScheduler.isAuthorized { [weak self] ok in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "系统通知未授权，测试提醒没有发送"
                    self.presentSaveError("系统通知未授权。请到「系统设置 → 通知 → 桌面课表」允许通知。")
                }
                return
            }
            self.reminderScheduler.sendTestReminder { error in
                DispatchQueue.main.async {
                    if let error {
                        self.statusLabel.stringValue = "测试提醒发送失败：\(error.localizedDescription)"
                    } else {
                        self.statusLabel.stringValue = "测试提醒已排程 · 5 秒后弹出"
                    }
                }
            }
        }
    }

    /// 仅供自动化测试用：关掉设置面板。
    func closeForTest() {
        window?.performClose(nil)
    }

    /// 退出前关掉设置面板 —— 不然 terminate 那一瞬间它还开着，会闪一下。
    func closePanel() {
        window?.close()
    }

    /// **自检收尾用**：把面板彻底收走。
    ///
    /// ⚠️ 自检进程调 `exit()` 不会走正常的 app 收尾流程 ——
    /// 面板窗口还开着的话，它会**一直挂在用户的窗口前面**
    /// （用户反馈「现在弹窗会遮挡我的窗口」）。
    ///
    /// 所以每个会 `show()` 面板的自检，退出前都要调这个。
    func closeForAutomationCleanup() {
        // ⚠️ **不要把 `window` 置 nil** ——
        //
        // 置 nil 的话，下次 `buildWindow()` 会**重建**一个窗口，
        // 重建出来的窗口第一帧尺寸和原来不一样 →
        // `--verify-panel-animation` 的「相邻帧最大跳变」会误报
        // （实测 54pt → 75pt，超过 60pt 的门槛）。
        //
        // 只要**关掉**窗口就够了 —— 窗口对象还在，但不再显示，
        // 不会挡在用户窗口前面。
        window?.orderOut(nil)
        window?.close()
    }

    // Esc 关闭面板
    // 注意：事件监视器的 token 必须自己持有，
    // 否则监视器会被立刻释放（Esc 就没反应了）。
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    /// Esc 键该不该把设置面板关掉。
    ///
    /// 抽成纯函数是为了能单测 —— 这个判断依赖 `NSApp.modalWindow` / `isKeyWindow`
    /// 这类全局状态，直接写在事件处理器里就没法在测试里驱动。
    ///
    /// 背景 1：设置面板开着的时候点「退出桌面课表」会弹一个模态确认框。
    /// 这时候面板的 Esc 监视器**不能**把面板关掉，否则确认框背后就空了；
    /// 而且监视器里 `return nil` 会把 Esc 吃掉，模态窗的「取消」快捷键收不到。
    ///
    /// 背景 2：差异合并页是独立浮窗，叠在设置面板**上面**。
    /// 以前监视器只看「收到的是不是 Esc」，不看面板是不是当前 key window ——
    /// 差异页聚焦时按 Esc 会把背后的设置面板关掉。现在只有面板自己是
    /// key window 时才关。
    ///
    /// - Parameters:
    ///   - isModalActive: 当前有没有模态窗在跑。
    ///   - isKeyWindow: 设置面板当前是不是 key window。
    /// - Returns: true = 关掉设置面板；false = 不关，Esc 原样放行。
    static func shouldClosePanelOnEscape(isModalActive: Bool, isKeyWindow: Bool) -> Bool {
        !isModalActive && isKeyWindow
    }

    /// 自检用：Esc 真的把面板关掉了的次数。
    ///
    /// 「面板能收到键盘输入」是「按钮能点」的前提 —— 面板不是 key window 时，
    /// 点击和按键都进不去，表现就是「所有按钮都不响应」。
    var testEscCloseCount = 0

    /// 自检用：面板被「点外面关掉」这条路径关掉的次数。
    ///
    /// 焦点自检跑的时候，用户可能正好在动鼠标 —— 真点一下别处，
    /// 全局鼠标监听就会把面板关掉（那是 popover 的正常行为）。
    /// 自检里这属于干扰，得能把它和「焦点真的丢了」区分开。
    var testOutsideClickCloseCount = 0

    /// 自检用：面板被关掉的次数（不管哪条路径）。
    ///
    /// 用来定位「面板为什么不见了」—— 只知道「不见了」没法区分：
    ///  - 用户点外面关的（干扰）；
    ///  - 焦点流程自己弄没的（bug）；
    ///  - Esc 处理器关的（自检自己发的 Esc）。
    var testAnyCloseCount = 0

    /// 激活重试的作废令牌。
    ///
    /// 每次 `activateAndTakeKey` 都会排一串重试（每次都调 `makeKeyAndOrderFront`）。
    /// 面板关掉之后如果这些重试还在跑，会把**刚关掉的面板重新弹出来** ——
    /// 用户看到的就是「我明明关了它，怎么又自己出来了」。
    /// 所以关窗时 +1，在途的重试发现令牌变了就自己停。
    private var activationToken = 0

    /// 自检探针：面板是不是**被关掉了**（不是「被隐藏」）。
    var testPanelClosed: Bool { panelClosed }

    /// 面板是不是**被关掉了**（不是「被隐藏」）。
    ///
    /// `restoreFocus()` 要区分这两种情况：
    /// - 被关掉 → 用户自己关的，不该硬拽回来（拽回来很烦）；
    /// - 只是不可见 → 得摆出来，否则数据不刷新、焦点也不回来。
    ///
    /// 用显式标志而不是 `NSApp.windows.contains(...)` 判断 —— 后者依赖
    /// AppKit 的窗口表行为（关掉的窗口什么时候被摘掉不是公开契约），
    /// 实测踩到过「面板关了但还在窗口列表里」的坑。
    private(set) var panelClosed = false

    /// 自检用：关掉「点外面关面板」这条路径。
    ///
    /// 焦点自检要验的是「面板能不能拿到 key、按钮能不能点」。
    /// 而「点外面关面板」会让正在跑的检查**因用户碰鼠标而误判** ——
    /// 面板被关了，自然拿不到 key，断言就变成在测干扰而不是测焦点了。
    ///
    /// 自检期间把它关掉，检查才是确定的。
    var testSuppressOutsideClickClose = false

    /// 自检用：面板当前显示的课程名（用来验证「导入后面板数据真的刷新了」）。
    ///
    /// 覆盖导入之后，面板里的课程预览必须换成新课表 —— 数据没刷新的话，
    /// 用户看到的是「导入成功了但列表还是老的」，比按钮没反应更容易误判。
    var testDisplayedCourseNames: [String] {
        courses.map(\.name)
    }

    func installEscHandler() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                // 其他模态窗（导入确认 / 差异页等）开着时，Esc 归模态窗管 ——
                // 这里要是把设置面板关掉，模态窗背后就空了；
                // 而且这里 return nil 会把 Esc 吃掉，模态窗的「取消」快捷键收不到。
                guard Self.shouldClosePanelOnEscape(
                    isModalActive: NSApp.modalWindow != nil,
                    isKeyWindow: self?.window?.isKeyWindow == true
                ) else {
                    return e
                }
                self?.testEscCloseCount += 1
                self?.window?.performClose(nil)
                return nil
            }
            return e
        }
    }

    // 点击面板外部 → 关闭（和系统 popover 的行为一致）
    func installOutsideClickHandler() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self = self, let win = self.window, win.isVisible else { return }
            // 打开文件选择面板/警告框时不要因为「点到别处」把设置窗关掉。
            guard NSApp.modalWindow == nil else { return }
            // 全局监听到的事件里，locationInWindow 是「事件所属窗口」的坐标：
            // 鼠标压在别的 App 窗口上时它根本不是屏幕坐标，
            // 拿它当屏幕坐标换算会把「点面板内部」误判成「点了外面」→ 面板秒关。
            // NSEvent.mouseLocation 才是当前光标的全局屏幕坐标，和 win.frame 同一套坐标系。
            let p = NSEvent.mouseLocation
            if win.frame.contains(p) { return }
            self.testOutsideClickCloseCount += 1
            // 自检期间不开这条：用户碰鼠标会让检查误判（面板被关 → 拿不到 key）。
            guard !self.testSuppressOutsideClickClose else { return }
            self.window?.performClose(nil)
        }
    }

    func currentWeek() -> Int {
        let w = WeekMath.weekNumber(Date(), semesterStart: semesterStart)
        return (1 <= w && w <= maxWeek) ? w : 1
    }

    /// 面板第一次建好时调用：装上事件监视器。
    func installHandlers() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installEscHandler()
        installOutsideClickHandler()
    }

    // ---------- 窗口 ----------
    func buildWindow() {
        // 建 UI 前先把 store 里的值读进来（滑杆初值要取自配置）
        if config.fadeInSec <= 0 { reload() }
        // 窗口一开始就是**收起态**（板块首页）的小长条。
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 窗口层级抬到 .floating：
        // 本 app 是 accessory，点桌面卡片上的齿轮时**根本不会变成前台 App**，
        // 而「非前台的 App 的窗口」在正常层级里永远排在别的 App 窗口后面 ——
        // 这就是「每次打开设置都在最下面」。抬到 .floating 才压得住。
        window.level = .floating
        window.title = "课表设置"
        // 不让 AppKit 自动把焦点给面板里的某个控件（默认会挑「开学日期」的
        // NSDatePicker）—— 控件一拿到焦点，系统会自动把滚动视图滚到它那儿，
        // 面板就落到最下面了。设成 nil = 焦点留在窗口本身，不产生滚动。
        window.initialFirstResponder = nil
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // ⚠️ **必须去掉标题栏的分隔线** ——
        //
        // `.titled` 窗口即使标题透明，macOS 26 仍会在标题栏那条带上画一条
        // 水平分隔线。窗口一缩放，那条线就**留在原地不动**
        // （用户反馈「收缩的时候变成一条黑线往下移」）。
        //
        // 面板是自绘的毛玻璃 + 圆角，不需要系统那条线。
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.delegate = self
        // NSWindow 默认 isReleasedWhenClosed = true：
        // 面板一关，窗口对象就被释放，控制器里的 `window` 变成悬垂指针，
        // 之后任何一次全局鼠标事件都会 objc_retain 野指针 → SIGSEGV。
        window.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(effect)

        // 不透明底：材质层是毛玻璃，永远透着一层桌面颜色。
        // 滑杆拉到 100% 时把这层盖实 → 面板变成「实心」；50% 时它是全透明的
        // （也就是「现在 100%」的样子）。
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.15,
                                                  blue: 0.17, alpha: 1).cgColor
        backdrop.alphaValue = 0
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(backdrop)
        panelBackdrop = backdrop

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)

        // 宽度固定（收起态 / 展开态一样宽），**高度随状态变**。
        // 约束要存下来 —— 切换状态时改 constant，窗口尺寸跟着变。
        let rootWidth = root.widthAnchor.constraint(equalToConstant: Self.panelWidth)
        let rootHeight = root.heightAnchor.constraint(equalToConstant: Self.collapsedSize.height)
        rootWidthConstraint = rootWidth
        rootHeightConstraint = rootHeight

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            effect.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            // 窗口没有 .resizable，AppKit 会按内容的 fitting size 缩放窗口。
            // 这里把内容区钉死成 panelWidth×收起态高度，高度随状态改 constant。
            rootWidth,
            rootHeight,
        ])

        // ---- 收起态：板块首页（4 个板块按钮）----
        //
        // 首页**不放在滚动视图里** —— 收起态没有可滚的内容，
        // 放在滚动视图外面才不会因为文档视图高度为 0 而被裁掉。
        let home = SettingsHomeScreen()
        home.onSelect = { [weak self] section in
            self?.expandTo(section)
        }
        home.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(home)
        homeScreen = home
        homeContainer = home
        NSLayoutConstraint.activate([
            home.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            // 砖块**不能垂直居中** —— 收起态上面还有一行「课表设置」标题，
            // 居中会正好压到标题上（用户反馈「字挡住了」）。
            // 这里钉在标题下方，留 12pt 间距。
            home.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
        ])

        let scroll = AutoHideScrollView()
        panelScrollView = scroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        NSLayoutConstraint.activate([
            // 内容区从**标题带下面**开始 ——
            // 这个 inset 必须和标题带的高度一致（返回键 + 板块名那行），
            // 不然第一张卡片会钻到标题底下去（看着像被裁掉一截）。
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.sectionHeaderHeight),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            // 文档视图比滚动视图窄一条沟：overlay 滚动条浮在内容之上，
            // 留出这条沟它就落在空白区，不会压住滑杆右侧的数值列。
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -Self.scrollerGutter),
        ])

        // 顶部标题
        // 窗口是 .fullSizeContentView + 透明标题栏，红绿灯按钮就浮在左上角。
        // 自绘标题必须让开红绿灯区域（最后一个按钮右边缘约 x=67），否则会压在一起。
        let titleLabel = makeLabel("课表设置", size: 16, weight: .semibold)
        self.titleLabel = titleLabel
        // 标题下的小字已去掉；这里保留一个等高的空占位视图，
        // 让标题和下方内容之间的空白高度保持不变。
        let subSpacer = NSView()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subSpacer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)
        root.addSubview(subSpacer)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 86),
            // 原副标题 11.5pt，行高约 17pt —— 用 fix 高度占位
            subSpacer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subSpacer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subSpacer.heightAnchor.constraint(equalToConstant: 17),
            subSpacer.widthAnchor.constraint(equalToConstant: 1),
        ])

        // ---- 展开态：分类页顶部的「返回」+「板块名」----
        //
        // 「返回」放在**红绿灯正下方**（不是跟板块名并排）——
        // 收起态的小长条和展开后的大页面，红绿灯位置不变，
        // 返回键紧跟在其下，视觉上是一条连贯的竖列。
        //
        // 收起态下这两个都隐藏（alpha 0 + 不接收点击），展开态显示。
        // 它们和上面的「课表设置」标题**不同时显示** ——
        // 收起态显示大标题，展开态显示「返回 + 板块名」。
        // ⚠️ 这里用**自绘的**返回键，不用 `NSButton` ——
        // macOS 26 的 `NSButton` 内部是 SwiftUI 宿主视图（`_NSCoreHostingView`），
        // 它自带一条高度几百点的内部约束；不给上限的话按钮会被撑成
        // 「半个窗口那么高」，自己跑到窗外去了（用户看到返回键被裁掉）。
        // 自绘的版本尺寸完全由我们说了算。
        let backBtn = HeaderBackButton()
        backBtn.onTap = { [weak self] in self?.backToHome() }
        backBtn.section = nil
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        backButton = backBtn

        let sectionTitle = makeLabel("", size: 15, weight: .semibold)
        sectionTitleLabel = sectionTitle

        // 「返回」和「板块名」各自直接挂在 root 上 ——
        // **不能塞进同一个 NSStackView**：栈会重新设置父视图，
        // 约束就跨了层级（"no common ancestor" 崩溃）。
        // 收起态 / 展开态切换时分别控制这两个的显隐。
        root.addSubview(backBtn)
        root.addSubview(sectionTitle)
        // addSubview 之后**再**关一次 —— addSubview 有时会重置这个标志。
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false

        // 收起态 / 展开态切换时用这两个控制显隐。
        sectionHeaderViews = [backBtn, sectionTitle]

        // 「返回」和「板块名」在**同一条水平线**上 ——
        // 而且这一行在**红绿灯的正下方**（红绿灯占 y≈13…32，
        // 标题带从 y=38 开始），三者连成一片，不会互相压。
        //
        // ⚠️ **必须给按钮钉死高度** ——
        // macOS 26 的 `NSButton` 内部是 SwiftUI 宿主视图（`_NSCoreHostingView`），
        // 它自带一条高度几百点的内部约束；不给上限的话按钮会被撑成
        // 「半个窗口那么高」，自己就跑到窗外去了（用户看到返回键被裁掉）。
        NSLayoutConstraint.activate([
            backBtn.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            backBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 13),
            backBtn.widthAnchor.constraint(equalToConstant: 62),
            backBtn.heightAnchor.constraint(equalToConstant: 22),
            // ⚠️ 高度上限：内部子视图（图标 + 文字）撑出来的**固有高度**不能把
            // 按钮拉高 —— 必须显式压住，否则按钮会变成几百点高，
            // 自己跑到窗口外面去（返回键被裁掉）。
            backBtn.heightAnchor.constraint(lessThanOrEqualToConstant: 24),
            // 板块名：跟返回键**垂直居中对齐**（同一条水平线）。
            sectionTitle.centerYAnchor.constraint(equalTo: backBtn.centerYAnchor),
            sectionTitle.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            // ⚠️ 板块名也要钉死高度 —— 它是 NSTextField，
            // 在四边钉死的容器里不给高度会被拉成整行高。
            sectionTitle.heightAnchor.constraint(equalToConstant: 18),
        ])

        // 内容栈
        //
        // 两级结构：**每个板块一个栈**。卡片照旧一个个 `addArrangedSubview`，
        // 到了板块边界就把 `stack` 换到下一个板块的栈上 —— 卡片代码本身一行不用改。
        var stack = NSStackView()
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])
        // 第一个栈 = 外观板块
        sectionStacks[.appearance] = stack

        // ---- 渐变动画卡片 ----
        // 两个滑杆上限统一为 6 秒，副标题里写明范围
        let fadeCard = SettingsCard(title: "渐变动画")
        fadeInRow = SliderRow(title: "变实秒数", subtitle: "鼠标移入后变清晰 · 范围 0.1–6.0 s",
                              min: 0.1, max: 6.0,
                              value: clamp(config.fadeInSec, 0.1, 6.0),
                              step: 0.1, decimals: 1) { String(format: "%.1f s", $0) }
        fadeOutRow = SliderRow(title: "变虚秒数", subtitle: "鼠标移开后变模糊 · 范围 0.1–6.0 s",
                               min: 0.1, max: 6.0,
                               value: clamp(config.fadeOutSec, 0.1, 6.0),
                               step: 0.1, decimals: 1) { String(format: "%.1f s", $0) }
        fadeInRow.onChange = { [weak self] v in self?.update("fadeInSec", v) }
        fadeOutRow.onChange = { [weak self] v in self?.update("fadeOutSec", v) }
        fadeCard.addRow(fadeInRow)
        fadeCard.addRow(fadeOutRow)
        stack.addArrangedSubview(fadeCard)
        fadeCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 不透明度卡片 ----
        // 用「不透明度」而不是「透明度」：CSS opacity 的语义是不透明度，
        // 0% = 完全看不见，100% = 完全不透明。叫「透明度」时 0%/100% 的含义正好反过来。
        let opCard = SettingsCard(title: "最终不透明度")
        // 变虚（静置时）不透明度：0% 全透明，100% 就是「不变虚」——始终清晰可见。
        minOpRow = SliderRow(title: "变虚不透明度", subtitle: "静置时 · 100% 即不变虚", min: 0.0, max: 1.0,
                             value: config.minOpacity,
                             step: 0.01, decimals: 2) { String(format: "%.0f%%", $0 * 100) }
        // 变实（悬停时）不透明度：0% 悬停也看不见，100% 完全清晰。
        maxOpRow = SliderRow(title: "变实不透明度", subtitle: "悬停时 · 100% 即完全清晰", min: 0.0, max: 1.0,
                             value: config.maxOpacity,
                             step: 0.01, decimals: 2) { String(format: "%.0f%%", $0 * 100) }
        minOpRow.onChange = { [weak self] v in self?.update("minOpacity", v) }
        maxOpRow.onChange = { [weak self] v in self?.update("maxOpacity", v) }
        opCard.addRow(minOpRow)
        opCard.addRow(maxOpRow)
        stack.addArrangedSubview(opCard)
        opCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 设置面板卡片 ----
        // 调的是「课表设置」这个窗口自己的透明度，不影响桌面上的课表卡片。
        let panelCard = SettingsCard(title: "设置面板")
        panelOpRow = SliderRow(title: "面板不透明度",
                               subtitle: "50% = 现在的样子（带毛玻璃感）· 100% = 实心不透",
                               min: 0.2, max: 1.0,
                               value: config.panelOpacity,
                               step: 0.01, decimals: 2) { String(format: "%.0f%%", $0 * 100) }
        panelOpRow.onChange = { [weak self] v in self?.update("panelOpacity", v) }
        panelCard.addRow(panelOpRow)
        stack.addArrangedSubview(panelCard)
        panelCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 课表卡片大小 ----
        //
        // 整体等比缩放桌面上的课表卡片（**不影响**这个设置面板本身）。
        //
        // 交互口径（2026-11 与用户确认）：
        //   · **拖动中实时变化** —— 课表跟着滑块即时胀大 / 缩小；
        //   · **松手才写盘** —— 拖动过程中每帧写盘太浪费；
        //   · 缩放**以卡片中心为锚点** —— 课表原地变化，不会「从某个角拽出来」。
        //
        // 上限说明：**滑块上限 = 当前屏幕放得下的最大值**（取 70%–115% 与
        // 「按屏幕算的 maxScale」的较小值）。
        //
        // ⚠️ 以前滑块固定 115%，但 115% 在这块屏上放不下（上限约 112%），
        // 于是拖到 112%–115% 时：
        //   · 卡片不再变大（被夹住），百分比却还在涨 —— 看着像「比例不对」；
        //   · 设置面板每帧把滑杆值改回 112%（`setValue`），和鼠标较劲 ——
        //     用户感觉「拖不动 / 粘住」。
        // 直接把上限设成真实上限，两个问题一起消失。
        let scaleMax = min(CardScalePolicy.maxScale, CardScalePolicy.currentMaxScale())
        let scaleCard = SettingsCard(title: "课表大小")
        cardScaleRow = SliderRow(title: "卡片大小",
                                 subtitle: "缩放桌面上的课表 · 范围 70%–"
                                     + CardScalePolicy.percentText(scaleMax),
                                 min: CardScalePolicy.minScale,
                                 max: scaleMax,
                                 value: min(config.cardScale, scaleMax),
                                 step: CardScalePolicy.step, decimals: 2) { CardScalePolicy.percentText($0) }
        cardScaleRow.onChange = { [weak self] v in self?.updateCardScale(v, persist: false) }
        cardScaleRow.onDragEnd = { [weak self] v in self?.updateCardScale(v, persist: true) }
        cardScaleRow.onChange = { [weak self] v in self?.updateCardScale(v, persist: false) }
        cardScaleRow.onDragEnd = { [weak self] v in self?.updateCardScale(v, persist: true) }
        scaleCard.addRow(cardScaleRow)
        stack.addArrangedSubview(scaleCard)
        scaleCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 板块边界：外观 → 课表 ----
        //
        // 「学期」及之后的课表相关卡片都进「课表」板块的栈。
        // 换一个栈就等于换了一个分类设置页 —— 卡片控件本身完全不动。
        stack = makeSectionStack(.timetable, in: doc)

        // ---- 学期卡片 ----
        let semCard = SettingsCard(title: "学期")
        let semLabel = makeLabel("开学日期", size: 12.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.85))
        let semHint = makeLabel("用于计算「本周」是第几周", size: 10.5, color: NSColor.white.withAlphaComponent(0.38))

        semesterPicker = NSDatePicker()
        semesterPicker.datePickerStyle = .textField
        semesterPicker.datePickerElements = [.yearMonthDay]
        semesterPicker.dateValue = semesterStart
        // .textField 样式本身即可直接输入日期（yyyy/M/d），
        // 上下箭头逐日 / 逐月增减。
        semesterPicker.controlSize = .small
        semesterPicker.font = .systemFont(ofSize: 12)
        semesterPicker.target = self
        semesterPicker.action = #selector(semesterChanged)
        semesterPicker.translatesAutoresizingMaskIntoConstraints = false

        semesterInfoLabel = makeLabel("", size: 11, color: NSColor.white.withAlphaComponent(0.5))
        semesterInfoLabel.translatesAutoresizingMaskIntoConstraints = false

        // 数据提示（周次缺失 / 超出学期周数 / 数据异常）
        dataNoticeLabel = makeLabel("", size: 10.5, color: NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.9))
        dataNoticeLabel.lineBreakMode = .byWordWrapping
        dataNoticeLabel.maximumNumberOfLines = 4
        dataNoticeLabel.translatesAutoresizingMaskIntoConstraints = false

        let semRow = NSStackView(views: [semLabel, semesterPicker])
        semRow.orientation = .horizontal
        semRow.spacing = 10
        semRow.alignment = .centerY

        // 学期总周数
        let maxWeekLabel = makeLabel("学期总周数", size: 12.5, weight: .medium,
                                     color: NSColor.white.withAlphaComponent(0.85))
        maxWeekField = NSTextField(string: String(semesterMaxWeek))
        maxWeekField.font = .systemFont(ofSize: 12)
        maxWeekField.controlSize = .small
        maxWeekField.alignment = .right
        maxWeekField.target = self
        maxWeekField.action = #selector(maxWeekChanged)
        maxWeekField.translatesAutoresizingMaskIntoConstraints = false
        maxWeekField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let maxWeekHint = makeLabel("1–30 周，决定翻周范围与「本周」计算",
                                    size: 10.5, color: NSColor.white.withAlphaComponent(0.38))
        let maxWeekRow = NSStackView(views: [maxWeekLabel, maxWeekField])
        maxWeekRow.orientation = .horizontal
        maxWeekRow.spacing = 10
        maxWeekRow.alignment = .centerY

        semCard.content.addArrangedSubview(semRow)
        semCard.content.addArrangedSubview(semHint)
        semCard.content.addArrangedSubview(semesterInfoLabel)
        semCard.content.addArrangedSubview(maxWeekRow)
        semCard.content.addArrangedSubview(maxWeekHint)
        semCard.content.addArrangedSubview(dataNoticeLabel)
        stack.addArrangedSubview(semCard)
        semCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 课表数据卡片 ----
        let dataCard = SettingsCard(title: "课表数据")
        infoLabel = makeLabel("", size: 11.5, color: NSColor.white.withAlphaComponent(0.55))
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 2
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        // 两个按钮都**带符号**、**同宽**，并且「导入课表」不再带省略号
        // （2026-11-09 用户要求：菜单项前面加符号、去掉省略号、两个框一样长）。
        //
        // 用 `makeIconButton`（课表卡片那一排「新建 / 重命名 / …」同款），
        // 图标 + 文字左对齐；宽度钉成同一个常量，否则 NSButton 各自按文字宽度收缩，
        // 两个圆角框一个长一个短。
        let importBtn = makeIconButton("导入课表", symbol: "square.and.arrow.down",
                                       action: #selector(importSchedule))
        let revealBtn = makeIconButton("在访达中显示", symbol: "folder",
                                       action: #selector(revealData))
        // 126pt 是按「在访达中显示」（6 个汉字 + 图标 + 内边距）量出来的宽度。
        let dataButtonWidth: CGFloat = 126
        for b in [importBtn, revealBtn] {
            b.widthAnchor.constraint(equalToConstant: dataButtonWidth).isActive = true
        }

        let btnRow = NSStackView(views: [importBtn, revealBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.alignment = .leading

        dataCard.content.addArrangedSubview(infoLabel)
        dataCard.content.addArrangedSubview(btnRow)
        stack.addArrangedSubview(dataCard)
        dataCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 课表卡片（阶段 3）：可滚动的课表预览 + 一排操作 + 蓝色「应用当前课表」----
        //
        // 以前这里只有一句摘要 + 四个按钮，点哪个都只是把「课表管理」窗口叫出来，
        // 选课表还要再点一次双击 —— 绕。现在预览直接列在设置面板里：
        // 单击选中 → 点「应用当前课表」才真正切换。
        let ttCard = SettingsCard(title: "课表")
        timetableSummaryLabel = makeLabel("", size: 11.5, color: NSColor.white.withAlphaComponent(0.55))
        timetableSummaryLabel.lineBreakMode = .byWordWrapping
        timetableSummaryLabel.maximumNumberOfLines = 2
        timetableSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        // 课表预览（自绘行 · 可滚动 · 单击选中）
        timetablePreviewList = TimetablePreviewList()
        timetablePreviewList.translatesAutoresizingMaskIntoConstraints = false
        timetablePreviewList.heightAnchor.constraint(equalToConstant: 112).isActive = true
        timetablePreviewList.onSelect = { [weak self] id in
            guard let self else { return }
            self.selectedTimetableID = id
            self.updateTimetableSummary()
        }

        // 一排操作按钮（前面带符号）
        let ttNewBtn = makeIconButton("新建", symbol: "plus", action: #selector(newTimetable))
        let ttRenameBtn = makeIconButton("重命名", symbol: "pencil", action: #selector(renameTimetable))
        let ttDeleteBtn = makeIconButton("删除", symbol: "trash", action: #selector(deleteTimetable))
        let ttManageBtn = makeIconButton("管理", symbol: "gearshape", action: #selector(manageTimetables))

        // 蓝色主按钮：把预览里选中的那份真正应用为当前课表
        let applyBtn = NSButton(title: "应用当前课表", target: self, action: #selector(applyTimetable))
        applyBtn.bezelStyle = .rounded
        applyBtn.bezelColor = .systemBlue
        applyBtn.contentTintColor = .white
        applyBtn.font = .systemFont(ofSize: 12, weight: .semibold)
        applyBtn.controlSize = .small
        timetableApplyBtn = applyBtn

        // 弹性垫片：把蓝色按钮推到最右边
        let ttSpacer = NSView()
        ttSpacer.translatesAutoresizingMaskIntoConstraints = false
        ttSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ttSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let ttBtnRow = NSStackView(views: [ttNewBtn, ttRenameBtn, ttDeleteBtn, ttManageBtn,
                                           ttSpacer, applyBtn])
        ttBtnRow.orientation = .horizontal
        ttBtnRow.spacing = 8
        ttBtnRow.alignment = .centerY

        ttCard.content.addArrangedSubview(timetableSummaryLabel)
        ttCard.content.addArrangedSubview(timetablePreviewList)
        ttCard.content.addArrangedSubview(ttBtnRow)
        stack.addArrangedSubview(ttCard)
        ttCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 预览卡片 ----
        let previewCard = SettingsCard(title: "课程预览")
        let prevBtn = NSButton(title: "◀", target: self, action: #selector(prevWeek))
        prevBtn.bezelStyle = .rounded
        prevBtn.controlSize = .small
        prevBtn.font = .systemFont(ofSize: 11)
        let nextBtn = NSButton(title: "▶", target: self, action: #selector(nextWeek))
        nextBtn.bezelStyle = .rounded
        nextBtn.controlSize = .small
        nextBtn.font = .systemFont(ofSize: 11)
        weekLabel = makeLabel("第 1 周", size: 12, weight: .semibold, color: SettingsStyle.accent)
        weekLabel.alignment = .center
        weekDateLabel = makeLabel("", size: 10.5, color: NSColor.white.withAlphaComponent(0.42))
        weekDateLabel.alignment = .center

        let weekStack = NSStackView(views: [weekLabel, weekDateLabel])
        weekStack.orientation = .vertical
        weekStack.spacing = 1
        weekStack.alignment = .centerX

        let thisWeekBtn = NSButton(title: "本周", target: self, action: #selector(gotoCurrentWeek))
        thisWeekBtn.bezelStyle = .rounded
        thisWeekBtn.controlSize = .small
        thisWeekBtn.font = .systemFont(ofSize: 11)

        let weekRow = NSStackView(views: [prevBtn, weekStack, nextBtn, thisWeekBtn])
        weekRow.orientation = .horizontal
        weekRow.spacing = 10
        weekRow.alignment = .centerY

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false

        // 表格可用宽度的推导（都从 panelWidth 算，改宽度时列宽自动跟上）：
        //   面板 580 − 左右边距 18×2 = 544（滚动视图宽）
        //   − 外层滚动条沟 16        = 528（文档/卡片宽）
        //   − 卡片内边距 15×2         = 498（卡片内容宽）
        //   − 表格滚动条沟 16         = 482（表格宽）
        let tableWidth = Self.panelWidth - 18 * 2 - Self.scrollerGutter - 15 * 2 - Self.scrollerGutter
        let tableColumns: [(String, CGFloat)] = [
            ("时间", 112), ("课程", 148), ("教师", 86), ("地点", 136),
        ]
        let colTotal = tableColumns.reduce(0) { $0 + $1.1 }
        for (title, width) in tableColumns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            col.title = title
            // 余量补给「地点」列（最容易写不下的一列）
            col.width = width + (tableWidth - colTotal)
            col.minWidth = 40
            tableView.addTableColumn(col)
        }

        // 课程预览表格：滚轮交给外层面板（内层只能用右边的滚动条看内容），
        // 否则鼠标停在这张表上时，滚轮会被内层吃掉，外层面板滚不动。
        let scrollTable = WheelForwardingScrollView()
        scrollTable.documentView = tableView
        scrollTable.hasVerticalScroller = true
        // 列宽已经刚好等于表格宽，再要横向滚动条只会露出一截空轨道
        scrollTable.hasHorizontalScroller = false
        scrollTable.drawsBackground = false
        scrollTable.borderType = .noBorder
        scrollTable.translatesAutoresizingMaskIntoConstraints = false
        scrollTable.heightAnchor.constraint(equalToConstant: 168).isActive = true
        // 表格比裁剪区窄一条沟：表格自己的 overlay 滚动条同样浮在内容上，
        // 不留沟就会压住最后一列（地点）的字。
        tableView.widthAnchor.constraint(
            equalTo: scrollTable.contentView.widthAnchor,
            constant: -Self.scrollerGutter
        ).isActive = true

        previewCard.content.addArrangedSubview(weekRow)
        previewCard.content.addArrangedSubview(scrollTable)
        stack.addArrangedSubview(previewCard)
        previewCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 课程时间自定义（课程预览下面）----
        //
        // 内置滚动列表：10 节课的起止时间就地改，改完立刻写盘。
        // 只开放**钟点**，节数固定 10 节 —— 网格行数 / 导入解析 / 提醒排程
        // 都绑定这个数量，增删节次不是「设置」能安全承担的事。
        let periodCard = SettingsCard(title: "课程时间自定义")
        let periodHint = makeLabel("每节课的开始 / 结束时间（24 小时制，自动补零）。回车或点到别处自动保存。",
                                   size: 10.5, color: NSColor.white.withAlphaComponent(0.42))
        periodHint.lineBreakMode = .byWordWrapping
        periodHint.maximumNumberOfLines = 2
        periodHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        periodHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let periodResetBtn = makeIconButton("恢复默认", symbol: "arrow.counterclockwise",
                                           action: #selector(resetPeriodTimes))

        let periodHeader = NSStackView(views: [periodHint, periodResetBtn])
        periodHeader.orientation = .horizontal
        periodHeader.spacing = 8
        periodHeader.alignment = .centerY

        periodEditor = PeriodTimesEditor()
        periodEditor.times = appSettings.periods.times
        periodEditor.translatesAutoresizingMaskIntoConstraints = false
        periodEditor.heightAnchor.constraint(equalToConstant: 176).isActive = true
        periodEditor.onCommit = { [weak self] times in
            self?.savePeriodTimes(times)
        }

        periodCard.content.addArrangedSubview(periodHeader)
        periodCard.content.addArrangedSubview(periodEditor)
        stack.addArrangedSubview(periodCard)
        periodCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 板块边界：课表 → 日记（2026-11-10 新增）----
        stack = makeSectionStack(.diary, in: doc)
        buildDiarySection(into: stack)

        // ---- 板块边界：课表 → 提醒 ----
        stack = makeSectionStack(.reminder, in: doc)

        // ---- 提醒与启动卡片（1.1.0 新增，放在退出应用之上）----
        //
        // 版式沿用 SettingsCard，和上面的卡片完全一致；原有卡片一个都不动。
        // 内容顺序按用户定的来：开机自启 → 上课提醒 → 提前提醒 → 状态行 → 测试按钮。
        let remindCard = SettingsCard(title: "提醒与启动")

        loginSwitch = NSButton(checkboxWithTitle: "开机自启",
                               target: self, action: #selector(loginItemToggled))
        loginSwitch.font = .systemFont(ofSize: 12.5)
        loginSwitch.translatesAutoresizingMaskIntoConstraints = false

        loginStatusLabel = makeLabel("", size: 10.5, color: NSColor.white.withAlphaComponent(0.42))
        loginStatusLabel.lineBreakMode = .byWordWrapping
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let loginApproveBtn = NSButton(title: "去系统设置允许",
                                       target: self, action: #selector(openLoginItemSettings))
        loginApproveBtn.bezelStyle = .rounded
        loginApproveBtn.controlSize = .small
        loginApproveBtn.font = .systemFont(ofSize: 11.5)
        loginApproveBtn.translatesAutoresizingMaskIntoConstraints = false
        loginApprovalButton = loginApproveBtn

        reminderSwitch = NSButton(checkboxWithTitle: "上课提醒",
                                  target: self, action: #selector(reminderToggled))
        reminderSwitch.font = .systemFont(ofSize: 12.5)
        reminderSwitch.translatesAutoresizingMaskIntoConstraints = false

        let leadLabel = makeLabel("提前提醒", size: 12.5, weight: .medium,
                                  color: NSColor.white.withAlphaComponent(0.85))
        leadLabel.translatesAutoresizingMaskIntoConstraints = false
        leadPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        leadPopup.font = .systemFont(ofSize: 12)
        leadPopup.controlSize = .small
        leadPopup.target = self
        leadPopup.action = #selector(leadMinutesChanged(_:))
        // 条目不在这里写死：下拉框的结构会随「当前值是不是自定义」变，
        // 由 rebuildLeadPopup() 统一铺（见 LeadMinutesChoice）。
        leadPopup.translatesAutoresizingMaskIntoConstraints = false
        // 宽度要放得下最长的那项：「提前 12 分钟（自定义）」
        // —— 窄了会被截成「提前 12 分…」，用户看不出自己设了几分钟。
        leadPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 162).isActive = true

        let leadRow = NSStackView(views: [leadLabel, leadPopup])
        leadRow.orientation = .horizontal
        leadRow.spacing = 10
        leadRow.alignment = .centerY
        leadRow.translatesAutoresizingMaskIntoConstraints = false

        notificationStatusLabel = makeLabel("", size: 10.5, color: NSColor.white.withAlphaComponent(0.42))
        notificationStatusLabel.lineBreakMode = .byWordWrapping
        notificationStatusLabel.maximumNumberOfLines = 2
        notificationStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        testReminderButton = NSButton(title: "发送测试提醒",
                                      target: self, action: #selector(sendTestReminder))
        testReminderButton.bezelStyle = .rounded
        testReminderButton.controlSize = .small
        testReminderButton.font = .systemFont(ofSize: 11.5)
        testReminderButton.translatesAutoresizingMaskIntoConstraints = false

        let openNotifyBtn = NSButton(title: "打开通知设置",
                                     target: self, action: #selector(openNotificationSettings))
        openNotifyBtn.bezelStyle = .rounded
        openNotifyBtn.controlSize = .small
        openNotifyBtn.font = .systemFont(ofSize: 11.5)
        openNotifyBtn.translatesAutoresizingMaskIntoConstraints = false
        openNotifyButton = openNotifyBtn

        let remindButtonsRow = NSStackView(views: [testReminderButton, openNotifyBtn])
        remindButtonsRow.orientation = .horizontal
        remindButtonsRow.spacing = 8
        remindButtonsRow.alignment = .centerY
        remindButtonsRow.translatesAutoresizingMaskIntoConstraints = false

        remindCard.addRow(loginSwitch)
        remindCard.addRow(loginStatusLabel)
        remindCard.addRow(loginApproveBtn)
        remindCard.addRow(reminderSwitch)
        remindCard.addRow(leadRow)
        remindCard.addRow(notificationStatusLabel)
        remindCard.addRow(remindButtonsRow)
        stack.addArrangedSubview(remindCard)
        remindCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 日期覆盖层卡片（接入系统日历 / 提醒事项）----
        //
        // 放在「提醒与启动」下面 —— 两者都是「往系统里接东西」，
        // 放一起用户找得到。
        let dayPanelCard = DayPanelSettingsCard()
        dayPanelCard.onToggleEnabled = { [weak self] enabled in
            self?.dayPanelEnabledToggled(enabled)
        }
        dayPanelCard.onSelectList = { [weak self] in
            self?.presentDayPanelListPicker()
        }
        dayPanelCard.onCreateList = { [weak self] title in
            self?.createDayPanelList(titled: title)
        }
        dayPanelCard.onOpenAuthorization = { [weak self] in
            self?.openDayPanelSystemSettings()
        }
        dayPanelCard.onToggleWeather = { [weak self] enabled in
            self?.dayPanelWeatherToggled(enabled)
        }
        dayPanelCard.onOpenLocationSettings = { [weak self] in
            self?.openLocationSettings()
        }

        // ---- 第三行：已完成的提醒事项 ----
        let completedRow = dayPanelCard.completedRowView
        completedRow.onToggleExpanded = { [weak self] expanded in
            self?.setCompletedExpanded(expanded)
        }
        completedRow.onRetry = { [weak self] in
            self?.reloadCompletedReminders()
        }
        completedRow.onOpenSystemSettings = { [weak self] in
            self?.openDayPanelSystemSettings()
        }
        completedRow.onSearchChange = { [weak self] text in
            self?.scheduleCompletedSearch(text)
        }
        completedRow.onListFilterChange = { [weak self] identifier in
            self?.applyCompletedListFilter(identifier)
        }
        completedRow.onLoadMore = { [weak self] in
            self?.loadMoreCompletedReminders()
        }
        completedRow.onRestore = { [weak self] item in
            self?.restoreCompletedReminder(item)
        }
        completedRow.onDelete = { [weak self] item in
            self?.deleteCompletedReminder(item)
        }
        completedRow.onDeleteAll = { [weak self] in
            self?.presentDeleteAllCompleted()
        }
        completedRowView = completedRow

        stack.addArrangedSubview(dayPanelCard)
        dayPanelCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dayPanelSettingsCard = dayPanelCard
        bindCompletedRemindersService()

        // ---- 板块边界：提醒 → 系统 ----
        stack = makeSectionStack(.system, in: doc)

        // ---- 退出应用卡片（放在最下面）----
        //
        // 为什么必须有这个：菜单栏图标可能被 macOS 26 的系统白名单拦掉
        // （「系统设置 → 菜单栏 → 允许在菜单栏中显示」里没勾选）。
        // 那种情况下 app 在跑、桌面卡片也在，但用户**没有任何入口能退出** ——
        // 菜单栏图标找不到，⌘Q 因为是 accessory app 也不一定奏效。
        // 设置面板是唯一稳定的入口，所以退出按钮必须放在这里。
        let quitCard = SettingsCard(title: "退出应用")
        let quitHint = makeLabel("退出后课表卡片会从桌面消失，数据不会丢失；下次双击 App 即可恢复。",
                                 size: 11.5, color: NSColor.white.withAlphaComponent(0.55))
        quitHint.lineBreakMode = .byWordWrapping
        quitHint.maximumNumberOfLines = 2
        quitHint.translatesAutoresizingMaskIntoConstraints = false

        let quitBtn = NSButton(title: "退出桌面课表", target: self, action: #selector(quitApp))
        quitBtn.bezelStyle = .rounded
        quitBtn.controlSize = .small
        quitBtn.font = .systemFont(ofSize: 12)
        // 退出按钮：红色提示 —— 「退出」是不可逆操作，要一眼看得出来。
        //
        // **不能靠 `contentTintColor` 上色**：它只影响「有底色的按钮」的内容，
        // 不会给标题文字染色 —— 设成红色渲染出来还是灰的（实测亮像素
        // RGB=(186,186,188)，偏红 0%）。要染标题必须走 `attributedTitle`
        // 的 `foregroundColor`（实测偏红 100%）。
        quitBtn.attributedTitle = NSAttributedString(
            string: "退出桌面课表",
            attributes: [
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.85),
                .font: NSFont.systemFont(ofSize: 12),
            ])
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        quitButton = quitBtn

        // 按钮居中，不靠左。
        //
        // **不能靠 NSStackView 的 alignment 实现居中**：
        // · quitCard.content 是竖向栈，alignment = .leading —— 排进去的子视图一律贴左边；
        // · 而横向栈的 alignment 管的是**垂直**方向（跨轴），改它不会让按钮水平居中。
        // 所以这里用一个普通 NSView 当「整行容器」，把按钮钉在容器的水平中心。
        // 容器宽度必须显式等于内容宽度 —— NSStackView 不会自动把子视图拉宽
        // （不写这条约束，容器会塌成按钮的宽度，居中也就看不出来）。
        let quitRow = NSView()
        quitRow.translatesAutoresizingMaskIntoConstraints = false
        quitRow.addSubview(quitBtn)
        NSLayoutConstraint.activate([
            quitBtn.centerXAnchor.constraint(equalTo: quitRow.centerXAnchor),
            quitBtn.topAnchor.constraint(equalTo: quitRow.topAnchor),
            quitBtn.bottomAnchor.constraint(equalTo: quitRow.bottomAnchor),
        ])

        quitCard.addRow(quitHint)
        quitCard.addRow(quitRow)
        stack.addArrangedSubview(quitCard)
        quitCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 版本号（系统板块最下面）----
        //
        // 用户要求：「在课表设置的系统里面，最下面加上当前的版本号」。
        // 版本从 App bundle 的 Info.plist 读 —— 不要在代码里写死，
        // 否则每次发版都会忘（Makefile / Info.plist 才是唯一来源）。
        let versionLabel = makeLabel(Self.versionText, size: 10.5,
                                     color: NSColor.white.withAlphaComponent(0.34))
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(versionLabel)
        versionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 底部状态 ----
        statusLabel = makeLabel("", size: 11, color: NSColor.white.withAlphaComponent(0.42))
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(statusLabel)

        // 状态栏是**所有板块共用**的页脚，钉在 doc 底部。
        //
        // 四个板块各有各的栈，但页脚只有一条 —— 所以 doc 的高度不能由某一个栈决定，
        // 而是「**最高的那个板块栈** + 页脚」。NSStackView 的高度会随内容变，
        // 这里取各个栈高度的最大值：所有板块栈都钉在 doc.top（内容从顶部往下排），
        // doc 的高度用 `greaterThanOrEqualTo` 约束在最高栈之下。
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        // doc 的高度 = **当前显示的板块**的内容高度 + 上下边距 + 页脚。
        //
        // 以前取的是「所有板块里最高的那个」，结果短板块（例如「系统」）
        // 的文档里会拖着一大段空白 —— 滚轮能一直往下滚进空白里
        // （用户反馈「不用滚动的板块，滚轮往下能一直滚，得有个束缚」）。
        // 现在只跟当前板块绑定：内容多长，可滚范围就多长，
        // 装得下时完全没有可滚的余量，滚轮到底就是到底。
        //
        // ⚠️ 不能再给**所有**板块栈加「底边离页脚 ≥ 12pt」的约束：
        // 隐藏的高板块（课表 826pt）会通过这条约束把 doc 撑高，
        // doc 的等式约束又反过来把当前显示的矮板块**拉高**到 826pt。
        // 边距关系由下面的等式天然保证（stack 高 + 8 + 12 + 16 + 6 = doc 高），
        // 隐藏板块直接允许溢出 doc 即可（它是 isHidden，不参与显示）。
        bindDocumentHeight(to: sectionStacks[.appearance])

        // 卡片宽度撑满
        for card in [fadeCard, opCard, dataCard, previewCard] as [NSView] {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // 滚动条按内容高度自动显隐（内容装得下就藏起来）。
        observeDocumentSizeChanges()
        updateScrollBarVisibility()

        // 建完界面立刻把「提醒与启动」的状态同步一次：
        // 开关 / 下拉 / 状态行的初值必须来自磁盘 + 系统，不能用控件默认值。
        syncReminderControls()

        // 显示窗口（必须显式 order front，否则进程在跑但没有可见窗口）
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - 两级结构：板块首页 ↔ 分类设置页

    /// 为某个板块建一个内容栈（挂在文档视图里）。
    ///
    /// 每个板块一个独立的竖向栈 —— 栈里就是该板块原来的卡片，
    /// 卡片控件一个都没改，只是**换了摆放位置**。
    private func makeSectionStack(_ section: SettingsSection, in doc: NSView) -> NSStackView {
        // 同一个板块重复调用 → 复用已有的栈（不要建两个）。
        if let existing = sectionStacks[section] { return existing }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])
        sectionStacks[section] = stack
        // 分类页默认隐藏 —— 只有当前板块可见。
        stack.alphaValue = 0
        stack.isHidden = true
        return stack
    }

    /// 展开到某个板块（首页 → 分类页）。
    func expandTo(_ section: SettingsSection) {
        guard panelState != .section(section) else { return }
        panelState = .section(section)

        // 板块名
        sectionTitleLabel?.stringValue = section.pageTitle

        // 切内容：只显示目标板块的栈，其余隐藏（交叉淡入淡出）。
        for (sect, stack) in sectionStacks {
            let visible = (sect == section)
            stack.isHidden = !visible
            stack.alphaValue = visible ? 1 : 0
        }
        // 「当前可见板块的栈」—— 自检探针按这个数卡片。
        contentStack = sectionStacks[section]
        // 可滚动的范围跟着当前板块走 —— 短板块下面不再拖着一条空白。
        bindDocumentHeight(to: sectionStacks[section])

        // 日记板块每次进都重读一次文件（2026-11-10）：
        // 日记可能是**在日期覆盖层里写的**，设置面板里的列表是构建时建的，
        // 不重读的话用户会以为「设置里没有这条记录」。
        if section == .diary { refreshDiaryList() }

        // 收起态的首页隐藏，分类页头部显示。
        homeContainer?.isHidden = true
        homeContainer?.alphaValue = 0
        for v in sectionHeaderViews { v.isHidden = false; v.alphaValue = 1 }
        titleLabel?.isHidden = true
        // 滚动视图在收起态是藏着的 —— 展开时放出来。
        panelScrollView?.isHidden = false

        // 展开时内容必须是完全不透明的（返回动画可能刚把透明度淡到 0，
        // 用户如果在这时又点了板块，要能立刻恢复）。
        panelScrollView?.alphaValue = 1
        homeContainer?.alphaValue = 0
        titleLabel?.alphaValue = 0
        for v in sectionHeaderViews { v.alphaValue = 1 }

        // 展开动画期间**先关掉滚动条**：这时视口还是收起态的高度，
        // 拿它去算会把「其实装得下」的板块也算成要滚动 —— 滚动条会在
        // 动画末尾再闪一下才消失（用户反馈「出现一会儿，然后消失」）。
        // 等动画结束、视口定下来，resize 的收尾会按真实高度重算一次。
        (panelScrollView as? AutoHideScrollView)?.setNeedsScroller(false)

        // 展开态：窗口长高（高度夹在屏幕可见区内）。
        resize(to: expandedSize(on: panelScreen, for: section), animated: true)

        // 新页面从最上面开始看。
        scrollPanelToTop()

        // 内容高度变了 → 重算滚动条（装得下就不显示）。
        //
        // ⚠️ 要等**动画结束 + 布局跑完**再算 ——
        // 动画期间窗口尺寸还在变，滚动视图会在这期间把滚动条重新显示出来；
        // 提前算等于白算。
        let delay = Self.resizeAnimationDuration * AnimationSpeed.shared.factor
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.updateScrollBarVisibility()
        }
    }

    /// 返回首页（分类页 → 收起态）。
    ///
    /// 收缩时**内容要跟着毛玻璃一起收**。
    ///
    /// 以前这里先把内容瞬间换成首页小砖块，再只动画窗口尺寸 ——
    /// 中间那一大段是「一整块大玻璃里只有顶上一排小砖块」，
    /// 内容和玻璃各动各的（用户反馈「脱节」）。
    ///
    /// 现在的顺序：
    ///   1. 分类页内容保持原样，窗口带着它一起缩小（内容从底部被裁掉）；
    ///   2. 收缩到中段再把分类页内容淡出；
    ///   3. 窗口快缩成小长条时才淡入首页（标题 + 4 个板块），最后定格。
    @objc func backToHome() {
        guard panelState != .home else { return }
        panelState = .home

        let duration = Self.resizeAnimationDuration * AnimationSpeed.shared.factor

        // 首页 / 标题先藏起来 —— 等窗口快缩完再淡入。
        homeContainer?.isHidden = true
        homeContainer?.alphaValue = 0
        titleLabel?.isHidden = true
        titleLabel?.alphaValue = 0

        if duration > 0.01 {
            // 前 30% 保持内容完整（让人看到玻璃和内容是一起在收），
            // 30%–70% 把分类页内容淡出。
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.30) { [weak self] in
                guard let self, self.panelState == .home else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration * 0.40
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    for stack in self.sectionStacks.values where !stack.isHidden {
                        stack.animator().alphaValue = 0
                    }
                    for v in self.sectionHeaderViews where !v.isHidden {
                        v.animator().alphaValue = 0
                    }
                    self.panelScrollView?.animator().alphaValue = 0
                }
            }

            // 窗口缩到约 70% 大小时，再切到首页并淡入 ——
            // 这时玻璃已经很小，砖块不会孤零零地飘在一大块空玻璃顶部。
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.70) { [weak self] in
                guard let self, self.panelState == .home else { return }
                self.hideSectionContent()
                self.homeContainer?.isHidden = false
                self.homeContainer?.alphaValue = 0
                self.titleLabel?.isHidden = false
                self.titleLabel?.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration * 0.30
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.homeContainer?.animator().alphaValue = 1
                    self.titleLabel?.animator().alphaValue = 1
                }
            }
        }

        // 收起：窗口缩回小长条，内容跟着窗口一起被裁、一起淡出。
        resize(to: Self.collapsedSize, animated: true) { [weak self] in
            guard let self, self.panelState == .home else { return }
            self.finishCollapse()
        }
    }

    /// 把分类页的内容（卡片栈 / 头部 / 滚动视图）彻底藏起来。
    private func hideSectionContent() {
        for stack in sectionStacks.values {
            stack.isHidden = true
            stack.alphaValue = 0
        }
        for v in sectionHeaderViews {
            v.isHidden = true
            v.alphaValue = 0
        }
        panelScrollView?.isHidden = true
        panelScrollView?.alphaValue = 1
    }

    /// 收缩动画结束：分类页彻底收起，首页定稿。
    private func finishCollapse() {
        hideSectionContent()
        homeContainer?.isHidden = false
        homeContainer?.alphaValue = 1
        titleLabel?.isHidden = false
        titleLabel?.alphaValue = 1
    }

    /// 展开态的窗口尺寸 —— **高度按当前板块的内容算**，但不超过上限。
    ///
    /// 规则（用户定的）：
    ///   · 内容**少** → 窗口**变小**（「系统」板块只有一张「退出应用」卡片，
    ///     就收成刚好够用，而不是撑到 700）；
    ///   · 内容**多** → 最多到 `expandedSize`（580×700），
    ///     **超出的部分在页面内部滚动**，不把窗口撑得更高。
    ///
    /// 宽度**不变**（还是 580），只有高度跟着内容走。
    ///
    /// 另外高度不能超出**屏幕可见区** —— 窗口不能伸出屏幕。
    private func expandedSize(on screen: NSScreen?, for section: SettingsSection) -> NSSize {
        var size = Self.expandedSize
        // 先按内容算高度。
        size.height = min(contentHeight(for: section), Self.expandedSize.height)
        guard let vf = screen?.visibleFrame else { return size }
        // 上下各留一点余量，窗口不贴着屏幕边缘。
        let maxHeight = vf.height - 24
        size.height = min(size.height, maxHeight)
        // 宽度同理（超宽屏之外的窄屏场景）。
        size.width = min(size.width, vf.width - 24)
        return size
    }

    /// 某个板块的**内容高度**（卡片总高 + 上下留白）。
    ///
    /// 算的是「这个板块的卡片一共多高」——
    /// 卡片本身是 `SettingsCard`（里面一个竖向 `NSStackView`），
    /// 所以高度 = 各行高度之和 + 行间距 + 卡片上下内边距。
    ///
    /// 拿不到精确值时（控件还没布局完）退回一个保守的估计值。
    private func contentHeight(for section: SettingsSection) -> CGFloat {
        guard let stack = sectionStacks[section] else { return Self.expandedSize.height }
        // ⚠️ **先量之前必须先布局** ——
        // 卡片的高度是 Auto Layout 算出来的，没布局过时 frame 是 0（或上一次的旧值），
        // 量出来的就是错的。
        // 目标板块此刻可能还没显示（isHidden = true）→ 先显示出来、量完再藏回去。
        let wasHidden = stack.isHidden
        stack.isHidden = false
        stack.layoutSubtreeIfNeeded()
        if let doc = stack.superview { doc.layoutSubtreeIfNeeded() }
        defer { stack.isHidden = wasHidden }

        var total: CGFloat = 0
        for view in stack.arrangedSubviews {
            total += measuredHeight(of: view)
        }
        // 卡片之间的间距（stack.spacing = 14）。
        let count = stack.arrangedSubviews.count
        if count > 1 { total += CGFloat(count - 1) * 14 }
        // 加上顶部「返回 + 板块名」那一行的高度。
        total += Self.expandedHeaderHeight
        // 加上内容区上下留白（滚动视图上下边距 + 状态栏）。
        total += Self.contentPadding
        return total
    }

    /// 量一个栈（板块内容）的高度。
    ///
    /// 栈的高度 = 各张卡片的高 + 卡片之间的间距。
    private func stackHeight(of stack: NSStackView) -> CGFloat {
        var total: CGFloat = 0
        let cards = stack.arrangedSubviews
        for view in cards {
            total += measuredHeight(of: view)
        }
        if cards.count > 1 { total += CGFloat(cards.count - 1) * stack.spacing }
        return total
    }

    /// 量一个视图的高度（优先用它的实际 frame，量不到就按固有高度估）。
    private func measuredHeight(of view: NSView) -> CGFloat {
        // 卡片：高度已经布局出来了就直接用。
        if view.frame.height > 1 { return view.frame.height }
        // 退化路径：用固有高度 + 已知内边距估。
        let intrinsic = view.fittingSize.height
        if intrinsic > 1 { return intrinsic }
        // 再不行，按「卡片」估：标题 13 + 间距 10 + 内容 + 底部 15。
        if let card = view as? SettingsCard {
            var h: CGFloat = 13 + 10 + 15
            for row in card.content.arrangedSubviews {
                h += measuredHeight(of: row)
            }
            if card.content.arrangedSubviews.count > 1 {
                h += CGFloat(card.content.arrangedSubviews.count - 1) * 11
            }
            return h
        }
        return 0
    }

    /// 面板当前所在的屏幕。
    ///
    /// ⚠️ **不是「鼠标所在的屏幕」** —— 扩张动画期间鼠标可能已经移到另一块屏上，
    /// 那时按鼠标所在屏算就会把面板**瞬移到另一块屏**去。
    /// 面板该待在**自己原来那块屏**上（打开时按鼠标所在屏选好，之后不再变）。
    ///
    /// 窗口不在任何屏上时（比如刚建好还没摆位置）→ 退回主屏。
    private var panelScreen: NSScreen? {
        if let win = window {
            let f = win.frame
            // 窗口中心落在哪块屏上就算哪块屏。
            let mid = NSPoint(x: f.midX, y: f.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(mid) }) { return s }
        }
        return NSScreen.main
    }

    /// 把窗口改成某个尺寸，**以屏幕中心为锚点对称变化**。
    ///
    /// 动画全程保持窗口中心不动 —— 扩张时上下左右同时长，中心不飘。
    ///
    /// - Parameters:
    ///   - animated: true = 0.28s ease-out 平滑变化；false = 立刻变。
    ///   - completion: 动画（或立刻变化）结束后调用。被新的 resize 顶掉时不会调用。
    private func resize(to size: NSSize, animated: Bool, completion: (() -> Void)? = nil) {
        guard let win = window else { completion?(); return }
        // 新的 resize 顶掉旧的：旧动画的收尾（包括调用方的 completion）作废，
        // 否则连续点「板块 / 返回」时，旧动画结束会把窗口重新摆到旧尺寸的中心。
        resizeGeneration += 1
        let generation = resizeGeneration
        resizeTimer?.invalidate()
        resizeTimer = nil

        let current = win.frame
        // 以**当前中心**为锚点，算出新的 frame（对称扩张 / 收缩）。
        //
        // 中心优先沿用上一次动画的锚点（见 `resizeCenterAnchor`），
        // 只有窗口被用户拖走（偏差超过 2pt）才改用当前中心 ——
        // 既不会每切一次板块就漂 0.5pt，也不会把被拖到旁边的面板拽回屏幕中间。
        let currentCenter = NSPoint(x: current.midX, y: current.midY)
        let center: NSPoint
        if let anchor = resizeCenterAnchor,
           abs(anchor.x - currentCenter.x) < 2,
           abs(anchor.y - currentCenter.y) < 2 {
            center = anchor
        } else {
            center = currentCenter
        }
        resizeCenterAnchor = center
        var target = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height)

        // 不能超出屏幕可见区。
        if let vf = panelScreen?.visibleFrame {
            if target.height > vf.height { target.size.height = vf.height }
            if target.width > vf.width { target.size.width = vf.width }
            target.origin.x = min(max(target.origin.x, vf.minX), vf.maxX - target.width)
            target.origin.y = min(max(target.origin.y, vf.minY), vf.maxY - target.height)
        }

        let heightConstraint = rootHeightConstraint

        // 窗口 frame 和内容高度**在同一步里**改。
        //
        // ⚠️ 这是「红绿灯和毛玻璃脱节」的根因：
        // 之前对窗口用 `animator().setFrame` —— 那是**窗口服务器**在插值窗口框，
        // 而内容高度由 Auto Layout 的 root 高度约束决定。收缩时如果把约束
        // 一次性改成最终高度，内容（毛玻璃）会**立刻缩成小条、贴在窗口底边**，
        // 红绿灯（跟着窗口框走）却还在上面慢慢往下落 —— 看起来就像
        // 「下边框往上移 + 红绿灯往下移」两个动作硬拼在一起。
        //
        // 现在自己逐帧驱动：每一帧同时把窗口框和 root 高度改成同一个值，
        // 毛玻璃、内容、红绿灯永远是同一个尺寸、同一个边，收缩就是一个整体。
        func apply(_ frame: NSRect) {
            heightConstraint?.constant = frame.height
            heightConstraint?.priority = .required
            win.setFrame(frame, display: false)
            win.contentView?.layoutSubtreeIfNeeded()
        }

        let duration = Self.resizeAnimationDuration * AnimationSpeed.shared.factor
        guard animated, duration > 0.001 else {
            apply(target)
            win.displayIfNeeded()
            updateScrollBarVisibility()
            completion?()
            return
        }

        let startFrame = current
        let startTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, generation == self.resizeGeneration else {
                timer.invalidate()
                return
            }
            let t = min(1.0, (ProcessInfo.processInfo.systemUptime - startTime) / duration)
            // easeOut：起步快、收尾缓，和原来的手感一致。
            let e = 1 - pow(1 - t, 3)
            let frame = NSRect(
                x: startFrame.origin.x + (target.origin.x - startFrame.origin.x) * e,
                y: startFrame.origin.y + (target.origin.y - startFrame.origin.y) * e,
                width: startFrame.width + (target.width - startFrame.width) * e,
                height: startFrame.height + (target.height - startFrame.height) * e)
            apply(frame)
            win.displayIfNeeded()

            guard t >= 1 else { return }
            timer.invalidate()
            self.resizeTimer = nil

            // 定格到目标尺寸 —— **不要**再摆回屏幕中心：
            // 窗口被用户拖到旁边后，点板块应该就地在原位置展开；
            // 每帧的目标 frame 本来就是以**当前中心**算的，收尾直接定格
            // 即可（只有超出屏幕可见区时 target 会被夹回来一点）。
            apply(target)

            // 视口高度变了 → 重算滚动条（内容装得下就不显示）。
            self.updateScrollBarVisibility()

            completion?()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }


    // MARK: - 日期覆盖层（接入系统日历 / 提醒事项）

    /// 日期覆盖层控制器（由 AppDelegate 注入）。
    ///
    /// 设置面板不直接碰 EventKit —— 取数、写回都在控制器里，
    /// 设置面板只负责「开关 + 选清单 + 显示状态」。
    var dayPanelController: DayPanelController? {
        didSet {
            // 控制器可能在面板建好之后才注入（AppDelegate 的顺序）——
            // 注入时立刻接上「已完成列表」的状态回调。
            bindCompletedRemindersService()
        }
    }

    // ---------- 已完成的提醒事项（日期覆盖层卡片第三行） ----------

    /// 已完成行（`buildWindow` 建完卡片后才有）。
    private var completedRowView: CompletedRemindersRow?
    /// 已经绑过 `onChange` 的服务（避免重复覆盖）。
    private weak var boundCompletedService: CompletedRemindersService?
    /// 用户是不是把这一行展开了（**展开状态归主控**，行本身只画）。
    private var completedExpanded = false
    /// 写操作结果（成功 / 失败原因）—— 优先于服务自己的状态文案显示。
    private var completedActionNotice: String?
    private var completedActionNoticeIsError = false
    /// 搜索防抖。
    private var completedSearchWork: DispatchWorkItem?
    /// 自检 / 截图用：替掉真实确认弹窗（`nil` = 正常弹窗）。
    var completedDeleteConfirmationForTest: ((CompletedReminder) -> Bool)?
    var completedDeleteAllConfirmationForTest: ((Int) -> Bool)?

    /// 开关切换：接入系统日历 / 提醒事项。
    @objc private func dayPanelEnabledToggled(_ sender: Any?) {
        let enabled = dayPanelSettingsCard?.isEnabled ?? false
        var current = appSettings
        current.dayPanel.enabled = enabled
        appSettings = current
        do {
            try settingsStore.save(current)
        } catch {
            NSLog("[DesktopTimetable] 保存日期覆盖层设置失败：%@", error.localizedDescription)
        }
        dayPanelController?.updateSettings(current.dayPanel)
        if enabled {
            // 第一次开 → 请求系统授权。
            // 没授权时覆盖层照样能用（只显示当天课程），所以失败不用报错。
            dayPanelController?.requestAccess()
        }
        refreshDayPanelRows()
    }

    /// 弹出「选择提醒事项清单」。
    private func presentDayPanelListPicker() {
        guard let controller = dayPanelController else { return }
        let lists = controller.reminderLists
        guard !lists.isEmpty else {
            AlertDialogController.show(.init(
                severity: .info,
                title: "还没有可用的提醒事项清单",
                message: "系统提醒事项里一个清单都没有。先在「提醒事项」App 里建一个，或在下面新建一个「桌面课表」清单。",
                confirmTitle: "好",
                showsCancel: false))
            return
        }
        let outcome = DayPanelListPicker.show(
            lists: lists.map { $0.title },
            current: appSettings.dayPanel.listTitle)
        switch outcome {
        case .selected(let title):
            // 按**标题**回查标识（清单重名时取第一个可写的）。
            guard let info = lists.first(where: { $0.title == title }) else { return }
            dayPanelController?.selectList(info.identifier, title: info.title)
            var current = appSettings
            current.dayPanel.listIdentifier = info.identifier
            current.dayPanel.listTitle = info.title
            appSettings = current
            try? settingsStore.save(current)
            refreshDayPanelRows()
        case .create:
            // 清单选择器只负责「用户想新建」这个信号，**名字**由这里弹输入框要
            // —— 复用现有的 `TimetableNameDialog`（工程里已有，不用重造）。
            presentCreateDayPanelListDialog()
        case .cancelled:
            break
        }
    }

    /// 弹输入框问「新建清单叫什么名字」。
    private func presentCreateDayPanelListDialog() {
        let result = TimetableNameDialog.run(
            title: "新建提醒事项清单",
            message: "桌面课表会把待办写进这个清单。名字可以随时在「提醒事项」App 里改。",
            name: DayPanelSettings.defaultListTitle,
            subtitle: "",
            confirmTitle: "创建",
            showsSubtitle: false)
        // 取消返回 nil。
        guard let result else { return }
        createDayPanelList(titled: result.name)
    }

    /// 新建一个提醒事项清单。
    private func createDayPanelList(titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let controller = dayPanelController else { return }
        guard let created = controller.createList(titled: trimmed) else {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "新建清单失败",
                message: "系统没允许新建提醒事项清单。检查一下「系统设置 → 隐私与安全性 → 提醒事项」里桌面课表的权限。",
                confirmTitle: "好",
                showsCancel: false))
            return
        }
        controller.selectList(created.identifier, title: created.title)
        var current = appSettings
        current.dayPanel.listIdentifier = created.identifier
        current.dayPanel.listTitle = created.title
        appSettings = current
        try? settingsStore.save(current)
        refreshDayPanelRows()
    }

    /// 打开系统设置里的日历 / 提醒事项权限页。
    private func openDayPanelSystemSettings() {
        dayPanelController?.openSystemSettings()
    }

    /// 天气开关切换。
    ///
    /// 开 → 请求一次定位授权（系统弹窗）。
    /// 关 → 立刻不再显示天气（不用等下次打开覆盖层）。
    private func dayPanelWeatherToggled(_ enabled: Bool) {
        var current = appSettings
        current.dayPanel.weatherEnabled = enabled
        appSettings = current
        do {
            try settingsStore.save(current)
        } catch {
            NSLog("[DesktopTimetable] 保存天气设置失败：%@", error.localizedDescription)
        }
        dayPanelController?.updateSettings(current.dayPanel)
        if enabled {
            dayPanelController?.requestLocationAccess()
        }
        refreshDayPanelRows()
    }

    /// 打开系统设置里的**定位**权限页。
    ///
    /// 定位是**第三个**隐私面板（`Privacy_Location`）——
    /// 和日历 / 提醒事项不是同一个，开错等于没开。
    private func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Location")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// 刷新日期覆盖层卡片的状态显示。
    ///
    /// 面板每次 `show()` 都要调 —— 授权状态是**异步**的，
    /// 打开时可能还没读到。
    func refreshDayPanelRows() {
        guard let card = dayPanelSettingsCard else { return }
        let state: DayPanelAuthState
        if !appSettings.dayPanel.enabled {
            state = .disabled
        } else if let controller = dayPanelController {
            state = (controller.reminderAuthorized || controller.eventAuthorized)
                ? .authorized : .notAuthorized
        } else {
            state = .unknown
        }
        card.update(enabled: appSettings.dayPanel.enabled,
                   authState: state,
                   listName: appSettings.dayPanel.listTitle,
                   weatherEnabled: appSettings.dayPanel.weatherEnabled,
                   locationAuthStatus: dayPanelController?.locationAuthorizationStatus,
                   completedAccess: completedAccess())
        // 入口状态变了：原来展开着但现在已经不可用 → 收起并作废在途读取。
        if completedExpanded && completedAccess() != .ready {
            completedExpanded = false
            dayPanelController?.completedReminders.reset()
        }
        refreshCompletedRow()
    }

    /// 已完成行当前可不可用。
    private func completedAccess() -> CompletedRemindersRow.Access {
        guard appSettings.dayPanel.enabled else { return .disabled }
        // 控制器还没注入 = 授权状态未知 → 先按不可用处理（不预判）。
        guard let controller = dayPanelController else { return .disabled }
        return controller.reminderAuthorized ? .ready : .needsAuthorization
    }

    /// 把控制器里的服务接上（只接一次，避免覆盖别的回调）。
    private func bindCompletedRemindersService() {
        let service = dayPanelController?.completedReminders
        guard service !== boundCompletedService else {
            refreshCompletedRow()
            return
        }
        boundCompletedService = service
        service?.onChange = { [weak self] in
            self?.refreshCompletedRow()
        }
        refreshCompletedRow()
    }

    /// 从服务状态 + 主控状态生成行要的 ViewModel 并刷新。
    private func refreshCompletedRow() {
        guard let row = completedRowView else { return }
        var vm = CompletedRemindersRow.ViewModel()
        vm.access = completedAccess()
        vm.isExpanded = completedExpanded && vm.access == .ready
        guard let service = dayPanelController?.completedReminders else {
            vm.notice = completedActionNotice
            vm.noticeIsError = completedActionNoticeIsError
            row.update(vm)
            return
        }
        switch service.state {
        case .idle:
            break
        case .loading:
            vm.isLoading = true
        case .loaded:
            vm.isLoaded = true
        case .failed(let message):
            vm.isLoaded = true
            vm.loadError = message
        }
        vm.items = service.pageItems
        vm.hasMore = service.hasMore
        vm.totalCompleted = service.totalCompleted
        vm.matchingCount = service.matchingCount
        vm.lists = service.lists.map {
            CompletedRemindersRow.ListOption(identifier: $0.identifier, title: $0.title)
        }
        vm.selectedListIdentifier = service.listFilterIdentifier
        vm.searchText = service.searchText
        vm.busy = service.busy
        if let progress = service.progress {
            vm.progressText = "正在删除 \(progress.done)/\(progress.total)…"
        }
        vm.notice = completedActionNotice ?? service.statusMessage
        vm.noticeIsError = completedActionNoticeIsError
        row.update(vm)
    }

    /// 用户展开 / 收起这一行。
    private func setCompletedExpanded(_ expanded: Bool) {
        let wantsExpanded = expanded && completedAccess() == .ready
        guard let service = dayPanelController?.completedReminders else { return }
        completedActionNotice = nil
        completedActionNoticeIsError = false
        if wantsExpanded {
            completedExpanded = true
            // 收起时不能残留上一次的搜索 / 筛选：重新展开就是「所有清单」。
            service.load()
        } else {
            completedExpanded = false
            // 收起 = 取消尚未完成的读取（迟到的回包由服务令牌丢弃）。
            completedSearchWork?.cancel()
            service.reset()
        }
        refreshCompletedRow()
    }

    /// 失败 / 手动重试。
    private func reloadCompletedReminders() {
        guard let service = dayPanelController?.completedReminders else { return }
        completedActionNotice = nil
        completedActionNoticeIsError = false
        service.retry()
        refreshCompletedRow()
    }

    /// 搜索防抖（每敲一个字都会来一次，不能每次都过滤 + 重绘 200 行）。
    private func scheduleCompletedSearch(_ text: String) {
        completedSearchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let service = self.dayPanelController?.completedReminders else {
                return
            }
            self.completedActionNotice = nil
            self.completedActionNoticeIsError = false
            service.setSearchText(text)
            self.refreshCompletedRow()
        }
        completedSearchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func applyCompletedListFilter(_ identifier: String?) {
        guard let service = dayPanelController?.completedReminders else { return }
        completedActionNotice = nil
        completedActionNoticeIsError = false
        service.setListFilter(identifier)
        refreshCompletedRow()
    }

    private func loadMoreCompletedReminders() {
        dayPanelController?.completedReminders.loadMore()
        refreshCompletedRow()
    }

    /// 恢复一条。
    private func restoreCompletedReminder(_ item: CompletedReminder) {
        guard let controller = dayPanelController else { return }
        completedActionNotice = nil
        completedActionNoticeIsError = false
        controller.restoreCompletedReminder(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.completedActionNotice = "已恢复「\(item.title)」"
                self.completedActionNoticeIsError = false
            case .failure(let error):
                self.completedActionNotice = error.localizedDescription
                self.completedActionNoticeIsError = true
            }
            self.refreshCompletedRow()
        }
    }

    /// 删除一条（先轻量确认）。
    private func deleteCompletedReminder(_ item: CompletedReminder) {
        guard let controller = dayPanelController else { return }
        let confirmed = completedDeleteConfirmationForTest?(item)
            ?? CompletedReminderDialogs.confirmDelete(item)
        guard confirmed else { return }
        completedActionNotice = nil
        completedActionNoticeIsError = false
        controller.deleteCompletedReminder(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.completedActionNotice = "已删除「\(item.title)」"
                self.completedActionNoticeIsError = false
            case .failure(let error):
                self.completedActionNotice = error.localizedDescription
                self.completedActionNoticeIsError = true
            }
            self.refreshCompletedRow()
        }
    }

    /// 「全部删除…」：**先重新统计**数量，再弹确认（避免拿旧数量误导）。
    private func presentDeleteAllCompleted() {
        guard let controller = dayPanelController else { return }
        let service = controller.completedReminders
        completedActionNotice = nil
        completedActionNoticeIsError = false
        service.countCompleted { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.completedActionNotice = error.localizedDescription
                self.completedActionNoticeIsError = true
                self.refreshCompletedRow()
            case .success(let count):
                guard count > 0 else {
                    self.completedActionNotice = "没有已完成的提醒事项"
                    self.completedActionNoticeIsError = false
                    self.refreshCompletedRow()
                    return
                }
                let confirmed = self.completedDeleteAllConfirmationForTest?(count)
                    ?? CompletedReminderDialogs.confirmDeleteAll(count: count)
                guard confirmed else { return }
                controller.deleteAllCompletedReminders { [weak self] result in
                    guard let self else { return }
                    self.completedActionNotice = result.summaryText
                    self.completedActionNoticeIsError = result.failed > 0
                    self.refreshCompletedRow()
                }
            }
        }
    }

    // MARK: - 自检 / 截图

    /// 自检用：当前窗口是不是**居中**在**课表锚点**上。
    ///
    /// ⚠️ 判定基准从「屏幕可见区中心」改成了「**课表窗口当前中心**」——
    /// 需求要求所有后续窗口以课表位置为锚点，而不是屏幕正中。
    /// 课表被拖到屏幕左下角时，面板就该跟着过去。
    ///
    /// 判定：窗口中心与锚点的偏差在 2pt 以内。
    var isCenteredOnScreen: Bool {
        guard let win = window else { return false }
        let anchor = WindowAnchor.provider()
        let f = win.frame
        return abs(f.midX - anchor.x) <= 2 && abs(f.midY - anchor.y) <= 2
    }

    /// 自检用：窗口是不是**完整落在屏幕可见区里**（没被夹出去）。
    var isFullyVisible: Bool {
        guard let win = window, let vf = panelScreen?.visibleFrame else { return false }
        let f = win.frame
        return f.minX >= vf.minX - 0.5 && f.maxX <= vf.maxX + 0.5
            && f.minY >= vf.minY - 0.5 && f.maxY <= vf.maxY + 0.5
    }

    /// 自检用：窗口尺寸（收起态 / 展开态）。
    var currentWindowSize: NSSize { window?.frame.size ?? .zero }

    /// 自检用：当前状态是不是收起态（板块首页）。
    var isShowingHome: Bool { panelState == .home }

    /// 自检用：当前状态是不是某个板块的设置页。
    var currentSection: SettingsSection? {
        if case .section(let s) = panelState { return s }
        return nil
    }

    /// 自检用：首页视图本身（发真实鼠标事件用）。
    var homeScreenForTest: SettingsHomeScreen? { homeScreen }

    /// 自检用：首页的板块按钮（名字 + 图标是不是纯色）。
    var homeSectionTitles: [String] { homeScreen?.sectionTitles ?? [] }

    /// 自检用：首页的图标是不是全都是纯色（template）。
    var homeIconsAreMonochrome: Bool { homeScreen?.allIconsAreMonochrome ?? false }

    /// 自检用：「返回」按钮和板块名是不是在**同一条水平线**上。
    ///
    /// 用户要求：「返回」和板块名（外观 / 课表…）放在同一个水平线上。
    var backButtonAlignedWithTitle: Bool {
        guard let back = backButton, let title = sectionTitleLabel else { return false }
        guard back.superview === title.superview else { return false }
        return abs(back.frame.midY - title.frame.midY) < 2
    }

    /// 自检用：「返回」按钮是不是在**红绿灯下方**（没被裁到窗口外）。
    var backButtonBelowTrafficLights: Bool {
        guard let back = backButton else { return false }
        let f = back.frame
        let root = back.superview
        guard let root else { return false }
        // 在 root 坐标系里，按钮的上边缘要离 root 顶边有一段距离
        // （红绿灯就占着最上面那一条）。
        let topGap = (root.bounds.height - f.maxY)
        return topGap > 20 && f.minY >= 0
    }

    /// 自检用：返回按钮本身（发真实鼠标事件用）。
    var backButtonForTest: HeaderBackButton? { backButton }

    /// 自检用：当前板块的内容是不是**一屏显示得下**（显示得下就不该有滚动条）。
    var contentFitsViewport: Bool {
        guard let scroll = panelScrollView else { return true }
        let visibleStack = sectionStacks.values.first { !$0.isHidden }
        let contentHeight = visibleStack.map { stackHeight(of: $0) } ?? 0
        return contentHeight <= scroll.contentView.bounds.height + 1
    }

    /// 自检用：滚动条现在是不是**藏着的**。
    var scrollBarHidden: Bool {
        panelScrollView?.verticalScroller?.isHidden ?? true
    }

    /// 自检用：滚动文档当前的高度（决定最多还能往下滚多远）。
    var scrollDocumentHeight: CGFloat {
        panelScrollView?.documentView?.frame.height ?? 0
    }

    /// 自检用：当前可见板块的内容高度（不含文档上下边距 / 页脚）。
    var visibleSectionContentHeight: CGFloat {
        let visibleStack = sectionStacks.values.first { !$0.isHidden }
        return visibleStack.map { stackHeight(of: $0) } ?? 0
    }

    /// 自检用：各板块栈的显隐与实际高度（排查「文档高度跟错板块」用）。
    var debugSectionStacks: String {
        sectionStacks
            .map { "\($0.key.rawValue):hidden=\($0.value.isHidden),h=\(Int($0.value.frame.height))" }
            .joined(separator: " ")
    }

    /// 自检用：每块板块砖的图标 / 文字是不是**完整落在砖内**。
    ///
    /// 点不中是最容易犯也最难发现的毛病 ——
    /// 视觉上按钮很大，但实际只有中间一小块能点。
    var homeTilesFullyClickable: Bool { homeScreen?.allTilesAreFullyClickable() ?? false }

    /// 自检用：某个板块的页面上有没有对应的卡片（按卡片标题找）。
    ///
    /// 板块内容映射的断言就是靠它 ——
    /// 「外观」里必须有「渐变动画」，「提醒」里必须有「提醒与启动」，等等。
    func sectionHasCard(_ section: SettingsSection, titled title: String) -> Bool {
        guard let stack = sectionStacks[section] else { return false }
        for v in stack.arrangedSubviews {
            if let card = v as? SettingsCard, card.titleLabel.stringValue == title { return true }
        }
        return false
    }

    /// 自检用：某个板块页面上所有卡片的标题。
    func sectionCardTitles(_ section: SettingsSection) -> [String] {
        guard let stack = sectionStacks[section] else { return [] }
        return stack.arrangedSubviews.compactMap { ($0 as? SettingsCard)?.titleLabel.stringValue }
    }

    /// 自检用：按**板块顺序**摊平后的全部卡片。
    ///
    /// 两级结构之后卡片分在 4 个板块栈里，但自检探针（和原来的语义）要的是
    /// 「面板里的第几张卡片」—— 这里按 外观 → 课表 → 提醒 → 系统 的顺序摊平，
    /// 下标和改造前那条长列表里的下标一致。
    func allCardsInSectionOrder() -> [SettingsCard] {
        var cards: [SettingsCard] = []
        for section in SettingsSection.allCases {
            guard let stack = sectionStacks[section] else { continue }
            for v in stack.arrangedSubviews {
                if let c = v as? SettingsCard { cards.append(c) }
            }
        }
        return cards
    }

    /// 自检用：所有板块的卡片总数（必须和改造前的卡片数一致 —— 不能弄丢卡片）。
    var totalCardCount: Int {
        sectionStacks.values.reduce(0) { $0 + $1.arrangedSubviews.filter { $0 is SettingsCard }.count }
    }

    /// 自检 / 截图用：直接设置内容区高度（不走动画）。
    ///
    /// 「把窗口停在中间尺寸」时用 ——
    /// 只改窗口 frame 的话，root 的高度约束还会把内容拉回旧尺寸。
    func setPanelContentHeight(_ height: CGFloat) {
        rootHeightConstraint?.constant = height
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - 滚动条：内容装得下就不显示

    /// 滚动条要不要显示 —— **内容装得下就不显示**。
    ///
    /// 用户要求：「一个页面可以显示完，右边就不用加拖杆了」。
    ///
    /// macOS 的滚动条默认是 overlay 样式，浮在内容上；系统会让它在滚动时
    /// 淡入、停下淡出，但**刚打开时常常是常驻的**（尤其窗口刚变过高）。
    /// 这里自己判断：内容高度 <= 视口高度 → 彻底藏起来。
    private func updateScrollBarVisibility() {
        guard let scroll = panelScrollView else { return }
        // 用子类统一处理 —— 直接改 `verticalScroller.isHidden` 会被
        // NSScrollView 自己在布局时改回去（它认为「有滚动条就该显示」）。
        (scroll as? AutoHideScrollView)?.updateScrollerVisibility()
        guard let doc = scroll.documentView else { return }
        // 内容高度取**当前可见板块的**那个栈 ——
        // `doc` 是四个板块栈共用的文档视图，它的高度是所有栈里最高的那个，
        // 用它判断的话，「系统」板块明明装得下，也会被算成「要滚动」。
        let visibleStack = sectionStacks.values.first { !$0.isHidden }
        let contentHeight = visibleStack.map { stackHeight(of: $0) } ?? doc.frame.height
        let viewportHeight = scroll.contentView.bounds.height
        // 内容比视口高 → 需要滚动条；否则藏掉。
        let needsScroll = contentHeight > viewportHeight + 1
        (scroll as? AutoHideScrollView)?.setNeedsScroller(needsScroll)
    }

    /// 把滚动文档的高度绑定到**当前板块**的内容高度上。
    ///
    /// 文档高度决定「最多能滚多远」：绑到当前板块，短板块就没有多余的
    /// 空白可滚（滚轮到底即止），长板块刚好能滚到内容末尾。
    private func bindDocumentHeight(to stack: NSStackView?) {
        guard let stack, let doc = stack.superview else { return }
        docHeightConstraint?.isActive = false
        let c = doc.heightAnchor.constraint(equalTo: stack.heightAnchor,
                                            constant: 8 + 12 + 16 + 6)
        c.isActive = true
        docHeightConstraint = c
    }

    /// 监听文档视图尺寸变化（内容高度变了就重算滚动条要不要显示）。
    ///
    /// 板块切换、卡片高度变化、窗口缩放都会改文档高度 ——
    /// 这些都要重算，否则会出现「内容装得下却还留着滚动条」。
    private func observeDocumentSizeChanges() {
        guard let doc = panelScrollView?.documentView else { return }
        doc.postsBoundsChangedNotifications = true
        // NSView.boundsDidChangeNotification 是**类**属性，
        // Swift 里要用 NotificationCenter 的名字常量。
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: doc,
            queue: .main) { [weak self] _ in
                self?.updateScrollBarVisibility()
            }
    }

    /// 自检用：把当前窗口内容渲染成 PNG（截图用）。
    ///
    /// 用 `cacheDisplay(in:to:)` —— 它渲染的是**真实的视图层级**，
    /// 所以毛玻璃、图标、卡片全都和屏幕上看到的一致。
    func renderCurrentWindow(to path: String) -> Bool {
        guard let win = window, let content = win.contentView else { return false }
        win.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        content.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data)
    }

    // 面板关掉后不退出 App —— 桌面课表还在跑。
    func windowWillClose(_ notification: Notification) {
        testAnyCloseCount += 1
        panelClosed = true
        // 作废在途的激活重试 —— 否则重试会把刚关掉的面板**重新弹出来**。
        activationToken += 1
        onPanelClosed?()
    }

    /// 「退出桌面课表」按钮（调试用：dumpLayout 会量它的位置）。
    private var quitButton: NSButton?

    /// 自动化自检用：「提醒与启动」卡片的关键控件状态。
    ///
    /// 为什么不直接暴露控件：面板的控件是 private 的，自检只需要看**状态**，
    /// 给一个只读探针比把控件公开干净。
    struct ReminderCardProbe {
        var cardCount: Int = 0
        var hasReminderCard = false
        var reminderOn = false
        var leadEnabled = false
        var leadSelection = ""
        /// 下拉框的全部条目（自检用：最后一项必须是「自定义…」）。
        var leadItemTitles: [String] = []
        /// 下拉框当前选中的下标（自检用）。
        var leadSelectedIndex = -1
        /// 下拉框的实际宽度（自检用：标题太长会被截成「提前 12 分…」）。
        var leadPopupWidth: CGFloat = 0
        /// 下拉框右边缘在卡片坐标系里的位置（自检用：不能溢出卡片）。
        var leadPopupMaxX: CGFloat = 0
        /// 卡片内容区的宽度（自检用）。
        var cardContentWidth: CGFloat = 0
        var loginSwitchEnabled = false
        var loginStateText = ""
        var notificationText = ""
        var testButtonEnabled = false
        /// 「打开通知设置」按钮还在不在、还能不能点。
        var openNotifyButtonPresent = false
        var openNotifyButtonEnabled = false
        var cardHeight: CGFloat = 0
        /// 「提醒与启动」卡片在内容栈里的位置（0 起），用于确认它排在退出卡片之上。
        var cardIndex = -1
    }

    /// 自检用：模拟用户在下拉框里选了第 index 项（走真实的 action 路径）。
    ///
    /// 不能只 `selectItem` —— 程序化选中**不会**触发 action（AppKit 的行为，
    /// 探针验过），所以这里选中之后显式把 action 发出去，跟用户点菜单项
    /// 走的是同一条路。
    func testSelectLeadItem(at index: Int) {
        guard leadPopup != nil, index >= 0, index < leadPopup.numberOfItems else { return }
        leadPopup.selectItem(at: index)
        guard let action = leadPopup.action, let target = leadPopup.target else { return }
        NSApp.sendAction(action, to: target, from: leadPopup)
    }

    /// 读一次「提醒与启动」卡片的控件状态（只读，不触发任何系统副作用）。
    /// 自检用：「日期覆盖层」卡片的状态（2026-11 加了天气行）。
    struct DayPanelCardProbe {
        var hasCard = false
        /// 「显示天气」开关当前是开是关。
        var weatherOn = false
        /// 天气行的状态说明。
        var weatherStatus = ""
        /// 「去授权」按钮现在显示着吗。
        var showsAuthorizeButton = false
        /// 卡片高度（自检用来确认天气行确实占了地方）。
        var cardHeight: Double = 0
    }

    /// 自检用：读「日期覆盖层」卡片的状态。
    func probeDayPanelCard() -> DayPanelCardProbe {
        var probe = DayPanelCardProbe()
        guard let card = dayPanelSettingsCard else { return probe }
        probe.hasCard = true
        probe.weatherOn = card.isWeatherEnabled
        probe.weatherStatus = card.displayedWeatherStatus
        probe.showsAuthorizeButton = card.showsWeatherAuthorizeButton
        probe.cardHeight = card.frame.height
        return probe
    }

    // ---------- 已完成提醒事项：自检探针 / 驱动 ----------

    /// 自检用：已完成行的状态快照。
    struct CompletedRemindersProbe {
        var hasRow = false
        var access = "disabled"
        var expanded = false
        var subtitleText = ""
        var isLoading = false
        var stateText = ""
        var noticeText = ""
        var renderedRows = 0
        var items: [CompletedRemindersRow.ItemProbe] = []
        var totalCompleted = 0
        var matchingCount = 0
        var hasMore = false
        var deleteAllVisible = false
        var deleteAllEnabled = false
        var loadMoreVisible = false
        var listScrollable = false
        var searchText = ""
        var serviceState = "idle"
    }

    func probeCompletedReminders() -> CompletedRemindersProbe {
        var probe = CompletedRemindersProbe()
        guard let row = completedRowView else { return probe }
        probe.hasRow = true
        switch row.testAccess {
        case .disabled: probe.access = "disabled"
        case .needsAuthorization: probe.access = "needsAuthorization"
        case .ready: probe.access = "ready"
        }
        probe.expanded = row.testIsExpanded
        probe.subtitleText = row.testSubtitleText
        probe.isLoading = row.testIsLoading
        probe.stateText = row.testStateText
        probe.noticeText = row.testNoticeText
        probe.renderedRows = row.testRenderedCount
        probe.items = row.testItemProbes
        probe.deleteAllVisible = row.testDeleteAllVisible
        probe.deleteAllEnabled = row.testDeleteAllEnabled
        probe.loadMoreVisible = row.testLoadMoreVisible
        probe.listScrollable = row.testListScrollable
        probe.searchText = row.testSearchText
        if let service = dayPanelController?.completedReminders {
            probe.totalCompleted = service.totalCompleted
            probe.matchingCount = service.matchingCount
            probe.hasMore = service.hasMore
            switch service.state {
            case .idle: probe.serviceState = "idle"
            case .loading: probe.serviceState = "loading"
            case .loaded: probe.serviceState = "loaded"
            case .failed(let message): probe.serviceState = "failed:\(message)"
            }
        }
        return probe
    }

    /// 自检用：模拟点「已完成的提醒事项」这一行。
    func testToggleCompletedRow() {
        setCompletedExpanded(!completedExpanded)
    }

    /// 自检用：像用户拨开关一样改「日历与提醒事项接入」并写盘。
    func testSetDayPanelEnabled(_ enabled: Bool) {
        var current = appSettings
        current.dayPanel.enabled = enabled
        appSettings = current
        try? settingsStore.save(current)
        dayPanelController?.updateSettings(current.dayPanel)
        refreshDayPanelRows()
    }

    /// 自检用：直接设置搜索词（跳过防抖，但走同一条 service 路径）。
    func testSetCompletedSearch(_ text: String) {
        completedSearchWork?.cancel()
        completedActionNotice = nil
        completedActionNoticeIsError = false
        dayPanelController?.completedReminders.setSearchText(text)
        refreshCompletedRow()
    }

    /// 自检用：选清单筛选（`nil` = 所有清单）。
    func testSelectCompletedList(_ identifier: String?) {
        applyCompletedListFilter(identifier)
    }

    func testLoadMoreCompleted() {
        loadMoreCompletedReminders()
    }

    func testRestoreCompleted(_ item: CompletedReminder) {
        restoreCompletedReminder(item)
    }

    func testDeleteCompleted(_ item: CompletedReminder) {
        deleteCompletedReminder(item)
    }

    func testDeleteAllCompleted() {
        presentDeleteAllCompleted()
    }

    func testReloadCompleted() {
        reloadCompletedReminders()
    }

    /// 自检 / 出图用：打印「日期覆盖层」卡片的视图 frame（排查高度 / 裁切）。
    func debugDayPanelCardLayout() -> String {
        guard let root = dayPanelSettingsCard else { return "dayPanelSettingsCard=nil" }
        var lines: [String] = []
        func walk(_ view: NSView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let intrinsic = view.intrinsicContentSize
            lines.append("\(pad)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) intrinsic=\(intrinsic)")
            if depth < 6 {
                for sub in view.subviews { walk(sub, depth + 1) }
            }
        }
        walk(root, 0)
        return lines.joined(separator: "\n")
    }

    /// 自检 / 出图用：把设置面板滚到「日期覆盖层」卡片顶部。
    func scrollPanelToDayPanelCardForTest() {
        guard let scroll = panelScrollView,
              let doc = scroll.documentView,
              let card = dayPanelSettingsCard else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        card.superview?.layoutSubtreeIfNeeded()
        let frame = card.convert(card.bounds, to: doc)
        let y = max(0, frame.minY - 8)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 自检 / 出图用：把设置面板滚到「已完成的提醒事项」这一行。
    func scrollPanelToCompletedRowForTest() {
        guard let scroll = panelScrollView,
              let doc = scroll.documentView,
              let row = completedRowView else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        row.superview?.layoutSubtreeIfNeeded()
        let frame = row.convert(row.bounds, to: doc)
        let y = max(0, frame.minY - 8)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 自检：「课表数据」卡片那两个按钮长什么样。
    ///
    /// 2026-11-09 用户要求：两个按钮前面各加一个符号、「导入课表」去掉省略号、
    /// 两个圆角框**一样长**。这里只读界面状态，不触发任何动作。
    struct DataCardButtonProbe {
        var importTitle = ""
        var revealTitle = ""
        var importHasIcon = false
        var revealHasIcon = false
        var importWidth: CGFloat = 0
        var revealWidth: CGFloat = 0
        var importEnabled = false
    }

    func probeDataCardButtons() -> DataCardButtonProbe {
        var probe = DataCardButtonProbe()
        var buttons: [NSButton] = []
        func walk(_ v: NSView) {
            if let b = v as? NSButton { buttons.append(b) }
            for sub in v.subviews { walk(sub) }
        }
        if let content = window?.contentView { walk(content) }
        for b in buttons {
            switch b.title {
            case "导入课表":
                probe.importTitle = b.title
                probe.importHasIcon = b.image != nil
                probe.importWidth = b.frame.width
                probe.importEnabled = b.isEnabled
            case "在访达中显示":
                probe.revealTitle = b.title
                probe.revealHasIcon = b.image != nil
                probe.revealWidth = b.frame.width
            default:
                break
            }
        }
        return probe
    }

    func probeReminderCard() -> ReminderCardProbe {
        var probe = ReminderCardProbe()
        // 两级结构之后卡片分散在 4 个板块栈里 —— 这里按**板块顺序**摊平成一张列表，
        // 语义和改造前的「一条长列表」完全一致：
        // 外观 → 课表 → 提醒 → 系统，卡片的下标也就是原来的下标。
        let cards = allCardsInSectionOrder()
        probe.cardCount = cards.count
        guard let card = cards.first(where: { $0.titleLabel.stringValue == "提醒与启动" }) else { return probe }
        probe.hasReminderCard = true
        probe.cardHeight = card.frame.height
        probe.cardIndex = cards.firstIndex(where: { $0 === card }) ?? -1
        probe.reminderOn = reminderSwitch?.state == .on
        probe.leadEnabled = leadPopup?.isEnabled ?? false
        probe.leadSelection = leadPopup?.titleOfSelectedItem ?? ""
        probe.leadItemTitles = leadPopup?.itemTitles ?? []
        probe.leadSelectedIndex = leadPopup?.indexOfSelectedItem ?? -1
        probe.leadPopupWidth = leadPopup?.frame.width ?? 0
        // 卡片内容区的宽度：卡片自身的宽度减去左右内边距。
        probe.cardContentWidth = card.frame.width
        if let pop = leadPopup, let sv = pop.superview {
            let inCard = sv.convert(pop.bounds, to: card).maxX
            probe.leadPopupMaxX = inCard
        }
        probe.loginSwitchEnabled = loginSwitch?.isEnabled ?? false
        probe.loginStateText = loginStatusLabel?.stringValue ?? ""
        probe.notificationText = notificationStatusLabel?.stringValue ?? ""
        probe.testButtonEnabled = testReminderButton?.isEnabled ?? false
        if let b = openNotifyButton {
            probe.openNotifyButtonPresent = true
            probe.openNotifyButtonEnabled = b.isEnabled
        }
        return probe
    }

    /// 调试用：把关键视图的真实 frame 打出来（`--dump-layout`）。
    func dumpLayout() {
        // `window` 只在 `show()` 里建；`--dump-layout` 这条 CLI 路径不会走 show()，
        // 所以这里必须自己建一次 —— 否则 window 是 nil，`layoutIfNeeded()` 直接 trap 崩溃
        // （退出码 133 = SIGTRAP）。
        if window == nil { buildWindow() }
        window.layoutIfNeeded()
        print("window      ", window.frame.size)
        print("table       ", tableView.frame.size)
        print("rowHeight   ", tableView.rowHeight, "rows", weekCourses().count)
        // 退出按钮的位置：用来核对「居中」这件事，别靠肉眼截图猜。
        // 往上找 SettingsCard 本身（按钮 → 整行容器 → 内容栈 → 卡片），
        // 拿卡片宽度做基准。
        if let btn = quitButton {
            var ancestor: NSView? = btn.superview
            while let v = ancestor, !(v is SettingsCard) { ancestor = v.superview }
            let b = btn.frame
            print("quitBtn     origin=(\(Int(b.origin.x)),\(Int(b.origin.y))) size=(\(Int(b.width))x\(Int(b.height)))")
            if let card = ancestor {
                let c = card.frame
                // **必须换算坐标系**：按钮的 frame 是相对它的容器（整行容器），
                // 卡片的 frame 是相对卡片自己 —— 直接比会差出一个内边距（15pt），
                // 看着像没居中，其实是坐标系没对齐。统一换算到卡片坐标系再比。
                let inCard = card.convert(btn.frame, from: btn.superview)
                print("  卡片宽度   ", Int(c.width))
                print("  按钮中心   ", Int(inCard.midX), " 卡片中心 ", Int(c.midX),
                      " 偏差 ", Int(inCard.midX - c.midX), "px")
            } else {
                print("  找不到 SettingsCard 祖先")
            }
        } else {
            print("quitBtn     nil（buildWindow 没跑到？）")
        }
    }

    // ---------- 行为 ----------
    /// 改一项外观配置并立刻写盘 + 通知桌面卡片。
    ///
    /// 写盘统一走 `SettingsStore`（读-改-写，只动外观那 5 项），
    /// 不在 UI 里自己拼字典 —— 那样迟早把别的模块写的字段覆盖掉。
    func update(_ key: String, _ value: Double) {
        switch key {
        case "fadeInSec":   appSettings.appearance.fadeInSec = value
        case "fadeOutSec":  appSettings.appearance.fadeOutSec = value
        case "minOpacity":  appSettings.appearance.minOpacity = value
        case "maxOpacity":  appSettings.appearance.maxOpacity = value
        case "panelOpacity": appSettings.appearance.panelOpacity = value
        case "cardScale":    appSettings.appearance.cardScale = value
        default: break
        }
        config = appSettings.appearance.asAppearanceConfig
        do {
            try settingsStore.saveAppearance(appSettings.appearance)
        } catch {
            presentSaveError("外观设置未保存：\(error.localizedDescription)")
            return
        }
        if key == "panelOpacity" {
            // 面板自己的透明度：立刻生效，不用等下一次打开
            applyPanelOpacity()
        } else {
            statusLabel.stringValue = "已保存 · 桌面课表将在数秒内生效"
        }
        onChange()
    }

    /// 课表卡片大小变了 —— 缩放桌面上的课表。
    ///
    /// ⚠️ **拖动中不写盘**（`persist: false`）：滑块拖动时每帧都来一次，
    /// 每帧写盘 + 每帧重排窗口太浪费；松手时（`persist: true`）才写。
    ///
    /// - Parameters:
    ///   - value: 目标缩放系数。
    ///   - persist: 是否写盘。
    func updateCardScale(_ value: Double, persist: Bool) {
        // 滑杆上限已经是「当前屏幕放得下」的值（见建面板处），这里再夹一次
        // 只是兜底（比如拖到一半换了屏幕）。
        let sliderMax = cardScaleRow.slider.maxValue
        let upper = min(CardScalePolicy.currentMaxScale(), sliderMax)
        let clamped = CardScalePolicy.clamp(value)
        let effective = min(clamped, upper)

        // 交给桌面那边重排（保持卡片中心 + 重新夹屏）。
        onCardScaleChange?(effective, persist)

        // 状态行提示。
        if let notice = CardScalePolicy.limitNotice(requested: value, actual: effective) {
            statusLabel.stringValue = notice
        } else if persist {
            statusLabel.stringValue = "已保存 · 课表大小 \(CardScalePolicy.percentText(effective))"
        } else {
            statusLabel.stringValue = "课表大小 \(CardScalePolicy.percentText(effective))"
        }
        // ⚠️ **拖动中不要把值写回滑杆**（2026-11 修「拖动不流畅」）。
        //
        // 以前每帧都 `setValue(effective)`：NSSlider 正在跟鼠标拖动，
        // 代码又把它的值改掉 → 滑杆和鼠标抢位置，手感是「粘、拖不动」。
        // 上限已经设成真实上限了，正常情况下 effective == value，不需要回填；
        // 真被夹住也只在松手时回填一次。
        if persist, abs(cardScaleRow.value - effective) > 0.0001 {
            cardScaleRow.setValue(effective)
        }
        config.cardScale = effective
        appSettings.appearance.cardScale = effective
    }

    func updateInfo() {
        if courses.isEmpty {
            infoLabel.stringValue = "未导入课表 · 桌面课表将使用内置数据"
        } else {
            let names = Set(courses.map { $0.name })
            let ids = Set(courses.map { $0.courseID }.filter { !$0.isEmpty })
            infoLabel.stringValue = "已载入 \(courses.count) 条记录 · \(names.count) 门课程（\(ids.count) 个 courseID）"
        }
        // 数据提示：周次缺失 / 超出学期周数 / 异常
        var lines = notices
        let exceeding = SemesterConfig(start: semesterStart, maxWeek: semesterMaxWeek)
            .coursesExceedingMaxWeek(courses)
        if !exceeding.isEmpty {
            let names = Array(Set(exceeding.map { $0.name })).sorted()
            lines.append("有课程超出学期周数，请调整学期总周数或课程周次：\(names.joined(separator: "、"))")
        }
        // 冲突列表（冲突格在设置面板里能看到）
        let conflicts = ScheduleConflicts.detect(courses)
        if !conflicts.isEmpty {
            lines.append("有 \(conflicts.count) 个时间格存在冲突：")
            for c in conflicts {
                lines.append("· \(c.timeText)：\(c.names.joined(separator: " / "))")
            }
        }
        dataNoticeLabel.stringValue = lines.joined(separator: "\n")
        dataNoticeLabel.isHidden = lines.isEmpty
    }

    /// 修改学期总周数。
    ///
    /// 调低导致已有课程超出时，**先列出超出的课程并确认**，不静默裁剪。
    @objc func maxWeekChanged() {
        let text = maxWeekField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(text), n >= SemesterConfig.minMaxWeek, n <= SemesterConfig.maxMaxWeek else {
            maxWeekField.stringValue = String(semesterMaxWeek)
            statusLabel.stringValue = "学期总周数必须是 \(SemesterConfig.minMaxWeek)–\(SemesterConfig.maxMaxWeek) 之间的整数"
            return
        }
        guard n != semesterMaxWeek else { return }

        // 调低且有课程超出 → 列出并确认
        if n < semesterMaxWeek {
            let cfg = SemesterConfig(start: semesterStart, maxWeek: n)
            let exceeding = cfg.coursesExceedingMaxWeek(courses)
            if !exceeding.isEmpty {
                // 每条超出的记录 → 列表行（圆点用课程自己的颜色）。
                let rows: [AlertDialogRow] = exceeding.map { c in
                    let dayName = Schedule.dayNames[max(0, min(6, c.day - 1))]
                    let period = "第\(c.block * 2 + 1)-\(c.block * 2 + 2)节"
                    let timeText = Schedule.timeRange(block: c.block)
                    let overWeeks = c.weeks.filter { $0 > n }.map(String.init).joined(separator: ",")
                    return .line("· \(dayName) \(period) \(timeText)　\(c.name)（第 \(overWeeks) 周）",
                                 TimetablePalette.accent(for: c))
                }
                let outcome = AlertDialogController.show(.init(
                    severity: .warning,
                    title: "有 \(exceeding.count) 条课程记录超出新的学期总周数",
                    message: "课程不会被自动裁剪，但这些周次将落在第 \(n + 1) 周之后。"
                        + "确定要改成 \(n) 周吗？",
                    rows: rows,
                    confirmTitle: "仍然保存",
                    cancelTitle: "返回修改"))
                if case .confirmed = outcome {
                    // 继续往下走（保存）
                } else {
                    maxWeekField.stringValue = String(semesterMaxWeek)
                    return
                }
            }
        }

        semesterMaxWeek = n
        guard let repo = repository else {
            // 没有当前课表 → 明确告诉用户「没保存」，别让界面看着像生效了
            semesterMaxWeek = maxWeek
            presentSaveError("当前没有课表，学期设置未保存")
            return
        }
        var cfg = repo.semester
        cfg.maxWeek = n
        // 以前是 `try? repo.saveSemester(cfg)` —— 失败被吞，界面照样显示
        // 「学期总周数已更新为 N 周」，用户以为存上了，其实根本没写盘。
        do {
            try repo.saveSemester(cfg)
        } catch {
            semesterMaxWeek = maxWeek
            presentSaveError("保存失败：\(error.localizedDescription)")
            return
        }
        maxWeek = cfg.effectiveMaxWeek(for: courses)
        selectedWeek = min(selectedWeek, maxWeek)
        updateInfo()
        refreshPreview()
        statusLabel.stringValue = "学期总周数已更新为 \(n) 周 · 桌面课表将在数秒内生效"
        onChange()
    }

    // MARK: - 课程时间自定义

    /// 列表提交了一组合法作息 → 写盘，并让当前进程立刻改用新时间。
    ///
    /// 顺序不能反：先写盘再 `Schedule.applyPeriodTimes` —— 写盘失败时
    /// 桌面卡片保持旧时间，不会出现「界面显示已生效、磁盘里还是旧值」。
    private func savePeriodTimes(_ times: [PeriodTime]) {
        guard PeriodSettings.isValid(times) else {
            // 编辑器已经拦过一轮；这里再兜一次，非法数据绝不落盘。
            statusLabel.stringValue = "课程时间不合法：开始须早于结束，且不能和相邻节次重叠"
            periodEditor.times = appSettings.periods.times
            return
        }
        do {
            appSettings = try settingsStore.update { $0.periods.setTimes(times) }
        } catch {
            presentSaveError("课程时间未保存：\(error.localizedDescription)")
            periodEditor.times = appSettings.periods.times
            return
        }
        // 当前进程的 `Schedule.periods` 是时间列 / 状态条 / 提醒的唯一来源，
        // 保存后必须马上换掉，不能等下次启动。
        Schedule.applyPeriodTimes(appSettings.periods.times)
        statusLabel.stringValue = "课程时间已保存 · 桌面课表将在数秒内生效"
        onChange()
    }

    @objc private func resetPeriodTimes() {
        periodEditor.times = PeriodSettings.defaults
        savePeriodTimes(PeriodSettings.defaults)
    }

    /// 保存失败时弹窗，并把界面值回滚。
    private func presentSaveError(_ message: String) {
        AlertDialogController.show(.init(
            severity: .warning,
            title: "设置未保存",
            message: message,
            confirmTitle: "知道了",
            showsCancel: false))
        updateInfo()
        refreshPreview()
    }

    func refreshPreview() {
        weekLabel.stringValue = "第 \(selectedWeek) 周"
        weekDateLabel.stringValue = WeekMath.weekDateText(selectedWeek, semesterStart: semesterStart)
        updateSemesterInfo()
        tableView.reloadData()
    }

    func updateSemesterInfo() {
        let w = WeekMath.weekNumber(Date(), semesterStart: semesterStart)
        let today = WeekMath.monthDayText(Date())
        if (1...maxWeek).contains(w) {
            semesterInfoLabel.stringValue = "今天是 \(today)，第 \(w) 周（\(WeekMath.weekDateText(w, semesterStart: semesterStart))）"
        } else {
            semesterInfoLabel.stringValue = "今天是 \(today)，不在第 1–\(maxWeek) 周范围内"
        }
    }

    @objc func semesterChanged() {
        let picked = semesterPicker.dateValue
        // 防误写：NSDatePicker 在获得焦点 / 首次布局时也会触发 action。
        // 这里必须拿「用户选的原始日期」和当前值比，而不是和归一化后的周一比 ——
        // 否则同一周内调「几号」（比如 9/21 → 9/22）会被误判成没变化而回滚，
        // 表现就是向上调不动、向下却能调。
        guard !WeekMath.calendar.isDate(picked, inSameDayAs: semesterStart) else { return }

        // 没有当前课表 → 明确说没保存（`persistSemesterStart` 会返回 false，
        // 但这里的提示文案不一样，所以先挡一次）。
        guard repository != nil else {
            presentSaveError("当前没有课表，学期设置未保存")
            return
        }

        switch persistSemesterStart(picked) {
        case .saved:
            selectedWeek = currentWeek()
            refreshPreview()
            statusLabel.stringValue = "开学日期已更新 · 桌面课表将在数秒内生效"
        case .unchanged:
            break
        case .failed(let message):
            // 失败：界面值回滚到旧日期（`persistSemesterStart` 只在成功时改它），
            // 并把**真实错误**告诉用户。
            presentSaveError("保存失败：\(message)")
        }
    }

    /// 保存新的开学日期，**保存成功后**通知外部刷新（桌面卡片 + 提醒计划）。
    ///
    /// 单独抽出来是为了能单测 —— 以前这段逻辑内联在 `semesterChanged()` 里，
    /// 而且**保存成功后没有通知任何人**：桌面卡片还按旧学期算周次，
    /// 提醒计划也还按旧学期排（学期起始日是提醒规划器的输入）。
    /// 学期总周数那条路径（`maxWeekChanged`）末尾有 `onChange()`，这里漏了。
    ///
    /// - Returns: 保存成功（且已通知刷新）返回 true；失败返回 false（**不通知**）。
    @discardableResult
    func persistSemesterStart(_ picked: Date) -> SemesterCommitResult {
        guard let repo = repository else {
            return .failed("当前没有课表，学期设置未保存")
        }
        var cfg = repo.semester
        cfg.start = picked
        let result = Self.commitSemesterStart(
            picked: picked,
            current: semesterStart,
            save: { _ in try repo.saveSemester(cfg) },
            onChanged: { [weak self] in self?.onChange() })
        if case .saved = result {
            // 只有真的写盘成功才更新界面上的日期。
            semesterStart = picked
        }
        return result
    }

    /// 学期开始日期的保存结果。
    enum SemesterCommitResult: Equatable {
        /// 同一天 —— 什么都没做（不算失败）。
        case unchanged
        /// 保存成功，刷新回调已触发一次。
        case saved
        /// 保存失败（带真实错误信息）。
        case failed(String)
    }

    /// 「保存学期开始日期 + 通知外部刷新」的**纯逻辑**（可单测）。
    ///
    /// `onChanged` 只在**保存成功**时调用一次；失败时一次都不调用。
    static func commitSemesterStart(picked: Date,
                                    current: Date,
                                    save: (Date) throws -> Void,
                                    onChanged: () -> Void) -> SemesterCommitResult {
        // 同一天 → 什么都不做（不写盘、不通知）。
        if WeekMath.calendar.isDate(picked, inSameDayAs: current) { return .unchanged }
        do {
            try save(picked)
        } catch {
            return .failed(error.localizedDescription)
        }
        onChanged()
        return .saved
    }

    @objc func gotoCurrentWeek() {
        selectedWeek = currentWeek()
        refreshPreview()
    }

    @objc func prevWeek() {
        selectedWeek = max(1, selectedWeek - 1)
        refreshPreview()
    }

    @objc func nextWeek() {
        selectedWeek = min(maxWeek, selectedWeek + 1)
        refreshPreview()
    }

    /// 在访达里显示**当前课表**的数据。
    ///
    /// 以前这里用的是 `store.directory` / `store.coursesFile` ——
    /// 那是全局外观配置用的 `ScheduleStore`，指数据**根目录**下的旧版
    /// `schedule_data.json`，不是当前课表目录 `<uuid>/schedule_data.json`。
    /// 用户点「在访达中显示」想看的是现在在用的那份课表，结果看到的是根目录的旧文件。
    @objc func revealData() {
        let target = currentRevealTarget()
        // 顺序固定：先让路 → 再让访达显示文件 → 再把访达提到最前。
        // 「为什么是这个顺序」写在 FinderRevealCoordinator 里。
        let steps = FinderRevealCoordinator.steps(path: target.path, root: target.root)
        // 自检接管：只把计划交给它（让它验顺序），并跳过「会碰用户桌面」的两步 ——
        // 真执行会在用户桌上弹出访达窗口，自检不能这样。
        // **让路那步照常执行**：它只改本 app 自己的窗口，不打扰用户。
        if let handler = testRevealStepHandler {
            handler(steps)
        }
        for step in steps {
            if testRevealStepHandler != nil, step.touchesUserDesktop { continue }
            performRevealStep(step)
        }
    }

    /// 「在访达中显示」的目标：当前课表的数据文件（没有就退到课表目录）。
    ///
    /// 以前这里用的是 `store.directory` / `store.coursesFile` —— 那是全局外观配置
    /// 用的 `ScheduleStore`，指数据**根目录**下的旧版 `schedule_data.json`，
    /// 不是当前课表目录 `<uuid>/schedule_data.json`。
    /// 用户点「在访达中显示」想看的是现在在用的那份课表，结果看到的是根目录的旧文件。
    private func currentRevealTarget() -> (path: String, root: String) {
        // 当前课表目录（没有当前课表就退到 timetables/ 根目录）
        if let ts = timetableStore, let id = ts.activeID {
            let dir = ts.directory(for: id)
            let file = ts.coursesFile(for: id)
            if FileManager.default.fileExists(atPath: file.path) {
                return (file.path, dir.path)
            }
            return (dir.path, dir.path)
        }
        // 没有当前课表：打开 timetables/ 根目录，而不是旧版根目录里的 schedule_data.json
        if let ts = timetableStore {
            let dir = ts.timetablesDirectory
            return (dir.path, dir.path)
        }
        let dir = store.directory
        let file = store.coursesFile
        if FileManager.default.fileExists(atPath: file.path) {
            return (file.path, dir.path)
        }
        return (dir.path, dir.path)
    }

    // MARK: - 「在访达中显示」：面板给访达窗口让路

    /// 面板是不是正在给访达窗口让路。
    ///
    /// 让路 = 降层到 `.normal` + `orderOut` 收起。
    /// 访达揭示期间必须让路 —— 面板是 `.floating` 浮层、访达窗口是普通层，
    /// **层级高的永远排在前面，跨 App 也一样**（详见 FinderRevealPolicy）。
    private(set) var isYieldingToFinder = false

    /// 自检用：接管「在访达中显示」的执行。
    ///
    /// 真执行会在用户桌上真的弹出访达窗口 —— 自检不能这样。
    /// 设了它之后 `revealData()` 只把步骤交给它，不做任何真实副作用。
    var testRevealStepHandler: (([FinderRevealStep]) -> Void)?

    /// 让路：面板降层 + 收起，把「前面」这个位置让给访达窗口。
    ///
    /// 两件事缺一不可：
    /// - **降层**：不降层的话 `.floating` 永远压在访达的普通层前面 —— 访达窗口
    ///   打开就在面板底下，用户点了「在访达中显示」什么也看不见。
    /// - **收起**：只降层的话面板还在屏上。用户一点它，本 App 立刻回到前台，
    ///   面板又回到前面把访达盖住 —— bug 原地复活。
    ///
    /// 顺带作废在途的激活重试（`activationToken`）：那些重试会
    /// `makeKeyAndOrderFront` 把面板顶回前面，还会 `NSApp.activate` 抢前台，
    /// 正好把刚让出去的位置抢回来。
    func yieldToFinder() {
        isYieldingToFinder = true
        guard let w = window else { return }
        w.level = FinderRevealPolicy.level(yielding: true)
        w.orderOut(nil)
        activationToken += 1
    }

    /// 让路结束，把面板摆回浮层。
    ///
    /// **只管层级**，不负责把面板摆出来 —— 让路时它被 `orderOut` 收起了，
    /// 摆不摆出来由 `show()` / `applicationDidBecomeActive` 决定。
    /// 平时调用零成本（没让过路就直接返回）。
    func restoreFinderRevealIfNeeded() {
        guard isYieldingToFinder else { return }
        isYieldingToFinder = false
        window?.level = FinderRevealPolicy.level(yielding: false)
    }

    /// 显式激活访达，把访达窗口提到最前。
    ///
    /// `NSWorkspace.selectFile` 只保证「选中并显示」，**不保证访达窗口排到最前**。
    /// 本 App 是 accessory、不抢前台 —— 访达窗口起来之后到底排在谁前面，
    /// 全看系统当时的心情。这里显式激活一次，把结果钉死。
    private func activateFinderApp() {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder").first else { return }
        finder.activate(options: [.activateAllWindows])
    }

    /// 执行「在访达中显示」的一步。
    private func performRevealStep(_ step: FinderRevealStep) {
        switch step {
        case .yieldPanel:
            yieldToFinder()
        case .selectFile(let path, let root):
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: root)
        case .activateFinder:
            activateFinderApp()
        }
    }

    /// 「退出应用」按钮。
    ///
    /// 菜单栏图标可能被系统拦掉，用户找不到别的退出入口，所以这里必须真的能退出。
    /// 不直接调 `NSApplication.terminate` —— 先让 AppDelegate 收尾（关桌面窗口、停定时器），
    /// 免得退出瞬间桌面上留一个残影。
    @objc func quitApp() {
        // 不弹确认框，直接在 AppDelegate 里统一清场 + 关面板 + terminate。
        if let onQuitRequested {
            onQuitRequested()
        } else {
            // 没有 AppDelegate（单独跑面板时）：自己收尾。
            window.close()
            NSApp.terminate(nil)
        }
    }

    @objc func importSchedule() {
        // 阶段 3：统一走三选一流程（新建 / 覆盖当前 / 取消）。
        if let onImportRequested {
            onImportRequested()
            return
        }
        importScheduleLegacy()
    }

    /// 阶段 1/2 的旧导入流程（直接替换当前课表）。
    ///
    /// **正常路径走不到这里** —— 阶段 3 起，导入统一走 `ImportDecisionController`
    /// 的三选一流程（新建 / 覆盖当前 / 取消）；`onImportRequested` 由 AppDelegate 注入。
    ///
    /// 这条只在**脱离 AppDelegate 单独使用设置面板**时才会走到（测试 / 预览场景）。
    /// 保留它是因为它还提供「预览 + 写盘前备份」的老能力。
    ///
    /// 注意：它的校验和正常路径**用同一份** `ImportValidator`
    /// （经由 `ScheduleImporter.plan` → `ImportPlanner.plan`），
    /// 所以不会出现「界面导入拦得住、这里拦不住」的情况。
    private func importScheduleLegacy() {
        let panel = NSOpenPanel()
        // allowedFileTypes 在 macOS 12 已废弃，改用 UTType
        var cts: [UTType] = [.json, .html]
        for ext in ["xls", "htm"] { if let t = UTType(filenameExtension: ext) { cts.append(t) } }
        panel.allowedContentTypes = cts
        // 面板默认落在「下载」文件夹（教务系统的导出一般都在那儿）。
        // 注意：只设 directoryURL，不自己去列这个目录 ——
        // app 直接读 ~/Downloads 会触发 macOS 的「访问下载文件夹」授权弹窗，
        // 而 LSUIElement 的后台 app 弹不出这个框，主线程会卡在 open() 上直到用户点按钮。
        // 由系统文件面板自己去读，就不需要这个授权。
        let dl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if FileManager.default.fileExists(atPath: dl.path) { panel.directoryURL = dl }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择教务系统导出的课表文件（.xls）或课表 JSON"
        panel.prompt = "导入"

        NSApp.activate(ignoringOtherApps: true)
        let modalRes = panel.runModal()
        guard modalRes == .OK, let url = panel.url else { return }
        do {
            // 解析 → 分组 → 匹配旧 courseID → 预览（写盘之前）
            let (plan, format) = try ScheduleImporter.plan(at: url,
                                                           existing: courses,
                                                           maxWeek: maxWeek)
            guard let newCourses = presentImportPreview(plan, format: format, fileName: url.lastPathComponent) else {
                statusLabel.stringValue = "已取消导入 · 课表未改动"
                return
            }
            // 写盘（自动备份）
            try repository?.save(newCourses)
            courses = newCourses
            maxWeek = (repository?.semester.effectiveMaxWeek(for: courses)) ?? maxWeek
            updateInfo()
            refreshPreview()
            statusLabel.stringValue = "课表已导入 · \(url.lastPathComponent) · \(newCourses.count) 条记录"
            onChange()
        } catch {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "导入失败",
                message: error.localizedDescription,
                confirmTitle: "好",
                showsCancel: false))
        }
    }

    /// 导入预览（写盘之前）。
    ///
    /// 返回 nil = 用户取消（不写盘）；返回非 nil = 确认后的最终课程数组。
    private func presentImportPreview(_ plan: ImportPlanner.Plan,
                                       format: ScheduleImporter.Format,
                                       fileName: String) -> [Course]? {
        var detail = "来源：\(fileName)（\(format.rawValue)）\n\n"
        detail += plan.summary

        if !plan.removedCourses.isEmpty {
            detail += "\n替换后，当前课表里未匹配的课程会被移除：\n"
            detail += plan.removedCourses.map { "· \($0.name)" }.joined(separator: "\n")
        }
        if !plan.conflicts.isEmpty {
            detail += "\n冲突的时间格（同一格多门课）：\n"
            detail += plan.conflicts.map { c in
                "· \(c.timeText)：\(c.names.joined(separator: " / "))"
            }.joined(separator: "\n")
        }
        if !plan.duplicates.isEmpty {
            detail += "\n同一门课同一格的重复上课时间：\n"
            detail += plan.duplicates.map { d in
                "· \(d.timeText)：\(d.name)"
            }.joined(separator: "\n")
        }
        if !plan.ambiguous.isEmpty {
            detail += "\n以下课程匹配到多个已有课程，无法自动判断，请手动确认：\n"
            detail += plan.ambiguous.map { c in
                "· \(c.name)（\(c.code.isEmpty ? "无代码" : c.code)）"
            }.joined(separator: "\n")
        }
        if !plan.anomalies.isEmpty {
            detail += "\n数据异常：\n"
            detail += plan.anomalies.map { "· \($0)" }.joined(separator: "\n")
        }

        // 长文本 → 滚动区（`AlertDialogController` 自己判断要不要滚）。
        let outcome = AlertDialogController.show(.init(
            severity: plan.conflicts.isEmpty ? .info : .warning,
            title: "导入预览",
            message: detail,
            confirmTitle: "替换导入",
            cancelTitle: "取消"))
        guard case .confirmed = outcome else { return nil }

        // 匹配不唯一的课程：逐个让用户选「合并到已有课程」或「新建」
        var resolved = plan
        for c in plan.ambiguous {
            guard case .ambiguous(let candidates) = c.match else { continue }
            // 候选课程的显示名（从已有课程里找）
            var candidateNames: [String] = []
            for id in candidates {
                let n = existingCourseName(id)
                candidateNames.append(n ?? id)
            }
            // 「合并到「X」」逐个一条，最后一条是「新建课程」——
            // 选项行取代了原来一排系统按钮，分支含义完全一样。
            var options: [AlertDialogOption] = candidateNames.map { n in
                AlertDialogOption(
                    title: "合并到「\(n)」",
                    detail: "并入已有的这门课",
                    accessibilityLabel: "合并到已有课程 \(n)")
            }
            options.append(AlertDialogOption(
                title: "新建课程",
                detail: "作为一门新课加入课表",
                accessibilityLabel: "新建课程，作为一门新课加入课表"))
            let pick = AlertDialogController.show(.init(
                severity: .warning,
                title: "「\(c.name)」匹配到多个已有课程",
                message: "请选择要合并到哪一门已有课程，或新建一门新课。",
                options: options,
                cancelTitle: "取消导入",
                showsConfirm: false,
                showsCancel: true))
            switch pick {
            case .chosen(let index) where index < candidates.count:
                let chosen = candidates[index]
                if let idx = resolved.courses.firstIndex(where: { $0.courseID == c.courseID }) {
                    resolved.courses[idx].courseID = chosen
                    for r in resolved.courses[idx].records.indices {
                        resolved.courses[idx].records[r].courseID = chosen
                    }
                    resolved.courses[idx].match = .reused(courseID: chosen)
                }
            case .chosen:
                // 新建（courseID 保持新生成的）
                break
            default:
                // 取消导入
                return nil
            }
        }
        // 用户决定之后重算「将被移除的旧课程」：合并到旧课后旧课要留下
        resolved = ImportPlanner.finalizeRemoved(plan: resolved, existing: courses)
        return ImportPlanner.materialize(resolved)
    }

    /// 已有课程里某个 courseID 的课名。
    private func existingCourseName(_ courseID: String) -> String? {
        courses.first { $0.courseID == courseID }?.name
    }

    /// 供菜单栏调用
    func performImport() {
        // 阶段 3：导入统一走 AppDelegate 的三选一流程（新建 / 覆盖 / 取消）。
        if let onImportRequested {
            onImportRequested()
            return
        }
        importSchedule()
    }

    // MARK: - 课表卡片（阶段 3）

    /// 刷新「课表」卡片的摘要。
    func updateTimetableSummary() {
        guard let label = timetableSummaryLabel else { return }
        guard let ts = timetableStore else {
            label.stringValue = "课表功能未启用"
            return
        }
        let metas = ts.allMetas()
        if metas.isEmpty {
            label.stringValue = "还没有课表 · 点「新建」建一份，或在「课表数据」里导入"
            timetableApplyBtn?.isEnabled = false
            return
        }
        let active = metas.first { $0.id == ts.activeID }
        var s = "当前：\(active?.name ?? "无") · 共 \(metas.count) 份"
        // 预览里选了另一份 → 提示还没应用
        if let sel = selectedMeta, sel.id != ts.activeID {
            s += " · 已选「\(sel.name)」（点「应用当前课表」切换）"
        }
        label.stringValue = s
        // 选中的就是当前这份 → 「应用」没必要，按钮置灰
        timetableApplyBtn?.isEnabled = (selectedMeta?.id != nil
                                        && selectedMeta?.id != ts.activeID)
    }

    @objc private func manageTimetables() {
        onManageTimetables?()
    }

    // MARK: - 课表：预览 / 新建 / 重命名 / 删除 / 应用

    /// 仓库里的全部课表。
    private var timetableMetas: [TimetableMeta] { timetableStore?.allMetas() ?? [] }

    /// 当前正在用的那份课表 id。
    private var activeTimetableID: String? { timetableStore?.activeID }

    /// 预览里选中的那份（没选就退回当前那份）。
    private var selectedMeta: TimetableMeta? {
        let metas = timetableMetas
        if let id = selectedTimetableID, let m = metas.first(where: { $0.id == id }) { return m }
        return metas.first { $0.id == activeTimetableID }
    }

    /// 刷新课表预览（列表 + 摘要 + 按钮状态）。
    func refreshTimetablePreview() {
        guard timetablePreviewList != nil else { return }
        let metas = timetableMetas
        // 选中的那份没了（刚被删）→ 退回当前那份
        if let id = selectedTimetableID, !metas.contains(where: { $0.id == id }) {
            selectedTimetableID = nil
        }
        if selectedTimetableID == nil { selectedTimetableID = activeTimetableID }
        timetablePreviewList.items = metas.map { meta in
            TimetablePreviewList.Item(
                id: meta.id,
                name: meta.name,
                subtitle: meta.subtitle,
                updated: Self.timetableDateFormatter.string(from: meta.updatedAt),
                isActive: meta.id == activeTimetableID)
        }
        timetablePreviewList.selectedID = selectedTimetableID
        updateTimetableSummary()
    }

    /// 带符号的小按钮（符号在文字前面）。
    // MARK: - 日记板块自检探针

    /// 只读：日记板块当前显示了几行、摘要写了什么、选中的是哪一条。
    func probeDiarySection() -> (count: Int, summary: String, selected: String?) {
        (diaryListStack?.arrangedSubviews.count ?? 0,
         diarySummaryLabel?.stringValue ?? "",
         selectedDiaryID)
    }

    /// 自检用：选中某一行（走的是和点击一样的路径）。
    func testSelectDiary(id: String) {
        selectedDiaryID = id
        refreshDiaryList()
    }

    // MARK: - 日记板块（2026-11-10 新增）

    /// 「日记」板块：列表 + 新建 / 编辑 / 删除。
    ///
    /// 数据源是 `DiaryStore`（`<数据目录>/diary.json`），和日期覆盖层用的是**同一份文件** ——
    /// 在设置里改完，桌面上的覆盖层下一次打开 / 刷新就跟着变。
    private func buildDiarySection(into stack: NSStackView) {
        let card = SettingsCard(title: "日记")

        diarySummaryLabel = makeLabel("", size: 11.5, color: NSColor.white.withAlphaComponent(0.55))
        diarySummaryLabel.maximumNumberOfLines = 2
        diarySummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        // 列表：可滚动的一列行（行 = 日期 · 时间 · 标题）。
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false
        diaryListStack = listStack

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedStackDocument()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 176),
        ])
        diaryScrollView = scroll

        let newBtn = makeIconButton("新建", symbol: "plus", action: #selector(newDiaryEntry))
        let editBtn = makeIconButton("编辑", symbol: "pencil", action: #selector(editDiaryEntry))
        let delBtn = makeIconButton("删除", symbol: "trash", action: #selector(deleteDiaryEntry))
        diaryEditButton = editBtn
        diaryDeleteButton = delBtn
        let buttons = NSStackView(views: [newBtn, editBtn, delBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .leading
        buttons.translatesAutoresizingMaskIntoConstraints = false

        card.content.addArrangedSubview(diarySummaryLabel)
        card.content.addArrangedSubview(scroll)
        card.content.addArrangedSubview(buttons)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        refreshDiaryList()
    }

    /// 重新读文件并重建列表（新建 / 编辑 / 删除之后都走这里）。
    func refreshDiaryList() {
        guard let diaryListStack else { return }
        diaryEntries = diaryStore.all()
        if let selected = selectedDiaryID,
           !diaryEntries.contains(where: { $0.id == selected }) {
            selectedDiaryID = nil
        }
        diarySummaryLabel?.stringValue = diaryEntries.isEmpty
            ? "还没有日记。日期覆盖层里点「＋ 写日记」，或者这里点「新建」。"
            : "共 \(diaryEntries.count) 篇。列表按日期倒序；点一行选中，再点「编辑」或「删除」。"
        for v in diaryListStack.arrangedSubviews {
            diaryListStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for entry in diaryEntries {
            let row = DiaryRowView(entry: entry, selected: entry.id == selectedDiaryID)
            row.onSelect = { [weak self] in
                guard let self else { return }
                self.selectedDiaryID = entry.id
                self.refreshDiaryList()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            diaryListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: diaryListStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        diaryEditButton?.isEnabled = selectedDiaryID != nil
        diaryDeleteButton?.isEnabled = selectedDiaryID != nil
    }

    @objc private func newDiaryEntry() {
        guard let result = DiaryEditorDialog.run(title: "写日记", entry: nil, confirmTitle: "保存") else { return }
        let date = DiaryStore.dateKey(Date())
        do {
            let entry = try diaryStore.add(date: date, title: result.title,
                                           body: result.body, time: result.time)
            selectedDiaryID = entry.id
            refreshDiaryList()
        } catch {
            statusLabel.stringValue = "写日记失败：\(error.localizedDescription)"
        }
    }

    @objc private func editDiaryEntry() {
        guard let id = selectedDiaryID,
              let entry = diaryEntries.first(where: { $0.id == id }) else { return }
        guard let result = DiaryEditorDialog.run(title: "修改日记", entry: entry,
                                                 confirmTitle: "保存") else { return }
        do {
            try diaryStore.update(id: id, title: result.title,
                                  body: result.body, time: result.time)
            refreshDiaryList()
        } catch {
            statusLabel.stringValue = "保存日记失败：\(error.localizedDescription)"
        }
    }

    @objc private func deleteDiaryEntry() {
        guard let id = selectedDiaryID,
              let entry = diaryEntries.first(where: { $0.id == id }) else { return }
        let name = entry.title.isEmpty ? "（未命名）" : entry.title
        let outcome = AlertDialogController.show(.init(
            severity: .destructive,
            title: "删除这篇日记？",
            message: "\(entry.date)　\(name)",
            confirmTitle: "删除"))
        guard case .confirmed = outcome else { return }
        do {
            try diaryStore.delete(id: id)
            selectedDiaryID = nil
            refreshDiaryList()
        } catch {
            statusLabel.stringValue = "删除日记失败：\(error.localizedDescription)"
        }
    }

    private func makeIconButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        b.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        return b
    }

    /// 新建课表：直接弹「新建课表」页，不再跳去「课表管理」窗口。
    @objc private func newTimetable() {
        guard let ts = timetableStore else { return }
        guard let input = TimetableNameDialog.run(
            title: "新建课表",
            message: "创建一份空课表，之后可以导入课表内容。",
            name: "新课表", subtitle: "", confirmTitle: "创建") else { return }
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusLabel.stringValue = "课表名称不能为空"
            return
        }
        do {
            let t = try ts.create(name: name,
                                  subtitle: input.subtitle.trimmingCharacters(in: .whitespacesAndNewlines))
            // 新建后立刻成为当前课表 —— 桌面卡片马上刷新。
            try ts.setActive(t.id)
            selectedTimetableID = t.id
            onTimetablesChanged?()
            statusLabel.stringValue = "已新建「\(t.name)」· 桌面课表已刷新"
        } catch {
            statusLabel.stringValue = "新建失败：\(error.localizedDescription)"
        }
    }

    /// 重命名预览里选中的那份课表。
    @objc private func renameTimetable() {
        guard let ts = timetableStore else { return }
        guard let meta = selectedMeta else {
            statusLabel.stringValue = "先在上面选中一份课表"
            return
        }
        guard let input = TimetableNameDialog.run(
            title: "重命名课表",
            message: "只改名字和副标题，不影响课程数据。",
            name: meta.name, subtitle: meta.subtitle, confirmTitle: "保存") else { return }
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusLabel.stringValue = "课表名称不能为空"
            return
        }
        do {
            try ts.rename(id: meta.id, name: name,
                          subtitle: input.subtitle.trimmingCharacters(in: .whitespacesAndNewlines))
            onTimetablesChanged?()
            statusLabel.stringValue = "已重命名为「\(name)」"
        } catch {
            statusLabel.stringValue = "重命名失败：\(error.localizedDescription)"
        }
    }

    /// 删除预览里选中的那份课表。
    @objc private func deleteTimetable() {
        guard let ts = timetableStore else { return }
        guard let meta = selectedMeta else {
            statusLabel.stringValue = "先在上面选中一份课表"
            return
        }
        let others = timetableMetas.filter { $0.id != meta.id }
        // 「切到哪一份」必须问 store 本身（`nextActiveIDAfterDeleting`），
        // 因为 `delete()` 实际切到的是索引里的第一份，
        // 而按更新时间倒序的第一份常常不是同一份 —— 提示会报错课表名字。
        let nextID = ts.nextActiveIDAfterDeleting(id: meta.id)
        let nextName = nextID.flatMap { id in timetableMetas.first { $0.id == id }?.name }

        let message: String
        if others.isEmpty {
            message = "这是最后一份课表。删除后进入空课表状态。"
        } else if meta.id == ts.activeID, let nextName {
            message = "这是当前课表。删除后会切换到「\(nextName)」。"
        } else {
            message = "删除后无法恢复。"
        }
        let dialog = ConfirmDialogController(request: .init(
            title: "删除课表「\(meta.name)」？",
            message: message + "\n\n删除前会备份整个课表目录。",
            confirmTitle: "删除",
            severity: .destructive))
        guard dialog.run() == .confirm else { return }
        do {
            try ts.delete(id: meta.id)
            selectedTimetableID = ts.activeID
            onTimetablesChanged?()
            statusLabel.stringValue = "已删除「\(meta.name)」"
        } catch {
            statusLabel.stringValue = "删除失败：\(error.localizedDescription)"
        }
    }

    /// 把预览里选中的那份真正应用为当前课表。
    @objc private func applyTimetable() {
        guard let ts = timetableStore else { return }
        guard let meta = selectedMeta else { return }
        guard meta.id != ts.activeID else { return }
        do {
            try ts.setActive(meta.id)
            onTimetablesChanged?()
            statusLabel.stringValue = "已切换到「\(meta.name)」· 桌面课表已刷新"
        } catch {
            statusLabel.stringValue = "切换失败：\(error.localizedDescription)"
        }
    }

    // ---------- 表格 ----------
    func weekCourses() -> [Course] {
        // 周次判断统一走 Course.isActive(in:)
        courses.filter { $0.isActive(in: selectedWeek) }
            .sorted { ($0.day, $0.block) < ($1.day, $1.block) }
    }

    /// 自检用：课程预览当前显示的课程名。
    var previewCourseNames: [String] { weekCourses().map { $0.name } }

    func numberOfRows(in tableView: NSTableView) -> Int {
        weekCourses().count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        cellString(tableColumn, row)
    }

    /// 课程预览里的一格文字。
    func cellString(_ tableColumn: NSTableColumn?, _ row: Int) -> String {
        let list = weekCourses()
        guard row < list.count, let col = tableColumn else { return "" }
        let c = list[row]
        switch col.title {
        case "时间": return "\(Schedule.dayNames[max(0, min(6, c.day - 1))]) \(Schedule.timeRange(block: c.block))"
        case "课程": return c.name
        case "教师": return c.teacher
        default: return c.loc.replacingOccurrences(of: "(学校本部)", with: "").replacingOccurrences(of: "(新校区)", with: "")
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = cellString(tableColumn, row)
        cell.font = .systemFont(ofSize: 11.5)
        cell.textColor = NSColor.white.withAlphaComponent(0.78)
        cell.lineBreakMode = .byTruncatingTail
        cell.translatesAutoresizingMaskIntoConstraints = false
        return cell
    }

    /// 「更新时间」列的格式。
    private static let timetableDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
import AppKit
import CoreLocation
import UniformTypeIdentifiers
import UserNotifications

/// 应用生命周期：桌面卡片窗口、菜单栏、定时刷新、渐隐动画。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 右键编辑调度器（菜单 → 编辑器 → 校验 → 写盘 → 刷新卡片）。
    private var editorController: ScheduleEditorController!

    /// 自动化测试用：最近一次弹出的菜单标题（验证右键链路）。
    var testLastMenuTitles: [String] = []

    /// 课表仓库（阶段 3）：多课表的唯一读写层。
    ///
    /// 课程数据经由 `timetableStore.repository(for:)` 拿到底层的
    /// `ScheduleRepository`，所以阶段 1/2 的迁移、备份、原子写逻辑完全复用。
    private let timetableStore = TimetableStore()

    /// 当前课表的数据仓库（课程 + 学期）。
    ///
    /// 没有课表时是 nil（空课表状态），此时卡片显示空课表。
    private var repository: ScheduleRepository? {
        timetableStore.activeRepository()
    }

    /// 外观配置用的 store —— 注意 config.json 是全局的，不跟着课表走。
    private var store: ScheduleStore {
        timetableStore.configStore
    }

    /// 统一设置层（外观 + 提醒 / 笔记 / 桌宠）。
    ///
    /// AppDelegate **只读**设置用于渲染与排程；
    /// 写的入口统一在 `SettingsWindowController` / `SettingsStore`。
    private lazy var settingsStore = SettingsStore(configDirectory: store.configDirectory)
    /// 当前设置快照（每次数据变化后重读，别拿着旧副本）。
    private var appSettings = AppSettings()
    /// 系统通知调度器（自动化模式下不会碰真实系统 API）。
    private let reminderScheduler = ClassReminderScheduler()
    /// 登录项控制器（状态以系统为准，不存本地 bool）。
    let loginItems = LoginItemController()
    /// 上一次排提醒时的「日期」（跨天要补足 14 天窗口）。
    private var lastReminderDay = WeekMath.calendar.startOfDay(for: Date())
    /// 睡醒 / 激活时补排。
    private var wakeObserver: NSObjectProtocol?
    /// **显示器**唤醒（系统没睡，只是屏幕关了）—— 2026-11-11 加。
    ///
    /// 用户原话：「刚打开显示屏的时候正在上课但是课表上没有显示我正在上课
    /// 而且时间晚了 1 分钟」。笔记本合盖 / 手动关屏走的是这条通知，
    /// 不是 `didWakeNotification` —— 只监听后者会漏。
    private var screenWakeObserver: NSObjectProtocol?

    /// 当前课表元数据（标题 / 副标题从这儿读，不再写死）。
    private var currentTimetable: Timetable? {
        guard let id = timetableStore.activeID else { return nil }
        return try? timetableStore.load(id)
    }

    /// 课表管理面板。
    private var timetableManager: TimetableManagerController!
    /// 差异合并页。
    private var diffWindowController: TimetableDiffWindowController?
    /// 正在跑的导入流程。
    ///
    /// **必须强持有**：以前是 `performImport()` 里的局部变量，
    /// `start()` 一返回就被释放 —— 差异页点「应用」时 `self` 已经是 nil，
    /// `[weak self]` 全部静默失效（只关窗、不保存、不刷新）。
    /// 同时它也是「同一时间只允许一个导入流程」的锁。
    private var importDecision: ImportDecisionController?
    private var window: DesktopWindow!
    private var card: TimetableCardView!
    /// 卡片上层的**交互层**（拖动 + 图钉）。
    ///
    /// 它盖在画面（网页 / 原生卡片）**之上**：
    ///   · 拖动整张课表由它处理；
    ///   · 图钉是它的子视图，所以图钉永远在最上面、点击优先给图钉；
    ///   · 没拖动的点击会**转交**回画面层（点课程、点齿轮照旧生效）。
    private var interaction: CardInteractionView!
    /// 图钉 / 窗口位置的持久化层（`window_state.json`）。
    private let pinStore = TimetablePinStore()
    /// 当前是否已固定（图钉为实心）。
    private var isPinned: Bool = false
    /// 设置窗口控制器
    private var settingsController: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var pulseTimer: Timer?
    private var hoverMonitor: Any?
    private var localHoverMonitor: Any?

    private var courses: [Course] = []
    /// 单周临时覆盖（独立文件 `week_overrides.json`）。
    ///
    /// 覆盖**不进** `courses`：它是「这个格子在这几周归另一门课」，
    /// 混进课程表会被按名字合并、会在差异页里被当成课程、也会挤在同一个格子里。
    private var overrides: [WeekOverride] = []
    private var config = AppearanceConfig([:])
    private var semesterStart = Date()
    /// 学期配置（开学日期 + 学期总周数）
    private var semester = SemesterConfig(start: Date(), maxWeek: Schedule.defaultMaxWeek)
    /// 生效的学期总周数（配置值与数据里的最大周次取大）
    private var maxWeek = Schedule.defaultMaxWeek
    /// 数据读取错误（展示给用户）
    private var dataErrorMessage: String?
    /// 数据错误只提示一次
    private var didShowDataError = false
    /// 当前正在浏览的周次（nil = 全部周次）。
    ///
    /// `didSet` 把浏览周次同步给编辑器（右键「新增课程」的默认周次）。
    /// 以前只在**创建编辑器那一刻**设置一次（`editorController.viewWeek = viewWeek`），
    /// 用户翻到第 9 周再新增课程，新增出来的课仍然落在启动时那一周 —— 对不上眼。
    private var viewWeek: Int? {
        didSet {
            editorController?.viewWeek = viewWeek
        }
    }
    /// 「日期覆盖层」的原生控制器（EventKit 取数 + intent 处理）。
    private var dayPanel: DayPanelController?
    /// 网页卡片渲染器（WKWebView + 旧版界面）
    private var webRenderer: WebCardRenderer?
    /// 卡片背后的原生毛玻璃层（模式 B 下要与网页 .card 的实际矩形对齐）
    private var glassView: NSVisualEffectView?
    /// 网页卡片上次刷新的「分钟」，以及是否有状态变化等待重拍
    private var lastWebMinute = -1
    private var webNeedsRefresh = true

    /// 渲染模式：true = 模式 B（网页直接上屏，不取快照），false = 快照管线。
    /// 默认模式 B；`DT_SNAPSHOT=1` 可强制回退到快照管线。
    private static let liveMode = RenderMode.live
    private var isLiveMode: Bool { AppDelegate.liveMode }

    /// 自动化测试用：当前渲染模式是不是 B（网页直接上屏）。
    static var testIsLiveMode: Bool { liveMode == RenderMode.live }

    /// 自动化测试用：拿到底层渲染器（验证快照次数）。
    var testWebRenderer: WebCardRenderer? { webRenderer }

    /// 鼠标进出判定的迟滞（px），避免在边缘抖动。
    private let hoverHysteresis: CGFloat = 14
    private var hovering = false
    private var hoverLayerCache: [Int: (layer: Int?, at: Date)] = [:]
    private var cardScale: Double = 1.0
    private var cardScaleAnchorCenter: CGPoint?
    private var cardScaleAnchorTop: CGPoint?
    private var cardScaleDragging = false
    private var cardScaleThrottleTimer: Timer?
    private var pendingCardScale: Double?
    private var collapseTimer: Timer?
    private var dragWindowActive = false
    private var dragWindowOrigin: CGPoint = .zero
    private var dragWindowSize: CGSize = .zero
    private var dragCardRect: CGRect = .zero
    private var dragPageTopLeft: CGPoint = .zero
    private var dragScaleGeneration = 0
    private var dragScaleInFlight = false
    private var dragScaleWatchdog: DispatchWorkItem?
    /// 拖动缩放的「帧序号」：chrome 只允许**朝新方向**摆。
    ///
    /// ⚠️ 网页的回调是异步的，watchdog 又会在 0.12s 后自己补一帧 ——
    /// 早先那一帧的回调晚到时，会拿**旧矩形**把图钉/玻璃摆回去，
    /// 用户看到的就是「缩放时图钉闪一下、跟卡片/标题不同步」。
    private var dragChromeSerial = 0
    private var appliedChromeSerial = -1
    private var settingsCanvasHeld = false
    private var containerView: NSView?
    private var webHost: NSView?

    /// 第一张网页快照（或兜底超时）到手前，窗口保持完全透明，
    /// 避免启动时原生占位卡和底下的网页层同时可见。
    private var hasPresentedCard = false
    private var revealFallback: DispatchWorkItem?

    /// 模式 B：网页没能加载出来，已经改用原生卡片顶上
    private var liveFallbackActive = false

    // MARK: - 生命周期

    /// macOS 26 起，激活策略必须在「初始焦点链」建立之前设置，
    /// 否则 NSStatusItem 会创建成功却不会出现在菜单栏里。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
    }

    /// 装一套最小主菜单。
    ///
    /// LSUIElement（后台）App 默认没有主菜单，而 Cmd+C / Cmd+V / Cmd+Z
    /// 这类快捷键是靠主菜单里的「编辑」项派发的 —— 没有主菜单，
    /// 编辑器里的文本框就没法复制粘贴。
    ///
    /// 菜单栏不显示（accessory 策略），但快捷键依然有效。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单（accessory App 不显示，但留着不影响）
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⌘Q 也走 quitApp —— 直接 terminate 会绕过退出确认框。
        appMenu.addItem(withTitle: "退出桌面课表",
                        action: #selector(quitApp),
                        keyEquivalent: "q")
            .target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // 编辑菜单：Cmd+C / Cmd+V / Cmd+Z / Cmd+A 走标准 responder chain
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        addMenuItem(editMenu, "撤销", "undo:", "z")
        addMenuItem(editMenu, "重做", "redo:", "Z")
        editMenu.addItem(.separator())
        addMenuItem(editMenu, "剪切", "cut:", "x")
        addMenuItem(editMenu, "拷贝", "copy:", "c")
        addMenuItem(editMenu, "粘贴", "paste:", "v")
        addMenuItem(editMenu, "全选", "selectAll:", "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    /// 往菜单里加一项（动作走 responder chain，target 留空）。
    private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: String, _ key: String) {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
        item.target = nil            // nil = first responder
        menu.addItem(item)
    }

    static let t0 = Date()
    private func mark(_ label: String) {
        NSLog("[TT-TIMING] %@ +%.0fms", label, Date().timeIntervalSince(Self.t0) * 1000)
    }

    /// 自检用：焦点闭环模式（`--verify-focus-flow`）。
    ///
    /// 焦点能不能恢复，取决于 app 是不是**真·前台 app**、窗口是不是真的拿到了 key。
    /// 这些只有跑在真正的 AppKit 事件循环里才验得出来 ——
    /// 手动 `RunLoop.run` 顶出来的进程永远拿不到激活权（`isActive` 恒为 false），
    /// 那样的断言是「永远为真的假断言」。
    ///
    /// 所以这个模式是给 `open -n` 启动用的：app 经 LaunchServices 正常起来，
    /// 事件循环由系统驱动，激活请求才处理得了。
    var focusVerificationMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        mark("didFinishLaunching进入")
        // 系统权限弹框期间：课表保持可见（每笔保持都有超时兜底）。
        // 弹框出现 / 消失都重算一次悬停，不用等鼠标动。
        PermissionPromptWatch.onStateChanged = { [weak self] _ in
            self?.updateHover(force: true)
        }
        installCancelEditingObserver()
        // 弹窗（设置面板 / 对话框 / 菜单）统一以**课表卡片中心**为锚点。
        installWindowAnchor()
        // 焦点自检：只做最小准备。
        //
        // 不能走完整启动流程 —— 完整流程会建菜单栏图标、装全局鼠标监听、
        // 清理通知中心的待发通知：自检进程不该往用户系统里塞东西。
        // 焦点要验的东西（设置面板、差异页）这两个都不需要。
        if focusVerificationMode {
            prepareForImportVerification()
            return
        }
        // 后台代理会被系统的自动终止回收，卡片就消失了 —— 明确关掉。
        ProcessInfo.processInfo.disableAutomaticTermination("桌面课表运行中")
        NSApp.appearance = NSAppearance(named: .darkAqua)

        mark("迁移数据前")
        AppPaths.migrateLegacyDataIfNeeded()
        reloadData()
        mark("读数据后")
        // 默认停在「本周」；今天不在学期内时退化为「全部周次」。
        viewWeek = currentWeek()

        buildDesktopWindow()
        mark("建桌面窗口后")
        buildStatusItem()
        mark("建菜单栏后")
        buildSettingsController()
        mark("建设置控制器后")
        installHoverMonitor()
        startRefreshTimer()
        // ⚠️ 诊断开关：`DT_WEATHER_PROBE=1` → 启动后自动走一遍**真实**天气链路
        // （真定位 + 真网络），把坐标和结果打进统一日志。
        // 用来回答「授权给了、坐标拿到了，天气为什么还是没有」这类问题。
        // ⚠️ 诊断开关：`DT_OPEN_DAY=3` → 启动后自动打开第 3 列的覆盖层
        // （自检 / 出图用，避免依赖鼠标点击）。
        if let dayStr = ProcessInfo.processInfo.environment["DT_OPEN_DAY"],
           let day = Int(dayStr) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.dayPanel?.open(day: day)
            }
        }
        // 诊断开关：`DT_FLICKER_DIAG=1` → 打开网页侧的「覆盖层重建 / 外观变化」探针。
        //
        // 用户报「点完成之后一直闪」——现象只在**真实合成器 + 真实提醒事项**里出现，
        // 自检（无合成器）复现不出来。打开这个开关之后，网页每真正重建一次覆盖层、
        // 每次外观变化都会写一条统一日志：
        //   log show --last 10m --info --predicate 'subsystem == "com.desktoptimetable.diag"'
        // 时间线里能直接看出「是不是原生在反复推送」。
        if ProcessInfo.processInfo.environment["DT_FLICKER_DIAG"] == "1" {
            for delay in [2.0, 6.0, 20.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.webRenderer?.webView.evaluateJavaScript(
                        "if (window.__ttEnablePanelTrace) window.__ttEnablePanelTrace();")
                }
            }
        }
        // 排查用：`DT_OPEN_SETTINGS=1` → 启动 1.5 秒后自动开一次设置面板，
        // 再看第 2 次是不是落在同一处（复现「第一次开在左下角」）。
        if ProcessInfo.processInfo.environment["DT_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.settingsController.closeForTest()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.openSettings()
                    }
                }
            }
        }
        // 前台 App 变了 → 我们的设置 / 弹窗跟着抬起或放下（2026-11-10）。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in
            WindowLevelPolicy.syncWithFrontmostApp()
        }
        WindowLevelPolicy.syncWithFrontmostApp()
        if ProcessInfo.processInfo.environment["DT_WEATHER_PROBE"] == "1" {
            // ⚠️ **必须用 `open` 启动**（走 LaunchServices，拿到 bundle id → TCC 才认）。
            // 直接跑二进制的话，系统认为「你还没授权」，探针必然拿不到坐标。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runWeatherProbe()
            }
        }
        // 清理上次遗留的测试通知（`dt.test.*`）。
        cleanupLeftoverTestNotifications()
        // 前台也要显示横幅 / 声音（默认前台不显示，用户会以为通知没来）。
        if !AutomationMode.isCurrentProcessAutomation {
            UNUserNotificationCenter.current().delegate = self
        }
        // 睡眠唤醒后补足 14 天窗口 —— 睡一觉醒来，窗口可能已经空了。
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSystemWake()
        }
        // ⚠️ **显示器单独唤醒**也要处理（2026-11-11，用户原话：
        // 「刚打开显示屏的时候……时间晚了 1 分钟、没显示正在上课」）。
        //
        // 笔记本合盖 / 手动关屏时，**系统不一定睡眠**，只是**显示器睡了**。
        // 这时发的是 `screensDidWake`（不是 `didWake`）——
        // 只监听 `didWake` 就会漏掉这个场景。
        //
        // 两种唤醒的共同点：**WebKit 挂起了网页的定时器**（`setInterval` 不再触发），
        // 原生 `Timer` 也停。醒来后两边都要等下一个 10 秒档才恢复，
        // 这中间卡片顶部显示的是**睡着前那一帧的旧值**。
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSystemWake()
        }

        // 调试：DT_CLICK="x,y" 启动后自动点一下该坐标，用于验证点击转发链路
        if let spec = ProcessInfo.processInfo.environment["DT_CLICK"] {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, let r = self.webRenderer else { return }
                    let pt = NSPoint(x: parts[0], y: parts[1])
                    NSLog("[DesktopTimetable] 模拟点击 %@", NSStringFromPoint(pt))
                    r.forwardClick(at: pt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { r.snapshot() }
                }
            }
        }
        startPulseTimer()

        mark("showCard前")
        // 主线程心跳：每 10ms 记一次，事后看哪一段被阻塞了
        var lastBeat = Date()
        let beat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = Date()
            let gap = now.timeIntervalSince(lastBeat) * 1000
            lastBeat = now
            if gap > 40 {
                NSLog("[TT-BEAT] 阻塞 %.0fms @ +%.0fms", gap, now.timeIntervalSince(Self.t0) * 1000)
            }
        }
        RunLoop.main.add(beat, forMode: .common)
        showCard()
        mark("showCard后")
        showDataErrorIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false          // 关设置面板不退出
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showCard()
        return true
    }

    /// `desktoptimetable://settings`
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.host == "settings" || url.path.contains("settings") {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        pulseTimer?.invalidate()
        // 窗口位置与固定状态要跨启动保留 —— 退出时写一次盘。
        // （`quitApp` 里也写过一次，这里是兜底：别的退出路径不走 `quitApp`。）
        saveWindowState()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
            self.screenWakeObserver = nil
        }
        // 注意：**不**清空待发通知 —— 退出后系统仍会按时投递已排好的提醒。
    }

    /// 切回前台：检查通知权限 / 登录项状态，并补排。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AutomationMode.isCurrentProcessAutomation else { return }
        // 「在访达中显示」时面板让过路（降层 + 收起）—— 用户切回来就摆回浮层。
        // 纯界面层状态，没有副作用，所以放在自动化护栏前面。
        settingsController?.restoreFinderRevealIfNeeded()
        refreshReminderSchedule()
        // 设置面板开着的话，权限可能刚在系统设置里被改过 —— 只刷状态行。
        settingsController?.refreshReminderStatusRows()
    }

    // MARK: - 离屏渲染（`--render-card`）

    /// 不进入 AppKit 事件循环，准备好数据与卡片（供离屏渲染用）。
    func prepareForRendering() {
        PermissionPromptWatch.onStateChanged = { [weak self] _ in
            self?.updateHover(force: true)
        }
        // 自检也要能验「Esc 取消」这条链路（和正式启动一样装上观察者）。
        installCancelEditingObserver()
        mark("迁移数据前")
        AppPaths.migrateLegacyDataIfNeeded()
        reloadData()
        mark("读数据后")
        viewWeek = currentWeek()
        buildDesktopWindow()
        applyCardState()
        // 把状态推给网页 —— 否则网页里是空表格（离屏渲染 / 自检都需要这一步）。
        refreshCard()
    }

    /// 自检用：准备卡片 + 设置面板。
    ///
    /// 比 `applicationDidFinishLaunching` 少做三件事：不建菜单栏图标、
    /// 不注册登录项、不请求通知权限 —— 自检进程不该往用户系统里塞东西。
    func prepareForImportVerification() {
        prepareForRendering()
        buildSettingsController()
    }

    /// 把卡片离屏画成 PNG。
    @discardableResult
    func renderCard(to path: String) -> Bool {
        guard let card else { return false }
        let size = card.bounds.size
        let scale: CGFloat = 2
        let pixelW = Int(size.width * scale)
        let pixelH = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelW, pixelsHigh: pixelH,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        // 毛玻璃在离屏渲染里没有桌面可模糊，先铺一层深色底
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        card.needsDisplay = true
        card.layoutSubtreeIfNeeded()
        card.displayIgnoringOpacity(card.bounds, in: ctx)
        // 图钉是**独立控件**（挂在容器上），卡片自绘里没有它 ——
        // 离屏渲染要手动补上，否则出的图看不到图钉。
        //
        // 卡片和容器同原点同尺寸，所以图钉的 frame 坐标可以直接用；
        // 但 `displayIgnoringOpacity` 画在视图**原点**，得自己平移。
        if let pin = interaction?.pinButton {
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: pin.frame.minX, y: pin.frame.minY)
            pin.displayIgnoringOpacity(pin.bounds, in: ctx)
            ctx.cgContext.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("已渲染 \(path)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            return true
        } catch {
            FileHandle.standardError.write(Data("渲染失败：\(error.localizedDescription)\n".utf8))
            return false
        }
    }

    // MARK: - 数据

    private func reloadData() {
        // 阶段 3：先保证有课表（旧数据自动迁移成第一份），再读当前课表。
        ensureTimetableExists()

        // 数据换了 → 网页必须重画。
        //
        // 以前 `refreshCard()` 只在「跨分钟」或 `webNeedsRefresh` 时才推状态给网页，
        // 而切课表 / 新建课表这条路径**没设**这个标记 —— 同一分钟内切换的话，
        // 桌面卡片还显示旧课表，要等到下一分钟才刷新。
        webNeedsRefresh = true

        appSettings = settingsStore.load()
        config = appSettings.appearance.asAppearanceConfig
        // 自定义作息要在**读课程 / 排提醒 / 画卡片之前**生效 ——
        // 后面的时间文案、提醒时间都是从这张表推出来的。
        Schedule.applyPeriodTimes(appSettings.periods.times)

        guard let repo = repository else {
            // 空课表状态：没有任何课表
            courses = []
            overrides = []
            semester = SemesterConfig(start: Date(), maxWeek: Schedule.defaultMaxWeek)
            semesterStart = semester.start
            maxWeek = Schedule.defaultMaxWeek
            dataErrorMessage = nil
            // 没有任何课表 → 本应用的待发通知必须清空，否则旧课表的通知还会响。
            refreshReminderSchedule()
            return
        }

        let loaded = repo.load()
        courses = loaded.courses
        overrides = loaded.overrides
        semester = loaded.semester
        semesterStart = loaded.semester.start
        maxWeek = loaded.semester.effectiveMaxWeek(for: loaded.courses)
        if let err = loaded.error {
            NSLog("[DesktopTimetable] 课表数据读取失败：%@", err)
            dataErrorMessage = err
        } else {
            dataErrorMessage = nil
        }
        for n in loaded.notices { NSLog("[DesktopTimetable] %@", n) }
        for a in loaded.anomalies { NSLog("[DesktopTimetable] 数据异常：%@", a) }

        // 切课表后把浏览周次夹回合法范围。
        // 以前 viewWeek 只在启动时设一次，换一份课表不管周数多少都不动 ——
        // 16 周的课表切过来时还停在「第 18 周」，界面上有、课表里没有。
        clampViewWeek()

        // 数据变了（导入 / 编辑 / 覆盖 / 切课表 / 改学期）→ 通知计划也跟着变。
        // 指纹去重，没变的话内部直接跳过，不会反复删了重排。
        refreshReminderSchedule()
    }

    // MARK: - 上课提醒

    /// 重新规划并排程上课提醒。
    ///
    /// 幂等：内部按指纹去重，数据没变就什么都不做。
    /// 自动化模式（自检 / 导入 / 离屏渲染 / 测试）直接返回，
    /// **绝不**请求权限、绝不发送真实通知。
    func refreshReminderSchedule() {
        guard !AutomationMode.isCurrentProcessAutomation else { return }

        appSettings = settingsStore.load()

        // 关闭提醒 / 删了当前课表 / 课表为空 → 清空本应用待发通知。
        guard appSettings.reminder.enabled, repository != nil, !courses.isEmpty else {
            reminderScheduler.clearAll()
            return
        }

        let now = Date()
        let detailed = ClassReminderPlanner.planDetailed(
            courses: courses,
            overrides: overrides,
            semesterStart: semesterStart,
            maxWeek: maxWeek,                       // 已含 effectiveMaxWeek（数据里最大周次）
            leadMinutes: appSettings.reminder.leadMinutes,
            now: now)
        if detailed.droppedCount > 0 {
            // 不静默截断：超上限就记日志（系统上限 64，本应用硬上限 60）。
            NSLog("[DesktopTimetable] 提醒计划超出上限，丢弃 %d 条（保留最早的 %d 条）",
                  detailed.droppedCount, ClassReminderPlanner.maxPlans)
        }

        let fingerprint = ClassReminderScheduler.fingerprint(
            timetableID: timetableStore.activeID ?? "none",
            courses: courses,
            overrides: overrides,
            semesterStart: semesterStart,
            maxWeek: maxWeek,
            enabled: appSettings.reminder.enabled,
            leadMinutes: appSettings.reminder.leadMinutes,
            now: now)

        lastReminderDay = WeekMath.calendar.startOfDay(for: now)
        reminderScheduler.reschedule(plans: detailed.plans, fingerprint: fingerprint)
    }

    /// 启动时清理遗留的 `dt.test.*` 测试通知。
    ///
    /// 上次点「发送测试提醒」后 app 被关掉，那条 5 秒后的通知还挂在系统里，
    /// 会在之后莫名其妙弹出来。
    private func cleanupLeftoverTestNotifications() {
        reminderScheduler.cleanupTestNotifications()
    }

    /// 把 viewWeek 夹回 `1...maxWeek`；超出就回到当前周。
    private func clampViewWeek() {
        let clamped = TimetableState.clampedViewWeek(viewWeek, maxWeek: maxWeek,
                                                     currentWeek: currentWeek())
        if clamped != viewWeek { viewWeek = clamped }
    }

    /// 确保至少有一份课表存在。
    ///
    /// 首次启动时把旧版的 `schedule_data.json` / `semester.json`
    /// 迁移成第一份课表；之后每次启动都只是确认一下，不做重复迁移。
    private func ensureTimetableExists() {
        if let migrated = try? timetableStore.migrateLegacyIfNeeded(defaultName: "我的课表") {
            NSLog("[DesktopTimetable] 旧版课表数据已迁移为第一份课表：%@", migrated.name)
        }
        if timetableStore.activeID == nil {
            let metas = timetableStore.allMetas()
            if let first = metas.first {
                try? timetableStore.setActive(first.id)
            }
        }
    }

    /// 数据读取失败时给用户一次明确提示（不静默变成空课表）。
    private func showDataErrorIfNeeded() {
        guard let err = dataErrorMessage, !didShowDataError else { return }
        didShowDataError = true
        DispatchQueue.main.async {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "课表数据读取失败",
                message: err + "\n\n桌面课表暂时显示上一次能读到的内容。",
                confirmTitle: "好",
                showsCancel: false))
        }
    }

    // MARK: - 桌面窗口

    func buildDesktopWindow() {
            // 常驻画布：窗口永远按「最大档卡片 + 四周留白」建，卡片在画布里居中缩放。
            TimetableLayout.configureCanvas(maxScale: CGFloat(CardScalePolicy.currentMaxScale()))
            let rect = NSRect(x: 0, y: 0,
                              width: TimetableLayout.windowWidth,
                              height: TimetableLayout.windowHeight)
            window = DesktopWindow(contentRect: rect)

            // 容器：毛玻璃背景（NSVisualEffectView）+ 卡片自绘层
            // 实验模式 B：容器换成 LiveContainerView —— 卡片以外的 90pt 边距
            // 一律不接管命中测试，点击直接穿透到桌面 / 下层窗口。
            let container: NSView
            if isLiveMode {
                let live = LiveContainerView(frame: rect)
                live.passthroughRect = TimetableLayout.cardRect
                container = live
            } else {
                container = NSView(frame: rect)
            }
            container.wantsLayer = true
            container.layer?.backgroundColor = .clear
            containerView = container
            webHost = container

            // CSS: backdrop-filter: blur(30px) saturate(165%)
            let glass = NSVisualEffectView(frame: TimetableLayout.cardRect)
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            // 调试用：DT_GLASS=sidebar|menu|popover|under|content|within  DT_LEVEL=normal
            if let m = ProcessInfo.processInfo.environment["DT_GLASS"] {
                switch m {
                case "sidebar": glass.material = .sidebar
                case "menu": glass.material = .menu
                case "popover": glass.material = .popover
                case "under": glass.material = .underWindowBackground
                case "content": glass.material = .contentBackground
                case "titlebar": glass.material = .titlebar
                default: break
                }
                if m == "within" { glass.blendingMode = .withinWindow }
            }
            glass.state = .active
            if ProcessInfo.processInfo.environment["DT_NOGLASS"] != nil { glass.isHidden = true }
            // 卡片底色现在画在网页层的羽化层上（.card 自身透明），
            // 毛玻璃层的直角边会露出来 —— 必须 layer-backed 后圆角才真正生效。
            glass.wantsLayer = true
            glass.layer?.cornerRadius = TimetableLayout.cardRadius
            glass.layer?.masksToBounds = true
            glassView = glass
            container.addSubview(glass)

            // 网页渲染器：加载 App 内置的旧版界面（Resources/Timetable.html），
            // 渲染成快照后贴到桌面层窗口上。
            mark("建WebView前")
            let renderer = WebCardRenderer(frame: rect)
            if ProcessInfo.processInfo.environment["DT_NOWEB"] != nil { renderer.skipPageLoad() }
            mark("建WebView后")
            webRenderer = renderer
            // 图钉视觉由网页画：把两张图交给渲染器（页面就绪后它会自己注入）。
            if let hollow = Self.pinHollowBase64, let solid = Self.pinSolidBase64 {
                renderer.setPinImages(hollow: hollow, solid: solid)
            }
            renderer.setPinned(isPinned)
            // ⚠️ **文本输入链路**（2026-11-08 修「添加待办打不了字」）。
            //
            // 桌面层窗口是 `.nonactivatingPanel`，永远拿不到 key → WKWebView 收不到按键。
            // 网页里的输入框聚焦时发 `textInputFocus` → 这里把窗口临时切成
            // 「能成为 key + first responder 交给 webView」，失焦 / 回车 / Esc 再还原。
            // 重建 AppDelegate 时这条线整段丢了：输入框能点开、但一个字都打不进去。
            window.textInputTarget = renderer.webView
            renderer.onTextInputModeChanged = { [weak self] active in
                guard let self else { return }
                self.window?.setTextInputMode(active)
                self.installTextInputKeyMonitor(active)
            }
            window.acceptsMouseMovedEvents = true
            renderer.onSnapshot = { [weak self] image in
                guard let self, let image else { return }
                NSLog("[TT-TIMING] 第一张快照到手 +%.0fms", Date().timeIntervalSince(Self.t0) * 1000)
                self.card?.webSnapshot = image
                self.card?.needsDisplay = true
                // 快照到手 = 原生卡片不再显示 = 原生呼吸圈画不出来了。
                // 这时候还留着 24fps 定时器就是纯浪费（每帧一次画不出东西的重绘），
                // 必须停掉。呼吸圈由网页自己的 CSS 动画负责。
                self.stopPulseTimer()
                // 网页版画面就绪，这时候才把窗口亮出来
                self.revealCard()
                // 自动化交互测试（A 模式：快照管线）
                if LiveTestHarness.isLiveTestEnabled {
                    LiveTestHarness.runSnapshotMode(app: self, renderer: renderer, window: self.window)
                }
            }
            renderer.onIntent = { [weak self] action, payload in
                self?.handleWebIntent(action, payload)
            }
            renderer.onHoverChanged = { [weak self] in
                self?.webRenderer?.snapshot()
            }
            // 菜单开着 / 关掉的桥接（2026-11 修「右键时课表淡掉、覆盖层闪一下」）。
            //
            // 菜单是 1×1 的浮动面板 + NSMenu，弹出后指针一定在卡片之外 ——
            // 不告诉网页「菜单开着」，网页会把日期覆盖层收走；
            // 不给自己一段宽限期，课表会在菜单关掉的瞬间淡到 22%。
            MenuPresenter.onMenuVisibilityChanged = { [weak self] showing in
                guard let self else { return }
                if !showing {
                    self.menuGraceUntil = Date().addingTimeInterval(Self.menuGraceSec)
                }
                self.webRenderer?.webView.evaluateJavaScript(
                    "if (window.ttDayPanelMenuOpen) window.ttDayPanelMenuOpen(\(showing));")
                self.updateHover(force: true)
            }
            container.addSubview(renderer.webView)

            // 实验模式 B：网页直接上屏，不需要卡片盖在上面。
            if isLiveMode {
                renderer.onLiveReady = { [weak self] in
                    guard let self else { return }
                    NSLog("[TT-LIVE] 网页加载完成，准备渐显")
                    // 网页（重新）加载完 → 图钉图片要重新注入一次。
                    self.webPinImagesSent = false
                    self.installWebPinImagesIfNeeded()
                    // 等一帧再亮：网页刚 load 完的那一帧可能还没画出来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.revealCard()
                    }
                    // 如果之前已经因为失败/超时切到原生卡片了，网页这时候才姗姗来迟，
                    // 就把原生卡片收回去，让网页接手（窗口已经是亮的，不用再渐显）
                    if self.liveFallbackActive {
                        self.liveFallbackActive = false
                        self.card?.isHidden = true
                        NSLog("[TT-LIVE] 网页随后加载成功，收回原生卡片，改由网页显示")
                    }
                    // 自动化交互测试（DT_LIVE_TEST=1）
                    if LiveTestHarness.isLiveTestEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            LiveTestHarness.run(app: self, renderer: renderer, window: self.window)
                        }
                    }
                }
                // 网页加载失败：把原生卡片放出来顶替，别亮一个空白窗口
                renderer.onLiveFailed = { [weak self] reason in
                    guard let self else { return }
                    self.applyLiveFallback(reason: reason)
                }
                // 原生毛玻璃按网页 .card 的真实矩形铺，避免底部露出一条裸玻璃边。
                let webHeight = renderer.webView.bounds.height
                renderer.onLiveCardFrame = { [weak self] rect in
                    guard let self, let glass = self.glassView else { return }
                    let frame = NSRect(x: rect.minX,
                                       y: webHeight - rect.maxY,
                                       width: rect.width, height: rect.height)
                    if glass.frame != frame { glass.frame = frame }
                }
                NSLog("[TT-LIVE] 模式 B 生效：WKWebView 直接上屏，不取快照")
            }

            card = TimetableCardView(frame: rect)
            card.autoresizingMask = [.width, .height]
            // 实验模式 B：原生卡片完全不参与显示与交互，
            // 网页自己上屏、自己处理点击/悬停。
            if isLiveMode {
                card.isHidden = true
            }
            card.onOpenSettings = { [weak self] in self?.openSettings() }
            card.onWeekChange = { [weak self] week in
                self?.viewWeek = week
                self?.refreshCard()
            }
            card.onSelectCourse = { [weak self] course in
                self?.card?.selectedCourse = course
            }
            card.usesWebRenderer = true
            card.onPointerEvent = { [weak self] point, isClick in
                guard let self, let renderer = self.webRenderer else { return }
                if isClick {
                    renderer.forwardClick(at: point)
                    // 点击后网页会重绘（浮层淡入等），分几次取快照，
                    // 保证最后贴到屏幕上的一定是点击后的画面。
                    for delay in [0.05, 0.18, 0.40] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            renderer.snapshot()
                        }
                    }
                } else {
                    renderer.forwardHover(at: point)
                }
            }
            // A 模式（快照贴图）：网页收不到右键事件，由原生自己做命中测试
            // （复用 TimetableLayout 网格几何，与网页 CSS 网格同一套像素规范）。
            card.onRightClick = { [weak self] point, hit in
                guard let self, let hit else { return }
                self.showNativeMenu(day: hit.day, block: hit.block, viewPoint: point)
            }
            // 自动化测试：记录菜单内容，不真的弹模态菜单（会把测试进程卡住）
            if LiveTestHarness.isLiveTestEnabled {
                MenuPresenter.suppressPresentation = true
                MenuPresenter.onMenuBuilt = { [weak self] menu in
                    self?.testLastMenuTitles = menu.items.map { $0.title }
                }
            }

            // 右键编辑调度器：与设置面板共用同一个 repository，
            // 保存后由 onCoursesChanged 触发重新读盘 + 刷新卡片。
            editorController = ScheduleEditorController(repositoryProvider: { [weak self] in
                self?.repository
            })
            editorController.viewWeek = viewWeek
            editorController.onCoursesChanged = { [weak self] in
                guard let self else { return }
                self.reloadData()
                self.webNeedsRefresh = true
                self.refreshCard()
            }
            editorController.onOpenSettings = { [weak self] in
                self?.openSettings()
            }
            editorController.onImportSchedule = { [weak self] in
                self?.performImport()
            }
            // 「查看详情」：B 模式（网页上屏）用网页里已有的详情浮层，
            // A 模式（贴的是静态快照）用原生详情窗口。
            editorController.onShowDetail = { [weak self] course in
                guard let self else { return }
                if self.isLiveMode {
                    self.webRenderer?.selectCourse(day: course.day, block: course.block,
                                                   courseID: course.courseID)
                } else {
                    self.editorController.presentNativeDetail(course)
                }
            }
            container.addSubview(card)

            // 交互层：拖动 / 点击 / 图钉（必须盖在画面层之上、且在
            // 卡片以外的边距上不拦截 —— 由 `LiveContainerView.hitTest` 决定）。
            let interaction = CardInteractionView(frame: rect)
            interaction.autoresizingMask = [.width, .height]
            interaction.onDragTo = { [weak self] origin in
                self?.dragWindow(to: origin)
            }
            interaction.onDragEnd = { [weak self] in
                self?.saveWindowState()
            }
            interaction.onClick = { [weak self] point in
                self?.forwardClickToCard(at: point)
            }
            // 右键：网页里的 `contextmenu`（待办菜单 / 课程菜单）要靠这条线。
            interaction.onRightClick = { [weak self] point in
                guard let self, self.isLiveMode else { return }
                self.webRenderer?.forwardContextMenu(at: point)
            }
            interaction.pinButton.onToggle = { [weak self] pinned in
                self?.setPinned(pinned)
            }
            interaction.setPinTitle(cardTitle)
            // 图钉的**视觉**由网页画（和标题同一套缩放）；原生这层只留热区。
            interaction.pinButton.drawsInWeb = true
            container.addSubview(interaction)
            self.interaction = interaction

            window.contentView = container
            // 层级对齐旧版 Übersicht 画布：普通窗口之下、桌面之上。
            // 之前放在桌面图标层（-2147483602），会被任何全屏窗口盖住而完全点不到。
            window.level = NSWindow.Level(rawValue: -1)
            if ProcessInfo.processInfo.environment["DT_LEVEL"] == "normal" { window.level = .normal }
            window.setContentSize(rect.size)
            // ---- 启动接线（1.3.1–1.4.2 重建补齐，见 docs/archive/2026-11-08）----
            //
            // ⚠️ 这几步在重建 AppDelegate 时整块丢了，症状各不相同：
            //   · 不恢复 `appearance.cardScale` → 重启后卡片回到 100%，
            //     而且网页没有那段「居中 translate」，卡片比玻璃偏 (74, 61.5)，
            //     画布上边缘那 23pt 的箭头位置直接落在命中矩形之外（点不动）；
            //   · 不建 `DayPanelController` → 点表头日期 / 待办 / 菜单全都没反应；
            //   · 不接 `WindowAnchor` → 设置面板 / 对话框跑到屏幕正中；
            //   · 不恢复窗口位置 → 重启后课表回到默认位置。
            performCardScale(Double(appSettings.appearance.cardScale), interactive: false)
            restoreWindowState()
            buildDayPanelController()
            installWindowAnchor()
            mark("窗口就位")
        }

    // MARK: - 启动接线（日期覆盖层 / 窗口锚点）

    /// 建「日期覆盖层」的原生控制器，并把它的回调接到网页。
    ///
    /// ⚠️ **重建时整块丢了**（2026-11-08）：`dayPanel` 一直是 nil，
    /// 于是网页发来的 `datePanelOpen` / `todo*` 意图全被 `dayPanel?.handle`
    /// 静默吞掉 —— 点表头日期什么都不发生，自检 `--verify-day-panel-click`
    /// 也看到「换列推送 0 次」。
    private func buildDayPanelController() {
        guard dayPanel == nil else { return }
        // 「当前浏览周」的周一 = 学期开始 + (week-1)*7 —— 和网页端
        // `Timetable.js` 的 `weekMonday()` 同一套算法，两边必须一致，
        // 否则翻到第 8 周点周三，覆盖层显示的却是别的周。
        let panelWeek = viewWeek ?? currentWeek() ?? 1
        let monday = Self.mondayOf(week: panelWeek, semesterStart: semesterStart)
        // ⚠️ `--verify-todo-focus`：临时目录里 `dayPanel.enabled` 默认 false →
        // `loadContent` 直接返回、根本不查待办 → 「输入时间时待办不能消失」
        // 永远是 0 → 0（空转）。这里**只在内存里**打开开关（不写盘），
        // 好让 `EmptyEventKitStore(seededTodos:)` 那条假待办真的显示出来（2026-11-09）。
        var panelSettings = appSettings.dayPanel
        if focusVerificationMode,
           ProcessInfo.processInfo.environment["DT_FOCUS_REPORT"] != nil {
            panelSettings.enabled = true
        }
        // ⚠️ **天气数据源必须在这里注入**（2026-11 修「天气永远没有数据」）。
        //
        // 以前生产路径没传 `weatherProvider:` → `DayPanelController.loadWeather`
        // 直接 return → 设置里开着「显示天气」也永远拿不到天气。
        // 自动化模式下 `OpenMeteoWeatherProvider` 不建 `CLLocationManager`，
        // 所以自检不会弹授权框、也不会联网。
        let weatherProvider = OpenMeteoWeatherProvider()
        let controller = DayPanelController(
            settings: panelSettings,
            festivalProvider: DayPanelFestivalProviderFactory.make(
                weatherProvider: weatherProvider),
            todayIndex: WeekMath.todayIndex(Date()),
            baseMonday: monday,
            weatherProvider: weatherProvider)
        controller.onStateChange = { [weak self] payload in
            self?.pushDayPanelState(payload)
        }
        controller.onAuthorizationChange = { [weak self] in
            self?.settingsController?.refreshDayPanelRows()
        }
        // 「添加 / 修改待办」的结果要回报给网页（失败时网页显示原因）。
        controller.onTodoAddResult = { [weak self] payload in
            guard let json = Self.jsonString(payload) else { return }
            self?.webRenderer?.webView.evaluateJavaScript(
                "if (window.ttDayPanelTodoAddResult) window.ttDayPanelTodoAddResult(\(json));")
        }
        controller.onTodoUpdateResult = { [weak self] payload in
            guard let json = Self.jsonString(payload) else { return }
            self?.webRenderer?.webView.evaluateJavaScript(
                "if (window.ttDayPanelTodoUpdateResult) window.ttDayPanelTodoUpdateResult(\(json));")
        }
        dayPanel = controller
        // 设置面板要能改「接入开关 / 清单」。
        settingsController?.dayPanelController = controller
        settingsController?.refreshDayPanelRows()
    }

    /// 把「当前浏览周」同步给日期覆盖层（翻周 / 切「全部周次」时调）。
    ///
    /// 覆盖层的 7 个日期是按 `baseMonday` 算出来的；不跟着 `viewWeek` 走的话，
    /// 翻到第 2 周再点周三，面板里显示的还是第 1 周那天的待办 / 日程。
    private func syncDayPanelWeek() {
        guard let dayPanel else { return }
        let week = viewWeek ?? currentWeek() ?? 1
        let monday = Self.mondayOf(week: week, semesterStart: semesterStart)
        dayPanel.updateBrowsingWeek(baseMonday: monday, allWeeks: viewWeek == nil)
    }

    /// 所有后续窗口（设置面板 / 对话框 / 编辑器）都摆在**课表卡片中心**。
    ///
    /// ⚠️ 重建时这段只写在 `applicationDidFinishLaunching` 里，自检（走
    /// `prepareForRendering`）和重建后的窗口构建都不经过那条路 ——
    /// 面板就退回 `WindowAnchor` 的默认值（屏幕正中），
    /// 用户看到的是「课表拖到左下角，设置面板还在屏幕中间」。
    /// 规则（2026-11-10 补）：
    ///   · **从设置面板里弹出来的窗口** → 跟着**设置面板**居中
    ///     （以前一律跟着课表走：课表折叠时，写日记的窗口会出现在折叠条的中间，很怪）；
    ///   · 其它情况 → 仍然以**课表卡片中心**为锚点。
    private func installWindowAnchor() {
        WindowAnchor.provider = { [weak self] in
            guard let self else { return .zero }
            if let settings = self.settingsController,
               let w = settings.window, w.isVisible, w.isKeyWindow {
                return NSPoint(x: w.frame.midX, y: w.frame.midY)
            }
            guard let window = self.window else { return .zero }
            let r = window.convertToScreen(TimetableLayout.cardRect)
            return NSPoint(x: r.midX, y: r.midY)
        }
    }

    // MARK: - 图钉 / 拖动 / 位置记忆

    /// 恢复上次的窗口位置与固定状态。
    ///
    /// 首次启动没有记录 → 用现有的默认位置（`moveToDefaultPosition`）。
    /// 有记录 → 摆回上次的原点，并**夹回可见区**（换了个分辨率 / 拔掉了外接屏
    /// 之后，记住的位置可能已经在屏幕外面了）。
    private func restoreWindowState() {
        let state = pinStore.load()
        isPinned = state.pinned
        if let origin = state.origin {
            window.move(to: origin, onScreenContaining: origin)
        } else {
            window.moveToDefaultPosition()
        }
        window.isPinned = isPinned
        interaction?.setPinned(isPinned)
        NSLog("[DesktopTimetable] 恢复窗口状态：固定=%@ 位置=%@",
              isPinned ? "是" : "否",
              state.origin.map { NSStringFromPoint($0) } ?? "默认")
    }

    /// 保存当前的窗口位置与固定状态。
    private func saveWindowState() {
        guard let window else { return }
        let state = TimetablePinState(pinned: isPinned, origin: window.frame.origin)
        pinStore.save(state)
    }

    /// 图钉被点击：切换固定状态。
    ///
    /// 固定 → 位置立刻锁住（拖动无效）；解锁 → 恢复可拖动。
    /// 固定状态立刻写盘（重启后要还原）。
    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        window?.isPinned = pinned
        interaction?.setPinned(pinned)
        webRenderer?.setPinned(pinned)
        // 顺便把完整状态再推一次：网页里那份 `pinned` 万一没收到刚才那次
        // 单向调用，会在下一次渲染时被快照纠正过来。
        webNeedsRefresh = true
        refreshCard()
        saveWindowState()
        NSLog("[DesktopTimetable] 图钉切换：%@", pinned ? "已固定" : "已解锁")
    }

    /// 把课表窗口拖到指定原点（拖动回调）。
    ///
    /// - Parameter origin: 目标原点（屏幕坐标系）—— 交互层给的是**绝对值**。
    private func dragWindow(to origin: NSPoint) {
        guard !isPinned, let window else { return }
        // 拖动课表时**强制收起覆盖层** ——
        // 拖动和看详情是两件互斥的事：一边拖窗口、一边浮着个面板，
        // 两层叠着谁也看不清。
        closeDayPanel()
        // 夹回屏幕可见区：窗口不能整个拖出屏幕。
        // 用**目标位置所在的那块屏**来夹 —— 多屏拖动时该跟着目标屏走。
        window.move(to: origin, onScreenContaining: origin)
    }

    /// 收起日期覆盖层（原生 + 网页两边都要收）。


    /// 交互层转交回来的「没拖动的点击」→ 交给画面层。
    ///
    /// 模式 B（网页上屏）：转给网页渲染器（和现在点课程 / 点齿轮的路径一致）。
    /// 模式 A（快照贴图）：转给原生卡片视图（自己画的那一套）。
    private func forwardClickToCard(at point: NSPoint) {
        if isLiveMode {
            webRenderer?.forwardClick(at: point)
        } else {
            card?.onPointerEvent?(point, true)
        }
    }

    /// 自检用：课表窗口当前的中心（屏幕坐标）。
    var testTimetableCenter: NSPoint {
        window?.cardCenterOnScreen ?? .zero
    }

    /// 自检用：课表当前是否已固定。
    var testIsPinned: Bool { isPinned }

    /// 自检用：交互层（图钉 + 拖动）。
    var testInteraction: CardInteractionView? { interaction }

    /// 自检用：桌面窗口本身（派发真事件用）。
    var testDesktopWindow: NSWindow? { window }

    /// 自检用：切到固定 / 解锁（走和点图钉一样的路径）。
    /// 自检用：点一下**网页里**的图钉（视觉和点击都在网页层）。
    func testClickWebPin() {
        let before = isPinned
        // 用**和 `forwardClick` 完全一样**的派发方式：真实点击走的是
        // `el.dispatchEvent(new MouseEvent('click', …))`，不是 `HTMLElement.click()`。
        //
        // ⚠️ 偶发失败：`evaluateJavaScript` 偶尔会被 WebKit 丢掉（不报错也不执行，
        // 就是前几轮修过的那个「推了不执行」）。这里重试几次 —— 自检要的是
        // 「这条链路通不通」，不是「第一次 eval 有没有被吞」。
        let js = """
        (function () {
          var p = document.querySelector('.ttlpin');
          if (p) p.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          return 'ok';
        })();
        """
        for attempt in 0..<3 {
            webRenderer?.webView.evaluateJavaScript(js, completionHandler: nil)
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                if isPinned != before { break }
            }
            if isPinned != before { break }
            if attempt < 2 { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if isPinned == before, ProcessInfo.processInfo.environment["DT_PIN_DIAG"] != nil {
            var info = "nil"
            webRenderer?.evaluateForTest("""
            (function () {
              var p = document.querySelector('.ttlpin');
              var l = window.__ttLastPost;
              if (p) { p.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); }
              var l2 = window.__ttLastPost;
              return JSON.stringify({ hasPin: !!p, src: p ? String(p.getAttribute('src') || '').length : -1,
                                      cls: p ? p.className : '', last: l ? l.action : null,
                                      afterDispatch: l2 ? l2.action : null,
                                      connected: p ? p.isConnected : null,
                                      n: document.querySelectorAll('.ttlpin').length });
            })();
            """) { info = $0 ?? "nil" }
            for _ in 0..<80 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if info != "nil" { break }
            }
            NSLog("[TT-PIN] 点网页图钉没变化：before=%d now=%d web=%@", before ? 1 : 0, isPinned ? 1 : 0, info)
        }
    }

    func testSetPinned(_ pinned: Bool) {
        interaction?.pinButton.isPinned = pinned
        setPinned(pinned)
    }

    /// 自检用：拖动课表窗口（走和真拖动一样的路径）。
    ///
    /// - Parameter delta: 相对位移（模拟鼠标移动了多少）。
    func testDragWindow(by delta: CGSize) {
        guard let window else { return }
        dragWindow(to: NSPoint(x: window.frame.origin.x + delta.width,
                               y: window.frame.origin.y + delta.height))
    }

    /// 自检用：把课表窗口摆到指定原点（并夹回可见区）。
    func testMoveWindow(to origin: NSPoint) {
        window?.move(to: origin, onScreenContaining: origin)
        saveWindowState()
    }

    /// 自检用：课表窗口当前的原点（屏幕坐标）。
    var testWindowOrigin: NSPoint { window?.frame.origin ?? .zero }

    /// 自检用：模拟「屏幕 / 系统唤醒」（2026-11-11）。
    ///
    /// 用户原话：「刚打开显示屏的时候正在上课但是课表上没有显示我正在上课
    /// 而且时间晚了 1 分钟」——
    /// 根因是屏幕睡着时 WebKit 挂起了网页的定时器，醒来后卡片顶部
    /// 停在睡着前那一帧。唤醒时必须主动重画一次。
    ///
    /// 自检里用这条路径验证「唤醒 → 卡片顶部被重画」。
    func testSimulateWake() {
        handleSystemWake()
    }

    /// 自检用：唤醒这条路径被调用过几次。
    private(set) var testWakeCount = 0

    /// 自检用：日期覆盖层的状态。
    var testDayPanelState: (open: Bool, day: Int?) {
        dayPanel?.testState ?? (false, nil)
    }

    /// 自检用：模拟点某一列的日期（打开覆盖层）。
    func testOpenDayPanel(day: Int) {
        dayPanel?.open(day: day)
    }

    /// 自检用：日期覆盖层的控制器。
    var testDayPanel: DayPanelController? { dayPanel }

    /// 自检用：课表**卡片**是不是**完整落在屏幕可见区里**。
    ///
    /// 「拖动时不能完全拖出屏幕」这条验收标准就是靠它验的。
    ///
    /// 注意验的是**卡片**而不是窗口框 —— 窗口框四周留了 90pt 投影留白，
    /// 比屏幕还高，永远不可能「完整可见」；用户看到的是卡片。
    var testWindowFullyVisible: Bool {
        guard let window else { return false }
        let f = window.cardFrameOnScreen
        let vf = (TimetablePinState.screen(forPoint: NSPoint(x: f.midX, y: f.midY))
                    ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return f.minX >= vf.minX - 0.5 && f.maxX <= vf.maxX + 0.5
            && f.minY >= vf.minY - 0.5 && f.maxY <= vf.maxY + 0.5
    }



    /// 把卡片渐显出来（第一张快照就绪或兜底超时）。
    /// 在这之前窗口 alpha 一直是 0 —— 启动时不会出现
    /// 「原生占位卡 + 底下透出的网页」两层错位的画面。


    /// 模式 B：网页没能显示出来（加载失败 / 超时），改用原生卡片顶替。
    ///
    /// 模式 B 下原生卡片默认是隐藏的（网页直接上屏），
    /// 这里把它放出来：窗口里至少是一张完整可用的原生课表，而不是空白。
    ///
    /// - Parameter timeout: true = 超时兜底，false = 网页明确加载失败。
    ///   两种情况日志分开写，方便事后分辨是哪种问题。


    /// 网页加载失败兜底：超时还没拿到快照就显示原生卡片。
    private func scheduleRevealFallback() {
        revealFallback?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.hasPresentedCard else { return }
            if self.isLiveMode {
                // 模式 B：网页没按时到，把原生卡片放出来顶上，
                // 而不是把一个空白窗口亮出来。
                self.applyLiveFallback(reason: "加载超时", timeout: true)
            } else {
                NSLog("[DesktopTimetable] 首张快照超时，回退到原生绘制")
            }
            self.revealCard()
        }
        revealFallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }



    /// 卡片标题 / 副标题。
    ///
    /// 阶段 3 引入多课表后，这里会改成读「当前课表」的 name / subtitle
    /// （迁移时把旧文案作为第一份课表的默认值）。
    ///
    /// 卡片标题 —— 读当前课表的 name。
    /// 没有课表时用中性默认值，不写死个人姓名。
    private var cardTitle: String {
        let name = currentTimetable?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "本周课表" : name
    }

    /// 卡片副标题 —— 读当前课表的 subtitle。
    private var cardSubtitle: String {
        currentTimetable?.subtitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 推给网页的状态快照（网页只做展示，不保存业务状态）。
    ///
    /// 具体拼装见 `TimetableState.webJSON(title:subtitle:)` —— 抽成纯函数是为了能单测：
    /// 周次字段一旦推成字符串，网页会当成「没选周次」，表现为永远显示「全部周次」
    /// 且左右箭头点了没反应。这个回归必须由单元测试挡住。
    private func webStateJSON() -> String {
        webStateObjectJSON()
    }

    /// 网页状态的**字典**版本（日期覆盖层要往里合并字段）。


    /// 网页状态的 JSON 字符串版本。
    private func webStateObjectJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: webStateObject(), options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"courses\":[]}"
        }
        return json
    }

    /// 把日期覆盖层的状态推给网页。
    ///
    /// 走的是和课表状态**同一条**推送通道（`ttUpdate`）——
    /// 网页只认一个状态入口，多开一条会让两边状态不同步。
    private func pushDayPanelState(_ payload: [String: Any]) {
        guard let renderer = webRenderer else { return }
        // ⚠️ 诊断：对比 payload 的 dayFestivals 与 webStateObject() 的（查 +1 错位）。
        if ProcessInfo.processInfo.environment["DT_DEBUG_WEATHER"] == "1" {
            func desc(_ v: Any?) -> String {
                guard let dict = v as? [String: Any] else { return "nil" }
                var parts: [String] = []
                for k in dict.keys.sorted() {
                    let one = dict[k] as? [String: Any]
                    parts.append("\(k)=\(one?["lunar"] as? String ?? "?")")
                }
                return parts.joined(separator: " ")
            }
            let stateFest = webStateObject()["dayFestivals"]
            DiagLog.info("天气：payload.dayFestivals = \(desc(payload["dayFestivals"]))")
            DiagLog.info("天气：webState.dayFestivals = \(desc(stateFest))")
        }
        // 合并进完整状态里再推 —— 不能只推 dayPanel，
        // 否则网页会把课表状态整个丢掉（课程、学期、周次全没了）。
        var merged = webStateObject()
        for (k, v) in payload { merged[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        renderer.update(stateJSON: json)
    }

    /// 某一教学周的周一（和网页端 `weekMonday()` 同一套算法）。
    static func mondayOf(week: Int, semesterStart: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let base = cal.startOfDay(for: semesterStart)
        return cal.date(byAdding: .day, value: (week - 1) * 7, to: base) ?? base
    }

    /// 网页发来的用户意图
    private func handleWebIntent(_ action: String, _ payload: Any?) {
        if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
            NSLog("[DesktopTimetable] 收到网页意图 %@ payload=%@", action, String(describing: payload))
        }
        // ⚠️ **待办右键菜单不归 DayPanelController**（2026-11-09 修「右键没菜单」）：
        // 网页发的是 `todoMenu`，前缀 `todo*` 会被下面那条「交给 DayPanelController」
        // 吞掉，而控制器不认这个动作 → 菜单永远出不来（用户：「右键删除恢复取消
        // 是不是还没恢复」）。这里先截走，交给 App 自己弹 NSMenu。
        if action == "todoMenu" {
            handleTodoMenuIntent(payload)
            return
        }
        // 日记的右键菜单同理：`diaryMenu` 不能让 `diary*` 前缀把它送进
        // DayPanelController（那边不认这个动作，菜单永远出不来）。
        if action == "diaryMenu" {
            handleDiaryMenuIntent(payload)
            return
        }
        // 日期覆盖层的 intent（datePanelOpen / datePanelToggle / …）
        // 单独交给 DayPanelController 处理。
        if action.hasPrefix("datePanel") || action.hasPrefix("todo") || action.hasPrefix("diary") {
            dayPanel?.handle(action: action, payload: payload)
            return
        }
        switch action {
        case "textInputFocus":
            // 网页里的输入框拿到焦点 → 进入文本输入模式（临时 key + first responder）。
            if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                DiagLog.info("[TT-MODE] focus 请求进入（当前 active=\(webRenderer?.testTextInputActive ?? false)）")
            }
            webRenderer?.setTextInputMode(true)
        case "textInputBlur":
            if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                DiagLog.info("[TT-MODE] blur 请求退出（当前 active=\(webRenderer?.testTextInputActive ?? false)）")
            }
            webRenderer?.setTextInputMode(false)
        case "panelRect":
            handleWebPanelRect(payload)
        case "panelTrace":
            // 诊断（`DT_FLICKER_DIAG=1`）：网页每真正重建一次覆盖层就报一条。
            // 用户报「点完成之后一直闪」——这里能看出是谁在驱动重画。
            if let d = payload as? [String: Any] {
                DiagLog.info("覆盖层重建 n=\(d["n"] ?? "?") day=\(d["day"] ?? "?") "
                             + "待办=\(d["todos"] ?? "?") 卡片=\(d["cards"] ?? "?") "
                             + "pending=\(d["pending"] ?? "") "
                             + "变了=\(d["changed"] ?? "(首次)")")
            }
        case "panelLook":
            // 诊断：覆盖层的 class / 高度 / 实心区高度 / 透明度 / 滚动位置变了。
            if let d = payload as? [String: Any] {
                DiagLog.info("覆盖层外观 \(d["look"] ?? "")")
            }
        case "pinToggle":
            // 网页里图钉被点到（视觉和点击都在网页层，原生只切状态）。
            //
            // ⚠️ **以原生为准，别信网页报的 `pinned`**（2026-11 修「点了没反应」）：
            // 网页那份状态是异步同步的，万一没跟上，按 payload 设成同一个值
            // 就等于「点了没反应」。这里无条件切一次，再把结果推回网页。
            setPinned(!isPinned)
        case "week":
            let delta = (payload as? Int) ?? 0
            shiftViewWeek(by: delta)
        case "toggleAllWeeks":
            webNeedsRefresh = true
            viewWeek = viewWeek == nil ? currentWeek() : nil
            syncDayPanelWeek()
            refreshCard()
        case "weekCurrent":
            webNeedsRefresh = true
            viewWeek = currentWeek()
            syncDayPanelWeek()
            refreshCard()
        case "openSettings":
            openSettings()
        case "toggleCollapse":
            // 状态条右侧的折叠按钮（无 payload）；
            // 折叠态点表头会带 day 过来 —— 展开完顺手打开那一列的覆盖层。
            let day = (payload as? [String: Any])?["day"] as? Int
            toggleCollapse(openDay: day)
        case "contextmenu":
            // 右键：网页用 DOM 命中测试算出 day/block/courseID 回传。
            // 原生按同样的数据弹菜单（不依赖当前 NSEvent —— 后台 App 里它可能是 nil）。
            handleContextMenuIntent(payload)

        default:
            break
        }
    }

    /// 测试用：当前课程（内存副本）。
    var testCourses: [Course] { courses }

    /// 测试用：打开某门课的编辑器，返回编辑器控制器。
    @discardableResult
    func testOpenEditor(courseID: String) -> CourseEditorWindowController? {
        editorController.testOpenEditor(courseID: courseID)
    }

    /// 测试用：拿到右键编辑器控制器（走保存流程用）。
    var testEditorController: ScheduleEditorController? { editorController }

    /// 自动化测试用：模拟点击菜单里的第 N 项。
    func testSelectMenuItem(_ index: Int) {
        guard let menu = MenuPresenter.lastMenu, menu.items.indices.contains(index) else { return }
        let item = menu.items[index]
        if let sub = item.submenu, sub.items.indices.contains(0) {
            let sub0 = sub.items[0]
            if let a = sub0.action, let t = sub0.target {
                NSApp.sendAction(a, to: t, from: sub0)
            }
            return
        }
        if let action = item.action, let target = item.target {
            NSApp.sendAction(action, to: target, from: item)
        }
    }

    /// 自动化测试用：打开设置面板（对照组）。
    func testOpenSettings() {
        openSettings()
    }

    /// 测试用：关掉设置面板。
    func testCloseSettings() {
        settingsController.closeForTest()
    }

    /// 测试用：当前编辑器。
    var testEditor: CourseEditorWindowController? { editorController.testEditor }

    /// 测试用：原生命中测试（视图坐标 → 格子）。
    func testSlotHit(at point: NSPoint) -> (day: Int, block: Int)? {
        guard let hit = card?.slotHit(at: point) else { return nil }
        return (hit.day, hit.block)
    }

    /// 网页发来的右键意图 → 弹菜单。
    private func handleContextMenuIntent(_ payload: Any?) {
        guard let dict = payload as? [String: Any] else { return }
        let day = (dict["day"] as? NSNumber)?.intValue ?? dict["day"] as? Int
        let block = (dict["block"] as? NSNumber)?.intValue ?? dict["block"] as? Int
        let courseID = dict["courseID"] as? String

        // 只有落在网格格子里的右键才有菜单内容（空白格 → 新增课程…）
        guard let day, let block, (1...7).contains(day), (0...TimetableState.maxBlock).contains(block) else {
            return
        }

        // 弹出位置：网页坐标 → 窗口坐标 → 屏幕坐标。
        // 网页的 clientY 从上往下，原生从下往上，要翻一次。
        var screenPoint = NSEvent.mouseLocation
        if let x = (dict["x"] as? NSNumber)?.doubleValue,
           let y = (dict["y"] as? NSNumber)?.doubleValue,
           let renderer = webRenderer, let window {
            let height = renderer.webView.bounds.height
            let windowPoint = NSPoint(x: x, y: height - y)
            screenPoint = window.convertPoint(toScreen: windowPoint)
        }

        editorController.showMenu(day: day, block: block,
                                  courseID: courseID?.isEmpty == true ? nil : courseID,
                                  at: screenPoint)
    }

    /// 原生右键（A 模式）→ 弹菜单。
    ///
    /// 命中以网页 DOM 为准（A 模式屏幕上贴的就是网页快照），
    /// 原生几何只作为网页不可用时的兜底。
    private func showNativeMenu(day: Int, block: Int, viewPoint: NSPoint) {
        // 视图坐标 → 屏幕坐标
        var screenPoint = NSEvent.mouseLocation
        if let window, let card {
            let windowPoint = card.convert(viewPoint, to: nil)
            screenPoint = window.convertPoint(toScreen: windowPoint)
        }

        guard let renderer = webRenderer else {
            editorController.showMenu(day: day, block: block, courseID: nil, at: screenPoint)
            return
        }
        // 卡片视图坐标 → 网页视图坐标（两者都挂在同一个 container 上，
        // 但显式换算一次，别依赖「碰巧在同一位置」）
        let webPoint: NSPoint
        if let card {
            webPoint = card.convert(viewPoint, to: renderer.webView)
        } else {
            webPoint = viewPoint
        }
        renderer.hitTestInWeb(at: webPoint) { webDay, webBlock, webCID in
            guard let d = webDay, let b = webBlock,
                  (1...7).contains(d), (0...TimetableState.maxBlock).contains(b) else {
                // 网页问不到 → 用原生几何兜底
                self.editorController.showMenu(day: day, block: block, courseID: nil, at: screenPoint)
                return
            }
            self.editorController.showMenu(day: d, block: b, courseID: webCID, at: screenPoint)
        }
    }

    /// 翻周：全部周次时先回到本周，再逐周前后移动（与旧版一致）
    private func shiftViewWeek(by delta: Int) {
        webNeedsRefresh = true
        if viewWeek == nil {
            viewWeek = currentWeek() ?? (delta > 0 ? 1 : maxWeek)
        } else {
            let next = (viewWeek ?? 0) + delta
            if (1...maxWeek).contains(next) { viewWeek = next }
        }
        // 日期覆盖层跟着换周：覆盖层的日期是「当前浏览周」算出来的，
        // 不同步的话翻到第 2 周点周三，看到的还是第 1 周的待办。
        syncDayPanelWeek()
        // ⚠️ 这个函数是在网页的 `evaluateJavaScript`（点击转发）里被调用回来的，
        // 直接 `refreshCard()` 会**嵌套**一次 `evaluateJavaScript` —— WebKit 会把
        // 嵌套的那次吞掉（表现：第一次点头部箭头，周次不变；再点一次才生效）。
        // 推到下一个 runloop 再推状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.webNeedsRefresh = true
            self.refreshCard()
        }
    }

    /// 把当前数据写进卡片。离屏渲染（`--render-card`）也走这里，保证两边一致。
    func applyCardState() {
        let curWeek = currentWeek()
        card.titleText = cardTitle
        card.subtitleText = cardSubtitle
        card.config = config
        card.state = TimetableState(courses: courses,
                                    semesterStart: semesterStart,
                                    currentWeek: curWeek,
                                    viewWeek: viewWeek,
                                    now: Date(),
                                    maxWeek: maxWeek,
                                    overrides: overrides)
    }

    /// 当前数据快照（离屏渲染用）。
    func snapshot() -> (courses: [Course], semesterStart: Date, config: AppearanceConfig) {
        (courses, semesterStart, config)
    }

    private func currentWeek() -> Int? {
        let w = WeekMath.weekNumber(Date(), semesterStart: semesterStart)
        return (1...maxWeek).contains(w) ? w : nil
    }

    // MARK: - 渐隐

    private func installHoverMonitor() {
        // 桌面层窗口不是 key window，跟踪区域收不到 mouseMoved，
        // 所以用全局监控 + 自己算几何（和旧版 widget 的做法一致）。
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateHover()
        }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.updateHover()
            return e
        }
        // 诊断用（DT_LIVE_DIAG=1）：把按键事件到底进没进 App 打出来。
        // 只在显式设置该环境变量时安装，常规运行零开销。
        if isLiveMode && ProcessInfo.processInfo.environment["DT_LIVE_DIAG"] != nil {
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] e in
                guard let self, let w = self.window else { return e }
                let inWindow = w.convertPoint(fromScreen: e.locationInWindow)
                let hit = w.contentView?.hitTest(inWindow)
                NSLog("[TT-DIAG] %@ 到达App windowNumber=%@(本窗=%d) 忽略鼠标=%@ "
                    + "窗口坐标=(%.0f,%.0f) 命中=%@ 卡片内=%@",
                      String(describing: e.type), String(describing: e.windowNumber),
                      w.windowNumber,
                      w.ignoresMouseEvents ? "是" : "否",
                      inWindow.x, inWindow.y,
                      hit.map { String(describing: type(of: $0)) } ?? "nil",
                      TimetableLayout.cardRect.contains(inWindow) ? "是" : "否")
                return e
            }
        }
    }

    /// 实验模式 B：把指针位置同步给网页（实验性方案）。
    ///
    /// 桌面层窗口不是 key window，即使 `acceptsMouseMovedEvents = true`，
    /// 网页也不一定能收到 mouseMoved —— CSS 的 :hover 伪类因此不触发。
    /// 这里沿用现有的全局鼠标监控，自己算坐标，再调用网页里的
    /// `window.ttLiveHover(x, y)`（CSS 像素，原点左上）。
    ///
    /// 标注：**实验性**。合成事件不会驱动 CSS 伪类，
    /// 所以网页侧是用 `.tt-hover` 类手动模拟悬停态。
    /// 指针是不是落在「本 App 的其它窗口」上（设置面板 / 弹窗 / 对话框）。
    ///
    /// 抽成**静态纯函数**是为了能单测：`syncLiveHover` 依赖真实鼠标和 live 模式，
    /// 在测试里没法稳定构造。这里只做几何 + 可见性判断。
    static func pointer(_ point: NSPoint,
                        isOverOwnWindowOtherThan card: NSWindow?,
                        in windows: [NSWindow] = NSApp.windows) -> Bool {
        windows.contains { other in
            other !== card && other.isVisible && other.frame.contains(point)
        }
    }

    private func syncLiveHover() {
        guard let renderer = webRenderer, renderer.liveMode, let window else { return }
        // 自检可以用 `testHoverProbe` 代替真实指针（否则断言取决于鼠标当时在哪）。
        let screen = testHoverProbe?.pointer ?? NSEvent.mouseLocation

        // ⚠️ **指针在我们自己的其它窗口上时，不要驱动课表的悬停**（2026-11-10 修）。
        //
        // 用户原话：「点开设置之后蹦出来的窗口，我的鼠标在这个窗口上移动，
        // 但是课表上还是会有对应的显示……课表上的日历也会生出来，并在不同列切换」。
        //
        // 根因：设置面板 / 弹窗是**盖在卡片矩形上面**的，指针落在那上面时
        // 几何上仍然「在 cardRect 里」→ 下面这段照常把坐标转给网页 →
        // 网页按列跟着换。而窗口本身的可见性是另一条线（`updateHover` 里
        // 「本 App 其它窗口算 inside」），所以课表不会淡出 —— 两边对不上。
        //
        // 现在：指针在自家窗口（设置 / 弹窗 / 菜单）上 → **直接冻结**，
        // 既不推进 hover，也不发 clear（发 clear 会让面板淡出，用户要求「不消失」）。
        if MenuPresenter.isMenuShowing { return }
        if Self.pointer(screen, isOverOwnWindowOtherThan: window) { return }
        // 屏幕坐标 → 窗口坐标
        let inWindow = window.convertPoint(fromScreen: screen)
        // ⚠️ **日期覆盖层那一列也算「在课表上」**（2026-11 修「鼠标移到日历上日历就没了」）：
        // 折叠时面板从卡片底下伸出来，指针一进面板就落到 cardRect 之外 ——
        // 这里如果只认 cardRect，就会给网页发 clearLiveHover，
        // 网页当作「指针离开课表」→ 把面板淡出（用户看到「日历直接消失」）。
        let inPanel = dayPanelRectInWindow?.contains(inWindow) ?? false
        guard TimetableLayout.cardRect.contains(inWindow) || inPanel else {
            renderer.clearLiveHover()
            return
        }
        renderer.forwardLiveHover(at: inWindow)
    }



    private func animateFade(solid: Bool) {
        // 卡片还没露出（等首张快照）时，hover 只更新状态、不动 alpha；
        // 露出时 revealCard() 会按当时的 hovering 决定目标值。
        guard hasPresentedCard else { return }
        // 调试：DT_SOLID=1 时卡片始终不透明，方便截图核对
        if ProcessInfo.processInfo.environment["DT_SOLID"] == "1" {
            window.alphaValue = 1
            return
        }
        let target = CGFloat(solid ? config.maxOpacity : config.minOpacity)
        let duration = solid ? config.fadeInSec : config.fadeOutSec
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = max(0.01, duration)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            window.animator().alphaValue = target
        }
    }

    // MARK: - 设置面板

    private func buildSettingsController() {
        settingsController = SettingsWindowController(store: store,
                                                    timetableStore: timetableStore,
                                                    settingsStore: settingsStore,
                                                    reminderScheduler: reminderScheduler,
                                                    loginItems: loginItems) { [weak self] in
            self?.reloadData()
            self?.refreshCard()
            // 透明度类设置改完要立刻反映到窗口上，
            // 否则要等下一次 hover 状态变化才会生效。
            if let self {
                self.animateFade(solid: self.hovering)
            }
        }
        // 提醒开关 / 提前分钟变了 → 立刻重排（不等下一轮定时器）。
        settingsController.onPanelClosed = { [weak self] in
            self?.restoreAfterSettingsClose()
        }
        settingsController.onReminderSettingsChanged = { [weak self] in
            self?.refreshReminderSchedule()
        }
        // ⚠️ **另接一条「只认课表」的锚点取值器**（2026-11-11 修「第一次打开在左下角」）。
        //
        // `WindowAnchor.provider` 里有一条「设置面板是 key 时锚点取设置面板自己中心」
        // —— 那条是给**面板里弹出来的窗口**用的。
        // 面板**自己**的落点基准必须是**课表卡片中心**，否则就成了自己跟自己比
        // （`windowDidBecomeKey` 的兜底恒为 0 → 变成死代码）。
        //
        // 接在这里（而不是 `installWindowAnchor`）是因为那里调用时
        // `settingsController` 还是 nil —— 赋值会被 `?.` 悄悄跳过。
        settingsController.cardAnchorProvider = { [weak self] in
            guard let self, let window = self.window else { return nil }
            let r = window.convertToScreen(TimetableLayout.cardRect)
            return NSPoint(x: r.midX, y: r.midY)
        }
        settingsController.installHandlers()
        // ⚠️ **把「日期覆盖层」控制器交给设置面板**（2026-11-08 修）。
        //
        // `buildDayPanelController()` 是在 `buildDesktopWindow()` 里调的，那时
        // `settingsController` 还没建（本函数后建），所以那里那句
        // `settingsController?.dayPanelController = controller` 是**空操作** ——
        // 结果：设置里「日历与提醒事项接入」开关点了只改配置，
        // `dayPanelController?.requestAccess()` 是 nil 调用 → **系统授权框永远不出来**，
        // 状态行一直停在「正在读取」（用户：「点了接入待办事项…并没有弹出来窗口」）。
        if let dayPanel {
            settingsController.dayPanelController = dayPanel
            settingsController.refreshDayPanelRows()
        }
        // ⚠️ **设置面板「卡片大小」滑杆 → 桌面课表重排**（2026-11-08 修）。
        //
        // 重建 AppDelegate 时这条线断了：`onCardScaleChange` 只有声明、没有赋值，
        // 滑杆拖动只改了自己的值和配置，课表**一点不动**（用户：「放大缩小还没恢复」）。
        // 拖动中走 `persist: false`（实时预览、不写盘），松手 `persist: true`
        // （落到最终档 + 写盘）。
        settingsController.onCardScaleChange = { [weak self] value, persist in
            self?.applyCardScale(value, persist: persist)
        }
        settingsController.onImportRequested = { [weak self] in
            self?.performImport()
        }
        settingsController.onManageTimetables = { [weak self] in
            self?.openTimetableManager()
        }
        settingsController.onQuitRequested = { [weak self] in
            self?.quitApp()
        }
        // 课表集合变了（设置面板里新建 / 重命名 / 删除 / 应用切换）→
        // 立刻重读数据、重画桌面卡片、重建菜单栏，别等下一分钟。
        settingsController.onTimetablesChanged = { [weak self] in
            guard let self else { return }
            self.reloadData()
            self.refreshCard()
            self.settingsController.reload()
            self.rebuildTimetableMenu()
        }
        settingsController.updateTimetableSummary()
    }

    /// 退出整个 app。
    ///
    /// 菜单栏图标可能被 macOS 26 的系统白名单拦掉，用户找不到别的退出入口，
    /// 所以设置面板底部提供了「退出桌面课表」按钮走这里。
    ///
    /// 收尾顺序有讲究：
    ///   1. 先停定时器 —— 不然退出过程里还可能触发一次刷新；
    ///   2. 再关桌面窗口 —— 桌面卡片是 level=-1 的无边框窗，不主动关的话
    ///      terminate 那一瞬间会留在桌面上（尤其在快照模式下）；
    ///   3. 最后 terminate。
    @objc private func quitApp() {
        NSLog("[TT-QUIT] 请求退出，开始清场")
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopPulseTimer()
        // 退出前把窗口位置与固定状态写盘 —— 下次启动要还原。
        saveWindowState()
        window?.close()
        settingsController.closePanel()
        NSApp.terminate(nil)
    }

    private func openSettings() {
        // ⚠️ **打开设置前先把展开的日期覆盖层收回去**（2026-11-11 用户要求）。
        //
        // 用户原话：「点开了设置之后展开的日历面板自动收回去」。
        // 设置面板弹在卡片中心，覆盖层还展开在那一列上 —— 两者叠在一起。
        //
        // 原生把 `currentDay` 清掉并推一版 `dayPanelOpen: false`，
        // 网页收到后自己播 400ms 收起动画（`Timetable.js` 里已有这条处理）。
        if let state = dayPanel?.testState, state.open, let day = state.day {
            dayPanel?.close(day: day)
        }
        reloadData()
        refreshCard()
        // 面板以**课表卡片**为中心（不是鼠标位置）—— 弹在屏幕角落会跟课表脱节。
        settingsController.show(relativeTo: nil)
    }

    /// 仅供自动化测试用：关掉设置面板。
    func closeSettingsForTest() {
        settingsController.closeForTest()
    }

    /// 自检用：当前课表窗口 frame（排查「设置第一次开在左下角」）。
    var testWindowFrame: NSRect { window?.frame ?? .zero }
    /// 自检用：当前锚点。
    var testAnchorPoint: NSPoint { WindowAnchor.provider() }
    /// 自检用：设置窗口 frame。
    var testSettingsFrame: NSRect { settingsController?.window?.frame ?? .zero }

    // MARK: - 课程详情

    /// 关闭卡片内的详情浮层（点遮罩或关闭按钮）。
    func closeCourseSheet() {
        card.selectedCourse = nil
    }

    // MARK: - 菜单栏

    /// 菜单栏图标是否真的显示出来了。
    ///
    /// macOS 26 的「菜单栏 → 允许在菜单栏中显示」是系统级白名单：
    /// 没被允许时 `statusItem` 依然存在、button 也有 frame，但那个 frame 还在
    /// (0,0)，说明它从没被摆进菜单栏。
    var isStatusItemVisible: Bool {
        guard let button = statusItem?.button,
              let win = button.window else { return false }
        let frame = win.frame
        // 菜单栏在屏幕最顶端；按钮的窗口落在那儿才算真的摆进去了。
        // 被系统拦下时 button 存在，但窗口停在 (0,0) 附近，永远到不了顶部。
        // 被系统拦下时：窗口 frame 是 (0,0,38,0) —— 高度 0、位置在原点，
        // 也就是「创建了但从没摆进菜单栏」。
        guard frame.height > 0, frame.minX > 100 else { return false }
        return win.isVisible && frame.maxY > (NSScreen.main?.frame.maxY ?? 0) - 50
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "桌面课表")
            button.toolTip = "桌面课表"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "打开设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
            .target = self

        // 「课表」子菜单：当前课表打勾；切换；新建；导入；重命名；删除
        let timetableItem = NSMenuItem(title: "课表", action: nil, keyEquivalent: "")
        let timetableMenu = NSMenu(title: "课表")
        buildTimetableSubmenu(timetableMenu)
        timetableItem.submenu = timetableMenu
        menu.addItem(timetableItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "重新加载", action: #selector(menuReload), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "回到本周", action: #selector(menuCurrentWeek), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        // 退出走 quitApp（带确认框）—— 直接 terminate 会绕过确认。
        menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu

        // 启动后确认一次图标是否真的摆进菜单栏（macOS 26 可能拦掉）
        //
        // macOS 26 有个系统级白名单（「系统设置 → 菜单栏 → 允许在菜单栏中显示」）：
        // 没被允许时 `statusItem` 对象依然存在、button 也有 frame，
        // 但那个 frame 停在 (0,0)，从来没被摆进菜单栏 —— **屏幕上什么都没有**。
        //
        // 这个坑的表现特别难查：app 在跑、卡片也在桌面上，但用户找不到菜单栏图标，
        // 于是**没有任何办法右键/退出**，只能去终端 kill。
        // 所以这里必须主动检查并弹窗告诉用户怎么开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            // 先把裸数据打出来 —— 这个判断出过一次错：
            // 屏幕上明明没有图标，`isStatusItemVisible` 却返回 true，弹窗永远不出现。
            // 有了这三行才能在日志里看出「窗口到底在哪、可见不可见」。
            let win = self.statusItem?.button?.window
            NSLog("[TT-MENUBAR] frame=%@ isVisible=%@ screenMaxY=%.0f visible=%@",
                  win.map { NSStringFromRect($0.frame) } ?? "nil",
                  win.map { String($0.isVisible) } ?? "nil",
                  NSScreen.main?.frame.maxY ?? 0,
                  String(self.isStatusItemVisible))
            guard !self.isStatusItemVisible else { return }
            NSLog("[TT-MENUBAR] 状态栏图标没有摆进菜单栏（macOS 26 白名单拦下了），用户将无法退出")
            self.showStatusItemBlockedAlert()
        }
    }

    /// 状态栏图标被系统拦下时的提示。
    ///
    /// 说明「图标在哪」「怎么开」「还有别的办法退出」，别让用户以为 app 坏了。
    private func showStatusItemBlockedAlert() {
        // 这个 app 是 accessory（LSUIElement）应用，弹窗前要临时切成 regular 才显示得出来。
        // 用完切回 accessory —— 读 `NSApp.activationPolicy` 再传回去容易撞上类型推断问题。
        NSApp.setActivationPolicy(.regular)
        let outcome = AlertDialogController.show(.init(
            severity: .info,
            title: "菜单栏图标没有显示出来",
            message: """
            桌面课表在运行，课表卡片也在桌面上，但菜单栏图标被 macOS 26 拦下了
            （系统设置 → 菜单栏 → 「允许在菜单栏中显示」里没有勾选「桌面课表」）。

            打开那个设置并允许后，图标就会出现，可以右键退出。

            在此之前想退出，可以在「终端」里执行：
                pkill -f DesktopTimetable
            """,
            confirmTitle: "打开菜单栏设置",
            cancelTitle: "知道了"))
        if case .confirmed = outcome {
            // 直接跳到「菜单栏」设置面板
            if let url = URL(string: "x-apple.systempreferences:com.apple.Menuextra.settings") {
                NSWorkspace.shared.open(url)
            }
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func menuOpenSettings() { openSettings() }

    @objc private func menuImport() {
        performImport()
    }

    // MARK: - 课表（阶段 3）

    /// 导入课表的统一入口。
    ///
    /// 三个入口（设置面板 / 右键菜单 / 菜单栏）都走这里，
    /// 保证「新建 / 覆盖 / 取消」三选一的行为完全一致。
    func performImport() {
        // 同一时间只允许一个导入流程：重复点导入会同时存在两个决策控制器
        // 和两个差异页，回调互相覆盖（点「应用」写的是另一份数据）。
        guard importDecision == nil, diffWindowController == nil else {
            AlertDialogController.show(.init(
                severity: .info,
                title: "上一次导入还没结束",
                message: "请先处理完当前的导入窗口（应用或取消），再重新导入。",
                confirmTitle: "好",
                showsCancel: false))
            return
        }

        let panel = NSOpenPanel()
        var cts: [UTType] = [.json, .html]
        for ext in ["xls", "htm"] { if let t = UTType(filenameExtension: ext) { cts.append(t) } }
        panel.allowedContentTypes = cts
        // 面板默认落在「下载」文件夹（教务系统的导出一般都在那儿）。
        // 只设 directoryURL，不自己去列这个目录 —— app 直接读 ~/Downloads
        // 会触发 macOS 的「访问下载文件夹」授权弹窗，而 LSUIElement 的后台
        // app 弹不出这个框，主线程会卡在 open() 上。由系统文件面板自己读。
        let dl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if FileManager.default.fileExists(atPath: dl.path) { panel.directoryURL = dl }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择教务系统导出的课表文件（.xls）或课表 JSON"
        panel.prompt = "导入"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // ---- 解析 ----
            let parsed = try ScheduleImporter.parse(at: url)

            // ---- 校验 + 补全（写盘前的最后一道关）----
            //
            // 以前这里只有 `ScheduleImporter.groupedCourses(at:)` ——
            // 只解析 + 分组，**不校验、不补全、不提示异常**：
            // `block == 5` 的课能写进文件（卡片上永远看不见），
            // 空周次不补全，异常只 `NSLog` 一句用户看不到。
            // 现在和命令行 / 预览走同一份 `ImportValidator`。
            let normalized = try ImportValidator.normalize(parsed: parsed.records,
                                                          maxWeek: maxWeek)

            // ---- 异常 / 周次补全 / 解析提示 → 明确告诉用户，用户可以取消 ----
            guard presentImportWarnings(normalized, extraNotices: parsed.notices) else { return }

            // ---- 分组（courseID 分配）----
            let grouped = CourseGrouper.assignCourseIDs(normalized.courses).courses

            // 接线统一在 `makeImportDecision` 里（自检走的也是同一份）。
            let decision = makeImportDecision(parsed: grouped, fileName: url.lastPathComponent)
            importDecision = decision
            decision.start()
        } catch {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "导入失败",
                message: error.localizedDescription,
                confirmTitle: "好",
                showsCancel: false))
        }
    }

    /// 建一个导入决策控制器并接好所有回调。
    ///
    /// `performImport()` 与自检钩子走**同一份接线** —— 以前自检单独复制一份，
    /// 真实的生命周期 bug（控制器被释放）在自检里永远复现不出来。
    private func makeImportDecision(parsed: [Course], fileName: String) -> ImportDecisionController {
        let decision = ImportDecisionController(store: timetableStore,
                                               parsed: parsed,
                                               fileName: fileName)
        decision.onDecision = { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancel:
                break
            case .newTimetable, .overwriteCurrent:
                // 切换课表后，标题 / 副标题 / 周次 / 课程全部跟着刷新
                self.reloadData()
                self.refreshCard()
                self.settingsController?.reload()
                self.rebuildTimetableMenu()
            }
            // 差异页还开着时先别清 —— 应用成功那条路会走 `onFinished`。
            if self.diffWindowController == nil { self.finishImportFlow() }
        }
        decision.onShowDiff = { [weak self] current, diff, imported, importedSemester,
                                 initialChoice, onApply, onCancel in
            guard let self else { return }
            // 差异页拿到的是**决策控制器刚 load 出来的当前课表**，
            // 不是 AppDelegate 里可能过时的 `self.courses`。
            let win = TimetableDiffWindowController(current: current,
                                                   imported: imported,
                                                   diff: diff,
                                                   importedSemester: importedSemester,
                                                   initialChoice: initialChoice)
            // onApply 的返回值原样交给差异页：只有写盘成功它才关窗。
            win.onApply = { courses, semester in onApply(courses, semester) }
            win.onCancel = { onCancel() }
            win.onFinished = { [weak self] in self?.finishImportFlow() }
            self.diffWindowController = win
            win.show()
        }
        return decision
    }

    /// 导入流程收尾：清掉强引用，把焦点和数据还给设置面板。
    ///
    /// 差异页是独立浮窗（不是 sheet），AppKit 不会自动把 key window 还回去；
    /// 不显式恢复的话用户会觉得「设置面板所有按钮都不响应」。
    private func finishImportFlow() {
        diffWindowController = nil
        importDecision = nil
        settingsController?.restoreFocus()
    }

    /// 自检钩子：跳过文件面板和三选一弹窗，直接走「覆盖当前课表」这条分支。
    ///
    /// 返回差异页控制器（没走到差异页时为 nil）。接线与 `performImport()` 完全一致。
    func testStartOverwriteImport(
        parsed: [Course],
        fileName: String,
        protectedRemovalDecision: ((_ name: String, _ index: Int, _ total: Int)
                                   -> ImportDecisionController.ProtectedRemovalDecision)? = nil
    ) -> TimetableDiffWindowController? {
        let decision = makeImportDecision(parsed: parsed, fileName: fileName)
        // 自检不能弹真模态框；需要时由调用方注入「保留 / 删除」。
        decision.testProtectedRemovalDecision = protectedRemovalDecision
        importDecision = decision
        decision.startOverwrite()
        return diffWindowController
    }

    /// 自检用：当前有没有挂着的导入流程。
    var testHasImportFlow: Bool { importDecision != nil || diffWindowController != nil }

    /// 自检用：设置面板窗口（验证焦点是否恢复）。
    var testSettingsWindow: NSWindow? { settingsController?.window }

    /// 自检用：设置面板控制器（验证「按钮真的能点」）。
    var testSettingsController: SettingsWindowController? { settingsController }

    /// 把「数据异常」和「周次被补全」明确展示给用户。
    ///
    /// 以前这些信息只有 `NSLog` 一句，用户根本看不到 ——
    /// 于是「这 3 门课的周次被按全学期处理了」这种事只有他自己猜。
    ///
    /// - Parameters:
    ///   - result: 校验 + 补全的结果。
    ///   - extraNotices: 解析阶段的提示（例如教务系统表格里第 11–12 节的课没进来）。
    /// - Returns: true = 继续导入；false = 用户取消（**不写盘**）。
    private func presentImportWarnings(_ result: ImportValidator.Result,
                                       extraNotices: [String] = []) -> Bool {
        var parts: [String] = []
        if let text = ImportValidator.warningText(for: result) { parts.append(text) }
        parts.append(contentsOf: extraNotices)
        guard !parts.isEmpty else { return true }
        let outcome = AlertDialogController.show(.init(
            severity: .warning,
            title: "导入前有一些需要确认的地方",
            message: parts.joined(separator: "\n\n"),
            confirmTitle: "继续导入",
            cancelTitle: "取消"))
        if case .confirmed = outcome { return true }
        return false
    }

    // MARK: - 自检钩子

    /// 自检用：走一遍「课表集合变了」这条路径 ——
    /// 跟设置面板 `onTimetablesChanged` 回调里做的事完全一致。
    func testTimetablesChanged() {
        reloadData()
        refreshCard()
        rebuildTimetableMenu()
    }

    /// 打开课表管理面板。
    func openTimetableManager() {
        if timetableManager == nil {
            timetableManager = TimetableManagerController(store: timetableStore)
            timetableManager.onSwitch = { [weak self] _ in
                guard let self else { return }
                self.reloadData()
                self.refreshCard()
                self.settingsController.reload()
                self.rebuildTimetableMenu()
            }
            // 课表集合变了（尤其是**删掉最后一份**）→ 上层必须重新拉数据。
            // 以前删最后一份时 `next == nil`，`onSwitch` 不触发，
            // 卡片 / 设置面板 / 菜单栏就一直显示已删课表的内容。
            timetableManager.onTimetablesChanged = { [weak self] in
                guard let self else { return }
                self.reloadData()
                self.refreshCard()
                self.settingsController.reload()
                self.rebuildTimetableMenu()
            }
            timetableManager.onImport = { [weak self] in
                self?.performImport()
            }
        }
        timetableManager.show()
    }

    /// 重建菜单栏的「课表」子菜单（课表列表会变，所以每次切完都重建）。
    private func rebuildTimetableMenu() {
        // 渲染自检 / 无菜单栏时 `statusItem` 是 nil —— 直接返回，
        // 别对 IUO 取 `.menu`（会 SIGTRAP）。
        guard let statusItem, let menu = statusItem.menu else { return }
        // 找到「课表」子菜单项
        guard let item = menu.items.first(where: { $0.title == "课表" }),
              let sub = item.submenu else { return }
        sub.removeAllItems()
        buildTimetableSubmenu(sub)
    }

    /// 「课表」子菜单的内容：
    /// 当前课表打勾；列出所有课表可切换；新建课表…；导入课表…；重命名…；删除…；管理课表…
    private func buildTimetableSubmenu(_ sub: NSMenu) {
        let metas = timetableStore.allMetas()
        let active = timetableStore.activeID

        // ---- 当前课表 ----
        let current = metas.first { $0.id == active }
        let currentItem = NSMenuItem(title: "当前课表：\(current?.name ?? "无")",
                                     action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        sub.addItem(currentItem)
        sub.addItem(.separator())

        // ---- 切换 ----
        if metas.isEmpty {
            let none = NSMenuItem(title: "（还没有课表）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for m in metas {
                let item = NSMenuItem(title: m.name,
                                      action: #selector(menuSwitchTimetable(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = m.id
                item.state = (m.id == active) ? .on : .off
                sub.addItem(item)
            }
        }
        sub.addItem(.separator())

        // ---- 操作 ----
        sub.addItem(withTitle: "新建课表…",
                    action: #selector(menuNewTimetable),
                    keyEquivalent: "n").target = self
        sub.addItem(withTitle: "导入课表…",
                    action: #selector(menuImportTimetable),
                    keyEquivalent: "i").target = self
        sub.addItem(withTitle: "重命名…",
                    action: #selector(menuRenameTimetable),
                    keyEquivalent: "").target = self
        sub.addItem(withTitle: "删除…",
                    action: #selector(menuDeleteTimetable),
                    keyEquivalent: "").target = self
        sub.addItem(.separator())
        sub.addItem(withTitle: "管理课表…",
                    action: #selector(menuManageTimetables),
                    keyEquivalent: "").target = self
    }

    @objc private func menuSwitchTimetable(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try timetableStore.setActive(id)
            reloadData()
            refreshCard()
            settingsController.reload()
            rebuildTimetableMenu()
        } catch {
            presentSimpleError("切换课表失败：\(error.localizedDescription)")
        }
    }

    @objc private func menuNewTimetable() { openTimetableManager() }
    @objc private func menuManageTimetables() { openTimetableManager() }
    @objc private func menuImportTimetable() { performImport() }
    @objc private func menuRenameTimetable() { openTimetableManager() }
    @objc private func menuDeleteTimetable() { openTimetableManager() }

    private func presentSimpleError(_ message: String) {
        AlertDialogController.show(.init(
            severity: .warning,
            title: "操作失败",
            message: message,
            confirmTitle: "好",
            showsCancel: false))
    }

    @objc private func menuReload() {
        reloadData()
        refreshCard()
    }

    @objc private func menuCurrentWeek() {
        viewWeek = currentWeek()
        refreshCard()
    }

    // MARK: - 定时刷新

    /// 状态条上的呼吸圈动画（CSS 里是 2.4s 无限循环）。
    private func startPulseTimer() {
        // 实验模式 B：原生卡片不显示，呼吸圈由网页自己的 CSS 动画负责，
        // 不用再跑 24fps 的原生定时器。
        if isLiveMode {
            NSLog("[TT-LIVE] 模式 B：跳过原生呼吸圈定时器（网页 CSS 自带动画）")
            return
        }
        // 模式 A（快照管线）：原生呼吸圈**只在原生卡片还看得见的时候**要跑。
        //
        // 原生呼吸圈画在 TimetableCardView.draw() 里，而 draw() 第一行就是
        // `if webSnapshot != nil { return }` —— 快照到手之后，画面由
        // layer.contents 提供，原生那一圈根本画不出来。
        //
        // 但在**第一张快照到手之前**（A 模式起步那几秒，或快照超时回退到
        // 原生绘制时），显示的正是原生卡片，呼吸圈得动 —— 所以不能一刀切关掉。
        //
        // 因此改成：先跑起来，等第一张快照到了就停（见 onSnapshot 回调）。
        //
        // 实测：旧写法在 A 模式下让这个 24fps 定时器空转 —— 每帧
        // needsDisplay = true，触发画不出任何东西的重绘，主线程每 ~275ms
        // 阻塞一次（TT-BEAT 记 25 次，最大 301ms）。B 模式只有 1 次 88–92ms。
        //
        // 快照里的呼吸圈由网页自己的 CSS 动画（.pulse，2.4s）负责，不受影响。
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self, let card = self.card else { return }
            card.advancePulse(by: 1.0 / 24.0)
        }
        RunLoop.main.add(pulseTimer!, forMode: .common)
    }

    /// 呼吸圈定时器用完了就停。
    ///
    /// 第一张快照到手之后，原生卡片不再显示（画面走 layer.contents），
    /// 原生呼吸圈画不出来，24fps 定时器就变成了纯浪费 —— 每帧触发一次
    /// 画不出东西的重绘，主线程每 ~275ms 卡一次。
    private func stopPulseTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    /// 天气探针：真跑一次「取位置 → 查天气」，把每一步打进统一日志。
    ///
    /// 只在 `DT_WEATHER_PROBE=1` 时调用；**不改任何用户数据**。
    private func runWeatherProbe() {
        let provider = OpenMeteoWeatherProvider()
        DiagLog.info("天气探针：provider 授权状态=\(provider.authorizationStatus.rawValue) 定位服务开=\(CLLocationManager.locationServicesEnabled())")
        // ⚠️ **有城市名就走城市**（不碰定位）—— 这就是给后台程序准备的退路。
        let city = appSettings.dayPanel.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty {
            provider.resolveCity(city) { coord in
                guard let coord else {
                    DiagLog.info("天气探针：城市「\(city)」查不到坐标")
                    return
                }
                DiagLog.info("天气探针：城市「\(city)」→ \(coord.latitude), \(coord.longitude)")
                provider.fetchForecast(at: coord) { forecast in
                    for key in forecast.keys.sorted() {
                        let w = forecast[key]!
                        DiagLog.info("天气探针：\(key) \(w.text) 现在\(w.temperature.map { String(Int($0.rounded())) } ?? "-")° 最低\(w.min.map { String(Int($0.rounded())) } ?? "-")° 最高\(w.max.map { String(Int($0.rounded())) } ?? "-")°")
                    }
                }
            }
            return
        }
        provider.requestCurrentLocation { coord in
            guard let coord else {
                DiagLog.info("天气探针：拿不到坐标（授权状态=\(provider.authorizationStatus.rawValue)）")
                return
            }
            DiagLog.info("天气探针：坐标 \(coord.latitude), \(coord.longitude)")
            provider.fetchForecast { forecast in
                if forecast.isEmpty {
                    DiagLog.info("天气探针：没拿到预报")
                    return
                }
                // 按天打印（今天 / 未来 6 天）。
                for key in forecast.keys.sorted() {
                    let w = forecast[key]!
                    DiagLog.info("天气探针：\(key) \(w.text) 现在\(w.temperature.map { String(Int($0.rounded())) } ?? "-")° 最低\(w.min.map { String(Int($0.rounded())) } ?? "-")° 最高\(w.max.map { String(Int($0.rounded())) } ?? "-")°")
                }
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 分钟没变就不重绘，省电
            self.refreshCard()
            // 跨天（午夜）→ 补足 14 天窗口。
            // **不**放在每 10 秒的路径里反复删了重排：指纹没变就只是比一下字符串。
            let today = WeekMath.calendar.startOfDay(for: Date())
            if today != self.lastReminderDay {
                self.lastReminderDay = today
                // ⚠️ **日期覆盖层也要跨天**（2026-11）：`todayIndex` 要换一天，
                // 天气要按新的一天重新取（用户要求「每天过 12 点了就更新」）。
                // 睡眠唤醒后定时器会补跑，所以这里能兜住「睡过了午夜」。
                self.dayPanel?.handleDayChange()
                self.refreshReminderSchedule()
            }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }
    // MARK: - 卡片缩放 / 折叠（1.3.x–1.4.2 重建）

    func applyCardScale(_ value: Double, persist: Bool = true) {
            if persist {
                // 松手：立刻落到最终值 + 写盘。
                commitCardScale(value: value)
                return
            }
            cardScaleDragging = true
            pendingCardScale = value
            // 拖动开始时锁锚点（网页卡片中心，屏幕坐标）。
            if cardScaleAnchorCenter == nil {
                let current = currentWebCardCenterOnScreen()
                    ?? window?.cardCenterOnScreen ?? .zero
                cardScaleAnchorCenter = current
            }
            // 上一帧的网页缩放还没应用完 → 只更新 pending，等回调里继续。
            if dragScaleInFlight { return }
            applyNextDragFrame()
        }

    func applyCardScaleImmediately(_ value: Double) {
            dragScaleGeneration += 1
            dragScaleInFlight = false
            dragScaleWatchdog?.cancel()
            dragScaleWatchdog = nil
            pendingCardScale = nil
            dragWindowActive = false
            cardScaleThrottleTimer?.invalidate()
            cardScaleThrottleTimer = nil
            cardScaleDragging = false
            cardScaleAnchorCenter = nil       // 按当时的卡片中心重新锚定
            performCardScale(value, interactive: false)
        }

    func applyNextDragFrame() {
            guard let value = pendingCardScale else { return }
            pendingCardScale = nil
            let screen = window.flatMap { TimetablePinState.screen(forPoint: $0.cardCenterOnScreen) }
                ?? NSScreen.main
            let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let clamped = CardScalePolicy.clamp(value,
                                                visibleSize: vf.size,
                                                cardSize: TimetableLayout.baseCardSize)
            cardScale = clamped
            let s = CGFloat(clamped)
            // ⚠️ 锚点没锁（例如「松手」被重复调一次、或面板里点滑杆直接提交）
            // 就按**当前卡片中心**补一把 —— 否则下面会拿 (0,0) 去夹屏，
            // 窗口直接被拽到左下角（实测 -297,-102）。
            let lockedAnchor = cardScaleAnchorCenter
                ?? currentWebCardCenterOnScreen()
                ?? .zero

            // 拖动开始时把窗口一次性放到**最大档的尺寸/位置**，之后整个拖动期间
            // 窗口完全不动 —— 只改网页的 CSS transform（scale + translate）。
            //
            // 为什么：窗口服务器会把 `setFrameOrigin` 的小数**截断到整点**，
            // 每帧移动窗口就会让卡片中心在 ±0.5pt 里抖（100% 附近实测 1pt，
            // 肉眼就是「整个画面抖一下」）。窗口不动 + translate 补零头，
            // 内容可以落在任意小数上，中心就钉死了。
            if !dragWindowActive { enterDragWindow(anchor: lockedAnchor, visibleFrame: vf) }

            // ⚠️ 必须用**网页卡片的 CSS 基础矩形**（90,90,968,773），
            // 不能用 `lastCardLayoutRect` —— 常驻画布下网页用 body translate
            // 摆到画布中心，`lastCardLayoutRect` 里已经含了那段 translate，
            // 再拿它算 tx 会把 translate 算两遍，卡片中心直接偏 74pt。
            //
            // ⚠️ **折叠态用折叠后的版式高度**（173）：
            // 之前一律按 773 算，拖动帧把「玻璃 / 穿透 / 松手落点」都当成展开卡片，
            // 折叠→缩放→展开时顶边被算错 600pt，展开后整张卡片跑到画布上面
            // （用户：「缩放之后移动结果下半部分显示不出了」）。
            let collapsed = TimetableLayout.collapse > 0.5
            let layoutHeight: CGFloat = collapsed
                ? WebCardRenderer.webCardCSSHeight - WebCardRenderer.collapseBodyCSSHeight
                : WebCardRenderer.webCardCSSHeight
            let layout = NSRect(x: 90, y: 90, width: 968, height: layoutHeight)
            // ⚠️ 用**网页实测的卡片尺寸**夹（和松手时一致）——
            // 用 968/773 的话，实测卡片多出来那 7~8pt 会让松手时再夹一次、画面跳一下。
            let measured = webRenderer?.lastCardLayoutRect?.size
            let cardSize = CGSize(width: (measured?.width ?? layout.width) * s,
                                  height: layout.height * s)
            // 放大到边缘时把卡片夹回可见区，保证整张卡片都在屏幕里。
            //
            // 折叠态锁的是**顶边**（1.4.1）：卡片只有一条 173pt 高，按中心夹的话
            // 它会被摆到画布中间，展开时从中间往下长 → 底部超出画布被裁。
            let anchor: NSPoint
            if collapsed, let top = cardScaleAnchorTop {
                var topY = top.y
                if cardSize.height < vf.height {
                    topY = min(max(topY, vf.minY + cardSize.height), vf.maxY)
                } else {
                    topY = vf.midY + cardSize.height / 2
                }
                let clampedX = clampedCardCenter(NSPoint(x: top.x, y: topY),
                                                 cardSize: cardSize, in: vf).x
                anchor = NSPoint(x: clampedX, y: topY - cardSize.height / 2)
            } else {
                anchor = clampedCardCenter(lockedAnchor, cardSize: cardSize, in: vf)
            }
            // ⚠️ **窗口在拖动帧里必须跟着卡片挪**（2026-11-08 修）。
            //
            // 用户：「放大时就要判定是不是会超出界面，不要最后松开拖动杆才一下
            // 把课表拖进界面内」。
            //
            // 以前拖动帧里窗口基本不动，只把卡片在**画布**里挪（窗口只在卡片
            // 超出画布时平移一下）。但画布只比最大档卡片大 ~208pt —— 卡片贴着
            // 屏幕边放大时，需要的位移很快就超过这点余量，卡片只能露在屏幕外，
            // 等松手 `commitCardScale` 再一次性把窗口挪进来（那一下就是「跳」）。
            //
            // 现在每一帧都按「卡片中心 = 夹过的锚点」反推窗口原点：
            // 卡片在窗口里始终落在画布的标准位置（展开居中 / 折叠顶边对齐），
            // 屏幕位置严格等于锚点 —— 放大过程中一旦要出界，窗口当帧就让位。
            //
            // 精度：窗口原点只落在整点，小数零头由 translate 补（tx/ty 用
            // **实际**页面原点算），所以卡片中心仍然严格落在锚点上，不会抖。
            let canvasCard = TimetableLayout.currentCardRect(scale: s,
                                                             containerSize: dragWindowSize)
            let H = dragWindowSize.height
            let desiredOrigin = NSPoint(x: anchor.x - canvasCard.midX,
                                        y: anchor.y - canvasCard.midY)
            if let window {
                let cur = window.frame.origin
                if abs(cur.x - desiredOrigin.x) > 0.01 || abs(cur.y - desiredOrigin.y) > 0.01 {
                    window.setFrameOrigin(desiredOrigin)
                }
            }
            // 页面原点（屏幕坐标）；transform 相对页面左上角。
            let winOrigin = window?.frame.origin ?? desiredOrigin
            let pageTL = NSPoint(x: winOrigin.x, y: winOrigin.y + H)
            dragPageTopLeft = pageTL
            let webFrame = webRenderer?.webView.frame ?? .zero
            let tx = anchor.x - pageTL.x - layout.midX * s
            // 折叠态：translate 让**卡片顶边**落在 anchor 的顶边上（page y = 90）。
            let ty = collapsed
                ? pageTL.y - (anchor.y + cardSize.height / 2) - layout.minY * s
                : pageTL.y - anchor.y - layout.midY * s
            // 卡片在**窗口坐标系**里的矩形。
            let cardRect = NSRect(x: webFrame.minX + tx + layout.minX * s,
                                  y: webFrame.maxY - (ty + layout.maxY * s),
                                  width: layout.width * s,
                                  height: layout.height * s)
            // ⚠️ **原生 chrome（毛玻璃 / 图钉 / 穿透矩形）要等网页真的应用了这一帧
            // 再摆**（2026-11-08 修「缩放的时候图钉和课表不同步」）。
            //
            // 窗口是同步挪的、网页的 transform 是跨进程异步的：
            //   · 窗口先挪 Δ → 窗口里的网页层跟着挪 Δ（此时卡片 = 老位置 + Δ）；
            //   · 网页过一会儿才把 transform 补上 → 卡片回到目标位置。
            // 如果 chrome 在**发命令的同一刻**就摆到目标位置，它会先跳一步、
            // 等网页追上才对齐 —— 拖动时看到的就是「图钉飘在卡片外面」。
            //
            // 现在 chrome 放在 `applyDragScale` 的回调里摆：网页应用完这一帧
            // 才动 chrome，三者（卡片 / 玻璃 / 图钉）始终落在同一帧上。
            dragChromeSerial += 1
            let chromeSerial = dragChromeSerial
            let chromeRect = cardRect
            let chromeScale = s
            let applyChrome = { [weak self] in
                guard let self else { return }
                // 只接受「不比已经摆过的更旧」的帧 —— 迟到的旧回调不能把
                // 图钉/玻璃摆回上一帧的位置（那一下就是肉眼看到的「闪」）。
                guard chromeSerial >= self.appliedChromeSerial else { return }
                self.appliedChromeSerial = chromeSerial
                self.dragCardRect = chromeRect
                TimetableLayout.cardRectOverride = chromeRect
                self.updateDragChrome(cardRect: chromeRect, scale: chromeScale)
            }

            let gen = dragScaleGeneration
            dragScaleInFlight = true
            dragScaleWatchdog?.cancel()
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, gen == self.dragScaleGeneration, self.dragScaleInFlight else { return }
                self.dragScaleInFlight = false
                // 回调没来也要把 chrome 摆上，否则它会一直停在上一帧。
                applyChrome()
                NSLog("[TT-SCALE] 拖动帧 0.12s 未回调，强制重发（s=%.3f）", s)
                if self.pendingCardScale == nil { self.pendingCardScale = self.cardScale }
                self.applyNextDragFrame()
            }
            dragScaleWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: watchdog)

            webRenderer?.applyDragScale(s, translateX: tx, translateY: ty) { [weak self] in
                guard let self, gen == self.dragScaleGeneration else { return }
                applyChrome()
                self.dragScaleWatchdog?.cancel()
                self.dragScaleWatchdog = nil
                self.dragScaleInFlight = false
                if self.pendingCardScale != nil { self.applyNextDragFrame() }
            }
        }

    func commitCardScale(value: Double? = nil) {
            cardScaleDragging = false
            cardScaleThrottleTimer?.invalidate()
            cardScaleThrottleTimer = nil

            // ---- 设置面板开着：保留画布，松手只更新网页缩放 ----
            //
            // 之前松手会把窗口从「画布」缩回正常、网页 transform 从 translate+scale
            // 切回 scale —— 窗口是同步的、网页是异步的，中间那一帧就会闪。
            // 现在面板开着时**完全不动窗口/页面原点**，只把最终 scale 写进网页；
            // 等设置面板关闭，再一次性恢复正常窗口（那一下被面板关闭遮住）。
            let panelOpen = (settingsController?.window?.isVisible ?? false)
            if panelOpen {
                let screen = window.flatMap { TimetablePinState.screen(forPoint: $0.cardCenterOnScreen) }
                    ?? NSScreen.main
                let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                // 面板开着但还没开始拖（点滑杆 / 点箭头）→ 同样先进画布，
                // 这样每一次尺寸变化都走「窗口不动、只改 transform」，不会闪。
                if !dragWindowActive {
                    let current = currentWebCardCenterOnScreen()
                        ?? window?.cardCenterOnScreen ?? .zero
                    cardScaleAnchorCenter = current
                    enterDragWindow(anchor: current, visibleFrame: vf)
                }
                let target = CardScalePolicy.clamp(value ?? cardScale,
                                                   visibleSize: vf.size,
                                                   cardSize: TimetableLayout.baseCardSize)
                // 松手这一帧**强制重发**最终值：不依赖之前那一帧的回调
                // （回调一旦拖住，pending 就永远不落地 —— 用户看到的就是
                // 「滑块到了 93%，课表还停在 100%」）。
                dragScaleGeneration += 1
                dragScaleInFlight = false
                dragScaleWatchdog?.cancel()
                dragScaleWatchdog = nil
                cardScale = target
                pendingCardScale = target
                applyNextDragFrame()
                // 松手这一帧把网页切到 **pageZoom 清晰档**（拖动帧用的是 CSS transform）。
                // 面板还开着、窗口不动，但网页必须立刻变清晰。
                TimetableLayout.apply(scale: CGFloat(target))
                // ⚠️ 松手后「卡片在窗口里在哪」必须落进 `TimetableLayout`：
                // `apply(scale:)` 会把 override 清成「画布居中」，而面板开着时
                // 卡片其实停在拖动帧的位置（可能贴着边）—— 玻璃 / 命中区 /
                // 拖出屏幕的夹屏全都会按「居中」算，卡片就跑到屏幕外去了。
                if !dragCardRect.isEmpty {
                    TimetableLayout.cardRectOverride = dragCardRect
                }
                // 松手时网页对到**当前卡片中心**（拖动帧的位置）—— 玻璃/命中区
                // 保持拖动帧的矩形不动，松手那一瞬间画面不能跳。
                // ⚠️ 这里传的是**窗口坐标**（容器坐标）的中心 ——
                // `applyScale(keepingCardCenter:)` 按容器坐标换算，不能传屏幕坐标。
                // 用**拖动帧落地的矩形中心**（`dragCardRect`）：松手瞬间卡片要在原地，
                // 不能按画布公式重新居中（差 5~6pt 就会被看出来）。
                let center = dragCardRect.isEmpty
                    ? NSPoint(x: TimetableLayout.cardRect.midX,
                              y: TimetableLayout.cardRect.midY)
                    : NSPoint(x: dragCardRect.midX, y: dragCardRect.midY)
                webRenderer?.applyScale(CGFloat(target), keepingCardCenter: center)
                // 松手后立刻量一次网页卡片（自检 / 玻璃 / 命中区都读这个实测值）。
                webRenderer?.reportLiveCardFrameNow()
                // ⚠️ **面板开着、窗口可以出屏，但卡片必须留在屏幕可见区内**
                // （1.3.3 修「放到最大被屏幕切」）：把窗口挪到「卡片中心 = 夹过的中心」。
                if let window {
                    let measured = webRenderer?.lastCardLayoutRect?.size
                    let cardSize = CGSize(width: (measured?.width ?? 968) * CGFloat(target),
                                          height: (measured?.height ?? 773) * CGFloat(target))
                    // ⚠️ 用**拖动帧落地的卡片矩形**（`dragCardRect`）当「卡片当前位置」，
                    // 不能用 `TimetableLayout.cardRect`（它是「画布居中」的位置）：
                    // 面板开着拖动时卡片被摆在锚点上（可能已贴边夹过），
                    // 两者差几磅 → 这里会平白把窗口再挪几磅，用户看到
                    // 「松手瞬间卡片跳一下」（实测 6pt）。
                    let viewCenter = dragCardRect.isEmpty
                        ? NSPoint(x: TimetableLayout.cardRect.midX,
                                  y: TimetableLayout.cardRect.midY)
                        : NSPoint(x: dragCardRect.midX, y: dragCardRect.midY)
                    let screenCenter = NSPoint(x: window.frame.minX + viewCenter.x,
                                               y: window.frame.minY + viewCenter.y)
                    let anchor = clampedCardCenter(screenCenter, cardSize: cardSize, in: vf)
                    if abs(anchor.x - screenCenter.x) > 0.5 || abs(anchor.y - screenCenter.y) > 0.5 {
                        window.setFrameOrigin(NSPoint(x: anchor.x - viewCenter.x,
                                                      y: anchor.y - viewCenter.y))
                    }
                }
                appSettings.appearance.cardScale = cardScale
                config.cardScale = cardScale
                do {
                    try settingsStore.saveAppearance(appSettings.appearance)
                } catch {
                    NSLog("[DesktopTimetable] 卡片大小未保存：%@", error.localizedDescription)
                }
                // 这一轮缩放结束 → **释放锚点**（下一轮按当时的卡片中心重新锁）。
                // 不释放的话：缩放过一次 → 把课表拖到别处 → 再缩放，
                // 卡片会被拽回上一轮的老位置。
                cardScaleAnchorCenter = nil
                cardScaleAnchorTop = nil
                // 不写 window_state：画布的位置不是卡片的位置。
                return
            }

            // 松手：作废还在飞的拖动帧（它们的回调会把旧值写回去）。
            dragScaleGeneration += 1
            dragScaleInFlight = false
            dragScaleWatchdog?.cancel()
            dragScaleWatchdog = nil
            pendingCardScale = nil
            dragWindowActive = false
            settingsCanvasHeld = false
            let target = value ?? cardScale
            performCardScale(target, interactive: false)
            // 写盘。
            //
            // ⚠️ **要写 `appSettings.appearance.cardScale`，不能只写 `config.cardScale`** ——
            // `saveAppearance(appSettings.appearance)` 写的是 `appSettings.appearance`，
            // 只改 `config`（那只是当前生效的快照）的话，写出去的仍然是旧值。
            appSettings.appearance.cardScale = cardScale
            config.cardScale = cardScale
            do {
                try settingsStore.saveAppearance(appSettings.appearance)
            } catch {
                NSLog("[DesktopTimetable] 卡片大小未保存：%@", error.localizedDescription)
            }
            // 同上：一轮结束就释放锚点，别让下一次缩放沿用旧位置。
            cardScaleAnchorCenter = nil
            cardScaleAnchorTop = nil
            saveWindowState()
        }

    func enterDragWindow(anchor: NSPoint, visibleFrame vf: NSRect) {
            guard let window else { return }
            let size = window.contentView?.bounds.size ?? window.frame.size
            dragWindowSize = size
            dragWindowOrigin = window.frame.origin
            dragPageTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            dragWindowActive = true
            webRenderer?.setViewportHeight(size.height)
            webRenderer?.webView.frame = NSRect(origin: .zero, size: size)
            webHost?.frame = NSRect(origin: .zero, size: size)
        }

    func lockScaleAnchor() {
            let current = currentWebCardCenterOnScreen()
                ?? window?.cardCenterOnScreen ?? .zero
            cardScaleAnchorCenter = current
            if TimetableLayout.collapse > 0.5, let window {
                let r = window.convertToScreen(TimetableLayout.cardRect)
                cardScaleAnchorTop = NSPoint(x: r.midX, y: r.maxY)
            } else {
                cardScaleAnchorTop = nil
            }
        }

    func updateDragChrome(cardRect: NSRect, scale: CGFloat) {
            if ProcessInfo.processInfo.environment["DT_DIAG_CHROME"] != nil {
                NSLog("[TT-CHROME] cardRect=%@ scale=%.3f cardRectOverride=%@",
                      NSStringFromRect(cardRect), scale,
                      TimetableLayout.cardRectOverride.map { NSStringFromRect($0) } ?? "nil")
            }
            if let glass = glassView {
                if glass.frame != cardRect { glass.frame = cardRect }
                let radius = TimetableLayout.cardRadius * scale
                if glass.layer?.cornerRadius != radius { glass.layer?.cornerRadius = radius }
            }
            (containerView as? LiveContainerView)?.passthroughRect = cardRect
            interaction?.layoutPinButton(inCard: cardRect, scale: scale)
        }

    func currentWebCardCenterOnScreen() -> NSPoint? {
            guard let window, let c = webCardCenterInWindow() else { return nil }
            return window.convertPoint(toScreen: c)
        }

    func updateGlassFrameForCurrentScale() {
            guard let renderer = webRenderer, let glass = glassView,
                  let container = containerView else { return }
            // 还没量过网页里的 .card（启动早期）→ 先用原生 cardRect 兜底，
            // 等第一次推状态后的测量把 9pt 的高度差修正掉。
            let frame = renderer.cardFrameForCurrentScale(containerHeight: container.bounds.height)
                ?? TimetableLayout.cardRect
            if glass.frame != frame { glass.frame = frame }
            let radius = TimetableLayout.cardRadiusScaled
            if glass.layer?.cornerRadius != radius {
                glass.layer?.cornerRadius = radius
            }
        }

    func applyLiveFallback(reason: String, timeout: Bool = false) {
            liveFallbackActive = true
            card?.isHidden = false
            if timeout {
                NSLog("[TT-LIVE] 网页加载超时兜底，改用原生卡片")
            } else {
                NSLog("[TT-LIVE] 网页加载失败：%@，改用原生卡片", reason)
            }
            // 窗口已经亮着了就不用再渐显；还没亮就现在点亮
            if !hasPresentedCard { revealCard() }
        }

    func animateCollapse(to target: CGFloat, openDay: Int?) {
            collapseTimer?.invalidate()
            collapseTimer = nil

            let from = TimetableLayout.collapse
            let base = TimetableLayout.cardRect
            let left = base.minX
            let top = base.maxY
            let width = base.width

            // ⚠️ 折叠**不再收掉日期覆盖层**（2026-11）：网页里面板会从折叠条
            // 底下伸出来（宿主从 `.grid` 换成 `.card`），收起时用户看到的是
            // 「表头还在，日历跟着掉到下面」，而不是「面板突然没了」。

            if abs(from - target) < 0.0001 {
                finishCollapse(target, left: left, top: top, width: width, openDay: openDay)
                return
            }

            let start = Date()
            let duration: TimeInterval = 0.30
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let t = min(1.0, Date().timeIntervalSince(start) / duration)
                let eased = 1 - pow(1 - t, 3)          // ease-out cubic
                let p = from + (target - from) * CGFloat(eased)
                self.applyCollapseFrame(p, left: left, top: top, width: width)
                if t >= 1 {
                    timer.invalidate()
                    if self.collapseTimer === timer { self.collapseTimer = nil }
                    self.finishCollapse(target, left: left, top: top, width: width, openDay: openDay)
                }
            }
            collapseTimer = timer
            // `.common`：拖着滑杆 / 菜单开着时也照常走。
            RunLoop.main.add(timer, forMode: .common)
        }

    func applyCollapseFrame(_ p: CGFloat, left: CGFloat, top: CGFloat, width: CGFloat) {
            TimetableLayout.setCollapse(p)
            let h = TimetableLayout.cardHeight
            let rect = NSRect(x: left, y: top - h, width: width, height: h)
            TimetableLayout.cardRectOverride = rect
            updateDragChrome(cardRect: rect, scale: TimetableLayout.scale)
            webRenderer?.setCollapse(p)
        }

    func finishCollapse(_ target: CGFloat, left: CGFloat, top: CGFloat,
                                    width: CGFloat, openDay: Int?) {
            TimetableLayout.setCollapse(target)
            let h = TimetableLayout.cardHeight
            let rect = NSRect(x: left, y: top - h, width: width, height: h)
            TimetableLayout.cardRectOverride = rect
            updateDragChrome(cardRect: rect, scale: TimetableLayout.scale)
            // 网页卡片的真实矩形量一次（公式和浏览器实测总差 1pt 上下）。
            webRenderer?.reportLiveCardFrameNow()
            updateHover(force: true)
            NSLog("[DesktopTimetable] 课表折叠：%@（进度 %.2f，卡片高 %.1f）",
                  target > 0.5 ? "已收起" : "已展开", target, TimetableLayout.cardHeight)
            if target < 0.5, let day = openDay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    self?.dayPanel?.handle(action: "datePanelOpen", payload: ["day": day])
                }
            }
        }

    func toggleCollapse(openDay: Int? = nil) {
            let target: CGFloat = TimetableLayout.collapse > 0.5 ? 0 : 1
            animateCollapse(to: target, openDay: openDay)
        }

    func closeDayPanel() {
            guard dayPanel != nil else { return }
            dayPanel?.forceClose()
            // 网页侧也要收 —— 原生的 `forceClose` 只改原生状态，
            // 网页的覆盖层得靠这个函数自己撤掉。
            webRenderer?.webView.evaluateJavaScript(
                "if (window.ttDayPanelClose) window.ttDayPanelClose();")
        }

    /// 图钉图片（SF Symbol → 2x PNG base64），只算一次。
    static let pinHollowBase64 = PushPinButton.pngDataURI(pinned: false)
    static let pinSolidBase64 = PushPinButton.pngDataURI(pinned: true)

    /// 网页里是否已经注入过图钉图片（网页重载会丢，`onLiveReady` 里复位）。
    private var webPinImagesSent = false

    /// 把图钉的两张图注入网页（视觉由网页画，和标题同一个 DOM）。
    private func installWebPinImagesIfNeeded() {
        guard !webPinImagesSent, let renderer = webRenderer, renderer.isReady else { return }
        guard let hollow = Self.pinHollowBase64, let solid = Self.pinSolidBase64 else { return }
        webPinImagesSent = true
        renderer.setPinImages(hollow: hollow, solid: solid)
        renderer.setPinned(isPinned)
    }

    /// 睡醒 / 屏幕唤醒后的统一处理。
    ///
    /// 两条通知都走这里（`didWake` = 系统睡眠，`screensDidWake` = 只是屏幕关了）：
    ///
    /// 1. 睡过了午夜 → 换日期（天气 / 今日摘要跟着换）；
    /// 2. 补排上课提醒；
    /// 3. **卡片顶部立刻重画**（时钟 / 状态条）——
    ///    屏幕睡着时 WebKit 挂起了网页的定时器，原生 `Timer` 也停，
    ///    醒来后两边都要等下一个 10 秒档才恢复；这中间卡片显示的是
    ///    **睡着前那一帧的旧值**（时间落后、正在上课没显示）。
    ///
    /// - Parameter forceCard: 是否强制重画卡片（自检里用来单测这条路径）。
    func handleSystemWake(forceCard: Bool = true) {
        testWakeCount += 1
        // 睡过了午夜：唤醒后立刻对一次日期（天气 / 今日摘要跟着换）。
        dayPanel?.handleDayChange()
        refreshReminderSchedule()
        guard forceCard else { return }
        // 主动叫醒一次（原生重画 + 网页就地刷新时钟）。
        forceRefreshCard()
        // 唤醒后网页的定时器可能还要一会儿才真正恢复 ——
        // 再补一刀（延后一小会儿），确保卡片一定显示的是**当前**时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.forceRefreshCard()
        }
    }

    /// **强制**刷新一次卡片（不管「这一分钟推过了没有」）。
    ///
    /// ⚠️ **为什么需要**（2026-11-11 修「刚打开显示屏时，时间晚了 1 分钟、
    /// 也没显示『正在上课』」）：
    /// 显示器睡着时，**WebKit 会挂起网页的定时器**（`setInterval` 不再触发），
    /// 原生这边的 `Timer` 也会停。醒来后：
    ///   · 原生的 10 秒定时器要等下一个档才恢复；
    ///   · 网页的 10 秒定时器同样要等下一个档才恢复。
    /// 这中间（最长 ~10 秒，实际常常更久）卡片顶部显示的是**睡着前那一帧的旧值**
    /// —— 时间落后一分钟、状态条还停在「今天没有课」。
    ///
    /// 用户「刚打开显示屏」看到的就是那个旧值。
    /// 所以在唤醒通知里**主动叫醒**一次：原生重画 + 网页就地刷新时钟。
    func forceRefreshCard() {
        // 原生卡片（快照模式 A / 原生兜底）：状态里带 `now: Date()`，
        // 重画一次就是当前的。
        applyCardState()
        interaction?.setPinTitle(cardTitle)
        guard let renderer = webRenderer else { return }
        // 绕过「按分钟才推一次」那道闸 —— 唤醒时必须立刻推。
        lastWebMinute = Int(Date().timeIntervalSince1970 / 60)
        webNeedsRefresh = false
        renderer.update(stateJSON: webStateJSON())
        // 网页自己走表的那个 `setInterval` 也叫醒一次 ——
        // 顶部时钟 / 状态条是它负责的（原生推状态不会重画那两处）。
        renderer.tickClockNow()
        if !isLiveMode {
            // 等网页画完这一帧再取快照，否则拿到的是上一帧
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                renderer.snapshot()
            }
        }
    }

    func refreshCard() {
            applyCardState()
            // 标题可能被改过名 —— 图钉要跟着标题文字走。
            interaction?.setPinTitle(cardTitle)
            guard let renderer = webRenderer else { return }
            // 网页里只有时钟/状态是随时间变的，按分钟刷新就够；
            // 其余情况（翻周、改设置）用 webNeedsRefresh 强制刷一次。
            let minute = Int(Date().timeIntervalSince1970 / 60)
            guard minute != lastWebMinute || webNeedsRefresh else { return }
            lastWebMinute = minute
            webNeedsRefresh = false
            renderer.update(stateJSON: webStateJSON())
            if isLiveMode {
                // 实验模式 B：网页直接上屏，状态推过去就完事了，不取快照
                return
            }
            // 等网页画完这一帧再取快照，否则拿到的是上一帧
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                renderer.snapshot()
            }
        }

    func updateHover(force: Bool = false) {
        guard let window else { return }
        let probe = testHoverProbe
        let p = probe?.pointer ?? NSEvent.mouseLocation
        // 窗口比卡片大（四周留了投影空间），判定要按卡片本身算。
        let frame = window.convertToScreen(TimetableLayout.cardRect)
        // 日期覆盖层那一列也算「在卡片上」（折叠态它伸到卡片外面）。
        let panelFrame = dayPanelRectInWindow.map { window.convertToScreen($0) }
        let pointerOnPanel = panelFrame?.contains(p) ?? false
        let pointerInCard = frame.contains(p) || pointerOnPanel
        // 本 App 的**其它**窗口（设置面板 / 对话框）压在卡片上时，
        // 指针其实是在那块面板上 —— 不能当成「在卡片上」。
        let pointerOnOwnPanel = NSApp.windows.contains {
            $0 !== window && $0.isVisible && $0.frame.contains(p)
        }
        // 只有指针落在这两块区域里，问窗口服务器才有意义；在别处直接算「没悬停」。
        let topNumber: Int
        if let probe {
            topNumber = probe.topWindowNumber
        } else if pointerInCard || pointerOnOwnPanel {
            topNumber = topWindowNumber(at: p)
        } else {
            topNumber = 0
        }
        // ⚠️ **挡住课表的必须「层级比课表高」**（详见 `HoverCoverPolicy`）。
        let coveredByOtherApp = isPointCoveredByOtherApp(topNumber, layer: probe?.topWindowLayer)
        // 本 App 的覆盖层面板矩形要同步给交互层 —— 折叠态它伸到卡片下面，
        // 不登记就会被判成「指针不在课表上」：点击穿透、卡片跟着淡出。
        (containerView as? LiveContainerView)?.panelRect = dayPanelRectInWindow
        // 系统权限弹框期间：无论指针在哪，课表必须保持可见（带超时兜底）。
        //
        // 另外两种「指针在卡片外但课表必须亮着」的情况（2026-11 修）：
        //   · 右键菜单开着（菜单是浮动面板，指针一定在卡片外）；
        //   · 菜单刚关掉的宽限期内（用户松手那一刻指针还停在菜单原处）。
        // 不兜住的话，每次右键都会看到课表淡到 22%。
        let holding = PermissionPromptWatch.isHolding()
            || MenuPresenter.isMenuShowing
            || Date() < menuGraceUntil
        var inside: Bool
        if holding {
            inside = true
        } else if coveredByOtherApp {
            inside = false
        } else if topNumber != 0 && isOwnWindow(topNumber) && topNumber != window.windowNumber {
            // 本 App 的其它窗口（设置面板 / 对话框）→ 算「还在课表这边」。
            inside = true
        } else if hovering {
            // 已经悬停：要离开得更远才算离开（迟滞）。
            let nearCard = frame.insetBy(dx: -hoverHysteresis, dy: -hoverHysteresis).contains(p)
            let nearPanel = panelFrame?.insetBy(dx: -hoverHysteresis,
                                                dy: -hoverHysteresis).contains(p) ?? false
            inside = nearCard || nearPanel
        } else {
            inside = pointerInCard
        }
        if ProcessInfo.processInfo.environment["DT_HOVER_DIAG"] != nil {
            NSLog("[TT-HOVER] p=%@ card=%@ panel=%@ frame=%@ panelFrame=%@ collapse=%.2f inCard=%@ onPanel=%@ covered=%@ hover=%@ inside=%@",
                  NSStringFromPoint(p),
                  NSStringFromRect(TimetableLayout.cardRect),
                  NSStringFromRect(dayPanelRectInWindow ?? .zero),
                  NSStringFromRect(frame),
                  panelFrame.map(NSStringFromRect) ?? "nil",
                  TimetableLayout.collapse,
                  pointerInCard ? "1" : "0",
                  pointerOnPanel ? "1" : "0", coveredByOtherApp ? "1" : "0",
                  hovering ? "1" : "0", inside ? "1" : "0")
        }
        if inside != hovering || force {
            hovering = inside
            // 卡片之外不吃鼠标事件（桌面图标 / 下层窗口照常可点）。
            window.ignoresMouseEvents = !inside
            animateFade(solid: inside)
        }
        if isLiveMode { syncLiveHover() }
    }

    func webStateObject() -> [String: Any] {
            var obj = TimetableState(courses: courses,
                                     semesterStart: semesterStart,
                                     currentWeek: currentWeek(),
                                     viewWeek: viewWeek,
                                     now: Date(),
                                     maxWeek: maxWeek,
                                     overrides: overrides).webObject(title: cardTitle, subtitle: cardSubtitle)
            // 日期覆盖层的数据**每次推状态都带上** ——
            // 只在「覆盖层状态变了」的时候推不够：网页每次 `ttUpdate` 都会
            // 用新状态**整体替换** `S`，不带 dayPanel 的话，
            // 覆盖层的数据会被下一次课表刷新冲掉。
            // 图钉固定状态：网页重建 DOM 时据此画对空心 / 实心。
            obj["pinned"] = isPinned
            // 「取消添加 / 编辑」令牌（Esc）：网页看到号码变了就取消。
            obj["cancelCompose"] = cancelComposeToken
            if let panel = dayPanel {
                obj["dayPanel"] = panel.currentContentJSON()
                obj["dayFlags"] = panel.currentFlagsJSON()
                obj["dayPanelOpen"] = panel.isOpen
                // ⚠️ **7 天各自的「今日详情」**（2026-11 修）——
                //
                // 以前只推当前那一天，网页换列时只能靠缓存兜底 →
                // 「有的列有今日详情、有的没有」，而且日期经常对不上。
                //
                // 现在每一天一份独立的数据，网页按 `day` 取，不会串。
                obj["dayFestivals"] = panel.currentFestivalsJSON()
            }
            return obj
        }

    func revealCard() {
            guard !hasPresentedCard else { return }
            hasPresentedCard = true
            revealFallback?.cancel()
            revealFallback = nil
            // ⚠️ **渐显前先重算一次 hover**（2026-11-05 修「开 app 课表不出来」）。
            //
            // `hovering` 只在 `.mouseMoved` 里更新。启动时鼠标往往**一动不动**
            // （app 是后台启动的，用户没去碰它）→ `hovering` 还是初始值 false
            // → 目标亮度被定成 `minOpacity`（22%）→ 课表「出来了一点点」，
            // 在花哨壁纸上看着就像**根本没出来**。
            //
            // 这里按**当前指针位置**重算一次：鼠标正好在课表上就直接全亮。
            updateHover()
            let solid = ProcessInfo.processInfo.environment["DT_SOLID"] == "1"
            let target: CGFloat = solid ? 1
                : CGFloat(hovering ? config.maxOpacity : config.minOpacity)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                window.animator().alphaValue = target
            }
            mark("卡片渐显")
            // ⚠️ **启动时「先亮一下」**（2026-11-05 修「开 app 课表不出来」）。
            //
            // 用户反馈：「点开 app 之后课表很久都不显示，鼠标在课表范围内也不显示，
            // 点击很多次和等很长时间之后才显示出来」。
            //
            // 根因：课表窗口在**桌面层**（level -1），按产品设定待在所有普通
            // App 窗口**之下**；而 hover 判定问的是「指针这点**最上面**的窗口是谁」
            // —— 既然课表在最底下，这个查询**永远不可能返回我们自己**，
            // 只要有任何一个 App 窗口盖到指针那一点，就被判成「被盖住」。
            // 启动时鼠标又常常一动不动 → `hovering` 停在 false → 目标亮度 22%，
            // 课表在屏幕上**几乎看不见**（用户看到的就是「没出来」）。
            //
            // 修法（最小改动，不改既有判定）：启动时**先亮一下** ——
            // 先按「点亮」的亮度渐显，让用户明确看到课表出来了；
            // 随后按当前 hover 状态落回常态（移上去就实、没移就虚）。
            //
            // ⚠️ 已经被别的 App 完全盖住时，卡片本来就看不见（实测截图确认），
            // 这一下「亮」只是把 alpha 拉起来，等窗口一移开就能立刻看到内容 ——
            // 不会再出现「等半天突然冒出来」。
            guard !solid else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                window.animator().alphaValue = 1
            }
            for i in 0...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) { [weak self] in
                    guard let self else { return }
                    NSLog("[TT-ALPHA] +%.1fs alpha=%.3f hovering=%@",
                          Double(i) * 0.3, self.window.alphaValue, self.hovering ? "是" : "否")
                }
            }
            // 亮完之后落回常态（亮 → 虚，或亮 → 实，取决于指针在哪）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                let settled: CGFloat = self.hovering ? self.config.maxOpacity : self.config.minOpacity
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = max(0.01, self.config.fadeOutSec)
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                    self.window.animator().alphaValue = settled
                }
            }
        }

    func showCard() {
            refreshCard()
            if hasPresentedCard {
                mark("orderFront前")
                window.orderFrontRegardless()
                mark("orderFront后")
                updateHover(force: true)
                return
            }
            // 第一张快照还没到：窗口先以 0 不透明度留在屏上
            // （WKWebView 需要窗口在屏上才能稳定渲染、取快照），
            // 等快照贴好或兜底超时后再渐显。
            window.alphaValue = 0
            mark("orderFront前")
            window.orderFrontRegardless()
            mark("orderFront后")
            updateHover(force: true)
            scheduleRevealFallback()
            // 模式 B：网页压根加载不出来（资源文件缺失等）→ 立刻用原生卡片顶上，
            // 不用等 1.5s 兜底把一个空白窗口亮出来。
            // loadPage() 是在 renderer 的 init 里调的，那时还没挂 onLiveFailed，
            // 所以「资源文件不存在」只能靠这个属性补一刀。
            if isLiveMode, let err = webRenderer?.liveLoadError {
                applyLiveFallback(reason: err)
            }
        }

    func applyTodoMenuAction(_ action: String, payload: [String: Any]?) {
            guard let payload, let json = Self.jsonString(payload) else { return }
            let literal = action == "edit" ? "'edit'" : "'delete'"
            webRenderer?.webView.evaluateJavaScript(
                "if (window.ttDayPanelTodoMenuAction) window.ttDayPanelTodoMenuAction(\(literal), \(json));")
        }


    private func performCardScale(_ value: Double, interactive: Bool, transformOnly: Bool = false) {
        let requested = value
        let screen = window.flatMap { TimetablePinState.screen(forPoint: $0.cardCenterOnScreen) }
            ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clamped = CardScalePolicy.clamp(requested,
                                            visibleSize: vf.size,
                                            cardSize: TimetableLayout.baseCardSize)
        cardScale = clamped
        // ⚠️ **清掉拖动帧留下的 override** —— 否则这里拿到的是拖动时
        // 的瞬时矩形（可能贴在窗口边上），松手后玻璃/命中区会跟着错位。
        TimetableLayout.cardRectOverride = nil
        // 常驻画布：卡片在画布里居中；网页对齐到**原生 cardRect 的中心**。
        let center = NSPoint(x: TimetableLayout.cardRect.midX,
                             y: TimetableLayout.cardRect.midY)
        TimetableLayout.apply(scale: CGFloat(clamped))
        // ⚠️ **边缘夹屏**（1.3.3 修「贴边放大被屏幕切」）：
        // 卡片中心先按可见区夹一次，再把窗口挪到「卡片中心 = 夹过的中心」。
        // 窗口尺寸不变，只改原点；网页仍然对齐到 cardRect 中心（窗口坐标不变）。
        if let window {
            // ⚠️ 夹屏要用**网页实测的卡片尺寸**（`.card` 实测 975×778 上下，
            // 不是 CSS 里写的 968×773）—— 差的那 7~8pt 会让卡片贴边时被切。
            let measured = webRenderer?.lastCardLayoutRect?.size
            let cardSize = CGSize(width: (measured?.width ?? 968) * CGFloat(clamped),
                                  height: (measured?.height ?? 773) * CGFloat(clamped))
            let screenCenter = NSPoint(x: window.frame.minX + center.x,
                                       y: window.frame.minY + center.y)
            let anchor = clampedCardCenter(screenCenter, cardSize: cardSize, in: vf)
            let origin = NSPoint(x: anchor.x - center.x, y: anchor.y - center.y)
            if abs(origin.x - window.frame.minX) > 0.01 || abs(origin.y - window.frame.minY) > 0.01 {
                window.setFrameOrigin(origin)
            }
        }
        webRenderer?.applyScale(CGFloat(clamped), keepingCardCenter: center)
        updateDragChrome(cardRect: TimetableLayout.cardRect, scale: CGFloat(clamped))
        updateGlassFrameForCurrentScale()
        updateHover(force: true)
        webNeedsRefresh = true
        refreshCard()
    }

    func webCardCenterInWindow() -> NSPoint? {
            // ⚠️ 用**可见卡片矩形**的中心，不能用「容器中心」（2026-11-08 修）。
            //
            // 以前这里假设「卡片永远用 translate 摆在画布正中」，于是直接返回
            // 容器中心。但只要卡片被拖过 / 在面板里缩放过，`cardRectOverride`
            // 记录的才是它在窗口里的真实位置 —— 返回容器中心会让
            // 「缩放 → 拖走 → 再缩放」把卡片拽回旧位置（实测 120pt）。
            //
            // `TimetableLayout.cardRect` 是同步算出来的（override → 画布居中），
            // 不依赖网页量回来的旧缓存，所以不会像 `lastCardLayoutRect` 那样
            // 慢一帧。
            guard containerView != nil else { return nil }
            let r = TimetableLayout.cardRect
            return NSPoint(x: r.midX, y: r.midY)
        }

    func clampedCardCenter(_ center: NSPoint,
                                       cardSize: CGSize,
                                       in vf: NSRect) -> NSPoint {
            var c = center
            if cardSize.width < vf.width {
                c.x = min(max(c.x, vf.minX + cardSize.width / 2),
                          vf.maxX - cardSize.width / 2)
            } else {
                c.x = vf.midX
                if cardSize.width > vf.width { c.x = vf.midX }
            }
            if cardSize.height < vf.height {
                c.y = min(max(c.y, vf.minY + cardSize.height / 2),
                          vf.maxY - cardSize.height / 2)
            } else {
                c.y = vf.midY
            }
            return c
        }

    static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }


    var testCardIsLit: Bool { hovering }

    /// 自检用：当前浏览周次（nil = 全部周次）。
    var testViewWeek: Int? { viewWeek }

    var testCollapseProgress: CGFloat { TimetableLayout.collapse }

    var testCardScale: CGFloat { CGFloat(cardScale) }

    var testScaleDragSettled: Bool { !dragScaleInFlight }

    var testMenuGraceRemaining: TimeInterval { menuGraceUntil.timeIntervalSinceNow }

    var testPassthroughRect: NSRect { (containerView as? LiveContainerView)?.passthroughRect ?? .zero }

    var testWindowFrameRect: NSRect { window?.frame ?? .zero }

    var testWebCardCenterOnScreen: NSPoint? { currentWebCardCenterOnScreen() }

    var testGlassFrame: NSRect { glassView?.frame ?? .zero }

    var testDayPanelRectInWindow: NSRect? { dayPanelRectInWindow }

    func testUpdateHover(_ probe: HoverProbe?) {
            testHoverProbe = probe
            updateHover(force: true)
            testHoverProbe = nil
        }

    func testSimulateMenuOpenWhilePointerOutside() {
            MenuPresenter.isMenuShowing = true
            updateHover(force: true)
        }

    func testSimulateMenuCloseWhilePointerOutside() {
            MenuPresenter.isMenuShowing = false
            menuGraceUntil = Date().addingTimeInterval(Self.menuGraceSec)
            updateHover(force: true)
        }

    func testShowTodoMenu(_ payload: [String: Any]) {
            handleTodoMenuIntent(payload)
        }

    func testApplyCardScale(_ value: Double) {
            applyCardScaleImmediately(value)
        }

    func testCommitCardScale() {
            commitCardScale()
        }

    /// 「取消添加 / 编辑」的令牌：每次按 Esc 加一，随状态推给网页。
    ///
    /// ⚠️ 为什么不用一次性 `evaluateJavaScript`：键盘事件是在事件派发栈里
    /// 触发的，那种「重入」的 eval 会被 WebKit 接受但不执行（实测 Esc 没反应）。
    /// 状态推送是每轮都在用的通道，网页在 `ttUpdate` 里看到号码变了就取消。
    private var cancelComposeToken = 0

    /// 请求网页取消「添加 / 编辑待办」（走状态推送）。
    private func requestCancelEditing() {
        cancelComposeToken += 1
        webNeedsRefresh = true
        refreshCard()
    }

    /// 装「Esc 取消」通知的观察者（`DesktopWindow.cancelOperation` 会发）。
    private var cancelEditingObserverInstalled = false
    private func installCancelEditingObserver() {
        guard !cancelEditingObserverInstalled else { return }
        cancelEditingObserverInstalled = true
        NotificationCenter.default.addObserver(forName: .ttCancelEditingRequested,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.requestCancelEditing()
        }
    }

    /// 自检用：直接走「Esc 取消」那条通知（等价于用户在输入时按 Esc）。
    func testRequestCancelEditing() {
        NotificationCenter.default.post(name: .ttCancelEditingRequested, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// 自检用：把课表摆到屏上（等价于正式启动时的 `showCard()`）。
    ///
    /// ⚠️ **焦点自检必须调它** —— 窗口没 `orderFrontRegardless()` 就摆不到屏上，
    /// 也就永远拿不到 key window，那样测出来的「打不上字」是**假 bug**。
    func testShowCard() {
        showCard()
    }

    /// 文本输入期间的按键监视器（只拦 Esc）。
    ///
    /// ⚠️ 为什么需要它（2026-11-08 修「第二次打开要按两下 Esc」）：
    /// 输入框的 Esc 走的是网页 `keydown`；可窗口每次重新变成 key 时，
    /// **第一下按键有时会被 AppKit / WebKit 的输入上下文建立吃掉**，
    /// 到不了 DOM。第二次打开输入框正好踩这个点 —— 用户就得按两下。
    /// 这里在**原生**用 `addLocalMonitorForEvents` 先截住 Esc（它在 responder
    /// 派发之前），直接调网页的 `ttCancelEditing()`，再也不看 DOM 收没收到。
    private var textInputKeyMonitor: Any?

    private func installTextInputKeyMonitor(_ active: Bool) {
        if active {
            guard textInputKeyMonitor == nil else { return }
            textInputKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {        // Esc
                    // ⚠️ **走状态推送，不走一次性 eval**：键盘事件在派发栈里，
                    // 这里同步 eval 会被 WebKit 丢掉（重入）；单次 eval 也没重试。
                    // 状态推送（`ttUpdate`）是每轮都在跑的通道，靠得住。
                    DispatchQueue.main.async { [weak self] in self?.requestCancelEditing() }
                    return nil
                }
                return event
            }
        } else if let monitor = textInputKeyMonitor {
            NSEvent.removeMonitor(monitor)
            textInputKeyMonitor = nil
        }
    }

    /// 自检用：文本输入的 Esc 监视器装上了吗？
    var testTextInputKeyMonitor: Bool { textInputKeyMonitor != nil }

    /// 自检用：设置面板拿到「日期覆盖层」控制器了吗？
    /// （没拿到 → 「接入」开关点了不弹系统授权框、状态行卡在「正在读取」。）
    var testSettingsHasDayPanel: Bool { settingsController?.dayPanelController != nil }

    /// 自检用：设置面板当前是否开着。
    var testSettingsPanelVisible: Bool {
        settingsController?.window?.isVisible ?? false
    }

    /// 自检用：走**设置面板滑杆**那条真实路径改课表大小。
    ///
    /// 和 `testApplyCardScaleDragFrame` 的区别：那个直接调缩放引擎，
    /// 这个经过 `SettingsWindowController.updateCardScale` → `onCardScaleChange`
    /// → `AppDelegate.applyCardScale` —— 用户拖滑杆走的就是这条链。
    func testSetCardScaleFromSettingsPanel(_ value: Double, persist: Bool) {
        settingsController?.updateCardScale(value, persist: persist)
    }

    func testOpenSettingsPanel() { openSettings() }

    func testCSSPoint(_ point: NSPoint) -> NSPoint {
        webRenderer?.testCSSPoint(point) ?? .zero
    }

    /// 自检用：一次 hover 判定的输入替身。
    struct HoverProbe {
        var pointer: NSPoint
        var topWindowNumber: Int
        var topWindowLayer: Int?
    }

    var testHoverProbe: HoverProbe?

    private var menuGraceUntil: Date = .distantPast

    /// 网页报上来的「日期覆盖层实际矩形」（窗口坐标）。
    ///
    /// ⚠️ 为什么不用 `TimetableLayout.dayPanelRect`：那套几何只按展开态算，
    /// 折叠 + 缩放 / 换宿主时和网页里的实际位置会差几个点 —— 差出去的缝
    /// 就表现为「鼠标移到日历上，整个课表淡出」。
    /// 网页每次 `positionPanel()` 都会把真实矩形报过来（`panelRect` 意图）。
    private var webPanelRect: NSRect?
    private var webPanelDay: Int?

    /// 网页报来的面板矩形（CSS px，页面左上角原点）→ 窗口坐标。
    ///
    /// `getBoundingClientRect()` 给的是**视觉** CSS px；换算成窗口点：
    ///   · x = css.x × 倍率；y 从底部往上量 = 窗口高 − (css.top + css.height) × 倍率。
    /// 倍率用 `testRectScale`（pageZoom 档 = pageZoom，transform 档 = 1）。
    private func handleWebPanelRect(_ payload: Any?) {
        guard let dict = payload as? [String: Any],
              (dict["open"] as? Bool) == true else {
            webPanelRect = nil
            webPanelDay = nil
            return
        }
        guard let l = (dict["l"] as? NSNumber)?.doubleValue,
              let t = (dict["t"] as? NSNumber)?.doubleValue,
              let w = (dict["w"] as? NSNumber)?.doubleValue,
              let h = (dict["h"] as? NSNumber)?.doubleValue,
              w > 1, h > 1, let renderer = webRenderer else { return }
        let k = Double(renderer.testRectScale)
        let vh = Double(renderer.viewportHeight > 0
                        ? renderer.viewportHeight
                        : (window?.contentView?.bounds.height ?? 0))
        webPanelRect = NSRect(x: l * k, y: vh - (t + h) * k, width: w * k, height: h * k)
        webPanelDay = (dict["day"] as? NSNumber)?.intValue
    }

    /// 日期覆盖层那一列的矩形（窗口坐标）；没开面板时 nil。
    ///
    /// 优先用**网页报来的真实矩形**（折叠 / 缩放 / 换宿主都不会错位），
    /// 还没有报过（刚打开的那一两帧）才退回原生几何。
    private var dayPanelRectInWindow: NSRect? {
        if let r = webPanelRect { return r }
        guard let day = dayPanel?.currentDay else { return nil }
        return TimetableLayout.dayPanelRect(day: day)
    }

    /// 菜单关闭后的宽限期（秒）：这段时间里指针离开卡片也不淡出。
    static let menuGraceSec: TimeInterval = 6

    func handleTodoMenuIntent(_ payload: Any?) {
            guard let dict = payload as? [String: Any],
                  let key = dict["key"] as? String, !key.isEmpty else { return }

            // 弹出位置：网页坐标 → 窗口坐标 → 屏幕坐标（和课程右键同一套换算）。
            var screenPoint = NSEvent.mouseLocation
            if let x = (dict["x"] as? NSNumber)?.doubleValue,
               let y = (dict["y"] as? NSNumber)?.doubleValue,
               let renderer = webRenderer, let window {
                let height = renderer.webView.bounds.height
                let windowPoint = NSPoint(x: x, y: height - y)
                screenPoint = window.convertPoint(toScreen: windowPoint)
            }

            let menu = NSMenu()
            menu.autoenablesItems = false
            let entries: [(String, Selector)] = [
                ("修改…", #selector(todoMenuEdit(_:))),
                ("删除", #selector(todoMenuDelete(_:))),
                ("取消", #selector(todoMenuCancel(_:))),
            ]
            for (title, action) in entries {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = dict
                menu.addItem(item)
            }
            MenuPresenter.present(menu, at: screenPoint)
        }


    /// 日记条目的右键菜单（和待办的同一套：修改… / 删除 / 取消）。
    ///
    /// 2026-11-10：面板列太窄，表单里的「删除」会被挤到卡片外，
    /// 所以删除改成右键（用户要求「和提醒事项一样」）。
    func handleDiaryMenuIntent(_ payload: Any?) {
        guard let dict = payload as? [String: Any],
              let id = dict["id"] as? String, !id.isEmpty else { return }

        var screenPoint = NSEvent.mouseLocation
        if let x = (dict["x"] as? NSNumber)?.doubleValue,
           let y = (dict["y"] as? NSNumber)?.doubleValue,
           let renderer = webRenderer, let window {
            let height = renderer.webView.bounds.height
            screenPoint = window.convertPoint(toScreen: NSPoint(x: x, y: height - y))
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, Selector)] = [
            ("修改…", #selector(diaryMenuEdit(_:))),
            ("删除", #selector(diaryMenuDelete(_:))),
            ("取消", #selector(diaryMenuCancel(_:))),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = dict
            menu.addItem(item)
        }
        MenuPresenter.present(menu, at: screenPoint)
    }

    @objc private func diaryMenuEdit(_ sender: NSMenuItem) {
        applyDiaryMenuAction("edit", payload: sender.representedObject as? [String: Any])
    }

    @objc private func diaryMenuDelete(_ sender: NSMenuItem) {
        applyDiaryMenuAction("delete", payload: sender.representedObject as? [String: Any])
    }

    @objc private func diaryMenuCancel(_ sender: NSMenuItem) {
        // 显式入口；NSMenu 自己会把菜单关掉。
    }

    func applyDiaryMenuAction(_ action: String, payload: [String: Any]?) {
        guard let payload, let json = Self.jsonString(payload) else { return }
        let literal = action == "edit" ? "'edit'" : "'delete'"
        webRenderer?.webView.evaluateJavaScript(
            "if (window.ttDiaryMenuAction) window.ttDiaryMenuAction(\(literal), \(json));")
    }

    @objc private func todoMenuDelete(_ sender: NSMenuItem) {
        applyTodoMenuAction("delete", payload: sender.representedObject as? [String: Any])
    }

    @objc private func todoMenuCancel(_ sender: NSMenuItem) {
        // 显式入口；NSMenu 自己会把菜单关掉，这里什么都不做。
    }

    @objc private func todoMenuEdit(_ sender: NSMenuItem) {
        applyTodoMenuAction("edit", payload: sender.representedObject as? [String: Any])
    }


    func testApplyCardScaleDragFrame(_ value: Double) {
        if cardScaleAnchorCenter == nil { lockScaleAnchor() }
        pendingCardScale = value
        applyNextDragFrame()
    }

    func testToggleCollapse() {
        toggleCollapse()
    }

    var testWindow: NSWindow? { window }

    func testCloseSettingsPanel() {
        settingsController?.window?.close()
    }

    func topWindowNumber(at screenPoint: NSPoint) -> Int {
            guard let window else { return 0 }
            if window.ignoresMouseEvents {
                window.ignoresMouseEvents = false
            }
            return NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        }

    func isPointCoveredByOtherApp(_ number: Int, layer: Int? = nil) -> Bool {
            guard number != 0, !isOwnWindow(number) else { return false }
            let otherLayer = layer ?? windowLayer(ofWindowNumber: number)
            return HoverCoverPolicy.covers(otherLayer: otherLayer,
                                           ourLevel: window?.level.rawValue ?? 0)
        }

    func isOwnWindow(_ number: Int) -> Bool {
            guard number != 0 else { return false }
            if number == window?.windowNumber { return true }
            return NSApp.windows.contains { $0.windowNumber == number }
        }

    func windowLayer(ofWindowNumber number: Int) -> Int? {
            if let cached = hoverLayerCache[number],
               Date().timeIntervalSince(cached.at) < 2 {
                return cached.layer
            }
            let layer = HoverCoverPolicy.layer(ofWindowNumber: number)
            // 缓存别无限涨：窗口号只会越来越多。
            if hoverLayerCache.count > 64 { hoverLayerCache.removeAll(keepingCapacity: true) }
            hoverLayerCache[number] = (layer, Date())
            return layer
        }
    func restoreAfterSettingsClose() {
            guard dragWindowActive else { return }
            let cardRect = dragCardRect.isEmpty ? TimetableLayout.cardRect : dragCardRect
            TimetableLayout.cardRectOverride = cardRect
            dragWindowActive = false
            settingsCanvasHeld = false
            dragScaleGeneration += 1
            dragScaleInFlight = false
            dragScaleWatchdog?.cancel()
            dragScaleWatchdog = nil
            pendingCardScale = nil
            cardScaleAnchorCenter = nil
            // 不再调用 performCardScale：
            // 常驻画布下窗口/网页 transform 已经是对的状态，再跑一遍会重设窗口原点
            // 并把 CSS transform 切回 pageZoom —— 关闭那一帧就会抖。
            // 原生 chrome 按当前可见卡片矩形重摆即可。
            interaction?.layoutPinButton(inCard: cardRect, scale: TimetableLayout.scale)
            (containerView as? LiveContainerView)?.passthroughRect = cardRect
            if let glass = glassView {
                glass.frame = cardRect
                glass.layer?.cornerRadius = TimetableLayout.cardRadius * TimetableLayout.scale
            }
            saveWindowState()
        }
}


// MARK: - 通知代理

/// 前台展示 + 点击处理。
///
/// 默认情况下 app 在前台时系统**不**显示通知 —— 桌面课表这种常驻后台的
/// 小工具，用户很可能正看着卡片，所以明确要求 `[.banner, .sound]`。
extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知：至少把 app 和卡片带到眼前。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        showCard()
        completionHandler()
    }
}
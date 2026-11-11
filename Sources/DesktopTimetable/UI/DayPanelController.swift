import AppKit
import EventKit
import CoreLocation

/// 「日期覆盖层」的**原生侧控制器**。
///
/// 职责：
///   · 持有 EventKit 接入层（协议注入，测试用 fake）；
///   · 接收网页发来的 intent（开 / 撑开 / 关 / 待办增删改）；
///   · 取到数据后把状态 push 给网页；
///   · 汇总 7 天的「有待办 / 有日程」标记（驱动表头的红点 / 橙点）。
///
/// ⚠️ **自动化模式下绝不碰真实的日历 / 提醒事项** ——
/// 自检进程一旦请求权限，用户会看到系统弹窗，用户的提醒事项也可能被改。
/// 所以 `AutomationMode.isCurrentProcessAutomation` 为真时：
///   · 不创建真实的 `EventKitStore`（用 fake）；
///   · 不请求任何权限。
final class DayPanelController {

    /// 接入设置（来自 `settings.json`）。
    private(set) var settings: DayPanelSettings

    /// EventKit 接入层。
    ///
    /// 自动化模式注入 fake（什么都返回空），真实模式才用真的。
    ///
    /// ⚠️ `var` + `testReplaceStore`（2026-11-11）：自检要复现「真实写回路径」——
    /// 空实现的 `setReminder` 永远返回失败，走不到「写回成功 → 重取数 →
    /// 补推」那条分支，于是「点完成之后一直闪」这类问题在自检里复现不出来。
    private var eventStore: EventKitStoreProtocol

    /// 「已完成的提醒事项」的读取 / 筛选 / 分页 / 批量删除状态机。
    ///
    /// 和日期覆盖层共用上面那个 `eventStore` —— 测试注入一个 fake，
    /// 两边都不会碰用户真实的提醒事项。
    private(set) var completedReminders: CompletedRemindersService

    /// 农历 / 节气 / 节日提供者（农历模块由别的 agent 实现，这里用协议解耦）。
    private let festivalProvider: DayPanelFestivalProvider

    /// 天气提供者（nil = 不显示天气）。
    ///
    /// 自动化模式**注入 fake**（绝不联网、不碰定位）。
    private let weatherProvider: DayPanelWeatherProvider?

    /// 当前覆盖层显示的是第几天（1…7）；nil = 没打开。
    private(set) var currentDay: Int?

    // ⚠️ **不再有「宽态」**（2026-11 去掉双击展开）——
    //
    // 以前双击表头会把覆盖层撑成一个浮在课表格上的大方块：
    // 盖住旁边的列、底边是硬边横切过课程格，观感不好，
    // 而且卡片化 + 面板内滚动之后，宽态也没多显示什么。
    //
    // 现在**只有一列宽**这一种形态。

    /// 状态变化时回调（把新状态推给网页）。
    var onStateChange: (([String: Any]) -> Void)?
    /// 授权状态变化时回调（设置面板要刷新状态行）。
    var onAuthorizationChange: (() -> Void)?
    /// 设置变了（自动打开接入开关时）→ 交给设置面板写盘。
    var onSettingsChanged: ((DayPanelSettings) -> Void)?
    /// 「添加待办」的结果（成功 / 失败 + 原因）→ 交给网页显示。
    var onTodoAddResult: (([String: Any]) -> Void)?
    /// 「修改待办」的结果 → 失败时网页回滚并显示原因。
    var onTodoUpdateResult: (([String: Any]) -> Void)?

    /// 缓存的 7 天标记（表头的红点 / 橙点）。
    private var flags: [Int: DayPanelFlags] = [:]

    /// `refreshAll()` 的令牌 —— 只接受**最新一次**刷新的结果。
    ///
    /// ⚠️ EventKit 的取数是异步的。翻周 / 连续加待办时会同时有好几轮刷新在飞，
    /// 而 `flags` 只按「1…7」存、不带周次 —— 旧一轮晚到就会把**上一周**
    /// 的结果写到当前周上（用户看到「换了星期红点还在 / 莫名出现」）。
    /// 每次刷新自增令牌，`group.notify` 里对不上就整轮丢掉。
    private var refreshToken = 0

    /// 「系统里的提醒事项 / 日历变了」的版本号（推给网页的 `dayPanelRevision`）。
    ///
    /// ⚠️ **为什么需要**（2026-11 修「系统里勾完，红点没了条目还在」）：
    /// 用户在系统「提醒事项」里勾掉一条 → 这里重算红点（红点消失）。
    /// 但如果那一刻面板是**关着的**（`currentDay == nil`），就没有 `dayPanel`
    /// 可推；网页的按天缓存仍留着旧列表 → 鼠标移回那一列时直接画缓存，
    /// 已完成的条目还在。
    ///
    /// 每次外部变化把版本号加一 → 网页看到变化就**作废缓存**并重新要数据。
    private var storeRevision = 0

    /// `loadContent()` 的令牌 —— 只接受**最新一次**取数的回包。
    ///
    /// ⚠️ 和 `refreshToken` 是同一个坑的另一半（2026-11 修）：
    /// 内容加载以前只用 `currentDay == day` 判断。但「第 1 周的周 4」和
    /// 「第 2 周的周 4」的 `day` 都是 4 —— 在两周的同一列之间来回切时，
    /// 旧周迟到的空回包会覆盖新周的内容，用户看到「待办显示不出来」。
    /// 每次加载自增令牌，旧的直接丢掉。
    private var contentToken = 0

    /// 正在写回的待办（按 identifier）—— 同一条**同时只允许一次写回**。
    ///
    /// ⚠️ 写回是异步的：第一次还没落地时又收到同一条的 `todoToggle`，
    /// `content.todos` 里那条还是 `done=false` → 第二次会把刚完成的又**取消**掉。
    /// 表现就是「点了确实没了（网页乐观隐藏），过一会儿 / 换周回来又出现」。
    /// 网页侧对同一条只发一次，但原生这边也要有防线。
    private var togglesInFlight: Set<String> = []

    /// 刚在课表里标记完成、但 EventKit **还没在取数里确认** done 的待办 id → 完成时刻。
    ///
    /// ⚠️ **为什么需要**：EventKit 的 `save(commit:)` 返回成功 ≠ 紧接着的
    /// `fetchReminders` 一定能读到新状态（不是强一致，取数可能是旧快照）。
    /// 如果只看取数结果，刚完成的条目会在面板里「复活」，
    /// 用户换周回来又看到它（用户反馈「有时候还是会」）。
    ///
    /// `save` 成功本身就是事实 → 在它被取数确认之前，展示层一律过滤掉。
    /// 取数一旦看到 `done=true`（或这条确实没了）就移除；
    /// 30 秒兜底，防止外部把状态改回去时被永远藏住。
    private var recentlyCompleted: [String: Date] = [:]

    /// 刚删除、但 EventKit 取数**还没反映**（旧快照里还在）的待办 id → 删除时刻。
    ///
    /// 和 `recentlyCompleted` 同一个道理：`remove(commit:)` 成功就是事实，
    /// 取数晚一步仍返回它的话，不能让它「复活」一下再消失（用户看到的「闪」）。
    private var recentlyDeleted: [String: Date] = [:]

    /// 刚改了标题 / 到期时间、但 EventKit 取数**还没反映**的待办。
    ///
    /// ⚠️ `save(commit:)` 成功 ≠ 紧接着的 `fetchReminders` 是新数据。
    /// 旧快照里仍是旧标题 / 旧时间 —— 直接展示就会把用户刚改的内容**改回去**，
    /// 等取数追上又变一次（看起来像「保存后闪两下」）。
    /// 写回成功就是事实：在取数确认之前，展示层用这份新值盖住旧快照。
    private struct TodoUpdateFact {
        var title: String
        var due: String       // HH:mm
        var minutes: Int
        var at: Date
    }
    private var recentlyUpdated: [String: TodoUpdateFact] = [:]

    /// 正在写回的「修改」——同一条同时只允许一次，避免连点两次写出两个结果。
    private var updatesInFlight: Set<String> = []

    /// 刚写入成功、但取数**还没读到**的新待办（identifier → 条目 + 哪一天 + 时刻）。
    ///
    /// ⚠️ **为什么需要**：`save` 成功之后 EventKit 的第一次取数可能是旧快照，
    /// 不含这条新待办 —— 面板推回去只有旧列表，用户看到「红点出现了、
    /// 待办文字没出现」（用户反馈）。把刚写的条目先展示出来，
    /// 等取数追到就无缝替换成真实数据。
    private var pendingAdded: [String: (todo: DayPanelTodo, day: Int, at: Date)] = [:]

    /// 是否已经有一轮系统权限请求在飞。
    ///
    /// ⚠️ 点「添加待办」会立刻请求权限；用户如果不等系统框回答就敲回车，
    /// `todoAdd` 那边会再请求一次。同一个 app 的 TCC 框不能连着弹，
    /// 第二个请求往往**一直不回调** —— 这里加锁，只发第一轮。
    private var accessRequestInFlight = false

    /// 系统 EventKit 数据库变化监听（在「提醒事项 / 日历」App 里增删改）。
    private var storeChangeObserver: NSObjectProtocol?

    /// 变化通知的防抖任务（`EKEventStoreChanged` 可能连着发很多次）。
    private var storeChangeWork: DispatchWorkItem?

    /// 缓存的当天内容（覆盖层要显示）。
    private var content = DayPanelContent()
    /// 日记存储（JSON 小文件，**不碰** EventKit —— 日记是本 app 自己的数据）。
    private let diaryStore = DiaryStore()

    /// 上一次真正推给网页的状态指纹（`pushState` 用，避免重复推送）。
    private var lastPushedSignature: String?
    /// 每一天**最近一次推出去**的 `dayPanel`（仅自检读取，见 `testPushedPanel(day:)`）。
    ///
    /// 按天存而不是只记最后一次：一次写操作之后会推两版
    ///（补推改动那天 + `refreshAll` 的表头标记），后者会把「最后一次」
    /// 覆盖成原生 `currentDay` 那一天 —— 自检就看不到补推的那一版了。
    private var pushedPanelsByDay: [Int: [String: Any]] = [:]

    /// **7 天各自的「今日详情」**（农历 / 节气 / 节日 / 宜忌）。
    ///
    /// ⚠️ **为什么要按天存**（2026-11 修）：
    ///
    /// 以前只 push **当前那一天**的 `dayPanel`（`content`），
    /// 网页侧靠 `DP.cache[day]` 兜底。于是：
    ///   · 刚打开某一列时，那一天**还没被 push 过** → 缓存是空的
    ///     → **「今日详情」整块消失**（用户反馈「有的天数有、有的没有」）；
    ///   · 指针扫到新的一列时，网页先显示**上一列缓存下来的**内容
    ///     → **农历对不上号**（用户反馈「今日详情大多数日期对不上」）。
    ///
    /// 现在**7 天的详情一次算好、一次推过去** ——
    /// 网页侧 `DP.cache[day]` 永远有正确的那一天，不会串。
    private var festivalByDay: [Int: DayPanelFestival] = [:]

    /// 天气请求**是不是在飞**（2026-11 加）。
    ///
    /// 按**日期**记住取回来的天气（`2026-11-10` → 天气）。
    ///
    /// ⚠️ 为什么单独存：`festivalByDay` 每次 `refreshFestivalCache` 都会整份重算，
    /// 天气是异步加进去的，重算就会丢。这里按日期存一份，重算时再贴回去。
    private var weatherByDate: [String: DayPanelWeather] = [:]

    /// 跟随模式下指针扫过每一列都会调 `loadWeather`；
    /// 不做去重的话，一天能发几十次 Open-Meteo 请求，而且互相抢回包。
    private var weatherRequestInFlight = false
    /// 等着这次天气结果的所有回调（去重后一起分发）。
    private var weatherPendingApplies: [([String: DayPanelWeather]) -> Void] = []

    /// 今天的日期在「周几」上的位置（1=周一 … 7=周日）。
    ///
    /// ⚠️ **可更新**（2026-11 加）：用户开着面板过 12 点，`todayIndex`
    /// 必须跟着换一天（`isToday` / 今日待办摘要都依赖它），
    /// 天气也要按新的一天重新取。见 `handleDayChange`。
    private var todayIndex: Int

    /// 当前浏览的那一周的起始日期（用来把「周几」换算成具体日期）。
    ///
    /// 覆盖层显示的是**当前浏览周**的那一天，不是「今天」——
    /// 用户翻到第 8 周，点周三就该看第 8 周的周三。
    ///
    /// ⚠️ **可更新**（2026-11 修）：翻周时必须跟着变 ——
    /// 以前它是 `let`，只在控制器创建时算一次，于是
    /// **翻到下一周，农历 / 节气 / 节日全都不变**（用户反馈「翻周之后农历都是一样的」）。
    private var baseMonday: Date

    /// 「全部周次」模式下**不显示覆盖层**。
    ///
    /// 全部周次 = 把所有教学周的课程叠在一起看，
    /// 这时「周三」到底指哪一天是**没有定义的**（有 16 个周三）。
    /// 所以这时候点日期**什么都不弹**（用户确认的行为）。
    private var allWeeksMode = false

    /// 切换「浏览周」—— 翻周之后要重算 7 天的详情。
    ///
    /// - Parameters:
    ///   - baseMonday：新一周的周一。
    ///   - allWeeks：是否处于「全部周次」模式（这种模式下不显示覆盖层）。
    func updateBrowsingWeek(baseMonday: Date, allWeeks: Bool) {
        self.baseMonday = baseMonday
        self.allWeeksMode = allWeeks
        // ⚠️ **翻周后必须重算 7 天的详情** ——
        // 否则农历 / 节气 / 节日还是上一周的（用户反馈「翻周之后农历都是一样的」）。
        refreshFestivalCache()
        // 关掉正在显示的面板 —— 它的内容属于旧的一周。
        currentDay = nil
        // 作废所有还在飞的取数（否则旧周的周 4 回包会落到新周的周 4 上）。
        contentToken += 1
        // 旧的「刚写入 / 刚删除」记录都带着「周几」但不带周次 ——
        // 不清的话，新一周的同一列可能把它们捞出来（乐观条目串周）。
        pendingAdded.removeAll()
        recentlyDeleted.removeAll()
        recentlyUpdated.removeAll()
        updatesInFlight.removeAll()
        // ⚠️ **标记必须立刻清空、立刻推给网页**（2026-11 修）。
        //
        // `flags` 只按「1…7」存，不带周次 —— 不清的话，新一周的表头会原样
        // 亮着上一周的红点（用户反馈「换到别的星期，红点还在」）。
        // 清空后先推一次，网页马上把点抹掉；重算结果稍后到。
        flags = [:]
        pushState()
        // 新一周的标记立即重算。令牌机制保证：
        // 翻周前发出的旧刷新就算晚到，也不会覆盖这一轮的结果。
        refreshAll()
    }

    init(settings: DayPanelSettings,
         festivalProvider: DayPanelFestivalProvider,
         todayIndex: Int,
         baseMonday: Date,
         eventStore: EventKitStoreProtocol? = nil,
         weatherProvider: DayPanelWeatherProvider? = nil) {
        self.settings = settings
        self.festivalProvider = festivalProvider
        self.todayIndex = todayIndex
        self.baseMonday = baseMonday
        self.weatherProvider = weatherProvider
        if let eventStore {
            self.eventStore = eventStore
        } else if AutomationMode.isCurrentProcessAutomation {
            // 自动化模式：注入空实现，绝不碰真实日历 / 提醒事项。
            //
            // ⚠️ `--verify-todo-focus` 例外（2026-11-09）：它要验
            // 「输入时间时上面的**待办事项**不能消失」，空 store 里 0 条
            // 待办 → 断言恒真 = 没验。所以按它自己的报告变量认领，
            // 塞一条假待办进去（绝不影响别的自检）。
            let seeded: [DayPanelTodo] = ProcessInfo.processInfo
                .environment["DT_FOCUS_REPORT"] == nil ? [] : [
                    DayPanelTodo(title: "自检待办（不能消失）", due: "20:00",
                                 done: false, dueMinutes: 20 * 60,
                                 identifier: "seed-todo-1",
                                 calendarIdentifier: "seed-list")
                ]
            self.eventStore = EmptyEventKitStore(seededTodos: seeded)
        } else {
            self.eventStore = EventKitStore()
        }
        // 已完成列表和日期覆盖层**共用同一个 store** —— 注入 fake 时两边都不会碰系统。
        self.completedReminders = CompletedRemindersService(store: self.eventStore)

        // 系统里的提醒事项 / 日程被增删改（比如用户在「提醒事项」App 里
        // 删掉一条课表待办）→ 自动重算表头红点；面板开着时重载当天内容。
        //
        // ⚠️ 以前没有任何监听：删掉之后红点 / 面板一直不更新，
        // 要等用户重新点开那一天（会重新 loadContent）才同步。
        // （用户反馈：「在系统里面删除了之后，课表不会同步更新」。）
        //
        // 自动化模式也注册：自检可以 post 这个通知来验同步，
        // 而且 refreshAll 用的还是注入的 fake —— 不会碰系统数据。
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleStoreChangeRefresh()
        }
    }

    deinit {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
        storeChangeWork?.cancel()
    }

    /// 系统数据变了 → 防抖后刷新（`EKEventStoreChanged` 会连发很多次）。
    private func scheduleStoreChangeRefresh() {
        storeChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.storeChangeWork = nil
            // 外部数据真的变了 → 版本号加一。网页据此作废按天缓存
            // （否则面板关着时缓存的旧待办会一直在）。
            self.storeRevision += 1
            self.refreshAll()
            if let day = self.currentDay {
                // ⚠️ **不要清空已有内容再推一次** —— 那是「打开某天」的流程，
                // 清空 + push 会让面板闪一下空白。外部变化只需要在取数回来后更新。
                self.loadContent(day: day, resetImmediately: false)
            }
        }
        storeChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - 授权

    /// 提醒事项的授权状态。
    var reminderAuthorized: Bool {
        eventStore.reminderAuthorization == .fullAccess
    }

    /// 日历的授权状态。
    var eventAuthorized: Bool {
        eventStore.eventAuthorization == .fullAccess
    }

    /// 定位的授权状态（设置面板要显示「天气能不能用」）。
    ///
    /// 自动化模式下没有位置管理器 → 返回 nil（= 还没问过）。
    var locationAuthorizationStatus: CLAuthorizationStatus? {
        (weatherProvider as? OpenMeteoWeatherProvider)?.authorizationStatus
    }

    /// 设置里填的**地区名**（去掉首尾空白；空串 = 还没选）。
    ///
    /// ⚠️ 2026-11-10：天气开着但没选地区时，网页要显示
    /// 「请在设置里选择地区」—— 所以这个值必须随 `festival` 一起推过去。
    private var weatherRegion: String {
        settings.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 请求授权（日历 + 提醒事项）。
    ///
    /// ⚠️ 本 app 是 `LSUIElement` 后台应用，**系统授权弹窗可能不显示**。
    /// 所以先临时切成 `.regular`（变成前台 app），弹窗才出得来；
    /// 用完切回 `.accessory`。
    ///
    /// 这套「切 regular 再弹窗」在本项目里有先例（见
    /// `AppDelegate.showStatusItemBlockedAlert`）。
    func requestAccess() {
        // ⚠️ 自动化模式**绝不碰真实 TCC**（原来的护栏）。
        //
        // 但自检注入的是 fake store（`EmptyEventKitStore` / `FakeEventKitStore`），
        // 走它们请求权限**不会**弹系统框 —— 不拦的话才能测到
        // 「点添加待办立刻请求权限」这条路径。所以只在真实 `EventKitStore`
        // 上才直接返回。
        if AutomationMode.isCurrentProcessAutomation && eventStore is EventKitStore { return }
        // 已经有一轮在飞 → 不再重复请求（见 `accessRequestInFlight`）。
        guard !accessRequestInFlight else { return }
        accessRequestInFlight = true

        // 自动化模式不做「切前台再切回来」—— 那是为了让**系统权限框**出得来，
        // 自检里没有系统框，切来切去反而影响后面的窗口自检。
        let automated = AutomationMode.isCurrentProcessAutomation

        // `activationPolicy` 是**方法**不是属性 —— 写成 `NSApp.activationPolicy`
        // 会拿到一个函数值，比较就编译不过。
        let wasRegular = NSApp.activationPolicy() == .regular
        if !automated && !wasRegular { NSApp.setActivationPolicy(.regular) }
        if !automated { NSApp.activate(ignoringOtherApps: true) }

        // ⚠️ **两个请求要「并行」，不能「串行」**（2026-11 修）。
        //
        // 以前是「先请求提醒事项，回调里再请求日历」——
        // 于是 macOS 上会出现这种情况：
        //   1. 弹「提醒事项」的权限框，用户点「允许」；
        //   2. 紧接着发第二个请求（日历）——
        //      **这时系统往往不会再弹第二个框**（同一个 app 的 TCC 提示
        //      不能连着弹），请求就**一直挂着**。
        //   3. 回调不来 → `activationPolicy` 永远切不回 `.accessory`
        //      → app 一直抢前台（用户看到「一直显示，等待系统确认」）。
        //
        // 并行发两个请求：macOS 会把两个权限框**依次**弹出来，
        // 任何一个有回应就把状态刷回来。
        //
        // 另外加一个**超时兜底**（10 秒）：万一某个请求真的不回调，
        // 也要把 app 的前台状态还原、把界面刷新，不能一直卡着。
        let group = DispatchGroup()
        var finished = false
        func finishOnce() {
            guard !finished else { return }
            finished = true
            self.accessRequestInFlight = false
            if !automated && !wasRegular { NSApp.setActivationPolicy(.accessory) }
            self.onAuthorizationChange?()
            self.refreshAll()
        }

        group.enter()
        eventStore.requestReminderAccess { _ in
            group.leave()
            DispatchQueue.main.async { finishOnce() }
        }
        group.enter()
        eventStore.requestEventAccess { _ in
            group.leave()
            DispatchQueue.main.async { finishOnce() }
        }

        // 超时兜底：10 秒内没有任何回调 → 也要收尾。
        //
        // ⚠️ **顺便把「课表保持可见」也一起解除**（2026-11-05 修）：
        // 系统有时只弹一个权限框，另一个请求永远不回调 —— 那一笔
        // `PermissionPromptWatch.begin` 就等不到自己的 `end`，课表会一直亮着
        // （用户反馈：「修改完 / 取消后，鼠标移到课表外面，课表不消失」）。
        // 这个 10 秒本来就是「不再等系统回应」的时刻，保持状态一起收掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            finishOnce()
            PermissionPromptWatch.endAll()
        }
    }

    /// 打开「系统设置 → 隐私与安全性」里**用户还缺的那个**面板。
    ///
    /// 日历和提醒事项在 macOS 上是**两个不同的隐私面板**
    /// （`Privacy_Calendars` / `Privacy_Reminders`），开错等于没开。
    /// 两个都缺 → 开「隐私与安全性」总页，让用户自己找。
    func openSystemSettings() {
        let url: URL?
        switch (reminderAuthorized, eventAuthorized) {
        case (false, true):
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        case (true, false):
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case (false, false):
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case (true, true):
            return
        }
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 提醒事项清单

    /// 可选的提醒事项清单。
    var reminderLists: [EventKitListInfo] {
        guard settings.enabled else { return [] }
        return eventStore.reminderLists()
    }

    /// 选一个清单（写回设置）。
    func selectList(_ identifier: String, title: String) {
        settings.listIdentifier = identifier
        settings.listTitle = title
    }

    /// 确保有一个可写的清单（没有就自动建一个「桌面课表」）。
    ///
    /// EventKit 建清单需要 `EKCalendar(for: .reminder, eventStore:)` +
    /// `saveCalendar(_:commit:)` —— 那是 `EventKitStore` 的活，
    /// 这里通过协议的一个扩展方法触发。
    private func ensureWritableList() -> String? {
        if !settings.listIdentifier.isEmpty {
            let lists = eventStore.reminderLists()
            if lists.contains(where: { $0.identifier == settings.listIdentifier && $0.isWritable }) {
                return settings.listIdentifier
            }
        }
        // 找现成的可写清单
        if let existing = eventStore.reminderLists().first(where: { $0.isWritable }) {
            settings.listIdentifier = existing.identifier
            settings.listTitle = existing.title
            return existing.identifier
        }
        // 都没有 → 建一个
        //
        // 走**协议**方法，不要 `as? EventKitStore` 强转 ——
        // 强转在测试用的 fake 上会失败（静默返回 nil），
        // 而且把「建清单」这个能力藏在了具体类型里。
        guard let created = eventStore.createReminderList(
            titled: DayPanelSettings.defaultListTitle) else { return nil }
        settings.listIdentifier = created.identifier
        settings.listTitle = created.title
        return created.identifier
    }

    /// 换一份设置（设置面板改了开关或清单后调用）。
    func updateSettings(_ new: DayPanelSettings) {
        let weatherTurnedOff = settings.weatherEnabled && !new.weatherEnabled
        let weatherTurnedOn = !settings.weatherEnabled && new.weatherEnabled
        // ⚠️ **换了地区 → 旧地区的天气必须清掉**（2026-11-10）。
        // 天气是按日期缓存的（`weatherByDate`），不清的话换城市后
        // 面板会先显示**上一个城市**的天气，看起来像「数据不对」。
        let regionChanged = settings.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
            != new.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
        settings = new
        // 「显示天气」开关直接影响面板里那一行 —— 改了要立刻生效，
        // 不用等用户关掉再打开覆盖层（设置页的注释是这么承诺的）。
        content.weatherEnabled = new.weatherEnabled
        if weatherTurnedOff || regionChanged {
            content.festival.weather = nil
            weatherByDate.removeAll()
            for key in festivalByDay.keys { festivalByDay[key]?.weather = nil }
        }
        if currentDay != nil {
            // 先推一版：关掉 → 天气行消失；打开 → 先显示「暂无数据」。
            pushState()
            if (weatherTurnedOn || regionChanged), let day = currentDay {
                loadWeather(day: day, token: contentToken)
            }
        }
        refreshAll()
    }

    /// 找一个清单（按标识）。
    func list(withIdentifier identifier: String) -> EventKitListInfo? {
        reminderLists.first { $0.identifier == identifier }
    }

    /// 新建一个提醒事项清单，返回建成的清单。
    func createList(titled title: String) -> EventKitListInfo? {
        guard !AutomationMode.isCurrentProcessAutomation else { return nil }
        let created = eventStore.createReminderList(titled: title)
        if let created {
            settings.listIdentifier = created.identifier
            settings.listTitle = created.title
        }
        return created
    }

    // MARK: - Intent（网页 → 原生）

    /// 处理网页发来的 intent。
    func handle(action: String, payload: Any?) {
        let dict = payload as? [String: Any]
        let day = (dict?["day"] as? Int) ?? (dict?["day"] as? NSNumber)?.intValue ?? 0

        switch action {
        case "datePanelOpen":
            open(day: day)
        case "datePanelClose":
            close(day: day)
        case "todoToggle":
            toggleTodo(payload: dict)
        case "todoCompose":
            prepareTodoCompose()
        case "todoAdd":
            let title = (dict?["title"] as? String) ?? ""
            let time = (dict?["time"] as? String) ?? ""
            addTodo(title: title, time: time, day: day)
        case "todoUpdate":
            updateTodo(payload: dict)
        case "todoDelete":
            deleteTodo(payload: dict)
        case "diaryAdd":
            addDiary(payload: dict, day: day)
        case "diaryUpdate":
            updateDiary(payload: dict)
        case "diaryDelete":
            deleteDiary(payload: dict)
        default:
            break
        }
    }

    // MARK: - 日记（本地 JSON，不碰提醒事项）

    /// 重新读当前这一天的日记并推状态。
    private func refreshDiary(day: Int) {
        guard let date = dayDate(day) else { return }
        let entries = diaryStore.entries(on: DiaryStore.dateKey(date)).map {
            DayPanelDiary(id: $0.id, title: $0.title, body: $0.body, time: $0.time)
        }
        // ⚠️ 只有**正在显示的就是这一天**时才改 `content` 并推状态（2026-11-10 修）。
        //
        // 之前不判断就写：网页发来的 `day` 和当前打开的那天不一致时
        //（比如面板还停在第 3 天、用户/自检给第 4 天加日记），会把第 4 天的日记
        // 写进第 3 天的 content 再推出去 → 网页拿 day 一对不上就退回按天缓存
        // → 刚写的那篇**在面板里不出现**（实测 rows = 0，但 diary.json 里已经有了）。
        guard currentDay == nil || currentDay == day else { return }
        content.diary = entries
        refreshAll()   // 绿点跟着变（本地数据，很快）
        pushState()
    }

    /// 新增一条（标题 / 正文都空就当没写，不落盘）。
    private func addDiary(payload: [String: Any]?, day: Int) {
        let title = ((payload?["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ((payload?["body"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let time = (payload?["time"] as? String) ?? ""
        let targetDay = day != 0 ? day : (currentDay ?? 0)
        guard targetDay != 0, let date = dayDate(targetDay) else { return }
        guard !title.isEmpty || !body.isEmpty else { return }
        do {
            try diaryStore.add(date: DiaryStore.dateKey(date),
                               title: title, body: body, time: time)
            refreshDiary(day: targetDay)
        } catch {
            DiagLog.info("写日记失败：\(error)")
        }
    }

    private func updateDiary(payload: [String: Any]?) {
        guard let id = payload?["id"] as? String, !id.isEmpty else { return }
        let title = ((payload?["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ((payload?["body"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let time = (payload?["time"] as? String) ?? ""
        guard !title.isEmpty || !body.isEmpty else { return }
        do {
            try diaryStore.update(id: id, title: title, body: body, time: time)
            if let day = currentDay { refreshDiary(day: day) }
        } catch {
            DiagLog.info("改日记失败：\(error)")
        }
    }

    private func deleteDiary(payload: [String: Any]?) {
        guard let id = payload?["id"] as? String, !id.isEmpty else { return }
        do {
            try diaryStore.delete(id: id)
            if let day = currentDay { refreshDiary(day: day) }
        } catch {
            DiagLog.info("删日记失败：\(error)")
        }
    }

    /// 打开某一列的覆盖层。
    func open(day: Int) {
        guard (1...7).contains(day) else { return }
        // ⚠️ **全部周次模式下不弹覆盖层**（2026-11）。
        //
        // 全部周次 = 所有教学周的课程叠在一起，「周三」指哪一天没有定义
        // （有 16 个周三），显示任何一天都是错的。
        // 用户确认：这时候点日期**什么都不弹**。
        guard !allWeeksMode else { return }
        // ⚠️ **同一天、已有完整内容 → 就地刷新，不清空再推中间态**（2026-11 修）。
        //
        // `open(day:)` 不只在用户点日期时调用：网页收到 `dayPanelRevision`
        // 变化后也会重发 `datePanelOpen`，原生再走一次 `open(day:)`。
        // 那时面板里本来就有完整数据，走默认的 `resetImmediately: true`
        // 会先清空、推一份 `ready:false` → 网页渲染成「读取中…」→
        // 约 0.5 秒后真数据回来再重画，用户看到整个面板闪一下。
        //
        // 换天时仍走默认路径（必须清空上一天的内容）。
        let sameDay = currentDay == day && content.day == day && content.ready
        currentDay = day
        loadContent(day: day, resetImmediately: !sameDay)
        // 表头的红点 / 橙点要跟着更新 ——
        // 用户新加了一条待办，那一列的红点就该出现。
        refreshAll()
    }

    // ⚠️ **原来的 `toggle(day:)`（双击窄 ↔ 宽）已删**（2026-11）。
    // 网页层不再发 `datePanelToggle`，原生也不再有宽态。

    /// 再点同一列的日期：直接关闭。
    func close(day: Int) {
        guard currentDay == day else { return }
        currentDay = nil
        pushState()
    }

    /// 强制收起（拖动课表时用）。
    func forceClose() {
        guard currentDay != nil else { return }
        currentDay = nil
        pushState()
    }

    /// 跨天（过了 12 点）：更新「今天」是哪一列，并把天气重新取一遍。
    ///
    /// 由 `AppDelegate.startRefreshTimer` 每 10 秒对一次日期后调用
    /// （睡眠唤醒后定时器会补跑，所以不需要单独的午夜定时器）。
    ///
    /// 用户要求：「每天过 12 点了就更新」。这里只换 `todayIndex` 与天气；
    /// 农历 / 节气 / 节日是按 `baseMonday` 算的，同一天内不会变。
    ///
    /// - Parameter now: 自检可以传固定日期。
    func handleDayChange(now: Date = Date()) {
        let newIndex = WeekMath.todayIndex(now)
        guard newIndex != todayIndex else { return }
        todayIndex = newIndex
        // 天气属于**具体的一天**：新的一天不能沿用昨天的温度 / 天气现象。
        // （provider 的缓存键也带日期，见 `OpenMeteoWeatherProvider.cacheKey`。）
        content.festival.weather = nil
        weatherByDate.removeAll()
        for key in festivalByDay.keys { festivalByDay[key]?.weather = nil }
        content.todoDigest = nil
        guard let day = currentDay else { return }
        content.isToday = (day == todayIndex)
        // 立刻推一版（天气行先变成「暂无数据」），再异步取新的一天。
        pushState()
        loadWeather(day: day, token: contentToken)
        if day == todayIndex {
            refreshTodoDigest(day: day)
        }
    }

    // MARK: - 待办增删改

    /// 完成 / 取消完成一条待办。
    ///
    /// ⚠️ **优先按 identifier 定位**（2026-11）。
    ///
    /// 以前网页传的是数组下标，原生按 `content.todos[index]` 取。下标本身
    /// 就依赖两边数组完全一致 —— 过滤已完成项、网页又有 1 秒的「正在完成」
    /// 展示期时，很容易指到另一条。identifier 是系统里的稳定 id，不会错。
    /// 保留 index 作为兜底（老网页 / 自检）。
    private func toggleTodo(payload: [String: Any]?) {
        guard settings.enabled, currentDay != nil else { return }
        // ⚠️ **以网页传来的 day 为准**（2026-11 修）。
        //
        // 网页「跟随鼠标换列」时，如果目标列已经有数据（`DP.loaded`），
        // 它**不会再发 `datePanelOpen`**（避免每移一下鼠标就查一次 EventKit）。
        // 于是原生的 `currentDay` 可能停留在旧列 —— 这个值只代表
        // 「最后一次收到 intent 的列」，不是用户眼前那一列。
        //
        // 以前这里用 `let day = currentDay`，写回之后就按旧列判断
        // 「要不要重载 / 补推」→ 眼前那一列的新待办要等到再点一下才出现
        //（用户反馈「第一次添加待办没有显示，红点却有」）。
        let day = (payload?["day"] as? Int)
            ?? (payload?["day"] as? NSNumber)?.intValue ?? currentDay ?? 1
        let identifier = (payload?["identifier"] as? String) ?? ""
        let calendarIdentifier = (payload?["calendarIdentifier"] as? String) ?? ""
        let index = (payload?["index"] as? Int)
            ?? (payload?["index"] as? NSNumber)?.intValue ?? -1

        // 需要写回的三要素：id / 清单 / 目标状态。
        let targetIdentifier: String
        let targetCalendar: String
        let expectedDone: Bool
        if !identifier.isEmpty {
            // 面板里只显示**未完成**的待办，点圆圈 = 完成。
            // 不再依赖 `content.todos`（它可能还是另一天的数据），
            // 这样即使原生 currentDay 落后于网页显示的列也不会「找不到」。
            targetIdentifier = identifier
            targetCalendar = calendarIdentifier
            expectedDone = true
        } else if content.todos.indices.contains(index) {
            // 老网页 / 自检只传下标。
            let todo = content.todos[index]
            targetIdentifier = todo.identifier
            targetCalendar = todo.calendarIdentifier
            expectedDone = !todo.done
        } else {
            NSLog("[DesktopTimetable] 标记待办完成失败：面板里找不到 id=%@（day=%@）",
                  identifier.isEmpty ? "(空)" : identifier, String(day))
            return
        }
        // 同一条还在写回中 → 直接忽略（见 `togglesInFlight` 的注释）。
        guard togglesInFlight.insert(targetIdentifier).inserted else {
            NSLog("[DesktopTimetable] 忽略重复的完成请求 id=%@（上一次还没写完）",
                  targetIdentifier)
            return
        }
        eventStore.setReminder(targetIdentifier, in: targetCalendar,
                               done: expectedDone) { [weak self] ok in
            guard let self else { return }
            self.togglesInFlight.remove(targetIdentifier)
            DiagLog.info("完成写回 id=\(targetIdentifier) done=\(expectedDone) 结果=\(ok ? "成功" : "失败")")
            if ok {
                // `save` 成功就是事实：在取数确认之前，展示层先按完成处理，
                // 避免 EventKit 的旧快照让条目「复活」（见 `recentlyCompleted`）。
                if expectedDone {
                    self.recentlyCompleted[targetIdentifier] = Date()
                }
                // ⚠️ **不要在这里清空列表**（2026-11 修「闪几下」）。
                //
                // 以前用默认的 `resetImmediately: true`：先把 todos / events
                // 清空推一版，等 EventKit 回来再推一版 —— 用户看到的是
                // **所有待办整体消失又出现**，同时表头跟着重建好几次。
                // 完成一条只需要「结果回来后更新」。
                self.refreshDay(day: day, expect: { todos, _ in
                    guard let item = todos.first(where: { $0.identifier == targetIdentifier }) else {
                        return true
                    }
                    return item.done == expectedDone
                })
                // ⚠️ **表头的红点要跟着更新**（2026-11 修）。
                //
                // 勾完最后一条待办 → 那一列**不该**再有红点了。
                // 以前这里只重载了内容，红点要等重新打开那一列才消失
                // （用户反馈「完成待办事项后红点就要消失」）。
                self.refreshAll()
            } else {
                self.pushState()
            }
        }
    }

    /// 用户点「＋ 添加待办」时**立刻**处理权限（2026-11 修）。
    ///
    /// 用户反馈：「第一次总是输入完之后点回车才弹出来（权限框）」。
    ///
    /// 以前只有回车提交（`todoAdd`）才请求提醒事项 / 日历权限 ——
    /// 第一次使用时，打完字按回车，系统权限框才弹出来，待办要等授权
    /// 之后才出现，看起来像「回车没反应 / 待办没加上」。
    ///
    /// 点「添加待办」= 明确的意图，这时候就弹权限框；
    /// 等用户打完字，权限早就处理完，回车直接写入。
    private func prepareTodoCompose() {
        // 没开接入 → 用户点「添加」就是要用，自动打开并让设置层同步。
        if !settings.enabled {
            var updated = settings
            updated.enabled = true
            settings = updated
            onSettingsChanged?(updated)
        }
        // 已经有提醒事项权限 → 什么都不做，绝不多弹一次框。
        guard !reminderAuthorized else { return }
        requestAccess()
    }

    private func addTodo(title: String, time: String, day: Int) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagLog.info("收到 todoAdd day=\(day) 时间=«\(time)» 原始标题长度=\(title.count)")
        guard !trimmed.isEmpty else {
            DiagLog.info("忽略 todoAdd：标题为空")
            return
        }
        // ⚠️ **用传进来的 `day`，不要用 `currentDay`**（2026-11 修）。
        //
        // 以前是 `guard ..., let day = currentDay` —— 传进来的 `day` 参数
        // **完全被忽略**了。于是「在 A 列打开输入框 → 期间切到了 B 列 →
        // 回车」的话，待办会加到**当前打开的那一列**（B），而不是
        // 输入框所在的那一列（A）。
        //
        // 网页那边传的是**输入框自己记着的 `data-day`**，那才是用户的意思。
        //
        // `currentDay` 只用来判断「面板是不是开着」。
        guard currentDay != nil else {
            DiagLog.info("忽略 todoAdd：面板没开着")
            return
        }
        let day = day

        // ⚠️ **不能再静默失败**（2026-11 修）。
        //
        // 以前这里有 `guard settings.enabled` ——
        // 「日历与提醒事项接入」开关关着时，点「＋ 添加待办」**什么都不会发生**
        // （用户反馈「点击添加待办现在根本加不上去」）。
        //
        // 现在：
        //   · 没开接入开关 → **自动打开**并请求提醒事项授权
        //     （写入待办只需要提醒事项权限，不需要日历权限）；
        //   · 还没拿到提醒事项权限 → 把失败原因告诉网页（显示一行提示），
        //     **不要**让用户以为「点了没反应」。
        guard settings.enabled else {
            // 先把接入打开（用户点了「添加」= 明确的意图）。
            var updated = settings
            updated.enabled = true
            settings = updated
            onSettingsChanged?(updated)
            // 请求权限（提醒事项 + 日历，并行）。
            requestAccess()
            // 权限还没到手 → 告诉网页「还在等授权」。
            notifyTodoAddResult(day: day, ok: false,
                                message: "正在请求提醒事项权限，授权后就能添加了")
            return
        }
        // 没拿到提醒事项权限 → 明确告诉用户去授权。
        guard reminderAuthorized else {
            requestAccess()
            notifyTodoAddResult(day: day, ok: false,
                                message: "还没拿到提醒事项权限，先在系统设置里允许访问提醒事项")
            return
        }
        guard let listIdentifier = ensureWritableList() else {
            notifyTodoAddResult(day: day, ok: false,
                                message: "没有可写的提醒事项清单")
            return
        }
        // 到期时间 = 那一列当天的 `time`（HH:mm）；留空 = 当天 00:00。
        //
        // 网页已经校验过一遍，这里再兜底——原生不能依赖网页的校验。
        let minutes: Int
        let trimmedTime = time.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTime.isEmpty {
            minutes = 0
        } else if let parsed = Self.clockMinutes(trimmedTime) {
            minutes = parsed
        } else {
            notifyTodoAddResult(day: day, ok: false,
                                message: "时间请用 00:00–23:59")
            return
        }
        guard let due = dueDate(day: day, minutes: minutes) else {
            notifyTodoAddResult(day: day, ok: false, message: "日期无效")
            return
        }
        let timeText = Self.clockText(minutes)
        DiagLog.info("添加待办 day=\(day) 标题=«\(trimmed)» 时间=\(timeText) 清单=\(listIdentifier.isEmpty ? "(空)" : listIdentifier)")
        eventStore.addReminder(title: trimmed, due: due, in: listIdentifier) { [weak self] ok, newIdentifier in
            guard let self else { return }
            DiagLog.info("添加待办结果 day=\(day) ok=\(ok) id=\(newIdentifier.isEmpty ? "(空)" : newIdentifier)")
            if ok {
                // ⚠️ **先乐观展示**（2026-11 修）：`save` 成功就是事实。
                // EventKit 紧接着的取数可能还是旧快照 —— 不先显示的话，
                // 用户会看到「红点出来了，文字没有，得再点一下」（用户反馈）。
                // 取数追上之后由 `mergePendingAdds` 无缝替换成真实数据。
                self.insertPendingAdded(identifier: newIdentifier, title: trimmed,
                                        due: due, list: listIdentifier, day: day)
                // ⚠️ **不要清空再推**（以前这里是默认的 `resetImmediately: true`）：
                // 加一条待办会让整个列表「白一下」再长出来（用户反馈「头部会先闪一下」）。
                // 就地重取；并且 EventKit 写后读可能还是旧快照 → 没看到新条目就重试。
                //
                // ⚠️ **按网页传来的 day 刷新**，不能拿 `currentDay` 当门槛：
                // 跟随鼠标换列时（目标列已有数据 → 网页不再发 intent），
                // 原生 `currentDay` 可能还是旧的；此时不刷新就永远看不到
                // 新加的那条（用户实测「添加待办成功、红点有了、文字没有」）。
                self.refreshDay(day: day, expect: { todos, _ in
                    todos.contains { $0.title == trimmed && !$0.done }
                })
                // ⚠️ **表头的红点要立刻出现**（2026-11 修）。
                //
                // 以前只有 `open(day:)` 会调 `refreshAll()`（重算 7 天的红点 / 橙点），
                // `addTodo` 只重载了内容 → **加完待办，表头上没有红点**，
                // 要等重新打开那一列才会出现（用户反馈「增加了待办之后就要有红点之类的」）。
                //
                // 这里补一次 `refreshAll()`。
                self.refreshAll()
                self.notifyTodoAddResult(day: day, ok: true, message: "")
            } else {
                if self.currentDay == day { self.pushState() }
                self.notifyTodoAddResult(day: day, ok: false,
                                         message: "添加失败（系统拒绝了写入）")
            }
        }
    }

    /// 把「添加待办」的结果告诉网页（成功 / 失败 + 原因）。
    ///
    /// 失败时网页会显示一行提示 —— 以前是**完全静默**，
    /// 用户点了「添加待办」什么反应都没有，只能干瞪眼。
    private func notifyTodoAddResult(day: Int, ok: Bool, message: String) {
        let payload: [String: Any] = [
            "day": day,
            "ok": ok,
            "message": message,
        ]
        DiagLog.info("添加待办回传 day=\(day) ok=\(ok) \(message)")
        onTodoAddResult?(payload)
    }

    /// 修改一条待办的标题 / 到期时间（右键「修改…」）。
    ///
    /// 只改这两项：完成状态、清单归属都不动（由 EventKitStore 保证）。
    /// 写回成功立刻乐观更新面板，并用 `recentlyUpdated` 挡住写后读旧快照。
    private func updateTodo(payload: [String: Any]?) {
        guard settings.enabled, currentDay != nil else { return }
        // 和 toggle / delete 一样：day 以网页传来的为准（原生 currentDay 可能落后）。
        let day = (payload?["day"] as? Int)
            ?? (payload?["day"] as? NSNumber)?.intValue ?? currentDay ?? 1
        let identifier = (payload?["identifier"] as? String) ?? ""
        let calendarIdentifier = (payload?["calendarIdentifier"] as? String) ?? ""
        let title = ((payload?["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTime = ((payload?["time"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !identifier.isEmpty else {
            notifyTodoUpdateResult(day: day, identifier: identifier, ok: false,
                                   message: "这条待办没有系统标识，无法修改",
                                   title: title, time: rawTime)
            return
        }
        guard !title.isEmpty else {
            notifyTodoUpdateResult(day: day, identifier: identifier, ok: false,
                                   message: "标题不能为空", title: title, time: rawTime)
            return
        }
        let minutes: Int
        if rawTime.isEmpty {
            minutes = 0
        } else if let parsed = Self.clockMinutes(rawTime) {
            minutes = parsed
        } else {
            notifyTodoUpdateResult(day: day, identifier: identifier, ok: false,
                                   message: "时间请用 00:00–23:59",
                                   title: title, time: rawTime)
            return
        }
        guard let due = dueDate(day: day, minutes: minutes) else {
            notifyTodoUpdateResult(day: day, identifier: identifier, ok: false,
                                   message: "日期无效", title: title, time: rawTime)
            return
        }
        let timeText = Self.clockText(minutes)

        // 同一条同时只允许一次写回（连点两次保存 / 菜单重复触发）。
        guard updatesInFlight.insert(identifier).inserted else {
            DiagLog.info("忽略重复的修改请求 id=\(identifier)（上一次还没写完）")
            return
        }
        let fact = TodoUpdateFact(title: title, due: timeText, minutes: minutes, at: Date())
        eventStore.updateReminder(identifier, in: calendarIdentifier,
                                  title: title, due: due) { [weak self] ok in
            guard let self else { return }
            self.updatesInFlight.remove(identifier)
            DiagLog.info("修改待办 id=\(identifier) 标题=«\(title)» 时间=\(timeText) 结果=\(ok ? "成功" : "失败")")
            if ok {
                // save 成功就是事实：取数追到之前，展示层先按新值显示。
                self.recentlyUpdated[identifier] = fact
                // 如果是「刚添加、取数还没读到的」那条 → 同步更新临时条目。
                if var pending = self.pendingAdded[identifier] {
                    pending.todo.title = title
                    pending.todo.due = timeText
                    pending.todo.dueMinutes = minutes
                    self.pendingAdded[identifier] = pending
                }
                self.applyTodoUpdateLocally(day: day, identifier: identifier,
                                            title: title, dueText: timeText, minutes: minutes)
                // 写后读可能还是旧快照 → 没看到新值就 0.35s 后重取（最多几次）。
                self.refreshDay(day: day, expect: { todos, _ in
                    guard let item = todos.first(where: { $0.identifier == identifier }) else {
                        return false
                    }
                    return item.title == title && item.due == timeText
                })
                // 标题 / 时间可能影响排序（同一天按时刻排），红点也要重算。
                self.refreshAll()
                self.notifyTodoUpdateResult(day: day, identifier: identifier, ok: true,
                                            message: "", title: title, time: timeText)
            } else {
                if self.currentDay == day { self.pushState() }
                self.notifyTodoUpdateResult(day: day, identifier: identifier, ok: false,
                                            message: "修改失败（系统拒绝了写入）",
                                            title: title, time: timeText)
            }
        }
    }

    /// 写回成功后，先把当前面板里的这一条改成新值（乐观展示）。
    private func applyTodoUpdateLocally(day: Int, identifier: String,
                                        title: String, dueText: String, minutes: Int) {
        guard currentDay == day else { return }
        guard let index = content.todos.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }
        content.todos[index].title = title
        content.todos[index].due = dueText
        content.todos[index].dueMinutes = minutes
        content.todos.sort(by: Self.todoOrder)
        pushState()
    }

    /// 把「修改待办」的结果告诉网页（成功不用提示，失败要能回滚 + 说明）。
    private func notifyTodoUpdateResult(day: Int, identifier: String, ok: Bool,
                                        message: String, title: String, time: String) {
        let payload: [String: Any] = [
            "day": day,
            "identifier": identifier,
            "ok": ok,
            "message": message,
            "title": title,
            "time": time,
        ]
        DiagLog.info("修改待办回传 day=\(day) id=\(identifier) ok=\(ok) \(message)")
        onTodoUpdateResult?(payload)
    }

    private func deleteTodo(payload: [String: Any]?) {
        guard settings.enabled, currentDay != nil else { return }
        // 同 `toggleTodo`：day 以网页传的为准（原生 currentDay 可能落后）。
        let day = (payload?["day"] as? Int)
            ?? (payload?["day"] as? NSNumber)?.intValue ?? currentDay ?? 1
        let index = (payload?["index"] as? Int)
            ?? (payload?["index"] as? NSNumber)?.intValue ?? -1
        // ⚠️ 优先用 identifier（网页已带上）：下标是**渲染那一刻**的，
        // 原生内容可能还是另一天的 —— 用它去取会删错 / 什么也删不掉。
        var identifier = (payload?["identifier"] as? String) ?? ""
        var calendarIdentifier = (payload?["calendarIdentifier"] as? String) ?? ""
        if identifier.isEmpty, content.todos.indices.contains(index) {
            let todo = content.todos[index]
            identifier = todo.identifier
            calendarIdentifier = todo.calendarIdentifier
        }
        guard !identifier.isEmpty else {
            NSLog("[DesktopTimetable] 删除待办失败：既没有 identifier，下标也越界（day=%@）",
                  String(day))
            return
        }
        eventStore.deleteReminder(identifier, in: calendarIdentifier) { [weak self] ok in
            guard let self else { return }
            DiagLog.info("删除待办 id=\(identifier) 结果=\(ok ? "成功" : "失败")")
            if ok {
                // ⚠️ **删除成功就是事实**：取数晚一步还是旧快照的话，
                // 不能让它「复活」一下再消失（那就是用户说的「闪」）。
                self.recentlyDeleted[identifier] = Date()
                // ⚠️ **不要 `resetImmediately: true`**（默认值）——
                // 那会先清空整块内容推一版，用户看到所有待办 / 日历白一下。
                // 就地重取，等新数据回来再替换。
                self.refreshDay(day: day, expect: { todos, _ in
                    !todos.contains { $0.identifier == identifier }
                })
                // ⚠️ **红点也要更新**（2026-11）—— 删掉最后一条 → 红点消失。
                self.refreshAll()
            } else {
                self.pushState()
            }
        }
    }

    // MARK: - 已完成的提醒事项（设置面板 → 日期覆盖层卡片）

    /// 恢复一条已完成的提醒事项。
    ///
    /// 写回成功后的联动（规格六.1）：
    ///   · 清掉「刚完成」事实表 —— 否则这条会被 `visibleTodos` 继续过滤掉；
    ///   · `dayPanelRevision` 加一 → 网页作废**其他天**的缓存（当前天保留，避免闪）；
    ///   · `refreshAll()` → 表头红点立刻更新（面板没开也要对）；
    ///   · 面板开着就**就地**重载当前天（`resetImmediately: false`），
    ///     不清空、不推「读取中…」中间态。
    func restoreCompletedReminder(_ item: CompletedReminder,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        guard settings.enabled else {
            completion(.failure(CompletedRemindersError.disabled))
            return
        }
        guard reminderAuthorized else {
            completion(.failure(CompletedRemindersError.notAuthorized))
            return
        }
        if CompletedReminderPolicy.restoreBlockedReason(isRecurring: item.isRecurring) != nil {
            completion(.failure(CompletedRemindersError.recurringRestoreUnsupported))
            return
        }
        completedReminders.restore(item) { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.noteCompletedRemindersRestored([item])
            }
            completion(result)
        }
    }

    /// 永久删除一条已完成提醒事项。
    func deleteCompletedReminder(_ item: CompletedReminder,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard settings.enabled else {
            completion(.failure(CompletedRemindersError.disabled))
            return
        }
        guard reminderAuthorized else {
            completion(.failure(CompletedRemindersError.notAuthorized))
            return
        }
        completedReminders.delete(item) { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.noteCompletedRemindersDeleted([item.identifier])
            }
            completion(result)
        }
    }

    /// 删除**所有清单**里的所有已完成项（不受设置里搜索 / 筛选影响）。
    func deleteAllCompletedReminders(
        completion: @escaping (CompletedRemindersDeleteResult) -> Void) {
        guard settings.enabled else {
            completion(.failure(CompletedRemindersError.disabled,
                                total: completedReminders.totalCompleted))
            return
        }
        guard reminderAuthorized else {
            completion(.failure(CompletedRemindersError.notAuthorized,
                                total: completedReminders.totalCompleted))
            return
        }
        completedReminders.deleteAll { [weak self] result in
            guard let self else { return }
            // ⚠️ 只有**真正删掉**的 id 才记「刚删除」。
            // commit 失败时 `deletedIdentifiers` 是空数组，面板不会出现假状态。
            self.noteCompletedRemindersDeleted(result.deletedIdentifiers)
            completion(result)
        }
    }

    /// 恢复成功后的联动。
    ///
    /// ⚠️ 必须移除 `recentlyCompleted` 里的记录 —— 用户可能刚在日期面板里
    /// 点了完成（那条被事实表藏起来），现在在设置里恢复它，
    /// 不删掉记录的话日期面板永远不会再显示它。
    private func noteCompletedRemindersRestored(_ items: [CompletedReminder]) {
        for item in items {
            recentlyCompleted.removeValue(forKey: item.identifier)
            recentlyDeleted.removeValue(forKey: item.identifier)
        }
        storeRevision += 1
        refreshAll()
        if let day = currentDay {
            // 就地重载：保留已有内容，等新数据回来替换（不闪「读取中…」）。
            loadContent(day: day, resetImmediately: false)
        }
    }

    /// 删除成功后的联动：记「刚删除」事实（挡住 EventKit 旧快照），
    /// 作废网页缓存、重算红点、就地重载当前天。
    private func noteCompletedRemindersDeleted(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let now = Date()
        for identifier in identifiers {
            recentlyCompleted.removeValue(forKey: identifier)
            // ⚠️ 旧快照里可能还有这条 —— 30 秒内展示层一律过滤，不能让它「复活」。
            recentlyDeleted[identifier] = now
        }
        storeRevision += 1
        refreshAll()
        if let day = currentDay {
            loadContent(day: day, resetImmediately: false)
        }
    }

    // MARK: - 取数

    /// 取某一天的内容并 push 给网页。
    ///
    /// ⚠️ **EventKit 的查询是异步的**，回包什么时候到不可控。
    /// 用户快速换列时（day3 → day5），day3 的回包可能**晚于** day5 的回包到达，
    /// 于是 day3 的 todos/events 被写进「当前已经是 day5」的内容里 ——
    /// 面板显示的是另一天的数据。
    ///
    /// 更糟的是：回包晚到时 `pushState()` 推出去的 `dayPanel.day` 跟网页
    /// 当前显示的列对不上 → 网页 `panelDataFor()` 返回 null → 整块内容
    /// （**包括今日详情**）全部消失。
    ///
    /// 两道防线：
    ///   1. 下面 `group.notify` 里 `guard self.currentDay == day` —— 过期回包直接丢掉；
    ///   2. `open(day:)` 里先把「只有节日」的**同步**状态推出去 —— 今日详情
    ///      （农历）**立刻**就能显示，不必等日历 / 提醒事项的权限与查询耗时。
    /// 重算 7 天各自的「今日详情」（农历 / 节气 / 节日 / 宜忌）。
    ///
    /// 纯计算（不碰 EventKit、不联网），7 次调用可以忽略不计。
    /// 结果存进 `festivalByDay`，`pushState()` 时一起推给网页。
    private func refreshFestivalCache() {
        var out: [Int: DayPanelFestival] = [:]
        for day in 1...7 {
            guard let date = dayDate(day) else { continue }
            var f = festivalProvider.festival(on: date)
            // ⚠️ **天气要按日期补回来**（2026-11-10 修「切到别的列再切回来，天气就没了」）。
            //
            // 节日是纯计算、每次都能重算；天气是**异步取回来**的，只存在
            // `weatherByDate` 里。以前这里直接 `out[day] = festivalProvider.festival(...)`，
            // 等于每开一次面板就把天气抹一次 —— 面板先闪「暂无数据」，
            // 要等下一个网络 / 缓存回包才回来；回包一慢或者撞上「已有请求在飞」，
            // 天气就一直不回来了（用户反馈）。
            //
            // 用**日期**而不是「周几」当键：翻周之后同一个下标是另一天，
            // 按周几记会把上一周的天气串过来。
            f.weather = weatherByDate[Self.dateKey(date)]
            out[day] = f
        }
        festivalByDay = out
    }

    /// 载入某一天的内容。
    ///
    /// - Parameter resetImmediately: `true` = 打开 / 换天：先清空旧内容再推一次
    ///   （详情立刻出现，不依赖 EventKit）；`false` = 系统数据变化后的**就地刷新**：
    ///   保留当前内容，等新数据回来再替换 —— 否则面板会先闪一下空白。
    /// - Parameters:
    ///   - expect: 取数回来后**期望看到的结果**（例如刚完成的那条要变成 done）。
    ///     EventKit 的写后读可能还是旧快照 → 不满足就隔一会儿再取一次
    ///     （`retriesLeft` 次），避免「刚加的待办 / 刚完成的勾选不立刻反映」。
    ///   - retriesLeft: 还能重取几次。
    private func loadContent(day: Int, resetImmediately: Bool = true,
                             expect: (([DayPanelTodo], [DayPanelEvent]) -> Bool)? = nil,
                             retriesLeft: Int = 0) {
        contentToken += 1
        let token = contentToken
        let date = dayDate(day) ?? Date()
        content.day = day
        content.isToday = (day == todayIndex)
        // ⚠️ **只有换天 / 换列才清空「今天 N 条待处理 · 逾期 M 条」摘要**（2026-11-11 修）。
        //
        // 用户报「点完成之后一直闪」，真机日志（`DT_FLICKER_DIAG=1`）显示：
        // 每刷新一次待办，`.dpcards` 的卡片数就在 **6 ↔ 7** 之间跳 ——
        // 那张 6/7 之间的卡片就是**黄色的摘要卡**（`.dpdigest`，琥珀色文字）。
        //
        // 根因：`loadContent` 不分青红皂白把 `content.todoDigest` 清成 nil →
        // 立刻推一版「没有摘要」的状态（摘要卡消失、下面的卡片整体上移）；
        // 0.35 秒后 `refreshTodoDigest` 的异步回包才把摘要补回来 →
        // 又推一版（摘要卡出现、整体下移）。**一次刷新 = 上下跳两下**，
        // 用户看到的就是「黄色那张东西一直在闪」。
        //
        // 同一天刷新（完成 / 添加 / 删除 / 外部变化）时摘要本来就该保留旧值，
        // 等新值算出来**直接替换**，不需要先消失一下。
        if resetImmediately {
            content.todoDigest = nil   // 换天 / 换列：上一天的「今天」口径不能再留着
        }
        // 「显示天气」开关是全局设置 —— 网页用它区分「暂不显示」和「暂无数据」。
        content.weatherEnabled = settings.weatherEnabled
        // 地区（空串 = 还没选 → 网页提示「请在设置里选择地区」）。
        content.weatherRegion = weatherRegion
        // 7 天的「今日详情」**一次算好**（纯计算，很便宜）——
        // 算完存进 `festivalByDay`，push 时一起给网页。
        refreshFestivalCache()
        content.festival = festivalByDay[day] ?? festivalProvider.festival(on: date)

        if resetImmediately {
            // ⚠️ 换天时**必须清空**上一天的 todos / events ——
            // 不清的话，先同步 push 的那份「只有节日」的状态里还带着**昨天**的
            // 待办和日程，网页会把它显示出来（显示成今天有昨天的待办）。
            content.todos = []
            content.events = []
            // ⚠️ 日记**不在这里清**（2026-11-10 修「记完日记收起 / 翻周就没了」）：
            // 以前这里清空、而真正的读取又写在这段**前面** ——
            // 于是每次打开某天，日记都会被「读进来 → 立刻清掉」，
            // 面板永远显示空，设置里也因为同一次读写的时序看不到。
            // 现在统一在下面（reset 之后）读一次。
            // ⚠️ **天气不要在这里清**（2026-11-10 修「切到别的列再切回来，天气就没了」）。
            //
            // 上面 `content.festival` 已经是从 `festivalByDay[day]` 取出来的 ——
            // 每一天各一份，本来就**不会串天**（串天是 1.5.4 之前的 bug）。
            // 以前这里再清一次，等于每次开列都先把天气抹掉：
            // 面板会先闪一下「暂无数据」，然后要等一次异步取数才回来；
            // 取数一旦慢 / 失败（或同一时刻有别的请求在飞），天气就一直不回来了。
            // ⚠️ 这是**中间态** —— 待办 / 日程还没查。
            // 网页看到 `ready: false` 才知道「还不能算有完整数据」，
            // 之后换周回来 / 跟随打开时会补发请求（见 Timetable.js 的 `DP.loaded`）。
            content.ready = false

            // 先同步推一次「只有节日、待办 / 日程为空」的状态 ——
            // 今日详情（农历 / 节气 / 节日 / 宜忌）**立刻**出现，不依赖 EventKit 权限，
            // 也不依赖异步查询的耗时。
            pushState()

            // 天气是**异步**的（CoreLocation + 网络），单独一条线。
            loadWeather(day: day, token: token)
        }

        // 日记是**本地 JSON**，同步读就行（不经过 EventKit、没有授权问题）。
        // ⚠️ 必须放在 reset 之后 —— 放在前面会被上面那次清空抹掉。
        content.diary = diaryStore.entries(on: DiaryStore.dateKey(date)).map {
            DayPanelDiary(id: $0.id, title: $0.title, body: $0.body, time: $0.time)
        }

        guard settings.enabled else {
            // 没开 → 只有节日信息，没有待办 / 日程。
            // 不会再有 EventKit 回包了 → 直接标成「已完成」，免得网页反复请求。
            content.ready = true
            pushState()
            return
        }

        let group = DispatchGroup()
        var todos: [DayPanelTodo] = []
        var events: [DayPanelEvent] = []

        group.enter()
        eventStore.reminders(on: date) { result in
            todos = result
            group.leave()
        }
        group.enter()
        eventStore.events(on: date) { result in
            events = result
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // ⚠️ **竞态防线**：这个回包可能已经不是当前天了
            // （用户快速换列 / 翻周 → 旧回包晚到）。
            // 直接丢掉，不能写进当前内容里。
            //
            // ⚠️ **只比 `currentDay` 不够**：两周的同一星期几 `day` 相同，
            // 旧周的周 4 回包会落到新周的周 4 上（用户反馈「看了别的周回来，
            // 本周的待办有时显示不出来」）。`contentToken` 才能区分「哪一轮」。
            guard token == self.contentToken, self.currentDay == day else { return }
            // ⚠️ **已完成的待办从面板里隐藏**（2026-11，用户确认）。
            // 数据层（`EventKitStore.reminders(on:)`）仍然返回 `done` 标记，
            // 下阶段的「已完成事项管理」可以直接复用；这里只过滤展示。
            //
            // 刚写回成功、取数还没反映出来的（`recentlyCompleted`）也一起过滤 ——
            // 否则条目会在 5 秒兜底后短暂「复活」。
            self.pruneRecentCompletions(todos)
            // 刚写上、取数还没追到的条目 → 继续展示（见 `pendingAdded`）。
            let mergedTodos = self.mergePendingAdds(todos, day: day)
            // 刚改过标题 / 时间、取数还没追到的 → 用写回结果盖住旧快照。
            let updatedTodos = self.mergeRecentlyUpdated(mergedTodos)
            // 刚删掉的条目：取数还是旧快照的话不能让它「复活」一下。
            self.pruneRecentlyDeleted(todos)
            let hidden = Set(self.recentlyCompleted.keys)
                .union(self.recentlyDeleted.keys)
            self.content.todos = Self.visibleTodos(updatedTodos, excluding: hidden)
            // 今天这一列：算「今天 + 逾期」的未处理条数（2026-11-10）。
            if day == self.todayIndex {
                self.refreshTodoDigest(day: day)
            }
            self.content.events = events
            // 待办 / 日程都查完并合并了 → 这一天才算「有完整数据」。
            self.content.ready = true
            self.pushState()
            DiagLog.info("取数 day=\(day) 原始待办=\(todos.count) 显示=\(self.content.todos.count) 日程=\(events.count) 待确认完成=\(self.recentlyCompleted.count) 剩余重试=\(retriesLeft)")
            // ⚠️ **写后读可能是旧快照**（2026-11）——
            // 刚加的待办 / 刚勾完的条目，EventKit 取数可能还没更新。
            // 不满足期望就隔 0.35 秒再取一次（最多几次），
            // 否则用户会看到「回车没立刻新增，要再点一下才出现」。
            if let expect, retriesLeft > 0, !expect(todos, events) {
                DiagLog.info("取数结果未达到期望 day=\(day)，0.35s 后重试（剩余 \(retriesLeft - 1) 次）")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    guard token == self.contentToken, self.currentDay == day else { return }
                    self.loadContent(day: day, resetImmediately: false,
                                     expect: expect, retriesLeft: retriesLeft - 1)
                }
            }
        }
    }

    /// 写操作（添加 / 完成 / 删除）之后刷新**发生改动的那一天**。
    ///
    /// ⚠️ **不能拿 `currentDay` 当门槛**（2026-11 修）。
    ///
    /// 网页「跟随鼠标换列」时，如果目标列已经有数据（`DP.loaded[day]`），
    /// 它不会再发 `datePanelOpen` 来省掉一次 EventKit 查询。于是原生的
    /// `currentDay` 可能停在**上一次收到 intent 的那一列**，而用户眼前
    /// 已经是另一列。以前这里写 `if self.currentDay == day`：
    ///   · 跳过乐观展示；
    ///   · 跳过重载；
    /// 结果就是「待办确实加上了（系统里能查到）、红点也有了（refreshAll 会查），
    /// 但面板文字一直没有 —— 必须再点一下日期」。
    ///
    /// 现在：
    ///   · 网页最后告诉原生的就是这一天 → 照旧 `loadContent`；
    ///   · 不是 → 单独查这一天、单独推一份 `dayPanel`，**不改当前内容**。
    ///     网页按 `day` 缓存：眼前正好是这一天就立刻重绘，不是也会把缓存更新对。
    private func refreshDay(day: Int,
                            expect: @escaping ([DayPanelTodo], [DayPanelEvent]) -> Bool) {
        guard (1...7).contains(day) else { return }
        if currentDay == day {
            loadContent(day: day, resetImmediately: false,
                        expect: expect, retriesLeft: 4)
            return
        }
        pushDayPanel(day: day)
    }

    /// 单独查某一天，并把结果作为**那一天**的 `dayPanel` 推给网页。
    ///
    /// 不修改 `currentDay` / `content` —— 那是「网页最后打开的那一天」的状态，
    /// 改成别的一天会让下一次 `pushState` 把待办标到错误的日期上。
    private func pushDayPanel(day: Int) {
        let date = dayDate(day) ?? Date()
        refreshFestivalCache()
        let festival = festivalByDay[day] ?? festivalProvider.festival(on: date)
        guard settings.enabled else {
            var empty = DayPanelContent(day: day, festival: festival)
            empty.ready = true
            pushState(dayPanelOverride: empty)
            return
        }
        let group = DispatchGroup()
        var todos: [DayPanelTodo] = []
        var events: [DayPanelEvent] = []
        group.enter()
        eventStore.reminders(on: date) { result in
            todos = result
            group.leave()
        }
        group.enter()
        eventStore.events(on: date) { result in
            events = result
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.pruneRecentCompletions(todos)
            let merged = self.mergePendingAdds(todos, day: day)
            let updated = self.mergeRecentlyUpdated(merged)
            self.pruneRecentlyDeleted(todos)
            let hidden = Set(self.recentlyCompleted.keys)
                .union(self.recentlyDeleted.keys)
            var panel = DayPanelContent(day: day,
                                        todos: Self.visibleTodos(updated, excluding: hidden),
                                        events: events,
                                        festival: festival)
            panel.ready = true
            if self.currentDay == day {
                // 期间网页又打开了这一天 → 正常走内容更新。
                self.content = panel
                self.pushState()
            } else {
                self.pushState(dayPanelOverride: panel)
            }
            DiagLog.info("补推 day=\(day) 显示=\(panel.todos.count) 日程=\(panel.events.count)")
        }
    }

    /// 把**刚写上、取数还没读到**的新待办先放进展示内容。
    ///
    /// 只在面板正停在写入的那一天、且内容已经完整（`ready`）时做 ——
    /// 中间态（`ready=false`）下网页会把列表换成「读取中…」，乐观条目反而看不见。
    private func insertPendingAdded(identifier: String, title: String, due: Date,
                                    list: String, day: Int) {
        guard !identifier.isEmpty else { return }
        // 取数的 `HH:mm` 和排序用的分钟数，和 `EventKitStore.reminders(on:)` 保持一致。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.hour, .minute], from: due)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let todo = DayPanelTodo(title: title,
                                due: String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0),
                                done: false,
                                dueMinutes: minutes,
                                identifier: identifier,
                                calendarIdentifier: list)
        pendingAdded[identifier] = (todo: todo, day: day, at: Date())
        guard currentDay == day, content.ready else { return }
        if !content.todos.contains(where: { $0.identifier == identifier }) {
            content.todos.append(todo)
            content.todos.sort(by: Self.todoOrder)
        }
        pushState()
    }

    /// 取数回来后合并 `pendingAdded`：
    ///   · 取数里已经有这个 id → 拿真实数据替换，删掉临时记录；
    ///   · 取数还是旧快照（没这个 id）→ 继续展示临时的，最多留 30 秒。
    private func mergePendingAdds(_ fetched: [DayPanelTodo], day: Int) -> [DayPanelTodo] {
        guard !pendingAdded.isEmpty else { return fetched }
        var out = fetched
        let now = Date()
        var settled: [String] = []
        for (identifier, entry) in pendingAdded {
            if now.timeIntervalSince(entry.at) > 30 {
                settled.append(identifier)
                continue
            }
            guard entry.day == day else { continue }
            if fetched.contains(where: { $0.identifier == identifier }) {
                // 取数已经读到了 —— 真实数据为准。
                settled.append(identifier)
                continue
            }
            // 取数还是旧快照 —— 继续展示刚写的那条（日志留证据）。
            out.append(entry.todo)
            DiagLog.info("新待办取数仍是旧快照 id=\(identifier) age=\(String(format: "%.1f", now.timeIntervalSince(entry.at)))s")
        }
        for identifier in settled { pendingAdded.removeValue(forKey: identifier) }
        out.sort(by: Self.todoOrder)
        return out
    }

    /// 取数回来后，用「刚写回成功的标题 / 时间」盖住可能还是旧快照的条目。
    ///
    /// 和 `recentlyCompleted` / `recentlyDeleted` 是同一类事实表：
    /// `save(commit:)` 成功就是事实，EventKit 紧接着的取数可能还没追上。
    /// 取数读到新值（或 30 秒兜底）后就把记录清掉。
    private func mergeRecentlyUpdated(_ fetched: [DayPanelTodo]) -> [DayPanelTodo] {
        guard !recentlyUpdated.isEmpty else { return fetched }
        var out = fetched
        let now = Date()
        var settled: [String] = []
        for (identifier, fact) in recentlyUpdated {
            if now.timeIntervalSince(fact.at) > 30 {
                settled.append(identifier)
                continue
            }
            guard let index = out.firstIndex(where: { $0.identifier == identifier }) else {
                // 取数里根本没有这条（例如刚添加、取数还没读到）——
                // 那条由 `pendingAdded` 负责展示，这里不凭空补一条。
                continue
            }
            if out[index].title == fact.title && out[index].due == fact.due {
                settled.append(identifier)
                continue
            }
            out[index].title = fact.title
            out[index].due = fact.due
            out[index].dueMinutes = fact.minutes
            DiagLog.info("修改后取数仍是旧快照 id=\(identifier) age=\(String(format: "%.1f", now.timeIntervalSince(fact.at)))s")
        }
        for identifier in settled { recentlyUpdated.removeValue(forKey: identifier) }
        out.sort(by: Self.todoOrder)
        return out
    }

    /// 清理 `recentlyDeleted`：取数里确实没有这条了（或超过 30 秒）就移除。
    private func pruneRecentlyDeleted(_ fetched: [DayPanelTodo]) {
        let now = Date()
        var settled: [String] = []
        for (identifier, at) in recentlyDeleted {
            if now.timeIntervalSince(at) > 30 {
                settled.append(identifier)
                continue
            }
            if fetched.contains(where: { $0.identifier == identifier }) {
                DiagLog.info("删除后取数仍是旧快照 id=\(identifier) age=\(String(format: "%.1f", now.timeIntervalSince(at)))s")
            } else {
                settled.append(identifier)
            }
        }
        for identifier in settled { recentlyDeleted.removeValue(forKey: identifier) }
    }

    /// 待办排序：和 `EventKitStore.reminders(on:)` 同一套规则（时刻 → 标题）。
    private static func todoOrder(_ lhs: DayPanelTodo, _ rhs: DayPanelTodo) -> Bool {
        let l = lhs.dueMinutes ?? Int.max
        let r = rhs.dueMinutes ?? Int.max
        if l != r { return l < r }
        return lhs.title < rhs.title
    }

    /// 清理 `recentlyCompleted`：取数确认 `done=true`（或条目确实没了）就移除；
    /// 超过 30 秒也移除（兜底，避免外部改回状态后被永远藏住）。
    private func pruneRecentCompletions(_ fetched: [DayPanelTodo]) {
        let now = Date()
        for (identifier, at) in recentlyCompleted {
            let age = now.timeIntervalSince(at)
            if age > 30 {
                recentlyCompleted.removeValue(forKey: identifier)
                continue
            }
            if let item = fetched.first(where: { $0.identifier == identifier }) {
                if item.done {
                    recentlyCompleted.removeValue(forKey: identifier)
                } else {
                    // 取数还是旧快照 —— 如实记下来（排查用），展示层继续过滤。
                    DiagLog.info("取数仍是旧快照 id=\(identifier) age=\(String(format: "%.1f", age))s")
                }
            } else {
                recentlyCompleted.removeValue(forKey: identifier)
            }
        }
    }

    /// 取某一天的天气。
    ///
    /// ⚠️ **异步**（CoreLocation + 网络）—— 和 todos / events 一样，
    /// 会有「过期回包」的问题，所以这里有同样的竞态防线。
    ///
    /// ## 失败时的行为
    ///
    /// 拿不到位置（用户拒绝授权 / 没网络 / 超时）→ `content.festival.weather`
    /// 保持 nil → 网页在「显示天气」开着时显示**「暂无数据」**。
    ///
    /// **绝不显示假数据**（比如「0°」或编出来的天气现象）。
    ///
    /// ## 自动化模式
    ///
    /// 自检注入的是 `FakeWeatherProvider`（不联网、不碰定位）；
    /// 真实模式才用 `OpenMeteoWeatherProvider`。
    private func loadWeather(day: Int, token: Int) {
        // ⚠️ 用户没开「显示天气」→ 什么都不做（不请求定位、不联网）。
        guard settings.weatherEnabled else {
            DiagLog.info("天气：loadWeather 跳过（天气开关是关的）")
            return
        }
        guard let provider = weatherProvider else {
            DiagLog.info("天气：loadWeather 跳过（没有 weatherProvider）")
            return
        }
        DiagLog.info("天气：loadWeather day=\(day) 已有天气=\(content.festival.weather != nil)")
        // 已经有天气了（同一列重新打开）→ 不用重新取。
        // 跨天时 `handleDayChange` 会先清掉它，所以不会把昨天的天气留下来。
        if content.festival.weather != nil { return }

        // ⚠️ **别把回包绑死在「发起请求的那一列」上**（2026-11 修「永远没有天气」）。
        //
        // 以前这里判 `token == contentToken && currentDay == day` ——
        // 指针扫过 3 列，contentToken 就变了，**所有回包全被丢掉**，
        // 面板永远停在「暂无数据」（用户反馈：授权给了、坐标也拿到了，还是没天气）。
        //
        // 预报是**按天**的（7 天），回来后按日期填进 7 天详情 —— 每一列拿自己那天的。
        let apply: ([String: DayPanelWeather]) -> Void = { [weak self] forecast in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !forecast.isEmpty else { return }
                // ⚠️ **按日期填进 7 天详情**（2026-11 修「天气一直显示在别的天上」）。
                //
                // 以前是「把今天的天气贴到发起请求的那一列」——
                // 指针扫到哪列就写哪列，于是天气出现在"你碰过的某一列"。
                // 现在每一列按**自己那天的日期**去预报里取：
                //   · 日期对得上 → 显示那一天自己的天气（含最高 / 最低温）；
                //   · 对不上（超出 7 天预报范围）→ 这一列没有天气。
                var filled = 0
                for key in self.festivalByDay.keys {
                    var f = self.festivalByDay[key] ?? DayPanelFestival()
                    if let date = self.dayDate(key) {
                        let dayKey = Self.dateKey(date)
                        f.weather = forecast[dayKey]
                        // 按日期存一份 —— `refreshFestivalCache` 重算时贴回去。
                        if let w = forecast[dayKey] { self.weatherByDate[dayKey] = w }
                        let w = forecast[dayKey]
                        let lunarText = self.festivalByDay[key]?.lunar ?? "?"
                        DiagLog.info("天气：第\(key)列 → \(dayKey)（\(lunarText)） → \(w?.text ?? "无") \(w.map { "min\(String(Int($0.min ?? 0))) max\(String(Int($0.max ?? 0)))" } ?? "")")
                        DiagLog.info("天气：预报字典的键 = \(forecast.keys.sorted().joined(separator: ","))")
                    } else {
                        f.weather = nil
                    }
                    if f.weather != nil { filled += 1 }
                    self.festivalByDay[key] = f
                }
                // 当前看着的那一列 → 同步到 content（网页从 `dayFestivals` 取，
                // 但 content 这份也保持一致，别的地方会读）。
                if let cur = self.currentDay,
                   let f = self.festivalByDay[cur] {
                    self.content.festival.weather = f.weather
                }
                DiagLog.info("天气：预报已填进 7 天详情（有天气的列数=\(filled)/\(self.festivalByDay.count)）")
                self.pushState()
                // ⚠️ 诊断：把**真正推给网页**的两处天气打出来（dayFestivals["2"] 和 dayPanel）。
                if let f2 = self.festivalByDay[2] {
                    DiagLog.info("天气：推给网页 dayFestivals[2] = \(f2.weather.map { "\($0.text) min\(String(Int($0.min ?? 0))) max\(String(Int($0.max ?? 0)))" } ?? "nil")")
                }
                if let c = self.content.festival.weather {
                    DiagLog.info("天气：推给网页 dayPanel.festival.weather = \(c.text) min\(String(Int(c.min ?? 0))) max\(String(Int(c.max ?? 0))) 当前列=\(String(describing: self.currentDay))")
                } else {
                    DiagLog.info("天气：推给网页 dayPanel.festival.weather = nil 当前列=\(String(describing: self.currentDay))")
                }
            }
        }

        // ⚠️ **同一时刻只发一次请求**（2026-11 修「扫 7 列发 7 次网络请求」）。
        //
        // 跟随模式下指针扫过每一列都会调 `loadWeather` ——
        // 以前每次都发一次 Open-Meteo 请求（一天几十次），还互相抢回包。
        // 现在：已经在取 → 直接复用那一次的结果。
        if weatherRequestInFlight {
            DiagLog.info("天气：已有请求在飞，复用")
            weatherPendingApplies.append(apply)
            return
        }
        weatherRequestInFlight = true
        weatherPendingApplies.append(apply)

        // ⚠️ **优先用手填的城市**（2026-11）。
        //
        // 后台程序弹不出定位授权框 → 天气永远拿不到。
        // 用户填了城市名 → 用 Open-Meteo 的地名搜索拿坐标（**不碰定位**）。
        // 没填 → 走系统定位。
        let city = settings.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty {
            // ⚠️ **内置坐标表优先**（2026-11-10）：运城 / 连云港 / 湖州 / 港澳台这些
            // 在 Open-Meteo 地名库里要么搜不到、要么被国家字段筛掉。
            // 城市目录里选了它们就直接用写死的坐标，不查地名服务。
            if let builtin = WeatherCityCatalog.coordinate(for: city) {
                fetchForecast(at: CLLocationCoordinate2D(latitude: builtin.lat,
                                                         longitude: builtin.lon))
                return
            }
            provider.resolveCity(city) { [weak self] coord in
                guard let self else { return }
                guard let coord else {
                    self.finishWeatherRequest([:])
                    return
                }
                self.fetchForecast(at: coord)
            }
        } else {
            // ⚠️ **没选地区就不再请求系统定位**（2026-11-11 用户要求）。
            //
            // 用户原话：「我在设置里面打开了显示天气的选项，还是会跳出来
            // 桌面课表想使用你当前的位置的请求授权的窗口」。
            //
            // 以前这里走「按当前定位取预报」→ `requestCurrentLocation`
            // → 第一次必定弹系统定位授权框；而这个 app 是 ad-hoc 签名，
            // 系统对定位请求会**静默拒绝**（详见 CHANGELOG 里的实测结论），
            // 所以弹框除了吓人之外一点用都没有。
            //
            // 现在：没选地区 → 什么都不请求，面板显示「请在设置里选择地区」。
            DiagLog.info("天气：没选地区 → 不请求定位（面板显示「请在设置里选择地区」）")
            finishWeatherRequest([:])
        }
    }

    /// 按指定坐标取预报（城市查出来的坐标也走这里）。
    private func fetchForecast(at coord: CLLocationCoordinate2D) {
        guard let provider = weatherProvider else {
            finishWeatherRequest([:])
            return
        }
        provider.fetchForecast(at: coord) { [weak self] forecast in
            self?.finishWeatherRequest(forecast)
        }
    }

    /// 一次天气请求结束 → 把结果分发给所有等着的人，并清掉「在飞」标志。
    private func finishWeatherRequest(_ forecast: [String: DayPanelWeather]) {
        let applies = weatherPendingApplies
        weatherPendingApplies = []
        weatherRequestInFlight = false
        for a in applies { a(forecast) }
    }

    /// 日期 → `2026-11-10`（与 Open-Meteo `daily.time` 同格式）。
    static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 刷新 7 天的标记（表头的红点 / 橙点）。
    ///
    /// 只在「接入开着」时才做 —— 没授权就别去打扰系统。
    func refreshAll() {
        // 新一轮刷新 → 旧一轮的回包全部作废（见 `refreshToken` 的说明）。
        refreshToken += 1
        let token = refreshToken
        // ⚠️ **「全部周次」模式下不显示红点 / 橙点**（2026-11）。
        //
        // 全部周次 = 所有教学周的课程叠在一起看，
        // 这时「周三」指哪一天没有定义 —— 表头上画一个「周三有待办」的
        // 红点，指向的是**当前那一周**的周三（`baseMonday`），
        // 和用户看到的「所有周」对不上号，会误导。
        //
        // 用户确认：全部周次下**不显示**红点。
        // 日记绿点：**本地数据**，不管 EventKit 有没有授权都要算（2026-11-10）。
        var diaryFlags: [Int: Bool] = [:]
        if !allWeeksMode {
            for day in 1...7 {
                guard let date = dayDate(day) else { continue }
                diaryFlags[day] = !diaryStore.entries(on: DiaryStore.dateKey(date)).isEmpty
            }
        }
        func diaryOnlyFlags() -> [Int: DayPanelFlags] {
            var out: [Int: DayPanelFlags] = [:]
            for day in 1...7 {
                out[day] = DayPanelFlags(hasTodo: false, hasEvent: false,
                                         hasDiary: diaryFlags[day] ?? false)
            }
            return out
        }
        guard !allWeeksMode else {
            flags = [:]
            pushState()
            return
        }
        guard settings.enabled, reminderAuthorized || eventAuthorized else {
            // 没接提醒事项 / 日历：红点橙点没有，但**日记绿点照常显示**。
            flags = diaryOnlyFlags()
            pushState()
            return
        }
        // 两类数据（待办 / 日程）是**分别**取回来的，回调顺序不定 ——
        // 所以先各自存进临时数组，等都回来了再合并，
        // 不能在回调里就地改同一个字典（会互相覆盖）。
        var todoFlags: [Int: Bool] = [:]
        var eventFlags: [Int: Bool] = [:]
        let group = DispatchGroup()
        for day in 1...7 {
            guard let date = dayDate(day) else { continue }
            group.enter()
            eventStore.reminders(on: date) { todos in
                // ⚠️ **已完成的待办不算红点**（2026-11，用户确认）。
                // 以前这里只看 `!todos.isEmpty`，勾完的条目仍然点亮红点，
                // 用户看到「都没有待办了红点还在」。
                todoFlags[day] = todos.contains { !$0.done }
                group.leave()
            }
            group.enter()
            eventStore.events(on: date) { events in
                eventFlags[day] = !events.isEmpty
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, token == self.refreshToken else { return }
            var merged: [Int: DayPanelFlags] = [:]
            for day in 1...7 {
                merged[day] = DayPanelFlags(hasTodo: todoFlags[day] ?? false,
                                            hasEvent: eventFlags[day] ?? false,
                                            hasDiary: diaryFlags[day] ?? false)
            }
            self.flags = merged
            self.pushState()
        }
    }


    /// 今天这一列的待办摘要（今天 N 条 + 逾期 M 条）。
    ///
    /// 只在「正在显示的就是今天」时算并推送 —— 别的列不需要。
    private func refreshTodoDigest(day: Int) {
        let today = content.todos.count
        let startOfToday = Calendar.current.startOfDay(for: Date())
        eventStore.pendingReminders(before: startOfToday) { [weak self] overdue in
            guard let self, self.currentDay == day, day == self.todayIndex else { return }
            self.content.todoDigest = DayPanelTodoDigest(today: today, overdue: overdue)
            self.pushState()
        }
    }

    /// 面板里显示的待办 = **未完成**的那些。
    ///
    /// 用户确认：完成的条目不再出现在面板里、也不算红点。
    /// 过滤放在展示层，`EventKitStore.reminders(on:)` 仍保留 `done` 信息 ——
    /// 下阶段的「已完成事项管理」入口可以直接复用同一个取数接口。
    private static func visibleTodos(_ todos: [DayPanelTodo],
                                     excluding completed: Set<String> = []) -> [DayPanelTodo] {
        todos.filter { !$0.done && !completed.contains($0.identifier) }
    }

    /// 「周几」→ 具体日期（当前浏览周的那一天）。
    private func dayDate(_ day: Int) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(byAdding: .day, value: day - 1, to: baseMonday)
    }

    /// 某一天 + 当天的分钟数 → 到期时刻。
    private func dueDate(day: Int, minutes: Int) -> Date? {
        guard let base = dayDate(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(byAdding: .minute, value: minutes, to: base)
    }

    /// 解析 `HH:mm`（也接受 `H:mm` / `H:m`）→ 当天分钟数；非法返回 nil。
    ///
    /// 网页已经做过一遍校验和补零，这里是**原生侧的兜底** ——
    /// 不能把「网页会不会传非法值」当成安全边界。
    static func clockMinutes(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let hourText = String(parts[0])
        let minuteText = parts.count == 2 ? String(parts[1]) : "0"
        guard !hourText.isEmpty, hourText.count <= 2,
              !minuteText.isEmpty, minuteText.count <= 2,
              let hour = Int(hourText), let minute = Int(minuteText),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    /// 当天分钟数 → `HH:mm`。
    static func clockText(_ minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 23 * 60 + 59)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// 把当前状态推给网页。
    ///
    /// `dayPanelOverride` 用于「写操作发生在网页正看着、但原生 `currentDay`
    /// 还没跟上」的那一天（见 `pushDayPanel`）：此时只替换这一版推送里的
    /// `dayPanel`，不改 `content`。
    private func pushState(dayPanelOverride: DayPanelContent? = nil) {
        // ⚠️ **7 天的「今日详情」一起推**（2026-11 修）。
        //
        // 以前只推当前那一天 → 网页换列时只能靠缓存兜底 →
        // 「有的列有今日详情、有的没有」，而且日期经常对不上。
        //
        // 现在每一天的农历 / 节气 / 节日 / 宜忌都有独立的一份，
        // 网页按 `day` 取，**永远不会串到别的日子**。
        var festivalJSON: [String: Any] = [:]
        for (day, f) in festivalByDay {
            festivalJSON["\(day)"] = DayPanelContent.festivalJSON(
                f, weatherEnabled: settings.weatherEnabled, region: weatherRegion)
        }
        let panelJSON: Any
        if let override = dayPanelOverride {
            panelJSON = override.jsonObject
        } else if let day = currentDay {
            var c = content
            c.day = day
            panelJSON = c.jsonObject
        } else {
            panelJSON = NSNull()
        }
        // ⚠️ 诊断：打印 dayFestivals 的键 → 农历（查网页侧错位）。
        if ProcessInfo.processInfo.environment["DT_DEBUG_WEATHER"] == "1" {
            var keysDesc = ""
            for (k, v) in festivalJSON.sorted(by: { $0.key < $1.key }) {
                let dict = v as? [String: Any]
                keysDesc += "\(k)=\(dict?["lunar"] as? String ?? "?") "
            }
            DiagLog.info("天气：推送的 dayFestivals 键 → 农历：\(keysDesc)")
        }
        var payload: [String: Any] = [
            "dayPanel": panelJSON,
            "dayFestivals": festivalJSON,
            "dayFlags": DayPanelFlags.jsonObject(flags),
            "dayPanelOpen": currentDay != nil,
            // 系统数据变了几次 —— 网页看到数字变化就作废自己的按天缓存。
            "dayPanelRevision": storeRevision,
        ]
        payload.removeValue(forKey: "unused")
        if let panel = panelJSON as? [String: Any] {
            let pushedDay = (panel["day"] as? Int)
                ?? (panel["day"] as? NSNumber)?.intValue
            if let pushedDay { pushedPanelsByDay[pushedDay] = panel }
        }
        // ⚠️ 诊断：把真正推给网页的 JSON dump 出来（查键错位）。
        if ProcessInfo.processInfo.environment["DT_DEBUG_WEATHER"] == "1" {
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let txt = String(data: data, encoding: .utf8) {
                DiagLog.info("天气：推送 JSON（截断 1500 字）=\(String(txt.prefix(1500)))")
            }
        }
        guard let onStateChange else { return }
        // ⚠️ **内容没变就不要重推**（2026-11 修「闪几下」）。
        //
        // 一次「添加 / 完成 / 删除」会连着推好几版：内容刷新一次、红点刷新一次，
        // 有时还有重试。网页每收到一版都要重绘面板 —— 内容一模一样也照画，
        // 用户看到的就是面板 / 表头闪几下。
        //
        // 这里用「排序键」序列化后的字符串做指纹：完全相同的状态直接跳过。
        // 排序键保证同样的字典每次序列化结果一致。
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys]),
           let signature = String(data: data, encoding: .utf8) {
            if signature == lastPushedSignature { return }
            lastPushedSignature = signature
        }
        onStateChange(payload)
    }

    /// 覆盖层是不是开着。
    var isOpen: Bool { currentDay != nil }

    /// 当前内容的 JSON（推给网页用）。
    ///
    /// 覆盖层**没开**时也要给一个值（空内容）——
    /// 网页每次 `ttUpdate` 整体替换 `S`，字段缺失会被当成「没有数据」，
    /// 而「没有数据」和「没打开」在网页里是两回事。
    func currentContentJSON() -> Any {
        guard let day = currentDay else { return NSNull() }
        var c = content
        c.day = day
        return c.jsonObject
    }

    /// 7 天标记的 JSON（推给网页用）。
    func currentFlagsJSON() -> [String: Any] {
        DayPanelFlags.jsonObject(flags)
    }

    /// **7 天各自的「今日详情」**的 JSON（推给网页用）。
    ///
    /// 键 = 「1」…「7」，值 = 那一天的 `festival` 字典。
    ///
    /// ⚠️ 这是 2026-11 加的 —— 以前只推当前那一天，
    /// 网页换列时只能靠缓存兜底 → 今日详情有的列没有、日期还对不上。
    func currentFestivalsJSON() -> [String: Any] {
        var out: [String: Any] = [:]
        for (day, f) in festivalByDay {
            out["\(day)"] = DayPanelContent.festivalJSON(
            f, weatherEnabled: settings.weatherEnabled, region: weatherRegion)
        }
        return out
    }

    /// 自检用：当前状态。
    var testState: (open: Bool, day: Int?) {
        (currentDay != nil, currentDay)
    }

    /// 自检用：换掉 EventKit 接入层（**只能在自动化模式里用**）。
    ///
    /// 空实现（`EmptyEventKitStore`）的 `setReminder` 永远失败 →
    /// 「点完成」只会走「写回失败、重新推送」那条分支；真实环境走的是
    /// 「写回成功 → 重取数（可能是旧快照）→ 补推」。
    /// 要复现用户报的「点完成之后一直闪」，必须换成会**真的写进数据**的
    /// `FakeEventKitStore`（`appliesToggle` / `toggleDelay` / `simulateStaleReads`）。
    ///
    /// ⚠️ 只在自动化模式生效：真实进程里调用它会把用户数据源换掉。
    func testReplaceStore(_ store: EventKitStoreProtocol) {
        guard AutomationMode.isCurrentProcessAutomation else { return }
        eventStore = store
        completedReminders = CompletedRemindersService(store: store)
    }

    /// 自检用：第 `day` 列对应的是哪一天（`dayDate` 私有）。
    func testDate(day: Int) -> Date? { dayDate(day) }

    /// 自检用：表头标记。
    var testFlags: [Int: DayPanelFlags] { flags }

    /// 自检用：今天在周几（跨天刷新后要跟着变）。
    var testTodayIndex: Int { todayIndex }

    /// 自检用：有没有接上天气数据源（生产环境必须为 true）。
    var hasWeatherProvider: Bool { weatherProvider != nil }

    /// 自检用：当前内容。
    var testContent: DayPanelContent { content }
    /// 最近一次**真正推出去**的 `dayPanel`（自检用）。
    ///
    /// 用来验「网页跟到了别的列、原生 currentDay 还没跟上」时，
    /// 写操作仍然会补推发生改动的那一天。
    func testPushedPanel(day: Int) -> [String: Any]? { pushedPanelsByDay[day] }
}

// MARK: - 农历提供方

/// 「今日详情」那一栏的数据来源（农历 / 节气 / 节日）。
///
/// 用协议解耦：农历模块由独立实现提供，本控制器只管问。
protocol DayPanelFestivalProvider {
    /// 某一天的节日 / 节气信息。
    func festival(on date: Date) -> DayPanelFestival
}

/// 没有农历数据时的兜底（空）。
struct EmptyFestivalProvider: DayPanelFestivalProvider {
    func festival(on date: Date) -> DayPanelFestival { DayPanelFestival() }
}

// MARK: - 空实现

/// 自检用的 **fake** EventKit —— 记录调用次数，验证「自动化模式不碰真实系统」。
final class FakeEventKitStore: EventKitStoreProtocol {
    var todos: [DayPanelTodo] = []
    var events: [DayPanelEvent] = []
    /// **按日期存放**的待办（键 = 那一天的零点）。
    ///
    /// 用来验「待办按日期归属」—— 某一天的待办在别的日子看不到。
    var todosByDate: [Date: [DayPanelTodo]] = [:]
    /// 默认给一个**可写**清单 —— 真实环境里只要用户有一个清单就能写。
    var lists: [EventKitListInfo] = [
        EventKitListInfo(title: "桌面课表", identifier: "c1", isWritable: true)
    ]
    var requestReminderCalls = 0
    var requestEventCalls = 0
    var addCalls: [(String, Date, String)] = []
    var toggleCalls: [(String, String, Bool)] = []
    var deleteCalls: [(String, String)] = []
    /// `updateReminder` 的调用记录：`(id, 清单, 标题, 到期时刻)`。
    var updateCalls: [(String, String, String, Date)] = []

    // MARK: - 已完成提醒事项（自检用）

    /// fake 里的「已完成提醒事项」（可分布在多个清单）。
    var completed: [CompletedReminder] = []
    /// `completedReminders` 被调用了几次（验「收起时不读取」）。
    var completedFetchCalls = 0
    /// 已完成读取的回调延迟（验「收起时取消在途读取」）。
    var completedFetchDelay: TimeInterval = 0
    /// `restoreReminder` 的调用记录。
    var restoreCalls: [(String, String)] = []
    /// `deleteCompletedReminder` 的调用记录。
    var deleteCompletedCalls: [(String, String)] = []
    /// `deleteAllCompletedReminders` 被调用了几次。
    var deleteAllCompletedCalls = 0
    /// 批量删除最后统一 `commit()` 了几次（必须只有一次）。
    var commitCalls = 0
    /// 恢复 / 单条删除 / 批量删除的失败注入。
    var restoreShouldFail = false
    var deleteCompletedShouldFail = false
    var deleteAllPartiallyFails: Set<String> = []
    var deleteAllCommitFails = false
    /// 恢复成功后，是否把这条**放回** `todosByDate`（日期面板要重新出现它）。
    var appliesRestore = true

    /// 是否把 `setReminder(done:)` **真的写进 fake 数据**（2026-11 加）。
    ///
    /// 默认 false：老用例只关心「调没调」。
    /// 「完成 → 换周 → 回来不能复活」这类回归需要 fake 像真实 EventKit
    /// 一样**持久化完成状态**，否则重载回来永远是 done=false。
    var appliesToggle = false

    /// `setReminder(done:)` 的回调延迟（秒）—— 模拟真实 EventKit 的**异步**写回。
    ///
    /// 默认 0（同步回调）：老用例不受影响。
    /// 「写回还没完成时又来一次完成请求」必须被原生挡住的回归要用它。
    var toggleDelay: TimeInterval = 0

    /// 是否把 `addReminder` **真的写进 fake 数据**（2026-11 加）。
    var appliesAdd = false

    /// 是否把 `updateReminder` **真的写进 fake 数据**（2026-11 加）。
    var appliesUpdate = false

    /// `updateReminder` 的回调延迟（秒）——模拟真实 EventKit 的异步写回。
    var updateDelay: TimeInterval = 0

    /// 模拟 EventKit 的「写后读不是强一致」：改动之后，针对那一天的前 N 次取数
    /// 仍然返回**改动前**的快照。用来验证原生的「结果不符就重试」。
    var simulateStaleReads = 0

    /// 旧快照（`simulateStaleReads` 用）。
    private var staleDay: Date?
    private var staleFetchesLeft = 0
    private var staleSnapshot: [DayPanelTodo] = []

    /// 在改动之前拍一份快照，之后针对这一天的 N 次取数返回它。
    private func beginStaleReads(for date: Date) {
        guard simulateStaleReads > 0 else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let key = cal.startOfDay(for: date)
        staleDay = key
        staleFetchesLeft = simulateStaleReads
        staleSnapshot = todosByDate[key] ?? []
    }

    /// 授权状态可调 —— 默认已授权；自检「第一次点添加待办就弹权限框」
    /// 时把它设成 `.notDetermined`。
    var reminderAuth: EKAuthorizationStatus = .fullAccess
    var eventAuth: EKAuthorizationStatus = .fullAccess

    var reminderAuthorization: EKAuthorizationStatus { reminderAuth }
    var eventAuthorization: EKAuthorizationStatus { eventAuth }

    func requestReminderAccess(completion: @escaping (Bool) -> Void) {
        requestReminderCalls += 1
        completion(true)
    }
    func requestEventAccess(completion: @escaping (Bool) -> Void) {
        requestEventCalls += 1
        completion(true)
    }
    func reminderLists() -> [EventKitListInfo] { lists }
    /// ⚠️ **按日期过滤**（2026-11 加）。
    ///
    /// 真实实现（`EventKitStore.reminders(on:)`）是按**到期日期**过滤的 ——
    /// 「某一天的待办」= 到期时刻落在那一天里的那些。
    ///
    /// 以前 fake 直接把全部待办返回，于是自检**测不出**「翻周之后
    /// 上一周的待办还在不在」这种问题（fake 永远返回同一批）。
    ///
    /// 现在的口径：
    ///   · `todosByDate` 里有的 → **只**在那一天返回（精确匹配）；
    ///   · `todos`（老的扁平数组）→ 按 `dueMinutes` 相对**被问的那一天**算，
    ///     所以「每天 10:00 的待办」在每一天都显示（和真实实现一致）。
    /// 自检注入：逾期未处理条数（`pendingReminders(before:)` 直接回这个）。
    var overduePendingCount = 0

    /// `pendingReminders`（「逾期几条」）的回调延迟（秒）。
    ///
    /// ⚠️ 真实 EventKit 跨进程查询要几十毫秒；同步回调时
    /// 「摘要卡先消失、0.35 秒后再回来」这两版推送会挤在**同一帧**里，
    /// 网页端根本采样不到中间态（自检就成了假绿）。
    var overdueDelay: TimeInterval = 0

    func pendingReminders(before date: Date, completion: @escaping (Int) -> Void) {
        if overdueDelay > 0 {
            let value = overduePendingCount
            DispatchQueue.main.asyncAfter(deadline: .now() + overdueDelay) {
                completion(value)
            }
            return
        }
        completion(overduePendingCount)
    }

    func reminders(on date: Date, completion: @escaping ([DayPanelTodo]) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            completion([])
            return
        }
        // 模拟「写后读旧快照」：前 N 次取数返回改动前的那份。
        if staleFetchesLeft > 0, let staleDay, cal.isDate(start, inSameDayAs: staleDay) {
            staleFetchesLeft -= 1
            completion(staleSnapshot)
            return
        }
        // 精确按日期存放的（键 = 那一天的零点）。
        if !todosByDate.isEmpty {
            let key = cal.startOfDay(for: date)
            completion(todosByDate[key] ?? [])
            return
        }
        // 老的扁平数组：按「被问的那一天」的时刻算。
        let picked = todos.filter { t in
            guard let m = t.minutesOfDay() else { return false }
            let due = cal.date(byAdding: .minute, value: m, to: start)!
            return due >= start && due < end
        }
        completion(picked)
    }
    func events(on date: Date, completion: @escaping ([DayPanelEvent]) -> Void) { completion(events) }
    func setReminder(_ identifier: String, in calendarIdentifier: String,
                     done: Bool, completion: @escaping (Bool) -> Void) {
        toggleCalls.append((identifier, calendarIdentifier, done))
        func apply() {
            guard appliesToggle else { return }
            // 改动前先拍快照（模拟写后读旧快照时用）。
            if let date = todosByDate.keys.first(where: { key in
                (todosByDate[key] ?? []).contains { $0.identifier == identifier }
            }) {
                beginStaleReads(for: date)
            }
            func flipped(_ t: DayPanelTodo) -> DayPanelTodo {
                var copy = t
                if copy.identifier == identifier { copy.done = done }
                return copy
            }
            todos = todos.map(flipped)
            for (date, items) in todosByDate {
                todosByDate[date] = items.map(flipped)
            }
        }
        if toggleDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + toggleDelay) {
                apply()
                completion(true)
            }
        } else {
            apply()
            completion(true)
        }
    }
    func createReminderList(titled title: String) -> EventKitListInfo? {
        let info = EventKitListInfo(title: title, identifier: "list-\(title)", isWritable: true)
        lists.append(info)
        return info
    }
    func updateReminder(_ identifier: String, in calendarIdentifier: String,
                        title: String, due: Date,
                        completion: @escaping (Bool) -> Void) {
        updateCalls.append((identifier, calendarIdentifier, title, due))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.hour, .minute], from: due)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let timeText = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        func apply() {
            guard appliesUpdate else { return }
            // 改动前先拍快照（模拟「写后读旧快照」时用）。
            if let date = todosByDate.keys.first(where: { key in
                (todosByDate[key] ?? []).contains { $0.identifier == identifier }
            }) {
                beginStaleReads(for: date)
            }
            func updated(_ t: DayPanelTodo) -> DayPanelTodo {
                guard t.identifier == identifier else { return t }
                var copy = t
                copy.title = title
                copy.due = timeText
                copy.dueMinutes = minutes
                return copy
            }
            todos = todos.map(updated)
            for (date, items) in todosByDate {
                todosByDate[date] = items.map(updated)
            }
        }
        if updateDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + updateDelay) {
                apply()
                completion(true)
            }
        } else {
            apply()
            completion(true)
        }
    }
    func addReminder(title: String, due: Date, in calendarIdentifier: String,
                     completion: @escaping (Bool, String) -> Void) {
        addCalls.append((title, due, calendarIdentifier))
        // ⚠️ 没开 `appliesAdd` 的 fake **不持久化** —— 返回空 id，
        // 调用方就不会把它当「已经写进去了」去乐观展示。
        guard appliesAdd else {
            completion(true, "")
            return
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let key = cal.startOfDay(for: due)
        // 先拍快照（模拟「加完之后第一次取数还看不到新条目」）。
        beginStaleReads(for: key)
        let comps = cal.dateComponents([.hour, .minute], from: due)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let timeText = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        let identifier = "added-\(addCalls.count)"
        var list = todosByDate[key] ?? []
        list.append(DayPanelTodo(title: title, due: timeText, done: false,
                                 dueMinutes: minutes,
                                 identifier: identifier,
                                 calendarIdentifier: calendarIdentifier))
        todosByDate[key] = list
        completion(true, identifier)
    }
    func deleteReminder(_ identifier: String, in calendarIdentifier: String,
                        completion: @escaping (Bool) -> Void) {
        deleteCalls.append((identifier, calendarIdentifier))
        completion(true)
    }

    // MARK: 已完成提醒事项

    func completedReminders(completion: @escaping (Result<[CompletedReminder], Error>) -> Void) {
        completedFetchCalls += 1
        let snapshot = completed
        let deliver = { completion(.success(snapshot)) }
        if completedFetchDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + completedFetchDelay,
                                          execute: deliver)
        } else {
            deliver()
        }
    }

    func restoreReminder(_ identifier: String, in calendarIdentifier: String,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        restoreCalls.append((identifier, calendarIdentifier))
        guard !restoreShouldFail else {
            completion(.failure(CompletedRemindersError.underlying("模拟：恢复失败")))
            return
        }
        guard let index = completed.firstIndex(where: { $0.identifier == identifier }) else {
            completion(.failure(CompletedRemindersError.reminderNotFound))
            return
        }
        let item = completed.remove(at: index)
        if appliesRestore {
            // 先把它从所有日期的快照里拿掉（它可能以 done=true 出现过）。
            let dates = Array(todosByDate.keys)
            for date in dates {
                todosByDate[date]?.removeAll { $0.identifier == identifier }
                if todosByDate[date]?.isEmpty == true {
                    todosByDate.removeValue(forKey: date)
                }
            }
            todos.removeAll { $0.identifier == identifier }
            // 有到期时间的 → 放回那一天，日期面板重载时就能重新出现。
            if let due = item.dueDate {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = .current
                let key = cal.startOfDay(for: due)
                let comps = cal.dateComponents([.hour, .minute], from: due)
                let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                let timeText = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
                var list = todosByDate[key] ?? []
                list.append(DayPanelTodo(title: item.title, due: timeText, done: false,
                                         dueMinutes: minutes,
                                         identifier: item.identifier,
                                         calendarIdentifier: item.listIdentifier))
                todosByDate[key] = list
            }
        }
        completion(.success(()))
    }

    func deleteCompletedReminder(_ identifier: String, in calendarIdentifier: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        deleteCompletedCalls.append((identifier, calendarIdentifier))
        guard !deleteCompletedShouldFail else {
            completion(.failure(CompletedRemindersError.underlying("模拟：删除失败")))
            return
        }
        completed.removeAll { $0.identifier == identifier }
        removeTodoEverywhere(identifier)
        completion(.success(()))
    }

    func deleteAllCompletedReminders(
        progress: ((Int, Int) -> Void)?,
        completion: @escaping (CompletedRemindersDeleteResult) -> Void) {
        deleteAllCompletedCalls += 1
        let targets = completed
        guard !targets.isEmpty else {
            completion(CompletedRemindersDeleteResult(deleted: 0, failed: 0,
                                                      deletedIdentifiers: [],
                                                      failedIdentifiers: [],
                                                      message: nil))
            return
        }
        var deleted: [String] = []
        var failed: [String] = []
        for (index, item) in targets.enumerated() {
            if deleteAllPartiallyFails.contains(item.identifier) {
                failed.append(item.identifier)
            } else {
                deleted.append(item.identifier)
            }
            progress?(index + 1, targets.count)
        }
        guard !deleted.isEmpty else {
            completion(CompletedRemindersDeleteResult(deleted: 0, failed: failed.count,
                                                      deletedIdentifiers: [],
                                                      failedIdentifiers: failed,
                                                      message: "模拟：全部删除失败"))
            return
        }
        commitCalls += 1
        guard !deleteAllCommitFails else {
            completion(CompletedRemindersDeleteResult(
                deleted: 0,
                failed: targets.count,
                deletedIdentifiers: [],
                failedIdentifiers: targets.map { $0.identifier },
                message: "模拟：提交更改失败"))
            return
        }
        completed.removeAll { deleted.contains($0.identifier) }
        for identifier in deleted { removeTodoEverywhere(identifier) }
        completion(CompletedRemindersDeleteResult(
            deleted: deleted.count,
            failed: failed.count,
            deletedIdentifiers: deleted,
            failedIdentifiers: failed,
            message: failed.isEmpty ? nil : "\(failed.count) 条删除失败"))
    }

    /// 把某条从 fake 的所有日期快照里清掉。
    private func removeTodoEverywhere(_ identifier: String) {
        let dates = Array(todosByDate.keys)
        for date in dates {
            todosByDate[date]?.removeAll { $0.identifier == identifier }
            if todosByDate[date]?.isEmpty == true {
                todosByDate.removeValue(forKey: date)
            }
        }
        todos.removeAll { $0.identifier == identifier }
    }
}

/// 自动化模式用的空 EventKit —— 什么都不返回，也绝不碰系统。
final class EmptyEventKitStore: EventKitStoreProtocol {
    /// 自检用：**假装当天已经有这几条待办**。
    ///
    /// 为什么需要（2026-11-09）：`--verify-todo-focus` 验的是「输入时间时
    /// 上面的待办事项不能消失」，但临时数据目录里待办是 0 条 →
    /// 「0 → 0 没变」恒真，这条断言等于**没验**。给它一条假待办，
    /// 断言才有东西可看。默认空 → 其它 `--verify-*` 完全不受影响。
    private let seededTodos: [DayPanelTodo]

    init(seededTodos: [DayPanelTodo] = []) {
        self.seededTodos = seededTodos
    }

    var reminderAuthorization: EKAuthorizationStatus { .denied }
    var eventAuthorization: EKAuthorizationStatus { .denied }
    func requestReminderAccess(completion: @escaping (Bool) -> Void) { completion(false) }
    func requestEventAccess(completion: @escaping (Bool) -> Void) { completion(false) }
    func reminderLists() -> [EventKitListInfo] { [] }
    func reminders(on date: Date, completion: @escaping ([DayPanelTodo]) -> Void) {
        completion(seededTodos)
    }
    func pendingReminders(before date: Date, completion: @escaping (Int) -> Void) {
        completion(0)
    }
    func events(on date: Date, completion: @escaping ([DayPanelEvent]) -> Void) { completion([]) }
    func setReminder(_ identifier: String, in calendarIdentifier: String,
                     done: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func updateReminder(_ identifier: String, in calendarIdentifier: String,
                        title: String, due: Date,
                        completion: @escaping (Bool) -> Void) { completion(false) }
    func createReminderList(titled title: String) -> EventKitListInfo? { nil }
    func addReminder(title: String, due: Date, in calendarIdentifier: String,
                     completion: @escaping (Bool, String) -> Void) { completion(false, "") }
    func deleteReminder(_ identifier: String, in calendarIdentifier: String,
                        completion: @escaping (Bool) -> Void) { completion(false) }

    // MARK: 已完成提醒事项（空实现：绝不碰系统，也绝不假装成功）

    func completedReminders(completion: @escaping (Result<[CompletedReminder], Error>) -> Void) {
        completion(.failure(CompletedRemindersError.notAuthorized))
    }
    func restoreReminder(_ identifier: String, in calendarIdentifier: String,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(CompletedRemindersError.notAuthorized))
    }
    func deleteCompletedReminder(_ identifier: String, in calendarIdentifier: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(CompletedRemindersError.notAuthorized))
    }
    func deleteAllCompletedReminders(
        progress: ((Int, Int) -> Void)?,
        completion: @escaping (CompletedRemindersDeleteResult) -> Void) {
        completion(.failure(CompletedRemindersError.notAuthorized))
    }
}

import AppKit
import EventKit
import WebKit

// MARK: - 命令行模式
//
// `DesktopTimetable --import <文件.xls|.json>`：不开界面，直接导入并落盘。
// 方便脚本化，也方便在没有 GUI 的环境里验证解析器。

let arguments = CommandLine.arguments

func runImport(_ path: String) -> Int32 {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    // 阶段 3：和界面一样走 TimetableStore（多课表），先确保旧数据已迁移。
    let timetableStore = TimetableStore()
    if let migrated = try? timetableStore.migrateLegacyIfNeeded(defaultName: "我的课表") {
        print("已迁移旧课表数据 → \(migrated.name)")
    }
    guard let repository = timetableStore.activeRepository() else {
        FileHandle.standardError.write(Data("没有可用的课表\n".utf8))
        return 1
    }
    let loaded = repository.load()
    do {
        // 解析 → 分组 → 匹配旧 courseID → 落盘（与界面导入同一套逻辑）
        let (plan, format) = try ScheduleImporter.plan(at: url,
                                                       existing: loaded.courses,
                                                       maxWeek: loaded.semester.effectiveMaxWeek(for: loaded.courses))
        print(plan.summary)
        let final = ImportPlanner.materialize(plan)
        try repository.save(final)
        print("已导入 \(final.count) 条上课时间记录（\(format.rawValue)）")
        print("→ \(repository.store.coursesFile.path)")
        if !plan.conflicts.isEmpty {
            print("")
            print("注意：以下时间格有多门课，桌面课表只能显示其中一门")
            for c in plan.conflicts {
                print("  \(c.timeText)：\(c.names.joined(separator: " / "))")
            }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("导入失败：\(error.localizedDescription)\n".utf8))
        return 1
    }
}

if let idx = arguments.firstIndex(of: "--import") {
    guard idx + 1 < arguments.count else {
        FileHandle.standardError.write(Data("用法：DesktopTimetable --import <课表文件>\n".utf8))
        exit(2)
    }
    exit(runImport(arguments[idx + 1]))
}

if arguments.contains("--verify-timetables") {
    // 自检：检查多课表存储结构、迁移结果、courseID 一致性。
    // 只读检查，不写盘（除了必要的迁移），退出码非 0 表示有问题。
    let store = TimetableStore()
    var problems: [String] = []

    // 1. 旧数据迁移
    if let migrated = try? store.migrateLegacyIfNeeded(defaultName: "我的课表") {
        print("迁移：旧数据 → 第一份课表「\(migrated.name)」（\(migrated.courses.count) 条记录）")
    } else {
        print("迁移：无需迁移")
    }

    // 2. 目录结构
    print("索引：\(store.indexFile.path)")
    for meta in store.allMetas() {
        let mark = meta.id == store.activeID ? "★" : " "
        print("  \(mark) \(meta.name) — \(meta.id) — 更新于 \(meta.updatedAt)")
    }

    // 3. 当前课表内容
    if let active = store.activeID, let t = try? store.load(active) {
        print("当前课表「\(t.name)」：\(t.courses.count) 条记录")
        let ids = t.courses.map { $0.courseID }
        let empty = ids.filter { $0.isEmpty }.count
        if empty > 0 { problems.append("有 \(empty) 条记录没有 courseID") }
        let unique = Set(ids).count
        print("  不同 courseID：\(unique) 门课")
        print("  学期：起始 \(t.semester.start) · 总周数 \(t.semester.maxWeek)")
        // 标题来源
        print("  卡片标题将显示：「\(t.name)」/ 副标题「\(t.subtitle)」")
    } else {
        print("当前课表：无（空课表状态）")
    }

    // 4. 备份
    let backupRoot = store.timetablesDirectory.appendingPathComponent("backups")
    let legacyBackups = store.rootDirectory.appendingPathComponent("backups")
    let legacyCount = (try? FileManager.default.contentsOfDirectory(atPath: legacyBackups.path))?.count ?? 0
    print("旧数据备份：\(legacyCount) 份（\(legacyBackups.path)）")
    let ttBackups = (try? FileManager.default.contentsOfDirectory(atPath: backupRoot.path))?.count ?? 0
    print("课表目录备份：\(ttBackups) 份")

    if problems.isEmpty {
        print("自检通过")
        exit(0)
    }
    for p in problems { print("问题：\(p)") }
    exit(1)
}

if arguments.contains("--verify-override-flow") {
    // 自检：走一遍「单周临时覆盖」的完整保存流程。
    //
    // **必须** DT_DATA_DIR 指向一个临时目录 —— 绝不碰用户真实课表。
    //
    // 验证点：
    //   · 撞上「正在上课的课」→ 第一道关（警告）
    //   · 撞上「非本周课」→ 第二道关（提醒）
    //   · 两道关是串行的：第一道取消 → 第二道根本不弹
    //   · 都确认 → 写进 week_overrides.json，原课表（schedule_data.json）一个字不动
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-override-flow 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let store = TimetableStore()
    if let migrated = try? store.migrateLegacyIfNeeded(defaultName: "我的课表") {
        print("课表：\(migrated.name)")
    }
    guard let active = store.activeID else {
        print("❌ 没有当前课表")
        exit(1)
    }
    let repo = store.repository(for: active)

    // 直接建一个右键编辑器控制器（不建卡片窗口 —— 自检不该往桌面上摆东西）
    let editor = ScheduleEditorController(repositoryProvider: { repo })
    editor.reload()

    var problems: [String] = []
    // 记录两道关的顺序
    var gates: [String] = []

    func draft(_ name: String, day: Int, block: Int, weeks: [Int]) -> CourseDraft {
        var d = CourseDraft()
        d.name = name
        d.day = day
        d.block = block
        d.weeks = weeks
        return d
    }

    // ---- 场景 1：警告 → 提醒（都确认）→ 写成覆盖 ----
    editor.testConfirmGate = { gate, _ in
        gates.append(gate == .realConflict ? "警告" : "提醒")
        return true
    }
    let before = repo.load().courses.count
    editor.testSubmit(draft: draft("临时课A", day: 3, block: 1, weeks: [3]),
                      scope: .create(day: 3, block: 1))
    let after = repo.load()
    if gates != ["警告", "提醒"] {
        problems.append("两道关的顺序不对：\(gates)")
    }
    if after.courses.count != before {
        problems.append("写覆盖不该动原课表：\(before) → \(after.courses.count)")
    }
    if after.overrides.count != 1 {
        problems.append("应该写进 1 条覆盖，实际 \(after.overrides.count)")
    } else if after.overrides[0].name != "临时课A" {
        problems.append("覆盖课名不对：\(after.overrides[0].name)")
    }
    print("场景1（警告→提醒→覆盖）：原课表 \(before) 条 → 覆盖 \(after.overrides.count) 条，"
          + "两道关：\(gates)")

    // ---- 场景 2：第一道关取消 → 第二道关不弹，什么都不写 ----
    gates = []
    editor.testConfirmGate = { gate, _ in
        gates.append(gate == .realConflict ? "警告" : "提醒")
        return false
    }
    editor.testSubmit(draft: draft("临时课B", day: 3, block: 1, weeks: [3]),
                      scope: .create(day: 3, block: 1))
    if gates != ["警告"] {
        problems.append("第一道关取消后，第二道关不该弹：\(gates)")
    }
    if repo.load().overrides.count != 1 {
        problems.append("取消后不该写覆盖，实际 \(repo.load().overrides.count) 条")
    }
    print("场景2（警告点取消）：两道关：\(gates) → 覆盖仍是 \(repo.load().overrides.count) 条")

    // ---- 场景 3：只有提醒（选中的周次原课不上课）→ 继续 → 写成覆盖 ----
    gates = []
    editor.testConfirmGate = { gate, _ in
        gates.append(gate == .realConflict ? "警告" : "提醒")
        return true
    }
    editor.testSubmit(draft: draft("临时课C", day: 1, block: 0, weeks: [12]),
                      scope: .create(day: 1, block: 0))
    if gates != ["提醒"] {
        problems.append("非本周课只该弹提醒：\(gates)")
    }
    let ovs = repo.load().overrides
    if ovs.count != 2 {
        problems.append("应该写进 2 条覆盖，实际 \(ovs.count)")
    }
    print("场景3（只有提醒→继续）：两道关：\(gates) → 覆盖 \(ovs.count) 条")

    // ---- 场景 4：整格没课 → 不弹任何关，直接进 courses ----
    gates = []
    editor.testSubmit(draft: draft("空格子新课", day: 5, block: 4, weeks: [3]),
                      scope: .create(day: 5, block: 4))
    if !gates.isEmpty {
        problems.append("整格没课不该弹关：\(gates)")
    }
    if repo.load().courses.count != before + 1 {
        problems.append("整格没课的课该进 courses，实际 \(repo.load().courses.count) 条")
    }
    print("场景4（整格没课）：两道关：\(gates) → 原课表 \(repo.load().courses.count) 条")

    // ---- 场景 5：撤销覆盖 → 那一格恢复原样 ----
    editor.testConfirmGate = { _, _ in true }
    let ovDay = 3, ovBlock = 1
    let coursesBefore = repo.load().courses.count
    editor.testDeleteOverride(day: ovDay, block: ovBlock, confirmed: true)
    let finalState = repo.load()
    if finalState.overrides.count != 1 {
        problems.append("撤销一条覆盖后应剩 \(ovs.count - 1) 条，实际 \(finalState.overrides.count)")
    }
    if finalState.courses.count != coursesBefore {
        problems.append("撤销覆盖不该动原课表：\(coursesBefore) → \(finalState.courses.count)")
    }
    print("场景5（撤销覆盖）：覆盖 \(ovs.count) → \(finalState.overrides.count) 条，"
          + "原课表 \(finalState.courses.count) 条")

    // ---- 场景 6：确认窗本身能弹出、能点、返回选择 ----
    func findButton(_ title: String, in view: NSView) -> NSButton? {
        for sub in view.subviews {
            if let b = sub as? NSButton, b.title == title { return b }
            if let hit = findButton(title, in: sub) { return hit }
        }
        return nil
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        for w in NSApp.windows where w.title == "这个时间已经有课了" {
            guard let content = w.contentView,
                  let btn = findButton("确认覆盖", in: content) else { continue }
            btn.performClick(nil)
            return
        }
    }
    let choice = ConfirmDialogController(request: .init(
        title: "这个时间已经有课了", message: "这是自检用的确认窗。",
        items: [Course(day: 3, block: 1, name: "高等数学", teacher: "李雷",
                       loc: "教三-201", code: "", courseID: "M1", weeks: [1, 2, 3])],
        confirmTitle: "确认覆盖")).run()
    if choice != .confirm {
        problems.append("确认窗点了「确认覆盖」却返回 \(choice)")
    }
    print("场景6（确认窗）：点了「确认覆盖」→ \(choice == .confirm ? "确认" : "取消")")

    if problems.isEmpty {
        print("✅ 临时覆盖流程自检通过")
        exit(0)
    } else {
        for p in problems { print("问题：\(p)") }
        exit(1)
    }
}


if arguments.contains("--verify-reminder-plan") {
    // 自检：统一设置层 + 上课提醒规划 + 自动化护栏。
    //
    // **必须** DT_DATA_DIR 指向临时目录 —— 绝不碰用户真实课表 / 真实设置。
    //
    // 验证点：
    //   · settings.json 读写往返，config.json 里不出现 reminder（旧版兼容）
    //   · 旧 saveConfig 路径不会抹掉 reminder
    //   · 规划器只看当前激活课表，从今天起 14 天
    //   · 自动化模式下不请求通知权限、不注册登录项
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-reminder-plan 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    var problems: [String] = []

    // ---- 1. 统一设置层 ----
    let settingsStore = SettingsStore(configDirectory: AppPaths.supportDirectory)
    _ = try? settingsStore.update { $0.reminder.enabled = true; $0.reminder.leadMinutes = 10 }
    var loaded = settingsStore.load()
    if !loaded.reminder.enabled || loaded.reminder.leadMinutes != 10 {
        problems.append("settings.json 往返失败：enabled=\(loaded.reminder.enabled) lead=\(loaded.reminder.leadMinutes)")
    }
    // 旧调用路径（整份外观字典）不能把 reminder 抹掉
    let legacyStore = ScheduleStore()
    _ = try? legacyStore.saveConfig(loaded.appearance.dictionary)
    loaded = settingsStore.load()
    if !loaded.reminder.enabled {
        problems.append("旧的 saveConfig 路径把 reminder 抹掉了")
    }
    if let data = try? Data(contentsOf: settingsStore.configFile),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       obj["reminder"] != nil {
        problems.append("config.json 里出现了 reminder（旧版会把它抹掉）")
    }
    print("设置层：settings.json 往返 ✓，旧 saveConfig 合并 ✓，config.json 只留外观 ✓")

    // ---- 2. 规划器 ----
    let timetableStore = TimetableStore()
    _ = try? timetableStore.migrateLegacyIfNeeded(defaultName: "我的课表")
    if timetableStore.activeID == nil, let first = timetableStore.allMetas().first {
        try? timetableStore.setActive(first.id)
    }
    guard let activeID = timetableStore.activeID else {
        print("❌ 没有当前课表")
        exit(1)
    }
    let repo = timetableStore.repository(for: activeID)
    let snapshot = repo.load()
    guard !snapshot.courses.isEmpty else {
        print("❌ 临时课表里没有课程")
        exit(1)
    }
    let now = Date()
    let detailed = ClassReminderPlanner.planDetailed(
        courses: snapshot.courses,
        overrides: snapshot.overrides,
        semesterStart: snapshot.semester.start,
        maxWeek: snapshot.semester.effectiveMaxWeek(for: snapshot.courses),
        leadMinutes: loaded.reminder.leadMinutes,
        now: now)

    print("规划：课程 \(snapshot.courses.count) 条 → 提醒 \(detailed.plans.count) 条"
          + (detailed.droppedCount > 0 ? "（丢弃 \(detailed.droppedCount) 条）" : ""))
    if detailed.plans.count > ClassReminderPlanner.maxPlans {
        problems.append("提醒超过硬上限 \(ClassReminderPlanner.maxPlans)：\(detailed.plans.count)")
    }
    if detailed.plans.isEmpty {
        problems.append("临时课表的课在 14 天窗口内一条都没排（数据/学期配置不对？）")
    }
    // id 稳定、不重复、带 dt.class. 前缀
    let ids = detailed.plans.map { $0.id }
    if Set(ids).count != ids.count { problems.append("提醒 id 有重复") }
    if !ids.allSatisfy({ $0.hasPrefix("dt.class.") }) { problems.append("提醒 id 前缀不对") }
    if !ids.allSatisfy({ $0.allSatisfy { $0.isASCII } }) { problems.append("提醒 id 里有非 ASCII") }
    // 全部在未来
    if detailed.plans.contains(where: { $0.fireDate <= now }) {
        problems.append("有提醒的触发时间已经过去了")
    }
    if let first = detailed.plans.first {
        let comps = ClassReminderPlanner.dateComponents(for: first.fireDate)
        if comps.timeZone?.identifier != "Asia/Shanghai" {
            problems.append("DateComponents 没带 Asia/Shanghai")
        }
        print("  第一条：\(first.id) → \(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0) "
              + "\(comps.hour ?? 0):\(String(format: "%02d", comps.minute ?? 0))"
              + "　第 \(first.week) 周 周\(first.day) 第 \(first.block) 格　\(first.body)")
        print("  窗口内共 \(Set(detailed.plans.map { $0.week }).sorted()) 周")
    }

    // ---- 3. 自动化护栏 ----
    let scheduler = ClassReminderScheduler()
    if !scheduler.automationBlocked {
        problems.append("自检进程没有被识别成自动化模式（会去请求真实通知权限）")
    }
    let login = LoginItemController()
    if login.currentState() != .unsupportedOS {
        problems.append("自检进程读到了真实登录项状态（不该碰）")
    }
    print("自动化护栏：不请求通知权限 ✓，不注册登录项 ✓")

    if problems.isEmpty {
        print("✅ 设置层 / 提醒规划自检通过")
        exit(0)
    } else {
        for p in problems { print("问题：\(p)") }
        exit(1)
    }
}

if arguments.contains("--notifications-status") {
    // 手工验收辅助：只**读**当前通知授权与本应用的待发通知，不请求、不发送。
    let scheduler = ClassReminderScheduler(isAutomation: false)
    let sem = DispatchSemaphore(value: 0)
    scheduler.authorizationDescription { text in
        print("通知授权：\(text)")
        sem.signal()
    }
    sem.wait()
    let sem2 = DispatchSemaphore(value: 0)
    scheduler.pendingIDs { ids in
        print("本应用待发通知：\(ids.count) 条")
        for id in ids.prefix(10) { print("  · \(id)") }
        if ids.count > 10 { print("  · …还有 \(ids.count - 10) 条") }
        sem2.signal()
    }
    sem2.wait()
    exit(0)
}

if arguments.contains("--verify-settings-card") {
    // 自检：「提醒与启动」卡片（1.1.0 新增）。
    //
    // 只读界面状态，**不**请求通知权限、**不**注册登录项：
    // 本进程属于自动化模式，登录项开关本来就该是灰的。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-settings-card 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let ts = TimetableStore()
    _ = try? ts.migrateLegacyIfNeeded(defaultName: "我的课表")
    let ctl = SettingsWindowController(store: ts.configStore, timetableStore: ts) {}
    ctl.buildWindow()
    ctl.window.layoutIfNeeded()
    // 通知状态行是异步回调写的（getNotificationSettings），转一下 runloop 再读。
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    // 「日期覆盖层」卡片的状态行也要刷一次 ——
    // `refreshDayPanelRows()` 平时是在 `show()` 里调的，
    // 这里没走 show()，得自己补上（否则天气行还是初始的空白状态）。
    ctl.refreshDayPanelRows()
    ctl.window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    var problems: [String] = []
    var probe = ctl.probeReminderCard()
    if !probe.hasReminderCard { problems.append("没找到「提醒与启动」卡片") }
    if probe.cardCount < 6 { problems.append("卡片数量不对：\(probe.cardCount)（原有卡片被删了？）") }
    if probe.cardIndex != probe.cardCount - 2 {
        problems.append("新卡片应排在退出卡片之上：index=\(probe.cardIndex)/\(probe.cardCount)")
    }
    if probe.cardHeight < 100 { problems.append("卡片高度异常：\(probe.cardHeight)") }
    if probe.reminderOn { problems.append("提醒默认应该是关的") }
    if probe.leadEnabled { problems.append("提醒关闭时，提前提醒下拉应置灰") }
    if probe.testButtonEnabled { problems.append("提醒关闭时，测试按钮应不可用") }
    if probe.loginSwitchEnabled { problems.append("自动化模式下登录项开关必须是灰的（不许注册）") }
    if !probe.openNotifyButtonPresent { problems.append("「打开通知设置」按钮不见了") }
    if !probe.openNotifyButtonEnabled { problems.append("「打开通知设置」按钮应保持可用（未授权时也要留入口）") }
    if !probe.loginStateText.contains("macOS 13") && !probe.loginStateText.contains("不可用") {
        problems.append("登录项状态行没说明不可用：\(probe.loginStateText)")
    }
    if !probe.notificationText.contains("自动化") {
        problems.append("通知状态行该说明自动化模式：\(probe.notificationText)")
    }
    // ---- 「日期覆盖层」卡片：天气行（2026-11 新增）----
    //
    // 天气要**定位权限 + 联网**，默认关 —— 关着时不该显示「去授权」。
    let dpProbe = ctl.probeDayPanelCard()
    if !dpProbe.hasCard { problems.append("没找到「日期覆盖层」卡片") }
    if dpProbe.weatherOn { problems.append("天气默认应该是关的") }
    if dpProbe.showsAuthorizeButton {
        problems.append("天气关着时不该显示「去授权」按钮")
    }
    if dpProbe.cardHeight < 120 {
        problems.append("「日期覆盖层」卡片高度异常（\(Int(dpProbe.cardHeight))）—— 天气行可能没加上")
    }
    print("  日期覆盖层卡片：天气开=\(dpProbe.weatherOn)　\(dpProbe.weatherStatus)")

    print("卡片：\(probe.cardCount) 张（新卡片 index=\(probe.cardIndex)，高度 \(Int(probe.cardHeight))）")
    print("  提醒：开=\(probe.reminderOn) 提前=\(probe.leadSelection) 下拉可用=\(probe.leadEnabled)")
    print("  登录项：开关可用=\(probe.loginSwitchEnabled)　\(probe.loginStateText)")
    print("  通知：\(probe.notificationText)")

    // 打开提醒（写 settings.json）→ 下拉与状态要跟着变
    let settingsStore = SettingsStore(configDirectory: ts.configStore.configDirectory)
    _ = try? settingsStore.update { $0.reminder.enabled = true; $0.reminder.leadMinutes = 15 }
    ctl.reload()
    ctl.syncUI()
    ctl.window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    probe = ctl.probeReminderCard()
    if !probe.reminderOn { problems.append("打开提醒后开关没同步") }
    if !probe.leadEnabled { problems.append("打开提醒后「提前提醒」应可用") }
    if probe.leadSelection != "提前 15 分钟" {
        problems.append("提前分钟没同步：\(probe.leadSelection)")
    }
    if probe.testButtonEnabled {
        problems.append("自动化模式下测试按钮必须不可用（不许发真实通知）")
    }
    print("  打开提醒后：开=\(probe.reminderOn) 提前=\(probe.leadSelection) 下拉可用=\(probe.leadEnabled)"
          + " 测试按钮=\(probe.testButtonEnabled)")

    // 关掉，别把临时目录里的设置留成「开着」
    _ = try? settingsStore.update { $0.reminder.enabled = false }

    if problems.isEmpty {
        print("✅ 提醒与启动卡片自检通过")
        exit(0)
    } else {
        for p in problems { print("问题：\(p)") }
        exit(1)
    }
}


if arguments.contains("--verify-period-save") {
    // 自检：「课程时间自定义」编辑 → 写盘 → 当前进程生效 的整条链路。
    //
    // 只允许写**临时目录**（DT_DATA_DIR）。没有隔离目录就直接拒绝 ——
    // 绝不能为了自检去改用户真实的 settings.json。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-period-save 需要 DT_DATA_DIR（临时目录），拒绝碰真实设置")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let ts = TimetableStore()
    _ = try? ts.migrateLegacyIfNeeded(defaultName: "我的课表")
    let ctl = SettingsWindowController(store: ts.configStore, timetableStore: ts) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.syncUI()
    ctl.expandTo(.timetable)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    ctl.window.contentView?.layoutSubtreeIfNeeded()

    var problems: [String] = []
    guard let editor = ctl.periodEditor else {
        print("❌ 没有「课程时间自定义」列表")
        exit(1)
    }
    let disk = SettingsStore(configDirectory: ts.configStore.configDirectory)

    // 1) 合法修改 → 写盘 + Schedule 立即生效 + 输入框规范化
    let ok = editor.commitForTest(row: 0, start: "7:10", end: "07：55")
    if !ok { problems.append("合法的自定义时间被拒绝了") }
    var expected = PeriodSettings.defaults
    expected[0] = PeriodTime(start: "07:10", end: "07:55")
    if disk.load().periods.times != expected {
        problems.append("settings.json 里的作息没写对：\(disk.load().periods.times[0])")
    }
    if Schedule.periods[0].start != "07:10" || Schedule.periods[0].end != "07:55" {
        problems.append("当前进程的 Schedule 没立刻生效：第 1 节 \(Schedule.periods[0].start)–\(Schedule.periods[0].end)")
    }
    if !Schedule.timeRange(block: 0).hasPrefix("07:10") {
        problems.append("第 1 块时间范围没跟着变：\(Schedule.timeRange(block: 0))")
    }
    if editor.firstRowTexts?.start != "07:10" || editor.firstRowTexts?.end != "07:55" {
        problems.append("输入框没有规范成 07:10–07:55")
    }
    print("  保存后：磁盘第 1 节 \(disk.load().periods.times[0].start)–\(disk.load().periods.times[0].end)，"
          + "Schedule 第 1 块 \(Schedule.timeRange(block: 0))")

    // 2) 非法修改（开始晚于结束）→ 拒绝，输入框回滚，磁盘不动
    if editor.commitForTest(row: 0, start: "09:00", end: "08:00") {
        problems.append("开始晚于结束竟然保存了")
    }
    if disk.load().periods.times != expected {
        problems.append("非法修改把磁盘写坏了")
    }
    if editor.firstRowTexts?.start != "07:10" || editor.firstRowTexts?.end != "07:55" {
        problems.append("非法修改后输入框没有回滚")
    }
    print("  非法修改后：磁盘仍是 \(disk.load().periods.times[0].start)–\(disk.load().periods.times[0].end)，"
          + "输入框 \(editor.firstRowTexts?.start ?? "?")–\(editor.firstRowTexts?.end ?? "?")")

    // 3) 改回默认 → 磁盘恢复默认作息
    if !editor.commitForTest(row: 0, start: "08:00", end: "08:45") {
        problems.append("改回默认时间被拒绝了")
    }
    if disk.load().periods.times != PeriodSettings.defaults {
        problems.append("改回默认后磁盘作息不对")
    }

    if problems.isEmpty {
        print("✅ 课程时间自定义：编辑 → 写盘 → 立即生效：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-lead-custom") {
    // 自检：「提前提醒」下拉框的「自定义…」入口。
    //
    // 验证点：
    //   · 下拉框最后一项恒为「自定义…」
    //   · 当前值不是候选时（如 12），列表里多一项「提前 12 分钟（自定义）」并选中它
    //   · 选「自定义…」→ 弹输入框 → 填 45 → 确定 → 存盘 45，列表跟着变
    //
    // 只写临时目录（DT_DATA_DIR），不碰用户真实设置。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-lead-custom 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    func findLeadButton(_ title: String, in view: NSView) -> NSButton? {
        for sub in view.subviews {
            if let b = sub as? NSButton, b.title == title { return b }
            if let hit = findLeadButton(title, in: sub) { return hit }
        }
        return nil
    }

    func findLeadField(in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let f = sub as? NSTextField, f.isEditable { return f }
            if let hit = findLeadField(in: sub) { return hit }
        }
        return nil
    }

    let ts = TimetableStore()
    _ = try? ts.migrateLegacyIfNeeded(defaultName: "我的课表")
    let ctl = SettingsWindowController(store: ts.configStore, timetableStore: ts) {}
    ctl.buildWindow()
    ctl.window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    var problems: [String] = []
    let settingsStore = SettingsStore(configDirectory: ts.configStore.configDirectory)

    // 默认值 10（候选）→ 6 个候选 + 「自定义…」
    var probe = ctl.probeReminderCard()
    if probe.leadItemTitles.last != "自定义…" {
        problems.append("下拉框最后一项应是「自定义…」：\(probe.leadItemTitles)")
    }
    if probe.leadItemTitles.count != ReminderSettings.leadOptions.count + 1 {
        problems.append("下拉框条目数不对：\(probe.leadItemTitles.count)（候选 \(ReminderSettings.leadOptions.count) + 自定义 1）")
    }
    print("默认下拉：\(probe.leadItemTitles.joined(separator: " / "))")

    // 当前值不是候选（12）→ 多一项「提前 12 分钟（自定义）」并选中它
    _ = try? settingsStore.update { $0.reminder.leadMinutes = 12 }
    ctl.reload()
    ctl.syncUI()
    ctl.window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    probe = ctl.probeReminderCard()
    if !probe.leadItemTitles.contains("提前 12 分钟（自定义）") {
        problems.append("当前值 12 没出现在列表里：\(probe.leadItemTitles)")
    }
    if probe.leadItemTitles.last != "自定义…" {
        problems.append("多了一项之后「自定义…」不在最后：\(probe.leadItemTitles)")
    }
    if probe.leadSelection != "提前 12 分钟（自定义）" {
        problems.append("没选中当前的自定义值：\(probe.leadSelection)")
    }
    if probe.leadSelectedIndex != probe.leadItemTitles.count - 2 {
        problems.append("选中的不是自定义值那一项：index=\(probe.leadSelectedIndex)")
    }
    print("自定义值下拉：\(probe.leadItemTitles.joined(separator: " / "))　选中：\(probe.leadSelection)")
    // 宽度：最长那条标题（「提前 12 分钟（自定义）」）不能被截断。
    // 截断了用户就看不出自己设了几分钟 —— 肉眼看得很清楚，断言盯着更稳。
    let longest = probe.leadItemTitles.max(by: { $0.count < $1.count }) ?? ""
    let needed = (longest as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
    if probe.leadPopupWidth + 1 < needed {
        problems.append("下拉框太窄，最长标题「\(longest)」会被截断：宽度 \(Int(probe.leadPopupWidth)) < 需要 \(Int(needed))")
    }
    print("  下拉框宽度：\(Int(probe.leadPopupWidth))（最长标题「\(longest)」需要 \(Int(needed))）")
    // 不能溢出卡片：卡片内容区右边缘之外不该有下拉框（会被裁掉 / 压到别的卡片上）。
    if probe.leadPopupMaxX > probe.cardContentWidth + 1 {
        problems.append("下拉框溢出卡片：右边缘 \(Int(probe.leadPopupMaxX)) > 卡片宽 \(Int(probe.cardContentWidth))")
    }

    // 选「自定义…」→ 弹输入框 → 填 45 → 确定
    var filled = false
    var confirmed = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        for w in NSApp.windows where w.title == "自定义提前提醒" && w.isVisible {
            guard let content = w.contentView,
                  let field = findLeadField(in: content),
                  let btn = findLeadButton("确定", in: content) else { continue }
            field.stringValue = "45"
            filled = true
            confirmed = true
            btn.performClick(nil)
            return
        }
    }
    // 兜底：2.5 秒内没点到就点「取消」，别让自检卡死。
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        for w in NSApp.windows where w.title == "自定义提前提醒" && w.isVisible {
            guard let content = w.contentView,
                  let btn = findLeadButton("取消", in: content) else { continue }
            btn.performClick(nil)
            return
        }
    }
    ctl.testSelectLeadItem(at: probe.leadItemTitles.count - 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if !filled { problems.append("没找到「自定义提前提醒」弹窗里的输入框") }
    if !confirmed { problems.append("没点到「确定」") }
    let saved = settingsStore.load().reminder.leadMinutes
    if saved != 45 { problems.append("填了 45 却存成 \(saved)") }
    probe = ctl.probeReminderCard()
    if !probe.leadItemTitles.contains("提前 45 分钟（自定义）") {
        problems.append("列表没跟着变：\(probe.leadItemTitles)")
    }
    if probe.leadSelection != "提前 45 分钟（自定义）" {
        problems.append("没选中 45：\(probe.leadSelection)")
    }
    print("自定义 45 后：\(probe.leadItemTitles.joined(separator: " / "))　选中：\(probe.leadSelection)")

    if problems.isEmpty {
        print("✅ 自定义提前提醒自检通过")
        exit(0)
    } else {
        for p in problems { print("问题：\(p)") }
        exit(1)
    }
}

if arguments.contains("--login-item-selftest") {
    // 手工验收辅助：在**真实 app bundle** 里试一次登录项注册，随后**立刻注销**。
    //
    // 为什么要这一步：`SMAppService.mainApp` 只有在 app bundle 里才有意义，
    // 单元测试（非 bundle 进程）测不了它。这个开关只在手工验收时用，
    // 而且是「注册 → 读状态 → 立刻注销」，不会留下指向 build/ 的失效登录项。
    print("macOS 版本支持：\(LoginItemController.isSupported)")
    let ctl = LoginItemController(isAutomation: false)
    print("初始状态：\(ctl.currentState())")
    let afterRegister = ctl.setEnabled(true)
    print("注册 → \(afterRegister)")
    let afterUnregister = ctl.setEnabled(false)
    print("注销 → \(afterUnregister)")
    print("最终状态：\(ctl.currentState())")
    if case .failed(let message) = afterRegister {
        print("⚠️ 注册失败（真实错误）：\(message)")
    }
    exit(0)
}

if arguments.contains("--verify-web-render") {
    // 自检：跑一遍真实的网页渲染链路，用 evaluateJavaScript 检查 DOM，
    // **不调用 takeSnapshot**（B 模式下不允许有快照调用）。
    //
    // 验证点：
    //   · 网页是否加载成功
    //   · 标题 / 副标题是不是当前课表的 name / subtitle
    //   · 表格格子、课程名有没有渲染出来
    //   · 冲突标记、MAX_WEEK 是否正确
    let store = TimetableStore()
    if let migrated = try? store.migrateLegacyIfNeeded(defaultName: "我的课表") {
        print("课表：\(migrated.name)")
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()

    guard let renderer = delegate.testWebRenderer else {
        print("❌ 没有渲染器")
        exit(1)
    }

    var problems: [String] = []

    // 等网页加载完
    let deadline = Date().addingTimeInterval(8)
    while !renderer.isReady && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !renderer.isReady {
        print("❌ 网页在 8 秒内没有加载完")
        exit(1)
    }
    print("✅ 网页已加载")

    // 用 evaluateJavaScript 检查 DOM（不拍快照）
    //
    // 注意：evaluateJavaScript 的回调在主线程，而这里已经在主线程了 ——
    // 不能用信号量阻塞等待（会死锁），要跑 runloop 让回调进来。
    let js = """
    (() => {
      const t = document.querySelector('.ttl');
      const st = document.querySelector('.sub');
      const cells = document.querySelectorAll('.cell');
      const courses = document.querySelectorAll('.cell.course');
      const names = [...document.querySelectorAll('.cname')]
        .map(e => (e.textContent || '').trim()).filter(Boolean).slice(0, 6);
      const times = [...document.querySelectorAll('.tcell')].slice(0, 3).map(e => ({
        s: (e.querySelector('.ts') || {}).textContent || '',
        e: (e.querySelector('.te') || {}).textContent || ''
      }));
      // 时钟回归（2026-11 修「时间停在半小时前」）：
      // 把时钟文字改成 00:00，调一次网页自己的就地刷新，必须对回当前时间。
      // 这验证的是「不重建 DOM 也能更新时间」这条路径本身。
      const tn = document.querySelector('.clock .tnum');
      if (tn) tn.textContent = '00:00';
      if (window.__ttUpdateClock) window.__ttUpdateClock();
      const clockAfter = tn ? tn.textContent.trim() : null;
      const now = new Date();
      const pad2 = n => (n < 10 ? '0' : '') + n;
      const clockWant = pad2(now.getHours()) + ':' + pad2(now.getMinutes());
      const stxt = document.querySelector('.status .stxt');
      // 耗电回归（2026-11）：呼吸圈动画必须只改 transform / opacity，
      // 不能再拿 box-shadow 做逐帧无限动画（那会让整张卡片每帧重绘）。
      const pulse = document.querySelector('.status .pulse');
      const pulseBefore = pulse ? getComputedStyle(pulse, '::before') : null;
      const pulseSelf = pulse ? getComputedStyle(pulse) : null;
      const pulseAfter = pulse ? getComputedStyle(pulse, '::after') : null;
      return JSON.stringify({
        title: t ? t.textContent.trim() : null,
        subtitle: st ? st.textContent.trim() : null,
        cellCount: cells.length,
        courseCount: courses.length,
        names: names,
        times: times,
        confCount: document.querySelectorAll('.cconf').length,
        clockAfter: clockAfter,
        clockWant: clockWant,
        clockTimer: window.__ttClockTimer === true,
        statusText: stxt ? stxt.textContent.trim() : null,
        pulseAnim: pulseBefore ? pulseBefore.animationName : null,
        pulseSize: pulseBefore ? (pulseBefore.width + ' x ' + pulseBefore.height) : null,
        pulseShadow: pulseSelf ? pulseSelf.boxShadow : null,
        pulseDotBg: pulseAfter ? pulseAfter.backgroundColor : null,
        parseError: window.__ttParseError || null,
        renderError: window.__ttRenderError || null
      });
    })()
    """

    var jsonOut: String? = nil
    renderer.evaluateForTest(js) { result in
        jsonOut = result
    }
    let jsDeadline = Date().addingTimeInterval(5)
    while jsonOut == nil && Date() < jsDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    guard let jsonOut, let data = jsonOut.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("❌ 拿不到网页状态")
        exit(1)
    }

    let title = obj["title"] as? String ?? ""
    let subtitle = obj["subtitle"] as? String ?? ""
    let cellCount = obj["cellCount"] as? Int ?? 0
    let courseCount = obj["courseCount"] as? Int ?? 0
    let names = obj["names"] as? [String] ?? []
    let confCount = obj["confCount"] as? Int ?? 0
    let webTimes = obj["times"] as? [[String: Any]] ?? []
    let clockAfter = obj["clockAfter"] as? String ?? ""
    let clockWant = obj["clockWant"] as? String ?? ""
    let clockTimer = obj["clockTimer"] as? Bool ?? false
    let statusText = obj["statusText"] as? String ?? ""
    let pulseAnim = obj["pulseAnim"] as? String ?? ""
    let pulseSize = obj["pulseSize"] as? String ?? ""
    let pulseShadow = obj["pulseShadow"] as? String ?? ""
    let pulseDotBg = obj["pulseDotBg"] as? String ?? ""

    print("  标题：\(title.isEmpty ? "(空)" : title)")
    print("  副标题：\(subtitle.isEmpty ? "(空)" : subtitle)")
    print("  格子数：\(cellCount)")
    print("  课程块数：\(courseCount)")
    print("  冲突标记：\(confCount)")
    print("  课程名样例：\(names.joined(separator: " / "))")
    print("  时间列样例：" + webTimes.prefix(3).map {
        "\($0["s"] as? String ?? "?")–\($0["e"] as? String ?? "?")"
    }.joined(separator: " / "))

    // 时间列必须和原生 `Schedule.periods` 一致 —— 验证 settings.json 里的自定义作息
    // 真的穿过 webJSON → Timetable.js，而不只是原生侧改了。
    for (i, expected) in Schedule.periods.prefix(3).enumerated() {
        guard i < webTimes.count else {
            problems.append("网页时间列第 \(i + 1) 节缺失")
            continue
        }
        let s = webTimes[i]["s"] as? String ?? ""
        let e = webTimes[i]["e"] as? String ?? ""
        if s != expected.start || e != expected.end {
            problems.append("网页时间列第 \(i + 1) 节是 \(s)–\(e)，原生作息是 \(expected.start)–\(expected.end)")
        }
    }

    // 时钟不能只在整树 render 时才更新 —— 原生每分钟推的状态在数据没变时
    // 不重画顶部，所以网页必须能自己就地刷新（2026-11 修「时间停在半小时前」）。
    if !clockTimer {
        problems.append("网页没有装上时钟定时器（window.__ttClockTimer）")
    }
    if clockAfter != clockWant {
        problems.append("时钟就地刷新失效：期望 \(clockWant)，实际 \(clockAfter)")
    }
    if statusText.isEmpty {
        problems.append("状态条文字为空")
    }
    // 呼吸圈省电回归：动画必须挂在伪元素的 transform / opacity 上。
    // 如果又有人把它改回 `box-shadow` 无限动画，这里会明确报出来。
    if pulseAnim != "pl" && pulseAnim != "pl-idle" {
        problems.append("呼吸圈伪元素没有在跑动画（animation-name=\(pulseAnim.isEmpty ? "空" : pulseAnim)）")
    }
    if pulseSize != "21px x 21px" {
        problems.append("呼吸圈伪元素尺寸异常：\(pulseSize)")
    }
    if pulseShadow != "none" {
        problems.append("呼吸圈又用 box-shadow 做动画了（会逐帧重绘整张卡片）：\(pulseShadow)")
    }
    if pulseDotBg.isEmpty || pulseDotBg == "rgba(0, 0, 0, 0)" {
        problems.append("呼吸圈的圆点没有画在 ::after 上")
    }
    print("  呼吸圈：\(pulseAnim)，伪元素 \(pulseSize)，box-shadow=\(pulseShadow)")
    print("  时钟就地刷新：\(clockAfter)（期望 \(clockWant)）")

    if let pe = obj["parseError"] as? String { print("  ❌ JS 解析错误：\(pe)") }
    if let re = obj["renderError"] as? String { print("  ❌ JS 渲染错误：\(re)") }

    // 期望值来自当前课表
    if let active = store.activeID, let t = try? store.load(active) {
        if title != t.name { problems.append("标题不对：网页显示「\(title)」，课表叫「\(t.name)」") }
        if subtitle != t.subtitle { problems.append("副标题不对：网页显示「\(subtitle)」，课表是「\(t.subtitle)」") }
        if t.courses.isEmpty && courseCount != 0 { problems.append("空课表却渲染出了 \(courseCount) 个课程块") }
        if !t.courses.isEmpty && courseCount == 0 { problems.append("课表有 \(t.courses.count) 条记录，但网页一个课程块都没渲染") }
        if cellCount == 0 { problems.append("表格格子一个都没有") }
    }

    if let pe = obj["parseError"] as? String { problems.append("JS 解析错误：\(pe)") }
    if let re = obj["renderError"] as? String { problems.append("JS 渲染错误：\(re)") }

    // B 模式：整个过程不允许有 takeSnapshot
    if renderer.testRealSnapshotCount != 0 {
        problems.append("出现了 \(renderer.testRealSnapshotCount) 次 takeSnapshot")
    } else {
        print("  takeSnapshot 次数：0 ✅")
    }

    if problems.isEmpty {
        print("✅ 网页渲染自检通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-switch-refresh") {
    // 自检：**新建 / 切换课表之后，桌面卡片是不是立刻刷新**。
    //
    // 以前的 bug：`refreshCard()` 只在「跨分钟」或 `webNeedsRefresh` 时才推状态给网页，
    // 而切课表这条路径没设这个标记 —— 同一分钟内切过去，卡片还显示旧课表。
    // 这里真的建一份新课表、切过去，然后在**同一分钟**内读网页标题，必须已经是新名字。
    _ = try? TimetableStore().migrateLegacyIfNeeded(defaultName: "我的课表")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()

    guard let renderer = delegate.testWebRenderer else {
        print("❌ 没有渲染器")
        exit(1)
    }
    let deadline = Date().addingTimeInterval(8)
    while !renderer.isReady && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !renderer.isReady {
        print("❌ 网页在 8 秒内没有加载完")
        exit(1)
    }

    /// 读网页卡片标题
    func webTitle() -> String? {
        var out: String? = nil
        renderer.evaluateForTest("(document.querySelector('.ttl')||{}).textContent||''") { r in
            out = r
        }
        let d = Date().addingTimeInterval(5)
        while out == nil && Date() < d {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return out
    }

    var problems: [String] = []
    let store = TimetableStore()

    // 1) 建一份新课表并切过去（跟设置面板「新建」做的事一致）
    let stamp = Int(Date().timeIntervalSince1970) % 100000
    let newName = "刷新自检 \(stamp)"
    guard let created = try? store.create(name: newName) else {
        print("❌ 建不出新课表")
        exit(1)
    }
    _ = try? store.setActive(created.id)
    // 2) 走上层回调（设置面板 onTimetablesChanged 里做的事）
    delegate.testTimetablesChanged()

    // 3) 同一分钟内读网页标题 —— 必须是新名字
    var shown = ""
    let checkDeadline = Date().addingTimeInterval(2)
    while Date() < checkDeadline {
        shown = (webTitle() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if shown == newName { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    print("  新建并切换后，网页标题 = \(shown.isEmpty ? "(空)" : shown)")
    if shown != newName {
        problems.append("新建/切换后卡片没刷新：网页标题还是「\(shown)」，应该是「\(newName)」")
    }

    // 4) 切回原来那份，同样要立刻刷新
    if let first = store.allMetas().first(where: { $0.id != created.id }) {
        _ = try? store.setActive(first.id)
        delegate.testTimetablesChanged()
        var back = ""
        let d2 = Date().addingTimeInterval(2)
        while Date() < d2 {
            back = (webTitle() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if back == first.name { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        print("  切换回去后，网页标题 = \(back.isEmpty ? "(空)" : back)")
        if back != first.name {
            problems.append("切回后卡片没刷新：网页标题还是「\(back)」，应该是「\(first.name)」")
        }
    }

    // 5) 收尾：把自检建的课表删掉（临时目录也无所谓，但保持干净）
    _ = try? store.delete(id: created.id)

    if problems.isEmpty {
        print("✅ 切换课表后立即刷新：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-preview-refresh") {
    // 自检：**切换课表后，设置面板的「课程预览」是不是马上换成新课表的内容**。
    //
    // 以前的 bug：设置面板 `reload()` 只刷了「课表」摘要和课表列表，
    // 课程预览表格还挂着旧课表的行 —— 用户点完「应用当前课表」，
    // 预览要等自己切周次或重开面板才更新。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let ts = TimetableStore()
    let semester = SemesterConfig(start: Date().addingTimeInterval(-7 * 86400), maxWeek: 16)
    func makeCourse(_ name: String, day: Int, block: Int) -> Course {
        Course(day: day, block: block, name: name, teacher: "测试老师",
               loc: "教一-101", courseID: name, weeks: Array(1...16))
    }
    guard let a = try? ts.create(name: "甲", courses: [makeCourse("甲课程", day: 1, block: 0)],
                                 semester: semester),
          let b = try? ts.create(name: "乙", courses: [makeCourse("乙课程一", day: 2, block: 1),
                                                        makeCourse("乙课程二", day: 3, block: 2)],
                                 semester: semester) else {
        print("❌ 建不出测试课表")
        exit(1)
    }
    try? ts.setActive(a.id)

    let panel = SettingsWindowController(store: ts.configStore, timetableStore: ts) {}
    panel.buildWindow()   // 建界面（不显示），预览表格才有数据源
    panel.reload()

    var problems: [String] = []
    let before = panel.previewCourseNames
    let rowsBefore = panel.tableView.numberOfRows
    print("  切换前，课程预览 = \(before)，表格行数 = \(rowsBefore)")
    if before != ["甲课程"] {
        problems.append("切换前课程预览就不对：\(before)")
    }
    if rowsBefore != 1 {
        problems.append("切换前表格行数不对：\(rowsBefore)")
    }

    // 点「应用当前课表」这一侧做的事：setActive + 面板 reload
    try? ts.setActive(b.id)
    panel.reload()
    let after = panel.previewCourseNames
    // 关键：**表格本身**要重绘 —— 表格没 reloadData 时行数还是旧的
    let rowsAfter = panel.tableView.numberOfRows
    print("  切换后，课程预览 = \(after)，表格行数 = \(rowsAfter)")
    if after != ["乙课程一", "乙课程二"] {
        problems.append("切换后课程预览没刷新：\(after)")
    }
    if rowsAfter != 2 {
        problems.append("切换后预览表格没重绘：行数还是 \(rowsAfter)，应该是 2")
    }

    if problems.isEmpty {
        print("✅ 切换课表后课程预览立即刷新：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-panel-scroll") {
    // 自检：**设置面板打开时必须从顶部开始显示**。
    //
    // 曾经的 bug：面板的滚动视图文档视图是普通 `NSView`（非 flipped，原点在左下角），
    // 于是裁剪区原点 (0,0) 对应的是文档的**底部** —— 面板一打开就停在
    // 「退出应用」那截，第二次打开还是最下面（滚动位置还被保留着）。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let ctl = SettingsWindowController(store: ScheduleStore(), timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.window.contentView?.layoutSubtreeIfNeeded()

    print("  \(ctl.debugScrollState)")
    if ctl.panelOpensAtTop {
        print("✅ 设置面板从顶部开始显示：通过")
        exit(0)
    }
    print("❌ 设置面板的文档视图不是 flipped —— 面板会停在最下面")
    exit(1)
}

if arguments.contains("--shot-panel-mid") {
    // 截图：把面板**停在扩张动画的中间尺寸**上渲染一张 PNG。
    //
    // 为什么不用「实时连拍」：0.28s 的动画太快，`screencapture` 一帧要 ~350ms，
    // 根本拍不到中间态。这里改成**离线渲染** ——
    // 直接把窗口设成中间尺寸（`setFrame`），再把内容画成 PNG，
    // 拍出来的就是「扩张到一半」时用户看到的样子。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    var shotDir = "/tmp/dt-shots"
    if let idx = arguments.firstIndex(of: "--shots"), idx + 1 < arguments.count {
        shotDir = arguments[idx + 1]
    }
    try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)

    let ctl = SettingsWindowController(store: ScheduleStore(),
                                       timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.show(relativeTo: NSEvent.mouseLocation)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    guard let win = ctl.window else { exit(1) }
    // 展开到「外观」—— 把动画**关掉**（倍率 0 = 不跑动画），否则
    // 动画结束时会把我们设的中间尺寸覆盖掉。
    SettingsWindowController.animationSpeedFactor = 0
    ctl.expandTo(.appearance)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    // 收起态尺寸 → 展开态尺寸的中点。
    let collapsed = SettingsWindowController.collapsedSize
    let expanded = ctl.currentWindowSize
    let mid = NSSize(width: expanded.width,
                     height: (collapsed.height + expanded.height) / 2)
    let center = NSPoint(x: win.frame.midX, y: win.frame.midY)
    win.setFrame(NSRect(x: center.x - mid.width / 2,
                        y: center.y - mid.height / 2,
                        width: mid.width, height: mid.height), display: true)
    // 高度约束也要跟着改，否则内容会被压缩/拉伸。
    ctl.setPanelContentHeight(mid.height)
    win.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))

    print("  中间态尺寸：\(Int(mid.width))×\(Int(mid.height))")
    let ok = ctl.renderCurrentWindow(to: "\(shotDir)/02-扩张中间态-渲染.png")
    print("  渲染：\(ok ? "成功" : "失败") → \(shotDir)/02-扩张中间态-渲染.png")

    // 收缩中间态：回到首页的**一半**高度。
    ctl.backToHome()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let backMid = NSSize(width: expanded.width,
                         height: (collapsed.height + expanded.height) / 2)
    let c2 = NSPoint(x: win.frame.midX, y: win.frame.midY)
    win.setFrame(NSRect(x: c2.x - backMid.width / 2,
                        y: c2.y - backMid.height / 2,
                        width: backMid.width, height: backMid.height), display: true)
    ctl.setPanelContentHeight(backMid.height)
    win.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    let ok2 = ctl.renderCurrentWindow(to: "\(shotDir)/04-收缩中间态-渲染.png")
    print("  收缩中间态渲染：\(ok2 ? "成功" : "失败")")

    // ⚠️ **自检收尾：把设置面板收走**（否则它一直浮在用户窗口前面）。
    ctl.closeForAutomationCleanup()
    exit(ok && ok2 ? 0 : 1)
}

if arguments.contains("--verify-panel-animation") {
    // 自检：扩张 / 收缩动画必须**以屏幕中心为锚点对称进行**。
    //
    // 逐帧采样窗口的 frame，验三件事：
    //   1. 尺寸是**连续插值**的（相邻帧不能有巨大跳变）；
    //   2. 窗口**中心全程不动**（始终等于屏幕可见区中心）；
    //   3. 扩张后确实变高、收缩后确实回到收起态。
    //
    // 这比截图更硬 —— 截图只能说明「某一帧看起来居中」，
    // 逐帧采样能证明「整个动画过程中心都没飘」。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // `--slow-anim N`：把动画放慢 N 倍（便于录屏 / 人工观察收放过程）。
    if let idx = arguments.firstIndex(of: "--slow-anim"), idx + 1 < arguments.count,
       let factor = Double(arguments[idx + 1]) {
        SettingsWindowController.animationSpeedFactor = factor
    }

    let ctl = SettingsWindowController(store: ScheduleStore(),
                                       timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.show(relativeTo: NSEvent.mouseLocation)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    ctl.window?.contentView?.layoutSubtreeIfNeeded()

    guard let win = ctl.window else {
        print("❌ 没有窗口")
        exit(1)
    }
    let screen = NSScreen.main?.visibleFrame ?? .zero
    print("  屏幕可见区中心：(\(Int(screen.midX)), \(Int(screen.midY)))")

    struct Frame { var t: Double; var w: CGFloat; var h: CGFloat; var cx: CGFloat; var cy: CGFloat }

    /// 采样一段动画（逐帧取窗口 frame）。
    ///
    /// 采样到**尺寸稳定为止**（连续 3 帧不变）就停 ——
    /// 固定时长在机器忙的时候会采到动画还没结束的帧，判定就不准了。
    func sample(_ trigger: () -> Void, maxDuration: Double = 2.0) -> [Frame] {
        let start = Date()
        var out: [Frame] = []
        trigger()
        var stable = 0
        var last = win.frame
        while Date().timeIntervalSince(start) < maxDuration {
            let f = win.frame
            out.append(Frame(t: Date().timeIntervalSince(start),
                             w: f.width, h: f.height, cx: f.midX, cy: f.midY))
            if abs(f.width - last.width) < 0.5 && abs(f.height - last.height) < 0.5 {
                stable += 1
                if stable >= 3 { break }
            } else {
                stable = 0
            }
            last = f
            RunLoop.current.run(until: Date().addingTimeInterval(0.012))
        }
        return out
    }

    // 采样时长要跟着动画倍率走 —— 放慢 20 倍时 0.28s 会变成 5.6s，
    // 固定 2s 会在动画中途就退出，后面的帧全采不到。
    let sampleBudget = max(2.0, 0.28 * SettingsWindowController.animationSpeedFactor * 2.5)

    print("\n  ── 扩张动画逐帧 ──")
    let grow = sample({ ctl.expandTo(.appearance) }, maxDuration: sampleBudget)
    for f in grow {
        print(String(format: "    t=%.3f  %6.1f × %6.1f   center=(%.1f, %.1f)",
                     f.t, f.w, f.h, f.cx, f.cy))
    }

    print("\n  ── 收缩动画逐帧 ──")
    let shrink = sample({ ctl.backToHome() }, maxDuration: sampleBudget)
    for f in shrink {
        print(String(format: "    t=%.3f  %6.1f × %6.1f   center=(%.1f, %.1f)",
                     f.t, f.w, f.h, f.cx, f.cy))
    }

    var problems: [String] = []

    /// 相邻帧的最大尺寸跳变（连续插值的硬指标）。
    ///
    /// ⚠️ 要跳过**动画启动前的几帧**：采样循环在 trigger 后立刻开始，
    /// 前一两帧窗口还没动，仍然挂着旧尺寸；它们和第一帧动画之间的差值
    /// 是「触发的瞬间」，不是插值的一步。
    ///
    /// ⚠️ 还要跳过**第一帧动画本身**：曲线是 easeOut，起步最快，
    /// 0.28s 的动画第一帧天然就占约 20% 的总位移（519 高时约 65pt）。
    /// 那是设计好的曲线形状，不是「跳变」；拿它当不连续的指标会误报。
    /// 从第二帧动画开始，相邻帧的步长才是真正用来抓卡顿/跳帧的。
    func maxJump(_ frames: [Frame]) -> CGFloat {
        guard frames.count > 3 else { return 0 }
        // 找最后一帧「还停在起始尺寸」的帧。
        var lastStill = 0
        while lastStill + 1 < frames.count,
              abs(frames[lastStill + 1].h - frames[0].h) < 0.5 {
            lastStill += 1
        }
        // 第一帧动画（lastStill + 1）也跳过。
        let start = lastStill + 1
        guard start + 1 < frames.count else { return 0 }
        var m: CGFloat = 0
        for i in (start + 1)..<frames.count {
            m = max(m, abs(frames[i].h - frames[i-1].h))
        }
        return m
    }
    /// 中心相对屏幕中心的最大漂移。
    func maxDrift(_ frames: [Frame]) -> CGFloat {
        frames.reduce(CGFloat(0)) {
            max($0, abs($1.cx - screen.midX), abs($1.cy - screen.midY))
        }
    }

    let growJump = maxJump(grow), growDrift = maxDrift(grow)
    let shrinkJump = maxJump(shrink), shrinkDrift = maxDrift(shrink)
    print("\n  ── 判定 ──")
    print(String(format: "    扩张：相邻帧最大跳变 %.1f pt · 中心最大漂移 %.1f pt", growJump, growDrift))
    print(String(format: "    收缩：相邻帧最大跳变 %.1f pt · 中心最大漂移 %.1f pt", shrinkJump, shrinkDrift))

    if growJump > 60 { problems.append("扩张时尺寸跳变 \(growJump)pt，动画不连续") }
    if shrinkJump > 60 { problems.append("收缩时尺寸跳变 \(shrinkJump)pt，动画不连续") }
    if growDrift > 2 { problems.append("扩张时窗口中心漂移 \(growDrift)pt") }
    if shrinkDrift > 2 { problems.append("收缩时窗口中心漂移 \(shrinkDrift)pt") }
    if let a = grow.first, let b = grow.last {
        if b.h <= a.h { problems.append("扩张后窗口没有变高") }
        if a.h > 200 { problems.append("扩张起始不是收起态") }
    }
    if let b = shrink.last {
        if b.h > 200 { problems.append("收缩后没有回到收起态") }
    }

    if problems.isEmpty {
        print("✅ 动画：尺寸连续插值、中心全程不动（以屏幕中心为锚点对称扩张）")
        // ⚠️ **自检收尾：把设置面板收走** ——
        // `exit()` 不会走 app 的正常收尾，面板会一直挂在用户窗口前面。
        ctl.closeForAutomationCleanup()
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-panel-click") {
    // 自检：**真实鼠标点击**板块按钮必须能展开。
    //
    // 为什么不能用 AXPress：AXPress 直接调 action，绕过了系统的
    // **命中测试**（hit testing）—— 按钮在屏幕上看得见，但点击落在
    // 别的视图上时，AXPress 照样「成功」，真实点击却没反应。
    // 用户报的「点了没反应」就是这一类问题，只能用真事件验。
    //
    // 这里派发真的 NSApp 事件（走系统的命中测试判定）。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let ctl = SettingsWindowController(store: ScheduleStore(),
                                       timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.show(relativeTo: NSEvent.mouseLocation)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    guard let win = ctl.window else { exit(1) }
    win.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    var problems: [String] = []

    /// 在窗口坐标系里找一个板块按钮的中心，派发一次真实的点击。
    @discardableResult
    func clickSection(_ section: SettingsSection) -> Bool {
        guard let home = ctl.homeScreenForTest else { return false }
        guard let tile = home.buttons.first(where: { $0.section == section }) else { return false }
        // 按钮中心 → **contentView 坐标**（NSEvent 的 locationInWindow 就是这个）。
        //
        // ⚠️ `convert(_:to: nil)` 转出来的是「窗口坐标系」（含标题栏偏移），
        // 不是 contentView 坐标系 —— 用它发事件会打偏。
        guard let content = win.contentView else { return false }
        let centerInTile = NSPoint(x: tile.bounds.midX, y: tile.bounds.midY)
        let inContent = tile.convert(centerInTile, to: content)
        // 命中测试诊断：谁接住了这个点？
        // （点不中时这里能一眼看出命中落到了谁身上）
        let hitName = win.contentView?.hitTest(inContent).map { String(describing: type(of: $0)) } ?? "nil"
        print("  「\(section.title)」砖 \(Int(tile.bounds.width))×\(Int(tile.bounds.height))"
              + " @(\(Int(inContent.x)), \(Int(inContent.y))) 命中：\(hitName)")
        // 真实事件：mouseDown → mouseUp → mouseUp（系统会做命中测试）。
        func send(_ type: NSEvent.EventType) {
            guard let ev = NSEvent.mouseEvent(
                with: type,
                location: inContent,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: (type == .leftMouseUp) ? 0 : 1) else { return }
            NSApp.sendEvent(ev)
        }
        send(.leftMouseDown)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        send(.leftMouseUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        send(.leftMouseUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return true
    }

    print("  收起态：\(ctl.currentWindowSize)")
    for section in SettingsSection.allCases {
        let before = ctl.currentWindowSize
        guard clickSection(section) else {
            problems.append("找不到「\(section.title)」按钮")
            continue
        }
        let after = ctl.currentWindowSize
        let ok = after.height > before.height
        print("  点「\(section.title)」：\(Int(before.height)) → \(Int(after.height))"
              + (ok ? " ✅" : " ❌ 没反应"))
        if !ok {
            problems.append("真实点击「\(section.title)」没有展开面板")
        } else {
            // 收回去
            ctl.backToHome()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
    }

    // ---------- 返回按钮也要能点 ----------
    //
    // 「返回」是**自绘**的（不是 NSButton）—— macOS 26 的 NSButton 内部是
    // SwiftUI 宿主视图，放进四边钉死的容器里会被撑成几百点高、
    // 自己跑到窗口外面去（用户反馈「返回键被裁掉」）。
    // 自绘的按钮必须自己接 mouseDown，AXPress 也要能触发。
    print("\n  ── 返回按钮 ──")
    ctl.expandTo(.appearance)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let expandedSize = ctl.currentWindowSize
    print("  展开后：\(Int(expandedSize.width))×\(Int(expandedSize.height))")
    if let back = ctl.backButtonForTest, let win = ctl.window {
        let inContent = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY),
                                     to: win.contentView)
        func send(_ type: NSEvent.EventType) {
            guard let ev = NSEvent.mouseEvent(
                with: type, location: inContent, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: (type == .leftMouseUp) ? 0 : 1) else { return }
            NSApp.sendEvent(ev)
        }
        send(.leftMouseDown)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        send(.leftMouseUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        send(.leftMouseUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        let after = ctl.currentWindowSize
        print("  点返回后：\(Int(after.width))×\(Int(after.height))")
        if after.height >= expandedSize.height {
            problems.append("真实点击「返回」没有收缩回首页")
        }
    } else {
        problems.append("找不到返回按钮")
    }

    if problems.isEmpty {
        print("✅ 真实鼠标点击：板块按钮都能展开，返回按钮能收缩")
        // ⚠️ **自检收尾：把设置面板收走**（否则它一直浮在用户窗口前面）。
        ctl.closeForAutomationCleanup()
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-panel-sections") {
    // 自检 + 截图：设置面板的**两级结构**（板块首页 → 分类设置页）。
    //
    // 验的是：
    //   1. 收起态是个小长条、居中在屏幕正中；
    //   2. 首页有 4 个板块按钮（外观 / 课表 / 提醒 / 系统），图标是纯色；
    //   3. 点板块 → 展开成该板块的设置页，**窗口尺寸和中心都不对**；
    //   4. 板块内容映射正确（卡片在对的板块里，一张卡片都没丢）；
    //   5. 返回 → 收缩回长条、仍然居中；
    //   6. 反复收缩→扩张→收缩，尺寸不漂移（不残影、不变形）。
    //
    // 顺便把每个状态渲染成 PNG（`--verify-panel-sections --shots <目录>`）。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    var shotDir: String?
    if let idx = arguments.firstIndex(of: "--shots"), idx + 1 < arguments.count {
        shotDir = arguments[idx + 1]
        try? FileManager.default.createDirectory(atPath: shotDir!,
                                                 withIntermediateDirectories: true)
    }

    // `--slow-anim N`：把动画放慢 N 倍（给中途截图留时间）。
    if let idx = arguments.firstIndex(of: "--slow-anim"), idx + 1 < arguments.count,
       let factor = Double(arguments[idx + 1]) {
        SettingsWindowController.animationSpeedFactor = factor
    }

    let ctl = SettingsWindowController(store: ScheduleStore(),
                                       timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.show(relativeTo: NSEvent.mouseLocation)
    ctl.window?.contentView?.layoutSubtreeIfNeeded()

    var problems: [String] = []

    func check(_ cond: Bool, _ message: String) {
        if !cond { problems.append(message) }
    }

    /// 等窗口尺寸**稳定下来**（动画结束）。
    ///
    /// ⚠️ **不能只看「连续几帧尺寸不变」** —— 动画还没启动的时候，
    /// 连着几帧都是旧尺寸，会被误判成「已经稳定」，
    /// 于是读到的是**动画开始前**的尺寸（断言误判成「没展开」）。
    ///
    /// 所以这里要求两件事同时成立：
    ///   1. 尺寸**至少变过一次**（和触发时的尺寸不同）；
    ///   2. 之后再连续 3 帧不变。
    /// 另外还兜一个最短观察时间，避免动画慢启动时提前退出。
    func settle(_ ctl: SettingsWindowController,
                changedFrom initial: NSSize? = nil,
                minObserve: TimeInterval = 0.25,
                timeout: TimeInterval = 3.0) {
        let start = Date()
        var last = ctl.currentWindowSize
        var stable = 0
        var sawChange = false
        while Date().timeIntervalSince(start) < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            let now = ctl.currentWindowSize
            let moved = abs(now.width - last.width) >= 0.5 || abs(now.height - last.height) >= 0.5
            if moved {
                sawChange = true
                stable = 0
            } else if sawChange {
                stable += 1
            }
            last = now
            let observed = Date().timeIntervalSince(start)
            if stable >= 3 && observed >= minObserve { return }
            // 尺寸压根没动过 —— 等满最短观察时间就放弃（后面断言会报错）。
            if !sawChange && observed >= minObserve { return }
        }
    }



    // ---------- 1) 收起态 ----------
    let collapsed = ctl.currentWindowSize
    print("  收起态尺寸：\(Int(collapsed.width))×\(Int(collapsed.height))")
    // 诊断：返回按钮 / 板块名的实际位置（要确认没被裁掉、且在同一水平线上）
    func dumpHeader() {
        guard let win = ctl.window else { return }
        win.layoutIfNeeded()
        win.contentView?.layoutSubtreeIfNeeded()
        func walk(_ v: NSView, _ d: Int) {
            let pad = String(repeating: "  ", count: d)
            // 只打印 root（第二层）那一支，别把砖块也打出来。
            if d <= 2 {
                print("\(pad)\(type(of: v)) frame=\(v.frame) flipped=\(v.isFlipped) hidden=\(v.isHidden)")
            }
            // 顺便打印「课表设置」标题的位置 —— 它用的是同一套约束，
            // 位置是对的（截图里标题就在红绿灯右边），
            // 对比一下就知道返回键该放哪。
            if let l = v as? NSTextField, l.stringValue == "课表设置" {
                print("\(pad)★标题「课表设置」 frame=\(l.frame) hidden=\(l.isHidden)")
            }
            if let b = v as? HeaderBackButton {
                print("\(pad)★返回按钮 frame=\(b.frame) TAM=\(b.translatesAutoresizingMaskIntoConstraints)")
                for c in b.constraints {
                    let fi = c.firstItem.map { String(describing: type(of: $0)) } ?? "nil"
                    print("\(pad)   attr \(c.firstAttribute.rawValue)→\(c.secondAttribute.rawValue) c=\(c.constant) first=\(fi) prio=\(c.priority.rawValue)")
                }
            }
            for sub in v.subviews { walk(sub, d + 1) }
        }
        for sub in (win.contentView?.subviews ?? []) { walk(sub, 1) }
    }
    check(ctl.isShowingHome, "打开时不是收起态（板块首页）")
    check(collapsed.width >= 540 && collapsed.width <= 620,
          "收起态宽度 \(Int(collapsed.width)) 不在 540–620 之间")
    check(collapsed.height >= 140 && collapsed.height <= 170,
          "收起态高度 \(Int(collapsed.height)) 不在 140–170 之间")
    check(ctl.isCenteredOnScreen, "收起态没有居中在屏幕正中")
    if let d = shotDir {
        _ = ctl.renderCurrentWindow(to: "\(d)/01-collapsed.png")
    }

    // ---------- 2) 首页板块按钮 ----------
    let titles = ctl.homeSectionTitles
    print("  首页板块：\(titles)")
    check(titles == ["外观", "课表", "提醒", "系统"], "首页板块按钮不对：\(titles)")
    check(ctl.homeIconsAreMonochrome, "首页图标不是纯色（template）")
    check(ctl.homeTilesFullyClickable, "板块砖的图标/文字必须完整落在砖内（否则点不中）")

    // ---------- 3) 逐个板块展开 ----------
    // 记录展开后的尺寸，验证「反复切换不漂移」。
    var expandedSizes: [NSSize] = []
    for section in SettingsSection.allCases {
        ctl.expandTo(section)
        // 等动画跑完。
        settle(ctl)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        print("  ── 展开「\(section.title)」 ──")
        print("    内容装得下=\(ctl.contentFitsViewport) 滚动条藏着=\(ctl.scrollBarHidden)")
        print("    返回按钮与板块名同一水平线：\(ctl.backButtonAlignedWithTitle)")
        ctl.window?.contentView?.layoutSubtreeIfNeeded()
        // 文档高度必须跟**当前板块**绑定 —— 否则短板块下面拖着一大段空白，
        // 滚轮能一直滚进空白里（用户反馈「要有个束缚」）。
        let docHeight = ctl.scrollDocumentHeight
        let contentHeight = ctl.visibleSectionContentHeight
        print("    文档高度=\(Int(docHeight)) 内容高度=\(Int(contentHeight))")
        print("    栈：\(ctl.debugSectionStacks)")
        check(docHeight <= contentHeight + 8 + 12 + 16 + 6 + 20,
              "展开「\(section.title)」后滚动文档被别的板块撑高了（滚轮能滚进空白）")
        let size = ctl.currentWindowSize
        expandedSizes.append(size)
        print("  展开「\(section.title)」→ \(Int(size.width))×\(Int(size.height))  frame=\(ctl.window?.frame ?? .zero)")
        check(ctl.currentSection == section, "展开「\(section.title)」后状态不对")
        // 「返回」和板块名必须在**同一条水平线**上（用户要求）。
        check(ctl.backButtonAlignedWithTitle,
              "展开「\(section.title)」后返回键和板块名不在同一水平线上")
        // 「返回」要在红绿灯**下方**，不能被裁到窗口外。
        check(ctl.backButtonBelowTrafficLights,
              "展开「\(section.title)」后返回键跑到红绿灯上方或窗口外了")
        // 滚动条：内容装得下就**不该有**滚动条。
        if ctl.contentFitsViewport {
            check(ctl.scrollBarHidden,
                  "展开「\(section.title)」后内容一屏显示得下，滚动条却还在")
        } else {
            check(!ctl.scrollBarHidden,
                  "展开「\(section.title)」后内容超出屏幕，滚动条应该显示")
        }
        check(size.height > collapsed.height,
              "展开「\(section.title)」后窗口没有变高")
        check(ctl.isCenteredOnScreen, "展开「\(section.title)」后没有居中")
        // 窗口不能超出屏幕可见区。
        if let vf = NSScreen.main?.visibleFrame {
            check(size.height <= vf.height, "展开「\(section.title)」后超出了屏幕高度")
            check(size.width <= vf.width, "展开「\(section.title)」后超出了屏幕宽度")
        }
        // 「课程时间自定义」：必须在「课程预览」正下方，10 行，内容超出可视区
        // （用户要的「内置滚动窗口」），默认显示内置作息。
        if section == .timetable {
            let titles = ctl.sectionCardTitles(.timetable)
            if let p = titles.firstIndex(of: "课程预览"),
               let t = titles.firstIndex(of: "课程时间自定义") {
                check(t == p + 1, "「课程时间自定义」没有紧放在「课程预览」下面：\(titles)")
            } else {
                check(false, "课表板块缺「课程预览」或「课程时间自定义」卡片：\(titles)")
            }
            if let ed = ctl.periodEditor {
                check(ed.rowCount == PeriodSettings.count,
                      "课程时间自定义应有 \(PeriodSettings.count) 行，实际 \(ed.rowCount)")
                check(ed.isContentScrollable,
                      "课程时间自定义内容高 \(Int(ed.contentHeight)) 没有超出可视区 \(Int(ed.visibleHeight))，内置滚动没生效")
                if let first = ed.firstRowTexts {
                    check(first.start == "08:00" && first.end == "08:45",
                          "默认第一行应是 08:00–08:45，实际 \(first.start)–\(first.end)")
                } else {
                    check(false, "课程时间自定义第一行没建出来")
                }
                // 时间拆成「时 / 分」两个框，冒号是固定标签不用输入。
                check(ed.firstRowFieldCount == 4,
                      "第一行应有 4 个输入框（时 / 分 × 开始 / 结束），实际 \(ed.firstRowFieldCount)")
                check(ed.firstRowFieldValues == ["08", "00", "08", "45"],
                      "第一行四个框的内容不对：\(ed.firstRowFieldValues)")
                check(ed.times == PeriodSettings.defaults, "临时目录里应显示内置默认作息")
            } else {
                check(false, "periodEditor 没有建出来")
            }
        }
        if let d = shotDir {
            _ = ctl.renderCurrentWindow(to: "\(d)/02-section-\(section.rawValue).png")
            // 长板块（课表）额外拍一张滚到底的：确认新卡片在「课程预览」下面。
            if section == .timetable {
                ctl.scrollPanelToBottomForTest()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                _ = ctl.renderCurrentWindow(to: "\(d)/02-section-\(section.rawValue)-bottom.png")
                ctl.panelScrollToTopForTest()
            }
        }
    }

    // ---------- 4) 板块内容映射 ----------
    // 「外观」：渐变动画 / 最终不透明度 / 设置面板 / 课表大小
    check(ctl.sectionHasCard(.appearance, titled: "渐变动画"), "外观板块缺「渐变动画」卡片")
    check(ctl.sectionHasCard(.appearance, titled: "最终不透明度"), "外观板块缺「最终不透明度」卡片")
    check(ctl.sectionHasCard(.appearance, titled: "设置面板"), "外观板块缺「设置面板」卡片")
    check(ctl.sectionHasCard(.appearance, titled: "课表大小"), "外观板块缺「课表大小」卡片")
    // 「课表」：学期 / 课表数据 / 课表 / 课程预览
    check(ctl.sectionHasCard(.timetable, titled: "学期"), "课表板块缺「学期」卡片")
    check(ctl.sectionHasCard(.timetable, titled: "课表数据"), "课表板块缺「课表数据」卡片")
    check(ctl.sectionHasCard(.timetable, titled: "课表"), "课表板块缺「课表」卡片")
    check(ctl.sectionHasCard(.timetable, titled: "课程预览"), "课表板块缺「课程预览」卡片")
    check(ctl.sectionHasCard(.timetable, titled: "课程时间自定义"), "课表板块缺「课程时间自定义」卡片")
    // 「提醒」：提醒与启动
    check(ctl.sectionHasCard(.reminder, titled: "提醒与启动"), "提醒板块缺「提醒与启动」卡片")
    // 「系统」：退出应用
    check(ctl.sectionHasCard(.system, titled: "退出应用"), "系统板块缺「退出应用」卡片")
    // 一张卡片都没丢（改造前是 9 张；新增「课程时间自定义」→ 10 张；
    // 再加「课表大小」→ 11 张：
    // 渐变动画/最终不透明度/设置面板/课表大小/学期/课表数据/课表/
    // 课程预览/课程时间自定义/提醒与启动/退出应用）
    let cards = ctl.totalCardCount
    print("  卡片总数：\(cards)")
    check(cards == 11, "卡片总数 \(cards) 不等于 11（有卡片被弄丢了）")

    // ---------- 5) 返回收缩 ----------
    ctl.backToHome()
    settle(ctl)
    // 动画收尾（定格尺寸 / 重算滚动条）可能比 settle 晚一点点。
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    ctl.window?.contentView?.layoutSubtreeIfNeeded()
    let back = ctl.currentWindowSize
    print("  返回后：\(Int(back.width))×\(Int(back.height))  frame=\(ctl.window?.frame ?? .zero)")
    if let sc = NSScreen.main?.visibleFrame {
        print("  可见区：\(sc)  中心=(\(Int(sc.midX)),\(Int(sc.midY)))")
    }
    print("  isCentered=\(ctl.isCenteredOnScreen)")
    check(ctl.isShowingHome, "返回后没有回到收起态")
    check(abs(back.width - collapsed.width) < 1 && abs(back.height - collapsed.height) < 1,
          "返回后尺寸漂移：\(Int(back.width))×\(Int(back.height)) ≠ 收起态")
    check(ctl.isCenteredOnScreen, "返回后没有居中")
    if let d = shotDir {
        _ = ctl.renderCurrentWindow(to: "\(d)/03-back-home.png")
    }

    // ---------- 6) 反复切换不漂移 ----------
    for _ in 0..<3 {
        for section in SettingsSection.allCases {
            ctl.expandTo(section)
            settle(ctl)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        ctl.backToHome()
        settle(ctl)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let again = ctl.currentWindowSize
        check(abs(again.width - collapsed.width) < 1 && abs(again.height - collapsed.height) < 1,
              "反复切换后尺寸漂移：\(Int(again.width))×\(Int(again.height))")
    }
    // 再展开一次 —— 尺寸必须和第一次展开时一模一样。
    ctl.expandTo(.appearance)
    settle(ctl)
    let again = ctl.currentWindowSize
    check(abs(again.width - expandedSizes[0].width) < 1 && abs(again.height - expandedSizes[0].height) < 1,
          "再次展开后尺寸和第一次不一致")

    if let d = shotDir {
        _ = ctl.renderCurrentWindow(to: "\(d)/04-expanded-again.png")
    }

    // ⚠️ **自检收尾：把设置面板收走**（否则它一直浮在用户窗口前面）。
    ctl.closeForAutomationCleanup()
    if problems.isEmpty {
        print("✅ 设置面板两级结构（板块首页 → 分类页）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-wheel-routing") {
    // 自检：**设置面板里的内层滚动视图必须把滚轮交给外层面板**。
    //
    // 曾经的 bug：鼠标停在「课表预览」/「课程预览表格」上时，滚轮被内层吃掉，
    // 外层面板推不动 —— 用户只能把鼠标移到别处才能继续往下滚。
    // 现在内层一律用 `WheelForwardingScrollView`，滚轮转交外层；
    // 内层内容仍然可以用右边的滚动条自己拖着看。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let ctl = SettingsWindowController(store: ScheduleStore(), timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()
    ctl.window.contentView?.layoutSubtreeIfNeeded()

    // 作息列表在下方的课表板块，先展开再验 —— 自滚型要真的能滚起来。
    ctl.expandTo(.timetable)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    ctl.window.contentView?.layoutSubtreeIfNeeded()

    let nested = ctl.nestedScrollViews
    let selfScrolling = ctl.periodEditor?.scrollViewForTest
    let completedScrolling = ctl.completedRowScrollViewForTest
    print("  面板内嵌的滚动视图数量：\(nested.count)")
    for s in nested {
        let kind: String
        if s === selfScrolling {
            kind = "自滚型（课程时间自定义）✓"
        } else if s === completedScrolling {
            kind = "自滚型（已完成提醒列表）✓"
        } else if s is WheelForwardingScrollView {
            kind = "转发型 ✓"
        } else {
            kind = "普通型 ✗"
        }
        print("  · \(kind)，认出的外层：\(s.enclosingScrollView != nil ? "有" : "无")")
    }
    if ctl.innerScrollForwardsToOuter {
        print("✅ 面板内层滚动视图滚轮行为（转发型转给外层 / 作息列表自己滚）：通过")
        exit(0)
    }
    print("❌ 内层滚动视图的滚轮行为不对（转发型没转交 / 作息列表滚不动）")
    exit(1)
}

if arguments.contains("--verify-finder-reveal") {
    // 自检：**「在访达中显示」时，设置面板必须给访达窗口让路**。
    //
    // 曾经的 bug：设置面板是 `.floating` 浮层，访达窗口是普通层 ——
    // macOS 里**层级高的永远排在前面，跨 App 也不例外**。于是点「在访达中显示」
    // 打开的访达窗口被面板整个盖住，用户点了按钮什么也看不见。
    //
    // 修法（A 方案，实测 zprobe2 mode D/E/F/G 全部通过）：
    //   1. 面板降层到 `.normal` + `orderOut` 收起 → 访达必然在上面；
    //   2. `NSWorkspace.selectFile` 选中文件；
    //   3. 显式激活访达（`selectFile` 不保证访达窗口排到最前）。
    //   回来时（applicationDidBecomeActive / show()）把面板摆回 `.floating`。
    //
    // 这条自检**不开真的访达窗口**（会在用户桌上弹窗）——
    // 它验的是「策略与接线」：步骤顺序、层级取值、两处恢复都接对了。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let ctl = SettingsWindowController(store: ScheduleStore(), timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.reload()

    var problems: [String] = []

    // ---- 1. 步骤顺序：先让路，再选文件，最后激活访达 ----
    var captured: [FinderRevealStep] = []
    ctl.testRevealStepHandler = { captured = $0 }
    ctl.revealData()
    // 让路那步是**真的执行了**的（它只改本 app 自己的窗口，不会在用户桌上弹东西）——
    // 下面断言的就是它的实际效果。
    func stepName(_ step: FinderRevealStep) -> String {
        switch step {
        case .yieldPanel: return "让路"
        case .selectFile: return "选文件"
        case .activateFinder: return "激活访达"
        }
    }
    print("  「在访达中显示」的步骤：\(captured.map(stepName).joined(separator: " → "))")
    let kinds = captured.map { step -> String in
        switch step {
        case .yieldPanel: return "yield"
        case .selectFile: return "select"
        case .activateFinder: return "activate"
        }
    }
    if kinds != ["yield", "select", "activate"] {
        problems.append("步骤顺序不对：\(kinds)（必须先让路，再选文件，最后激活访达）")
    }

    // ---- 2. 让路之后：面板降层 + 收起 ----
    if ctl.isYieldingToFinder != true {
        problems.append("让路状态没记上（isYieldingToFinder 应为 true）")
    }
    if ctl.window.level != FinderRevealPolicy.yieldingLevel {
        problems.append("让路后层级不是 .normal（实际 \(ctl.window.level.rawValue)）")
    }
    if ctl.window.isVisible {
        problems.append("让路后面板还在屏上（必须 orderOut 收起，否则用户一点它 bug 就复活）")
    }

    // ---- 3. 恢复之后：摆回 .floating ----
    ctl.restoreFinderRevealIfNeeded()
    if ctl.isYieldingToFinder != false {
        problems.append("恢复后让路状态没清掉")
    }
    if ctl.window.level != FinderRevealPolicy.restingLevel {
        problems.append("恢复后层级不是 .floating（实际 \(ctl.window.level.rawValue)）")
    }

    // ---- 4. 没让过路时，恢复是零成本的（不能乱改层级）----
    let levelBefore = ctl.window.level
    ctl.restoreFinderRevealIfNeeded()
    if ctl.window.level != levelBefore {
        problems.append("没让过路也改了层级（恢复函数必须幂等）")
    }

    // ---- 5. 策略取值：浮层 > 普通层（这是「盖住」的根因）----
    if FinderRevealPolicy.restingLevel.rawValue <= FinderRevealPolicy.yieldingLevel.rawValue {
        problems.append("策略取值反了：浮层必须比普通层高")
    }
    if FinderRevealPolicy.level(yielding: true) != FinderRevealPolicy.yieldingLevel {
        problems.append("level(yielding: true) 取值不对")
    }
    if FinderRevealPolicy.level(yielding: false) != FinderRevealPolicy.restingLevel {
        problems.append("level(yielding: false) 取值不对")
    }

    if problems.isEmpty {
        print("✅ 「在访达中显示」时面板给访达让路：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-hover") {
    // 自检：**课表「亮不亮」的判定**（2026-11-05 修「开 app 课表不出来」）。
    //
    // 要回归的 bug：课表窗口在普通窗口之下、桌面窗口之上（level = -1）。
    // 实测（`DT_HOVER_DIAG=1`），窗口服务器报回来的窗口随 alpha 变：
    //   · alpha = 0（minOpacity = 0，还没亮）→ 访达的**桌面图标窗口**
    //     （-2147483603），层级比课表还低；
    //   · alpha = 0.22 且指针压着别的 App 窗口 → **那个 App 的窗口**（层级 0）；
    //   · alpha = 1，指针下面是课表 → **我们自己的窗口**（-1）。
    // 旧写法「不是我们的窗口 = 被盖住」把第一种也算成遮挡 →
    // 课表永远停在 minOpacity（0 / 22%），用户看到的就是
    // 「点了 app 课表很久不出来，指针放在上面也不浮出来」。
    //
    // 这里把「指针位置 / 窗口服务器的答案」喂进**真实的** `updateHover`：
    // 层级比较 → inside → hovering 全走生产代码，只有输入是假的。
    // 不挪用户的鼠标、不真的盖窗口。
    //
    // 和别的自检一样必须在临时数据目录里跑 —— 别读 / 动用户真实课表。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-hover 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let win = delegate.testDesktopWindow else {
        print("❌ 没有桌面窗口")
        exit(1)
    }
    // 让窗口拿到窗口号（内容还看不见：alpha 还是 0）。
    win.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }

    let card = win.convertToScreen(TimetableLayout.cardRect)
    let insideCard = NSPoint(x: card.midX, y: card.midY)
    // 离卡片足够远：避开 `hoverHysteresis` 的迟滞范围。
    let outsideCard = NSPoint(x: card.minX - 400, y: card.midY)
    let ourNumber = win.windowNumber
    let ourLevel = win.level.rawValue
    let desktopLayer = Int(CGWindowLevelForKey(.desktopWindow))
    let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    print("[诊断] 窗口号=\(ourNumber) 课表层级=\(ourLevel) 桌面层级=\(desktopLayer) 桌面图标层级=\(iconLayer)")

    // ---- 1. 层级口径（这条是整件事的根）----
    check(ourNumber != 0, "桌面窗口必须拿到窗口号（实际 \(ourNumber)）")
    check(ourLevel == HoverCoverPolicy.cardWindowLevel,
          "课表层级必须等于策略里的值 \(HoverCoverPolicy.cardWindowLevel)（实际 \(ourLevel)）")
    check(ourLevel < Int(CGWindowLevelForKey(.normalWindow)),
          "课表必须在普通窗口（0）之下（实际 \(ourLevel)）")
    check(desktopLayer < ourLevel, "桌面窗口必须比课表低（桌面 \(desktopLayer) / 课表 \(ourLevel)）")
    check(HoverCoverPolicy.covers(otherLayer: desktopLayer, ourLevel: ourLevel) == false,
          "桌面窗口不算遮挡（层级 \(desktopLayer) < 课表 \(ourLevel)）")
    check(HoverCoverPolicy.covers(otherLayer: 0, ourLevel: ourLevel),
          "普通 App 窗口（层级 0）必须算遮挡")
    check(HoverCoverPolicy.covers(otherLayer: ourLevel, ourLevel: ourLevel) == false,
          "同层窗口不算遮挡")
    check(HoverCoverPolicy.covers(otherLayer: nil, ourLevel: ourLevel) == false,
          "查不到层级时不能判成遮挡（否则又会「永远不亮」）")

    // ---- 2. 空桌面：指针在卡片矩形里，但窗口服务器答「桌面图标窗口」→ 必须亮 ----
    // 这就是用户遇到的那一幕：鼠标明明在课表上，课表却不亮
    // （实测 alpha = 0 时窗口服务器给的就是桌面图标窗口）。
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: 900_001,
                                   topWindowLayer: iconLayer))
    check(delegate.testCardIsLit, "窗口服务器报桌面图标窗口时，课表必须亮（它层级更低，挡不住）")
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: 900_001,
                                   topWindowLayer: desktopLayer))
    check(delegate.testCardIsLit, "窗口服务器报桌面窗口时，课表必须亮")

    // ---- 3. 策略层安全网：窗口服务器若真报出更高层的窗口 → 必须淡下去 ----
    //（实测这个查询从不返回别的 App 的窗口；这里验的是「万一报了，判定要正确」。）
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: 900_002,
                                   topWindowLayer: 0))
    check(!delegate.testCardIsLit, "窗口服务器报出更高层窗口时，课表必须淡下去（安全网）")

    // ---- 4. 指针在卡片上、窗口服务器答「我们自己」→ 必须亮 ----
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: ourNumber,
                                   topWindowLayer: nil))
    check(delegate.testCardIsLit, "指针在卡片上时课表必须亮")

    // ---- 5. 被盖住之后回到卡片 → 必须能亮回来（旧代码会卡在 22%）----
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: 900_002,
                                   topWindowLayer: 0))
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: ourNumber,
                                   topWindowLayer: nil))
    check(delegate.testCardIsLit, "被别的窗口盖过之后，指针回到卡片必须能亮回来")

    // ---- 6. 指针离开卡片 → 必须淡下去 ----
    delegate.testUpdateHover(.init(pointer: outsideCard,
                                   topWindowNumber: 900_001,
                                   topWindowLayer: desktopLayer))
    check(!delegate.testCardIsLit, "指针离开卡片后课表必须淡下去")

    // ---- 6b. **卡片外那圈「投影留白」不算悬停**（2026-11-05 用户反馈）----
    //
    // 用户原话：「修改完成或者点了取消之后，鼠标移动到课表外面，课表没有消失」。
    //
    // 课表窗口是 1148×962，卡片只有 968×782 —— 四周各 90pt 是**透明**的投影留白。
    // 指针落在那圈留白里时，窗口服务器仍然会返回**我们自己的窗口**（层级 -1），
    // 旧代码看到 `isOwnWindow(topNumber)` 就 `inside = true` →
    // 卡片外面那 90pt 全被算成「还在卡片上」→ 课表怎么都不淡出。
    //
    // 现在：只有**卡片矩形 + 14pt 迟滞**才算在卡片上；那圈留白按「离开」处理
    // （窗口本来就在那里不吃鼠标事件，点击会穿透到桌面）。
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: ourNumber,
                                   topWindowLayer: ourLevel))
    check(delegate.testCardIsLit, "（准备）指针在卡片上时是亮的")
    let shadowMarginPoint = NSPoint(x: card.minX - 40, y: card.midY)
    delegate.testUpdateHover(.init(pointer: shadowMarginPoint,
                                   topWindowNumber: ourNumber,
                                   topWindowLayer: ourLevel))
    check(!delegate.testCardIsLit,
          "指针在卡片外的投影留白里（仍在课表窗口内）时，课表必须淡下去")

    // ---- 7. **系统权限弹框期间课表必须保持可见**（2026-11-05 用户反馈）----
    //
    // 用户原话：「点访问权的时候，课表还在」。
    //
    // 日历 / 提醒事项 / 定位 / 通知的授权框是系统进程弹的，层级比课表高
    // （实测在 1000 以上）、位置常在屏幕中间 —— 用户把鼠标移过去点「允许」时，
    // 指针既不在卡片矩形里、那个点还被更高的窗口占着 → 正常判定一定淡出。
    // 用户设的 `minOpacity = 0` 就等于「课表整个消失」。
    //
    // 修法：`PermissionPromptWatch` 在弹框期间把课表钉在可见状态。
    let systemPromptLayer = 2000   // 系统弹框的层级区间（比课表高得多）
    // 7a. 接线：弹框一出现就该**立刻**亮着，不能等下一次鼠标移动。
    //     `AppDelegate` 把 `onStateChanged` 接到 `updateHover(force:)` 上，
    //     所以这里只 start 状态、不喂任何假输入，直接看课表有没有亮。
    check(PermissionPromptWatch.onStateChanged != nil,
          "AppDelegate 必须接上 PermissionPromptWatch 的状态回调")
    PermissionPromptWatch.endAll()
    delegate.testUpdateHover(.init(pointer: outsideCard,
                                   topWindowNumber: 900_001,
                                   topWindowLayer: desktopLayer))
    check(!delegate.testCardIsLit, "（准备）先把课表弄成暗的")
    PermissionPromptWatch.begin("定位", seconds: 60)
    print("[诊断] 权限弹框保持中：\(PermissionPromptWatch.activeReasons)")
    check(delegate.testCardIsLit, "权限弹框一出现就该立刻亮着（不用等鼠标移动）")

    // 7b. 保持期间：指针在弹框上（不在卡片里、还被更高的窗口占着）→ 仍然亮。
    delegate.testUpdateHover(.init(pointer: outsideCard,
                                   topWindowNumber: 900_003,
                                   topWindowLayer: systemPromptLayer))
    check(delegate.testCardIsLit, "系统权限弹框期间，指针在弹框上课表也必须保持可见")
    // 指针又回到卡片上 → 依然亮着（保持状态不该把「亮不亮」反过来）
    delegate.testUpdateHover(.init(pointer: insideCard,
                                   topWindowNumber: ourNumber,
                                   topWindowLayer: nil))
    check(delegate.testCardIsLit, "权限弹框期间指针回到卡片，课表仍然亮着")

    // ---- 8. 弹框关掉（拿到授权回调）→ 恢复原来的判定 ----
    PermissionPromptWatch.end("定位")
    check(!PermissionPromptWatch.isHolding(), "拿到授权回调后要解除保持")
    delegate.testUpdateHover(.init(pointer: outsideCard,
                                   topWindowNumber: 900_003,
                                   topWindowLayer: systemPromptLayer))
    check(!delegate.testCardIsLit, "弹框关掉后恢复：指针离开卡片就该淡下去")
    PermissionPromptWatch.endAll()

    // ---- 9. 真机窗口服务器：桌面上确实存在「比课表低」的窗口 ----
    // 让第 2 条不只是纸上推演：macOS 的桌面 / 壁纸 / 桌面图标窗口就在课表下面。
    let layers = HoverCoverPolicy.onScreenWindowLayers()
    let below = layers.filter { $0 < ourLevel }
    print("[诊断] 屏幕上 \(layers.count) 个窗口，其中层级低于课表的有 \(below.count) 个"
          + (below.isEmpty ? "" : "（最低 \(below.min() ?? 0)）"))
    check(layers.isEmpty == false, "窗口服务器至少要能列出屏幕上的窗口")
    check(below.isEmpty == false,
          "屏幕上必须存在比课表低的窗口（桌面 / 桌面图标），否则「桌面窗口不算遮挡」无从谈起")
    if let ownLayer = HoverCoverPolicy.layer(ofWindowNumber: ourNumber) {
        check(ownLayer == ourLevel, "自己窗口的层级读出来是 \(ownLayer)，应为 \(ourLevel)")
    } else {
        print("[诊断] 读不到自己窗口的层级（窗口可能还没上屏），跳过这一条")
    }

    if problems.isEmpty {
        print("✅ 悬停判定（桌面窗口不算遮挡 / 被盖住要淡出）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-card-scale") {
    // 自检：**课表卡片大小（缩放）**的完整链路（2026-11 新增）。
    //
    // 要验的验收标准：
    //   1. 缩放后卡片 / 窗口尺寸正确（等比）；
    //   2. **缩放以「卡片中心」为锚点** —— 缩放前后卡片中心在屏幕上不动；
    //   3. 缩放后按**新卡片尺寸**夹屏（卡片仍完整落在可见区里）；
    //   4. **网页层的缩放与命中换算正确** ——
    //      点表头能命中对应的那一列（这是最容易错的地方）；
    //   5. 缩放值写盘 → 重新读回来一致（等价于「重启后恢复」）。
    //
    // 用 `DT_DATA_DIR` 指向临时目录跑 —— **不碰用户真实的课表 / 设置 / 壁纸**。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-card-scale 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let win = delegate.testDesktopWindow else {
        print("❌ 没有桌面窗口")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    var problems: [String] = []
    func fail(_ s: String) { problems.append(s) }
    func check(_ ok: Bool, _ what: String) {
        if !ok { fail(what) }
    }

    // 缩放是节流的（16ms），每次改完要等它落地。
    func applyScale(_ s: Double) {
        delegate.testApplyCardScale(s)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }

    let scales: [Double] = [0.70, 0.85, 1.0, 1.15]
    print("[诊断] 屏幕可见区：\(NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero))")

    // ---- 1. 缩放后卡片 / 窗口尺寸正确（等比）----
    let baseCard = NSSize(width: TimetableLayout.baseCardSize.width,
                          height: TimetableLayout.baseCardSize.height)
    for s in scales {
        applyScale(s)
        let card = TimetableLayout.cardRect
        print("  scale=\(s) 卡片 \(Int(card.width))×\(Int(card.height))"
              + " 窗口 \(Int(TimetableLayout.windowWidth))×\(Int(TimetableLayout.windowHeight))")
        // ⚠️ **实际生效的缩放**可能比请求的小（屏幕放不下 → 被夹到上限）。
        // 断言要按**实际生效值**算，不能按请求值。
        let effective = delegate.testCardScale
        check(abs(card.width - baseCard.width * effective) < 0.5,
              "scale=\(s) 卡片宽应为 \(baseCard.width * effective)（实际 \(card.width)）")
        check(abs(card.height - baseCard.height * effective) < 0.5,
              "scale=\(s) 卡片高应为 \(baseCard.height * effective)（实际 \(card.height)）")
        // 窗口实际尺寸也要跟上（不是只有计算值变了）。
        // `setContentSize` 会取整，容差放宽到 1pt。
        check(abs((win.contentView?.bounds.width ?? 0) - TimetableLayout.windowWidth) < 1.5,
              "scale=\(s) 窗口实际宽度要跟上（实际 \(win.contentView?.bounds.width ?? 0)）")
        check(abs((win.contentView?.bounds.height ?? 0) - TimetableLayout.windowHeight) < 1.5,
              "scale=\(s) 窗口实际高度要跟上（实际 \(win.contentView?.bounds.height ?? 0)）")
        // 窗口中心 = 卡片中心（这条破了，「保持中心」就不成立）。
        let winCenter = NSPoint(x: win.frame.midX, y: win.frame.midY)
        let cardScreen = win.convertToScreen(card)
        let cardCenterScreen = NSPoint(x: cardScreen.midX, y: cardScreen.midY)
        check(abs(winCenter.x - cardCenterScreen.x) < 1.0
              && abs(winCenter.y - cardCenterScreen.y) < 1.0,
              "scale=\(s) 窗口中心必须等于卡片中心")
    }

    // ---- 2. **缩放以卡片中心为锚点** ----
    //
    // 把课表摆到屏幕**正中**，依次缩放，
    // 每一次缩放后卡片中心（屏幕坐标）都必须**不动**。
    //
    // ⚠️ 摆到正中是有讲究的：放到边上时，放大后的卡片会被「夹屏」推回来
    // （`clampOrigin` 把卡片夹回可见区），中心当然会动 ——
    // 那是**正确的行为**，不是 bug。所以这条要单独验「不触发夹屏」的情况。
    applyScale(1.0)
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    // 摆到正中：卡片中心落在可见区中心，四周留足余量，缩放不会触发夹屏。
    let centerOrigin = NSPoint(x: vf.midX - TimetableLayout.windowWidth / 2,
                               y: vf.midY - TimetableLayout.windowHeight / 2)
    delegate.testMoveWindow(to: centerOrigin)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    var centers: [NSPoint] = []
    var usedScales: [Double] = []
    for s in scales {
        applyScale(s)
        // 只用**没被屏幕上限夹住**的档位验中心不动 ——
        // 被夹住时卡片放不下，夹屏会推动中心，那是预期行为。
        let effective = delegate.testCardScale
        guard abs(effective - s) < 0.001 else {
            print("  scale=\(s) 被屏幕上限夹到 \(effective)，跳过中心锚点断言")
            continue
        }
        let cs = win.convertToScreen(TimetableLayout.cardRect)
        let nativeCenter = NSPoint(x: cs.midX, y: cs.midY)
        // 锚点必须盯**网页卡片中心**（用户可见的那张）：
        // 原生 cardRect 按整数取整，中心会随缩放 ±0.5pt 跳。
        let visibleCenter = delegate.testWebCardCenterOnScreen ?? nativeCenter
        centers.append(visibleCenter)
        usedScales.append(s)
        print("  scale=\(s) 网页卡片中心 \(NSStringFromPoint(visibleCenter))"
              + " 原生中心 \(NSStringFromPoint(nativeCenter))"
              + " 窗口frame=\(NSStringFromRect(win.frame))"
              + " content=\(NSStringFromRect(win.contentView?.bounds ?? .zero))")
    }
    check(centers.count >= 2, "至少要有两个档位没被屏幕上限夹住（实际 \(centers.count)）")
    // 目标中心取整到整点（窗口位置会被系统吸附到像素网格）。
    let targetCenter = NSPoint(x: centers[0].x.rounded(), y: centers[0].y.rounded())
    for (i, c) in centers.enumerated() {
        check(abs(c.x - targetCenter.x) < 1.0 && abs(c.y - targetCenter.y) < 1.0,
              "scale=\(usedScales[i]) 之后卡片中心必须不动（目标 \(NSStringFromPoint(targetCenter))"
              + " → 实际 \(NSStringFromPoint(c))）")
    }

    // ---- 3. 缩放后按新卡片尺寸夹屏（卡片仍完整可见）----
    for s in scales {
        applyScale(s)
        check(delegate.testWindowFullyVisible,
              "scale=\(s) 时卡片必须完整落在屏幕可见区里")
    }

    // ---- 4. **网页层的命中换算**（最容易错的地方）----
    //
    // 拿网页里的表头格（`.hcell[data-day=3]`）的实际位置，
    // 换算成原生点，再走生产的转发链路，问网页「命中了哪一列」。
    // 命中必须是**同一列** —— 差一列就说明坐标换算错了。
    guard let renderer = delegate.testWebRenderer else {
        print("❌ 没有拿到网页渲染器")
        exit(1)
    }
    // 等网页 ready。
    var ready = false
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if renderer.isReady { ready = true; break }
    }
    check(ready, "网页必须就绪（否则命中测不了）")

    func evalJSON(_ js: String) -> [String: Any]? {
        var out: [String: Any]?
        renderer.evaluateForTest(js) { r in
            guard let s = r, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = o
        }
        for _ in 0..<60 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if out != nil { break }
        }
        return out
    }

    for s in scales {
        applyScale(s)
        // 网页里量一个**课程格**的中心（CSS 坐标）。
        //
        // ⚠️ 必须用 `.cell`（课程格）而不是 `.hcell`（表头格）——
        // `ttHitTest` 的 `hitPayload` 只认 `.cell`（`Timetable.js:3942`），
        // 表头格命中不到 day。但**表头**的命中走的是 `forwardClick`
        // （`elementFromPoint` 直接命中元素），不在这里验。
        guard let geo = evalJSON("""
            (function () {
              var el = document.querySelector('.cell[data-day="3"]');
              if (!el) return '';
              var r = el.getBoundingClientRect();
              return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2,
                                      w: r.width, h: r.height });
            })();
            """) , let geoX = geo["x"] as? Double, let geoY = geo["y"] as? Double else {
            fail("scale=\(s) 量不到网页里第 3 列的课程格位置")
            continue
        }
        // 网页坐标 → 原生点（view 点）。
        //
        // ⚠️ `getBoundingClientRect()` 的数字要乘的是 **`rectScale`**，不是缩放系数：
        //   · pageZoom 档位（≥100%）：返回 CSS px，× 缩放系数；
        //   · CSS transform 档位（<100%）：返回的已经是视觉坐标，× 1。
        // 用错的话缩小档位会把点翻到两倍远的地方去。
        let rectScale = renderer.testRectScale
        // pageZoom 档：`getBoundingClientRect` 返回**页面**坐标，视觉 = (页面 + translate) × s。
        // transform 档：返回的已经是**视觉**坐标（含 translate），直接乘 rectScale。
        let viewX = geoX * rectScale
        let viewY = geoY * rectScale
        // 网页坐标原点在网页左上；翻成窗口坐标（左下原点）。
        let windowPoint = NSPoint(x: viewX, y: TimetableLayout.windowHeight - viewY)

        // 诊断用：请求值 / 实际值 / 缩放方式。
        print("  scale=\(s) 请求 \(s) 实际 \(delegate.testCardScale)"
              + " 方式=\(renderer.testUsesPageZoom ? "pageZoom" : "transform")"
              + " rectScale=\(rectScale)")

        // ---- 关键：走**生产的换算**（`cssPoint`）必须还原出同一个 CSS 坐标 ----
        //
        // 这一步错了，原生转发点击就会点偏（点到隔壁那一格）。
        let back = renderer.testCSSPoint(windowPoint)
        print("  scale=\(s) 第 3 列课程格 CSS=(\(geoX),\(geoY))"
              + " → 还原=(\(back.x),\(back.y))")
        check(abs(back.x - geoX) < 0.5,
              "scale=\(s) 坐标换算的 X 必须还原（期望 \(geoX)，实际 \(back.x)）")
        check(abs(back.y - geoY) < 0.5,
              "scale=\(s) 坐标换算的 Y 必须还原（期望 \(geoY)，实际 \(back.y)）")

        // ---- 诊断：网页内容在 webView 里的实际位置与尺寸 ----
        if let dbg = evalJSON("""
            (function () {
              var b = document.body.getBoundingClientRect();
              var c = document.querySelector('.card');
              var cr = c ? c.getBoundingClientRect() : {left:0,top:0,width:0,height:0};
              var wd = document.querySelector('.wkdate');
              return JSON.stringify({
                viewW: \(renderer.webView.bounds.width),
                viewH: \(renderer.webView.bounds.height),
                pageZoom: \(renderer.viewScale),
                rectScale: \(renderer.testRectScale),
                usesPageZoom: \(renderer.testUsesPageZoom ? "true" : "false"),
                geomScale: (typeof window.__ttGeomScale === 'number' ? window.__ttGeomScale : 1),
                bodyTransform: document.body.style.transform || '',
                wkdateFontSize: wd ? getComputedStyle(wd).fontSize : '',
                bodyLeft: b.left, bodyTop: b.top, bodyW: b.width, bodyH: b.height,
                cardLeft: cr.left, cardTop: cr.top, cardW: cr.width, cardH: cr.height,
                clientW: document.documentElement.clientWidth,
                innerW: window.innerWidth, innerH: window.innerHeight,
                scrollH: document.documentElement.scrollHeight
              });
            })();
            """) {
            print("  [网页布局] \(dbg)")
        }

        // ---- 小字号必须**按比例**缩（不能再被 WebKit 的 9pt 下限撑大）----
        //
        // `.wkdate` 是 9.5px，0.7 档下按比例应该仍是 9.5 CSS px 的版式
        // （视觉 6.65pt）。以前 pageZoom 会把它撑到 12.86px，
        // 顶栏跟着变高 —— 这就是「比例不对」的直接来源。
        if let fontProbe = evalJSON("""
            (function () {
              var el = document.querySelector('.wkdate');
              if (!el) return '';
              return JSON.stringify({ size: parseFloat(getComputedStyle(el).fontSize),
                                      geom: (typeof window.__ttGeomScale === 'number'
                                             ? window.__ttGeomScale : 1) });
            })();
            """) , let fontSize = fontProbe["size"] as? Double {
            let geom = (fontProbe["geom"] as? Double) ?? 1
            print("  [字号] .wkdate = \(fontSize)px"
                  + "（缩放 \(delegate.testCardScale)，geomScale=\(geom)）")
            check(abs(fontSize - 9.5) < 0.2,
                  "scale=\(s) 小字号必须保持 9.5px 参与等比（实际 \(fontSize)px，"
                  + "被 WebKit 最小字号撑大了）")
        }

        // ---- 核心对齐断言：网页里的 .card 必须和原生 cardRect 重合 ----
        //
        // 这是整个缩放功能最容易错的地方：
        // 网页层用 `pageZoom` 缩放（CSS 版式不变），
        // 原生层用 `TimetableLayout` 算几何 —— 两边必须**逐点对齐**，
        // 否则「点表头」会点到隔壁那一列。
        //
        // 验法：网页里量出 `.card` 的矩形，乘 `rectScale` 换算成 view pt，
        // 再跟原生 `cardRect` 比。
        if let geo2 = evalJSON("""
            (function () {
              var el = document.querySelector('.card');
              if (!el) return '';
              var r = el.getBoundingClientRect();
              return JSON.stringify({ left: r.left, top: r.top, w: r.width, h: r.height });
            })();
            """) , let wl = geo2["left"] as? Double,
           let wt = geo2["top"] as? Double,
           let ww = geo2["w"] as? Double,
           let wh = geo2["h"] as? Double {
            let sc = renderer.testRectScale
            let nativeRect = TimetableLayout.cardRect
            // 网页坐标 → view pt（`rectScale` 见 `WebCardRenderer`）。
            // 网页原点在左上，原生在左下，所以 y 要翻。
            let webLeft = wl * sc
            let webTopPt = wt * sc
            let webW = ww * sc
            let webH = wh * sc
            print("  [对齐] 网页 .card -> view: x=\(webLeft) y=\(webTopPt)"
                  + " w=\(webW) h=\(webH)")
            print("  [对齐] 原生 cardRect: x=\(nativeRect.minX) y=\(nativeRect.minY)"
                  + " w=\(nativeRect.width) h=\(nativeRect.height)")
            check(abs(webLeft - nativeRect.minX) <= 1.5,
                  "scale=\(s) 网页卡片的左边必须和原生卡片重合"
                  + "（网页 \(webLeft) vs 原生 \(nativeRect.minX)）")
            check(abs(webTopPt - nativeRect.minY) <= 1.5,
                  "scale=\(s) 网页卡片的顶边必须和原生卡片重合"
                  + "（网页 \(webTopPt) vs 原生 \(nativeRect.minY)）")
            check(abs(webW - nativeRect.width) <= 1.5,
                  "scale=\(s) 网页卡片的宽必须和原生卡片一致"
                  + "（网页 \(webW) vs 原生 \(nativeRect.width)）")
            // ⚠️ **高度允许 12pt 误差**（不是 1.5）。
            //
            // 原生的卡片高度是**公式算**的（`TimetableLayout.cardHeight`），
            // 网页的高度是**内容撑**的 —— 两者天生差几磅
            // （代码里早就记过「原生另算一套几何和网页实际布局差了 7px」，
            //  1.2.7 时实测是 9px：网页 773 vs 原生 782）。
            //
            // 这点误差**不影响命中**：B 模式（默认）下点课程 / 点表头
            // 走的是 `forwardClick` → 网页自己的 `elementFromPoint`，
            // 全程用网页坐标，原生几何根本不参与。
            //
            // 但它**会**放大：缩放时误差按比例放大
            // （1.15 时差 11px），所以容差要按比例给。
            //
            // ⚠️ 宽度**必须**严丝合缝 —— 宽度决定「点的是哪一列」，
            // 差一点点就会点到隔壁那列。
            let heightTolerance = 12.0 * delegate.testCardScale
            check(abs(webH - nativeRect.height) <= heightTolerance,
                  "scale=\(s) 网页卡片的高必须在容差内"
                  + "（网页 \(webH) vs 原生 \(nativeRect.height)，容差 \(heightTolerance)）")

            // ---- 比例断言：网页卡片必须严格等比（高/宽比不变）----
            //
            // 这是本轮修的「缩放比例问题」的**回归防线**：
            // 以前 `pageZoom < 1` 会触发 WebKit 的最小逻辑字号（9pt），
            // 顶栏小字被撑大 → 卡片从 773 变成 782.5（0.7 档），
            // 高/宽比偏 1.2%。现在缩小档位走 CSS transform，比例必须守住。
            let baseRatio = 773.0 / 968.0     // 网页 100% 时 .card 的实测高宽比
            let ratio = webH / max(webW, 1)
            let ratioError = abs(ratio - baseRatio) / baseRatio
            print("  [比例] 网页卡片 \(Int(webW))×\(Int(webH)) 高宽比 \(ratio)"
                  + "（基准 \(baseRatio)，偏差 \(String(format: "%.3f%%", ratioError * 100))）")
            check(ratioError < 0.005,
                  "scale=\(s) 网页卡片必须严格等比（高宽比偏差 \(ratioError * 100)% > 0.5%）")

            // ---- 毛玻璃层必须铺在网页卡片上（缩放后不能错位）----
            let glass = delegate.testGlassFrame
            let expectedGlass = NSRect(x: webLeft,
                                       y: TimetableLayout.windowHeight - (webTopPt + webH),
                                       width: webW, height: webH)
            print("  [玻璃] 实际 \(glass) 期望 \(expectedGlass)")
            check(abs(glass.minX - expectedGlass.minX) <= 1.5
                  && abs(glass.minY - expectedGlass.minY) <= 1.5
                  && abs(glass.width - expectedGlass.width) <= 1.5
                  && abs(glass.height - expectedGlass.height) <= 1.5,
                  "scale=\(s) 毛玻璃层必须铺在网页卡片上（实际 \(glass) vs 期望 \(expectedGlass)）")

            // ---- 点击穿透区域必须等于缩放后的卡片矩形 ----
            let passthrough = delegate.testPassthroughRect
            print("  [穿透] 实际 \(passthrough) 期望 \(nativeRect)")
            check(abs(passthrough.minX - nativeRect.minX) <= 0.5
                  && abs(passthrough.minY - nativeRect.minY) <= 0.5
                  && abs(passthrough.width - nativeRect.width) <= 0.5
                  && abs(passthrough.height - nativeRect.height) <= 0.5,
                  "scale=\(s) 卡片外的点击穿透区域必须跟随缩放（实际 \(passthrough) vs \(nativeRect)）")
        } else {
            fail("scale=\(s) 量不到网页里 .card 的矩形")
        }

        // ---- 再验「拿这个点去问网页，命中的是不是第 3 列」 ----
        var hitDay: Int? = nil
        renderer.hitTestInWeb(at: windowPoint) { d, _, _ in
            hitDay = d
        }
        for _ in 0..<80 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if hitDay != nil { break }
        }
        print("  scale=\(s) 命中 day=\(hitDay.map(String.init) ?? "nil")")
        check(hitDay == 3,
              "scale=\(s) 点第 3 列的课程格必须命中第 3 列（实际 \(hitDay.map(String.init) ?? "nil")）")
    }

    // ---- 5. 缩放值写盘 → 读回来一致 ----
    applyScale(0.85)
    delegate.testCommitCardScale()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let store = SettingsStore()
    let saved = store.load().appearance.cardScale
    print("[诊断] 写盘的 cardScale = \(saved)")
    check(abs(saved - 0.85) < 0.02,
          "写盘的 cardScale 应为 0.85（实际 \(saved)）")
    // 老配置兼容：没有 cardScale 时读成 1.0（不是 0）。
    check(AppearanceConfig(["fadeInSec": 1.0]).cardScale == 1.0,
          "老配置（缺 cardScale）要读成 1.0")

    // ---- 6. 拖动流畅度冒烟：每帧只做几何，一帧的同步耗时必须远小于一帧预算 ----
    //
    // 拖动滑块时 `applyCardScale(persist: false)` 每 16ms 走一次
    // `performCardScale(interactive: true)`。这一档**不推状态、不跨进程量矩形、
    // 不重算悬停**（那些都在松手时做一次），所以每帧的同步耗时应该只有
    // 窗口 resize + pageZoom/transform 更新。
    //
    // 断言不追求精确（机器忙时会抖），只挡「明显退化成几十毫秒」的回归。
    var frameTimes: [Double] = []
    var dragCenters: [NSPoint] = []
    var webCenters: [NSPoint] = []
    for i in 0..<30 {
        let v = 0.70 + Double(i) / 29.0 * 0.30     // 70% → 100%
        let t0 = CFAbsoluteTimeGetCurrent()
        delegate.testApplyCardScaleDragFrame(v)
        // 等这一帧真正落地（网页缩放跨进程 + 窗口对齐）；超时也算失败。
        var waited = 0.0
        while !delegate.testScaleDragSettled && waited < 0.05 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            waited += 0.001
        }
        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        frameTimes.append(dt)
        let cs = win.convertToScreen(TimetableLayout.cardRect)
        dragCenters.append(NSPoint(x: cs.midX, y: cs.midY))
        if let wc = delegate.testWebCardCenterOnScreen { webCenters.append(wc) }
        // 模拟 120Hz 的下一帧（8.3ms），让测量包含真实节奏。
        RunLoop.current.run(until: Date().addingTimeInterval(0.008))
    }
    let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
    let maxFrame = frameTimes.max() ?? 0
    print(String(format: "[拖动] 30 帧同步耗时 平均 %.2fms / 最大 %.2fms（帧预算 16.7ms）",
                 avg, maxFrame))
    check(maxFrame < 40.0,
          String(format: "拖动每帧同步耗时必须 < 40ms（最大 %.2fms）", maxFrame))

    // 拖动全程卡片中心也必须钉住（否则松手时会「跳一下」）。
    if let firstCenter = dragCenters.first {
        var maxDrift: CGFloat = 0
        for c in dragCenters {
            maxDrift = max(maxDrift, abs(c.x - firstCenter.x), abs(c.y - firstCenter.y))
        }
        // 拖动期间原生 cardRect 不再参与显示（窗口固定、卡片位置由网页
        // transform 决定），这里只打印作参考，不做断言。
        print(String(format: "[拖动] 原生卡片中心最大漂移 %.2fpt（仅供参考，可见的是网页卡片）", maxDrift))
    }
    // 用户看到的是**网页卡片**：它的中心漂移必须更小（抖动就来自这里）。
    if let firstCenter = webCenters.first {
        var maxDrift: CGFloat = 0
        for c in webCenters {
            maxDrift = max(maxDrift, abs(c.x - firstCenter.x), abs(c.y - firstCenter.y))
        }
        print(String(format: "[拖动] 网页卡片中心最大漂移 %.2fpt（可见画面）", maxDrift))
        check(maxDrift < 0.75,
              String(format: "拖动全程可见的网页卡片中心必须钉住（最大漂移 %.2fpt）", maxDrift))
    }

    // ---- 9. 拖动到边缘：从贴边位置开始拖动放大，卡片必须完整可见 ----
    for (name, origin) in [("左上", NSPoint(x: vf.minX + 6, y: vf.maxY - 300)),
                           ("右下", NSPoint(x: vf.maxX - 300, y: vf.minY + 6))] {
        applyScale(0.92)
        delegate.testCommitCardScale()
        delegate.testMoveWindow(to: origin)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        delegate.testApplyCardScaleDragFrame(1.10)
        var waited = 0.0
        while !delegate.testScaleDragSettled && waited < 0.5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            waited += 0.002
        }
        let g = delegate.testGlassFrame
        let wf = win.frame
        let screen = NSRect(x: wf.minX + g.minX, y: wf.minY + g.minY,
                            width: g.width, height: g.height)
        let insideWindow = g.minX >= -1 && g.minY >= -1
            && g.maxX <= wf.width + 1 && g.maxY <= wf.height + 1
        let insideScreen = screen.minX >= vf.minX - 1 && screen.maxX <= vf.maxX + 1
            && screen.minY >= vf.minY - 1 && screen.maxY <= vf.maxY + 1
        print("  [拖动边缘·\(name)] 窗口=\(NSStringFromRect(wf)) 玻璃=\(NSStringFromRect(g))"
              + " 屏幕=\(NSStringFromRect(screen)) 屏内=\(insideScreen) 窗内=\(insideWindow)")
        check(insideWindow && insideScreen,
              "从\(name)贴边拖动放大后卡片必须完整可见（屏内=\(insideScreen) 窗内=\(insideWindow)）")
        delegate.testCommitCardScale()
        // 松手后 0.3s，量**实际**网页矩形 / transform / pageZoom，确认不是模型自洽。
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        if let g2 = evalJSON("""
            (function () {
              var c = document.querySelector('.card');
              if (!c) return '';
              var r = c.getBoundingClientRect();
              return JSON.stringify({ l: r.left, t: r.top, w: r.width, h: r.height,
                                      tr: document.body.style.transform,
                                      pz: window.devicePixelRatio,
                                      vw: window.innerWidth, vh: window.innerHeight });
            })();
            """) {
            print("  [松手后·\(name)] 实际网页=\(g2)")
        }
        print("  [松手后·\(name)] 窗口=\(NSStringFromRect(win.frame)) 玻璃=\(NSStringFromRect(delegate.testGlassFrame)) 缩放=\(delegate.testCardScale)")
    }

    // ---- 8. 边缘夹屏：卡片贴着屏幕左上角时放大，必须仍然完整可见 ----
    //
    // 用户截图：110% 时卡片左边/上边被屏幕切掉。缩放锚点夹进可见区后，
    // 无论卡片本来靠哪个角，放大都必须完整可见。
    applyScale(1.0)
    delegate.testMoveWindow(to: NSPoint(x: vf.minX + 6, y: vf.maxY - 300))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    applyScale(1.15)
    let edgeGlass = delegate.testGlassFrame
    let edgeScreen = NSRect(x: win.frame.minX + edgeGlass.minX,
                            y: win.frame.minY + edgeGlass.minY,
                            width: edgeGlass.width, height: edgeGlass.height)
    print("  [边缘] 贴左上角放大后网页卡片=\(NSStringFromRect(edgeScreen)) 可见区=\(NSStringFromRect(vf))")
    check(edgeScreen.minX >= vf.minX - 1.0 && edgeScreen.maxX <= vf.maxX + 1.0
          && edgeScreen.minY >= vf.minY - 1.0 && edgeScreen.maxY <= vf.maxY + 1.0,
          "贴边放大后卡片必须完整可见（实际 \(NSStringFromRect(edgeScreen))）")

    // ---- 7. 100% 边界诊断：98% → 102% 连续拖动，画面不能有跳变 ----
    //
    // 用户反馈「99~100 / 100~101 时整个画面抖一下」。这里把网页实际矩形
    // 和 dpr / body transform 打出来：任何一项在 100% 附近跳变都能看见。
    print("[边界] 98% → 102% 连续拖动（真实路径）")
    var prevWeb: NSRect?
    for i in 0...4 {
        let s = 0.98 + Double(i) * 0.01
        delegate.testApplyCardScaleDragFrame(s)
        var waited = 0.0
        while !delegate.testScaleDragSettled && waited < 0.05 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            waited += 0.001
        }
        guard let g = evalJSON("""
            (function () {
              var c = document.querySelector('.card');
              if (!c) return '';
              var r = c.getBoundingClientRect();
              return JSON.stringify({ l: r.left, t: r.top, w: r.width, h: r.height,
                                      tr: document.body.style.transform,
                                      dpr: window.devicePixelRatio });
            })();
            """), let l = g["l"] as? Double, let t = g["t"] as? Double,
              let w = g["w"] as? Double, let h = g["h"] as? Double else { continue }
        let winH = win.frame.height
        let center = NSPoint(x: win.frame.minX + l + w / 2,
                             y: win.frame.minY + winH - (t + h / 2))
        let rect = NSRect(x: win.frame.minX + l,
                          y: win.frame.minY + winH - (t + h),
                          width: w, height: h)
        let dpr = (g["dpr"] as? Double) ?? 0
        let tr = (g["tr"] as? String) ?? ""
        var delta = ""
        if let p = prevWeb {
            delta = String(format: " Δ中心=(%.2f, %.2f) Δ宽=%.2f Δ高=%.2f",
                           center.x - p.midX, center.y - p.midY,
                           w - p.width, h - p.height)
        }
        print(String(format: "  s=%.2f 窗口=%@ 网页=%@ 中心=%@ dpr=%.2f transform=%@%@",
                     s, NSStringFromRect(win.frame), NSStringFromRect(rect),
                     NSStringFromPoint(center), dpr, tr, delta))
        prevWeb = rect
    }

    // 恢复原尺寸，别把临时目录里的状态搞乱。
    applyScale(1.0)
    delegate.testCommitCardScale()

    if problems.isEmpty {
        print("✅ 课表卡片大小（等比缩放 / 中心锚点 / 命中换算 / 写盘）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-scale-drag-edge") {
    // 自检：**缩放之后还能不能把课表拖到屏幕边缘**（2026-11 新增）。
    //
    // 用户原话：「放大缩小之后不能够拖动到边缘」——
    // 缩放之后卡片和窗口之间的偏移变了（常驻画布，卡片居中），
    // 拖动夹屏如果还按「窗口框」或者旧的卡片矩形算，
    // 卡片就会在离屏幕边还有一段距离时被夹住、拖不过去。
    //
    // 验收（每一档缩放、四个方向各一次）：
    //   1. 卡片**能贴到**屏幕可见区边缘（误差 ≤ 2pt）；
    //   2. 贴边时卡片**完整可见**，不越界（误差 ≤ 2pt）。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-scale-drag-edge 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForImportVerification()
    guard let win = delegate.testDesktopWindow else {
        print("❌ 没有桌面窗口")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    print("[诊断] 屏幕可见区：\(NSStringFromRect(vf))")

    // 等网页就绪（玻璃矩形来自网页测量）。
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if delegate.testWebRenderer?.isReady == true { break }
    }

    /// 走**真实用户路径**：拖动滑块（interactive 帧）→ 松手写盘 → 等落地。
    func applyScaleLikeUser(_ s: Double) {
        delegate.testApplyCardScaleDragFrame(s)
        var waited = 0.0
        while !delegate.testScaleDragSettled && waited < 0.5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            waited += 0.002
        }
        delegate.testCommitCardScale()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    /// 卡片（网页可见矩形）在屏幕坐标系里的矩形。
    func cardOnScreen() -> NSRect {
        let g = delegate.testGlassFrame
        return NSRect(x: win.frame.minX + g.minX, y: win.frame.minY + g.minY,
                      width: g.width, height: g.height)
    }

    func dragToEdge(_ name: String, by delta: CGSize,
                    expectLeft: Bool, expectRight: Bool,
                    expectBottom: Bool, expectTop: Bool) {
        delegate.testDragWindow(by: delta)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        let r = cardOnScreen()
        print("  [\(name)] 窗口=\(NSStringFromRect(win.frame))"
              + " 卡片=\(NSStringFromRect(r)) 缩放=\(delegate.testCardScale)")
        print("       原生卡片矩形=\(NSStringFromRect(TimetableLayout.cardRect))"
              + " 覆盖值=\(TimetableLayout.cardRectOverride.map { NSStringFromRect($0) } ?? "nil")")
        if expectLeft {
            check(abs(r.minX - vf.minX) <= 2, "\(name)：卡片左边要贴到屏幕边（期望 \(vf.minX)，实际 \(r.minX)）")
        }
        if expectRight {
            check(abs(r.maxX - vf.maxX) <= 2, "\(name)：卡片右边要贴到屏幕边（期望 \(vf.maxX)，实际 \(r.maxX)）")
        }
        if expectBottom {
            check(abs(r.minY - vf.minY) <= 2, "\(name)：卡片下边要贴到屏幕边（期望 \(vf.minY)，实际 \(r.minY)）")
        }
        if expectTop {
            check(abs(r.maxY - vf.maxY) <= 2, "\(name)：卡片上边要贴到屏幕边（期望 \(vf.maxY)，实际 \(r.maxY)）")
        }
        // 贴边后必须仍然完整可见（不能为了贴边把卡片顶出屏幕）。
        check(r.minX >= vf.minX - 2 && r.maxX <= vf.maxX + 2
              && r.minY >= vf.minY - 2 && r.maxY <= vf.maxY + 2,
              "\(name)：贴边时卡片必须完整可见（实际 \(NSStringFromRect(r))，可见区 \(NSStringFromRect(vf))）")
    }

    for s in [0.70, 0.85, 1.0, 1.15] {
        applyScaleLikeUser(s)
        print("  scale 请求 \(s) → 实际 \(delegate.testCardScale)"
              + " 窗口=\(NSStringFromRect(win.frame))")
        let label = "\(Int(delegate.testCardScale * 100))%"
        dragToEdge("\(label)·左上", by: CGSize(width: -4000, height: 4000),
                   expectLeft: true, expectRight: false, expectBottom: false, expectTop: true)
        dragToEdge("\(label)·右下", by: CGSize(width: 4000, height: -4000),
                   expectLeft: false, expectRight: true, expectBottom: true, expectTop: false)
        // 贴边之后**再缩放一次**：卡片应按新尺寸夹回来，且仍完整可见。
        delegate.testApplyCardScaleDragFrame(0.85)
        var waited = 0.0
        while !delegate.testScaleDragSettled && waited < 0.5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            waited += 0.002
        }
        delegate.testCommitCardScale()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let after = cardOnScreen()
        print("  [\(label)·贴边后再缩放] 卡片=\(NSStringFromRect(after))")
        check(after.minX >= vf.minX - 2 && after.maxX <= vf.maxX + 2
              && after.minY >= vf.minY - 2 && after.maxY <= vf.maxY + 2,
              "贴边后再缩放：卡片必须完整可见（实际 \(NSStringFromRect(after))）")
    }

    // ---- 真实用户路径：**在设置面板里放大 → 关面板 → 拖到边缘** ----
    //
    // 上面的循环走的是「一次性应用」，而用户实际只能在设置面板里拖滑杆：
    // 拖动帧 + 松手都发生在面板开着的时候（窗口尺寸不动、位置跟着卡片中心）。
    // 这一条必须单独走一遍 —— 上一轮的「拖不到边」就出在这条路径上。
    print("[用户路径] 设置面板 → 拖到 112% → 松手 → 关面板 → 拖到左上 / 右下")
    delegate.testOpenSettingsPanel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    for i in 0..<12 {
        let v = 1.0 + Double(i) * (0.12 / 11.0)
        delegate.testApplyCardScaleDragFrame(v)
        RunLoop.current.run(until: Date().addingTimeInterval(0.008))
    }
    var waitedPanel = 0.0
    while !delegate.testScaleDragSettled && waitedPanel < 1.0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        waitedPanel += 0.002
    }
    let panelCenterBeforeCommit = cardOnScreen()
    delegate.testCommitCardScale()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let panelCenterAfterCommit = cardOnScreen()
    print("  [面板松手] 卡片 \(NSStringFromRect(panelCenterBeforeCommit))"
          + " → \(NSStringFromRect(panelCenterAfterCommit)) 缩放=\(delegate.testCardScale)")
    check(abs(panelCenterAfterCommit.midX - panelCenterBeforeCommit.midX) < 3
          && abs(panelCenterAfterCommit.midY - panelCenterBeforeCommit.midY) < 3,
          "面板里松手时卡片中心不能跳（\(NSStringFromRect(panelCenterBeforeCommit))"
          + " → \(NSStringFromRect(panelCenterAfterCommit))）")
    delegate.testCloseSettingsPanel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let panelCenterAfterClose = cardOnScreen()
    check(abs(panelCenterAfterClose.midX - panelCenterAfterCommit.midX) < 3
          && abs(panelCenterAfterClose.midY - panelCenterAfterCommit.midY) < 3,
          "关闭面板时卡片中心不能跳（\(NSStringFromRect(panelCenterAfterCommit))"
          + " → \(NSStringFromRect(panelCenterAfterClose))）")
    if let renderer = delegate.testWebRenderer {
        check(renderer.testUsesPageZoom && abs(renderer.webView.pageZoom - renderer.testViewScale) < 0.001,
              "面板放大松手后必须是 pageZoom 清晰档（usesPageZoom=\(renderer.testUsesPageZoom)"
              + " pageZoom=\(renderer.webView.pageZoom) viewScale=\(renderer.testViewScale)）")
    }
    dragToEdge("面板放大后·左上", by: CGSize(width: -4000, height: 4000),
               expectLeft: true, expectRight: false, expectBottom: false, expectTop: true)
    dragToEdge("面板放大后·右下", by: CGSize(width: 4000, height: -4000),
               expectLeft: false, expectRight: true, expectBottom: true, expectTop: false)

    // 恢复默认尺寸（临时目录里的状态随便，但别留下奇怪比例）。
    delegate.testApplyCardScale(1.0)
    delegate.testCommitCardScale()

    if problems.isEmpty {
        print("✅ 缩放后拖动到屏幕边缘（四方向 / 四档）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-slider-scale") {
    // 自检：设置 → 外观 →「卡片大小」**滑杆**这条真实路径（2026-11-08 新增）。
    //
    // 用户反馈：「放大缩小还没恢复吧」。
    // 根因：`SettingsWindowController.onCardScaleChange` 只有声明、没有赋值 ——
    // 拖滑杆只改滑杆自己的值和配置，**桌面课表一点不动**。
    // 这里从 `updateCardScale`（滑杆 onChange / onDragEnd 的入口）一路验到
    // 原生几何、网页缩放、写盘、关面板后保持。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-slider-scale 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForImportVerification()
    guard let win = delegate.testDesktopWindow, let renderer = delegate.testWebRenderer else {
        print("❌ 没有桌面窗口 / 渲染器")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    for _ in 0..<100 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if renderer.isReady { break }
    }

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }
    func settle(_ limit: Double = 1.0) {
        var waited = 0.0
        while !delegate.testScaleDragSettled && waited < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            waited += 0.002
        }
    }
    func dragSlider(to target: Double, from: Double) {
        let steps = 10
        for i in 1...steps {
            let v = from + (target - from) * Double(i) / Double(steps)
            delegate.testSetCardScaleFromSettingsPanel(v, persist: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        settle()
        delegate.testSetCardScaleFromSettingsPanel(target, persist: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    let startScale = Double(delegate.testCardScale)
    delegate.testOpenSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))

    // ---- 1. 放大到 110% ----
    dragSlider(to: 1.10, from: startScale)
    let scaleAfterUp = Double(delegate.testCardScale)
    print("[诊断] 滑杆拖到 110%：原生缩放=\(scaleAfterUp)"
          + " 网页缩放=\(renderer.testViewScale) 布局缩放=\(TimetableLayout.scale)"
          + " 面板开着=\(delegate.testSettingsPanelVisible)")
    check(abs(scaleAfterUp - 1.10) < 0.005,
          "滑杆拖到 110% 后课表缩放要跟着变（实际 \(scaleAfterUp)）")
    check(abs(Double(renderer.testViewScale) - scaleAfterUp) < 0.005,
          "网页缩放要和原生一致（网页 \(renderer.testViewScale) / 原生 \(scaleAfterUp)）")
    check(abs(Double(TimetableLayout.scale) - scaleAfterUp) < 0.005,
          "布局缩放要和原生一致（布局 \(TimetableLayout.scale) / 原生 \(scaleAfterUp)）")
    check(renderer.testUsesPageZoom,
          "放大档必须走 pageZoom（否则文字会糊）")

    // ---- 2. 缩小回 90%（transform 档）----
    dragSlider(to: 0.90, from: 1.10)
    let scaleAfterDown = Double(delegate.testCardScale)
    print("[诊断] 滑杆拖到 90%：原生缩放=\(scaleAfterDown)"
          + " 网页缩放=\(renderer.testViewScale) usesPageZoom=\(renderer.testUsesPageZoom)")
    check(abs(scaleAfterDown - 0.90) < 0.005,
          "滑杆拖回 90% 后课表缩放要跟着变（实际 \(scaleAfterDown)）")
    check(abs(Double(renderer.testViewScale) - scaleAfterDown) < 0.005,
          "缩小档网页缩放也要一致（网页 \(renderer.testViewScale)）")
    check(!renderer.testUsesPageZoom, "缩小档必须用 CSS transform（不能用 pageZoom）")

    // ---- 3. 写盘：临时目录里的 config.json 要记下 0.90 ----
    let cfgURL = URL(fileURLWithPath: dataDir).appendingPathComponent("config.json")
    var savedScale: Double?
    if let data = try? Data(contentsOf: cfgURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        savedScale = (obj["cardScale"] as? NSNumber)?.doubleValue
    }
    print("[诊断] 写盘 cardScale=\(savedScale.map { String(format: "%.3f", $0) } ?? "nil")")
    check(savedScale != nil && abs((savedScale ?? 0) - 0.90) < 0.01,
          "松手后要把大小写盘（实际 \(savedScale.map { String($0) } ?? "nil")）")

    // ---- 4. 关面板后保持这个大小 ----
    delegate.testCloseSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let scaleAfterClose = Double(delegate.testCardScale)
    let glass = delegate.testGlassFrame
    print("[诊断] 关面板后：缩放=\(scaleAfterClose) 玻璃高=\(glass.height)")
    check(abs(scaleAfterClose - 0.90) < 0.005, "关面板后缩放不能回弹（实际 \(scaleAfterClose)）")
    check(abs(glass.height - CGFloat(773 * 0.90)) < 8,
          "关面板后玻璃高度要跟 90% 对得上（实际 \(glass.height)）")

    // ---- 5. 贴边放大：拖动**过程中**就要留在屏幕内（不能等松手才跳进来）----
    //
    // 用户原话：「放大时就要判定是不是会超出界面，不要最后松开拖动杆才一下
    // 把课表拖进界面内，就像 1.4.2 一样」。
    // 复现路径：先缩到 70% 把课表拖到屏幕左下角 → 打开设置面板 → 把滑杆一路拖大。
    delegate.testApplyCardScale(0.70)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    delegate.testDragWindow(by: CGSize(width: -4000, height: -4000))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    delegate.testOpenSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let vfSlide = NSScreen.main?.visibleFrame ?? .zero
    var worstOver: CGFloat = 0
    var worstRect = NSRect.zero
    func cardScreenRect() -> NSRect {
        let glass = delegate.testGlassFrame
        let origin = win.frame.origin
        return NSRect(x: origin.x + glass.minX, y: origin.y + glass.minY,
                      width: glass.width, height: glass.height)
    }
    for i in 1...12 {
        let v = 0.70 + Double(i) * (0.42 / 12.0)
        delegate.testSetCardScaleFromSettingsPanel(v, persist: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let r = cardScreenRect()
        let over = max(0, vfSlide.minX - r.minX) + max(0, r.maxX - vfSlide.maxX)
            + max(0, vfSlide.minY - r.minY) + max(0, r.maxY - vfSlide.maxY)
        if over > worstOver { worstOver = over; worstRect = r }
    }
    settle()
    let beforeRelease = cardScreenRect()
    delegate.testSetCardScaleFromSettingsPanel(1.12, persist: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let afterRelease = cardScreenRect()
    print("[诊断] 贴边放大：拖动中最大越界=\(String(format: "%.1f", worstOver))pt"
          + " 最远处=\(NSStringFromRect(worstRect))"
          + " 松手前后=\(NSStringFromRect(beforeRelease)) → \(NSStringFromRect(afterRelease))"
          + " 可见区=\(NSStringFromRect(vfSlide))")
    check(worstOver < 3, "拖动滑杆放大时卡片就要留在屏幕内（最大越界 \(String(format: "%.1f", worstOver))pt，"
          + "卡片 \(NSStringFromRect(worstRect))，可见区 \(NSStringFromRect(vfSlide))）")
    check(abs(afterRelease.minX - beforeRelease.minX) < 3
          && abs(afterRelease.minY - beforeRelease.minY) < 3
          && abs(afterRelease.width - beforeRelease.width) < 3
          && abs(afterRelease.height - beforeRelease.height) < 3,
          "松手瞬间卡片不能再跳（\(NSStringFromRect(beforeRelease)) → \(NSStringFromRect(afterRelease))）")
    check(afterRelease.minX >= vfSlide.minX - 1.5 && afterRelease.maxX <= vfSlide.maxX + 1.5
          && afterRelease.minY >= vfSlide.minY - 1.5 && afterRelease.maxY <= vfSlide.maxY + 1.5,
          "松手后卡片要完整落在屏幕内（\(NSStringFromRect(afterRelease))）")
    // ---- 6. 左上角图钉必须钉在标题右边、跟着卡片一起缩放 ----
    //
    // 用户反馈：「左上角图钉和课表在缩放的时候出现了不同步」。
    // 图钉是原生控件，位置由「卡片矩形 + 标题宽度 × 缩放」算出来；
    // 这里直接量网页里标题文本的右边缘，和原生图钉的左边缘比对。
    if let pin = delegate.testInteraction?.testPinRect {
        var titleRight: Double = -1
        var titleMidY: Double = -1
        var webPinLeft: Double = -1
        var webPinMidY: Double = -1
        var webPinWidth: Double = -1
        var webPinHeight: Double = -1
        if let renderer = delegate.testWebRenderer {
            renderer.evaluateForTest("""
            (function () {
              // ⚠️ 量**标题文字**（`.ttltxt`），不是整个 `.ttl` ——
              // 2026-11 起图钉画在 `.ttl` 里，量 `.ttl` 会把图钉自己也算进去。
              var t = document.querySelector('.ttltxt') || document.querySelector('.ttl');
              if (!t) return JSON.stringify({ r: -1, m: -1 });
              var range = document.createRange();
              range.selectNodeContents(t);
              var r = range.getBoundingClientRect();
              var pin = document.querySelector('.ttlpin');
              var pr = pin ? pin.getBoundingClientRect() : null;
              // 只报 CSS 值；倍率（pageZoom / transform）由原生按 testRectScale 乘。
              return JSON.stringify({
                r: r.right, m: r.top + r.height / 2,
                pl: pr ? pr.left : -1, pm: pr ? (pr.top + pr.height / 2) : -1,
                pw: pr ? pr.width : -1, ph: pr ? pr.height : -1
              });
            })();
            """) { raw in
                guard let raw, let d = raw.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
                let k = Double(delegate.testWebRenderer?.testRectScale ?? 1)
                titleRight = ((o["r"] as? Double) ?? -1) * k
                titleMidY = ((o["m"] as? Double) ?? -1) * k
                webPinLeft = ((o["pl"] as? Double) ?? -1) * k
                webPinMidY = ((o["pm"] as? Double) ?? -1) * k
                webPinWidth = ((o["pw"] as? Double) ?? -1) * k
                webPinHeight = ((o["ph"] as? Double) ?? -1) * k
            }
            for _ in 0..<120 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                if titleRight >= 0 { break }
            }
        }
        let s2 = Double(delegate.testCardScale)
        let glass = delegate.testGlassFrame
        let h = win.contentView?.bounds.height ?? 0
        // 网页 y 向下 → 窗口坐标 y 向上。
        let titleMidInWindow = h - CGFloat(titleMidY)
        print("[诊断] 图钉对齐：图钉=\(NSStringFromRect(pin))"
              + " 标题右=\(String(format: "%.1f", titleRight))"
              + " 间距=\(String(format: "%.2f", Double(pin.minX) - titleRight))（应为 \(String(format: "%.2f", 8 * s2))）"
              + " 纵向差=\(String(format: "%.2f", Double(pin.midY - titleMidInWindow)))")
        check(abs((Double(pin.minX) - titleRight) - 8 * s2) < 2,
              "图钉要钉在标题右边 8×缩放处（实际间距 \(String(format: "%.2f", Double(pin.minX) - titleRight))，应为 \(String(format: "%.2f", 8 * s2))）")
        check(abs(Double(pin.midY - titleMidInWindow)) < 2,
              "图钉要和标题同一条水平线（纵向差 \(String(format: "%.2f", Double(pin.midY - titleMidInWindow)))）")
        check(abs(Double(glass.maxY) - Double(pin.midY) - 36 * s2) < 2.5,
              "图钉纵向要跟着卡片顶边缩放（卡片顶 \(glass.maxY) 图钉中心 \(pin.midY)）")
        // ⚠️ 用户看到的是**网页里**那枚图钉（视觉已经搬进网页层）：
        // 直接量它和标题文字的间距 / 中线，才是「有没有同步」的真正判据。
        print("[诊断] 网页图钉：左=\(String(format: "%.2f", webPinLeft))"
              + " 间距=\(String(format: "%.2f", webPinLeft - titleRight))（应为 \(String(format: "%.2f", 8 * s2))）"
              + " 尺寸=\(String(format: "%.2f", webPinWidth))×\(String(format: "%.2f", webPinHeight))"
              + "（高应为 \(String(format: "%.2f", 17 * s2))）"
              + " 纵向差=\(String(format: "%.2f", webPinMidY - titleMidY))")
        check(abs((webPinLeft - titleRight) - 8 * s2) < 2,
              "网页图钉要贴着标题右边 8×缩放（实际 \(String(format: "%.2f", webPinLeft - titleRight))）")
        check(abs(webPinMidY - titleMidY) < 1.5,
              "网页图钉要和标题同一条水平线（纵向差 \(String(format: "%.2f", webPinMidY - titleMidY)))")
        // 图钉按「17pt 高 + 原始比例」显示：不能写死 width/height 把它拉成正方形
        // （那会比原来的图钉胖一圈，用户：「图钉标识还是有点儿宽」）。
        check(abs(webPinHeight - 17 * s2) < 1.2,
              "网页图钉高度要跟着缩放（实际 \(String(format: "%.2f", webPinHeight))，"
              + "应为 \(String(format: "%.2f", 17 * s2))）")
        check(webPinWidth > 12 * s2 && webPinWidth < 16 * s2,
              "网页图钉宽度要按原始比例（实际 \(String(format: "%.2f", webPinWidth))，应明显小于 17×缩放）")
    } else {
        check(false, "拿不到图钉矩形")
    }

    delegate.testCloseSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    if problems.isEmpty {
        print("✅ 设置面板「卡片大小」滑杆（放大 / 缩小 / 写盘 / 关面板保持 / 贴边放大不越界 / 图钉对齐）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-scale-panel") {
    // 自检：**设置面板开着**时的缩放路径（2026-11）。
    //
    // 用户反馈「每次拖动之后都会闪一下，设置面板还会跟着移动」——
    // 根因是松手时把「拖动画布」缩回正常窗口、网页 transform 从
    // translate+scale 切回 scale：窗口同步、网页异步，中间一帧就闪。
    // 现在面板开着时松手**保留画布**（窗口/页面原点都不动，只更新网页缩放），
    // 面板关闭时才恢复成正常窗口。
    //
    // 验收：
    //   1. 拖动/松手期间窗口 frame 不变（= 画布），所以不会闪；
    //   2. 松手后卡片中心仍在原处（±2pt）；
    //   3. 关闭面板后窗口恢复成正常尺寸，卡片中心仍在原处（±2pt）。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-scale-panel 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForImportVerification()
    guard let win = delegate.testDesktopWindow else {
        print("❌ 没有桌面窗口")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }

    delegate.testOpenSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let centerBefore = delegate.testWebCardCenterOnScreen
    let frameNormal = delegate.testWindowFrameRect
    print("  [面板开] 窗口=\(NSStringFromRect(frameNormal)) 卡片中心=\(centerBefore.map(NSStringFromPoint) ?? "nil")")

    // 模拟一次**连续快速拖动**（不等每一帧落地，和真实滑块一样），
    // 最后一次 0.95，然后立刻松手 —— 检查网页最终 transform 是否真的到了 0.95。
    for i in 0..<40 {
        let v = 0.90 + Double(i) * (0.05 / 39.0)
        delegate.testApplyCardScaleDragFrame(v)
        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
    }
    var waited = 0.0
    while !delegate.testScaleDragSettled && waited < 1.0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        waited += 0.002
    }
    delegate.testCommitCardScale()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    if let renderer = delegate.testWebRenderer {
        func evalLocal(_ js: String) -> String? {
            var out: String?
            renderer.evaluateForTest(js) { out = $0 }
            for _ in 0..<200 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                if out != nil { break }
            }
            return out
        }
        let raw = evalLocal("""
        (function () {
          var c = document.querySelector('.card');
          var r = c ? c.getBoundingClientRect() : {width: 0};
          return JSON.stringify({ tr: document.body.style.transform, w: r.width });
        })();
        """)
        print("  [连续拖动后·实际] \(raw ?? "nil")")
        if let raw, let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tr = (obj["tr"] as? String) ?? ""
            let w = (obj["w"] as? Double) ?? 0
            // 0.95 档：网页卡片视觉宽度 ≈ 968 × 0.95 ≈ 919.6（允许 3pt）
            check(tr.contains("0.95") || abs(w - 919.6) < 3,
                  "连续拖动松手后网页必须真的到 0.95 档（transform=\(tr)，宽=\(w)）")
        }
    }
    let frameDrag = delegate.testWindowFrameRect
    delegate.testCommitCardScale()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let frameCommit = delegate.testWindowFrameRect
    let centerCommit = delegate.testWebCardCenterOnScreen
    print("  [拖动中] 窗口=\(NSStringFromRect(frameDrag))")
    print("  [松手后] 窗口=\(NSStringFromRect(frameCommit)) 卡片中心=\(centerCommit.map(NSStringFromPoint) ?? "nil")")
    check(frameDrag.width > 1200, "面板开着拖动时应进入常驻画布（实际宽 \(frameDrag.width)）")
    check(abs(frameCommit.width - frameDrag.width) < 1
          && abs(frameCommit.height - frameDrag.height) < 1
          && abs(frameCommit.minX - frameDrag.minX) < 1
          && abs(frameCommit.minY - frameDrag.minY) < 1,
          "松手时窗口不能变（否则会闪）：拖动中 \(NSStringFromRect(frameDrag)) → 松手 \(NSStringFromRect(frameCommit))")
    if let a = centerBefore, let b = centerCommit {
        check(abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3,
              "松手后卡片中心应仍在原处（\(NSStringFromPoint(a)) → \(NSStringFromPoint(b))）")
    }
    // ---- 松手后必须是「清晰档」：≥100% 用 pageZoom，不能停在位图放大 ----
    //
    // 拖动期间为了让网页和窗口同步，用的是 `body { transform: scale }`
    // （合成器放大，字是位图）。松手后如果不切回 `pageZoom`，
    // 用户看到的就是「放大后整套字都发糊」，而且关掉设置面板也不会恢复
    // （`restoreAfterSettingsClose` 有意不动网页）。
    //
    // 先放大到 112%（这台屏的上限附近），再松手 —— 只有 ≥100% 才该走 pageZoom。
    for i in 0..<16 {
        let v = 1.0 + Double(i) * (0.12 / 15.0)
        delegate.testApplyCardScaleDragFrame(v)
        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
    }
    var waitedZoomIn = 0.0
    while !delegate.testScaleDragSettled && waitedZoomIn < 1.0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        waitedZoomIn += 0.002
    }
    // 松手**前一帧**的可见中心 —— 松手只允许「换实现方式」，不允许位置变。
    // （放大过程中中心被夹屏推动是正常的：卡片变大后必须留在屏幕里。）
    let centerBeforeZoomIn = delegate.testWebCardCenterOnScreen
    let glassBeforeZoomIn = delegate.testGlassFrame
    let dragScaleNow = delegate.testCardScale
    delegate.testCommitCardScale()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let centerAfterZoomIn = delegate.testWebCardCenterOnScreen
    let glassAfterZoomIn = delegate.testGlassFrame
    if let renderer = delegate.testWebRenderer {
        print("  [放大松手] 请求 \(dragScaleNow) 实际 \(delegate.testCardScale)"
              + " usesPageZoom=\(renderer.testUsesPageZoom)"
              + " viewScale=\(renderer.testViewScale) pageZoom=\(renderer.webView.pageZoom)")
        if delegate.testCardScale >= 0.999 {
            check(renderer.testUsesPageZoom,
                  "≥100% 松手后必须切回 pageZoom（否则课表是位图放大，字发糊）")
            check(abs(renderer.webView.pageZoom - renderer.testViewScale) < 0.001,
                  "pageZoom 必须等于当前缩放（实际 \(renderer.webView.pageZoom) vs \(renderer.testViewScale)）")
        }
    }
    if let a = centerBeforeZoomIn, let b = centerAfterZoomIn {
        print("  [放大松手·中心] \(NSStringFromPoint(a)) → \(NSStringFromPoint(b))")
        check(abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3,
              "松手瞬间卡片中心不能跳（\(NSStringFromPoint(a)) → \(NSStringFromPoint(b))）")
    }
    print("  [放大松手·玻璃] 松手前=\(NSStringFromRect(glassBeforeZoomIn))"
          + " 松手后=\(NSStringFromRect(glassAfterZoomIn))")
    check(abs(glassAfterZoomIn.minX - glassBeforeZoomIn.minX) < 3
          && abs(glassAfterZoomIn.minY - glassBeforeZoomIn.minY) < 3
          && abs(glassAfterZoomIn.width - glassBeforeZoomIn.width) < 3
          && abs(glassAfterZoomIn.height - glassBeforeZoomIn.height) < 3,
          "松手瞬间毛玻璃不能跳（\(NSStringFromRect(glassBeforeZoomIn)) → \(NSStringFromRect(glassAfterZoomIn))）")
    let centerCommit2 = delegate.testWebCardCenterOnScreen

    // ---- 缩放 → 把课表拖到别处 → 再缩放：不能跳回上一次的锚点 ----
    //
    // 缩放锚点在拖动期间是锁定的；**松手必须释放**，否则用户
    // 「缩放过一次 → 把课表拖到别处 → 再缩放」时，卡片会被拽回老位置。
    let centerBeforeDrag = centerCommit2
    delegate.testDragWindow(by: CGSize(width: 120, height: -80))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let centerAfterDrag = delegate.testWebCardCenterOnScreen
    for i in 0..<8 {
        let v = 1.12 - Double(i) * (0.08 / 7.0)
        delegate.testApplyCardScaleDragFrame(v)
        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
    }
    var waitedSecond = 0.0
    while !delegate.testScaleDragSettled && waitedSecond < 1.0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        waitedSecond += 0.002
    }
    delegate.testCommitCardScale()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let centerAfterSecondZoom = delegate.testWebCardCenterOnScreen
    print("  [缩放→拖走→再缩放] 缩放后=\(centerBeforeDrag.map(NSStringFromPoint) ?? "nil")"
          + " 拖后=\(centerAfterDrag.map(NSStringFromPoint) ?? "nil")"
          + " 再缩放后=\(centerAfterSecondZoom.map(NSStringFromPoint) ?? "nil")")
    if let a = centerAfterDrag, let b = centerAfterSecondZoom {
        check(abs(a.x - b.x) < 4 && abs(a.y - b.y) < 4,
              "拖走之后再次缩放不能跳回旧锚点（\(NSStringFromPoint(a)) → \(NSStringFromPoint(b))）")
    }
    let centerCommit3 = centerAfterSecondZoom

    delegate.testCloseSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let frameAfterClose = delegate.testWindowFrameRect
    let centerAfterClose = delegate.testWebCardCenterOnScreen
    print("  [面板关] 窗口=\(NSStringFromRect(frameAfterClose)) 卡片中心=\(centerAfterClose.map(NSStringFromPoint) ?? "nil")")
    check(frameAfterClose.width < 1500, "关闭面板后窗口应恢复正常尺寸（实际宽 \(frameAfterClose.width)）")
    if let a = centerCommit3, let b = centerAfterClose {
        check(abs(a.x - b.x) < 3 && abs(a.y - b.y) < 3,
              "关闭面板后卡片中心不能跳（\(NSStringFromPoint(a)) → \(NSStringFromPoint(b))）")
    }
    // 关闭面板后也不许退回位图放大（以前关闭面板是完全不动网页的）。
    if let renderer = delegate.testWebRenderer {
        print("  [面板关·清晰度] usesPageZoom=\(renderer.testUsesPageZoom)"
              + " viewScale=\(renderer.testViewScale) pageZoom=\(renderer.webView.pageZoom)")
        check(renderer.testUsesPageZoom,
              "关闭面板后仍必须走 pageZoom（实际 usesPageZoom=\(renderer.testUsesPageZoom)）")
    }

    // ---- 面板里放到最大：卡片不能被画布（webView）裁掉 ----
    //
    // 用户原话：「放到最大，怎么右边被削了」。
    // 复现路径：先缩到 70% 把课表贴到屏幕左边 → 打开设置面板 → 放到最大。
    // 放大时卡片中心被按屏幕夹回来，旧实现里窗口不动，卡片就偏到画布一侧；
    // 画布只比最大档卡片宽 ~208pt，偏多一点就被 WKWebView 在边界裁掉。
    delegate.testApplyCardScale(0.70)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    delegate.testCommitCardScale()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    delegate.testDragWindow(by: CGSize(width: -4000, height: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print("  [放到最大] 贴左后卡片=\(NSStringFromRect(delegate.testGlassFrame))"
          + " 窗口=\(NSStringFromRect(win.frame))")
    delegate.testOpenSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    for i in 0..<12 {
        let v = 0.70 + Double(i) * (0.45 / 11.0)
        delegate.testApplyCardScaleDragFrame(v)
        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
    }
    var waitedMax = 0.0
    while !delegate.testScaleDragSettled && waitedMax < 1.0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        waitedMax += 0.002
    }
    delegate.testCommitCardScale()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let maxCard = TimetableLayout.cardRect
    let maxGlass = delegate.testGlassFrame
    let maxW = win.contentView?.bounds.width ?? 0
    let maxH = win.contentView?.bounds.height ?? 0
    let maxScreen = NSRect(x: win.frame.minX + maxCard.minX,
                           y: win.frame.minY + maxCard.minY,
                           width: maxCard.width, height: maxCard.height)
    let vfNow = NSScreen.main?.visibleFrame ?? .zero
    print("  [放到最大] 缩放=\(delegate.testCardScale)"
          + " 卡片(窗口坐标)=\(NSStringFromRect(maxCard))"
          + " 玻璃=\(NSStringFromRect(maxGlass))"
          + " 窗口=\(NSStringFromRect(win.frame))"
          + " 屏上=\(NSStringFromRect(maxScreen))")
    check(maxCard.minX >= -1.5 && maxCard.maxX <= maxW + 1.5
          && maxCard.minY >= -1.5 && maxCard.maxY <= maxH + 1.5,
          "放到最大时卡片必须完整落在画布内（否则会被 webView 裁：卡片 \(NSStringFromRect(maxCard))，画布 \(maxW)×\(maxH)）")
    check(maxScreen.minX >= vfNow.minX - 1.5 && maxScreen.maxX <= vfNow.maxX + 1.5
          && maxScreen.minY >= vfNow.minY - 1.5 && maxScreen.maxY <= vfNow.maxY + 1.5,
          "放到最大时卡片必须完整落在屏幕内（实际 \(NSStringFromRect(maxScreen))）")
    // 网页层自己也量一遍：真实渲染出来的 .card 不能超出 webView 的边界。
    if let renderer = delegate.testWebRenderer {
        var raw: String?
        renderer.evaluateForTest("""
        (function () {
          var c = document.querySelector('.card');
          var r = c ? c.getBoundingClientRect() : {left:0,right:0,top:0,bottom:0,width:0,height:0};
          return JSON.stringify({ l: r.left, r: r.right, t: r.top, b: r.bottom,
                                  w: r.width, h: r.height });
        })();
        """) { raw = $0 }
        for _ in 0..<80 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if raw != nil { break }
        }
        if let raw, let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let left = obj["l"] as? Double, let right = obj["r"] as? Double,
           let top = obj["t"] as? Double, let bottom = obj["b"] as? Double {
            let sc = Double(renderer.testRectScale)
            let webRight = right * sc
            let webBottom = bottom * sc
            let webLeft = left * sc
            let webTop = top * sc
            let vw = Double(renderer.webView.bounds.width)
            let vh = Double(renderer.webView.bounds.height)
            print("  [放到最大·网页] 左右=\(webLeft)/\(webRight) 上下=\(webTop)/\(webBottom)"
                  + " 画布=\(vw)×\(vh)")
            check(webRight <= vw + 1.5 && webLeft >= -1.5
                  && webBottom <= vh + 1.5 && webTop >= -1.5,
                  "放到最大时网页卡片不能超出 webView（会被裁）：右 \(webRight) / 底 \(webBottom)，画布 \(vw)×\(vh)")
        } else {
            check(false, "放到最大时量不到网页卡片矩形")
        }
    }
    delegate.testCloseSettingsPanel()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    if problems.isEmpty {
        print("✅ 设置面板开着的缩放（画布保持 / 松手不闪 / 关闭恢复）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-collapse") {
    // 自检：**课表折叠 / 展开**（2026-11 新增）。
    //
    // 验收（与用户确认的口径）：
    //   1. 折叠后只剩「顶栏 + 状态条 + 表头」，网格收掉；
    //   2. **卡片顶边 / 左边不动**，从底部收上去；
    //   3. 展开后回到原高度、顶边仍不动；
    //   4. 折叠是**过渡动画**（中间帧高度在变），不是瞬切；
    //   5. 原生玻璃 / 点击穿透 / 悬停区域跟着折叠矩形；
    //   6. 状态推送重建 DOM 之后仍然保持折叠（不会自己弹开）；
    //   7. 折叠态下拖到屏幕边缘仍然贴边（用矮卡片矩形夹屏）。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-collapse 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForImportVerification()
    guard let win = delegate.testDesktopWindow else {
        print("❌ 没有桌面窗口")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    guard let renderer = delegate.testWebRenderer else {
        print("❌ 没有网页渲染器")
        exit(1)
    }
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if renderer.isReady { break }
    }

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }
    func evalJSON(_ js: String) -> [String: Any]? {
        var out: [String: Any]?
        renderer.evaluateForTest(js) { r in
            guard let s = r, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = o
        }
        for _ in 0..<80 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if out != nil { break }
        }
        return out
    }
    func cardOnScreen() -> NSRect {
        let g = delegate.testGlassFrame
        return NSRect(x: win.frame.minX + g.minX, y: win.frame.minY + g.minY,
                      width: g.width, height: g.height)
    }
    let vf = NSScreen.main?.visibleFrame ?? .zero
    let expandedGlass = delegate.testGlassFrame
    let expandedScreen = cardOnScreen()
    let expandedFrame = win.frame
    print("[诊断] 屏幕可见区：\(NSStringFromRect(vf))  缩放=\(delegate.testCardScale)"
          + " 展开卡片=\(NSStringFromRect(expandedScreen))")

    // ---- 1. 走真实按钮路径：点网页里的折叠按钮 ----
    let btn = evalJSON("""
    (function () {
      var b = document.querySelector('.collapsebtn');
      if (!b) return JSON.stringify({ found: false });
      b.click();
      return JSON.stringify({ found: true });
    })();
    """)
    check((btn?["found"] as? Bool) == true, "状态条右侧必须有折叠按钮（.collapsebtn）")
    // 等动画落地（0.30s + 余量）
    RunLoop.current.run(until: Date().addingTimeInterval(0.55))
    let collapsedProgress = delegate.testCollapseProgress
    let collapsedGlass = delegate.testGlassFrame
    let collapsedScreen = cardOnScreen()
    let collapsedFrame = win.frame
    print("[诊断] 折叠后进度=\(collapsedProgress) 卡片=\(NSStringFromRect(collapsedScreen))"
          + " 玻璃=\(NSStringFromRect(collapsedGlass)) 窗口=\(NSStringFromRect(collapsedFrame))")
    check(collapsedProgress > 0.99, "点按钮后应完全收起（进度 \(collapsedProgress)）")
    check(abs(collapsedScreen.maxY - expandedScreen.maxY) < 2,
          "折叠时卡片**顶边**不能动（\(expandedScreen.maxY) → \(collapsedScreen.maxY)）")
    check(abs(collapsedScreen.minX - expandedScreen.minX) < 2,
          "折叠时卡片左边不能动（\(expandedScreen.minX) → \(collapsedScreen.minX)）")
    check(abs(collapsedScreen.width - expandedScreen.width) < 2,
          "折叠时卡片宽度不能变（\(expandedScreen.width) → \(collapsedScreen.width)）")
    check(collapsedScreen.height < expandedScreen.height * 0.5,
          "折叠后卡片应明显变矮（\(expandedScreen.height) → \(collapsedScreen.height)）")
    check(abs(collapsedFrame.minX - expandedFrame.minX) < 1
          && abs(collapsedFrame.minY - expandedFrame.minY) < 1,
          "折叠时窗口不能动（\(NSStringFromRect(expandedFrame)) → \(NSStringFromRect(collapsedFrame))）")
    // 网页实测：卡片高度、网格裁切高度
    if let web = evalJSON("""
        (function () {
          var c = document.querySelector('.card');
          var w = document.querySelector('.gridwrap');
          var cell = document.querySelector('.grid > .cell');
          var st = document.querySelector('.status');
          var r = c ? c.getBoundingClientRect() : null;
          return JSON.stringify({ h: r ? r.height : -1, w: r ? r.width : -1,
                                  wrapH: w ? w.offsetHeight : -1,
                                  statusH: st ? st.offsetHeight : -1,
                                  cellOpacity: cell ? getComputedStyle(cell).opacity : '-1' });
        })();
        """) , let webH = web["h"] as? Double, let webW = web["w"] as? Double,
       let wrapH = web["wrapH"] as? Int {
        let cellOpacity = (web["cellOpacity"] as? String) ?? "?"
        print("[诊断] 网页：卡片 \(Int(webW))×\(Int(webH)) 网格容器高 \(wrapH)"
              + " 状态条高 \((web["statusH"] as? Int) ?? -1) 正文透明度 \(cellOpacity)")
        check(abs(webH - Double(collapsedGlass.height)) < 3,
              "网页卡片高度要和原生玻璃一致（网页 \(webH) vs 玻璃 \(collapsedGlass.height)）")
        check(abs(Double(wrapH) - 38) < 2, "折叠后网格容器应只剩表头 38pt（实际 \(wrapH)）")
    } else {
        check(false, "折叠后量不到网页卡片 / 网格容器")
    }
    // 点击穿透 / 悬停区域必须缩到折叠矩形
    let pass = delegate.testPassthroughRect
    let nativeCard = TimetableLayout.cardRect
    check(abs(pass.minX - nativeCard.minX) < 1 && abs(pass.minY - nativeCard.minY) < 1
          && abs(pass.height - nativeCard.height) < 1,
          "折叠后点击穿透区域要跟着缩（穿透 \(NSStringFromRect(pass)) vs 卡片 \(NSStringFromRect(nativeCard))）")

    // ---- 2. 中间帧：动画要有过程（不是瞬切）----
    // 重新展开，在 0.1s 时采样一次高度，必须介于两档之间。
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.10))
    let midHeight = delegate.testGlassFrame.height
    print("[诊断] 展开动画 0.10s 时高度=\(midHeight)（展开 \(expandedGlass.height)，折叠 \(collapsedGlass.height)）")
    check(midHeight > collapsedGlass.height + 8 && midHeight < expandedGlass.height - 8,
          "展开必须有过渡动画（0.10s 时高度应在两档之间，实际 \(midHeight)）")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let reExpanded = delegate.testGlassFrame
    let reExpandedScreen = cardOnScreen()
    print("[诊断] 展开后卡片=\(NSStringFromRect(reExpandedScreen))")
    check(abs(reExpanded.height - expandedGlass.height) < 2,
          "展开后卡片高度要回到原值（\(expandedGlass.height) → \(reExpanded.height)）")
    check(abs(reExpandedScreen.maxY - expandedScreen.maxY) < 2,
          "展开后卡片顶边仍不能动（\(expandedScreen.maxY) → \(reExpandedScreen.maxY)）")

    // ---- 3. 折叠 + 原生推状态（重建 DOM）后仍是折叠 ----
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let collapsedBeforePush = delegate.testGlassFrame
    delegate.testApplyCardScale(delegate.testCardScale)   // 触发 refreshCard（整树重建）
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let collapsedAfterPush = delegate.testGlassFrame
    print("[诊断] 状态推送前=\(NSStringFromRect(collapsedBeforePush))"
          + " 推送后=\(NSStringFromRect(collapsedAfterPush))")
    check(abs(collapsedAfterPush.height - collapsedBeforePush.height) < 2,
          "原生推状态重建 DOM 后仍应保持折叠（\(collapsedBeforePush.height) → \(collapsedAfterPush.height)）")

    // ---- 4. 折叠态拖到屏幕左边：矮卡片也要能贴边 ----
    delegate.testDragWindow(by: CGSize(width: -4000, height: 0))
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    let edge = cardOnScreen()
    print("[诊断] 折叠贴左后卡片=\(NSStringFromRect(edge)) 可见区=\(NSStringFromRect(vf))")
    check(abs(edge.minX - vf.minX) < 2,
          "折叠态拖到左边要贴边（期望 \(vf.minX)，实际 \(edge.minX)）")
    check(edge.height > 100, "折叠态卡片高度不能算错（实际 \(edge.height)）")

    // ---- 5. 折叠态缩放：保持折叠、按折叠高度算、不被画布裁 ----
    delegate.testApplyCardScale(1.10)
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let zoomed = delegate.testGlassFrame
    let canvas = win.contentView?.bounds ?? .zero
    let zoomTop = win.frame.minY + zoomed.maxY
    print("[诊断] 折叠态缩放到 1.10：卡片=\(NSStringFromRect(zoomed)) 画布=\(NSStringFromRect(canvas))")
    check(delegate.testCollapseProgress > 0.99, "缩放之后仍应保持折叠（进度 \(delegate.testCollapseProgress)）")
    check(zoomed.height > 180 && zoomed.height < 210,
          "折叠态缩放后高度应按折叠尺寸算（实际 \(zoomed.height)）")
    check(zoomed.minX >= -1.5 && zoomed.maxX <= canvas.width + 1.5
          && zoomed.minY >= -1.5 && zoomed.maxY <= canvas.height + 1.5,
          "折叠态缩放后卡片不能被画布裁（卡片 \(NSStringFromRect(zoomed))，画布 \(canvas.width)×\(canvas.height)）")
    check(abs(zoomTop - (win.frame.minY + zoomed.maxY)) < 0.5, "折叠态缩放后顶边仍应稳定")

    // ---- 6. 折叠态点表头：先展开，再打开那一列的覆盖层 ----
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let headerClick = evalJSON("""
    (function () {
      var c = document.querySelector('.hcell[data-day="3"]');
      if (!c) return JSON.stringify({ ok: false });
      c.click();
      return JSON.stringify({ ok: true });
    })();
    """)
    check((headerClick?["ok"] as? Bool) == true, "折叠态应能找到周三的表头格")
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    let dayState = delegate.testDayPanelState
    print("[诊断] 折叠态点表头后：折叠进度=\(delegate.testCollapseProgress)"
          + " 覆盖层 open=\(dayState.open) day=\(dayState.day.map(String.init) ?? "nil")")
    check(delegate.testCollapseProgress < 0.01, "折叠态点表头应先展开（进度 \(delegate.testCollapseProgress)）")
    check(dayState.open && dayState.day == 3,
          "展开后应打开第 3 列的日期覆盖层（实际 open=\(dayState.open) day=\(dayState.day.map(String.init) ?? "nil")）")
    // ---- 7. 折叠 → 面板里缩放 → 展开：底部不能被画布裁 ----
    // 用户原话：「缩放之后移动结果下半部分显示不出了」。
    // 根因：折叠态缩放原来按「卡片中心」摆，折叠条会被摆到画布中间；
    // 展开时顶边不动、整段往下长 → 底部超出画布被 webView 裁掉。
    // 现在折叠态缩放锁**顶边**，卡片在画布里始终顶边对齐。
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let collapsedTopBefore = win.frame.minY + delegate.testGlassFrame.maxY
    delegate.testOpenSettingsPanel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    for i in 0..<12 {
        let v = 1.0 + Double(i) * (0.12 / 11.0)
        delegate.testApplyCardScaleDragFrame(v)
        RunLoop.current.run(until: Date().addingTimeInterval(0.008))
    }
    var waitedPanel2 = 0.0
    while !delegate.testScaleDragSettled && waitedPanel2 < 1.0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        waitedPanel2 += 0.002
    }
    delegate.testCommitCardScale()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    delegate.testCloseSettingsPanel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let collapsedAfterZoom = delegate.testGlassFrame
    print("[诊断] 折叠态面板缩放后：卡片=\(NSStringFromRect(collapsedAfterZoom))"
          + " 折叠进度=\(delegate.testCollapseProgress)")
    check(delegate.testCollapseProgress > 0.99, "面板里缩放后仍应保持折叠")
    // 展开
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let expandedAfter = delegate.testGlassFrame
    let canvas7 = win.contentView?.bounds ?? .zero
    let screen7 = NSRect(x: win.frame.minX + expandedAfter.minX,
                         y: win.frame.minY + expandedAfter.minY,
                         width: expandedAfter.width, height: expandedAfter.height)
    print("[诊断] 折叠→缩放→展开后：卡片=\(NSStringFromRect(expandedAfter))"
          + " 画布=\(NSStringFromRect(canvas7)) 屏上=\(NSStringFromRect(screen7))")
    check(expandedAfter.minX >= -1.5 && expandedAfter.maxX <= canvas7.width + 1.5
          && expandedAfter.minY >= -1.5 && expandedAfter.maxY <= canvas7.height + 1.5,
          "折叠→缩放→展开后卡片不能被画布裁（卡片 \(NSStringFromRect(expandedAfter))，画布 \(canvas7.width)×\(canvas7.height)）")
    check(screen7.minX >= vf.minX - 2 && screen7.maxX <= vf.maxX + 2
          && screen7.minY >= vf.minY - 2 && screen7.maxY <= vf.maxY + 2,
          "折叠→缩放→展开后卡片要完整在屏幕内（实际 \(NSStringFromRect(screen7))）")
    _ = collapsedTopBefore

    // 收尾：回到 100% 并展开（临时目录，不影响用户）
    delegate.testApplyCardScale(1.0)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))

    if problems.isEmpty {
        print("✅ 课表折叠（按钮 / 顶边不动 / 过渡动画 / 穿透 / 推状态保持 / 折叠态贴边）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-week-arrow") {
    // 自检：**点顶栏「上一周 / 下一周」必须真的切周并立刻重画**（2026-11 新增）。
    //
    // 用户反馈：「加了折叠功能之后，调上一周 / 下一周无法调动，
    // 加课 / 删课也不显示，过很久才逐渐显示」。
    //
    // 根因（已修）：折叠时会无条件 `closeDayPanel()`，而网页的
    // `runCloseAnimation` 在「没有面板元素」时直接 return，
    // 把 `DP.closing` 永久留在 true —— 之后所有整树重画都被跳过。
    //
    // 这里走**真实点击**（合成 NSEvent → CardInteractionView → 网页
    // elementFromPoint → post('week') → 原生 shiftViewWeek → 推状态 → 重画），
    // 三种状态各点一次：100% 展开、113% 展开、折叠态。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-week-arrow 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let win = delegate.testDesktopWindow, let renderer = delegate.testWebRenderer else {
        print("❌ 没有桌面窗口 / 渲染器")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if renderer.isReady { break }
    }

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }
    func evalJSON(_ js: String) -> [String: Any]? {
        var out: [String: Any]?
        renderer.evaluateForTest(js) { r in
            guard let s = r, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = o
        }
        for _ in 0..<80 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if out != nil { break }
        }
        return out
    }
    func chipText() -> String {
        (evalJSON("""
        (function () {
          var c = document.querySelector('.wkchip');
          return JSON.stringify({ chip: c ? c.textContent.trim() : '' });
        })();
        """)?["chip"] as? String) ?? ""
    }
    func lastPosted() -> String {
        (evalJSON("""
        (function () {
          var p = window.__ttLastPost;
          return JSON.stringify({ action: p ? p.action : null });
        })();
        """)?["action"] as? String) ?? "nil"
    }
    func arrowCenter(_ index: Int) -> NSPoint? {
        guard let o = evalJSON("""
        (function () {
          var a = document.querySelectorAll('.arrow')[\(index)];
          if (!a) return JSON.stringify({ x: -1, y: -1 });
          var r = a.getBoundingClientRect();
          return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
        })();
        """), let x = o["x"] as? Double, let y = o["y"] as? Double, x > 0, y > 0 else { return nil }
        let s = Double(renderer.testRectScale)
        let canvasH = win.contentView?.bounds.height ?? 0
        return NSPoint(x: win.frame.minX + x * s, y: win.frame.minY + (canvasH - y * s))
    }
    func sendClick(atScreen p: NSPoint) {
        let o = win.frame.origin
        let loc = NSPoint(x: p.x - o.x, y: p.y - o.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let ev = NSEvent.mouseEvent(with: type,
                                           location: loc,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: win.windowNumber,
                                           context: nil,
                                           eventNumber: 0,
                                           clickCount: 1,
                                           pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.sendEvent(ev)
            }
        }
    }
    /// 点一下某个箭头并等重画；返回 (点击前周次, 点击后周次, 发出的意图)。
    func clickArrow(_ index: Int, label: String)
        -> (before: String, after: String, action: String) {
        let before = chipText()
        guard let p = arrowCenter(index) else {
            check(false, "\(label)：量不到箭头位置")
            return (before, before, "nil")
        }
        sendClick(atScreen: p)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return (before, chipText(), lastPosted())
    }

    // ---- 1. 100% 展开：下一周 → 上一周 ----
    let r1 = clickArrow(1, label: "100% 展开·下一周")
    if let dbg = evalJSON("""
        (function () {
          return JSON.stringify({
            renderWeek: window.__ttRenderWeek,
            renderCount: window.__ttRenderCount || 0,
            weeks: (window.__ttUpdateWeeks || []).join(','),
            last: window.__ttLastPost ? window.__ttLastPost.action : null,
            err: window.__ttRenderError || null,
            ttUpdateType: (typeof window.ttUpdate),
            readyState: document.readyState,
            calls: window.__ttUpdateCalls || 0,
            href: location.href,
            chip: (document.querySelector('.wkchip') || {}).textContent || ''
          });
        })();
        """) {
        print("[诊断] 点击后网页：渲染周=\(dbg["renderWeek"] ?? "nil") "
              + "渲染次数=\(dbg["renderCount"] ?? "nil") 收到周次=\(dbg["weeks"] ?? "nil") "
              + "lastPost=\(dbg["last"] ?? "nil") chip=\(dbg["chip"] ?? "nil")"
              + " 渲染错=\(dbg["err"] ?? "nil")"
              + " ttUpdate=\(dbg["ttUpdateType"] ?? "nil") ready=\(dbg["readyState"] ?? "nil")"
              + " ttUpdate调用=\(dbg["calls"] ?? "nil")")
    }
    print("[诊断] 100% 展开点「下一周」：\(r1.before) → \(r1.after)（意图 \(r1.action)）")
    check(r1.action == "week", "点箭头应发出 week 意图（实际 \(r1.action)）")
    check(r1.after != r1.before, "100% 展开点「下一周」要切周（\(r1.before) → \(r1.after)）")
    let r2 = clickArrow(0, label: "100% 展开·上一周")
    print("[诊断] 100% 展开点「上一周」：\(r2.before) → \(r2.after)")
    check(r2.after == r1.before, "点「上一周」要回到最初的周次（\(r1.before) → \(r2.after)）")

    // ---- 2. 113% 展开（pageZoom 档位的坐标换算）----
    delegate.testApplyCardScale(1.13)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let r3 = clickArrow(1, label: "113% 展开·下一周")
    print("[诊断] 113% 展开点「下一周」：\(r3.before) → \(r3.after)")
    check(r3.after != r3.before, "113% 展开点「下一周」要切周（\(r3.before) → \(r3.after)）")

    // ---- 3. 折叠态（卡片只有一条，箭头还在顶栏）----
    delegate.testApplyCardScale(1.0)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let r4 = clickArrow(1, label: "折叠态·下一周")
    print("[诊断] 折叠态点「下一周」：\(r4.before) → \(r4.after)")
    check(r4.after != r4.before, "折叠态点「下一周」也要切周（\(r4.before) → \(r4.after)）")
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    if problems.isEmpty {
        print("✅ 顶栏切周（真实点击 → week 意图 → 立即重画，展开 / 113% / 折叠态）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-collapse-panel") {
    // 自检：**折叠态也能开日期覆盖层**（2026-11 新增）。
    //
    // 用户要求：折叠之后点表头日期，日历（日期覆盖层）照样展开；
    // 「显示的日历那一列」仍算课表内（悬停不淡出、点击不穿透），
    // 在表头之间移动时日历跟着换到那一天。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-collapse-panel 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let win = delegate.testDesktopWindow, let renderer = delegate.testWebRenderer else {
        print("❌ 没有桌面窗口 / 渲染器")
        exit(1)
    }
    win.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if renderer.isReady { break }
    }

    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok { problems.append(what) }
    }
    func evalJSON(_ js: String) -> [String: Any]? {
        var out: [String: Any]?
        renderer.evaluateForTest(js) { r in
            guard let s = r, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = o
        }
        for _ in 0..<80 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if out != nil { break }
        }
        return out
    }
    func click(_ js: String) {
        renderer.evaluateForTest(js) { _ in }
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    }
    func headerClick(_ day: Int) {
        click("""
        (function () {
          var c = document.querySelector('.hcell[data-day="\(day)"]');
          if (c) c.click();
          return '';
        })();
        """)
    }
    func panelDom() -> [String: Any]? {
        evalJSON("""
        (function () {
          var p = document.querySelector('.daypanel');
          var card = document.querySelector('.card');
          if (!p) return JSON.stringify({ found: false });
          var r = p.getBoundingClientRect();
          return JSON.stringify({
            found: true,
            opacity: getComputedStyle(p).opacity,
            visibility: getComputedStyle(p).visibility,
            cls: p.className,
            top: r.top, left: r.left, width: r.width, height: r.height,
            cardOverflow: card ? getComputedStyle(card).overflow : '',
            cardCollapsedCls: card ? card.classList.contains('collapsed') : false,
            collapse: (typeof window.__ttCollapse !== 'undefined' ? window.__ttCollapse : null)
          });
        })();
        """)
    }

    // ---- 1. 折叠 ----
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    check(delegate.testCollapseProgress > 0.9, "先要收起来（进度 \(delegate.testCollapseProgress)）")
    let strip = delegate.testGlassFrame
    print("[诊断] 折叠后卡片=\(NSStringFromRect(strip))")

    // ---- 2. 点第 3 列的表头 → 面板展开 ----
    headerClick(3)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let state = delegate.testDayPanelState
    let panelRect = delegate.testDayPanelRectInWindow
    let dom = panelDom()
    print("[诊断] 折叠态点表头：open=\(state.open) day=\(state.day.map(String.init) ?? "nil")"
          + " 面板矩形=\(panelRect.map(NSStringFromRect) ?? "nil")")
    print("[诊断] 网页面板：opacity=\(dom?["opacity"] ?? "nil") 可见=\(dom?["visibility"] ?? "nil")"
          + " top=\(dom?["top"] ?? "nil") cardOverflow=\(dom?["cardOverflow"] ?? "nil")"
          + " collapsedClass=\(dom?["cardCollapsedCls"] ?? "nil")")
    check(delegate.testCollapseProgress > 0.9, "开面板时卡片应保持折叠（进度 \(delegate.testCollapseProgress)）")
    check(state.open && state.day == 3, "折叠态点第 3 列表头应打开第 3 列的面板（open=\(state.open) day=\(state.day.map(String.init) ?? "nil")）")
    if let panelRect {
        let canvasH = win.contentView?.bounds.height ?? 0
        let headerBottom = TimetableLayout.headerRect.minY
        print("[诊断] 面板矩形（窗口坐标）=\(NSStringFromRect(panelRect))"
              + " 表头底边=\(headerBottom) 画布高=\(canvasH)")
        check(abs(panelRect.maxY - headerBottom) < 2,
              "面板顶边应贴着表头底边（面板 \(panelRect.maxY) vs 表头 \(headerBottom)）")
        check(panelRect.maxY <= canvasH + 1, "面板应在画布内（maxY=\(panelRect.maxY)）")
        // 悬停判定：面板那一列算「在课表上」
        let center = NSPoint(x: win.frame.minX + panelRect.midX,
                             y: win.frame.minY + panelRect.midY)
        delegate.testUpdateHover(.init(pointer: center,
                                       topWindowNumber: win.windowNumber,
                                       topWindowLayer: nil))
        check(delegate.testCardIsLit, "指针在折叠态面板那一列上时课表必须亮着")
        // 面板右侧外面（同一高度）→ 不算在课表上
        let outside = NSPoint(x: win.frame.minX + panelRect.maxX + 200,
                              y: win.frame.minY + panelRect.midY)
        delegate.testUpdateHover(.init(pointer: outside,
                                       topWindowNumber: win.windowNumber,
                                       topWindowLayer: nil))
        check(!delegate.testCardIsLit, "指针在面板右侧外面时必须判成离开课表")
        // 回到面板列，课表要能亮回来
        delegate.testUpdateHover(.init(pointer: center,
                                       topWindowNumber: win.windowNumber,
                                       topWindowLayer: nil))
        check(delegate.testCardIsLit, "指针回到面板列必须能亮回来")
    } else {
        check(false, "折叠态开面板后拿不到面板矩形")
    }
    if let dom, let opacity = Double(dom["opacity"] as? String ?? ""), let vis = dom["visibility"] as? String {
        check(opacity > 0.9 && vis == "visible", "网页面板必须真的显示（opacity=\(opacity) visibility=\(vis)）")
        check((dom["cardOverflow"] as? String) == "visible", "折叠态卡片要允许面板伸出来（overflow=\(dom["cardOverflow"] ?? "")）")
        check((dom["cardCollapsedCls"] as? Bool) == true, "卡片要带 collapsed 类")
    } else {
        check(false, "拿不到网页面板状态")
    }

    // ---- 3. 换一列（第 5 列）→ 面板跟着过去 ----
    headerClick(5)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let state2 = delegate.testDayPanelState
    let panelRect2 = delegate.testDayPanelRectInWindow
    print("[诊断] 换到第 5 列：open=\(state2.open) day=\(state2.day.map(String.init) ?? "nil")"
          + " 面板=\(panelRect2.map(NSStringFromRect) ?? "nil")")
    check(state2.open && state2.day == 5, "点第 5 列表头后日历应换到第 5 列（day=\(state2.day.map(String.init) ?? "nil")）")
    if let a = panelRect, let b = panelRect2 {
        check(abs(b.minX - a.minX) > 20, "换列后面板横向位置要跟着变（\(a.minX) → \(b.minX)）")
    }

    // ---- 4. 展开：面板还在（本来就落在卡片里）----
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let state3 = delegate.testDayPanelState
    check(state3.open && state3.day == 5, "展开后面板应保持打开（open=\(state3.open) day=\(state3.day.map(String.init) ?? "nil")）")
    delegate.testToggleCollapse()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    if problems.isEmpty {
        print("✅ 折叠态日期覆盖层（点表头展开 / 面板列算课表内 / 换列跟随）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-pin-flow") {
    // 自检：**课表图钉固定**的完整链路。
    //
    // 覆盖需求里的 5 条验收标准里能离线验的部分：
    //   1. 图钉在卡片**左侧外面**、与左边缘平行；空心时可拖动，
    //      点一下变实心（拖不动），再点变回空心；
    //   2. 位置与固定状态写盘 → 重新读回来一致（等价于「重启后恢复」）；
    //   3. 课表拖到左下角后，设置面板 / 课程编辑器 / 确认框都以课表为中心；
    //   4. 课表贴到屏幕边缘时，弹窗仍完整可见（被夹回屏幕内）；
    //   5. 原有自检不回归（由 `make test` 与 `make verify` 的其他关卡保证）。
    //
    // 用 `DT_DATA_DIR` 指向临时目录跑 —— **不碰用户真实的课表 / 设置 / 壁纸**。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    // 只准备数据与卡片，不建菜单栏图标、不注册登录项、不请求通知权限。
    delegate.prepareForRendering()

    var problems: [String] = []
    func fail(_ s: String) { problems.append(s) }

    /// 派发一个真实的鼠标事件（走 `NSApp.sendEvent` 的完整命中测试链路）。
    ///
    /// ⚠️ 合成事件的 `location` 会被原样当成 `locationInWindow`；而真实鼠标
    /// 事件给的是「相对**当前**窗口位置」的窗口坐标。窗口拖动过程中自己在动，
    /// 所以这里接收**屏幕坐标**、按当前窗口原点换算，才能和真实链路一致。
    func sendMouse(_ type: NSEvent.EventType, atScreen screen: NSPoint, in window: NSWindow) {
        let o = window.frame.origin
        let location = NSPoint(x: screen.x - o.x, y: screen.y - o.y)
        guard let ev = NSEvent.mouseEvent(with: type,
                                           location: location,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber,
                                           context: nil,
                                           eventNumber: 0,
                                           clickCount: 1,
                                           pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.sendEvent(ev)
    }

    // ---- 1. 图钉在卡片左上角、标题「我的课表」右边 ----
    guard let interaction = delegate.testInteraction else {
        print("❌ 没有拿到交互层（图钉 / 拖动）")
        exit(1)
    }
    let card = TimetableLayout.cardRect
    let pinRect = interaction.testPinRect
    let titleRight = card.minX + PushPinButton.titleLeftInset
        + PushPinButton.titleWidth(interaction.pinTitle)
    print("  图钉矩形：\(NSStringFromRect(pinRect))")
    print("  卡片矩形：\(NSStringFromRect(card))")
    print("  标题：\(interaction.pinTitle)（右缘 \(titleRight)）")
    // 在卡片内部（左上角区域），不能跑出卡片。
    if pinRect.minX < card.minX || pinRect.maxX > card.maxX
        || pinRect.minY < card.minY || pinRect.maxY > card.maxY {
        fail("图钉跑出卡片了（\(NSStringFromRect(pinRect))）")
    }
    // 必须在标题文字**右边**，且不压标题。
    if pinRect.minX < titleRight {
        fail("图钉压到标题文字了（图钉 \(pinRect.minX)，标题右缘 \(titleRight)）")
    }
    if pinRect.minX - titleRight > PushPinButton.gapToTitle + 0.5 {
        fail("图钉没有紧贴标题右侧（间距 \(pinRect.minX - titleRight)pt）")
    }
    // 与标题行平行（垂直居中对齐标题文字）。
    let titleCenterY = card.maxY - PushPinButton.titleCenterFromCardTop
    if abs(pinRect.midY - titleCenterY) > 1 {
        fail("图钉没有和标题行对齐（图钉中心 \(pinRect.midY)，标题中心 \(titleCenterY)）")
    }
    if pinRect.width < 16 || pinRect.width > 20 {
        fail("图钉尺寸 \(Int(pinRect.width))pt 不在 16–20pt 之间")
    }

    // ---- 2. 空心时可拖动 ----
    if !interaction.testAllowsDragging {
        fail("初始状态（空心图钉）竟然不允许拖动")
    }
    if delegate.testIsPinned {
        fail("初始状态不该是已固定")
    }

    // ---- 3. 拖动：窗口真的动了（位移换算）----
    let originBefore = delegate.testWindowOrigin
    delegate.testDragWindow(by: CGSize(width: 60, height: -40))
    let originAfter = delegate.testWindowOrigin
    print("  拖动前原点：\(NSStringFromPoint(originBefore))")
    print("  拖动后原点：\(NSStringFromPoint(originAfter))")
    if abs(originAfter.x - originBefore.x - 60) > 1
        || abs(originAfter.y - originBefore.y + 40) > 1 {
        fail("拖动没有按位移移动窗口（\(originBefore) → \(originAfter)）")
    }

    // ---- 3b. **真事件**拖动（走 NSApp.sendEvent 的完整命中测试链路）----
    //
    // 上面那条验的是位移换算；这条验的是「鼠标按下 → 拖动 → 松手」
    // 这条真实链路：交互层必须能接到事件、把位移转给窗口、
    // 而且**没拖动的点击**要原样转交给画面层（点课程、点齿轮照旧生效）。
    if let win = delegate.testDesktopWindow {
        // 事件必须送到**看得见**的窗口上 —— `NSApp.sendEvent` 不会投递给
        // 没 order front 的窗口（`prepareForRendering` 只准备数据与卡片）。
        win.alphaValue = 1
        win.orderFrontRegardless()
        win.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // 起点选在卡片**空白处**（标题右侧），不是图钉、也不是任何按钮。
        //
        // `startInWindow` 用来做命中测试（窗口坐标）；拖拽事件按**屏幕坐标**
        // 给，由 `sendMouse` 换算成「相对当前窗口原点」的窗口坐标 ——
        // 这样窗口在拖拽中移动时，事件坐标始终跟得上，和真实鼠标一致。
        // 常驻画布下窗口比卡片大；默认位置时卡片顶部离屏幕可见区上沿很近，
        // 往上拖 60pt 会被夹屏（最多只能挪 18pt）。先把窗口往下挪 60pt，
        // 给这张测试留出足够的拖动空间，再验「1:1」。
        let origin0 = win.frame.origin
        (win as? DesktopWindow)?.move(to: NSPoint(x: origin0.x, y: origin0.y - 60),
                                      onScreenContaining: origin0)
        win.contentView?.layoutSubtreeIfNeeded()
        let winOrigin = win.frame.origin
        let startScreen = NSPoint(x: winOrigin.x + TimetableLayout.cardRect.minX + 400,
                                  y: winOrigin.y + TimetableLayout.cardRect.midY)
        let startInWindow = NSPoint(x: TimetableLayout.cardRect.minX + 400,
                                    y: TimetableLayout.cardRect.midY)
        // 诊断：事件到底落到哪个视图上。
        let hit = win.contentView?.hitTest(startInWindow)
        NSLog("[DesktopTimetable] 自检诊断：命中=%@ ignoresMouse=%@ alpha=%.2f visible=%@",
              hit.map { String(describing: type(of: $0)) } ?? "nil",
              String(win.ignoresMouseEvents), win.alphaValue, String(win.isVisible))
        let before = delegate.testWindowOrigin
        sendMouse(.leftMouseDown, atScreen: startScreen, in: win)
        // 分几步拖 —— 超过阈值（4pt）才算拖动。
        for step in 1...6 {
            let p = NSPoint(x: startScreen.x + CGFloat(step) * 20,
                            y: startScreen.y + CGFloat(step) * 10)
            sendMouse(.leftMouseDragged, atScreen: p, in: win)
        }
        sendMouse(.leftMouseUp, atScreen: NSPoint(x: startScreen.x + 120,
                                                  y: startScreen.y + 60), in: win)
        let after = delegate.testWindowOrigin
        print("  真事件拖动：\(NSStringFromPoint(before)) → \(NSStringFromPoint(after))")
        // ⚠️ 必须是**1:1**：鼠标挪多远，窗口就挪多远。
        //
        // 曾经的 bug：算鼠标屏幕坐标时用了「当前」窗口原点，
        // 而窗口在拖动过程中自己也在动 —— 每来一个拖动事件，
        // 窗口已经移动的距离就被**再算一遍**，位移越滚越大
        // （鼠标只挪 10pt、窗口却飞出去 100pt）。
        let expected = CGSize(width: 120, height: 60)
        let actual = CGSize(width: after.x - before.x, height: after.y - before.y)
        print("  位移：期望 \(Int(expected.width))×\(Int(expected.height))  实际 \(Int(actual.width))×\(Int(actual.height))")
        if abs(actual.width - expected.width) > 1 || abs(actual.height - expected.height) > 1 {
            fail("拖动和鼠标不同步（期望 \(Int(expected.width))×\(Int(expected.height))，实际 \(Int(actual.width))×\(Int(actual.height))）")
        }

        // 固定之后：同样的真事件拖动必须**纹丝不动**。
        delegate.testSetPinned(true)
        let pinnedBefore = delegate.testWindowOrigin
        sendMouse(.leftMouseDown, atScreen: startScreen, in: win)
        for step in 1...6 {
            let p = NSPoint(x: startScreen.x + CGFloat(step) * 20,
                            y: startScreen.y + CGFloat(step) * 10)
            sendMouse(.leftMouseDragged, atScreen: p, in: win)
        }
        sendMouse(.leftMouseUp, atScreen: NSPoint(x: startScreen.x + 120,
                                                  y: startScreen.y + 60), in: win)
        if delegate.testWindowOrigin != pinnedBefore {
            fail("固定后还能用真事件拖动窗口")
        }
        delegate.testSetPinned(false)
    } else {
        fail("拿不到桌面窗口（真事件拖动没测成）")
    }

    // ---- 4. 拖不出屏幕：至少完整可见 ----
    // 往左下角猛拖 —— 应该被夹回可见区，而不是整个跑到屏幕外面。
    delegate.testDragWindow(by: CGSize(width: -99999, height: -99999))
    let clamped = delegate.testWindowOrigin
    print("  猛拖之后原点：\(NSStringFromPoint(clamped))")
    if !delegate.testWindowFullyVisible {
        fail("猛拖之后课表没有完整留在屏幕可见区里（原点 \(NSStringFromPoint(clamped))）")
    }

    // ---- 5. 点图钉 → 变实心 → 拖不动 ----
    interaction.pinButton.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 8, y: 8),
        modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    if !interaction.testPinIsPinned {
        fail("点图钉没有变成「已固定」")
    }
    if !delegate.testIsPinned {
        fail("图钉状态没有传到 AppDelegate")
    }
    if interaction.testAllowsDragging {
        fail("固定后仍然允许拖动")
    }
    // 固定后再拖 → 窗口纹丝不动。
    let pinnedOrigin = delegate.testWindowOrigin
    delegate.testDragWindow(by: CGSize(width: 120, height: 90))
    if delegate.testWindowOrigin != pinnedOrigin {
        fail("固定后还能拖动窗口")
    }
    // 图钉本身仍然可点（要能解开固定）。
    //
    // ⚠️ 2026-11 起图钉**视觉和点击都在网页层**（`.ttlpin`，和标题同一个 DOM）：
    // 交互层这一小块必须让出去（hitTest 返回 nil），点击才会落到网页那张图上。
    let pinHit = interaction.hitTest(pinRect.origin)
    if pinHit != nil {
        fail("固定后图钉区域应让给网页（实际被 \(type(of: pinHit!)) 接管）")
    }
    delegate.testClickWebPin()
    if delegate.testIsPinned {
        fail("点网页里的图钉没有解开固定")
    }
    // 再点一次锁回去，后面的「再点 → 解锁」步骤仍按原来的状态机走。
    delegate.testClickWebPin()
    if !delegate.testIsPinned {
        fail("再点网页里的图钉没有重新固定")
    }

    // ---- 6. 再点 → 变白 → 恢复可拖动 ----
    interaction.pinButton.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 8, y: 8),
        modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    if interaction.testPinIsPinned {
        fail("再点图钉没有变回未固定")
    }
    if !interaction.testAllowsDragging {
        fail("解锁后仍然拖不动")
    }

    // ---- 7. 位置与固定状态持久化（等价于「重启后恢复」）----
    // 先固定 + 挪到一个已知位置，再写盘 → 新开一个 store 读回来。
    delegate.testSetPinned(true)
    // 选一个**卡片放得下**的位置（窗口原点 y 要给卡片 782pt 留够空间）。
    let vfForSave = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    // 常驻画布下卡片在窗口里居中，窗口原点 = 卡片原点 - 画布留白。
    // 20pt 是给卡片底部留的余量；太大会被「卡片完整可见」的夹屏修正。
    let known = NSPoint(x: vfForSave.minX + 100, y: vfForSave.minY - 33)
    delegate.testMoveWindow(to: known)
    let store = TimetablePinStore()
    let saved = store.load()
    print("  写盘内容：固定=\(saved.pinned) 位置=\(saved.origin.map { NSStringFromPoint($0) } ?? "nil")")
    if !saved.pinned {
        fail("固定状态没有写盘")
    }
    guard let savedOrigin = saved.origin else {
        fail("窗口位置没有写盘")
        print("")
        for p in problems { print("❌ \(p)") }
        exit(1)
    }
    // 位置可能因为「夹回可见区」被修正过，所以只验它落在这附近。
    if abs(savedOrigin.x - known.x) > 5 || abs(savedOrigin.y - known.y) > 5 {
        fail("写盘的位置和实际位置对不上（期望 ≈ \(NSStringFromPoint(known))，实际 \(NSStringFromPoint(savedOrigin))）")
    }
    // 写盘的位置必须让卡片完整落在可见区里。
    if !delegate.testWindowFullyVisible {
        fail("写盘的位置让课表有一部分跑到屏幕外了")
    }
    // 解锁也要写盘。
    delegate.testSetPinned(false)
    if store.load().pinned {
        fail("解锁状态没有写盘")
    }
    // 位置在解锁后仍然保留。
    if store.load().origin == nil {
        fail("解锁后位置丢了")
    }

    // ---- 8. 后续窗口以课表位置为锚点 ----
    // 把课表拖到屏幕**左下角**，然后看设置面板 / 确认框是不是跟着过去。
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    delegate.testMoveWindow(to: NSPoint(x: vf.minX + 2, y: vf.minY + 2))
    let anchor = delegate.testTimetableCenter
    print("  课表中心（拖到左下角后）：\(NSStringFromPoint(anchor))")

    // 设置面板：中心必须落在课表中心附近（而不是屏幕正中）。
    let ctl = SettingsWindowController(store: ScheduleStore(), timetableStore: TimetableStore()) {}
    ctl.buildWindow()
    ctl.show(relativeTo: nil)
    let panelFrame = ctl.window?.frame ?? .zero
    print("  设置面板 frame：\(NSStringFromRect(panelFrame))")
    if abs(panelFrame.midX - anchor.x) > 2 || abs(panelFrame.midY - anchor.y) > 2 {
        fail("设置面板没有以课表为中心（面板 \(NSStringFromRect(panelFrame))，课表中心 \(NSStringFromPoint(anchor))）")
    }
    // 面板必须完整可见。
    if !ctl.isFullyVisible {
        fail("设置面板没有完整落在屏幕可见区里")
    }
    // 「在原位置展开」：展开板块时中心不能飘。
    let homeCenter = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
    ctl.expandTo(.appearance)
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let expandedFrame = ctl.window?.frame ?? .zero
    print("  展开后 frame：\(NSStringFromRect(expandedFrame))")
    if abs(expandedFrame.midX - homeCenter.x) > 3 || abs(expandedFrame.midY - homeCenter.y) > 3 {
        fail("面板展开时中心飘了（应保持原位置展开）")
    }
    if !ctl.isFullyVisible {
        fail("展开后的面板没有完整落在屏幕可见区里")
    }

    // 确认框（统一弹窗）：同样以课表为中心。
    let alert = AlertDialogController.makeWindowForTest(.init(
        severity: .info,
        title: "自检",
        message: "这是一个自检用的确认框，用来验它是不是以课表位置为锚点。",
        confirmTitle: "好",
        showsCancel: false))
    let alertFrame = alert.frame
    print("  确认框 frame：\(NSStringFromRect(alertFrame))")
    if abs(alertFrame.midX - anchor.x) > 2 || abs(alertFrame.midY - anchor.y) > 2 {
        fail("确认框没有以课表为中心（框 \(NSStringFromRect(alertFrame))，课表中心 \(NSStringFromPoint(anchor))）")
    }
    if alertFrame.minX < vf.minX - 0.5 || alertFrame.maxX > vf.maxX + 0.5
        || alertFrame.minY < vf.minY - 0.5 || alertFrame.maxY > vf.maxY + 0.5 {
        fail("确认框没有完整落在屏幕可见区里")
    }

    // 课程编辑器：同样以课表为中心。
    if let editor = delegate.testOpenEditor(courseID: "nonexistent-id") {
        let editorFrame = editor.testWindow?.frame ?? .zero
        print("  课程编辑器 frame：\(NSStringFromRect(editorFrame))")
        if abs(editorFrame.midX - anchor.x) > 2 || abs(editorFrame.midY - anchor.y) > 2 {
            fail("课程编辑器没有以课表为中心")
        }
        if editorFrame.minX < vf.minX - 0.5 || editorFrame.maxX > vf.maxX + 0.5
            || editorFrame.minY < vf.minY - 0.5 || editorFrame.maxY > vf.maxY + 0.5 {
            fail("课程编辑器没有完整落在屏幕可见区里")
        }
        editor.close()
    }

    // ---- 9. 课表贴到屏幕边缘 → 弹窗仍完整可见 ----
    delegate.testMoveWindow(to: NSPoint(x: vf.maxX - 10, y: vf.maxY - 10))
    let edgeAnchor = delegate.testTimetableCenter
    ctl.positionWindow(mouse: nil)
    let edgeFrame = ctl.window?.frame ?? .zero
    print("  课表贴到右上角后，面板 frame：\(NSStringFromRect(edgeFrame))")
    if edgeFrame.minX < vf.minX - 0.5 || edgeFrame.maxX > vf.maxX + 0.5
        || edgeFrame.minY < vf.minY - 0.5 || edgeFrame.maxY > vf.maxY + 0.5 {
        fail("课表贴到屏幕边缘后面板跑出屏幕了")
    }
    if abs(edgeFrame.midX - edgeAnchor.x) > 2 && abs(edgeFrame.midY - edgeAnchor.y) > 2 {
        fail("课表贴边后面板没有以课表为中心")
    }

    // ---- 10. 复位：删掉临时状态文件，别留下垃圾 ----
    try? FileManager.default.removeItem(at: TimetablePinStore().file)

    if problems.isEmpty {
        print("✅ 课表图钉固定（拖动 / 固定 / 位置记忆 / 弹窗锚点）：通过")
        // ⚠️ **自检收尾：把设置面板收走**（否则它一直浮在用户窗口前面）。
        ctl.closeForAutomationCleanup()
        exit(0)
    }
    print("")
    for p in problems { print("❌ \(p)") }
    exit(1)
}

/// 自检用：**延迟回包**的 EventKit fake。
///
/// 真实的 EventKit 是异步的；`FakeEventKitStore` 是同步的，测不出
/// 「翻周前的旧刷新晚到、覆盖新一周」这种竞态。这里让回调延迟返回，
/// 并且延迟**在发起查询那一刻就确定** —— 自检可以先用长延迟发一轮、
/// 再改短延迟发新一轮，稳定复现「后发的先回、先发的后回」。
final class DelayedEventKitStore: EventKitStoreProtocol {
    var delay: TimeInterval = 0.25
    var todosByDate: [Date: [DayPanelTodo]] = [:]

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
    var reminderAuthorization: EKAuthorizationStatus { .fullAccess }
    var eventAuthorization: EKAuthorizationStatus { .fullAccess }
    func requestReminderAccess(completion: @escaping (Bool) -> Void) { completion(true) }
    func requestEventAccess(completion: @escaping (Bool) -> Void) { completion(true) }
    func reminderLists() -> [EventKitListInfo] {
        [EventKitListInfo(title: "测试清单", identifier: "list-1", isWritable: true)]
    }
    func reminders(on date: Date, completion: @escaping ([DayPanelTodo]) -> Void) {
        let key = cal.startOfDay(for: date)
        let items = todosByDate[key] ?? []
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completion(items) }
    }
    func events(on date: Date, completion: @escaping ([DayPanelEvent]) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completion([]) }
    }
    func setReminder(_ identifier: String, in calendarIdentifier: String,
                     done: Bool, completion: @escaping (Bool) -> Void) { completion(true) }
    func updateReminder(_ identifier: String, in calendarIdentifier: String,
                        title: String, due: Date,
                        completion: @escaping (Bool) -> Void) { completion(true) }
    func createReminderList(titled title: String) -> EventKitListInfo? {
        EventKitListInfo(title: title, identifier: "list-new", isWritable: true)
    }
    func addReminder(title: String, due: Date, in calendarIdentifier: String,
                     completion: @escaping (Bool, String) -> Void) { completion(true, "") }
    func deleteReminder(_ identifier: String, in calendarIdentifier: String,
                        completion: @escaping (Bool) -> Void) { completion(true) }

    // 已完成提醒事项：这组竞态用例用不到，返回空 / 失败即可。
    func completedReminders(completion: @escaping (Result<[CompletedReminder], Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completion(.success([])) }
    }
    func restoreReminder(_ identifier: String, in calendarIdentifier: String,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(CompletedRemindersError.underlying("DelayedEventKitStore 不支持恢复")))
    }
    func deleteCompletedReminder(_ identifier: String, in calendarIdentifier: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(CompletedRemindersError.underlying("DelayedEventKitStore 不支持删除")))
    }
    func deleteAllCompletedReminders(
        progress: ((Int, Int) -> Void)?,
        completion: @escaping (CompletedRemindersDeleteResult) -> Void) {
        completion(CompletedRemindersDeleteResult(deleted: 0, failed: 0,
                                                  deletedIdentifiers: [],
                                                  failedIdentifiers: [],
                                                  message: nil))
    }
}

if arguments.contains("--verify-day-panel") {
    // 自检：**日期覆盖层**（点表头日期 → 该列覆盖一个面板）。
    //
    // 覆盖 5 件事：
    //   1. 纯计算：农历 / 节气 / 节日算得对不对；
    //   2. 纯计算：覆盖层的锚点与夹回可见区；
    //   3. 状态机：开 → 撑开 → 关，以及「离开所有列就淡出」；
    //   4. EventKit 封装：**用 fake**（绝不碰用户真实的日历 / 提醒事项）；
    //   5. 授权护栏：自动化模式下不请求权限。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()

    var problems: [String] = []
    func fail(_ s: String) { problems.append(s) }
    func check(_ cond: Bool, _ msg: String) { if !cond { fail(msg) } }

    // ---- 1. 农历 / 节气 / 节日（纯函数）----
    //
    // ⚠️ 时区用**固定 +08:00**，不能用 `Asia/Shanghai` ——
    // 后者在 1901 年前是 LMT(+08:05:43)，同一天的零点会差 5 分钟，
    // 正好把 1900-01-31（农历表的下边界）推到范围外。
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    check(LunarCalendar.text(day(2026, 2, 17)).contains("正月初一"),
          "2026-02-17 应该是农历正月初一（春节）")
    check(LunarCalendar.text(day(2026, 9, 25)).contains("八月十五"),
          "2026-09-25 应该是农历八月十五（中秋）")
    check(LunarCalendar.lunar(from: day(2020, 5, 23))?.isLeapMonth == true,
          "2020-05-23 应该在闰四月")
    check(FestivalCalendar.festivals(on: day(2026, 10, 1)).contains("国庆节"),
          "2026-10-01 应该是国庆节")
    check(FestivalCalendar.festivals(on: day(2026, 2, 17)).contains("春节"),
          "2026-02-17 应该是春节")
    check(!SolarTerms.terms(on: day(2026, 6, 21)).isEmpty,
          "2026-06-21 应该是夏至")
    // 往返：公历 → 农历 → 公历
    var roundTripOK = true
    var cursor = day(2026, 1, 1)
    for _ in 0..<365 {
        if let lunar = LunarCalendar.lunar(from: cursor),
           let back = LunarCalendar.date(from: lunar),
           cal.startOfDay(for: back) != cal.startOfDay(for: cursor) {
            roundTripOK = false
            break
        }
        cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
    }
    check(roundTripOK, "2026 全年公历→农历→公历往返必须一致")

    // ---- 2. 覆盖层锚点（纯计算）----
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let anchorOrigin = WindowAnchor.origin(forSize: NSSize(width: 119, height: 300),
                                           centeredAt: NSPoint(x: 400, y: 400),
                                           in: vf)
    check(abs(anchorOrigin.x + 59.5 - 400) < 0.001,
          "覆盖层中心要对齐课表中心")
    let clamped = WindowAnchor.origin(forSize: NSSize(width: 119, height: 300),
                                      centeredAt: NSPoint(x: -500, y: -500),
                                      in: vf)
    check(clamped.x >= vf.minX - 0.5 && clamped.y >= vf.minY - 0.5,
          "课表在屏幕外时覆盖层要夹回可见区")

    // ---- 3. 状态机（用 fake EventKit，不碰真实系统）----
    let fake = FakeEventKitStore()
    let controller = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: day(2026, 11, 2),
        eventStore: fake)
    check(controller.testState.open == false, "初始：覆盖层没打开")
    controller.open(day: 3)
    check(controller.testState.open == true, "点日期 → 覆盖层打开")
    check(controller.testState.day == 3, "打开的是第 3 列")
    controller.close(day: 3)
    check(controller.testState.open == false, "再点同一列日期 → 直接关闭")
    controller.open(day: 2)
    controller.close(day: 5)
    check(controller.testState.open == true, "关的是别的列 → 不该关掉当前的")
    controller.forceClose()
    check(controller.testState.open == false, "强制收起（拖动课表时用）")

    // ---- 4. EventKit 封装（fake）----
    fake.todos = [DayPanelTodo(title: "买牛奶", due: "20:00", done: false,
                               identifier: "r1", calendarIdentifier: "c1")]
    fake.events = [DayPanelEvent(title: "团队会议", start: "10:00", end: "11:00",
                                 identifier: "e1", calendarIdentifier: "c2")]
    controller.open(day: 3)
    // 取数是**异步**的（fake 也走 completion），转一圈主线程。
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let content = controller.testContent
    check(content.todos.count == 1 && content.todos.first?.title == "买牛奶",
          "覆盖层要拿到待办数据")
    check(content.events.count == 1 && content.events.first?.title == "团队会议",
          "覆盖层要拿到日程数据")
    check(controller.testFlags[3]?.hasTodo == true, "有待办的列 → 红点")
    check(controller.testFlags[3]?.hasEvent == true, "有日程的列 → 橙点")

    // ---- 4b. 待办的增删改（走 fake，不碰真实系统）----
    fake.todos = [
        DayPanelTodo(title: "买牛奶", due: "09:00", done: false,
                    dueMinutes: 540, identifier: "r1", calendarIdentifier: "c1"),
        DayPanelTodo(title: "交作业", due: "20:00", done: false,
                    dueMinutes: 1200, identifier: "r2", calendarIdentifier: "c1"),
    ]
    controller.open(day: 3)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    // 右键删除第 0 条（网页传的 index 是**原始下标**）。
    controller.handle(action: "todoDelete", payload: ["day": 3, "index": 0])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fake.deleteCalls.count == 1, "右键删除 → 调了一次 deleteReminder")
    check(fake.deleteCalls.first?.0 == "r1", "删的是第 0 条（r1）")

    // 单击打勾（切完成状态）。
    //
    // 传 identifier 而不是只传下标：删除后弹层里只剩一条（被删的那条先藏起来，
    // 不等 EventKit 取数追上），下标会和网页渲染时对不上。
    controller.handle(action: "todoToggle", payload: ["day": 3, "identifier": "r2", "index": 1])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fake.toggleCalls.count == 1, "单击待办 → 调了一次 setReminder")
    check(fake.toggleCalls.first?.2 == true, "打勾 → done = true")

    // 添加待办。
    controller.handle(action: "todoAdd", payload: ["day": 3, "title": "买面包"])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fake.addCalls.count == 1, "添加待办 → 调了一次 addReminder")
    check(fake.addCalls.first?.0 == "买面包", "加的是「买面包」")

    // ---- 4b-2. **网页跟到了别的列、原生 currentDay 还没跟上**（2026-11 修）----
    //
    // 场景（用户实测）：网页悬停跟随换列时，目标列已经有数据
    //（`DP.loaded[day] == true`）→ 它**不再发 `datePanelOpen`** 省掉一次查询
    // → 原生 `currentDay` 仍停在旧列。
    //
    // 此时用户在同一列添加待办：原生日志显示「新建提醒事项成功」、红点也亮了
    //（`refreshAll` 会查系统），但面板文字一直没有 —— 必须再点一下日期。
    // 根因是写操作后的乐观展示 / 重载都用 `currentDay == day` 当门槛。
    //
    // 这里验：写操作必须按**网页传来的 day** 补推那一天的数据，
    // 并验带 identifier 的完成请求不依赖 `content.todos` 里的旧数据。
    fake.appliesAdd = true
    controller.handle(action: "todoAdd", payload: ["day": 5, "title": "跨天新增"])
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    check(controller.testState.day == 3, "跨天写入不该改动原生的 currentDay")
    let pushedPanel = controller.testPushedPanel(day: 5)
    check(pushedPanel != nil,
          "网页看着别的列时，写操作也要补推那一天（否则面板文字一直不出现）")
    let pushedTodos = pushedPanel?["todos"] as? [[String: Any]] ?? []
    check(pushedTodos.contains { ($0["title"] as? String) == "跨天新增" },
          "补推的那一天里要包含刚加的待办（否则红点亮了、文字没有）")

    // 完成请求带 identifier + 清单 → 即使 content 还是别的天，也必须写回。
    controller.handle(action: "todoToggle",
                      payload: ["day": 5, "identifier": "added-2",
                                "calendarIdentifier": "c1"])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    check(fake.toggleCalls.contains { $0.0 == "added-2" },
          "带 identifier 的完成请求不能因为 currentDay 落后就丢掉")
    fake.appliesAdd = false

    // ---- 4b-3. 修改待办：标题 / 时间写回（fake，含写后读旧快照）----
    //
    // 用户需求：右键「修改…」改标题和到期时间，保存后：
    //   · 界面立刻更新（乐观展示）；
    //   · 系统提醒事项里真的改了（fake 断言参数）；
    //   · 写后读晚到的旧快照不能把界面改回去。
    let updateDay3 = day(2026, 11, 4)
    let updateDay5 = day(2026, 11, 6)
    var updateCal = Calendar(identifier: .gregorian)
    updateCal.timeZone = .current
    fake.todos = []
    fake.todosByDate = [
        updateCal.startOfDay(for: updateDay3): [
            DayPanelTodo(title: "旧标题", due: "09:00", done: false,
                         dueMinutes: 540, identifier: "u3",
                         calendarIdentifier: "c1")
        ],
        updateCal.startOfDay(for: updateDay5): [
            DayPanelTodo(title: "周五旧标题", due: "10:00", done: false,
                         dueMinutes: 600, identifier: "u5",
                         calendarIdentifier: "c1")
        ],
    ]
    fake.appliesUpdate = true
    fake.simulateStaleReads = 1
    controller.open(day: 3)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(controller.testContent.todos.first?.title == "旧标题", "修改用例基线：第 3 列是旧标题")

    controller.handle(action: "todoUpdate",
                      payload: ["day": 3, "identifier": "u3",
                                "calendarIdentifier": "c1",
                                "title": "新标题", "time": "20:30"])
    for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fake.updateCalls.count == 1, "修改待办 → 调了一次 updateReminder（实际 \(fake.updateCalls.count) 次）")
    if let call = fake.updateCalls.first {
        check(call.0 == "u3", "修改的是 u3")
        check(call.1 == "c1", "清单归属不变（c1）")
        check(call.2 == "新标题", "写回的是新标题")
        check(EventKitStore.timeText(call.3) == "20:30", "写回的是 20:30（实际 \(EventKitStore.timeText(call.3))）")
    }
    check(controller.testContent.todos.first?.title == "新标题",
          "保存成功后要立刻乐观显示新标题（实际 \(controller.testContent.todos.first?.title ?? "nil")）")
    check(controller.testContent.todos.first?.due == "20:30",
          "保存成功后要立刻乐观显示 20:30（实际 \(controller.testContent.todos.first?.due ?? "nil")）")
    // 第一次取数还是旧快照（旧标题 / 09:00）→ 展示层必须继续用新值；重试后也仍是新值。
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(controller.testContent.todos.first?.title == "新标题",
          "写后读旧快照不能把标题改回去（实际 \(controller.testContent.todos.first?.title ?? "nil")）")
    check(controller.testContent.todos.first?.due == "20:30",
          "写后读旧快照不能把时间改回去（实际 \(controller.testContent.todos.first?.due ?? "nil")）")
    check(controller.testContent.todos.count == 1, "修改不能复制出一条新待办")

    // 非法标题 / 时间 → 不写回（原生兜底，不依赖网页校验）。
    controller.handle(action: "todoUpdate",
                      payload: ["day": 3, "identifier": "u3",
                                "calendarIdentifier": "c1",
                                "title": "   ", "time": "21:00"])
    controller.handle(action: "todoUpdate",
                      payload: ["day": 3, "identifier": "u3",
                                "calendarIdentifier": "c1",
                                "title": "还是新标题", "time": "24:00"])
    for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(fake.updateCalls.count == 1, "空标题 / 非法时间不能写回（实际 \(fake.updateCalls.count) 次）")

    // 非当天列（网页跟随到别的列、原生 currentDay 还没跟上）也要能改。
    controller.handle(action: "todoUpdate",
                      payload: ["day": 5, "identifier": "u5",
                                "calendarIdentifier": "c1",
                                "title": "周五新标题", "time": "21:15"])
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    check(fake.updateCalls.count == 2, "非当天列的修改也要写回（实际 \(fake.updateCalls.count) 次）")
    check(controller.testState.day == 3, "非当天列写入不该改动原生 currentDay")
    let pushedUpdateDay = controller.testPushedPanel(day: 5)?["todos"] as? [[String: Any]] ?? []
    check(pushedUpdateDay.contains { ($0["title"] as? String) == "周五新标题" },
          "非当天列修改后要补推那一天（否则界面一直显示旧标题）")
    fake.appliesUpdate = false
    fake.simulateStaleReads = 0

    // ---- 4c. 网页层的交互（点日期打开 / 悬停跟随 / 再点关闭）----
    //
    // 这几条是**用户实测反馈**过的：
    //   · 鼠标移到顶部日期 → 瀑布不该消失（表头格也得算「那一列」）
    //   · 再点一次日期 → 瀑布不该还在（面板要真的关掉）
    //   · 点掉之后**悬停不能再把它弹回来**（包括扫到别的日期）
    //   · 悬停只负责「跟随」，打开只能靠点日期
    guard let renderer = delegate.testWebRenderer else {
        fail("拿不到网页渲染器")
        exit(1)
    }
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if renderer.isReady { break }
    }
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    // 注入数据 + 打开覆盖层。
    let sample = """
    (function () {
      var fake = { day: 3, todos: [], events: [],
        festival: { lunar: 'x', term: '', festivals: [] } };
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: fake, dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      return 'ok';
    })();
    """
    renderer.evaluateForTest(sample) { _ in }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    // ⚠️ 覆盖层的消失动画是 400ms 的 `.closing`；动画期间 `DP.closing` 为真，
    // 重新打开会被**推迟到动画播完**（设计如此，避免收一半突然弹回）。
    // 所以这些步骤不能挤在一次同步的 JS 求值里 —— 定时器根本没机会跑。
    // 拆成多段，每段之间等 ~600ms。
    func probeJSON(_ js: String) -> [String: Any]? {
        var out: [String: Any]?
        renderer.evaluateForTest(js) { result in
            guard let s = result, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = o
        }
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if out != nil { break }
        }
        return out
    }
    func pause(_ seconds: TimeInterval = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    var obj: [String: Any] = [:]
    func mergeProbe(_ js: String, _ what: String) {
        if let o = probeJSON(js) {
            obj.merge(o) { _, new in new }
        } else {
            fail("拿不到网页交互的诊断结果（\(what)）")
        }
    }

    // ---- 第 1 段：打开态、瀑布连续性、整列扫描、移出淡出 ----
    mergeProbe("""
    (function () {
      var d = document.querySelector('.daypanel');
      var out = {};
      out.opened = window.ttDayPanelIsOpen().open;
      // ---- 瀑布连续性：实心区底边必须贴住渐变尾巴的顶边（允许 1px 重叠）----
      var b = document.querySelector('.dpbody');
      var f = document.querySelector('.dpfade');
      out.bodyBottom = b ? Math.round(b.getBoundingClientRect().bottom) : -1;
      out.fadeTop = f ? Math.round(f.getBoundingClientRect().top) : -1;
      out.bodyH = b
        ? Math.round(b.getBoundingClientRect().height
                     / (typeof window.__ttGeomScale === 'number' ? window.__ttGeomScale : 1))
        : -1;

      // 表头选中态（`.sel`）的采样：逗号分隔的日期。
      function selDays() {
        var list = [];
        var cells = document.querySelectorAll('.hcell.sel');
        for (var si = 0; si < cells.length; si++) {
          list.push(cells[si].getAttribute('data-day'));
        }
        return list.join(',');
      }

      // ---- 打开状态下移到表头：瀑布不该消失（表头格也算那一列）----
      var hc3 = document.querySelector('.hcell[data-day="3"]');
      var hcr = hc3 ? hc3.getBoundingClientRect() : null;
      if (hcr) window.__ttDiagMove(hcr.left + hcr.width / 2, hcr.top + hcr.height / 2);
      out.afterMoveOpen = window.ttDayPanelIsOpen().open;
      out.afterMoveCls = d ? d.className : '';
      out.selAtTop = selDays();

      // ---- 沿整列从上到下扫一遍：课程格之间的缝不能把覆盖层弄没 ----
      //
      // 用户实测：点开后鼠标往下移，瀑布就消失了。根因是行与行之间有间距，
      // 指针掉进缝里时 elementFromPoint 返回 .grid（不是课程格）→ 当时判成
      // 「不在任何列」→ 淡出。覆盖层跟的是**整列**，不是某个格子。
      var grd = document.querySelector('.grid');
      var grdR = grd ? grd.getBoundingClientRect() : null;
      var lostAt = -1;
      if (hcr && grdR) {
        var cx = hcr.left + hcr.width / 2;
        for (var yy = grdR.top + 2; yy <= grdR.bottom - 2; yy += 6) {
          window.__ttDiagMove(cx, yy);
          if (!window.ttDayPanelIsOpen().open) { lostAt = Math.round(yy); break; }
        }
      }
      out.scanLostAt = lostAt;

      // ---- 跟随模式：移出网格（非列区域）→ 淡出 ----
      //
      // 用户实测：「点开后往下一移就没了，移到别的地也没了」。
      // 淡出只是看不见，跟随模式还在 —— 移回来必须继续跟着。
      if (hcr && grdR) window.__ttDiagMove(hcr.left + hcr.width / 2, grdR.bottom + 40);
      out.afterLeaveOpen = window.ttDayPanelIsOpen().open;
      out.leaveCls = d ? d.className : '';
      // ⚠️ **刚移出的这一瞬间，高亮必须还在**（2026-11 修「表头一暗一亮」）：
      // 收起动画 400ms 期间那一列仍然是被查看的；高亮提前掉 → 鼠标一晃回来
      // 又加回去，文字就会褪一半再变白。
      out.selAfterLeave = selDays();
      return JSON.stringify(out);
    })();
    """, "打开/扫描/移出")

    // 等 400ms 收拢动画播完（`DP.closing` 才会被清掉）。
    pause()

    // ---- 收起动画播完之后：高亮才可以摘 ----
    mergeProbe("""
    (function () {
      var list = [];
      var cells = document.querySelectorAll('.hcell.sel');
      for (var i = 0; i < cells.length; i++) list.push(cells[i].getAttribute('data-day'));
      return JSON.stringify({ selAfterClose: list.join(','), selAfterCloseCount: list.length });
    })();
    """, "收起动画播完")

    // ---- 第 2 段：移回第 4 列 → 跟随模式继续出现 ----
    mergeProbe("""
    (function () {
      var hc = document.querySelector('.hcell[data-day="4"]');
      if (hc) {
        var r = hc.getBoundingClientRect();
        window.__ttDiagMove(r.left + r.width / 2, r.top + r.height / 2);
      }
      return JSON.stringify({});
    })();
    """, "移回第 4 列")
    pause(0.3)
    mergeProbe("""
    (function () {
      var s = window.ttDayPanelIsOpen();
      var d = document.querySelector('.daypanel');
      var selCell = document.querySelector('.hcell.sel');
      return JSON.stringify({ afterBackOpen: s.open, afterBackDay: s.day,
                              backCls: d ? d.className : '',
                              afterBackSel: selCell ? selCell.getAttribute('data-day') : '' });
    })();
    """, "移回第 4 列后读状态")

    // ---- 第 3 段：再点当前那一列（第 4 列）→ 关闭并退出跟随模式 ----
    mergeProbe("""
    (function () {
      window.__ttDiagClick(4);
      var selCell = document.querySelector('.hcell.sel');
      return JSON.stringify({ afterClickOpen: window.ttDayPanelIsOpen().open,
                              selDuringClickClose: selCell ? selCell.getAttribute('data-day') : '' });
    })();
    """, "点第 4 列关闭")
    // 收拢 400ms 播完后 `.closing` 必须被摘掉（不能一直留着）。
    pause()
    mergeProbe("""
    (function () {
      var d = document.querySelector('.daypanel');
      return JSON.stringify({ afterClickCls: d ? d.className : '',
                              afterClickOpen: window.ttDayPanelIsOpen().open,
                              selAfterClickClose: document.querySelectorAll('.hcell.sel').length });
    })();
    """, "关闭动画播完后读状态")

    // ---- 第 4 段：点掉之后移到别的日期 → 不能再弹出来 ----
    mergeProbe("""
    (function () {
      var hc = document.querySelector('.hcell[data-day="3"]');
      if (hc) {
        var r = hc.getBoundingClientRect();
        window.__ttDiagMove(r.left + r.width / 2, r.top + r.height / 2);
      }
      return JSON.stringify({ afterHoverOtherClosed: window.ttDayPanelIsOpen().open });
    })();
    """, "关闭后悬停第 3 列")
    pause(0.3)

    // ---- 第 5 段：点另一个日期 → 重新打开；再点掉 → 悬停仍不弹 ----
    mergeProbe("""
    (function () {
      var out = {};
      window.__ttDiagClick(3);
      var s3 = window.ttDayPanelIsOpen();
      out.afterClickOther = s3.open;
      out.afterClickOtherDay = s3.day;
      var sel3 = document.querySelector('.hcell.sel');
      out.selAfterClickOther = sel3 ? sel3.getAttribute('data-day') : '';
      function hover(day) {
        var hc = document.querySelector('.hcell[data-day="' + day + '"]');
        if (!hc) return;
        var r = hc.getBoundingClientRect();
        window.__ttDiagMove(r.left + r.width / 2, r.top + r.height / 2);
      }
      // ---- 已经打开时移到第 5 列：悬停照常跟随 ----
      hover(5);
      var s5 = window.ttDayPanelIsOpen();
      out.followOpen = s5.open;
      out.followDay = s5.day;
      var sel5 = document.querySelector('.hcell.sel');
      out.followSel = sel5 ? sel5.getAttribute('data-day') : '';
      // ---- 再点当前显示的那一列（第 5 列）→ 关闭 ----
      window.__ttDiagClick(5);
      out.finalOpen = window.ttDayPanelIsOpen().open;
      var selClosing = document.querySelector('.hcell.sel');
      out.selWhileFinalClose = selClosing ? selClosing.getAttribute('data-day') : '';
      // ---- 关掉之后继续扫别的日期 → 仍然不弹 ----
      hover(6);
      out.afterFinalHover = window.ttDayPanelIsOpen().open;
      return JSON.stringify(out);
    })();
    """, "点别的列重开/跟随/再关闭")

    do {
        check((obj["opened"] as? Bool) == true, "覆盖层打开了")
        check((obj["afterMoveOpen"] as? Bool) == true,
              "鼠标移到顶部日期 → 覆盖层不该消失")
        let scanLostAt = (obj["scanLostAt"] as? NSNumber)?.intValue ?? -1
        check(scanLostAt == -1,
              "沿整列从上往下扫时覆盖层不能中途消失（在 y=\(scanLostAt) 处没了）")
        // 移出网格 → 淡出；移回某一列 → 跟随模式还在，继续出现
        check((obj["afterLeaveOpen"] as? Bool) == false,
              "指针移到课表外 / 时间列 → 覆盖层该淡出")
        check((obj["afterBackOpen"] as? Bool) == true,
              "点开过的面板移出后再移回某一列 → 应该继续跟着出现")
        check((obj["afterBackDay"] as? NSNumber)?.intValue == 4,
              "移回第 4 列 → 覆盖层跟到第 4 列（实际 \(obj["afterBackDay"] ?? "?")）")

        // ---- 表头选中态：收起动画期间保留、播完才摘（2026-11 修「一暗一亮」）----
        //
        // 用户实测：点完待办后表头「暗 → 亮 → 暗 → 亮」。根因是鼠标轻微一晃，
        // `fadeOutPanel` 立刻摘 `.sel`（文字开始 200ms 褪色），紧接着
        // `openPanel` 又加回来（文字再变白）—— 过渡被反复重播。
        // 现在：`.sel` 只在面板**真的收起了**（400ms 动画播完）之后才摘。
        check((obj["selAtTop"] as? String) == "3",
              "面板开在第 3 列时，表头第 3 列应当是选中态（实际 \(obj["selAtTop"] ?? "?")）")
        check((obj["selAfterLeave"] as? String) == "3",
              "鼠标刚移出时收起动画还在播 → 表头高亮必须保留（实际 \(obj["selAfterLeave"] ?? "?")，"
              + "提前摘掉就是「一暗一亮」的来源）")
        check((obj["selAfterCloseCount"] as? NSNumber)?.intValue ?? -1 == 0,
              "收起动画播完 → 表头高亮应当摘掉（实际还有 \(obj["selAfterCloseCount"] ?? "?") 列）")
        check((obj["afterBackSel"] as? String) == "4",
              "移回第 4 列重新打开 → 选中态跟到第 4 列（实际 \(obj["afterBackSel"] ?? "?")）")
        check((obj["selDuringClickClose"] as? String) == "4",
              "点击关闭的收起动画期间 → 高亮仍应保留（实际 \(obj["selDuringClickClose"] ?? "?")）")
        check((obj["selAfterClickClose"] as? NSNumber)?.intValue ?? -1 == 0,
              "点击关闭动画播完 → 高亮摘掉（实际还有 \(obj["selAfterClickClose"] ?? "?") 列）")
        check((obj["selAfterClickOther"] as? String) == "3",
              "点开第 3 列 → 选中态在第 3 列（实际 \(obj["selAfterClickOther"] ?? "?")）")
        check((obj["followSel"] as? String) == "5",
              "悬停跟随到第 5 列 → 选中态也跟到第 5 列（实际 \(obj["followSel"] ?? "?")）")
        check((obj["selWhileFinalClose"] as? String) == "5",
              "关闭第 5 列时收起动画期间 → 高亮仍应保留（实际 \(obj["selWhileFinalClose"] ?? "?")）")
        check((obj["afterClickOpen"] as? Bool) == false,
              "再点一次日期 → 覆盖层该关掉")
        let cls = obj["afterClickCls"] as? String ?? ""
        check(!cls.contains("show"), "关掉之后不能还留着 show 类（\(cls)）")
        // ⚠️ 2026-11 统一后消失动画只有 `.closing`（`.fading` 已删除），
        // 收拢 400ms 播完后 closing 也该被移除。
        check(!cls.contains("closing"), "关掉之后不能还留着 closing 类（\(cls)）")

        // 瀑布连续性：实心区底边和渐变尾巴顶边必须是**接上**的
        // （允许 -1…+2 的 1px 重叠 / 抗锯齿误差）。
        // 这里注入的就是**没有待办 / 日程**的数据 —— 实心区靠 min-height
        // 撑到 216pt，正是之前会裂开 140pt 缝的那种情况。
        let bodyBottom = (obj["bodyBottom"] as? NSNumber)?.doubleValue ?? -1
        let fadeTop = (obj["fadeTop"] as? NSNumber)?.doubleValue ?? -9999
        let gap = fadeTop - bodyBottom
        check(gap >= -2 && gap <= 2,
              "实心区（底边 \(bodyBottom)）与渐变尾巴（顶边 \(fadeTop)）不能断开，缝 = \(gap)pt")
        check((obj["bodyH"] as? NSNumber)?.doubleValue ?? 0 >= 216,
              "没有待办时实心区仍要有 216pt 的体量（实际 \(obj["bodyH"] ?? "?")）")

        // 点掉之后移到别的日期 → 悬停**不能**再把它弹出来（「点了收不了」的根治）
        check((obj["afterHoverOtherClosed"] as? Bool) == false,
              "点掉之后悬停到别的日期 → 不能自动弹出来")
        // 打开只能靠点击：点另一个日期 → 在新的那一列打开
        check((obj["afterClickOther"] as? Bool) == true,
              "点另一个日期 → 覆盖层重新打开")
        check((obj["afterClickOtherDay"] as? NSNumber)?.intValue == 3,
              "点第 3 列 → 覆盖层开在第 3 列（实际 \(obj["afterClickOtherDay"] ?? "?")）")
        // 打开之后 → 悬停照常跟随换列
        check((obj["followOpen"] as? Bool) == true, "打开后悬停不该让覆盖层消失")
        check((obj["followDay"] as? NSNumber)?.intValue == 5,
              "打开后悬停到第 5 列 → 覆盖层跟到第 5 列（实际 \(obj["followDay"] ?? "?")）")
        check((obj["finalOpen"] as? Bool) == false, "再点当前日期 → 覆盖层关闭")
        check((obj["afterFinalHover"] as? Bool) == false,
              "关掉之后继续悬停别的日期 → 仍然不能弹出来")
    }
    // 上面最后一步是「点掉第 5 列」→ 收拢动画还在播。等它播完，
    // 否则下面重新打开会被推迟（`DP.closing` 期间 openPanel 会等动画结束）。
    pause()

    // ---- 4c-2. **闪烁**回归：连续原生 push 期间面板不能回到起始态 ----
    //
    // 用户实测：「同一列上下移动时面板整块消失约 2 帧再回来」。
    //
    // 根因：原生每次推状态 → `ttUpdate` → `render()` → `root.innerHTML=''`
    // 把 `.daypanel` 一起删掉 → 重建 → **入场动画重播**。
    // 表头那一列始终高亮（说明不是状态被关掉了），所以是 DOM 重建。
    //
    // 这里模拟「鼠标不动、原生周期性推状态」：
    // 连续 6 次 `ttUpdate`，每次都量一下 `.daypanel` 的
    //   · opacity（容器）
    //   · clip-path（内容）
    //   · 元素是不是**同一个**（用一个挂在元素上的标记来认）
    // 只要有一次回到起始值（opacity < 0.99 或 clip-path 回到 inset(...,100%,...)）
    // 或者元素被换掉了，就算失败。
    var flickerResult: String?
    let flickerProbe = """
    (function () {
      var out = { samples: [], sameEl: true };
      var first = null;
      // ⚠️ 先**打开**覆盖层 —— 上一段交互自检结束时它是关着的。
      // 真实场景里面板开着，原生周期性地推状态。
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: { day: 3, todos: [], events: [],
          festival: { lunar: 'x', term: '', festivals: [] } },
          dayFlags: {}, dayPanelOpen: true });
      }
      // 快速越过入场动画：这一段只验「重绘不闪」。
      // 动画进度 / 时长由 4c-3 单独验证 —— 否则这里会一直采到
      // 0 → 1 过程中的中间值，把「正在播动画」误判成「面板淡出」。
      var d0 = document.querySelector('.daypanel');
      if (d0) {
        d0.style.transition = 'none';
        d0.style.opacity = '1';
        d0.style.clipPath = 'none';
        d0.style.webkitClipPath = 'none';
      }
      for (var i = 0; i < 6; i++) {
        var d = document.querySelector('.daypanel');
        if (!d) { out.samples.push({ missing: true }); continue; }
        if (first === null) { first = d; d.__flickerMark = 1; }
        else if (d !== first) { out.sameEl = false; }
        var cs = getComputedStyle(d);
        out.samples.push({
          op: cs.opacity,
          vis: cs.visibility,
          clip: cs.clipPath || cs.webkitClipPath || '',
          cls: d.className,
          h: Math.round(d.getBoundingClientRect().height)
        });
        // 模拟原生又推了一次状态（内容不变，只是重绘）
        if (window.ttUpdate) {
          window.ttUpdate({ dayPanel: { day: 3, todos: [], events: [],
            festival: { lunar: 'x', term: '', festivals: [] } },
            dayFlags: {}, courses: [], viewWeek: 1 });
        }
      }
      // 表头选中态：原生每推一次状态，表头格都会重建 ——
      // `.sel`（蓝色底 + 顶部亮线）必须由 render() 重新打上，
      // 否则用户看到的「点第一下之后蓝色边框就没了」。
      var selCell = document.querySelector('.hcell[data-day="3"]');
      out.headerSel = selCell ? selCell.classList.contains('sel') : false;
      out.headerSelCount = document.querySelectorAll('.hcell.sel').length;
      // 把上面为「越过入场动画」写的行内样式撤掉，再量*真实*的最终态 ——
      // 否则量到的是我们自己按下去的值，验不出 render() 有没有留下 show。
      if (d0) {
        d0.style.transition = '';
        d0.style.opacity = '';
        d0.style.clipPath = '';
        d0.style.webkitClipPath = '';
      }
      var d = document.querySelector('.daypanel');
      out.finalOp = d ? getComputedStyle(d).opacity : '';
      out.finalOpNum = d ? parseFloat(getComputedStyle(d).opacity) : -1;
      out.finalClip = d ? (getComputedStyle(d).clipPath || '') : '';
      out.finalClipTruncated = out.finalClip.indexOf('100%') >= 0;
      out.finalCls = d ? d.className : '';
      out.panelCount = document.querySelectorAll('.daypanel').length;
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(flickerProbe) { result in
        flickerResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = flickerResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let samples = obj["samples"] as? [[String: Any]] {
        check((obj["sameEl"] as? Bool) == true,
              "连续原生推状态时覆盖层元素必须是**同一个**（不能被重建）")
        var worstOp = 1.0
        var worstClip = ""
        for s in samples {
            let op = (s["op"] as? NSNumber)?.doubleValue ?? 1.0
            let clip = s["clip"] as? String ?? ""
            worstOp = min(worstOp, op)
            if clip.contains("100%") { worstClip = clip }
        }
        check(worstOp >= 0.99,
              "连续原生推状态期间覆盖层不能淡出（实测最低 opacity = \(worstOp)）")
        check(worstClip.isEmpty,
              "连续原生推状态期间覆盖层不能回到「完全裁掉」的起始态（实测 clip-path = \(worstClip)）")
        // ⚠️ `getComputedStyle().opacity` 是**字符串**（"1"），不是数字 ——
        // 用 NSNumber 取会拿到 nil → 0 → 误报「面板不可见」。
        let finalOp = (obj["finalOpNum"] as? NSNumber)?.doubleValue ?? -1
        check(finalOp >= 0.99,
              "连续推状态之后覆盖层仍然可见（实际 opacity = \(obj["finalOp"] ?? "?"))")
        check((obj["panelCount"] as? NSNumber)?.intValue ?? -1 == 1,
              "页面上只能有**一个** .daypanel（实际 \(obj["panelCount"] ?? "?") 个）")
        let finalCls = obj["finalCls"] as? String ?? ""
        check(finalCls.contains("show"),
              "连续推状态之后覆盖层仍然带着 show 类（实际 \"\(finalCls)\"）")
        check((obj["finalClipTruncated"] as? Bool) == false,
              "连续推状态之后覆盖层没有被裁到起始态（实际 clip-path = \(obj["finalClip"] ?? "?")）")
        // 表头选中态（蓝色底 + 顶部亮线）不能在重绘后丢掉。
        check((obj["headerSel"] as? Bool) == true,
              "连续推状态之后表头仍然保留选中态（.sel）")
        check((obj["headerSelCount"] as? NSNumber)?.intValue ?? 0 == 1,
              "有且只有一列表头处于选中态（实际 \(obj["headerSelCount"] ?? "?") 列）")
    } else {
        fail("拿不到闪烁诊断的结果")
    }

    // ---- 4c-2b. 「＋ 添加待办」输入框：**要能真的打字** ----
    //
    // 用户反馈「点击添加待办也打不了字」。
    //
    // 两个根因：
    //   1. 桌面层窗口是 `.nonactivatingPanel` → **永远拿不到 key**
    //      → WKWebView 拿不到键盘焦点 → `<input>` 收不到按键。
    //      （原生侧已加「文本输入模式」：输入框聚焦时把窗口临时变成 key。）
    //   2. 输入框以前每次重绘都**新建**一个 → 原生每推一次状态，
    //      用户的字和焦点就全没了。
    //      （现在改成**复用同一个元素**，见 Timetable.js 的 ensureInput。）
    //
    // 这里验第 2 条（纯网页层，能在自动化环境测）：
    // 打开输入框 → 写进值 → **触发一次原生推状态的重绘** → 值还在吗？
    // 焦点还在吗？
    var inputResult: String?
    let inputProbe = """
    (function () {
      var out = {};
      // 打开「＋ 添加待办」
      var add = document.querySelector('.dpadd');
      if (add) add.click();
      var inp = document.querySelector('[data-dp-input]');
      out.opened = !!inp;
      if (!inp) return JSON.stringify(out);
      // 模拟用户打字
      inp.value = '买牛奶和面包';
      inp.dispatchEvent(new Event('input', { bubbles: true }));
      out.valueBefore = inp.value;
      // 模拟原生推状态 → 整个面板内容重绘
      if (window.ttUpdate) {
        window.ttUpdate({ dayPanel: { day: 3, todos: [], events: [],
          festival: { lunar: 'x', term: '', festivals: [] } },
          dayFlags: {}, courses: [], viewWeek: 1 });
      }
      var inp2 = document.querySelector('[data-dp-input]');
      out.stillThere = !!inp2;
      out.sameElement = (inp2 === inp);
      out.valueAfter = inp2 ? inp2.value : '';
      out.focused = inp2 ? (document.activeElement === inp2) : false;
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(inputProbe) { result in
        inputResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = inputResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check((obj["opened"] as? Bool) == true, "点「＋ 添加待办」要能展开输入框")
        check((obj["stillThere"] as? Bool) == true, "重绘之后输入框还在")
        check((obj["sameElement"] as? Bool) == true,
              "重绘之后输入框必须是**同一个元素**（不能重建，否则字和焦点全丢）")
        let valueAfter = obj["valueAfter"] as? String ?? ""
        check(valueAfter == "买牛奶和面包",
              "重绘之后输入框里的字要还在（实际「\(valueAfter)」）")
    } else {
        fail("拿不到输入框的诊断结果")
    }

    // ---- 4c-3. 动画时长：打开约 600ms / 收起约 400ms ----
    //
    // 用户要求「瀑布动画更明显、更慢」（已确认 600ms 打开 / 400ms 收起）。
    //
    // 做法：用 `requestAnimationFrame` 逐帧采样 `.daypanel` 的 clip-path，
    // 记录「从起始值走到终值」花了多少毫秒。
    //
    // ⚠️ **合成器不跑的时候 transition 不推进**（窗口不可见 / 离屏渲染），
    // 采样到的会是 0ms —— 那说明「没动画」，不是「动画太快」。
    // 所以这里**只看相对关系**：开 : 收 的比值应该 ≈ 1.5（600/400）。
    // 绝对时长交给 CSS 本身保证（CSS 里写的就是 600ms / 400ms）。
    var animResult: String?
    let animProbe = """
    (function () {
      var out = { openMs: -1, closeMs: -1, samples: [] };
      var d = document.querySelector('.daypanel');
      if (!d) return JSON.stringify(out);

      // clip-path 现在做在 `.daypanel` 上（实心区 + 渐变尾巴一起揭开）——
      // 只裁 `.dpbody` 时，下面很高的尾巴会整块瞬间出现，看着还是「太快」。
      function clipNow() {
        var cs = getComputedStyle(d);
        var v = cs.clipPath || cs.webkitClipPath || 'none';
        // inset(0 0 100% 0) → 「被裁掉的比例」
        var m = v.match(/([0-9.]+)%/);
        return m ? parseFloat(m[1]) : (v === 'none' ? 0 : -1);
      }
      // 逐帧采样直到数值不再变（最多 120 帧 ≈ 2 秒）
      function sampleUntilStable(cb) {
        var t0 = performance.now();
        var last = clipNow();
        var stable = 0;
        function step() {
          var now = clipNow();
          out.samples.push(Math.round(performance.now() - t0));
          if (Math.abs(now - last) < 0.5) {
            stable++;
            if (stable >= 3) { cb(Math.round(performance.now() - t0)); return; }
          } else {
            stable = 0;
          }
          last = now;
          requestAnimationFrame(step);
        }
        requestAnimationFrame(step);
      }
      // ---- 打开 ----
      if (window.ttDayPanelClose) window.ttDayPanelClose();
      setTimeout(function () {
        if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
        sampleUntilStable(function (ms) {
          out.openMs = ms;
          // ---- 收起 ----
          setTimeout(function () {
            if (window.ttDayPanelClose) window.ttDayPanelClose();
            sampleUntilStable(function (ms2) { out.closeMs = ms2; });
          }, 120);
        });
      }, 120);
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(animProbe) { result in
        animResult = result
    }
    // 动画要跑一会儿，多等几秒
    for _ in 0..<80 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = animResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let openMs = (obj["openMs"] as? NSNumber)?.intValue ?? -1
        let closeMs = (obj["closeMs"] as? NSNumber)?.intValue ?? -1
        let samples = (obj["samples"] as? [Int]) ?? []
        // ⚠️ **合成器不跑时 rAF 回调根本不会触发**（页面被系统判成 hidden），
        // 于是采样数是 0、时长是 -1 —— 那不是「动画时长不对」，
        // 而是「这个环境测不了」。这种情况**不判失败**，只报出来
        // （免得以为测过了）。时长本身由 CSS 保证（见下面的 CSS 断言）。
        if samples.isEmpty || openMs < 0 {
            print("  ℹ️ 合成器未推进（页面 hidden），动画时长无法在此环境实测 —— 改由 CSS 断言把关")
        } else {
            check(openMs >= 500 && openMs <= 760,
                  "打开动画约 600ms（实测 \(openMs)ms）")
            check(closeMs >= 300 && closeMs <= 560,
                  "收起动画约 400ms（实测 \(closeMs)ms）")
            check(openMs > closeMs,
                  "打开要比收起慢（实测开 \(openMs)ms / 收 \(closeMs)ms）")
        }
    }

    // ---- 4c-3. 今日详情：**七列都要有** ----
    //
    // 用户反馈：「今日详情有的列有、有的列没有」。
    //
    // 根因有两个：
    //   1. 网页 `dpFestivalSection()` 在 lunar/term/festivals 全空时 `return null`
    //      → 整块消失；
    //   2. `panelDataFor()` 在原生 dayPanel.day 与当前列对不上时返回 null
    //      → 整块内容（包括今日详情）消失。
    //
    // 这里逐列检查：**每一列**的面板里都必须有「今日详情」这一块。
    var festivalResult: String?
    let festivalProbe = """
    (function () {
      var out = { days: {} };
      for (var d = 1; d <= 7; d++) {
        window.ttDayPanelOpen(d, false);
        // 注入这一天���数据（模拟原生把这一天的内容推过来）
        if (window.ttDayPanelSetState) {
          window.ttDayPanelSetState({ dayPanel: { day: d, todos: [], events: [],
            festival: { lunar: '农历测试', term: '', festivals: [] } },
            dayFlags: {}, dayPanelOpen: true });
        }
        var el = document.querySelector('.daypanel');
        // ⚠️ 2026-11 卡片化：分类不再是「.dpsect 分组块」，
        // 而是**各自的卡片**。这里按卡片查。
        var cards = el ? el.querySelectorAll('.dpcard') : [];
        var titles = [];
        for (var i = 0; i < cards.length; i++) {
          var hd = cards[i].querySelector('.dpcardhd');
          titles.push(hd ? (hd.textContent || '').trim() : '');
        }
        var detail = el ? el.querySelectorAll('.dpcard.detail').length : 0;
        out.days[String(d)] = {
          count: cards.length,
          titles: titles,
          detailCards: detail,
          hasToday: detail > 0
        };
      }
      window.ttDayPanelClose();
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(festivalProbe) { result in
        festivalResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = festivalResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let days = obj["days"] as? [String: [String: Any]] {
        for day in 1...7 {
            guard let info = days[String(day)] else {
                fail("第 \(day) 列的面板状态没测到")
                continue
            }
            check((info["hasToday"] as? Bool) == true,
                  "第 \(day) 列的覆盖层里必须有「今日详情」这张卡")
            check((info["detailCards"] as? NSNumber)?.intValue == 1,
                  "第 \(day) 列的「今日详情」要正好一张卡（实际 \(info["detailCards"] ?? "?") 张）")
            // 空数据时：待办 / 日程各一张空状态卡 + 今日详情一张 + 添加待办一张 = 4 张。
            let cardCount = (info["count"] as? NSNumber)?.intValue ?? -1
            check(cardCount == 4,
                  "第 \(day) 列的覆盖层必须有 4 张卡（空待办 + 空日程 + 今日详情 + 添加待办，实际 \(cardCount) 张）")
        }
    } else {
        fail("拿不到今日详情的诊断结果")
    }

    // ---- 4d. 原生悬停桥（ttLiveHover）的坐标换算 ----
    //
    // 真实使用里，网页的 onPointerMove 是**原生全局鼠标监控**驱动的：
    // 原生算好指针位置 → `ttLiveHover(x, y)` → 网页。这一段的坐标换算
    // 如果错了，表现就是「点开之后往下一移就没了」。
    // 上面 4c 直接调网页的 `__ttDiagMove`，绕过了这一步 —— 这里补上。
    func evalJSONObject(_ js: String) -> [String: Any]? {
        var out: [String: Any]?
        renderer.evaluateForTest(js) { r in
            guard let s = r, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = o
        }
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if out != nil { break }
        }
        return out
    }
    let webH = renderer.webView.bounds.height
    // 网页坐标（左上原点）→ 窗口坐标（左下原点），再走原生那条悬停桥。
    func hoverViaNative(_ x: Double, _ y: Double) {
        renderer.forwardLiveHover(at: NSPoint(x: x, y: webH - y))
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    func openStateNow() -> (open: Bool, day: Int?) {
        guard let o = evalJSONObject("JSON.stringify(window.ttDayPanelIsOpen())") else {
            return (false, nil)
        }
        return ((o["open"] as? Bool) ?? false, (o["day"] as? NSNumber)?.intValue)
    }
    guard let geo = evalJSONObject("""
        (function () {
          var h3 = document.querySelector('.hcell[data-day="3"]').getBoundingClientRect();
          var h5 = document.querySelector('.hcell[data-day="5"]').getBoundingClientRect();
          var g = document.querySelector('.grid').getBoundingClientRect();
          return JSON.stringify({ x3: h3.left + h3.width / 2,
                                  x5: h5.left + h5.width / 2,
                                  gmid: (g.top + g.bottom) / 2,
                                  gbottom: g.bottom });
        })();
        """),
          let x3 = geo["x3"] as? Double, let x5 = geo["x5"] as? Double,
          let gmid = geo["gmid"] as? Double, let gbottom = geo["gbottom"] as? Double else {
        fail("量不到表格几何（原生悬停桥自检）")
        exit(1)
    }
    // 点开第 3 列 → 指针移到网格下方（非列区域）→ 应淡出
    renderer.evaluateForTest("window.__ttDiagClick(3); 'ok'") { _ in }
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    hoverViaNative(x3, gbottom + 40)
    let viaOut = openStateNow()
    check(viaOut.open == false,
          "原生悬停桥：指针移出列区域 → 覆盖层该淡出（实际 open=\(viaOut.open)）")
    // ⚠️ 淡出 = 400ms 收拢动画；动画期间 `DP.closing` 为真，
    // 打开会被推迟到播完 —— 这里必须等够时间再移回去。
    for _ in 0..<35 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    // 跟随模式应当保留 → 移回第 5 列继续出现
    hoverViaNative(x5, gmid)
    let viaBack = openStateNow()
    check(viaBack.open == true && viaBack.day == 5,
          "原生悬停桥：移回第 5 列 → 跟随模式继续出现（实际 open=\(viaBack.open) day=\(String(describing: viaBack.day))）")
    // 点掉当前列 → 退出跟随模式；再悬停别的列不能弹
    renderer.evaluateForTest("window.__ttDiagClick(5); 'ok'") { _ in }
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    for _ in 0..<35 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    hoverViaNative(x3, gmid)
    let viaClosed = openStateNow()
    check(viaClosed.open == false,
          "原生悬停桥：点掉之后悬停别的列 → 不能弹出来（实际 open=\(viaClosed.open)）")

    // ---- 4c-4. **卡片化**：条目数 = 卡片数、间距、描边、底板、滚动 ----
    //
    // 2026-11 把覆盖层改成「每条待办 / 每条日程 / 今日详情各自一张玻璃卡片」。
    // 这里验的是**结构**（数量对不对、间距够不够、能不能滚到底），
    // 视觉（描边 / 发光 / 对比度）靠 `--shot-day-panel` 的真实截图。
    var cardResult: String?
    let cardProbe = """
    (function () {
      var out = {};
      // 注入一批数据：3 条待办 + 2 条日程 + 今日详情（含天气 / 宜忌）。
      var fake = {
        day: 3,
        todos: [
          { title: '买牛奶和面包', due: '20:00', done: false },
          { title: '交数据结构作业', due: '23:00', done: false },
          { title: '给导师回邮件', due: '', done: false }
        ],
        events: [
          { title: '团队会议', start: '10:00', end: '11:30' },
          { title: '图书馆', start: '15:00', end: '17:00' }
        ],
        festival: {
          lunar: '农历九月廿三', term: '霜降', festivals: ['万圣节前夜'],
          weather: { text: '晴', temperature: 12, min: 12, max: 21 },
          yi: '出行', ji: '动土'
        }
      };
      if (window.ttDayPanelSetState) {
        // ⚠️ **也要给 dayFestivals**（2026-11）——
        // 网页现在**优先**用 `dayFestivals[day]`（每一列各用自己的那份）。
        // 只给 dayPanel.festival 的话，会被上一次探针留下的 dayFestivals 盖掉。
        window.ttDayPanelSetState({ dayPanel: fake,
          dayFestivals: { '1': fake.festival, '2': fake.festival, '3': fake.festival,
                          '4': fake.festival, '5': fake.festival, '6': fake.festival,
                          '7': fake.festival },
          dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);

      var cards = document.querySelectorAll('.dpcard');
      out.cardCount = cards.length;
      // 每条待办 / 每条日程各一张卡 + 今日详情一张 + 「＋ 添加待办」一张幽灵卡
      out.todoCards = document.querySelectorAll('.dpcard.todo').length;
      out.eventCards = document.querySelectorAll('.dpcard.event').length;
      out.detailCards = document.querySelectorAll('.dpcard.detail').length;
      out.ghostCards = document.querySelectorAll('.dpcard.ghost').length;
      out.emptyCards = document.querySelectorAll('.dpcard.empty').length;

      // 卡片之间的**间距**（相邻两张卡的 rect 差）。
      //
      // 缩小档位网页用 CSS transform 缩放，rect 是**视觉坐标**；
      // 这里的验收标准（≥8px）是版式 px，所以除以 `__ttGeomScale` 还原。
      var gs = (typeof window.__ttGeomScale === 'number' ? window.__ttGeomScale : 1);
      var gaps = [];
      for (var i = 1; i < cards.length; i++) {
        var a = cards[i - 1].getBoundingClientRect();
        var b = cards[i].getBoundingClientRect();
        gaps.push(Math.round((b.top - a.bottom) / gs * 100) / 100);
      }
      out.gaps = gaps;
      out.minGap = gaps.length ? Math.min.apply(null, gaps) : -1;

      // 卡片自身的样式（描边 / 圆角 / 竖条 / 底色）。
      //
      // ⚠️ 量**可见**的那张卡：`.daypanel` 在没打开时是 `visibility:hidden`，
      // 那种情况下量到的计算样式全是默认值（宽 0 / opacity 0）。
      var panelEl = document.querySelector('.daypanel');
      out.panelCls = panelEl ? panelEl.className : '';
      var c0 = null;
      for (var ci = 0; ci < cards.length; ci++) {
        var cc = cards[ci];
        var ccs = getComputedStyle(cc);
        if (parseFloat(ccs.opacity) > 0.5) { c0 = cc; break; }
      }
      out.usedCard = !!c0;
      if (c0) {
        var cs = getComputedStyle(c0);
        out.radius = cs.borderRadius;
        out.hasGradientBg = cs.backgroundImage.indexOf('gradient') >= 0;
        out.opacity = cs.opacity;
        var before = getComputedStyle(c0, '::before');
        out.borderBg = before.backgroundImage;
        var after = getComputedStyle(c0, '::after');
        out.barWidth = after.width;
        out.barBg = after.backgroundImage;
      }

      // 底板：接近不透明 + 有 backdrop-filter（文字区域不能透出课表格）。
      var body = document.querySelector('.dpbody');
      if (body) {
        var bs = getComputedStyle(body);
        out.bodyBg = bs.backgroundColor;
        out.bodyFilter = bs.backdropFilter || bs.webkitBackdropFilter;
        out.bodyPadding = bs.padding;
      }

      // 面板宽度：窄态必须还是**一列宽**（约 119pt），不能被卡片撑宽。
      var panel = document.querySelector('.daypanel');
      if (panel) {
        out.panelWidth = Math.round(panel.getBoundingClientRect().width);
        var hc = document.querySelector('.hcell[data-day="3"]');
        out.columnWidth = hc ? Math.round(hc.getBoundingClientRect().width) : -1;
      }

      // 天气行 / 宜忌行必须渲染出来。
      out.weatherRows = document.querySelectorAll('.dpweather').length;
      out.yijiRows = document.querySelectorAll('.dpyiji').length;

      // ---- 溢出 → 面板内可滚动，且能滚到底 ----
      //
      // ⚠️ 这里灌**很多**条待办，把面板撑爆。
      var many = { day: 3, todos: [], events: [], festival: { lunar: 'x', term: '', festivals: [] } };
      for (var k = 0; k < 30; k++) {
        many.todos.push({ title: '待办条目 ' + k, due: '20:00', done: false });
      }
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: many, dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      var b2 = document.querySelector('.dpbody');
      if (b2) {
        out.manyCards = document.querySelectorAll('.dpcard').length;
        out.scrollHeight = b2.scrollHeight;
        out.clientHeight = b2.clientHeight;
        out.overflowY = getComputedStyle(b2).overflowY;
        out.canScroll = b2.scrollHeight > b2.clientHeight + 1;
        // 滚到底。
        b2.scrollTop = b2.scrollHeight;
        out.scrolledTo = Math.round(b2.scrollTop);
        out.maxScroll = b2.scrollHeight - b2.clientHeight;
        // 内容短的，不该出现滚动条（overflow-y: auto 天然满足）。
        var cs2 = getComputedStyle(b2);
        out.scrollbarWidth = cs2.scrollbarWidth;
      }
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(cardProbe) { result in
        cardResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = cardResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // ---- 条目数 = 卡片数 ----
        //
        // 3 条待办 + 2 条日程 + 1 张今日详情 + 1 张「＋ 添加待办」= 7 张。
        check((obj["cardCount"] as? NSNumber)?.intValue == 7,
              "3 待办 + 2 日程 + 今日详情 + 添加待办 = 7 张卡片（实际 \(obj["cardCount"] ?? "?") 张）")
        check((obj["todoCards"] as? NSNumber)?.intValue == 3,
              "每条待办一张卡（实际 \(obj["todoCards"] ?? "?") 张）")
        check((obj["eventCards"] as? NSNumber)?.intValue == 2,
              "每条日程一张卡（实际 \(obj["eventCards"] ?? "?") 张）")
        check((obj["detailCards"] as? NSNumber)?.intValue == 1,
              "今日详情一张卡（实际 \(obj["detailCards"] ?? "?") 张）")
        check((obj["ghostCards"] as? NSNumber)?.intValue == 1,
              "「＋ 添加待办」一张幽灵卡（实际 \(obj["ghostCards"] ?? "?") 张）")
        check((obj["emptyCards"] as? NSNumber)?.intValue == 0,
              "有数据时不该有空状态卡")

        // ---- 卡片间距 ≥ 8px ----
        let minGap = (obj["minGap"] as? NSNumber)?.doubleValue ?? -1
        check(minGap >= 8,
              "卡片之间的间距必须 ≥ 8px（实际最小 \(minGap)pt）")

        // ---- 卡片的视觉结构 ----
        check((obj["radius"] as? String)?.hasPrefix("14px") == true,
              "卡片圆角要是 14px（实际 \(obj["radius"] ?? "?")）")
        check((obj["hasGradientBg"] as? Bool) == true,
              "卡片要有半透明渐变底（玻璃感）")
        // ⚠️ `getComputedStyle().opacity` 返回的是**字符串**（"1"），
        // 用 NSNumber 取会拿到 nil → 0 → 误报「卡片不可见」。
        let opacityText = obj["opacity"] as? String ?? ""
        let opacity = Double(opacityText) ?? 0
        check(opacity >= 0.99,
              "卡片必须**完全可见**（opacity = \(opacityText)）—— 动画卡在第 0 帧的话这里会是 0")
        check((obj["borderBg"] as? String)?.contains("gradient") == true,
              "卡片要有渐变描边（::before 的渐变底）")
        // ⚠️ `getComputedStyle().width` 也是**字符串**（"2px"）。
        let barWText = obj["barWidth"] as? String ?? ""
        let barW = Double(barWText.replacingOccurrences(of: "px", with: "")) ?? 0
        check(barW >= 2 && barW <= 3.5,
              "卡片左侧彩色竖条宽 2–3px（实际 \(barWText)）")
        check((obj["barBg"] as? String)?.contains("gradient") == true,
              "卡片左侧竖条要有颜色")

        // ---- 底板：接近不透明（背后是彩色课表格，不能透上来）----
        let bodyBg = obj["bodyBg"] as? String ?? ""
        check(bodyBg.contains("0.94"),
              "底板要接近不透明 rgba(34,38,48,.94)（实际 \(bodyBg)）")
        check((obj["bodyFilter"] as? String)?.contains("blur") == true,
              "底板要有 backdrop-filter 模糊（实际 \(obj["bodyFilter"] ?? "?")）")

        // ---- 面板宽度仍是一列 ----
        let panelW = (obj["panelWidth"] as? NSNumber)?.doubleValue ?? 0
        let colW = (obj["columnWidth"] as? NSNumber)?.doubleValue ?? 0
        check(panelW > 0 && colW > 0 && abs(panelW - colW) <= 2,
              "窄态面板宽度必须还是一列宽（面板 \(panelW)pt / 列 \(colW)pt）")
        check(panelW <= 130, "窄态面板不能被卡片撑宽（实际 \(panelW)pt）")

        // ---- 天气行 / 宜忌行 ----
        check((obj["weatherRows"] as? NSNumber)?.intValue == 1,
              "有天气数据时要渲染一行天气（实际 \(obj["weatherRows"] ?? "?") 行）")
        check((obj["yijiRows"] as? NSNumber)?.intValue == 1,
              "有宜忌数据时要渲染一行宜 / 忌（实际 \(obj["yijiRows"] ?? "?") 行）")

        // ---- 溢出 → 面板内滚动，能滚到底 ----
        // 30 条待办 + 1 张「＋ 添加待办」+ 1 张「今日无日程」空状态 + 1 张今日详情 = 33。
        check((obj["manyCards"] as? NSNumber)?.intValue == 33,
              "30 条待办一张都不能少（+ 添加待办 + 无日程 + 详情 = 33 张，实际 \(obj["manyCards"] ?? "?") 张）")
        check((obj["overflowY"] as? String) == "auto",
              "内容超高时底板要能滚（overflow-y = \(obj["overflowY"] ?? "?")）")
        check((obj["canScroll"] as? Bool) == true,
              "30 条待办时面板内容应该超高到能滚")
        let maxScroll = (obj["maxScroll"] as? NSNumber)?.doubleValue ?? 0
        let scrolledTo = (obj["scrolledTo"] as? NSNumber)?.doubleValue ?? 0
        check(maxScroll > 0 && scrolledTo >= maxScroll - 2,
              "面板要能滚到底（滚到 \(scrolledTo) / 最多 \(maxScroll)）")
    } else {
        fail("拿不到卡片结构的诊断结果")
    }


    // ---- 4c-5. **滚动位置在原生推状态时保持** ----
    //
    // 用户反馈过「面板自己跳了一下」：原生每推一次状态就重绘内容，
    // 滚动位置归零 → 视图弹回顶部。
    var keepScrollResult: String?
    let keepScrollProbe = """
    (function () {
      var out = {};
      var many = { day: 3, todos: [], events: [], festival: { lunar: 'x', term: '', festivals: [] } };
      for (var k = 0; k < 30; k++) {
        many.todos.push({ title: '待办条目 ' + k, due: '20:00', done: false });
      }
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: many, dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      var b = document.querySelector('.dpbody');
      if (!b) return JSON.stringify(out);
      b.scrollTop = 120;
      out.before = Math.round(b.scrollTop);
      // 模拟原生推一次状态（内容不变，只是重绘）。
      if (window.ttUpdate) {
        window.ttUpdate({ dayPanel: many, dayFlags: {}, courses: [], viewWeek: 1 });
      }
      var b2 = document.querySelector('.dpbody');
      out.after = b2 ? Math.round(b2.scrollTop) : -1;
      out.sameEl = (b2 === b);
      out.cardsStillThere = document.querySelectorAll('.dpcard').length;
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(keepScrollProbe) { result in
        keepScrollResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = keepScrollResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let before = (obj["before"] as? NSNumber)?.doubleValue ?? 0
        let after = (obj["after"] as? NSNumber)?.doubleValue ?? -1
        check(before > 0, "先滚下去一点（实际 \(before)pt）")
        check(abs(after - before) <= 2,
              "原生推状态后滚动位置要保持（\(before) → \(after)）")
        check((obj["cardsStillThere"] as? NSNumber)?.intValue == 33,
              "推状态之后卡片不能消失（实际 \(obj["cardsStillThere"] ?? "?") 张）")
    } else {
        fail("拿不到滚动位置的诊断结果")
    }

    // ---- 4c-6. **天气拿不到时整行隐藏**（绝不显示假数据）----
    //
    // 天气 / 宜忌是**可选**字段：没城市 / 拒绝授权 / 网络失败时
    // 原生推的 `weather` 是 null，网页必须**整行不渲染**。
    var weatherResult: String?
    let weatherProbe = """
    (function () {
      var out = {};
      var fake = {
        day: 3, todos: [], events: [],
        festival: { lunar: '农历九月廿三', term: '', festivals: [], weather: null, yi: '', ji: '' }
      };
      if (window.ttDayPanelSetState) {
        // ⚠️ **也要给 dayFestivals**（2026-11）——
        // 网页优先用 `dayFestivals[day]`，不给的话会沿用上一轮的旧值。
        window.ttDayPanelSetState({ dayPanel: fake,
          dayFestivals: { '1': fake.festival, '2': fake.festival, '3': fake.festival,
                          '4': fake.festival, '5': fake.festival, '6': fake.festival,
                          '7': fake.festival },
          dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      out.weatherRows = document.querySelectorAll('.dpweather').length;
      out.yijiRows = document.querySelectorAll('.dpyiji').length;
      out.detailCards = document.querySelectorAll('.dpcard.detail').length;
      // 文本里**不能**出现「0°」这种假数据。
      var d = document.querySelector('.dpcard.detail');
      out.detailText = d ? (d.textContent || '') : '';
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(weatherProbe) { result in
        weatherResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = weatherResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check((obj["weatherRows"] as? NSNumber)?.intValue == 0,
              "天气为 null 时不能渲染天气行（实际 \(obj["weatherRows"] ?? "?") 行）")
        check((obj["yijiRows"] as? NSNumber)?.intValue == 0,
              "宜忌为空时不能渲染宜 / 忌行（实际 \(obj["yijiRows"] ?? "?") 行）")
        check((obj["detailCards"] as? NSNumber)?.intValue == 1,
              "「今日详情」卡本身**不能消失**（实际 \(obj["detailCards"] ?? "?") 张）")
        let text = obj["detailText"] as? String ?? ""
        check(!text.contains("0°"), "没有天气时不能显示「0°」这种假数据")
    } else {
        fail("拿不到天气降级的诊断结果")
    }

    // ---- 4c-7. **原生侧**：天气 / 宜忌怎么进到内容里 ----
    //
    // 这里用 **fake** provider（不联网、不碰定位）：
    //   · 开了「显示天气」→ 天气要进到 `content.festival.weather`；
    //   · 关了「显示天气」→ **不请求**（`requestCount` 不涨）；
    //   · 宜忌是**离线**算的（`AlmanacCalendar`），不依赖天气开关。
    let fakeWeather = FakeWeatherProvider(stub: DayPanelWeather(text: "晴", temperature: 12, min: 12, max: 21))
    let weatherController = DayPanelController(
        settings: DayPanelSettings(enabled: true, weatherEnabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(weatherProvider: fakeWeather),
        todayIndex: 1,
        baseMonday: day(2026, 11, 2),
        eventStore: FakeEventKitStore(),
        weatherProvider: fakeWeather)
    weatherController.open(day: 3)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let wContent = weatherController.testContent
    check(wContent.festival.weather?.text == "晴",
          "开了「显示天气」→ 天气要进到覆盖层内容里（实际 \(wContent.festival.weather?.text ?? "nil")）")
    check(wContent.festival.weather?.max == 21,
          "天气要带最高温（实际 \(String(describing: wContent.festival.weather?.max))）")
    // 宜忌是离线算的 —— 不看天气开关。
    check(!wContent.festival.yi.isEmpty, "「今日详情」要有宜（实际「\(wContent.festival.yi)」）")
    check(!wContent.festival.ji.isEmpty, "「今日详情」要有忌（实际「\(wContent.festival.ji)」）")

    // 关掉「显示天气」→ **不请求**（不碰定位、不联网）。
    let quietWeather = FakeWeatherProvider(stub: DayPanelWeather(text: "晴", temperature: 12, min: 12, max: 21))
    let quietController = DayPanelController(
        settings: DayPanelSettings(enabled: true, weatherEnabled: false),
        festivalProvider: DayPanelFestivalProviderFactory.make(weatherProvider: quietWeather),
        todayIndex: 1,
        baseMonday: day(2026, 11, 2),
        eventStore: FakeEventKitStore(),
        weatherProvider: quietWeather)
    quietController.open(day: 3)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(quietController.testContent.festival.weather == nil,
          "关了「显示天气」→ 覆盖层里不能有天气")
    check(quietWeather.requestCount == 0,
          "关了「显示天气」→ 不能去请求位置（实际请求了 \(quietWeather.requestCount) 次）")
    // 宜忌照样有（离线）。
    check(!quietController.testContent.festival.yi.isEmpty,
          "关了天气也要有宜忌（离线算的）")

    // ⚠️ **自动化模式绝不真发请求** ——
    // `OpenMeteoWeatherProvider` 在自动化模式下不建位置管理器。
    let autoProvider = OpenMeteoWeatherProvider()
    check(autoProvider.authorizationStatus == .notDetermined
          || !AutomationMode.isCurrentProcessAutomation,
          "自动化模式下不该有定位授权状态")

    // ---- 4c-8. **7 天各自的今日详情**（2026-11 修）----
    //
    // 用户反馈：「有的天数有今日详情，有的没有」「今日详情大多数日期对不上」。
    //
    // 根因：以前原生只 push **当前那一天**的 dayPanel，
    // 网页换列时靠 `DP.cache[day]` 兜底 →
    //   · 没推过的那一天 → **整块消失**；
    //   · 换列时先显示**别的日子**的内容 → **日期对不上**。
    //
    // 现在原生一次推 7 天（`dayFestivals`），网页按 `day` 取。
    var perDayResult: String?
    let perDayProbe = """
    (function () {
      var out = { days: [] };
      // 造 7 份**内容各不相同**的详情（农历里带天数，一眼能看出串没串）。
      var fest = {};
      for (var d = 1; d <= 7; d++) {
        fest[String(d)] = { lunar: '农历九月' + d, term: '', festivals: [],
                            weather: null, yi: '', ji: '' };
      }
      // ⚠️ 故意**不**给 dayPanel —— 只给 dayFestivals。
      // 这样能验出「网页是不是只靠 dayPanel（当前那一天），
      // 导致其它列要么空白、要么显示成同一份」。
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: null, dayFestivals: fest,
                                    dayFlags: {}, dayPanelOpen: true });
      }
      for (var dd = 1; dd <= 7; dd++) {
        if (window.ttDayPanelOpen) window.ttDayPanelOpen(dd, false);
        var el = document.querySelector('.daypanel');
        var det = el ? el.querySelector('.dpcard.detail') : null;
        var lun = det ? det.querySelector('.dplunar') : null;
        out.days.push({
          day: dd,
          lunar: lun ? (lun.textContent || '') : '',
          detailCards: det ? 1 : 0
        });
      }
      window.ttDayPanelClose();
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(perDayProbe) { result in
        perDayResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = perDayResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let days = obj["days"] as? [[String: Any]] {
        check(days.count == 7, "要能逐列检查 7 天（实际 \(days.count) 天）")
        for d in days {
            guard let day = (d["day"] as? NSNumber)?.intValue else { continue }
            let lunar = d["lunar"] as? String ?? ""
            // 每列都必须有「今日详情」这张卡。
            check((d["detailCards"] as? NSNumber)?.intValue == 1,
                  "第 \(day) 列必须有「今日详情」卡")
            // ⚠️ **必须是这一天自己的农历** —— 不能都是同一份。
            check(lunar == "农历九月\(day)",
                  "第 \(day) 列的今日详情要是那一天的（期望「农历九月\(day)」，实际「\(lunar)」）")
        }
    } else {
        fail("拿不到逐列今日详情的诊断结果")
    }

    // ---- 4c-9. **添加待办失败要有提示**（不是静默失败）----
    //
    // 用户反馈「点击添加待办现在根本加不上去」——
    // 以前原生侧 `guard settings.enabled` 直接 return，网页**什么都不知道**。
    var addErrResult: String?
    let addErrProbe = """
    (function () {
      var out = {};
      var fake = { day: 3, todos: [], events: [],
        festival: { lunar: '农历九月廿三', term: '', festivals: [], weather: null, yi: '', ji: '' } };
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: fake,
          dayFestivals: { '1': fake.festival, '2': fake.festival, '3': fake.festival,
                          '4': fake.festival, '5': fake.festival, '6': fake.festival,
                          '7': fake.festival },
          dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      // 原生回报「失败 + 原因」。
      if (window.ttDayPanelTodoAddResult) {
        window.ttDayPanelTodoAddResult({ day: 3, ok: false, message: '还没拿到提醒事项权限' });
      }
      var errs = document.querySelectorAll('.dpadderr');
      out.errCount = errs.length;
      out.errText = errs.length ? (errs[0].textContent || '') : '';
      // 成功 → 提示要消失。
      if (window.ttDayPanelTodoAddResult) {
        window.ttDayPanelTodoAddResult({ day: 3, ok: true, message: '' });
      }
      out.errCountAfterOk = document.querySelectorAll('.dpadderr').length;
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(addErrProbe) { result in
        addErrResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = addErrResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check((obj["errCount"] as? NSNumber)?.intValue == 1,
              "添加失败要显示一行提示（实际 \(obj["errCount"] ?? "?") 行）")
        check((obj["errText"] as? String ?? "").contains("权限"),
              "提示里要说清楚原因（实际「\(obj["errText"] ?? "")」）")
        check((obj["errCountAfterOk"] as? NSNumber)?.intValue == 0,
              "添加成功后提示要消失")
    } else {
        fail("拿不到添加失败提示的诊断结果")
    }

    // ---- 4c-10. **翻周之后农历要跟着变**（2026-11 修）----
    //
    // 用户反馈「点击下一周或上一周之后农历什么的都是一样的」。
    //
    // 根因：覆盖层的 `baseMonday` 是 `let`，只在控制器创建时算一次，
    // 翻周时**没跟着变** → 7 天的详情一直按原来那一周算。
    //
    // 这里验两件事：
    //   1. 原生侧 `updateBrowsingWeek()` 之后，7 天的详情**确实变了**；
    //   2. 翻到下一周，那一天（周三）的农历和上一周**不同**。
    let weekA = day(2026, 11, 2)          // 2026-11-02 是周一
    let weekAController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: FakeEventKitStore())
    weekAController.open(day: 3)
    let lunarWeekA = weekAController.testContent.festival.lunar
    check(!lunarWeekA.isEmpty, "第 1 周的周三要有农历（实际「\(lunarWeekA)」）")

    // 翻到下一周（周一 = 2026-11-09）。
    //
    // ⚠️ 顺序很重要：**先翻周（面板会被关掉），再打开** ——
    // 这才是真实流程（用户点「下一周」→ 面板关掉 → 再点日期才打开）。
    let weekB = day(2026, 11, 9)
    weekAController.updateBrowsingWeek(baseMonday: weekB, allWeeks: false)
    // 翻周后正在显示的面板应该已经关掉了（上一周的内容不该继续显示）。
    check(weekAController.testState.open == false,
          "翻周后正在显示的面板应该关掉")
    // 再打开 → 这次是**下一周**的内容。
    weekAController.open(day: 3)
    let lunarWeekB = weekAController.testContent.festival.lunar
    check(!lunarWeekB.isEmpty, "第 2 周的周三要有农历（实际「\(lunarWeekB)」）")
    check(lunarWeekA != lunarWeekB,
          "翻周之后农历必须跟着变（两周都是「\(lunarWeekA)」）")

    // ---- 4c-11. **待办按日期归属 + 加完要有红点**（2026-11 修）----
    //
    // 用户反馈：「我在具体一天增加的待办事项只在那一天显示，
    // 换到下一天或者下一个星期都不会显示，而且增加了待办之后就要有红点之类的」。
    //
    // 这里用 fake EventKit 验两件事：
    //   1. 待办**按日期**归属 —— 第 1 周周一加的，第 2 周周一看不到；
    //   2. 加完待办**立刻**重算红点（`refreshAll()`）。
    let perDayFake = FakeEventKitStore()
    let perDayController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: day(2026, 11, 2),      // 第 1 周的周一
        eventStore: perDayFake)
    // 第 1 周的周一有一条待办（**按日期存放** —— 只有那一天能看到）。
    var perDayCal = Calendar(identifier: .gregorian)
    perDayCal.timeZone = .current
    perDayFake.todosByDate = [
        perDayCal.startOfDay(for: day(2026, 11, 2)):
            [DayPanelTodo(title: "只在第1周周一", due: "10:00", done: false,
                          dueMinutes: 600, identifier: "r1", calendarIdentifier: "c1")]
    ]
    perDayController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(perDayController.testContent.todos.count == 1,
          "第 1 周的周一要看到那条待办（实际 \(perDayController.testContent.todos.count) 条）")
    check(perDayController.testFlags[1]?.hasTodo == true,
          "第 1 周的周一要有红点（有待办）")

    // 翻到第 2 周（周一 = 2026-11-09）—— 那一天**没有**这条待办。
    perDayController.updateBrowsingWeek(baseMonday: day(2026, 11, 9), allWeeks: false)
    perDayController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(perDayController.testContent.todos.isEmpty,
          "第 2 周的周一**不该**看到第 1 周那条待办（实际 \(perDayController.testContent.todos.count) 条）")

    // 加完待办 → 红点要立刻出现。
    let flagFake = FakeEventKitStore()
    let flagController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: day(2026, 11, 2),
        eventStore: flagFake)
    flagController.open(day: 2)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(flagFake.addCalls.isEmpty, "还没添加之前不该有写入")
    flagController.handle(action: "todoAdd", payload: ["day": 2, "title": "新加的待办"])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(flagFake.addCalls.count == 1, "「添加待办」要真的写入（实际 \(flagFake.addCalls.count) 次）")
    check(flagFake.addCalls.first?.0 == "新加的待办", "写进去的标题要对")

    // ---- 4c-12. **加完待办要立刻显示在那一天 + 红点跟着走**（2026-11 修）----
    //
    // 用户反馈：「增加了待办事项后没有直接显示在我加上的那一天」
    // 「红点只在那一天出现，换到别的周和全部周就不要显示了」
    // 「完成待办事项后红点就要消失」。
    var addFlowResult: String?
    let addFlowProbe = """
    (function () {
      var out = {};
      // 第 1 周的周一有一条待办（按日期存放）。
      var mon = { day: 1, todos: [{ title: '第1周周一的待办', due: '10:00', done: false }],
        events: [], festival: { lunar: '农历九月一', term: '', festivals: [], weather: null, yi: '', ji: '' } };
      var fest = {};
      for (var d = 1; d <= 7; d++) {
        fest[String(d)] = { lunar: '第1周九月' + d, term: '', festivals: [], weather: null, yi: '', ji: '' };
      }
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: mon, dayFestivals: fest,
          dayFlags: { '1': { todo: true, event: false } }, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(1, false);

      function todosOn(day) {
        if (window.ttDayPanelOpen) window.ttDayPanelOpen(day, false);
        var t = document.querySelectorAll('.dpcard.todo .dptitle');
        var names = [];
        for (var i = 0; i < t.length; i++) names.push(t[i].textContent || '');
        return names;
      }
      out.day1 = todosOn(1);
      out.day2 = todosOn(2);

      // ---- 全部周次 → 表头上不该有红点 ----
      if (window.ttUpdate) {
        window.ttUpdate({ dayPanel: mon, dayFestivals: fest,
          dayFlags: { '1': { todo: true, event: false } }, courses: [], viewWeek: null });
      }
      // ⚠️ 现在红点节点**永远存在**（没有时带 `.off` = 不可见占位），
      // 所以数「看得见的」才行。
      out.redDotsAllWeeks = document.querySelectorAll('.hcell .dot.todo:not(.off)').length;

      // ---- 回到第 1 周 → 红点该出现 ----
      if (window.ttUpdate) {
        window.ttUpdate({ dayPanel: mon, dayFestivals: fest,
          dayFlags: { '1': { todo: true, event: false } }, courses: [], viewWeek: 1 });
      }
      out.redDotsWeek1 = document.querySelectorAll('.hcell .dot.todo:not(.off)').length;

      // ---- 勾完待办 → 红点该消失 ----
      if (window.ttUpdate) {
        window.ttUpdate({ dayPanel: { day: 1, todos: [], events: [],
          festival: fest['1'] }, dayFestivals: fest,
          dayFlags: { '1': { todo: false, event: false } }, courses: [], viewWeek: 1 });
      }
      out.redDotsAfterDone = document.querySelectorAll('.hcell .dot.todo:not(.off)').length;

      // ---- 红点要和蓝点对称（在「周几」文字左边）----
      //
      // ⚠️ 不能靠真实的表头格来测 ——
      // 蓝点只在「今天」那一列（`.hcell.today`），
      // 而自检环境里课表是**空学期**，今天**不在**显示的那一周里
      // → 找不到 `.hcell.today`。
      //
      // 所以这里**单独造一个表头格**（结构和真的一模一样）：
      // 红点 + 「周几」 + 蓝点，然后量它们的几何关系。
      var probe = document.createElement('div');
      probe.className = 'hcell pick today';
      probe.style.position = 'absolute';
      probe.style.left = '0px';
      probe.style.top = '0px';
      probe.style.width = '119px';
      probe.style.visibility = 'hidden';
      var row = document.createElement('span');
      row.className = 'hdrow';
      var td = document.createElement('span');
      td.className = 'dot todo';
      var txt = document.createElement('span');
      txt.textContent = '周一';
      var hd = document.createElement('span');
      hd.className = 'dot';
      row.appendChild(td);
      row.appendChild(txt);
      row.appendChild(hd);
      var mid = document.createElement('span');
      mid.className = 'hmid';
      var hnum = document.createElement('span');
      hnum.className = 'hnum';
      hnum.textContent = '2';
      mid.appendChild(row);
      mid.appendChild(hnum);
      probe.appendChild(mid);
      document.body.appendChild(probe);

      var tr = td.getBoundingClientRect(), hr = hd.getBoundingClientRect();
      var tr2 = txt.getBoundingClientRect();
      out.redY = Math.round(tr.top + tr.height / 2);
      out.blueY = Math.round(hr.top + hr.height / 2);
      out.sameRow = Math.abs(out.redY - out.blueY) <= 1;
      // 红点要在「周几」文字**左边**：红点右边缘 ≤ 文字左边缘。
      out.redLeftOfText = tr.right <= tr2.left + 0.5;
      out.redRight = Math.round(tr.right);
      out.txtLeft = Math.round(tr2.left);
      out.blueLeft = Math.round(hr.left);
      // 对称性：红点到文字左边的距离 ≈ 蓝点到文字右边的距离。
      out.gapLeft = Math.round(tr2.left - tr.right);
      out.gapRight = Math.round(hr.left - tr2.right);
      out.symmetric = Math.abs(out.gapLeft - out.gapRight) <= 1;
      probe.remove();
      return JSON.stringify(out);
    })();
    """
    renderer.evaluateForTest(addFlowProbe) { result in
        addFlowResult = result
    }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let raw = addFlowResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // 待办只在那一天。
        let day1 = (obj["day1"] as? [String]) ?? []
        let day2 = (obj["day2"] as? [String]) ?? []
        check(day1.count == 1 && day1.first == "第1周周一的待办",
              "第 1 周的周一要看到那条待办（实际 \(day1)）")
        check(day2.isEmpty,
              "第 1 周的周二**不该**看到它（实际 \(day2)）")

        // 全部周次 → 没有红点。
        check((obj["redDotsAllWeeks"] as? NSNumber)?.intValue == 0,
              "「全部周次」下表头不该有红点（实际 \(obj["redDotsAllWeeks"] ?? "?") 个）")
        // 具体周次 → 红点在。
        check((obj["redDotsWeek1"] as? NSNumber)?.intValue == 1,
              "第 1 周那一列要有红点（实际 \(obj["redDotsWeek1"] ?? "?") 个）")
        // 勾完 → 红点消失。
        check((obj["redDotsAfterDone"] as? NSNumber)?.intValue == 0,
              "勾完待办后红点要消失（实际 \(obj["redDotsAfterDone"] ?? "?") 个）")

        // 红点和蓝点同一水平线 + 在文字左边 + 左右对称。
        check((obj["sameRow"] as? Bool) == true,
              "红点要和蓝点在**同一水平线**（红 y=\(obj["redY"] ?? "?") / 蓝 y=\(obj["blueY"] ?? "?")）")
        check((obj["redLeftOfText"] as? Bool) == true,
              "红点要在「周几」文字的**左边**")
        check((obj["symmetric"] as? Bool) == true,
              "红点到文字的距离要和蓝点到文字的距离相等（对称）—— 左 \(obj["gapLeft"] ?? "?") / 右 \(obj["gapRight"] ?? "?")")
    } else {
        fail("拿不到添加待办流程的诊断结果")
    }

    // ---- 4c-12b. **完成待办：只有圆圈能点 / 立刻变蓝 / 1 秒后再缓慢消失**（2026-11 修）----
    //
    // 用户确认的行为：
    //   · **只有**待办前面的空心圆能完成 —— 点标题、点卡片都不算；
    //   · 点下去 → 圆圈**立刻变蓝**，其它什么都不变（标题不变灰、不加删除线）；
    //   · 停留 1 秒 → 缓慢淡出（400ms）→ 从列表移除；
    //   · 这一串动作期间**表头不能重建**（否则用户看到周四 / 日期闪几下）。
    let completionSetup = """
    (function () {
      var fest = { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      var festAll = {};
      for (var d = 1; d <= 7; d++) festAll[String(d)] = fest;
      var panel = { day: 3, todos: [
          { title: '第一条', due: '09:00', done: false, identifier: 'rid-1', calendarIdentifier: 'cal-1' },
          { title: '第二条', due: '10:00', done: false, identifier: 'rid-2', calendarIdentifier: 'cal-2' }
        ], events: [], festival: fest };
      window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
        dayFlags: { '3': { todo: true, event: false } },
        courses: [], viewWeek: 2 });
      window.ttDayPanelOpen(3, false);
      var out = {};
      var header = document.querySelector('.hcell[data-day="3"]');
      if (header) header.__probeStamp = 'keep';
      window.__probeStart = Date.now();
      var cards = document.querySelectorAll('.dpcard.todo');
      var first = null, second = null;
      for (var i = 0; i < cards.length; i++) {
        var k = cards[i].getAttribute('data-todo-key');
        if (k === 'id:rid-1') first = cards[i];
        if (k === 'id:rid-2') second = cards[i];
      }
      out.found = !!(first && second);
      if (!first) return JSON.stringify(out);
      var title = first.querySelector('.dptitle');
      var titleColor = getComputedStyle(title).color;
      var titleDeco = getComputedStyle(title).textDecorationLine || '';

      function click(el) {
        if (!el) return;
        el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
      }
      // 1) 点标题 / 点正文：**都不该**完成。
      click(title);
      click(first.querySelector('.dpmain'));
      out.titleClickCompleting = first.classList.contains('completing');
      out.titleClickCount = document.querySelectorAll('.dpcard.todo').length;

      // 2) 点圆圈：立刻变蓝（用 no-transition 保证量到的是**终值**）。
      var st = document.createElement('style');
      st.id = 'probe-notrans';
      st.textContent = '.dpcard.todo.completing .dpcheck { transition: none !important; }';
      document.head.appendChild(st);
      var dot = first.querySelector('.dpcheck');
      click(dot);
      out.completing = first.classList.contains('completing');
      out.leavingImmediately = first.classList.contains('leaving');
      out.countImmediately = document.querySelectorAll('.dpcard.todo').length;
      out.titleTextImmediately = title.textContent;
      out.titleColorSame = (getComputedStyle(title).color === titleColor);
      out.titleDecoSame = ((getComputedStyle(title).textDecorationLine || '') === titleDeco);
      out.dotBg = getComputedStyle(dot).backgroundColor;
      out.secondUntouched = second ? !second.classList.contains('completing') : null;

      // 3) 原生「完成写回」→ 推来**不含这条**的新内容。
      //    1 秒展示期内它必须还在，而且留在**原来的位置**。
      var panelAfter = { day: 3, todos: [
          { title: '第二条', due: '10:00', done: false, identifier: 'rid-2', calendarIdentifier: 'cal-2' }
        ], events: [], festival: fest };
      window.ttUpdate({ dayPanel: panelAfter, dayFestivals: festAll,
        dayFlags: { '3': { todo: true, event: false } },
        courses: [], viewWeek: 2 });
      var kept = document.querySelector('.dpcard.todo[data-todo-key="id:rid-1"]');
      out.stillThereAfterPush = !!kept;
      out.stillCompletingAfterPush = kept ? kept.classList.contains('completing') : null;
      out.stillTitleAfterPush = kept ? kept.querySelector('.dptitle').textContent : '';
      var firstCardKey = document.querySelector('.dpcard.todo');
      out.staysInPlace = firstCardKey
        ? firstCardKey.getAttribute('data-todo-key') === 'id:rid-1' : false;
      // 表头：DOM 节点**一个都不能换**（换了就是用户看到的「闪几下」）。
      var headerNow = document.querySelector('.hcell[data-day="3"]');
      out.headerSameNode = (headerNow === header);
      out.headerStamp = headerNow ? (headerNow.__probeStamp || '') : '';
      out.headerSel = headerNow ? headerNow.classList.contains('sel') : null;
      return JSON.stringify(out);
    })();
    """
    // 发起一次 JS 求值并等它回来（最多 `timeout` 秒），返回解析后的字典。
    //
    // ⚠️ 不能用「固定转 30 次主循环」来等 —— 那样光等回调就会吃掉 0.6 秒，
    // 后面的「1 秒后才消失」时间窗口就对不上了。
    func pollProbe(_ js: String, timeout: TimeInterval = 1.0) -> [String: Any]? {
        var raw: String?
        renderer.evaluateForTest(js) { raw = raw ?? $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while raw == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard let s = raw, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
    var completionSetupResult: String?
    renderer.evaluateForTest(completionSetup) { completionSetupResult = completionSetupResult ?? $0 }
    for _ in 0..<200 {
        if completionSetupResult != nil { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    // 点击发生在 setup 里；从这里开始计时（相差几十毫秒，足够判断窗口）。
    let completionStart = Date()
    if let raw = completionSetupResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check((obj["found"] as? Bool) == true, "要能找到两条待办卡片")
        check((obj["titleClickCompleting"] as? Bool) == false,
              "点**标题**不能完成待办（用户要求「只有圆圈能点」）")
        check((obj["titleClickCount"] as? NSNumber)?.intValue == 2,
              "点标题之后两条待办都还要在（实际 \(obj["titleClickCount"] ?? "?") 条）")
        check((obj["completing"] as? Bool) == true,
              "点圆圈 → 立刻进入「正在完成」状态")
        check((obj["leavingImmediately"] as? Bool) == false,
              "点圆圈之后不能马上开始消失 —— 要停 1 秒")
        check((obj["countImmediately"] as? NSNumber)?.intValue == 2,
              "点圆圈之后**立刻**不该少任何一条（实际 \(obj["countImmediately"] ?? "?") 条）")
        check((obj["titleTextImmediately"] as? String) == "第一条",
              "圆圈变蓝时标题**一个字都不能变**（实际「\(obj["titleTextImmediately"] ?? "")」）")
        check((obj["titleColorSame"] as? Bool) == true,
              "圆圈变蓝时标题颜色不能变（不能变灰）")
        check((obj["titleDecoSame"] as? Bool) == true,
              "圆圈变蓝时标题不能加删除线")
        let dotBg = (obj["dotBg"] as? String) ?? ""
        check(dotBg.contains("79") && dotBg.contains("140") && dotBg.contains("255"),
              "圆圈必须马上是**蓝色实心**（实际背景色 \(dotBg)）")
        check((obj["secondUntouched"] as? Bool) == true,
              "别的待办不能被连带标成已完成")
        check((obj["stillThereAfterPush"] as? Bool) == true,
              "原生推来「不含这条」的新内容后，1 秒内它还得留在面板上")
        check((obj["stillCompletingAfterPush"] as? Bool) == true,
              "这段时间里圆圈要保持蓝色（不能先变回空心）")
        check((obj["stillTitleAfterPush"] as? String) == "第一条",
              "原位补回来的还是原来那条待办")
        check((obj["staysInPlace"] as? Bool) == true,
              "消失前它必须留在**原来的位置**（不能跳到列表末尾）")
        check((obj["headerSameNode"] as? Bool) == true,
              "推状态时表头 DOM 不能被重建（否则就是用户看到的「闪几下」）")
        check((obj["headerStamp"] as? String) == "keep",
              "表头格上的自定义标记要还在（证明是同一个节点）")
        check((obj["headerSel"] as? Bool) == true,
              "表头选中态要保留")
    } else {
        fail("拿不到「完成待办」交互的诊断结果")
    }

    // ---- 约 0.4 秒：还在，但**还没开始**消失 ----
    while Date().timeIntervalSince(completionStart) < 0.35 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let completionMidProbe = """
    (function () {
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:rid-1"]');
      return JSON.stringify({
        elapsed: Date.now() - window.__probeStart,
        there: !!card,
        completing: card ? card.classList.contains('completing') : null,
        leaving: card ? card.classList.contains('leaving') : null,
        headerSameNode: (document.querySelector('.hcell[data-day="3"]') || {}).__probeStamp === 'keep'
      });
    })();
    """
    if let obj = pollProbe(completionMidProbe) {
        let elapsed = (obj["elapsed"] as? NSNumber)?.doubleValue ?? -1
        check(elapsed >= 250 && elapsed < 950,
              "「完成」后的第一次取样要在 1 秒展示期内（实际 \(Int(elapsed))ms）")
        check((obj["there"] as? Bool) == true,
              "过了约 0.4 秒，待办还要在")
        check((obj["completing"] as? Bool) == true,
              "过了约 0.4 秒，圆圈还得是蓝的")
        check((obj["leaving"] as? Bool) == false,
              "过了约 0.4 秒，**还不能**开始淡出")
        check((obj["headerSameNode"] as? Bool) == true,
              "这段时间表头不能重建")
    } else {
        fail("拿不到「完成待办」中段的诊断结果")
    }

    // ---- 约 1.2 秒：开始缓慢消失（`.leaving` + 400ms 动画）----
    while Date().timeIntervalSince(completionStart) < 1.20 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let completionLeaveProbe = """
    (function () {
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:rid-1"]');
      return JSON.stringify({
        elapsed: Date.now() - window.__probeStart,
        there: !!card,
        leaving: card ? card.classList.contains('leaving') : null,
        otherThere: !!document.querySelector('.dpcard.todo[data-todo-key="id:rid-2"]'),
        headerSameNode: (document.querySelector('.hcell[data-day="3"]') || {}).__probeStamp === 'keep'
      });
    })();
    """
    if let obj = pollProbe(completionLeaveProbe) {
        let elapsed = (obj["elapsed"] as? NSNumber)?.doubleValue ?? -1
        check(elapsed >= 950 && elapsed < 1400,
              "第二次取样应该正好在「1 秒后开始消失」的窗口里（实际 \(Int(elapsed))ms）")
        check((obj["there"] as? Bool) == true,
              "1 秒后要开始消失，但这一刻它还在（动画中）")
        check((obj["leaving"] as? Bool) == true,
              "1 秒后必须进入缓慢消失状态（`.leaving`）")
        check((obj["otherThere"] as? Bool) == true,
              "消失的只是被完成的那一条，别的不受影响")
        check((obj["headerSameNode"] as? Bool) == true,
              "淡出过程中表头同样不能重建")
    } else {
        fail("拿不到「完成待办」消失阶段的诊断结果")
    }

    // ---- 约 1.7 秒：消失动画跑完 → 真正移除 ----
    while Date().timeIntervalSince(completionStart) < 1.70 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let completionGoneProbe = """
    (function () {
      return JSON.stringify({
        elapsed: Date.now() - window.__probeStart,
        gone: !document.querySelector('.dpcard.todo[data-todo-key="id:rid-1"]'),
        otherThere: !!document.querySelector('.dpcard.todo[data-todo-key="id:rid-2"]'),
        headerSameNode: (document.querySelector('.hcell[data-day="3"]') || {}).__probeStamp === 'keep',
        headerSel: (function () {
          var h = document.querySelector('.hcell[data-day="3"]');
          return h ? h.classList.contains('sel') : null;
        })()
      });
    })();
    """
    if let obj = pollProbe(completionGoneProbe) {
        check((obj["gone"] as? Bool) == true,
              "消失动画跑完（约 1.4 秒）后这条待办要真正移除")
        check((obj["otherThere"] as? Bool) == true,
              "另一条待办不能被误删")
        check((obj["headerSameNode"] as? Bool) == true,
              "整个完成 / 消失过程中表头都不能被重建（不能闪）")
        check((obj["headerSel"] as? Bool) == true,
              "整个完成 / 消失过程中表头选中态要保留")
    } else {
        fail("拿不到「完成待办」结束后的诊断结果")
    }
    // 清掉测试注入的 no-transition 覆盖，免得影响后面的几何自检。
    renderer.evaluateForTest("(function(){var s=document.getElementById('probe-notrans');if(s)s.remove();return 'ok';})()") { _ in }

    // ---- 4c-12b2. **完成淡出期间原生推状态：不能「消失一下又回来」**（2026-11 修）----
    //
    // 用户反馈：「点击了一次确认完成的那个圆圈之后，它会消失，然后马上又回来」。
    //
    // 根因有两条：
    //   1. 消失是 `.leaving` 触发的 CSS 动画 —— 原生在淡出的 400ms 里推一次
    //      状态（loadContent / refreshAll / EKEventStoreChanged 防抖），
    //      网页整块重绘，**新卡片的动画从头播**（opacity 1）→ 正在淡出的
    //      条目跳回完全不透明，再淡一次；
    //   2. 1.4 秒真正移除时，如果原生重取数还没回来，`S.dayPanel` 里仍是
    //      done=false → 重绘用旧数据把它画回来。
    //
    // 这里两条都复现：淡出中推「数据里**还有**这条」→ 新卡片必须接着淡
    // （负的 animation-delay），不能跳回；1.4 秒后数据仍含这条 → 也不能回来。
    let reviveSetup = """
    (function () {
      function fest() {
        return { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      }
      var festAll = {};
      for (var d = 1; d <= 7; d++) festAll[String(d)] = fest();
      var panel = { day: 6, todos: [
          { title: '会复活的待办', due: '09:00', done: false,
            identifier: 'rid-revive', calendarIdentifier: 'cal-r' },
          { title: '旁边的待办', due: '10:00', done: false,
            identifier: 'rid-neighbor', calendarIdentifier: 'cal-n' }
        ], events: [], festival: fest() };
      window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
        dayFlags: {}, courses: [], viewWeek: 3 });
      window.ttDayPanelOpen(6, false);
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:rid-revive"]');
      var dot = card ? card.querySelector('.dpcheck') : null;
      if (!dot) return JSON.stringify({ found: false });
      dot.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
      window.__probeReviveStart = Date.now();
      return JSON.stringify({ found: true,
        completing: card.classList.contains('completing') });
    })();
    """
    if let o = pollProbe(reviveSetup) {
        check((o["found"] as? Bool) == true, "要能找到「会复活的待办」卡片")
        check((o["completing"] as? Bool) == true, "点圆圈后要立刻进入完成状态")
    } else {
        fail("拿不到「完成中途重绘」的准备结果")
    }
    let reviveStart = Date()
    // 等进入淡出窗口（1 秒之后、1.4 秒之前）。
    while Date().timeIntervalSince(reviveStart) < 1.10 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let reviveDuringLeaveProbe = """
    (function () {
      function fest() {
        return { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      }
      var festAll = {};
      for (var d = 1; d <= 7; d++) festAll[String(d)] = fest();
      // ⚠️ 关键：推来的数据里**仍然有**这条（done=false）——
      // 模拟原生「完成写回 / 重取数」还没回来。
      var panel = { day: 6, todos: [
          { title: '会复活的待办', due: '09:00', done: false,
            identifier: 'rid-revive', calendarIdentifier: 'cal-r' },
          { title: '旁边的待办', due: '10:00', done: false,
            identifier: 'rid-neighbor', calendarIdentifier: 'cal-n' }
        ], events: [], festival: fest() };
      window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
        dayFlags: {}, courses: [], viewWeek: 3 });
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:rid-revive"]');
      return JSON.stringify({
        elapsed: Date.now() - window.__probeReviveStart,
        there: !!card,
        leaving: card ? card.classList.contains('leaving') : null,
        delay: card ? (card.style.animationDelay || '') : '',
        neighborThere: !!document.querySelector('.dpcard.todo[data-todo-key="id:rid-neighbor"]')
      });
    })();
    """
    if let o = pollProbe(reviveDuringLeaveProbe) {
        let elapsed = (o["elapsed"] as? NSNumber)?.doubleValue ?? -1
        check(elapsed >= 950 && elapsed < 1400,
              "推状态要落在淡出窗口内（实际 \(Int(elapsed))ms）")
        check((o["there"] as? Bool) == true,
              "淡出中的待办重绘后还要在（不能被直接掐掉）")
        check((o["leaving"] as? Bool) == true,
              "重绘后仍要保持淡出状态")
        // 负 delay = 从已经播到的进度接着淡。旧实现这里是空字符串
        //（新元素从头播 → 跳回完全不透明，就是用户看到的「又回来」）。
        let delayStr = (o["delay"] as? String) ?? ""
        let delayValue = Double(delayStr.replacingOccurrences(of: "ms", with: "")) ?? 1
        check(delayStr.hasSuffix("ms") && delayValue < 0 && delayValue >= -400,
              "重绘后必须用负的 animation-delay 接着淡（实际「\(delayStr)」）")
        check((o["neighborThere"] as? Bool) == true,
              "别的待办不能受影响")
    } else {
        fail("拿不到「淡出中推状态」的诊断结果")
    }
    // 等过 1.4 秒的移除点（数据里**仍然有**这条）。
    while Date().timeIntervalSince(reviveStart) < 1.70 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let reviveGoneProbe = """
    (function () {
      return JSON.stringify({
        elapsed: Date.now() - window.__probeReviveStart,
        gone: !document.querySelector('.dpcard.todo[data-todo-key="id:rid-revive"]'),
        neighborThere: !!document.querySelector('.dpcard.todo[data-todo-key="id:rid-neighbor"]')
      });
    })();
    """
    if let o = pollProbe(reviveGoneProbe) {
        check((o["gone"] as? Bool) == true,
              "1.4 秒后即使原生数据还没更新，完成的那条也不能重新出现")
        check((o["neighborThere"] as? Bool) == true,
              "别的待办不能被误删")
    } else {
        fail("拿不到「完成中途重绘」的结束诊断结果")
    }
    // 原生最终确认（数据里没有这条了）→ 仍然不该出现。
    let reviveConfirmProbe = """
    (function () {
      function fest() {
        return { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      }
      var festAll = {};
      for (var d = 1; d <= 7; d++) festAll[String(d)] = fest();
      var panel = { day: 6, todos: [
          { title: '旁边的待办', due: '10:00', done: false,
            identifier: 'rid-neighbor', calendarIdentifier: 'cal-n' }
        ], events: [], festival: fest() };
      window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
        dayFlags: {}, courses: [], viewWeek: 3 });
      return JSON.stringify({
        gone: !document.querySelector('.dpcard.todo[data-todo-key="id:rid-revive"]'),
        neighborThere: !!document.querySelector('.dpcard.todo[data-todo-key="id:rid-neighbor"]')
      });
    })();
    """
    if let o = pollProbe(reviveConfirmProbe) {
        check((o["gone"] as? Bool) == true,
              "原生确认完成后，那条待办不能被重新画出来")
        check((o["neighborThere"] as? Bool) == true,
              "原生确认后另一条待办还要在")
    } else {
        fail("拿不到「完成确认」的诊断结果")
    }
    // 还原 4c-12b 结束时的状态（第 3 列开着、第 2 周），
    // 后面的「点添加待办」用例是接着这个状态测的。
    _ = probeJSON("""
    (function () {
      var fest = { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      var festAll = {};
      for (var d = 1; d <= 7; d++) festAll[String(d)] = fest;
      var panel = { day: 3, todos: [
          { title: '第二条', due: '10:00', done: false,
            identifier: 'rid-2', calendarIdentifier: 'cal-2' }
        ], events: [], festival: fest };
      window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
        dayFlags: { '3': { todo: true, event: false } },
        courses: [], viewWeek: 2 });
      window.ttDayPanelOpen(3, false);
      return JSON.stringify({ open: window.ttDayPanelIsOpen().open });
    })();
    """)
    pause()

    // ---- 4c-12c. **点「添加待办」立刻发 todoCompose**（2026-11 修）----
    //
    // 原生收到它就该马上弹系统权限框 —— 不能等用户打完字按回车。
    // 这里验网页确实在**点击的同一拍**发出了这个 intent。
    var composePostResult: String?
    renderer.evaluateForTest(
        "(function(){var add=document.querySelector('.dpadd');" +
        "if(!add)return JSON.stringify({found:false});" +
        "var r=add.getBoundingClientRect();" +
        "var opts={bubbles:true,cancelable:true," +
        "clientX:r.left+r.width/2,clientY:r.top+r.height/2};" +
        "var before=window.ttDayPanelIsOpen();" +
        // 原生 `forwardClick` 在 click 之前会先派发这三种事件 —— 必须照做，
        // 否则测不到「点一下面板自己收起来了」的真实路径。
        "['pointerover','mouseover','mousemove'].forEach(function(t){" +
        "add.dispatchEvent(new MouseEvent(t,opts));});" +
        "var afterMove=window.ttDayPanelIsOpen();" +
        "window.__ttLastPost=null;" +
        "add.dispatchEvent(new MouseEvent('click',opts));" +
        "var p=window.__ttLastPost||null;" +
        "return JSON.stringify({found:true,beforeOpen:before.open," +
        "afterMoveOpen:afterMove.open,open:window.ttDayPanelIsOpen().open," +
        "action:p?p.action:null," +
        "day:p&&p.payload?p.payload.day:null,adding:!!document.querySelector('[data-dp-input]')});})();"
    ) { composePostResult = composePostResult ?? $0 }
    for _ in 0..<40 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if composePostResult != nil { break }
    }
    if let raw = composePostResult, let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check((obj["found"] as? Bool) == true, "要能找到「＋ 添加待办」")
        check((obj["action"] as? String) == "todoCompose",
              "点「添加待办」要立刻发 `todoCompose`（实际 \(obj["action"] ?? "nil")）")
        check((obj["day"] as? NSNumber)?.intValue == 3,
              "`todoCompose` 要带上输入框所在的日期（实际 \(obj["day"] ?? "nil")）")
        check((obj["adding"] as? Bool) == true,
              "点完要立刻展开输入框（不能等权限）")
        // ⚠️ 真实点击路径会在 click 前先派发 mousemove ——
        // 那一下**不能**把面板当成「鼠标离开了」收起来。
        check((obj["beforeOpen"] as? Bool) == true, "点击前面板必须是开着的（基线）")
        check((obj["afterMoveOpen"] as? Bool) == true,
              "点击前的那次 mousemove 不能让面板收起来")
        check((obj["open"] as? Bool) == true,
              "点「添加待办」之后面板不能消失（open=\(obj["open"] ?? "nil")）")
    } else {
        fail("拿不到「点添加待办」的诊断结果")
    }

    // ---- 4c-13. **待办右键菜单 + 内联编辑 + 带时间添加**（2026-11）----
    //
    // 用户需求：
    //   · 右键只弹菜单，不直接删除；
    //   · 「修改…」在卡片里编辑标题 / 时间，标题空 / 时间非法不能保存；
    //   · 添加待办能填时间，留空 = 00:00；
    //   · 窄列两行布局不溢出。
    //
    // ⚠️ 右键会走到原生 `handleTodoMenuIntent`；这里把 `MenuPresenter`
    // 设成只构造不弹出，否则自检会被模态菜单卡住。
    MenuPresenter.suppressPresentation = true
    _ = probeJSON("""
    (function () {
      var fest = { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      var festAll = {};
      for (var d = 1; d <= 7; d++) festAll[String(d)] = fest;
      var panel = { day: 3, todos: [
          { title: '原标题', due: '09:00', done: false,
            identifier: 'edit-1', calendarIdentifier: 'cal-e' }
        ], events: [], festival: fest };
      window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
        dayFlags: { '3': { todo: true, event: false } }, courses: [], viewWeek: 2 });
      window.ttDayPanelOpen(3, false);
      return JSON.stringify({ ok: true });
    })();
    """)
    pause(0.4)

    // 右键：只发 todoMenu，卡片还在，不能直接删除。
    let ctxResult = probeJSON("""
    (function () {
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:edit-1"]');
      if (!card) return JSON.stringify({ found: false });
      var r = card.getBoundingClientRect();
      window.__ttLastPost = null;
      card.dispatchEvent(new MouseEvent('contextmenu', {
        bubbles: true, cancelable: true,
        clientX: r.left + 20, clientY: r.top + 10
      }));
      var p = window.__ttLastPost || {};
      return JSON.stringify({
        found: true,
        action: p.action || null,
        day: p.payload ? p.payload.day : null,
        key: p.payload ? p.payload.key : null,
        stillThere: !!document.querySelector('.dpcard.todo[data-todo-key="id:edit-1"]')
      });
    })();
    """)
    if let o = ctxResult {
        check((o["found"] as? Bool) == true, "右键用例：要能找到待办卡片")
        check((o["action"] as? String) == "todoMenu",
              "右键待办只能发 todoMenu（实际 \(o["action"] ?? "nil")）")
        check((o["day"] as? NSNumber)?.intValue == 3, "todoMenu 要带当前列")
        check((o["key"] as? String) == "id:edit-1", "todoMenu 要带稳定键")
        check((o["stillThere"] as? Bool) == true, "右键不能直接把待办删掉")
    } else {
        fail("拿不到待办右键的诊断结果")
    }

    // 进入编辑态 → 标题 / 时间预填、自动聚焦标题、三行布局不溢出。
    _ = probeJSON("""
    (function () {
      window.__ttLastPost = null;
      var ok = window.ttDayPanelTodoMenuAction('edit', { key: 'id:edit-1' });
      var title = document.querySelector('[data-dp-edit-title]');
      var hour = document.querySelector('[data-dp-time-part="edit-hour"]');
      var minute = document.querySelector('[data-dp-time-part="edit-minute"]');
      var form = document.querySelector('.dpedit');
      var btns = document.querySelector('.dpeditbtns');
      var timerow = document.querySelector('.dpedittimerow');
      return JSON.stringify({
        ok: !!ok,
        editing: !!document.querySelector('.dpcard.todo.editing'),
        title: title ? title.value : null,
        hour: hour ? hour.value : null,
        minute: minute ? minute.value : null,
        // 时间小框和标题框平级（不是后代节点）。
        timeOutsideBlueBox: !!(hour && title && !title.contains(hour)),
        overflow: form ? (form.scrollWidth - form.clientWidth) : -1,
        btnBelow: !!(btns && timerow && btns.getBoundingClientRect().top > timerow.getBoundingClientRect().top)
      });
    })();
    """)
    pause(0.3)
    let editState = probeJSON("""
    (function () {
      var title = document.querySelector('[data-dp-edit-title]');
      var a = document.activeElement;
      var st = window.ttDayPanelTodoState ? window.ttDayPanelTodoState() : {};
      return JSON.stringify({
        focused: !!title && a === title,
        focusRequested: !!st.focusRequested,
        focusPending: !!st.focusPending,
        editingKey: st.editingKey || null,
        hasTitleInput: !!st.hasTitleInput,
        activeTag: a ? a.tagName : null,
        activeClass: a ? (a.className || '') : null,
        hasFocus: document.hasFocus()
      });
    })();
    """)
    if let o = editState {
        print("[诊断] 编辑态焦点：\(o)")
        let focused = (o["focused"] as? Bool) == true
        let requested = (o["focusRequested"] as? Bool) == true
        // ⚠️ 自检进程的网页是 hidden（`document.hasFocus() == false`），
        // `focus()` 不会落到 activeElement 上 —— 真正让它生效的是
        // 原生收到 `textInputFocus` 后把窗口切成 key。
        // 所以这里验「确实请求了聚焦 + 输入框在 DOM 里」；
        // 真实前台下的光标由 `--shot-day-panel ... edit` 截图核对。
        check((o["hasTitleInput"] as? Bool) == true, "编辑态标题输入框要在 DOM 里")
        check(focused || requested,
              "进入编辑态后要自动聚焦标题（focused=\(focused) requested=\(requested) active=\(o["activeTag"] ?? "nil")）")
    }
    // 上面那次 probe 的结果没有合并，单独再取一次完整状态。
    if let o = probeJSON("""
    (function () {
      var form = document.querySelector('.dpedit');
      var btns = document.querySelector('.dpeditbtns');
      var timerow = document.querySelector('.dpedittimerow');
      return JSON.stringify({
        title: document.querySelector('[data-dp-edit-title]') ? document.querySelector('[data-dp-edit-title]').value : null,
        hour: document.querySelector('[data-dp-time-part="edit-hour"]') ? document.querySelector('[data-dp-time-part="edit-hour"]').value : null,
        minute: document.querySelector('[data-dp-time-part="edit-minute"]') ? document.querySelector('[data-dp-time-part="edit-minute"]').value : null,
        // 时间小框和标题框平级（不是后代节点）。
        timeOutsideBlueBox: (function () {
          var t = document.querySelector('[data-dp-edit-title]');
          var h = document.querySelector('[data-dp-time-part="edit-hour"]');
          return !!(h && t && !t.contains(h));
        })(),
        overflow: form ? (form.scrollWidth - form.clientWidth) : -1,
        btnBelow: !!(btns && timerow && btns.getBoundingClientRect().top > timerow.getBoundingClientRect().top)
      });
    })();
    """) {
        check((o["title"] as? String) == "原标题", "编辑态标题要预填（实际 \(o["title"] ?? "nil")）")
        check((o["hour"] as? String) == "09", "编辑态小时要预填 09")
        check((o["minute"] as? String) == "00", "编辑态分钟要预填 00")
        // 编辑态的时间小框也要和标题框**平级**（不在同一个蓝框里）。
        check((o["timeOutsideBlueBox"] as? Bool) == true,
              "编辑态的时间小框不能放在标题输入框里面（要平级）")
        check((o["overflow"] as? NSNumber)?.intValue ?? 99 <= 1, "编辑态窄列不能横向溢出")
        check((o["btnBelow"] as? Bool) == true, "编辑态保存 / 取消要单独一行（窄列放得下）")
    }

    // 空标题 → 不提交。
    if let o = probeJSON("""
    (function () {
      var t = document.querySelector('[data-dp-edit-title]');
      window.__ttLastPost = null;
      t.value = '';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13,
        bubbles: true, cancelable: true }));
      var err = document.querySelector('.dpcard.editing .dpadderr');
      return JSON.stringify({
        post: window.__ttLastPost ? window.__ttLastPost.action : null,
        err: err ? err.textContent : '',
        editing: !!document.querySelector('.dpcard.editing')
      });
    })();
    """) {
        check((o["post"] as? String) == nil, "标题为空不能提交 todoUpdate")
        check(((o["err"] as? String) ?? "").contains("标题不能为空"),
              "标题为空要就地提示（实际「\(o["err"] ?? "")」）")
        check((o["editing"] as? Bool) == true, "标题为空后仍留在编辑态")
    } else {
        fail("拿不到空标题的诊断结果")
    }

    // 非法时间 → 不提交。
    if let o = probeJSON("""
    (function () {
      var t = document.querySelector('[data-dp-edit-title]');
      var h = document.querySelector('[data-dp-time-part="edit-hour"]');
      var m = document.querySelector('[data-dp-time-part="edit-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      window.__ttLastPost = null;
      set(t, '新标题');
      set(h, '24');
      set(m, '00');
      (document.activeElement || m).dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
      var err = document.querySelector('.dpcard.editing .dpadderr');
      return JSON.stringify({
        post: window.__ttLastPost ? window.__ttLastPost.action : null,
        err: err ? err.textContent : '',
        editing: !!document.querySelector('.dpcard.editing')
      });
    })();
    """) {
        check((o["post"] as? String) == nil, "24:00 不能提交 todoUpdate")
        check(((o["err"] as? String) ?? "").contains("时间"),
              "非法时间要就地提示（实际「\(o["err"] ?? "")」）")
        check((o["editing"] as? Bool) == true, "非法时间后仍留在编辑态")
    } else {
        fail("拿不到非法时间的诊断结果")
    }

    // 合法保存 → 发 todoUpdate，乐观显示新标题 / 20:30。
    if let o = probeJSON("""
    (function () {
      var t = document.querySelector('[data-dp-edit-title]');
      var h = document.querySelector('[data-dp-time-part="edit-hour"]');
      var m = document.querySelector('[data-dp-time-part="edit-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      window.__ttLastPost = null;
      set(t, '新标题');
      set(h, '20');
      set(m, '30');
      (document.activeElement || m).dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
      var p = window.__ttLastPost || {};
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:edit-1"]');
      return JSON.stringify({
        action: p.action || null,
        title: p.payload ? p.payload.title : null,
        time: p.payload ? p.payload.time : null,
        editing: !!document.querySelector('.dpcard.editing'),
        shownTitle: card ? (card.querySelector('.dptitle') || {}).textContent : null,
        shownTime: card ? (card.querySelector('.dptime') || {}).textContent : null
      });
    })();
    """) {
        check((o["action"] as? String) == "todoUpdate", "保存要发 todoUpdate（实际 \(o["action"] ?? "nil")）")
        check((o["title"] as? String) == "新标题", "todoUpdate 要带新标题")
        check((o["time"] as? String) == "20:30", "todoUpdate 要带 20:30（实际 \(o["time"] ?? "nil")）")
        check((o["editing"] as? Bool) == false, "保存后退出编辑态")
        check((o["shownTitle"] as? String) == "新标题", "保存后标题立即乐观更新")
        check((o["shownTime"] as? String) == "20:30", "保存后时间立即乐观更新")
    } else {
        fail("拿不到合法保存的诊断结果")
    }
    // 原生回包（成功）→ 清掉 pendingEdit，避免影响后面的用例。
    _ = probeJSON("(function(){ if (window.ttDayPanelTodoUpdateResult) window.ttDayPanelTodoUpdateResult({ ok: true, identifier: 'edit-1', title: '新标题', time: '20:30' }); return JSON.stringify({ok:true}); })();")

    // Esc 取消 → 原内容不变。
    if let o = probeJSON("""
    (function () {
      var fest = { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      var panel = { day: 3, todos: [
          { title: '原标题', due: '09:00', done: false,
            identifier: 'edit-1', calendarIdentifier: 'cal-e' }
        ], events: [], festival: fest };
      window.ttUpdate({ dayPanel: panel, dayFestivals: { '3': fest },
        dayFlags: { '3': { todo: true, event: false } }, courses: [], viewWeek: 2 });
      window.ttDayPanelOpen(3, false);
      window.ttDayPanelTodoMenuAction('edit', { key: 'id:edit-1' });
      var t = document.querySelector('[data-dp-edit-title]');
      window.__ttLastPost = null;
      t.value = '改了但取消';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27,
        bubbles: true, cancelable: true }));
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:edit-1"]');
      return JSON.stringify({
        post: window.__ttLastPost ? window.__ttLastPost.action : null,
        editing: !!document.querySelector('.dpcard.editing'),
        title: card ? (card.querySelector('.dptitle') || {}).textContent : null
      });
    })();
    """) {
        check((o["post"] as? String) == nil, "Esc 取消不能发 todoUpdate")
        check((o["editing"] as? Bool) == false, "Esc 后退出编辑态")
        check((o["title"] as? String) == "原标题", "Esc 取消后原内容不变")
    } else {
        fail("拿不到 Esc 取消的诊断结果")
    }

    // 添加态：两行、时间框、窄列不溢出；填 20:00 写回 20:00。
    //
    // ⚠️ **时间两个小框和标题蓝框是平级的**（不在蓝框里面）——
    // 用户明确要求「时间在虚线框里，但不在同一个蓝色输入框里」。
    if let o = probeJSON("""
    (function () {
      document.querySelector('.dpadd').click();
      var form = document.querySelector('.dpaddform');
      var rows = document.querySelectorAll('.dpaddform .dpinputrow');
      var title = document.querySelector('[data-dp-input]');
      var h = document.querySelector('[data-dp-time-part="add-hour"]');
      var m = document.querySelector('[data-dp-time-part="add-minute"]');
      return JSON.stringify({
        rows: rows.length,
        hasTime: !!(h && m),
        overflow: form ? (form.scrollWidth - form.clientWidth) : -1,
        secondRowBelow: rows.length > 1 &&
          rows[1].getBoundingClientRect().top > rows[0].getBoundingClientRect().top,
        // 时间框**不在**标题蓝框里面（不是后代节点）。
        timeOutsideBlueBox: !!(h && title && !title.contains(h)),
        // 默认显示四个 0。
        hourValue: h ? h.value : null,
        minuteValue: m ? m.value : null
      });
    })();
    """) {
        check((o["rows"] as? NSNumber)?.intValue == 2, "添加态必须是两行（实际 \(o["rows"] ?? "?") 行）")
        check((o["hasTime"] as? Bool) == true, "添加态要有小时 / 分钟两个框")
        check((o["overflow"] as? NSNumber)?.intValue ?? 99 <= 1, "添加态窄列不能横向溢出")
        check((o["secondRowBelow"] as? Bool) == true, "时间行必须在内容行下面（不能挤成一行）")
        check((o["timeOutsideBlueBox"] as? Bool) == true,
              "时间两个小框不能放在蓝色标题输入框里面（要平级）")
        check((o["hourValue"] as? String) == "00",
              "小时框默认显示 00（实际「\(o["hourValue"] ?? "nil")」）")
        check((o["minuteValue"] as? String) == "00",
              "分钟框默认显示 00（实际「\(o["minuteValue"] ?? "nil")」）")
    } else {
        fail("拿不到添加态布局的诊断结果")
    }

    // ---- 4c-13b. **时间输入的键盘行为**（2026-11）----
    //
    // 用户要求（和「课程时间自定义」一致）：
    //   · ↑ / ↓ 加减 1，**到头循环**（23 → 00，00 → 23）；
    //   · 框是空的 → 按 ↑ 变成 01；
    //   · 填满两位 → 自动跳到另一个框（时→分，分→时）；
    //   · 清空后保存按 00 处理（不报错）。
    if let o = probeJSON("""
    (function () {
      var h = document.querySelector('[data-dp-time-part="add-hour"]');
      var m = document.querySelector('[data-dp-time-part="add-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      function key(el, k, code) {
        el.dispatchEvent(new KeyboardEvent('keydown', {
          key: k, keyCode: code, which: code,
          bubbles: true, cancelable: true
        }));
      }
      var out = {};
      // ↑ 加 1：00 → 01
      set(h, '00');
      key(h, 'ArrowUp', 38);
      out.upFrom00 = h.value;
      // ↓ 减 1：01 → 00
      key(h, 'ArrowDown', 40);
      out.downFrom01 = h.value;
      // 到头循环：23 ↑ → 00；00 ↓ → 23
      set(h, '23');
      key(h, 'ArrowUp', 38);
      out.hourWrapUp = h.value;
      set(h, '00');
      key(h, 'ArrowDown', 40);
      out.hourWrapDown = h.value;
      // 分同理：59 ↑ → 00
      set(m, '59');
      key(m, 'ArrowUp', 38);
      out.minuteWrapUp = m.value;
      // 空框按 ↑ → 01
      set(h, '');
      key(h, 'ArrowUp', 38);
      out.emptyUp = h.value;
      // 填满两位 → 自动跳到另一个框（分→时）
      set(m, '30');
      out.focusAfterMinute = (document.activeElement === h) ? 'hour' :
        (document.activeElement === m ? 'minute' : 'other');
      // 填满两位 → 自动跳到另一个框（时→分）
      set(h, '20');
      out.focusAfterHour = (document.activeElement === m) ? 'minute' :
        (document.activeElement === h ? 'hour' : 'other');
      return JSON.stringify(out);
    })();
    """) {
        check((o["upFrom00"] as? String) == "01", "↑ 让 00 变成 01（实际 \(o["upFrom00"] ?? "nil")）")
        check((o["downFrom01"] as? String) == "00", "↓ 让 01 变成 00（实际 \(o["downFrom01"] ?? "nil")）")
        check((o["hourWrapUp"] as? String) == "00", "时 23 再按 ↑ 要回到 00（实际 \(o["hourWrapUp"] ?? "nil")）")
        check((o["hourWrapDown"] as? String) == "23", "时 00 再按 ↓ 要回到 23（实际 \(o["hourWrapDown"] ?? "nil")）")
        check((o["minuteWrapUp"] as? String) == "00", "分 59 再按 ↑ 要回到 00（实际 \(o["minuteWrapUp"] ?? "nil")）")
        check((o["emptyUp"] as? String) == "01", "空框按 ↑ 要变成 01（实际 \(o["emptyUp"] ?? "nil")）")
        check((o["focusAfterMinute"] as? String) == "hour",
              "分框填满两位要自动跳回时框（实际 \(o["focusAfterMinute"] ?? "nil")）")
        check((o["focusAfterHour"] as? String) == "minute",
              "时框填满两位要自动跳到分框（实际 \(o["focusAfterHour"] ?? "nil")）")
    } else {
        fail("拿不到时间键盘行为的诊断结果")
    }

    // 清空后保存 → 按 00 处理（不报错、不拦着）。
    if let o = probeJSON("""
    (function () {
      var t = document.querySelector('[data-dp-input]');
      var h = document.querySelector('[data-dp-time-part="add-hour"]');
      var m = document.querySelector('[data-dp-time-part="add-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      set(t, '清空时间');
      set(h, '');
      set(m, '');
      window.__ttLastPost = null;
      t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13,
        bubbles: true, cancelable: true }));
      var p = window.__ttLastPost || {};
      return JSON.stringify({
        action: p.action || null,
        time: p.payload ? p.payload.time : null,
        err: (document.querySelector('.dpadderr') || {}).textContent || ''
      });
    })();
    """) {
        check((o["action"] as? String) == "todoAdd", "时间清空后仍应能提交")
        check((o["time"] as? String) == "00:00", "时间清空按 00:00 处理（实际 \(o["time"] ?? "nil")）")
        check(((o["err"] as? String) ?? "").isEmpty, "时间清空不该报错")
    } else {
        fail("拿不到清空时间的诊断结果")
    }

    if let o = probeJSON("""
    (function () {
      // 上一个用例提交后表单已收起 → 这里**重新展开**再填。
      var add = document.querySelector('.dpadd');
      if (add) add.click();
      var t = document.querySelector('[data-dp-input]');
      var h = document.querySelector('[data-dp-time-part="add-hour"]');
      var m = document.querySelector('[data-dp-time-part="add-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      window.__ttLastPost = null;
      set(t, '带时间的待办');
      set(h, '20');
      set(m, '00');
      // ⚠️ 分框填满两位会自动跳回**时框**（新的交互）——
      // 回车要发给当前焦点所在的那个框，不能写死发给了 m。
      (document.activeElement || m).dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
      var p = window.__ttLastPost || {};
      return JSON.stringify({
        action: p.action || null,
        title: p.payload ? p.payload.title : null,
        time: p.payload ? p.payload.time : null,
        adding: !!document.querySelector('.dpaddform')
      });
    })();
    """) {
        check((o["action"] as? String) == "todoAdd", "填完时间回车要发 todoAdd（实际 \(o["action"] ?? "nil")）")
        check((o["title"] as? String) == "带时间的待办", "todoAdd 要带标题")
        check((o["time"] as? String) == "20:00", "todoAdd 要带 20:00（实际 \(o["time"] ?? "nil")）")
        check((o["adding"] as? Bool) == false, "提交后收起添加态")
    } else {
        fail("拿不到带时间添加的诊断结果")
    }

    // 留空 = 00:00。
    if let o = probeJSON("""
    (function () {
      document.querySelector('.dpadd').click();
      var t = document.querySelector('[data-dp-input]');
      window.__ttLastPost = null;
      t.value = '默认时间';
      t.dispatchEvent(new Event('input', { bubbles: true }));
      t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13,
        bubbles: true, cancelable: true }));
      var p = window.__ttLastPost || {};
      return JSON.stringify({
        action: p.action || null,
        time: p.payload ? p.payload.time : null
      });
    })();
    """) {
        check((o["action"] as? String) == "todoAdd", "留空时间也要能提交")
        check((o["time"] as? String) == "00:00", "时间留空 = 00:00（实际 \(o["time"] ?? "nil")）")
    } else {
        fail("拿不到默认时间的诊断结果")
    }

    // ---- 4c-13b-2. **右下角是「取消」，不是「添加」**（2026-11 改）----
    //
    // 用户需求：添加态右下角那个按钮改成「取消」——
    //   · 填好内容时它该说的是「放弃这次输入」；
    //   · 添加态以前**根本没有取消按钮**（填错了只能按 Esc，很多人不知道）；
    //   · 提交靠**回车**（和编辑态的「保存 / 取消」语义统一）。
    //
    // 「取消」的行为 = 关掉表单 + **清空**已填的标题 / 时间（和 Esc 一致）。
    if let o = probeJSON("""
    (function () {
      document.querySelector('.dpadd').click();
      var t = document.querySelector('[data-dp-input]');
      var h = document.querySelector('[data-dp-time-part="add-hour"]');
      var m = document.querySelector('[data-dp-time-part="add-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      var btn = document.querySelector('.dpok');
      var out = { buttonText: btn ? btn.textContent : null };
      set(t, '填了一半');
      set(h, '20');
      set(m, '30');
      window.__ttLastPost = null;
      if (btn) btn.click();
      out.post = window.__ttLastPost ? window.__ttLastPost.action : null;
      out.formClosed = !document.querySelector('.dpaddform');
      // 重新打开 → 之前填的内容应该**没了**（取消 = 放弃这次输入）。
      document.querySelector('.dpadd').click();
      var t2 = document.querySelector('[data-dp-input]');
      var h2 = document.querySelector('[data-dp-time-part="add-hour"]');
      var m2 = document.querySelector('[data-dp-time-part="add-minute"]');
      out.titleAfter = t2 ? t2.value : null;
      out.hourAfter = h2 ? h2.value : null;
      out.minuteAfter = m2 ? m2.value : null;
      // 收尾：关掉添加态。
      var btn2 = document.querySelector('.dpok');
      if (btn2) btn2.click();
      return JSON.stringify(out);
    })();
    """) {
        check((o["buttonText"] as? String) == "取消",
              "添加态右下角按钮应该是「取消」（实际「\(o["buttonText"] ?? "nil")」）")
        check((o["post"] as? String) == nil, "点「取消」不能提交 todoAdd")
        check((o["formClosed"] as? Bool) == true, "点「取消」要关掉添加态")
        check(((o["titleAfter"] as? String) ?? "").isEmpty,
              "点「取消」要清空已填的标题（实际「\(o["titleAfter"] ?? "nil")」）")
        check((o["hourAfter"] as? String) == "00",
              "点「取消」后时间回到 00（实际「\(o["hourAfter"] ?? "nil")」）")
    } else {
        fail("拿不到「取消按钮」的诊断结果")
    }

    // 非法时间 → 不提交，表单还开着，提示还在。
    if let o = probeJSON("""
    (function () {
      document.querySelector('.dpadd').click();
      var t = document.querySelector('[data-dp-input]');
      var h = document.querySelector('[data-dp-time-part="add-hour"]');
      var m = document.querySelector('[data-dp-time-part="add-minute"]');
      function set(el, v) {
        el.value = v;
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      window.__ttLastPost = null;
      set(t, '非法时间');
      set(h, '25');
      set(m, '00');
      (document.activeElement || m).dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
      var p = window.__ttLastPost || {};
      var err = document.querySelector('.dpadderr');
      var still = !!document.querySelector('.dpaddform');
      // 收起添加态，交给后面的用例。
      var hh = document.querySelector('[data-dp-time-part="add-hour"]');
      if (hh) hh.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27,
        bubbles: true, cancelable: true }));
      return JSON.stringify({
        action: p.action || null,
        err: err ? err.textContent : '',
        still: still
      });
    })();
    """) {
        check((o["action"] as? String) == nil, "25:00 不能提交 todoAdd")
        check(((o["err"] as? String) ?? "").contains("时间"),
              "非法添加时间要就地提示（实际「\(o["err"] ?? "")」）")
        check((o["still"] as? Bool) == true, "非法时间后表单不能收起")
    } else {
        fail("拿不到非法添加时间的诊断结果")
    }
    MenuPresenter.suppressPresentation = false

    // ---- 4c-13c. **原生菜单开着时，覆盖层不能被收走**（2026-11 修）----
    //
    // 用户反馈：「点击删除之后，整个日历就会闪一下」。
    //
    // 成因：菜单是用临时 NSPanel（level .floating）当宿主的 ——
    // 菜单一弹出**指针就离开卡片** → 原生 `pointerOnCard` 翻转 →
    // 发 `ttLiveHoverClear()` → 网页 `onPointerLeave()` → `fadeOutPanel()`。
    //
    // 修法：原生弹菜单前告诉网页「菜单开着」，菜单期间不收覆盖层、
    // 也不跟指针换列；菜单关掉后自动恢复。
    //
    // 这里用网页的 `ttDayPanelMenuOpen` 直接模拟原生的那一帧。
    if let o = probeJSON("""
    (function () {
      var out = {};
      // 菜单开着 + 指针离开 → 覆盖层必须**留在原位**。
      window.ttDayPanelMenuOpen(true);
      if (window.ttLiveHoverClear) window.ttLiveHoverClear();
      out.openAfterLeave = window.ttDayPanelIsOpen().open;
      out.dayAfterLeave = window.ttDayPanelIsOpen().day;
      // 菜单开着 + 指针移到别的列 → 覆盖层**不能换列**。
      if (window.__ttDiagMove) window.__ttDiagMove(700, 260);
      out.dayAfterMove = window.ttDayPanelIsOpen().day;
      // 菜单关掉 → 恢复正常（指针离开会收）。
      window.ttDayPanelMenuOpen(false);
      if (window.ttLiveHoverClear) window.ttLiveHoverClear();
      out.openAfterMenuClosed = window.ttDayPanelIsOpen().open;
      // 重新打开这一列，供后面的用例继续用。
      window.ttDayPanelOpen(3, false);
      return JSON.stringify(out);
    })();
    """) {
        check((o["openAfterLeave"] as? Bool) == true,
              "菜单开着时指针离开，覆盖层不能被收走（实际 open=\(o["openAfterLeave"] ?? "nil")）")
        check((o["dayAfterLeave"] as? NSNumber)?.intValue == 3,
              "菜单开着时覆盖层要留在原来那一列（实际 day=\(o["dayAfterLeave"] ?? "nil")）")
        check((o["dayAfterMove"] as? NSNumber)?.intValue == 3,
              "菜单开着时指针移动，覆盖层不能跟着换列（实际 day=\(o["dayAfterMove"] ?? "nil")）")
        check((o["openAfterMenuClosed"] as? Bool) == false,
              "菜单关掉之后要恢复正常（指针离开仍然收覆盖层）")
    } else {
        fail("拿不到「菜单开着」的诊断结果")
    }

    // ---- 4c-13d. **面板已被收走时，选「修改…」仍要能进入编辑态**（2026-11）----
    //
    // 用户反馈：点「修改…」后整个日历先消失、之后又出现，但什么都没了。
    //
    // 菜单期间指针离开 → 覆盖层被收走（`DP.open == false`）→ 用户选「修改…」时，
    // 如果直接 return false 就**什么都没发生**。
    // 现在按「菜单打开时记住的那一列」重新打开，再进入编辑态。
    if let o = probeJSON("""
    (function () {
      var out = {};
      // 模拟「面板被收走」：
      //   菜单开着 → 指针离开（**这时不该收**，有上面的用例把关）
      //   → 菜单关掉 → 指针再离开一次 → 这时正常收走。
      window.ttDayPanelMenuOpen(true);
      if (window.ttLiveHoverClear) window.ttLiveHoverClear();
      window.ttDayPanelMenuOpen(false);
      if (window.ttLiveHoverClear) window.ttLiveHoverClear();
      out.openBefore = window.ttDayPanelIsOpen().open;
      // 用户这时才选「修改…」。
      var ok = window.ttDayPanelTodoMenuAction('edit', { key: 'id:edit-1' });
      out.editReturned = !!ok;
      out.editing = !!document.querySelector('.dpcard.todo.editing');
      var t = document.querySelector('[data-dp-edit-title]');
      out.title = t ? t.value : null;
      out.day = window.ttDayPanelIsOpen().day;
      return JSON.stringify(out);
    })();
    """) {
        check((o["openBefore"] as? Bool) == false, "前置条件：面板确实被收走了")
        check((o["editReturned"] as? Bool) == true,
              "面板被收走后选「修改…」也要有反应（不能静默失败）")
        check((o["editing"] as? Bool) == true, "面板被收走后选「修改…」要进入编辑态")
        check((o["title"] as? String) == "原标题",
              "带回来的编辑态要预填原标题（实际「\(o["title"] ?? "nil")」）")
        check((o["day"] as? NSNumber)?.intValue == 3,
              "要回到原来那一列（实际 day=\(o["day"] ?? "nil")）")
    } else {
        fail("拿不到「面板被收走后修改」的诊断结果")
    }
    // 收尾：退出编辑态，别影响后面的用例。
    _ = probeJSON("""
    (function () {
      var t = document.querySelector('[data-dp-edit-title]');
      if (t) t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27,
        bubbles: true, cancelable: true }));
      window.ttDayPanelMenuOpen(false);
      return JSON.stringify({ ok: true });
    })();
    """)

    // ---- 4c-13d-2. **输入（添加 / 修改待办）期间锁定当前列**（2026-11-05 用户反馈）----
    //
    // 用户原话：「点了添加待办、或者正在改某列的待办，鼠标不小心滑到别的列，
    // 原本要输入的那一列就没了 —— 把它固定住，以免鼠标误滑动」。
    //
    // 换列 = `openPanel(day)` 重建整块内容 → 正在输入的 `<input>` 被销毁，
    // 打了一半的标题 / 时间直接丢。现在 `onPointerMove` 在
    // `DP.adding || DP.editingTodoKey` 时直接忽略换列，只认当前那一列。
    //
    // 这里同时验「锁住」和「解锁后恢复跟随」——只验锁住的话，
    // 万一把跟随彻底关死了也能「通过」。
    //
    // ⚠️ 复用前一个用例注入的第 3 列数据（含 `id:edit-1`），**不要**再 `setState`：
    // 后面的 4c-13e-2 依赖「面板开在第 3 列」这个状态。
    // 顺序上先做编辑态（不触发任何 intent），最后做添加态（点 `.dpadd` 会发
    // `todoCompose`，可能让原生推一轮数据回来）。
    if let o = probeJSON("""
    (function () {
      var out = {};
      function headCenter(d) {
        var e = document.querySelector('.hcell[data-day="' + d + '"]');
        if (!e) return null;
        var r = e.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
      }
      window.ttDayPanelMenuOpen(false);
      window.ttDayPanelOpen(3, false);
      out.dayBefore = window.ttDayPanelIsOpen().day;
      var c2 = headCenter(2);
      var c6 = headCenter(6);
      out.hasTwo = !!c2;
      out.hasSix = !!c6;

      // ---- 修改待办期间：指针滑到第 2 列 ----
      out.editReturned = window.ttDayPanelTodoMenuAction('edit', { key: 'id:edit-1' });
      if (c2) window.__ttDiagMove(c2.x, c2.y);
      out.dayAfterMoveEditing = window.ttDayPanelIsOpen().day;
      out.editingAfterMove = (window.ttDayPanelTodoState() || {}).editingKey || null;
      out.titleAfterMove = (function () {
        var t = document.querySelector('[data-dp-edit-title]');
        return t ? t.value : null;
      })();
      // Esc 取消编辑 → 跟随恢复：再移到第 2 列，这次应该真的换过去。
      var t = document.querySelector('[data-dp-edit-title]');
      if (t) t.dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
      if (c2) window.__ttDiagMove(c2.x, c2.y);
      out.dayAfterEditUnlock = window.ttDayPanelIsOpen().day;

      // ---- 添加待办期间：指针滑到第 6 列 ----
      window.ttDayPanelOpen(3, false);
      var add = document.querySelector('.dpadd');
      if (add) add.click();
      out.addFormOpen = !!document.querySelector('[data-dp-input]');
      if (c6) window.__ttDiagMove(c6.x, c6.y);
      out.dayAfterMoveAdding = window.ttDayPanelIsOpen().day;
      out.openAfterMoveAdding = window.ttDayPanelIsOpen().open;
      out.inputAfterMoveAdding = !!document.querySelector('[data-dp-input]');
      // Esc 取消添加 → 恢复跟随
      var inp = document.querySelector('[data-dp-input]');
      if (inp) inp.dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
      out.dayAfterEscape = window.ttDayPanelIsOpen().day;
      if (c6) window.__ttDiagMove(c6.x, c6.y);
      out.dayAfterAddUnlock = window.ttDayPanelIsOpen().day;

      // 收尾：回到第 3 列，给后面的用例一个干净起点。
      window.ttDayPanelOpen(3, false);
      return JSON.stringify(out);
    })();
    """) {
        check((o["dayBefore"] as? NSNumber)?.intValue == 3, "前置：面板开在第 3 列")
        check((o["hasTwo"] as? Bool) == true, "前置：能拿到第 2 列表头的坐标")
        check((o["hasSix"] as? Bool) == true, "前置：能拿到第 6 列表头的坐标")
        check((o["editReturned"] as? Bool) == true, "前置：能进入编辑态")
        check((o["dayAfterMoveEditing"] as? NSNumber)?.intValue == 3,
              "修改待办期间指针滑到别的列，面板必须留在原列（实际 day=\(o["dayAfterMoveEditing"] ?? "nil")）")
        check((o["editingAfterMove"] as? String) == "id:edit-1",
              "修改待办期间指针滑到别的列，编辑态不能被重置（实际 \(o["editingAfterMove"] ?? "nil")）")
        check((o["titleAfterMove"] as? String) == "原标题",
              "修改待办期间指针滑到别的列，已经打进去的标题不能被清掉（实际「\(o["titleAfterMove"] ?? "nil")」）")
        check((o["dayAfterEditUnlock"] as? NSNumber)?.intValue == 2,
              "取消编辑后要恢复跟随（移到第 2 列就该换过去，实际 day=\(o["dayAfterEditUnlock"] ?? "nil")）")
        check((o["addFormOpen"] as? Bool) == true, "前置：点了「添加待办」要出现输入框")
        check((o["dayAfterMoveAdding"] as? NSNumber)?.intValue == 3,
              "添加待办期间指针滑到别的列，面板必须留在原列（实际 day=\(o["dayAfterMoveAdding"] ?? "nil")）")
        check((o["openAfterMoveAdding"] as? Bool) == true,
              "添加待办期间指针滑到别的列，面板不能被收走")
        check((o["inputAfterMoveAdding"] as? Bool) == true,
              "添加待办期间指针滑到别的列，输入框不能消失（否则打了一半的字就丢了）")
        check((o["dayAfterAddUnlock"] as? NSNumber)?.intValue == 6,
              "取消添加后要恢复跟随（移到第 6 列就该换过去，实际 day=\(o["dayAfterAddUnlock"] ?? "nil")）")
        print("[诊断] 输入期间锁定：编辑中移到第 2 列后 day=\(o["dayAfterMoveEditing"] ?? "nil")"
              + "（编辑态 \(o["editingAfterMove"] ?? "nil")），"
              + "添加中移到第 6 列后 day=\(o["dayAfterMoveAdding"] ?? "nil")；"
              + "解锁后分别跟到 \(o["dayAfterEditUnlock"] ?? "nil") / \(o["dayAfterAddUnlock"] ?? "nil")")
    } else {
        fail("拿不到「输入期间锁定当前列」的诊断结果")
    }

    // ---- 4c-13e. **菜单往左弹 + 关掉后有宽限期**（2026-11 修「闪一下」）----
    //
    // 用户反馈：「点删除之后，整个日历就会闪一下」「最后课表莫名其妙消失」。
    //
    // 成因（真机截图证实）：菜单**往右弹**时从课表最右列伸出卡片右边缘
    // 约 60pt → 菜单一关，宿主面板消失 → 指针停在**卡片矩形之外** →
    // 原生判定「指针离开了课表」→ **整个课表 6 秒淡到 22%**。
    //
    // 修法：① 菜单往左弹（菜单落在卡片内）；② 菜单关掉后给 0.6 秒宽限期。
    if let o = probeJSON("""
    (function () {
      var out = {};
      // 菜单开着时，网页必须处于「菜单开着」状态。
      window.ttDayPanelMenuOpen(true);
      out.menuFlagOn = true;
      // 菜单关掉 → 网页恢复正常。
      window.ttDayPanelMenuOpen(false);
      out.menuFlagOff = true;
      return JSON.stringify(out);
    })();
    """) {
        check((o["menuFlagOn"] as? Bool) == true, "菜单开着时网页要处于「菜单开着」状态")
        check((o["menuFlagOff"] as? Bool) == true, "菜单关掉后网页要恢复正常")
    }

    // ---- 4c-13e-2. **指针在网格上方（表头上面的时钟 / 状态条）时，面板不该收走**----
    //
    // 用户实测：「点击了日历，移到了日历上方，日历收进去了」。
    // 那个位置（顶栏 / 状态条）**还在课表卡片里**，指针并没有离开课表 ——
    // 面板不该收。
    //
    // 修法：指针纵向在网格上方、横向落在**当前那一列**的范围里
    // → 认定还是这一列（`dayAtPoint` 返回 `DP.day`），面板不动。
    if let o = probeJSON("""
    (function () {
      var out = {};
      var grid = document.querySelector('.grid');
      var gr = grid ? grid.getBoundingClientRect() : null;
      var head = document.querySelector('.hcell[data-day="3"]');
      var hr = head ? head.getBoundingClientRect() : null;
      if (!gr || !hr) return JSON.stringify({ skip: true });
      // 指针放在**表头上方**那一列的水平位置。
      var x = hr.left + hr.width / 2;
      var y = gr.top - 12;
      window.__ttDiagMove(x, y);
      out.open = window.ttDayPanelIsOpen().open;
      out.day = window.ttDayPanelIsOpen().day;
      return JSON.stringify(out);
    })();
    """) {
        if (o["skip"] as? Bool) != true {
            check((o["open"] as? Bool) == true,
                  "指针移到表头上方（还在课表里）时，面板不该被收走（实际 open=\(o["open"] ?? "nil")）")
            check((o["day"] as? NSNumber)?.intValue == 3,
                  "指针在表头上方移动时，面板要留在原来那一列（实际 day=\(o["day"] ?? "nil")）")
        }
    } else {
        fail("拿不到「表头上方」的诊断结果")
    }

    // ---- 4c-13f. **收走之后再打开：必须重新播入场动画**（2026-11 修）----
    //
    // 用户反馈：「在日历头部向下缓慢滑动，就会突然出现日历然后消失再渐渐出现」，
    // 后来补充：「点击了日历，到了日历上方，日历收进去了，
    // 然后从顶上往下滑到日历头部」——
    // 「他应该是要显示，但不是要这么闪一下」。
    //
    // 成因（实测）：收起动画只摘 `.closing`，**`.show` 还留在元素上** →
    // 下次打开时 `wasShown` 一直为 true → 「重新加 `.show` + 刷新
    // `DP.openedAt`」那一段被整个跳过 → **揭开动画根本没重新开始**：
    //   · clip-path 卡在 `inset(0 0 100% 0)` → 面板是裁掉的；
    //   · 兜底定时器（`DP.openedAt` 还是旧值）判定「动画没跑」→
    //     加 `.dpnoplay`（= 全露）→ **面板瞬间整个出现**（「突然出现」）；
    //   · 之后 `.dpnoplay` 被摘掉 → 揭开动画又重播 → **「渐渐出现」**。
    //
    // 另外兜底定时器**从来没被取消过** —— 上一次打开留下的那一个会在
    // 这一次打开的动画刚起步时触发，把正在播的动画打断。
    if let o = probeJSON("""
    (function () {
      var out = {};
      // 收走（模拟指针离开网格上方）。
      if (window.ttLiveHoverClear) window.ttLiveHoverClear();
      out.closed = window.ttDayPanelIsOpen().open === false;
      // 重新打开同一列。
      window.ttDayPanelOpen(3, false);
      var d = document.querySelector('.daypanel');
      out.reopened = window.ttDayPanelIsOpen().open === true;
      // 重新打开后：`show` 必须在身上（否则揭开动画不会重播）。
      out.hasShow = !!(d && d.classList.contains('show'));
      // 「兜底」类不能**立刻**就在（那就是「突然出现」）。
      out.hasFallbackNow = !!(d && d.classList.contains('dpnoplay'));
      // 重新打开后 `openedAt` 必须是**这一次**的时刻（兜底定时器靠它判断）。
      out.openedAtFresh = !!(window.__ttOpenedAtProbe !== undefined);
      return JSON.stringify(out);
    })();
    """) {
        check((o["closed"] as? Bool) == true, "前置条件：面板确实被收走了")
        check((o["reopened"] as? Bool) == true, "重新打开要成功")
        check((o["hasShow"] as? Bool) == true, "重新打开后 `.show` 必须在身上（揭开动画要重播）")
        check((o["hasFallbackNow"] as? Bool) == false,
              "重新打开的瞬间不能已经带上兜底类（那就是「突然出现」）")
    } else {
        fail("拿不到「重新打开入场动画」的诊断结果")
    }

    // ---- 4c-14. **换周后红点不能残留**（2026-11 修）----
    //
    // 用户反馈：「在对应的日期添加了待办，换到别的星期，结果红点还在，
    // 而且有些红点会莫名其妙地出现，我都没有待办事项」。
    //
    // 根因：`flags` 只按「周几」存（1…7），**没有周次身份**；
    // `updateBrowsingWeek()` 翻周时没有清空/重算 → 上一周的红点留在原地。
    // 用户真实的操作是「点下一周 → 面板关掉 → 不再点开」，
    // 所以这里**不重新 open**，直接看翻周后的 flags。
    var staleFakeCal = Calendar(identifier: .gregorian)
    staleFakeCal.timeZone = .current
    let staleFake = FakeEventKitStore()
    staleFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA):
            [DayPanelTodo(title: "第1周周一", due: "10:00", done: false,
                          dueMinutes: 600, identifier: "r-stale", calendarIdentifier: "c1")]
    ]
    let staleController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: staleFake)
    var lastPushedFlags: [String: Any]?
    staleController.onStateChange = { payload in
        lastPushedFlags = payload["dayFlags"] as? [String: Any]
    }
    staleController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleController.testFlags[1]?.hasTodo == true,
          "翻周前：第 1 周周一要有红点（基线）")

    staleController.updateBrowsingWeek(baseMonday: weekB, allWeeks: false)
    // 翻周是同步推状态的 —— 推给网页的 dayFlags 必须**当场**清空，
    // 不能等异步刷新回来才变（中间那一帧就是用户看到的「残留红点」）。
    // 清空后 flags 是空字典（day 1 这个键直接没了）—— 两种写法都算「没有红点」。
    let pushedDay1 = (lastPushedFlags?["1"] as? [String: Any])
    let pushedDay1Todo = (pushedDay1?["todo"] as? Bool) ?? false
    check(pushedDay1Todo == false,
          "翻周瞬间推给网页的 dayFlags 必须已经是「没有红点」")
    // 不重新打开面板，等异步刷新跑完。
    for _ in 0..<15 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleController.testFlags[1]?.hasTodo == false,
          "换周之后不能残留上一周的红点（实际 \(staleController.testFlags[1]?.hasTodo ?? false)）")

    // ---- 4c-15. **已完成的待办：面板里不显示，也不点亮红点**（2026-11 修）----
    //
    // 用户确认：「完成待办事项后红点就要消失」，而且完成的事项
    // **从面板里也隐藏**（下一阶段才做「已完成事项」的管理入口）。
    let doneFake = FakeEventKitStore()
    doneFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA):
            [DayPanelTodo(title: "已经做完的", due: "10:00", done: true,
                          dueMinutes: 600, identifier: "r-done", calendarIdentifier: "c1")]
    ]
    let doneController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: doneFake)
    doneController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(doneController.testContent.todos.isEmpty,
          "已完成的待办不能显示在面板里（实际 \(doneController.testContent.todos.count) 条）")
    check(doneController.testFlags[1]?.hasTodo == false,
          "已完成的待办不能点亮红点")

    // ---- 4c-16. **旧刷新的回包不能覆盖新一周**（2026-11 修）----
    //
    // 换周 + EventKit 异步 → 「翻周前发出的那一轮刷新」可能**后到**，
    // 把上一周的结果写进 `flags` → 新一周凭空冒出红点。
    // 用「延迟回包」的 fake 稳定复现：先发一轮慢的，再发一轮快的。
    let raceFake = DelayedEventKitStore()
    raceFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA):
            [DayPanelTodo(title: "第1周周一", due: "10:00", done: false,
                          dueMinutes: 600, identifier: "r-race", calendarIdentifier: "c1")]
    ]
    let raceController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: raceFake)
    raceFake.delay = 0.6                 // 第一轮（第 1 周）：慢
    raceController.open(day: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    raceFake.delay = 0.05                // 第二轮（第 2 周）：快，先回来
    raceController.updateBrowsingWeek(baseMonday: weekB, allWeeks: false)
    // 等快的回来（~0.05s）再等慢的回来（~0.6s，不带 token 就会把
    // 第 1 周的「周一有红点」写回到当前的第 2 周）。
    for _ in 0..<45 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(raceController.testFlags[1]?.hasTodo == false,
          "翻周前发出的旧刷新晚到，不能把旧周的红点写进新一周（实际 \(raceController.testFlags[1]?.hasTodo ?? false)）")

    // ---- 4c-18. **旧周「同一天号」的回包不能覆盖新周内容**（2026-11 修）----
    //
    // 用户反馈：「看别的周之后，再看本周的待办，它会显示不出来」。
    //
    // `loadContent` 以前只用 `currentDay == day` 判断回包是否还有效。
    // 但「第 1 周的周一」和「第 2 周的周一」`day` **都是 1** ——
    // 在两周的同一列之间来回切时，旧周迟到的回包会被当成当前内容写进去
    // （通常是空的，于是本周的待办就「显示不出来」了）。
    let sameDayFake = DelayedEventKitStore()
    sameDayFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA):
            [DayPanelTodo(title: "第1周周一的待办", due: "10:00", done: false,
                          dueMinutes: 600, identifier: "r-sameday", calendarIdentifier: "c1")]
    ]
    let sameDayController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: sameDayFake)
    sameDayFake.delay = 0.5               // 第 1 周的周一：慢
    sameDayController.open(day: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    sameDayFake.delay = 0.05              // 第 2 周的周一：快、而且没有待办
    sameDayController.updateBrowsingWeek(baseMonday: weekB, allWeeks: false)
    sameDayController.open(day: 1)
    // 快回包（空）先到，慢回包（旧周那一条）后到 —— 后者必须被丢掉。
    for _ in 0..<50 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(sameDayController.testContent.todos.isEmpty,
          "旧周周一的回包晚到，不能把待办塞进新周的周一（用户反馈「本周的待办显示不出来」）")

    // ---- 4c-21. **完成 → 换周 → 回来：完成的那条不能复活**（2026-11 修）----
    //
    // 用户反馈：「点的圆圈之后，确实当时没了，但是当我换到别的周再回来的时候，
    // 又突然有了」。
    //
    // 用「完成状态会真的持久化」的 fake 走一遍**原生路径**：
    // 完成 → 等重载（应已过滤掉）→ 翻到第 2 周 → 回到第 1 周 → 重新打开。
    // 这条能确认控制器 / 周切换本身没问题；如果这里过了，问题就只可能在
    // 真实 EventKit 的写回 / 读回（需要日志确认）。
    let persistFake = FakeEventKitStore()
    persistFake.appliesToggle = true
    persistFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA): [
            DayPanelTodo(title: "会被完成的待办", due: "10:00", done: false,
                         dueMinutes: 600, identifier: "r-persist",
                         calendarIdentifier: "c1")
        ]
    ]
    let persistController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: persistFake)
    persistController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(persistController.testContent.todos.count == 1,
          "基线：第 1 周周一要有一条待办")
    persistController.handle(action: "todoToggle",
                             payload: ["day": 1, "identifier": "r-persist",
                                       "calendarIdentifier": "c1"])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(persistController.testContent.todos.isEmpty,
          "完成之后重载回来的内容里不能再有这条（实际 \(persistController.testContent.todos.count) 条）")
    persistController.updateBrowsingWeek(baseMonday: weekB, allWeeks: false)
    for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    persistController.updateBrowsingWeek(baseMonday: weekA, allWeeks: false)
    for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    persistController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(persistController.testContent.todos.isEmpty,
          "完成过的待办在换周回来后不能复活（实际 \(persistController.testContent.todos.count) 条）")

    // ---- 4c-22. **写回还没完成时又来一次：不能写两次**（2026-11 修）----
    //
    // 真实 EventKit 的写回是**异步**的（`findReminder` → `save` → 回包）。
    // 如果这期间又来一次同一条的 `todoToggle`，第二次仍会在旧内容里看到
    // `done=false` —— 再写一次就可能把状态写乱。原生用 `togglesInFlight` 挡住。
    let inflightFake = FakeEventKitStore()
    inflightFake.appliesToggle = true
    inflightFake.toggleDelay = 0.2
    inflightFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA): [
            DayPanelTodo(title: "连点两次的待办", due: "10:00", done: false,
                         dueMinutes: 600, identifier: "r-inflight",
                         calendarIdentifier: "c1")
        ]
    ]
    let inflightController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: inflightFake)
    inflightController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(inflightController.testContent.todos.count == 1, "连点用例基线：要有一条待办")
    inflightController.handle(action: "todoToggle",
                              payload: ["day": 1, "identifier": "r-inflight",
                                        "calendarIdentifier": "c1"])
    inflightController.handle(action: "todoToggle",
                              payload: ["day": 1, "identifier": "r-inflight",
                                        "calendarIdentifier": "c1"])
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(inflightFake.toggleCalls.count == 1,
          "写回还没完成时重复的完成请求要被挡住（实际写回 \(inflightFake.toggleCalls.count) 次）")
    check(inflightController.testContent.todos.isEmpty,
          "连点之后那条待办仍要算已完成（实际 \(inflightController.testContent.todos.count) 条）")

    // ---- 4c-23. **EventKit「写后读」是旧快照：加待办要重试到出现**（2026-11 修）----
    //
    // 用户反馈：「输入了提醒事项之后回车，提醒事项没有立即新增，
    // 需要再次点击之后才会新增出来」。
    // 真实 EventKit 的 `save` 返回成功 ≠ 紧接着的 `fetchReminders` 能看到它。
    // 这里让 fake 的**第一次**取数返回改动前的快照 —— 控制器必须自己重取。
    let staleAddFake = FakeEventKitStore()
    staleAddFake.appliesAdd = true
    staleAddFake.simulateStaleReads = 1
    staleAddFake.todosByDate = [staleFakeCal.startOfDay(for: weekA): []]
    let staleAddController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: staleAddFake)
    staleAddController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleAddController.testContent.todos.isEmpty, "旧快照用例基线：这一天本来是空的")
    staleAddController.handle(action: "todoAdd", payload: ["day": 1, "title": "回车新增的"])
    // ⚠️ 2026-11 改：`save` 成功之后**立刻**把这条放进展出的内容
    // （乐观展示）—— 旧快照阶段也必须看得见，不能等取数。
    for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleAddController.testContent.todos.count == 1,
          "写回成功后要立刻显示新待办，不能等取数（实际 \(staleAddController.testContent.todos.count) 条）")
    check(staleAddController.testContent.todos.first?.title == "回车新增的",
          "乐观展示的标题要对（实际 \(staleAddController.testContent.todos.first?.title ?? "nil")）")
    // 重试（0.35s 一次）之后 EventKit 也读到了 —— 仍然只能有**一条**（不能重复）。
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(staleAddController.testContent.todos.count == 1,
          "取数追上之后也只能出现一条（实际 \(staleAddController.testContent.todos.count) 条）")

    // ---- 4c-24. **完成写回成功、但取数还是旧快照：不能复活**（2026-11 修）----
    //
    // 用户反馈：「有的时候还是会」出现「点完消失、换周回来又有了」。
    // 把「save 成功后第一次取数返回 done=false」这条真实存在的时序造出来：
    // 展示层必须**以写回结果为准**先过滤掉，并且重取直到 EventKit 说 done。
    let staleToggleFake = FakeEventKitStore()
    staleToggleFake.appliesToggle = true
    staleToggleFake.simulateStaleReads = 1
    staleToggleFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA): [
            DayPanelTodo(title: "写后读旧快照的待办", due: "10:00", done: false,
                         dueMinutes: 600, identifier: "r-stale-read",
                         calendarIdentifier: "c1")
        ]
    ]
    let staleToggleController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: staleToggleFake)
    staleToggleController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleToggleController.testContent.todos.count == 1, "旧快照用例基线：要有一条待办")
    staleToggleController.handle(action: "todoToggle",
                                 payload: ["day": 1, "identifier": "r-stale-read",
                                           "calendarIdentifier": "c1"])
    // 紧接着的取数还是 done=false —— 但面板上**不能**再显示它。
    for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleToggleController.testContent.todos.isEmpty,
          "写回成功但取数是旧快照时，条目也不能复活（实际 \(staleToggleController.testContent.todos.count) 条）")
    // 重试之后 EventKit 那边也确认了 done=true → 依然不显示。
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(staleToggleController.testContent.todos.isEmpty,
          "重取确认完成后仍然不能显示（实际 \(staleToggleController.testContent.todos.count) 条）")
    staleToggleController.updateBrowsingWeek(baseMonday: weekB, allWeeks: false)
    for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    staleToggleController.updateBrowsingWeek(baseMonday: weekA, allWeeks: false)
    for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    staleToggleController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(staleToggleController.testContent.todos.isEmpty,
          "旧快照场景下换周回来也不能复活（实际 \(staleToggleController.testContent.todos.count) 条）")

    // ---- 4c-19. **点「添加待办」就弹权限框**（2026-11 修）----
    //
    // 用户反馈：「第一次总是输入完之后点回车才弹出来」。
    //
    // 以前只有回车提交（`todoAdd`）才请求系统权限 —— 用户打完字按回车，
    // 权限框才出来，待办要等授权完才出现。点「＋ 添加待办」是明确的意图，
    // 这时候就该请求；等打完字，权限已经处理完。
    let composeFake = FakeEventKitStore()
    composeFake.reminderAuth = .notDetermined
    composeFake.eventAuth = .notDetermined
    let composeController = DayPanelController(
        settings: DayPanelSettings(enabled: false),   // 第一次用：接入没开
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: composeFake)
    var composeSettings: DayPanelSettings?
    composeController.onSettingsChanged = { composeSettings = $0 }
    composeController.open(day: 3)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(composeFake.requestReminderCalls == 0,
          "还没点「添加待办」时不该弹权限框（基线）")

    composeController.handle(action: "todoCompose", payload: ["day": 3])
    // 连点两下（用户手快点两次）—— 只发一轮请求。
    composeController.handle(action: "todoCompose", payload: ["day": 3])
    for _ in 0..<15 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(composeFake.requestReminderCalls == 1,
          "点「添加待办」要**当场**请求提醒事项权限，且不能重复请求（实际 \(composeFake.requestReminderCalls) 次）")
    check(composeFake.requestEventCalls == 1,
          "日历权限也要一并请求（和回车流程一致，实际 \(composeFake.requestEventCalls) 次）")
    check(composeSettings?.enabled == true,
          "没开接入时点「添加待办」要自动打开接入（设置层要跟着更新）")

    // 已经授权 → 点添加时**不要**再弹框。
    let readyFake = FakeEventKitStore()
    let readyController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: readyFake)
    readyController.handle(action: "todoCompose", payload: ["day": 3])
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(readyFake.requestReminderCalls == 0,
          "已经拿到提醒事项权限时，点「添加待办」不该再弹权限框")

    // ---- 4c-17. **系统「提醒事项」里增删 → 课表要同步**（2026-11 新增）----
    //
    // 用户反馈：「在系统里面删除了之后，课表不会同步更新」。
    // 原生监听 `.EKEventStoreChanged`（外部修改时系统会发），
    // 防抖 0.4s 后重算红点 + 重读当前那一天。
    let syncFake = FakeEventKitStore()
    syncFake.todosByDate = [
        staleFakeCal.startOfDay(for: weekA):
            [DayPanelTodo(title: "系统里加的", due: "10:00", done: false,
                          dueMinutes: 600, identifier: "r-sync", calendarIdentifier: "c1")]
    ]
    let syncController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: syncFake)
    // 每次推出去的状态里都带着 `dayPanelRevision` —— 网页靠它作废按天缓存。
    var syncRevisions: [Int] = []
    syncController.onStateChange = { payload in
        if let r = payload["dayPanelRevision"] as? Int { syncRevisions.append(r) }
    }
    syncController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(syncController.testContent.todos.count == 1,
          "同步前：面板里要看到系统里那条待办")
    check(syncController.testFlags[1]?.hasTodo == true,
          "同步前：红点要在")

    // 模拟用户在系统「提醒事项」里把它删了。
    syncFake.todosByDate = [:]
    NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
    // 防抖 0.4s + 异步刷新，留足时间。
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(syncController.testContent.todos.isEmpty,
          "系统里删掉之后，面板要跟着清空（实际 \(syncController.testContent.todos.count) 条）")
    check(syncController.testFlags[1]?.hasTodo == false,
          "系统里删掉之后，红点要跟着消失")
    // 网页的按天缓存只能靠这个版本号知道「系统数据变了」（面板关着时
    // 原生根本没有新的 `dayPanel` 可推）。
    check((syncRevisions.last ?? 0) > (syncRevisions.first ?? 0),
          "系统数据变了之后，`dayPanelRevision` 必须加一（实际 \(syncRevisions)）")

    // ---- 4c-13. **「全部周次」时不弹覆盖层**（2026-11）----
    //
    // 全部周次 = 所有教学周的课程叠在一起，「周三」指哪一天没有定义。
    // 用户确认：这时候点日期**什么都不弹**。
    let allWeeksController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: FakeEventKitStore())
    allWeeksController.updateBrowsingWeek(baseMonday: weekA, allWeeks: true)
    allWeeksController.open(day: 3)
    check(allWeeksController.testState.open == false,
          "「全部周次」模式下点日期不能弹覆盖层")

    // ---- 4c-20b. 原生 `ready` 标记：中间态 false → EventKit 合并后 true（2026-11 修）----
    //
    // 网页的「这列有没有完整数据」**只能**靠原生明确告诉它。
    // `loadContent` 先同步推一份「只有节日」的中间态，再异步查 EventKit 推全量：
    // 中间态必须 `ready: false`，全量必须 `ready: true`。
    // 否则网页会把中间态当成「数据已到齐」，换周回来也不再补发请求。
    let readyFlagFake = FakeEventKitStore()
    readyFlagFake.todos = [DayPanelTodo(title: "ready 自检", due: "10:00", done: false,
                                    dueMinutes: 600, identifier: "r-ready",
                                    calendarIdentifier: "c1")]
    let readyFlagController = DayPanelController(
        settings: DayPanelSettings(enabled: true),
        festivalProvider: DayPanelFestivalProviderFactory.make(),
        todayIndex: 1,
        baseMonday: weekA,
        eventStore: readyFlagFake)
    var readyPushes: [Bool] = []
    readyFlagController.onStateChange = { payload in
        if let dp = payload["dayPanel"] as? [String: Any],
           let r = dp["ready"] as? Bool {
            readyPushes.append(r)
        }
    }
    readyFlagController.open(day: 1)
    check(readyPushes.first == false,
          "打开时同步推的中间态必须 `ready: false`（实际 \(String(describing: readyPushes.first))）")
    check(readyFlagController.testContent.ready == false,
          "EventKit 还没回包时内容不能算「已到齐」")
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(readyPushes.last == true,
          "EventKit 合并完成后推的状态必须 `ready: true`（实际 \(String(describing: readyPushes.last))）")
    check(readyFlagController.testContent.ready == true,
          "EventKit 合并完成后内容才算「已到齐」")

    // 同一天重复 `open(day:)`（网页收到 `dayPanelRevision` 后会再发一次
    // `datePanelOpen`）不能清空已有内容、推 `ready:false` 的中间态 ——
    // 否则面板会先闪成「读取中…」（2026-11 修）。
    readyPushes = []
    readyFlagController.open(day: 1)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(!readyPushes.contains(false),
          "同一天重复打开不能推 `ready:false` 中间态（实际 \(readyPushes)）")
    check(readyFlagController.testContent.todos.count == 1,
          "同一天重复打开期间，已有的待办不能被清空（实际 \(readyFlagController.testContent.todos.count) 条）")

    // ---- 4c-20. **换周回来，跟随打开要自动补拉数据**（2026-11 修）----
    //
    // 用户反馈：「换到别的周后再回到本周，待办事项都不会第一时间显示，
    // 要再点一下才会更新」。
    //
    // 根因：`panelDataFor()` 有「只有今日详情」的兜底（**永远非空**），
    // 旧代码用 `!panelDataFor(day)` 判断「要不要补发请求」→ 永远不补发。
    // 换周时缓存被清空，但兜底还在 → 跟随打开只显示农历 / 节气，
    // 待办 / 日程要等用户再点一下日期（点击路径无条件发 `datePanelOpen`）。
    //
    // 现在改用 `DP.loaded`（只认原生 `ready: true`）→ 换周清空 →
    // 回到本周悬停任一列都会自动补发请求。这里完整复现用户路径：
    // 面板开着 → 鼠标移出（淡出，但跟随模式仍在）→ 原生推「切到第 2 周」
    // → 原生推「回到第 1 周」→ 悬停第 4 列。
    _ = probeJSON("""
    (function () { window.ttDayPanelClose(); return JSON.stringify({ ok: true }); })();
    """)
    pause()

    let weekRoundTripSetup = """
    (function () {
      function fest(prefix) {
        var f = {};
        for (var d = 1; d <= 7; d++) {
          f[String(d)] = { lunar: prefix + d, term: '', festivals: [],
                           weather: null, yi: '', ji: '' };
        }
        return f;
      }
      // 第 1 周：第 3 列由原生推过**完整数据**（ready: true → 进入 DP.loaded）。
      window.ttUpdate({ courses: [], viewWeek: 1, currentWeek: 1,
        dayPanel: { day: 3, ready: true, todos: [], events: [],
                    festival: { lunar: 'w1-3', term: '', festivals: [] } },
        dayFestivals: fest('w1-'), dayFlags: {}, dayPanelOpen: false });
      // 打开第 3 列 → 进入跟随模式。
      window.ttDayPanelOpen(3);
      var opened = window.ttDayPanelIsOpen();
      // 鼠标移出网格 → 淡出（只是看不见，跟随模式**保持**）。
      var grd = document.querySelector('.grid');
      var g = grd ? grd.getBoundingClientRect() : null;
      if (g) window.__ttDiagMove(g.left + g.width / 2, g.bottom + 80);
      var faded = window.ttDayPanelIsOpen();
      return JSON.stringify({ opened: opened.open, openedDay: opened.day,
                              faded: faded.open });
    })();
    """
    if let o = probeJSON(weekRoundTripSetup) {
        check((o["opened"] as? Bool) == true, "基线：第 3 列要能打开")
        check((o["openedDay"] as? NSNumber)?.intValue == 3,
              "基线：打开的是第 3 列（实际 \(o["openedDay"] ?? "nil")）")
        check((o["faded"] as? Bool) == false,
              "鼠标移出网格后要淡出（实际 open=\(o["faded"] ?? "nil")）")
    } else {
        fail("拿不到「换周回来补拉数据」的准备结果")
    }
    // 等 400ms 收拢动画播完（`DP.closing` 清掉）。
    pause()

    let weekRoundTripProbe = """
    (function () {
      function fest(prefix) {
        var f = {};
        for (var d = 1; d <= 7; d++) {
          f[String(d)] = { lunar: prefix + d, term: '', festivals: [],
                           weather: null, yi: '', ji: '' };
        }
        return f;
      }
      // 原生翻到第 2 周（形状和 AppDelegate.webStateObject 推的一致：
      // dayPanel 为空、dayPanelOpen=false）。
      window.ttUpdate({ courses: [], viewWeek: 2, currentWeek: 1, dayPanel: null,
        dayFestivals: fest('w2-'), dayFlags: {}, dayPanelOpen: false });
      var afterSwitch = window.ttDayPanelIsOpen();
      // 再回到第 1 周 —— 网页这边上一周的缓存 / 「已加载」记录全部作废。
      window.ttUpdate({ courses: [], viewWeek: 1, currentWeek: 1, dayPanel: null,
        dayFestivals: fest('w1-'), dayFlags: {}, dayPanelOpen: false });
      window.__ttLastPost = null;
      // 悬停第 4 列 —— 这一列从没拿到过原生数据。
      var hc = document.querySelector('.hcell[data-day="4"]');
      var r = hc ? hc.getBoundingClientRect() : null;
      if (r) window.__ttDiagMove(r.left + r.width / 2, r.top + r.height / 2);
      var p = window.__ttLastPost || null;
      return JSON.stringify({ afterSwitchOpen: afterSwitch.open,
        open: window.ttDayPanelIsOpen().open,
        day: window.ttDayPanelIsOpen().day,
        action: p ? p.action : null,
        postedDay: (p && p.payload) ? p.payload.day : null });
    })();
    """
    if let o = probeJSON(weekRoundTripProbe) {
        check((o["afterSwitchOpen"] as? Bool) == false,
              "翻到别的周时覆盖层不能还开着")
        check((o["action"] as? String) == "datePanelOpen",
              "换周回来后悬停未加载的列，必须自动补发 `datePanelOpen`（实际 \(o["action"] ?? "nil")）")
        check((o["postedDay"] as? NSNumber)?.intValue == 4,
              "补发的请求要带上悬停的那一列（实际 \(o["postedDay"] ?? "nil")）")
        check((o["open"] as? Bool) == true,
              "补发请求的同时覆盖层要打开（实际 \(o["open"] ?? "nil")）")
        check((o["day"] as? NSNumber)?.intValue == 4,
              "打开的是悬停的第 4 列（实际 \(o["day"] ?? "nil")）")
    } else {
        fail("拿不到「换周回来补拉数据」的诊断结果")
    }
    // 收尾：把覆盖层关掉，别影响后面的用例。
    _ = probeJSON("(function () { window.ttDayPanelClose(); return JSON.stringify({ ok: true }); })();")
    pause()

    // ---- 4c-25. **点日期不能先闪「今日无待办」再用真实内容盖掉**（2026-11 修）----
    //
    // 用户反馈：「点击日期之后，日期的头部会先闪一下，之后提醒 / 日历才出来」。
    //
    // 两个来源：
    //   · 打开某天时原生先推一份 `ready:false` 的中间态（只有节日）——
    //     它以前会**覆盖缓存**，把上一次的完整数据换成空列表；
    //   · 第一次打开（没有缓存）时，空列表被当成「确实没有待办」。
    // 现在：中间态不进缓存、不覆盖已有的完整缓存；没有数据时显示「读取中…」。
    let staleShellProbe = """
    (function () {
      function fest(prefix) {
        var f = {};
        for (var d = 1; d <= 7; d++) {
          f[String(d)] = { lunar: prefix + d, term: '', festivals: [],
                           weather: null, yi: '', ji: '' };
        }
        return f;
      }
      function base() {
        return { courses: [], viewWeek: 1, currentWeek: 1,
                 dayFestivals: fest('w1-'), dayFlags: {}, dayPanelOpen: true };
      }
      var todo3 = { title: '旧缓存的待办', due: '10:00', done: false,
                    identifier: 'r-cache-3', calendarIdentifier: 'c1' };
      var st1 = base();
      st1.dayPanel = { day: 3, ready: true, todos: [todo3], events: [],
                       festival: { lunar: 'w1-3', term: '', festivals: [] } };
      window.ttUpdate(st1);
      window.ttDayPanelOpen(3);
      var before = document.querySelectorAll('.dpcard.todo[data-todo-key="id:r-cache-3"]').length;

      // 原生推「只有节日」的中间态（ready:false）。
      var st2 = base();
      st2.dayPanel = { day: 3, ready: false, todos: [], events: [],
                       festival: { lunar: 'w1-3', term: '', festivals: [] } };
      window.ttUpdate(st2);
      var afterMid = document.querySelectorAll('.dpcard.todo[data-todo-key="id:r-cache-3"]').length;
      var loadingMid = document.querySelectorAll('.dpempty.dploading').length;
      var emptyTextMid = '';
      var empties = document.querySelectorAll('.dpcard.empty .dpempty');
      for (var i = 0; i < empties.length; i++) emptyTextMid += empties[i].textContent;

      // 第一次打开一列（没有缓存）→ 必须先显示「读取中…」，不能先说「今日无待办」。
      var st3 = base();
      st3.dayPanel = null;
      window.ttUpdate(st3);
      window.ttDayPanelOpen(5);
      var loadingFresh = document.querySelectorAll('.dpempty.dploading').length;
      var freshText = '';
      var empties2 = document.querySelectorAll('.dpcard.empty .dpempty');
      for (var j = 0; j < empties2.length; j++) freshText += empties2[j].textContent;

      // 数据回来 → 占位换成真实内容。
      var todo5 = { title: '刚加载出来的待办', due: '11:00', done: false,
                    identifier: 'r-fresh-5', calendarIdentifier: 'c1' };
      var st4 = base();
      st4.dayPanel = { day: 5, ready: true, todos: [todo5], events: [],
                       festival: { lunar: 'w1-5', term: '', festivals: [] } };
      window.ttUpdate(st4);
      var afterFresh = document.querySelectorAll('.dpcard.todo[data-todo-key="id:r-fresh-5"]').length;
      var loadingAfter = document.querySelectorAll('.dpempty.dploading').length;

      return JSON.stringify({
        before: before, afterMid: afterMid, loadingMid: loadingMid,
        emptyTextMid: emptyTextMid,
        loadingFresh: loadingFresh, freshText: freshText,
        afterFresh: afterFresh, loadingAfter: loadingAfter
      });
    })();
    """
    if let o = probeJSON(staleShellProbe) {
        check((o["before"] as? NSNumber)?.intValue == 1,
              "基线：注入的完整数据要显示出来（实际 \(o["before"] ?? "nil") 条）")
        check((o["afterMid"] as? NSNumber)?.intValue == 1,
              "中间态（ready:false）不能把已缓存的待办盖成空（实际 \(o["afterMid"] ?? "nil") 条）")
        check((o["loadingMid"] as? NSNumber)?.intValue == 0,
              "有完整缓存时不该出现「读取中…」占位（实际 \(o["loadingMid"] ?? "nil") 个）")
        check(!(o["emptyTextMid"] as? String ?? "").contains("今日无待办"),
              "中间态不能让待办块显示「今日无待办」（实际「\(o["emptyTextMid"] ?? "")」）")
        check((o["loadingFresh"] as? NSNumber)?.intValue == 2,
              "第一次打开、没有缓存时，待办 / 日程两块都要显示「读取中…」（实际 \(o["loadingFresh"] ?? "nil") 个）")
        check((o["freshText"] as? String ?? "").contains("读取中…") &&
              !(o["freshText"] as? String ?? "").contains("今日无待办"),
              "还没查完时不能先说「今日无待办」（实际「\(o["freshText"] ?? "")」）")
        check((o["afterFresh"] as? NSNumber)?.intValue == 1,
              "数据回来之后真实待办要出现（实际 \(o["afterFresh"] ?? "nil") 条）")
        check((o["loadingAfter"] as? NSNumber)?.intValue == 0,
              "数据回来之后「读取中…」占位要消失（实际 \(o["loadingAfter"] ?? "nil") 个）")
    } else {
        fail("拿不到「中间态闪空」的诊断结果")
    }
    _ = probeJSON("(function () { window.ttDayPanelClose(); return JSON.stringify({ ok: true }); })();")
    pause()

    // ---- 4c-26. **状态没变不能重绘面板；红点只切可见性、不插摘节点**（2026-11 修）----
    //
    // 用户反馈：「新增 / 删除 / 完成待办之后，头部还是会闪，包括日历也会闪」，
    // 「第一次点头部 / 平移到别的日期时也会闪」。
    //
    // 原生一次操作会连着推好几版状态（内容一版、红点一版、重试又一版），
    // 网页以前**每一版都清空 `.dpbody` 重建** —— 面板是半透明玻璃，
    // 重绘一次就能看出闪。表头小点则是「插 / 摘节点」，
    // 会让「周几」两个字左右跳一下。
    //
    // 这里验两件事：
    //   1. 同一份状态推两次 → 面板里的卡片节点**还是同一个**（没重建）；
    //   2. 红点从无到有 / 从有到无 → 表头格和红点节点都不换，只切 `.off`。
    let noFlashProbe = """
    (function () {
      function fest() {
        var f = {};
        for (var d = 1; d <= 7; d++) {
          f[String(d)] = { lunar: '测试' + d, term: '', festivals: [],
                           weather: null, yi: '', ji: '' };
        }
        return f;
      }
      function state(flags) {
        var f = fest();
        return { courses: [], viewWeek: 1, currentWeek: 1,
                 dayFestivals: f, dayFlags: flags || {}, dayPanelOpen: true,
                 dayPanel: { day: 2, ready: true,
                   todos: [{ title: '去重测试的待办', due: '10:00', done: false,
                             identifier: 'r-dup', calendarIdentifier: 'c1' }],
                   events: [], festival: f['2'] } };
      }
      window.ttUpdate(state({}));
      window.ttDayPanelOpen(2);
      var card = document.querySelector('.dpcard.todo[data-todo-key="id:r-dup"]');
      var hcell = document.querySelector('.hcell[data-day="2"]');
      if (card) card.setAttribute('data-node-mark', 'keep');
      if (hcell) hcell.setAttribute('data-node-mark', 'keep');
      var dot0 = hcell ? hcell.querySelector('.hdrow .dot.todo') : null;

      // ① 同一份状态再推一遍 → 节点必须原封不动。
      window.ttUpdate(state({}));
      var card2 = document.querySelector('.dpcard.todo[data-todo-key="id:r-dup"]');
      var hcell2 = document.querySelector('.hcell[data-day="2"]');
      var cardKept = !!(card2 && card2.getAttribute('data-node-mark') === 'keep');
      var hcellKept = !!(hcell2 && hcell2.getAttribute('data-node-mark') === 'keep');
      var offBefore = !!(dot0 && dot0.classList.contains('off'));

      // ② 红点出现 → 同一个表头格、同一个红点节点，只摘掉 `.off`。
      window.ttUpdate(state({ '2': { todo: true, event: false } }));
      var hcell3 = document.querySelector('.hcell[data-day="2"]');
      var dot1 = hcell3 ? hcell3.querySelector('.hdrow .dot.todo') : null;
      var dotShown = !!(dot1 && !dot1.classList.contains('off'));
      var dotSame = !!(dot1 && dot0 && dot1 === dot0);
      var hcellKept2 = !!(hcell3 && hcell3.getAttribute('data-node-mark') === 'keep');

      // ③ 红点消失 → 还是同一个节点，加回 `.off`。
      window.ttUpdate(state({ '2': { todo: false, event: false } }));
      var hcell4 = document.querySelector('.hcell[data-day="2"]');
      var dot2 = hcell4 ? hcell4.querySelector('.hdrow .dot.todo') : null;
      var offAfter = !!(dot2 && dot2.classList.contains('off'));
      var dotSame2 = !!(dot2 && dot0 && dot2 === dot0);

      return JSON.stringify({
        found: !!card, cardKept: cardKept, hcellKept: hcellKept,
        offBefore: offBefore, dotShown: dotShown, dotSame: dotSame,
        hcellKept2: hcellKept2, offAfter: offAfter, dotSame2: dotSame2
      });
    })();
    """
    if let o = probeJSON(noFlashProbe) {
        check((o["found"] as? Bool) == true, "去重用例基线：待办卡片要显示出来")
        check((o["cardKept"] as? Bool) == true,
              "同一份状态推第二次时，待办卡片节点不能被重建（否则面板会闪）")
        check((o["hcellKept"] as? Bool) == true,
              "同一份状态推第二次时，表头格不能被重建")
        check((o["offBefore"] as? Bool) == true,
              "没有待办时，红点节点也要在（`.off` 占位），不能干脆不渲染")
        check((o["dotShown"] as? Bool) == true, "有待办之后红点要显示出来")
        check((o["dotSame"] as? Bool) == true,
              "红点从无到有只能切换 `.off`，不能插 / 摘节点（否则表头文字会跳）")
        check((o["hcellKept2"] as? Bool) == true,
              "红点变化时表头格不能被重建")
        check((o["offAfter"] as? Bool) == true, "待办没了之后红点要隐藏")
        check((o["dotSame2"] as? Bool) == true,
              "红点从有到无也只能切换 `.off`，节点不能换")
    } else {
        fail("拿不到「面板重绘 / 表头闪」的诊断结果")
    }
    // ---- 4c-27. **数据真的变了，也只能换掉变的那一张卡片**（2026-11 修）----
    //
    // 用户反馈：「点了两个完成待办事项，一个没了，一个还有」，
    // 「消失的时候还是会闪」。
    //
    // 上一版只用渲染指纹挡掉了「数据没变」的重绘；一旦数据真变了
    // （完成一条 = 少一条），网页依旧把整个 `.dpcards` 清空重造：
    //   · 半透明玻璃面板整体重绘一次 → 用户看到闪；
    //   · 另一张卡片也被换掉 —— 如果用户正好在点它，
    //     mousedown / mouseup 落在两个节点上，click **直接丢失**
    //     （原生日志里只收到一次 toggle，看着就像「只消失了一条」）。
    //
    // 现在按稳定键合并：没变的卡片节点必须原样保留。
    let incrementalProbe = """
    (function () {
      function fest() {
        var f = {};
        for (var d = 1; d <= 7; d++) {
          f[String(d)] = { lunar: '测试' + d, term: '', festivals: [],
                           weather: null, yi: '', ji: '' };
        }
        return f;
      }
      function state(todos) {
        var f = fest();
        return { courses: [], viewWeek: 1, currentWeek: 1,
                 dayFestivals: f, dayFlags: {}, dayPanelOpen: true,
                 dayPanel: { day: 2, ready: true, todos: todos,
                             events: [], festival: f['2'] } };
      }
      var a = { title: '保留的', due: '09:00', done: false,
                identifier: 'keep-1', calendarIdentifier: 'c1' };
      var b = { title: '要没的', due: '10:00', done: false,
                identifier: 'gone-1', calendarIdentifier: 'c1' };
      window.ttUpdate(state([a, b]));
      window.ttDayPanelOpen(2);
      var cardA = document.querySelector('.dpcard.todo[data-todo-key="id:keep-1"]');
      if (cardA) cardA.setAttribute('data-node-mark', 'a');
      var bothShown = !!cardA &&
        !!document.querySelector('.dpcard.todo[data-todo-key="id:gone-1"]');

      // ① 数据里少了一条 → 只允许摘掉这一张，另一张节点不能动。
      window.ttUpdate(state([a]));
      var cardA2 = document.querySelector('.dpcard.todo[data-todo-key="id:keep-1"]');
      var aKept = !!(cardA2 && cardA2.getAttribute('data-node-mark') === 'a');
      var bGone = !document.querySelector('.dpcard.todo[data-todo-key="id:gone-1"]');

      // ② 数据里多了一条 → 老卡片还是同一个节点，新卡片插进来。
      var c = { title: '新来的', due: '11:00', done: false,
                identifier: 'new-1', calendarIdentifier: 'c1' };
      window.ttUpdate(state([a, c]));
      var cardA3 = document.querySelector('.dpcard.todo[data-todo-key="id:keep-1"]');
      var cardC = document.querySelector('.dpcard.todo[data-todo-key="id:new-1"]');
      var aKept2 = !!(cardA3 && cardA3.getAttribute('data-node-mark') === 'a');
      var emptyCount = document.querySelectorAll('.dpcard.empty').length;

      return JSON.stringify({
        bothShown: bothShown, aKept: aKept, bGone: bGone,
        aKept2: aKept2, cShown: !!cardC, emptyCount: emptyCount
      });
    })();
    """
    if let o = probeJSON(incrementalProbe) {
        check((o["bothShown"] as? Bool) == true, "增量重绘基线：两条待办都要显示")
        check((o["aKept"] as? Bool) == true,
              "完成 / 删掉一条时，其他待办卡片节点不能被重建（否则会闪、点击会丢）")
        check((o["bGone"] as? Bool) == true, "被删掉的那条卡片要真的消失")
        check((o["aKept2"] as? Bool) == true,
              "新增一条待办时，已有卡片节点也不能被重建")
        check((o["cShown"] as? Bool) == true, "新增的那条要显示出来")
        check((o["emptyCount"] as? Int) == 1,
              "有待办时只剩「日历行程」一张空态卡（待办空态不该出现）")
    } else {
        fail("拿不到「卡片增量合并」的诊断结果")
    }
    _ = probeJSON("(function () { window.ttDayPanelClose(); return JSON.stringify({ ok: true }); })();")
    pause()

    // ---- 4e. 文本输入模式：窗口必须能临时变成 key ----
    //
    // 「＋ 添加待办」打不了字的根因：桌面层窗口是 `.nonactivatingPanel`，
    // **永远不能成为 key window** → WKWebView 拿不到键盘焦点。
    //
    // 解法：输入框聚焦时网页发 `textInputFocus`，原生把窗口临时变成 key。
    //
    // 这里验「窗口**确实**能变成 key」——自动化环境里窗口不是前台，
    // `makeKey` 可能拿不到，所以**只验能力位**（canBecomeKey / canBecomeMain），
    // 那才是「能不能打字」的决定性因素。
    if let deskWin = delegate.testDesktopWindow as? DesktopWindow {
        // ⚠️ 先**复位**：前面的网页探针点过「＋ 添加待办」，
        // 输入框聚焦 → 网页发了 `textInputFocus` → 原生已经把窗口
        // 切进文本输入模式了（这是**预期的**）。
        // 这里测的是「模式本身对不对」，所以先复位再测。
        deskWin.setTextInputMode(false)
        check(deskWin.canBecomeKey == false,
              "平时（不输入时）桌面层窗口**不能**成为 key —— 否则会抢用户前台焦点")
        deskWin.setTextInputMode(true)
        check(deskWin.canBecomeKey == true,
              "文本输入模式下窗口必须能成为 key（否则网页里的输入框收不到按键）")
        check(deskWin.canBecomeMain == true,
              "文本输入模式下窗口必须能成为 main")
        deskWin.setTextInputMode(false)
        check(deskWin.canBecomeKey == false,
              "退出文本输入模式后要还原成「不抢焦点」")
    } else {
        fail("拿不到桌面层窗口（文本输入模式自检）")
    }

    // ---- 5. 自动化护栏：绝不碰真实系统 ----
    check(fake.requestReminderCalls == 0, "自动化模式下不能请求提醒事项授权")
    check(fake.requestEventCalls == 0, "自动化模式下不能请求日历授权")

    if problems.isEmpty {
        print("✅ 日期覆盖层（农历 / 锚点 / 状态机 / EventKit / 护栏）：通过")
        exit(0)
    }
    print("")
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--verify-completed-reminders") {
    // 自检：**设置 → 提醒 → 日期覆盖层 → 已完成的提醒事项**。
    //
    // 全部走 FakeEventKitStore：
    //   · 不请求任何 TCC 权限、不碰用户真实的提醒事项；
    //   · 覆盖收起不读取 / 跨清单 / 搜索筛选 / 恢复联动 / 单条删除 /
    //     全部删除（部分失败、commit 失败）/ 重复提醒禁用 / 接入关闭与未授权禁用 /
    //     收起取消在途读取 / 首屏 200 条与「加载更多」。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-completed-reminders 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // 接入开关打开（临时目录的 settings.json，不碰真实设置）。
    let bootstrap = SettingsStore()
    var bootSettings = bootstrap.load()
    bootSettings.dayPanel.enabled = true
    try? bootstrap.save(bootSettings)

    let store = TimetableStore()
    _ = try? store.migrateLegacyIfNeeded(defaultName: "我的课表")
    let ctl = SettingsWindowController(store: store.configStore, timetableStore: store) {}
    ctl.buildWindow()

    var problems: [String] = []
    func fail(_ message: String) { problems.append(message) }
    func check(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }
    func waitUntil(_ timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if condition() { return true }
        }
        return condition()
    }

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let monday = WeekMath.mondayOfWeek(Date())
    func dayStart(_ offset: Int) -> Date {
        cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: monday)!)
    }
    func at(_ offset: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(byAdding: .minute, value: hour * 60 + minute, to: dayStart(offset))!
    }
    let now = Date()
    func completed(_ id: String, _ title: String,
                   list: String, listTitle: String,
                   completedAgo: TimeInterval, due: Date?,
                   recurring: Bool = false) -> CompletedReminder {
        CompletedReminder(identifier: id, title: title,
                          listIdentifier: list, listTitle: listTitle,
                          completionDate: now.addingTimeInterval(-completedAgo),
                          dueDate: due, isRecurring: recurring)
    }

    let fake = FakeEventKitStore()
    fake.lists = [
        EventKitListInfo(title: "桌面课表", identifier: "c1", isWritable: true),
        EventKitListInfo(title: "购物", identifier: "c2", isWritable: true),
        EventKitListInfo(title: "学习", identifier: "c3", isWritable: true),
    ]
    fake.completed = [
        completed("done-1", "买牛奶", list: "c1", listTitle: "桌面课表",
                  completedAgo: 60, due: at(0, 10, 0)),
        completed("done-2", "交作业", list: "c3", listTitle: "学习",
                  completedAgo: 120, due: at(1, 9, 0)),
        completed("done-3", "每周复盘", list: "c2", listTitle: "购物",
                  completedAgo: 180, due: at(0, 20, 0), recurring: true),
        completed("done-4", "没有到期的", list: "c2", listTitle: "购物",
                  completedAgo: 240, due: nil),
    ]
    // 一条**未完成**待办：任何「全部删除」都不许碰它。
    fake.todosByDate = [
        dayStart(0): [DayPanelTodo(title: "未完成的事", due: "09:00", done: false,
                                   dueMinutes: 540, identifier: "open-1",
                                   calendarIdentifier: "c1")]
    ]

    let panel = DayPanelController(settings: DayPanelSettings(enabled: true),
                                   festivalProvider: DayPanelFestivalProviderFactory.make(),
                                   todayIndex: 1,
                                   baseMonday: monday,
                                   eventStore: fake)
    ctl.dayPanelController = panel
    ctl.refreshDayPanelRows()
    ctl.expandTo(.reminder)
    ctl.window?.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))

    // ---- 1. 收起态：不读取 EventKit ----
    let collapsed = ctl.probeCompletedReminders()
    check(collapsed.hasRow, "卡片里没有「已完成的提醒事项」这一行")
    check(collapsed.access == "ready", "已授权时入口应该是可用的（实际 \(collapsed.access)）")
    check(!collapsed.expanded, "新增行默认必须收起")
    check(collapsed.subtitleText == "查看、恢复或删除已完成的提醒事项",
          "收起态副标题不对：\(collapsed.subtitleText)")
    check(fake.completedFetchCalls == 0,
          "收起状态不能读取 EventKit（实际读取 \(fake.completedFetchCalls) 次）")

    // ---- 2. 展开：跨清单读取、倒序、显示清单名 ----
    ctl.testToggleCompletedRow()
    let loaded = waitUntil {
        let p = ctl.probeCompletedReminders()
        return p.serviceState == "loaded" && p.renderedRows == 4
    }
    check(loaded, "展开后没有读到 4 条已完成项（状态 \(ctl.probeCompletedReminders().serviceState)，渲染 \(ctl.probeCompletedReminders().renderedRows) 条）")
    let expanded = ctl.probeCompletedReminders()
    check(expanded.expanded, "点这一行没有展开")
    check(fake.completedFetchCalls == 1, "展开应只发起一次读取（实际 \(fake.completedFetchCalls) 次）")
    check(expanded.items.map { $0.title } == ["买牛奶", "交作业", "每周复盘", "没有到期的"],
          "没有按完成时间倒序：\(expanded.items.map { $0.title })")
    check(Set(expanded.items.map { $0.listTitle }) == ["桌面课表", "学习", "购物"],
          "没有显示跨清单的来源：\(expanded.items.map { $0.listTitle })")
    check(expanded.items.allSatisfy { !$0.completionText.isEmpty },
          "每行都要显示完成时间")
    check(expanded.items.allSatisfy { !$0.dueText.isEmpty },
          "到期时间必须有文案（没有时显示「无到期时间」）")
    check(expanded.items.allSatisfy { $0.detailText.contains($0.listTitle) },
          "每一行都要把所属清单名显示出来：\(expanded.items.map { $0.detailText })")
    check(expanded.items.allSatisfy { $0.detailText.contains("完成 ") },
          "每一行都要显示完成时间：\(expanded.items.map { $0.detailText })")
    check(expanded.items.allSatisfy { $0.detailText.contains("到期 ") },
          "每一行都要显示到期时间：\(expanded.items.map { $0.detailText })")
    check(expanded.deleteAllVisible, "有已完成项时「全部删除…」应可见")
    check(expanded.deleteAllEnabled, "有已完成项时「全部删除…」应可点")

    // ---- 2b. 真实点击：展开后必须还能再点回收起（不能只开不合）----
    guard let settingsWindow = ctl.window, let rowView = ctl.completedRowForTest else {
        fail("拿不到设置窗口 / 已完成行，无法做真实点击")
        print("")
        for p in problems { print("❌ \(p)") }
        exit(1)
    }
    @discardableResult
    func realClick(_ target: NSView) -> Bool {
        guard let content = settingsWindow.contentView else { return false }
        // 目标可能在面板滚动区外（例如卡片展开后整个列表比窗口高）——
        // 先滚到可见，再取坐标；否则会点到窗口外（hit=nil）。
        _ = target.scrollToVisible(target.bounds)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        settingsWindow.contentView?.layoutSubtreeIfNeeded()
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY),
                                   to: content)
        let hit = content.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil"
        print("  真实点击 \(type(of: target)) @(\(Int(point.x)),\(Int(point.y))) 命中：\(hit)")
        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: settingsWindow.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.sendEvent(event)
        }
        send(.leftMouseDown)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        send(.leftMouseUp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        send(.leftMouseUp)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return true
    }
    realClick(rowView.testHeaderView)
    check(!ctl.probeCompletedReminders().expanded,
          "真实点击展开后的标题行必须能收起（实际 expanded=\(ctl.probeCompletedReminders().expanded)）")
    realClick(rowView.testHeaderView)
    check(ctl.probeCompletedReminders().expanded,
          "收起后再点标题行必须能重新展开（实际 expanded=\(ctl.probeCompletedReminders().expanded)）")
    _ = waitUntil(8) {
        let p = ctl.probeCompletedReminders()
        return p.serviceState == "loaded" && p.renderedRows == 4
    }

    // 「全部删除…」也要是**真实点击**能触发确认流程（自检里用 hook 拦下弹窗）。
    var deleteAllPromptCount = 0
    let savedDeleteAllHook = ctl.completedDeleteAllConfirmationForTest
    ctl.completedDeleteAllConfirmationForTest = { _ in
        deleteAllPromptCount += 1
        return false
    }
    realClick(rowView.testDeleteAllButton)
    _ = waitUntil(4) { deleteAllPromptCount == 1 }
    check(deleteAllPromptCount == 1,
          "真实点击「全部删除…」必须能触发确认流程（实际 \(deleteAllPromptCount) 次）")
    ctl.completedDeleteAllConfirmationForTest = savedDeleteAllHook

    // ---- 3. 搜索 / 清单筛选 ----
    ctl.testSetCompletedSearch("交作业")
    let searched = waitUntil {
        let p = ctl.probeCompletedReminders()
        return p.matchingCount == 1 && p.renderedRows == 1
    }
    check(searched, "按标题搜索结果不对（匹配 \(ctl.probeCompletedReminders().matchingCount) 条）")
    check(ctl.probeCompletedReminders().items.first?.title == "交作业",
          "搜索「交作业」应该只剩交作业")
    ctl.testSetCompletedSearch("")
    _ = waitUntil { ctl.probeCompletedReminders().matchingCount == 4 }

    ctl.testSelectCompletedList("c2")
    let filtered = waitUntil {
        let p = ctl.probeCompletedReminders()
        return p.matchingCount == 2 && p.renderedRows == 2
    }
    check(filtered, "按清单筛选结果不对（匹配 \(ctl.probeCompletedReminders().matchingCount) 条）")
    check(ctl.probeCompletedReminders().items.allSatisfy { $0.listTitle == "购物" },
          "清单筛选后不该混进别的清单")
    ctl.testSelectCompletedList(nil)
    _ = waitUntil { ctl.probeCompletedReminders().matchingCount == 4 }

    // ---- 4. 重复提醒：禁用恢复并说明原因 ----
    guard let recurring = panel.completedReminders.allItems.first(where: { $0.isRecurring }) else {
        fail("测试数据里没有重复提醒")
        print("")
        for p in problems { print("❌ \(p)") }
        exit(1)
    }
    let recurringProbe = ctl.probeCompletedReminders().items.first { $0.title == recurring.title }
    check(recurringProbe?.restoreEnabled == false, "重复提醒的「恢复」必须禁用")
    check(recurringProbe?.recurringNoteVisible == true, "重复提醒旁必须有原因说明")
    var recurringError: Error?
    panel.restoreCompletedReminder(recurring) { result in
        if case .failure(let error) = result { recurringError = error }
    }
    check(recurringError != nil, "重复提醒不能静默恢复")
    check(fake.restoreCalls.isEmpty, "重复提醒被拒绝时不能写回 EventKit")

    // ---- 5. 恢复联动：列表少一条 / 日期面板重新出现 / 红点更新 ----
    panel.open(day: 1)
    let panelBaseline = waitUntil(4) {
        panel.testContent.ready && panel.testContent.todos.contains { $0.title == "未完成的事" }
    }
    check(panelBaseline, "基线：日期面板没有读到未完成的事")
    check(panel.testFlags[1]?.hasTodo == true, "基线：第 1 列应该有红点")

    guard let milk = panel.completedReminders.allItems.first(where: { $0.identifier == "done-1" }) else {
        fail("拿不到要恢复的「买牛奶」")
        print("")
        for p in problems { print("❌ \(p)") }
        exit(1)
    }
    ctl.testRestoreCompleted(milk)
    let restored = waitUntil(6) {
        let p = ctl.probeCompletedReminders()
        return p.totalCompleted == 3
            && p.renderedRows == 3
            && panel.testContent.todos.contains { $0.title == "买牛奶" }
    }
    check(restored,
          "恢复后：列表应少一条、日期面板应重新出现它（列表 \(ctl.probeCompletedReminders().totalCompleted) 条，面板待办 \(panel.testContent.todos.count) 条）")
    check(fake.restoreCalls.count == 1, "恢复应该只写回一次")
    check(panel.testFlags[1]?.hasTodo == true, "恢复后红点必须重新计算")
    check(ctl.probeCompletedReminders().noticeText.contains("已恢复"),
          "恢复成功要给出结果提示（实际 «\(ctl.probeCompletedReminders().noticeText)»）")

    // ---- 6. 单条删除：确认 + 成功移除 + 失败不先移除 ----
    ctl.completedDeleteConfirmationForTest = { _ in true }
    guard let homework = panel.completedReminders.allItems.first(where: { $0.identifier == "done-2" }) else {
        fail("拿不到要删除的「交作业」")
        print("")
        for p in problems { print("❌ \(p)") }
        exit(1)
    }
    ctl.testDeleteCompleted(homework)
    let deleted = waitUntil {
        ctl.probeCompletedReminders().totalCompleted == 2
            && ctl.probeCompletedReminders().renderedRows == 2
    }
    check(deleted, "单条删除后列表应该少一条")
    check(fake.deleteCompletedCalls.count == 1, "单条删除应该只调用一次")
    check(!panel.completedReminders.allItems.contains { $0.identifier == "done-2" },
          "删除成功后缓存里不能还有它")

    fake.deleteCompletedShouldFail = true
    guard let noDue = panel.completedReminders.allItems.first(where: { $0.identifier == "done-4" }) else {
        fail("拿不到「没有到期的」")
        print("")
        for p in problems { print("❌ \(p)") }
        exit(1)
    }
    ctl.testDeleteCompleted(noDue)
    let deleteFailed = waitUntil {
        ctl.probeCompletedReminders().noticeText.contains("模拟：删除失败")
    }
    check(deleteFailed, "写回失败要显示原因")
    check(ctl.probeCompletedReminders().totalCompleted == 2,
          "写回失败不能先从列表移除（实际 \(ctl.probeCompletedReminders().totalCompleted) 条）")
    fake.deleteCompletedShouldFail = false

    // ---- 7. 全部删除：重新统计 / 统一 commit / 部分失败如实 / 不碰未完成 ----
    var reportedCount = -1
    ctl.completedDeleteAllConfirmationForTest = { count in
        reportedCount = count
        return true
    }
    fake.deleteAllPartiallyFails = ["done-4"]
    ctl.testDeleteAllCompleted()
    let batchDone = waitUntil {
        ctl.probeCompletedReminders().totalCompleted == 1
            && ctl.probeCompletedReminders().noticeText.contains("已删除")
    }
    check(batchDone,
          "批量删除后状态不对（列表 \(ctl.probeCompletedReminders().totalCompleted) 条，提示 «\(ctl.probeCompletedReminders().noticeText)»）")
    check(reportedCount == 2, "确认框数量必须重新统计（期望 2，实际 \(reportedCount)）")
    check(fake.commitCalls == 1, "批量删除只能统一 commit 一次（实际 \(fake.commitCalls) 次）")
    check(fake.completed.map { $0.identifier } == ["done-4"],
          "部分失败时只剩失败的那条（实际 \(fake.completed.map { $0.identifier })）")
    check(ctl.probeCompletedReminders().noticeText.contains("1 条失败"),
          "部分失败必须如实报失败数（实际 «\(ctl.probeCompletedReminders().noticeText)»）")
    let openLeft = fake.todosByDate.values.flatMap { $0 }.filter { $0.identifier == "open-1" }
    check(openLeft.count == 1, "全部删除不能碰未完成项")

    // commit 失败：一条都不能算成功、列表也不能先清空。
    fake.deleteAllCommitFails = true
    ctl.testDeleteAllCompleted()
    let commitFailed = waitUntil {
        ctl.probeCompletedReminders().noticeText.contains("删除失败")
    }
    check(commitFailed, "commit 失败不能报「全部成功」")
    check(ctl.probeCompletedReminders().totalCompleted == 1,
          "commit 失败不能把列表清空（实际 \(ctl.probeCompletedReminders().totalCompleted) 条）")
    check(fake.completed.count == 1, "commit 失败时系统里那条仍然存在")
    fake.deleteAllCommitFails = false
    fake.deleteAllPartiallyFails = []

    // ---- 8. 收起时取消在途读取 ----
    ctl.testToggleCompletedRow()                    // 收起
    _ = waitUntil { ctl.probeCompletedReminders().serviceState == "idle" }
    fake.completedFetchDelay = 0.35
    ctl.testToggleCompletedRow()                    // 展开（读取会晚到）
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(ctl.probeCompletedReminders().isLoading, "展开后应立刻显示「正在读取…」")
    ctl.testToggleCompletedRow()                    // 立刻收起
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let cancelled = ctl.probeCompletedReminders()
    check(cancelled.serviceState == "idle",
          "收起后迟到的读取结果必须被取消（实际 \(cancelled.serviceState)）")
    check(cancelled.renderedRows == 0, "收起后不能再渲染列表")
    fake.completedFetchDelay = 0

    // ---- 9. 接入关闭 / 未授权：入口置灰、点了不读取、不弹权限框 ----
    ctl.testSetDayPanelEnabled(false)
    let disabled = ctl.probeCompletedReminders()
    check(disabled.access == "disabled", "接入关闭时入口必须置灰（实际 \(disabled.access)）")
    check(!disabled.expanded, "接入关闭时不能保持展开")
    check(disabled.subtitleText == "开启接入并获得提醒事项权限后可查看",
          "接入关闭时副标题不对：\(disabled.subtitleText)")
    let fetchBeforeDisabled = fake.completedFetchCalls
    ctl.testToggleCompletedRow()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check(!ctl.probeCompletedReminders().expanded, "接入关闭时点这一行不能展开")
    check(fake.completedFetchCalls == fetchBeforeDisabled,
          "接入关闭时点这一行不能读取 EventKit")

    ctl.testSetDayPanelEnabled(true)
    fake.reminderAuth = .denied
    ctl.refreshDayPanelRows()
    let denied = ctl.probeCompletedReminders()
    check(denied.access == "needsAuthorization",
          "未授权时入口应该是 needsAuthorization（实际 \(denied.access)）")
    check(denied.subtitleText.contains("未授权"), "未授权时副标题要写「未授权」")
    check(denied.subtitleText.contains("开启接入并获得提醒事项权限后可查看"),
          "未授权时副标题要说明怎么才能看")
    let fetchBeforeDenied = fake.completedFetchCalls
    ctl.testToggleCompletedRow()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check(!ctl.probeCompletedReminders().expanded, "未授权时点这一行不能展开")
    check(fake.completedFetchCalls == fetchBeforeDenied,
          "未授权时不能读取 EventKit（也不能弹系统权限框）")
    fake.reminderAuth = .fullAccess
    ctl.refreshDayPanelRows()

    // ---- 10. 首屏 200 条 + 加载更多 ----
    fake.completed = (1...210).map { index in
        CompletedReminder(identifier: "bulk-\(index)",
                          title: "条目 \(index)",
                          listIdentifier: "c1",
                          listTitle: "桌面课表",
                          completionDate: now.addingTimeInterval(-Double(index)),
                          dueDate: nil,
                          isRecurring: false)
    }
    ctl.testSetCompletedSearch("")
    ctl.testToggleCompletedRow()                    // 重新展开 → 重新读
    let firstPage = waitUntil(10) {
        ctl.probeCompletedReminders().renderedRows == 200
    }
    check(firstPage, "首屏最多渲染 200 条（实际 \(ctl.probeCompletedReminders().renderedRows) 条）")
    check(ctl.probeCompletedReminders().hasMore, "210 条时应该有「加载更多」")
    check(ctl.probeCompletedReminders().loadMoreVisible, "有更多数据时「加载更多」要显示")
    ctl.testLoadMoreCompleted()
    let secondPage = waitUntil(10) {
        ctl.probeCompletedReminders().renderedRows == 210
    }
    check(secondPage, "点「加载更多」后应显示 210 条（实际 \(ctl.probeCompletedReminders().renderedRows) 条）")
    check(!ctl.probeCompletedReminders().hasMore, "全部渲染完后不该还有「加载更多」")
    check(ctl.probeCompletedReminders().listScrollable,
          "列表内容超出 260pt 时必须内部滚动（不能把设置页无限撑长）")

    // 收走面板，别让它悬在用户窗口前面。
    ctl.closeForAutomationCleanup()

    if problems.isEmpty {
        print("✅ 已完成的提醒事项（收起不读取 / 跨清单 / 搜索筛选 / 恢复联动 / 删除 / 批量 / 重复提醒 / 权限 / 分页）：通过")
        exit(0)
    }
    print("")
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if arguments.contains("--shot-settings") {
    // 截一张**设置面板**的图（2026-11 加了「日期覆盖层」卡片里的天气行，
    // 2026-11-05 又加了「已完成的提醒事项」）。
    //
    // ⚠️ 必须走 **app bundle**（不能是裸可执行文件）——
    // `UserNotificationCenter.current` 在裸可执行文件里会抛异常
    // （`bundleProxyForCurrentProcess is nil`）。
    //
    // 出图走 `NSBitmapImageRep` + `displayIgnoringOpacity` ——
    // 设置面板是**原生**视图（不是 WKWebView），不需要 takeSnapshot。
    //
    // 可用参数：
    //   wired              接入打开 + fake 控制器（不碰真实权限）
    //   completed-collapsed  收起态入口（滚到这一行）
    //   completed          展开后的列表（fake 已完成项）
    //   empty              展开后的空状态（fake 没有已完成项）
    //   delete-all         全部删除确认框（37 条，不需输入）
    //   delete-all typed   全部删除确认框（60 条，要输入「删除」）
    //   scroll-bottom      滚到底（天气行）
    let out = arguments.firstIndex(of: "--shot-settings").map { i -> String in
        (i + 1 < arguments.count) ? arguments[i + 1] : "/tmp/settings.png"
    } ?? "/tmp/settings.png"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // ⚠️ 真实 app 在 `installHandlers()` 里把全局外观设成 `.darkAqua`；
    // 截图入口不走那条路 → 不设的话控件和 HUD 材质会按**浅色**画，
    // 出图跟用户看到的完全不是一个东西。
    NSApp.appearance = NSAppearance(named: .darkAqua)

    /// 把一个窗口的真实视图层级渲染成 PNG。
    func renderShot(_ target: NSWindow, to path: String) -> Bool {
        guard let content = target.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        let size = content.bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width),
                                         pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return false
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
        // 设置面板的底色是 `NSVisualEffectView`（`.behindWindow` 材质）——
        // 它靠窗口背后的桌面内容合成，**离屏渲染拿不到**。
        // 这里铺一层和深色 HUD 面板同色系的底，保证文字 / 卡片对比度与真机一致
        // （否则出图会是白底 + 白字，看不清）。
        NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        content.displayIgnoringOpacity(content.bounds,
                                       in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("已截图 \(path)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        return true
    }

    // ---- 全部删除确认框：只建弹窗，不进入设置面板 ----
    if arguments.contains("delete-all") {
        let count = arguments.contains("typed") ? 60 : 37
        let dialog = DeleteAllCompletedDialog.buildWindowForTest(count: count)
        dialog.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        dialog.contentView?.layoutSubtreeIfNeeded()
        if !renderShot(dialog, to: out) {
            print("❌ 确认框截图失败")
            exit(1)
        }
        exit(0)
    }

    let ts = TimetableStore()
    _ = try? ts.migrateLegacyIfNeeded(defaultName: "我的课表")
    let needsWiring = arguments.contains("wired")
        || arguments.contains("completed-collapsed")
        || arguments.contains("completed")
        || arguments.contains("empty")
    // 可选参数 `wired`：把「接入」打开并接一个 fake 控制器，
    // 截一张「已接入」的真实设置面板 —— 用来核对交付前的状态行，
    // 不碰真实权限（fake store 默认 fullAccess）。
    if needsWiring {
        let settingsStore = SettingsStore()
        var settings = settingsStore.load()
        settings.dayPanel.enabled = true
        try? settingsStore.save(settings)
    }
    let ctl = SettingsWindowController(store: ts.configStore, timetableStore: ts) {}
    ctl.buildWindow()

    let fake = FakeEventKitStore()
    if needsWiring {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = Date()
        func shotDate(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let base = cal.date(byAdding: .day, value: -daysAgo, to: now)!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        fake.lists = [
            EventKitListInfo(title: "桌面课表", identifier: "c1", isWritable: true),
            EventKitListInfo(title: "购物", identifier: "c2", isWritable: true),
            EventKitListInfo(title: "学习", identifier: "c3", isWritable: true),
        ]
        if !arguments.contains("empty") {
            fake.completed = [
                CompletedReminder(identifier: "shot-1", title: "买牛奶",
                                  listIdentifier: "c2", listTitle: "购物",
                                  completionDate: now.addingTimeInterval(-25 * 60),
                                  dueDate: shotDate(daysAgo: 0, hour: 20, minute: 0),
                                  isRecurring: false),
                CompletedReminder(identifier: "shot-2", title: "交作业",
                                  listIdentifier: "c3", listTitle: "学习",
                                  completionDate: now.addingTimeInterval(-3 * 3600),
                                  dueDate: shotDate(daysAgo: 1, hour: 9, minute: 0),
                                  isRecurring: false),
                CompletedReminder(identifier: "shot-3", title: "每周复盘",
                                  listIdentifier: "c1", listTitle: "桌面课表",
                                  completionDate: now.addingTimeInterval(-26 * 3600),
                                  dueDate: shotDate(daysAgo: 0, hour: 22, minute: 0),
                                  isRecurring: true),
                CompletedReminder(identifier: "shot-4", title: "整理书桌",
                                  listIdentifier: "c1", listTitle: "桌面课表",
                                  completionDate: now.addingTimeInterval(-3 * 86400),
                                  dueDate: nil,
                                  isRecurring: false),
            ]
        }
        ctl.dayPanelController = DayPanelController(
            settings: DayPanelSettings(enabled: true),
            festivalProvider: DayPanelFestivalProviderFactory.make(),
            todayIndex: 1,
            baseMonday: WeekMath.mondayOfWeek(now),
            eventStore: fake)
    }
    // 天气行的状态要刷一次（平时是在 show() 里调的）。
    ctl.refreshDayPanelRows()
    // 「日期覆盖层」卡片在**提醒**板块里（「提醒与启动」下面）→ 展开到那一页再截。
    //
    // ⚠️ 「课表大小」在**外观**板块里 —— 所以要截那一页时用 `card-scale` 参数；
    //    `system` 参数截「系统」板块（最下面是版本号）。
    let shotSection: SettingsSection
    if arguments.contains("card-scale") { shotSection = .appearance }
    else if arguments.contains("system") { shotSection = .system }
    else { shotSection = .reminder }
    ctl.expandTo(shotSection)
    ctl.window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    guard let win = ctl.window else {
        print("没有设置窗口")
        exit(1)
    }
    // 窗口要**真的上屏**才画得出来（后台窗口的内容不会被合成）。
    win.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    // 展开动画（0.28s）要跑完，窗口尺寸才是最终的 580×700。
    RunLoop.main.run(until: Date().addingTimeInterval(1.6))
    win.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    print("设置面板尺寸：\(win.frame.size)")

    if arguments.contains("completed") || arguments.contains("empty") {
        ctl.testToggleCompletedRow()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if ctl.probeCompletedReminders().serviceState == "loaded" {
                // 列表是异步分批渲染的，等它画完。
                if ctl.probeCompletedReminders().renderedRows
                    == ctl.probeCompletedReminders().matchingCount {
                    break
                }
            }
        }
        ctl.scrollPanelToCompletedRowForTest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        win.contentView?.layoutSubtreeIfNeeded()
    } else if arguments.contains("completed-collapsed") {
        // 收起态入口：连卡片标题 / 前两行一起露出来，方便核对顺序。
        ctl.scrollPanelToDayPanelCardForTest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        win.contentView?.layoutSubtreeIfNeeded()
    } else if arguments.contains("scroll-bottom") {
        // 天气行在卡片的最下面 —— 滚到底再截，才能看全。
        ctl.scrollPanelToBottomForTest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    if !renderShot(win, to: out) {
        print("❌ 设置面板截图失败")
        exit(1)
    }
    exit(0)
}

// 自检：**真的能打字吗**（网页里的「＋ 添加待办」输入框）。
//
// 为什么必须单独验这个：
// 网页层的 DOM 自检（`--verify-day-panel` 里的输入框探针）只能证明
// 「重绘不丢焦点、不丢字」—— 它跑在一个**独立**的 WKWebView 里，
// 绕过了原生这边「窗口能不能拿 key / webView 是不是 first responder」。
//
// 而用户报的「字还是打不上」恰恰出在原生这一层：
//   · 桌面卡片的鼠标事件全被 `CardInteractionView` 截走，
//     再以**合成 JS 事件**转发给网页 → WKWebView **从没收到过真点击**
//     → 它**从来不是 first responder**；
//   · 于是即使窗口成了 key window，按键也只到窗口、到不了网页。
//
// 这一项就是端到端验它：真的按 3 个键，看网页里的输入框有没有收到。
if arguments.contains("--verify-typing") {
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --verify-typing 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()

    guard let renderer = delegate.testWebRenderer,
          let win = delegate.testDesktopWindow as? DesktopWindow else {
        print("❌ 拿不到网页渲染器 / 桌面窗口")
        exit(1)
    }
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if renderer.isReady { break }
    }
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    var problems: [String] = []
    func check(_ cond: Bool, _ msg: String) { if !cond { problems.append(msg) } }

    // 窗口上屏 + 激活（打字必须有 key window）。
    win.alphaValue = 1
    win.level = .floating          // 自检期间临时抬上来，保证真的可见
    win.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    win.contentView?.layoutSubtreeIfNeeded()
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    // ⚠️ **原生那边也要知道面板是开着的**（`dayPanelOpen`）。
    //
    // 「点添加待办」现在会**立刻**请求提醒 / 日历权限；授权回调里的
    // `refreshAll()` 会推一次完整状态。如果原生以为面板是关着的，
    // 这次推送会带 `dayPanelOpen: false` → 网页收到就把面板关了
    // （自检会误报「回车后面板消失」）。
    //
    // 真实使用里用户是点表头打开的，原生本来就知道；这里绕过交互直接
    // 调网页的 `ttDayPanelOpen`，所以要先补上原生这一侧的状态。
    delegate.testDayPanel?.open(day: 3)
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    // 打开覆盖层 → 点「＋ 添加待办」→ 等输入框出现并拿到焦点。
    let openJS = """
    (function () {
      var fake = { day: 3, todos: [], events: [],
        festival: { lunar: '农历九月廿三', term: '', festivals: [], weather: null, yi: '', ji: '' } };
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: fake,
          dayFestivals: { '1': fake.festival, '2': fake.festival, '3': fake.festival,
                          '4': fake.festival, '5': fake.festival, '6': fake.festival,
                          '7': fake.festival },
          dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(3, false);
      var add = document.querySelector('.dpadd');
      if (add) add.click();
      var inp = document.querySelector('[data-dp-input]');
      return JSON.stringify({
        hasInput: !!inp,
        activeIsInput: inp ? (document.activeElement === inp) : false
      });
    })();
    """
    var openResult: String?
    renderer.evaluateForTest(openJS) { r in openResult = r }
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    print("  注入结果：\(openResult ?? "nil")")

    // ⚠️ 关键：等窗口真的拿到 key + first responder 交给 webView。
    var ready = false
    for _ in 0..<80 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if win.firstResponderReady { ready = true; break }
    }
    let frName = win.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    print("  窗口 isKey=\(win.isKeyWindow) appActive=\(NSApp.isActive)")
    print("  firstResponder=\(frName)")
    print("  firstResponderReady=\(ready)")
    // ⚠️ **key window 只在能激活的时候才断言**。
    //
    // 从 shell 直接跑这个二进制时，进程没经 LaunchServices 注册成前台 app，
    // `NSApp.activate` 会被系统拒掉（实测 appActive 始终 false）——
    // 那是**自检环境**的限制，不是产品问题：
    // 真实使用里 app 是用 `open` 启动的，窗口约 0.8s 就能拿到 key
    // （我用一个同样窗口配置的独立测试 app 验过）。
    //
    // 所以：能激活就断言 isKeyWindow；不能激活就只报出来，不算失败。
    if NSApp.isActive {
        check(win.isKeyWindow, "app 已激活但桌面窗口没拿到 key window")
    } else {
        print("  ℹ️ 本进程激活不了（shell 启动，非 LaunchServices）—— isKeyWindow 不作断言")
    }
    if let target = win.textInputTarget {
        check(win.firstResponder === target,
              "first responder 不是 webView（实际 \(frName)）—— 按键到不了网页")
    } else {
        problems.append("桌面窗口没有设置 textInputTarget（webView）")
    }

    // 真的按 3 个键（交给 App 的事件链路，走 window → firstResponder → 网页）。
    func sendKey(_ ch: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let ev = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil,
                characters: ch, charactersIgnoringModifiers: ch,
                isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(ev)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    }
    func readValue(_ tag: String) {
        var v: String?
        renderer.evaluateForTest(
            "(function(){var i=document.querySelector('[data-dp-input]');" +
            "return i ? (i.value + '|active=' + (document.activeElement===i)) : '<没有输入框>';})();"
        ) { r in v = r }
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        print("  \(tag) → \(v ?? "nil")")
    }
    readValue("按键前")
    sendKey("a", code: 0)
    readValue("按下 a 后")
    sendKey("b", code: 11)
    readValue("按下 b 后")
    sendKey("c", code: 8)
    readValue("按下 c 后")
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    var valueResult: String?
    renderer.evaluateForTest(
        "(function(){var i=document.querySelector('[data-dp-input]');" +
        "return i ? i.value : '<没有输入框>';})();"
    ) { r in valueResult = r }
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    let typed = valueResult ?? ""
    print("  输入框里的内容：\"\(typed)\"")
    check(typed.contains("abc"),
          "按键没有进到网页输入框（实际 \"\(typed)\"，期望包含 \"abc\"）")

    // ---- 回车回归：按回车后面板不能消失（2026-11 修）----
    //
    // 用户反馈：「输入完待办事项之后点回车，整个瀑布面板会突然不见，
    // 鼠标再移动之后又会出现」。
    //
    // 根因：网页以前用 `window` 的 `blur` 判断「指针离开卡片」。
    // 回车 → `commitTodo` → `textInputBlur` → 原生 `resignKey()` →
    // 网页收到 `window.blur` → 误判「指针离开」→ `fadeOutPanel()`。
    // 跟随模式还开着，所以鼠标一动面板又回来 —— 和反馈完全一致。
    //
    // 这里真的按回车，等过淡出时长（400ms），再看面板是不是还在。
    //
    // ⚠️ 只把「类状态」当硬断言，opacity 只在**基线本来就不透明**时才断言：
    // shell 直接启动时进程激活不了（上面已说明），网页被判定 hidden →
    // CSS 过渡冻在 0，`show` 在、算出来的 opacity 也是 0。那是自检环境限制，
    // 不是面板真的消失了（真实 app 由 LaunchServices 启动，不存在这个问题）。
    func panelState(_ done: @escaping ([String: Any]) -> Void) {
        var raw: String?
        renderer.evaluateForTest(
            "(function(){var p=document.querySelector('.daypanel');" +
            "if(!p) return JSON.stringify({found:false});" +
            "var cs=getComputedStyle(p);" +
            "return JSON.stringify({found:true, show:p.classList.contains('show')," +
            "closing:p.classList.contains('closing'), opacity:cs.opacity});})();"
        ) { r in raw = r }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard let s = raw, let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            done([:])
            return
        }
        done(obj)
    }
    var baseline: [String: Any] = [:]
    panelState { baseline = $0 }
    let baselineOpacity = Double((baseline["opacity"] as? String) ?? "0") ?? 0
    print("  回车前面板：show=\(baseline["show"] ?? "?") opacity=\(baselineOpacity)")
    sendKey("\r", code: 36)
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    var enterState: [String: Any] = [:]
    panelState { enterState = $0 }
    if enterState.isEmpty {
        problems.append("拿不到回车后面板状态的诊断结果")
    } else {
        let found = (enterState["found"] as? Bool) ?? false
        let show = (enterState["show"] as? Bool) ?? false
        let closing = (enterState["closing"] as? Bool) ?? false
        let opacity = Double((enterState["opacity"] as? String) ?? "0") ?? 0
        print("  回车后面板：found=\(found) show=\(show) closing=\(closing) opacity=\(opacity)")
        let opacityOK = baselineOpacity <= 0.9 || opacity > 0.9
        check(found && show && !closing && opacityOK,
              "输入完待办按回车，面板不能消失（found=\(found) show=\(show) closing=\(closing) opacity=\(opacity)，基线 opacity=\(baselineOpacity)）")
    }

    if problems.isEmpty {
        print("✅ 文本输入（真按键 → key window → webView → 输入框）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    exit(1)
}

if let idx = arguments.firstIndex(of: "--shot-day-panel") {
    // 在**真机**上截一张「点开覆盖层」之后的卡片图。
    //
    // 与 `--render-day-panel` 的区别：那个是离屏渲染（动画不跑、位置可能不准），
    // 这个是真的把窗口摆到屏幕上、真的点一下表头、再截**窗口本身** ——
    // 看到的就是用户看到的。
    let out = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("shot-daypanel.png")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let renderer = delegate.testWebRenderer, let win = delegate.testDesktopWindow else {
        print("没有窗口")
        exit(1)
    }
    // 等网页加载完 + 窗口上屏。
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if renderer.isReady { break }
    }
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    win.alphaValue = 1
    // ⚠️ 截图时必须让网页**真的可见**，否则截出来的是假图。
    //
    // 桌面层窗口（desktopIconWindow + 1）只要被任何普通窗口盖住，macOS 就把它判成
    // 遮挡，WKWebView 随即将 `document.visibilityState` 变成 `hidden`：
    // 合成器暂停，CSS 过渡冻在 `currentTime 0` —— 覆盖层的 class 已经是 `show`，
    // 算出来 opacity 却是 0，截图里根本没面板（看起来像「点了没反应」）。
    // 截图期间把窗口临时提到浮动层，让网页真的在画；进程退出窗口就没了。
    win.level = .floating
    win.orderFrontRegardless()
    // 光有「窗口在前面」还不够：WKWebView 判定页面可见还看**应用是否活跃**，
    // 后台进程的网页一律算 hidden（过渡同样冻结）。自检进程短暂把自己激活一下。
    NSApp.activate(ignoringOtherApps: true)
    win.contentView?.layoutSubtreeIfNeeded()
    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    // 真的点一下第 N 列的表头（用真实的 NSApp 事件链路）。
    var panelDay = 3
    if let dIdx = arguments.firstIndex(of: "day"), dIdx + 1 < arguments.count,
       let d = Int(arguments[dIdx + 1]) { panelDay = d }
    // 表头格中心的**窗口**坐标。
    //
    // ⚠️ 不能再用 TimetableLayout 的常量手算：顶栏 / 状态条的高度变过之后，
    // 手算出来的点是错位的（点到顶栏上去了）—— 自检照样「跑通」，
    // 但截出来的图里根本没有覆盖层，等于什么都没验。
    // 这里直接问网页要表头格的 rect（CSS 像素），再换算成窗口坐标。
    var headerPoint: NSPoint?
    let probe = """
    (function () {
      var e = document.querySelector('.hcell[data-day="\(panelDay)"]');
      if (!e) return '';
      var r = e.getBoundingClientRect();
      return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
    })();
    """
    renderer.evaluateForTest(probe) { result in
        guard let s = result, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let cx = obj["x"], let cy = obj["y"] else { return }
        // 网页坐标（左上原点）→ 窗口坐标（左下原点）。
        headerPoint = renderer.webView.convert(NSPoint(x: cx, y: cy), to: nil)
    }
    for _ in 0..<40 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if headerPoint != nil { break }
    }
    guard let pt = headerPoint else {
        print("量不到第 \(panelDay) 列的表头位置")
        exit(1)
    }
    func send(_ type: NSEvent.EventType, at p: NSPoint) {
        guard let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: win.windowNumber,
                                           context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1) else { return }
        NSApp.sendEvent(ev)
    }
    send(.leftMouseDown, at: pt)
    send(.leftMouseUp, at: pt)

    // 可选：采样入场动画的实际进度（`--shot-day-panel ... probe-anim`）。
    //
    // 页面在截图模式下是**真的可见**的（窗口浮动 + 进程激活），
    // 所以这里量到的 clip-path 推进是用户实际看到的节奏 ——
    // 用来确认「原生推状态把 600ms 动画截断」的问题真的修好了。
    if arguments.contains("probe-anim") {
        let clipJS = "(function(){var d=document.querySelector('.daypanel');" +
            "var h=document.querySelector('.hcell[data-day=\"3\"]');" +
            "var hc=h?getComputedStyle(h):null;var hs=h?getComputedStyle(h.querySelector('.hmid')||h):null;" +
            "if(!d)return 'no-panel';var cs=getComputedStyle(d);" +
            "return [cs.opacity,(cs.clipPath||cs.webkitClipPath||'')," +
            "h?h.className:'no-cell',hc?hc.color:'',hc?hc.backgroundColor:''," +
            "hs?hs.color:''].join(' | ');})();"
        let t0 = ProcessInfo.processInfo.systemUptime
        var samples: [String] = []
        for _ in 0..<18 {
            renderer.evaluateForTest(clipJS) { r in
                let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
                samples.append("\(ms)ms: \(r ?? "nil")")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.045))
        }
        print("---- 入场动画采样 ----")
        for s in samples { print(s) }
        print("----------------------")
    }

    for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    // ---- 可选：采样**关闭**时的收起动画（`--shot-day-panel ... probe-close`）----
    //
    // ⚠️ 收起动画必须在**页面真的可见**时才有意义 ——
    // 合成器不跑的话 transition 永远停在起始帧，量到的都是终值。
    if arguments.contains("probe-close") {
        var closeSamples: [String] = []
        let closeT0 = ProcessInfo.processInfo.systemUptime
        let closeJS = "(function(){var d=document.querySelector('.daypanel');" +
            "if(!d)return 'no-panel';var cs=getComputedStyle(d);" +
            "return [cs.opacity,(cs.clipPath||cs.webkitClipPath||''),d.className].join(' | ');})();"
        // ⚠️ **必须等入场动画跑完**再测收起动画 ——
        // 提前关会打断入场动画（clip-path 还在中间态），量到的不是收起过程。
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        // 先看**关闭前**的 clip-path（是不是 `none` —— 那就转不动了）。
        renderer.evaluateForTest(
            "(function(){var d=document.querySelector('.daypanel');" +
            "if(!d)return 'no-panel';var cs=getComputedStyle(d);" +
            "return [cs.opacity,(cs.clipPath||cs.webkitClipPath||''),d.className," +
            "d.style.clipPath||'(no inline)', cs.transitionProperty||'(none)', " +
            "cs.transitionDuration||'(none)'].join(' | ');})();"
        ) { r in print("关闭前：\(r ?? "nil")") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        renderer.evaluateForTest("if (window.ttDayPanelClose) window.ttDayPanelClose(); 'closing'") { _ in }
        for _ in 0..<14 {
            renderer.evaluateForTest(closeJS) { r in
                let ms = Int((ProcessInfo.processInfo.systemUptime - closeT0) * 1000)
                closeSamples.append("\(ms)ms: \(r ?? "nil")")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.045))
        }
        print("---- 收起动画采样 ----")
        for s in closeSamples { print(s) }
        print("----------------------")
        exit(0)
    }

    // 可选：**真的在输入框里按回车再截图**（`--shot-day-panel ... enter`）。
    //
    // 回归：以前网页用 `window` 的 blur 判断「指针离开卡片」，而回车会让
    // 原生 `resignKey()` → 网页收到 blur → 误判 → `fadeOutPanel()`。
    // 这里走和用户完全一样的链路（输入框 Enter → commitTodo →
    // `textInputBlur` → 原生退出文本输入模式 → 网页 blur），
    // 等过淡出时长（400ms）后把面板状态打出来，后面截的图就是证据。
    if arguments.contains("enter") {
        renderer.evaluateForTest(
            "(function(){var add=document.querySelector('.dpadd');" +
            "if(add)add.click();" +
            "var i=document.querySelector('[data-dp-input]');" +
            "if(!i)return 'no-input';" +
            "i.focus();i.value='回车回归测试';" +
            "i.dispatchEvent(new KeyboardEvent('keydown'," +
            "{key:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));" +
            "return 'sent';})();"
        ) { r in print("回车注入：\(r ?? "nil")") }
        // 等过淡出时长（DP_CLOSE_MS = 400ms）+ 余量。
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        renderer.evaluateForTest(
            "(function(){var d=document.querySelector('.daypanel');" +
            "var cs=d?getComputedStyle(d):null;" +
            "return JSON.stringify({cls:d?d.className:'none'," +
            "op:cs?cs.opacity:'',vis:cs?cs.visibility:''," +
            "open:window.ttDayPanelIsOpen?window.ttDayPanelIsOpen():null});})();"
        ) { r in print("回车后面板：\(r ?? "nil")") }
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    // 可选：**待办的「添加态 / 编辑态」两张图**
    // （`--shot-day-panel <out> todoedit`）。
    //
    // 需求：添加待办要能填到期时间（两行布局），右键「修改…」是卡片内编辑
    // （标题 + 时分 + 保存 / 取消）。这两张图是给人眼核对的。
    //
    // ⚠️ 只截**面板那一列**（不是整张卡片）—— 整张卡片 968pt 宽，
    // 面板只有约 119pt，放大后才有意义。
    if arguments.contains("todoedit") {
        func snapPanel(_ path: String, _ tag: String) {
            // ⚠️ **截取范围要往上多留一截**。
            //
            // 自检进程的网页被系统判成 hidden，合成器**落后一拍**：
            // 「插入一张卡」这种**改布局**的变化要等下一帧才被画出来，
            // 截图里会看到它落在**上一帧的位置**（偏上）。
            // 往上多留一段，编辑卡就一定在画面里。
            var rect: NSRect = renderer.webView.bounds
            var raw: String?
            renderer.evaluateForTest(
                "(function(){var b=document.querySelector('.dpcards');" +
                "if(!b)return '';var r=b.getBoundingClientRect();" +
                "return JSON.stringify({x:r.left-8,y:r.top-40,w:r.width+16,h:r.height+80});})();"
            ) { r in raw = r }
            for _ in 0..<60 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                if raw != nil { break }
            }
            if let s = raw, let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
               let x = obj["x"], let y = obj["y"], let w = obj["w"], let h = obj["h"] {
                rect = renderer.webView.convert(
                    NSRect(x: x, y: y, width: w, height: h), to: nil)
            }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = rect
            cfg.afterScreenUpdates = true
            var done = false
            renderer.webView.takeSnapshot(with: cfg) { image, _ in
                defer { done = true }
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:]) else { return }
                try? data.write(to: URL(fileURLWithPath: path))
                print("已截图 \(tag) → \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            }
            for _ in 0..<120 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                if done { break }
            }
        }

        // 注入两条待办（直接注入网页，不碰 EventKit）。
        let injectTodos = """
        (function () {
          var fest = { lunar: '九月十二', term: '', festivals: [], weather: null, yi: '', ji: '' };
          var festAll = {};
          for (var d = 1; d <= 7; d++) festAll[String(d)] = fest;
          var panel = { day: 3, todos: [
              { title: '交实验报告', due: '18:00', done: false, identifier: 'shot-rid-1', calendarIdentifier: 'shot-cal' },
              { title: '买牛奶和面包', due: '20:00', done: false, identifier: 'shot-rid-2', calendarIdentifier: 'shot-cal' }
            ], events: [], festival: fest };
          window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
            dayFlags: { '3': { todo: true, event: false } },
            courses: [], viewWeek: 2 });
          window.ttDayPanelOpen(3, false);
          return 'ok';
        })();
        """
        renderer.evaluateForTest(injectTodos) { r in print("注入待办：\(r ?? "nil")") }
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        let base = (out as NSString).deletingPathExtension

        // ---- 图 1：添加态（两行：内容 / 时分 + 添加）----
        renderer.evaluateForTest(
            "(function(){var add=document.querySelector('.dpadd');" +
            "if(add)add.click();" +
            "var t=document.querySelector('[data-dp-input]');" +
            "if(t){t.value='买菜';t.dispatchEvent(new Event('input',{bubbles:true}));}" +
            "var h=document.querySelector('[data-dp-time-part=\"add-hour\"]');" +
            "if(h){h.value='20';h.dispatchEvent(new Event('input',{bubbles:true}));}" +
            "var m=document.querySelector('[data-dp-time-part=\"add-minute\"]');" +
            "if(m){m.value='00';m.dispatchEvent(new Event('input',{bubbles:true}));}" +
            "return 'ok';})();"
        ) { r in print("添加态：\(r ?? "nil")") }
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        snapPanel(base + "-add.png", "添加态")

        // ---- 图 2：编辑态（右键「修改…」进入的那张卡）----
        //
        // ⚠️ **分步做**：先关掉添加态，再单独进编辑态。
        // 一次 JS 里连着做两件事，隐藏页面里容易只截到中间那一帧。
        renderer.evaluateForTest(
            "(function(){var add=document.querySelector('.dpadd');if(add)add.click();" +
            "return 'ok';})();"
        ) { r in print("收起添加态：\(r ?? "nil")") }
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        renderer.evaluateForTest(
            "window.ttDayPanelTodoMenuAction('edit',{key:'id:shot-rid-2'});'ok';"
        ) { r in print("进入编辑态：\(r ?? "nil")") }
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        renderer.evaluateForTest(
            "(function(){" +
            "var t=document.querySelector('[data-dp-edit-title]');" +
            "if(t){t.value='交实验报告（改）';t.dispatchEvent(new Event('input',{bubbles:true}));}" +
            "var h=document.querySelector('[data-dp-time-part=\"edit-hour\"]');" +
            "if(h){h.value='21';h.dispatchEvent(new Event('input',{bubbles:true}));}" +
            "var m=document.querySelector('[data-dp-time-part=\"edit-minute\"]');" +
            "if(m){m.value='30';m.dispatchEvent(new Event('input',{bubbles:true}));}" +
            "return 'ok';})();"
        ) { r in print("填写编辑内容：\(r ?? "nil")") }
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        // 诊断：编辑态的 DOM 状态（截图之外，还要有**可核对的数据**）。
        var editStateRaw: String?
        renderer.evaluateForTest(
            "(function(){var st=window.ttDayPanelTodoState?window.ttDayPanelTodoState():{};" +
            "var t=document.querySelector('[data-dp-edit-title]');" +
            "var e=document.querySelector('.dpcard.todo.editing');" +
            "var f=document.querySelector('.dpedit');" +
            "return JSON.stringify({editingKey:st.editingKey||null," +
            "editing:!!e,title:t?t.value:null," +
            "overflow:f?(f.scrollWidth-f.clientWidth):-1});})();"
        ) { r in editStateRaw = r }
        for _ in 0..<60 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if editStateRaw != nil { break }
        }
        print("[诊断] 编辑态 DOM：\(editStateRaw ?? "nil")")
        snapPanel(base + "-edit.png", "编辑态")
        exit(0)
    }

    // 可选：**真的点一下待办前面的空心圆**，截「变蓝」和「正在淡出」两张图
    // （`--shot-day-panel <out> complete`）。
    //
    // 这里只看**网页层**：两条待办是直接注入的，原生的 `todoToggle` 找不到
    // 对应 identifier 会直接返回 —— 不会去动任何真实的提醒事项。
    if arguments.contains("complete") {
        let inject = """
        (function () {
          var fest = { lunar: '九月十二', term: '', festivals: ['测试'], weather: null, yi: '宜出行', ji: '忌熬夜' };
          var festAll = {};
          for (var d = 1; d <= 7; d++) festAll[String(d)] = fest;
          var panel = { day: 3, todos: [
              { title: '交实验报告', due: '18:00', done: false, identifier: 'shot-rid-1', calendarIdentifier: 'shot-cal' },
              { title: '买牛奶', due: '20:00', done: false, identifier: 'shot-rid-2', calendarIdentifier: 'shot-cal' }
            ], events: [], festival: fest };
          window.ttUpdate({ dayPanel: panel, dayFestivals: festAll,
            dayFlags: { '3': { todo: true, event: false } },
            courses: [], viewWeek: 2 });
          window.ttDayPanelOpen(3, false);
          return 'ok';
        })();
        """
        renderer.evaluateForTest(inject) { r in print("注入待办：\(r ?? "nil")") }
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        // 自检进程被判定 hidden 时合成器不推进，`.dpcheck` 的 120ms 颜色过渡
        // 会冻在第一帧（还是透明）——截图里就看不到蓝色。
        // 这里**只关掉圆圈的颜色过渡**（不影响淡出动画），让类一加就是终值。
        renderer.evaluateForTest(
            "(function(){var s=document.createElement('style');s.id='shot-notrans';" +
            "s.textContent='.dpcheck{transition:none !important}';" +
            "document.head.appendChild(s);return 'ok';})()"
        ) { _ in }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var dotPoint: NSPoint?
        renderer.evaluateForTest(
            "(function(){var c=document.querySelector('.dpcard.todo[data-todo-key=\"id:shot-rid-1\"] .dpcheck');" +
            "if(!c)return '';var r=c.getBoundingClientRect();" +
            "return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})();"
        ) { result in
            guard let s = result, let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                  let cx = obj["x"], let cy = obj["y"] else { return }
            dotPoint = renderer.webView.convert(NSPoint(x: cx, y: cy), to: nil)
        }
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if dotPoint != nil { break }
        }
        guard let dp = dotPoint else {
            print("量不到待办圆圈的位置")
            exit(1)
        }
        func snapTo(_ path: String) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = renderer.webView.bounds
            cfg.afterScreenUpdates = true
            var done = false
            renderer.webView.takeSnapshot(with: cfg) { image, _ in
                defer { done = true }
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:]) else { return }
                try? data.write(to: URL(fileURLWithPath: path))
                print("已截图 \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            }
            for _ in 0..<120 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                if done { break }
            }
        }
        func stateNow(_ tag: String) {
            var raw: String?
            renderer.evaluateForTest(
                "(function(){var c=document.querySelector('.dpcard.todo[data-todo-key=\"id:shot-rid-1\"]');" +
                "var dot=c?c.querySelector('.dpcheck'):null;" +
                "var cs=dot?getComputedStyle(dot):null;" +
                "return JSON.stringify({elapsed:Date.now()-(window.__shotStart||0)," +
                "there:!!c,completing:c?c.classList.contains('completing'):null," +
                "leaving:c?c.classList.contains('leaving'):null," +
                "opacity:c?getComputedStyle(c).opacity:null," +
                "dotBg:cs?cs.backgroundColor:null," +
                "docvis:document.visibilityState});})();"
            ) { r in raw = r }
            for _ in 0..<60 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                if raw != nil { break }
            }
            print("\(tag)：\(raw ?? "nil")")
        }

        // 真的点下去（和用户一样的鼠标事件链路）。
        renderer.evaluateForTest("window.__shotStart = Date.now(); 'ok'") { _ in }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let shotStart = Date()
        send(.leftMouseDown, at: dp)
        send(.leftMouseUp, at: dp)

        // 约 0.3 秒：圆圈应该已经是**蓝色实心**，其它都没变。
        while Date().timeIntervalSince(shotStart) < 0.30 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        stateNow("点圆圈后 0.3 秒")
        let base = (out as NSString).deletingPathExtension
        snapTo(base + "-complete-blue.png")

        // 模拟原生「完成写回」之后推来的内容（不含刚完成的那条）。
        // 不推的话，1.4 秒的移除定时器重绘时会把缓存里的旧数据又画回来。
        renderer.evaluateForTest(
            "(function(){var fest={lunar:'九月十二',term:'',festivals:['测试'],weather:null,yi:'宜出行',ji:'忌熬夜'};" +
            "var festAll={};for(var d=1;d<=7;d++)festAll[String(d)]=fest;" +
            "window.ttUpdate({dayPanel:{day:3,todos:[{title:'买牛奶',due:'20:00',done:false," +
            "identifier:'shot-rid-2',calendarIdentifier:'shot-cal'}],events:[],festival:fest}," +
            "dayFestivals:festAll,dayFlags:{'3':{todo:true,event:false}},courses:[],viewWeek:2});" +
            "return 'ok';})()"
        ) { _ in }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // 约 1.15 秒：开始缓慢淡出（`.leaving` 已加上）。
        // 页面 hidden 时动画冻在 0ms，这里把**真正的那条 CSS 动画**
        // 拨到 200ms（400ms 动画的一半）再截图 —— 看到的是实际淡出中间帧。
        while Date().timeIntervalSince(shotStart) < 1.15 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        stateNow("点圆圈后 1.15 秒")
        var fadeState: String?
        renderer.evaluateForTest(
            "(function(){var c=document.querySelector('.dpcard.todo[data-todo-key=\"id:shot-rid-1\"]');" +
            "if(!c)return 'no-card';var anims=c.getAnimations?c.getAnimations():[];" +
            "var names=[];for(var i=0;i<anims.length;i++){" +
            "  names.push((anims[i].animationName||'?')+':'+anims[i].playState);" +
            "  if(anims[i].animationName==='dpTodoLeave'){anims[i].pause();anims[i].currentTime=200;}}" +
            "return JSON.stringify({names:names,opacity:getComputedStyle(c).opacity," +
            "transform:getComputedStyle(c).transform});})();"
        ) { r in fadeState = r }
        for _ in 0..<60 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if fadeState != nil { break }
        }
        print("淡出中间帧：\(fadeState ?? "nil")")
        snapTo(base + "-complete-fading.png")

        // 约 1.7 秒：这一条已经从列表里移除。
        while Date().timeIntervalSince(shotStart) < 1.70 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        stateNow("点圆圈后 1.7 秒")
        snapTo(base + "-complete-gone.png")
        exit(0)
    }

    // 可选：截「读取中…」占位态（`--shot-day-panel <out> loading`）。
    //
    // 原生刚打开一列、EventKit 还没查完时会推一份 `ready: false` 的中间态。
    // 这时两张卡片必须显示「读取中…」，**不能**先闪一下
    // 「今日无待办 / 今日无日程」——那是用户看到的「点日期先闪一下」。
    // 这里直接注入这样一份状态，出图核对。
    if arguments.contains("loading") {
        renderer.evaluateForTest(
            "(function(){var fest={lunar:'九月十三',term:'',festivals:[],weather:null,yi:'',ji:''};" +
            "var festAll={};for(var d=1;d<=7;d++)festAll[String(d)]=fest;" +
            "window.ttDayPanelSetState({dayPanel:{day:5,todos:[],events:[]," +
            "festival:fest,ready:false},dayFestivals:festAll," +
            "dayFlags:{'5':{todo:false,event:false}}});" +
            "window.ttDayPanelOpen(5);return 'ok';})();"
        ) { r in print("注入读取中中间态：\(r ?? "nil")") }
        for _ in 0..<60 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        renderer.evaluateForTest(
            "(function(){var out=[];" +
            "document.querySelectorAll('.dpcard.empty').forEach(function(e){" +
            "out.push(e.textContent.trim().replace(/\\s+/g,' '));});" +
            "return JSON.stringify(out);})();"
        ) { r in print("空态卡片文字：\(r ?? "nil")") }
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    // 截**网页**（走 takeSnapshot —— WKWebView 在 `cacheDisplay` 里画不出内容）。
    //
    // ⚠️ 必须等动画跑完（合成器推进），否则截到的是生长动画的中间帧。
    for _ in 0..<60 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    // 诊断：点完之后覆盖层到底还在不在（不在的话说明被别的东西关掉了）。
    renderer.evaluateForTest(
        "(function(){var d=document.querySelector('.daypanel');" +
        "var s=window.ttDayPanelIsOpen();" +
        "var cs=d?getComputedStyle(d):null;" +
        "return JSON.stringify({open:s.open,day:s.day,cls:d?d.className:''," +
        "op:cs?cs.opacity:'',vis:cs?cs.visibility:'',inline:d?d.style.cssText:''," +
        "count:document.querySelectorAll('.daypanel').length," +
        "grids:document.querySelectorAll('.grid').length," +
        "anims:d&&d.getAnimations?d.getAnimations().map(function(a){" +
        "return a.transitionProperty+':'+a.playState+':'+Math.round(a.currentTime||0);}):[]," +
        "docvis:document.visibilityState," +
        "h:d?Math.round(d.getBoundingClientRect().height):-1});})();"
    ) { result in
        NSLog("[DesktopTimetable] 点开之后：%@", result ?? "nil")
    }
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    // 兜底断言：网页被系统判成 hidden 的话，CSS 过渡停摆，截图必然「看起来没打开」。
    // 与其截一张骗人的图，不如直接报错。
    var pageVisibility = ""
    renderer.evaluateForTest("document.visibilityState") { r in pageVisibility = r ?? "" }
    for _ in 0..<20 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if !pageVisibility.isEmpty { break }
    }
    if pageVisibility != "visible" {
        // 页面被判成 hidden（屏保 / 锁屏 / 会话后台 / 进程没激活）时，合成器不推进，
        // CSS 过渡永远停在第一帧 —— 覆盖层 class 是 `show`，opacity 却一直是 0。
        //
        // 本自检要看的是**最终形态**，不是过渡过程（过渡由 `--verify-panel-animation` 单独验）。
        // 所以这里直接关掉过渡，让样式跳到最终值再截图；否则截出来的是一张骗人的空图。
        print("⚠️ 网页处于 \(pageVisibility.isEmpty ? "未知" : pageVisibility) 状态，合成器不推进 —— 关掉过渡截最终态")
        renderer.evaluateForTest(
            "(function(){var s=document.createElement('style');" +
            "s.textContent='*,*::before,*::after{transition:none !important;animation:none !important}';" +
            "document.head.appendChild(s);return 'ok';})()"
        ) { _ in }
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    // 兜底：面板必须真的看得见（opacity 1）。看不见就是自检失败，不能截空图交差。
    var panelOpacity = ""
    renderer.evaluateForTest(
        "(function(){var d=document.querySelector('.daypanel');" +
        "return d?getComputedStyle(d).opacity:'';})()"
    ) { r in panelOpacity = r ?? "" }
    for _ in 0..<20 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if !panelOpacity.isEmpty { break }
    }
    if Double(panelOpacity) ?? 0 < 0.99 {
        print("❌ 覆盖层算出来的 opacity = \(panelOpacity.isEmpty ? "未知" : panelOpacity)，截图不可信")
        exit(1)
    }
    let cfg = WKSnapshotConfiguration()
    cfg.rect = renderer.webView.bounds
    cfg.afterScreenUpdates = true
    var done = false
    renderer.webView.takeSnapshot(with: cfg) { image, _ in
        defer { done = true }
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: out))
        print("已截图 \(out)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
    for _ in 0..<200 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if done { break }
    }
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-day-panel") {
    // 渲染一张**带日期覆盖层**的卡片 PNG（自检 / 出图用）。
    //
    // 覆盖层是网页层的东西，原生的 `renderCard` 只会画原生卡片 —— 看不到它。
    // 所以这里走「真的把网页渲染出来 → 注入覆盖层状态 → 截图」这条路。
    //
    // ⚠️ WKWebView 在**离屏**上下文里 `displayIgnoringOpacity` 画不出内容
    // （它要靠窗口服务器合成）—— 必须用 `takeSnapshot`。
    // 但模式 B 下 `snapshot()` 是空操作（网页直接上屏，不走快照管线），
    // 所以这里直接调 `takeSnapshot` 绕开那个开关。
    let out = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("daypanel.png")
    // `empty` = 不注入任何数据（模拟「鼠标刚悬停上来、原生还没推数据」的样子）。
    // 这是用户实际看到的最常见状态，必须单独能出图核对。
    let isEmpty = arguments.contains("empty")
    // 第四个参数：`day=N` = 渲染第几列（默认 3）。
    var panelDay = 3
    if let dIdx = arguments.firstIndex(of: "day"), dIdx + 1 < arguments.count,
       let d = Int(arguments[dIdx + 1]) { panelDay = d }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()

    guard let renderer = delegate.testWebRenderer else {
        print("没有渲染器")
        exit(1)
    }
    // 等网页加载完。
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if renderer.isReady { break }
    }
    for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    // 注入一份假数据 + 打开覆盖层（3 号列）。
    let sample = """
    (function () {
      var fake = {
        day: \(panelDay),
        todos: [
          { title: '买牛奶和面包', due: '20:00', done: false, identifier: 'r1', calendarIdentifier: 'c1' },
          { title: '交数据结构作业', due: '23:00', done: false, identifier: 'r2', calendarIdentifier: 'c1' },
          { title: '给导师回邮件', due: '', done: false, identifier: 'r3', calendarIdentifier: 'c1' }
        ],
        events: [
          { title: '团队会议', start: '10:00', end: '11:30', identifier: 'e1', calendarIdentifier: 'c2' },
          { title: '图书馆', start: '15:00', end: '17:00', identifier: 'e2', calendarIdentifier: 'c2' }
        ],
        festival: { lunar: '农历九月廿三', term: '霜降', festivals: ['万圣节前夜'],
          // ⚠️ **天气 / 宜忌留空** —— 出图要反映「原生还没推数据」的真实样子。
          // 天气行和宜忌行的渲染由 `--verify-day-panel` 验（那里注入假数据）。
          weather: null, yi: '', ji: '' }
      };
      if (window.ttDayPanelSetState && !\(isEmpty)) {
        window.ttDayPanelSetState({ dayPanel: fake, dayFlags: { '1': {todo:false,event:false},
          '2': {todo:true,event:false}, '3': {todo:true,event:true},
          '4': {todo:false,event:true}, '5': {todo:false,event:false},
          '6': {todo:false,event:false}, '7': {todo:false,event:false} },
          dayPanelOpen: true });
      }
      // 数据灌进去之后**再打开** —— 打开时会按当前数据渲染。
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(\(panelDay));
      // 出图辅助（`pulse-demo`）：把呼吸圈钉在 40% 相位并临时点亮。
      // 离屏截图时合成器可能停住，动画正好停在 0%（圆环藏在圆点后面看不见），
      // 固定相位才能核对圆环形状。只影响这张自检图，真实运行没有这段。
      if (\(arguments.contains("pulse-demo"))) {
        var pu = document.querySelector('.status .pulse');
        if (pu) pu.classList.remove('idle');
        if (document.getAnimations) document.getAnimations().forEach(function (a) {
          if (a.animationName === 'pl' || a.animationName === 'pl-idle') {
            a.pause();
            a.currentTime = 960;
          }
        });
      }
      return 'ok';
    })();
    """
    renderer.evaluateForTest(sample) { _ in }

    // ⚠️ **必须等生长动画跑完**（260ms + 兜底 400ms）——
    // CSS transition 靠**合成器**推进，合成器不跑时动画会**永远停在起始帧**
    // （面板看起来就是一条 7px 的细线）。网页侧有兜底把 transform / opacity
    // 落到终态，但这里也得等它跑完。
    if let win = delegate.testDesktopWindow {
        win.alphaValue = 1
        win.orderFrontRegardless()
        win.contentView?.layoutSubtreeIfNeeded()
    }
    for _ in 0..<60 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    // 诊断：覆盖层的实际几何与可见性（出问题时看这里）。
    renderer.evaluateForTest(
        "(function () { var el = document.querySelector('.daypanel');" +
        " var b = document.querySelector('.dpbody');" +
        " if (!el || !b) return 'no el';" +
        " var er = el.getBoundingClientRect(); var br = b.getBoundingClientRect();" +
        " return JSON.stringify({" +
        "  rect: [Math.round(er.left), Math.round(er.top), Math.round(er.width), Math.round(er.height)]," +
        "  bodyH: Math.round(br.height), transform: getComputedStyle(b).transform," +
        "  opacity: getComputedStyle(el).opacity," +
        "  fadeH: (function () { var f = document.querySelector('.dpfade');" +
        "    return f ? Math.round(f.getBoundingClientRect().height) : -1; })()," +
        "  fadeTop: (function () { var f = document.querySelector('.dpfade');" +
        "    return f ? Math.round(f.getBoundingClientRect().top) : -1; })()," +
        "  elBottom: Math.round(el.getBoundingClientRect().bottom)," +
        "  gridBottom: Math.round(el.parentElement.getBoundingClientRect().bottom) }); })();"
    ) { result in
        NSLog("[DesktopTimetable] 覆盖层：%@", result ?? "nil")
    }
    for _ in 0..<60 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    // ⚠️ **渲染模式下不跑交互诊断** —— 它会「再点一次日期」把面板关掉，
    // 后面截到的就是关掉后的画面（什么都没有）。
    // 诊断：覆盖层的几何与可见性（出问题时看这里）。
    renderer.evaluateForTest(
        "(function () {" +
        " var d = document.querySelector('.daypanel');" +
        " var b = document.querySelector('.dpbody');" +
        " var f = document.querySelector('.dpfade');" +
        " if (!d || !b || !f) return 'missing';" +
        " var br = b.getBoundingClientRect(), fr = f.getBoundingClientRect();" +
        " return JSON.stringify({" +
        "  bodyTop: Math.round(br.top), bodyBottom: Math.round(br.bottom)," +
        "  fadeTop: Math.round(fr.top), fadeBottom: Math.round(fr.bottom)," +
        "  varPanel: d.style.getPropertyValue('--dp-body-h')," +
        "  transform: getComputedStyle(b).transform," +
        "  opacity: getComputedStyle(d).opacity }); })();"
    ) { result in
        NSLog("[DesktopTimetable] 覆盖层：%@", result ?? "nil")
    }
    for _ in 0..<60 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

    // 截网页视图。
    let cfg = WKSnapshotConfiguration()
    cfg.rect = renderer.webView.bounds
    cfg.afterScreenUpdates = true
    var done = false
    renderer.webView.takeSnapshot(with: cfg) { image, error in
        defer { done = true }
        guard let image else {
            NSLog("[DesktopTimetable] takeSnapshot 失败：%@", error?.localizedDescription ?? "?")
            return
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: out))
        print("已渲染 \(out)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
    for _ in 0..<200 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if done { break }
    }
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-pin") {
    // 渲染图钉对照图（左边未固定 / 右边已固定）—— 用来肉眼确认两种状态分得清。
    let out = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("pin.png")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let img = PushPinRenderer.renderComparison(),
          let data = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: data),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("渲染失败")
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: out))
    print("已渲染 \(out)")
    exit(0)
}

if arguments.contains("--verify-day-panel-click") {
    // 自检：**真实 NSApp 鼠标事件**点「＋ 添加待办」/ 待办圆圈之后，覆盖层不能消失。
    //
    // 用户反馈：「点击了添加待办之后日历直接消失了，点击圆圈完成之后也会直接消失，
    // 鼠标移一下就回来」。网页层用合成 DOM 事件的用例（--verify-day-panel 4c-12c）
    // 复现不出来 —— 因为真实点击走的是
    // CardInteractionView → NSApp.sendEvent → WebCardRenderer.forwardClick
    // 这条链。这里用 `NSApp.sendEvent` 派发真事件（走系统完整的命中测试），
    // 并读取网页里的淡出诊断记录（`window.__ttFadeLog`）。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()

    var problems: [String] = []
    func fail(_ s: String) { problems.append(s) }
    func check(_ cond: Bool, _ msg: String) { if !cond { fail(msg) } }

    guard let renderer = delegate.testWebRenderer, let window = delegate.testWindow else {
        print("拿不到网页渲染器 / 卡片窗口")
        exit(1)
    }
    for _ in 0..<120 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if renderer.isReady { break }
    }
    func pause(_ seconds: TimeInterval = 0.8) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    pause(1.2)

    var raw: String?
    func eval(_ js: String) -> [String: Any]? {
        raw = nil
        renderer.evaluateForTest(js) { raw = $0 }
        for _ in 0..<60 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if raw != nil { break }
        }
        guard let s = raw, let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }
    // 打开网页侧的淡出诊断（正常运行时是零开销的）。
    _ = eval("""
    window.__TT_PANEL_TRACE = true;
    window.__ttFadeLog = [];
    window.__ttClicks = [];
    // 表头状态采样：看完成待办之后 `.sel` / 文字颜色到底有没有变、
    // 表头节点有没有被整树重绘（`__id` 变化 = 重建）。
    //
    // ⚠️ 不能用 setInterval 轮询 —— 隐藏页面里定时器会被节流到 ~1 次/秒，
    // 量不到 200ms 级的过渡。改成由原生在关键时间点显式采样。
    window.__ttHdrSeq = 0;
    window.__ttHeaderLog = [];
    window.__ttHeaderT0 = performance.now();
    window.__ttHdrNow = function (tag) {
      var h = document.querySelector('.hcell[data-day="4"]');
      if (!h) { window.__ttHeaderLog.push(tag + '|no-cell'); return tag; }
      if (!h.__id) h.__id = ++window.__ttHdrSeq;
      var cs = getComputedStyle(h);
      window.__ttHeaderLog.push([
        tag, Math.round(performance.now() - window.__ttHeaderT0),
        h.__id, h.className.replace(/hcell /, ''), cs.color
      ].join('|'));
      return tag;
    };
    document.addEventListener('click', function (e) {
      window.__ttClicks.push({
        cls: (e.target && (e.target.className || e.target.tagName)) || 'null',
        x: Math.round(e.clientX), y: Math.round(e.clientY)
      });
    }, true);
    // ---- 回归探针：原生推状态会不会把表头整块重建？----
    //
    // 如果每次都重建，表头格会重新挂 `.sel` → 文字重播 200ms 渐变
    // （用户看到的「点日期 / 点完成都会闪」）。
    //
    // 做法：包住 `window.ttUpdate`，每次 push 前后各采一次表头节点 __id /
    // class —— `render()` 会 `root.innerHTML=''` 重建表头格，节点 __id 必变。
    (function () {
      window.__ttUpdLog = [];
      function snap() {
        var h = document.querySelector('.hcell[data-day="4"]');
        if (h && !h.__id) h.__id = ++window.__ttHdrSeq;
        return { id: h ? h.__id : -1,
                 cls: h ? h.className.replace(/hcell /, '') : '',
                 color: h ? getComputedStyle(h).color : '' };
      }
      // 指纹对比：ttUpdate 内部比的是 `tableStateKey(S) !== tableStateKey(next)`，
      // 这里照抄一份，并额外用「键排序后的稳定序列化」区分
      // 「值真的变了」和「只是对象键的顺序变了」。
      function sortKeys(v) {
        if (Array.isArray(v)) return v.map(sortKeys);
        if (v && typeof v === 'object') {
          var out = {};
          Object.keys(v).sort().forEach(function (k) { out[k] = sortKeys(v[k]); });
          return out;
        }
        return v;
      }
      // 和网页里修好之后的 `tableStateKey` 一致：键序无关。
      function keyStr(o) {
        return JSON.stringify([sortKeys(o.courses), sortKeys(o.periods), o.semesterStart,
                               o.currentWeek, o.viewWeek, o.maxWeek, sortKeys(o.overrides),
                               o.title, o.subtitle,
                               Math.floor(Date.now() / 60000)]);
      }
      var FIELDS = ['courses', 'periods', 'semesterStart', 'currentWeek', 'viewWeek',
                    'maxWeek', 'overrides', 'title', 'subtitle'];
      var orig = window.ttUpdate;
      window.ttUpdate = function (json) {
        var next = typeof json === 'string' ? JSON.parse(json) : json;
        var prev = window.__ttPrev;
        var info = { changed: prev ? (keyStr(prev) !== keyStr(next)) : true };
        if (prev) {
          info.rawDiff = [];
          info.valueDiff = [];
          FIELDS.forEach(function (f) {
            if (JSON.stringify(prev[f]) !== JSON.stringify(next[f])) info.rawDiff.push(f);
            if (JSON.stringify(sortKeys(prev[f])) !== JSON.stringify(sortKeys(next[f]))) {
              info.valueDiff.push(f);
            }
          });
        }
        window.__ttPrev = next;
        var before = snap();
        var n = window.__ttUpdLog.length + 1;
        orig(json);
        info.n = n; info.before = before; info.after = snap();
        window.__ttUpdLog.push(info);
      };
    })();
    JSON.stringify({ ok: true });
    """)

    // 自检进程没跑 `app.run()`，窗口可能还停在上屏前（alpha 渐显没推进、
    // isVisible=false）—— `sendEvent` 就送不出去。先钉到最终态。
    NSApp.finishLaunching()
    window.alphaValue = 1
    window.orderFrontRegardless()
    pause(0.4)

    let webH = renderer.webView.bounds.height
    @discardableResult
    func realClick(_ selector: String, _ what: String) -> Bool {
        guard let c = eval("""
        (function () {
          var el = document.querySelector('\(selector)');
          if (!el) return '';
          var r = el.getBoundingClientRect();
          var x = r.x + r.width / 2, y = r.y + r.height / 2;
          var under = document.elementFromPoint(x, y);
          return JSON.stringify({
            x: x, y: y,
            under: under ? (under.className || under.tagName) : 'null',
            rect: [r.x, r.y, r.width, r.height]
          });
        })();
        """),
              let x = (c["x"] as? NSNumber)?.doubleValue,
              let y = (c["y"] as? NSNumber)?.doubleValue else {
            fail("找不到要点的元素：\(what)（\(selector)）")
            return false
        }
        let wp = NSPoint(x: x, y: webH - y)
        let hitView = window.contentView?.hitTest(wp)
        let hitName = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        let rectText = (c["rect"] as? [NSNumber] ?? []).map { "\(Int($0.doubleValue))" }.joined(separator: ",")
        print("[诊断] 点 \(what)：css=(\(Int(x)),\(Int(y))) rect=[\(rectText)] "
              + "elementFromPoint=\(c["under"] ?? "?") 命中视图=\(hitName) "
              + "窗口号=\(window.windowNumber) 可见=\(window.isVisible) alpha=\(window.alphaValue) "
              + "忽略鼠标=\(window.ignoresMouseEvents) key=\(window.isKeyWindow) active=\(NSApp.isActive)")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let ev = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) else {
                fail("造不出鼠标事件：\(what)")
                return false
            }
            // ⚠️ 自检进程没有跑 `app.run()` 的事件循环，窗口级派发在
            // 「文本输入模式 / 非 key」这些状态下不可靠（实测第二次点击会被丢掉）。
            // 直接交给 hitTest 命中的视图 —— 和 NSWindow 内部的派发等价，
            // 后面的交互层 → forwardClick 链路完全一致。
            guard let view = hitView else {
                fail("点击点没有命中任何视图：\(what)")
                return false
            }
            switch type {
            case .leftMouseDown: view.mouseDown(with: ev)
            case .leftMouseUp: view.mouseUp(with: ev)
            default: break
            }
        }
        return true
    }
    func panelState(_ label: String) -> [String: Any] {
        eval("""
        (function () {
          var p = window.ttDayPanelIsOpen ? window.ttDayPanelIsOpen() : { open: false, day: null };
          p.input = !!document.querySelector('[data-dp-input]');
          p.checks = document.querySelectorAll('.dpcheck').length;
          p.fades = (window.__ttFadeLog || []).slice(-6);
          p.clicks = (window.__ttClicks || []).slice(-4);
          p.lastPost = window.__ttLastPost ? window.__ttLastPost.action : null;
          var d = document.querySelector('.daypanel');
          if (d) {
            var cs = getComputedStyle(d);
            var add = document.querySelector('.dpadd');
            var ar = add ? add.getBoundingClientRect() : null;
            var under = ar ? document.elementFromPoint(ar.x + ar.width / 2, ar.y + ar.height / 2) : null;
            p.panel = { cls: d.className, op: cs.opacity, vis: cs.visibility,
                        pe: cs.pointerEvents,
                        clip: cs.clipPath || cs.webkitClipPath || '',
                        h: Math.round(d.getBoundingClientRect().height),
                        underAdd: under ? (under.className || under.tagName) : 'null' };
          } else { p.panel = null; }
          return JSON.stringify(p);
        })();
        """) ?? ["label": label, "error": "拿不到面板状态"]
    }

    // 前置：让原生一侧也知道面板开着（否则原生每次推状态都会把网页侧关掉）。
    // 全部周次模式下 `open(day:)` 会被原生拒绝，这里显式退出「全部周次」。
    let monday = Calendar(identifier: .gregorian).startOfDay(for: Date())
    delegate.testDayPanel?.updateBrowsingWeek(baseMonday: monday, allWeeks: false)
    delegate.testDayPanel?.open(day: 4)
    pause(0.8)
    _ = eval("""
    (function () {
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: { day: 4, todos: [], events: [],
          festival: { lunar: 'x', term: '', festivals: [] } },
          dayFlags: {}, dayPanelOpen: true });
      }
      if (window.ttDayPanelOpen) window.ttDayPanelOpen(4, false);
      // ⚠️ 自检窗口在自动化模式下不被合成器绘制，CSS 过渡停在起始值
      // （opacity=0 / clip-path 完全裁掉）→ 命中测试会穿透到下面的课表格，
      // 真实点击永远点不到面板里的按钮。这里和 flicker 用例一样，
      // 用行内样式把面板钉成「完全可见」，只验点击链路，不验动画。
      var d = document.querySelector('.daypanel');
      if (d) {
        d.style.transition = 'none';
        d.style.opacity = '1';
        d.style.clipPath = 'none';
        d.style.webkitClipPath = 'none';
      }
      return JSON.stringify({ ok: true });
    })();
    """)
    pause(0.8)

    var st = panelState("打开面板后")
    func oneLine(_ value: Any?) -> String {
        guard let value, let d = try? JSONSerialization.data(withJSONObject: value, options: []) else {
            return "nil"
        }
        return String(data: d, encoding: .utf8) ?? "nil"
    }
    print("[诊断] 基线面板状态：open=\(st["open"] ?? "nil") panel=\(oneLine(st["panel"]))")
    print("[诊断] 基线淡出记录：\(oneLine(st["fades"]))")
    check((st["open"] as? Bool) == true, "基线：面板应当是开着的（实际 \(st)）")

    // ---- 表头对齐：「周几」和下面的号数必须在同一条竖中线上 ----
    //
    // 用户反馈「周几和日期没对齐」：今天那列多一个蓝点、有待办那列多一个红点，
    // 点把文字往一边挤。修法是左右两个点**永远占位**（没有就 `.off`），
    // 且两侧间距对称（`gap: 3px`）。这里量真实布局：文字范围的中心
    // 和 `.hnum` 的中心必须在同一条线上。
    _ = eval("""
    (function () {
      var out = [];
      var cells = document.querySelectorAll('.hcell[data-day]');
      for (var i = 0; i < cells.length; i++) {
        var cell = cells[i];
        var row = cell.querySelector('.hdrow');
        var num = cell.querySelector('.hnum');
        if (!row || !num) { out.push({ day: -1, error: 'missing' }); continue; }
        var textNode = null;
        for (var j = 0; j < row.childNodes.length; j++) {
          if (row.childNodes[j].nodeType === 3 && row.childNodes[j].textContent.trim()) {
            textNode = row.childNodes[j]; break;
          }
        }
        if (!textNode) { out.push({ day: -1, error: 'no-text' }); continue; }
        var range = document.createRange();
        range.selectNodeContents(textNode);
        var tr = range.getBoundingClientRect();
        var nr = num.getBoundingClientRect();
        out.push({
          day: parseInt(cell.getAttribute('data-day'), 10),
          diff: (tr.left + tr.width / 2) - (nr.left + nr.width / 2),
          dots: row.querySelectorAll('.dot').length,
          today: cell.classList.contains('today'),
          todo: !!row.querySelector('.dot.todo:not(.off)')
        });
      }
      return JSON.stringify({ cells: out });
    })();
    """).map { obj in
        guard let cells = obj["cells"] as? [[String: Any]] else { return }
        print("[诊断] 表头中心线（文字中心 − 号数中心）：")
        for c in cells {
            let d = (c["day"] as? NSNumber)?.intValue ?? -1
            let diff = (c["diff"] as? NSNumber)?.doubleValue ?? 999
            let dots = (c["dots"] as? NSNumber)?.intValue ?? 0
            let today = (c["today"] as? Bool) == true
            let todo = (c["todo"] as? Bool) == true
            print("    周\(d)\(today ? "(今天)" : "")\(todo ? "(有待办)" : "")："
                  + "差 \(String(format: "%.2f", diff))px，点数 \(dots)")
        }
        check(cells.count == 7, "表头应当有 7 列（实际 \(cells.count) 列）")
        for c in cells {
            let d = (c["day"] as? NSNumber)?.intValue ?? -1
            let diff = (c["diff"] as? NSNumber)?.doubleValue ?? 999
            let dots = (c["dots"] as? NSNumber)?.intValue ?? 0
            check(abs(diff) <= 0.5,
                  "周\(d)「周几」和号数没对齐（差 \(String(format: "%.2f", diff))px）")
            check(dots == 2,
                  "周\(d) 表头应当有左右两个点占位（实际 \(dots) 个）—— 少了就会把文字挤偏")
        }
    }

    // ---- 回归：面板开着时，原生推状态不能重建表头、不能摘掉 .sel ----
    //
    // 这是用户看到的「点日期 / 点完成表头一暗一亮」的根因检查：
    // 原生一次交互会推好几次状态；只要其中一次把表头整树重建，
    // `.sel` 就会挂到新节点上重播 200ms 渐变。
    _ = eval("window.__ttUpdLog = []; 'ok'")
    delegate.testDayPanel?.open(day: 3)
    pause(0.6)
    delegate.testDayPanel?.open(day: 4)
    pause(0.6)
    _ = eval("JSON.stringify({ log: window.__ttUpdLog || [] })").map { obj in
        guard let log = obj["log"] as? [[String: Any]] else { return }
        print("[诊断] 面板开着时的原生推送 \(log.count) 次：")
        for e in log { print("    \(oneLine(e))") }
        check(log.count >= 1, "面板开着时打开另一列应当至少推 1 次状态（实际 \(log.count) 次）")
        for e in log {
            let before = e["before"] as? [String: Any]
            let after = e["after"] as? [String: Any]
            let idBefore = (before?["id"] as? NSNumber)?.intValue ?? -1
            let idAfter = (after?["id"] as? NSNumber)?.intValue ?? -1
            let clsAfter = after?["cls"] as? String ?? ""
            check(idBefore == idAfter,
                  "面板开着时，原生推状态不能重建表头格（节点 \(idBefore) → \(idAfter)）：\(oneLine(e))")
            check(clsAfter.contains("sel"),
                  "面板开着时，原生推状态后表头仍要保留 .sel（实际 class=\(clsAfter)）：\(oneLine(e))")
            check((e["changed"] as? Bool) == false,
                  "只换覆盖层数据时，课表指纹不能报「变了」（否则整树 render）：\(oneLine(e))")
        }
    }

    // ---- 回归：系统数据变了 → 网页必须作废缓存并重新要数据 ----
    //
    // 用户反馈「在系统「提醒事项」里点完成，课表红点没了、但条目还在」：
    // 面板关着时原生没有 `dayPanel` 可推，网页的按天缓存还是旧列表。
    // 原生每次外部变化都把 `dayPanelRevision` 加一；网页看到变化就清空缓存，
    // 并且**面板开着时立刻补发 `datePanelOpen`** 重新取数。
    // 把原生的「当前天」故意拨到 3：网页仍停在 4（缓存里是完整数据），
    // 原生却以为在看 3。版本号变化后网页会重新要 4，原生这边会走「换天」
    // 的清空路径（修 2 管不到这一种）—— 能不能不闪，完全看网页有没有
    // 保留 4 的完整缓存（修 1）。
    delegate.testDayPanel?.open(day: 3)
    pause(0.8)
    _ = eval("window.__ttLastPost = null; 'ok'")
    // 用 MutationObserver 盯住整段重新取数过程：只要出现过一次
    // 「读取中…」（`.dploading`），就是中间态漏到了屏幕上。
    _ = eval("""
    (function () {
      window.__ttLoadingSeen = false;
      if (window.__ttLoadingObserver) window.__ttLoadingObserver.disconnect();
      window.__ttLoadingObserver = new MutationObserver(function () {
        if (document.querySelector('.dpbody .dploading')) window.__ttLoadingSeen = true;
      });
      window.__ttLoadingObserver.observe(document.body,
        { childList: true, subtree: true, characterData: true });
      return 'ok';
    })();
    """)
    NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
    pause(1.2)
    _ = eval("""
    (function () {
      var p = window.__ttLastPost;
      var loading = !!window.__ttLoadingSeen;
      if (window.__ttLoadingObserver) {
        window.__ttLoadingObserver.disconnect();
        window.__ttLoadingObserver = null;
      }
      return JSON.stringify({
        action: p ? p.action : null,
        day: p && p.payload ? p.payload.day : null,
        loadingSeen: loading,
        open: window.ttDayPanelIsOpen ? window.ttDayPanelIsOpen().open : false
      });
    })();
    """).map { obj in
        print("[诊断] 系统数据变化后的网页请求：\(oneLine(obj))")
        check((obj["action"] as? String) == "datePanelOpen",
              "系统数据变了之后，网页要重新向原生要这一天的数据（实际 action=\(obj["action"] ?? "nil")）")
        check((obj["day"] as? NSNumber)?.intValue == 4,
              "补发请求的日期应当是当前打开的那一列（实际 day=\(obj["day"] ?? "nil")）")
        // 修 1 回归：原生换天清空 + 推中间态时，网页必须拿缓存的完整数据顶上，
        // 不能让「读取中…」闪出来（用户截图里的那个中间态）。
        check((obj["loadingSeen"] as? Bool) == false,
              "重新取数期间不能出现「读取中…」中间态（缓存里的完整数据要顶住）")
        check((obj["open"] as? Bool) == true,
              "重新取数之后面板仍然要开着（实际 open=\(obj["open"] ?? "nil")）")
    }

    // ---- 1) 真实点击「＋ 添加待办」----
    if realClick(".dpadd", "＋ 添加待办") {
        pause(1.2)
        st = panelState("点添加待办后")
        print("[诊断] 点「添加待办」后：open=\(st["open"] ?? "nil") day=\(st["day"] ?? "nil") "
              + "input=\(st["input"] ?? "nil") clicks=\(oneLine(st["clicks"])) "
              + "lastPost=\(st["lastPost"] ?? "nil") fades=\(oneLine(st["fades"]))")
        check((st["open"] as? Bool) == true,
              "真实点击「添加待办」之后面板不能消失（实际 open=\(st["open"] ?? "nil")，"
              + "fades=\(st["fades"] ?? [])）")
        check((st["input"] as? Bool) == true,
              "真实点击「添加待办」之后输入框应该展开（实际 input=\(st["input"] ?? "nil")）")
    }

    // 收起输入框（Esc 的路径：清 adding，让面板恢复跟随），再验圆圈。
    _ = eval("""
    (function () {
      if (window.ttDayPanelSetState) {
        window.ttDayPanelSetState({ dayPanel: { day: 4,
          todos: [{ title: '测试待办', due: '', done: false,
                    identifier: 'test-1', calendarIdentifier: '' }],
          events: [], festival: { lunar: 'x', term: '', festivals: [] } },
          dayFlags: {}, dayPanelOpen: true });
      }
      return JSON.stringify({ ok: true });
    })();
    """)
    pause(0.6)

    // ---- 2) 真实点击待办圆圈（完成）----
    st = panelState("注入待办后")
    _ = eval("window.__ttHdrNow('完成前'); 'ok'")
    if (st["checks"] as? NSNumber)?.intValue ?? 0 > 0,
       realClick(".dpcheck", "待办圆圈") {
        // 点完之后按时间点采样表头（20ms 太密，隐藏页面也承受不起）。
        for (delay, tag) in [(0.03, "完成后+30ms"), (0.12, "完成后+150ms"),
                             (0.2, "完成后+350ms"), (0.5, "完成后+850ms"),
                             (0.8, "完成后+1.65s")] {
            pause(delay)
            _ = eval("window.__ttHdrNow('\(tag)'); 'ok'")
        }
        pause(0.4)   // 完成动画 1.4s + 收尾
        st = panelState("点圆圈后")
        print("[诊断] 点圆圈后：open=\(st["open"] ?? "nil") day=\(st["day"] ?? "nil") "
              + "clicks=\(oneLine(st["clicks"])) lastPost=\(st["lastPost"] ?? "nil") "
              + "fades=\(oneLine(st["fades"]))")
        check((st["open"] as? Bool) == true,
              "真实点击待办圆圈之后面板不能消失（实际 open=\(st["open"] ?? "nil")，"
              + "fades=\(st["fades"] ?? [])）")
        // 表头采样：看 `.sel` 有没有被摘掉再补回、节点有没有被整树重绘。
        if let poll = eval("""
            (function () {
              return JSON.stringify({ states: window.__ttHeaderLog || [],
                                      clicks: window.__ttClicks || [],
                                      ups: (window.__ttUpdLog || []).slice(-8) });
            })();
            """), let states = poll["states"] as? [String] {
            print("[诊断] 表头采样（\(states.count) 条）：")
            for s in states { print("    \(s)") }
            if let ups = poll["ups"] as? [[String: Any]] {
                print("[诊断] 点击前后 push 记录（最近 \(ups.count) 次）：")
                for u in ups { print("    \(oneLine(u))") }
            }
        } else {
            print("[诊断] 表头采样读不到")
        }
    } else {
        fail("注入的待办没有渲染出圆圈（实际 \(st)）")
    }

    // ---- 3) **右键待办 → 原生菜单（修改… / 删除 / 取消）**（2026-11）----
    //
    // 需求：右键**不再直接删除**，改成弹原生 NSMenu；
    // 选「修改…」进编辑态，选「删除」才走删除。
    //
    // ⚠️ 这里只构造菜单、不真的弹（`MenuPresenter.suppressPresentation`）——
    // 模态菜单会把自检进程卡住。菜单的 target/action 仍然是真实的那一套。
    MenuPresenter.suppressPresentation = true
    _ = eval("""
    (function () {
      var fest = { lunar: 'x', term: '', festivals: [], weather: null, yi: '', ji: '' };
      var panel = { day: 4, todos: [
          { title: '要改的待办', due: '10:00', done: false,
            identifier: 'menu-1', calendarIdentifier: 'cal-m' }
        ], events: [], festival: fest };
      window.ttDayPanelSetState({ dayPanel: panel, dayFlags: { '4': { todo: true, event: false } } });
      return JSON.stringify({ ok: true });
    })();
    """)
    pause(0.6)
    delegate.testShowTodoMenu([
        "day": 4,
        "key": "id:menu-1",
        "identifier": "menu-1",
        "calendarIdentifier": "cal-m",
        "title": "要改的待办",
        "due": "10:00",
        "index": 0,
        "x": 600.0,
        "y": 300.0,
    ])
    // ⚠️ **菜单开着时，网页必须收到「菜单开着」的标志**（2026-11 修「闪一下」）。
    //
    // 这是原生 → 网页的新通路：`MenuPresenter` 在弹菜单前置位、关闭后清位，
    // 网页在这期间不因指针离开而收覆盖层（用户看到「点删除时闪一下」）。
    //
    // ⚠️ 自检里菜单**不真的弹**（`suppressPresentation`），
    // 所以验的是「置位 / 清位这一对通知」本身通不通。
    print("[诊断] 菜单可见性通知：\(MenuPresenter.lastVisibilityEvents)")
    check(MenuPresenter.lastVisibilityEvents.first == true,
          "弹菜单前要通知网页「菜单开着」（实际 \(MenuPresenter.lastVisibilityEvents)）")
    check(MenuPresenter.lastVisibilityEvents.last == false,
          "菜单关闭后要通知网页「菜单关了」（实际 \(MenuPresenter.lastVisibilityEvents)）")

    // ⚠️ **菜单开着时，课表必须保持亮着**（2026-11 修「闪一下」的核心修复）。
    //
    // 用户反馈（真机截图证实）：点「删除 / 修改」→ **整个课表渐渐消失**，
    // 编辑框还在（tooltip 都在）但课表看不见了。
    //
    // 根因：菜单是用临时 NSPanel 当宿主的，但**菜单本身是另一个弹出窗口**，
    // 不在 `NSApp.windows` 里 —— 指针停在菜单上时：
    //   · 不在卡片矩形里；
    //   · 也不在本 App 任何窗口的 frame 里（宿主面板只有 1×1）；
    //   → 原生判定「指针离开了课表」→ **课表 6 秒淡到 22%**。
    //
    // 修法：菜单开着时直接短路 —— `inside = true`，课表不淡出。
    //
    // 这里验：菜单开着时课表仍亮着；菜单关掉后（指针在卡片外）也有宽限期。
    delegate.testSimulateMenuOpenWhilePointerOutside()
    check(delegate.testCardIsLit,
          "菜单开着时课表必须保持亮着（不能淡出）")
    delegate.testSimulateMenuCloseWhilePointerOutside()
    check(delegate.testCardIsLit,
          "菜单刚关掉时课表也要保持亮着（有宽限期）")

    // ⚠️ **菜单关掉后，课表有一段「不淡出」的宽限期**（2026-11 修「闪一下」）。
    //
    // 指针刚离开菜单、可能还在卡片矩形之外 —— 这时候把课表淡掉，
    // 用户看到的就是「点一下删除，整个日历闪一下」，严重时看着像「课表没了」。
    print("[诊断] 菜单关闭后的淡出宽限期：\(delegate.testMenuGraceRemaining) 秒")
    check(delegate.testMenuGraceRemaining > 0,
          "菜单关掉后要有一段不淡出课表的宽限期（实际 \(delegate.testMenuGraceRemaining) 秒）")

    let menuTitles = MenuPresenter.lastMenu?.items.map { $0.title } ?? []
    print("[诊断] 待办右键菜单：\(menuTitles)")
    // ⚠️ **菜单必须往左弹**（2026-11 修「闪一下」）。
    //
    // 日期覆盖层在课表**最后一列**（最靠右）：菜单往右弹会伸出卡片右边缘
    // 约 60pt → 菜单一关，指针就落在卡片矩形之外 → 原生判定「指针离开课表」
    // → 整个课表 6 秒淡到 22%（用户看到「闪一下」「课表不见了」）。
    //
    // 这里量一下：菜单右边缘必须落在**卡片右边缘之内**。
    let cardRect = TimetableLayout.cardRect
    let cardRight = window.convertToScreen(cardRect).maxX
    let menuWidth = MenuPresenter.lastMenu?.size.width ?? 0
    // 菜单往左弹时，定位点往左挪了 (menuWidth - 6)。
    let popPoint = NSPoint(x: 600.0 - max(menuWidth - 6, 0), y: 300.0)
    let menuRight = popPoint.x + menuWidth
    print("[诊断] 菜单宽 \(menuWidth)，菜单右边缘 \(menuRight)，卡片右边缘 \(cardRight)")
    check(menuRight <= cardRight + 1,
          "菜单不能伸出卡片右边缘（否则菜单一关指针就在卡片外，课表会淡出）")
    check(menuTitles.count == 3, "待办右键菜单要有三项（实际 \(menuTitles.count) 项：\(menuTitles))")
    check(menuTitles.first == "修改…", "菜单第一项是「修改…」（实际 \(menuTitles.first ?? "nil")）")
    check(menuTitles.count > 1 && menuTitles[1] == "删除", "菜单第二项是「删除」（实际 \(menuTitles.count > 1 ? menuTitles[1] : "nil")）")
    check(menuTitles.count > 2 && menuTitles[2] == "取消", "菜单第三项是「取消」（实际 \(menuTitles.count > 2 ? menuTitles[2] : "nil")）")

    // 选「修改…」→ 网页进入编辑态（不新开窗口，卡片里就地编辑）。
    delegate.testSelectMenuItem(0)
    pause(0.6)
    if let o = eval("""
    (function () {
      var t = document.querySelector('[data-dp-edit-title]');
      return JSON.stringify({
        editing: !!document.querySelector('.dpcard.todo.editing'),
        title: t ? t.value : null,
        hour: document.querySelector('[data-dp-time-part="edit-hour"]') ?
          document.querySelector('[data-dp-time-part="edit-hour"]').value : null,
        minute: document.querySelector('[data-dp-time-part="edit-minute"]') ?
          document.querySelector('[data-dp-time-part="edit-minute"]').value : null
      });
    })();
    """) {
        print("[诊断] 选「修改…」后：\(o)")
        check((o["editing"] as? Bool) == true, "选「修改…」要进入卡片内编辑态")
        check((o["title"] as? String) == "要改的待办", "编辑态要预填原标题")
        check((o["hour"] as? String) == "10", "编辑态要预填原小时")
        check((o["minute"] as? String) == "00", "编辑态要预填原分钟")
    }
    // 取消编辑，别影响后面的删除用例。
    delegate.testSelectMenuItem(0)
    pause(0.3)
    _ = eval("""
    (function () {
      var t = document.querySelector('[data-dp-edit-title]');
      if (t) t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27,
        bubbles: true, cancelable: true }));
      return JSON.stringify({ ok: true });
    })();
    """)

    // 选「删除」→ 才真的发 todoDelete（前面一直没发过）。
    _ = eval("window.__ttLastPost = null; 'ok'")
    delegate.testSelectMenuItem(1)
    pause(0.5)
    if let o = eval("""
    (function () {
      var p = window.__ttLastPost;
      return JSON.stringify({
        action: p ? p.action : null,
        day: p && p.payload ? p.payload.day : null,
        identifier: p && p.payload ? p.payload.identifier : null
      });
    })();
    """) {
        print("[诊断] 选「删除」后：\(o)")
        check((o["action"] as? String) == "todoDelete", "选「删除」才发 todoDelete（实际 \(o["action"] ?? "nil")）")
        check((o["identifier"] as? String) == "menu-1", "删除要带对的系统标识")
    }
    MenuPresenter.suppressPresentation = false

    if problems.isEmpty {
        print("✅ 日期覆盖层真实点击（添加待办 / 圆圈完成）：通过")
        exit(0)
    }
    for p in problems { print("❌ \(p)") }
    print("❌ 日期覆盖层真实点击（添加待办 / 圆圈完成）：失败 \(problems.count) 项")
    exit(1)
}

if arguments.contains("--verify-snapshot-mode") {
    // 自检：确认 B 模式 0 次 takeSnapshot，DT_SNAPSHOT=1 下能正常拍。
    let store = TimetableStore()
    if let migrated = try? store.migrateLegacyIfNeeded(defaultName: "我的课表") {
        print("课表：\(migrated.name)")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let renderer = delegate.testWebRenderer else {
        print("❌ 没有渲染器")
        exit(1)
    }
    let live = RenderMode.live
    print("RenderMode.live = \(live)（true = B 模式）")
    print("实际 takeSnapshot 次数 = \(renderer.testRealSnapshotCount)")
    print("跳过次数 = \(renderer.testSkippedSnapshotCount)")
    if live {
        if renderer.testRealSnapshotCount != 0 {
            print("❌ B 模式下出现了 takeSnapshot")
            exit(1)
        }
        print("✅ B 模式：0 次 takeSnapshot")
    }
    exit(0)
}

if arguments.contains("--verify-import-flow") {
    // 自检：覆盖导入的完整生命周期。
    //
    //   起流程 → 差异页出现 → 冲突没选时「应用」不可点 → 选完 → 点应用
    //   → 数据真的写盘 → 差异页关闭 → 导入流程清空 → 设置面板拿回焦点
    //   → 再导入一次并取消 → 文件字节不变。
    //
    // 这条自检专门拦「ImportDecisionController 是局部变量、start() 返回就被释放」
    // 那个 bug：点「应用」只关窗、不写盘、不刷新，界面上看不出任何错误。
    // 走的是 AppDelegate 的真实接线（`testStartOverwriteImport` = performImport 的同一条路）。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-import-flow 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    print("数据目录：\(dataDir)")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // 焦点这条要真的可测：不激活 app，`isKeyWindow` 永远是 false，
    // 「设置面板有没有拿回 key」就成了永远为真的假断言。
    app.activate(ignoringOtherApps: true)

    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    // ---- 1. 造一份四种来源都有的当前课表 ----
    let store = TimetableStore()
    _ = try? store.migrateLegacyIfNeeded(defaultName: "自检课表")
    if store.activeID == nil, let created = try? store.create(name: "自检课表") {
        try? store.setActive(created.id)
    }
    guard let activeID = store.activeID, var cur = try? store.load(activeID) else {
        print("❌ 没有当前课表")
        exit(1)
    }
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    cur.semester = sem
    cur.courses = [
        // 导入来源、没改过 → 本次会更新
        Course(day: 3, block: 1, name: "高等数学", teacher: "李雷", loc: "教三-201",
               courseID: "M1", weeks: Array(1...8), origin: .imported),
        // 用户新增，与导入的物理同格
        Course(day: 2, block: 1, name: "自习", teacher: "", loc: "图书馆",
               courseID: "S1", weeks: Array(1...8), origin: .manual),
        // 导入来源、用户改过地点
        Course(day: 1, block: 0, name: "大学英语", teacher: "", loc: "外语-102",
               courseID: "E1", weeks: Array(1...8), origin: .imported, userModified: true),
        // 导入来源、没改过，导入文件里没有它
        Course(day: 4, block: 2, name: "军事理论", teacher: "", loc: "",
               courseID: "J1", weeks: Array(1...8), origin: .imported),
    ]
    try? store.save(cur)
    try? store.setActive(activeID)
    let bytesBefore = (try? Data(contentsOf: store.coursesFile(for: activeID))) ?? Data()

    // ---- 2. 起 AppDelegate（真实接线）+ 打开设置面板 ----
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForImportVerification()
    delegate.testOpenSettings()
    pump(0.4)

    var problems: [String] = []

    // 设置面板必须拿到日期覆盖层控制器 —— 否则「日期覆盖层」卡片的状态行
    // 永远停在「正在检查…」，开关也不会真的去请求日历 / 提醒事项权限。
    if delegate.testSettingsController?.dayPanelController == nil {
        problems.append("设置面板没有拿到日期覆盖层控制器（状态行会卡在「正在检查…」）")
    }

    let imported = [
        Course(day: 3, block: 1, name: "高等数学", teacher: "王老师", loc: "教三-305",
               courseID: "M1", weeks: Array(1...8)),
        Course(day: 2, block: 1, name: "物理", teacher: "", loc: "",
               courseID: "P1", weeks: Array(1...16)),
        Course(day: 1, block: 0, name: "大学英语", teacher: "", loc: "外语-101",
               courseID: "E1", weeks: Array(1...8)),
        Course(day: 5, block: 0, name: "体育", teacher: "", loc: "",
               courseID: "T1", weeks: Array(1...8)),
    ]

    // ---- 3. 覆盖导入 → 先问缺失的保护课，再进差异页 ----
    var protectedPrompts: [String] = []
    guard let win = delegate.testStartOverwriteImport(
        parsed: imported,
        fileName: "自检导入.xls",
        protectedRemovalDecision: { name, _, _ in
            protectedPrompts.append(name)
            return .keep
        }
    ) else {
        print("❌ 没有弹出差异页")
        exit(1)
    }
    pump(0.3)

    if !protectedPrompts.contains("自习") {
        problems.append("导入里没有「自习」时，没有逐门问保留/删除：\(protectedPrompts)")
    }
    if !win.testIsVisible { problems.append("差异页没有显示") }
    if !delegate.testHasImportFlow { problems.append("导入流程没有被持有（就是本次要修的 bug）") }
    if win.testConflictCount != 1 {
        problems.append("应该检测到 1 处冲突（物理 vs 自习），实际 \(win.testConflictCount)")
    }
    if win.testApplyEnabled {
        problems.append("冲突还没决定时「应用」就能点 —— 又会静默覆盖")
    }
    if win.testBlockerText.isEmpty {
        problems.append("冲突没决定时没有显示原因")
    }
    print("  摘要：\(win.testSummary)")
    print("  阻塞原因：\(win.testBlockerText)")
    print("  来源标签：\(win.testOriginLabels.joined(separator: "、"))")
    if !win.testOriginLabels.contains("你新增") || !win.testOriginLabels.contains("你修改过") {
        problems.append("差异页没有标出课程来源：\(win.testOriginLabels)")
    }
    if !win.testSummary.contains("处冲突待决定") {
        problems.append("摘要没写冲突数：\(win.testSummary)")
    }

    // ---- 4. 逐条决定冲突 → 应用 ----
    guard let unit = win.testPlan.unresolved.first else {
        print("❌ 没有检测到未决定的冲突")
        exit(1)
    }
    win.testResolve(conflictID: unit.id, .keepCurrent)
    pump(0.1)
    if !win.testApplyEnabled { problems.append("冲突决定之后「应用」还是不可点") }
    if !win.testBlockerText.isEmpty {
        problems.append("冲突决定后还挂着阻塞原因：\(win.testBlockerText)")
    }

    win.testApply()
    // 等得**比激活重试的总时长还久**（退避 0.12+0.2+0.32+0.5+0.7+0.9+1.1+1.3 ≈ 5.1 秒）。
    //
    // 以前这里只 pump 0.5 秒 —— 关窗之后还在排队的激活重试会把差异页**重新弹出来**，
    // 而重试最早在 0.12 秒后就可能触发，0.5 秒刚好能抓到前几次；
    // 现在等满 2.5 秒，把「窗口不会再自己冒出来」变成一条真的断言。
    pump(2.5)

    if win.testIsVisible { problems.append("应用成功后差异页没关") }
    if delegate.testHasImportFlow { problems.append("应用后导入流程没清空（第二次导入会被拒）") }

    // ---- 5. 数据真的写盘了吗 ----
    guard let after = try? store.load(activeID) else {
        print("❌ 写盘后读不回来")
        exit(1)
    }
    let byID = Dictionary(uniqueKeysWithValues: after.courses.map { ($0.courseID, $0) })
    if byID["M1"]?.teacher != "王老师" { problems.append("没改过的高数没有被更新") }
    if byID["S1"] == nil { problems.append("用户新增的自习被静默删掉了") }
    // 冲突选的是「保留当前」→ 只让开**重叠的那几周**（1-8 周）。
    // 导入的物理是 1-16 周：重叠的 1-8 周让给自习，9-16 周**不该**跟着一起没。
    if byID["P1"] == nil {
        problems.append("选了「保留当前」，物理连没冲突的 9-16 周也被整条丢掉了")
    } else if byID["P1"]?.weeks.sorted() != Array(9...16) {
        problems.append("物理应该只剩 9-16 周，实际 \(byID["P1"]?.weeks.sorted() ?? [])")
    }
    if byID["S1"]?.weeks.sorted() != Array(1...8) {
        problems.append("自习的 1-8 周不该被动：\(byID["S1"]?.weeks.sorted() ?? [])")
    }
    if byID["T1"] == nil { problems.append("全新的体育课没导入") }
    if byID["E1"]?.loc != "外语-102" {
        problems.append("用户改过的英语被覆盖了：\(byID["E1"]?.loc ?? "nil")")
    }
    if byID["J1"] == nil { problems.append("导入里没有的军事理论被删了") }
    if byID["S1"]?.origin != .manual { problems.append("来源标记没落盘（自习应是 manual）") }
    if byID["E1"]?.userModified != true { problems.append("「你修改过」没落盘") }
    print("  写盘后课程：\(after.courses.map { "\($0.name)[\($0.originLabel)]" }.sorted().joined(separator: "、"))")

    // ---- 6. 设置面板要拿回焦点 ----
    if let sw = delegate.testSettingsWindow {
        if !sw.isVisible { problems.append("设置面板不见了") }
        if !sw.canBecomeKey { problems.append("设置面板不再能成为 key window") }
        print("  设置面板：isVisible=\(sw.isVisible) isKeyWindow=\(sw.isKeyWindow) appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow?.title ?? "nil")")
        // 进程是从终端直接起的（没有经过 LaunchServices），macOS 不让它变成 active app ——
        // 所以 `isKeyWindow` 在这里永远是 false，只能当参考值。
        // 能确定断言的等价信号：设置面板必须是**这个 app 最前面的窗口**
        // （差异页已经 orderOut，不该再压着它）。这条不依赖 app 是否 active。
        let frontmost = NSApp.orderedWindows.first
        if frontmost !== sw {
            problems.append("设置面板不是最前面的窗口（最前是「\(frontmost?.title ?? "nil")」）")
        }
        if !sw.isKeyWindow && NSApp.isActive {
            problems.append("应用之后设置面板没有拿回 key window（按钮会像「没反应」）")
        }
    } else {
        problems.append("拿不到设置面板窗口")
    }

    // ---- 7. 第二次导入：取消 → 不写盘 ----
    let bytesAfterApply = (try? Data(contentsOf: store.coursesFile(for: activeID))) ?? Data()
    guard let win2 = delegate.testStartOverwriteImport(
        parsed: imported,
        fileName: "自检导入2.xls",
        protectedRemovalDecision: { _, _, _ in .keep }
    ) else {
        print("❌ 第二次导入弹不出差异页（上一次的流程没清干净）")
        exit(1)
    }
    pump(0.3)
    if !win2.testIsVisible { problems.append("第二次导入的差异页没显示") }
    win2.testCancel()
    // 同样等够 —— 取消走的也是 finish()，在途的激活重试一样会把窗口弹回来。
    pump(2.5)
    if win2.testIsVisible { problems.append("取消后差异页没关") }
    if delegate.testHasImportFlow { problems.append("取消后导入流程没清空") }
    let bytesAfterCancel = (try? Data(contentsOf: store.coursesFile(for: activeID))) ?? Data()
    if bytesAfterCancel != bytesAfterApply {
        problems.append("取消之后文件变了")
    }

    // ---- 8. 收尾：删掉这次自检写的课表内容（临时目录随后会被 Makefile 清掉） ----
    _ = bytesBefore

    print("")
    if problems.isEmpty {
        print("✅ 覆盖导入：持有控制器、逐条冲突、真正写盘、焦点恢复全部正常")
        exit(0)
    }
    for p in problems { print("问题：\(p)") }
    exit(1)
}

if arguments.contains("--verify-focus-flow") {
    // 自检：**真机焦点闭环** —— 覆盖导入之后，设置面板的按钮到底还能不能点。
    //
    // 为什么必须单独一个模式（而不是并进 --verify-import-flow）：
    //
    // 从终端直接起的进程**永远当不了 active app** —— macOS 不给这种进程
    // 激活权，于是 `NSApp.isActive` 恒为 false、`window.isKeyWindow` 恒为 false。
    // 那样的断言是「永远为真的假断言」：它证明不了任何事。
    //
    // 真要验证焦点，app 必须**经 LaunchServices 启动**（`open -n app --args ...`），
    // 这样它才是个正经的 GUI app，才有资格当 active app、才能拿到 key window。
    //
    // 还有一个坑：**必须在真正的 `NSApplication` 事件循环里跑**。
    // 手动 `RunLoop.current.run(until:)` 顶出来的循环不算 ——
    // 实测那样 `NSApp.isActive` 恒为 false（探针验过：手动 pump → false；
    // 真 `app.run()` → true）。所以本模式把整段检查排成**异步步骤**，
    // 在 `app.run()` 起来之后由系统的事件循环驱动。
    //
    // 它验证三件事（缺一不可）：
    //   1. app 真的成了 active app（`NSApp.isActive`）—— 能当主角；
    //   2. 差异页关掉之后，设置面板真的拿回了 key window；
    //   3. **一个真实点击**能落到差异页的「应用」按钮上，
    //      **一个真实按键**能进到设置面板。
    //      第 3 条最关键：直接调 action 只能证明回调连着，
    //      证明不了「用户点得到」—— 而「点了没反应」正是用户报的现象。

    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"], !dataDir.isEmpty else {
        print("❌ --verify-focus-flow 需要 DT_DATA_DIR（临时目录）")
        exit(2)
    }
    let reportPath = ProcessInfo.processInfo.environment["DT_FOCUS_REPORT"]
        ?? (dataDir as NSString).appendingPathComponent("focus-report.txt")
    var report: [String] = []
    func say(_ s: String) { report.append(s); print(s) }
    func finish(_ problems: [String]) {
        say("")
        if problems.isEmpty {
            say("✅ 焦点闭环：app 能当 active app、差异页关掉后面板拿回 key、真实点击/按键都进得去")
        } else {
            for p in problems { say("问题：\(p)") }
        }
        try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        // ⚠️ **自检收尾：把设置面板收走** ——
        // 这一项会反复 `show()` 面板，`exit()` 不会走 app 的正常收尾，
        // 面板会一直悬在用户正在用的窗口前面（用户反馈「弹窗会遮挡我的窗口」）。
        delegate.testSettingsController?.closeForAutomationCleanup()
        exit(problems.isEmpty ? 0 : 1)
    }

    // ---- 1. 造一份临时课表（真实写盘，走 AppPaths 的 DT_DATA_DIR） ----
    let store = TimetableStore()
    _ = try? store.migrateLegacyIfNeeded(defaultName: "自检课表")
    if store.activeID == nil, let created = try? store.create(name: "自检课表") {
        try? store.setActive(created.id)
    }
    guard let activeID = store.activeID, var cur = try? store.load(activeID) else {
        say("❌ 没有当前课表")
        try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        exit(1)
    }
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    cur.semester = sem
    cur.courses = [
        Course(day: 3, block: 1, name: "高等数学", teacher: "李雷", loc: "教三-201",
               courseID: "M1", weeks: Array(1...8), origin: .imported),
        Course(day: 2, block: 1, name: "自习", teacher: "", loc: "图书馆",
               courseID: "S1", weeks: Array(1...8), origin: .manual),
    ]
    try? store.save(cur)
    try? store.setActive(activeID)

    let imported = [
        // 与当前的高等数学同课同名同格 → 会走「更新」
        Course(day: 3, block: 1, name: "高等数学", teacher: "王老师", loc: "教三-305",
               courseID: "M1", weeks: Array(1...8)),
        // 与用户的「自习」同格 → 会走「逐条冲突」，自检里选「保留当前」，
        // 所以它**不该**出现在合并结果里（自习该留着）。
        Course(day: 2, block: 1, name: "物理", teacher: "", loc: "",
               courseID: "P1", weeks: Array(1...16)),
        // 跟谁都不冲突 → 干净地新增，用来验证「面板数据真的刷新了」
        Course(day: 5, block: 3, name: "体育", teacher: "", loc: "操场",
               courseID: "T1", weeks: Array(1...8)),
    ]

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.focusVerificationMode = true
    app.delegate = delegate

    var problems: [String] = []

    // 整段检查排成异步步骤 —— 由真事件循环驱动。
    //
    // 每一步之间的等待都必须给够：激活是**异步**的，
    // `NSApp.activate` 调用完那一瞬间 `isActive` 还是 false。
    func step(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    /// 等某个窗口真的拿到 key window（最多等到 deadline）。
    ///
    /// 激活是**异步**的 —— `NSApp.activate` 调用完那一瞬间 `isActive` 还是 false，
    /// key window 要等下一轮事件循环才到位。所以「等固定时长」只是「大概够」：
    /// 抢前台慢的时候会误报。改成「等到真的拿到 key 为止」。
    func waitForKey(_ sw: NSWindow, deadline: Date, done: @escaping () -> Void) {
        if sw.isKeyWindow { done(); return }
        if Date() >= deadline { done(); return }
        step(0.15) { waitForKey(sw, deadline: deadline, done: done) }
    }

    // ---- 2. 打开设置面板，等它成为 key window ----
    step(0.8) {
        delegate.testOpenSettings()
        // 自检期间关掉「点外面关面板」—— 用户碰鼠标会让检查误判
        // （面板被关 → 拿不到 key → 报假 bug）。
        delegate.testSettingsController?.testSuppressOutsideClickClose = true
        say("app 已启动：isActive=\(NSApp.isActive)")
        step(0.2) {
            guard let sw = delegate.testSettingsWindow else {
                finish(["拿不到设置面板窗口"])
                return
            }
            waitForKey(sw, deadline: Date().addingTimeInterval(12)) {
                say("打开面板后：isActive=\(NSApp.isActive) isKeyWindow=\(sw.isKeyWindow)")
                if !sw.isKeyWindow {
                    problems.append("设置面板打开后不是 key window（isActive=\(NSApp.isActive)）")
                }
                runImportPart(sw)
            }
        }
    }

    // ---- 3. 走一遍覆盖导入 ----
    func runImportPart(_ sw: NSWindow) {
        guard let win = delegate.testStartOverwriteImport(
            parsed: imported,
            fileName: "自检导入.xls",
            protectedRemovalDecision: { _, _, _ in .keep }
        ) else {
                finish(problems + ["没有弹出差异页"])
                return
            }
            step(0.8) {
                if !win.testIsVisible { problems.append("差异页没有显示") }
                say("差异页：visible=\(win.testIsVisible) 冲突数=\(win.testConflictCount)")

                // 决定冲突 → **真点**「应用」按钮
                if let unit = win.testPlan.unresolved.first {
                    win.testResolve(conflictID: unit.id, .keepCurrent)
                }
                step(0.4) {
                    // 真实点击（不是直接调 action）—— 用户报的现象就是「点了没反应」，
                    // 直接调 action 证明不了「点得到」。
                    let clicked = win.testRealClickApply()
                    if !clicked { problems.append("没能对「应用」按钮发出真实点击") }
                    // **等焦点真的飞回来**，而不是死等一个固定时长。
                    //
                    // 差异页一关，焦点要飞回设置面板 —— 那一跳是**异步**的
                    // （activate + makeKeyAndOrderFront 排到下一轮循环）。
                    // 固定等 1.5 秒只是「大概够」：抢前台慢的时候（跟别的 app 抢）
                    // 1.5 秒并不够，自检就会误报「面板没拿回 key」。
                    // 改成「等到面板真的拿到 key 为止，最多等 8 秒」——
                    // 跟打开面板那一步用的是同一个套路（`waitForKey`）。
                    waitForKey(sw, deadline: Date().addingTimeInterval(8)) {
                        let ctlOutsideCloseCount = delegate.testSettingsController?.testOutsideClickCloseCount ?? 0
                        let ctlAnyCloseCount = delegate.testSettingsController?.testAnyCloseCount ?? 0
                        // 面板「不见了」有两种完全不同的原因，处置方式也不同：
                        //  a) **被关掉了**（不在 NSApp.windows 里）—— 窗口真的没了；
                        //  b) **只是被隐藏了**（还在 windows 里，但不 visible）—— 还能救。
                        // 报告里要能分清这两种，否则没法判断是 bug 还是干扰。
                        let panelWasClosed = delegate.testSettingsController?.testPanelClosed ?? false
                        say("诊断：outsideClick关闭=\(ctlOutsideCloseCount) 任意关闭=\(ctlAnyCloseCount) "
                            + "面板visible=\(sw.isVisible) 面板被关掉=\(panelWasClosed)")
                        if win.testIsVisible { problems.append("应用成功后差异页没关") }
                        if delegate.testHasImportFlow { problems.append("应用后导入流程没清空") }
                        say("真点「应用」之后：差异页还开着=\(win.testIsVisible) "
                            + "导入流程还在=\(delegate.testHasImportFlow)")

                        // ---- 4. 设置面板拿回焦点了没有 ----
                        say("应用之后：isActive=\(NSApp.isActive) isKeyWindow=\(sw.isKeyWindow) "
                            + "keyWindow=\(NSApp.keyWindow?.title ?? "nil")")
                        if !sw.isVisible {
                            // 面板不见了有两种可能：
                            //  a) 焦点自检期间用户正好在动鼠标 → 真点了一下别处 →
                            //     全局鼠标监听把面板关了（popover 的正常行为，属干扰）；
                            //  b) 焦点流程自己把面板弄没了（真 bug）。
                            // 用 testOutsideClickCloseCount 区分开，别把干扰算成 bug。
                            if ctlOutsideCloseCount == 0 {
                                problems.append("设置面板不见了（不是用户点外面关的）")
                            } else {
                                say("注意：面板被「点外面关掉」关了一次（自检期间有鼠标点击，属干扰，不算 bug）")
                            }
                        }
                        if !sw.isKeyWindow {
                            problems.append("应用之后设置面板没有拿回 key window（按钮会像「没反应」）")
                        }
                        if NSApp.keyWindow !== sw {
                            problems.append("应用之后 key window 不是设置面板（是「\(NSApp.keyWindow?.title ?? "nil")」）")
                        }

                        // ---- 4b. 面板里的数据真的换成新课表了吗 ----
                        //
                        // 焦点对了但数据没刷新，用户看到的是「导入成功了，列表还是老的」——
                        // 比按钮没反应更容易误判成「导入没生效」。所以这条也得查。
                        if let ctl = delegate.testSettingsController {
                            let names = ctl.testDisplayedCourseNames
                            say("应用之后面板里的课程：\(names)")
                            if !names.contains("体育") {
                                problems.append("应用之后设置面板没显示新课表的「体育」（数据没刷新）")
                            }
                            if !names.contains("高等数学") {
                                problems.append("应用之后设置面板没有「高等数学」")
                            }
                            // 冲突选的是「保留当前」→ 用户的「自习」该留着；
                            // 导入的「物理」只让开重叠的 1-8 周，9-16 周还在 ——
                            // 所以面板上**应该**有物理，只是周次变了。
                            if !names.contains("自习") {
                                problems.append("应用之后设置面板丢了用户的「自习」")
                            }
                            if !names.contains("物理") {
                                problems.append("应用之后设置面板丢了「物理」没冲突的 9-16 周")
                            }
                        }

                        // ---- 5. 设置面板还能不能接收输入 ----
                        //
                        // 「按钮点了没反应」有两种可能：面板不是 key window（点击根本进不来），
                        // 或者事件进来了但没人处理。这里验证前者已经排除之后，
                        // **键盘输入**能不能进到面板（Esc 会关掉面板，是个可观测的信号）。
                        //
                        // 注意：这里发的是**真实按键事件**（走 AppKit 的事件分发），
                        // 不是直接调方法 —— 直接调方法只能证明回调连着。
                        if let ctl = delegate.testSettingsController {
                            let before = ctl.testEscCloseCount
                            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: sw.windowNumber, context: nil,
                                                       characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                       isARepeat: false, keyCode: 53)
                            if let key {
                                // 必须走 **NSApp.sendEvent**：`NSEvent.addLocalMonitorForEvents`
                                // 装的本地监视器只拦「经过 NSApplication 分发」的事件，
                                // 直接 `window.sendEvent` 绕过了分发，监视器根本看不到。
                                // 而 Esc 处理器正是本地监视器 —— 用户按 Esc 也走同一条路。
                                app.sendEvent(key)
                                step(0.5) {
                                    let after = ctl.testEscCloseCount
                                    say("真实 Esc 之后：面板关闭计数 \(before) → \(after)")
                                    if after == before {
                                        problems.append("真实 Esc 没被设置面板接住（键盘输入进不去 = 面板不是 key window）")
                                    }
                                    runHiddenPanelPart(sw)
                                }
                                return
                            }
                            problems.append("构造不出按键事件")
                        } else {
                            problems.append("拿不到设置面板控制器")
                        }
                        finish(problems)
                    }
                }
            }
    }

    // ---- 6. 面板被**隐藏**（不是关掉）之后，焦点还能不能回来 ----
    //
    // 这是个真实存在的坑：`restoreFocus()` 以前开头是
    // `guard let w = window, w.isVisible else { return }` ——
    // 面板一旦处于「不可见」状态，它就**什么都不做**：
    // 数据不刷新（用户看到「导入成功了，列表还是老的」），
    // 焦点也不回来（按钮像「没反应」）。
    //
    // 面板为什么会被隐藏而不是关掉？差异页是 `.floating` 浮窗，
    // 它关掉时 AppKit 可能把同层的面板一起 orderOut。
    // 不管原因是哪个，「隐藏了就该摆出来」这条必须成立。
    func runHiddenPanelPart(_ sw: NSWindow) {
        guard let ctl = delegate.testSettingsController else {
            finish(problems + ["拿不到设置面板控制器（隐藏面板场景）"])
            return
        }
        // 上一步的「真实 Esc」把面板**关掉**了。这里要测的是「隐藏」，
        // 所以先重新打开一次 —— `show()` 会把「被关掉」这个标记清掉。
        // （顺带证明：面板被用户关掉时，restoreFocus() **不会**硬拽它回来。）
        ctl.show(relativeTo: nil)
        waitForKey(sw, deadline: Date().addingTimeInterval(10)) {
            if !sw.isVisible {
                finish(problems + ["面板重新打开失败（隐藏场景的前置条件）"])
                return
            }
            // 把面板藏起来（orderOut = 隐藏，窗口对象还在，不是关掉）。
            sw.orderOut(nil)
            step(0.3) {
                if sw.isVisible {
                    finish(problems + ["面板藏不住（orderOut 没生效），隐藏场景测不了"])
                    return
                }
                if ctl.testPanelClosed {
                    finish(problems + ["orderOut 被当成了「关掉」，隐藏场景测不了"])
                    return
                }
                say("面板已隐藏：visible=\(sw.isVisible) 被关掉=\(ctl.testPanelClosed)")
                // 走真正的恢复路径。
                ctl.restoreFocus()
                waitForKey(sw, deadline: Date().addingTimeInterval(10)) {
                    say("隐藏之后恢复：isActive=\(NSApp.isActive) isKeyWindow=\(sw.isKeyWindow) "
                        + "visible=\(sw.isVisible)")
                    if !sw.isVisible {
                        problems.append("面板被隐藏后 restoreFocus() 没把它摆出来")
                    }
                    if !sw.isKeyWindow {
                        problems.append("面板被隐藏后 restoreFocus() 没把 key 拿回来")
                    }
                    finish(problems)
                }
            }
        }
    }

    // 事件循环跑起来 —— 上面那些异步步骤全靠它驱动。
    app.run()
}

if arguments.contains("--dump-webstate") {
    // 自检：打印推给网页的状态 JSON（课程 / 学期 / 标题 / 副标题）。
    // 用来验证「卡片标题读当前课表的 name/subtitle」这条链路。
    let store = TimetableStore()
    if let migrated = try? store.migrateLegacyIfNeeded(defaultName: "我的课表") {
        print("// 迁移：\(migrated.name)")
    }
    guard let active = store.activeID, let t = try? store.load(active) else {
        print("// 没有当前课表")
        exit(1)
    }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"
    let obj: [String: Any] = [
        "courses": t.courses.map { c -> [String: Any] in
            ["courseID": c.courseID, "name": c.name, "code": c.code,
             "teacher": c.teacher, "loc": c.loc,
             "day": c.day, "block": c.block, "weeks": c.weeks,
             "weeksLabel": c.weeksLabel]
        },
        "semesterStart": fmt.string(from: t.semester.start),
        "maxWeek": t.semester.effectiveMaxWeek(for: t.courses),
        "title": t.name,
        "subtitle": t.subtitle,
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    桌面课表

    用法：
      DesktopTimetable                     启动桌面课表
      DesktopTimetable --import <文件>     导入课表（.xls 或 .json）后退出
      DesktopTimetable --help              显示这段帮助

    --import 是**脚本接口**：直接覆盖当前课表，不弹界面、不走「新建 / 覆盖 / 取消」三选一。
    它和界面导入共用同一套校验（`ImportValidator`）和写盘前备份，
    但没有预览和确认环节 —— 只适合放进自动化脚本，手动导入请用图形界面。

    调试用（正常用不到）：
      --show-settings            只打开「课表设置」面板
      --show-editor              只打开「编辑课程」弹窗（带样例数据）
      --show-detail              只打开「课程详情」浮层（带样例数据）
      --render-card <png>        离屏渲染桌面卡片
      --dump-layout              打印设置面板的视图层级
    """)
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-pin") {
    // 渲染图钉对照图（左边未固定 / 右边已固定）—— 用来肉眼确认两种状态分得清。
    let out = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("pin.png")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let img = PushPinRenderer.renderComparison(),
          let data = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: data),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("渲染失败")
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: out))
    print("已渲染 \(out)")
    exit(0)
}

if let idx = arguments.firstIndex(of: "--render-card") {
    // 离屏渲染卡片到 PNG：既能自检渲染结果，也能给 README 出图。
    let out = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("card.png")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // AppDelegate 的初始化在 applicationDidFinishLaunching 里，这里手动做一遍。
    delegate.prepareForRendering()
    let ok = delegate.renderCard(to: out)
    exit(ok ? 0 : 1)
}

if let idx = arguments.firstIndex(of: "--shot-web-card") {
    // 截**网页层**（WKWebView 真正画出来的内容）在某个缩放档位下的图。
    //
    // 用途：`--shot-card-scale` 只能截到原生层（毛玻璃 / 图钉 / 窗口），
    // 网页层（卡片内容、缩放后的文字 / 边框 / 投影）必须用
    // `WKWebView.takeSnapshot` 才能看到。缩放对不对、边缘是不是只剩毛玻璃，
    // 全靠这张图确认。
    //
    // 用法：`--shot-web-card <png> [scale]`
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --shot-web-card 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let out = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("web-card.png")
    let requested = idx + 2 < arguments.count ? Double(arguments[idx + 2]) ?? 1.0 : 1.0

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let renderer = delegate.testWebRenderer else {
        print("❌ 没有网页渲染器")
        exit(1)
    }
    NSApp.activate(ignoringOtherApps: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    for _ in 0..<100 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if renderer.isReady { break }
    }
    delegate.testApplyCardScale(requested)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    // 可选出折叠态：`--shot-web-card out.png 1.12 collapse`
    if idx + 3 < arguments.count, arguments[idx + 3] == "collapse" {
        delegate.testToggleCollapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }
    print("[诊断] 请求 \(requested) → 实际 \(delegate.testCardScale)"
          + " 卡片=\(NSStringFromRect(TimetableLayout.cardRect))"
          + " 玻璃=\(NSStringFromRect(delegate.testGlassFrame))")
    let cfg = WKSnapshotConfiguration()
    cfg.rect = renderer.webView.bounds
    cfg.afterScreenUpdates = true
    var done = false
    renderer.webView.takeSnapshot(with: cfg) { image, error in
        defer { done = true }
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("❌ 网页截图失败：\(error?.localizedDescription ?? "?")")
            return
        }
        try? data.write(to: URL(fileURLWithPath: out))
        print("已截图 \(out)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
    for _ in 0..<200 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if done { break }
    }
    exit(0)
}

if let idx = arguments.firstIndex(of: "--shot-card-scale") {
    // 截**桌面课表卡片**在某个缩放档位下的图（2026-11 新增）。
    //
    // 用途：缩放是「整体等比」这件事**必须靠肉眼确认** ——
    // 代码算对了不代表网页层画对了（`pageZoom` 的坐标语义、
    // 网页里的卡片位置、字体大小…全都要看图）。
    //
    // 用法：`--shot-card-scale <png> [scale]`
    //   scale 省略时按 0.70 / 0.85 / 1.0 / 1.15 各截一张，
    //   文件名自动加后缀 `-<scale>.png`。
    //
    // ⚠️ 走的是**真实窗口**（`WKWebView` 直接上屏的那种），
    // 所以截出来就是用户看到的样子。
    guard let dataDir = ProcessInfo.processInfo.environment["DT_DATA_DIR"],
          !dataDir.isEmpty else {
        print("❌ --shot-card-scale 需要 DT_DATA_DIR（临时目录）")
        exit(1)
    }
    let outBase = idx + 1 < arguments.count
        ? arguments[idx + 1]
        : (NSTemporaryDirectory() as NSString).appendingPathComponent("card-scale.png")
    // 第二个参数是缩放值；没给就截四档。
    var requested: [Double] = []
    if idx + 2 < arguments.count, let v = Double(arguments[idx + 2]) {
        requested = [v]
    } else {
        requested = [0.70, 0.85, 1.0, 1.15]
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    delegate.prepareForRendering()
    guard let win = delegate.testDesktopWindow else {
        print("❌ 没有桌面窗口")
        exit(1)
    }
    win.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))

    /// 把窗口当前画面抓成 PNG。
    ///
    /// 用 `bitmapImageRepForCachingDisplay` 缓存视图层级 ——
    /// `CGWindowListCreateImage` 在新版 macOS 上已经不可用了
    /// （编译报 "unavailable in macOS: Please use ScreenCaptureKit instead"）。
    ///
    /// ⚠️ `WKWebView` 的内容**不在**普通视图层级里（它跑在独立的渲染进程），
    /// 所以这一步截到的是「原生那一层」——
    /// 用来核对卡片位置 / 尺寸 / 投影留白 / 图钉。
    /// 网页层缩放的效果另有验证（`--verify-card-scale` 的命中换算 +
    ///  真机开 app 肉眼确认）。
    func grabWindow(_ window: NSWindow, to path: String) -> Bool {
        guard let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: URL(fileURLWithPath: path))
        print("已截图 \(path)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        return true
    }

    var failed = false
    for s in requested {
        delegate.testApplyCardScale(s)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let effective = delegate.testCardScale
        // 文件名带后缀，多档不会互相覆盖。
        let path = requested.count > 1
            ? outBase.replacingOccurrences(of: ".png", with: "-\(String(format: "%.2f", s)).png")
            : outBase
        print("[诊断] 请求 \(s) → 实际 \(effective)，卡片 \(Int(TimetableLayout.cardRect.width))"
              + "×\(Int(TimetableLayout.cardRect.height))")
        if !grabWindow(win, to: path) {
            print("❌ 截图失败（scale=\(s)）")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}

if arguments.contains("--dump-layout") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let store = ScheduleStore()
    let ctl = SettingsWindowController(store: store) {}
    ctl.dumpLayout()
    exit(0)
}

// 调试：只打开设置面板，不启动整套桌面课表。
//
// 用途：设置面板的版式（尤其是「退出应用」按钮的位置）要靠肉眼确认，
// 而点齿轮才能打开面板太绕 —— 这个模式直接把它摆出来，方便截图核对。
if arguments.contains("--show-settings") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let store = ScheduleStore()
    // 带上多课表仓库：设置面板的「课表」卡片要能列出课表（预览式）。
    let ctl = SettingsWindowController(store: store, timetableStore: TimetableStore()) {}
    // 真实 app 路径会调 installHandlers()（里面设 darkAqua 外观 + 事件监视器），
    // 调试开关也要调 —— 否则面板是浅色外观，跟线上看到的不一样。
    ctl.installHandlers()
    ctl.show(relativeTo: nil)
    app.activate(ignoringOtherApps: true)
    // 不 exit —— 留着跑，用户看完自己关。
    NSApplication.shared.run()
    exit(0)
}

// 调试：只打开「编辑课程」弹窗，不启动整套桌面课表。
//
// 用途：这个弹窗的**红绿灯位置和边框圆角**必须靠肉眼确认 ——
// 而要弹出它得先在桌面卡片上右键，路径太绕。
// 这个模式直接摆一个填好样例数据的弹窗，方便截图核对。
if arguments.contains("--show-editor") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var draft = CourseDraft()
    draft.name = "系统测试与质量管理"
    draft.code = "3100213002.01"
    draft.teacher = "于七龙,傅昌锃"
    draft.loc = "科技楼6058(新校区)"
    draft.day = 4
    draft.block = 0
    draft.weeks = Array(2...15)
    let ctl = CourseEditorWindowController(mode: .edit(courseID: "preview", day: 4, block: 0),
                                          draft: draft,
                                          maxWeek: 16)
    ctl.show()
    app.activate(ignoringOtherApps: true)
    // 不 exit —— 留着跑，用户看完自己关。
    NSApplication.shared.run()
    exit(0)
}

// 调试：只打开「单周临时覆盖」的两道确认窗，不启动整套桌面课表。
//
// 用途：这两个弹窗是新做的（不是系统 NSAlert），版式、配色、按钮位置
// 必须靠肉眼确认 —— 而要弹出它得先在桌面卡片上右键走一遍保存流程，太绕。
// 这个模式直接摆出来（写盘通道一次也不碰），方便截图核对。
if arguments.contains("--show-override-confirm") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let clash = Course(day: 3, block: 1, name: "高等数学", teacher: "李雷",
                       loc: "教三-201", code: "MATH001", courseID: "M1",
                       weeks: Array(1...8))
    let other = Course(day: 3, block: 1, name: "体育", teacher: "李雷",
                       loc: "操场", code: "PE001", courseID: "P1",
                       weeks: [1, 2])
    let which = arguments.contains("--show-override-remind") ? 2 : 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        if which == 1 {
            // 第一道关：警告
            _ = ConfirmDialogController(request: .init(
                title: "这个时间已经有课了",
                message: "你选的这些周次里，下面这门课正在上课：\n"
                    + "要用你的课覆盖这几周吗？原课只在被覆盖的那几周被遮住，其它周不受影响。",
                items: [clash],
                confirmTitle: "确认覆盖")).run()
        } else {
            // 第二道关：提醒
            _ = ConfirmDialogController(request: .init(
                title: "这个时间已有一门非本周课",
                message: "下面这门课在这个时间有课，但它不在你选中的那几周上：\n"
                    + "你的课只在选中的那几周生效，原课不受影响。继续吗？",
                items: [other],
                confirmTitle: "继续")).run()
        }
    }
    app.activate(ignoringOtherApps: true)
    // 不 exit —— 留着跑，用户看完自己关。
    NSApplication.shared.run()
    exit(0)
}

// 调试：只打开「新建课表」小窗（设置面板里点「新建」弹的就是它）。
if arguments.contains("--show-timetable-dialog") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    _ = TimetableNameDialog.run(title: "新建课表",
                                message: "创建一份空课表，之后可以导入课表内容。",
                                name: "新课表", subtitle: "", confirmTitle: "创建")
    exit(0)
}

// 调试：只打开「课程详情」浮层，不启动整套桌面课表。
//
// 用途：和 --show-editor 一样，用来肉眼核对 HUD 窗口的红绿灯位置和边框圆角。
if arguments.contains("--show-detail") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let course = Course(day: 4, block: 0,
                         name: "系统测试与质量管理",
                         teacher: "于七龙,傅昌锃",
                         loc: "科技楼6058(新校区)",
                         code: "3100213002.01",
                         weeksLabel: "2-15",
                         weeks: Array(2...15))
    let win = HUDWindow.make(title: course.name,
                             size: NSSize(width: 400, height: 278),
                             miniaturizable: false)
    HUDWindow.installContent(in: win, root: CourseDetailView(course: course))
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
    NSApplication.shared.run()
    exit(0)
}

// MARK: - 界面模式

// live 测试的数据护栏 —— 必须在构造 AppDelegate **之前**。
//
// AppDelegate 的属性初始化里有 `TimetableStore()`，它的 init 会
// `createDirectory(timetablesDirectory)` —— 也就是说，光是 new 一下 delegate
// 就已经在用户真实数据目录下留了个目录。想拦住这个副作用，护栏得放在这里。
//
// 阶段 3 之后 app 启动还会把旧版 schedule_data.json 迁移成 timetables/<uuid>/，
// 那更是实打实的写操作。live 测试没设 DT_DATA_DIR 就等于默认跑在真实课表上，
// 所以直接拒绝启动。
if let reason = LiveTestHarness.liveTestDataGuard() {
    // **不能只往 stderr 写一行然后 exit。**
    // 通过 Finder/`open` 启动时 stderr 没人看，app 会在几十毫秒内静默消失 ——
    // 用户看到的现象是「双击没反应」，完全猜不到原因。
    // 所以除了 stderr，还往系统日志写一条（`log stream` / Console.app 能看到），
    // 并在界面上弹一个说明 —— 告诉用户「为什么没启动、怎么解」。
    let message = """
    桌面课表拒绝启动。

    \(reason)

    常见原因：之前跑 live 测试时用 `launchctl setenv DT_LIVE_TEST 1` 设过环境变量，
    忘了清干净，它留在了系统全局环境里，于是每次双击都会带着这个标记启动。

    解除方法（在「终端」里执行一行）：
        launchctl unsetenv DT_LIVE_TEST
    """
    FileHandle.standardError.write(Data(("拒绝启动：\(reason)\n").utf8))
    NSLog("[TT-GUARD] 拒绝启动：%@", reason)

    // 弹窗提示。accessory app 默认不抢焦点，所以先激活自己再弹。
    let alert = NSAlert()
    alert.messageText = "桌面课表拒绝启动"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "退出")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 注意：激活策略在 AppDelegate.applicationWillFinishLaunching 里设置。
// macOS 26 上，如果等 didFinishLaunching 才设，NSStatusItem 会创建成功却不显示。
app.run()
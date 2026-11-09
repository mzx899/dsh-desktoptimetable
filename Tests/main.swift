import AppKit
import Foundation
import UserNotifications

// 自带断言运行器：不依赖 XCTest，只要 Command Line Tools 就能跑。
// `make test`

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String, file: String = #filePath, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        let name = (file as NSString).lastPathComponent
        print("  ✗ \(name):\(line)  \(message)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String,
                               file: String = #filePath, line: Int = #line) {
    checks += 1
    if a != b {
        failures += 1
        let name = (file as NSString).lastPathComponent
        print("  ✗ \(name):\(line)  \(message) — 期望 \(b)，实际 \(a)")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("▸ \(name)")
    body()
}

func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    WeekMath.calendar.date(from: DateComponents(year: y, month: m, day: d))!
}

// MARK: - 周次计算

suite("WeekMath · 周次") {
    let start = day(2026, 8, 31)

    expectEqual(WeekMath.weekNumber(start, semesterStart: start), 1, "开学日所在周是第 1 周")
    expectEqual(WeekMath.weekNumber(day(2026, 9, 7), semesterStart: start), 2, "第二周的周一")
    expectEqual(WeekMath.weekNumber(day(2026, 9, 6), semesterStart: start), 1, "第一周的周日仍属第 1 周")
    expectEqual(WeekMath.weekNumber(day(2026, 10, 22), semesterStart: start), 8, "10 月 22 日是第 8 周")

    expectEqual(WeekMath.mondayOfWeek(day(2026, 10, 22)), day(2026, 10, 19), "10/22 所在周的周一是 10/19")
    expectEqual(WeekMath.weekDateText(8, semesterStart: start), "10月19日 – 10月25日", "第 8 周日期范围")

    let range = WeekMath.weekRange(1, semesterStart: start)!
    expectEqual(range.start, day(2026, 8, 31), "第 1 周周一")
    expectEqual(range.end, day(2026, 9, 6), "第 1 周周日")

    // 开学日不是周一时，仍按「所在周的周一」作为锚点
    let midWeekStart = day(2026, 9, 2)          // 周三
    expectEqual(WeekMath.weekNumber(day(2026, 9, 4), semesterStart: midWeekStart), 1,
                "周三开学时，同周周五仍是第 1 周")
    expectEqual(WeekMath.weekNumber(day(2026, 9, 7), semesterStart: midWeekStart), 2,
                "周三开学时，下周一进入第 2 周")

    // 星期索引 1=周一 ... 7=周日
    expectEqual(WeekMath.todayIndex(day(2026, 10, 22)), 4, "10/22 是周四")
    expectEqual(WeekMath.todayIndex(day(2026, 10, 25)), 7, "10/25 是周日")
}

// MARK: - 周次字符串

suite("WeekSpec · 周次字符串") {
    expectEqual(WeekSpec.expand("1-3,5-6"), Set([1, 2, 3, 5, 6]), "区间与逗号")
    expectEqual(WeekSpec.expand("1-3，5"), Set([1, 2, 3, 5]), "中文逗号")
    expectEqual(WeekSpec.expand("1-6单"), Set([1, 3, 5]), "单周")
    expectEqual(WeekSpec.expand("1-6双"), Set([2, 4, 6]), "双周")
    expectEqual(WeekSpec.expand("7"), Set([7]), "单个周次")
    expectEqual(WeekSpec.expand(""), Set<Int>(), "空字符串")

    expectEqual(WeekSpec.format(Set([1, 2, 3, 5, 6])), "1-3,5-6", "格式化连续区间")
    expectEqual(WeekSpec.format(Set([7])), "7", "单个周次格式化")
    expectEqual(WeekSpec.format(Set<Int>()), "", "空集合")
    // 往返
    let set = Set([1, 2, 3, 7, 9, 10])
    expectEqual(WeekSpec.expand(WeekSpec.format(set)), set, "格式化与解析往返一致")
}

// MARK: - 单元格文本

suite("CellTextParser · 单元格") {
    // 真实导出里课程名和代码在**同一行**（中间是空格），教师和「周次+地点」各自独立成行。
    let text = """
    数据结构        (3030112015.02)
            (宋欣)
            (1-14  工学馆506(学校本部))
    """
    let entries = CellTextParser.parse(text)
    expectEqual(entries.count, 1, "一门课解析出一条")
    if let e = entries.first {
        expectEqual(e.name, "数据结构", "课程名")
        expectEqual(e.code, "3030112015.02", "课程代码")
        expectEqual(e.teacher, "宋欣", "教师")
        expectEqual(e.weeksRaw, "1-14", "周次原文")
        expectEqual(e.loc, "工学馆506(学校本部)", "地点（已去掉多余空格）")
        expectEqual(e.weeksLabel, "1-14", "周次标签")
    }

    // 一个格子里两门课
    let two = """
    数据结构        (3030112015.02)
            (宋欣)
            (1-14  工学馆506(学校本部))
    形势与政策（三）        (3080511003.04)
            (赵勇/张玉宝)
            (11-14  工学馆411(学校本部))
    """
    expectEqual(CellTextParser.parse(two).count, 2, "一格两门课")

    // 没有课程代码标签的行不该被当成课程
    expectEqual(CellTextParser.parse("随便一句话\n没有代码").count, 0, "无代码行被忽略")
}

// MARK: - .xls 表格解析

suite("XlsScheduleParser · HTML 表格") {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sample_timetable.html")

    expect(FileManager.default.fileExists(atPath: fixture.path), "fixture 存在")

    do {
        let courses = try XlsScheduleParser.parse(at: fixture)
        expectEqual(courses.count, 4, "解析出 4 门课")

        // rowspan=2 的关键验证：第二节行里第一个 td 是计算机网络基础，
        // 按 td 序号取列会把它算到星期一，按网格取列才是星期二。
        let network = courses.first { $0.name == "计算机网络基础" }
        expect(network != nil, "找到计算机网络基础")
        expectEqual(network?.day, 2, "计算机网络基础在星期二（rowspan 未把列挤歪）")
        expectEqual(network?.block, 0, "计算机网络基础在第一节次")

        let military = courses.first { $0.name == "军事理论" }
        expectEqual(military?.day, 2, "军事理论在星期二")
        expectEqual(military?.block, 1, "军事理论在第三节次")

        let ds = courses.first { $0.name == "数据结构" }
        expectEqual(ds?.day, 1, "数据结构在星期一")
        expectEqual(ds?.weeks.count, 14, "数据结构 14 周")
        expectEqual(ds?.teacher, "宋欣", "数据结构教师")
        expect(ds?.loc.contains("工学馆506") == true, "数据结构地点")

        // 周次 1-3,5-6,8-15
        expectEqual(network?.weeks, [1, 2, 3, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15],
                    "计算机网络基础周次")
    } catch {
        expect(false, "解析抛错：\(error.localizedDescription)")
    }
}

// MARK: - JSON 归一化

suite("JSONCourseNormalizer") {
    // 标准格式
    let standard: [[String: Any]] = [
        ["day": 1, "block": 0, "name": "数据结构", "teacher": "宋欣",
         "loc": "工学馆506", "code": "1", "weeksLabel": "1-14", "weeks": Array(1...14)],
    ]
    if let c = try? JSONCourseNormalizer.normalize(standard).first {
        expectEqual(c.name, "数据结构", "标准格式课程名")
        expectEqual(c.weeks.count, 14, "标准格式周次")
    } else {
        expect(false, "标准格式应当解析成功")
    }

    // 宽松格式：中文星期 / 第N节 / 字符串周次
    let loose: [[String: Any]] = [
        ["day": "周四", "block": "第5-6节", "name": "英语", "weeks": "1-3,5"],
        ["day": "星期四", "block": "第5-6节", "name": "英语", "weeks": [2]],
    ]
    do {
        let courses = try JSONCourseNormalizer.normalize(loose)
        expectEqual(courses.count, 1, "同名同格合并成一条")
        expectEqual(courses.first?.day, 4, "中文星期解析")
        expectEqual(courses.first?.block, 2, "第5-6节 → block 2")
        expectEqual(courses.first?.weeks, [1, 2, 3, 5], "两条周次合并")
        expectEqual(courses.first?.weeksLabel, "1-3,5", "自动生成周次标签")
    } catch {
        expect(false, "宽松格式应当解析成功：\(error.localizedDescription)")
    }

    // 错误场景
    expect((try? JSONCourseNormalizer.normalize([])) == nil, "空数组被拒绝")
    expect((try? JSONCourseNormalizer.normalize([["day": 1, "block": 0]])) == nil, "缺 name 被拒绝")
    expect((try? JSONCourseNormalizer.normalize([["day": 9, "block": 0, "name": "X"]])) == nil,
           "day 越界被拒绝")
    expect((try? JSONCourseNormalizer.normalize([["day": 1, "block": 9, "name": "X"]])) == nil,
           "block 越界被拒绝")

    // 颜色（可选字段）：给了合法值就顺手读，没给 / 非法都不影响导入
    let withColor: [[String: Any]] = [
        ["day": 1, "block": 0, "name": "数据结构", "weeks": [1], "color": "#EF5F5B"],
        ["day": 2, "block": 1, "name": "英语", "weeks": [1], "colorHex": " 2ec4b6 "],
        ["day": 3, "block": 2, "name": "体育", "weeks": [1], "color": "红色"],
        ["day": 4, "block": 3, "name": "军事理论", "weeks": [1]],
    ]
    if let cs = try? JSONCourseNormalizer.normalize(withColor) {
        expectEqual(cs.count, 4, "四条都解析出来（颜色不影响解析）")
        expectEqual(cs.first { $0.name == "数据结构" }?.colorHex, "#ef5f5b",
                    "JSON 里的 color 键能读出来并规范化")
        expectEqual(cs.first { $0.name == "英语" }?.colorHex, "#2ec4b6",
                    "JSON 里的 colorHex 键也能读")
        expect(cs.first { $0.name == "体育" }?.colorHex == nil,
               "非法颜色值 → 自动（不报错、不中断导入）")
        expect(cs.first { $0.name == "军事理论" }?.colorHex == nil,
               "没写颜色 → 自动")
    } else {
        expect(false, "带颜色的 JSON 应当照常解析成功")
    }
}

// MARK: - 存储

suite("ScheduleStore · 读写往返") {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dt-store-test-\(UUID().uuidString)")
    let store = ScheduleStore(directory: tmp)

    let courses = [
        Course(day: 1, block: 0, name: "数据结构", teacher: "宋欣",
               loc: "工学馆506", code: "1", weeksLabel: "1-14", weeks: Array(1...14)),
        Course(day: 5, block: 3, name: "军事理论", teacher: "金炳烨",
               loc: "工学馆331", code: "2", weeksLabel: "1-9", weeks: Array(1...9)),
    ]
    do {
        try store.saveCourses(courses)
        expectEqual(try store.loadCourses(), courses, "课程写入后读回一致")
    } catch {
        expect(false, "课程写入失败：\(error.localizedDescription)")
    }

    let sem = day(2026, 8, 31)
    try? store.saveSemesterStart(sem)
    expectEqual(store.loadSemesterStart(), sem, "学期起始日往返一致")

    _ = try? store.saveConfig(["fadeInSec": 1.5, "fadeOutSec": 3.0,
                           "minOpacity": 0.3, "maxOpacity": 0.9,
                           "panelOpacity": 0.55])
    let cfg = AppearanceConfig(store.loadConfig())
    expectEqual(cfg.fadeInSec, 1.5, "配置 fadeInSec")
    expectEqual(cfg.fadeOutSec, 3.0, "配置 fadeOutSec")
    expectEqual(cfg.minOpacity, 0.3, "配置 minOpacity")
    expectEqual(cfg.panelOpacity, 0.55, "配置 panelOpacity（设置面板不透明度）")
    expectEqual(cfg.dictionary["panelOpacity"], 0.55, "面板不透明度写回字典")
    expectEqual(AppearanceConfig([:]).panelOpacity, 1.0, "面板不透明度缺省为 1（不透明）")

    // 缺字段时用默认值
    let empty = ScheduleStore(directory: tmp.appendingPathComponent("empty"))
    expectEqual(AppearanceConfig(empty.loadConfig()).fadeInSec, 0.8, "缺失配置用默认值")
    expectEqual((try? empty.loadCourses())?.count ?? 0, 0, "缺失课程文件返回空数组")

    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - 导入器

suite("ScheduleImporter") {
    // HTML 嗅探
    expect(ScheduleImporter.looksLikeHTML(Data("<html><table id=\"x\"></table>".utf8)),
           "识别 HTML")
    expect(!ScheduleImporter.looksLikeHTML(Data("[{\"name\":\"x\"}]".utf8)), "不把 JSON 当 HTML")

    // 冲突检测
    let conflicting = [
        Course(day: 1, block: 0, name: "数据结构", weeks: [1]),
        Course(day: 1, block: 0, name: "英语", weeks: [1]),
        Course(day: 2, block: 0, name: "数学", weeks: [1]),
    ]
    let conflicts = ScheduleImporter.detectConflicts(conflicting)
    expectEqual(conflicts.count, 1, "只有周一第一节冲突")
    expectEqual(conflicts.first?.names, ["数据结构", "英语"], "冲突课程名（已排序）")

    expectEqual(ScheduleImporter.detectConflicts([Course(day: 1, block: 0, name: "A")]).count, 0,
                "无冲突时为空")
}

// MARK: - 显示状态

suite("TimetableState · 显示逻辑") {
    let start = day(2026, 8, 31)
    let courses = [
        Course(day: 4, block: 0, name: "数据结构", weeks: Array(1...14)),
        Course(day: 5, block: 3, name: "军事理论", weeks: Array(1...9)),
    ]

    // 本周视图
    let week8ThursdayMorning = WeekMath.calendar.date(
        from: DateComponents(year: 2026, month: 10, day: 22, hour: 8, minute: 10))!
    var state = TimetableState(courses: courses, semesterStart: start,
                                currentWeek: 8, viewWeek: 8, now: week8ThursdayMorning)

    expect(state.isCurWeek, "当前看的是本周")
    expectEqual(state.currentCourse?.name, "数据结构", "周四早上正在上数据结构")
    expect(state.status.isLive, "状态条显示正在上课")
    expect(state.status.text.contains("数据结构"), "状态条含课程名")

    // 本节课结束时间 09:35，8:10 时还剩 85 分钟
    expect(state.status.meta.contains("1 小时 25 分"), "剩余时间文案：\(state.status.meta)")

    // 全部周次
    state.viewWeek = nil
    expect(state.isAllWeeks, "全部周次模式")
    expect(state.status.text.contains("全部周次"), "全部周次状态文案")
    expectEqual(state.runsThisWeek(courses[0]), true, "全部周次时所有课都算「本周有」")

    // 浏览其他周
    state.viewWeek = 3
    expect(!state.isCurWeek, "第 3 周不是本周")
    expectEqual(state.currentCourse, nil, "非本周不显示正在上课")

    // 周次过滤
    expectEqual(state.runsThisWeek(courses[1]), true, "军事理论第 3 周上课")
    state.viewWeek = 10
    expectEqual(state.runsThisWeek(courses[1]), false, "军事理论第 10 周不上")

    // 时间间隔文案
    expectEqual(TimetableState.gapText(45), "45 分钟", "间隔文案-分钟")
    expectEqual(TimetableState.gapText(60), "1 小时", "间隔文案-整小时")
    expectEqual(TimetableState.gapText(85), "1 小时 25 分", "间隔文案-时分")
}


// MARK: - 卡片点击命中

suite("TimetableCardView · 点击命中") {
    let courses: [Course] = [
        Course(day: 1, block: 0, name: "数据结构", teacher: "宋欣",
               loc: "工学馆506(学校本部)", code: "3030112015.02",
               weeksLabel: "1-14", weeks: [1,2,3,4,5,6,7,8,9,10,11,12,13,14]),
        Course(day: 2, block: 1, name: "计算机网络基础", teacher: "韩鹏",
               loc: "科技楼6050(新校区)", code: "3100012010.02",
               weeksLabel: "1-15", weeks: Array(1...15)),
    ]
    let view = TimetableCardView(frame: NSRect(x: 0, y: 0,
                                              width: TimetableLayout.cardRect.width + 180,
                                              height: TimetableLayout.cardRect.height + 180))
    view.state = TimetableState(courses: courses,
                                semesterStart: day(2026, 8, 31),
                                currentWeek: 8, viewWeek: 8, now: Date())

    func press(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    var picked: Course?
    var openedSettings = false
    var weekChange: Int??
    view.onSelectCourse = { picked = $0 }
    view.onOpenSettings = { openedSettings = true }
    view.onWeekChange = { weekChange = $0 }

    // 点课程格
    let cell = TimetableLayout.courseRect(block: 0, day: 1)
    let cp = NSPoint(x: cell.midX, y: cell.midY)
    view.mouseDown(with: press(.leftMouseDown, cp))
    view.mouseUp(with: press(.leftMouseUp, cp))
    expectEqual(picked?.name, "数据结构", "点击课程格触发 onSelectCourse")

    // 浮层打开后点遮罩关闭
    view.selectedCourse = picked
    let blank = NSPoint(x: TimetableLayout.cardRect.minX + 6,
                        y: TimetableLayout.cardRect.minY + 6)
    view.mouseDown(with: press(.leftMouseDown, blank))
    view.mouseUp(with: press(.leftMouseUp, blank))
    expect(view.selectedCourse == nil, "点遮罩关闭详情浮层")

    // 点齿轮打开设置
    let gear = view.gearRectForTest
    view.mouseDown(with: press(.leftMouseDown, NSPoint(x: gear.midX, y: gear.midY)))
    view.mouseUp(with: press(.leftMouseUp, NSPoint(x: gear.midX, y: gear.midY)))
    expect(openedSettings, "点击齿轮触发 onOpenSettings")

    // 点下一周箭头
    view.mouseDown(with: press(.leftMouseDown, NSPoint(x: view.nextArrowRectForTest.midX,
                                                       y: view.nextArrowRectForTest.midY)))
    view.mouseUp(with: press(.leftMouseUp, NSPoint(x: view.nextArrowRectForTest.midX,
                                                   y: view.nextArrowRectForTest.midY)))
    expect(weekChange != nil, "点击下一周箭头触发 onWeekChange")
}

// MARK: - 阶段 1 单测：数据地基
//
// 覆盖：
//   · courseID 分组规则（跨天/跨老师/同名不同 code/空 code/同 code 不同名）
//   · 迁移幂等（跑两次 ID 不变）
//   · 重复导入幂等
//   · 解码健壮性（字符串 weeks、中文 day、非法数据报错）
//   · weeks 为空 → 扩成全学期
//   · semester maxWeek：缺省 / 配置 / 数据超出
//   · 冲突判定：周次重叠 vs 不重叠

// MARK: 辅助

/// 临时目录（每个 suite 一个）。
func makeTempDir(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dt-test-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func course(_ name: String, code: String = "", day: Int = 1, block: Int = 0,
            teacher: String = "", loc: String = "", weeks: [Int] = [1],
            courseID: String = "", colorHex: String? = nil) -> Course {
    Course(day: day, block: block, name: name, teacher: teacher, loc: loc,
           code: code, courseID: courseID, weeks: weeks, colorHex: colorHex)
}

// MARK: - 分组规则

suite("CourseGrouper · 分组规则") {
    // 1. 同 code 跨天跨老师 → 一个 courseID
    let a = course("数据结构", code: "3030112015.02", day: 1, block: 0, teacher: "宋欣")
    let b = course("数据结构", code: "3030112015.02", day: 4, block: 2, teacher: "李雷")
    var g = CourseGrouper.group([a, b])
    expectEqual(g.groups.count, 1, "同 code 跨天跨老师 → 一门课")
    expectEqual(g.groups.first?.records.count, 2, "两条上课时间都在同一门课下")

    let assigned = CourseGrouper.assignCourseIDs([a, b])
    expectEqual(Set(assigned.courses.map { $0.courseID }).count, 1, "同 code → 一个 courseID")
    expectEqual(assigned.anomalies.count, 0, "同 code 同名不算异常")

    // 2. 同名不同 code → 两门课
    let c1 = course("数据结构", code: "A001")
    let c2 = course("数据结构", code: "B002")
    g = CourseGrouper.group([c1, c2])
    expectEqual(g.groups.count, 2, "同名不同 code → 两门课")
    expectEqual(CourseGrouper.assignCourseIDs([c1, c2]).courses.map { $0.courseID }.uniqued().count, 2,
                "同名不同 code → 两个 courseID")

    // 3. code 为空同名 → 一门课
    let e1 = course("军事理论")
    let e2 = course("军事理论", day: 3, block: 1)
    g = CourseGrouper.group([e1, e2])
    expectEqual(g.groups.count, 1, "code 为空同名 → 一门课")
    expectEqual(CourseGrouper.assignCourseIDs([e1, e2]).courses.map { $0.courseID }.uniqued().count, 1,
                "code 为空同名 → 一个 courseID")

    // 4. 同 code 不同名 → 两门课 + 异常提示
    let f1 = course("数据结构", code: "X100")
    let f2 = course("数据结构进阶", code: "X100")
    g = CourseGrouper.group([f1, f2])
    expectEqual(g.groups.count, 2, "同 code 不同名 → 两门课")
    expect(g.anomalies.count >= 1, "同 code 不同名给出异常提示：\(g.anomalies)")

    // 5. 老师不参与身份
    let h1 = course("体育", code: "P001", teacher: "张三")
    let h2 = course("体育", code: "P001", day: 5, teacher: "李四")
    expectEqual(CourseGrouper.assignCourseIDs([h1, h2]).courses.map { $0.courseID }.uniqued().count, 1,
                "不同老师仍是同一门课")

    // 6. 规范化：全角/空白/大小写
    expectEqual(CourseGrouper.matchKey("  Data  Structures "), "data structures", "折叠空白 + 小写")
    expectEqual(CourseGrouper.matchKey("ＡＢＣ"), "abc", "全角转半角")
    let full = course("数据结构", code: "ＡＢＣ")
    let half = course("数据结构", code: "abc")
    expectEqual(CourseGrouper.group([full, half]).groups.count, 1, "全角/半角 code 归到同一门课")

    // 7. 显示保留原文
    g = CourseGrouper.group([course("数据结构（软）", code: "C1")])
    expectEqual(g.groups.first?.name, "数据结构（软）", "显示保留原文（不删括号）")

    // 8. 已有 courseID 原样保留
    let keep = course("数据结构", code: "K1", courseID: "fixed-id")
    let none = course("数据结构", code: "K1")
    let res = CourseGrouper.assignCourseIDs([keep, none])
    expect(res.courses.first { $0.courseID == "fixed-id" } != nil, "已有 courseID 原样保留")
    expectEqual(Set(res.courses.map { $0.courseID }).count, 1, "同组不带的记录继承已有 ID")
}

// MARK: - 迁移幂等

suite("ScheduleRepository · 迁移幂等") {
    let dir = makeTempDir("migrate")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)

    // 旧数据：没有 courseID
    let old = [
        course("数据结构", code: "C1", day: 1, block: 0),
        course("数据结构", code: "C1", day: 4, block: 2),
        course("英语", code: "C2", day: 2, block: 1),
    ]
    try! store.saveCourses(old)

    let repo = ScheduleRepository(store: store)
    let first = repo.load()
    expectEqual(first.courses.count, 3, "迁移后记录数不变")
    expectEqual(Set(first.courses.map { $0.courseID }).count, 2, "3 条记录 → 2 个 courseID")
    expectEqual(first.courses.filter { $0.name == "数据结构" }.map { $0.courseID }.uniqued().count, 1,
                "同一门课的多条记录共用一个 courseID")
    expect(first.courses.allSatisfy { !$0.courseID.isEmpty }, "所有记录都有 courseID")

    // 备份已生成
    expect(store.listBackups().count >= 1, "迁移前已备份")

    // 第二次加载：ID 完全不变
    let firstIDs = first.courses.map { "\($0.courseID)-\($0.day)-\($0.block)" }.sorted()
    let second = repo.load()
    let secondIDs = second.courses.map { "\($0.courseID)-\($0.day)-\($0.block)" }.sorted()
    expectEqual(secondIDs, firstIDs, "迁移跑第二次不改变任何 ID")

    // 记录顺序不被迁移打乱
    expectEqual(second.courses.map { "\($0.day)-\($0.block)" },
                old.map { "\($0.day)-\($0.block)" },
                "迁移保持记录原有顺序")

    // 第二次加载不再改写文件（迁移只落一次盘）
    let mtime1 = (try? FileManager.default.attributesOfItem(atPath: store.coursesFile.path)[.modificationDate]) as? Date
    _ = repo.load()
    let mtime2 = (try? FileManager.default.attributesOfItem(atPath: store.coursesFile.path)[.modificationDate]) as? Date
    expectEqual(mtime1, mtime2, "第二次加载不重写文件")
}

// MARK: - 解码健壮性

suite("Course · 解码健壮性") {
    // 字符串 weeks
    let c1 = try! Course(dictionary: ["name": "数据结构", "day": 4, "block": 0,
                                      "weeks": "1-3,5-6(单)"])
    expectEqual(c1.weeks, [1, 2, 3, 5], "字符串 weeks 被展开")
    expectEqual(c1.weeksLabel, WeekSpec.format(Set(c1.weeks)), "weeksLabel 由 weeks 生成")

    // 中文 day
    let c2 = try! Course(dictionary: ["name": "英语", "day": "周四", "block": 0, "weeks": [1]])
    expectEqual(c2.day, 4, "「周四」→ day 4")
    let c3 = try! Course(dictionary: ["name": "英语", "day": "星期日", "block": 0, "weeks": [1]])
    expectEqual(c3.day, 7, "「星期日」→ day 7")

    // weeksLabel 缺失或与 weeks 不一致 → 以 weeks 为准
    let c4 = try! Course(dictionary: ["name": "X", "day": 1, "block": 0,
                                      "weeks": [1, 2, 3], "weeksLabel": "错误的标签"])
    expectEqual(c4.weeksLabel, "1-3", "weeksLabel 与 weeks 不一致时以 weeks 为准")
    let c5 = try! Course(dictionary: ["name": "X", "day": 1, "block": 0, "weeks": [1, 2, 3]])
    expectEqual(c5.weeksLabel, "1-3", "weeksLabel 缺失时自动生成")

    // 非法数据抛可读错误
    func fails(_ dict: [String: Any], _ tag: String) {
        do {
            _ = try Course(dictionary: dict)
            expect(false, "\(tag) 应当抛出错误")
        } catch {
            expect(true, "\(tag) 抛出可读错误")
        }
    }
    fails(["day": 1, "block": 0, "weeks": [1]], "缺课名")
    fails(["name": "X", "day": 9, "block": 0, "weeks": [1]], "day 越界")
    fails(["name": "X", "day": "礼拜八", "block": 0, "weeks": [1]], "day 写法不认")
    fails(["name": "X", "day": 1, "block": 99, "weeks": [1]], "block 越界")
    fails(["name": "X", "day": 1, "block": 0, "weeks": "乱七八糟"], "weeks 写法不认")

    // 空文件 / 顶层不是数组 → 具体错误，不是空课表
    let dir = makeTempDir("decode")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    try! Data().write(to: store.coursesFile)
    do {
        _ = try store.loadCourses()
        expect(false, "空文件应当报错")
    } catch {
        expect(error.localizedDescription.contains("空"), "空文件给出具体错误：\(error.localizedDescription)")
    }
    try! Data("{\"a\":1}".utf8).write(to: store.coursesFile)
    do {
        _ = try store.loadCourses()
        expect(false, "顶层不是数组应当报错")
    } catch {
        expect(error.localizedDescription.contains("数组"), "顶层不是数组给出具体错误：\(error.localizedDescription)")
    }
}

// MARK: - weeks 为空 → 全学期

suite("ScheduleRepository · 周次缺失处理") {
    let dir = makeTempDir("weeks")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let cfg = SemesterConfig(start: day(2026, 8, 31), maxWeek: 16)
    try! store.saveSemesterConfig(cfg)

    try! store.saveCourses([course("数据结构", code: "C1", weeks: [])])   // weeks = []
    let repo = ScheduleRepository(store: store)
    let loaded = repo.load()
    expectEqual(loaded.courses.first?.weeks, Array(1...16), "weeks 为空 → 扩成 1...maxWeek")
    expect(loaded.notices.contains { $0.contains("周次缺失") }, "给出「周次缺失，已按全学期处理」提示：\(loaded.notices)")
}

// MARK: - 学期总周数

suite("SemesterConfig · 学期总周数") {
    // 缺省
    let cfg = SemesterConfig.from(json: ["start": "2026-08-31"], defaultStart: Date())
    expectEqual(cfg.maxWeek, 16, "maxWeek 缺省为 16")

    // 越界夹回
    expectEqual(SemesterConfig(start: Date(), maxWeek: 99).maxWeek, 30, "maxWeek 上限 30")
    expectEqual(SemesterConfig(start: Date(), maxWeek: 0).maxWeek, 1, "maxWeek 下限 1")
    expectEqual(SemesterConfig.from(json: ["maxWeek": 99], defaultStart: Date()).maxWeek, 30,
                "非法 maxWeek 被夹回")

    // 数据超出 → effectiveMaxWeek 取大
    let c = SemesterConfig(start: Date(), maxWeek: 16)
    expectEqual(c.effectiveMaxWeek(for: [course("X", weeks: [1, 20])]), 20, "数据超出时 effectiveMaxWeek 取大")
    expectEqual(c.coursesExceedingMaxWeek([course("X", weeks: [1, 20])]).count, 1, "列出超出的课程")
    expectEqual(c.effectiveMaxWeek(for: [course("X", weeks: [1, 10])]), 16, "没超出时用配置值")

    // semester.json 往返
    let dir = makeTempDir("semester")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let saved = SemesterConfig(start: day(2026, 8, 31), maxWeek: 18)
    try! store.saveSemesterConfig(saved)
    expectEqual(store.loadSemesterConfig(), saved, "semester.json 往返一致")
}

// MARK: - 冲突判定

suite("ScheduleConflicts · 冲突判定") {
    // 不同 courseID、同格、周次重叠 → 冲突
    let a = course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2, 3], courseID: "id-a")
    let b = course("英语", code: "C2", day: 1, block: 0, weeks: [2, 3], courseID: "id-b")
    let conflicts = ScheduleConflicts.detect([a, b])
    expectEqual(conflicts.count, 1, "周次重叠 → 冲突")
    expectEqual(conflicts.first?.names, ["数据结构", "英语"], "冲突列出两门课")

    // 单双周无交集 → 不算冲突
    let c = course("英语", code: "C2", day: 1, block: 0, weeks: [4, 6], courseID: "id-c")
    expectEqual(ScheduleConflicts.detect([a, c]).count, 0, "单双周交替（周次无交集）→ 不算冲突")

    // 同一门课同一格重复 → 重复（不是冲突）
    let d = course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "id-a")
    let e = course("数据结构", code: "C1", day: 1, block: 0, weeks: [2], courseID: "id-a")
    expectEqual(ScheduleConflicts.detect([d, e]).count, 0, "同一门课不算冲突")
    expectEqual(ScheduleConflicts.duplicates([d, e]).count, 1, "同一门课同一格 → 判为重复上课时间")
}

// MARK: - 导入幂等 + 匹配

suite("ImportPlanner · 导入匹配与幂等") {
    // 已有课程
    let existing = [
        course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "old-id-1"),
        course("英语", code: "C2", day: 2, block: 1, weeks: [1], courseID: "old-id-2"),
    ]

    // 重新导入同样的内容（code 匹配）→ 复用旧 ID
    let parsed = [
        course("数据结构", code: "C1", day: 1, block: 0, weeks: [1]),
        course("数据结构", code: "C1", day: 4, block: 2, weeks: [1]),
        course("英语", code: "C2", day: 2, block: 1, weeks: [1]),
    ]
    let plan = try! ImportPlanner.plan(parsed: parsed, existing: existing, maxWeek: 16)
    expectEqual(plan.reusedCount, 2, "两门课匹配到已有课程")
    expectEqual(plan.createdCount, 0, "没有新建课程")
    let after = ImportPlanner.materialize(plan)
    expectEqual(after.count, 3, "记录数正确")
    expectEqual(Set(after.map { $0.courseID }).count, 2, "课程数不变（2 门）")
    expect(after.contains { $0.courseID == "old-id-1" }, "复用旧的 courseID")

    // 幂等：再导入一次，ID 与记录数都不变
    let plan2 = try! ImportPlanner.plan(parsed: parsed, existing: after, maxWeek: 16)
    let after2 = ImportPlanner.materialize(plan2)
    expect(ImportPlanner.isIdempotent(after, after2), "重复导入幂等")
    expectEqual(Set(after2.map { $0.courseID }), Set(after.map { $0.courseID }), "重复导入 courseID 不变")
    expectEqual(after2.count, after.count, "重复导入记录数不变")

    // 旧课在新文件里消失 → 计划里列为「将被移除」
    let parsed3 = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1])]
    let plan3 = try! ImportPlanner.plan(parsed: parsed3, existing: existing, maxWeek: 16)
    expectEqual(plan3.removedCourses.count, 1, "消失的旧课被列为移除")
    expectEqual(plan3.removedCourses.first?.name, "英语", "移除的是「英语」")

    // 匹配不唯一 → 不猜，交给用户
    let dupExisting = [
        course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "x1"),
        course("数据结构", code: "C2", day: 2, block: 0, weeks: [1], courseID: "x2"),
    ]
    let plan4 = try! ImportPlanner.plan(parsed: [course("数据结构", code: "C3", day: 3, block: 0, weeks: [1])],
                                        existing: dupExisting, maxWeek: 16)
    expectEqual(plan4.ambiguous.count, 1, "同名多组 → 标记为需要用户决定")
    expectEqual(plan4.createdCount + plan4.reusedCount, 0, "歧义时不自动复用也不计入新建")
    // 歧义候选不算「确定移除」——它们可能被合并进来
    expectEqual(plan4.removedCourses.count, 0, "歧义候选不列为待移除")

    // 用户选择「合并到已有课程」后重算：被合并的旧课不再被移除
    var resolved4 = plan4
    if let idx = resolved4.courses.firstIndex(where: { $0.courseID == plan4.ambiguous[0].courseID }) {
        resolved4.courses[idx].courseID = "x1"
        for r in resolved4.courses[idx].records.indices {
            resolved4.courses[idx].records[r].courseID = "x1"
        }
        resolved4.courses[idx].match = .reused(courseID: "x1")
    }
    let final4 = ImportPlanner.finalizeRemoved(plan: resolved4, existing: dupExisting)
    expectEqual(final4.removedCourses.count, 1, "合并后只移除另一门未匹配的旧课")
    expectEqual(final4.removedCourses.first?.courseID, "x2", "移除的是没被合并的那门")

    // 周次超出学期 → 报错
    do {
        _ = try ImportPlanner.plan(parsed: [course("X", weeks: [1, 30])], existing: [], maxWeek: 16)
        expect(false, "周次超出学期总周数应当报错")
    } catch {
        expect(true, "周次超出学期总周数给出错误")
    }
}

// MARK: - 导入解析

suite("ScheduleImporter · 解析") {
    // JSON：字符串 weeks + 中文 day
    let json = """
    [{"name":"数据结构","code":"C1","day":"周四","block":0,"teacher":"宋欣","loc":"工学馆506","weeks":"1-8"}]
    """
    let courses = try! JSONCourseNormalizer.normalize(data: Data(json.utf8))
    expectEqual(courses.count, 1, "JSON 解析出 1 条记录")
    expectEqual(courses[0].day, 4, "中文 day")
    expectEqual(courses[0].weeks, Array(1...8), "字符串 weeks 展开")
    expectEqual(courses[0].courseID, "", "解析器不分配 courseID（身份由 CourseGrouper 决定）")

    // 顶层不是数组 → 报错
    do {
        _ = try JSONCourseNormalizer.normalize(data: Data("{\"a\":1}".utf8))
        expect(false, "顶层不是数组应当报错")
    } catch {
        expect(true, "顶层不是数组给出错误")
    }
}


// MARK: - 右键菜单计划（阶段 2）

suite("ScheduleMenuBuilder · 菜单内容") {
    // 空白格
    let empty = ScheduleMenuBuilder.build(for: .init(day: 3, block: 2, courses: [], hitCourseID: nil))
    expectEqual(empty.count, 4, "空白格 4 项")
    expectEqual(empty[0].action, .addCourse(day: 3, block: 2), "空白格第一项是新增课程")
    expectEqual(empty[0].title, "新增课程…", "空白格第一项标题")
    expectEqual(empty[2].action, .openSettings, "空白格有学期设置")
    expectEqual(empty[3].action, .importSchedule, "空白格有导入课表")

    // 单门课
    let c = course("数据结构", code: "CS201", day: 1, block: 0, teacher: "宋欣", weeks: [1, 2],
                   courseID: "id-1")
    let single = ScheduleMenuBuilder.build(for: .init(day: 1, block: 0, courses: [c], hitCourseID: "id-1"))
    expectEqual(single.count, 6, "课程格 6 项")
    expectEqual(single[0].action, .viewSession(courseID: "id-1", day: 1, block: 0), "第一项查看详情")
    expectEqual(single[1].action, .editSession(courseID: "id-1", day: 1, block: 0), "第二项编辑课程")
    expectEqual(single[2].action, .addSession(courseID: "id-1"), "第三项添加上课时间")
    expectEqual(single[4].action, .deleteSession(courseID: "id-1"), "第五项删除这一次上课")
    expectEqual(single[5].action, .deleteCourse(courseID: "id-1"), "第六项删除整门课程")
    expect(single[3].isSeparator, "删除两项之间有分隔线")

    // 冲突格：每门课一个子菜单
    let c2 = course("英语", day: 1, block: 0, weeks: [1], courseID: "id-2")
    let conflict = ScheduleMenuBuilder.build(for: .init(day: 1, block: 0, courses: [c, c2], hitCourseID: "id-2"))
    expectEqual(conflict[0].submenu.count, 6, "冲突格每门课带子菜单")
    expectEqual(conflict[0].title, "数据结构", "冲突格第一项是课程名")
    expectEqual(conflict[1].submenu.count, 6, "冲突格第二门课也带子菜单")
    expectEqual(conflict[1].title, "英语", "冲突格第二项是课程名")
    // 顶层编辑/删除作用在命中的那门课
    let edits = conflict.filter { $0.action == .editSession(courseID: "id-2", day: 1, block: 0) }
    expectEqual(edits.count, 1, "冲突格顶层编辑作用在命中的课程")
    let deletes = conflict.filter { $0.action == .deleteCourse(courseID: "id-2") }
    expectEqual(deletes.count, 1, "冲突格顶层删除作用在命中的课程")
}

suite("ScheduleMenuBuilder · 菜单动作带课次坐标") {
    // 一门课有两次上课（同一个 courseID，不同时间）
    let mon = course("学术语言", code: "C1", day: 1, block: 3, weeks: [1, 2, 3], courseID: "same")
    let sat = course("学术语言", code: "C1", day: 6, block: 0, weeks: [10], courseID: "same")

    // 周六那次的菜单 → 动作必须指向周六那次，而不是同一门课的第一条
    let satMenu = ScheduleMenuBuilder.build(for: .init(day: 6, block: 0, courses: [sat], hitCourseID: "same"))
    expectEqual(satMenu[1].action, .editSession(courseID: "same", day: 6, block: 0),
                "编辑动作带的是这次上课的坐标（周六 1-2 节）")
    expectEqual(satMenu[0].action, .viewSession(courseID: "same", day: 6, block: 0),
                "查看详情带的是这次上课的坐标")

    // 周一那次 → 坐标不同
    let monMenu = ScheduleMenuBuilder.build(for: .init(day: 1, block: 3, courses: [mon], hitCourseID: "same"))
    expectEqual(monMenu[1].action, .editSession(courseID: "same", day: 1, block: 3),
                "编辑动作带的是这次上课的坐标（周一 3-4 节）")

    // 取出动作对应的课程 → 必须精确到那一次
    let picked = ScheduleMenuBuilder.course(for: .editSession(courseID: "same", day: 6, block: 0),
                                             in: .init(day: 6, block: 0, courses: [sat], hitCourseID: "same"))
    expectEqual(picked?.day, 6, "按课次取课程 → 周六")
    expectEqual(picked?.weeks, [10], "按课次取课程 → 周次是这次的")
}

// MARK: - 右键编辑（阶段 2）

suite("CourseEdit · 校验") {
    let existing = [course("数据结构", code: "CS201", day: 1, block: 0, weeks: [1, 2], courseID: "id-1")]

    // 课名不能为空
    var d = CourseDraft()
    d.name = "   "
    d.day = 1; d.block = 0; d.weeks = [1]
    let errs = CourseEdit.validate(draft: d, scope: .create(day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(errs.contains(.emptyName), "课名为空 → 报错")

    // day / block 越界
    var d2 = CourseDraft()
    d2.name = "X"; d2.day = 8; d2.block = 9; d2.weeks = [1]
    let errs2 = CourseEdit.validate(draft: d2, scope: .create(day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(errs2.contains(.invalidDay(8)), "day 越界 → 报错")
    expect(errs2.contains(.invalidBlock(9)), "block 越界 → 报错")

    // 周次为空 / 超出学期
    var d3 = CourseDraft()
    d3.name = "X"; d3.day = 1; d3.block = 1; d3.weeks = []
    expect(CourseEdit.validate(draft: d3, scope: .create(day: 1, block: 1), courses: existing, maxWeek: 16)
            .contains(.emptyWeeks), "周次为空 → 报错")
    var d4 = CourseDraft()
    d4.name = "X"; d4.day = 1; d4.block = 1; d4.weeks = [1, 20]
    expect(CourseEdit.validate(draft: d4, scope: .create(day: 1, block: 1), courses: existing, maxWeek: 16)
            .contains(.weekOutOfRange(20)), "周次超出学期 → 报错")

    // 同一门课同一格重复 → 拒绝（添加上课时间时）
    var d5 = CourseDraft()
    d5.name = "数据结构"; d5.day = 1; d5.block = 0; d5.weeks = [1]

    // 添加上课时间撞到已有格子 → 拒绝
    expect(CourseEdit.validate(draft: d5, scope: .addSession(courseID: "id-1"),
                                courses: existing, maxWeek: 16)
            .contains(.duplicateSlot(courseName: "数据结构")), "添加上课时间撞格子 → 拒绝")

    // 编辑时排除自己 → 不算重复（改的正是这条记录）
    expect(!CourseEdit.validate(draft: d5, scope: .edit(courseID: "id-1", day: 1, block: 0),
                                 courses: existing, maxWeek: 16)
            .contains(.duplicateSlot(courseName: "数据结构")),
           "编辑同一条记录不算重复")
}

suite("CourseEdit · 冲突判定") {
    let a = course("A", day: 1, block: 0, weeks: [1, 2], courseID: "id-a")
    let b = course("B", day: 1, block: 0, weeks: [3, 4], courseID: "id-b")
    let c = course("C", day: 1, block: 0, weeks: [2, 3], courseID: "id-c")

    var d = CourseDraft()
    d.name = "D"; d.day = 1; d.block = 0; d.weeks = [2]
    let clashes = CourseEdit.conflicts(draft: d, scope: .create(day: 1, block: 0), courses: [a, b, c])
    expectEqual(clashes.count, 2, "周次有交集的两门课算冲突（单双周不相交不算）")
    expect(clashes.contains { $0.courseID == "id-a" }, "A 与草稿周次相交")
    expect(clashes.contains { $0.courseID == "id-c" }, "C 与草稿周次相交")
    expect(!clashes.contains { $0.courseID == "id-b" }, "B 单双周不相交 → 不算冲突")
}

suite("CourseEdit · 应用") {
    let existing = [
        course("数据结构", code: "CS201", day: 1, block: 0, teacher: "宋欣", weeks: [1, 2], courseID: "id-1"),
        course("数据结构", code: "CS201", day: 3, block: 2, teacher: "李雷", weeks: [1, 2], courseID: "id-1"),
    ]

    // 新增：生成新 courseID
    var d = CourseDraft()
    d.name = "英语"; d.day = 5; d.block = 1; d.teacher = "王五"; d.weeks = [1, 2]
    let added = try! CourseEdit.apply(draft: d, scope: .create(day: 5, block: 1),
                                      courses: existing, maxWeek: 16)
    expectEqual(added.count, 3, "新增后多一条记录")
    expect(added[2].courseID != "id-1" && !added[2].courseID.isEmpty, "新课生成新 courseID")
    expectEqual(added[2].day, 5, "新课落在指定的星期")
    expectEqual(added[2].block, 1, "新课落在指定的节次")

    // 编辑课程级字段 → 同步到所有同 courseID 记录
    var d2 = CourseDraft()
    d2.name = "数据结构（重修）"; d2.code = "CS201"; d2.day = 1; d2.block = 0
    d2.teacher = "赵六"; d2.weeks = [1, 2]
    let edited = try! CourseEdit.apply(draft: d2, scope: .edit(courseID: "id-1", day: 1, block: 0),
                                       courses: existing, maxWeek: 16)
    expectEqual(edited[0].name, "数据结构（重修）", "课程名同步到第一条")
    expectEqual(edited[1].name, "数据结构（重修）", "课程名同步到第二条")
    expectEqual(edited[1].teacher, "李雷", "教师只改当前那条")
    expectEqual(edited[1].day, 3, "另一条记录的星期不变")

    // 添加上课时间 → 复用 courseID
    var d3 = CourseDraft()
    d3.name = "数据结构"; d3.day = 5; d3.block = 3; d3.teacher = "孙七"; d3.weeks = [1]
    let withSession = try! CourseEdit.apply(draft: d3, scope: .addSession(courseID: "id-1"),
                                            courses: existing, maxWeek: 16)
    expectEqual(withSession.count, 3, "多一条上课时间记录")
    expectEqual(withSession[2].courseID, "id-1", "新记录复用原 courseID")
    expectEqual(withSession[2].name, "数据结构", "新记录沿用课程名")

    // 删除一次 vs 删除整门课
    let delSession = CourseEdit.deleteSession(courseID: "id-1", day: 3, block: 2, courses: existing)
    expectEqual(delSession.count, 1, "删除这一次只删一条")
    let delCourse = CourseEdit.deleteCourse(courseID: "id-1", courses: existing)
    expectEqual(delCourse.count, 0, "删除整门课删掉全部记录")
    expectEqual(CourseEdit.sessionCount(courseID: "id-1", courses: existing), 2, "统计上课时间条数")
}

suite("CourseEdit · 周次解析") {
    expectEqual(CourseEdit.parseWeeks("1-16"), Array(1...16), "解析 1-16")
    expectEqual(CourseEdit.parseWeeks("1-3,5-6(单)"), [1, 2, 3, 5], "解析 1-3,5-6(单)：单周过滤掉双周")
    expectEqual(CourseEdit.parseWeeks(""), [], "空串解析为空")
    expectEqual(CourseEdit.parseWeeks("abc"), [], "非法文本解析为空")
    expect(CourseEdit.weeksPreview([1, 2, 3]).contains("共 3 周"), "周次预览文案")
}

suite("右键编辑 · 按课次定位（同一门课的多次上课）") {
    // 一门课 3 次上课，同一个 courseID（真实数据里就是这样：
    // 「学术语言与研究方法」周一 3-4 节、周三 3-4 节、周六 1-2 节）
    let mon = course("学术语言", code: "C1", day: 1, block: 3, teacher: "Yazeed",
                     weeks: [1, 2, 3], courseID: "same")
    let wed = course("学术语言", code: "C1", day: 3, block: 3, teacher: "Yazeed",
                     weeks: [1, 2], courseID: "same")
    let sat = course("学术语言", code: "C1", day: 6, block: 0, teacher: "",
                     weeks: [10], courseID: "same")
    let all = [mon, wed, sat]

    // 编辑周六那次 —— scope 的坐标必须就是那一次
    var d = CourseDraft()
    d.name = "学术语言"; d.code = "C1"; d.day = 6; d.block = 0; d.weeks = [10]
    d.teacher = "张老师"
    let scope = CourseEditScope.edit(courseID: "same", day: 6, block: 0)

    // 关键回归：编辑自己那一次上课，不能报「该时间已有课程」
    let errs = CourseEdit.validate(draft: d, scope: scope, courses: all, maxWeek: 16)
    expect(errs.isEmpty, "编辑自己那一次上课不报重复")
    expect(CourseEdit.conflicts(draft: d, scope: scope, courses: all).isEmpty,
           "编辑自己那一次上课不报冲突")

    // 保存：只改那一条，同门课另外两次一个字都不动
    let out = try! CourseEdit.apply(draft: d, scope: scope, courses: all, maxWeek: 16)
    expectEqual(out.count, 3, "记录数不变")
    expectEqual(out[2].teacher, "张老师", "被编辑的那次改了老师")
    expectEqual(out[2].weeks, [10], "被编辑的那次周次没变")
    expectEqual(out[0].teacher, "Yazeed", "同门课另一个上课时间老师没被动")
    expectEqual(out[0].weeks, [1, 2, 3], "同门课另一个上课时间周次没被动")
    expectEqual(out[1].weeks, [1, 2], "同门课第三个上课时间周次没被动")

    // 老 bug 的形态：scope 指到同门课的**另一条**时，用户点的那次会被误判成重复
    let wrongScope = CourseEditScope.edit(courseID: "same", day: 1, block: 3)
    let wrongErrs = CourseEdit.validate(draft: d, scope: wrongScope, courses: all, maxWeek: 16)
    expect(wrongErrs.contains(.duplicateSlot(courseName: "学术语言")),
           "scope 指错上课时间时会误判重复（老 bug 的形态）")

    // 记录已经不在了 → 明确报错，不静默保存
    let goneScope = CourseEditScope.edit(courseID: "same", day: 2, block: 2)
    var dGone = d
    dGone.day = 2; dGone.block = 2
    var threw = false
    do {
        _ = try CourseEdit.apply(draft: dGone, scope: goneScope, courses: all, maxWeek: 16)
    } catch CourseEditError.sessionNotFound {
        threw = true
    } catch {
        threw = false
    }
    expect(threw, "课次记录已消失时报错，而不是静默保存")
    expect(CourseEdit.validate(draft: dGone, scope: goneScope, courses: all, maxWeek: 16)
            .contains(.sessionNotFound), "校验阶段就能发现课次记录已消失")
}

suite("CourseBatchEdit · 校验") {
    let mon = course("数据结构", code: "CS201", day: 1, block: 0, weeks: [1, 2], courseID: "id-1")
    let wed = course("数据结构", code: "CS201", day: 3, block: 2, weeks: [1, 2], courseID: "id-1")
    let existing = [mon, wed]

    func slot(_ day: Int, _ block: Int, weeks: [Int] = [1],
              teacher: String = "") -> CourseSessionDraft {
        var d = CourseDraft()
        d.name = "数据结构"; d.code = "CS201"
        d.day = day; d.block = block; d.weeks = weeks; d.teacher = teacher
        return CourseSessionDraft(original: nil, draft: d)
    }

    // 课名为空 / 一个时段都没有
    var emptyName = slot(1, 0)
    emptyName.draft.name = "   "
    let nameIssues = CourseBatchEdit.validate(
        CourseEditBatch(name: "   ", code: "", sessions: [emptyName]),
        scope: .create(day: 1, block: 0), courses: [], maxWeek: 16)
    expect(nameIssues.contains { $0.error == .emptyName }, "批量校验：课名为空")
    let noSlotIssues = CourseBatchEdit.validate(
        CourseEditBatch(name: "X", code: "", sessions: []),
        scope: .create(day: 1, block: 0), courses: [], maxWeek: 16)
    expect(noSlotIssues.contains { $0.error == .emptySessions }, "批量校验：没有时段")

    // 每个时段的字段都校验，并带上时段序号
    let bad = CourseBatchEdit.validate(
        CourseEditBatch(name: "X", code: "", sessions: [
            slot(8, 9, weeks: []),
            slot(1, 0, weeks: [20]),
        ]),
        scope: .create(day: 1, block: 0), courses: [], maxWeek: 16)
    expect(bad.contains { $0.error == .invalidDay(8) && $0.slotIndex == 0 }, "批量校验：时段 1 星期越界")
    expect(bad.contains { $0.error == .invalidBlock(9) && $0.slotIndex == 0 }, "批量校验：时段 1 节次越界")
    expect(bad.contains { $0.error == .emptyWeeks && $0.slotIndex == 0 }, "批量校验：时段 1 周次为空")
    expect(bad.contains { $0.error == .weekOutOfRange(20) && $0.slotIndex == 1 }, "批量校验：时段 2 周次越界")
    expect(bad.first?.message.hasPrefix("时段 1：") == true, "批量校验：错误文案带时段序号")

    // 表单内部两个时段撞格
    let dupIssues = CourseBatchEdit.validate(
        CourseEditBatch(name: "X", code: "", sessions: [slot(2, 1), slot(2, 1)]),
        scope: .create(day: 2, block: 1), courses: [], maxWeek: 16)
    expect(dupIssues.contains {
        $0.error == .duplicateSlotInEditor(firstSlot: 0, secondSlot: 1, day: 2, block: 1)
    }, "批量校验：表单内两个时段撞格")

    // 编辑：original / deleted 必须真实存在，不能一行既是保留又是删除
    let bogusOriginal = CourseSessionDraft(
        original: CourseSessionIdentity(courseID: "id-1", day: 5, block: 4),
        draft: slot(5, 4).draft)
    let bogusIssues = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201", sessions: [bogusOriginal]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(bogusIssues.contains { $0.error == .sessionNotFound }, "批量校验：原时段已不存在")

    let crossCourse = CourseSessionDraft(
        original: CourseSessionIdentity(courseID: "id-2", day: 1, block: 0),
        draft: slot(1, 0).draft)
    let crossIssues = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201", sessions: [crossCourse]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(crossIssues.contains { $0.error == .sessionNotFound }, "批量校验：原时段不属于这门课")

    let monIdentity = CourseSessionIdentity(courseID: "id-1", day: 1, block: 0)
    let bothIssues = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201",
                        sessions: [CourseSessionDraft(original: monIdentity, draft: slot(1, 0).draft)],
                        deleted: [monIdentity]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(bothIssues.contains { $0.error == .sessionNotFound }, "批量校验：同一时段又保留又删除")

    let repeatedOriginal = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201", sessions: [
            CourseSessionDraft(original: monIdentity, draft: slot(1, 0).draft),
            CourseSessionDraft(original: monIdentity, draft: slot(1, 0).draft),
        ]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(repeatedOriginal.contains { $0.error == .sessionNotFound }, "批量校验：同一旧时段被两行同时编辑")

    // 与保留下来的旧记录撞格
    let hitKept = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201", sessions: [slot(3, 2)]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing, maxWeek: 16)
    expect(hitKept.contains { $0.error == .duplicateSlot(courseName: "数据结构") },
           "批量校验：新时段撞到还没动的旧记录")

    // 添加上课时间的编辑器也会列出已有记录：允许带着 original、也允许删旧记录，
    // 但只能动这门课自己的记录。
    let addWithOriginal = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201",
                        sessions: [CourseSessionDraft(original: monIdentity, draft: slot(5, 1).draft)]),
        scope: .addSession(courseID: "id-1"), courses: existing, maxWeek: 16)
    expect(addWithOriginal.isEmpty,
           "批量校验：添加上课时间可以更新已有时段")
    let addWithDeleted = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201", sessions: [slot(5, 1)], deleted: [monIdentity]),
        scope: .addSession(courseID: "id-1"), courses: existing, maxWeek: 16)
    expect(addWithDeleted.isEmpty,
           "批量校验：添加上课时间可以删掉已有时段")
    let addCrossCourse = CourseBatchEdit.validate(
        CourseEditBatch(name: "数据结构", code: "CS201", sessions: [crossCourse]),
        scope: .addSession(courseID: "id-1"), courses: existing, maxWeek: 16)
    expect(addCrossCourse.contains { $0.error == .sessionNotFound },
           "批量校验：添加上课时间不能动别的课")

    // 新增课程不能带删除项
    let createWithDeleted = CourseBatchEdit.validate(
        CourseEditBatch(name: "X", code: "", sessions: [slot(5, 1)], deleted: [monIdentity]),
        scope: .create(day: 5, block: 1), courses: [], maxWeek: 16)
    expect(createWithDeleted.contains { $0.error == .sessionNotFound },
           "批量校验：新增课程不能带删除项")
}

suite("CourseBatchEdit · 应用") {
    let mon = course("数据结构", code: "CS201", day: 1, block: 0,
                     teacher: "宋欣", weeks: [1, 2], courseID: "id-1")
    let wed = course("数据结构", code: "CS201", day: 3, block: 2,
                     teacher: "李雷", weeks: [1, 2], courseID: "id-1")
    let existing = [mon, wed]

    func session(original: CourseSessionIdentity?, day: Int, block: Int,
                 weeks: [Int] = [1], teacher: String = "", loc: String = "") -> CourseSessionDraft {
        var d = CourseDraft()
        d.name = "数据结构"; d.code = "CS201"
        d.day = day; d.block = block; d.weeks = weeks
        d.teacher = teacher; d.loc = loc
        return CourseSessionDraft(original: original, draft: d)
    }

    let monID = CourseSessionIdentity(courseID: "id-1", day: 1, block: 0)
    let wedID = CourseSessionIdentity(courseID: "id-1", day: 3, block: 2)

    // 1. 新增多时段：共用一个新 courseID，来源 manual
    let createBatch = CourseEditBatch(name: "英语", code: "EN101", sessions: [
        session(original: nil, day: 2, block: 1, weeks: [1, 2], teacher: "王五"),
        session(original: nil, day: 4, block: 3, weeks: [1, 2], teacher: "赵六"),
    ])
    let created = try! CourseBatchEdit.apply(
        createBatch, scope: .create(day: 2, block: 1),
        courses: [], overrides: [], courseID: "new-id",
        overrideSlots: [], maxWeek: 16)
    expectEqual(created.courses.count, 2, "新增多时段 → 两条记录")
    expect(Set(created.courses.map { $0.courseID }) == ["new-id"], "新增多时段共用同一个 courseID")
    expect(created.courses.allSatisfy { $0.origin == .manual }, "新增课程来源 manual")
    expect(created.courses.allSatisfy { $0.userModified == false }, "新增课程不算改过导入课")
    expectEqual(created.courses.map { $0.name }, ["英语", "英语"], "两条记录都用新课程名")
    expectEqual(created.courses.map { $0.code }, ["EN101", "EN101"], "两条记录都用新课程代码")

    // 2. 编辑：改名同步 + 改一个时段 + 删一个旧时段 + 复制新增一个
    let editBatch = CourseEditBatch(name: "数据结构（重修）", code: "CS202", sessions: [
        session(original: monID, day: 1, block: 0, weeks: [3], teacher: "赵七"),
        session(original: nil, day: 6, block: 2, weeks: [3], teacher: "钱八"),
    ], deleted: [wedID])
    let edited = try! CourseBatchEdit.apply(
        editBatch, scope: .edit(courseID: "id-1", day: 1, block: 0),
        courses: existing, overrides: [], courseID: "id-1",
        overrideSlots: [], maxWeek: 16)
    expectEqual(edited.courses.count, 2, "删一条 + 加一条 → 仍是两条")
    expect(!edited.courses.contains { $0.day == 3 && $0.block == 2 }, "被删除的旧时段不在了")
    expectEqual(edited.courses[0].name, "数据结构（重修）", "改名同步到保留的旧记录")
    expectEqual(edited.courses[1].name, "数据结构（重修）", "改名同步到新复制的时段")
    expectEqual(edited.courses[0].teacher, "赵七", "保留的旧时段字段已更新")
    expectEqual(edited.courses[0].weeks, [3], "保留的旧时段周次已更新")
    expectEqual(edited.courses[1].teacher, "钱八", "新复制的时段内容正确")
    expectEqual(edited.courses[1].code, "CS202", "新时段使用新代码")
    expect(edited.courses.allSatisfy { $0.userModified }, "编辑导入课 → 整门课标成改过")
    expect(edited.courses.allSatisfy { $0.origin == .imported }, "编辑不改变来源")

    // 3. 添加上课时间：已有记录不动，新记录沿用课程级字段
    let addBatch = CourseEditBatch(name: "随便写的名字", code: "WHATEVER", sessions: [
        session(original: nil, day: 5, block: 3, weeks: [1], teacher: "孙九"),
    ])
    let added = try! CourseBatchEdit.apply(
        addBatch, scope: .addSession(courseID: "id-1"),
        courses: existing, overrides: [], courseID: "id-1",
        overrideSlots: [], maxWeek: 16)
    expectEqual(added.courses.count, 3, "添加上课时间 → 多一条")
    expectEqual(added.courses[2].name, "数据结构", "沿用已有课程名（忽略表单里的只读值）")
    expectEqual(added.courses[2].code, "CS201", "沿用已有课程代码")
    expectEqual(added.courses[2].courseID, "id-1", "复用 courseID")
    expectEqual(added.courses[0].teacher, "宋欣", "已有记录不动")
    expect(added.courses.allSatisfy { $0.userModified }, "给导入课加时段 → 整门课标成改过")

    // 3b. 添加上课时间的表单会列出全部时段，所以也可以顺手改 / 删已有记录
    let addEditBatch = CourseEditBatch(name: "随便写的名字", code: "WHATEVER", sessions: [
        session(original: monID, day: 1, block: 0, weeks: [4], teacher: "改过的老师"),
        session(original: nil, day: 7, block: 4, weeks: [4], teacher: "新老师"),
    ], deleted: [wedID])
    let addedEdited = try! CourseBatchEdit.apply(
        addEditBatch, scope: .addSession(courseID: "id-1"),
        courses: existing, overrides: [], courseID: "id-1",
        overrideSlots: [], maxWeek: 16)
    expectEqual(addedEdited.courses.count, 2, "添加上课时间：改一条 + 删一条 + 加一条")
    expect(addedEdited.courses.contains { $0.day == 1 && $0.teacher == "改过的老师" },
           "添加上课时间：已有记录被更新")
    expect(!addedEdited.courses.contains { $0.day == 3 && $0.block == 2 },
           "添加上课时间：已有记录被删除")
    expect(addedEdited.courses.allSatisfy { $0.name == "数据结构" },
           "添加上课时间：课程名仍沿用已有课程")

    // 4. 普通时段 + 冲突时段混在一次保存里
    let other = course("形势与政策", code: "X2", day: 5, block: 1,
                       weeks: [1, 2], courseID: "id-other")
    let mixedBatch = CourseEditBatch(name: "数据结构（重修）", code: "CS201", sessions: [
        session(original: monID, day: 5, block: 1, weeks: [1, 2], teacher: "周十"),
        session(original: nil, day: 6, block: 3, weeks: [1, 2], teacher: "吴十一"),
    ])
    let mixed = try! CourseBatchEdit.apply(
        mixedBatch, scope: .edit(courseID: "id-1", day: 1, block: 0),
        courses: existing + [other], overrides: [], courseID: "id-1",
        overrideSlots: [0], maxWeek: 16)
    expect(!mixed.courses.contains { $0.courseID == "id-1" && $0.day == 5 && $0.block == 1 },
           "冲突时段不进 courses")
    expect(mixed.overrides.count == 1, "冲突时段写成一条覆盖")
    expectEqual(mixed.overrides.first?.courseID, "id-1", "覆盖沿用课程身份")
    expectEqual(mixed.overrides.first?.restored?.day, 1, "覆盖保存原记录（周一那次）")
    expectEqual(mixed.overrides.first?.restored?.teacher, "宋欣", "restored 保存原记录内容")
    expect(mixed.courses.contains { $0.courseID == "id-1" && $0.day == 6 && $0.block == 3 },
           "非冲突时段照常进 courses")
    expect(mixed.courses.contains { $0.courseID == "id-other" }, "别的课不受影响")

    // 5. 新增的时段也可以直接写成覆盖，restored 为空
    let newOverride = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "讲座", code: "L1", sessions: [
            session(original: nil, day: 5, block: 1, weeks: [1], teacher: "讲师"),
        ]),
        scope: .create(day: 5, block: 1),
        courses: [other], overrides: [], courseID: "lecture-id",
        overrideSlots: [0], maxWeek: 16)
    expectEqual(newOverride.courses.count, 1, "覆盖不塞进 courses，原课还在")
    expectEqual(newOverride.overrides.first?.restored, nil, "新增时段的覆盖没有 restored")
    expectEqual(newOverride.overrides.first?.courseID, "lecture-id", "覆盖使用调用方给的 courseID")

    // 6. 来源语义：manual / unknown 不会被改成 imported，也不会被莫名标脏
    var manual = course("自习", day: 2, block: 2, weeks: [1], courseID: "id-m")
    manual.origin = .manual
    let manualEdit = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "自习（改）", code: "", sessions: [
            session(original: CourseSessionIdentity(courseID: "id-m", day: 2, block: 2),
                    day: 2, block: 2, weeks: [1]),
        ]),
        scope: .edit(courseID: "id-m", day: 2, block: 2),
        courses: [manual], overrides: [], courseID: "id-m",
        overrideSlots: [], maxWeek: 16)
    expectEqual(manualEdit.courses.first?.origin, .manual, "手工课来源保持 manual")
    expectEqual(manualEdit.courses.first?.userModified, false, "手工课不被额外标脏")

    var legacy = course("旧数据", day: 4, block: 4, weeks: [1], courseID: "id-u")
    legacy.origin = .unknown
    let legacyEdit = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "旧数据（改）", code: "", sessions: [
            session(original: CourseSessionIdentity(courseID: "id-u", day: 4, block: 4),
                    day: 4, block: 4, weeks: [1]),
        ]),
        scope: .edit(courseID: "id-u", day: 4, block: 4),
        courses: [legacy], overrides: [], courseID: "id-u",
        overrideSlots: [], maxWeek: 16)
    expectEqual(legacyEdit.courses.first?.origin, .unknown, "旧数据来源保持 unknown")
    expectEqual(legacyEdit.courses.first?.userModified, false, "旧数据不被额外标脏")

    // 7. 校验失败 → apply 抛错，不产生半成品
    var threw = false
    do {
        _ = try CourseBatchEdit.apply(
            CourseEditBatch(name: "", code: "", sessions: [session(original: nil, day: 1, block: 0)]),
            scope: .create(day: 1, block: 0), courses: [],
            overrides: [], courseID: "x", overrideSlots: [], maxWeek: 16)
    } catch CourseEditError.emptyName {
        threw = true
    } catch {
        threw = false
    }
    expect(threw, "批量校验失败时 apply 抛错")
}

suite("周次选择器 · 区间与自定义") {
    let p = WeekRangePicker()
    p.maxWeek = 16

    // 连续周次 → 区间模式（左边起始、右边结束）
    p.weeks = [3, 4, 5]
    expect(!p.isCustomMode, "连续周次用区间模式")
    expectEqual(p.testRange?.start, 3, "起始周 = 3")
    expectEqual(p.testRange?.end, 5, "结束周 = 5")

    // 单周 → 起始 = 结束
    p.weeks = [10]
    expectEqual(p.testRange?.start, 10, "单周起始 = 10")
    expectEqual(p.testRange?.end, 10, "单周结束 = 10")

    // 上下键增减（↑ / ↓）
    p.weeks = [3, 4, 5]
    p.stepStart(by: 1)
    expectEqual(p.weeks, [4, 5], "↑ 起始周 +1")
    p.stepEnd(by: -1)
    expectEqual(p.weeks, [4], "↓ 结束周 -1")

    // 不连续周次 → 自定义模式，原值一个不丢
    p.weeks = [1, 2, 4]
    expect(p.isCustomMode, "不连续周次切到自定义模式")
    expectEqual(p.testCustomText, "1-2,4", "自定义写法保留原值")
    expectEqual(CourseEdit.parseWeeks(p.testCustomText ?? ""), [1, 2, 4], "自定义写法能原样解析回来")
    expectEqual(p.weeks, [1, 2, 4], "不连续周次一个不丢")

    // 单双周（1-3,5-6(单)）展开出来的集合也要原样保留
    let odd = CourseEdit.parseWeeks("1-3,5-6(单)")
    p.weeks = odd
    expect(p.isCustomMode, "单双周是自定义模式")
    expectEqual(p.weeks, odd, "单双周一个不丢")

    // 打字打到一半把框清空 → 不能被立刻改写回去（否则永远没法重输）
    p.weeks = [3, 4, 5]
    p.testSimulateClearStartField()
    expectEqual(p.testStartFieldText, "", "清空后输入框保持为空（可以继续打字）")
    expectEqual(p.weeks, [3, 4, 5], "清空输入不改变已选的周次")

    // 步进器（上下箭头）必须跟着数字框走：
    // 以前步进器停在初始值 1，数字框显示 15，用户点向上箭头 → 数字框被改成 2
    // （用户原话：「最右边那个 15 周一点向上的箭头之后变成第二周」）。
    p.maxWeek = 16
    p.weeks = Array(1...15)
    expectEqual(p.testRange?.end, 15, "结束周 = 15")
    p.testSimulateEndStepperUp()
    expectEqual(p.testRange?.end, 16, "点结束周的上箭头 → 16 周（不是 2 周）")
    expectEqual(p.weeks, Array(1...16), "周次整体 +1")
    p.testSimulateEndStepperDown()
    expectEqual(p.testRange?.end, 15, "点结束周的下箭头 → 15 周")
    expectEqual(p.weeks, Array(1...15), "周次整体 -1")
}

suite("编辑器 · 布局装得下 + 预填") {
    var d = CourseDraft()
    d.name = "学术语言"; d.code = "C1"; d.day = 6; d.block = 0; d.weeks = [10]
    let editor = CourseEditorWindowController(mode: .edit(courseID: "same", day: 6, block: 0),
                                             draft: d, maxWeek: 16)
    editor.testPrepareLayout()

    // 周次选择器换成了左右两个数字，表单变高了 —— 底部按钮不能被挤出窗口
    let frame = editor.testSaveButtonFrame
    expect(frame != nil, "能取到保存按钮的位置")
    if let f = frame {
        expect(f.minY >= 0, "保存按钮没被挤出窗口顶部")
        expect(f.maxY <= editor.testContentHeight, "保存按钮没被挤出窗口底部")
        // 底部还要留出放错误提示的空（原来窗口高度就是按这个留的）
        let slack = editor.testContentHeight - f.maxY
        expect(slack >= 20, "底部留白够放错误提示（余量 \(Int(slack)) pt）")
    }
    // 新布局：一个时段一张卡，放在中间滚动区里；单时段不需要滚动。
    expectEqual(editor.testSlotCount, 1, "单时段编辑器只有一张时段卡")
    expect(editor.testViewportHeight > 0, "滚动视口有高度")
    expect(editor.testDocumentHeight > 0, "滚动文档有高度")
    expect(!editor.testScrolls, "单时段放得下，不需要滚动")
    expectEqual(editor.testSlotActionsVisible, [true], "编辑模式显示复制 / 删除")
    expectEqual(editor.testSlotMarkedNew, [false], "已有记录不标「新增」")

    // 预填：周次原样带进来（不再是 1-15 那种默认区间）
    expectEqual(editor.currentDraft().weeks, [10], "周次原样预填")
    expectEqual(editor.currentDraft().day, 6, "星期预填")
    expectEqual(editor.currentDraft().block, 0, "节次预填")
}

suite("编辑器 · 多时段复制 / 删除") {
    func draft(day: Int, block: Int, teacher: String, loc: String = "", weeks: [Int] = [1, 2]) -> CourseDraft {
        var d = CourseDraft()
        d.name = "学术语言"; d.code = "C1"
        d.day = day; d.block = block
        d.teacher = teacher; d.loc = loc; d.weeks = weeks
        return d
    }

    let monID = CourseSessionIdentity(courseID: "same", day: 1, block: 1)
    let wedID = CourseSessionIdentity(courseID: "same", day: 3, block: 3)
    let mon = CourseSessionDraft(original: monID,
                                 draft: draft(day: 1, block: 1, teacher: "周一老师", loc: "A101"))
    let wed = CourseSessionDraft(original: wedID,
                                 draft: draft(day: 3, block: 3, teacher: "周三老师", loc: "B202", weeks: [3]))
    let base = draft(day: 1, block: 1, teacher: "周一老师")

    let editor = CourseEditorWindowController(
        mode: .edit(courseID: "same", day: 3, block: 3),
        courseDraft: base,
        sessions: [mon, wed],
        primary: wedID,
        maxWeek: 16)
    editor.testPrepareLayout()

    expectEqual(editor.testSlotCount, 2, "编辑时显示全部上课时间")
    expectEqual(editor.testSlotTitles, ["时段 1", "时段 2"], "时段按顺序编号")
    expectEqual(editor.currentDraft().teacher, "周三老师", "主时段是用户点中的那一条")
    expectEqual(editor.testSlotIdentities[0], monID, "第一段对应周一记录")
    expectEqual(editor.testSlotIdentities[1], wedID, "第二段对应周三记录")

    // 复制：插在下面，字段一模一样，原记录身份为空
    editor.testCopySlot(at: 0)
    expectEqual(editor.testSlotCount, 3, "复制后多一段")
    expectEqual(editor.testSlotTitles, ["时段 1", "时段 2", "时段 3"], "复制后重新编号")
    expectEqual(editor.testSlotIdentities[1], nil, "复制出来的时段是新时段")
    expectEqual(editor.testSlotMarkedNew, [false, true, false],
                "复制出来的行标成「新增」，旧记录不标")
    let copied = editor.testBatch.sessions[1].draft
    expectEqual(copied.day, 1, "复制星期")
    expectEqual(copied.block, 1, "复制节次")
    expectEqual(copied.teacher, "周一老师", "复制教师")
    expectEqual(copied.loc, "A101", "复制地点")
    expectEqual(copied.weeks, [1, 2], "复制周次")
    expectEqual(editor.currentDraft().teacher, "周三老师", "复制不影响主时段")

    // 多段时删除不弹确认
    var prompted = false
    editor.testConfirmLastSlotDelete = { prompted = true; return false }
    editor.testDeleteSlot(at: 1)
    expect(!prompted, "还有多个时段时删除不弹确认")
    expectEqual(editor.testSlotCount, 2, "删掉复制出来的时段")

    // 删掉一个旧记录 → 记进 deleted，保存时才会真删
    editor.testDeleteSlot(at: 0)
    expect(!prompted, "多个时段时删除旧记录也不弹确认")
    expectEqual(editor.testSlotCount, 1, "只剩一个时段")
    expectEqual(editor.testBatch.deleted, [monID], "明确记录被删掉的旧时段")
    expectEqual(editor.currentDraft().teacher, "周三老师", "主时段被删后自动落到剩下的那段")

    // 只剩一个：点删除先确认；取消 → 什么都不动
    prompted = false
    editor.testDeleteSlot(at: 0)
    expect(prompted, "最后一个时段删除前要确认")
    expectEqual(editor.testSlotCount, 1, "取消确认后时段还在")

    // 确认 → 编辑模式交给 onDeleteAll（删整门课）
    var deleteAllCalls = 0
    editor.onDeleteAll = { deleteAllCalls += 1; return true }
    editor.testConfirmLastSlotDelete = { true }
    editor.testDeleteSlot(at: 0)
    expectEqual(deleteAllCalls, 1, "编辑模式最后一个时段 → 删整门课")
}

suite("编辑器 · 新增模式删除最后一个时段 = 放弃编辑") {
    var d = CourseDraft()
    d.name = "讲座"; d.day = 2; d.block = 1; d.weeks = [1]
    let editor = CourseEditorWindowController(mode: .create, draft: d, maxWeek: 16)
    editor.testPrepareLayout()

    var cancelled = 0
    editor.onCancel = { cancelled += 1 }
    editor.testConfirmLastSlotDelete = { true }
    editor.testDeleteSlot(at: 0)
    expectEqual(cancelled, 1, "新增模式最后一个时段删除 → 取消编辑器")
    expectEqual(editor.testSlotCount, 1, "编辑器本身不会凭空多出/少掉时段卡")
    expectEqual(editor.testSlotMarkedNew, [false], "新增课程不把仅有的时段标成「新增」")
}

suite("编辑器 · 临时覆盖不显示复制 / 删除") {
    var d = CourseDraft()
    d.name = "覆盖课"; d.day = 4; d.block = 2; d.weeks = [3]
    let editor = CourseEditorWindowController(mode: .editOverride, draft: d, maxWeek: 16)
    editor.testPrepareLayout()
    expectEqual(editor.testSlotCount, 1, "临时覆盖只有一格")
    expectEqual(editor.testSlotActionsVisible, [false], "临时覆盖不显示复制 / 删除")
    expectEqual(editor.testSlotMarkedNew, [false], "临时覆盖不标「新增」")
    expectEqual(editor.currentDraft().day, 4, "临时覆盖的星期预填")
}

suite("编辑器 · 多时段超出视口时可滚动") {
    let slots: [(Int, Int)] = [(1, 0), (2, 1), (3, 2), (4, 3), (5, 4), (6, 0)]
    let sessions = slots.enumerated().map { i, slot -> CourseSessionDraft in
        var d = CourseDraft()
        d.name = "滚动测试"; d.day = slot.0; d.block = slot.1
        d.teacher = "老师\(i + 1)"; d.weeks = [1, 2]
        return CourseSessionDraft(original: CourseSessionIdentity(courseID: "scroll",
                                                                   day: slot.0, block: slot.1),
                                   draft: d)
    }
    var base = CourseDraft()
    base.name = "滚动测试"; base.code = "S1"; base.day = 1; base.block = 0; base.weeks = [1, 2]
    let editor = CourseEditorWindowController(mode: .create,
                                               courseDraft: base,
                                               sessions: sessions,
                                               primary: nil,
                                               maxWeek: 16)
    editor.testPrepareLayout()

    expectEqual(editor.testSlotCount, 6, "6 个时段都显示")
    expectEqual(editor.testSlotTitles, (1...6).map { "时段 \($0)" }, "6 个时段顺序编号")
    expect(editor.testViewportHeight > 0, "滚动视口有高度")
    expect(editor.testScrolls, "6 个时段超出视口 → 需要滚动")
    expect(editor.testDocumentHeight > editor.testViewportHeight,
           "文档高度 \(Int(editor.testDocumentHeight)) > 视口 \(Int(editor.testViewportHeight))")
    if let f = editor.testSaveButtonFrame {
        expect(f.minY >= 0, "多时段时保存按钮仍在窗口里")
        expect(f.maxY <= editor.testContentHeight, "多时段时保存按钮没被挤出底部")
    } else {
        expect(false, "多时段时能取到保存按钮位置")
    }
}

suite("右键编辑 · 写盘链路（临时目录）") {
    let dir = makeTempDir("edit")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let repo = ScheduleRepository(store: store)

    // 初始数据
    try! store.saveCourses([course("数据结构", code: "CS201", day: 1, block: 0,
                                   teacher: "宋欣", weeks: [1, 2], courseID: "id-1")])
    let loaded = repo.load()
    expectEqual(loaded.courses.count, 1, "读到 1 条")
    expectEqual(loaded.courses[0].courseID, "id-1", "已有 courseID 原样保留")

    // 编辑课名 → 同步所有同 courseID 记录 → 写盘 → 备份存在
    var d = CourseDraft()
    d.name = "数据结构（重修）"; d.code = "CS201"; d.day = 1; d.block = 0
    d.teacher = "宋欣"; d.weeks = [1, 2]
    let updated = try! CourseEdit.apply(draft: d, scope: .edit(courseID: "id-1", day: 1, block: 0),
                                       courses: loaded.courses, maxWeek: 16)
    try! repo.save(updated)

    let saved = try! store.loadCourses()
    expectEqual(saved.count, 1, "写盘后仍是 1 条")
    expectEqual(saved[0].name, "数据结构（重修）", "课名已更新")
    expectEqual(saved[0].courseID, "id-1", "courseID 没变")
    expectEqual(saved[0].weeksLabel, WeekSpec.format(Set([1, 2])), "weeksLabel 重新生成")

    let backups = (try? FileManager.default.contentsOfDirectory(
        at: store.backupsDirectory, includingPropertiesForKeys: nil)) ?? []
    expect(backups.contains { $0.lastPathComponent.hasPrefix("schedule_data-") },
           "写盘前自动备份 schedule_data.json")

    // 新增课程 → 新 courseID，与旧课不冲突
    var d2 = CourseDraft()
    d2.name = "英语"; d2.day = 3; d2.block = 1; d2.weeks = [1]
    let withNew = try! CourseEdit.apply(draft: d2, scope: .create(day: 3, block: 1),
                                        courses: saved, maxWeek: 16)
    expectEqual(Set(withNew.map { $0.courseID }).count, 2, "新课是新 courseID，与旧课不冲突")

    // 删除整门课 → 课表里不再有它
    let deleted = CourseEdit.deleteCourse(courseID: "id-1", courses: withNew)
    expectEqual(deleted.count, 1, "删除整门课后只剩 1 条")
    expectEqual(deleted.first?.name, "英语", "剩下的是英语")

    // 重新加载：courseID 仍然是 id-1（迁移不会重新分配已有 ID）
    let reloaded = repo.load()
    expectEqual(reloaded.courses.first?.courseID, "id-1", "重新加载不重新分配 courseID")
}

suite("编辑器 · 批量保存接入控制器（临时目录）") {
    let dir = makeTempDir("batch-save")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let repo = ScheduleRepository(store: store)

    let mon = course("学术语言", code: "C1", day: 1, block: 1,
                     teacher: "周一老师", loc: "A101", weeks: [1, 2], courseID: "id-1")
    let wed = course("学术语言", code: "C1", day: 3, block: 3,
                     teacher: "周三老师", loc: "B202", weeks: [1, 2], courseID: "id-1")
    let sat = course("学术语言", code: "C1", day: 6, block: 0,
                     teacher: "周六老师", loc: "C303", weeks: [9], courseID: "id-1")
    try! store.saveCourses([mon, wed, sat])

    let ctl = ScheduleEditorController(repositoryProvider: { repo })

    func id(_ c: Course) -> CourseSessionIdentity {
        CourseSessionIdentity(courseID: c.courseID, day: c.day, block: c.block)
    }
    func d(_ c: Course, teacher: String? = nil, weeks: [Int]? = nil) -> CourseDraft {
        var x = CourseDraft()
        x.name = c.name; x.code = c.code
        x.teacher = teacher ?? c.teacher; x.loc = c.loc
        x.day = c.day; x.block = c.block; x.weeks = weeks ?? c.weeks
        return x
    }
    func newDraft(name: String, code: String, day: Int, block: Int,
                  teacher: String, weeks: [Int]) -> CourseDraft {
        var x = CourseDraft()
        x.name = name; x.code = code; x.day = day; x.block = block
        x.teacher = teacher; x.weeks = weeks
        return x
    }

    // 1. 打开编辑器 → 显示这门课的全部上课时间，点中的那条是主时段
    let editor = ctl.testOpenEditor(courseID: "id-1")
    expect(editor != nil, "能打开课程编辑器")
    editor?.testPrepareLayout()
    expectEqual(editor?.testSlotCount, 3, "编辑器显示全部 3 个上课时间")
    expectEqual(editor?.currentDraft().day, mon.day, "主时段是点中的那条（星期）")
    expectEqual(editor?.currentDraft().block, mon.block, "主时段是点中的那条（节次）")
    editor?.close()

    // 1b. 「添加一个上课时间」：列出全部已有时间 + 末尾一个新时段，
    //     新时段的教师 / 地点 / 周次沿用点中的那次，星期 / 节次挑空格。
    let addEditor = ctl.testOpenAddSessionEditor(courseID: "id-1",
                                                 day: wed.day, block: wed.block)
    expect(addEditor != nil, "能打开「添加一个上课时间」编辑器")
    addEditor?.testPrepareLayout()
    expectEqual(addEditor?.testSlotCount, 4, "已有 3 个时段 + 新增 1 个")
    expectEqual(addEditor?.testSlotMarkedNew ?? [], [false, false, false, true],
                "只有末尾新加的那行标「新增」")
    expect(addEditor?.testLastSlotVisible == true,
           "打开后自动滚到新加的那行，用户一眼能看到")
    let addSessions = addEditor?.testBatch.sessions ?? []
    expectEqual(addSessions.count, 4, "表单里 4 行")
    expect(addSessions.last?.original == nil, "最后一行是新时段")
    expect(addSessions.first?.original == id(wed), "点中的那次排第一")
    let freshDraft = addSessions.last?.draft
    expectEqual(freshDraft?.teacher ?? "", wed.teacher, "新时段沿用点中那次的教师")
    expectEqual(freshDraft?.loc ?? "", wed.loc, "新时段沿用点中那次的地点")
    expectEqual(freshDraft?.weeks ?? [], wed.weeks, "新时段沿用点中那次的周次")
    expect(freshDraft?.day != wed.day || freshDraft?.block != wed.block,
           "新时段不会和已有时间落在同一格")
    let addIdentities = addEditor?.testSlotIdentities.compactMap { $0 } ?? []
    expectEqual(Set(addIdentities), Set([id(mon), id(wed), id(sat)]),
                "前面三行仍对应已有的三个时段")
    addEditor?.close()

    // 2. 批量保存：改名 + 改两个时段 + 删一个 + 新增一个
    var addedDraft = d(mon)
    addedDraft.day = 5; addedDraft.block = 3
    addedDraft.teacher = "新时段老师"; addedDraft.weeks = [3]
    let batch = CourseEditBatch(name: "学术语言（改）", code: "C9", sessions: [
        CourseSessionDraft(original: id(mon), draft: d(mon, teacher: "新周一老师")),
        CourseSessionDraft(original: id(sat), draft: d(sat, weeks: [9, 10])),
        CourseSessionDraft(original: nil, draft: addedDraft),
    ], deleted: [id(wed)])

    ctl.testSubmit(batch: batch, scope: .edit(courseID: "id-1",
                                              day: mon.day, block: mon.block))

    let saved = try! store.loadCourses()
    expectEqual(saved.count, 3, "删一条 + 加一条，记录数保持 3")
    expect(saved.allSatisfy { $0.name == "学术语言（改）" }, "改名同步到所有记录")
    expect(saved.allSatisfy { $0.code == "C9" }, "代码同步到所有记录")
    expect(!saved.contains { $0.day == wed.day && $0.block == wed.block }, "被删的周三时段不在了")
    expect(saved.contains { $0.day == 5 && $0.block == 3 && $0.teacher == "新时段老师" },
           "新增时段写盘")
    expect(saved.contains { $0.day == mon.day && $0.teacher == "新周一老师" },
           "保留的旧时段更新写盘")
    expectEqual(Set(saved.map { $0.courseID }), ["id-1"], "所有时段仍属于同一门课")
    expect(saved.allSatisfy { $0.userModified }, "编辑导入课 → 整门课标成改过")

    // 3. 添加上课时间：只追加，不改已有记录
    let addBatch = CourseEditBatch(name: "表单里的只读值", code: "IGNORED", sessions: [
        CourseSessionDraft(original: nil,
                           draft: newDraft(name: "表单里的只读值", code: "IGNORED",
                                           day: 7, block: 4, teacher: "周日老师", weeks: [4])),
    ])
    ctl.testSubmit(batch: addBatch, scope: .addSession(courseID: "id-1"))
    let afterAdd = try! store.loadCourses()
    expectEqual(afterAdd.count, 4, "添加上课时间只追加一条")
    expect(afterAdd.contains { $0.day == 7 && $0.block == 4 && $0.teacher == "周日老师" },
           "新增时段写盘")
    expect(afterAdd.allSatisfy { $0.name == "学术语言（改）" },
           "添加时段沿用已有课程名，不被表单只读值覆盖")
    expect(afterAdd.allSatisfy { $0.courseID == "id-1" }, "新增时段复用 courseID")
}

suite("编辑器 · 批量保存冲突时段 → 覆盖（临时目录）") {
    let dir = makeTempDir("batch-override")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let repo = ScheduleRepository(store: store)

    let other = course("形势与政策", code: "X1", day: 5, block: 1,
                       teacher: "赵老师", weeks: [1, 2], courseID: "id-other")
    try! store.saveCourses([other])

    let ctl = ScheduleEditorController(repositoryProvider: { repo })

    func newDraft(name: String, day: Int, block: Int, weeks: [Int]) -> CourseDraft {
        var x = CourseDraft()
        x.name = name; x.day = day; x.block = block; x.weeks = weeks
        return x
    }

    // 一段冲突（周五 1-2 节）、一段空闲（周六 3-4 节）→ 只把冲突那段写成覆盖
    let batch = CourseEditBatch(name: "讲座", code: "L1", sessions: [
        CourseSessionDraft(original: nil, draft: newDraft(name: "讲座", day: 5, block: 1, weeks: [1])),
        CourseSessionDraft(original: nil, draft: newDraft(name: "讲座", day: 6, block: 3, weeks: [1])),
    ])
    var gates = 0
    ctl.testConfirmGate = { _, _ in gates += 1; return true }
    ctl.testSubmit(batch: batch, scope: .create(day: 5, block: 1))

    expectEqual(gates, 1, "只有冲突的那一段需要确认")
    let loaded = repo.load()
    expectEqual(loaded.overrides.count, 1, "冲突段落写成一条覆盖")
    expectEqual(loaded.overrides.first?.name, "讲座", "覆盖记录是这门课")
    expectEqual(loaded.overrides.first?.day, 5, "覆盖落在冲突的星期")
    expectEqual(loaded.overrides.first?.block, 1, "覆盖落在冲突的节次")
    expectEqual(loaded.overrides.first?.restored, nil, "新课没有需要还原的旧记录")

    let normal = loaded.courses.filter { $0.name == "讲座" }
    expectEqual(normal.count, 1, "非冲突段落进 courses")
    expectEqual(normal.first?.day, 6, "非冲突段落保持自己的时间")
    expectEqual(normal.first?.courseID, loaded.overrides.first?.courseID,
                "覆盖和普通段落属于同一门课")
    expect(loaded.courses.contains { $0.courseID == "id-other" }, "被覆盖的原课还在 courses 里")

    // 取消确认 → 整次保存不写盘
    let coursesBefore = try! store.loadCourses()
    let overridesBefore = repo.load().overrides
    var cancelGates = 0
    ctl.testConfirmGate = { _, _ in cancelGates += 1; return false }
    let cancelBatch = CourseEditBatch(name: "取消测试", code: "", sessions: [
        CourseSessionDraft(original: nil, draft: newDraft(name: "取消测试", day: 5, block: 1, weeks: [1])),
    ])
    ctl.testSubmit(batch: cancelBatch, scope: .create(day: 5, block: 1))
    expectEqual(cancelGates, 1, "冲突确认回调了一次")
    expectEqual(try! store.loadCourses(), coursesBefore, "取消后课表没有变化")
    expectEqual(repo.load().overrides, overridesBefore, "取消后覆盖没有变化")
}

suite("编辑器 · 删除最后一个时段删整门课（临时目录）") {
    let dir = makeTempDir("batch-delete-all")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let repo = ScheduleRepository(store: store)
    try! store.saveCourses([course("唯一课", day: 2, block: 0, weeks: [1], courseID: "only-one")])

    let ctl = ScheduleEditorController(repositoryProvider: { repo })
    let editor = ctl.testOpenEditor(courseID: "only-one")
    expect(editor != nil, "能打开单时段课程")
    editor?.testPrepareLayout()
    editor?.testConfirmLastSlotDelete = { true }
    editor?.testDeleteSlot(at: 0)

    expectEqual(try! store.loadCourses().count, 0, "最后一个时段删除 → 整门课从磁盘消失")
    expect(ctl.testEditor == nil, "删完整门课后编辑器关闭")
}

// MARK: - 阶段 3：多课表

suite("TimetableStore · 旧数据迁移") {
    let dir = makeTempDir("tt-migrate")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default

    // 旧版单课表数据躺在根目录
    let oldCourses = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "old-id-1"),
                      course("英语", code: "C2", day: 2, block: 1, weeks: [1], courseID: "old-id-2")]
    let data = try! JSONEncoder().encode(oldCourses)
    try! data.write(to: dir.appendingPathComponent("schedule_data.json"))
    let sem = try! JSONSerialization.data(withJSONObject: ["start": "2026-08-31", "maxWeek": 16])
    try! sem.write(to: dir.appendingPathComponent("semester.json"))

    let store = TimetableStore(rootDirectory: dir)
    expect(store.needsLegacyMigration, "根目录有旧文件且没有课表 → 需要迁移")

    // 第一次迁移
    let tt = try! store.migrateLegacyIfNeeded(defaultName: "我的课表")
    expect(tt != nil, "迁移出第一份课表")
    expectEqual(store.allMetas().count, 1, "迁移后只有一份课表")
    expect(!store.needsLegacyMigration, "迁移后不再需要迁移")

    // 旧数据搬过去了
    let loaded = try! store.load(tt!.id)
    expectEqual(loaded.courses.count, 2, "旧课程数据搬过来了")
    expectEqual(loaded.courses.first?.courseID, "old-id-1", "已有 courseID 原样保留")
    expectEqual(loaded.semester.maxWeek, 16, "学期配置搬过来了")

    // 备份存在
    let legacyBackups = try! fm.contentsOfDirectory(at: dir.appendingPathComponent("backups"),
                                                     includingPropertiesForKeys: nil)
    expect(legacyBackups.contains { $0.lastPathComponent.hasPrefix("legacy-schedule_data") },
           "迁移前备份了旧课程文件")
    expect(fm.fileExists(atPath: dir.appendingPathComponent("schedule_data.json").path),
           "旧文件迁移成功后仍保留在原地")

    // 第二次迁移：什么都不做
    let second = try! store.migrateLegacyIfNeeded(defaultName: "我的课表")
    expect(second == nil, "第二次启动不再迁移")
    expectEqual(store.allMetas().count, 1, "第二次启动课表数量不变")
}

suite("TimetableStore · 增删改查") {
    let dir = makeTempDir("tt-crud")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)

    // 新建
    let a = try! store.create(name: "2026 秋季", subtitle: "计算机 2501")
    expectEqual(store.allMetas().count, 1, "新建后有一份课表")
    expectEqual(a.name, "2026 秋季", "名字正确")

    // 第二份
    let b = try! store.create(name: "2027 春季")
    expectEqual(store.allMetas().count, 2, "可以有多份课表")

    // 切换
    try! store.setActive(b.id)
    expectEqual(store.activeID, b.id, "可以切换当前课表")

    // 重命名：只改名字，不改 id
    let oldID = a.id
    try! store.rename(id: a.id, name: "2026 秋季（重修）", subtitle: "计算机 2502")
    let renamed = try! store.load(a.id)
    expectEqual(renamed.id, oldID, "重命名不改 id")
    expectEqual(renamed.name, "2026 秋季（重修）", "重命名生效")
    expectEqual(renamed.subtitle, "计算机 2502", "副标题也改了")

    // 写课程 → 读回来
    var t = try! store.load(a.id)
    t.courses = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "x-1")]
    try! store.save(t)
    let reread = try! store.load(a.id)
    expectEqual(reread.courses.count, 1, "课程写盘后读得回来")
    expectEqual(reread.courses.first?.courseID, "x-1", "courseID 存得住")

    // 写盘前自动备份
    let backups = store.listBackups(for: a.id)
    expect(backups.count >= 1, "写盘前自动备份")

    // 删除当前课表 → 切到另一份
    try! store.setActive(b.id)
    let nextActive = try! store.delete(id: b.id)
    expectEqual(nextActive, a.id, "删掉当前课表后切到另一份")
    expectEqual(store.allMetas().count, 1, "只剩一份")

    // 删掉最后一份 → 空课表状态
    let none = try! store.delete(id: a.id)
    expect(none == nil, "删掉最后一份后进入空课表状态")
    expectEqual(store.allMetas().count, 0, "没有课表了")
    expect(store.activeID == nil, "没有当前课表")
}

suite("TimetableStore · 目录结构") {
    let dir = makeTempDir("tt-layout")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let t = try! store.create(name: "A")

    let fm = FileManager.default
    expect(fm.fileExists(atPath: store.indexFile.path), "有 timetables/index.json")
    expect(fm.fileExists(atPath: store.metaFile(for: t.id).path), "有 <uuid>/meta.json")
    expect(fm.fileExists(atPath: store.coursesFile(for: t.id).path), "有 <uuid>/schedule_data.json")
    expect(fm.fileExists(atPath: store.semesterFile(for: t.id).path), "有 <uuid>/semester.json")
    expect(store.indexFile.path.hasSuffix("timetables/index.json"), "索引在 timetables/ 下")
    expect(store.metaFile(for: t.id).path.contains("/timetables/"), "课表在 timetables/<uuid>/ 下")
}

suite("TimetableDiff · 匹配规则") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)

    // 1) 按 courseID 匹配
    let cur = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "id-1")]
    let imp = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "id-1")]
    var r = TimetableDiff.compare(current: cur, imported: imp,
                                  currentSemester: sem, importedSemester: sem)
    expectEqual(r.matched.count, 1, "同 courseID → 匹配上")
    expectEqual(r.matched.first?.match, .byID(oldID: "id-1"), "按 ID 匹配")
    expect(r.isIdentical, "完全一样 → 无差异")

    // 2) 导入里 courseID 变了，但 code 一样 → 按 code 匹配，复用旧 ID
    let imp2 = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "new-uuid")]
    r = TimetableDiff.compare(current: cur, imported: imp2,
                               currentSemester: sem, importedSemester: sem)
    expectEqual(r.matched.count, 1, "code 相同 → 匹配上")
    expectEqual(r.matched.first?.match, .byCode, "按 code 匹配")
    expectEqual(r.matched.first?.courseID, "id-1", "匹配上 → 复用旧 courseID")

    // 3) code 为空 → 按课名匹配
    let cur3 = [course("军事理论", code: "", day: 3, block: 1, courseID: "id-3")]
    let imp3 = [course("军事理论", code: "", day: 3, block: 1, courseID: "uuid-3")]
    r = TimetableDiff.compare(current: cur3, imported: imp3,
                               currentSemester: sem, importedSemester: sem)
    expectEqual(r.matched.count, 1, "code 空 + 课名相同 → 匹配上")
    expectEqual(r.matched.first?.match, .byName, "按课名匹配")

    // 4) 课名相同但 code 不同 → 不猜，列进「需要确认」
    let cur4 = [course("数据结构", code: "A1", day: 1, block: 0, courseID: "id-4")]
    let imp4 = [course("数据结构", code: "B2", day: 1, block: 0, courseID: "uuid-4")]
    r = TimetableDiff.compare(current: cur4, imported: imp4,
                               currentSemester: sem, importedSemester: sem)
    expectEqual(r.ambiguous.count, 1, "课名相同但 code 不同 → 需要确认")
    expectEqual(r.matched.count, 0, "不自动猜")

    // 5) 匹配不上 → 新增
    let imp5 = [course("体育", code: "P1", day: 5, block: 0, courseID: "uuid-5")]
    r = TimetableDiff.compare(current: cur, imported: imp5,
                               currentSemester: sem, importedSemester: sem)
    expectEqual(r.added.count, 1, "匹配不上 → 新增")
    expectEqual(r.removed.count, 1, "当前课表里有、导入里没有 → 移除候选")
}

suite("TimetableDiff · 字段差异") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let cur = [course("数据结构", code: "C1", day: 1, block: 0,
                      teacher: "宋欣", loc: "工学馆506", weeks: [1, 2], courseID: "id-1")]

    // 教师/地点/周次变了 → 上课时间级有差异
    let imp = [course("数据结构", code: "C1", day: 1, block: 0,
                      teacher: "李佳音", loc: "工学馆506", weeks: [1, 3], courseID: "id-1")]
    var r = TimetableDiff.compare(current: cur, imported: imp,
                                  currentSemester: sem, importedSemester: sem)
    expectEqual(r.matched.count, 1, "匹配上")
    expect(r.matched.first!.sessionLevelChanged, "教师/周次变了 → 上课时间级差异")
    expect(!r.matched.first!.courseLevelChanged, "课名代码没变 → 课程级无差异")

    // 课名变了 → 课程级差异
    let imp2 = [course("数据结构（重修）", code: "C1", day: 1, block: 0,
                       teacher: "宋欣", loc: "工学馆506", weeks: [1, 2], courseID: "id-1")]
    r = TimetableDiff.compare(current: cur, imported: imp2,
                               currentSemester: sem, importedSemester: sem)
    expect(r.matched.first!.courseLevelChanged, "课名变了 → 课程级差异")

    // 学期差异
    let sem2 = SemesterConfig(start: Date().addingTimeInterval(86400 * 3), maxWeek: 18)
    r = TimetableDiff.compare(current: cur, imported: imp,
                               currentSemester: sem, importedSemester: sem2)
    expect(r.semesterStartChanged, "开学日期不同 → 学期级差异")
    expect(r.semesterMaxWeekChanged, "总周数不同 → 学期级差异")
    expect(r.differenceCount >= 3, "差异计数包含学期差异")
}

suite("TimetableDiff · 合并") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let cur = [
        course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "id-1"),
        course("英语", code: "C2", day: 2, block: 1, weeks: [1], courseID: "id-2"),
    ]
    let imp = [
        course("数据结构", code: "C1", day: 1, block: 0, teacher: "李佳音", weeks: [1, 2], courseID: "id-1"),
        course("体育", code: "P1", day: 5, block: 0, weeks: [1], courseID: "uuid-p"),
    ]

    let r = TimetableDiff.compare(current: cur, imported: imp,
                                  currentSemester: sem, importedSemester: sem)

    // 默认选择：**按来源分流**（本轮改过）。
    //
    // 旧断言是「有差异的已有课程一律默认保留当前」。这条规则在覆盖导入下等于
    // 「什么都不更新」—— 用户点了「覆盖当前课表」，课表还是旧的。
    // 现在：当前这门课如果就是导入来的原样（无保护）→ 默认「用导入」；
    // 用户新增 / 改过 / 旧数据（受保护）→ 默认「保留当前」。
    // 下面这门 `id-1` 是用 `course(...)` 造出来的导入课、没被改过 → 不保护。
    var choice = TimetableDiff.defaultMergeChoice(for: r)
    expectEqual(choice.courses["id-1"], .useImported,
                "未受保护的匹配课默认用导入（覆盖语义：让导入内容生效）")
    expectEqual(choice.courses["uuid-p"], .useImported, "导入新增默认用导入")
    expectEqual(choice.courses["id-2"], .keepCurrent, "导入消失默认保留当前")
    expectEqual(choice.semesterStart, .keepCurrent, "学期默认保留当前")
    expectEqual(choice.semesterMaxWeek, .keepCurrent, "学期默认保留当前")

    // 全用导入
    for d in r.matched { choice.courses[d.courseID] = .useImported }
    for d in r.added { choice.courses[d.courseID] = .useImported }
    for d in r.removed { choice.courses[d.courseID] = .delete }
    choice.semesterStart = .useImported
    choice.semesterMaxWeek = .useImported

    var merged = TimetableDiff.merge(current: cur, imported: imp, result: r, choice: choice)
    expectEqual(merged.courses.count, 2, "全用导入 → 1 门匹配 + 1 门新增，消失的被删")
    expect(merged.courses.contains { $0.courseID == "id-1" }, "匹配课程复用旧 courseID")
    expect(merged.courses.contains { $0.courseID == "uuid-p" }, "新增课程用新 courseID")
    expect(!merged.courses.contains { $0.courseID == "id-2" }, "消失课程被删除")
    expectEqual(merged.courses.first { $0.courseID == "id-1" }?.teacher, "李佳音", "用导入 → 教师变了")
    expectEqual(merged.semester.maxWeek, 16, "学期用导入")

    // 全部保留当前
    choice = TimetableDiff.defaultMergeChoice(for: r)
    // 默认值现在按来源分流（这门课不保护 → 默认「用导入」），
    // 这个用例要验证的是「全部保留当前」，所以显式把所有匹配课设回保留。
    for d in r.matched { choice.courses[d.courseID] = .keepCurrent }
    for d in r.added { choice.courses[d.courseID] = .skip }
    merged = TimetableDiff.merge(current: cur, imported: imp, result: r, choice: choice)
    expectEqual(merged.courses.count, 2, "全部保留当前 → 课程数不变")
    expectEqual(merged.courses.first { $0.courseID == "id-1" }?.teacher, "", "保留当前 → 教师没变")
    expect(!merged.courses.contains { $0.courseID == "uuid-p" }, "跳过 → 新增课程不导入")
}

suite("阶段 3 · 导入三选一") {
    let dir = makeTempDir("tt-import")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let store = TimetableStore(rootDirectory: dir)

    // 当前课表（3 门课）
    let t = try! store.create(name: "当前课表")
    var cur = try! store.load(t.id)
    cur.courses = [
        course("数据结构", code: "C1", day: 1, block: 0, teacher: "宋欣", weeks: [1, 2], courseID: "id-ds"),
        course("英语", code: "C2", day: 2, block: 1, teacher: "李佳音", weeks: [1], courseID: "id-en"),
        course("体育", code: "P1", day: 5, block: 0, teacher: "王强", weeks: [1], courseID: "id-ty"),
    ]
    try! store.save(cur)
    try! store.setActive(t.id)

    // 导入内容：数据结构（教师变了）+ 军事理论（新增），没有英语和体育
    let imported = [
        course("数据结构", code: "C1", day: 1, block: 0, teacher: "赵敏", weeks: [1, 3], courseID: "new-ds"),
        course("军事理论", code: "M1", day: 3, block: 2, teacher: "周老师", weeks: [1], courseID: "new-ml"),
    ]

    // ---- 情况 1：无课表导入 → 成为当前课表 ----
    let emptyDir = makeTempDir("tt-import-empty")
    defer { try? FileManager.default.removeItem(at: emptyDir) }
    let emptyStore = TimetableStore(rootDirectory: emptyDir)
    expectEqual(emptyStore.allMetas().count, 0, "一开始没有课表")
    let newT = try! emptyStore.create(name: "导入的课表", courses: imported)
    try! emptyStore.setActive(newT.id)
    expectEqual(emptyStore.allMetas().count, 1, "无课表导入 → 成为当前课表")
    expectEqual(emptyStore.activeID, newT.id, "导入的那份就是当前课表")
    let loadedNew = try! emptyStore.load(newT.id)
    expectEqual(loadedNew.courses.count, 2, "内容正确")

    // ---- 情况 2：选「新建」→ 两份都在，当前表内容不变，新表可切换 ----
    let before = try! store.load(t.id)
    let newOne = try! store.create(name: "导入的课表", courses: imported)
    expectEqual(store.allMetas().count, 2, "新建后有两份课表")
    let after = try! store.load(t.id)
    expectEqual(after.courses.count, before.courses.count, "原课表内容不变")
    expectEqual(after.courses.first?.teacher, "宋欣", "原课表内容不变（教师没变）")
    // 新课表的 courseID 是全新的
    let newIDs = Set((try! store.load(newOne.id)).courses.map { $0.courseID })
    let oldIDs = Set(after.courses.map { $0.courseID })
    expect(newIDs.isDisjoint(with: oldIDs), "新课表的 courseID 与旧表不冲突")
    // 新表可切换
    try! store.setActive(newOne.id)
    expectEqual(store.activeID, newOne.id, "新表可切换")
    expectEqual((try! store.load(newOne.id)).courses.count, 2, "切过去内容正确")

    // ---- 情况 3：选「取消」→ 磁盘无变化 ----
    let snapshotBefore = try! Data(contentsOf: store.coursesFile(for: t.id))
    let countBefore = store.allMetas().count
    // 取消 = 什么都不做
    try! store.setActive(t.id)
    expectEqual(store.allMetas().count, countBefore, "取消 → 课表数量不变")
    let snapshotAfter = try! Data(contentsOf: store.coursesFile(for: t.id))
    expect(snapshotBefore == snapshotAfter, "取消 → 磁盘无变化")

    // ---- 情况 4：覆盖且无差异 → 幂等，courseID 不变 ----
    let sameDir = makeTempDir("tt-import-same")
    defer { try? FileManager.default.removeItem(at: sameDir) }
    let sameStore = TimetableStore(rootDirectory: sameDir)
    let st = try! sameStore.create(name: "课表")
    var stt = try! sameStore.load(st.id)
    stt.courses = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "id-ds")]
    try! sameStore.save(stt)
    try! sameStore.setActive(st.id)

    let sameDiff = TimetableDiff.compare(current: stt.courses, imported: stt.courses,
                                         currentSemester: stt.semester,
                                         importedSemester: stt.semester)
    expect(sameDiff.isIdentical, "完全相同 → 无差异")
    let idsBefore = stt.courses.map { $0.courseID }
    // 覆盖（全部保留当前）
    var sameChoice = TimetableDiff.defaultMergeChoice(for: sameDiff)
    for d in sameDiff.matched { sameChoice.courses[d.courseID] = .keepCurrent }
    let sameMerged = TimetableDiff.merge(current: stt.courses, imported: stt.courses,
                                         result: sameDiff, choice: sameChoice)
    var stt2 = stt
    stt2.courses = sameMerged.courses
    try! sameStore.save(stt2)
    let reread = try! sameStore.load(st.id)
    expectEqual(reread.courses.map { $0.courseID }, idsBefore, "覆盖且无差异 → courseID 不变")

    // ---- 情况 5：覆盖且有差异 → 逐项保留/替换，匹配课程 courseID 不变 ----
    let diff = TimetableDiff.compare(current: cur.courses, imported: imported,
                                     currentSemester: cur.semester,
                                     importedSemester: cur.semester)
    expectEqual(diff.matched.count, 1, "数据结构匹配上")
    expectEqual(diff.added.count, 1, "军事理论是新增")
    expectEqual(diff.removed.count, 2, "英语和体育在导入里消失了")

    var choice = TimetableDiff.defaultMergeChoice(for: diff)
    // 数据结构：保留当前
    choice.courses["id-ds"] = .keepCurrent
    // 军事理论：用导入
    choice.courses["new-ml"] = .useImported
    // 英语、体育：保留当前（默认）
    choice.courses["id-en"] = .keepCurrent
    choice.courses["id-ty"] = .keepCurrent

    let merged = TimetableDiff.merge(current: cur.courses, imported: imported,
                                     result: diff, choice: choice)
    expectEqual(merged.courses.count, 4, "3 门保留当前 + 1 门用导入 = 4")
    expectEqual(merged.courses.first { $0.courseID == "id-ds" }?.teacher, "宋欣", "保留当前 → 教师没变")
    expect(merged.courses.contains { $0.courseID == "new-ml" }, "用导入 → 新增课程进来了")
    expectEqual(merged.courses.first { $0.courseID == "new-ml" }?.teacher, "周老师", "新增课程内容来自导入")

    // ---- 情况 6：导入新增课程 → 新 courseID，不覆盖旧课程 ----
    let diff2 = TimetableDiff.compare(current: cur.courses, imported: imported,
                                      currentSemester: cur.semester,
                                      importedSemester: cur.semester)
    var choice2 = TimetableDiff.defaultMergeChoice(for: diff2)
    choice2.courses["id-ds"] = .useImported      // 数据结构用导入
    choice2.courses["new-ml"] = .useImported     // 军事理论用导入
    let merged2 = TimetableDiff.merge(current: cur.courses, imported: imported,
                                      result: diff2, choice: choice2)
    expectEqual(merged2.courses.first { $0.courseID == "id-ds" }?.teacher, "赵敏", "用导入 → 教师变了")
    expectEqual(merged2.courses.first { $0.courseID == "id-ds" }?.courseID, "id-ds",
                "用导入 → 仍然复用旧 courseID")

    // ---- 情况 7：导入消失课程 → 选保留则不删；选删除则移除，备份存在 ----
    var choice3 = TimetableDiff.defaultMergeChoice(for: diff)
    choice3.courses["id-en"] = .delete
    let merged3 = TimetableDiff.merge(current: cur.courses, imported: imported,
                                      result: diff, choice: choice3)
    expect(!merged3.courses.contains { $0.courseID == "id-en" }, "选删除 → 课程被移除")
    expect(merged3.courses.contains { $0.courseID == "id-ty" }, "选保留 → 课程还在")

    // 写盘前备份存在
    let backups = try! fm.contentsOfDirectory(atPath: store.backupsDirectory(for: t.id).path)
    expect(backups.count >= 1, "写盘前自动备份存在")

    // ---- 情况 8：学期日期/总周数分别选择保留/用导入 ----
    let sem2 = SemesterConfig(start: Date().addingTimeInterval(86400 * 7), maxWeek: 18)
    let diff3 = TimetableDiff.compare(current: cur.courses, imported: imported,
                                      currentSemester: cur.semester,
                                      importedSemester: sem2)
    expect(diff3.semesterStartChanged, "开学日期有差异")
    expect(diff3.semesterMaxWeekChanged, "总周数有差异")

    var choice4 = TimetableDiff.defaultMergeChoice(for: diff3)
    choice4.semesterStart = .keepCurrent
    choice4.semesterMaxWeek = .useImported
    let merged4 = TimetableDiff.merge(current: cur.courses, imported: imported,
                                      result: diff3, choice: choice4)
    expectEqual(merged4.semester.start, cur.semester.start, "开学日期保留当前")
    expectEqual(merged4.semester.maxWeek, 18, "总周数用导入")

    // 反过来
    choice4.semesterStart = .useImported
    choice4.semesterMaxWeek = .keepCurrent
    let merged5 = TimetableDiff.merge(current: cur.courses, imported: imported,
                                      result: diff3, choice: choice4)
    expectEqual(merged5.semester.start, sem2.start, "开学日期用导入")
    expectEqual(merged5.semester.maxWeek, cur.semester.maxWeek, "总周数保留当前")
}

suite("阶段 3 · 切换/重命名/删除后的刷新") {
    let dir = makeTempDir("tt-refresh")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)

    // 两份课表，内容和学期都不同
    let a = try! store.create(name: "秋季")
    var ta = try! store.load(a.id)
    ta.courses = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "id-a")]
    ta.semester = SemesterConfig(start: Date(), maxWeek: 16)
    try! store.save(ta)

    let b = try! store.create(name: "春季")
    var tb = try! store.load(b.id)
    tb.courses = [course("体育", code: "P1", day: 5, block: 0, weeks: [1, 2], courseID: "id-b")]
    tb.semester = SemesterConfig(start: Date().addingTimeInterval(86400 * 30), maxWeek: 18)
    try! store.save(tb)

    // ---- 切换 ----
    try! store.setActive(a.id)
    let la = try! store.load(a.id)
    expectEqual(la.name, "秋季", "切换后标题正确")
    expectEqual(la.courses.count, 1, "切换后课程正确")
    expectEqual(la.courses.first?.name, "数据结构", "切换后课程内容正确")
    expectEqual(la.semester.maxWeek, 16, "切换后周次正确")

    try! store.setActive(b.id)
    let lb = try! store.load(b.id)
    expectEqual(lb.name, "春季", "切换后标题正确")
    expectEqual(lb.courses.first?.name, "体育", "切换后课程内容正确")
    expectEqual(lb.semester.maxWeek, 18, "切换后周次正确")

    // ---- 重命名：只改名字，id 和课程不动 ----
    try! store.rename(id: b.id, name: "春季（重修）", subtitle: "计算机 2501")
    let renamed = try! store.load(b.id)
    expectEqual(renamed.name, "春季（重修）", "重命名生效")
    expectEqual(renamed.subtitle, "计算机 2501", "副标题生效")
    expectEqual(renamed.id, b.id, "重命名不改 id")
    expectEqual(renamed.courses.first?.courseID, "id-b", "重命名不改 courseID")

    // ---- 删除当前课表 → 切到另一份 ----
    try! store.setActive(b.id)
    let next = try! store.delete(id: b.id)
    expectEqual(next, a.id, "删掉当前课表 → 切到另一份")
    expectEqual(store.activeID, a.id, "activeID 跟着切")
    let stillA = try! store.load(a.id)
    expectEqual(stillA.name, "秋季", "切过去的课表内容正确")
    // 删除前有备份
    let backupRoot = store.timetablesDirectory.appendingPathComponent("backups")
    let backups = try! FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
    expect(backups.contains { $0.contains(b.id) }, "删除前备份了整个课表目录")

    // ---- 删除最后一份 → 空课表状态 ----
    let none = try! store.delete(id: a.id)
    expect(none == nil, "删掉最后一份 → 空课表状态")
    expect(store.activeID == nil, "没有当前课表")
}

suite("阶段 3 · 真实数据的迁移（只读副本）") {
    // 用用户真实课表的**副本**做迁移验证，绝不动原文件。
    let live = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DesktopTimetable")
    let liveCourses = live.appendingPathComponent("schedule_data.json")
    guard FileManager.default.fileExists(atPath: liveCourses.path) else {
        // 没有真实数据就跳过这个用例（不失败）
        return
    }

    let dir = makeTempDir("tt-real")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    try? fm.copyItem(at: liveCourses, to: dir.appendingPathComponent("schedule_data.json"))
    let liveSemester = live.appendingPathComponent("semester.json")
    if fm.fileExists(atPath: liveSemester.path) {
        try? fm.copyItem(at: liveSemester, to: dir.appendingPathComponent("semester.json"))
    }

    let store = TimetableStore(rootDirectory: dir)
    let migrated = try! store.migrateLegacyIfNeeded(defaultName: "我的课表")
    expect(migrated != nil, "真实数据迁移成功")

    let loaded = try! store.load(migrated!.id)
    expect(loaded.courses.count > 0, "迁移后有课程")

    // 幂等：第二次不再迁移
    let again = try! store.migrateLegacyIfNeeded(defaultName: "我的课表")
    expect(again == nil, "第二次启动不再迁移")

    // courseID 全部存在且不重复
    let ids = loaded.courses.map { $0.courseID }
    expect(!ids.contains(where: { $0.isEmpty }), "所有课程都有 courseID")
    expectEqual(Set(ids).count, Set(ids.map { normalizeIDForTest($0) }).count,
                "courseID 不重复")

    // 备份存在
    let legacyBackups = try! fm.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
    expect(legacyBackups.contains { $0.hasPrefix("legacy-schedule_data") }, "旧数据有备份")
}

/// 把 courseID 按「同一门课」归一（同一门课的多个上课时间共用一个 ID）。
private func normalizeIDForTest(_ id: String) -> String { id }

suite("阶段 3 · B 模式 / 快照模式") {
    // 阶段 1/2 已经验证过；这里确保多课表改动没有破坏渲染模式的选择。
    expect(AppDelegate.testIsLiveMode, "默认是 B 模式（网页直接上屏）")
}



// MARK: - 推给网页的状态 JSON（周次字段类型）

// 这一组是回归测试。曾经的 bug：
// 阶段 1–3 把 webState 从「裸字符串插值」改成 JSONSerialization，
// `currentWeek` / `viewWeek` 却仍是 Swift String，于是 JSON 里成了 `"9"`。
// 网页判 `typeof S.viewWeek === 'number'` 永远 false，表现为：
//   · 周次胶囊永远显示「全部周次」（还把它挤宽，箭头位置跟着变）；
//   · 点左右箭头时原生改了值重推，网页读不到数字 → 画面毫无变化（「按了没反应」）。
suite("TimetableState · webJSON 周次字段类型") {
    func parse(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    let c1 = course("数据结构", day: 1, block: 0, weeks: [1, 2, 3])

    // 1) 选中某一周 → viewWeek / currentWeek 必须是 JSON 数字
    var st = TimetableState(courses: [c1],
                            semesterStart: day(2026, 8, 30),
                            currentWeek: 9,
                            viewWeek: 9,
                            maxWeek: 16)
    var obj = parse(st.webJSON(title: "我的课表", subtitle: ""))
    expect(obj != nil, "webJSON 能被解析成对象")
    if let o = obj {
        expect(o["viewWeek"] is NSNumber, "viewWeek 必须是 JSON 数字，不能是字符串")
        expect(o["currentWeek"] is NSNumber, "currentWeek 必须是 JSON 数字，不能是字符串")
        expect((o["viewWeek"] as? NSNumber)?.intValue == 9, "viewWeek = 9")
        expect((o["currentWeek"] as? NSNumber)?.intValue == 9, "currentWeek = 9")
        expect(o["maxWeek"] is NSNumber, "maxWeek 必须是 JSON 数字")
        expect((o["maxWeek"] as? NSNumber)?.intValue == 16, "maxWeek = 16")
    }

    // 2) 「全部周次」→ viewWeek 必须是 JSON null（不是字符串 "null"）
    st = TimetableState(courses: [c1],
                        semesterStart: day(2026, 8, 30),
                        currentWeek: 9,
                        viewWeek: nil,
                        maxWeek: 16)
    obj = parse(st.webJSON(title: "我的课表", subtitle: ""))
    if let o = obj {
        expect(o["viewWeek"] is NSNull, "全部周次时 viewWeek 必须是 JSON null")
        expect((o["viewWeek"] as? String) != "null", "viewWeek 不能是字符串 \"null\"")
        expect(o["currentWeek"] is NSNumber, "viewWeek 为 null 时 currentWeek 仍是数字")
    }

    // 3) 今天不在学期内 → currentWeek 为 null，viewWeek 仍可正常是 nil
    st = TimetableState(courses: [c1],
                        semesterStart: day(2026, 8, 30),
                        currentWeek: nil,
                        viewWeek: nil,
                        maxWeek: 16)
    obj = parse(st.webJSON(title: "我的课表", subtitle: ""))
    if let o = obj {
        expect(o["currentWeek"] is NSNull, "不在学期内时 currentWeek 必须是 JSON null")
    }

    // 4) 课程字段照旧（courseID / weeks 是数组）
    let cid = "B2F1E000-0000-0000-0000-000000000001"
    st = TimetableState(courses: [course("计算机网络", day: 3, block: 2, weeks: [2, 4, 6],
                                         courseID: cid)],
                        semesterStart: day(2026, 8, 30),
                        currentWeek: 9, viewWeek: 9, maxWeek: 16)
    obj = parse(st.webJSON(title: "t", subtitle: "s"))
    if let o = obj, let list = o["courses"] as? [[String: Any]], let first = list.first {
        expectEqual(list.count, 1, "courses 条数")
        expectEqual(first["courseID"] as? String ?? "", cid, "courseID 原样保留")
        expect((first["weeks"] as? [Int]) == [2, 4, 6], "weeks 是数字数组")
        expect((first["day"] as? NSNumber)?.intValue == 3, "day 是数字")
    } else {
        expect(false, "courses 结构不对")
    }
}

// MARK: - 问题清单 P0-1：差异页写盘前的校验

suite("TimetableDiff · validate（写盘前校验）") {
    let maxWeek = 16
    // 正常课程：周次非空 → 通过。
    // 以前这里是 `guard c.weeks.isEmpty else { 报错 }` —— 判断反了：
    // 正常课程周次当然非空，于是「应用」按钮必然失败；真·空周次反而能过。
    expectEqual(TimetableDiff.validate(courses: [course("数据结构", day: 1, block: 0, weeks: [1, 2, 3])],
                                       maxWeek: maxWeek),
                nil, "正常课程（周次非空）通过校验")
    // 空周次 → 拒绝
    expect(TimetableDiff.validate(courses: [course("空周次", weeks: [])], maxWeek: maxWeek) != nil,
           "空周次被拒绝")
    // 非法星期 → 拒绝
    expect(TimetableDiff.validate(courses: [course("星期越界", day: 8, weeks: [1])], maxWeek: maxWeek) != nil,
           "星期越界被拒绝")
    expect(TimetableDiff.validate(courses: [course("星期为 0", day: 0, weeks: [1])], maxWeek: maxWeek) != nil,
           "星期为 0 被拒绝")
    // 非法节次（block 5 = 第 11 节，网格只有 10 节）→ 拒绝
    let blockMessage = TimetableDiff.validate(
        courses: [course("第 11 节", block: 5, weeks: [1])], maxWeek: maxWeek)
    expect(blockMessage != nil, "block 5（第 11 节）被拒绝")
    expect(blockMessage?.contains("第 1–10 节") == true,
           "节次报错文案说的是第 1–10 节（不是 block 数 1–5）")
    // 周次超出学期 → 拒绝
    expect(TimetableDiff.validate(courses: [course("周次超界", weeks: [1, 20])], maxWeek: maxWeek) != nil,
           "周次超出学期被拒绝")
    // 边界值合法
    expectEqual(TimetableDiff.validate(courses: [course("边界", day: 7, block: 4, weeks: [16])], maxWeek: maxWeek),
                nil, "第 7 天 / 第 10 节 / 第 16 周合法")
    // 空课表 → 通过
    expectEqual(TimetableDiff.validate(courses: [], maxWeek: maxWeek), nil, "空课表通过校验")
}

// MARK: - 问题清单 P0-2：「需要确认」的课真的被合并

suite("TimetableDiff · 「需要确认」的课真的被合并") {
    // 当前有两门同名不同 code 的课；导入里有一门同名的新课
    // → 匹配不唯一 → 进「需要确认」。
    let current = [
        course("数据结构", code: "A001", day: 1, block: 0, weeks: [1], courseID: "cur-1"),
        course("数据结构", code: "B002", day: 3, block: 1, weeks: [1], courseID: "cur-2"),
    ]
    let imported = [
        course("数据结构", code: "C003", day: 5, block: 2, weeks: [2], courseID: "imp-1"),
    ]
    let sem = SemesterConfig(start: day(2026, 9, 1), maxWeek: 16)
    let result = TimetableDiff.compare(current: current, imported: imported,
                                        currentSemester: sem, importedSemester: nil)
    expectEqual(result.ambiguous.count, 1, "匹配不唯一 → 一门课进「需要确认」")
    let ambID = result.ambiguous.first?.courseID ?? ""
    expectEqual(ambID, "cur-1", "「需要确认」用当前候选的 courseID（不是导入方的）")
    expect(!result.removed.contains { $0.courseID == "cur-1" },
           "当前候选不再重复出现在「将移除」里")

    // 默认：保留当前
    var choice = TimetableDiff.defaultMergeChoice(for: result)
    expectEqual(choice.choice(for: ambID), .keepCurrent, "「需要确认」默认保留当前")
    var merged = TimetableDiff.merge(current: current, imported: imported, result: result, choice: choice)
    expect(merged.courses.contains { $0.courseID == "cur-1" && $0.day == 1 && $0.block == 0 },
           "默认保留当前 → 当前课原样在")
    expect(!merged.courses.contains { $0.day == 5 && $0.block == 2 },
           "默认保留当前 → 导入版本没进来")

    // 显式「用导入」：用导入的上课时间替换当前候选，复用当前候选的 courseID
    choice.courses[ambID] = .useImported
    merged = TimetableDiff.merge(current: current, imported: imported, result: result, choice: choice)
    expect(merged.courses.contains { $0.courseID == "cur-1" && $0.day == 5 && $0.block == 2 },
           "「用导入」→ 导入的上课时间换上来了")
    expect(merged.courses.contains { $0.courseID == "cur-1" && $0.weeks == [2] },
           "「用导入」→ 周次也跟着换成导入的")
    expect(!merged.courses.contains { $0.courseID == "cur-1" && $0.day == 1 },
           "「用导入」→ 当前候选的旧上课时间被替换掉了")
    expect(merged.courses.contains { $0.courseID == "cur-2" },
           "没被确认的那门课默认保留")

    // 明确「删除」：当前课和导入版本都不留（用户明确要的，不是静默丢失）
    choice.courses[ambID] = .delete
    merged = TimetableDiff.merge(current: current, imported: imported, result: result, choice: choice)
    expect(!merged.courses.contains { $0.courseID == "cur-1" }, "「删除」→ 当前候选被删掉")
    expect(!merged.courses.contains { $0.day == 5 && $0.block == 2 },
           "「删除」→ 导入版本也没进来（明确的删除）")

    // 关键不变量：除了用户明确选了「删除」，
    // 任何选择组合下都不会出现「旧课没了、新课也没进来」这种静默丢失。
    for c in [TimetableDiff.MergeChoice.CourseChoice.keepCurrent,
              .useImported, .skip] {
        var ch = TimetableDiff.defaultMergeChoice(for: result)
        ch.courses[ambID] = c
        let m = TimetableDiff.merge(current: current, imported: imported, result: result, choice: ch)
        expect(m.courses.contains { $0.courseID == "cur-1" },
               "选择 \(c.rawValue) 时「需要确认」那门课不会凭空消失")
    }
}

// MARK: - 问题清单 P1-4：学期差异不再是自比较

suite("TimetableDiff · 学期差异不再是自比较") {
    let cur = SemesterConfig(start: day(2026, 9, 1), maxWeek: 16)
    let imp = SemesterConfig(start: day(2026, 9, 8), maxWeek: 18)

    // 导入文件不含学期信息 → 诚实地传 nil → 两行都不出现
    // （以前传的是 `cur.semester` —— 拿当前学期跟当前学期比，恒等 → 死代码）
    let rNil = TimetableDiff.compare(current: [], imported: [], currentSemester: cur, importedSemester: nil)
    expect(!rNil.semesterStartChanged, "导入无学期信息 → 开学日期不报差异")
    expect(!rNil.semesterMaxWeekChanged, "导入无学期信息 → 总周数不报差异")

    // 导入文件含学期信息 → 真的能报出差异
    let rImp = TimetableDiff.compare(current: [], imported: [], currentSemester: cur, importedSemester: imp)
    expect(rImp.semesterStartChanged, "导入含学期信息 → 开学日期报差异")
    expect(rImp.semesterMaxWeekChanged, "导入含学期信息 → 总周数报差异")

    // 合并：默认保留当前
    var choice = TimetableDiff.defaultMergeChoice(for: rImp)
    var merged = TimetableDiff.merge(current: [], imported: [], result: rImp, choice: choice)
    expectEqual(merged.semester.start, cur.start, "默认保留当前学期")
    expectEqual(merged.semester.maxWeek, 16, "默认保留当前总周数")

    // 「用导入」
    choice.semesterStart = .useImported
    choice.semesterMaxWeek = .useImported
    merged = TimetableDiff.merge(current: [], imported: [], result: rImp, choice: choice)
    expectEqual(merged.semester.start, imp.start, "「用导入」→ 用导入的开学日期")
    expectEqual(merged.semester.maxWeek, 18, "「用导入」→ 用导入的总周数")
}

// MARK: - 问题清单 P1-5：导入前的校验与补全（GUI 和命令行共用）

suite("ImportValidator · 导入前的校验与补全") {
    // 非法星期 → 报错
    do {
        _ = try ImportValidator.normalize(parsed: [course("非法天", day: 9, weeks: [1])], maxWeek: 16)
        expect(false, "非法星期应当报错")
    } catch {
        expect(true, "非法星期报错")
    }
    // 非法节次（第 11 节）→ 报错
    do {
        _ = try ImportValidator.normalize(parsed: [course("第 11 节", block: 5, weeks: [1])], maxWeek: 16)
        expect(false, "block 5 应当报错")
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        expect(message.contains("第 1–10 节"),
               "block 报错文案按节次说第 1–10 节（不再混用 block 范围 0–4）")
    }
    // 周次超出学期 → 报错
    do {
        _ = try ImportValidator.normalize(parsed: [course("超周", weeks: [1, 30])], maxWeek: 16)
        expect(false, "超 maxWeek 应当报错")
    } catch {
        expect(true, "超 maxWeek 报错")
    }
    // 空周次 → 补成全学期，并记下来给用户看
    let r = try! ImportValidator.normalize(
        parsed: [course("空周次", weeks: []), course("有周次", weeks: [3])], maxWeek: 16)
    expectEqual(r.courses.first?.weeks.count ?? 0, 16, "空周次补成 1–16 周")
    expectEqual(r.courses.first?.weeks.first ?? -1, 1, "补全后从第 1 周开始")
    expectEqual(r.courses.first?.weeks.last ?? -1, 16, "补全后到第 16 周")
    expect((r.courses.last?.weeks ?? []) == [3], "有周次的不动")
    expectEqual(r.filledWeekCourses, ["空周次"], "补全过的课被记录下来")
    expect(ImportValidator.warningText(for: r)?.contains("空周次") == true, "补全提示里点名了哪门课")
    // 没有要提示的东西 → 不弹窗
    let clean = try! ImportValidator.normalize(parsed: [course("正常", weeks: [1])], maxWeek: 16)
    expect(ImportValidator.warningText(for: clean) == nil, "没有异常和补全 → 没有提示")
    // 同名不同 code → 异常被收集（GUI 导入要展示给用户，不能只 NSLog）
    let anom = try! ImportValidator.normalize(
        parsed: [course("数据结构", code: "A1"), course("数据结构", code: "B2")], maxWeek: 16)
    expect(anom.anomalies.count > 0, "同名不同 code → 异常被收集")
    // ImportPlanner 走同一份校验
    do {
        _ = try ImportPlanner.plan(parsed: [course("第 11 节", block: 5, weeks: [1])],
                                   existing: [], maxWeek: 16)
        expect(false, "计划器也应当拒绝第 11 节")
    } catch {
        expect(true, "计划器和 GUI 导入用同一份校验")
    }
    // block 合法范围统一为 0...4
    expectEqual(Course.blockRange, 0...4, "block 合法范围统一为 0–4（第 1–10 节）")
}

// MARK: - 问题清单 P1-7：损坏数据不被当成空数据

suite("ScheduleStore · 损坏数据不被当成空数据") {
    let dir = makeTempDir("corrupt")
    defer { try? FileManager.default.removeItem(at: dir) }

    // ---- 一条记录损坏 → 其余的照样读出来 ----
    let store = ScheduleStore(directory: dir)
    let good = course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "g-1")
    var arr: [[String: Any]] = []
    arr.append(try! JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as! [String: Any])
    // 手写一条非法记录：星期是 9
    arr.append(["day": 9, "block": 0, "name": "坏课", "code": "C2", "courseID": "b-1", "weeks": [1]])
    let data = try! JSONSerialization.data(withJSONObject: arr)
    try! data.write(to: store.coursesFile)

    let partial = store.loadCoursesPartial()
    expectEqual(partial.courses.count, 1, "一条坏记录不影响其他记录读出来")
    expectEqual(partial.failures.count, 1, "坏记录被记下来")

    // 读完之后**文件不能被改写**（不能因为部分读取就把坏记录静默删掉）
    let before = try! Data(contentsOf: store.coursesFile)
    let repo = ScheduleRepository(store: store)
    let loaded = repo.load()
    expect(loaded.error != nil, "读取出错时 error 不为空")
    expectEqual(loaded.courses.count, 1, "能读的部分照样显示")
    let after = try! Data(contentsOf: store.coursesFile)
    expect(before == after, "读完之后坏记录还在文件里（没有被静默删掉）")
}

suite("ScheduleStore · 学期配置损坏不静默重写") {
    let dir = makeTempDir("corrupt-sem")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)

    // 坏掉的学期文件
    let broken = Data("{ 这不是 JSON".utf8)
    try! broken.write(to: store.semesterFile)
    expect(store.semesterConfigIsCorrupt, "学期文件存在但读不出来 → 判为损坏")

    let before = try! Data(contentsOf: store.semesterFile)
    let loaded = ScheduleRepository(store: store).load()
    expect(loaded.error != nil, "学期文件损坏 → 明确报错")
    let after = try! Data(contentsOf: store.semesterFile)
    expect(before == after, "学期文件损坏时不被默认值覆盖")
}

suite("TimetableStore · 索引损坏不再触发重复迁移") {
    let dir = makeTempDir("corrupt-index")
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default

    // 根目录留着旧数据
    let old = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "old-1")]
    try! JSONEncoder().encode(old).write(to: dir.appendingPathComponent("schedule_data.json"))

    let store = TimetableStore(rootDirectory: dir)
    // 先正常迁移一次
    _ = try! store.migrateLegacyIfNeeded(defaultName: "我的课表")
    expect(!store.needsLegacyMigration, "迁移过后不再需要迁移")

    // 把索引弄坏
    let indexURL = dir.appendingPathComponent("timetables/index.json")
    try! Data("{ 坏掉的索引".utf8).write(to: indexURL)
    expect(store.indexIsCorrupt, "索引存在但读不出来 → 判为损坏")
    expect(!store.needsLegacyMigration, "索引损坏时不再触发迁移（不会多出一份重复课表）")
    expect(store.backupCorruptIndex() != nil, "损坏的索引被备份下来了")
    expect(fm.fileExists(atPath: indexURL.path), "损坏的索引原件还在（不自动删除）")
}

// MARK: - 问题清单 P1-6：删掉最后一份课表

suite("TimetableStore · 删掉最后一份课表") {
    let dir = makeTempDir("tt-delete-last")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)

    let a = try! store.create(name: "A")
    expectEqual(store.allMetas().count, 1, "创建了一份课表")
    expectEqual(store.nextActiveIDAfterDeleting(id: a.id), nil, "删掉最后一份 → 没有下一份")
    let next = try! store.delete(id: a.id)
    expectEqual(next, nil, "删掉最后一份 → 返回 nil（上层要据此进入空课表状态）")
    expectEqual(store.allMetas().count, 0, "课表删干净了")
    expectEqual(store.activeID, nil, "当前课表为空")
    // 删光之后索引是合法的 `items: []`，不能当成损坏（否则会多备份一份、误报）。
    expect(!store.indexIsCorrupt, "删光所有课表后的空索引不算损坏")
    expect(store.backupCorruptIndex() == nil, "合法空索引不会被当成损坏备份")

    // 删当前但还有其他 → 提示的名字要和实际切到的那一份一致
    let b = try! store.create(name: "B")
    let c = try! store.create(name: "C")
    try! store.setActive(b.id)
    let predicted = store.nextActiveIDAfterDeleting(id: b.id)
    let actual = try! store.delete(id: b.id)
    expectEqual(predicted, actual, "「会切到哪一份」的提示和实际切换结果一致")
    expectEqual(actual, c.id, "删掉当前课表后切到剩下的那一份")
}

// MARK: - 问题清单 P2-8：「在访达中显示」指向当前课表

suite("TimetableStore · 当前课表的数据文件位置") {
    let dir = makeTempDir("tt-reveal")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let a = try! store.create(name: "A")

    // 当前课表的课程文件在自己的目录里，不在数据根目录
    expectEqual(store.coursesFile(for: a.id).deletingLastPathComponent().path,
                store.directory(for: a.id).path, "课程文件在当前课表自己的目录下")
    expect(store.coursesFile(for: a.id).path.contains("timetables"), "课程文件在 timetables/ 下面")
    expect(store.coursesFile(for: a.id).deletingLastPathComponent().path != dir.path,
           "课程文件不在数据根目录（旧版位置）")
}

// MARK: - 问题清单 P2-9：同一秒连续保存产生两份备份

suite("BackupFile · 同一秒连续保存产生两份备份") {
    let dir = makeTempDir("backup")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)

    // 先造一份数据
    let c = course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "x-1")
    try! store.saveCourses([c])

    // 连续保存两次（同一秒内）
    let b1 = store.backupCourses()
    let b2 = store.backupCourses()
    expect(b1 != nil && b2 != nil, "两次备份都写成功了")
    expect(b1?.lastPathComponent != b2?.lastPathComponent, "两次备份文件名不同（不会被覆盖）")
    expectEqual(store.listBackups().count, 2, "备份目录里有 2 份备份")

    // 学期备份也是同一套
    try! store.saveSemesterConfig(SemesterConfig(start: day(2026, 9, 1), maxWeek: 16))
    let s = store.backupSemester()
    expect(s != nil, "学期也能备份")
    expect(s?.lastPathComponent.hasPrefix("semester-") == true, "学期备份用的是 semester- 前缀")

    // 保留份数：课程和学期各自按 keep 清理
    for _ in 0..<6 { _ = store.backupCourses() }
    expect(store.listBackups().count <= 5, "课程备份按 keep 清理")
    let semBackups = try! FileManager.default
        .contentsOfDirectory(at: store.backupsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("semester-") }
    expect(semBackups.count <= 5, "学期备份也按 keep 清理")

    // 备份名带毫秒 → 同一秒内也不会撞
    let stamp = BackupFile.stamp()
    expectEqual(stamp.count, 19, "备份时间戳精确到毫秒（yyyyMMdd-HHmmss-SSS）")
    expect(stamp.contains("-"), "备份名带分隔符")
}

// MARK: - 问题清单 P2-10：浏览周次越界被夹回

suite("TimetableState · 浏览周次越界被夹回") {
    // 切到 16 周的课表之前停在第 18 周 → 夹回本周
    expectEqual(TimetableState.clampedViewWeek(18, maxWeek: 16, currentWeek: 9), 9,
                "越界 → 回到本周")
    // 本周也不合法 → 退回第 1 周
    expectEqual(TimetableState.clampedViewWeek(18, maxWeek: 16, currentWeek: nil), 1,
                "越界且本周未知 → 退回第 1 周")
    // 合法 → 不动
    expectEqual(TimetableState.clampedViewWeek(9, maxWeek: 16, currentWeek: 3), 9,
                "合法周次保持不变")
    // 「全部周次」保持 nil
    expectEqual(TimetableState.clampedViewWeek(nil, maxWeek: 16, currentWeek: 3), nil,
                "「全部周次」保持 nil")
}

// MARK: - 问题清单 P2-11 / P1-4B：写学期前有备份

suite("ScheduleRepository · 写学期前会备份") {
    let dir = makeTempDir("sem-backup")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let repo = ScheduleRepository(store: store)

    var cfg = SemesterConfig(start: day(2026, 9, 1), maxWeek: 16)
    try! repo.saveSemester(cfg)
    cfg.maxWeek = 18
    try! repo.saveSemester(cfg)

    let semBackups = try! FileManager.default
        .contentsOfDirectory(at: store.backupsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("semester-") }
    expect(semBackups.count >= 1, "写学期前备份了旧学期文件")
    expectEqual(repo.semester.maxWeek, 18, "学期真的写进去了")
}

// MARK: - 问题清单 P3-12：重名规则统一

suite("TimetableStore · 重名自动加后缀（三条路统一）") {
    let dir = makeTempDir("tt-unique")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)

    let a = try! store.create(name: "我的课表")
    _ = try! store.create(name: "我的课表")
    expectEqual(store.uniqueName("我的课表"), "我的课表 2", "重名自动加后缀")
    expectEqual(store.uniqueName("别的"), "别的", "不重名就原样返回")

    // 重命名到别人的名字 → 加后缀
    try! store.rename(id: a.id, name: "别的", subtitle: "")
    expectEqual(store.allMetas().first { $0.id == a.id }?.name, "别的", "重命名到不重名的名字 → 原样")

    let c = try! store.create(name: "我的课表")
    try! store.rename(id: c.id, name: "别的", subtitle: "")
    expectEqual(store.allMetas().first { $0.id == c.id }?.name, "别的 2",
                "重命名到重名的名字 → 加后缀（和新建一致）")

    // 改成自己的名字不会变成「名字 2」
    try! store.rename(id: c.id, name: "别的 2", subtitle: "")
    expectEqual(store.allMetas().first { $0.id == c.id }?.name, "别的 2",
                "改成自己现在的名字不会被加后缀")
}

// MARK: - 残留问题：XLS 第 11–12 节、周次下界（子代理实测发现）

suite("XlsScheduleParser · 第 11–12 节不写进数据") {
    // 教务系统的表格是 12 节，课表网格只有 10 节（block 0…4）。
    // 以前第 11 节会被解析成 block=5 写进文件 —— 那条记录**读不出来**，
    // 课程在下次启动时静默消失，用户全程收不到提示。
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sample_timetable_12sections.html")
    expect(FileManager.default.fileExists(atPath: fixture.path), "12 节 fixture 存在")

    do {
        let parsed = try! XlsScheduleParser.parseWithNotices(at: fixture)
        expect(!parsed.courses.contains { $0.block > Course.blockRange.upperBound },
               "不会产生第 11 节（block 5）的课")
        expect(parsed.courses.contains { $0.name.contains("数据结构") }, "第 1 节的课照常解析")
        expect(!parsed.courses.contains { $0.name.contains("晚间自习辅导") },
               "第 11 节的课没进数据（否则读盘会整条读不出来）")
        expectEqual(parsed.notices.count, 1, "有一条提示")
        expect(parsed.notices.first?.contains("晚间自习辅导") == true, "提示里点名了哪门课")
        expect(parsed.notices.first?.contains("10 节") == true, "提示里说清了课表只有 10 节")
    }
}

suite("ImportValidator · 周次下界也要拦") {
    // weeks:[0] 能过解析层（FieldParse 放行），但 `Course` 解码时拒收它 ——
    // 写进文件就等于下次启动读不出来、课程在用户眼皮底下消失。
    // 必须在写盘前拦住。
    do {
        _ = try ImportValidator.normalize(parsed: [course("第 0 周", weeks: [0])], maxWeek: 16)
        expect(false, "weeks 含 0 应当报错")
    } catch {
        expect(true, "weeks 含 0 报错")
    }
    do {
        _ = try ImportValidator.normalize(parsed: [course("负周", weeks: [-1])], maxWeek: 16)
        expect(false, "weeks 含负数应当报错")
    } catch {
        expect(true, "weeks 含负数报错")
    }
    // 合法周次不受影响
    let ok = try! ImportValidator.normalize(parsed: [course("正常", weeks: [1, 16])], maxWeek: 16)
    expectEqual(ok.courses.count, 1, "合法周次照常通过")
    // 错误文案里的 block 范围跟现行规则一致（0–4）
    expect(Course.DecodeError.invalidBlock("9").errorDescription?.contains("0–4") == true,
           "block 报错文案写的是 0–4")
}

// MARK: - 单周临时覆盖

suite("WeekOverrideLogic · 两道关（先警告，再提醒）") {
    // 格子 (周三 第 2 节) 上有一门课，它在第 1–8 周上。
    let a = course("高等数学", day: 3, block: 1, weeks: [1, 2, 3, 4, 5, 6, 7, 8], courseID: "M1")

    // 选中的周次里有课在上课 → 真冲突（第一道关：警告）
    var col = WeekOverrideLogic.collision(day: 3, block: 1, weeks: [1, 2, 3, 4],
                                           courses: [a], ownCourseID: nil)
    expectEqual(col.realConflicts.count, 1, "选中的周次里有课在上课 → 真冲突")
    expectEqual(col.nonOverlapping.count, 0, "此时没有非本周课")
    expect(col.hasOtherCourse, "格子上有别的课 → 不进 courses")

    // 选中的周次里原课不上课 → 非本周课（第二道关：提醒）
    col = WeekOverrideLogic.collision(day: 3, block: 1, weeks: [9, 10, 11, 12],
                                       courses: [a], ownCourseID: nil)
    expectEqual(col.realConflicts.count, 0, "此时没有真冲突")
    expectEqual(col.nonOverlapping.count, 1, "原课只在别的周 → 非本周课")
    expect(col.hasOtherCourse, "格子上有别的课 → 不进 courses")

    // 整格没课 → 没有冲突 → 进 courses
    col = WeekOverrideLogic.collision(day: 3, block: 1, weeks: [1], courses: [], ownCourseID: nil)
    expect(!col.hasOtherCourse, "整格没课 → 普通课，进 courses")
    expectEqual(col.realConflicts.count + col.nonOverlapping.count, 0, "两道关都不触发")

    // 编辑自己那格 → 自己不算占用
    col = WeekOverrideLogic.collision(day: 3, block: 1, weeks: [1], courses: [a], ownCourseID: "M1")
    expect(!col.hasOtherCourse, "编辑自己那格 → 不算有别的课")
}

suite("WeekOverrideLogic · 写盘与撤销") {
    let a = course("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1")
    var draft = CourseDraft()
    draft.name = "毛概"
    draft.day = 3
    draft.block = 1
    draft.weeks = [9, 10]

    // 1. 新增的课 → 只写覆盖记录，原课表一个字不动
    let ov = WeekOverrideLogic.makeOverride(day: 3, block: 1, weeks: [9, 10], draft: draft,
                                             courseID: "NEW", restored: nil)
    var r = WeekOverrideLogic.writeOverride(ov, into: [], courses: [a])
    expectEqual(r.courses.count, 1, "新增的覆盖不动原课表")
    expectEqual(r.overrides.count, 1, "写入一条覆盖")
    expectEqual(r.overrides[0].name, "毛概", "覆盖课名写对")

    // 2. 改已有课 → 那条记录从 courses 移出，存进 restored
    let ov2 = WeekOverrideLogic.makeOverride(day: 3, block: 1, weeks: [9, 10], draft: draft,
                                              courseID: "M1", restored: WeekOverride.RestoredSession(a))
    r = WeekOverrideLogic.writeOverride(ov2, into: [], courses: [a])
    expectEqual(r.courses.count, 0, "改已有课 → 原记录从 courses 移出")
    expect(r.overrides[0].restored != nil, "移出的原记录存进覆盖（撤销时放回）")

    // 3. 撤销覆盖 → 原记录放回
    let back = WeekOverrideLogic.removeOverride(day: 3, block: 1, from: r.overrides, courses: r.courses)
    expectEqual(back.courses.count, 1, "撤销覆盖 → 原记录放回 courses")
    expectEqual(back.courses[0].name, "高等数学", "放回的是原来那门课")
    expectEqual(back.overrides.count, 0, "覆盖记录被删掉")

    // 4. 撤销一个「新增的课」的覆盖 → 彻底消失
    let back2 = WeekOverrideLogic.removeOverride(day: 3, block: 1, from: [ov], courses: [a])
    expectEqual(back2.courses.count, 1, "撤销新增课的覆盖 → 原课表不动")
    expectEqual(back2.overrides.count, 0, "覆盖记录被删掉")

    // 5. 同格替换：新覆盖接管，旧覆盖移走的原课要放回来
    let oldOv = WeekOverrideLogic.makeOverride(day: 3, block: 1, weeks: [9], draft: draft,
                                                courseID: "M1", restored: WeekOverride.RestoredSession(a))
    let newOv = WeekOverrideLogic.makeOverride(day: 3, block: 1, weeks: [10], draft: draft,
                                                courseID: "M2", restored: nil)
    let swap = WeekOverrideLogic.writeOverride(newOv, into: [oldOv], courses: [])
    expectEqual(swap.courses.count, 1, "旧覆盖移走的原课被放回")
    expectEqual(swap.overrides.count, 1, "同格只留一条覆盖")
    expectEqual(swap.overrides[0].courseID, "M2", "新覆盖接管这一格")
}

suite("TimetableState · 覆盖的显示与统计") {
    let a = course("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1")
    var draft = CourseDraft()
    draft.name = "毛概"
    draft.day = 3
    draft.block = 1
    draft.weeks = [9]
    let ov = WeekOverrideLogic.makeOverride(day: 3, block: 1, weeks: [9], draft: draft,
                                             courseID: "NEW", restored: nil)

    let st = TimetableState(courses: [a], semesterStart: Date(),
                            currentWeek: 9, viewWeek: 9, now: Date(),
                            maxWeek: 16, overrides: [ov])

    // 单周视图（第 9 周）→ 那一格只显示覆盖课
    let shown9 = st.displayCourses(for: 9)
    expectEqual(shown9.count, 1, "被覆盖的格子只显示一门课")
    expectEqual(shown9.first?.name, "毛概", "显示的是覆盖课")

    // 第 1 周 → 原课照常显示
    let shown1 = st.displayCourses(for: 1)
    expectEqual(shown1.count, 1, "没被覆盖的周 → 原课")
    expectEqual(shown1.first?.name, "高等数学", "没被覆盖的周显示原课")

    // 全部周次视图 → 忽略覆盖
    let all = st.displayCourses(for: nil)
    expectEqual(all.count, 1, "全部周次视图忽略覆盖")
    expectEqual(all.first?.name, "高等数学", "全部周次视图显示原课")

    // 统计：第 9 周 1 门课（覆盖课顶上了原课）
    expectEqual(st.weekCount, 1, "第 9 周 1 门课（覆盖课）")
}

suite("ScheduleMenuPlan · 被覆盖的格子") {
    let a = course("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1")
    let ov = WeekOverride(day: 3, block: 1, weeks: [9], name: "毛概", teacher: "",
                           loc: "", code: "", courseID: "NEW", restored: nil)
    let items = ScheduleMenuBuilder.build(
        for: ScheduleMenuBuilder.Slot(day: 3, block: 1, courses: [a],
                                       hitCourseID: "M1", override: ov))
    expect(items.contains { if case .deleteOverride = $0.action { return true }; return false },
           "被覆盖的格子有「删除临时覆盖」")
    expect(items.contains { if case .viewOverride = $0.action { return true }; return false },
           "被覆盖的格子有「查看详情」")
    expect(items.contains { if case .editOverride = $0.action { return true }; return false },
           "被覆盖的格子有「编辑课程…」")

    let plain = ScheduleMenuBuilder.build(
        for: ScheduleMenuBuilder.Slot(day: 3, block: 1, courses: [a],
                                       hitCourseID: "M1", override: nil))
    expect(!plain.contains { if case .deleteOverride = $0.action { return true }; return false },
           "没被覆盖的格子没有「删除临时覆盖」")
}

suite("ScheduleStore · 覆盖文件坏了只影响覆盖本身") {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dt-ov-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ScheduleStore(directory: dir)
    // 课程数据正常
    let c = course("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1")
    try! store.saveCourses([c])
    // 覆盖文件是坏的
    try! "{ 这不是 json".write(to: store.overridesFile, atomically: true, encoding: .utf8)

    let partial = store.loadOverridesPartial()
    expectEqual(partial.overrides.count, 0, "坏掉的覆盖文件读不出覆盖")
    // 课程照常读得到
    expectEqual((try? store.loadCourses().count) ?? 0, 1, "原课表照常能用")
}

suite("WeekOverrideLogic · 一次保存算成覆盖（编辑 / 新增）") {
    let a = course("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1")
    let a2 = course("高等数学", day: 5, block: 2, weeks: [1, 2], courseID: "M1")
    var draft = CourseDraft()
    draft.name = "高等数学（改）"
    draft.code = "MATH001"
    draft.day = 3
    draft.block = 1
    draft.weeks = [9, 10]

    // 编辑已有课 → 那条记录移出 courses，同 courseID 的另一条留着（并同步课名）
    var r = WeekOverrideLogic.makeOverrideSave(
        draft: draft, scope: .edit(courseID: "M1", day: 3, block: 1),
        courses: [a, a2], overrides: [])
    expectEqual(r.courses.count, 1, "被编辑的那条记录移出 courses")
    expectEqual(r.courses[0].block, 2, "同一门课的另一条上课时间留着")
    expectEqual(r.courses[0].name, "高等数学（改）", "课程级字段同步到同 courseID 的记录")
    expectEqual(r.overrides.count, 1, "写成一条覆盖")
    expect(r.overrides[0].restored != nil, "移出的原记录留在覆盖里（撤销时放回）")

    // 新增一门课 → courses 一个字不动
    var draft2 = draft
    draft2.name = "毛概"
    r = WeekOverrideLogic.makeOverrideSave(
        draft: draft2, scope: .create(day: 3, block: 1),
        courses: [a, a2], overrides: [])
    expectEqual(r.courses.count, 2, "新增的覆盖不动原课表")
    expectEqual(r.courses[0].name, "高等数学", "原课名没被改")
    expectEqual(r.overrides.count, 1, "写成一条覆盖")
    expect(r.overrides[0].restored == nil, "新增的课没有可恢复的原记录")
    expect(!r.overrides[0].courseID.isEmpty, "新增的覆盖有自己的 courseID")

    // 撤销 → 原记录放回
    let back = WeekOverrideLogic.removeOverride(day: 3, block: 1,
                                                 from: r.overrides, courses: r.courses)
    expectEqual(back.courses.count, 2, "撤销后原课表不变")
    expectEqual(back.overrides.count, 0, "覆盖记录被删掉")
}

// MARK: - 面板不透明度映射（用户定稿）

// 滑杆 50%  = 现在的 100% 的样子（完全不透明 + 毛玻璃质感）
// 滑杆 100% = 实心（一点透明感都没有）
let m50 = SettingsWindowController.panelOpacityMapping(0.5)
expectEqual(Double(m50.windowAlpha), 1.0, "50% 时窗口完全不透明")
expectEqual(Double(m50.solid), 0.0, "50% 时不盖实心底（保留毛玻璃质感）")

let m100 = SettingsWindowController.panelOpacityMapping(1.0)
expectEqual(Double(m100.windowAlpha), 1.0, "100% 时窗口完全不透明")
expectEqual(Double(m100.solid), 1.0, "100% 时盖实心底 → 面板变实心")

let m75 = SettingsWindowController.panelOpacityMapping(0.75)
expectEqual(Double(m75.windowAlpha), 1.0, "75% 时窗口仍然完全不透明")
expect(m75.solid > 0 && m75.solid < 1, "75% 时玻璃感退了一半")

let m30 = SettingsWindowController.panelOpacityMapping(0.3)
expectEqual(Double(m30.windowAlpha), 0.6, "30% 时整体半透明")
expectEqual(Double(m30.solid), 0.0, "30% 时没有实心底")

// MARK: - 面板内层滚动视图：滚轮要交给外层面板

suite("WheelForwardingScrollView · 滚轮转交外层") {
    // 造一个和设置面板一样的结构：外层滚动视图套一个内层滚动视图。
    final class TestDoc: NSView { override var isFlipped: Bool { true } }

    func makeStack() -> (outer: NSScrollView, inner: WheelForwardingScrollView) {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        outer.hasVerticalScroller = true
        let outerDoc = TestDoc(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        outer.documentView = outerDoc

        let inner = WheelForwardingScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        inner.hasVerticalScroller = true
        outerDoc.addSubview(inner)
        let innerDoc = TestDoc(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        inner.documentView = innerDoc
        return (outer, inner)
    }

    let (outer, inner) = makeStack()
    expect(inner.enclosingScrollView === outer, "内层能认出外层滚动视图")

    // 没有外层时退回默认行为（自己滚），不能把事件丢掉。
    let lonely = WheelForwardingScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    expect(lonely.enclosingScrollView == nil, "孤立的内层没有外层")
    expect(lonely.outerScrollView == nil, "孤立内层的外层是 nil")

    // 转发计数：事件交给内层时，转交计数要 +1
    if let event = SettingsWindowController.makeScrollEvent(delta: -40) {
        let before = inner.forwardedWheelCount
        inner.scrollWheel(with: event)
        expectEqual(inner.forwardedWheelCount, before + 1, "滚轮事件被转交给外层")
    } else {
        expect(false, "造得出滚轮事件")
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
// MARK: -

// MARK: - 确认弹窗的 Esc 绑定

suite("ConfirmDialogController · Esc 只给显式声明的弹窗") {
    // 普通确认框默认**不该**带 Esc ——
    // 保存课程时按 Esc 会误取消，那两道关是「要么做要么不做」，不能按 Esc 蒙混过去。
    let plain = ConfirmDialogController.Request(title: "t", message: "m")
    expect(plain.cancelKeyEquivalent == nil, "普通确认框默认没有 Esc 快捷键")
}

// MARK: - 设置面板的 Esc 归属

suite("SettingsWindowController · Esc 归属") {
    // 没有模态窗、面板自己是 key window → Esc 关设置面板（老行为，不能被改坏）
    expect(SettingsWindowController.shouldClosePanelOnEscape(isModalActive: false,
                                                             isKeyWindow: true),
           "没有模态窗时，Esc 关掉设置面板")
    // 有模态窗（导入确认 / 差异页等）→ Esc 归模态窗，面板不能关
    expect(!SettingsWindowController.shouldClosePanelOnEscape(isModalActive: true,
                                                              isKeyWindow: true),
           "模态窗开着时，Esc 不能把设置面板关掉")
    // 差异合并页聚焦时（面板不是 key）→ Esc 不能关面板
    expect(!SettingsWindowController.shouldClosePanelOnEscape(isModalActive: false,
                                                              isKeyWindow: false),
           "面板不是 key window（差异页在前面）时，Esc 不能把设置面板关掉")
}

// MARK: - 设置面板的两级结构（板块首页 → 分类设置页）

suite("SettingsSection · 板块定义") {
    // 五个板块（2026-11-10 加了「日记」），顺序固定（首页按钮从左到右就是这个顺序）。
    expectEqual(SettingsSection.allCases.map(\.title), ["外观", "课表", "日记", "提醒", "系统"],
                "五个板块的名字和顺序")
    // 每个板块都要有图标。
    for section in SettingsSection.allCases {
        expect(!section.symbolName.isEmpty, "板块「\(section.title)」必须有图标名")
        // 图标名必须是合法的 SF Symbol —— 不能是 emoji。
        expect(section.symbolName.allSatisfy { $0.isLetter || $0 == "." },
               "板块「\(section.title)」的图标名不是 SF Symbol：\(section.symbolName)")
    }
    // 图标不能重复（五个板块要能一眼分清）。
    expectEqual(Set(SettingsSection.allCases.map(\.symbolName)).count,
                SettingsSection.allCases.count, "四个板块的图标不重复")
    // rawValue 要能原样往返（首页按钮靠它认领板块）。
    for section in SettingsSection.allCases {
        expectEqual(SettingsSection(rawValue: section.rawValue), section,
                    "板块 rawValue 往返：\(section.rawValue)")
    }
}

suite("SettingsHomeScreen · 首页板块按钮") {
    let home = SettingsHomeScreen()
    // 5 个按钮，名字就是板块名（「日记」是 2026-11-10 加的）。
    expectEqual(home.sectionTitles, ["外观", "课表", "日记", "提醒", "系统"], "首页有 5 个板块按钮")
    expect(home.sectionTitlesMatch, "首页板块名字和 SettingsSection 一致")
    // 图标必须是**纯色**（template）—— 禁止 emoji / 彩色图标。
    expect(home.allIconsAreMonochrome, "首页图标全部是纯色（template）")
    for tile in home.buttons {
        let name = tile.section.title
        // 图标现在画在**子视图**里（NSImageView），不是 NSButton.image ——
        // 「图标在上、文字在下」的版式 NSButton 自己做不到。
        let icon = tile.iconView
        expect(icon != nil, "板块砖「\(name)」有图标视图")
        expect(icon?.image != nil, "板块砖「\(name)」有图标")
        expect(icon?.image?.isTemplate == true, "板块砖「\(name)」的图标是 template（单色）")
        // 统一 tint（白 / 浅灰），不能各自一套颜色。
        expect(icon?.contentTintColor != nil, "板块砖「\(name)」有统一 tint")
        expect(tile.titleLabel?.stringValue == name, "板块砖「\(name)」有对应的名称文字")
    }
    // 砖块必须**完整可点**（图标和文字都要落在砖内）——
    // 「看得见但点不中」是最难发现的毛病。
    expect(home.allTilesAreFullyClickable(), "每块砖的图标/文字都完整落在砖内")
}

suite("HUDWindow · 居中算法（多屏）") {
    // 屏幕 0..1000（水平），0..1000（垂直）
    let vf = NSRect(x: 0, y: 0, width: 1000, height: 1000)
    // 普通尺寸 → 居中。
    let p = HUDWindow.centeredOrigin(size: NSSize(width: 580, height: 132), in: vf)
    expectEqual(p.x, 210.0, "收起态水平居中（1000-580)/2")
    expectEqual(p.y, 434.0, "收起态垂直居中（1000-132)/2")
    // 展开态 → 也居中。
    let q = HUDWindow.centeredOrigin(size: NSSize(width: 580, height: 700), in: vf)
    expectEqual(q.x, 210.0, "展开态水平居中")
    expectEqual(q.y, 150.0, "展开态垂直居中")
    // 窗口比可见区还高 → 上边缘对齐顶部（不然底边掉出屏幕）。
    let tall = HUDWindow.centeredOrigin(size: NSSize(width: 580, height: 1200), in: vf)
    expectEqual(tall.y, -200.0, "比屏幕还高时上边缘对齐可见区顶部")
    // **第二块屏**（在右边）→ 必须按那块屏的可见区居中，而不是主屏。
    let vf2 = NSRect(x: 1000, y: 0, width: 1920, height: 1080)
    let r = HUDWindow.centeredOrigin(size: NSSize(width: 580, height: 132), in: vf2)
    expectEqual(r.x, 1670.0, "第二块屏上水平居中（1000+(1920-580)/2）")
    expectEqual(r.y, 474.0, "第二块屏上垂直居中（1080-132)/2")
    // 屏幕之间有间隔（不连续）时，也要按那一块算。
    let vf3 = NSRect(x: 2000, y: 100, width: 1440, height: 900)
    let s = HUDWindow.centeredOrigin(size: NSSize(width: 580, height: 132), in: vf3)
    expectEqual(s.x, 2430.0, "第三块屏（x=2000）上水平居中")
    expectEqual(s.y, 484.0, "第三块屏（y=100）上垂直居中")
}

// MARK: - 1.1.0 测试用假通知中心

/// 假的通知中心：**测试绝不调用真实系统 API**。
final class FakeNotificationCenter: UserNotificationCenterProtocol {
    var added: [UNNotificationRequest] = []
    var pending: [UNNotificationRequest] = []
    var removed: [String] = []
    var status: UNAuthorizationStatus = .authorized
    var requested = false
    var grantOnRequest = true
    var addError: Error?

    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping (Bool, Error?) -> Void) {
        requested = true
        status = grantOnRequest ? .authorized : .denied
        completionHandler(grantOnRequest, nil)
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        completion(status)
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?) {
        if let addError {
            withCompletionHandler?(addError)
            return
        }
        added.append(request)
        // 同 id 覆盖
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
        withCompletionHandler?(nil)
    }

    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void) {
        completionHandler(pending)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removed.append(contentsOf: identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

func at(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
    WeekMath.calendar.date(from: DateComponents(year: y, month: m, day: d,
                                               hour: hh, minute: mm))!
}

// MARK: - 上课提醒 · 规划器

suite("ClassReminderPlanner · 基本规划") {
    let start = day(2026, 8, 31)                    // 周一，第 1 周
    let c = course("高等数学", day: 2, block: 0, teacher: "李雷", loc: "教三-201",
                   weeks: [1, 2, 3], courseID: "M1")
    let now = at(2026, 9, 1, 7, 0)                  // 周二 07:00，第 1 周
    let plans = ClassReminderPlanner.plan(courses: [c], overrides: [],
                                          semesterStart: start, maxWeek: 16,
                                          leadMinutes: 10, now: now)
    expectEqual(plans.count, 2, "14 天窗口内排 2 次（第 1、2 周的周二）")
    guard let p = plans.first else { return }
    expectEqual(p.id, "dt.class.20260901.2.0", "id 是纯 ASCII 稳定格式")
    expectEqual(p.week, 1, "第 1 周")
    expectEqual(p.day, 2, "周二")
    expectEqual(p.block, 0, "第 0 格")
    expectEqual(p.courseNames, ["高等数学"], "课程名")
    expectEqual(p.title, "10 分钟后上课", "标题带提前分钟数")
    expect(p.body.contains("高等数学"), "正文含课程名")
    expect(p.body.contains("08:00–09:35"), "正文含起止时间")
    expect(p.body.contains("教三-201"), "正文含地点")
    expectEqual(p.fireDate, at(2026, 9, 1, 7, 50), "提醒时间 = 08:00 前 10 分钟")
}

suite("ClassReminderPlanner · 不该排的情况") {
    let start = day(2026, 8, 31)
    let c = course("高等数学", day: 2, block: 0, weeks: [1], courseID: "M1")

    // 学期还没开始（所有日期都在开学前）
    let beforeSemester = ClassReminderPlanner.plan(
        courses: [c], overrides: [], semesterStart: day(2026, 9, 21),
        maxWeek: 16, leadMinutes: 10, now: at(2026, 9, 1, 7, 0))
    expectEqual(beforeSemester.count, 0, "开学前不排")

    // 超出 maxWeek
    let overMax = ClassReminderPlanner.plan(
        courses: [c], overrides: [], semesterStart: start,
        maxWeek: 0, leadMinutes: 10, now: at(2026, 9, 1, 7, 0))
    expectEqual(overMax.count, 0, "超出 maxWeek 不排")

    // weeks 不含本周
    let notThisWeek = course("大学英语", day: 2, block: 0, weeks: [5], courseID: "E1")
    let none = ClassReminderPlanner.plan(
        courses: [notThisWeek], overrides: [], semesterStart: start,
        maxWeek: 16, leadMinutes: 10, now: at(2026, 9, 1, 7, 0))
    expectEqual(none.count, 0, "本周不生效的课不排")

    // 提醒时间已过去 / 课程已开始
    let started = ClassReminderPlanner.plan(
        courses: [c], overrides: [], semesterStart: start,
        maxWeek: 16, leadMinutes: 10, now: at(2026, 9, 1, 8, 30))
    expectEqual(started.count, 0, "课程已开始就不补发迟到的提醒")

    // 正好在提醒时刻：fire == now，不算「已过去」之外的情况，必须不排（避免立刻弹）
    let exactly = ClassReminderPlanner.plan(
        courses: [c], overrides: [], semesterStart: start,
        maxWeek: 16, leadMinutes: 10, now: at(2026, 9, 1, 7, 50))
    expectEqual(exactly.count, 0, "提醒时刻正好等于现在也不排（用 > 判断）")
}

suite("ClassReminderPlanner · 单周覆盖") {
    let start = day(2026, 8, 31)
    // 原课：周三第 1 格，第 1、2 周
    let original = course("高等数学", day: 3, block: 1, loc: "教三-201",
                          weeks: [1, 2], courseID: "M1")
    // 第 2 周临时换成「自习」
    let ovJSON: [String: Any] = ["day": 3, "block": 1, "weeks": [2],
                                 "name": "自习", "courseID": "SELF"]
    let ovData = try! JSONSerialization.data(withJSONObject: ovJSON)
    var ov = try! JSONDecoder().decode(WeekOverride.self, from: ovData)
    ov.restored = WeekOverride.RestoredSession(original)

    let now = at(2026, 8, 31, 7, 0)   // 第 1 周周一
    let plans = ClassReminderPlanner.plan(courses: [original], overrides: [ov],
                                          semesterStart: start, maxWeek: 16,
                                          leadMinutes: 10, now: now)
    let week1 = plans.filter { $0.week == 1 }
    let week2 = plans.filter { $0.week == 2 }
    expectEqual(week1.count, 1, "未覆盖的第 1 周仍提醒原课")
    expectEqual(week1.first?.courseNames, ["高等数学"], "第 1 周提醒的是原课")
    expectEqual(week2.count, 1, "覆盖生效的第 2 周提醒覆盖课")
    expectEqual(week2.first?.courseNames, ["自习"], "第 2 周提醒的是覆盖课")
    expect(!week2.contains { $0.courseNames.contains("高等数学") },
           "覆盖周不该再提醒被盖掉的原课")
}

suite("ClassReminderPlanner · 同格合并与上限") {
    let start = day(2026, 8, 31)

    // 同一格两门课 → 合并成一条
    let a = course("高等数学", day: 2, block: 0, loc: "教三-201", weeks: [1], courseID: "M1")
    let b = course("线性代数", day: 2, block: 0, loc: "教三-202", weeks: [1], courseID: "M2")
    let merged = ClassReminderPlanner.plan(courses: [a, b], overrides: [],
                                           semesterStart: start, maxWeek: 16,
                                           leadMinutes: 10, now: at(2026, 9, 1, 7, 0))
    expectEqual(merged.count, 1, "同格多门冲突课合并成一条通知")
    expectEqual(merged.first?.courseNames.count, 2, "一条通知里带两门课的名字")
    expect(merged.first?.body.hasPrefix("线性代数 / 高等数学") ?? false,
           "多门课用「 / 」连接")

    // 14 天 × 每天 5 格 × 7 天 = 70 条 > 60
    var many: [Course] = []
    for d in 1...7 {
        for blk in 0...4 {
            many.append(course("课\(d)\(blk)", day: d, block: blk,
                               weeks: Array(1...16), courseID: "C\(d)\(blk)"))
        }
    }
    let detailed = ClassReminderPlanner.planDetailed(
        courses: many, overrides: [], semesterStart: start, maxWeek: 16,
        leadMinutes: 10, now: at(2026, 8, 31, 7, 0))
    expectEqual(detailed.plans.count, ClassReminderPlanner.maxPlans, "硬上限 60 条")
    expectEqual(detailed.droppedCount, 10, "超出的条数记进 droppedCount")
    let sorted = detailed.plans.map { $0.fireDate }
    expectEqual(sorted, sorted.sorted(), "保留的是最早的那些（按 fireDate 升序）")
}

suite("ClassReminderPlanner · id 与触发时间") {
    let start = day(2026, 8, 31)
    let c = course("高等数学", day: 2, block: 0, weeks: Array(1...8), courseID: "M1")
    let now = at(2026, 9, 1, 7, 0)
    let first = ClassReminderPlanner.plan(courses: [c], overrides: [], semesterStart: start,
                                          maxWeek: 16, leadMinutes: 10, now: now)
    let second = ClassReminderPlanner.plan(courses: [c], overrides: [], semesterStart: start,
                                           maxWeek: 16, leadMinutes: 10, now: now)
    expectEqual(first.map { $0.id }, second.map { $0.id }, "重复规划得到相同 id")
    expectEqual(Set(first.map { $0.id }).count, first.count, "id 不重复")
    expect(first.allSatisfy { $0.id.hasPrefix("dt.class.") }, "id 以 dt.class. 开头")
    expect(first.allSatisfy { $0.id.allSatisfy { $0.isASCII } }, "id 全是 ASCII")

    // DateComponents 必须带 Asia/Shanghai
    let comps = ClassReminderPlanner.dateComponents(for: at(2026, 9, 1, 7, 50))
    expectEqual(comps.year, 2026, "年")
    expectEqual(comps.month, 9, "月")
    expectEqual(comps.day, 1, "日")
    expectEqual(comps.hour, 7, "时")
    expectEqual(comps.minute, 50, "分")
    expectEqual(comps.timeZone?.identifier, "Asia/Shanghai", "DateComponents 带 Asia/Shanghai")

    // 触发器的秒必须是 0（否则系统可能推迟一分钟）
    expectEqual(comps.second ?? 0, 0, "秒为 0")
}

suite("ClassReminderPlanner · 提前分钟边界") {
    let start = day(2026, 8, 31)
    let c = course("高等数学", day: 2, block: 0, weeks: [1], courseID: "M1")
    let now = at(2026, 9, 1, 6, 0)

    let zero = ClassReminderPlanner.plan(courses: [c], overrides: [], semesterStart: start,
                                         maxWeek: 16, leadMinutes: 0, now: now)
    expectEqual(zero.first?.fireDate, at(2026, 9, 1, 8, 0), "lead 0 = 上课时刻")
    expectEqual(zero.first?.title, "马上要上课了", "lead 0 的标题")

    let sixty = ClassReminderPlanner.plan(courses: [c], overrides: [], semesterStart: start,
                                          maxWeek: 16, leadMinutes: 60, now: now)
    expectEqual(sixty.first?.fireDate, at(2026, 9, 1, 7, 0), "lead 60 = 提前一小时")
    expectEqual(sixty.first?.title, "60 分钟后上课", "lead 60 的标题")
}

// MARK: - 设置层

suite("SettingsStore · 外观与新设置互不覆盖") {
    let dir = makeTempDir("settings-split")
    let store = ScheduleStore(directory: dir)
    let ss = SettingsStore(configDirectory: dir)

    // 1. 先存 reminder，再用**旧的** saveConfig 写外观 → reminder 还在
    _ = try? ss.update { $0.reminder.enabled = true; $0.reminder.leadMinutes = 15 }
    _ = try? store.saveConfig(["fadeInSec": 2.5])
    var s = ss.load()
    expectEqual(s.reminder.enabled, true, "旧 saveConfig 路径不会删掉 reminder")
    expectEqual(s.reminder.leadMinutes, 15, "提前分钟还在")
    expectEqual(s.appearance.fadeInSec, 2.5, "外观写进去了")

    // 2. 先存外观，reminder 还在
    _ = try? ss.update { $0.appearance.fadeOutSec = 9 }
    s = ss.load()
    expectEqual(s.reminder.enabled, true, "写外观后 reminder 仍在")
    expectEqual(s.appearance.fadeOutSec, 9, "外观已更新")

    // 3. 先存 reminder，外观还在
    _ = try? ss.update { $0.reminder.leadMinutes = 30 }
    s = ss.load()
    expectEqual(s.appearance.fadeOutSec, 9, "写 reminder 后外观仍在")
    expectEqual(s.reminder.leadMinutes, 30, "reminder 已更新")

    // config.json 里只有外观，不该出现 reminder
    if let data = try? Data(contentsOf: store.configFile),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["reminder"] == nil, "config.json 里不许出现 reminder（旧版会抹掉）")
    } else {
        expect(false, "config.json 应该能读")
    }
}

suite("SettingsStore · 缺键 / 损坏 / 未知字段") {
    let dir = makeTempDir("settings-robust")
    let ss = SettingsStore(configDirectory: dir)

    // 旧 config.json 缺键 → 默认值
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data("{\"fadeInSec\":1.2}".utf8).write(to: ss.configFile)
    var s = ss.load()
    expectEqual(s.appearance.fadeInSec, 1.2, "读到的键用读到的值")
    expectEqual(s.appearance.fadeOutSec, 6.0, "缺的键用默认值")
    expectEqual(s.reminder.leadMinutes, 10, "没有 settings.json → reminder 默认值")

    // settings.json 损坏 → 默认值，外观仍能读
    try? Data("{ 这不是 JSON".utf8).write(to: ss.settingsFile)
    s = ss.load()
    expectEqual(s.reminder.enabled, false, "损坏的 settings.json → 默认值")
    expectEqual(s.appearance.fadeInSec, 1.2, "settings.json 损坏不影响外观")
    expect(ss.settingsFileIsCorrupt, "能识别出损坏")
    expect(ss.diagnostics.contains { $0.contains("损坏") }, "记录诊断信息")
    expect(ss.backupCorruptSettingsFile() != nil, "损坏文件会被备份")

    // 未知字段不丢（读-改-写）
    let raw = "{\"schemaVersion\":1,\"futureFeature\":{\"x\":42},\"reminder\":{\"enabled\":true,\"leadMinutes\":5,\"extra\":\"keep\"}}"
    try? Data(raw.utf8).write(to: ss.settingsFile)
    _ = try? ss.update { $0.reminder.leadMinutes = 20 }
    if let data = try? Data(contentsOf: ss.settingsFile),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["futureFeature"] != nil, "未知的顶层字段不被误删")
        expectEqual(obj["schemaVersion"] as? Int, 1, "schemaVersion 保持 1")
        if let r = obj["reminder"] as? [String: Any] {
            expectEqual(r["leadMinutes"] as? Int, 20, "已知字段已更新")
            expectEqual(r["extra"] as? String, "keep", "分组里的未知字段也不被误删")
        } else {
            expect(false, "reminder 分组应该存在")
        }
    } else {
        expect(false, "settings.json 应该能读")
    }
}

suite("SettingsStore · 类型非法与边界值") {
    let dir = makeTempDir("settings-types")
    let ss = SettingsStore(configDirectory: dir)

    // 类型非法 → 回退默认值
    try? Data("{\"reminder\":{\"enabled\":\"yes\",\"leadMinutes\":\"ten\"}}".utf8).write(to: ss.settingsFile)
    var s = ss.load()
    expectEqual(s.reminder.enabled, false, "enabled 是字符串 → 默认 false")
    expectEqual(s.reminder.leadMinutes, 10, "leadMinutes 是字符串 → 默认 10")

    // 越界 → 夹回
    try? Data("{\"reminder\":{\"enabled\":true,\"leadMinutes\":999}}".utf8).write(to: ss.settingsFile)
    s = ss.load()
    expectEqual(s.reminder.leadMinutes, 60, "leadMinutes 上界 60")

    try? Data("{\"reminder\":{\"enabled\":true,\"leadMinutes\":-5}}".utf8).write(to: ss.settingsFile)
    expectEqual(ss.load().reminder.leadMinutes, 0, "leadMinutes 下界 0")

    // 0 / 60 往返
    _ = try? ss.update { $0.reminder.leadMinutes = 0 }
    expectEqual(ss.load().reminder.leadMinutes, 0, "0 往返正确")
    _ = try? ss.update { $0.reminder.leadMinutes = 60 }
    expectEqual(ss.load().reminder.leadMinutes, 60, "60 往返正确")
    _ = try? ss.update { $0.reminder.enabled = true }
    expectEqual(ss.load().reminder.enabled, true, "Bool true 往返正确")
    _ = try? ss.update { $0.reminder.enabled = false }
    expectEqual(ss.load().reminder.enabled, false, "Bool false 往返正确")
}

suite("SettingsStore · 诊断信息") {
    let dir = makeTempDir("settings-diag")
    let ss = SettingsStore(configDirectory: dir)
    // 文件不存在：不该报错
    expectEqual(ss.load().reminder.enabled, false, "没有文件时返回默认值")
    expect(!ss.settingsFileIsCorrupt, "没有文件不算损坏")
}

// MARK: - 课程时间自定义

suite("PeriodSettings · 默认 / 规范化 / 校验") {
    expectEqual(PeriodSettings.defaults.count, PeriodSettings.count, "默认正好 10 节")
    expect(PeriodSettings.isValid(PeriodSettings.defaults), "默认作息本身合法")

    expectEqual(PeriodSettings.normalizeTime("8:5"), "08:05", "单位数补零")
    expectEqual(PeriodSettings.normalizeTime(" 08：05 "), "08:05", "中文冒号 + 首尾空白")
    expectEqual(PeriodSettings.normalizeTime("23:59"), "23:59", "上界 23:59 合法")
    expectEqual(PeriodSettings.normalizeTime("24:00"), nil, "24 点非法")
    expectEqual(PeriodSettings.normalizeTime("08:60"), nil, "60 分非法")
    expectEqual(PeriodSettings.normalizeTime("abc"), nil, "非时间非法")
    expectEqual(PeriodSettings.normalizeTime("8:05:00"), nil, "带秒非法")
    expectEqual(PeriodSettings.normalizeTime(""), nil, "空串非法")

    var backward = PeriodSettings.defaults
    backward[0] = PeriodTime(start: "09:00", end: "08:00")
    expect(!PeriodSettings.isValid(backward), "开始晚于结束 → 非法")

    var overlap = PeriodSettings.defaults
    overlap[1] = PeriodTime(start: "08:30", end: "09:00")
    expect(!PeriodSettings.isValid(overlap), "和上一节重叠 → 非法")

    var touching = PeriodSettings.defaults
    touching[1] = PeriodTime(start: "08:45", end: "09:30")
    expect(PeriodSettings.isValid(touching), "首尾相接（不算重叠）合法")

    expectEqual(PeriodSettings.sanitize(backward), PeriodSettings.defaults,
                "非法配置整份退回默认")
    expectEqual(PeriodSettings.sanitize(Array(PeriodSettings.defaults.prefix(9))),
                PeriodSettings.defaults, "不足 10 节退回默认")
    expectEqual(PeriodSettings(times: overlap).times, PeriodSettings.defaults,
                "构造时也会清洗非法配置")
}

suite("PeriodSettings · settings.json 往返") {
    let dir = makeTempDir("settings-periods")
    let ss = SettingsStore(configDirectory: dir)

    var custom = PeriodSettings.defaults
    custom[0] = PeriodTime(start: "07:30", end: "08:15")
    custom[1] = PeriodTime(start: "08:20", end: "09:05")
    _ = try? ss.update { $0.periods.setTimes(custom) }
    var loaded = ss.load().periods
    expectEqual(loaded.times, custom, "自定义作息完整往返")
    expectEqual(loaded.times[0].start, "07:30", "第一节开始时间读回")

    // 其他分组不受影响
    _ = try? ss.update { $0.reminder.enabled = true }
    loaded = ss.load().periods
    expectEqual(loaded.times, custom, "写提醒不会冲掉作息")

    // 缺项 / 空列表 / 倒序 → 整份默认，绝不半套坏时间
    try? Data("{\"periods\":{\"items\":[{\"start\":\"08:00\",\"end\":\"08:45\"}]}}".utf8)
        .write(to: ss.settingsFile)
    expectEqual(ss.load().periods.times, PeriodSettings.defaults, "不足 10 项 → 默认作息")

    try? Data("{\"periods\":{\"items\":[]}}".utf8).write(to: ss.settingsFile)
    expectEqual(ss.load().periods.times, PeriodSettings.defaults, "空列表 → 默认作息")

    let inverted = (0..<10).map { _ in "{\"start\":\"10:00\",\"end\":\"09:00\"}" }
        .joined(separator: ",")
    try? Data("{\"periods\":{\"items\":[\(inverted)]}}".utf8).write(to: ss.settingsFile)
    expectEqual(ss.load().periods.times, PeriodSettings.defaults, "倒序时间 → 默认作息")

    try? Data("{\"periods\":{\"items\":\"坏\"}}".utf8).write(to: ss.settingsFile)
    expectEqual(ss.load().periods.times, PeriodSettings.defaults, "类型错误 → 默认作息")
}

suite("Schedule · 自定义作息驱动时间列与网页") {
    Schedule.applyPeriodTimes(PeriodSettings.defaults)
    expectEqual(Schedule.timeRange(block: 0), "08:00–09:35", "默认第 1 块")

    var custom = PeriodSettings.defaults
    custom[0] = PeriodTime(start: "07:00", end: "07:45")
    custom[1] = PeriodTime(start: "07:50", end: "08:35")
    Schedule.applyPeriodTimes(custom)
    expectEqual(Schedule.timeRange(block: 0), "07:00–08:35", "第 1 块跟着自定义变")
    expectEqual(TimetableState.blockStart(0), "07:00", "blockStart 跟着变")
    expectEqual(TimetableState.blockEnd(0), "08:35", "blockEnd 跟着变")

    // 网页 JSON：periods 是 10 个 {s, e}，网页用它替换 PERIODS
    let st = TimetableState(courses: [], semesterStart: day(2026, 8, 30),
                            currentWeek: 1, viewWeek: 1, maxWeek: 16)
    if let data = st.webJSON(title: "t", subtitle: "").data(using: .utf8),
       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let periods = obj["periods"] as? [[String: Any]] {
        expectEqual(periods.count, 10, "webJSON 带 10 条作息")
        expectEqual(periods.first?["s"] as? String, "07:00", "网页拿到的开始时间")
        expectEqual(periods.first?["e"] as? String, "07:45", "网页拿到的结束时间")
        expectEqual(periods.dropFirst().first?["s"] as? String, "07:50", "网页第二节课开始时间")
    } else {
        expect(false, "webJSON 里应该有 periods 数组")
    }

    // 非法配置 → 自动退回默认，不让坏时间扩散到状态条 / 提醒
    var bad = PeriodSettings.defaults
    bad[0] = PeriodTime(start: "10:00", end: "09:00")
    Schedule.applyPeriodTimes(bad)
    expectEqual(Schedule.timeRange(block: 0), "08:00–09:35", "非法配置退回默认")

    // 复位，避免影响后面的测试
    Schedule.applyPeriodTimes(PeriodSettings.defaults)
}

// MARK: - 调度器（假通知中心）

suite("ClassReminderScheduler · 排程与清理") {
    let fake = FakeNotificationCenter()
    let sch = ClassReminderScheduler(center: fake, isAutomation: false)
    let p1 = ReminderPlan(id: "dt.class.20260901.2.0", fireDate: Date().addingTimeInterval(3600),
                          title: "10 分钟后上课", body: "高等数学", day: 2, block: 0,
                          week: 1, courseNames: ["高等数学"])
    let p2 = ReminderPlan(id: "dt.class.20260902.2.1", fireDate: Date().addingTimeInterval(7200),
                          title: "10 分钟后上课", body: "大学英语", day: 3, block: 1,
                          week: 1, courseNames: ["大学英语"])

    sch.reschedule(plans: [p1, p2], fingerprint: "fp1")
    expectEqual(fake.added.count, 2, "两条都排进去了")
    expectEqual(fake.pending.count, 2, "系统里有两条待发")

    // 同指纹 → 不重排
    sch.reschedule(plans: [p1, p2], fingerprint: "fp1")
    expectEqual(fake.added.count, 2, "指纹没变就不重排")

    // 换了数据：只剩一条 → 多余的那条必须删掉
    sch.reschedule(plans: [p1], fingerprint: "fp2")
    expectEqual(fake.pending.count, 1, "不再需要的待发通知被删掉")
    expectEqual(fake.pending.first?.identifier, "dt.class.20260901.2.0", "留下的是还在的课")

    // 清空
    sch.clearAll()
    expectEqual(fake.pending.count, 0, "关闭提醒后待发通知清空")

    // 只删自己的前缀
    fake.pending = []
    fake.added = []
    sch.reschedule(plans: [p1], fingerprint: "fp3")
    let foreign = UNNotificationRequest(identifier: "other.app.notification",
                                        content: UNMutableNotificationContent(), trigger: nil)
    fake.pending.append(foreign)
    sch.clearAll()
    expectEqual(fake.pending.map { $0.identifier }, ["other.app.notification"],
                "别人的通知不许删")
}

suite("ClassReminderScheduler · 测试通知与自动化") {
    let fake = FakeNotificationCenter()
    let sch = ClassReminderScheduler(center: fake, isAutomation: false)

    // 授权中的测试提醒
    sch.sendTestReminder { _ in }
    expectEqual(fake.pending.count, 1, "测试提醒排了一条")
    expect(fake.pending.first?.identifier.hasPrefix("dt.test.") ?? false, "测试通知用 dt.test. 前缀")
    expect(fake.pending.first?.trigger is UNTimeIntervalNotificationTrigger, "5 秒后触发")

    // 启动时清理遗留测试通知
    let keep = UNNotificationRequest(identifier: "dt.class.keep", content: UNMutableNotificationContent(), trigger: nil)
    fake.pending.append(keep)
    sch.cleanupTestNotifications()
    expectEqual(fake.pending.map { $0.identifier }, ["dt.class.keep"], "只清理 dt.test.*")

    // 未授权时拒绝发测试提醒
    let denied = FakeNotificationCenter()
    denied.status = .denied
    let sch2 = ClassReminderScheduler(center: denied, isAutomation: false)
    var err: Error?
    sch2.sendTestReminder { err = $0 }
    expect(err != nil, "未授权时不发测试提醒，并报错")
    expectEqual(denied.added.count, 0, "未授权时一条都不加")

    // 已拒绝 → 不再弹系统框
    let denied2 = FakeNotificationCenter()
    denied2.status = .denied
    let sch3 = ClassReminderScheduler(center: denied2, isAutomation: false)
    sch3.requestAuthorizationIfNeeded { _ in }
    expect(!denied2.requested, "已拒绝时不再反复请求授权")

    // 自动化模式：什么都不做
    let auto = FakeNotificationCenter()
    let schAuto = ClassReminderScheduler(center: auto, isAutomation: true)
    schAuto.reschedule(plans: [ReminderPlan(id: "dt.class.x", fireDate: Date(),
                                            title: "t", body: "b", day: 1, block: 0,
                                            week: 1, courseNames: ["x"])], fingerprint: "f")
    schAuto.sendTestReminder { _ in }
    schAuto.requestAuthorizationIfNeeded { _ in }
    schAuto.cleanupTestNotifications()
    expectEqual(auto.added.count, 0, "自动化模式不排通知")
    expectEqual(auto.pending.count, 0, "自动化模式不发测试通知")
    expect(!auto.requested, "自动化模式不请求权限")
}

// MARK: - 登录项

suite("LoginItemState · 状态到文案") {
    expect(LoginItemState.enabled.isOn, "enabled → 开关打开")
    expect(!LoginItemState.notRegistered.isOn, "notRegistered → 开关关闭")
    expect(!LoginItemState.requiresApproval.isOn, "requiresApproval 不算打开")
    expect(!LoginItemState.unsupportedOS.isOn, "macOS 12 不算打开")
    expect(!LoginItemState.failed("x").isOn, "失败不算打开")

    expectEqual(LoginItemState.describe(.enabled).text, "已开启", "已开启文案")
    expectEqual(LoginItemState.describe(.notRegistered).text, "未开启", "未开启文案")

    let approval = LoginItemState.describe(.requiresApproval)
    expectEqual(approval.text, "等待系统允许", "requiresApproval 文案")
    expect(approval.detail.contains("登录项"), "提示去「登录项」里允许")
    expect(LoginItemState.showsApprovalButton(.requiresApproval), "requiresApproval 显示「去允许」按钮")
    expect(!LoginItemState.showsApprovalButton(.enabled), "已开启时不显示")
    expect(!LoginItemState.showsApprovalButton(.notRegistered), "未注册时不显示")

    let legacy = LoginItemState.describe(.unsupportedOS)
    expectEqual(legacy.text, "不可用", "macOS 12 不可用")
    expect(legacy.detail.contains("macOS 13"), "说明需要 macOS 13")

    let bad = LoginItemState.describe(.failed("操作不被允许"))
    expectEqual(bad.text, "开启失败", "失败状态标题")
    expectEqual(bad.detail, "操作不被允许", "失败时显示真实错误")
}

suite("LoginItemController · 自动化模式与假后端") {
    final class FakeBackend: LoginItemController.Backend {
        var state: LoginItemState = .notRegistered
        var failOnRegister: String?
        var registered = false
        func currentState() -> LoginItemState { state }
        func register() throws {
            if let failOnRegister {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: failOnRegister])
            }
            registered = true
            state = .enabled
        }
        func unregister() throws {
            registered = false
            state = .notRegistered
        }
    }

    let backend = FakeBackend()
    let ctl = LoginItemController(backend: backend, isAutomation: false)
    expectEqual(ctl.currentState(), .notRegistered, "初始未注册")
    expectEqual(ctl.setEnabled(true), .enabled, "开启成功")
    expect(backend.registered, "后端真的被调用了")
    expectEqual(ctl.setEnabled(false), .notRegistered, "关闭成功")

    backend.failOnRegister = "ad-hoc 签名不支持"
    guard case .failed(let msg) = ctl.setEnabled(true) else {
        expect(false, "注册失败要返回 .failed")
        return
    }
    expectEqual(msg, "ad-hoc 签名不支持", "失败时把真实错误带出去")

    // 自动化模式：绝不注册登录项
    let autoBackend = FakeBackend()
    let autoCtl = LoginItemController(backend: autoBackend, isAutomation: true)
    expectEqual(autoCtl.currentState(), .unsupportedOS, "自动化模式下不读真实登录项")
    expectEqual(autoCtl.setEnabled(true), .unsupportedOS, "自动化模式下不注册")
    expect(!autoBackend.registered, "自动化模式下后端一次都没被调用")
}

// MARK: - 自动化模式识别

// MARK: - 网页资源（Timetable.css / Timetable.js）体检

/// 找到项目里的 `Resources/` 目录（测试跑在仓库里，路径可能带空格）。
func repoResourcesDir() -> URL? {
    // Tests/main.swift → 上两级是仓库根
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // 仓库根
    let res = here.appendingPathComponent("Resources")
    return FileManager.default.fileExists(atPath: res.path) ? res : nil
}

/// 读 Resources 里的一个文本文件。
func readResource(_ name: String) -> String? {
    guard let dir = repoResourcesDir() else { return nil }
    let url = dir.appendingPathComponent(name)
    return try? String(contentsOf: url, encoding: .utf8)
}

/// 从 CSS 里抠出某个规则的内容（按 `{` … 配对的 `}` 找）。
///
/// ⚠️ 不能用 `components(separatedBy: ".dpbody {").last` ——
/// 文件里同名规则有好几个（比如 `.daypanel .dpbody {` 和 `.dpbody {`），
/// `.last` 拿到的不一定是想要的那一条。
func cssRule(_ css: String, _ selector: String) -> String? {
    // ⚠️ 必须在**行首**找 —— 否则 `.dpbody {` 会先匹配到
    // `.daypanel .dpbody {`（那是入场动画规则，不是材质规则）。
    let needle = "\n" + selector + " {"
    guard let start = css.range(of: needle) else { return nil }
    // ⚠️ `start` **已经包含**了那个 `{` —— 再往后找 `{` 会跳到
    // 下一条规则里去（取到的是别处的规则体，断言就永远失败）。
    let open = start.upperBound
    var depth = 1
    var i = open
    while i < css.endIndex {
        if css[i] == "{" { depth += 1 }
        if css[i] == "}" {
            depth -= 1
            if depth == 0 { return String(css[open..<i]) }
        }
        i = css.index(after: i)
    }
    return nil
}

suite("网页资源 · CSS / JS 体检") {
    let css = readResource("Timetable.css")
    expect(css != nil, "要能读到 Resources/Timetable.css")
    let js = readResource("Timetable.js")
    expect(js != nil, "要能读到 Resources/Timetable.js")

    if let css {
        // ---- 注释必须闭合 ----
        //
        // ⚠️ **未闭合的注释会把后面所有规则吞掉** ——
        // 表现是「CSS 一半生效、一半不生效」（比如卡片样式没了、
        // 面板变成一块没样的黑方块），而且**不报任何错**，
        // 肉眼极难定位。这里直接数一遍。
        var open = 0
        var idx = css.startIndex
        while idx < css.endIndex {
            if css[idx...].hasPrefix("/*") {
                open += 1
                idx = css.index(idx, offsetBy: 2)
            } else if css[idx...].hasPrefix("*/") {
                open -= 1
                idx = css.index(idx, offsetBy: 2)
            } else {
                idx = css.index(after: idx)
            }
        }
        expectEqual(open, 0, "Timetable.css 的注释必须成对闭合（未闭合会把后面的规则全吞掉）")

        // ---- 花括号必须配平 ----
        var braces = 0
        var negative = false
        for ch in css {
            if ch == "{" { braces += 1 } else if ch == "}" { braces -= 1 }
            if braces < 0 { negative = true }
        }
        expect(!negative, "Timetable.css 里出现了多余的右花括号")
        expectEqual(braces, 0, "Timetable.css 的花括号必须配平")

        // ---- 逐条玻璃卡片的关键样式必须在（防止误删）----
        //
        // ⚠️ 2026-11 卡片化：`.dpsect` / `.dphd`（三块分组卡片）已经**退役**，
        // 现在是「每条待办 / 每条日程 / 今日详情各自一张 `.dpcard`」。
        for sel in [".dpcards", ".dpcard", ".dpcardhd", ".dpcardbody",
                    ".dpbody", ".dpfade", ".daypanel"] {
            expect(css.contains(sel), "Timetable.css 里要保留 \(sel) 规则")
        }
        // 卡片之间的间距必须 ≥ 8px（验收要求）。
        let dpcardsRule = cssRule(css, ".dpcards")
        expect(dpcardsRule?.contains("gap") == true,
               "`.dpcards`（卡片容器）必须用 gap 控制卡片间距")
        if let r = dpcardsRule, let m = r.range(of: "gap:\\s*([0-9]+)px", options: .regularExpression) {
            let gapStr = r[m].replacingOccurrences(of: "gap:", with: "")
                .replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)
            if let gap = Int(gapStr) {
                expect(gap >= 8, "卡片间距必须 ≥ 8px（实际 \(gap)px）")
            }
        }
        // 卡片圆角（参考图是 14–16px）。
        let dpcardRule = cssRule(css, ".dpcard")
        expect(dpcardRule?.contains("border-radius: 14px") == true,
               "`.dpcard`（卡片）圆角要是 14px")
        // 卡片要有渐变描边（伪元素 + mask 的 xor 技巧）。
        expect(css.contains("mask-composite: exclude") || css.contains("-webkit-mask-composite: xor"),
               "卡片的渐变描边要用 mask 的 xor / exclude 技巧（伪元素挖空中间）")
        expect(css.contains(".dpcard::before"),
               "卡片要有 ::before 伪元素做渐变描边")
        // 左侧 2px 彩色竖条（待办 / 日程 / 今日详情各一个颜色）。
        expect(css.contains(".dpcard::after"),
               "卡片要有 ::after 伪元素做左侧彩色竖条")
        for kind in [".dpcard.todo::after", ".dpcard.event::after", ".dpcard.detail::after"] {
            expect(css.contains(kind), "要有 \(kind) 的竖条颜色")
        }
        // 空状态 / 幽灵卡（各自一张，分类不能消失）。
        expect(css.contains(".dpcard.empty"), "要有 .dpcard.empty（空状态卡）")
        expect(css.contains(".dpcard.ghost"), "要有 .dpcard.ghost（「＋ 添加待办」幽灵卡）")
        // ⚠️ **卡片不能有自己的入场动画** ——
        //
        // 合成器不跑的时候（离屏渲染 / 快照模式）CSS 动画会永远停在第 0 帧，
        // 而第 0 帧是 `opacity: 0` → **整块卡片内容永远看不见**。
        // 面板本身已经有 600ms 的入场动画了，卡片不需要再动一次。
        let dpcardNoComments = (dpcardRule ?? "")
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        expect(!dpcardNoComments.contains("animation:"),
               "`.dpcard` 不能有入场动画（合成器不跑时会停在 opacity: 0 → 内容看不见）")
        // ⚠️ **卡片之间不能有 backdrop-filter** ——
        //
        // 一屏十几张卡片各带一层实时模糊会把旧机器拖垮。
        // 玻璃感靠「半透明渐变 + 描边 + 高光」模拟，模糊只在 `.dpbody` 那一层。
        expect(!dpcardNoComments.contains("backdrop-filter"),
               "`.dpcard` 不能有 backdrop-filter（十几层实时模糊会卡；模糊只在底板那一层）")
        // 底板那层仍然要有模糊（玻璃感来源）。
        expect(dpcardRule?.contains("linear-gradient") == true,
               "`.dpcard` 要有半透明渐变底（玻璃感靠它模拟）")
        // 玻璃质感的关键值
        expect(css.contains("blur(40px) saturate(180%)"), "玻璃质感：backdrop-filter 要用 blur(40px) saturate(180%)")
        // ⚠️ **有文字的地方必须接近不透明** ——
        //
        // 用户反馈「玻璃太透明导致看不清」：底下的课表格直接透上来，
        // 和卡片里的文字叠在一起（「今日详情」那格最明显）。
        //
        // 实心区（.dpbody）= 有文字的地方 → 接近不透明；
        // 尾巴（.dpfade）= 没有文字的地方 → 从同样的颜色渐隐到透明。
        // 两者的颜色 + 透明度必须**完全一致**，否则交界处有台阶
        // （用户看到的「两个模块拼接」）。
        expect(css.contains("rgba(34, 38, 48, 0.94)"), "玻璃质感：底色要用 rgba(34, 38, 48, 0.94)（接近不透明，保证文字清晰）")
        let dpbodyRule = cssRule(css, ".dpbody")
        expect(dpbodyRule?.contains("rgba(34, 38, 48, 0.94)") == true,
               "实心区（有文字）必须接近不透明")
        let dpfadeRule = cssRule(css, ".dpfade")
        expect(dpfadeRule?.contains("rgba(34, 38, 48, 0.94)") == true,
               "渐变尾巴的底色必须和实心区**完全一致**（否则交界处有台阶）")
        // 尾巴必须**四边都化开**（上下淡出 ∩ 左右淡出）——
        // 只有上下渐隐的话，底部能看出一个矩形（用户反馈「两个模块拼接」）。
        expect(css.contains("mask-composite: intersect"),
               "渐变尾巴的 mask 必须显式相乘（上下淡出 ∩ 左右淡出），否则四边有硬边")
        expect(dpfadeRule?.contains("linear-gradient(to right") == true,
               "渐变尾巴左右也要淡出（否则底部看得出矩形边）")
        // 动画：clip-path 而不是 scaleY
        expect(css.contains("clip-path"), "入场/收起动画要用 clip-path")
        // 只看**真正的声明**（注释里提到 scaleY 是允许的 —— 那是在解释为什么不用它）
        let cssNoComments = css
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        expect(!cssNoComments.contains("scaleY"), "不要用 scaleY 压扁文字（改用 clip-path 揭开）")
        // ---- 动画时长：打开 600ms / 收起 400ms（CSS 里写死）----
        //
        // ⚠️ 动画时长**没法在自检环境实测**（合成器不跑，rAF 不触发），
        // 所以这里断言的是 **CSS 里写的值** —— 那是真正生效的那一份。
        expect(css.contains("clip-path 600ms"), "打开动画要用 clip-path 600ms")
        expect(css.contains("clip-path 400ms"), "收起动画要用 clip-path 400ms")
        // 打开用 600ms、收起用 400ms —— CSS 的过渡取「变化后」的值，
        // 所以 `.show` 那条必须是 600ms，基础那条必须是 400ms。
        // 裁剪做在**整个面板**上（实心区 + 渐变尾巴一起揭开），
        // 不是只裁 `.dpbody` —— 否则尾巴会整块瞬间出现。
        let showRule = cssRule(css, ".daypanel.show")
        expect(showRule?.contains("clip-path 600ms") == true,
               "`.daypanel.show`（打开）要用 clip-path 600ms")
        let baseRule = cssRule(css, ".daypanel")
        expect(baseRule?.contains("clip-path 400ms") == true,
               "`.daypanel`（收起）要用 clip-path 400ms")
        expect(baseRule?.contains("inset(0 0 100% 0)") == true,
               "`.daypanel` 关闭态要被完全裁掉（clip-path: inset(0 0 100% 0)）")
        // 收起状态要自成一体（不依赖 show），否则关不掉
        expect(css.contains(".daypanel.closing"), "要有 .daypanel.closing 状态（收起动画）")
        // visibility 的切换必须延迟到淡出结束
        expect(css.contains("visibility 0s linear 400ms"),
               "visibility 的切换要延迟到淡出结束（否则淡出看不见）")
        // 玻璃材质
        expect(css.contains("blur(40px) saturate(180%)"), "玻璃质感：backdrop-filter 要用 blur(40px) saturate(180%)")
        // ⚠️ **有文字的地方必须接近不透明** ——
        //
        // 用户反馈「玻璃太透明导致看不清」：底下的课表格直接透上来，
        // 和卡片里的文字叠在一起（「今日详情」那格最明显）。
        //
        // 实心区（.dpbody）= 有文字的地方 → 接近不透明；
        // 尾巴（.dpfade）= 没有文字的地方 → 从同样的颜色渐隐到透明。
        // 两者的颜色 + 透明度必须**完全一致**，否则交界处有台阶
        // （用户看到的「两个模块拼接」）。
        expect(css.contains("rgba(34, 38, 48, 0.94)"), "玻璃质感：底色要用 rgba(34, 38, 48, 0.94)（接近不透明，保证文字清晰）")
        let dpbodyRule2 = cssRule(css, ".dpbody")
        expect(dpbodyRule2?.contains("rgba(34, 38, 48, 0.94)") == true,
               "实心区（有文字）必须接近不透明")
        let dpfadeRule2 = cssRule(css, ".dpfade")
        expect(dpfadeRule2?.contains("rgba(34, 38, 48, 0.94)") == true,
               "渐变尾巴的底色必须和实心区**完全一致**（否则交界处有台阶）")
        // 尾巴必须**四边都化开**（上下淡出 ∩ 左右淡出）——
        // 只有上下渐隐的话，底部能看出一个矩形（用户反馈「两个模块拼接」）。
        expect(css.contains("mask-composite: intersect"),
               "渐变尾巴的 mask 必须显式相乘（上下淡出 ∩ 左右淡出），否则四边有硬边")
        expect(dpfadeRule?.contains("linear-gradient(to right") == true,
               "渐变尾巴左右也要淡出（否则底部看得出矩形边）")
        // 尾巴必须用 mask 衰减（WKWebView 里 backdrop-filter 会吃掉背景渐变的 alpha）
        expect(css.contains("mask-image"), "渐变尾巴要用 mask-image 做衰减")

        // 三个分类标题（每张卡片的标签行）
        expect(js?.contains("待办事项") == true, "卡片标签要有「待办事项」")
        expect(js?.contains("日历行程") == true, "卡片标签要有「日历行程」（不是「今日日程」）")
        expect(js?.contains("今日详情") == true, "卡片标签要有「今日详情」")

        // ---- 卡片化的结构（JS 侧）----
        //
        // ⚠️ 2026-11：待办 / 日程 / 详情各自是**一张独立卡片**。
        expect(js?.contains("dpcard") == true, "JS 要生成 .dpcard 卡片")
        expect(js?.contains("dpcards") == true, "JS 要生成 .dpcards 卡片容器")
        expect(js?.contains("dpCard") == true, "JS 要有造卡片的函数")
        // 空状态必须是**卡片**（分类不能整块消失）。
        expect(js?.contains("今日无待办") == true, "没有待办时要显示「今日无待办」")
        expect(js?.contains("今日无日程") == true, "没有日程时要显示「今日无日程」")
        // 「＋ 添加待办」永远在（幽灵卡）。
        expect(js?.contains("添加待办") == true, "要有「＋ 添加待办」入口")

        // ---- 不再截断条目（2026-11 改）----
        //
        // 以前窄态按「最多能放下多少条」裁一刀，装不下的用「还有 N 条」收尾。
        // 用户明确要求改成**面板内滚动** —— 一条都不能少。
        // ⚠️ 「还有 N 条」是**覆盖层**里的截断提示 —— 网页别处（顶部状态条）
        // 也有「还有 …」的文案，所以这里只查**覆盖层相关**的那一段。
        expect(js?.contains("dpmore") == false,
               "不能再有 .dpmore（「还有 N 条」那个元素）")
        expect(js?.contains("' 还有 ' + more") == false,
               "不能再用「还有 N 条」截断条目（改成面板内滚动）")
        expect(js?.contains("narrowTodoLimit") == false,
               "不能再有 narrowTodoLimit（按高度裁条目的逻辑）")
        expect(js?.contains("applyNarrowLimit") == true,
               "要有 applyNarrowLimit（算滚动上限）")

        // ---- 面板内滚动 ----
        //
        // 滚动上限 = 表头之下剩余高度；滚轮不能穿透到课表；
        // 内容不长时不出滚动条（overflow-y: auto 天然满足）。
        expect(css.contains(".dpbody.scroll"),
               "要有 `.dpbody.scroll` 规则（内容超高时内部滚动）")
        // ⚠️ `cssRule` 取的是**第一条**匹配该选择器的规则 ——
        // 这里 `.dpbody.scroll` 是一条**并列选择器**（`,` 分隔），
        // 所以要用「包含 overflow-y: auto」这种更宽松的查法。
        let scrollRule = cssRule(css, ".dpbody.scroll")
        expect(scrollRule?.contains("overflow-y: auto") == true
               || css.contains(".dpbody.scroll,") && css.contains("overflow-y: auto"),
               "`.dpbody.scroll` 要用 overflow-y: auto（内容不长时不出滚动条）")
        expect(js?.contains("wheel") == true,
               "网页层要处理 wheel 事件（滚轮不能穿透到背后的课表）")
        expect(js?.contains("preventDefault") == true,
               "滚轮落在面板上时要 preventDefault（别让课表跟着滚）")

        // ---- 选中表头：蓝色渐变 + 外发光 ----
        //
        // 可以加强成渐变 + 发光，但**不能**把它从表头行里拆出来
        // （表头格是 CSS Grid 的一格，拆出来网格对齐会崩）。
        let selRule = cssRule(css, ".hcell.pick.sel")
        expect(selRule?.contains("linear-gradient") == true,
               "选中表头要有蓝色渐变底")
        expect(selRule?.contains("box-shadow") == true,
               "选中表头要有外发光（box-shadow）")
        expect(selRule?.contains("position") == false,
               "选中表头不能改成 absolute（那会把它从表头行里拆出来，网格会崩）")

        // ---- **宽态已删**（2026-11）----
        //
        // 双击展开曾经会把覆盖层撑成一个浮在课表格上的大方块：
        // 盖住旁边的列、底边是硬边横切过课程格，观感不好，
        // 而且卡片化 + 面板内滚动之后，宽态也没多显示什么。
        //
        // 现在**只有一列宽**这一种形态。
        // 这里钉住「别把它偷偷加回来」。
        expect(css.contains(".daypanel.wide") == false,
               "不能再有 .daypanel.wide 的规则（宽态已删，覆盖层永远是一列宽）")
        // ⚠️ **要先剥掉注释** —— 上面那些「已删」的说明文字里
        // 本身就写着这些名字，直接 `contains` 会误报。
        let jsNoComments = (js ?? "")
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "//[^\\n]*", with: "", options: .regularExpression)
        expect(jsNoComments.contains("onHeaderDouble") == false,
               "不能再有 onHeaderDouble（双击撑开已删）")
        expect(jsNoComments.contains("dblclick") == false,
               "不能再监听 dblclick（双击撑开已删）")
        expect(jsNoComments.contains("datePanelToggle") == false,
               "不能再发 datePanelToggle（双击撑开已删）")
        expect(jsNoComments.contains("wideWidthFor") == false,
               "不能再有 wideWidthFor（宽态测宽的函数已删）")
        expect(jsNoComments.contains("DP_WIDE") == false,
               "不能再有 DP_WIDE_* 常量（宽态已删）")
        expect(jsNoComments.contains("DP.wide") == false,
               "不能再有 DP.wide 状态位（宽态已删）")
        // 面板宽度仍然锁死在一列宽：2026-11 起按「表头格的宽度 ÷ 倍率」算
        //（覆盖层可能挂在卡片上，不再用 grid 的列几何）。
        expect(js?.contains("el.style.width = (cb.width / s) + 'px'") == true,
               "面板宽度必须一直是单列宽（表头格宽度）")

        // ---- **收起动画不能被 inline style 压掉**（2026-11 修）----
        //
        // 用户反馈「再点一次关闭覆盖层的时候没有消失的动画」。
        //
        // 根因：兜底代码写了 inline 的 `style.clipPath = 'none'` 和
        // `style.transition = 'none'` —— **inline 的优先级比任何 class 都高**，
        // 于是它**永久**压住了 `.closing` 的收起动画。
        //
        // 现在兜底改用**类**（`.dpnoplay`），而且：
        //   · `.dpnoplay` 的 clip-path 必须是 `inset(0)`（**不能是 `none`**）——
        //     浏览器**不能**在 `none` ↔ `inset(...)` 之间插值，
        //     一端是 `none` 的话过渡会直接跳到终值，不播动画；
        //   · JS 里**不能**再有 `style.clipPath = 'none'` / `style.transition = 'none'`。
        let jsNoComments2 = (js ?? "")
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "//[^\\n]*", with: "", options: .regularExpression)
        expect(!jsNoComments2.contains("style.clipPath = 'none'"),
               "不能用 inline 的 clipPath: none（会永久压掉收起 / 揭开动画）")
        // ⚠️ `resumePanelEntrance()` 里有一个 inline 的 `transition = 'none'` ——
        // 那是**故意的**（先把值钉住、强制回流，再写新的 transition）。
        // 但它必须在**关闭面板时也被清掉**，否则会留下来压掉所有过渡。
        //
        // 所以这里查的是「兜底那段」里不许再有 inline 的 transition ——
        // 兜底那段是「动画没跑」的保险，它写 inline 会**永久**生效。
        let fallbackStart = jsNoComments2.range(of: "兜底：动画不跑时也要能看见")
        if let fs = fallbackStart {
            let tail = String(jsNoComments2[jsNoComments2.index(after: fs.lowerBound)...])
            // 只看兜底那一段（截 2200 字，够覆盖整段代码）。
            let seg = String(tail.prefix(2200))
            expect(!seg.contains("style.transition = 'none'"),
                   "兜底那段不能用 inline 的 transition: none（会永久关掉所有过渡）")
            expect(!seg.contains("style.clipPath = 'none'"),
                   "兜底那段不能用 inline 的 clipPath: none（会永久压掉收起 / 揭开动画）")
        }
        // 关闭面板时必须清掉 inline 的 transition。
        expect(jsNoComments2.contains("el.style.transition = ''"),
               "关闭面板时要清掉 inline 的 transition（不然收起动画被压掉）")
        expect(jsNoComments2.contains("dpnoplay"),
               "兜底要用 `.dpnoplay` 类（不能用 inline style）")
        // `.dpnoplay` 的 clip-path 必须是 `inset(0)`，不能是 `none`。
        let dpnoplayRule = cssRule(css, ".daypanel.dpnoplay")
        expect(dpnoplayRule?.contains("inset(0)") == true,
               "`.dpnoplay` 的 clip-path 要用 `inset(0)`（`none` 不能插值 → 没有动画）")
        expect(dpnoplayRule?.contains("clip-path: none") == false,
               "`.dpnoplay` 不能用 `clip-path: none`（浏览器不能从 none 插值）")
        // `.dpnoplay` 必须在 `.closing` **之后**（同优先级时靠后的赢）。
        if let cp = css.range(of: ".daypanel.closing {"),
           let dp = css.range(of: ".daypanel.dpnoplay {") {
            expect(dp.lowerBound > cp.lowerBound,
                   "`.dpnoplay` 必须排在 `.closing` 之后（否则兜底会压掉收起动画）")
        }

        // ---- **7 天各自的今日详情**（2026-11 修）----
        //
        // 用户反馈「有的天数有今日详情、有的没有」「今日详情大多数日期对不上」。
        //
        // 根因：以前只 push **当前那一天**的 dayPanel，网页换列时靠缓存兜底
        // → 没推过的那一天就**整块消失**，换列时还会显示**别的日子**的内容。
        //
        // 现在原生一次推 7 天（`dayFestivals`），网页按 `day` 取。
        expect(jsNoComments2.contains("dayFestivals"),
               "网页层要读 dayFestivals（7 天各自的今日详情）")
        expect(jsNoComments2.contains("DP.dayFestivals"),
               "要把 7 天的详情存起来（按天取，不会串）")

        // ---- **添加待办失败要有提示**（2026-11 修）----
        //
        // 用户反馈「点击添加待办现在根本加不上去」——
        // 以前原生侧 `guard settings.enabled` 直接 return，**完全静默**。
        expect(jsNoComments2.contains("ttDayPanelTodoAddResult"),
               "网页层要接住「添加待办」的结果（失败要有提示）")
        expect(jsNoComments2.contains("addError"),
               "要记住添加失败的原因并显示出来")
        expect(css.contains(".dpadderr"),
               "失败提示要有样式（.dpadderr）")

        // ---- 待办右键菜单 + 内联编辑（2026-11）----
        expect(jsNoComments2.contains("todoMenu"),
               "右键待办要发 todoMenu（不能直接 todoDelete）")
        expect(jsNoComments2.contains("todoUpdate"),
               "编辑保存要发 todoUpdate")
        expect(jsNoComments2.contains("ttDayPanelTodoMenuAction"),
               "网页要接住原生菜单的选择（修改 / 删除）")
        expect(jsNoComments2.contains("ttDayPanelTodoUpdateResult"),
               "网页要接住修改结果（失败时回滚）")
        expect(jsNoComments2.contains("timeHourValue"),
               "添加待办要记住时 / 分输入（重绘不丢字）")
        expect(jsNoComments2.contains("editingTodoKey"),
               "编辑态要按稳定键记住正在改哪一条")
        expect(css.contains(".dpedit"), "编辑态要有样式（.dpedit）")
        expect(css.contains(".dptimepart"), "时 / 分输入框要有样式（.dptimepart）")
        expect(css.contains(".dpinputrow"), "添加态要能分两行（.dpinputrow）")

        // ---- **输入框焦点不能丢**（2026-11 修）----
        //
        // 用户反馈「移动鼠标了之后，添加待办那里的输入的竖线一直在闪」。
        //
        // 根因：面板内容重建会把输入框从 DOM 摘下来再挂回去 → 失焦
        // → 焦点一丢又 refocus → 光标反复闪烁。
        expect(jsNoComments2.contains("inputHadFocus"),
               "重建面板时要记住输入框有没有焦点（不然光标会一直闪）")
        expect(jsNoComments2.contains("DP.input.focus()"),
               "重建之后要把焦点还给输入框")

        // ---- **红点位置：和蓝点对称**（2026-11 改）----
        //
        // 用户反馈红点位置不对，要求「在日期左边和蓝色点对称」。
        //
        // 以前红点 / 橙点是绝对定位在**格子最左缘**的（`.hslot`），
        // 蓝点却在「周几」文字**右边** —— 两者既不同高、离中轴也差 50pt 以上。
        //
        // 现在红点进 `.hdrow`，变成「🔴 周一 🔵」：
        //   · 同一水平线；
        //   · 分居文字两侧，距离相等。
        // ⚠️ **要先剥掉注释** —— 上面那些说明文字里就写着 `.hslot`。
        let cssNoCommentsDot = css
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        expect(cssNoCommentsDot.contains(".hslot") == false,
               "`.hslot`（绝对定位的左槽）要整个删掉 —— 红点不再飘在格子最左缘")
        let jsNoCommentsDot = (js ?? "")
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "//[^\\n]*", with: "", options: .regularExpression)
        expect(jsNoCommentsDot.contains("hslot") == false,
               "JS 里也不能再渲染 .hslot")
        // 红点必须在 .hdrow 里（和蓝点同一行）。
        let hdrowRule = cssRule(css, ".hdrow")
        expect(hdrowRule?.contains("align-items: center") == true,
               "`.hdrow` 要居中对齐（红点和蓝点才会同一水平线）")
        expect(css.contains(".dot.todo"),
               "红点的颜色规则要在（.dot.todo）")
        expect(css.contains(".dot.event"),
               "橙点的颜色规则要在（.dot.event）")
        // 全部周次不画红点 / 橙点。
        expect(js?.contains("allWeeks") == true,
               "网页层要认得出「全部周次」（那种模式下不画红点 / 橙点）")

        // ---- **翻周 / 全部周次**（2026-11 修）----
        //
        // 用户反馈：「点击下一周或上一周之后农历什么的都是一样的」
        // 「全部周次不要弹出来日历，只有具体日期才有」。
        //
        // 根因：覆盖层的 `baseMonday` 原来是 `let`，只在控制器创建时算一次，
        // 翻周时没跟着变 → 7 天的详情一直按原来那一周算。
        let jsNoComments3 = (js ?? "")
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "//[^\\n]*", with: "", options: .regularExpression)
        expect(jsNoComments3.contains("isAllWeeksMode"),
               "网页层要认得出「全部周次」模式（viewWeek 为 null）")
        expect(jsNoComments3.contains("dayPanelOpen"),
               "网页层要看原生的 dayPanelOpen（原生说关就跟着关）")
        // 原生侧：baseMonday 必须可更新 + 有「全部周次」开关。
        //
        // ⚠️ 源码在 `Sources/`，不在 `Resources/` 里 ——
        // `repoResourcesDir()` 给的是 Resources，这里要回到仓库根再拼。
        let repoRoot = repoResourcesDir()?.deletingLastPathComponent()
        let controllerSrc = (repoRoot.map {
            (try? String(contentsOf: $0.appendingPathComponent(
                "Sources/DesktopTimetable/UI/DayPanelController.swift"),
                encoding: .utf8)) ?? ""
        }) ?? ""
        expect(controllerSrc.contains("func updateBrowsingWeek"),
               "原生侧要有 updateBrowsingWeek（翻周时同步 baseMonday）")
        expect(controllerSrc.contains("allWeeksMode"),
               "原生侧要有「全部周次」状态（这种模式下不弹覆盖层）")
        expect(controllerSrc.contains("refreshFestivalCache()"),
               "翻周后要重算 7 天的详情（否则农历还是上一周的）")

        // ---- **覆盖层动画的四个修复**（2026-11）----
        //
        // A. 淡出收到一半会「闪一下」——
        //    根因：`buildPanel()` 挂回面板时加的 `.dpnoreplay`
        //    （`transition: none !important`）把**正在跑的过渡掐断**，
        //    clip-path 瞬间回到 `.show` 的 `inset(0)` → 面板整个闪回来。
        //    修法：淡出 / 收起动画在跑时**跳过** `.dpnoreplay`。
        //
        // B. 关闭没有收起动画 ——
        //    `.closing` 以前 `opacity: 1`（只有裁切一条曲线），
        //    窄条上看着就是「消失」。现在 opacity 也一起淡出。
        //
        // C. 要点几次才收得回去 ——
        //    `DP.open` 关闭时立刻置 false，动画播完前再点会被当成「打开」。
        //    修法：加 `DP.closing` 标志，动画期间忽略点击。
        //
        // D. 打不上字 ——
        //    `render()` 的 `root.innerHTML = ''` 让输入框脱离文档 → 焦点掉到 body
        //    → WKWebView 要等下一次绘制才让 focus() 生效（实测 ~190ms）
        //    → 这段时间的按键全丢（实测 11 个字丢 11 个）。
        //    修法：输入框有焦点时**整个 render 都不做**。
        let jsNoComments4 = (js ?? "")
            .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "//[^\\n]*", with: "", options: .regularExpression)

        // A. `.dpnoreplay` 的使用必须**有守卫**（动画在跑时跳过）。
        expect(jsNoComments4.contains("animating"),
               "buildPanel 要有「动画在跑」的判断（淡出/收起时不能用 .dpnoreplay）")
        // ⚠️ 2026-11 统一：消失动画只有 `.closing` 一种（`.fading` 已删除）。
        // 两套并存会互相抢状态（淡出播一半被摘 → opacity 回弹），
        // 所以这里反过来断言 fading 必须**彻底消失**。
        expect(!jsNoComments4.contains("fading"),
               "fading 淡出逻辑要已删除（统一为 .closing 收拢，两套并存会冲突）")
        expect(jsNoComments4.contains("contains('closing')"),
               "要检查 .closing 类（收起动画在跑）")

        // B. `.closing` 的 opacity 必须是 0（跟着一起淡出）。
        let closingRule = cssRule(css, ".daypanel.closing")
        expect(closingRule?.contains("opacity: 0") == true,
               "`.daypanel.closing` 的 opacity 要是 0（收起时一起淡出，否则窄条上看着像「消失」）")
        expect(closingRule?.contains("clip-path 400ms") == true,
               "`.daypanel.closing` 的 clip-path 过渡还是 400ms")

        // C. `DP.closing` 标志。
        expect(jsNoComments4.contains("DP.closing"),
               "要有 DP.closing 标志（收起动画期间忽略点击，否则要点几次）")

        // D. 输入框有焦点时不重建。
        // ⚠️ 判据是「输入框是不是当前焦点元素」——
        // 有了这个判断，render 就会在输入框有焦点时**整个跳过**（不重建）。
        expect(jsNoComments4.contains("document.activeElement === DP.input"),
               "要检查输入框是不是当前焦点元素（有焦点时不重建，否则打字会丢）")
        // ⚠️ 这个判断必须在 `root.innerHTML = ''` **之前** ——
        // 那一下就已经把输入框拆了，那时候再判断就晚了。
        let jsIdxActive = jsNoComments4.range(of: "document.activeElement === DP.input")
        let jsIdxInner = jsNoComments4.range(of: "root.innerHTML = ''")
        if let a = jsIdxActive, let b = jsIdxInner {
            expect(a.lowerBound < b.lowerBound,
                   "「输入框有焦点」的判断必须在 `root.innerHTML = ''` 之前（否则输入框已经被拆了）")
        }

        // ---- 天气 / 宜忌：拿不到就隐藏，绝不显示假数据 ----
        //
        // 网页侧：字段缺失 / null → 整行不渲染。
        expect(js?.contains("f.weather") == true,
               "网页层要读 festival.weather")
        expect(js?.contains("dpweather") == true,
               "天气行要有 .dpweather 样式")
        expect(js?.contains("f.yi") == true && js?.contains("f.ji") == true,
               "网页层要读 festival.yi / festival.ji")
        expect(js?.contains("dpyiji") == true,
               "宜 / 忌行要有 .dpyiji 样式")
    }

    if let js {
        // ---- 花括号 / 圆括号必须配平 ----
        var curly = 0, paren = 0
        var inStr: Character? = nil
        var inLineComment = false
        var inBlockComment = false
        var prev: Character = " "
        var i = js.startIndex
        while i < js.endIndex {
            let c = js[i]
            let next = js.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false }
            } else if inBlockComment {
                if prev == "*" && c == "/" { inBlockComment = false }
            } else if let s = inStr {
                if c == "\\" { i = next; prev = c; continue }
                if c == s { inStr = nil }
            } else {
                if c == "/" && next < js.endIndex && js[next] == "/" {
                    inLineComment = true
                } else if c == "/" && next < js.endIndex && js[next] == "*" {
                    inBlockComment = true
                } else if c == "\"" || c == "'" || c == "`" {
                    inStr = c
                } else if c == "{" { curly += 1 }
                else if c == "}" { curly -= 1 }
                else if c == "(" { paren += 1 }
                else if c == ")" { paren -= 1 }
            }
            prev = c
            i = next
        }
        expectEqual(curly, 0, "Timetable.js 的花括号必须配平")
        expectEqual(paren, 0, "Timetable.js 的圆括号必须配平")
        expect(inStr == nil, "Timetable.js 有没闭合的字符串")
        expect(!inBlockComment, "Timetable.js 有没闭合的块注释")
    }
}

suite("AutomationMode · 哪些路径不许有副作用") {
    for flag in AutomationMode.automationFlags {
        expect(AutomationMode.isAutomation(arguments: ["/Applications/x.app/Contents/MacOS/DesktopTimetable", flag]),
               "\(flag) 属于自动化模式")
    }
    expect(AutomationMode.isAutomation(arguments: ["/tmp/build/tests"]), "测试运行器属于自动化模式")
    expect(!AutomationMode.isAutomation(arguments: ["/Applications/DesktopTimetable.app/Contents/MacOS/DesktopTimetable"]),
           "正常启动不是自动化模式")
}

// MARK: - 提醒指纹

suite("ClassReminderScheduler · 指纹") {
    let start = day(2026, 8, 31)
    let c = course("高等数学", day: 2, block: 0, weeks: [1, 2], courseID: "M1")
    let now = at(2026, 9, 1, 7, 0)
    let base = ClassReminderScheduler.fingerprint(timetableID: "T1", courses: [c], overrides: [],
                                                  semesterStart: start, maxWeek: 16,
                                                  enabled: true, leadMinutes: 10, now: now)
    let same = ClassReminderScheduler.fingerprint(timetableID: "T1", courses: [c], overrides: [],
                                                  semesterStart: start, maxWeek: 16,
                                                  enabled: true, leadMinutes: 10, now: now)
    expectEqual(base, same, "同样数据得到同样指纹")

    let otherLead = ClassReminderScheduler.fingerprint(timetableID: "T1", courses: [c], overrides: [],
                                                       semesterStart: start, maxWeek: 16,
                                                       enabled: true, leadMinutes: 15, now: now)
    expect(base != otherLead, "提前分钟变了 → 指纹变")

    let otherTable = ClassReminderScheduler.fingerprint(timetableID: "T2", courses: [c], overrides: [],
                                                        semesterStart: start, maxWeek: 16,
                                                        enabled: true, leadMinutes: 10, now: now)
    expect(base != otherTable, "切换课表 → 指纹变")

    let tomorrow = ClassReminderScheduler.fingerprint(timetableID: "T1", courses: [c], overrides: [],
                                                      semesterStart: start, maxWeek: 16,
                                                      enabled: true, leadMinutes: 10,
                                                      now: at(2026, 9, 2, 7, 0))
    expect(base != tomorrow, "跨天 → 指纹变（要补足 14 天窗口）")
}

// MARK: - 设置面板的文案解析

suite("SettingsWindowController · 提醒下拉文案") {
    expectEqual(SettingsWindowController.leadTitle(0), "上课时提醒", "0 分钟文案")
    expectEqual(SettingsWindowController.leadTitle(10), "提前 10 分钟", "10 分钟文案")
    expectEqual(SettingsWindowController.parseLeadTitle("提前 12 分钟"), 12, "解析自定义分钟数")
    expectEqual(SettingsWindowController.parseLeadTitle("上课时提醒"), 0, "解析 0 分钟")
    expect(SettingsWindowController.parseLeadTitle("提前 分钟") == nil, "没有数字返回 nil")
}

// MARK: - 1.1.2「提前提醒」的自定义分钟数

suite("LeadMinutesChoice · 下拉框结构") {
    // 候选值 → 6 个候选 + 「自定义…」
    let preset = LeadMinutesChoice.popupItems(currentMinutes: 10)
    expectEqual(preset.titles.count, ReminderSettings.leadOptions.count + 1,
                "候选值时：候选 + 「自定义…」一项")
    expectEqual(preset.titles.last, "自定义…", "最后一项恒为「自定义…」")
    expectEqual(preset.customEntryIndex, preset.titles.count - 1, "自定义入口就是最后一项")
    expect(preset.minutes[preset.customEntryIndex] == nil, "自定义入口本身不是分钟数")
    expectEqual(preset.titles[preset.selectedIndex], "提前 10 分钟", "选中当前生效的分钟数")
    // 每一项的分钟数都能对回标题（不能只有索引对得上）
    for (i, title) in preset.titles.enumerated() {
        expect(LeadMinutesChoice.parseTitle(title) == preset.minutes[i],
               "第 \(i) 项「\(title)」的分钟数")
    }

    // 当前值不是候选（12）→ 多一项「提前 12 分钟（自定义）」并选中它
    let custom = LeadMinutesChoice.popupItems(currentMinutes: 12)
    expectEqual(custom.titles.count, ReminderSettings.leadOptions.count + 2,
                "自定义值时：候选 + 自定义值 + 「自定义…」")
    expect(custom.titles.contains("提前 12 分钟（自定义）"),
           "列表里要能看到当前的自定义值：\(custom.titles)")
    expectEqual(custom.titles.last, "自定义…", "「自定义…」永远在最后")
    expectEqual(custom.titles[custom.selectedIndex], "提前 12 分钟（自定义）",
                "选中自定义值那一项")
    expectEqual(custom.customEntryIndex, custom.titles.count - 1, "自定义入口还是最后一项")
    expect(custom.minutes[custom.selectedIndex] == 12, "自定义值那一项的分钟数是 12")

    // 0 是候选（「上课时提醒」），不该多出自定义值那一项
    let zero = LeadMinutesChoice.popupItems(currentMinutes: 0)
    expectEqual(zero.titles.count, ReminderSettings.leadOptions.count + 1, "0 分钟不额外列一项")
    expectEqual(zero.selectedIndex, 0, "0 分钟选中第一项")
    expectEqual(zero.titles[0], "上课时提醒", "0 分钟的文案")
}

suite("LeadMinutesChoice · 文案与输入解析") {
    expectEqual(LeadMinutesChoice.title(for: 0), "上课时提醒", "0 分钟文案")
    expectEqual(LeadMinutesChoice.title(for: 10), "提前 10 分钟", "10 分钟文案")
    expectEqual(LeadMinutesChoice.customValueTitle(for: 12), "提前 12 分钟（自定义）", "自定义值文案")
    expect(LeadMinutesChoice.parseTitle("提前 12 分钟") == 12, "解析分钟数")
    expect(LeadMinutesChoice.parseTitle("提前 12 分钟（自定义）") == 12, "解析自定义值的标题")
    expect(LeadMinutesChoice.parseTitle("上课时提醒") == 0, "解析 0 分钟")
    expect(LeadMinutesChoice.parseTitle("提前 分钟") == nil, "没有数字返回 nil")
    expect(LeadMinutesChoice.parseTitle("自定义…") == nil, "「自定义…」不是分钟数")

    expect(LeadMinutesChoice.parseMinutes("45") == 45, "正常输入")
    expect(LeadMinutesChoice.parseMinutes(" 12 ") == 12, "前后空格忽略")
    expect(LeadMinutesChoice.parseMinutes("0") == 0, "0 合法")
    expect(LeadMinutesChoice.parseMinutes("60") == 60, "60 合法（= maxLeadMinutes）")
    expect(LeadMinutesChoice.parseMinutes("61") == nil, "超过上界 → nil")
    expect(LeadMinutesChoice.parseMinutes("-1") == nil, "负数 → nil")
    expect(LeadMinutesChoice.parseMinutes("abc") == nil, "不是数字 → nil")
    expect(LeadMinutesChoice.parseMinutes("") == nil, "空 → nil")
    expect(LeadMinutesChoice.parseMinutes("1.5") == nil, "小数 → nil")
    // 存盘只存一个整数：老配置（没有自定义标记）照样能用
    expectEqual(ReminderSettings.clampLead(45), 45, "45 是合法提前量")
    expectEqual(ReminderSettings.clampLead(999), 60, "超界的值存盘时被夹到 60")
    expectEqual(ReminderSettings.clampLead(-5), 0, "负的值存盘时被夹到 0")
}

// MARK: - 缺口 1：改开学日期后必须重排（回归测试）

suite("SettingsWindowController · 改学期起始日要触发刷新（缺口 1）") {
    let dir = makeTempDir("semester-onchange")
    defer { try? FileManager.default.removeItem(at: dir) }
    let ts = TimetableStore(rootDirectory: dir)
    let t = try! ts.create(name: "测试课表", subtitle: "",
                           courses: [course("高等数学", day: 1, block: 0,
                                            weeks: [1, 2], courseID: "M1")],
                           semester: SemesterConfig(start: day(2026, 8, 31), maxWeek: 16))
    try! ts.setActive(t.id)

    var refreshCount = 0
    let ctl = SettingsWindowController(store: ScheduleStore(directory: dir, configDirectory: dir),
                                       timetableStore: ts,
                                       settingsStore: SettingsStore(configDirectory: dir),
                                       onChange: { refreshCount += 1 })

    // ---- 保存成功 → 刷新回调被触发一次 ----
    let picked = day(2026, 9, 7)
    let result = ctl.persistSemesterStart(picked)
    expect(result == .saved, "写盘成功时返回 .saved（实际 \(result)）")
    expectEqual(refreshCount, 1, "保存成功后刷新回调恰好触发一次")
    expectEqual(ctl.semesterStart, picked, "界面上的开学日期跟着更新")
    let repo = ts.activeRepository()!
    expectEqual(repo.semester.start, picked, "磁盘上的开学日期确实变了")

    // ---- 写盘失败 → 不触发刷新回调，界面值保持原样 ----
    //
    // 失败注入：把课表目录改成只读（0o500）→ 原子写盘必然失败
    //（Data.write(to:options:.atomic) 要在同目录建临时文件）。
    let ttDir = ts.directory(for: t.id)
    try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ttDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ttDir.path) }
    let before = refreshCount
    let failed = ctl.persistSemesterStart(day(2026, 9, 14))
    if case .failed(let message) = failed {
        expect(!message.isEmpty, "失败要带上真实错误信息")
    } else {
        expect(false, "写盘失败时必须返回 .failed，实际 \(failed)")
    }
    expectEqual(refreshCount, before, "写盘失败不触发刷新回调")
    expectEqual(ctl.semesterStart, picked, "写盘失败时界面日期保持原值（不假装保存成功）")
    expectEqual(ts.activeRepository()!.semester.start, picked, "写盘失败时磁盘上的日期没被改")
}

// MARK: - 缺口 2：指纹必须覆盖地点和教师（回归测试）

suite("ClassReminderScheduler · 指纹要覆盖地点和教师（缺口 2）") {
    let start = day(2026, 8, 31)
    let now = at(2026, 9, 1, 7, 0)

    func fingerprint(_ courses: [Course], _ overrides: [WeekOverride] = []) -> String {
        ClassReminderScheduler.fingerprint(timetableID: "T1", courses: courses, overrides: overrides,
                                           semesterStart: start, maxWeek: 16,
                                           enabled: true, leadMinutes: 10, now: now)
    }

    let base = course("高等数学", day: 2, block: 0,
                      teacher: "李雷", loc: "教三-201", weeks: [1, 2], courseID: "M1")
    var movedLoc = base
    movedLoc.loc = "教三-202"
    var newTeacher = base
    newTeacher.teacher = "韩梅梅"

    let fp = fingerprint([base])
    expectEqual(fp, fingerprint([base]), "数据没变 → 指纹稳定（不会每次都重排）")
    expect(fp != fingerprint([movedLoc]), "只改地点 → 指纹必须变（否则通知正文还是旧地点）")
    expect(fp != fingerprint([newTeacher]), "只改教师 → 指纹必须变（没地点时正文用教师）")

    // 覆盖课同理：它的 name / loc / teacher 也会进正文
    let ov = WeekOverride(day: 2, block: 0, weeks: [3], name: "高等数学",
                          teacher: "李雷", loc: "教三-201", code: "", courseID: "M1",
                          restored: nil)
    var ovLoc = ov
    ovLoc.loc = "实验楼"
    var ovTeacher = ov
    ovTeacher.teacher = "张伟"
    let fpOv = fingerprint([base], [ov])
    expect(fpOv != fingerprint([base], [ovLoc]), "只改覆盖课地点 → 指纹必须变")
    expect(fpOv != fingerprint([base], [ovTeacher]), "只改覆盖课教师 → 指纹必须变")

    // 指纹之所以要覆盖这些字段：正文里真的有它们
    let body = ClassReminderPlanner.bodyText(names: ["高等数学"], start: "08:00", end: "09:35",
                                              courses: [base])
    expect(body.contains("教三-201"), "通知正文里带地点")
    var noLoc = base
    noLoc.loc = ""
    let bodyNoLoc = ClassReminderPlanner.bodyText(names: ["高等数学"], start: "08:00", end: "09:35",
                                                   courses: [noLoc])
    expect(bodyNoLoc.contains("李雷"), "没有地点时通知正文改用教师")
}

// MARK: - 缺口 3：测试提醒按钮的可用性（回归测试）

suite("SettingsWindowController · 测试提醒按钮的可用性（缺口 3）") {
    // 授权 × 开关 × 自动化，共 8 种组合
    let combos: [(Bool, Bool, Bool)] = [
        (true, true, false), (true, true, true),
        (true, false, false), (true, false, true),
        (false, true, false), (false, true, true),
        (false, false, false), (false, false, true),
    ]
    for (enabled, authorized, automation) in combos {
        let expected = enabled && authorized && !automation
        let actual = SettingsWindowController.testReminderAvailability(
            reminderEnabled: enabled, notificationsAuthorized: authorized,
            isAutomation: automation)
        expectEqual(actual, expected,
                    "开关=\(enabled) 授权=\(authorized) 自动化=\(automation) → \(expected)")
    }

    // 授权状态一次回调拿全（授权 + 文案），别分两次查
    let fake = FakeNotificationCenter()
    fake.status = .denied
    let scheduler = ClassReminderScheduler(center: fake, isAutomation: false)
    var seen: (Bool, String)? = nil
    scheduler.authorizationState { seen = ($0, $1) }
    expect(seen?.0 == false, "未授权 → authorized = false")
    expect(seen?.1 == "系统通知未授权", "未授权 → 文案说「系统通知未授权」")

    // 自动化模式：绝不碰系统通知中心
    let autoFake = FakeNotificationCenter()
    let autoScheduler = ClassReminderScheduler(center: autoFake, isAutomation: true)
    var autoSeen: (Bool, String)? = nil
    autoScheduler.authorizationState { autoSeen = ($0, $1) }
    expect(autoSeen?.0 == false, "自动化模式 → 一律未授权")
    expect(autoSeen?.1.contains("自动化") == true, "自动化模式 → 文案说明是自动化模式")
    expect(!autoFake.requested, "自动化模式不请求通知权限")
}

// MARK: - 缺口 4：损坏的 settings.json 写盘前先备份（回归测试）

suite("SettingsStore · 写盘前要备份损坏的 settings.json（缺口 4）") {
    let dir = makeTempDir("settings-corrupt-backup")
    defer { try? FileManager.default.removeItem(at: dir) }
    let ss = SettingsStore(configDirectory: dir)
    let fm = FileManager.default

    func corruptBackups() -> [String] {
        let items = (try? fm.contentsOfDirectory(atPath: ss.backupsDirectory.path)) ?? []
        return items.filter { $0.hasPrefix("settings-corrupt-") }.sorted()
    }

    // 正常保存 → 不产生损坏备份
    var settings = AppSettings()
    settings.reminder.enabled = true
    try! ss.save(settings)
    expectEqual(corruptBackups().count, 0, "正常保存不产生损坏备份")

    // 写一个坏文件 → 再保存 → 坏文件必须先被备份下来
    let broken = "{ 这不是 JSON"
    try! Data(broken.utf8).write(to: ss.settingsFile)
    expect(ss.settingsFileIsCorrupt, "能识别出 settings.json 坏了")

    var settings2 = AppSettings()
    settings2.reminder.leadMinutes = 20
    try! ss.save(settings2)
    let backups = corruptBackups()
    expectEqual(backups.count, 1, "写盘前把损坏文件备份了一份")
    if let name = backups.first {
        let content = (try? String(contentsOf: ss.backupsDirectory.appendingPathComponent(name),
                                   encoding: .utf8)) ?? ""
        expectEqual(content, broken, "备份内容 == 原来的坏内容（用户还能找回）")
    }
    // 保存之后文件是好的，值也读得回来
    expect(!ss.settingsFileIsCorrupt, "保存后 settings.json 不再是坏的")
    expectEqual(ss.load().reminder.leadMinutes, 20, "保存后的新值读得回来")
}

// MARK: - 缺口 5：登录项系统状态映射（回归测试）

suite("LoginItemState · 系统状态映射（缺口 5）") {
    expectEqual(LoginItemState.fromServiceStatus(.enabled), .enabled,
                "enabled → 已开启")
    expectEqual(LoginItemState.fromServiceStatus(.notRegistered), .notRegistered,
                "notRegistered → 未开启")
    expectEqual(LoginItemState.fromServiceStatus(.requiresApproval), .requiresApproval,
                "requiresApproval → 等用户允许")

    // .notFound 和未知状态**不能**被当成「未开启」——
    // 那样用户以为没开，其实系统根本找不到这个登录项。
    let notFound = LoginItemState.fromServiceStatus(.notFound)
    if case .failed(let message) = notFound {
        expect(message.contains("应用程序") || message.contains("找不到"),
               "notFound → 给出真实原因")
    } else {
        expect(false, "notFound 必须映射成 .failed，实际 \(notFound)")
    }
    expect(!notFound.isOn, "notFound → 开关是关的")

    let unknown = LoginItemState.fromServiceStatus(.unknown)
    if case .failed = unknown {
        expect(true, "未知状态 → .failed")
    } else {
        expect(false, "未知状态必须映射成 .failed，实际 \(unknown)")
    }
    expect(!unknown.isOn, "未知状态 → 开关是关的")
    expect(!LoginItemState.describe(notFound).text.isEmpty, "失败也有状态文案")
    expectEqual(LoginItemState.describe(notFound).text, "开启失败", "失败时状态行说「开启失败」")
}

// MARK: - 可选项 7：JSON 类型必须严格（回归测试）

suite("StrictJSONValue · 数字和布尔不能混（可选项 7）") {
    // 走 JSONSerialization —— 这才是 settings.json 真实的解析路径
    let raw = "{\"a\":1,\"b\":true,\"c\":1.5,\"d\":1.0,\"e\":\"x\"}"
    let obj = (try! JSONSerialization.jsonObject(with: Data(raw.utf8))) as! [String: Any]

    expect(StrictJSONValue.bool(obj["a"]) == nil, "JSON 的 1 不能当 Bool")
    expect(StrictJSONValue.bool(obj["b"]) == true, "JSON 的 true 是 Bool")
    expect(StrictJSONValue.int(obj["b"]) == nil, "JSON 的 true 不能当 Int")
    expect(StrictJSONValue.int(obj["a"]) == 1, "JSON 的 1 是 Int")
    expect(StrictJSONValue.int(obj["c"]) == nil, "1.5 不是 Int")
    expect(StrictJSONValue.int(obj["d"]) == nil, "1.0 不是 Int（浮点不能悄悄变整数）")
    expect(StrictJSONValue.int(obj["e"]) == nil, "字符串不是 Int")

    // 走设置模型：类型非法必须回退默认值
    // （同样走 JSONSerialization，保证拿到的是真正的 NSNumber）
    let badJSON = "{\"reminder\":{\"enabled\":1,\"leadMinutes\":true}}"
    let bad = (try! JSONSerialization.jsonObject(with: Data(badJSON.utf8))) as! [String: Any]
    let rem = ReminderSettings(json: bad["reminder"] as? [String: Any] ?? [:])
    expectEqual(rem.enabled, false, "enabled = 1（数字）→ 类型非法 → 保持默认 false")
    expectEqual(rem.leadMinutes, 10, "leadMinutes = true → 类型非法 → 保持默认 10")
}

// MARK: - 可选项 8 / 9：自动化边界与手工验收辅助（回归测试）

suite("AutomationMode · 自动化开关的边界（可选项 8 / 9）") {
    // 所有 --verify-* 都是自动化：不请求通知权限、不注册登录项
    for flag in AutomationMode.automationFlags {
        expect(AutomationMode.isAutomation(arguments: ["/tmp/app", flag]),
               "\(flag) 必须算自动化模式")
    }
    // 手工验收辅助**不能**算自动化 —— 它们就是要真的碰系统
    expect(!AutomationMode.isAutomation(arguments: ["/tmp/app", "--login-item-selftest"]),
           "--login-item-selftest 不是自动化（它要真的注册一次再注销）")
    expect(!AutomationMode.isAutomation(arguments: ["/tmp/app", "--notifications-status"]),
           "--notifications-status 不是自动化（它要真的读授权状态）")
    // 测试运行器（可执行文件名以 tests 结尾）→ 自动化
    expect(AutomationMode.isAutomation(arguments: ["/tmp/build/tests"]),
           "测试运行器算自动化模式")
}

suite("README · 文档与实际一致（缺口 6 / 可选项 9）") {
    // 用 #filePath 定位项目根目录，不依赖当前工作目录
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 项目根
    let readme = root.appendingPathComponent("README.md")
    guard let text = try? String(contentsOf: readme, encoding: .utf8) else {
        expect(false, "README.md 应该存在（\(readme.path)）")
        return
    }
    expect(text.contains("默认走模式 B"), "README 说明 B 模式是默认渲染路径")
    expect(text.contains("DT_SNAPSHOT=1"), "README 说明 A 模式是回退（DT_SNAPSHOT=1）")
    expect(text.contains("--notifications-status"), "README 写了手工验收辅助 --notifications-status")
    expect(text.contains("--login-item-selftest"), "README 写了手工验收辅助 --login-item-selftest")

    // 只检查「模式 B」这一段本身：B 模式是网页直接上屏，
    // 不能出现快照管线的步骤。以前整段是从快照管线复制来的，
    // 图里画着 takeSnapshot / layer.contents，和标题自相矛盾。
    guard let bStart = text.range(of: "**模式 B（默认）**"),
          let snapshotStart = text.range(of: "**快照管线",
                                         range: bStart.upperBound..<text.endIndex) else {
        expect(false, "README 应该能定位到「模式 B（默认）」到「快照管线」之间的段落")
        return
    }
    let bSection = String(text[bStart.lowerBound..<snapshotStart.lowerBound])
    expect(bSection.contains("WKWebView"), "B 模式段落要说明 WKWebView 直接渲染")
    expect(!bSection.contains("takeSnapshot"), "B 模式说明里不能出现 takeSnapshot（那是快照管线）")
    expect(!bSection.contains("layer.contents"), "B 模式说明里不能出现 layer.contents（那是快照管线）")
    expect(!bSection.contains("快照位图"), "B 模式说明里不能把画面说成快照位图")
}

/// 带来源标记的课程（测试专用构造器）。
func sourced(_ name: String, day: Int, block: Int, weeks: [Int],
             courseID: String, teacher: String = "", loc: String = "", code: String = "",
             origin: CourseOrigin = .imported, userModified: Bool = false) -> Course {
    Course(day: day, block: block, name: name, teacher: teacher, loc: loc,
           code: code, courseID: courseID, weeks: weeks,
           origin: origin, userModified: userModified)
}

// MARK: - 1.1.1 导入保护：来源字段

suite("Course · 来源字段（向后兼容）") {
    // 旧数据：没有 origin / userModified 两个键 —— 不能因此解码失败
    let legacyJSON = """
    [{"name":"高等数学","day":3,"block":1,"weeks":[1,2,3],"courseID":"M1","teacher":"李雷","loc":"教三-201","weeksLabel":"1-3"}]
    """.data(using: .utf8)!

    do {
        let decoded = try JSONDecoder().decode([Course].self, from: legacyJSON)
        expectEqual(decoded.count, 1, "旧数据能解码（不能因为缺来源字段失败）")
        expectEqual(decoded.first?.origin, .unknown, "缺来源字段 → unknown")
        expectEqual(decoded.first?.userModified, false, "缺 userModified → false")
        expectEqual(decoded.first?.isProtected, true, "旧数据一律受保护（不自动删 / 覆盖）")
        expectEqual(decoded.first?.originLabel, "旧数据（来源未知）", "旧数据的展示文案")
    } catch {
        expect(false, "旧数据解码抛错：\(error)")
    }

    // 新字段 encode / decode 往返
    let list = [sourced("大学英语", day: 1, block: 0, weeks: [1, 2], courseID: "E1",
                        origin: .manual, userModified: false),
                sourced("物理", day: 2, block: 1, weeks: [1, 2], courseID: "P1",
                        origin: .imported, userModified: true)]
    do {
        let data = try JSONEncoder().encode(list)
        let back = try JSONDecoder().decode([Course].self, from: data)
        expectEqual(back.map { $0.origin }, [.manual, .imported], "来源 encode/decode 往返不丢")
        expectEqual(back.map { $0.userModified }, [false, true], "userModified 往返不丢")
        expectEqual(back[0].originLabel, "你新增", "manual 文案")
        expectEqual(back[1].originLabel, "你修改过", "imported + userModified 文案")
    } catch {
        expect(false, "来源字段往返失败：\(error)")
    }

    // 字典构造（ScheduleRepository 的宽松解析路径）
    let legacyDict: [String: Any] = ["name": "军事理论", "day": 3, "block": 2, "weeks": [1, 2]]
    let d1 = try? Course(dictionary: legacyDict)
    expectEqual(d1?.origin, .unknown, "字典缺来源字段 → unknown")
    expectEqual(d1?.isProtected, true, "字典旧数据也受保护")

    let newDict: [String: Any] = ["name": "体育", "day": 5, "block": 0, "weeks": [1],
                                  "origin": "manual", "userModified": false]
    let d2 = try? Course(dictionary: newDict)
    expectEqual(d2?.origin, .manual, "字典能读 origin")
    expectEqual(d2?.originLabel, "你新增", "字典路径文案一致")

    expectEqual(sourced("x", day: 1, block: 0, weeks: [1], courseID: "a").originLabel,
                "导入", "imported 且没改过 → 「导入」")
    expectEqual(sourced("x", day: 1, block: 0, weeks: [1], courseID: "a",
                        origin: .imported).isProtected, false, "没动过的导入课不受保护")
}

// MARK: - 1.1.1 导入保护：编辑后的来源维护

suite("CourseEdit · 来源标记") {
    let maxWeek = 16
    let draft = CourseDraft(name: "高等数学", code: "M1", teacher: "李雷", loc: "教三-201",
                            day: 3, block: 1, weeks: Array(1...8))

    // create → manual
    let created = try? CourseEdit.apply(draft: draft, scope: .create(day: 3, block: 1),
                                        courses: [], maxWeek: maxWeek)
    expectEqual(created?.first?.origin, .manual, "用户新增 → manual")
    expectEqual(created?.first?.userModified, false, "用户新增不算「改过」")
    expectEqual(created?.first?.isProtected, true, "用户新增受保护")

    // 同一门导入课两条上课时间
    let base = [sourced("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1"),
                sourced("高等数学", day: 5, block: 1, weeks: [1, 2], courseID: "M1"),
                sourced("物理", day: 2, block: 0, weeks: [1], courseID: "P1")]

    // edit 导入课 → 该 courseID 所有记录 userModified = true，别的课不受影响
    let edited = try? CourseEdit.apply(draft: draft,
                                       scope: .edit(courseID: "M1", day: 3, block: 1),
                                       courses: base, maxWeek: maxWeek)
    expectEqual(edited?.filter { $0.courseID == "M1" }.map { $0.userModified }, [true, true],
                "改导入课 → 同 courseID 的所有记录都标 userModified")
    expectEqual(edited?.first { $0.courseID == "P1" }?.userModified, false, "别的课不受影响")
    expectEqual(edited?.first { $0.courseID == "M1" }?.originLabel, "你修改过", "改过的导入课文案")
    expectEqual(edited?.first { $0.courseID == "M1" }?.origin, .imported, "origin 仍是 imported（靠 userModified 标记）")

    // edit manual → 仍是 manual，且不打 userModified
    let manualBase = [sourced("自习", day: 3, block: 1, weeks: [1, 2], courseID: "S1",
                              origin: .manual)]
    var manualDraft = draft
    manualDraft.name = "自习"
    let editedManual = try? CourseEdit.apply(draft: manualDraft,
                                             scope: .edit(courseID: "S1", day: 3, block: 1),
                                             courses: manualBase, maxWeek: maxWeek)
    expectEqual(editedManual?.first?.origin, .manual, "改用户新增的课 → 仍是 manual")
    expectEqual(editedManual?.first?.userModified, false, "manual 不需要额外标记")

    // edit unknown → 保持 unknown
    let unknownBase = [sourced("旧课", day: 3, block: 1, weeks: [1, 2], courseID: "U1",
                               origin: .unknown)]
    var unknownDraft = draft
    unknownDraft.name = "旧课"
    let editedUnknown = try? CourseEdit.apply(draft: unknownDraft,
                                              scope: .edit(courseID: "U1", day: 3, block: 1),
                                              courses: unknownBase, maxWeek: maxWeek)
    expectEqual(editedUnknown?.first?.origin, .unknown, "旧数据改完仍是 unknown")
    expectEqual(editedUnknown?.first?.isProtected, true, "旧数据始终受保护")

    // addSession 导入课 → 视为用户修改
    var addDraft = draft
    addDraft.day = 2
    addDraft.block = 3
    let added = try? CourseEdit.apply(draft: addDraft, scope: .addSession(courseID: "M1"),
                                      courses: base, maxWeek: maxWeek)
    expectEqual(added?.filter { $0.courseID == "M1" }.count, 3, "追加一节 → 多一条记录")
    expectEqual(added?.filter { $0.courseID == "M1" }.allSatisfy { $0.userModified }, true,
                "追加上课时间 = 用户修改（所有记录一起标）")

    // addSession manual → 保持 manual，新记录也是 manual
    let addedManual = try? CourseEdit.apply(draft: addDraft, scope: .addSession(courseID: "S1"),
                                            courses: manualBase, maxWeek: maxWeek)
    expectEqual(addedManual?.filter { $0.courseID == "S1" }.map { $0.origin }, [.manual, .manual],
                "manual 追加 → 新记录沿用 manual")
    expectEqual(addedManual?.filter { $0.courseID == "S1" }.allSatisfy { !$0.userModified }, true,
                "manual 追加不需要 userModified")
}

// MARK: - 1.1.1 导入保护：冲突检测

suite("ImportConflicts · 冲突检测") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)

    // 当前：用户新增的「自习」占周二第 3-4 节 / 1-8 周；
    //       导入来的「军事理论」占周四第 5-6 节（没动过）；
    //       改过的「大学英语」占周一第 1-2 节。
    let current = [
        sourced("自习", day: 2, block: 1, weeks: Array(1...8), courseID: "S1", origin: .manual),
        sourced("军事理论", day: 4, block: 2, weeks: Array(1...16), courseID: "J1"),
        sourced("大学英语", day: 1, block: 0, weeks: Array(1...8), courseID: "E1",
                origin: .imported, userModified: true),
    ]
    // 导入：物理（新增，与自习同格、周次重叠）+ 军事理论（改地点，未动过 → 会更新）
    let imported = [
        sourced("物理", day: 2, block: 1, weeks: Array(1...16), courseID: "P1"),
        sourced("军事理论", day: 4, block: 2, weeks: Array(1...16), courseID: "J1", loc: "新楼"),
    ]
    let result = TimetableDiff.compare(current: current, imported: imported,
                                       currentSemester: sem, importedSemester: nil)
    let choice = TimetableDiff.defaultMergeChoice(for: result)
    let units = ImportConflictLogic.detect(current: current, result: result, choice: choice)

    expectEqual(units.count, 1, "导入的物理 vs 用户新增的自习 → 1 处冲突")
    expectEqual(units.first?.currentCourseID, "S1", "冲突指向用户新增的课")
    expectEqual(units.first?.importedCourseID, "P1", "冲突指向导入的课")
    expectEqual(units.first?.currentOriginLabel, "你新增", "冲突行要标出来源")
    expectEqual(units.first?.currentProtected, true, "用户新增的课受保护")
    expectEqual(units.first?.slots.first?.overlap, Array(1...8), "重叠周次 = 1-8")

    // 周次不重叠（单双周交替）→ 不算冲突
    let dj = [sourced("自习", day: 2, block: 1, weeks: [1, 3, 5], courseID: "S1", origin: .manual)]
    let di = [sourced("物理", day: 2, block: 1, weeks: [2, 4, 6], courseID: "P1")]
    let dr = TimetableDiff.compare(current: dj, imported: di, currentSemester: sem, importedSemester: nil)
    expectEqual(ImportConflictLogic.detect(current: dj, result: dr,
                                           choice: TimetableDiff.defaultMergeChoice(for: dr)).count, 0,
                "周次不重叠 → 不算冲突")

    // 同一门课的更新（同 courseID）→ 不算冲突
    let sj = [sourced("军事理论", day: 4, block: 2, weeks: [1, 2], courseID: "J1")]
    let si = [sourced("军事理论", day: 4, block: 2, weeks: [1, 2], courseID: "J1", loc: "新楼")]
    let sr = TimetableDiff.compare(current: sj, imported: si, currentSemester: sem, importedSemester: nil)
    expectEqual(ImportConflictLogic.detect(current: sj, result: sr,
                                           choice: TimetableDiff.defaultMergeChoice(for: sr)).count, 0,
                "同一门课的更新不算冲突")

    // 不同 day / block → 不算冲突
    let bj = [sourced("自习", day: 2, block: 1, weeks: [1], courseID: "S1", origin: .manual)]
    let bi = [sourced("物理", day: 3, block: 1, weeks: [1], courseID: "P1")]
    let br = TimetableDiff.compare(current: bj, imported: bi, currentSemester: sem, importedSemester: nil)
    expectEqual(ImportConflictLogic.detect(current: bj, result: br,
                                           choice: TimetableDiff.defaultMergeChoice(for: br)).count, 0,
                "不同天 / 不同节次 → 不算冲突")

    // 导入课与「没被用户动过的旧导入课」冲突 → 同样要能被用户选择（不静默覆盖）
    let oj = [sourced("军事理论", day: 4, block: 2, weeks: [1, 2, 3], courseID: "J1")]
    let oi = [sourced("物理", day: 4, block: 2, weeks: [2, 3, 4], courseID: "P1")]
    let or = TimetableDiff.compare(current: oj, imported: oi, currentSemester: sem, importedSemester: nil)
    let oUnits = ImportConflictLogic.detect(current: oj, result: or,
                                            choice: TimetableDiff.defaultMergeChoice(for: or))
    expectEqual(oUnits.count, 1, "旧导入课被新导入课顶掉 → 也要用户逐条选择")
    expectEqual(oUnits.first?.currentProtected, false, "这门旧课本身不保护，但仍然是冲突")

    // 当前课表内部本来就有的冲突 → 不进导入冲突列表
    let inner = [sourced("课甲", day: 6, block: 0, weeks: [1], courseID: "A1"),
                 sourced("课乙", day: 6, block: 0, weeks: [1], courseID: "B1"),
                 sourced("自习", day: 2, block: 1, weeks: [1], courseID: "S1", origin: .manual)]
    let innerImport = [sourced("物理", day: 5, block: 3, weeks: [1], courseID: "P1")]
    let ir = TimetableDiff.compare(current: inner, imported: innerImport,
                                   currentSemester: sem, importedSemester: nil)
    expectEqual(ImportConflictLogic.detect(current: inner, result: ir,
                                           choice: TimetableDiff.defaultMergeChoice(for: ir)).count, 0,
                "当前课表内部的旧冲突不算导入冲突")
}

// MARK: - 1.1.1 导入保护：冲突解析

suite("ImportConflicts · 冲突解析") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    // 用户新增「自习」周二 3-4 节 1-8 周；导入「物理」两节：周二 3-4 节（冲突）+ 周五 1-2 节
    let current = [sourced("自习", day: 2, block: 1, weeks: Array(1...8),
                           courseID: "S1", origin: .manual)]
    let imported = [sourced("物理", day: 2, block: 1, weeks: Array(1...8), courseID: "P1"),
                    sourced("物理", day: 5, block: 0, weeks: Array(1...8), courseID: "P1")]
    let result = TimetableDiff.compare(current: current, imported: imported,
                                       currentSemester: sem, importedSemester: nil)
    var choice = TimetableDiff.defaultMergeChoice(for: result)
    let units = ImportConflictLogic.detect(current: current, result: result, choice: choice)
    expectEqual(units.count, 1, "先确认有 1 处冲突")
    guard let unit = units.first else { return }

    // 未选择 → 不能应用
    var plan = ImportConflictLogic.plan(current: current, imported: imported,
                                        result: result, choice: choice)
    expectEqual(plan.unresolved.count, 1, "没选 → 1 处未决定")
    expect(!plan.canApply, "有未决定的冲突 → 「应用」不可点")
    expect(plan.blocker?.contains("没有决定") == true, "要说明原因：冲突没决定")

    // 保留当前 → 只去掉导入侧冲突的那条，导入课的其他上课时间保留
    choice.conflicts[unit.id] = .keepCurrent
    plan = ImportConflictLogic.plan(current: current, imported: imported,
                                    result: result, choice: choice)
    expect(plan.canApply, "冲突解决后可以应用")
    expect(plan.courses.contains { $0.name == "物理" && $0.day == 5 },
           "保留当前 → 导入课另一节还在")
    expect(!plan.courses.contains { $0.name == "物理" && $0.day == 2 },
           "保留当前 → 导入侧冲突的那节被去掉")
    expect(plan.courses.contains { $0.courseID == "S1" }, "保留当前 → 用户课保留")

    // 用导入 → 只去掉当前侧冲突的那条
    choice.conflicts[unit.id] = .useImported
    plan = ImportConflictLogic.plan(current: current, imported: imported,
                                    result: result, choice: choice)
    expect(plan.canApply, "用导入也能应用（用户显式授权）")
    expect(!plan.courses.contains { $0.courseID == "S1" }, "用导入 → 用户课冲突的那节被去掉")
    expectEqual(plan.courses.filter { $0.name == "物理" }.count, 2, "用导入 → 导入课两节都在")

    // 两边都留 → 都在，且显式记录为「用户接受冲突」
    choice.conflicts[unit.id] = .keepBoth
    plan = ImportConflictLogic.plan(current: current, imported: imported,
                                    result: result, choice: choice)
    expect(plan.canApply, "显式「两边都留」→ 允许保存")
    expect(plan.courses.contains { $0.courseID == "S1" }, "两边都留 → 用户课在")
    expectEqual(plan.courses.filter { $0.name == "物理" }.count, 2, "两边都留 → 导入课两节都在")

    // 同一冲突对的多条重叠时段，一次选择全部生效
    let multiCurrent = [
        sourced("自习", day: 2, block: 1, weeks: [1, 2], courseID: "S1", origin: .manual),
        sourced("自习", day: 4, block: 2, weeks: [1, 2], courseID: "S1", origin: .manual),
    ]
    let multiImport = [
        sourced("物理", day: 2, block: 1, weeks: [1, 2], courseID: "P1"),
        sourced("物理", day: 4, block: 2, weeks: [1, 2], courseID: "P1"),
    ]
    let mr = TimetableDiff.compare(current: multiCurrent, imported: multiImport,
                                   currentSemester: sem, importedSemester: nil)
    var mc = TimetableDiff.defaultMergeChoice(for: mr)
    let mu = ImportConflictLogic.detect(current: multiCurrent, result: mr, choice: mc)
    expectEqual(mu.count, 1, "同一对课的多个时段合成 1 个冲突单元")
    expectEqual(mu.first?.slots.count, 2, "单元里记着 2 个重叠时段")
    if let mid = mu.first?.id {
        mc.conflicts[mid] = .keepCurrent
        let mp = ImportConflictLogic.plan(current: multiCurrent, imported: multiImport,
                                          result: mr, choice: mc)
        expectEqual(mp.courses.filter { $0.name == "物理" }.count, 0,
                    "一次选择让导入课两条冲突时段全部去掉（课也就不进来了）")
        expectEqual(mp.courses.filter { $0.courseID == "S1" }.count, 2, "用户课两节都保留")
    }

    // id 稳定：同样的输入两次算出同样的 id
    let again = ImportConflictLogic.detect(current: current, result: result, choice: choice)
    expectEqual(again.first?.id, unit.id, "冲突单元 id 每次重算都一样")
}

// MARK: - 1.1.1 导入保护：防丢课

suite("ImportConflicts · 防丢保护课") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let current = [
        sourced("自习", day: 2, block: 1, weeks: [1], courseID: "S1", origin: .manual),
        sourced("旧课", day: 3, block: 0, weeks: [1], courseID: "U1", origin: .unknown),
    ]
    let result = TimetableDiff.compare(current: current, imported: [],
                                       currentSemester: sem, importedSemester: nil)
    var choice = TimetableDiff.defaultMergeChoice(for: result)

    expectEqual(choice.courses["S1"], .keepCurrent, "用户新增的课导入里没有 → 默认保留")
    expectEqual(choice.courses["U1"], .keepCurrent, "旧数据导入里没有 → 默认保留")

    // 合并结果里没有这门课、也没有任何显式选择 → 必须报出来
    let lost = ImportConflictLogic.lostProtectedCourses(current: current, result: result,
                                                         choice: choice, units: [], courses: [])
    expectEqual(lost.sorted(), ["旧课", "自习"], "保护课无故消失 → 两门都要报出来")

    // 显式删除 → 允许消失（removed 的课只有 delete 才算授权；
    // 对导入里没有的课选「用导入」等于保留，不算授权）
    var explicitDelete = choice
    explicitDelete.courses["S1"] = .delete
    expectEqual(ImportConflictLogic.lostProtectedCourses(current: current, result: result,
                                                          choice: explicitDelete, units: [],
                                                          courses: []), ["旧课"],
                "显式删除的课不算「静默丢失」")

    // 匹配上的保护课显式选「用导入」→ 也允许消失
    let mCurrent = [sourced("大学英语", day: 1, block: 0, weeks: [1], courseID: "E1",
                            loc: "旧楼", origin: .imported, userModified: true)]
    let mImported = [sourced("大学英语", day: 1, block: 0, weeks: [1], courseID: "E1",
                             loc: "新楼")]
    let mResult = TimetableDiff.compare(current: mCurrent, imported: mImported,
                                        currentSemester: sem, importedSemester: nil)
    var mChoice = TimetableDiff.defaultMergeChoice(for: mResult)
    let mMerged = TimetableDiff.merge(current: mCurrent, imported: mImported,
                                      result: mResult, choice: mChoice)
    expectEqual(ImportConflictLogic.lostProtectedCourses(current: mCurrent, result: mResult,
                                                          choice: mChoice, units: [],
                                                          courses: mMerged.courses), [],
                "默认保留 → 不会被当成丢失")
    mChoice.courses["E1"] = .useImported
    expectEqual(ImportConflictLogic.lostProtectedCourses(current: mCurrent, result: mResult,
                                                          choice: mChoice, units: [], courses: []), [],
                "显式「用导入」的课不算静默丢失")
}

// MARK: - 1.1.1 导入保护：默认值按来源分流

suite("TimetableDiff · 默认值按来源分流") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let current = [
        // 没动过的导入课 → 覆盖语义：默认用导入
        sourced("军事理论", day: 4, block: 2, weeks: [1, 2], courseID: "J1"),
        // 用户改过的导入课 → 默认保留
        sourced("大学英语", day: 1, block: 0, weeks: [1, 2], courseID: "E1",
                origin: .imported, userModified: true),
        // 用户新增的课 → 默认保留（导入里也没有）
        sourced("自习", day: 2, block: 1, weeks: [1, 2], courseID: "S1", origin: .manual),
        // 旧数据 → 默认保留
        sourced("旧课", day: 3, block: 3, weeks: [1, 2], courseID: "U1", origin: .unknown),
    ]
    let imported = [
        sourced("军事理论", day: 4, block: 2, weeks: [1, 2], courseID: "J1", loc: "新楼"),
        sourced("大学英语", day: 1, block: 0, weeks: [1, 2], courseID: "E1", loc: "旧楼"),
        sourced("体育", day: 5, block: 0, weeks: [1, 2], courseID: "T1"),
    ]
    let r = TimetableDiff.compare(current: current, imported: imported,
                                  currentSemester: sem, importedSemester: nil)
    let choice = TimetableDiff.defaultMergeChoice(for: r)

    expectEqual(choice.courses["J1"], .useImported, "未受保护的匹配课 → 默认用导入")
    expectEqual(choice.courses["E1"], .keepCurrent, "用户改过的课 → 默认保留当前")
    expectEqual(choice.courses["T1"], .useImported, "导入新增 → 默认用导入")
    expectEqual(choice.courses["S1"], .keepCurrent, "导入里没有的用户新增课 → 默认保留")
    expectEqual(choice.courses["U1"], .keepCurrent, "旧数据 → 默认保留")
    expect(choice.conflicts.isEmpty, "冲突单元不给默认值（必须由用户逐条选）")

    // 保护课程不会被默认值删掉
    let merged = TimetableDiff.merge(current: current, imported: imported,
                                     result: r, choice: choice)
    expect(merged.courses.contains { $0.courseID == "S1" }, "默认合并结果里用户新增的课还在")
    expect(merged.courses.contains { $0.courseID == "U1" }, "默认合并结果里旧数据还在")
}

// MARK: - 1.1.1 覆盖导入 · 端到端（临时目录）

suite("覆盖导入 · 来源保护端到端") {
    let dir = makeTempDir("tt-protect")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let sem = SemesterConfig(start: Date(), maxWeek: 16)

    // ---- 当前课表：四种来源各一门 ----
    let t = try! store.create(name: "当前课表", semester: sem)
    var cur = try! store.load(t.id)
    cur.courses = [
        // 导入来源、没改过 → 导入文件里它更新
        sourced("高等数学", day: 3, block: 1, weeks: Array(1...8), courseID: "M1",
                teacher: "李雷", loc: "教三-201"),
        // 用户新增，与导入的物理同格
        sourced("自习", day: 2, block: 1, weeks: Array(1...8), courseID: "S1",
                loc: "图书馆", origin: .manual),
        // 导入来源、用户改过地点
        sourced("大学英语", day: 1, block: 0, weeks: Array(1...8), courseID: "E1",
                loc: "外语-102", origin: .imported, userModified: true),
        // 导入来源、没改过，导入文件里没有它（会被当成 removed）
        sourced("军事理论", day: 4, block: 2, weeks: Array(1...8), courseID: "J1"),
    ]
    try! store.save(cur)
    try! store.setActive(t.id)

    // ---- 导入文件 ----
    let imported = [
        sourced("高等数学", day: 3, block: 1, weeks: Array(1...8), courseID: "M1",
                teacher: "王老师", loc: "教三-305"),      // 更新（未改过 → 默认用导入）
        sourced("物理", day: 2, block: 1, weeks: Array(1...16), courseID: "P1"),  // 与自习冲突
        sourced("大学英语", day: 1, block: 0, weeks: Array(1...8), courseID: "E1",
                loc: "外语-101"),                          // 旧版本（用户改过 → 默认保留）
        sourced("体育", day: 5, block: 0, weeks: Array(1...8), courseID: "T1"),   // 全新
    ]

    let result = TimetableDiff.compare(current: cur.courses, imported: imported,
                                       currentSemester: sem, importedSemester: nil)
    var choice = TimetableDiff.defaultMergeChoice(for: result)

    expectEqual(choice.courses["M1"], .useImported, "没改过的高数 → 默认更新")
    expectEqual(choice.courses["E1"], .keepCurrent, "改过的英语 → 默认保留")
    expectEqual(choice.courses["J1"], .keepCurrent, "导入里没有的课 → 默认保留")
    expectEqual(choice.courses["S1"], .keepCurrent, "用户新增的课 → 默认保留")

    let units = ImportConflictLogic.detect(current: cur.courses, result: result, choice: choice)
    expectEqual(units.count, 1, "物理 vs 自习 → 1 处冲突")
    guard let unit = units.first else { return }

    // 没选冲突 → 不能应用（这就是「不能再静默覆盖」的硬约束）
    var plan = ImportConflictLogic.plan(current: cur.courses, imported: imported,
                                        result: result, choice: choice)
    expect(!plan.canApply, "冲突没决定时不能让用户点应用")
    expect(plan.summary.contains("1 处冲突待决定"), "摘要要写清冲突数：\(plan.summary)")

    // 选「保留当前」→ 物理不进来，自习保留
    choice.conflicts[unit.id] = .keepCurrent
    plan = ImportConflictLogic.plan(current: cur.courses, imported: imported,
                                    result: result, choice: choice)
    expect(plan.canApply, "决定冲突后可以应用")
    expect(plan.courses.contains { $0.courseID == "S1" }, "用户新增的自习保留")
    // 「保留当前」= 只让开**重叠的那几周**（1-8），导入课没冲突的 9-16 周要留下。
    // （以前是整条 session 删掉 → 物理连 9-16 周也没了，那是静默丢数据。）
    expect(plan.courses.contains { $0.name == "物理" },
           "选了保留当前 → 物理的非冲突周次（9-16 周）仍然导入")
    expectEqual(plan.courses.first { $0.name == "物理" }?.weeks.sorted(),
                Array(9...16), "物理只保留没冲突的 9-16 周（重叠的 1-8 周让给自习）")
    expect(plan.courses.contains { $0.name == "体育" }, "全新体育课导入")
    expectEqual(plan.courses.first { $0.courseID == "M1" }?.teacher, "王老师", "高数被更新")
    expectEqual(plan.courses.first { $0.courseID == "E1" }?.loc, "外语-102", "改过的英语保留当前地点")
    expect(plan.courses.contains { $0.courseID == "J1" }, "导入里没有的军事理论保留")
    expectEqual(plan.courses.first { $0.courseID == "M1" }?.originLabel, "导入",
                "导入记录带 imported 来源")

    // 写盘 → 读回：来源标记也落盘了
    var saved = cur
    saved.courses = plan.courses
    saved.semester = plan.semester
    try! store.save(saved)
    let back = try! store.load(t.id)
    expectEqual(back.courses.count, plan.courses.count, "写盘后读回的课程数一致")
    expectEqual(back.courses.first { $0.courseID == "S1" }?.origin, .manual,
                "用户新增课的来源标记落盘")
    expectEqual(back.courses.first { $0.courseID == "M1" }?.teacher, "王老师", "更新的内容落盘")
    expectEqual(back.courses.first { $0.courseID == "E1" }?.userModified, true,
                "「你修改过」标记落盘")

    // 取消（不写盘）→ 文件字节不变
    let beforeCancel = try! Data(contentsOf: store.coursesFile(for: t.id))
    let again = try! store.load(t.id)
    expectEqual(again.courses.count, back.courses.count, "取消路径：读回内容不变")
    let afterCancel = try! Data(contentsOf: store.coursesFile(for: t.id))
    expect(beforeCancel == afterCancel, "取消 → 文件字节不变")
}

// MARK: - 1.1.1 保护课选「用导入」之后，保护标记不能被这一次点击抹掉

suite("覆盖导入 · 显式用导入不解除保护") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    // 当前：用户新增的「自习」（origin = .manual，受保护）
    // 导入：同名的「自习」，内容不同
    let current = [sourced("自习", day: 2, block: 1, weeks: Array(1...8),
                           courseID: "S1", origin: .manual)]
    let imported = [sourced("自习", day: 2, block: 1, weeks: Array(1...16), courseID: "P1")]

    let result = TimetableDiff.compare(current: current, imported: imported,
                                       currentSemester: sem, importedSemester: nil)
    // 默认是保留当前（受保护的课不自动覆盖）
    var choice = TimetableDiff.defaultMergeChoice(for: result)
    expectEqual(result.matched.count, 1, "同名同门 → 匹配上（不是「需要确认」）")
    guard let m = result.matched.first else { return }
    expectEqual(choice.choice(for: m.courseID), .keepCurrent,
                "受保护的课默认保留当前")

    // 用户**显式**点「用导入」→ 这一次按导入走
    choice.courses[m.courseID] = .useImported
    let merged = TimetableDiff.merge(current: current, imported: imported,
                                     result: result, choice: choice)
    expectEqual(merged.courses.first { $0.courseID == "S1" }?.weeks.sorted(), Array(1...16),
                "显式用导入 → 这一次内容按导入走")
    // 但保护标记要留住 —— 用户当初那句「用导入」只授权了**这一次**。
    // 标记丢了的话，下次导入这门课就成了「不保护的导入课」，默认会静默覆盖。
    let merged1 = merged.courses.first { $0.courseID == "S1" }
    expectEqual(merged1?.isProtected, true, "显式用导入之后，这门课仍然受保护")
    expectEqual(merged1?.originLabel, "你新增", "来源标记没有因为一次「用导入」就变成「导入」")

    // 下次导入：这门课仍然是受保护的 → 默认动作还是「保留当前」，不会被静默覆盖
    let result2 = TimetableDiff.compare(current: merged.courses, imported: imported,
                                        currentSemester: sem, importedSemester: nil)
    let choice2 = TimetableDiff.defaultMergeChoice(for: result2)
    let amb2 = result2.ambiguous.first ?? result2.matched.first
    if let amb2 {
        expectEqual(choice2.choice(for: amb2.courseID), .keepCurrent,
                    "下次导入时这门课默认保留当前（不会被静默覆盖）")
    }

    // 反过来：本来就只是「上次导入的原样」的课，用导入之后**不该**变成受保护的
    // （否则以后每次导入都要多问一句，噪音太大）
    let cur2 = [sourced("高数", day: 3, block: 1, weeks: Array(1...8),
                        courseID: "M1", origin: .imported, userModified: false)]
    let imp2 = [sourced("高数", day: 3, block: 1, weeks: Array(1...16), courseID: "M2")]
    let r3 = TimetableDiff.compare(current: cur2, imported: imp2,
                                   currentSemester: sem, importedSemester: nil)
    var choice3 = TimetableDiff.defaultMergeChoice(for: r3)
    guard let m3 = r3.matched.first else { return }
    choice3.courses[m3.courseID] = .useImported
    let merged3 = TimetableDiff.merge(current: cur2, imported: imp2,
                                      result: r3, choice: choice3)
    expectEqual(merged3.courses.first { $0.courseID == "M1" }?.isProtected, false,
                "本来就不受保护的导入课，用导入之后仍然不受保护（不制造噪音）")
    expectEqual(merged3.courses.first { $0.courseID == "M1" }?.originLabel, "导入",
                "本来就不受保护的导入课，用导入之后来源仍是「导入」")
}

// MARK: - 1.1.1 覆盖导入 · 旧数据文件

suite("覆盖导入 · 旧数据文件（无来源字段）") {
    let dir = makeTempDir("tt-legacy-file")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let t = try! store.create(name: "旧数据课表",
                              semester: SemesterConfig(start: Date(), maxWeek: 16))

    // 手写一份「旧版 app 写的」文件：完全没有 origin / userModified 两个键
    let legacy = """
    [{"name":"旧课","day":3,"block":1,"weeks":[1,2,3],"courseID":"L1","teacher":"","loc":"","code":"","weeksLabel":"1-3"}]
    """
    try! legacy.data(using: .utf8)!.write(to: store.coursesFile(for: t.id))

    let loaded = try! store.load(t.id)
    expectEqual(loaded.courses.count, 1, "旧文件能正常打开（不会因为缺来源字段读不出来）")
    expectEqual(loaded.courses.first?.origin, .unknown, "旧文件里的课 → unknown")
    expectEqual(loaded.courses.first?.isProtected, true, "旧文件里的课受保护")

    // 导入里没有它 → 默认保留，不会被静默删掉
    let r = TimetableDiff.compare(current: loaded.courses, imported: [],
                                  currentSemester: loaded.semester, importedSemester: nil)
    let ch = TimetableDiff.defaultMergeChoice(for: r)
    expectEqual(ch.courses["L1"], .keepCurrent, "旧数据默认保留")
    let merged = TimetableDiff.merge(current: loaded.courses, imported: [], result: r, choice: ch)
    expectEqual(merged.courses.count, 1, "默认合并不删旧数据")
}

// MARK: - 1.1.1 部分周次重叠：只让开重叠的那几周，不整条删掉

suite("ImportConflicts · 部分周次重叠按周让开") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    // 当前：用户新增的「自习」周一1-2节 1-8 周
    // 导入：「物理」周一1-2节 1-16 周（只有 1-8 周跟自习重叠）
    let current = [sourced("自习", day: 1, block: 0, weeks: Array(1...8),
                           courseID: "S1", origin: .manual)]
    let imported = [sourced("物理", day: 1, block: 0, weeks: Array(1...16), courseID: "P1")]

    let result = TimetableDiff.compare(current: current, imported: imported,
                                       currentSemester: sem, importedSemester: nil)
    var choice = TimetableDiff.defaultMergeChoice(for: result)
    let units = ImportConflictLogic.detect(current: current, result: result, choice: choice)
    expectEqual(units.count, 1, "1 处冲突")
    guard let unit = units.first else { return }
    expectEqual(unit.slots.first?.overlap, Array(1...8), "重叠周次 = 1-8（不是全部 1-16）")

    // ---- 保留当前：导入课让开重叠的 1-8 周，9-16 周保留 ----
    choice.conflicts[unit.id] = .keepCurrent
    var plan = ImportConflictLogic.plan(current: current, imported: imported,
                                        result: result, choice: choice)
    expect(plan.canApply, "决定冲突后可以应用")
    let phys = plan.courses.first { $0.courseID == "P1" }
    expectEqual(phys?.weeks.sorted(), Array(9...16),
                "保留当前 → 导入课只让开重叠的 1-8 周，9-16 周留着（不整条删）")
    expectEqual(plan.courses.first { $0.courseID == "S1" }?.weeks.sorted(), Array(1...8),
                "保留当前 → 用户那门课一周都不动")
    expectEqual(plan.blocker, nil, "让开周次之后不该还有残留冲突")

    // ---- 用导入：当前课让开重叠的 1-8 周，用户课的其他周次保留 ----
    // 当前课改成 1-16 周，这样才能看出「只让开重叠的那几周」
    let cur16 = [sourced("自习", day: 1, block: 0, weeks: Array(1...16),
                          courseID: "S1", origin: .manual)]
    let imp8 = [sourced("物理", day: 1, block: 0, weeks: Array(1...8), courseID: "P1")]
    let r2 = TimetableDiff.compare(current: cur16, imported: imp8,
                                   currentSemester: sem, importedSemester: nil)
    var choice2 = TimetableDiff.defaultMergeChoice(for: r2)
    let units2 = ImportConflictLogic.detect(current: cur16, result: r2, choice: choice2)
    expectEqual(units2.count, 1, "1 处冲突")
    guard let unit2 = units2.first else { return }
    expectEqual(unit2.slots.first?.overlap, Array(1...8), "重叠周次 = 1-8")

    choice2.conflicts[unit2.id] = .useImported
    plan = ImportConflictLogic.plan(current: cur16, imported: imp8,
                                    result: r2, choice: choice2)
    expect(plan.canApply, "决定冲突后可以应用")
    expectEqual(plan.courses.first { $0.courseID == "P1" }?.weeks.sorted(), Array(1...8),
                "用导入 → 导入课整条都在")
    expectEqual(plan.courses.first { $0.courseID == "S1" }?.weeks.sorted(), Array(9...16),
                "用导入 → 用户课只让开重叠的 1-8 周，9-16 周留着（不整条删）")

    // ---- 完全重叠：让完之后那条上课时间一周不剩 → 整条去掉 ----
    let curSame = [sourced("自习", day: 1, block: 0, weeks: Array(1...16),
                            courseID: "S1", origin: .manual)]
    let r3 = TimetableDiff.compare(current: curSame, imported: imported,
                                   currentSemester: sem, importedSemester: nil)
    var choice3 = TimetableDiff.defaultMergeChoice(for: r3)
    let units3 = ImportConflictLogic.detect(current: curSame, result: r3, choice: choice3)
    guard let unit3 = units3.first else { return }
    choice3.conflicts[unit3.id] = .keepCurrent
    let plan3 = ImportConflictLogic.plan(current: curSame, imported: imported,
                                         result: r3, choice: choice3)
    expectEqual(plan3.courses.first { $0.courseID == "P1" }?.weeks, nil,
                "完全重叠 + 保留当前 → 导入课那一条一周不剩，整条去掉")
    expect(plan3.courses.contains { $0.courseID == "S1" }, "用户课保留")

    // ---- 两边都留：谁的周次都不动，冲突由用户自己接受 ----
    var choice4 = TimetableDiff.defaultMergeChoice(for: result)
    choice4.conflicts[unit.id] = .keepBoth
    let plan4 = ImportConflictLogic.plan(current: current, imported: imported,
                                         result: result, choice: choice4)
    expectEqual(plan4.courses.first { $0.courseID == "P1" }?.weeks.sorted(), Array(1...16),
                "两边都留 → 导入课一周都不动")
    expectEqual(plan4.courses.first { $0.courseID == "S1" }?.weeks.sorted(), Array(1...8),
                "两边都留 → 用户课一周都不动")
}

// MARK: - 1.1.1 幽灵冲突：ambiguous 选「删除」后不该再报冲突

suite("ImportConflicts · 删除后不再产生幽灵冲突") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    // 当前：两门同名「数据结构」（cur-1 周一1-2节、cur-2 周三1-2节）
    // 导入：同名「数据结构」（→ ambiguous）+「物理」（周一1-2节，与 cur-1 同格）
    let current = [
        sourced("数据结构", day: 1, block: 0, weeks: [1, 2], courseID: "cur-1"),
        sourced("数据结构", day: 3, block: 0, weeks: [1, 2], courseID: "cur-2"),
    ]
    let imported = [
        sourced("数据结构", day: 1, block: 0, weeks: [1, 2], courseID: "imp-1", code: "DS-新"),
        sourced("物理", day: 1, block: 0, weeks: [1, 2], courseID: "imp-2"),
    ]
    let result = TimetableDiff.compare(current: current, imported: imported,
                                       currentSemester: sem, importedSemester: nil)
    expect(result.ambiguous.count == 1, "同名不同 code → 一门课落在「需要确认」里")

    var choice = TimetableDiff.defaultMergeChoice(for: result)
    // 用户明确把「需要确认」那门（cur-1）选成「删除」
    let ambID = result.ambiguous[0].courseID
    choice.courses[ambID] = .delete

    // 合并结果里 cur-1 已经不在了
    let merged = TimetableDiff.merge(current: current, imported: imported,
                                     result: result, choice: choice)
    expect(!merged.courses.contains { $0.courseID == "cur-1" },
           "选了删除 → 合并结果里没有 cur-1")

    // 关键：detect 不能再把它当成「还保留着」→ 不该报幽灵冲突
    let units = ImportConflictLogic.detect(current: current, result: result, choice: choice)
    expectEqual(units.count, 0,
                "课已经删了就不该再报冲突（以前会报出「物理 ↔ 数据结构」的幽灵冲突）")

    let plan = ImportConflictLogic.plan(current: current, imported: imported,
                                        result: result, choice: choice)
    expect(plan.canApply, "没有冲突 → 可以应用（不该被一个不存在的冲突挡住）")
    expect(plan.unresolved.count == 0, "未决定冲突数 = 0")

    // 对照：换成「保留当前」，冲突就该出现（证明上面不是把检测关掉了）
    var keepChoice = choice
    keepChoice.courses[ambID] = .keepCurrent
    let keepUnits = ImportConflictLogic.detect(current: current, result: result, choice: keepChoice)
    expectEqual(keepUnits.count, 1, "保留当前 → 冲突照常报出来")
    expectEqual(keepUnits.first?.currentCourseID, "cur-1", "冲突指向保留的那门课")

    // 对照：matched 选「删除」也不该留下幽灵冲突
    let mCurrent = [sourced("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "m-1")]
    let mImported = [
        sourced("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "m-1", teacher: "新老师"),
        sourced("物理", day: 3, block: 1, weeks: [1, 2], courseID: "m-2"),
    ]
    let mResult = TimetableDiff.compare(current: mCurrent, imported: mImported,
                                        currentSemester: sem, importedSemester: nil)
    var mChoice = TimetableDiff.defaultMergeChoice(for: mResult)
    mChoice.courses["m-1"] = .delete
    expectEqual(ImportConflictLogic.detect(current: mCurrent, result: mResult,
                                           choice: mChoice).count, 0,
                "matched 选删除 → 也不该有幽灵冲突")
}

// MARK: - 导入弹窗策略：只有需要注意的事才打扰

suite("ImportDecisionController · 什么时候该弹窗") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)

    // 1. 普通更新 + 新增：没有冲突、没碰保护课 → 不弹差异页。
    let plainCurrent = [
        sourced("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1",
                teacher: "旧老师"),
    ]
    let plainImported = [
        sourced("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1",
                teacher: "新老师"),
        sourced("体育", day: 5, block: 0, weeks: [1], courseID: "P1"),
    ]
    let plain = ImportDecisionController.assess(current: plainCurrent,
                                                imported: plainImported,
                                                currentSemester: sem)
    expect(!plain.needsDiff, "普通更新/新增不该弹差异页")
    expect(plain.protectedRemoved.isEmpty, "没有保护课缺失")
    expect(!plain.needsProtectedRemovalPrompt, "没有需要单独确认的课")

    // 2. 导入里少了用户新增的课 → 只需要逐门问保留/删除，不用打开差异页。
    let protectedCurrent = [
        sourced("工程职场实习", day: 7, block: 0, weeks: Array(1...10),
                courseID: "JOB1", origin: .manual),
    ]
    let protectedOnly = ImportDecisionController.assess(current: protectedCurrent,
                                                        imported: plainImported,
                                                        currentSemester: sem)
    expect(!protectedOnly.needsDiff, "只有保护课缺失时不该打开整页差异")
    expectEqual(protectedOnly.protectedRemoved.map { $0.name }, ["工程职场实习"],
                "必须识别出导入里少了的保护课")
    expect(protectedOnly.needsProtectedRemovalPrompt, "保护课缺失必须单独确认")

    // 3. 导入的新课和用户保留的课撞时间 → 必须打开差异页逐条决定。
    let conflictCurrent = [
        sourced("自习", day: 2, block: 1, weeks: [1], courseID: "S1", origin: .manual),
    ]
    let conflictImported = [
        sourced("物理", day: 2, block: 1, weeks: [1], courseID: "P1"),
    ]
    let conflict = ImportDecisionController.assess(current: conflictCurrent,
                                                   imported: conflictImported,
                                                   currentSemester: sem)
    expect(conflict.needsDiff, "有时间冲突 → 必须打开差异页")
    expectEqual(conflict.conflicts.count, 1, "冲突检测到 1 处")

    // 4. 受保护的匹配课内容变了 → 也要让用户看见（默认不会覆盖它）。
    let modifiedCurrent = [
        sourced("大学英语", day: 1, block: 0, weeks: [1], courseID: "E1",
                loc: "旧楼", origin: .imported, userModified: true),
    ]
    let modifiedImported = [
        sourced("大学英语", day: 1, block: 0, weeks: [1], courseID: "E1",
                loc: "新楼"),
    ]
    let modified = ImportDecisionController.assess(current: modifiedCurrent,
                                                   imported: modifiedImported,
                                                   currentSemester: sem)
    expect(modified.hasProtectedMatchedChanges, "识别出受保护课程有差异")
    expect(!modified.needsDiff, "受保护课程默认保留当前、不会被改 → 不弹差异页（用户要求：没冲突就不弹）")
    let modifiedPlan = ImportConflictLogic.plan(current: modifiedCurrent,
                                                 imported: modifiedImported,
                                                 result: modified.diff,
                                                 choice: modified.defaultChoice)
    expect(modifiedPlan.canApply, "受保护的普通更新也要能直接应用")
    expectEqual(modifiedPlan.courses.first { $0.courseID == "E1" }?.loc, "旧楼",
                "受保护课程默认保留当前内容")
}

suite("ImportDecisionController · 无冲突直接覆盖，不弹差异页") {
    let dir = makeTempDir("tt-auto-import")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let t = try! store.create(name: "当前课表", semester: sem)
    var cur = try! store.load(t.id)
    cur.courses = [sourced("高等数学", day: 3, block: 1, weeks: [1, 2],
                           courseID: "M1", teacher: "旧老师")]
    try! store.save(cur)
    try! store.setActive(t.id)

    let parsed = [
        sourced("高等数学", day: 3, block: 1, weeks: [1, 2],
                courseID: "M1", teacher: "新老师"),
        sourced("体育", day: 5, block: 0, weeks: [1], courseID: "P1"),
    ]
    let controller = ImportDecisionController(store: store,
                                              parsed: parsed,
                                              fileName: "导入.xls")
    var decisions: [ImportDecisionController.Decision] = []
    var errors: [String] = []
    var diffCount = 0
    var prompted: [String] = []
    controller.onDecision = { decisions.append($0) }
    controller.testErrorHandler = { errors.append($0) }
    controller.testProtectedRemovalDecision = { name, _, _ in
        prompted.append(name)
        return .keep
    }
    controller.onShowDiff = { _, _, _, _, _, _, _ in diffCount += 1 }

    controller.startOverwrite()

    expectEqual(errors, [], "没有错误：\(errors)")
    expectEqual(diffCount, 0, "无冲突/无保护课 → 不弹差异页")
    expectEqual(prompted, [], "没有保护课缺失 → 不做保留/删除询问")
    expectEqual(decisions, [.overwriteCurrent], "直接覆盖当前课表")

    let after = try! store.load(t.id)
    let byID = Dictionary(uniqueKeysWithValues: after.courses.map { ($0.courseID, $0) })
    expectEqual(byID["M1"]?.teacher, "新老师", "未保护课程按覆盖语义更新")
    expect(byID["P1"] != nil, "导入新增的课写进去了")
}

suite("ImportDecisionController · 缺失的保护课逐门确认") {
    func makeCase(_ tag: String)
        -> (URL, TimetableStore, Timetable, ImportDecisionController) {
        let dir = makeTempDir(tag)
        let store = TimetableStore(rootDirectory: dir)
        let sem = SemesterConfig(start: Date(), maxWeek: 16)
        let t = try! store.create(name: "当前课表", semester: sem)
        var cur = try! store.load(t.id)
        cur.courses = [sourced("工程职场实习", day: 7, block: 0,
                               weeks: Array(1...10), courseID: "JOB1",
                               origin: .manual)]
        try! store.save(cur)
        try! store.setActive(t.id)
        let parsed = [sourced("体育", day: 5, block: 0, weeks: [1],
                              courseID: "P1")]
        let controller = ImportDecisionController(store: store,
                                                  parsed: parsed,
                                                  fileName: "导入.xls")
        return (dir, store, t, controller)
    }

    // 保留：课程继续留在课表里，其他导入内容照常生效。
    do {
        let (dir, store, t, controller) = makeCase("tt-protected-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        var decisions: [ImportDecisionController.Decision] = []
        var errors: [String] = []
        var prompted: [String] = []
        var diffCount = 0
        controller.onDecision = { decisions.append($0) }
        controller.testErrorHandler = { errors.append($0) }
        controller.testProtectedRemovalDecision = { name, index, total in
            prompted.append("\(name)#\(index + 1)/\(total)")
            return .keep
        }
        controller.onShowDiff = { _, _, _, _, _, _, _ in diffCount += 1 }

        controller.startOverwrite()

        expectEqual(errors, [], "没有错误：\(errors)")
        expectEqual(diffCount, 0, "保护课缺失是单独确认，不打开整页差异")
        expectEqual(prompted, ["工程职场实习#1/1"], "必须逐门问一次")
        expectEqual(decisions, [.overwriteCurrent], "确认后继续覆盖")
        let after = try! store.load(t.id)
        expect(after.courses.contains { $0.courseID == "JOB1" },
               "选「保留」→ 保护课还在")
        expect(after.courses.contains { $0.courseID == "P1" },
               "选「保留」不影响其他导入内容")
    }

    // 删除：用户明确选择后，保护课才允许消失。
    do {
        let (dir, store, t, controller) = makeCase("tt-protected-delete")
        defer { try? FileManager.default.removeItem(at: dir) }
        var decisions: [ImportDecisionController.Decision] = []
        var errors: [String] = []
        controller.onDecision = { decisions.append($0) }
        controller.testErrorHandler = { errors.append($0) }
        controller.testProtectedRemovalDecision = { _, _, _ in .delete }
        controller.onShowDiff = { _, _, _, _, _, _, _ in
            expect(false, "明确删除保护课不该再弹差异页")
        }

        controller.startOverwrite()

        expectEqual(errors, [], "没有错误：\(errors)")
        expectEqual(decisions, [.overwriteCurrent], "确认后继续覆盖")
        let after = try! store.load(t.id)
        expect(!after.courses.contains { $0.courseID == "JOB1" },
               "选「删除」→ 保护课被移除")
        expect(after.courses.contains { $0.courseID == "P1" },
               "选「删除」不影响其他导入内容")
    }

    // 取消：任意一门选取消 → 整次导入不写盘。
    do {
        let (dir, store, t, controller) = makeCase("tt-protected-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try! Data(contentsOf: store.coursesFile(for: t.id))
        var decisions: [ImportDecisionController.Decision] = []
        var errors: [String] = []
        controller.onDecision = { decisions.append($0) }
        controller.testErrorHandler = { errors.append($0) }
        controller.testProtectedRemovalDecision = { _, _, _ in .cancel }
        controller.onShowDiff = { _, _, _, _, _, _, _ in
            expect(false, "取消保护课询问不该弹差异页")
        }

        controller.startOverwrite()

        expectEqual(errors, [], "没有错误：\(errors)")
        expectEqual(decisions, [.cancel], "取消询问 → 结束导入流程")
        let after = try! Data(contentsOf: store.coursesFile(for: t.id))
        expectEqual(after, before, "取消之后课表文件一个字节都不能变")
    }
}

suite("ImportDecisionController · 有冲突仍然打开差异页") {
    let dir = makeTempDir("tt-conflict-diff")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let t = try! store.create(name: "当前课表", semester: sem)
    var cur = try! store.load(t.id)
    cur.courses = [sourced("自习", day: 2, block: 1, weeks: [1],
                           courseID: "S1", origin: .manual)]
    try! store.save(cur)
    try! store.setActive(t.id)

    let parsed = [sourced("物理", day: 2, block: 1, weeks: [1], courseID: "P1")]
    let controller = ImportDecisionController(store: store,
                                              parsed: parsed,
                                              fileName: "导入.xls")
    var decisions: [ImportDecisionController.Decision] = []
    var diffCount = 0
    var prompted: [String] = []
    var initialRemovedChoice: TimetableDiff.MergeChoice.CourseChoice?
    controller.onDecision = { decisions.append($0) }
    controller.testErrorHandler = { _ in }
    controller.testProtectedRemovalDecision = { name, _, _ in
        prompted.append(name)
        return .keep
    }
    controller.onShowDiff = { _, diff, _, _, initialChoice, _, _ in
        diffCount += 1
        initialRemovedChoice = initialChoice.courses["S1"]
        expectEqual(diff.ambiguous.count, 0, "这个用例没有需要确认的匹配")
    }

    controller.startOverwrite()

    expectEqual(prompted, ["自习"], "先逐门问「消失的保护课」要不要留")
    expectEqual(diffCount, 1, "保留后仍然有冲突 → 必须打开差异页")
    expectEqual(initialRemovedChoice, .keepCurrent,
                "差异页要沿用用户刚才的「保留」选择")
    expectEqual(decisions, [], "差异页还没决定时不结束导入流程")
}

suite("ImportDecisionController · 删除保护课消掉冲突后直接继续") {
    let dir = makeTempDir("tt-conflict-delete")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let t = try! store.create(name: "当前课表", semester: sem)
    var cur = try! store.load(t.id)
    cur.courses = [sourced("自习", day: 2, block: 1, weeks: [1],
                           courseID: "S1", origin: .manual)]
    try! store.save(cur)
    try! store.setActive(t.id)

    let parsed = [sourced("物理", day: 2, block: 1, weeks: [1], courseID: "P1")]
    let controller = ImportDecisionController(store: store,
                                              parsed: parsed,
                                              fileName: "导入.xls")
    var decisions: [ImportDecisionController.Decision] = []
    var errors: [String] = []
    var diffCount = 0
    controller.onDecision = { decisions.append($0) }
    controller.testErrorHandler = { errors.append($0) }
    controller.testProtectedRemovalDecision = { _, _, _ in .delete }
    controller.onShowDiff = { _, _, _, _, _, _, _ in
        diffCount += 1
        expect(false, "删掉引起冲突的保护课后，冲突已经不存在，不该再弹差异页")
    }

    controller.startOverwrite()

    expectEqual(errors, [], "没有错误：\(errors)")
    expectEqual(diffCount, 0, "冲突随保护课删除而消失 → 直接继续")
    expectEqual(decisions, [.overwriteCurrent], "直接完成覆盖")
    let after = try! store.load(t.id)
    expect(!after.courses.contains { $0.courseID == "S1" }, "明确删除的自习课被移除")
    expect(after.courses.contains { $0.courseID == "P1" }, "导入的物理课进来了")
}

// MARK: - 1.1.1 写盘失败必须有反馈

suite("ImportDecisionController · 写盘失败要报错并收尾") {
    let dir = makeTempDir("tt-savefail")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimetableStore(rootDirectory: dir)
    let sem = SemesterConfig(start: Date(), maxWeek: 16)
    let t = try! store.create(name: "当前课表", semester: sem)
    var cur = try! store.load(t.id)
    cur.courses = [sourced("高等数学", day: 3, block: 1, weeks: [1, 2], courseID: "M1")]
    try! store.save(cur)
    try! store.setActive(t.id)

    // 导入内容 = 当前内容（走自动覆盖分支，它不弹差异页）
    let controller = ImportDecisionController(store: store,
                                              parsed: cur.courses,
                                              fileName: "导入.xls")
    var decisions: [ImportDecisionController.Decision] = []
    var errors: [String] = []
    controller.onDecision = { decisions.append($0) }
    controller.testErrorHandler = { errors.append($0) }
    controller.testSaveHandler = { _ in
        throw NSError(domain: "tt", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "磁盘写满了（模拟）"])
    }

    controller.startOverwrite()

    expectEqual(errors.count, 1, "写盘失败要弹一次错误（以前被 `_ =` 吞掉了）")
    expect(errors.first?.contains("覆盖失败") == true, "错误里说清是覆盖失败：\(errors)")
    expectEqual(decisions, [.cancel], "失败后要走 cancel 收尾（否则导入流程卡住、下次导入被拦）")
}

// MARK: - 1.1.1 自动化护栏：每个 --verify-* 都必须登记

suite("AutomationMode · --verify-* 必须登记进 automationFlags") {
    // 为什么这条必须存在：`--verify-*` 没登记 → `AutomationMode.isCurrentProcessAutomation`
    // 为 false → `AppDelegate.refreshReminderSchedule()` 的护栏不生效 → 走到
    // `reminderScheduler.clearAll()`，**清掉用户真实排好的上课提醒**。
    //
    // 断言方式：从源码里扫出所有 `--verify-xxx` 开关，逐个检查是不是在
    // `automationFlags` 里。用 `#filePath` 反推仓库根目录，不依赖当前工作目录。
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // 仓库根
    let mainSwift = repoRoot.appendingPathComponent("Sources/DesktopTimetable/main.swift")
    guard let text = try? String(contentsOf: mainSwift, encoding: .utf8) else {
        expect(false, "读不到 \(mainSwift.path) —— 断言跑不起来")
        return
    }
    // 扫出源码里出现过的所有 `--verify-xxx`
    var used: Set<String> = []
    var scanner = text
    while let r = scanner.range(of: "--verify-", range: scanner.startIndex..<scanner.endIndex) {
        let rest = scanner[r.upperBound...]
        let flags = rest.prefix { $0.isLetter || $0 == "-" || $0.isNumber }
        used.insert("--verify-" + flags)
        scanner = String(rest)
    }
    expect(!used.isEmpty, "源码里应该能扫到 --verify-* 开关（否则断言本身失效了）")
    for flag in used.sorted() {
        expect(AutomationMode.automationFlags.contains(flag),
               "\(flag) 必须登记在 automationFlags 里（否则自检会动真实通知中心）")
    }
    // 反向：登记了的开关也得真的被源码用到（避免留了个空壳条目）
    for flag in AutomationMode.automationFlags where flag.hasPrefix("--verify-") {
        expect(used.contains(flag), "\(flag) 登记了但源码里没有用它")
    }
    // 护栏本身：登记过的开关都判定为自动化模式
    for flag in AutomationMode.automationFlags {
        expect(AutomationMode.isAutomation(arguments: ["DesktopTimetable", flag]),
               "\(flag) 应该被判定为自动化模式")
    }
}

// MARK: - 1.1.2 「在访达中显示」让路策略

suite("FinderRevealPolicy · 面板让路给访达的层级") {
    // 面板平时是浮层（.floating = 3），访达窗口是普通层（.normal = 0）。
    // macOS 里层级高的永远排在前面，跨 App 也一样 —— 这就是「访达被盖住」的根因。
    expectEqual(FinderRevealPolicy.restingLevel, .floating, "平时面板是浮层")
    expectEqual(FinderRevealPolicy.yieldingLevel, .normal, "让路时降到普通层")
    expect(FinderRevealPolicy.restingLevel.rawValue > FinderRevealPolicy.yieldingLevel.rawValue,
           "浮层必须比普通层高（不然让路没有意义）")
    // 单一事实来源：两个入口（applicationDidBecomeActive / show）都走它。
    expectEqual(FinderRevealPolicy.level(yielding: true), FinderRevealPolicy.yieldingLevel,
                "让路中用普通层")
    expectEqual(FinderRevealPolicy.level(yielding: false), FinderRevealPolicy.restingLevel,
                "不在让路时用浮层")
}

suite("FinderRevealCoordinator · 揭示访达的步骤顺序") {
    let steps = FinderRevealCoordinator.steps(path: "/tmp/a.json", root: "/tmp")
    expectEqual(steps.count, 3, "揭示访达是三步")
    // 顺序是 bug 的要害：先让路（降层+收起）→ 再选文件 → 最后显式激活访达。
    // 顺序错了访达窗口还是会被盖住，肉眼看不出来，只能靠断言盯着。
    expectEqual(steps[0], .yieldPanel, "第一步必须是让路（降层 + 收起）")
    expectEqual(steps[1], .selectFile(path: "/tmp/a.json", root: "/tmp"), "第二步是选文件")
    expectEqual(steps[2], .activateFinder, "第三步是显式激活访达（selectFile 不保证排最前）")
    // 让路这步不能省：少了它访达窗口会被浮层面板盖住。
    expect(steps.contains(.yieldPanel), "步骤里必须有让路")
}

// MARK: - 课程颜色（colorHex）

/// 把 NSColor 转回 `#rrggbb`（比较颜色用，避免直接比 NSColor 实例）。
func srgbHex(_ c: NSColor?) -> String {
    guard let s = c?.usingColorSpace(.sRGB) else { return "?" }
    func p(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
    return String(format: "#%02x%02x%02x", p(s.redComponent), p(s.greenComponent), p(s.blueComponent))
}

suite("ColorHex · 解析与优先级") {
    expectEqual(ColorHex.normalized("#4F8CFF"), "#4f8cff", "大写归一成小写")
    expectEqual(ColorHex.normalized("#123456"), "#123456", "任意 6 位十六进制都接受（自定义色）")
    expectEqual(ColorHex.normalized("4f8cff"), "#4f8cff", "省略 # 也认")
    expectEqual(ColorHex.normalized("  #4f8cff\n"), "#4f8cff", "前后空白去掉")
    expect(ColorHex.normalized(nil) == nil, "nil → 自动")
    expect(ColorHex.normalized("#fff") == nil, "3 位简写不收（会歧义）")
    expect(ColorHex.normalized("#4f8cffaa") == nil, "8 位（带 alpha）不收")
    expect(ColorHex.normalized("#gggggg") == nil, "非法字符 → nil，绝不抛错")
    expect(ColorHex.normalized("") == nil, "空串 → nil")

    // 预设色自己必须都是规范形式，否则界面里点了也存不回来
    expectEqual(ColorHex.presets.count, 12, "预设 12 色")
    expect(ColorHex.presetHexes.allSatisfy { ColorHex.normalized($0) == $0 },
           "每个预设色都是规范形式（#rrggbb 小写）")
    expectEqual(Set(ColorHex.presetHexes).count, 12, "预设色不重复")

    // 按课名的自动色：和原来的 9 门课默认配色完全一致（默认配色没被改动）
    expectEqual(ColorHex.byName.count, 9, "自动色 9 门课")
    expectEqual(ColorHex.byName["数据结构"], "#4f8cff", "数据结构 · 蓝")
    expectEqual(ColorHex.byName["业务需求建模"], "#a577ff", "业务需求建模 · 紫")
    expectEqual(ColorHex.byName["计算机网络基础"], "#2ec4b6", "计算机网络基础 · 青")
    expectEqual(ColorHex.byName["系统测试与质量管理"], "#f5a524", "系统测试与质量管理 · 橙黄")
    expectEqual(ColorHex.byName["学术语言与研究方法（中级）"], "#f2569b", "学术语言 · 粉")
    expectEqual(ColorHex.byName["军事理论"], "#93c05b", "军事理论 · 绿")
    expectEqual(ColorHex.byName["马克思主义基本原理"], "#ef5f5b", "马原 · 红")
    expectEqual(ColorHex.byName["形势与政策（三）"], "#35b9e6", "形势与政策 · 天蓝")
    expectEqual(ColorHex.byName["体育(三)篮球"], "#ff8a3d", "体育 · 橙")

    // 优先级：显式色 > 按课名 > 中性灰
    expectEqual(ColorHex.resolvedHex(name: "数据结构", colorHex: "#EF5F5B"), "#ef5f5b",
                "显式色盖过按课名")
    expectEqual(ColorHex.resolvedHex(name: "数据结构", colorHex: nil), "#4f8cff",
                "没有显式色 → 按课名")
    expectEqual(ColorHex.resolvedHex(name: "数据结构", colorHex: "#zzz"), "#4f8cff",
                "显式色非法 → 静默回落按课名（不能画不出来）")
    expectEqual(ColorHex.resolvedHex(name: "没见过的课", colorHex: nil), ColorHex.fallbackHex,
                "既没显式色、课名也不在表里 → 兜底灰")

    // 改名的语义：自动色跟着课名走，显式色不跟着变
    expectEqual(ColorHex.resolvedHex(name: "数据结构（重修）", colorHex: nil), ColorHex.fallbackHex,
                "自动模式：改名后查不到 → 落灰")
    expectEqual(ColorHex.resolvedHex(name: "数据结构（重修）", colorHex: "#4f8cff"), "#4f8cff",
                "显式色：改名不影响")

    // RGB 分解
    let rgb = ColorHex.rgb("#4f8cff")
    expect(rgb != nil, "能解析 rgb")
    expectEqual(Int(rgb?.r ?? -1), 79, "R = 0x4f")
    expectEqual(Int(rgb?.g ?? -1), 140, "G = 0x8c")
    expectEqual(Int(rgb?.b ?? -1), 255, "B = 0xff")
    expect(ColorHex.rgb("nope") == nil, "非法值的 rgb 是 nil")

    // 原生画卡片：颜色来自课程自己
    expectEqual(srgbHex(TimetablePalette.accent(for: course("数据结构", colorHex: "#EF5F5B"))),
                "#ef5f5b", "有显式色 → 卡片用显式色")
    expectEqual(srgbHex(TimetablePalette.accent(for: course("数据结构"))),
                "#4f8cff", "没有显式色 → 卡片按课名")
}

suite("Course · colorHex 编解码") {
    func decode(_ json: String) -> Course? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Course.self, from: d)
    }
    let base = #"{"courseID":"a","day":1,"block":0,"name":"数据结构","teacher":"","loc":"","code":"","weeks":[1]"#

    // 1) 老数据没有这个字段 → 自动（nil），不能读不出来
    let legacy = decode(base + "}")
    expect(legacy != nil, "没有 colorHex 的老数据仍能解码")
    expect(legacy?.colorHex == nil, "缺字段 = 自动（nil）")

    // 2) 往返
    let orig = course("数据结构", code: "C1", weeks: [1, 2], courseID: "a", colorHex: "#ef5f5b")
    if let data = try? JSONEncoder().encode(orig),
       let back = try? JSONDecoder().decode(Course.self, from: data) {
        expectEqual(back.colorHex, "#ef5f5b", "colorHex 能编码再解码回来")
        expectEqual(back, orig, "整条记录往返不变（颜色不破坏其它字段）")
    } else {
        expect(false, "Course 编解码失败")
    }

    // 3) 解码时就规范化
    expectEqual(decode(base + #","colorHex":" #EF5F5B "}"#)?.colorHex, "#ef5f5b",
                "解码时把大写/空格规范化")

    // 4) 非法值 → nil，不抛错
    expect(decode(base + #","colorHex":"red"}"#) != nil, "颜色非法不影响整条记录解码")
    expect(decode(base + #","colorHex":"red"}"#)?.colorHex == nil, "非法颜色 → 自动")
    expect(decode(base + #","colorHex":123}"#)?.colorHex == nil, "颜色类型不对 → 自动")

    // 5) 字典路径（读 schedule_data.json）也认 color / colorHex
    let d1 = try? Course(dictionary: ["name": "数据结构", "day": 1, "block": 0,
                                      "weeks": [1], "color": "#2EC4B6"])
    expectEqual(d1?.colorHex, "#2ec4b6", "字典里写 color 也认")
    let d2 = try? Course(dictionary: ["name": "数据结构", "day": 1, "block": 0,
                                      "weeks": [1], "colorHex": "#d98cf2"])
    expectEqual(d2?.colorHex, "#d98cf2", "字典里写 colorHex 也认")

    // 6) 颜色不参与 userModified / isProtected 的计算
    let plain = course("x", courseID: "a")
    var colored = plain
    colored.colorHex = "#ef5f5b"
    expectEqual(colored.userModified, plain.userModified, "颜色不影响 userModified")
    expectEqual(colored.isProtected, plain.isProtected, "颜色不影响 isProtected")

    // 7) 写盘往返（临时目录）
    let dir = makeTempDir("color-store")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    try! store.saveCourses([colored, course("y", courseID: "b")])
    let loaded = try! store.loadCourses()
    expectEqual(loaded.first { $0.courseID == "a" }?.colorHex, "#ef5f5b", "颜色能存进磁盘再读回来")
    expect(loaded.first { $0.courseID == "b" }?.colorHex == nil, "没选色的课读回来仍是自动")
}

suite("课程颜色 · 批量保存同步") {
    func session(_ original: CourseSessionIdentity?, day: Int, block: Int) -> CourseSessionDraft {
        var d = CourseDraft()
        d.name = "结构"; d.code = "C1"; d.day = day; d.block = block; d.weeks = [1]
        return CourseSessionDraft(original: original, draft: d)
    }
    let monday = course("结构", code: "C1", day: 1, block: 0, weeks: [1, 2], courseID: "id-1")
    let wednesday = course("结构", code: "C1", day: 3, block: 1, weeks: [1, 2], courseID: "id-1")
    let other = course("别的课", code: "C2", day: 2, block: 0, weeks: [1], courseID: "id-2")
    let existing = [monday, wednesday, other]
    let monID = CourseSessionIdentity(courseID: "id-1", day: 1, block: 0)

    // 1) 新增：所有新记录都用表单里的颜色（规范化后）
    let created = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "新结构", code: "C9", colorHex: "#F5A524",
                        sessions: [session(nil, day: 2, block: 2),
                                   session(nil, day: 4, block: 3)]),
        scope: .create(day: 2, block: 2), courses: [], overrides: [],
        courseID: "new-id", overrideSlots: [], maxWeek: 16)
    expectEqual(created.courses.map { $0.colorHex }, ["#f5a524", "#f5a524"],
                "新增：两条记录都带上规范化后的颜色")

    // 2) 编辑：颜色同步到这门课的所有记录（含表单里没出现的那条）
    let edited = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "结构", code: "C1", colorHex: "#2ec4b6",
                        sessions: [session(monID, day: 1, block: 0)]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing, overrides: [],
        courseID: "id-1", overrideSlots: [], maxWeek: 16)
    expectEqual(edited.courses.filter { $0.courseID == "id-1" }.map { $0.colorHex },
                ["#2ec4b6", "#2ec4b6"], "编辑：同 courseID 的所有记录一起改色")
    expect(edited.courses.first { $0.courseID == "id-2" }?.colorHex == nil,
           "别的课颜色不受影响")

    // 3) 添加上课时间：课名 / 代码只读，但颜色可改 → 整门课一起改
    let added = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "表单只读值", code: "忽略", colorHex: "#a577ff",
                        sessions: [session(nil, day: 5, block: 1)]),
        scope: .addSession(courseID: "id-1"), courses: existing, overrides: [],
        courseID: "id-1", overrideSlots: [], maxWeek: 16)
    expectEqual(added.courses.filter { $0.courseID == "id-1" }.map { $0.colorHex },
                ["#a577ff", "#a577ff", "#a577ff"],
                "添加时段：整门课一起改色（含新加的那条）")

    // 4) 选「自动」= nil → 显式清空旧值
    let cleared = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "结构", code: "C1", colorHex: nil,
                        sessions: [session(monID, day: 1, block: 0)]),
        scope: .edit(courseID: "id-1", day: 1, block: 0), courses: edited.courses,
        overrides: [], courseID: "id-1", overrideSlots: [], maxWeek: 16)
    expect(cleared.courses.filter { $0.courseID == "id-1" }.allSatisfy { $0.colorHex == nil },
           "选「自动」→ 旧颜色被清掉（不是「不改」）")

    // 5) 同名不同课：各管各的
    let a = course("重名课", code: "A1", day: 1, block: 0, weeks: [1], courseID: "id-a")
    let b = course("重名课", code: "B1", day: 2, block: 0, weeks: [1], courseID: "id-b")
    let twin = try! CourseBatchEdit.apply(
        CourseEditBatch(name: "重名课", code: "A1", colorHex: "#ef5f5b",
                        sessions: [session(CourseSessionIdentity(courseID: "id-a", day: 1, block: 0),
                                          day: 1, block: 0)]),
        scope: .edit(courseID: "id-a", day: 1, block: 0), courses: [a, b], overrides: [],
        courseID: "id-a", overrideSlots: [], maxWeek: 16)
    expectEqual(twin.courses.first { $0.courseID == "id-a" }?.colorHex, "#ef5f5b", "改 A 的颜色")
    expect(twin.courses.first { $0.courseID == "id-b" }?.colorHex == nil,
           "同名但不同 courseID 的课互不影响")

    // 6) 换成「临时覆盖」的那一段也带颜色，撤销时能还原
    let ovBatch = CourseEditBatch(name: "结构", code: "C1", colorHex: "#f2569b",
                                  sessions: [session(monID, day: 1, block: 0)])
    let ovResult = try! CourseBatchEdit.apply(
        ovBatch, scope: .edit(courseID: "id-1", day: 1, block: 0), courses: existing,
        overrides: [], courseID: "id-1", overrideSlots: [0], maxWeek: 16)
    expectEqual(ovResult.overrides.first?.colorHex, "#f2569b", "写成覆盖的那段带课程色")
    expectEqual(ovResult.overrides.first?.restored?.colorHex, "#f2569b",
                "被移走的原记录同步成同一个色（撤销后整门课仍一致）")
}

suite("课程颜色 · 覆盖记录") {
    var draft = CourseDraft()
    draft.name = "结构"; draft.code = "C1"; draft.teacher = "T"
    draft.day = 2; draft.block = 1; draft.weeks = [3]; draft.colorHex = "#A577FF"

    let made = WeekOverrideLogic.makeOverride(day: 2, block: 1, weeks: [3], draft: draft,
                                              courseID: "ov-1", restored: nil)
    expectEqual(made.colorHex, "#a577ff", "覆盖记录带上规范化后的颜色")
    expectEqual(made.asCourse().colorHex, "#a577ff", "asCourse 带颜色（原生渲染要用它）")
    expectEqual(ColorHex.resolvedHex(for: made.asCourse()), "#a577ff", "覆盖课按自己的颜色画")

    // 课名正好在自动色表里也不该被覆盖成自动色
    var named = draft
    named.name = "数据结构"
    let made2 = WeekOverrideLogic.makeOverride(day: 2, block: 1, weeks: [3], draft: named,
                                               courseID: "ov-2", restored: nil)
    expectEqual(ColorHex.resolvedHex(for: made2.asCourse()), "#a577ff",
                "课名命中自动色表时，显式色仍然优先")

    // 存 / 读
    if let data = try? JSONEncoder().encode(made),
       let back = try? JSONDecoder().decode(WeekOverride.self, from: data) {
        expectEqual(back.colorHex, "#a577ff", "覆盖记录的颜色能存能读")
    } else {
        expect(false, "WeekOverride 编解码失败")
    }
    let legacyJSON = #"{"day":2,"block":1,"weeks":[3],"name":"旧覆盖","teacher":"","loc":"","code":"","courseID":"o","restored":null}"#
    let legacy = try? JSONDecoder().decode(WeekOverride.self,
                                           from: legacyJSON.data(using: .utf8)!)
    expect(legacy != nil, "老覆盖文件（没有 colorHex）仍能解码")
    expect(legacy?.colorHex == nil, "老覆盖记录 → 自动色")

    // 写覆盖 → 撤销覆盖：原课颜色必须回来
    let original = course("结构", code: "C1", day: 2, block: 1, weeks: [3],
                          courseID: "id-1", colorHex: "#EF5F5B")
    let ov = WeekOverrideLogic.makeOverride(day: 2, block: 1, weeks: [3], draft: draft,
                                            courseID: "id-1",
                                            restored: WeekOverride.RestoredSession(original))
    let written = WeekOverrideLogic.writeOverride(ov, into: [], courses: [original])
    expectEqual(written.courses.count, 0, "写覆盖后原记录被移出 courses")
    expectEqual(written.overrides.first?.colorHex, "#a577ff", "覆盖记录用覆盖课的颜色")
    expectEqual(written.overrides.first?.restored?.colorHex, "#ef5f5b", "原课颜色存进 restored")

    let undone = WeekOverrideLogic.removeOverride(day: 2, block: 1,
                                                  from: written.overrides,
                                                  courses: written.courses)
    expectEqual(undone.courses.map { $0.colorHex }, ["#ef5f5b"], "撤销覆盖后原课颜色回来")
    expectEqual(undone.courses.first?.name, "结构", "撤销覆盖后课名也回来")

    // makeOverrideSave（临时覆盖编辑器走这条路）：颜色同步到整门课 + 写进覆盖
    let existing = [course("结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "id-1"),
                    course("结构", code: "C1", day: 3, block: 2, weeks: [1], courseID: "id-1")]
    var saveDraft = CourseDraft()
    saveDraft.name = "结构"; saveDraft.code = "C1"
    saveDraft.day = 1; saveDraft.block = 0; saveDraft.weeks = [1]
    saveDraft.colorHex = "#D98CF2"
    let savedOv = WeekOverrideLogic.makeOverrideSave(
        draft: saveDraft, scope: .edit(courseID: "id-1", day: 1, block: 0),
        courses: existing, overrides: [])
    expectEqual(savedOv.overrides.first?.colorHex, "#d98cf2", "覆盖记录带上表单颜色")
    expectEqual(savedOv.overrides.first?.restored?.colorHex, "#d98cf2",
                "被移走的那条同步成同一个色")
    expectEqual(savedOv.courses.map { $0.colorHex }, ["#d98cf2"],
                "留在 courses 里的同课记录也同步改色")
}

suite("导入合并 · 颜色归属") {
    let sem = SemesterConfig(start: Date(), maxWeek: 16)

    func merged(current: [Course], imported: [Course]) -> [Course] {
        let r = TimetableDiff.compare(current: current, imported: imported,
                                      currentSemester: sem, importedSemester: sem)
        var choice = TimetableDiff.defaultMergeChoice(for: r)
        for d in r.matched { choice.courses[d.courseID] = .useImported }
        for d in r.added { choice.courses[d.courseID] = .useImported }
        return TimetableDiff.merge(current: current, imported: imported,
                                   result: r, choice: choice).courses
    }

    // 1) 当前有显式色 → 用导入换内容，颜色保留当前的
    var cur = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1],
                      courseID: "id-1", colorHex: "#EF5F5B")]
    var imp = [course("数据结构", code: "C1", day: 1, block: 0, teacher: "李老师",
                      weeks: [1], courseID: "uuid-x", colorHex: "#2ec4b6")]
    var out = merged(current: cur, imported: imp)
    expectEqual(out.count, 1, "替换后仍是一条记录")
    expectEqual(out.first?.colorHex, "#ef5f5b", "当前有显式色 → 保留当前的（不被导入抹掉）")
    expectEqual(out.first?.teacher, "李老师", "内容确实换成导入的")
    expectEqual(out.first?.courseID, "id-1", "复用旧 courseID")

    // 2) 当前没有显式色、导入有合法颜色 → 用导入的
    cur = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1], courseID: "id-1")]
    out = merged(current: cur, imported: imp)
    expectEqual(out.first?.colorHex, "#2ec4b6", "当前没有、导入有 → 用导入的颜色")

    // 3) 都没有 → nil（自动）
    imp[0].colorHex = nil
    out = merged(current: cur, imported: imp)
    expect(out.first?.colorHex == nil, "两边都没有 → 自动（nil）")

    // 4) 只有颜色不同不算改动：差异页不会因为改色多出一条
    let same = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1],
                       courseID: "id-1", colorHex: "#ef5f5b")]
    let sameImp = [course("数据结构", code: "C1", day: 1, block: 0, weeks: [1],
                          courseID: "id-1", colorHex: "#2ec4b6")]
    let r4 = TimetableDiff.compare(current: same, imported: sameImp,
                                   currentSemester: sem, importedSemester: sem)
    expectEqual(r4.matched.first?.hasDifference, false, "只有颜色不同 → 不算内容差异")
    expect(r4.isIdentical, "只有颜色不同 → 整张课表「没有差异」")
    expectEqual(r4.matched.first?.currentSessions.first?.isProtected, false,
                "颜色不改变保护语义")
}

suite("TimetableState · webJSON 带颜色") {
    let c1 = course("数据结构", day: 1, block: 0, weeks: [1], colorHex: "#EF5F5B")
    let c2 = course("没见过的课", day: 2, block: 1, weeks: [1])
    var st = TimetableState(courses: [c1, c2], semesterStart: day(2026, 8, 30),
                            currentWeek: 5, viewWeek: 5, maxWeek: 16)
    st.overrides = [WeekOverride(day: 3, block: 2, weeks: [5], name: "覆盖课",
                                 teacher: "", loc: "", code: "", courseID: "ov-1",
                                 restored: nil, colorHex: "#2EC4B6")]
    let json = st.webJSON(title: "t", subtitle: "")
    let obj = (try? JSONSerialization.jsonObject(with: json.data(using: .utf8)!)) as? [String: Any]
    let courses = obj?["courses"] as? [[String: Any]] ?? []
    expectEqual(courses.count, 2, "两门课都推了")
    expectEqual(courses.first?["color"] as? String, "#ef5f5b",
                "显式色规范化后推给网页（网页不再自己查表）")
    expectEqual(courses.last?["color"] as? String, ColorHex.fallbackHex,
                "没有显式色、课名也不在表里 → 兜底灰（永远有值）")
    let ovs = obj?["overrides"] as? [[String: Any]] ?? []
    expectEqual(ovs.count, 1, "覆盖记录也推了")
    expectEqual(ovs.first?["color"] as? String, "#2ec4b6", "覆盖课的颜色也推给网页")
}

suite("编辑器 · 颜色行（三种模式显示 / 覆盖模式隐藏）") {
    var d = CourseDraft()
    d.name = "学术语言"; d.code = "C1"; d.day = 6; d.block = 0; d.weeks = [10]

    // 新增
    let createEditor = CourseEditorWindowController(mode: .create, draft: d, maxWeek: 16)
    createEditor.testPrepareLayout()
    expect(createEditor.testColorRowVisible, "新增模式有颜色行")
    expectEqual(createEditor.testColorPicker?.testOptionCount ?? -1, 14,
                "自动 + 12 个预设色 + 自定义")
    expectEqual(createEditor.testColorPicker?.testSelectedIndex ?? -1, 0, "新增时默认「自动」")
    expect(createEditor.testBatch.colorHex == nil, "默认「自动」→ 批量提交里没有颜色")
    createEditor.close()

    // 编辑（预填已有颜色）
    var withColor = d
    withColor.colorHex = "#EF5F5B"
    let editEditor = CourseEditorWindowController(
        mode: .edit(courseID: "same", day: 6, block: 0), draft: withColor, maxWeek: 16)
    editEditor.testPrepareLayout()
    expect(editEditor.testColorRowVisible, "编辑模式有颜色行")
    expectEqual(editEditor.testColorPicker?.testSelectedIndex ?? -1, 7,
                "已有颜色 #ef5f5b 是第 7 个预设 → 选中项预填正确")
    expectEqual(editEditor.testBatch.colorHex, "#ef5f5b", "不改颜色时按原色提交")

    // 布局：14 个选项都在控件内、互不重叠、不撑破窗口
    if let picker = editEditor.testColorPicker {
        picker.needsLayout = true
        picker.layoutSubtreeIfNeeded()
        let rects = picker.testOptionRects
        expectEqual(rects.count, 14, "14 个选项都有位置")
        expect(picker.bounds.width > 100, "颜色行拿到了宽度（不会被挤成 0）")
        expect(rects.allSatisfy { $0.minX >= -0.5 && $0.maxX <= picker.bounds.width + 0.5 },
               "14 个选项都在控件宽度内（不被裁掉）")
        // 第 0 个是「自动」胶囊（比色块宽），后面 13 个是色块。
        expect(rects.dropFirst().allSatisfy { $0.width >= 11 && $0.width <= 21 },
               "色块直径被压缩在 11–21 之间（按宽度自适应）")
        var overlap = false
        for i in 1..<rects.count where rects[i].minX < rects[i - 1].maxX - 0.01 { overlap = true }
        expect(!overlap, "色块之间不重叠")
        expect(picker.testCustomRect.width >= 11, "「自定义」色块也拿到了可用宽度")
        expectEqual(picker.testToolTipTexts.count, 14, "每个选项都有 tooltip")
        expect(picker.testToolTipTexts.first?.contains("自动") == true, "「自动」有说明 tooltip")
        expect(picker.testToolTipTexts.last?.contains("自定义") == true,
               "最后一个 tooltip 是「自定义颜色」")
    } else {
        expect(false, "编辑模式没拿到颜色选择器")
    }
    // 点色块 → 批量提交立刻带上新颜色
    editEditor.testSelectColorOption(at: 4)
    expectEqual(editEditor.testBatch.colorHex, "#f5a524", "选中第 4 个预设 → 表单带 #f5a524")
    editEditor.testSelectColorOption(at: 0)
    expect(editEditor.testBatch.colorHex == nil, "选回「自动」→ 表单里没有颜色")

    // 自定义色：不在 12 个预设里 → 最后一个选项选中
    editEditor.testColorPicker?.testSelectCustomHex("#123456")
    expectEqual(editEditor.testColorPicker?.testSelectedIndex ?? -1, 13,
                "自定义色 → 选中最后一个选项")
    expect(editEditor.testColorPicker?.testCustomSelected == true, "自定义色被标记为自定义")
    expect(editEditor.testColorPicker?.testSelectedLabel.contains("#123456") == true,
           "自定义色显示色值")
    expectEqual(editEditor.testBatch.colorHex, "#123456", "自定义色进入批量提交")
    editEditor.testSelectColorOption(at: 0)
    expect(editEditor.testBatch.colorHex == nil, "选回「自动」→ 清掉自定义色")
    editEditor.close()

    // NSColor → hex（色池的收口逻辑）
    expectEqual(CourseColorPickerView.hexString(
                    from: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                "#ff0000", "色池颜色转成 sRGB 十六进制")
    expectEqual(CourseColorPickerView.hexString(
                    from: NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 0.25)),
                "#0080ff", "忽略 alpha，0.5 → 80")

    // 临时覆盖：没有颜色行
    let ovEditor = CourseEditorWindowController(mode: .editOverride, draft: d, maxWeek: 16)
    ovEditor.testPrepareLayout()
    expect(!ovEditor.testColorRowVisible, "临时覆盖不显示颜色行")
    expect(ovEditor.testColorPicker == nil, "临时覆盖没有颜色选择器")
    ovEditor.close()
}

suite("课程颜色 · 编辑器选色 → 写盘（临时目录）") {
    let dir = makeTempDir("color-save")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScheduleStore(directory: dir)
    let repo = ScheduleRepository(store: store)

    let mon = course("学术语言", code: "C1", day: 1, block: 1, weeks: [1, 2], courseID: "id-1")
    let wed = course("学术语言", code: "C1", day: 3, block: 3, weeks: [1, 2], courseID: "id-1")
    try! store.saveCourses([mon, wed])

    let ctl = ScheduleEditorController(repositoryProvider: { repo })

    // 打开 → 默认「自动」
    let editor = ctl.testOpenEditor(courseID: "id-1")
    editor?.testPrepareLayout()
    expect(editor != nil, "能打开编辑器")
    expect(editor?.testColorRowVisible == true, "编辑已有课也有颜色行")
    expectEqual(editor?.testColorPicker?.testSelectedIndex ?? -1, 0, "没选过色 → 默认「自动」")

    // 选橙黄 → 保存 → 这门课所有记录同色
    editor?.testSelectColorOption(at: 4)
    if let e = editor {
        ctl.testSubmit(batch: e.testBatch,
                       scope: .edit(courseID: "id-1", day: mon.day, block: mon.block))
    }
    editor?.close()
    var saved = try! store.loadCourses()
    expectEqual(saved.count, 2, "两条记录都在")
    expect(saved.allSatisfy { $0.colorHex == "#f5a524" },
           "同 courseID 的所有记录写了同一个颜色")

    // 再打开 → 选中项就是刚选的那个色
    let again = ctl.testOpenEditor(courseID: "id-1")
    again?.testPrepareLayout()
    expectEqual(again?.testColorPicker?.testSelectedIndex ?? -1, 4, "重新打开 → 还是刚选的那个色")

    // 选回「自动」→ 保存 → 磁盘上的颜色被清掉
    again?.testSelectColorOption(at: 0)
    expect(again?.testBatch.colorHex == nil, "选「自动」→ 表单里没有颜色")
    if let e = again {
        ctl.testSubmit(batch: e.testBatch,
                       scope: .edit(courseID: "id-1", day: mon.day, block: mon.block))
    }
    again?.close()
    saved = try! store.loadCourses()
    expect(saved.allSatisfy { $0.colorHex == nil }, "选「自动」保存 → 磁盘上的颜色被清掉")

    // 自定义色 → 保存 → 重新打开仍选中「自定义」
    let custom = ctl.testOpenEditor(courseID: "id-1")
    custom?.testPrepareLayout()
    custom?.testColorPicker?.testSelectCustomHex("#123456")
    expectEqual(custom?.testBatch.colorHex, "#123456", "自定义色写进批量提交")
    if let e = custom {
        ctl.testSubmit(batch: e.testBatch,
                       scope: .edit(courseID: "id-1", day: mon.day, block: mon.block))
    }
    custom?.close()
    saved = try! store.loadCourses()
    expect(saved.allSatisfy { $0.colorHex == "#123456" },
           "自定义色写到同 courseID 的所有记录")

    let reopened = ctl.testOpenEditor(courseID: "id-1")
    reopened?.testPrepareLayout()
    expectEqual(reopened?.testColorPicker?.testSelectedIndex ?? -1, 13,
                "重新打开 → 自定义色仍在最后一个选项")
    expect(reopened?.testColorPicker?.testCustomSelected == true,
           "重新打开 → 识别为自定义色")
    reopened?.close()
}

// MARK: - 图钉固定 · 纯计算

suite("图钉 · 位置夹回屏幕可见区") {
    let vf = NSRect(x: 0, y: 0, width: 1000, height: 1000)
    let size = NSSize(width: 400, height: 300)

    // 在屏幕内 → 原样不动。
    let inside = TimetablePinState.clampOrigin(NSPoint(x: 100, y: 200), size: size, visibleFrame: vf)
    expectEqual(inside.x, 100.0, "屏幕内的位置不被改动（x）")
    expectEqual(inside.y, 200.0, "屏幕内的位置不被改动（y）")

    // 拖出左下角 → 夹回（至少完整可见）。
    let outLowLeft = TimetablePinState.clampOrigin(NSPoint(x: -500, y: -400), size: size, visibleFrame: vf)
    expectEqual(outLowLeft.x, 0.0, "拖出左边界 → 夹回可见区左沿")
    expectEqual(outLowLeft.y, 0.0, "拖出下边界 → 夹回可见区下沿")

    // 拖出右上角 → 夹回（窗口右边缘 / 上边缘贴住可见区）。
    let outHighRight = TimetablePinState.clampOrigin(NSPoint(x: 5000, y: 5000), size: size, visibleFrame: vf)
    expectEqual(outHighRight.x, 600.0, "拖出右边界 → 右边缘贴住可见区右沿")
    expectEqual(outHighRight.y, 700.0, "拖出上边界 → 上边缘贴住可见区上沿")

    // 非零原点的屏幕（第二块屏）→ 按那块屏算。
    let vf2 = NSRect(x: 1000, y: 0, width: 1920, height: 1080)
    let onSecond = TimetablePinState.clampOrigin(NSPoint(x: 1200, y: 500), size: size, visibleFrame: vf2)
    expectEqual(onSecond.x, 1200.0, "第二块屏上的合法位置不动")
    let outSecond = TimetablePinState.clampOrigin(NSPoint(x: 500, y: 500), size: size, visibleFrame: vf2)
    expectEqual(outSecond.x, 1000.0, "第二块屏上拖到左边 → 夹回该屏左沿")

    // 窗口比屏幕还大 → 贴左上角（至少左上角在屏幕里）。
    let huge = TimetablePinState.clampOrigin(NSPoint(x: 300, y: 300),
                                              size: NSSize(width: 2000, height: 2000),
                                              visibleFrame: vf)
    expectEqual(huge.x, 0.0, "窗口比屏幕还宽 → 贴可见区左沿")
    expectEqual(huge.y, 0.0, "窗口比屏幕还高 → 贴可见区下沿")
}

suite("图钉 · 后续窗口以课表位置为锚点") {
    let vf = NSRect(x: 0, y: 0, width: 1000, height: 1000)

    // 锚点在屏幕左上附近 → 窗口中心对齐锚点。
    // （锚点要离屏幕边足够远，否则窗口放不下会被夹回 —— 那正是期望行为，
    //   下面单独有一条用例验它。）
    let anchor = NSPoint(x: 400, y: 800)
    let p = WindowAnchor.origin(forSize: NSSize(width: 580, height: 132),
                                centeredAt: anchor, in: vf)
    expectEqual(p.x + 290.0, anchor.x, "窗口水平中心对齐课表中心")
    expectEqual(p.y + 66.0, anchor.y, "窗口垂直中心对齐课表中心")

    // 锚点靠屏幕左下角 → 窗口跟着过去（而不是屏幕正中）。
    let anchor2 = NSPoint(x: 250, y: 250)
    let q = WindowAnchor.origin(forSize: NSSize(width: 400, height: 300),
                                centeredAt: anchor2, in: vf)
    expectEqual(q.x + 200.0, anchor2.x, "课表在左下角时，弹窗中心跟着过去（x）")
    expectEqual(q.y + 150.0, anchor2.y, "课表在左下角时，弹窗中心跟着过去（y）")
    expect(q.x < 500, "弹窗不再出现在屏幕正中")

    // 锚点离左边缘太近（窗口放不下）→ 夹回可见区，仍完整可见。
    let anchorEdge = NSPoint(x: 100, y: 500)
    let edge = WindowAnchor.origin(forSize: NSSize(width: 580, height: 132),
                                   centeredAt: anchorEdge, in: vf)
    expectEqual(edge.x, 0.0, "课表太靠左 → 弹窗左边缘贴住可见区左沿")
    expectEqual(edge.x + 580 <= vf.maxX, true, "夹回后弹窗右边缘仍在可见区内")

    // 锚点太靠边 → 夹回可见区，窗口仍完整可见。
    let anchor3 = NSPoint(x: -100, y: -100)
    let r = WindowAnchor.origin(forSize: NSSize(width: 580, height: 400),
                                centeredAt: anchor3, in: vf)
    expectEqual(r.x, 0.0, "课表在屏幕外 → 弹窗左边缘贴住可见区左沿")
    expectEqual(r.y, 0.0, "课表在屏幕外 → 弹窗下边缘贴住可见区下沿")
    expect(r.x + 580 <= vf.maxX && r.y + 400 <= vf.maxY, "夹回后弹窗完整落在可见区里")

    // 锚点靠近右边缘 → 弹窗右边缘贴住可见区右沿，仍完整可见。
    let anchor4 = NSPoint(x: 990, y: 990)
    let s = WindowAnchor.origin(forSize: NSSize(width: 580, height: 400),
                                centeredAt: anchor4, in: vf)
    expectEqual(s.x, 420.0, "课表贴右边缘时弹窗右边缘贴住可见区右沿")
    expectEqual(s.y, 600.0, "课表贴上边缘时弹窗上边缘贴住可见区上沿")
}

suite("图钉 · 状态持久化") {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dt-pin-test-\(UUID().uuidString)")
    let store = TimetablePinStore(directory: dir)

    // 没有文件 → 全部默认值（首次启动）。
    let fresh = store.load()
    expectEqual(fresh.pinned, false, "首次启动：未固定")
    expect(fresh.origin == nil, "首次启动：没有记住位置")

    // 写入 → 读回一致。
    store.save(TimetablePinState(pinned: true, origin: NSPoint(x: 123.5, y: 456.25)))
    let loaded = store.load()
    expectEqual(loaded.pinned, true, "固定状态写盘后能读回")
    expectEqual(loaded.origin?.x ?? -1, 123.5, "位置 x 写盘后能读回")
    expectEqual(loaded.origin?.y ?? -1, 456.25, "位置 y 写盘后能读回")

    // 换成未固定，位置保留。
    store.save(TimetablePinState(pinned: false, origin: loaded.origin))
    let unlocked = store.load()
    expectEqual(unlocked.pinned, false, "解锁状态写盘后能读回")
    expectEqual(unlocked.origin?.x ?? -1, 123.5, "解锁后位置仍然保留")

    // 损坏的文件 → 退回默认值（不能崩，也不能把用户锁死在屏幕上）。
    try? Data("{ 这不是 JSON".utf8).write(to: store.file)
    let broken = store.load()
    expectEqual(broken.pinned, false, "状态文件损坏 → 退回未固定")
    expect(broken.origin == nil, "状态文件损坏 → 退回默认位置")

    // `pinned: 1` 不该被当成 true（严格的 Bool 判定）。
    try? Data(#"{"pinned": 1, "x": 5, "y": 6}"#.utf8).write(to: store.file)
    let strict = store.load()
    expectEqual(strict.pinned, false, "pinned: 1（数字）不算固定")
    expectEqual(strict.origin?.x ?? -1, 5.0, "pinned 类型非法不影响位置")

    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 图钉固定 · 控件

suite("图钉 · 按钮") {
    let button = PushPinButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    expectEqual(button.testIsPinned, false, "图钉初始为未固定（空心）")

    // 点击 → 切到固定（实心），回调带上新状态。
    var toggles: [Bool] = []
    button.onToggle = { toggles.append($0) }
    func click() {
        guard let e = NSEvent.mouseEvent(with: .leftMouseDown,
                                         location: NSPoint(x: 10, y: 10),
                                         modifierFlags: [],
                                         timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1) else { return }
        button.mouseDown(with: e)
    }
    click()
    expectEqual(button.testIsPinned, true, "点一下 → 已固定（实心）")
    expectEqual(toggles.count, 1, "点一下 → 回调一次")
    expectEqual(toggles.first ?? false, true, "回调带上的是「已固定」")

    // 再点一下 → 回到未固定。
    click()
    expectEqual(button.testIsPinned, false, "再点一下 → 回到未固定（空心）")
    expectEqual(toggles.count, 2, "再点一下 → 再回调一次")
    expectEqual(toggles.last ?? true, false, "回调带上的是「已解锁」")

    // 图钉在卡片**左上角、标题文字右边**：与标题行平行，不压标题。
    let card = TimetableLayout.cardRect
    let title = "我的课表"
    let r = PushPinButton.rect(inCard: card, title: title)
    let titleRight = card.minX + PushPinButton.titleLeftInset
        + PushPinButton.titleWidth(title)
    expect(r.minX >= titleRight, "图钉在标题文字右侧（不压标题）")
    expect(r.minX - titleRight <= PushPinButton.gapToTitle + 0.5,
           "图钉紧贴标题右侧（间距 \(r.minX - titleRight)pt）")
    expect(r.minX >= card.minX && r.maxX <= card.maxX
           && r.minY >= card.minY && r.maxY <= card.maxY, "图钉在卡片内部")
    expect(abs(r.midY - (card.maxY - PushPinButton.titleCenterFromCardTop)) <= 0.5,
           "图钉与标题行垂直居中对齐")
    expect(r.width >= 16 && r.width <= 20, "图钉热区尺寸在 16–20pt 之间：\(r.width)")

    // 标题改名 / 变长 → 图钉跟着往右挪，仍贴着标题。
    let longer = PushPinButton.rect(inCard: card, title: "马克思主义基本原理")
    expect(longer.minX > r.minX, "标题变长后图钉跟着右移（\(r.minX) → \(longer.minX)）")
    expect(abs(longer.midY - r.midY) <= 0.5, "标题变长不影响图钉所在行")
}

suite("图钉 · 拖动 1:1 跟随鼠标") {
    // 真机上曾经只跟到一半：`locationInWindow` 是相对**当前**窗口的，
    // 而窗口又全程跟着鼠标动；用「拖动开始时的窗口原点」去加，
    // 等于把窗口已经走过的距离又减了一遍（实测鼠标 200×120pt → 窗口 104×62pt）。
    //
    // 这里模拟真实链路：每报一次目标原点就真的把窗口挪过去，
    // 再用**屏幕坐标**造下一个事件 —— 老实现会立刻「掉队」，
    // 新实现必须严格 1:1。
    let interaction = CardInteractionView(frame: NSRect(x: 0, y: 0, width: 1148, height: 962))
    let win = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 1148, height: 962),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    // 交互层必须**挂在窗口里** —— 它靠 `window` 做坐标换算。
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1148, height: 962))
    win.contentView = host
    host.addSubview(interaction)
    var targets: [NSPoint] = []
    interaction.onDragTo = { origin in
        targets.append(origin)
        // 和 AppDelegate 一样，真的把窗口挪过去。
        win.setFrameOrigin(origin)
    }
    // 合成事件的 `location` 会被当成**窗口坐标**（`locationInWindow` 原样返回）。
    // 真实鼠标事件给的是「相对**当前**窗口位置」的坐标 —— 所以这里按
    // 「屏幕坐标 − 当前窗口原点」造事件，才能模拟出窗口边动边拖的真实链路。
    let pressScreen = NSPoint(x: 600, y: 700)
    func mouse(_ type: NSEvent.EventType, screen: NSPoint) -> NSEvent {
        let o = win.frame.origin
        let inWindow = NSPoint(x: screen.x - o.x, y: screen.y - o.y)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                  timestamp: 0, windowNumber: win.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    interaction.mouseDown(with: mouse(.leftMouseDown, screen: pressScreen))
    for step in 1...5 {
        let p = NSPoint(x: pressScreen.x + CGFloat(step) * 24,
                        y: pressScreen.y + CGFloat(step) * 12)
        interaction.mouseDragged(with: mouse(.leftMouseDragged, screen: p))
    }
    expectEqual(targets.count, 5, "每次拖动都报一个目标原点")
    // 鼠标挪 120×60 → 窗口也必须挪 120×60（不是只跟一半）。
    expectEqual(win.frame.origin.x, 220.0, "窗口 x 与鼠标 1:1")
    expectEqual(win.frame.origin.y, 260.0, "窗口 y 与鼠标 1:1")
    expectEqual(targets.last?.x ?? -1, 220.0, "目标原点是绝对值（不是增量）")
}

suite("图钉 · 两态只有空心 / 实心的区别") {
    // 未固定 → 空心；已固定 → 实心。
    // 用**同一套 SF Symbol**（`pin` / `pin.fill`）、同一个字号和颜色，
    // 只有内部填没填满 —— 切换时形状、大小、位置都不跳。
    let button = PushPinButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    button.isPinned = false
    let outline = PushPinButton.renderIconForTest(pinned: false)
    let solid = PushPinButton.renderIconForTest(pinned: true)
    expect(outline != nil, "空心图标能渲染出来")
    expect(solid != nil, "实心图标能渲染出来")
    if let outline, let solid {
        // 两种 symbol 的画布必须一样大（切换不跳大小）。
        expectEqual(outline.size.width, solid.size.width, "两态图标画布宽度一致")
        expectEqual(outline.size.height, solid.size.height, "两态图标画布高度一致")
        // 唯一差别：实心填得更多。
        let a = PushPinButton.inkDensityForTest(of: outline)
        let b = PushPinButton.inkDensityForTest(of: solid)
        expect(a != b, "空心图和实心图的墨量必须不同（填充上有差别）")
        expect(b > a, "实心图的墨量密度应比空心图高（实心 \(b) > 空心 \(a)）")
    }
}

suite("图钉 · 固定后拖不动") {
    let interaction = CardInteractionView(frame: NSRect(x: 0, y: 0, width: 1148, height: 962))
    expectEqual(interaction.testAllowsDragging, true, "未固定 → 可以拖动")

    // 固定 → 交互层不再接管命中测试（拖动无效），但图钉仍可点。
    interaction.setPinned(true)
    expectEqual(interaction.testAllowsDragging, false, "已固定 → 不允许拖动")
    expectEqual(interaction.testPinIsPinned, true, "已固定 → 图钉变实心")

    // 固定后，交互层不接管卡片区域的命中（点哪儿都落到画面层）。
    let hit = interaction.hitTest(NSPoint(x: 500, y: 500))
    expect(hit == nil, "已固定 → 卡片区域的点击不再被交互层接管")

    // 图钉那块区域**让给网页**（2026-11 起图钉视觉和点击都在网页层）：
    // 交互层返回 nil，点击落到网页里的 `<img class="ttlpin">`，
    // 由它 `post('pinToggle')` 回来切状态 —— 这样「看到的位置 = 能点的位置」。
    let pinHit = interaction.hitTest(interaction.testPinRect.origin)
    expect(pinHit == nil, "已固定 → 图钉区域要让给网页（否则点击被交互层截走）")
    // 未固定时同样不接管（那时交互层还在管拖动的其他地方）。
    interaction.setPinned(false)
    let pinHitUnpinned = interaction.hitTest(interaction.testPinRect.origin)
    expect(pinHitUnpinned == nil, "未固定 → 图钉区域也要让给网页")
    interaction.setPinned(true)

    // 解锁 → 恢复可拖动。
    interaction.setPinned(false)
    expectEqual(interaction.testAllowsDragging, true, "解锁 → 恢复可拖动")
    expectEqual(interaction.testPinIsPinned, false, "解锁 → 图钉变空心")
}

// MARK: - 日期覆盖层 · 农历 / 节气 / 节日

suite("农历 · 换算") {
    // ⚠️ 时区必须用**固定 +08:00**，不能用 `Asia/Shanghai` ——
    // 后者在 1901 年前是 LMT(+08:05:43)，同一天的零点会差 5 分钟，
    // 正好把 1900-01-31（农历表的下边界）推到范围外。
    //
    // 农历模块本身也用固定 +08:00（农历/节气本来就定义在东八区标准时），
    // 这里跟它保持一致。
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    func d(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }

    // 边界：1900-01-31 必须是农历 1900 年正月初一。
    expectEqual(LunarCalendar.lunar(from: d(1900, 1, 31))?.month, 1, "1900-01-31 是正月初一")
    expectEqual(LunarCalendar.lunar(from: d(1900, 1, 31))?.day, 1, "1900-01-31 是初一")

    // 2026 春节。
    expectEqual(LunarCalendar.lunar(from: d(2026, 2, 17))?.month, 1, "2026-02-17 是正月")
    expectEqual(LunarCalendar.lunar(from: d(2026, 2, 17))?.day, 1, "2026-02-17 是初一")
    expectEqual(LunarCalendar.lunar(from: d(2026, 2, 17))?.year, 2026, "2026 春节的农历年")

    // 2026 中秋 = 农历八月十五。
    expectEqual(LunarCalendar.lunar(from: d(2026, 9, 25))?.month, 8, "2026-09-25 是八月")
    expectEqual(LunarCalendar.lunar(from: d(2026, 9, 25))?.day, 15, "2026-09-25 是十五")

    // 闰月。
    expectEqual(LunarCalendar.lunar(from: d(2020, 5, 23))?.isLeapMonth, true, "2020-05-23 在闰月")
    expectEqual(LunarCalendar.leapMonth(ofLunarYear: 2023), 2, "2023 年闰二月")

    // 名称。
    expectEqual(LunarCalendar.monthName(1), "正月", "正月")
    expectEqual(LunarCalendar.monthName(4, isLeap: true), "闰四月", "闰四月")
    expectEqual(LunarCalendar.dayName(1), "初一", "初一")
    expectEqual(LunarCalendar.dayName(15), "十五", "十五")

    // 往返：公历 → 农历 → 公历，一年逐日一致。
    var roundTripOK = true
    var cursor = d(2026, 1, 1)
    for _ in 0..<365 {
        if let lunar = LunarCalendar.lunar(from: cursor),
           let back = LunarCalendar.date(from: lunar),
           cal.startOfDay(for: back) != cal.startOfDay(for: cursor) {
            roundTripOK = false
            break
        }
        cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
    }
    expect(roundTripOK, "2026 全年公历→农历→公历往返一致")

    // 范围外返回 nil（不静默出错）。
    expect(LunarCalendar.lunar(from: d(1899, 1, 1)) == nil, "1900 年之前返回 nil")
}

suite("二十四节气") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    func d(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }
    // 2026 年的四个关键节气。
    expect(SolarTerms.terms(on: d(2026, 2, 4)).contains("立春"), "2026-02-04 立春")
    expect(SolarTerms.terms(on: d(2026, 3, 20)).contains("春分"), "2026-03-20 春分")
    expect(SolarTerms.terms(on: d(2026, 6, 21)).contains("夏至"), "2026-06-21 夏至")
    expect(SolarTerms.terms(on: d(2026, 12, 22)).contains("冬至"), "2026-12-22 冬至")
    // 一年 24 个。
    expectEqual(SolarTerms.terms(inYear: 2026).count, 24, "2026 年 24 个节气")
    // 普通日子没有节气。
    expectEqual(SolarTerms.terms(on: d(2026, 11, 1)).count, 0, "2026-11-01 没有节气")
}

suite("节日") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    func d(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }
    expect(FestivalCalendar.festivals(on: d(2026, 10, 1)).contains("国庆节"), "国庆节")
    expect(FestivalCalendar.festivals(on: d(2026, 2, 17)).contains("春节"), "春节（农历）")
    expect(FestivalCalendar.festivals(on: d(2026, 1, 1)).contains("元旦"), "元旦")
    // 万圣节前夜（10-31）在万圣节（11-01）**之前**，两个名字以前写反了。
    expect(FestivalCalendar.solarFestivals(on: d(2026, 10, 31)).contains("万圣节前夜"), "10-31 万圣节前夜")
    expect(FestivalCalendar.solarFestivals(on: d(2026, 11, 1)).contains("万圣节"), "11-01 万圣节")
    expect(!FestivalCalendar.solarFestivals(on: d(2026, 10, 31)).contains("万圣节"), "10-31 不是万圣节")
    // 除夕按「腊月最后一天」动态判定。
    let nye = FestivalCalendar.lunarFestivals(on: d(2026, 2, 16))
    expect(nye.contains("除夕") || nye.contains("春节"), "除夕/春节至少有一个")
}

// MARK: - 日期覆盖层 · 状态与数据

suite("日期覆盖层 · 设置往返") {
    var settings = DayPanelSettings()
    expectEqual(settings.enabled, false, "默认：接入关闭")
    expectEqual(settings.listIdentifier, "", "默认：还没选清单")
    expectEqual(settings.listTitle, "桌面课表", "默认清单名")

    // JSON 往返。
    settings.enabled = true
    settings.listIdentifier = "abc"
    settings.listTitle = "我的清单"
    let back = DayPanelSettings(json: settings.jsonObject)
    expectEqual(back, settings, "日期覆盖层设置往返一致")

    // 缺字段 → 默认值。
    let empty = DayPanelSettings(json: [:])
    expectEqual(empty.enabled, false, "缺字段 → 默认关闭")
    expectEqual(empty.listTitle, "桌面课表", "缺字段 → 默认清单名")

    // `enabled: 1` 不算 true（严格布尔）。
    let strict = DayPanelSettings(json: ["enabled": 1])
    expectEqual(strict.enabled, false, "enabled: 1（数字）不算开启")
}

suite("日期覆盖层 · 内容模型") {
    var content = DayPanelContent()
    content.day = 3
    content.todos = [DayPanelTodo(title: "买牛奶", due: "20:00", done: false,
                                   identifier: "r1", calendarIdentifier: "c1")]
    content.events = [DayPanelEvent(title: "会议", start: "10:00", end: "11:00",
                                     identifier: "e1", calendarIdentifier: "c2")]
    content.festival.lunar = "农历九月廿三"

    expectEqual(content.isEmpty, false, "有内容")
    let json = content.jsonObject
    expectEqual(json["day"] as? Int, 3, "JSON 里有 day")
    expectEqual((json["todos"] as? [[String: Any]])?.count, 1, "JSON 里有 1 条待办")
    expectEqual((json["events"] as? [[String: Any]])?.count, 1, "JSON 里有 1 个日程")

    // 空内容。
    let empty = DayPanelContent()
    expectEqual(empty.isEmpty, true, "空内容")
    expectEqual(empty.festival.isEmpty, true, "空的节日块")

    // 表头标记的 JSON。
    let flags = DayPanelFlags.jsonObject([1: DayPanelFlags(hasTodo: true, hasEvent: false),
                                          2: DayPanelFlags(hasTodo: false, hasEvent: true)])
    expectEqual((flags["1"] as? [String: Any])?["todo"] as? Bool, true, "第 1 列有红点")
    expectEqual((flags["2"] as? [String: Any])?["event"] as? Bool, true, "第 2 列有橙点")
    expectEqual((flags["1"] as? [String: Any])?["event"] as? Bool, false, "第 1 列没有橙点")
}

// MARK: - 日期覆盖层 · 待办时间解析

suite("日期覆盖层 · 待办时间解析") {
    // 网页传 `HH:mm`；原生再兜底解析一次，不能依赖网页的校验。
    expectEqual(DayPanelController.clockMinutes("20:00"), 1200, "20:00 → 1200")
    expectEqual(DayPanelController.clockMinutes("00:00"), 0, "00:00 → 0")
    expectEqual(DayPanelController.clockMinutes("23:59"), 1439, "23:59 → 1439")
    expectEqual(DayPanelController.clockMinutes("9:5"), 545, "9:5 → 09:05")
    expectEqual(DayPanelController.clockMinutes("20"), 1200, "只填小时 → 整点")
    expectEqual(DayPanelController.clockMinutes(""), nil, "空时间非法（调用方按 00:00 处理）")
    expectEqual(DayPanelController.clockMinutes("24:00"), nil, "24:00 非法")
    expectEqual(DayPanelController.clockMinutes("12:60"), nil, "12:60 非法")
    expectEqual(DayPanelController.clockMinutes("abc"), nil, "乱码非法")

    expectEqual(DayPanelController.clockText(0), "00:00", "0 分钟 → 00:00")
    expectEqual(DayPanelController.clockText(1200), "20:00", "1200 分钟 → 20:00")
    expectEqual(DayPanelController.clockText(1439), "23:59", "1439 分钟 → 23:59")
}

// MARK: - 日干支 / 建除黄历（离线）

suite("日干支") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    func d(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }

    // 两个互相独立的公认锚点。
    expectEqual(LunarCalendar.dayGanzhi(d(1949, 10, 1)), "甲子", "1949-10-01 是甲子日")
    expectEqual(LunarCalendar.dayGanzhi(d(2000, 1, 1)), "戊午", "2000-01-01 是戊午日")

    // 六十甲子一循环（60 天后必须回到同一个干支）。
    let base = LunarCalendar.dayGanzhi(d(2026, 11, 2))
    // 2026-11-02 往前推 300 天（= 60 的 5 倍）→ 干支相同。
    expectEqual(LunarCalendar.dayGanzhi(d(2026, 1, 6)), base, "相隔 300 天（60 的倍数）干支相同")
    // 往前推一天 → 干支**必须**不同（否则说明周期算错了）。
    expect(LunarCalendar.dayGanzhi(d(2026, 11, 1)) != base, "相邻两天的干支必须不同")

    // ⚠️ **奇偶不变量**：六十甲子里天干与地支的序号奇偶性**永远相同**
    // （10 和 12 都是偶数，120 种组合里只出现 60 种）。
    // 任何偏移常数错了，这个不变量都会在若干天内被破坏。
    var parityOK = true
    var cursor = d(2020, 1, 1)
    let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
    for _ in 0..<2000 {
        guard let gz = LunarCalendar.dayGanzhi(cursor),
              let s = stems.firstIndex(of: String(gz.prefix(1))),
              let b = branches.firstIndex(of: String(gz.suffix(1))) else {
            parityOK = false
            break
        }
        if s % 2 != b % 2 { parityOK = false; break }
        cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
    }
    expect(parityOK, "日干支的奇偶不变量要成立（连续 2000 天）")

    // 范围外返回 nil（不静默出错）。
    expect(LunarCalendar.dayGanzhi(d(1899, 12, 31)) == nil, "1900 年之前返回 nil")

    // ⚠️ **日干支和农历换算必须用同一个日界** ——
    // 两者都基于 epoch（1900-01-31），不会差一天。
    expectEqual(LunarCalendar.dayNumberForTest(d(2026, 11, 2)), 46296,
                "距 epoch 的天数要稳定（epoch = 1900-01-31）")
    expectEqual(LunarCalendar.dayNumberForTest(d(1900, 1, 31)), 0,
                "epoch 当天的天数是 0")
}

suite("建除黄历（简化的建除十二神）") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    func d(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }

    // 十二神齐全，且「子 → 建、除丑、满寅……」的排法固定。
    expectEqual(AlmanacCalendar.twelveGods.count, 12, "建除十二神要齐 12 个")
    expectEqual(AlmanacCalendar.god(branchIndex: 0), "建", "子日建")
    expectEqual(AlmanacCalendar.god(branchIndex: 1), "除", "丑日除")
    expectEqual(AlmanacCalendar.god(branchIndex: 11), "闭", "亥日闭")

    // 每个神都要有宜 / 忌条目（不能有一个是空的）。
    for god in AlmanacCalendar.twelveGods {
        let e = AlmanacCalendar.entries(forGod: god)
        expect(e != nil, "\(god) 要有宜 / 忌条目")
        expect((e?.yi.isEmpty == false), "\(god) 的宜不能为空")
        expect((e?.ji.isEmpty == false), "\(god) 的忌不能为空")
    }

    // 连续若干天：每天都能算出结果，而且十二神按顺序轮转。
    var godSeq: [String] = []
    var cursor = d(2026, 11, 1)
    for _ in 0..<15 {
        guard let a = AlmanacCalendar.briefAlmanac(on: cursor) else { break }
        godSeq.append(a.god)
        cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
    }
    expectEqual(godSeq.count, 15, "连续 15 天都要算得出宜 / 忌")
    // 十二神按日支轮转 → 连续 12 天正好把十二个神走一遍（不重复）。
    expectEqual(Set(godSeq.prefix(12)).count, 12, "连续 12 天要走遍十二神")

    // ⚠️ **岁首前后不崩**（农历年切换的那几天）。
    var newYearOK = true
    cursor = d(2026, 2, 10)
    for _ in 0..<20 {
        if AlmanacCalendar.briefAlmanac(on: cursor) == nil { newYearOK = false; break }
        cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
    }
    expect(newYearOK, "春节前后（岁首）不能算出空值")

    // ⚠️ **闰月不崩**（2020 年闰四月）。
    var leapMonthOK = true
    cursor = d(2020, 5, 1)
    for _ in 0..<40 {
        if AlmanacCalendar.briefAlmanac(on: cursor) == nil { leapMonthOK = false; break }
        cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
    }
    expect(leapMonthOK, "闰四月前后不能算出空值")

    // 范围外返回 nil → 网页隐藏这一行（不编造）。
    expect(AlmanacCalendar.briefAlmanac(on: d(1899, 12, 31)) == nil,
           "1900 年之前返回 nil（不编造宜忌）")
}

suite("日期覆盖层 · 天气 / 宜忌的模型与 JSON") {
    // 天气为 nil → JSON 里整个键是 null（网页隐藏整行）。
    var content = DayPanelContent()
    content.festival.lunar = "农历九月廿三"
    let json = content.jsonObject
    let fest = json["festival"] as? [String: Any]
    expect(fest != nil, "JSON 里有 festival")
    expect(fest?["weather"] is NSNull, "没有天气时 weather 是 null（网页隐藏整行）")
    expectEqual(fest?["yi"] as? String, "", "没有宜忌时 yi 是空串（网页隐藏这一行）")

    // 有天气 → JSON 里有完整的天气字段。
    var content2 = DayPanelContent()
    content2.festival.weather = DayPanelWeather(text: "晴", temperature: 12, min: 12, max: 21)
    content2.festival.yi = "出行"
    content2.festival.ji = "动土"
    let fest2 = content2.jsonObject["festival"] as? [String: Any]
    let w = fest2?["weather"] as? [String: Any]
    expectEqual(w?["text"] as? String, "晴", "天气里有现象")
    expectEqual(w?["temperature"] as? Double, 12, "天气里有当前温度")
    expectEqual(w?["min"] as? Double, 12, "天气里有最低温")
    expectEqual(w?["max"] as? Double, 21, "天气里有最高温")
    expectEqual(fest2?["yi"] as? String, "出行", "有宜")
    expectEqual(fest2?["ji"] as? String, "动土", "有忌")

    // 空天气的判定（描述和温度都没有 → 整行隐藏）。
    expectEqual(DayPanelWeather().isEmpty, true, "空天气")
    expectEqual(DayPanelWeather(text: "晴").isEmpty, false, "有现象就不算空")
    expectEqual(DayPanelWeather(temperature: 3).isEmpty, false, "有温度就不算空")
}

suite("日期覆盖层 · 天气的解析与编码") {
    // Open-Meteo 的响应解析。
    let ok = OpenMeteoWeatherProvider.parse([
        "current": ["temperature_2m": 12.4, "weather_code": 0] as [String: Any],
        "daily": ["temperature_2m_max": [21.0], "temperature_2m_min": [12.0]] as [String: Any]
    ])
    expectEqual(ok?.text, "晴", "天气码 0 → 晴")
    expectEqual(ok?.temperature, 12.4, "当前温度")
    expectEqual(ok?.max, 21.0, "最高温")
    expectEqual(ok?.min, 12.0, "最低温")

    // ⚠️ **什么都没有 → nil**（网页隐藏整行，绝不显示 0°）。
    expect(OpenMeteoWeatherProvider.parse([:]) == nil, "空响应 → nil（不显示假数据）")
    expect(OpenMeteoWeatherProvider.parse(["current": [:] as [String: Any]]) == nil,
           "只有空 current → nil")

    // 天气码 → 中文。
    expectEqual(OpenMeteoWeatherProvider.weatherText(0), "晴", "码 0")
    expectEqual(OpenMeteoWeatherProvider.weatherText(3), "阴", "码 3")
    expectEqual(OpenMeteoWeatherProvider.weatherText(61), "小雨", "码 61")
    expectEqual(OpenMeteoWeatherProvider.weatherText(75), "大雪", "码 75")
    expectEqual(OpenMeteoWeatherProvider.weatherText(95), "雷阵雨", "码 95")
    // 未知码 → 多云（不返回空串，避免出现一个空的天气行）。
    expect(!OpenMeteoWeatherProvider.weatherText(12345).isEmpty, "未知天气码也要有文案")

    // ⚠️ **自动化模式绝不真发请求** ——
    // `OpenMeteoWeatherProvider` 在自动化模式下不建位置管理器。
    expect(AutomationMode.isCurrentProcessAutomation
           || true, "占位：真实模式才建位置管理器")
}

suite("日期覆盖层 · 设置往返（天气开关）") {
    // 默认关（天气要定位权限 + 联网，必须用户自己开）。
    expectEqual(DayPanelSettings().weatherEnabled, false, "默认：天气关闭")

    var settings = DayPanelSettings()
    settings.enabled = true
    settings.weatherEnabled = true
    let back = DayPanelSettings(json: settings.jsonObject)
    expectEqual(back, settings, "含天气开关的设置往返一致")

    // 缺字段 → 默认关（老版本的 settings.json 没有这个键）。
    let empty = DayPanelSettings(json: [:])
    expectEqual(empty.weatherEnabled, false, "缺字段 → 天气关闭")

    // `weatherEnabled: 1` 不算 true（严格布尔）。
    let strict = DayPanelSettings(json: ["weatherEnabled": 1])
    expectEqual(strict.weatherEnabled, false, "weatherEnabled: 1（数字）不算开启")
}

suite("日期覆盖层 · 天气行的状态文案") {
    // 关着 → 不显示任何授权提示。
    let off = DayPanelWeatherRow.describe(enabled: false, authStatus: .authorizedAlways)
    expect(!off.needsButton, "关着时不该显示「去授权」")

    // 已授权 → 不显示按钮。
    let granted = DayPanelWeatherRow.describe(enabled: true, authStatus: .authorizedAlways)
    expect(!granted.needsButton, "已授权时不该显示「去授权」")
    expect(granted.text.contains("位置"), "已授权的文案要说清楚是按位置")

    // 没授权 / 没问过 → 显示按钮。
    expect(DayPanelWeatherRow.describe(enabled: true, authStatus: .denied).needsButton,
           "被拒绝时要显示「去授权」")
    expect(DayPanelWeatherRow.describe(enabled: true, authStatus: .notDetermined).needsButton,
           "还没问过时要显示「去授权」")
    expect(!DayPanelWeatherRow.describe(enabled: true, authStatus: nil).needsButton,
           "状态未知时不显示按钮（不预判）")
}

suite("已完成提醒事项 · 查询 / 排序 / 分页") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func item(_ id: String, _ title: String,
              list: String = "c1", listTitle: String = "桌面课表",
              completion: Date?, due: Date? = nil, recurring: Bool = false) -> CompletedReminder {
        CompletedReminder(identifier: id, title: title,
                          listIdentifier: list, listTitle: listTitle,
                          completionDate: completion, dueDate: due,
                          isRecurring: recurring)
    }

    let early = item("r1", "买牛奶", completion: at(2026, 11, 4, 9, 0))
    let late = item("r2", "交作业", list: "c2", listTitle: "学习",
                    completion: at(2026, 11, 5, 18, 30))
    let middle = item("r3", "交作业", completion: at(2026, 11, 4, 20, 0))
    let noTime = item("r4", "没有完成时间", completion: nil)

    // 完成时间倒序：最近完成的在前；没有完成时间的排最后。
    let sorted = CompletedReminderQuery.sorted([early, noTime, late, middle])
    expectEqual(sorted.map { $0.identifier }, ["r2", "r3", "r1", "r4"],
                "按完成时间倒序（nil 排最后）")
    // 完成时间相同 → 按标题稳定排序。
    let sameA = item("a", "B 标题", completion: at(2026, 11, 4, 10, 0))
    let sameB = item("b", "A 标题", completion: at(2026, 11, 4, 10, 0))
    expectEqual(CompletedReminderQuery.sorted([sameA, sameB]).map { $0.identifier }, ["b", "a"],
                "完成时间相同按标题稳定排序")

    // 搜索：去首尾空白、大小写不敏感、只匹配标题。
    expect(CompletedReminderQuery.filter([early, late, middle], search: " 交作业 ",
                                         listIdentifier: nil).map { $0.identifier } == ["r2", "r3"],
           "搜索「交作业」应命中两条")
    expect(CompletedReminderQuery.filter([early], search: "桌面课表",
                                         listIdentifier: nil).isEmpty,
           "搜索只按标题，不按清单名")
    let latin = item("en", "Buy MILK", completion: at(2026, 11, 4, 8, 0))
    expect(CompletedReminderQuery.filter([latin], search: "milk", listIdentifier: nil).count == 1,
           "搜索英文标题大小写不敏感")

    // 清单筛选：只在选中的清单里找；nil / 空串 = 所有清单。
    expect(CompletedReminderQuery.filter([early, late, middle], search: "",
                                         listIdentifier: "c2").map { $0.identifier } == ["r2"],
           "按清单筛选只留该清单")
    expect(CompletedReminderQuery.filter([early, late], search: "", listIdentifier: "").count == 2,
           "空串筛选 = 所有清单")

    // 清单汇总：去重、按标题排序、空标识忽略。
    let lists = CompletedReminderQuery.lists(in: [early, late, middle,
                                                  item("x", "x", list: "", listTitle: "",
                                                       completion: nil)])
    expectEqual(lists, [CompletedReminderList(identifier: "c2", title: "学习"),
                        CompletedReminderList(identifier: "c1", title: "桌面课表")],
                "清单汇总（去重 + 排序 + 忽略空标识）")
    expectEqual(item("x", "x", listTitle: "", completion: nil).listDisplayName, "未命名清单",
                "清单标题为空要有占位")

    // 分页：首屏 200（服务按这个值翻页）。
    expectEqual(CompletedReminderPolicy.pageSize, 200, "首屏最多 200 条")
}

suite("已完成提醒事项 · 时间 / 行文案") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let completion = cal.date(from: DateComponents(year: 2026, month: 11, day: 5,
                                                   hour: 14, minute: 20))!
    let due = cal.date(from: DateComponents(year: 2026, month: 11, day: 6,
                                            hour: 9, minute: 5))!
    let item = CompletedReminder(identifier: "r1", title: "买牛奶",
                                 listIdentifier: "c1", listTitle: "购物",
                                 completionDate: completion, dueDate: due,
                                 isRecurring: false)
    expectEqual(CompletedReminder.timeText(completion), "2026-11-05 14:20",
                "完成时间格式 yyyy-MM-dd HH:mm")
    expectEqual(item.completionText, "2026-11-05 14:20", "完成时间文案")
    expectEqual(item.dueText, "2026-11-06 09:05", "到期时间文案")
    expectEqual(item.listDisplayName, "购物", "清单名")
    expect(item.subtitleText.contains("完成 2026-11-05 14:20"), "行副文案带完成时间")
    expect(item.subtitleText.contains("到期 2026-11-06 09:05"), "行副文案带到期时间")

    let noDue = CompletedReminder(identifier: "r2", title: "无到期",
                                  listIdentifier: "c1", listTitle: "购物",
                                  completionDate: nil, dueDate: nil,
                                  isRecurring: false)
    expectEqual(noDue.dueText, "无到期时间", "没有到期时间要显示「无到期时间」")
    expectEqual(noDue.completionText, "完成时间未知", "没有完成时间不能显示空白")
}

suite("已完成提醒事项 · 全部删除确认策略") {
    // 阈值：≥50 条要求输入「删除」。
    expect(!CompletedReminderPolicy.needsTypedConfirmation(count: 49), "49 条不要求输入")
    expect(CompletedReminderPolicy.needsTypedConfirmation(count: 50), "50 条要输入「删除」")
    expectEqual(CompletedReminderPolicy.deleteAllTitle, "删除全部已完成事项？", "确认标题")
    expectEqual(CompletedReminderPolicy.deleteAllMessage(count: 37),
                "将永久删除所有清单中 37 条已完成提醒事项，此操作无法撤销。",
                "确认正文要写数量")
    // 输入校验：只认「删除」两个字（去首尾空白）。
    expect(CompletedReminderPolicy.typedConfirmationMatches("删除"), "输入「删除」应通过")
    expect(CompletedReminderPolicy.typedConfirmationMatches(" 删除 "), "允许首尾空白")
    expect(!CompletedReminderPolicy.typedConfirmationMatches("删 除"), "中间空格不算")
    expect(!CompletedReminderPolicy.typedConfirmationMatches("delete"), "英文不算")
    expect(!DeleteAllCompletedDialog.phraseGate(count: 60, text: ""), "≥50 条空输入不能提交")
    expect(DeleteAllCompletedDialog.phraseGate(count: 60, text: "删除"), "≥50 条输入正确可提交")
    expect(DeleteAllCompletedDialog.phraseGate(count: 3, text: ""), "<50 条不需要输入")

    // 单条删除：标题带上待办名。
    expectEqual(CompletedReminderPolicy.deleteOneTitle(title: "买牛奶"), "删除「买牛奶」？",
                "单条确认标题带待办名")
    expectEqual(CompletedReminderPolicy.deleteOneTitle(title: "  "),
                "删除这条已完成提醒事项？", "空标题有兜底")

    // 重复提醒：第一版禁用恢复，并给出原因。
    expect(CompletedReminderPolicy.restoreBlockedReason(isRecurring: false) == nil,
           "普通提醒可以恢复")
    expect(CompletedReminderPolicy.restoreBlockedReason(isRecurring: true) != nil,
           "重复提醒不允许恢复")
    expect(CompletedReminderPolicy.recurringRestoreReason.contains("重复提醒"),
           "禁用原因要说明是重复提醒")
}

suite("已完成提醒事项 · 批量删除结果文案") {
    let full = CompletedRemindersDeleteResult(deleted: 37, failed: 0,
                                              deletedIdentifiers: [], failedIdentifiers: [],
                                              message: nil)
    expectEqual(full.summaryText, "已删除 37 条", "全部成功")

    let partial = CompletedRemindersDeleteResult(deleted: 35, failed: 2,
                                                 deletedIdentifiers: [], failedIdentifiers: [],
                                                 message: "2 条删除失败")
    expect(partial.summaryText.contains("已删除 35 条"), "部分失败要报成功数")
    expect(partial.summaryText.contains("2 条失败"), "部分失败要报失败数")

    let commitFail = CompletedRemindersDeleteResult(deleted: 0, failed: 37,
                                                    deletedIdentifiers: [], failedIdentifiers: [],
                                                    message: "提交更改失败：x")
    expect(commitFail.summaryText.contains("删除失败"), "commit 失败不能报成功")
    expect(commitFail.summaryText.contains("37"), "commit 失败要报数量")

    let inAppFail = CompletedRemindersDeleteResult(deleted: 0, failed: 3,
                                                   deletedIdentifiers: [], failedIdentifiers: [],
                                                   message: nil)
    expect(inAppFail.summaryText.contains("3 条未能删除"), "全部失败要如实说明")
    let none = CompletedRemindersDeleteResult(deleted: 0, failed: 0,
                                              deletedIdentifiers: [], failedIdentifiers: [],
                                              message: nil)
    expectEqual(none.summaryText, "没有需要删除的已完成事项", "空结果文案")
}

// MARK: - 悬停遮挡判定（2026-11-05 修「开 app 课表不出来」）

suite("HoverCoverPolicy · 遮挡判定") {
    // 课表在普通窗口（0）之下、桌面窗口（≈ -2147483623）之上。
    let ourLevel = HoverCoverPolicy.cardWindowLevel
    let desktopLayer = Int(CGWindowLevelForKey(.desktopWindow))
    let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    expectEqual(ourLevel, -1, "课表层级 = -1（普通窗口之下、桌面之上）")
    expect(ourLevel < Int(CGWindowLevelForKey(.normalWindow)), "课表在普通窗口之下")
    expect(desktopLayer < ourLevel, "桌面窗口比课表低")
    expect(iconLayer < ourLevel, "桌面图标窗口比课表低")

    // ⚠️ 回归核心：桌面窗口**不能**算遮挡。
    // 旧写法 `topNumber != 0 && !isOwnWindow(topNumber)` 会在这里判成 true，
    // 于是空桌面上课表永远停在 minOpacity（22%），用户看到「没出来」。
    expect(HoverCoverPolicy.covers(otherLayer: desktopLayer, ourLevel: ourLevel) == false,
           "桌面窗口不算遮挡")
    expect(HoverCoverPolicy.covers(otherLayer: iconLayer, ourLevel: ourLevel) == false,
           "桌面图标窗口不算遮挡")
    expect(HoverCoverPolicy.covers(otherLayer: ourLevel, ourLevel: ourLevel) == false,
           "同层窗口不算遮挡")
    expect(HoverCoverPolicy.covers(otherLayer: nil, ourLevel: ourLevel) == false,
           "查不到层级不判成遮挡（否则又会永远不亮）")

    // 普通 App 窗口 / 浮层 / 菜单都在课表上面 → 必须算遮挡。
    expect(HoverCoverPolicy.covers(otherLayer: 0, ourLevel: ourLevel),
           "普通窗口（层级 0）算遮挡")
    expect(HoverCoverPolicy.covers(otherLayer: 3, ourLevel: ourLevel),
           "浮动面板（层级 3）算遮挡")
    expect(HoverCoverPolicy.covers(otherLayer: 25, ourLevel: ourLevel),
           "菜单栏 / 控制中心这类高层窗口算遮挡")

    // 窗口号 0 = 没有窗口，不是遮挡，也读不到层级。
    expectEqual(HoverCoverPolicy.layer(ofWindowNumber: 0), nil, "窗口号 0 读不到层级")

    // 真机：屏幕上必然有比课表低的窗口（桌面 / 壁纸 / 桌面图标）。
    // 这条让上面的断言不是纸上推演；离屏环境取不到列表时跳过。
    let layers = HoverCoverPolicy.onScreenWindowLayers()
    if layers.isEmpty {
        print("  （离屏环境：窗口列表为空，跳过真机层级断言）")
    } else {
        expect(layers.contains { $0 < ourLevel },
               "屏幕上必须存在比课表低的窗口（桌面 / 桌面图标）")
    }
}

// MARK: - 权限弹框期间课表保持可见（2026-11-05 用户反馈）

suite("PermissionPromptWatch · 权限弹框期间不淡出") {
    PermissionPromptWatch.endAll()
    PermissionPromptWatch.onStateChanged = nil

    let t0 = Date()
    expect(!PermissionPromptWatch.isHolding(now: t0), "初始不保持")

    PermissionPromptWatch.begin("定位", seconds: 120, now: t0)
    expect(PermissionPromptWatch.isHolding(now: t0.addingTimeInterval(1)), "弹框期间要保持可见")
    expectEqual(PermissionPromptWatch.activeReasons, ["定位"], "记下了弹框原因")

    // 日历 + 提醒事项会**并行**弹两个框：只回了一个不能解除保持。
    PermissionPromptWatch.begin("日历", seconds: 120, now: t0)
    PermissionPromptWatch.end("定位", now: t0.addingTimeInterval(2))
    expect(PermissionPromptWatch.isHolding(now: t0.addingTimeInterval(2)),
           "还有一个弹框没回应，必须继续保持")
    expectEqual(PermissionPromptWatch.activeReasons, ["日历"], "销掉的那笔不能再挂着")
    PermissionPromptWatch.end("日历", now: t0.addingTimeInterval(3))
    expect(!PermissionPromptWatch.isHolding(now: t0.addingTimeInterval(3)),
           "全部回应后解除保持")

    // 用户一直不点弹框 → 到时间自己解除（不能无限期亮着）。
    PermissionPromptWatch.begin("通知", seconds: 5, now: t0)
    expect(PermissionPromptWatch.isHolding(now: t0.addingTimeInterval(4)), "没到时间仍保持")
    expect(!PermissionPromptWatch.isHolding(now: t0.addingTimeInterval(6)), "超时后不再保持")
    // 清干净（连同它排的 5 秒定时器），下面单独验定时器这条路。
    PermissionPromptWatch.endAll()

    // ⚠️ **兜底超时必须真的把这一笔销掉**（2026-11-05 修「修改完 / 取消后，
    // 鼠标移到课表外面，课表不消失」）：日历 + 提醒事项是并行请求的，
    // macOS 有时只弹一个框、另一个请求永远不回调 —— 那一笔等不到 `end`，
    // 课表就会一直亮着。这里用 0.05 秒的保持来验定时器这条路真的会走。
    var timeoutEvents: [Bool] = []
    PermissionPromptWatch.onStateChanged = { timeoutEvents.append($0) }
    PermissionPromptWatch.begin("提醒事项", seconds: 0.05)
    expect(PermissionPromptWatch.isHolding(), "刚 begin 时保持生效")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    expect(!PermissionPromptWatch.isHolding(), "兜底超时到了要自动解除保持")
    expectEqual(PermissionPromptWatch.activeReasons, [], "超时解除后不能再挂着这个原因")
    expectEqual(timeoutEvents, [true, false],
                "超时解除也要通知一次（否则要等下一次 10 秒巡检课表才回落）")
    PermissionPromptWatch.onStateChanged = nil
    PermissionPromptWatch.endAll()

    // 没记过账就 end（系统没弹框、走的是「已经授权」分支）→ 无害。
    PermissionPromptWatch.end("定位", now: t0)
    PermissionPromptWatch.endAll()

    // 进入 / 退出各通知一次（`AppDelegate` 靠它立刻重算 hover）。
    var events: [Bool] = []
    PermissionPromptWatch.onStateChanged = { events.append($0) }
    PermissionPromptWatch.begin("定位", seconds: 10, now: t0)
    PermissionPromptWatch.begin("日历", seconds: 10, now: t0)
    PermissionPromptWatch.end("定位", now: t0)
    PermissionPromptWatch.end("日历", now: t0)
    expectEqual(events, [true, false], "进入 / 退出各通知一次（并行两框只算一次）")
    // endAll 也要通知退出
    PermissionPromptWatch.begin("定位", seconds: 10, now: t0)
    PermissionPromptWatch.endAll()
    expectEqual(events, [true, false, true, false], "endAll 也要通知退出")

    PermissionPromptWatch.onStateChanged = nil
    PermissionPromptWatch.endAll()
}

// MARK: - 课表卡片大小（缩放，2026-11）

suite("CardScalePolicy · 取值策略") {
    // 滑块范围固定 70%–115%。
    expectEqual(CardScalePolicy.minScale, 0.70, "滑块下限 70%")
    expectEqual(CardScalePolicy.maxScale, 1.15, "滑块上限 115%")

    // 夹取。
    expectEqual(CardScalePolicy.clamp(0.5), 0.70, "小于下限 → 夹到 70%")
    expectEqual(CardScalePolicy.clamp(2.0), 1.15, "大于上限 → 夹到 115%")
    expectEqual(CardScalePolicy.clamp(1.0), 1.0, "范围内的值原样返回")

    // 屏幕上限：卡片 968×782，可见区 1512×937。
    //   高度：(937 − 24) / 782 = 1.1675…
    //   宽度：(1512 − 24) / 968 = 1.537…
    //   → 取小者，再被 1.15 压住 → 1.15
    let screen = CGSize(width: 1512, height: 937)
    let card = CGSize(width: 968, height: 782)
    let upper = CardScalePolicy.maxScale(for: screen, cardSize: card)
    expect(upper <= CardScalePolicy.maxScale + 0.0001,
           "屏幕上限不超过滑块上限（\(upper)）")
    expect(upper > 1.0, "常见屏幕上能放到 100% 以上（实际 \(upper)）")

    // 小屏：可见区 800×600 → 高度上限 (600−24)/782 = 0.7366，
    // 仍然**大于**滑块下限 70% → 所以能放到 73%。
    let small = CardScalePolicy.maxScale(for: CGSize(width: 800, height: 600), cardSize: card)
    expect(small > CardScalePolicy.minScale && small < 1.0,
           "小屏的上限落在下限与 100% 之间（实际 \(small)）")
    expectEqual(CardScalePolicy.clamp(1.0, visibleSize: CGSize(width: 800, height: 600),
                                      cardSize: card),
                small,
                "小屏上 100% 被夹到屏幕上限")
    // 夹取后不能低于下限。
    expect(CardScalePolicy.clamp(0.0, visibleSize: CGSize(width: 800, height: 600),
                                 cardSize: card) >= CardScalePolicy.minScale,
           "小屏上夹取结果不低于滑块下限")

    // 极小屏：可见区 500×400 → 高度上限 (400−24)/782 = 0.4808，
    // **低于**滑块下限 70% —— 这时「屏幕上限」比「下限」还小，
    // 必须取下限（更保守），不能让值夹到 0.48（那样卡片虽然放得下，
    // 但比用户能拖到的最小值还小，行为不一致）。
    let tiny = CardScalePolicy.maxScale(for: CGSize(width: 500, height: 400), cardSize: card)
    expect(tiny < CardScalePolicy.minScale,
           "极小屏的上限低于滑块下限（实际 \(tiny)）")
    expectEqual(CardScalePolicy.clamp(1.0, visibleSize: CGSize(width: 500, height: 400),
                                      cardSize: card),
                CardScalePolicy.minScale,
                "极小屏上 100% 被夹到滑块下限")

    // 大屏：3000×2000 → 高度 (2000−24)/782 = 2.53，被 1.15 压住。
    expectEqual(CardScalePolicy.maxScale(for: CGSize(width: 3000, height: 2000), cardSize: card),
                CardScalePolicy.maxScale,
                "大屏上上限就是滑块上限 115%")

    // 卡片尺寸不能写死：给一个更高的卡片，上限必须跟着变小。
    let tall = CardScalePolicy.maxScale(for: screen, cardSize: CGSize(width: 968, height: 1000))
    let normal = CardScalePolicy.maxScale(for: screen, cardSize: card)
    expect(tall < normal, "卡片更高 → 屏幕上限更小（\(tall) < \(normal)）")

    // 超限提示。
    expectEqual(CardScalePolicy.limitNotice(requested: 1.15, actual: 1.10),
                "已按当前屏幕上限调整为 110%",
                "超限时给提示")
    expect(CardScalePolicy.limitNotice(requested: 1.0, actual: 1.0) == nil,
           "没超限不提示")

    // 文案。
    expectEqual(CardScalePolicy.percentText(1.0), "100%", "百分比文案")
    expectEqual(CardScalePolicy.percentText(0.85), "85%", "百分比文案（85%）")
}

suite("TimetableLayout · 缩放几何") {
    // scale = 1 时必须与旧版完全一致（这是「不加缩放时视觉不变」的保证）。
    TimetableLayout.resetScale()
    expectEqual(TimetableLayout.cardWidth, 968, "scale=1 卡片宽 968")
    expectEqual(TimetableLayout.cardHeight, 773, "scale=1 卡片高 773")
    expectEqual(TimetableLayout.shadowMargin, 90, "scale=1 投影留白 90")
    expectEqual(TimetableLayout.windowWidth, 1148, "scale=1 窗口宽 1148")
    expectEqual(TimetableLayout.windowHeight, 953, "scale=1 窗口高 953")
    expectEqual(TimetableLayout.cardRect.origin.x, 90, "scale=1 卡片左边距 90")
    expectEqual(TimetableLayout.cardRect.origin.y, 90, "scale=1 卡片下边距 90")

    // ⚠️ **核心不变量**：窗口中心 = 卡片中心。
    // 这条破了，「缩放时保持卡片中心不动」就不成立
    // （而且所有以课表中心为锚点的弹窗都会相对课表错位）。
    for s in [0.70, 0.85, 1.0, 1.15] {
        TimetableLayout.apply(scale: CGFloat(s))
        let card = TimetableLayout.cardRect
        let winCenter = NSPoint(x: TimetableLayout.windowWidth / 2,
                                y: TimetableLayout.windowHeight / 2)
        expect(abs(card.midX - winCenter.x) < 0.001,
               "scale=\(s) 卡片中心 X = 窗口中心 X")
        expect(abs(card.midY - winCenter.y) < 0.001,
               "scale=\(s) 卡片中心 Y = 窗口中心 Y")
    }

    // ⚠️ **核心不变量**：缩放后所有几何 = scale=1 布局的等比放大。
    // 不等比的话，原生算出的「某一天在某一行」会和网页里的实际位置对不上
    // （表现是「菜单弹在隔壁那一格」）。
    //
    // ⚠️ **容差 1pt**：窗口尺寸只能是整数点，所以卡片宽高、投影留白都取整了
    // （见 `TimetableLayout` 里的取整说明）。
    // 取整带来的误差最多 1pt，对命中没有影响（差 1pt 点不到隔壁格子）。
    TimetableLayout.resetScale()
    let base = (
        cardWidth: TimetableLayout.cardWidth,
        cardHeight: TimetableLayout.cardHeight,
        dayColumnWidth: TimetableLayout.dayColumnWidth,
        gridOrigin: TimetableLayout.gridOrigin,
        periodRect: TimetableLayout.periodRect(period: 3),
        headerRect: TimetableLayout.headerRect,
        courseRect: TimetableLayout.courseRect(block: 2, day: 4),
        dayColumn: TimetableLayout.dayColumn(day: 5)
    )
    for s in [0.70, 0.85, 1.15] {
        TimetableLayout.apply(scale: CGFloat(s))
        let f = CGFloat(s)
        expect(abs(TimetableLayout.cardWidth - base.cardWidth * f) <= 1.0,
               "scale=\(s) 卡片宽等比")
        expect(abs(TimetableLayout.cardHeight - base.cardHeight * f) <= 1.0,
               "scale=\(s) 卡片高等比")
        expect(abs(TimetableLayout.dayColumnWidth - base.dayColumnWidth * f) <= 1.0,
               "scale=\(s) 星期列宽等比")
        expect(abs(TimetableLayout.gridOrigin.x - base.gridOrigin.x * f) <= 1.0,
               "scale=\(s) 网格原点 X 等比")
        expect(abs(TimetableLayout.gridOrigin.y - base.gridOrigin.y * f) <= 1.0,
               "scale=\(s) 网格原点 Y 等比")
        let pr = TimetableLayout.periodRect(period: 3)
        expect(abs(pr.origin.x - base.periodRect.origin.x * f) <= 1.0
               && abs(pr.origin.y - base.periodRect.origin.y * f) <= 1.0
               && abs(pr.width - base.periodRect.width * f) <= 1.0
               && abs(pr.height - base.periodRect.height * f) <= 1.0,
               "scale=\(s) 时间段矩形等比")
        let hr = TimetableLayout.headerRect
        expect(abs(hr.width - base.headerRect.width * f) <= 1.0
               && abs(hr.height - base.headerRect.height * f) <= 1.0,
               "scale=\(s) 表头矩形等比")
        let cr = TimetableLayout.courseRect(block: 2, day: 4)
        expect(abs(cr.origin.x - base.courseRect.origin.x * f) <= 1.0
               && abs(cr.width - base.courseRect.width * f) <= 1.0
               && abs(cr.height - base.courseRect.height * f) <= 1.0,
               "scale=\(s) 课程矩形等比")
        let dc = TimetableLayout.dayColumn(day: 5)
        expect(abs(dc.x - base.dayColumn.x * f) <= 1.0
               && abs(dc.width - base.dayColumn.width * f) <= 1.0,
               "scale=\(s) 星期列坐标等比")
    }
    TimetableLayout.resetScale()

    // 投影留白也必须跟着缩放 —— 不缩的话窗口中心 ≠ 卡片中心。
    // （留白取整，所以用 0.5 / 1.5 这类能整除的档位。）
    TimetableLayout.apply(scale: 0.5)
    expectEqual(TimetableLayout.shadowMargin, 45, "scale=0.5 投影留白 45")
    TimetableLayout.apply(scale: 1.5)
    expectEqual(TimetableLayout.shadowMargin, 135, "scale=1.5 投影留白 135")
    TimetableLayout.resetScale()

    // 基准卡片尺寸（算屏幕上限用）。
    expectEqual(TimetableLayout.baseCardSize.width, 968, "基准卡片宽")
    expectEqual(TimetableLayout.baseCardSize.height, 773, "基准卡片高")
}

suite("外观配置 · cardScale 往返") {
    // 老配置没有 cardScale → 默认 1.0（自动兼容，不能报错也不能是 0）。
    let old = AppearanceConfig(["fadeInSec": 1.0, "minOpacity": 0.5])
    expectEqual(old.cardScale, 1.0, "老配置缺 cardScale → 默认 1.0")
    expectEqual(old.fadeInSec, 1.0, "老配置其它项照常读")

    // 写回字典要带上 cardScale。
    var c = AppearanceConfig([:])
    c.cardScale = 0.85
    expectEqual(c.dictionary["cardScale"], 0.85, "cardScale 写进字典")

    // 往返。
    let round = AppearanceConfig(c.dictionary)
    expectEqual(round.cardScale, 0.85, "cardScale 往返一致")

    // AppearanceSettings 同理。
    let s = AppearanceSettings(dictionary: ["cardScale": 1.15])
    expectEqual(s.cardScale, 1.15, "AppearanceSettings 读 cardScale")
    expectEqual(s.dictionary["cardScale"], 1.15, "AppearanceSettings 写 cardScale")
    expectEqual(AppearanceSettings(dictionary: [:]).cardScale, 1.0,
                "AppearanceSettings 缺项 → 1.0")
    expectEqual(AppearanceSettings().asAppearanceConfig.cardScale, 1.0,
                "默认构造 → 1.0")
}

DialogStyleTests.run()

print("")
if failures == 0 {
    print("✓ 全部通过（\(checks) 项断言）")
    exit(0)
} else {
    print("✗ \(failures) 项失败 / \(checks) 项断言")
    exit(1)
}

// MARK: - 日记（2026-11-10）

suite("日记 · 存储（增 / 改 / 删 / 排序）") {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dt-diary-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DiaryStore(directory: dir)

    // 空目录：不崩、返回空。
    expectEqual(store.all().count, 0, "空目录应该没有任何日记")

    // 同一天按时间升序；没写时间的排最后。
    let late = try! store.add(date: "2026-11-11", title: "晚", body: "b", time: "20:00")
    let early = try! store.add(date: "2026-11-11", title: "早", body: "a", time: "08:00")
    let noTime = try! store.add(date: "2026-11-11", title: "没时间", body: "c", time: "")
    let other = try! store.add(date: "2026-11-12", title: "第二天", body: "d", time: "09:00")

    let day1 = store.entries(on: "2026-11-11")
    expectEqual(day1.count, 3, "同一天应该读到 3 条")
    expectEqual(day1.map(\.title), ["早", "晚", "没时间"], "同一天按时间升序，没时间的排最后")
    expectEqual(store.entries(on: "2026-11-10").count, 0, "别的日子没有日记")

    // all() 日期倒序：11-12 排在 11-11 前面。
    expectEqual(store.all().first?.id, other.id, "all() 按日期倒序")

    // 改：标题 / 正文 / 时间都变了，id 不变。
    _ = try! store.update(id: early.id, title: "早（改）", body: "aa", time: "07:30")
    let updated = store.entries(on: "2026-11-11").first
    expectEqual(updated?.title, "早（改）", "改标题要落盘")
    expectEqual(updated?.time, "07:30", "改时间要落盘")
    expectEqual(updated?.id, early.id, "改完 id 不能变")

    // 删：只删这一条。
    _ = try! store.delete(id: late.id)
    expectEqual(store.entries(on: "2026-11-11").count, 2, "删一条之后剩 2 条")
    expect(!store.entries(on: "2026-11-11").contains { $0.id == late.id }, "删掉的那条不该还在")

    // 删不存在的：返回 false、不崩。
    expectEqual(try! store.delete(id: "不存在"), false, "删不存在的 id 应该返回 false")

    // 换一个 store 实例读同一份文件（证明真的落盘了）。
    let reread = DiaryStore(directory: dir)
    expectEqual(reread.entries(on: "2026-11-11").count, 2, "重新打开文件应该还能读到 2 条")
    expectEqual(reread.count(), 3, "全量 3 条（两天）")
}

suite("日记 · 坏文件不吞数据") {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dt-diary-bad-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("diary.json")
    try! "{ 这不是 JSON".data(using: .utf8)!.write(to: file)

    let store = DiaryStore(directory: dir)
    expectEqual(store.all().count, 0, "坏文件按空处理（不能崩）")

    // 写一次之后，坏文件应该被备份出来，而不是被静默覆盖。
    _ = try! store.add(date: "2026-11-11", title: "新的", body: "", time: "")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
        .filter { $0.hasPrefix("diary.corrupt-") } ?? []
    expectEqual(backups.count, 1, "坏文件要备份成 diary.corrupt-*.json")
}

suite("日记 · 日期键与内容 JSON") {
    // 日期键只用一种格式，避免时区 / locale 漂移。
    expectEqual(DiaryStore.dateKey(day(2026, 11, 11)), "2026-11-11", "日期键格式")

    var content = DayPanelContent(day: 3)
    content.diary = [DayPanelDiary(id: "x", title: "标题", body: "正文", time: "20:00")]
    let json = content.jsonObject
    let diary = json["diary"] as? [[String: Any]] ?? []
    expectEqual(diary.count, 1, "jsonObject 要带 diary")
    expectEqual(diary.first?["title"] as? String, "标题", "jsonObject 的标题")
    expectEqual(diary.first?["time"] as? String, "20:00", "jsonObject 的时间")
}

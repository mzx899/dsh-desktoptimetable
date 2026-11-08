import Foundation

/// 课表显示状态：把「当前在看哪一周」和课程数据算成渲染需要的一切。
///
/// 纯逻辑，不碰 UI，方便单元测试。
struct TimetableState {
    var courses: [Course] = []
    var semesterStart: Date = Date()
    /// 开学日所在周为第 1 周；超出学期范围时为 nil。
    var currentWeek: Int?
    /// 正在浏览的周；nil = 「全部周次」。
    var viewWeek: Int?
    var now: Date = Date()
    /// 学期总周数（来自 semester.json / effectiveMaxWeek）。
    var maxWeek: Int = Schedule.defaultMaxWeek
    /// 单周临时覆盖（独立文件 `week_overrides.json` 里的记录）。
    var overrides: [WeekOverride] = []

    /// 网格最多显示 5 个 block（第 1–10 节）。合法范围以 `Course.blockRange` 为准。
    static let maxBlock = Course.blockRange.upperBound

    /// 把「正在浏览的周次」夹回合法范围（纯函数，可单测）。
    ///
    /// 切到周数更少的课表后，旧的浏览周次（比如第 18 周）会超出新学期 ——
    /// 界面上显示「第 18 周」，而课表只有 16 周。
    /// 网页侧也有一道兜底（`Timetable.js` 里把超范围的周次夹到 `MAX_WEEK`），
    /// 但真正该修的是数据源：切课表时就该夹一次。
    ///
    /// - Parameters:
    ///   - viewWeek: 当前浏览的周次（nil = 「全部周次」，保持 nil）。
    ///   - maxWeek: 学期总周数。
    ///   - currentWeek: 当前周（越界时回落到它；它自己也不合法就退回第 1 周）。
    static func clampedViewWeek(_ viewWeek: Int?, maxWeek: Int, currentWeek: Int?) -> Int? {
        guard let w = viewWeek else { return nil }
        let range = 1...max(1, maxWeek)
        if range.contains(w) { return w }
        if let c = currentWeek, range.contains(c) { return c }
        return range.lowerBound
    }

    // MARK: - 临时覆盖

    /// 某一周的覆盖（`"day-block"` → 覆盖记录）。全部周次视图 → 空。
    ///
    /// 「全部周次」视图**忽略**覆盖 —— 那里只显示原始课表。
    func overrideMap(for week: Int?) -> [String: WeekOverride] {
        guard let week else { return [:] }
        var map: [String: WeekOverride] = [:]
        for o in overrides where o.applies(to: week) {
            map["\(o.day)-\(o.block)"] = o
        }
        return map
    }

    /// 这一周**实际显示**的课程。
    ///
    /// 被覆盖的格子只显示覆盖课 —— 那一格原来的课在这一周被遮住
    /// （「只在被覆盖的那几周隐藏掉那个时间段的，其他的不受影响」）。
    /// 全部周次视图忽略覆盖 → 原样返回 `courses`。
    func displayCourses(for week: Int?) -> [Course] {
        guard let week else { return courses }
        let ov = overrideMap(for: week)
        guard !ov.isEmpty else { return courses }
        var out = courses.filter { ov["\($0.day)-\($0.block)"] == nil }
        out += ov.values.map { $0.asCourse() }
        return out.sorted { ($0.day, $0.block) < ($1.day, $1.block) }
    }

    // MARK: - 派生状态

    var isAllWeeks: Bool { viewWeek == nil }
    var isCurWeek: Bool { !isAllWeeks && currentWeek != nil && viewWeek == currentWeek }

    /// 表头日期跟着「正在看的那一周」走；全部周次时用本周。
    var baseWeek: Int { isAllWeeks ? (currentWeek ?? 1) : (viewWeek ?? 1) }

    /// "day-block" → 课程
    var courseMap: [String: Course] {
        var map: [String: Course] = [:]
        for c in displayCourses(for: isAllWeeks ? nil : viewWeek) where c.day >= 1 && c.day <= 7 {
            map["\(c.day)-\(c.block)"] = c
        }
        return map
    }

    /// 同一格里可能有冲突（多门课）→ 全部列出来。
    var slotCourses: [String: [Course]] {
        var map: [String: [Course]] = [:]
        for c in displayCourses(for: isAllWeeks ? nil : viewWeek) where c.day >= 1 && c.day <= 7 {
            map["\(c.day)-\(c.block)", default: []].append(c)
        }
        return map
    }

    /// 有冲突的时间格（用于渲染标记）。
    var conflictSlots: Set<String> {
        Set(ScheduleConflicts.detect(courses).map { "\($0.day)-\($0.block)" })
    }

    /// 这门课在当前查看的周是否上课。
    func runsThisWeek(_ course: Course) -> Bool {
        course.isActive(in: isAllWeeks ? nil : baseWeek)
    }

    /// 这门课在「本周」是否上课。
    func runsCurWeek(_ course: Course) -> Bool {
        course.isActive(in: currentWeek)
    }

    var todayIndex: Int { WeekMath.todayIndex(now) }

    var minutesNow: Int { WeekMath.minutesSinceMidnight(now) }

    /// 当前正在上的课（block 索引），没有则 nil。
    var currentBlock: Int? {
        let cur = minutesNow
        for i in 0...Self.maxBlock {
            guard let s = Self.blockStart(i), let e = Self.blockEnd(i) else { continue }
            if cur >= Schedule.minutes(s) && cur <= Schedule.minutes(e) { return i }
        }
        return nil
    }

    /// 正在上的那门课。
    var currentCourse: Course? {
        guard let b = currentBlock, isCurWeek else { return nil }
        let c = courseMap["\(todayIndex)-\(b)"]
        guard let c, runsCurWeek(c) else { return nil }
        return c
    }

    /// 下一节课。
    var nextCourse: (course: Course, block: Int)? {
        let cur = minutesNow
        for i in 0...Self.maxBlock {
            guard let s = Self.blockStart(i), Schedule.minutes(s) > cur else { continue }
            guard let c = courseMap["\(todayIndex)-\(i)"], runsCurWeek(c) else { continue }
            return (c, i)
        }
        return nil
    }

    /// 本周（当前周）今天的课程数。
    ///
    /// 覆盖课也算：它在被覆盖的那几周确实有课。
    /// 被覆盖掉的原课不算：那一周它已经被遮住了。
    var todayCount: Int {
        let week = isAllWeeks ? nil : viewWeek
        return displayCourses(for: week).filter { $0.day == todayIndex && runsCurWeek($0) }.count
    }

    /// 当前查看的周有几门课。
    var weekCount: Int {
        displayCourses(for: isAllWeeks ? nil : baseWeek).filter { $0.isActive(in: baseWeek) }.count
    }

    // MARK: - 状态条文案

    struct Status {
        var text: String
        var meta: String
        var isLive: Bool = false
    }

    var status: Status {
        if isAllWeeks {
            return Status(text: "全部周次 · 共 \(courses.count) 门课",
                          meta: "\(WeekMath.semesterRangeText(semesterStart, maxWeek: maxWeek))　·　第 1–\(maxWeek) 周全部课程")
        }
        if !isCurWeek {
            return Status(text: "第 \(baseWeek) 周 · 共 \(weekCount) 门课",
                          meta: "\(WeekMath.weekDateText(baseWeek, semesterStart: semesterStart))　·　本学期第 1–\(maxWeek) 周　·　用左右箭头浏览其他周次")
        }
        if let cur = currentCourse, let b = currentBlock,
           let s = Self.blockStart(b), let e = Self.blockEnd(b) {
            let left = Schedule.minutes(e) - minutesNow
            return Status(text: "正在上课 · \(cur.name)",
                          meta: "\(s)–\(e)　·　剩 \(Self.gapText(left))　·　\(cur.briefLoc)",
                          isLive: true)
        }
        if let (next, nb) = nextCourse, let s = Self.blockStart(nb) {
            let until = Schedule.minutes(s) - minutesNow
            return Status(text: "下一节 · \(next.name)",
                          meta: "\(s) 开始　·　还有 \(Self.gapText(until))　·　\(next.briefLoc)")
        }
        return todayCount > 0
            ? Status(text: "今日课程已结束", meta: "今天共 \(todayCount) 门课　·　好好休息")
            : Status(text: "今天没有课", meta: "自由安排")
    }

    // MARK: - 工具

    static func blockStart(_ block: Int) -> String? {
        let i = block * 2
        guard i >= 0, i < Schedule.periods.count else { return nil }
        return Schedule.periods[i].start
    }

    static func blockEnd(_ block: Int) -> String? {
        let i = block * 2 + 1
        guard i >= 0, i < Schedule.periods.count else { return nil }
        return Schedule.periods[i].end
    }

    /// 90 → "1 小时 30 分"，45 → "45 分钟"
    static func gapText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }

    // MARK: - 推给网页的状态 JSON

    /// 拼出推给网页的状态快照（网页只做展示，不保存业务状态）。
    ///
    /// **`currentWeek` / `viewWeek` 必须是 JSON 数字，未选周次时必须是 JSON `null`。**
    ///
    /// 网页那边判的是：
    /// ```js
    /// var week = (typeof S.viewWeek === 'number') ? S.viewWeek : null;
    /// ```
    /// 一旦推成**字符串** `"9"`，`typeof` 就是 `"string"`，网页会当成「没选中任何周次」：
    ///   · 周次胶囊永远显示「全部周次」（而不是「本周」/「第 9 周」），
    ///     胶囊变宽把左右箭头挤开 —— 看着就是「位置和旧版不一样」；
    ///   · `curWeek` 也读不到 → `isCurWeek` 永远 false → 「回到本周」变灰且点了没反应；
    ///   · 点左右箭头时原生确实改了 `viewWeek` 并重推，但网页每次读到的还是字符串
    ///     → 画面**完全没有变化** —— 用户看到的就是「按了没反应」。
    ///
    /// 这个坑是阶段 1–3 从「裸字符串插值」改成 `JSONSerialization` 时引入的：
    /// 插值时代码写的是 `"currentWeek": \(cur)`，产出数字 `9`；
    /// 改成字典后 `cur` 仍是 `String`，于是 JSON 里变成 `"9"`。
    /// 所以这里**显式**用 `map { $0 as Any } ?? NSNull()`，别再用 `String.init`。
    func webJSON(title: String, subtitle: String) -> String {
        let obj = webObject(title: title, subtitle: subtitle)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"courses\":[]}"
        }
        return json
    }

    /// 完整状态**字典**（`webJSON` 的字典版本）。
    ///
    /// 为什么要字典版本：日期覆盖层拿到数据后，要把 `dayPanel` / `dayFlags`
    /// **合并进同一份状态**再推给网页 —— 只推增量的话，
    /// 网页会把课表状态整个丢掉（课程、学期、周次全没了）。
    /// 两条推送通道共用一份字典，就不会出现「推了 A 把 B 冲掉」的问题。
    func webObject(title: String, subtitle: String) -> [String: Any] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let obj: [String: Any] = [
            "courses": courses.map { c -> [String: Any] in
                [
                    "courseID": c.courseID,
                    "name": c.name,
                    "code": c.code,
                    "teacher": c.teacher,
                    "loc": c.loc,
                    "day": c.day,
                    "block": c.block,
                    "weeks": c.weeks,
                    "weeksLabel": c.weeksLabel,
                    // 颜色由原生**解析好**再推（显式色 > 按课名 > 灰），
                    // 永远有值；网页不再自己维护一份课程配色表。
                    "color": ColorHex.resolvedHex(for: c),
                ]
            },
            "semesterStart": fmt.string(from: semesterStart),
            "currentWeek": currentWeek.map { $0 as Any } ?? NSNull(),
            "viewWeek": viewWeek.map { $0 as Any } ?? NSNull(),
            "maxWeek": maxWeek,
            "title": title,
            "subtitle": subtitle,
            // 作息时间：网页左侧时间列 / 课程块时间都按这份数据画，
            // 不再用 Timetable.js 里写死的 PERIODS。
            "periods": Schedule.periods.map { ["s": $0.start, "e": $0.end] },
            // 单周临时覆盖：网页在**单周视图**里用它顶掉那一格，
            // 「全部周次」视图直接忽略（那边只显示原始课表）。
            "overrides": overrides.map { o -> [String: Any] in
                [
                    "courseID": o.courseID,
                    "name": o.name,
                    "code": o.code,
                    "teacher": o.teacher,
                    "loc": o.loc,
                    "day": o.day,
                    "block": o.block,
                    "weeks": o.weeks,
                    "weeksLabel": WeekSpec.format(Set(o.weeks)),
                    // 覆盖课也要带解析好的颜色，否则网页会用兜底色画它。
                    "color": ColorHex.resolvedHex(name: o.name, colorHex: o.colorHex),
                ]
            },
        ]
        return obj
    }
}

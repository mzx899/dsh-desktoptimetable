import Foundation

/// 一条上课提醒的**计划**（还没进系统通知中心）。
struct ReminderPlan: Equatable {
    /// 稳定的通知 id（同一天重算用它覆盖旧通知，不会越排越多）。
    var id: String
    /// 提醒触发时刻（Date，Asia/Shanghai 语义）。
    var fireDate: Date
    /// 通知标题。
    var title: String
    /// 通知正文。
    var body: String
    /// 星期几（1=周一 ... 7=周日）。
    var day: Int
    /// 第几节课（block，0...4）。
    var block: Int
    /// 教学周（第几周）。
    var week: Int
    /// 这一格里的课程名（同一格多门课冲突时合并成一条通知）。
    var courseNames: [String]
}

/// 上课提醒的**纯逻辑规划器**。
///
/// 纯函数，不 import UserNotifications —— 系统调度的活儿在
/// `ClassReminderScheduler` 里。这样规划逻辑能完整单测，
/// 测试也永远不会碰到真实系统 API。
enum ClassReminderPlanner {

    /// 往后的规划天数（从今天算起，含今天）。
    static let horizonDays = 14
    /// 本应用的硬上限（系统上限是 64，本应用留一格余量）。
    static let maxPlans = 60
    /// 通知 id 的前缀。
    static let idPrefix = "dt.class."
    /// 测试通知 id 的前缀（启动时清理遗留的）。
    static let testIDPrefix = "dt.test."
    /// 教学周使用的固定时区。
    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 0)!

    /// 规划结果（计划 + 被丢掉的数量）。
    struct Result: Equatable {
        var plans: [ReminderPlan] = []
        /// 因超过上限被丢掉的条数（不静默截断）。
        var droppedCount: Int = 0
    }

    /// 规划未来 `horizonDays` 天的上课提醒。
    ///
    /// - Parameters:
    ///   - courses: 当前课表的课程记录。
    ///   - overrides: 单周临时覆盖记录。
    ///   - semesterStart: 开学日期。
    ///   - maxWeek: **生效**的学期总周数（`SemesterConfig.effectiveMaxWeek`）。
    ///   - leadMinutes: 提前多少分钟提醒。
    ///   - now: 当前时间。
    static func plan(courses: [Course],
                     overrides: [WeekOverride],
                     semesterStart: Date,
                     maxWeek: Int,
                     leadMinutes: Int,
                     now: Date) -> [ReminderPlan] {
        planDetailed(courses: courses, overrides: overrides, semesterStart: semesterStart,
                     maxWeek: maxWeek, leadMinutes: leadMinutes, now: now).plans
    }

    /// 同上，但同时返回被丢掉的条数。
    static func planDetailed(courses: [Course],
                              overrides: [WeekOverride],
                              semesterStart: Date,
                              maxWeek: Int,
                              leadMinutes: Int,
                              now: Date) -> Result {
        let state = TimetableState(courses: courses,
                                   semesterStart: semesterStart,
                                   currentWeek: WeekMath.weekNumber(now, semesterStart: semesterStart),
                                   viewWeek: nil,
                                   now: now,
                                   maxWeek: maxWeek,
                                   overrides: overrides)
        let lead = ReminderSettings.clampLead(leadMinutes)
        var plans: [ReminderPlan] = []

        let cal = WeekMath.calendar
        let today = cal.startOfDay(for: now)

        for offset in 0..<horizonDays {
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let week = WeekMath.weekNumber(date, semesterStart: semesterStart)
            // 只保留学期范围内的周（1...maxWeek）。
            guard week >= 1, week <= maxWeek else { continue }
            let dayIndex = WeekMath.todayIndex(date)

            // 当周实际课程 —— **复用** `TimetableState.displayCourses(for:)` 的语义：
            // 覆盖生效的周只算覆盖课，原课不提醒；未覆盖的周仍提醒原课。
            let weekCourses = state.displayCourses(for: week)
                .filter { $0.day == dayIndex && $0.isActive(in: week) }
            guard !weekCourses.isEmpty else { continue }

            // 同一格多门冲突课 → 合并成一条通知。
            let byBlock = Dictionary(grouping: weekCourses, by: { $0.block })
            for (block, list) in byBlock {
                guard let startText = TimetableState.blockStart(block),
                      let endText = TimetableState.blockEnd(block) else { continue }
                guard let start = dateBySettingMinutes(startText, on: date),
                      let end = dateBySettingMinutes(endText, on: date) else { continue }
                // 提醒时间 = 开始时间 - 提前分钟数。
                let fire = start.addingTimeInterval(TimeInterval(-lead * 60))
                // 提醒时间已过去 / 课程已开始 → 不排（不补发一堆迟到通知）。
                guard fire > now else { continue }
                // 课程已经结束 → 不排。
                guard end > now else { continue }

                let names = list.map { $0.name }.sorted()
                plans.append(ReminderPlan(
                    id: notificationID(date: date, day: dayIndex, block: block),
                    fireDate: fire,
                    title: titleText(leadMinutes: lead),
                    body: bodyText(names: names, start: startText, end: endText, courses: list),
                    day: dayIndex,
                    block: block,
                    week: week,
                    courseNames: names))
            }
        }

        // 按触发时间排序，只保留最早的 maxPlans 条，其余记进 droppedCount。
        plans.sort { ($0.fireDate, $0.day, $0.block) < ($1.fireDate, $1.day, $1.block) }
        var result = Result()
        if plans.count > maxPlans {
            result.droppedCount = plans.count - maxPlans
            plans = Array(plans.prefix(maxPlans))
        }
        result.plans = plans
        return result
    }

    // MARK: - 文案

    /// 通知标题。
    static func titleText(leadMinutes: Int) -> String {
        leadMinutes > 0 ? "\(leadMinutes) 分钟后上课" : "马上要上课了"
    }

    /// 通知正文：`「高等数学 · 08:00–09:35 · 教三-201」`。
    /// 多门课用「 / 」连接；地点 / 教师为空时省略。
    static func bodyText(names: [String], start: String, end: String, courses: [Course]) -> String {
        var parts: [String] = []
        parts.append(names.joined(separator: " / "))
        parts.append("\(start)–\(end)")
        let locs = courses.map { $0.loc.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let loc = locs.first { parts.append(loc) }
        let teachers = courses.map { $0.teacher.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if locs.isEmpty, let t = teachers.first { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    // MARK: - id

    /// 通知 id：`dt.class.<yyyyMMdd>.<day>.<block>`（纯 ASCII、稳定）。
    ///
    /// 同一天重算用同一个 id → 系统里旧的那条被**覆盖**，不会越排越多。
    static func notificationID(date: Date, day: Int, block: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd"
        return "\(idPrefix)\(f.string(from: date)).\(day).\(block)"
    }

    // MARK: - 时间

    /// 把「HH:mm」落到某一天的零点起第几分钟。
    static func dateBySettingMinutes(_ hhmm: String, on day: Date) -> Date? {
        let cal = WeekMath.calendar
        let start = cal.startOfDay(for: day)
        return cal.date(byAdding: .minute, value: Schedule.minutes(hhmm), to: start)
    }

    /// Date → 触发用的 DateComponents（**必须带 Asia/Shanghai**）。
    ///
    /// `UNCalendarNotificationTrigger` 用的是「墙上时间」，不带时区的话
    /// 换个时区就全乱了。这里显式带上教学周使用的固定时区。
    static func dateComponents(for date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // `dateComponents(_:from:)` 不会把时区塞进结果里 —— 必须显式带上，
        // 否则触发器的「墙上时间」会按系统当前时区解释。
        comps.timeZone = timeZone
        comps.second = 0
        return comps
    }
}

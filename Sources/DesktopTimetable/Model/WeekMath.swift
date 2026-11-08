import Foundation

/// 学期 / 周次计算。教学周固定按「周一 → 周日」划分。
///
/// 全部函数是无状态的纯函数，方便单元测试。
enum WeekMath {
    /// 教学周使用的时区与历法配置（周一为一周的第一天）。
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()

    /// 该日期所在教学周的周一（零点）。
    static func mondayOfWeek(_ date: Date) -> Date {
        let cal = calendar
        let day = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: day)   // 周一=2 ... 周日=1
        let back = (weekday + 5) % 7
        return cal.date(byAdding: .day, value: -back, to: day) ?? day
    }

    /// 指定日期是第几教学周（开学日所在周的周一为第 1 周）。
    static func weekNumber(_ date: Date, semesterStart: Date) -> Int {
        let cal = calendar
        let from = cal.startOfDay(for: mondayOfWeek(semesterStart))
        let to = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: from, to: to).day ?? 0
        return days / 7 + 1
    }

    /// 某教学周的起止日期（周一、周日）。
    static func weekRange(_ week: Int, semesterStart: Date) -> (start: Date, end: Date)? {
        let cal = calendar
        let anchor = cal.startOfDay(for: mondayOfWeek(semesterStart))
        guard let s = cal.date(byAdding: .day, value: (week - 1) * 7, to: anchor),
              let e = cal.date(byAdding: .day, value: 6, to: s)
        else { return nil }
        return (s, e)
    }

    /// 某教学周里第 `day` 天（1=周一 ... 7=周日）的日期。
    static func dayDate(_ week: Int, semesterStart: Date, day: Int) -> Date? {
        guard let (start, _) = weekRange(week, semesterStart: semesterStart) else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: start)
    }

    /// "10月19日"
    static func monthDayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    /// "10月19日 – 10月25日"
    static func weekDateText(_ week: Int, semesterStart: Date) -> String {
        guard let (s, e) = weekRange(week, semesterStart: semesterStart) else { return "" }
        return "\(monthDayText(s)) – \(monthDayText(e))"
    }

    /// 整个学期的起止，如 "2026年8月31日 – 2027年1月17日"。
    static func semesterRangeText(_ semesterStart: Date, maxWeek: Int = Schedule.defaultMaxWeek) -> String {
        guard let (s, _) = weekRange(1, semesterStart: semesterStart),
              let (e, _) = weekRange(maxWeek, semesterStart: semesterStart)
        else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy年M月d日"
        let last = calendar.date(byAdding: .day, value: 6, to: e) ?? e
        return "\(f.string(from: s)) – \(f.string(from: last))"
    }

    /// 今天是星期几（1=周一 ... 7=周日）。
    static func todayIndex(_ date: Date = Date()) -> Int {
        let wd = calendar.component(.weekday, from: calendar.startOfDay(for: date))
        return wd == 1 ? 7 : wd - 1
    }

    /// 从 "HH:mm" 取当天零点起的分钟数。
    static func minutesSinceMidnight(_ date: Date = Date()) -> Int {
        let c = calendar
        let h = c.component(.hour, from: date)
        let m = c.component(.minute, from: date)
        return h * 60 + m
    }
}

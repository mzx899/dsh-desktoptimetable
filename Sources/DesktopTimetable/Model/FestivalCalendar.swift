import Foundation

/// 节日查询（公历节日 + 农历节日）。
///
/// 全部函数是无状态的纯函数，不碰 IO / 网络 / UI。
///
/// 输出是 `[String]` —— 一天可能同时是多个节日（比如 10 月 1 日既是国庆节，
/// 又可能撞上农历某个节日），规格里 `festivals` 字段就是数组。
enum FestivalCalendar {

    /// 历法计算用的时区 —— **固定 UTC+8**，理由同 `LunarCalendar.calendar`：
    /// IANA `Asia/Shanghai` 带历史偏移（1901 年前的 LMT +08:05:43、
    /// 1940/1986–1991 的 +09:00 与夏令时 +10:00），用它划日界会让某些日期
    /// 差一小时，足以把节日挪到隔壁一天。
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    /// 星期几（1 = 周一 … 7 = 周日）。
    ///
    /// 「第几个星期几」的节日（母亲节、感恩节……）要靠它。
    /// 注意 Calendar 的 `.weekday` 是 1 = 周日 … 7 = 周六，这里转成 1 = 周一。
    private static func weekdayIndex(_ date: Date) -> Int {
        let wd = calendar.component(.weekday, from: date)
        return wd == 1 ? 7 : wd - 1
    }

    // MARK: - 公历节日

    /// 固定月日的公历节日。
    ///
    /// 只放**日期固定、全国通行**的节日。春节/端午这类农历节日不在这里。
    /// 洋节（情人节、万圣节、平安夜）也列进来了 —— 覆盖层的用途是
    /// 「让用户知道今天是什么日子」，漏掉反而是缺陷；
    /// 但**不收**联合国纪念日之类的冷门条目，避免列表变成噪音。
    private static let fixedSolarFestivals: [(month: Int, day: Int, name: String)] = [
        (1, 1, "元旦"),
        (2, 14, "情人节"),
        (3, 8, "妇女节"),
        (3, 12, "植树节"),
        (4, 1, "愚人节"),
        (5, 1, "劳动节"),
        (5, 4, "青年节"),
        (5, 12, "护士节"),
        (6, 1, "儿童节"),
        (7, 1, "建党节"),
        (8, 1, "建军节"),
        (9, 10, "教师节"),
        (10, 1, "国庆节"),
        // 10 月 31 日是万圣节前夜（Halloween），11 月 1 日才是万圣节，
        // 一前一后不能写反。
        (10, 31, "万圣节前夜"),
        (11, 1, "万圣节"),
        (11, 11, "光棍节"),
        (12, 24, "平安夜"),
        (12, 25, "圣诞节")
    ]

    /// 「第几个星期几」的公历节日。
    ///
    /// 母亲节（5 月第二个周日）、父亲节（6 月第三个周日）、
    /// 感恩节（11 月第四个周四）、美国阵亡将士纪念日（5 月最后一个周一）。
    private struct WeekdayFestival {
        let month: Int
        /// 第几个（1 起）；`0` = 最后一个。
        let ordinal: Int
        /// 星期几（1 = 周一 … 7 = 周日）。
        let weekday: Int
        let name: String
    }

    /// 「第几个星期几」节日表。
    private static let weekdayFestivals: [WeekdayFestival] = [
        WeekdayFestival(month: 5, ordinal: 2, weekday: 7, name: "母亲节"),
        WeekdayFestival(month: 6, ordinal: 3, weekday: 7, name: "父亲节"),
        WeekdayFestival(month: 11, ordinal: 4, weekday: 4, name: "感恩节"),
        WeekdayFestival(month: 5, ordinal: 0, weekday: 1, name: "美国阵亡将士纪念日")
    ]

    /// 某天的公历节日。
    ///
    /// 返回值按「固定月日 → 第几个星期几」的顺序拼接，同一天可能多个。
    static func solarFestivals(on date: Date) -> [String] {
        let day = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.month, .day], from: day)
        guard let month = parts.month, let dayNum = parts.day else { return [] }

        // 固定月日的节日
        var names: [String] = []
        for item in fixedSolarFestivals where item.month == month && item.day == dayNum {
            names.append(item.name)
        }
        // 「第几个星期几」类节日
        let weekday = weekdayIndex(day)
        for f in weekdayFestivals where f.month == month && f.weekday == weekday {
            if isWeekdayOccurrence(f, on: day) {
                names.append(f.name)
            }
        }
        return names
    }

    /// 判断某天是不是「该月的第 n 个星期 w」。
    ///
    /// `ordinal == 0` 表示「最后一个」。
    private static func isWeekdayOccurrence(_ f: WeekdayFestival, on day: Date) -> Bool {
        let cal = calendar
        let parts = cal.dateComponents([.year, .month], from: day)
        guard let year = parts.year, let month = parts.month,
              let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1))
        else { return false }

        // 该月第一个星期 f.weekday 的日期
        let delta = (f.weekday - weekdayIndex(monthStart) + 7) % 7
        guard let first = cal.date(byAdding: .day, value: delta, to: monthStart) else { return false }

        if f.ordinal > 0 {
            return cal.date(byAdding: .day, value: (f.ordinal - 1) * 7, to: first) == day
        }
        // 「最后一个」：从第一个往后数，直到再过一周就出月为止。
        // 「美国阵亡将士纪念日」是 5 月最后一个周一 —— 这个月有几个周一是变数，
        // 所以不能只看「第一个 + 3 周」。
        var candidate = first
        while true {
            guard let next = cal.date(byAdding: .day, value: 7, to: candidate),
                  cal.component(.month, from: next) == month
            else { break }
            candidate = next
        }
        return candidate == day
    }

    // MARK: - 农历节日

    /// 某天的农历节日。
    ///
    /// 「除夕」在这里动态判定：当天是农历腊月的**最后一天**就算除夕。
    /// 它不能写进固定表 —— 腊月有时 29 天有时 30 天，
    /// 写死「腊月三十」会有一半的年份漏掉。
    static func lunarFestivals(on date: Date) -> [String] {
        guard let lunar = LunarCalendar.lunar(from: date) else { return [] }
        // 闰月不算节日（闰八月十五不是中秋）。
        guard !lunar.isLeapMonth else { return [] }

        var names: [String] = []
        switch (lunar.month, lunar.day) {
        case (1, 1):  names.append("春节")
        case (1, 15): names.append("元宵节")
        case (2, 2):  names.append("龙抬头")
        case (5, 5):  names.append("端午节")
        case (7, 7):  names.append("七夕")
        case (7, 15): names.append("中元节")
        case (8, 15): names.append("中秋节")
        case (9, 9):  names.append("重阳节")
        case (12, 8): names.append("腊八节")
        case (12, 23): names.append("小年")   // 北方
        case (12, 24): names.append("小年")   // 南方
        case (12, 25): names.append("小年")   // 部分地区
        default: break
        }

        // 除夕 = 腊月最后一天
        if lunar.month == 12,
           let last = LunarCalendar.daysInMonth(lunarYear: lunar.year, month: 12),
           lunar.day == last {
            names.append("除夕")
        }
        return names
    }

    // MARK: - 汇总

    /// 某天的全部节日（公历 + 农历）。
    ///
    /// 同一天可能有多个节日，所以是数组。
    static func festivals(on date: Date) -> [String] {
        solarFestivals(on: date) + lunarFestivals(on: date)
    }

    /// 某天的节日名（多个时用「、」连接），没有节日返回空字符串。
    static func text(on date: Date) -> String {
        festivals(on: date).joined(separator: "、")
    }

    /// 某天是否有节日。
    static func hasFestival(_ date: Date) -> Bool {
        !festivals(on: date).isEmpty
    }

    /// 某个月的节日日历：`[(日, 名称数组)]`，按日序排好。
    ///
    /// 用于「本月节日一览」这类展示。
    static func festivals(inMonthOf year: Int, month: Int) -> [(day: Int, names: [String])] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first)
        else { return [] }
        var out: [(day: Int, names: [String])] = []
        for day in 1...range.count {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: first) else { continue }
            let names = festivals(on: date)
            if !names.isEmpty {
                out.append((day: day, names: names))
            }
        }
        return out
    }
}

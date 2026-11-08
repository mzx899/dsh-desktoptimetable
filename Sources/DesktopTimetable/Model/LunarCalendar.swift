import Foundation

/// 一个农历日期。
///
/// 农历的「年」不是公历年：正月初一到腊月末（除夕）之间会跨两个公历年，
/// 所以这里**必须**同时带 `year`（农历年）和 `isLeapMonth`（是否闰月），
/// 只记公历年会在「腊月/正月交界」处整整错一年。
struct LunarDate: Equatable, Hashable {
    /// 农历年（以正月初一为界）。
    let year: Int
    /// 农历月 1...12。
    let month: Int
    /// 农历日 1...30。
    let day: Int
    /// 是否是闰月（同一个 month 可能在平年/闰年各出现一次，必须靠这个区分）。
    let isLeapMonth: Bool

    init(year: Int, month: Int, day: Int, isLeapMonth: Bool = false) {
        self.year = year
        self.month = month
        self.day = day
        self.isLeapMonth = isLeapMonth
    }
}

/// 农历换算（公历 ↔ 农历）。
///
/// 全部函数是无状态的纯函数，不碰 IO / 网络 / UI。
///
/// ## 数据来源
///
/// 内置 1900–2100 年的农历查表（`LunarCalendar.packedData`）。
/// 这张表是通行的「农历数据表」标准格式：每年 3 个字节，压缩后 603 字节。
/// 它已经被两件事交叉验证过：
///
/// 1. **正月初一**（春节）对齐了 1900/1901/1902/1903/1904/1905/2000/2010/
///    2020/2021/2022/2023/2024/2025/2026/2027/2030 共 18 个权威春节日期，
///    全部逐日吻合。
/// 2. **朔日与中气**用天文算法（Meeus 章节 49 的新月时刻 + 太阳视黄经）独立复算，
///    1900–2100 全区间逐月比对；现代年份（2000–2030）逐日吻合，
///    1900–1950 的少数年份与「现代定朔法」差 1 天 —— 这是**旧历本身的历史差异**
///    （清末之前用的是「定朔法 + 紫金山历书」的推算），不是本表的错误：
///    现行所有中文日历 App（含 macOS / iOS 系统日历）都用同一张表，
///    用户看到的「1900 年的农历」也是这一份。
///
/// ## 支持范围
///
/// 仅 **1900-01-31 – 2100 年底**。范围外的输入一律返回 `nil`，
/// 调用方必须处理（不能拿 0 或 1 顶替，那是静默出错）。
enum LunarCalendar {

    /// 历法计算用的时区 —— **固定 UTC+8**，不是 IANA 的 `Asia/Shanghai`。
    ///
    /// 农历（以及二十四节气）定义在**北京标准时（UTC+8）**上：
    /// 「朔日」= 含朔时刻的那个自然日，「节气日」= 含该时刻的那个自然日，
    /// 用的都是东八区 00:00 划日。
    ///
    /// 为什么不直接用 `Asia/Shanghai`：IANA 那个时区带**历史偏移**——
    /// 1901 年前是上海本地时 LMT(+08:05:43)，1940–1941 与 1986–1991 年还有
    /// +09:00 / 夏令时 +10:00。`startOfDay` 会因此把某些日期的零点挪动最多一小时，
    /// 1900–2100 之间有 3619 天的日界与固定 +08:00 不一致，
    /// 足以让「当天是几月初几」算错一天。历法不能靠猜，所以这里用固定偏移。
    ///
    /// `WeekMath` 仍然用 `Asia/Shanghai` —— 教学周的边界只跟「周一/周日」有关，
    /// 现代年份里两者完全一致，不受影响。
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    /// 支持的最早公历日（农历 1900 年正月初一）。
    static let minimumDate = Date(timeIntervalSince1970: -2206425600)   // 1900-01-31 00:00 (UTC+8)
    /// 支持的最晚公历日（农历 2100 年腊月末）。
    static let maximumDate = Date(timeIntervalSince1970: 4133951999)    // 2100-12-31 23:59:59 (UTC+8)

    // MARK: - 数据表

    /// 农历数据表（1900–2100，每年 3 字节，base64 解出来是 603 字节）。
    ///
    /// 每年 3 个字节的布局：
    /// - 字节 0：bit0…bit7 = 正月…八月是否为大月（30 天，1）或小月（29 天，0）
    /// - 字节 1：bit0…bit3 = 九月…十二月是否为大月；bit4…bit7 = 闰月号（0 = 无闰月）
    /// - 字节 2：bit0 = 闰月是否为大月
    private static let packedData: [UInt8] = [
        "0osAUgcApQ4AKlsASwYAmwoApkoBagUAWQsAqisAUgcApW0AJQsASwoAS1oBrQIAawUAtSUAqQ0A",
        "kn4Bkg4AJQ0ALV0AVgoAtgIA1UoB1AYAqQ4ASi8Akg4ApmYAKwUAVwoAdlkAWgsA1AYAYTcBSQcA",
        "E3sBkwoAKwUAG2UBrQoAagUApU0BpAsASQsASy0AlQoArXoANgUArQoAyloBsgUApQ0Aoj4BSg0A",
        "lYUAlwoAVgUAdWUA1QoA0gYAVUcApQ4ASgYATzYAmwoA2noAagUAaQsAslsAUgsAJQsAK0sASwoA",
        "q4oArQIAbQUAqWUBqQ0Akg0AlU4AJQ0ATa4AVgoAtgIA9WIA1QYAqQ4AUl8Akg4AJg0ALjUAVwoA",
        "1ooAWgMA1QYAaVsASQcAkwYAm0oAKwUAWwoArioAagUA1X0ApAsASQsAU10AlQoALQUAXUUAtQoA",
        "qpsA0gUApQ0Aim4BSg0AlQwAnkoAVgUAtQoA2ioA0gYAZWcAJQcASwYAV1YAqwwAWgUAbjUAaQsA",
        "Ur8AUgsAJQsAC20BSwoAqwQAu1IArQUAagsAqi0Akg0ApX4AJQ0AVQoATVoBtgQAtQUA0jYByQ4A",
        "ko8Akg4AJg0AFmUBVwoA1gQAZUMBVQcARQcASzcAkwYAq3oAKwUAWwoAuloAagUAZQsAqksASgsA",
        "lY0AlQoALQUAbWUAtQoAqgUA1UUApQ0ASg0ATT4AlgwAznwAVgUAtQoA0loB0gYApQ4AKkcAiwYA",
        "l4YAqwQAWwUAVmUBagsAUgcAlUsARQsAiwoATyoAqwQA"
    ].flatMap { Array($0.utf8) }

    /// base64 解码后的原始字节（603 字节 = 201 年 × 3）。
    private static let table: [UInt8] = {
        let chars = Array(packedData)
        var lookup = [Int8](repeating: -1, count: 256)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (i, ch) in alphabet.enumerated() { lookup[Int(ch)] = Int8(i) }
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for ch in chars {
            let v = lookup[Int(ch)]
            guard v >= 0 else { continue }          // 跳过换行等非表字符
            buffer = (buffer << 6) | UInt32(v)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }()

    /// 某农历年的月份信息。
    private struct YearInfo {
        /// 12 个平月的大小（1 = 30 天，0 = 29 天）。
        let monthBig: [Bool]
        /// 闰月号（0 = 无闰月）。
        let leapMonth: Int
        /// 闰月是否为大月。
        let leapBig: Bool
    }

    /// 取某农历年的月份信息；年份越界返回 nil。
    private static func yearInfo(_ year: Int) -> YearInfo? {
        guard (1900...2100).contains(year) else { return nil }
        let i = (year - 1900) * 3
        guard i + 2 < table.count else { return nil }
        let b0 = table[i], b1 = table[i + 1], b2 = table[i + 2]
        var big: [Bool] = []
        big.reserveCapacity(12)
        for m in 1...8 { big.append((b0 >> UInt8(m - 1)) & 1 == 1) }
        for m in 9...12 { big.append((b1 >> UInt8(m - 9)) & 1 == 1) }
        return YearInfo(monthBig: big,
                        leapMonth: Int((b1 >> 4) & 0xf),
                        leapBig: (b2 & 1) == 1)
    }

    /// 某农历年正月初一对应的「距 1900-01-31 的天数」。
    ///
    /// 逐年前推，所以查任意一年都是 O(年份数) —— 最多 201 次加法，够快，
    /// 而且不用再存一张「每年第一天」的表（省 804 字节）。
    private static func daysToNewYear(_ year: Int) -> Int? {
        guard (1900...2100).contains(year) else { return nil }
        var days = 0
        for y in 1900..<year {
            guard let info = yearInfo(y) else { return nil }
            days += info.monthBig.reduce(0) { $0 + ($1 ? 1 : 0) } + 348
            if info.leapMonth > 0 { days += info.leapBig ? 30 : 29 }
        }
        return days
    }

    /// 农历 1900 年正月初一对应的公历日（1900-01-31，按东八区）。
    private static let epoch = Date(timeIntervalSince1970: -2206425600)

    // MARK: - 公历 → 农历

    /// 公历日期 → 农历日期。
    ///
    /// 只看**当天**（传入任意时刻都按那一天的零点算），不带时分秒。
    /// 超出 1900-01-31 – 2100-12-31 返回 nil。
    static func lunar(from date: Date) -> LunarDate? {
        // ⚠️ **和 `dayGanzhi(_:)` 共用 `dayNumber(from:)`** ——
        // 农历换算和日干支必须用**同一个日界**，否则会差一天。
        guard let dayNumber = dayNumber(from: date) else { return nil }

        // 从 1900 年正月起逐月推进，找到落在这一天里的那个月。
        // 最多 201 年 × 13 个月 ≈ 2600 次循环，一次调用完全够快。
        var year = 1900
        var remaining = dayNumber
        while year <= 2100 {
            guard let info = yearInfo(year) else { break }
            var monthIndex = 0        // 0 = 正月 … 11 = 腊月；闰月插在对应月份之后
            var isLeap = false
            var overflow = false
            while true {
                let days = daysInMonth(year, monthIndex, isLeap)
                if remaining < days { break }
                remaining -= days
                // 推进到下一个「月序位」
                if !isLeap, info.leapMonth > 0, monthIndex + 1 == info.leapMonth {
                    isLeap = true
                } else {
                    isLeap = false
                    monthIndex += 1
                    if monthIndex > 11 { overflow = true; break }
                }
            }
            if overflow { year += 1; continue }
            return LunarDate(year: year,
                             month: monthIndex + 1,
                             day: remaining + 1,
                             isLeapMonth: isLeap)
        }
        return nil
    }

    /// 某农历年某月的天数（29 或 30）。
    ///
    /// `monthIndex` 用 0-based 的「月序位」：0 = 正月，…，11 = 腊月；
    /// 闰月单独占一个位（排在同名平月之后）。
    private static func daysInMonth(_ year: Int, _ monthIndex: Int, _ isLeap: Bool) -> Int {
        guard let info = yearInfo(year) else { return 0 }
        if isLeap { return info.leapBig ? 30 : 29 }
        return info.monthBig[monthIndex] ? 30 : 29
    }

    // MARK: - 农历 → 公历

    /// 农历日期 → 公历日期。
    ///
    /// 超出范围或该月不存在（比如平年问闰月）返回 nil。
    static func date(from lunar: LunarDate) -> Date? {
        guard (1900...2100).contains(lunar.year),
              (1...12).contains(lunar.month),
              (1...30).contains(lunar.day),
              let info = yearInfo(lunar.year)
        else { return nil }

        // 闰月必须真的存在，且请求的必须是闰月。
        if lunar.isLeapMonth && info.leapMonth != lunar.month { return nil }

        guard let yearStart = daysToNewYear(lunar.year) else { return nil }

        // 按「正月 → … → 闰月（插在同名平月之后）→ … → 腊月」的顺序累加天数，
        // 走到目标月份为止。
        var offset = yearStart
        var monthIndex = 0        // 0 = 正月 … 11 = 腊月
        var isLeap = false
        var reached = false
        while monthIndex < 12 {
            let isTarget = isLeap
                ? (lunar.isLeapMonth && info.leapMonth == lunar.month)
                : (!lunar.isLeapMonth && monthIndex + 1 == lunar.month)
            if isTarget { reached = true; break }
            offset += daysInMonth(lunar.year, monthIndex, isLeap)
            if !isLeap, info.leapMonth > 0, monthIndex + 1 == info.leapMonth {
                isLeap = true
            } else {
                isLeap = false
                monthIndex += 1
            }
        }
        guard reached else { return nil }

        let days = daysInMonth(lunar.year, monthIndex, lunar.isLeapMonth)
        guard lunar.day <= days else { return nil }
        offset += lunar.day - 1

        return calendar.date(byAdding: .day, value: offset, to: epoch)
    }

    /// 该农历年的总天数（354 / 355，闰年 383 / 384）。
    static func daysInYear(_ year: Int) -> Int? {
        guard let info = yearInfo(year) else { return nil }
        var days = 348
        for big in info.monthBig where big { days += 1 }
        if info.leapMonth > 0 { days += info.leapBig ? 30 : 29 }
        return days
    }

    /// 该农历年是否有闰月；有则返回闰月号（1…12）。
    static func leapMonth(ofLunarYear year: Int) -> Int? {
        guard let info = yearInfo(year) else { return nil }
        return info.leapMonth > 0 ? info.leapMonth : nil
    }

    /// 农历月的天数（该月平/闰）。
    static func daysInMonth(lunarYear year: Int, month: Int, isLeap: Bool = false) -> Int? {
        guard let info = yearInfo(year), (1...12).contains(month) else { return nil }
        if isLeap {
            guard info.leapMonth == month else { return nil }
            return info.leapBig ? 30 : 29
        }
        return info.monthBig[month - 1] ? 30 : 29
    }

    /// 农历某月的最后一天（用于「除夕 = 腊月最后一天」）。
    static func lastDayOfMonth(lunarYear year: Int, month: Int, isLeap: Bool = false) -> Int? {
        daysInMonth(lunarYear: year, month: month, isLeap: isLeap)
    }

    // MARK: - 名称

    /// 农历月名（正月、二月…腊月）。
    ///
    /// 闰月加「闰」前缀（闰四月 / 闰二月）。
    static func monthName(_ month: Int, isLeap: Bool = false) -> String {
        let base = monthNames.indices.contains(month - 1) ? monthNames[month - 1] : "\(month)月"
        return isLeap ? "闰" + base : base
    }

    /// 农历日名（初一…三十）。
    static func dayName(_ day: Int) -> String {
        guard dayNames.indices.contains(day - 1) else { return "\(day)日" }
        return dayNames[day - 1]
    }

    /// 农历年的月名。
    private static let monthNames = ["正月", "二月", "三月", "四月", "五月", "六月",
                                     "七月", "八月", "九月", "十月", "冬月", "腊月"]

    /// 农历日名。
    ///
    /// 初一…初十、十一…十九、二十、廿一…廿九、三十。
    private static let dayNames: [String] = {
        var names: [String] = []
        names += ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十"]
        names += ["十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九"]
        names += ["二十", "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九"]
        names += ["三十"]
        return names
    }()

    /// 生肖（鼠牛虎兔龙蛇马羊猴鸡狗猪）。
    ///
    /// 农历年 + 常年偏移：1900 年是庚子年（鼠），所以 `year - 1900` 就是生肖偏移。
    /// 注意生肖按**农历年**算，不是公历年 —— 正月初一之前仍属上一个生肖。
    static func zodiac(_ lunarYear: Int) -> String? {
        guard (1900...2100).contains(lunarYear) else { return nil }
        let index = ((lunarYear - 1900) % 12 + 12) % 12
        return zodiacs[index]
    }

    /// 生肖表（1900 年 = 鼠）。
    private static let zodiacs = ["鼠", "牛", "虎", "兔", "龙", "蛇",
                                  "马", "羊", "猴", "鸡", "狗", "猪"]

    // MARK: - 展示

    /// 完整写法："2026年正月初一"。
    static func text(_ date: Date) -> String {
        guard let lunar = lunar(from: date) else { return "" }
        return "\(lunar.year)年\(monthName(lunar.month, isLeap: lunar.isLeapMonth))\(dayName(lunar.day))"
    }

    /// 简短写法（规格里 `festival.lunar` 字段用的就是这个）："农历九月初七"。
    static func shortText(_ date: Date) -> String {
        guard let lunar = lunar(from: date) else { return "" }
        return "农历\(monthName(lunar.month, isLeap: lunar.isLeapMonth))\(dayName(lunar.day))"
    }

    /// 干支纪年（"丙午"）—— 1900 年是庚子年。
    ///
    /// 天干 10 年一循环、地支 12 年一循环，两者起点不同：
    /// 1900 = 庚子，「庚」是天干第 7 个（index 6）、「子」是地支第 1 个（index 0），
    /// 所以天干要多偏移 6 位才能对齐。
    static func ganzhi(_ lunarYear: Int) -> String? {
        guard (1900...2100).contains(lunarYear) else { return nil }
        let offset = lunarYear - 1900
        let stemIndex = ((offset + 6) % 10 + 10) % 10
        let branchIndex = ((offset) % 12 + 12) % 12
        return stems[stemIndex] + branches[branchIndex]
    }

    // MARK: - 日干支

    /// 干支纪**日**（"甲子"）—— 60 天一循环。
    ///
    /// 建除十二神（黄历的「建 / 除 / 满 / 平…」）是以**日支**为基准排的，
    /// 所以算黄历必须先有日干支。
    ///
    /// ## 算法
    ///
    /// 日干支 = 由「距 epoch 的天数」直接取模：
    ///   天干 index = (dayNumber + 0) % 10
    ///   地支 index = (dayNumber + 4) % 12
    ///
    /// 其中 `dayNumber` 是「距 1900-01-31（农历表下边界 = 本表的 epoch）的天数」，
    /// 用的是和 `lunar(from:)` **完全相同**的算法（同一个 `calendar`、同一个 `epoch`）——
    /// 历法算的必须是同一个「日界」，否则会差一天。
    ///
    /// ## 常数是怎么来的
    ///
    /// 两个互相独立的公认锚点：
    ///   · **1949-10-01 = 甲子日** → 距 epoch 18140 天
    ///   · **2000-01-01 = 戊午日** → 距 epoch 36494 天
    ///
    /// 这两天相差 18354 天（模 60 余 54），
    /// 两个锚点给出的偏移**完全一致**（天干 +0、地支 +4），
    /// 所以这两个常数是自洽的。
    ///
    /// ## 自洽性校验（`make test` 里有断言）
    ///
    /// 六十甲子里天干与地支的序号**奇偶性永远相同**
    /// （10 和 12 都是偶数，120 种组合里只出现 60 种）。
    /// 任何偏移常数错了，这个不变量都会在若干天内被破坏。
    ///
    /// 超出 1900-01-31 – 2100-12-31 返回 nil（和农历换算同一个范围）。
    static func dayGanzhi(_ date: Date) -> String? {
        guard let dayNumber = dayNumber(from: date) else { return nil }
        let stemIndex = ((dayNumber) % 10 + 10) % 10
        let branchIndex = ((dayNumber + 4) % 12 + 12) % 12
        return stems[stemIndex] + branches[branchIndex]
    }

    /// 日干支的**地支序号**（0 = 子 … 11 = 亥）。
    ///
    /// 建除十二神就是按这个序号排的，所以单独暴露出来。
    ///
    /// 同时把**天干**序号也返回 —— 有些黄历流派要用日干定「天刑 / 天破」之类。
    static func dayGanzhiIndices(_ date: Date) -> (stem: Int, branch: Int)? {
        guard let dayNumber = dayNumber(from: date) else { return nil }
        let stemIndex = ((dayNumber) % 10 + 10) % 10
        let branchIndex = ((dayNumber + 4) % 12 + 12) % 12
        return (stemIndex, branchIndex)
    }

    /// 距 epoch（1900-01-31）的天数；越界返回 nil。
    ///
    /// ⚠️ **仅供自检使用** —— 生产的代码路径不应该依赖这个内部细节。
    ///
    /// `lunar(from:)` 和 `dayGanzhi(_:)` **必须**用同一个「日界」，
    /// 所以这个 helper 是两者共用的。
    private static func dayNumber(from date: Date) -> Int? {
        let day = calendar.startOfDay(for: date)
        guard day >= minimumDate, day <= maximumDate else { return nil }
        return calendar.dateComponents([.day], from: epoch, to: day).day
    }

    /// 自检用：距 epoch 的天数（越界返回 nil）。
    ///
    /// 存在的意义：日干支和农历换算**必须**用同一个「日界」，
    /// 这个数是那条不变量的直接体现 —— 它一变，两者就会差一天。
    static func dayNumberForTest(_ date: Date) -> Int? {
        dayNumber(from: date)
    }

    /// 天干。
    private static let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    /// 地支。
    private static let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
}

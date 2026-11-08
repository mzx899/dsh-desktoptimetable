import Foundation

/// 学期配置（semester.json）。
///
/// 格式：`{"start":"2026-08-31","maxWeek":16}`
///   · `start`    开学日期（ISO8601 日期）
///   · `maxWeek`  学期总周数，缺省 16，合法范围 1...30
struct SemesterConfig: Codable, Equatable {
    var start: Date
    var maxWeek: Int

    /// 学期总周数的缺省值。
    static let defaultMaxWeek = 16
    /// 学期总周数的合法范围。
    static let minMaxWeek = 1
    static let maxMaxWeek = 30

    init(start: Date, maxWeek: Int = SemesterConfig.defaultMaxWeek) {
        self.start = start
        self.maxWeek = SemesterConfig.clampMaxWeek(maxWeek)
    }

    /// 把越界的周数夹回合法范围。
    static func clampMaxWeek(_ n: Int) -> Int {
        min(max(n, minMaxWeek), maxMaxWeek)
    }

    /// 编码成 semester.json 的字典。
    func jsonObject() -> [String: Any] {
        ["start": ISO8601DateFormatter.dayOnly.string(from: start),
         "maxWeek": maxWeek]
    }

    /// 从 semester.json 的字典解析；`maxWeek` 缺失或非法时退回缺省值。
    static func from(json obj: [String: Any], defaultStart: Date) -> SemesterConfig {
        var start = defaultStart
        if let s = obj["start"] as? String,
           let d = ISO8601DateFormatter.dayOnly.date(from: s) {
            start = d
        }
        var maxWeek = defaultMaxWeek
        if let n = obj["maxWeek"] as? Int {
            maxWeek = clampMaxWeek(n)
        } else if let d = obj["maxWeek"] as? NSNumber {
            maxWeek = clampMaxWeek(d.intValue)
        }
        return SemesterConfig(start: start, maxWeek: maxWeek)
    }

    /// 课程数据里出现的最大周次。
    static func maxWeekInCourses(_ courses: [Course]) -> Int {
        courses.flatMap { $0.weeks }.max() ?? 0
    }

    /// 生效的学期总周数 = max(配置值, 数据里的最大周次)。
    ///
    /// 数据超出配置时**不静默隐藏**：调用方要给出「有课程超出学期周数」的提示。
    func effectiveMaxWeek(for courses: [Course]) -> Int {
        max(maxWeek, SemesterConfig.maxWeekInCourses(courses))
    }

    /// 超出学期总周数的课程（调低周数时先列出来给用户确认）。
    func coursesExceedingMaxWeek(_ courses: [Course]) -> [Course] {
        courses.filter { c in c.weeks.contains { $0 > maxWeek } }
    }
}

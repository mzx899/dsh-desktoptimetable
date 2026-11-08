import Foundation

/// 一条「单周临时覆盖」。
///
/// 覆盖 = 某个格子在**某几周**里归一门课，但：
///   · **原课程绝对不变** —— 它的记录、courseID、周次一个字都不动；
///   · 覆盖记录**独立存放**（`week_overrides.json`），**不混进 `courses`**；
///   · 「全部周次」视图**忽略**覆盖记录 —— 那里只显示原始课表。
///
/// 键：**(覆盖的周次集合, day, block)**。一次覆盖横跨多周时周次写在 `weeks` 里，
/// 而不是拆成多条 —— 拆开就会出现「同一格每周一条」的重复记录，
/// 撤销时也不知道该删哪几条。同一格**最多一条**覆盖记录，
/// 所以「每格每周最多一条」这个不变量由数据结构本身保证。
struct WeekOverride: Codable, Equatable {

    /// 星期几（1...7）。
    var day: Int = 1
    /// 第几节（`Course.blockRange`）。
    var block: Int = 0

    /// 这次覆盖覆盖的**周次集合**（编辑器里选的那些）。
    var weeks: [Int] = []

    /// 覆盖课本身的字段。
    var name: String = ""
    var teacher: String = ""
    var loc: String = ""
    var code: String = ""
    /// 覆盖课的颜色（`#rrggbb`）；`nil` = 自动（按课名）。
    ///
    /// 和课名 / 代码一样是课程级字段：写覆盖时跟课程一起带进来，
    /// 撤销覆盖 / 换新覆盖时要跟着原课一起还原，不能丢。
    var colorHex: String? = nil
    /// 覆盖课的身份：新增的课是新 UUID；改已有课时沿用原 courseID。
    var courseID: String = ""

    /// 从 `courses` 里移出来的那条原记录 —— **撤销覆盖时放回去**。
    /// nil = 这门课是新增的（撤销覆盖 = 彻底删掉它）。
    var restored: RestoredSession?

    /// 被移出来的上课时间记录（只存覆盖前的样子）。
    struct RestoredSession: Codable, Equatable {
        var name: String = ""
        var teacher: String = ""
        var loc: String = ""
        var code: String = ""
        /// 原课的颜色（`#rrggbb`）；`nil` = 自动。撤销覆盖要一起还原。
        var colorHex: String? = nil
        var courseID: String = ""
        var day: Int = 1
        var block: Int = 0
        var weeks: [Int] = []

        init(_ course: Course) {
            name = course.name
            teacher = course.teacher
            loc = course.loc
            code = course.code
            colorHex = course.colorHex
            courseID = course.courseID
            day = course.day
            block = course.block
            weeks = course.weeks
        }

        /// 还原成一条课程记录。
        func asCourse() -> Course {
            Course(day: day, block: block, name: name, teacher: teacher,
                   loc: loc, code: code, courseID: courseID, weeks: weeks,
                   colorHex: colorHex)
        }
    }

    /// 覆盖记录 → 课程形状（渲染、统计都用它）。
    func asCourse() -> Course {
        Course(day: day, block: block, name: name, teacher: teacher,
               loc: loc, code: code, courseID: courseID, weeks: weeks,
               colorHex: colorHex)
    }

    /// 这一条覆盖在第 `week` 周是否生效。
    func applies(to week: Int) -> Bool {
        weeks.contains(week)
    }

    // MARK: 构造

    init(day: Int, block: Int, weeks: [Int], name: String, teacher: String,
         loc: String, code: String, courseID: String,
         restored: RestoredSession?,
         colorHex: String? = nil) {
        self.day = day
        self.block = block
        self.weeks = weeks.sorted()
        self.name = name
        self.teacher = teacher
        self.loc = loc
        self.code = code
        self.courseID = courseID
        self.restored = restored
        self.colorHex = ColorHex.normalized(colorHex)
    }

    // MARK: 解码

    enum CodingKeys: String, CodingKey {
        case day, block, weeks, name, teacher, loc, code, colorHex, courseID, restored
    }

    /// 缺字段就取默认值 —— 覆盖文件里坏了一条，不该让整个文件读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decodeIfPresent(Int.self, forKey: .day) ?? 1
        block = try c.decodeIfPresent(Int.self, forKey: .block) ?? 0
        weeks = try c.decodeIfPresent([Int].self, forKey: .weeks) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        teacher = try c.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        loc = try c.decodeIfPresent(String.self, forKey: .loc) ?? ""
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        // 颜色（后加的字段）：缺失 = 自动，非法值也当自动。
        colorHex = ColorHex.normalized((try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? nil)
        courseID = try c.decodeIfPresent(String.self, forKey: .courseID) ?? ""
        restored = try c.decodeIfPresent(RestoredSession.self, forKey: .restored)
    }
}

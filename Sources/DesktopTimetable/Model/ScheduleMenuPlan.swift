import Foundation

// MARK: - 菜单动作

/// 右键菜单里的动作（纯数据，便于单元测试）。
enum ScheduleMenuAction: Equatable {
    /// 新增课程（指定格子）。
    case addCourse(day: Int, block: Int)
    /// 查看**某一次上课**的详情。
    ///
    /// 必须带 day/block：一门课可以有多次上课，只给 courseID 分不清是哪一次。
    case viewSession(courseID: String, day: Int, block: Int)
    /// 编辑**某一次上课**（课程级字段仍同步到同 courseID 的所有记录）。
    ///
    /// 必须带 day/block —— 同上，而且这正是之前「编辑自己刚加的那次上课，
    /// 却打开了同一门课另一个上课时间」的根因。
    case editSession(courseID: String, day: Int, block: Int)
    /// 添加一个上课时间（复用 courseID）。
    case addSession(courseID: String)
    /// 删除这一次上课（只删当前记录）。
    case deleteSession(courseID: String)
    /// 删除整门课程（删该 courseID 的所有记录）。
    case deleteCourse(courseID: String)
    /// 删除**单周临时覆盖**（指定格子）。
    ///
    /// 删掉之后该格恢复成原来的课；原课本来就是新增的（没有可恢复的原记录）
    /// 就是这门课彻底消失。
    case deleteOverride(day: Int, block: Int)
    /// 编辑**单周临时覆盖**（指定格子）。
    case editOverride(day: Int, block: Int)
    /// 查看**临时覆盖**的详情。
    case viewOverride(day: Int, block: Int)
    /// 打开设置面板（学期设置）。
    case openSettings
    /// 导入课表。
    case importSchedule
}

// MARK: - 菜单项

/// 一条菜单项（可能带子菜单）。
struct ScheduleMenuItem: Equatable {
    var title: String
    var action: ScheduleMenuAction
    /// 子菜单（空 = 普通项）。
    var submenu: [ScheduleMenuItem] = []
    /// 分隔线。
    var isSeparator: Bool = false

    static func separator() -> ScheduleMenuItem {
        ScheduleMenuItem(title: "", action: .openSettings, isSeparator: true)
    }
}

// MARK: - 菜单计划

/// 按格子构造右键菜单的内容。
///
/// 纯函数，不碰 UI，方便单元测试。
enum ScheduleMenuBuilder {

    /// 一个格子（day 1...7，block 0...4）里的课程。
    struct Slot {
        var day: Int
        var block: Int
        /// 该格里的所有课程（可能多门 —— 冲突）。
        var courses: [Course]
        /// 右键命中的那一门课（网页传回来的 courseID；原生命中时按位置推断）。
        var hitCourseID: String?
        /// 该格在**当前浏览的周**的临时覆盖记录（全部周次视图里永远是 nil）。
        var override: WeekOverride? = nil
    }

    /// 构造菜单。
    ///
    /// - 空白格：新增课程…、学期设置…、导入课表…
    /// - 课程格：查看详情、编辑课程…、添加一个上课时间…、删除这一次上课、删除整门课程…
    /// - 冲突格（同一格多门课）：先列出每门课的子菜单，再提供编辑/删除
    static func build(for slot: Slot) -> [ScheduleMenuItem] {
        // 被覆盖的格子：这一周显示的是**覆盖课**，菜单针对覆盖课。
        // （这一格在「全部周次」视图里没有覆盖 —— `Slot.override` 只在单周视图有值。）
        if let ov = slot.override {
            return [
                ScheduleMenuItem(title: "查看详情", action: .viewOverride(day: ov.day, block: ov.block)),
                ScheduleMenuItem(title: "编辑课程…", action: .editOverride(day: ov.day, block: ov.block)),
                ScheduleMenuItem.separator(),
                ScheduleMenuItem(title: "删除临时覆盖", action: .deleteOverride(day: ov.day, block: ov.block)),
                ScheduleMenuItem.separator(),
                ScheduleMenuItem(title: "学期设置…", action: .openSettings),
                ScheduleMenuItem(title: "导入课表…", action: .importSchedule),
            ]
        }

        if slot.courses.isEmpty {
            return [
                ScheduleMenuItem(title: "新增课程…", action: .addCourse(day: slot.day, block: slot.block)),
                ScheduleMenuItem.separator(),
                ScheduleMenuItem(title: "学期设置…", action: .openSettings),
                ScheduleMenuItem(title: "导入课表…", action: .importSchedule),
            ]
        }

        if slot.courses.count == 1, let c = slot.courses.first {
            return singleCourseMenu(c)
        }

        // 冲突格：每门课一个子菜单
        var items: [ScheduleMenuItem] = []
        for c in slot.courses {
            items.append(ScheduleMenuItem(title: c.name,
                                          action: .viewSession(courseID: c.courseID,
                                                               day: c.day, block: c.block),
                                          submenu: singleCourseMenu(c)))
        }
        items.append(ScheduleMenuItem.separator())

        // 顶层再提供编辑/删除（作用在主命中的那门课，没有就取第一门）
        let primary = slot.hitCourseID.flatMap { id in slot.courses.first { $0.courseID == id } }
            ?? slot.courses.first
        if let p = primary {
            items.append(ScheduleMenuItem(title: "编辑课程…",
                                          action: .editSession(courseID: p.courseID,
                                                               day: p.day, block: p.block)))
            items.append(ScheduleMenuItem(title: "删除整门课程…", action: .deleteCourse(courseID: p.courseID)))
        }
        items.append(ScheduleMenuItem.separator())
        items.append(ScheduleMenuItem(title: "新增课程…", action: .addCourse(day: slot.day, block: slot.block)))
        items.append(ScheduleMenuItem(title: "学期设置…", action: .openSettings))
        items.append(ScheduleMenuItem(title: "导入课表…", action: .importSchedule))
        return items
    }

    /// 单门课的菜单内容（冲突格里作为子菜单复用）。
    ///
    /// 动作里带的是**这条记录自己的** day/block —— 一门课的多次上课
    /// 各自的位置不一样，必须按「课次」定位，不能只靠 courseID。
    private static func singleCourseMenu(_ c: Course) -> [ScheduleMenuItem] {
        [
            ScheduleMenuItem(title: "查看详情",
                             action: .viewSession(courseID: c.courseID, day: c.day, block: c.block)),
            ScheduleMenuItem(title: "编辑课程…",
                             action: .editSession(courseID: c.courseID, day: c.day, block: c.block)),
            ScheduleMenuItem(title: "添加一个上课时间…", action: .addSession(courseID: c.courseID)),
            ScheduleMenuItem.separator(),
            ScheduleMenuItem(title: "删除这一次上课", action: .deleteSession(courseID: c.courseID)),
            ScheduleMenuItem(title: "删除整门课程…", action: .deleteCourse(courseID: c.courseID)),
        ]
    }

    /// 取出某个动作对应的课程（用于上层查课程详情）。
    static func course(for action: ScheduleMenuAction, in slot: Slot) -> Course? {
        switch action {
        case .viewSession(let id, let day, let block),
             .editSession(let id, let day, let block):
            // 按课次定位（courseID + day + block）
            return slot.courses.first { $0.courseID == id && $0.day == day && $0.block == block }
                ?? slot.courses.first { $0.courseID == id }
        case .addSession(let id), .deleteSession(let id), .deleteCourse(let id):
            return slot.courses.first { $0.courseID == id }
        case .viewOverride:
            // 覆盖课不在 courses 里 → 用覆盖记录本身还原一份
            return slot.override?.asCourse()
        case .editOverride, .deleteOverride:
            return nil
        case .addCourse, .openSettings, .importSchedule:
            return nil
        }
    }
}

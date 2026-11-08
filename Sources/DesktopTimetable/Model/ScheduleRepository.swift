import Foundation

/// 课表仓库：**唯一的**迁移入口与写盘入口。
///
/// AppDelegate 和设置面板都只通过这里读写课表，避免各自生成一套 courseID。
///
/// 职责：
///   · 加载时按需迁移（旧数据 → courseID）、补齐缺失周次；
///   · 写盘前自动备份到 `backups/`（保留最近 5 份）；
///   · 统一维护学期配置（开学日期 + 学期总周数）。
final class ScheduleRepository {

    /// 加载结果 + 需要给用户看的提示。
    struct LoadResult {
        var courses: [Course] = []
        var semester = SemesterConfig(start: Date(), maxWeek: SemesterConfig.defaultMaxWeek)
        /// 「周次缺失，已按全学期处理」之类的提示。
        var notices: [String] = []
        /// 数据异常（同名不同 code 之类）。
        var anomalies: [String] = []
        /// 加载失败时的错误（数据非法时不会静默变成空课表）。
        var error: String?
        /// 单周临时覆盖记录（独立文件，坏了一条只少一条覆盖）。
        var overrides: [WeekOverride] = []
    }

    let store: ScheduleStore

    init(store: ScheduleStore = ScheduleStore()) {
        self.store = store
    }

    // MARK: - 加载

    /// 加载课表 + 学期配置。必要时做一次迁移（幂等）。
    func load() -> LoadResult {
        var result = LoadResult()

        // ---- 学期：损坏就只报，不覆盖 ----
        if store.semesterConfigIsCorrupt {
            result.error = "学期配置文件已损坏，已临时按默认学期显示（原文件不会被覆盖）"
        }
        result.semester = store.loadSemesterConfig()

        // ---- 课程：能读多少读多少，读不了的记下来 ----
        var courses: [Course]
        var hadFailures = false
        do {
            courses = try store.loadCourses()
        } catch {
            result.error = error.localizedDescription
            // 数据非法时仍把能读的部分显示出来，但明确给出错误。
            // 以前这里是 `store.loadCoursesOrNil() ?? []` —— 那是「全有或全无」，
            // 一条记录坏掉整个文件就读不出来，于是课表被当成**空课表**，
            // 导入决策会直接覆盖它。注释写的「把能读的部分显示出来」其实做不到。
            let partial = store.loadCoursesPartial()
            courses = partial.courses
            if !partial.failures.isEmpty {
                hadFailures = true
                result.error = "有 \(partial.failures.count) 条课程记录无法读取，已跳过其余内容："
                    + partial.failures.prefix(3).joined(separator: "；")
                    + (partial.failures.count > 3 ? " …等 \(partial.failures.count) 条" : "")
            }
        }

        // ---- 迁移：分配 courseID（幂等，已有 ID 原样保留）----
        let before = courses
        let assigned = CourseGrouper.assignCourseIDs(courses)
        courses = assigned.courses
        result.anomalies = assigned.anomalies

        // ---- weeks 为空 → 扩成 1...effectiveMaxWeek ----
        let effective = result.semester.effectiveMaxWeek(for: courses)
        var expandedNames: Set<String> = []
        for i in courses.indices where courses[i].weeks.isEmpty {
            courses[i].weeks = Array(1...effective)
            expandedNames.insert(courses[i].name)
        }
        if !expandedNames.isEmpty {
            result.notices.append(
                "周次缺失，已按全学期处理：\(expandedNames.sorted().joined(separator: "、"))")
        }

        // weeksLabel 一律由 weeks 重新生成
        for i in courses.indices { courses[i].refreshWeeksLabel() }

        result.courses = courses

        // ---- 临时覆盖：读不出来只影响覆盖本身，原课表照常 ----
        //
        // 覆盖是独立文件（`week_overrides.json`），它坏了**不会**让课表变成空课表，
        // 也不会把课程数据一起写回 —— 这里只读、只提示。
        let partialOverrides = store.loadOverridesPartial()
        result.overrides = partialOverrides.overrides
        if !partialOverrides.failures.isEmpty, result.error == nil {
            result.error = "有 \(partialOverrides.failures.count) 条临时覆盖记录无法读取，已跳过："
                + partialOverrides.failures.prefix(3).joined(separator: "；")
                + (partialOverrides.failures.count > 3 ? " …等 \(partialOverrides.failures.count) 条" : "")
        }

        // ---- 需要落盘（迁移改变了数据）→ 备份后写回 ----
        //
        // 但**有记录读不出来的时候不写回**：
        // 部分读取拿到的课程比文件里少，写回就等于把读不了的那几条**静默删掉**。
        // 这时只提示，不动文件（用户可以自己看备份或修文件）。
        if courses != before && !hadFailures {
            store.backupCourses()
            try? store.saveCourses(courses)
        }

        // ---- 旧学期文件没有 maxWeek 字段 → 补写一次（让格式显式）----
        // 学期文件损坏时**不补写**：否则会用默认值把用户的原始配置盖掉。
        if !store.semesterHasMaxWeek() && !store.semesterConfigIsCorrupt {
            store.backupSemester()
            try? store.saveSemesterConfig(result.semester)
        }
        return result
    }

    // MARK: - 保存

    /// 写盘（自动备份旧数据）。
    func save(_ courses: [Course]) throws {
        var list = courses
        for i in list.indices { list[i].refreshWeeksLabel() }
        store.backupCourses()
        try store.saveCourses(list)
    }

    /// 写覆盖记录（自动备份旧文件）。
    ///
    /// 覆盖与课程**分别写盘** —— 课程文件坏了不影响覆盖，反过来也一样。
    func saveOverrides(_ overrides: [WeekOverride]) throws {
        store.backupOverrides()
        try store.saveOverrides(overrides)
    }

    /// 学期配置。
    var semester: SemesterConfig { store.loadSemesterConfig() }

    /// 写学期配置（自动备份旧文件）。
    ///
    /// 以前这里只有一句 `try store.saveSemesterConfig(config)` —— **不备份**。
    /// 结果是：学期配置被覆盖之后，旧的那份没了；而 `save(_ courses:)` 是会备份的，
    /// 两边不对称，出了事只能靠运气。
    func saveSemester(_ config: SemesterConfig) throws {
        store.backupSemester()
        try store.saveSemesterConfig(config)
    }
}

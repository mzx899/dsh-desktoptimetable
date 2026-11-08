import Foundation

/// 「覆盖导入」的冲突检测 + 合并计划（纯函数，可单测）。
///
/// 背景（这一层为什么存在）：
///   · 覆盖导入以前只弹一个全局警告「合并后有时间冲突 / 仍然保存」，
///     没有逐条冲突，也不区分「导入的课」和「用户新增 / 改过的课」；
///   · `TimetableDiff.merge` 只按课程级选择合并，冲突只能整门留或整门丢；
///   · 后果是「用户自己加的课被导入的课悄悄顶掉」这类静默覆盖。
///
/// 现在把「哪些时段真冲突」「冲突怎么解析」「合并后还丢没丢保护课」全部抽到这里，
/// 差异页只负责显示和把用户的选择写进 `MergeChoice`。
enum ImportConflictLogic {

    // MARK: - 冲突单元

    /// 一条「导入的上课时间 vs 当前的上课时间」重叠。
    ///
    /// 周次不重叠（单双周交替）不算冲突，所以这里存的是**真的重叠**的那部分周次。
    struct Slot: Equatable {
        var day: Int
        var block: Int
        var importedWeeks: [Int]
        var currentWeeks: [Int]
        var overlap: [Int]

        var timeText: String {
            let d = Schedule.dayNames[max(0, min(6, day - 1))]
            return "\(d) 第\(block * 2 + 1)-\(block * 2 + 2)节"
        }

        var weeksText: String {
            "导入 \(WeekSpec.format(Set(importedWeeks))) · 你的 \(WeekSpec.format(Set(currentWeeks)))"
                + " · 重叠 \(WeekSpec.format(Set(overlap)))"
        }
    }

    /// 一个冲突单元 = 一对课程（导入侧 courseID / 当前侧 courseID）+ 它们所有重叠的时段。
    ///
    /// **一次选择作用于整对课程**（同一天同一格的多条记录一起处理）。
    struct Unit: Equatable {
        /// 稳定 id：两个 courseID + 重叠时段的 day/block/weeks。每次重算 id 不变。
        var id: String
        /// 合并结果里这门导入课会用的 courseID（匹配上的课复用当前 ID）。
        var importedCourseID: String
        var importedName: String
        var currentCourseID: String
        var currentName: String
        /// 当前这门课的来源标签（「你新增」/「你修改过」/「导入」/「旧数据（来源未知）」）。
        var currentOriginLabel: String
        /// 当前这门课受不受保护（用户新增 / 改过 / 旧数据）。
        var currentProtected: Bool
        var slots: [Slot]

        /// 「周三 第3-4节；周五 第1-2节」
        var timeText: String { slots.map { $0.timeText }.joined(separator: "；") }
        /// 每个时段的周次说明（多行）。
        var weeksText: String { slots.map { $0.weeksText }.joined(separator: "\n") }
    }

    // MARK: - 计划

    /// 合并计划：最终课程 + 还有哪些事没决定。
    struct Plan {
        var courses: [Course] = []
        var semester: SemesterConfig = SemesterConfig(start: Date())
        /// 检测到的全部冲突单元。
        var conflicts: [Unit] = []
        /// 用户还没决定的冲突。
        var unresolved: [Unit] = []
        /// 硬阻塞原因（nil = 可以应用）。
        var blocker: String?
        /// 顶部摘要。
        var summary: String = ""

        /// 「应用」能不能点。
        var canApply: Bool { blocker == nil && unresolved.isEmpty }
    }

    // MARK: - 检测

    /// 「当前内容会不会留在合并结果里」——**和 `TimetableDiff.merge` 同一套语义**。
    ///
    /// 逐条对应 `merge` 的三个循环：
    ///   · matched：`.keepCurrent` 留当前；`.useImported` 用导入的（当前不留）；
    ///     `.skip` / `.delete` 两边都不留。
    ///   · ambiguous：`.keepCurrent` / `.skip` 留当前；`.useImported` 用导入的；
    ///     `.delete` 两边都不留（**这条以前算错，会产生幽灵冲突**）。
    ///   · removed：除了 `.delete` 都留当前。
    ///
    /// 单独抽出来是为了让 `detect` 和 `merge` 不可能各说各话 ——
    /// 以前 detect 用「≠ .useImported」自己推一遍，删掉的课还被当成保留着。
    static func retainedCurrentIDs(result: TimetableDiff.Result,
                                   choice: TimetableDiff.MergeChoice) -> Set<String> {
        var keeps = Set<String>()

        for d in result.matched {
            if choice.choice(for: d.courseID) == .keepCurrent {
                keeps.insert(d.courseID)
            }
        }
        for d in result.ambiguous {
            let c = choice.choice(for: d.courseID)
            if c == .keepCurrent || c == .skip {
                keeps.insert(d.courseID)
            }
        }
        for d in result.removed where choice.choice(for: d.courseID) != .delete {
            keeps.insert(d.courseID)
        }
        // 注意：不在任何差异列表里的当前课**不算保留** —— `merge` 同样不会把它
        // 放进结果（merge 只遍历 matched / ambiguous / removed / added）。
        // 以前 detect 在这里「按保留处理、宁可多报冲突」，那会和 merge 说法不一致，
        // 又造出一类幽灵冲突。这类课如果还是受保护的，`lostProtectedCourses`
        // 会把它们报出来要求用户明确选择，不会静默丢掉。
        return keeps
    }

    /// 找出「本次导入的课」和「当前会保留的课」之间的时间冲突。
    ///
    /// 只比较：
    ///   · 导入侧：课程级选择是 `useImported` 的那些课（保持当前的课不会进结果，谈不上冲突）；
    ///   · 当前侧：会以当前内容保留的记录（matched/ambiguous 保留当前、removed 没删）。
    ///
    /// **当前课表内部本来就存在的冲突不算**（那是旧问题，不该拦住这次导入）。
    static func detect(current: [Course],
                       result: TimetableDiff.Result,
                       choice: TimetableDiff.MergeChoice) -> [Unit] {

        // ---- 当前侧：哪些 courseID 会以当前内容保留 ----
        //
        // 判定必须和 `TimetableDiff.merge` **逐字对齐** —— 两者说的是同一件事：
        // 「这门课的当前内容，最后在不在合并结果里」。
        //
        // 以前这里是 `choice != .useImported` 一把梭，于是：
        //   · ambiguous 选「删除」→ merge 里明明没有它了，detect 还当它保留着
        //     → 报出一条**幽灵冲突**（课都删了还让你处理冲突）；
        //   · matched 选「删除」/「跳过」→ 同理。
        // 用户明明选了删除，却还要再处理一个不存在的冲突；更糟的是
        // 为了消掉它去选「保留当前」，反而把本来能导入的课删了。
        let keepsCurrent = retainedCurrentIDs(result: result, choice: choice)
        let retained = current.filter { keepsCurrent.contains($0.courseID) }

        // ---- 导入侧：合并后真正会进结果的记录 ----
        // 注意 courseID 要按 merge 的语义改写成 `d.courseID`（匹配上的课复用当前 ID）。
        var importedSide: [(courseID: String, name: String, session: Course)] = []
        for d in result.matched + result.ambiguous + result.added
            where choice.choice(for: d.courseID) == .useImported {
            for s in d.importedSessions {
                var r = s
                r.courseID = d.courseID
                importedSide.append((d.courseID, d.name.isEmpty ? s.name : d.name, r))
            }
        }

        // ---- 配对 ----
        var units: [String: Unit] = [:]
        var order: [String] = []
        for imp in importedSide {
            for cur in retained {
                // 同一门课的更新不算冲突（那是课程级差异）
                guard imp.session.courseID != cur.courseID else { continue }
                guard imp.session.day == cur.day, imp.session.block == cur.block else { continue }
                let overlap = Set(imp.session.weeks).intersection(cur.weeks)
                guard !overlap.isEmpty else { continue }

                let key = imp.courseID + ">" + cur.courseID
                if units[key] == nil {
                    units[key] = Unit(id: key,
                                      importedCourseID: imp.courseID,
                                      importedName: imp.name,
                                      currentCourseID: cur.courseID,
                                      currentName: cur.name,
                                      currentOriginLabel: cur.originLabel,
                                      currentProtected: cur.isProtected,
                                      slots: [])
                    order.append(key)
                }
                let slot = Slot(day: cur.day, block: cur.block,
                                importedWeeks: imp.session.weeks.sorted(),
                                currentWeeks: cur.weeks.sorted(),
                                overlap: overlap.sorted())
                if !(units[key]!.slots.contains(slot)) {
                    units[key]!.slots.append(slot)
                }
            }
        }

        // ---- 稳定 id + 稳定排序 ----
        var out: [Unit] = []
        for key in order {
            guard var u = units[key] else { continue }
            u.slots.sort { a, b in
                if a.day != b.day { return a.day < b.day }
                if a.block != b.block { return a.block < b.block }
                if a.importedWeeks != b.importedWeeks { return a.importedWeeks.lexicographicallyPrecedes(b.importedWeeks) }
                return a.currentWeeks.lexicographicallyPrecedes(b.currentWeeks)
            }
            u.id = key + "#" + u.slots.map { s in
                "\(s.day)-\(s.block)-\(s.importedWeeks.map(String.init).joined(separator: ","))"
                    + "/\(s.currentWeeks.map(String.init).joined(separator: ","))"
            }.joined(separator: ";")
            out.append(u)
        }
        // 行序不能跟着字典顺序跳（同一份数据每次打开同样的顺序）
        out.sort { a, b in
            let ad = a.slots.first.map { ($0.day, $0.block) } ?? (0, 0)
            let bd = b.slots.first.map { ($0.day, $0.block) } ?? (0, 0)
            if ad != bd { return ad < bd }
            if a.currentName != b.currentName { return a.currentName < b.currentName }
            if a.importedName != b.importedName { return a.importedName < b.importedName }
            return a.id < b.id
        }
        return out
    }

    // MARK: - 合并计划

    /// 按课程级选择 + 冲突解析算出最终结果。
    ///
    /// 顺序（和提示词里定的一致）：
    ///   1. 课程级 `TimetableDiff.merge` 得到基础结果；
    ///   2. 逐条冲突做 session 级增删；
    ///   3. 校验（字段合法）+ 防丢课 + 残留冲突检查；
    ///   4. 有任何阻塞就 `canApply == false`，差异页拿 `blocker` 显示原因。
    static func plan(current: [Course],
                     imported: [Course],
                     result: TimetableDiff.Result,
                     choice: TimetableDiff.MergeChoice) -> Plan {
        let base = TimetableDiff.merge(current: current, imported: imported,
                                       result: result, choice: choice)
        let units = detect(current: current, result: result, choice: choice)

        var courses = base.courses
        // 冲突解析：**按周次**扣，不是整条上课时间删掉。
        //
        // 「保留当前」→ 把**导入侧**那几周（重叠的那部分）扣掉；
        // 「用导入」  → 把**当前侧**那几周扣掉（用户这门课其他上课时间保留）。
        //
        // 只扣重叠的那几周，导入课里**没冲突**的周次（例：导入 1-16 周、
        // 重叠只有 1-8 周 → 9-16 周保留）不该跟着一起没。
        var trims: [WeekTrim] = []
        for u in units {
            switch choice.resolution(for: u.id) {
            case .keepCurrent?:
                for s in u.slots {
                    trims.append(WeekTrim(courseID: u.importedCourseID, day: s.day,
                                          block: s.block, weeks: Set(s.overlap)))
                }
            case .useImported?:
                for s in u.slots {
                    trims.append(WeekTrim(courseID: u.currentCourseID, day: s.day,
                                          block: s.block, weeks: Set(s.overlap)))
                }
            case .keepBoth?, nil:
                break
            }
        }
        courses = applyWeekTrims(courses, trims)

        var plan = Plan()
        plan.courses = courses
        plan.semester = base.semester
        plan.conflicts = units
        plan.unresolved = units.filter { choice.resolution(for: $0.id) == nil }
        plan.summary = summaryText(result: result, units: units,
                                  unresolved: plan.unresolved, choice: choice)

        // ---- 1. 未决定的冲突 ----
        if !plan.unresolved.isEmpty {
            plan.blocker = "还有 \(plan.unresolved.count) 处时间冲突没有决定 —— "
                + plan.unresolved.map { "\($0.importedName) ↔ \($0.currentName)" }
                    .joined(separator: "、")
        }

        // ---- 2. 防丢课：保护课程不许无缘无故消失 ----
        if plan.blocker == nil {
            let lost = lostProtectedCourses(current: current, result: result,
                                            choice: choice, units: units, courses: courses)
            if !lost.isEmpty {
                plan.blocker = "这些课会被导入删掉，但没有你的明确选择："
                    + lost.joined(separator: "、")
                    + "（请逐门选「保留当前」，或明确选「用导入 / 删除」）"
            }
        }

        // ---- 3. 字段校验 ----
        if plan.blocker == nil {
            let maxWeek = plan.semester.effectiveMaxWeek(for: courses)
            if let reason = TimetableDiff.validate(courses: courses, maxWeek: maxWeek) {
                plan.blocker = reason
            }
        }

        // ---- 4. 残留冲突（必须都是用户显式「两边都留」的）----
        if plan.blocker == nil {
            let residual = residualConflicts(courses: courses, current: current,
                                            units: units, choice: choice)
            if !residual.isEmpty {
                plan.blocker = "合并后还有时间冲突：" + residual.joined(separator: "；")
            }
        }

        return plan
    }

    // MARK: - 摘要

    /// 顶部摘要：「X 门将更新；Y 门将新增；Z 门你新增/修改的课受影响；N 处冲突待决定」。
    static func summaryText(result: TimetableDiff.Result,
                            units: [Unit],
                            unresolved: [Unit],
                            choice: TimetableDiff.MergeChoice) -> String {
        var willUpdate = 0
        var willAdd = 0
        var affectedProtected = Set<String>()

        for d in result.matched + result.ambiguous {
            let c = choice.choice(for: d.courseID)
            if c == .useImported && !d.currentSessions.isEmpty { willUpdate += 1 }
            if d.currentSessions.contains(where: { $0.isProtected }) {
                affectedProtected.insert(d.courseID)
            }
        }
        for d in result.added where choice.choice(for: d.courseID) == .useImported {
            willAdd += 1
        }
        for d in result.removed where d.currentSessions.contains(where: { $0.isProtected }) {
            affectedProtected.insert(d.courseID)
        }
        for u in units where u.currentProtected {
            affectedProtected.insert(u.currentCourseID)
        }

        return "\(willUpdate) 门将更新；\(willAdd) 门将新增；"
            + "\(affectedProtected.count) 门你新增/修改的课受影响；"
            + "\(unresolved.count) 处冲突待决定"
    }

    // MARK: - 内部

    /// 一条「把某门课某节课的某几周扣掉」的指令。
    struct WeekTrim: Equatable {
        var courseID: String
        var day: Int
        var block: Int
        /// 要扣掉的周次（就是冲突真正重叠的那部分）。
        var weeks: Set<Int>
    }

    /// 按**周次**粒度扣掉冲突的那几周（而不是整条上课时间删掉）。
    ///
    /// 为什么要按周扣：
    ///   · 冲突的定义是「同一格 + 周次有交集」，界面上写的也是「重叠 1-8 周」；
    ///   · 如果按 session 整条删，导入课里**根本没冲突**的那几周（9-16 周）
    ///     也被一起删了 —— 用户看到「重叠 1-8」，结果丢了 1-16 周；
    ///   · 这套东西的底线是「宁可多问一句，也不能静默删掉用户的课」，
    ///     没冲突的周次就不该跟着一起没。
    ///
    /// 扣完一周都不剩 → 这条上课时间整条去掉（那门课可能就此消失，
    /// 由 `lostProtectedCourses` 那道安全网兜底）。
    private static func applyWeekTrims(_ courses: [Course], _ trims: [WeekTrim]) -> [Course] {
        guard !trims.isEmpty else { return courses }
        var out: [Course] = []
        out.reserveCapacity(courses.count)
        for var c in courses {
            var drop: Set<Int> = []
            for t in trims
            where t.courseID == c.courseID && t.day == c.day && t.block == c.block {
                // 只在真的重叠时才扣 —— 免得扣到同格的另一条无关记录
                if !Set(c.weeks).isDisjoint(with: t.weeks) {
                    drop.formUnion(t.weeks)
                }
            }
            if drop.isEmpty {
                out.append(c)
                continue
            }
            let kept = c.weeks.filter { !drop.contains($0) }
            if kept.isEmpty {
                continue    // 这条上课时间一周都不剩 → 整条去掉
            }
            c.weeks = kept
            c.refreshWeeksLabel()
            out.append(c)
        }
        return out
    }

    /// 合并结果里消失了的保护课程（且找不到用户的显式选择）。
    ///
    /// 不是 `private` 是为了让单元测试能直接驱动这条安全网 —— 正常路径上
    /// 保护课不会消失（默认值就是保留），它拦的是「以后有人改了默认值 / 合并逻辑」。
    static func lostProtectedCourses(current: [Course],
                                             result: TimetableDiff.Result,
                                             choice: TimetableDiff.MergeChoice,
                                             units: [Unit],
                                             courses: [Course]) -> [String] {
        let presentIDs = Set(courses.map { $0.courseID })
        var authorized = Set<String>()

        // 课程级显式选择：matched/ambiguous 用导入 或 删除；removed 删除
        for d in result.matched + result.ambiguous {
            let c = choice.choice(for: d.courseID)
            if c == .useImported || c == .delete { authorized.insert(d.courseID) }
        }
        for d in result.removed where choice.choice(for: d.courseID) == .delete {
            authorized.insert(d.courseID)
        }
        // 冲突级显式选择：用导入（把这门当前课冲突的那几条去掉，算明确授权）
        for u in units where choice.resolution(for: u.id) == .useImported {
            authorized.insert(u.currentCourseID)
        }

        var lost: [String] = []
        var seen = Set<String>()
        for c in current where c.isProtected && !presentIDs.contains(c.courseID) {
            guard !authorized.contains(c.courseID) else { continue }
            guard !seen.contains(c.courseID) else { continue }
            seen.insert(c.courseID)
            lost.append(c.name)
        }
        return lost
    }

    /// 合并结果里「不是用户显式保留」的冲突。
    ///
    /// 两条豁免：
    ///   · 当前课表**本来就存在**的冲突（同两个 courseID + 同一格）→ 旧问题，不拦；
    ///   · 用户显式选了「两边都留」的那个组合。
    private static func residualConflicts(courses: [Course],
                                          current: [Course],
                                          units: [Unit],
                                          choice: TimetableDiff.MergeChoice) -> [String] {
        func sig(_ a: String, _ b: String, _ day: Int, _ block: Int) -> String {
            "\([a, b].sorted().joined(separator: "|"))@\(day)-\(block)"
        }
        var preExisting = Set<String>()
        for c in ScheduleConflicts.detect(current) {
            let ids = c.courses.map { $0.courseID }.sorted()
            for i in 0..<max(0, ids.count) {
                for j in (i + 1)..<max(0, ids.count) {
                    preExisting.insert(sig(ids[i], ids[j], c.day, c.block))
                }
            }
        }
        var keepBoth = Set<String>()
        for u in units where choice.resolution(for: u.id) == .keepBoth {
            for s in u.slots {
                keepBoth.insert(sig(u.importedCourseID, u.currentCourseID, s.day, s.block))
            }
        }

        var out: [String] = []
        for c in ScheduleConflicts.detect(courses) {
            let ids = c.courses.map { $0.courseID }.sorted()
            var blocking = false
            for i in 0..<max(0, ids.count) {
                for j in (i + 1)..<max(0, ids.count) {
                    let s = sig(ids[i], ids[j], c.day, c.block)
                    if preExisting.contains(s) || keepBoth.contains(s) { continue }
                    blocking = true
                }
            }
            if blocking {
                out.append("\(c.timeText)：\(c.names.joined(separator: " / "))")
            }
        }
        return out
    }
}

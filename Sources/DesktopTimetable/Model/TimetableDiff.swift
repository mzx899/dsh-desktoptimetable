import Foundation

/// 课表差异比较（纯函数，可单元测试）。
///
/// 用来回答一个问题：把导入结果覆盖到当前课表上，会发生哪些变化？
///
/// 比较范围：
///   · 学期级：开学日期、学期总周数
///   · 课程级：课名、代码
///   · 上课时间级：星期、节次、教师、地点、周次
///
/// 匹配规则（按优先级）：
///   1. 按 courseID 匹配
///   2. 没有 courseID 的旧数据 → 按规范化 code 匹配
///   3. code 为空 → 按规范化课名匹配
///   4. 课名相同但 code 不同、或匹配到多组 → 不猜，列在「需要确认」里
///
/// 匹配上的课程**一律复用旧 courseID**。
enum TimetableDiff {

    // MARK: - 结果类型

    /// 一门课的差异。
    struct CourseDiff {
        /// 匹配方式。
        enum Match: Equatable {
            /// 按 courseID 匹配上。
            case byID(oldID: String)
            /// 按规范化 code 匹配上。
            case byCode
            /// 按规范化课名匹配上。
            case byName
            /// 导入里新增的课。
            case newCourse
            /// 当前课表有、导入里没有的课。
            case removed
            /// 匹配到多组 / 课名相同但 code 不同 —— 不猜，要用户确认。
            case ambiguous

            /// 是不是「匹配上」（复用旧 courseID）。
            var isMatched: Bool {
                switch self {
                case .byID, .byCode, .byName: return true
                case .newCourse, .removed, .ambiguous: return false
                }
            }
        }

        /// 课程身份（匹配上时是旧 courseID）。
        var courseID: String
        var name: String
        var code: String
        var match: Match

        /// 当前课表里的上课时间。
        var currentSessions: [Course] = []
        /// 导入结果里的上课时间。
        var importedSessions: [Course] = []

        /// 课程级字段有差异（课名 / 代码）。
        var courseLevelChanged: Bool = false
        /// 上课时间级字段有差异（星期 / 节次 / 教师 / 地点 / 周次）。
        var sessionLevelChanged: Bool = false

        /// 这门课到底有没有差异。
        var hasDifference: Bool {
            courseLevelChanged || sessionLevelChanged
        }
    }

    /// 整体比较结果。
    struct Result {
        /// 学期级差异。
        var semesterStartChanged = false
        var semesterMaxWeekChanged = false
        var currentSemester: SemesterConfig = SemesterConfig(start: Date())
        /// 导入学期。
        ///
        /// **导入文件不含学期信息时为 `nil`** —— 导入格式（JSON / Excel）只描述课程，
        /// 没有开学日期和总周数。这种情况下下面两个 Changed 恒为 `false`，
        /// 差异页不会出现「开学日期 / 总周数」两行。**这不是 bug，是没有可比的东西。**
        /// 以前这里传的是 `cur.semester`（拿当前学期跟当前学期比），恒等 → 两行永远不出现，
        /// 属于典型的自比较死代码，现在改成诚实的 `nil`。
        var importedSemester: SemesterConfig?

        /// 匹配上的课程（复用旧 courseID）。
        var matched: [CourseDiff] = []
        /// 导入里新增的课。
        var added: [CourseDiff] = []
        /// 当前课表有、导入里没有的课。
        var removed: [CourseDiff] = []
        /// 需要用户确认的（不自动猜）。
        var ambiguous: [CourseDiff] = []

        /// 差异总数（用于「检测到 N 处差异」）。
        var differenceCount: Int {
            var n = 0
            if semesterStartChanged { n += 1 }
            if semesterMaxWeekChanged { n += 1 }
            n += matched.filter { $0.hasDifference }.count
            return n
        }

        /// 合并后会新增多少门课。
        var addedCount: Int { added.count }
        /// 合并后会移除多少门课。
        var removedCount: Int { removed.count }

        /// 完全没有差异（覆盖等于没变）。
        var isIdentical: Bool {
            differenceCount == 0 && added.isEmpty && removed.isEmpty && ambiguous.isEmpty
        }

        /// 一句话摘要。
        var summary: String {
            "检测到 \(differenceCount) 处差异；\(addedCount) 门课将新增；\(removedCount) 门课将移除"
        }
    }

    // MARK: - 比较

    /// 比较当前课表与导入结果。
    ///
    /// - Parameters:
    ///   - current: 当前课表的课程。
    ///   - imported: 导入结果（courseID 已由 ImportPlanner 分配）。
    ///   - currentSemester: 当前课表的学期配置。
    ///   - importedSemester: 导入文件里的学期配置；**导入文件不含学期信息时传 nil**。
    static func compare(current: [Course],
                        imported: [Course],
                        currentSemester: SemesterConfig,
                        importedSemester: SemesterConfig?) -> Result {
        var result = Result()
        result.currentSemester = currentSemester
        result.importedSemester = importedSemester
        if let imp = importedSemester {
            result.semesterStartChanged = !sameDay(currentSemester.start, imp.start)
            result.semesterMaxWeekChanged = currentSemester.maxWeek != imp.maxWeek
        }

        // ---- 把两边都按 courseID 分组 ----
        let currentGroups = groupByCourseID(current)
        let importedGroups = groupByCourseID(imported)

        // ---- 建索引：旧 courseID / 规范化 code / 规范化课名 ----
        var currentByID: [String: [Course]] = [:]
        var currentByCode: [String: [String]] = [:]   // 规范化 code → courseID 列表
        var currentByName: [String: [String]] = [:]   // 规范化课名 → courseID 列表

        for (cid, records) in currentGroups {
            currentByID[cid] = records
            let code = CourseGrouper.matchKey(records.first?.code ?? "")
            if !code.isEmpty {
                currentByCode[code, default: []].append(cid)
            }
            let name = CourseGrouper.matchKey(records.first?.name ?? "")
            if !name.isEmpty {
                currentByName[name, default: []].append(cid)
            }
        }

        // 候选列表**按 courseID 排序**。
        //
        // 以前是直接 append，顺序取决于 `currentGroups`（字典）的遍历顺序 ——
        // Swift 的字典顺序每次进程都可能不同，于是「匹配不唯一时挑哪个当当前候选」
        // **每次启动结果都不一样**（差异页的「需要确认」行会换一门课）。
        // 排序之后同样的输入永远得到同样的输出。
        for key in currentByCode.keys { currentByCode[key]?.sort() }
        for key in currentByName.keys { currentByName[key]?.sort() }

        var usedCurrentIDs = Set<String>()
        var matchedDiffs: [CourseDiff] = []
        var addedDiffs: [CourseDiff] = []
        var ambiguousDiffs: [CourseDiff] = []

        // ---- 逐个处理导入里的课 ----
        for (importedID, importedRecords) in importedGroups {
            let impName = importedRecords.first?.name ?? ""
            let impCode = importedRecords.first?.code ?? ""

            // 1) 按 courseID 匹配
            if let curRecords = currentByID[importedID] {
                usedCurrentIDs.insert(importedID)
                matchedDiffs.append(makeDiff(currentRecords: curRecords,
                                             importedRecords: importedRecords,
                                             match: .byID(oldID: importedID),
                                             oldID: importedID))
                continue
            }

            // 2) 按规范化 code 匹配
            let codeKey = CourseGrouper.matchKey(impCode)
            if !codeKey.isEmpty {
                let candidates = (currentByCode[codeKey] ?? [])
                    .filter { !usedCurrentIDs.contains($0) }
                if candidates.count == 1 {
                    let cid = candidates[0]
                    usedCurrentIDs.insert(cid)
                    matchedDiffs.append(makeDiff(currentRecords: currentByID[cid]!,
                                                 importedRecords: importedRecords,
                                                 match: .byCode,
                                                 oldID: cid))
                    continue
                }
                if candidates.count > 1 {
                    // 匹配到多组 → 不猜，交给用户确认。
                    //
                    // `oldID` 用**当前候选**的 courseID（不是导入方的）：
                    //   · 「用导入」才有明确的身份可复用（导入的上课时间套上当前课的 courseID）；
                    //   · 当前候选不再落到 `removed` 里，避免同一门课在两个列表里各出现一次。
                    let cid = candidates[0]
                    usedCurrentIDs.insert(cid)
                    ambiguousDiffs.append(makeDiff(currentRecords: currentByID[cid]!,
                                                   importedRecords: importedRecords,
                                                   match: .ambiguous,
                                                   oldID: cid))
                    continue
                }
            }

            // 3) code 为空（或没匹配上）→ 按规范化课名匹配
            let nameKey = CourseGrouper.matchKey(impName)
            if !nameKey.isEmpty {
                let candidates = (currentByName[nameKey] ?? [])
                    .filter { !usedCurrentIDs.contains($0) }
                // 课名相同但 code 不同 → 不猜
                let sameNameDifferentCode = candidates.filter { cid in
                    let curCode = CourseGrouper.matchKey(currentByID[cid]?.first?.code ?? "")
                    let impC = CourseGrouper.matchKey(impCode)
                    return curCode != impC && !curCode.isEmpty && !impC.isEmpty
                }
                if sameNameDifferentCode.count > 0 {
                    let cid = sameNameDifferentCode[0]
                    usedCurrentIDs.insert(cid)
                    ambiguousDiffs.append(makeDiff(currentRecords: currentByID[cid]!,
                                                   importedRecords: importedRecords,
                                                   match: .ambiguous,
                                                   oldID: cid))
                    continue
                }
                if candidates.count == 1 {
                    let cid = candidates[0]
                    usedCurrentIDs.insert(cid)
                    matchedDiffs.append(makeDiff(currentRecords: currentByID[cid]!,
                                                 importedRecords: importedRecords,
                                                 match: .byName,
                                                 oldID: cid))
                    continue
                }
                if candidates.count > 1 {
                    let cid = candidates[0]
                    usedCurrentIDs.insert(cid)
                    ambiguousDiffs.append(makeDiff(currentRecords: currentByID[cid]!,
                                                   importedRecords: importedRecords,
                                                   match: .ambiguous,
                                                   oldID: cid))
                    continue
                }
            }

            // 4) 匹配不上 → 新增
            addedDiffs.append(makeDiff(currentRecords: [],
                                       importedRecords: importedRecords,
                                       match: .newCourse,
                                       oldID: importedID))
        }

        // ---- 当前课表里有、导入里没有的课 ----
        var removedDiffs: [CourseDiff] = []
        for (cid, records) in currentGroups where !usedCurrentIDs.contains(cid) {
            removedDiffs.append(makeDiff(currentRecords: records,
                                         importedRecords: [],
                                         match: .removed,
                                         oldID: cid))
        }
        // 排序：字典遍历顺序不稳定，界面上的行序不能跟着乱跳
        removedDiffs.sort { $0.courseID < $1.courseID }

        result.matched = matchedDiffs
        result.added = addedDiffs
        result.removed = removedDiffs
        result.ambiguous = ambiguousDiffs
        return result
    }

    // MARK: - 合并

    /// 合并决策（用户在差异合并页的选择）。
    struct MergeChoice: Equatable {
        /// 学期总周数：保留当前 / 用导入。
        enum SemesterChoice: String, Equatable {
            case keepCurrent
            case useImported

            var label: String {
                self == .keepCurrent ? "保留当前" : "用导入"
            }
        }
        /// 单门课：保留当前 / 用导入。
        enum CourseChoice: String, Equatable {
            case keepCurrent
            case useImported
            /// 导入新增的课：跳过（不导入）。
            case skip
            /// 导入里消失的课：删除。
            case delete

            var label: String {
                switch self {
                case .keepCurrent: return "保留当前"
                case .useImported: return "用导入"
                case .skip: return "跳过"
                case .delete: return "删除"
                }
            }
        }

        var semesterStart: SemesterChoice = .keepCurrent
        var semesterMaxWeek: SemesterChoice = .keepCurrent
        /// courseID → 课程选择。
        var courses: [String: CourseChoice] = [:]
        /// 冲突单元 id → 选择。**没有键 = 用户还没决定**（不是「默认保留当前」）——
        /// 有未决定的冲突时「应用」必须置灰，不能替用户做选择。
        var conflicts: [String: ConflictResolution] = [:]

        /// 某门课的选择（没设置过时按默认原则算）。
        func choice(for courseID: String) -> CourseChoice {
            courses[courseID] ?? defaultChoice
        }

        /// 某个冲突单元的选择（nil = 未决定）。
        func resolution(for conflictID: String) -> ConflictResolution? {
            conflicts[conflictID]
        }
    }

    /// 冲突单元的三种解析方式。
    enum ConflictResolution: String, Equatable {
        /// 保留当前（导入侧**重叠的那几周**让开；没冲突的周次照旧导入）。
        case keepCurrent
        /// 用导入（当前侧**重叠的那几周**让开；这门课其他周次保留）。
        case useImported
        /// 两边都留 —— 用户明确接受这个时间冲突。
        case keepBoth

        var label: String {
            switch self {
            case .keepCurrent: return "保留当前"
            case .useImported: return "用导入"
            case .keepBoth: return "两边都留"
            }
        }
    }

    /// 默认选择原则（**来源感知**，防止静默覆盖 / 静默丢课）：
    ///   · 匹配上的课 + 当前这门是「用户新增 / 用户改过 / 来源不明」→ 保留当前
    ///   · 匹配上的课 + 当前这门就是导入来的、没动过 → 用导入（覆盖语义）
    ///   · 导入新增 → 用导入
    ///   · 导入里消失 → 保留当前（保护课程绝不允许默认删除）
    ///   · 需要确认 → 保留当前
    ///   · 学期字段 → 保留当前
    static let defaultChoice = MergeChoice.CourseChoice.keepCurrent

    /// 新增课的默认选择。
    static let defaultChoiceForAdded = MergeChoice.CourseChoice.useImported
    /// 消失课的默认选择。
    static let defaultChoiceForRemoved = MergeChoice.CourseChoice.keepCurrent
    /// 「需要确认」的课的默认选择：保留当前（不动比乱动安全）。
    static let defaultChoiceForAmbiguous = MergeChoice.CourseChoice.keepCurrent

    /// 匹配上的课、当前那份**受保护**（用户新增 / 改过 / 旧数据）→ 保留当前。
    static let defaultChoiceForProtectedMatched = MergeChoice.CourseChoice.keepCurrent
    /// 匹配上的课、当前那份不保护（就是上次导入的原样）→ 用导入。
    static let defaultChoiceForUnprotectedMatched = MergeChoice.CourseChoice.useImported

    /// 差异合并页的初始选择（按默认原则）。
    static func defaultMergeChoice(for result: Result) -> MergeChoice {
        var choice = MergeChoice()
        choice.semesterStart = .keepCurrent
        choice.semesterMaxWeek = .keepCurrent
        for d in result.matched {
            // 当前这门课是不是受保护的（用户新增 / 改过 / 旧数据）？
            // 以前这里一律 keepCurrent：用户改了地点的那门课默认保留（对），
            // 但**没动过的导入课也默认保留** → 覆盖导入等于什么都没更新，
            // 用户点「应用」后课表还是旧的。现在按来源分流。
            let protected = d.currentSessions.contains { $0.isProtected }
            choice.courses[d.courseID] = protected ? defaultChoiceForProtectedMatched
                                                   : defaultChoiceForUnprotectedMatched
        }
        for d in result.added {
            choice.courses[d.courseID] = defaultChoiceForAdded
        }
        for d in result.removed {
            choice.courses[d.courseID] = defaultChoiceForRemoved
        }
        // 「需要确认」的课默认**保留当前**。
        // 以前这些课没有默认项，`choice.choice(for:)` 会落到 `defaultChoice`（也是 keepCurrent），
        // 看着一样；但 `merge` 根本不读 ambiguous，所以真正的默认值没人管。
        for d in result.ambiguous {
            choice.courses[d.courseID] = defaultChoiceForAmbiguous
        }
        // 冲突单元**不给默认值** —— 用户必须逐条选（见 `ImportConflictLogic`）。
        return choice
    }

    /// 把「用导入」之后的来源标记定下来。
    ///
    /// - 当前那门课**受保护** → 来源标记**原样保住**（`.manual` 仍是「你新增」，
    ///   `.unknown` 仍是「旧数据（来源未知）」，`.imported + userModified` 仍是「你修改过」）。
    ///   导入的内容这次是照用了，但这门课「是谁的」这件事没变。
    /// - 当前那门课**不保护**（就是上次导入的原样）→ 来源就是「导入」，
    ///   不制造额外噪音。
    ///
    /// 注意 `.manual` / `.unknown` 保住的是**来源标记**，不是内容 ——
    /// 内容这一次确实按导入的走（用户点的「用导入」）。
    private static func originAfterImport(_ d: CourseDiff, imported: Course) -> (CourseOrigin, Bool) {
        // 当前这几条里只要有一条是受保护的，就保住**那条**的来源标记
        // （课程级字段本来就应该全一致，这里只是防御性地取最保守的那个）。
        if let cur = d.currentSessions.first(where: { $0.isProtected }) {
            return (cur.origin, cur.userModified)
        }
        return (imported.origin, imported.userModified)
    }

    /// 「用导入」之后这门课用哪个颜色。
    ///
    /// 颜色属于**课程设置**（用户挑的），不是导入内容：
    ///   1. 当前这门课有显式色 → 保留当前的（一次导入不该抹掉用户挑的色）；
    ///   2. 当前没有、导入数据有合法颜色 → 用导入的；
    ///   3. 都没有 → `nil`（自动，按课名）。
    ///
    /// 颜色**不参与**差异判定 —— 只有颜色不同不算改动，也就不会影响
    /// `isProtected` / 覆盖导入的保护语义。
    static func colorAfterImport(_ d: CourseDiff) -> String? {
        if let explicit = d.currentSessions.lazy.compactMap({ ColorHex.normalized($0.colorHex) }).first {
            return explicit
        }
        return d.importedSessions.lazy.compactMap({ ColorHex.normalized($0.colorHex) }).first
    }

    /// 按选择合并出最终结果。
    ///
    /// - Returns: (课程数组, 学期配置)。匹配上的课程**复用旧 courseID**。
    static func merge(current: [Course],
                      imported: [Course],
                      result: Result,
                      choice: MergeChoice) -> (courses: [Course], semester: SemesterConfig) {
        var out: [Course] = []
        var seenCurrentIDs = Set<String>()

        // ---- 学期 ----
        // 导入文件不含学期信息时（`importedSemester == nil`），学期一律保留当前。
        var semester = result.currentSemester
        if let imp = result.importedSemester {
            if choice.semesterStart == .useImported { semester.start = imp.start }
            if choice.semesterMaxWeek == .useImported { semester.maxWeek = imp.maxWeek }
        }

        // ---- 匹配上的课 ----
        for d in result.matched {
            let c = choice.choice(for: d.courseID)
            switch c {
            case .keepCurrent:
                out.append(contentsOf: current.filter { $0.courseID == d.courseID })
                seenCurrentIDs.insert(d.courseID)
            case .useImported:
                // 复用旧 courseID
                let color = colorAfterImport(d)
                out.append(contentsOf: d.importedSessions.map { rec in
                    var r = rec
                    r.courseID = d.courseID
                    // 颜色是课程级设置：当前有显式色就保住，别被这次导入抹掉。
                    r.colorHex = color
                    // 用户只授权了**这一次**用导入 —— 「这门课是我的」这个事实
                    // 不能被这一次点击抹掉（否则下次导入就静默覆盖了）。
                    let (o, m) = originAfterImport(d, imported: rec)
                    r.origin = o
                    r.userModified = m
                    return r
                })
                seenCurrentIDs.insert(d.courseID)
            case .skip:
                break
            case .delete:
                break
            }
        }

        // ---- 需要确认的课 ----
        //
        // 以前这一段**根本不存在** —— `merge` 只遍历 matched / removed / added，
        // 于是：
        //   · 差异页给「需要确认」行的「用导入」按钮写进了 `choice.courses[导入方ID]`，
        //     而 merge 从不读这个键 → 按钮是空操作；
        //   · 用户若把对应的「当前有、导入里没有」行选成「删除」，当前课被删掉，
        //     导入版本又不会被加入 → **整门课凭空消失**。
        //
        // 现在 ambiguous 的 `courseID` 是**当前候选**的 courseID，
        // 「用导入」= 用导入的上课时间替换当前候选、复用它的 courseID，
        // 「保留当前」= 原样保留，「删除」= 明确删掉当前候选。
        // 任何组合都不会出现「旧课删了、新课没进」。
        for d in result.ambiguous {
            let c = choice.choice(for: d.courseID)
            switch c {
            case .keepCurrent, .skip:
                out.append(contentsOf: current.filter { $0.courseID == d.courseID })
                seenCurrentIDs.insert(d.courseID)
            case .useImported:
                let color = colorAfterImport(d)
                out.append(contentsOf: d.importedSessions.map { rec in
                    var r = rec
                    r.courseID = d.courseID
                    // 同 matched：颜色保住当前显式色。
                    r.colorHex = color
                    // 同 matched：用户只授权了**这一次**用导入，
                    // 「这是我自己的课」这个事实不能被这一次点击抹掉。
                    let (o, m) = originAfterImport(d, imported: rec)
                    r.origin = o
                    r.userModified = m
                    return r
                })
                seenCurrentIDs.insert(d.courseID)
            case .delete:
                break
            }
        }

        // ---- 当前课表里有、但没被匹配上的课（保持原样，除非选了删除）----
        for d in result.removed {
            let c = choice.choice(for: d.courseID)
            if c == .delete { continue }
            // 已经在上面加过的就别再加一遍（ambiguous 的当前候选不会再出现在 removed 里，
            // 这里只是兜底，保证同一门课永远只出现一次）。
            guard !seenCurrentIDs.contains(d.courseID) else { continue }
            out.append(contentsOf: current.filter { $0.courseID == d.courseID })
            seenCurrentIDs.insert(d.courseID)
        }

        // ---- 导入新增的课 ----
        for d in result.added {
            let c = choice.choice(for: d.courseID)
            guard c == .useImported else { continue }
            out.append(contentsOf: d.importedSessions)
        }

        return (out, semester)
    }

    // MARK: - 校验

    /// 课表数据的合法性校验（纯函数，可单元测试）。
    ///
    /// 这段以前写在 UI 里（`TimetableDiffWindowController.applyTapped`），而且**周次判断是反的**：
    /// ```swift
    /// guard c.weeks.isEmpty else { presentInvalid("…周次为空"); return }
    /// ```
    /// 读出来是「周次**非空**就报错」。正常课程的周次当然非空 —— 于是只要合并结果里有
    /// 一门正常课，点「应用」就必然失败并报「周次为空」；反过来，真·空周次的课程
    /// 反而能通过校验进写盘。抽成纯函数既修掉了这个反向判断，也让它能被单元测试覆盖。
    ///
    /// - Returns: 出错原因（中文，可直接给用户看）；`nil` 表示合法。
    static func validate(courses: [Course], maxWeek: Int) -> String? {
        for c in courses {
            guard (1...7).contains(c.day) else {
                return "「\(c.name)」的星期 \(c.day) 不合法"
            }
            guard Course.blockRange.contains(c.block) else {
                let lastPeriod = Course.blockRange.upperBound * 2 + 2
                return "「\(c.name)」的上课节次超出范围（课表只有第 1–\(lastPeriod) 节）"
            }
            guard !c.weeks.isEmpty else {
                return "「\(c.name)」的周次为空"
            }
            if let over = c.weeks.filter({ $0 < 1 || $0 > maxWeek }).max() {
                return "「\(c.name)」的周次 \(over) 超出学期总周数（最多 \(maxWeek) 周）"
            }
        }
        return nil
    }

    // MARK: - 私有

    /// 按 courseID 分组（保持出现顺序）。
    private static func groupByCourseID(_ courses: [Course]) -> [String: [Course]] {
        var order: [String] = []
        var map: [String: [Course]] = [:]
        for c in courses {
            if map[c.courseID] == nil { order.append(c.courseID) }
            map[c.courseID, default: []].append(c)
        }
        var out: [String: [Course]] = [:]
        for id in order { out[id] = map[id] }
        return out
    }

    private static func makeDiff(currentRecords: [Course],
                                 importedRecords: [Course],
                                 match: CourseDiff.Match,
                                 oldID: String) -> CourseDiff {
        let curName = currentRecords.first?.name ?? ""
        let impName = importedRecords.first?.name ?? ""
        let curCode = currentRecords.first?.code ?? ""
        let impCode = importedRecords.first?.code ?? ""

        var diff = CourseDiff(courseID: oldID,
                              name: impName.isEmpty ? curName : impName,
                              code: impCode.isEmpty ? curCode : impCode,
                              match: match)
        diff.currentSessions = currentRecords
        diff.importedSessions = importedRecords

        // 课程级：课名 / 代码
        if match != .newCourse && match != .removed {
            diff.courseLevelChanged = (curName != impName) || (curCode != impCode)
        }

        // 上课时间级：把两边按 (day, block) 对齐逐项比
        if !currentRecords.isEmpty && !importedRecords.isEmpty {
            diff.sessionLevelChanged = sessionsDiffer(current: currentRecords,
                                                      imported: importedRecords)
        } else if currentRecords.isEmpty != importedRecords.isEmpty {
            diff.sessionLevelChanged = true
        }
        return diff
    }

    /// 上课时间是否不同（星期 / 节次 / 教师 / 地点 / 周次）。
    private static func sessionsDiffer(current: [Course], imported: [Course]) -> Bool {
        // 用「星期+节次」当键对齐，一格多门课时按集合比
        func bucket(_ list: [Course]) -> [String: Set<String>] {
            var out: [String: Set<String>] = [:]
            for c in list {
                let key = "\(c.day)-\(c.block)"
                let sig = "\(c.teacher)|\(c.loc)|\(c.weeks.sorted())"
                out[key, default: []].insert(sig)
            }
            return out
        }
        let a = bucket(current)
        let b = bucket(imported)
        if Set(a.keys) != Set(b.keys) { return true }
        for key in a.keys where a[key] != b[key] { return true }
        return false
    }

    /// 同一天（忽略时分秒）。
    private static func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }
}

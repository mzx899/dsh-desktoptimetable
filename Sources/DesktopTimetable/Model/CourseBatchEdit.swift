import Foundation

// MARK: - 编辑器里的一个时段

/// 一条已落盘的「上课时间」记录的身份。
///
/// 课程表里没有单独的「时段 ID」——同一门课的一次上课由
/// `courseID + day + block` 唯一确定。编辑器用这个身份把
/// 表单里的时段对应回磁盘上的记录。
struct CourseSessionIdentity: Hashable, Equatable {
    var courseID: String
    var day: Int
    var block: Int
}

/// 编辑器里的一行时段。
///
/// `original == nil` 表示这一行是新增的（新增课程、点「复制」、或右键
/// 「添加一个上课时间」）。有值时表示它在保存时要更新对应的旧记录。
struct CourseSessionDraft: Equatable {
    var original: CourseSessionIdentity?
    var draft: CourseDraft
}

/// 一次编辑器保存提交的全部内容。
///
/// `deleted` 是用户明确在表单里删掉的旧时段。保存时只删这里列出的记录，
/// 不会因为「表单里没显示」就误删数据。
struct CourseEditBatch: Equatable {
    var name: String
    var code: String
    /// 课程级颜色（`#rrggbb`）。`nil` = 自动（按课名自动配色）。
    ///
    /// 和 `name` / `code` 一样是**课程级**字段：保存时同步到该 `courseID` 的
    /// **所有**记录，不只是表单里显示出来的那些。
    var colorHex: String?
    var sessions: [CourseSessionDraft]
    var deleted: [CourseSessionIdentity]

    init(name: String,
         code: String,
         colorHex: String? = nil,
         sessions: [CourseSessionDraft],
         deleted: [CourseSessionIdentity] = []) {
        self.name = name
        self.code = code
        self.colorHex = colorHex
        self.sessions = sessions
        self.deleted = deleted
    }
}

/// 一条批量编辑的校验问题。
///
/// `slotIndex` 是表单里的零基下标；课程级问题为 nil。
struct CourseBatchIssue: Equatable {
    var slotIndex: Int?
    var error: CourseEditError
    var message: String
}

/// 批量保存算出来的最终数据。
struct CourseBatchApplyResult {
    var courses: [Course]
    var overrides: [WeekOverride]
    var courseID: String
}

// MARK: - 批量编辑

/// 多时段编辑器的纯逻辑：校验 + 算出最终课程/覆盖记录。
///
/// 旧版 `CourseEdit.apply` 一次只能处理一个时段，且 `.create` 每次都会生成
/// 新 `courseID`。多时段表单必须：
///   · 所有时段共用一个 `courseID`；
///   · 一次校验整张表单（包括时段之间的重复）；
///   · 编辑时显式保留/删除旧记录，不能靠「表单里有没有」来猜。
///
/// 这里不碰磁盘、不弹窗，冲突确认仍由 `ScheduleEditorController` 负责。
enum CourseBatchEdit {

    // MARK: 校验

    static func validate(_ batch: CourseEditBatch,
                         scope: CourseEditScope,
                         courses: [Course],
                         maxWeek: Int) -> [CourseBatchIssue] {
        var issues: [CourseBatchIssue] = []
        let name = batch.name.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            issues.append(issue(.emptyName, slot: nil))
        }
        if batch.sessions.isEmpty {
            issues.append(issue(.emptySessions, slot: nil))
        }

        let existing = courses.filter { $0.courseID == scope.courseID }

        switch scope {
        case .create:
            if !batch.deleted.isEmpty {
                issues.append(issue(.sessionNotFound, slot: nil))
            }
            for (i, session) in batch.sessions.enumerated() where session.original != nil {
                issues.append(issue(.sessionNotFound, slot: i))
            }

        case .edit(let courseID, _, _), .addSession(let courseID):
            if !courses.contains(where: { $0.courseID == courseID }) {
                issues.append(issue(.sessionNotFound, slot: nil))
            }

            for (i, session) in batch.sessions.enumerated() {
                guard let original = session.original else { continue }
                if original.courseID != courseID || !contains(original, in: courses) {
                    issues.append(issue(.sessionNotFound, slot: i))
                }
            }
            for id in batch.deleted {
                if id.courseID != courseID || !contains(id, in: courses) {
                    issues.append(issue(.sessionNotFound, slot: nil))
                }
            }
            // 同一行不能既在「保留」又在「删除」里；一个旧记录也不能被两个时段同时编辑。
            let originalIDs = batch.sessions.compactMap(\.original)
            if Set(originalIDs).count != originalIDs.count {
                issues.append(issue(.sessionNotFound, slot: nil))
            }
            if !Set(originalIDs).isDisjoint(with: Set(batch.deleted)) {
                issues.append(issue(.sessionNotFound, slot: nil))
            }
        }

        // 每个时段的字段校验。
        var validSlots: [(index: Int, day: Int, block: Int)] = []
        for (i, session) in batch.sessions.enumerated() {
            let d = session.draft
            if !(1...7).contains(d.day) {
                issues.append(issue(.invalidDay(d.day), slot: i))
            }
            if !Course.blockRange.contains(d.block) {
                issues.append(issue(.invalidBlock(d.block), slot: i))
            }
            if d.weeks.isEmpty {
                issues.append(issue(.emptyWeeks, slot: i))
            } else if let over = d.weeks.filter({ $0 > maxWeek || $0 < 1 }).min() {
                issues.append(issue(.weekOutOfRange(over), slot: i))
            }
            if (1...7).contains(d.day), Course.blockRange.contains(d.block) {
                validSlots.append((i, d.day, d.block))
            }
        }

        // 表单内部的两个时段不能落在同一格。
        var bySlot: [String: [(index: Int, day: Int, block: Int)]] = [:]
        for slot in validSlots {
            bySlot["\(slot.day)-\(slot.block)", default: []].append(slot)
        }
        for group in bySlot.values where group.count > 1 {
            guard let first = group.first, let second = group.dropFirst().first else { continue }
            issues.append(issue(.duplicateSlotInEditor(firstSlot: first.index,
                                                       secondSlot: second.index,
                                                       day: second.day,
                                                       block: second.block),
                                slot: second.index))
        }

        // 与保存后会保留下来的旧记录也不能撞格。
        //
        // `.edit` 时，`deleted` 和带 `original` 的行都会从旧记录里消失；
        // 剩下的才是「没动、继续留着」的记录。
        let keptExisting: [Course]
        switch scope {
        case .create:
            keptExisting = []
        case .edit, .addSession:
            let mentioned = Set(batch.sessions.compactMap(\.original))
                .union(batch.deleted)
            keptExisting = existing.filter {
                !mentioned.contains(identity(of: $0))
            }
        }
        for slot in validSlots {
            if keptExisting.contains(where: { $0.day == slot.day && $0.block == slot.block }) {
                let displayName = name.isEmpty ? "这门课" : name
                issues.append(issue(.duplicateSlot(courseName: displayName), slot: slot.index))
            }
        }

        return issues
    }

    // MARK: 应用

    /// 把整张表单算成最终 `courses` + `overrides`。
    ///
    /// - `overrideSlots`: 需要写成单周临时覆盖的时段下标（由控制器在冲突确认后给出）。
    /// - 其余时段写进 `courses`；全部时段共用同一个 `courseID`。
    static func apply(_ batch: CourseEditBatch,
                      scope: CourseEditScope,
                      courses: [Course],
                      overrides: [WeekOverride],
                      courseID: String,
                      overrideSlots: Set<Int>,
                      maxWeek: Int) throws -> CourseBatchApplyResult {
        if let first = validate(batch, scope: scope, courses: courses, maxWeek: maxWeek).first {
            throw first.error
        }
        guard !batch.sessions.isEmpty else { throw CourseEditError.emptySessions }
        guard overrideSlots.allSatisfy({ batch.sessions.indices.contains($0) }) else {
            throw CourseEditError.sessionNotFound
        }

        var list = courses
        var ovs = overrides

        let existing = list.filter { $0.courseID == courseID }
        let template = existing.first
        let origin: CourseOrigin
        let inheritedModified: Bool
        switch scope {
        case .create:
            origin = .manual
            inheritedModified = false
        case .edit, .addSession:
            origin = template?.origin ?? .unknown
            inheritedModified = template?.userModified ?? false
        }

        // 1. 先删掉用户明确删除的旧记录。
        for id in batch.deleted {
            guard let i = list.firstIndex(where: { matches($0, id) }) else {
                throw CourseEditError.sessionNotFound
            }
            list.remove(at: i)
        }

        // 2. 编辑模式下，课程级字段（课名 / 代码）同步到这门课的所有旧记录。
        if case .edit = scope {
            let name = batch.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for i in list.indices where list[i].courseID == courseID {
                list[i].name = name
                list[i].code = batch.code
            }
        }

        // 2b. 课程级颜色：`.edit` / `.addSession` 都同步到这门课的所有记录
        //     （包括表单里没显示出来的旧记录）。
        //     `.addSession` 时课名 / 代码只读，但颜色可改 —— 所以颜色单独算一步。
        //     选「自动」= `colorHex = nil`，要**显式清空**旧值。
        let courseColor = ColorHex.normalized(batch.colorHex)
        switch scope {
        case .create:
            break                       // 新课：颜色由下面新建的记录自己带上
        case .edit, .addSession:
            for i in list.indices where list[i].courseID == courseID {
                list[i].colorHex = courseColor
            }
        }

        // 添加上课时间时课程级字段只读，沿用已有课程的值。
        let resolvedName: String
        let resolvedCode: String
        if case .addSession = scope, let template {
            resolvedName = template.name
            resolvedCode = template.code
        } else {
            resolvedName = batch.name.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedCode = batch.code
        }

        // 3. 逐个时段更新 / 新增 / 写成覆盖。
        for (index, session) in batch.sessions.enumerated() {
            var draft = session.draft
            draft.name = resolvedName
            draft.code = resolvedCode
            // 颜色是课程级字段：每一个时段（含写成覆盖的那一段）都用同一个色。
            draft.colorHex = courseColor
            let wantsOverride = overrideSlots.contains(index)

            if let original = session.original {
                guard let i = list.firstIndex(where: { matches($0, original) }) else {
                    throw CourseEditError.sessionNotFound
                }
                if wantsOverride {
                    // 覆盖期间原记录不在 courses 里，只活在覆盖的 restored 里。
                    let old = list.remove(at: i)
                    let ov = WeekOverrideLogic.makeOverride(day: draft.day,
                                                            block: draft.block,
                                                            weeks: draft.weeks,
                                                            draft: draft,
                                                            courseID: courseID,
                                                            restored: WeekOverride.RestoredSession(old))
                    let written = WeekOverrideLogic.writeOverride(ov, into: ovs, courses: list)
                    list = written.courses
                    ovs = written.overrides
                } else {
                    list[i].teacher = draft.teacher
                    list[i].loc = draft.loc
                    list[i].day = draft.day
                    list[i].block = draft.block
                    list[i].weeks = draft.weeks
                    list[i].refreshWeeksLabel()
                }
            } else if wantsOverride {
                let ov = WeekOverrideLogic.makeOverride(day: draft.day,
                                                        block: draft.block,
                                                        weeks: draft.weeks,
                                                        draft: draft,
                                                        courseID: courseID,
                                                        restored: nil)
                let written = WeekOverrideLogic.writeOverride(ov, into: ovs, courses: list)
                list = written.courses
                ovs = written.overrides
            } else {
                var c = Course(day: draft.day, block: draft.block,
                               name: resolvedName,
                               teacher: draft.teacher, loc: draft.loc,
                               code: resolvedCode, courseID: courseID,
                               weeks: draft.weeks,
                               origin: origin,
                               userModified: inheritedModified || origin == .imported,
                               colorHex: courseColor)
                c.refreshWeeksLabel()
                list.append(c)
            }
        }

        // 4. 导入来源的课被用户动过 → 整门课标成 userModified（覆盖导入时保护它）。
        if origin == .imported {
            for i in list.indices where list[i].courseID == courseID {
                list[i].userModified = true
            }
        }
        for i in list.indices {
            list[i].refreshWeeksLabel()
        }

        return CourseBatchApplyResult(courses: list, overrides: ovs, courseID: courseID)
    }

    // MARK: 小工具

    private static func issue(_ error: CourseEditError, slot: Int?) -> CourseBatchIssue {
        let prefix = slot.map { "时段 \($0 + 1)：" } ?? ""
        return CourseBatchIssue(slotIndex: slot,
                                error: error,
                                message: prefix + (error.errorDescription ?? "数据无效"))
    }

    private static func identity(of course: Course) -> CourseSessionIdentity {
        CourseSessionIdentity(courseID: course.courseID,
                              day: course.day,
                              block: course.block)
    }

    private static func contains(_ id: CourseSessionIdentity, in courses: [Course]) -> Bool {
        courses.contains { matches($0, id) }
    }

    private static func matches(_ course: Course, _ id: CourseSessionIdentity) -> Bool {
        course.courseID == id.courseID
            && course.day == id.day
            && course.block == id.block
    }
}

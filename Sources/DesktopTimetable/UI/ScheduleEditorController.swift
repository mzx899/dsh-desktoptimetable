import AppKit

/// 右键编辑调度器：菜单 → 编辑器 → 校验 → 写盘 → 刷新卡片。
///
/// 数据流只有一条：
///   菜单动作 → `CourseEdit`（纯逻辑）→ `ScheduleRepository.save`（备份 + 原子写）
///   → 回调 `onCoursesChanged` → AppDelegate 重新读盘 + 刷新卡片。
///
/// 每次改动前都重新从磁盘读一遍，避免与设置面板的内存副本打架。
final class ScheduleEditorController: NSObject {

    /// 当前课表的数据仓库。
    ///
    /// 阶段 3 引入多课表后，仓库会随「当前课表」变化，
    /// 所以这里存的是取仓库的闭包，而不是固定的一个实例。
    private let repositoryProvider: () -> ScheduleRepository?

    /// 当前课表的仓库（没有课表时为 nil）。
    private var repository: ScheduleRepository? { repositoryProvider() }

    private var courses: [Course] = []
    /// 单周临时覆盖（独立文件 `week_overrides.json`）。
    private var overrides: [WeekOverride] = []
    private var maxWeek = SemesterConfig.defaultMaxWeek

    /// 写盘成功后回调（AppDelegate 重新读盘并刷新卡片）。
    var onCoursesChanged: (() -> Void)?
    /// 自动化测试用：替换两道关的确认。
    ///
    /// nil = 正常弹确认窗（警告 → 提醒，串行）。
    /// 非 nil = 用这个闭包代替确认窗，返回 false 就当用户点了「取消」。
    /// 两道关分别回调（第一道取消 → 第二道根本不会回调），顺序和真实流程一致。
    var testConfirmGate: ((OverrideGate, WeekOverrideLogic.SlotCollision) -> Bool)?

    /// 两道关的种类。
    enum OverrideGate {
        /// 第一道关：选中的周次里**真的有课在上课** → 警告。
        case realConflict
        /// 第二道关：格子上有别的课，但它们在选中的周次里**都不上课** → 提醒。
        case nonOverlapping
    }
    /// 打开设置面板。
    var onOpenSettings: (() -> Void)?
    /// 导入课表。
    var onImportSchedule: (() -> Void)?
    /// 查看课程详情（由上层决定用哪种呈现：网页浮层 or 原生窗口）。
    var onShowDetail: ((Course) -> Void)?

    /// 正在浏览的周（nil = 全部周次），决定新增课程时的默认周次。
    var viewWeek: Int?

    private var editor: CourseEditorWindowController?
    private var detailWindow: NSWindow?

    init(repositoryProvider: @escaping () -> ScheduleRepository?) {
        self.repositoryProvider = repositoryProvider
        super.init()
        reload()
    }

    // MARK: - 数据

    /// 从磁盘读一份最新数据。
    func reload() {
        guard let repo = repository else {
            courses = []
            overrides = []
            maxWeek = SemesterConfig.defaultMaxWeek
            return
        }
        let loaded = repo.load()
        courses = loaded.courses
        overrides = loaded.overrides
        maxWeek = loaded.semester.effectiveMaxWeek(for: loaded.courses)
    }

    var currentCourses: [Course] { courses }

    /// 自动化测试用：走一遍保存流程（不弹编辑器窗口）。
    ///
    /// 两道关由 `testConfirmGate` 决定（没设就真的会弹确认窗）。
    func testSubmit(draft: CourseDraft, scope: CourseEditScope) {
        submit(draft: draft, scope: scope, editor: nil)
    }

    /// 自动化测试用：走一遍多时段保存流程（不弹编辑器窗口）。
    func testSubmit(batch: CourseEditBatch, scope: CourseEditScope) {
        submit(batch: batch, scope: scope, editor: nil)
    }

    /// 当前课表的覆盖记录。
    var currentOverrides: [WeekOverride] { overrides }

    /// 某个格子里的所有课程。
    func coursesInSlot(day: Int, block: Int) -> [Course] {
        courses.filter { $0.day == day && $0.block == block }
    }

    // MARK: - 菜单

    /// 在指定位置弹出右键菜单。
    ///
    /// - Parameters:
    ///   - day/block: 命中的格子。
    ///   - courseID: 命中的课程（网页传来的；原生推断时传 nil）。
    ///   - screenPoint: 屏幕坐标（弹出位置）。
    func showMenu(day: Int,
                  block: Int,
                  courseID: String?,
                  at screenPoint: NSPoint) {
        reload()
        let slotCourses = coursesInSlot(day: day, block: block)
        let hit = courseID.flatMap { id in slotCourses.first { $0.courseID == id } }
        // 这一格在**当前浏览的周**有没有覆盖。
        // 全部周次视图（viewWeek == nil）没有覆盖 —— 那边只显示原始课表。
        let ov = WeekOverrideLogic.override(day: day, block: block,
                                             week: viewWeek, in: overrides)
        let slot = ScheduleMenuBuilder.Slot(day: day, block: block,
                                             courses: slotCourses,
                                             hitCourseID: hit?.courseID ?? slotCourses.first?.courseID,
                                             override: ov)
        let plan = ScheduleMenuBuilder.build(for: slot)
        let menu = buildNSMenu(plan, slot: slot)
        // 只弹菜单本身不激活 App（不抢焦点）；选「编辑…」时再激活。
        MenuPresenter.present(menu, at: screenPoint)
    }

    /// 把纯数据菜单计划变成真正的 NSMenu。
    private func buildNSMenu(_ items: [ScheduleMenuItem], slot: ScheduleMenuBuilder.Slot) -> NSMenu {
        let menu = NSMenu()
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let mi = NSMenuItem(title: item.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = MenuTag(action: item.action, slot: slot)
            if !item.submenu.isEmpty {
                let sub = buildNSMenu(item.submenu, slot: slot)
                mi.submenu = sub
                mi.action = nil
                mi.target = nil
            }
            menu.addItem(mi)
        }
        return menu
    }

    /// NSMenuItem 的附带信息（动作 + 当时的格子）。
    private struct MenuTag {
        var action: ScheduleMenuAction
        var slot: ScheduleMenuBuilder.Slot
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? MenuTag else { return }
        handle(tag.action, slot: tag.slot)
    }

    // MARK: - 动作

    private func handle(_ action: ScheduleMenuAction, slot: ScheduleMenuBuilder.Slot) {
        switch action {
        case .addCourse(let day, let block):
            openCreateEditor(day: day, block: block)

        case .editSession(let courseID, let day, let block):
            guard let c = session(courseID: courseID, day: day, block: block) else { return }
            openEditEditor(course: c)

        case .addSession(let courseID):
            guard let c = session(courseID: courseID, day: slot.day, block: slot.block)
                ?? courses.first(where: { $0.courseID == courseID }) else { return }
            openAddSessionEditor(course: c)

        case .viewSession(let courseID, let day, let block):
            guard let c = session(courseID: courseID, day: day, block: block) else { return }
            showDetail(course: c)

        case .deleteSession(let courseID):
            deleteSession(courseID: courseID, slot: slot)

        case .deleteCourse(let courseID):
            deleteCourse(courseID: courseID)

        case .viewOverride(let day, let block):
            guard let ov = overrides.first(where: { $0.day == day && $0.block == block }) else { return }
            showDetail(course: ov.asCourse())

        case .editOverride(let day, let block):
            guard let ov = overrides.first(where: { $0.day == day && $0.block == block }) else { return }
            openOverrideEditor(ov)

        case .deleteOverride(let day, let block):
            deleteOverride(day: day, block: block)

        case .openSettings:
            onOpenSettings?()

        case .importSchedule:
            onImportSchedule?()
        }
    }

    /// 按「课次」定位记录：courseID + day + block。
    ///
    /// 只按 courseID 找会拿到**同一门课的第一个上课时间** —— 一门课有多次上课时，
    /// 编辑器会打开别人那条：预填的星期 / 节次 / 周次全错，
    /// 保存时还会被「同一时间已经有上课记录」拦下（自己跟自己撞了）。
    private func session(courseID: String, day: Int, block: Int) -> Course? {
        courses.first { $0.courseID == courseID && $0.day == day && $0.block == block }
            // 兜底：坐标对不上（记录被移动过）时退回按 courseID 找
            ?? courses.first { $0.courseID == courseID }
    }

    // MARK: - 新增

    private func openCreateEditor(day: Int, block: Int) {
        var draft = CourseDraft()
        draft.day = day
        draft.block = block
        draft.weeks = defaultWeeks()
        let session = CourseSessionDraft(original: nil, draft: draft)
        presentEditor(mode: .create,
                      courseDraft: draft,
                      sessions: [session],
                      primary: nil,
                      scope: .create(day: day, block: block))
    }

    /// 默认周次：正在浏览具体周 → 该周；全部周次 → 1...maxWeek。
    private func defaultWeeks() -> [Int] {
        if let w = viewWeek, (1...maxWeek).contains(w) { return [w] }
        return Array(1...maxWeek)
    }

    // MARK: - 编辑

    /// 测试用：当前编辑器。
    var testEditor: CourseEditorWindowController? { editor }

    /// 测试用：打开某门课的编辑器。
    @discardableResult
    func testOpenEditor(courseID: String) -> CourseEditorWindowController? {
        guard let c = courses.first(where: { $0.courseID == courseID }) else { return nil }
        openEditEditor(course: c)
        return editor
    }

    /// 测试用：打开「添加一个上课时间」编辑器（按课次定位，和右键点的那次一致）。
    @discardableResult
    func testOpenAddSessionEditor(courseID: String, day: Int, block: Int)
        -> CourseEditorWindowController? {
        guard let c = session(courseID: courseID, day: day, block: block) else { return nil }
        openAddSessionEditor(course: c)
        return editor
    }

    /// 一门课在编辑器里的时段顺序：点中的那条排第一，其余按 (星期, 节次) 排。
    ///
    /// 旧数据里万一有同 courseID + 同格的重复记录，只保留一条，
    /// 避免两行对应同一个身份、保存时互相打架。
    private func orderedSessions(for course: Course) -> (primary: Course, ordered: [Course]) {
        let all = courses.filter { $0.courseID == course.courseID }
        let primary = all.first {
            $0.day == course.day && $0.block == course.block
        } ?? course
        let primaryID = CourseSessionIdentity(courseID: primary.courseID,
                                              day: primary.day,
                                              block: primary.block)
        var ordered = [primary]
        var seen: Set<CourseSessionIdentity> = [primaryID]
        for c in all.sorted(by: { ($0.day, $0.block) < ($1.day, $1.block) }) {
            let id = CourseSessionIdentity(courseID: c.courseID, day: c.day, block: c.block)
            guard seen.insert(id).inserted else { continue }
            ordered.append(c)
        }
        return (primary, ordered)
    }

    private func openEditEditor(course: Course) {
        let (primary, ordered) = orderedSessions(for: course)
        let primaryID = CourseSessionIdentity(courseID: primary.courseID,
                                              day: primary.day,
                                              block: primary.block)
        let sessions = ordered.map {
            CourseSessionDraft(original: CourseSessionIdentity(courseID: $0.courseID,
                                                                day: $0.day,
                                                                block: $0.block),
                               draft: draft(from: $0))
        }
        presentEditor(mode: .edit(courseID: primary.courseID,
                                  day: primary.day, block: primary.block),
                      courseDraft: draft(from: primary),
                      sessions: sessions,
                      primary: primaryID,
                      scope: .edit(courseID: primary.courseID,
                                   day: primary.day, block: primary.block))
    }

    /// 「添加一个上课时间」：和编辑一样列出这门课的**全部**时段，
    /// 末尾追加一条预填好的新时段（教师 / 地点 / 周次沿用点中的那次）。
    ///
    /// 以前这里只放一条空白时段：多时段课程看不到已有时间，
    /// 教师 / 地点是空的，周次也被换成默认值 —— 看起来像数据丢了。
    private func openAddSessionEditor(course: Course) {
        let (primary, ordered) = orderedSessions(for: course)
        let primaryID = CourseSessionIdentity(courseID: primary.courseID,
                                              day: primary.day,
                                              block: primary.block)
        // 新时段：字段沿用点中的那条；星期 / 节次挑一个这门课还没占用的空格，
        // 否则一打开表单就是「同一时间重复」，保存必被拦。
        var fresh = draft(from: primary)
        let slot = freeSlot(for: ordered, near: primary)
        fresh.day = slot.day
        fresh.block = slot.block

        let sessions = ordered.map {
            CourseSessionDraft(original: CourseSessionIdentity(courseID: $0.courseID,
                                                                day: $0.day,
                                                                block: $0.block),
                               draft: draft(from: $0))
        } + [CourseSessionDraft(original: nil, draft: fresh)]

        presentEditor(mode: .addSession(courseID: primary.courseID),
                      courseDraft: draft(from: primary),
                      sessions: sessions,
                      primary: primaryID,
                      scope: .addSession(courseID: primary.courseID))
    }

    /// 从 `base` 所在的那天开始，找这门课还没占用的第一个 (星期, 节次)。
    private func freeSlot(for records: [Course], near base: Course) -> (day: Int, block: Int) {
        let used = Set(records.map { "\($0.day)-\($0.block)" })
        for offset in 0..<7 {
            let day = (base.day - 1 + offset) % 7 + 1
            for block in Course.blockRange where !used.contains("\(day)-\(block)") {
                return (day, block)
            }
        }
        return (base.day, base.block)
    }

    private func draft(from course: Course) -> CourseDraft {
        var draft = CourseDraft()
        draft.name = course.name
        draft.code = course.code
        draft.teacher = course.teacher
        draft.loc = course.loc
        draft.day = course.day
        draft.block = course.block
        draft.weeks = course.weeks
        // 颜色是课程级字段：预填成这门课当前的色，
        // 「添加上课时间」时颜色选择器才会停在正确的选中项上。
        draft.colorHex = course.colorHex
        return draft
    }

    // MARK: - 编辑器

    private func presentEditor(mode: CourseEditorWindowController.Mode,
                               courseDraft: CourseDraft,
                               sessions: [CourseSessionDraft],
                               primary: CourseSessionIdentity?,
                               scope: CourseEditScope) {
        let e = CourseEditorWindowController(mode: mode,
                                             courseDraft: courseDraft,
                                             sessions: sessions,
                                             primary: primary,
                                             maxWeek: maxWeek)
        editor = e
        e.onSubmitBatch = { [weak self, weak e] batch in
            self?.submit(batch: batch, scope: scope, editor: e)
        }
        if case .edit = scope {
            e.onDeleteAll = { [weak self] in
                self?.deleteCourseFromEditor(scope.courseID) ?? false
            }
        }
        e.onCancel = { [weak self] in
            self?.editor = nil
        }
        e.show()
    }

    private func submit(draft: CourseDraft, scope: CourseEditScope, editor: CourseEditorWindowController?) {
        // ---- 这个时间段上有没有别的课？----
        //
        //   · 没有 → 普通课，进 `courses`（「全部周次」视图看得见）；
        //   · 有   → 只能是**单周临时覆盖**，不进 `courses`
        //            （否则那个格子在「全部周次」视图里会挤两门课 —— 用户说的「否则会冲突」）。
        let collision = WeekOverrideLogic.collision(day: draft.day, block: draft.block,
                                                    weeks: draft.weeks, courses: courses,
                                                    ownCourseID: scope.courseID)
        if collision.hasOtherCourse {
            // 两道关：先警告（真冲突），再提醒（非本周课）。
            // 第一个点「取消」→ 后面的提醒不再弹，什么都不保存。
            if let gate = testConfirmGate {
                if !collision.realConflicts.isEmpty,
                   !gate(.realConflict, collision) { return }
                if !collision.nonOverlapping.isEmpty,
                   !gate(.nonOverlapping, collision) { return }
            } else {
                if !collision.realConflicts.isEmpty,
                   !confirmRealConflict(collision.realConflicts) { return }
                if !collision.nonOverlapping.isEmpty,
                   !confirmNonOverlapping(collision.nonOverlapping) { return }
            }
            // 两道都过了 → 写成覆盖记录
            saveAsOverride(draft: draft, scope: scope, editor: editor)
            return
        }

        // ---- 普通课：原路径 ----
        do {
            let updated = try CourseEdit.apply(draft: draft, scope: scope, courses: courses, maxWeek: maxWeek)
            try repository?.save(updated)
            courses = updated
            editor?.clearError()
            editor?.close()
            self.editor = nil
            onCoursesChanged?()
        } catch let e as CourseEditError {
            editor?.showError(e.errorDescription ?? "数据无效")
        } catch {
            editor?.showError("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 多时段保存

    /// 一次保存整张表单（新增 / 编辑 / 添加上课时间都走这里）。
    ///
    /// 顺序：
    ///   1. 全部时段先校验，任何一条不合法 → 表单内提示，不写盘；
    ///   2. 逐时段判断冲突；冲突的段落写成单周覆盖，其余进 `courses`；
    ///      任何一道确认被取消 → 整次保存中止（之前确认过的也不写）；
    ///   3. 一次算出最终课表 + 覆盖，再统一写盘。
    private func submit(batch: CourseEditBatch,
                        scope: CourseEditScope,
                        editor: CourseEditorWindowController?) {
        // 编辑模式把唯一时段删掉了 = 删整门课（正常由编辑器的 onDeleteAll 处理；
        // 这里再兜一层，保证 testSubmit / 旧调用不会写出空课表）。
        if case .edit = scope, batch.sessions.isEmpty {
            _ = deleteCourseFromEditor(scope.courseID)
            return
        }

        let issues = CourseBatchEdit.validate(batch, scope: scope,
                                              courses: courses, maxWeek: maxWeek)
        if let first = issues.first {
            editor?.showError(first.message)
            return
        }

        // 新增课先分配 courseID：冲突判断要把这门课自己排除掉。
        // （旧单时段路径传的是空字符串，会把 courseID 为空的老记录误当成「自己」。）
        let courseID: String
        if case .create = scope {
            courseID = UUID().uuidString
        } else {
            courseID = scope.courseID
        }

        var overrideSlots: Set<Int> = []
        for (i, session) in batch.sessions.enumerated() {
            let d = session.draft
            let collision = WeekOverrideLogic.collision(day: d.day, block: d.block,
                                                        weeks: d.weeks, courses: courses,
                                                        ownCourseID: courseID)
            guard collision.hasOtherCourse else { continue }

            if let gate = testConfirmGate {
                if !collision.realConflicts.isEmpty,
                   !gate(.realConflict, collision) { return }
                if !collision.nonOverlapping.isEmpty,
                   !gate(.nonOverlapping, collision) { return }
            } else {
                if !collision.realConflicts.isEmpty,
                   !confirmRealConflict(collision.realConflicts, slotNumber: i) { return }
                if !collision.nonOverlapping.isEmpty,
                   !confirmNonOverlapping(collision.nonOverlapping, slotNumber: i) { return }
            }
            overrideSlots.insert(i)
        }

        do {
            let result = try CourseBatchEdit.apply(batch, scope: scope,
                                                   courses: courses,
                                                   overrides: overrides,
                                                   courseID: courseID,
                                                   overrideSlots: overrideSlots,
                                                   maxWeek: maxWeek)
            try repository?.save(result.courses)
            if result.overrides != overrides {
                try repository?.saveOverrides(result.overrides)
            }
            courses = result.courses
            overrides = result.overrides
            editor?.clearError()
            editor?.close()
            self.editor = nil
            onCoursesChanged?()
        } catch let e as CourseEditError {
            editor?.showError(e.errorDescription ?? "数据无效")
        } catch {
            editor?.showError("保存失败：\(error.localizedDescription)")
        }
    }

    /// 编辑器里删掉最后一个时段 → 删整门课。
    ///
    /// 编辑器已经确认过了，这里不再弹第二个确认框。
    @discardableResult
    private func deleteCourseFromEditor(_ courseID: String) -> Bool {
        let updated = CourseEdit.deleteCourse(courseID: courseID, courses: courses)
        do {
            try repository?.save(updated)
            courses = updated
            editor?.clearError()
            editor?.close()
            self.editor = nil
            onCoursesChanged?()
            return true
        } catch {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "删除失败",
                message: error.localizedDescription,
                confirmTitle: "好",
                showsCancel: false))
            return false
        }
    }

    // MARK: - 临时覆盖

    /// 第一道关：选中的周次里**真的有课在上课** → 警告。
    ///
    /// 取消 → 什么都不保存，提醒框也不再弹。
    private func confirmRealConflict(_ clashes: [Course], slotNumber: Int? = nil) -> Bool {
        let prefix = slotNumber.map { "时段 \($0 + 1)：" } ?? ""
        let dialog = ConfirmDialogController(request: .init(
            title: prefix + "这个时间已经有课了",
            message: "你选的这些周次里，下面这门课正在上课：\n"
                + "要用你的课覆盖这几周吗？原课只在被覆盖的那几周被遮住，其它周不受影响。",
            items: clashes,
            confirmTitle: "确认覆盖"))
        return dialog.run() == .confirm
    }

    /// 第二道关：格子上还有别的课，但它们在选中的周次里**都不上课**（非本周课）→ 提醒。
    private func confirmNonOverlapping(_ others: [Course], slotNumber: Int? = nil) -> Bool {
        let prefix = slotNumber.map { "时段 \($0 + 1)：" } ?? ""
        let dialog = ConfirmDialogController(request: .init(
            title: prefix + "这个时间已有一门非本周课",
            message: "下面这门课在这个时间有课，但它不在你选中的那几周上：\n"
                + "你的课只在选中的那几周生效，原课不受影响。继续吗？",
            items: others,
            confirmTitle: "继续"))
        return dialog.run() == .confirm
    }

    /// 把这次保存变成一条**单周临时覆盖**。
    ///
    /// 覆盖**不进** `courses`：
    ///   · 新增的课 → 只有覆盖记录里有它，「全部周次」视图看不见；
    ///   · 改已有课 → 那条记录从 `courses` 里移出去（存进覆盖记录的 `restored`），
    ///     撤销覆盖时再放回来。
    private func saveAsOverride(draft: CourseDraft, scope: CourseEditScope,
                                editor: CourseEditorWindowController?) {
        // 校验（课名 / 周次 / 星期节次 / 同一门课同格重复）
        let errors = CourseEdit.validate(draft: draft, scope: scope,
                                         courses: courses, maxWeek: maxWeek)
        if let first = errors.first {
            editor?.showError(first.errorDescription ?? "数据无效")
            return
        }

        do {
            // 纯逻辑：算出新的课表 + 新的覆盖记录
            let result = WeekOverrideLogic.makeOverrideSave(draft: draft, scope: scope,
                                                            courses: courses, overrides: overrides)
            try repository?.save(result.courses)
            try repository?.saveOverrides(result.overrides)
            courses = result.courses
            overrides = result.overrides
            editor?.clearError()
            editor?.close()
            self.editor = nil
            onCoursesChanged?()
        } catch let e as CourseEditError {
            editor?.showError(e.errorDescription ?? "数据无效")
        } catch {
            editor?.showError("保存失败：\(error.localizedDescription)")
        }
    }

    /// 编辑一条覆盖（星期节次锁定 —— 换格子请删掉重加）。
    private func openOverrideEditor(_ ov: WeekOverride) {
        var draft = CourseDraft()
        draft.name = ov.name
        draft.code = ov.code
        draft.teacher = ov.teacher
        draft.loc = ov.loc
        draft.day = ov.day
        draft.block = ov.block
        draft.weeks = ov.weeks
        // 颜色行在这个模式里不显示：把原色带进草稿，
        // 保存时（`var updated = ov`）自然保留，不会被静默清成自动色。
        draft.colorHex = ov.colorHex

        let e = CourseEditorWindowController(mode: .editOverride, draft: draft, maxWeek: maxWeek)
        editor = e
        e.onSubmit = { [weak self, weak e] newDraft in
            self?.submitOverride(draft: newDraft, override: ov, editor: e)
        }
        e.onCancel = { [weak self] in
            self?.editor = nil
        }
        e.show()
    }

    /// 保存对一条覆盖的修改（周次 / 字段）。
    private func submitOverride(draft: CourseDraft, override ov: WeekOverride,
                                editor: CourseEditorWindowController?) {
        let errors = CourseEdit.validate(draft: draft, scope: .create(day: ov.day, block: ov.block),
                                         courses: courses, maxWeek: maxWeek)
        if let first = errors.first {
            editor?.showError(first.errorDescription ?? "数据无效")
            return
        }
        // 两道关照旧（改周次也可能撞上别的课）
        let collision = WeekOverrideLogic.collision(day: ov.day, block: ov.block,
                                                    weeks: draft.weeks, courses: courses,
                                                    ownCourseID: ov.courseID)
        if !collision.realConflicts.isEmpty,
           !confirmRealConflict(collision.realConflicts) { return }
        if !collision.nonOverlapping.isEmpty,
           !confirmNonOverlapping(collision.nonOverlapping) { return }

        do {
            var updated = ov
            updated.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.teacher = draft.teacher
            updated.loc = draft.loc
            updated.code = draft.code
            updated.weeks = draft.weeks.sorted()
            let result = WeekOverrideLogic.writeOverride(updated, into: overrides, courses: courses)
            try repository?.save(result.courses)
            try repository?.saveOverrides(result.overrides)
            courses = result.courses
            overrides = result.overrides
            editor?.clearError()
            editor?.close()
            self.editor = nil
            onCoursesChanged?()
        } catch {
            editor?.showError("保存失败：\(error.localizedDescription)")
        }
    }

    /// 删除一条覆盖（撤销覆盖）→ 那一格恢复成原来的课。
    private func deleteOverride(day: Int, block: Int) {
        guard let ov = overrides.first(where: { $0.day == day && $0.block == block }) else { return }
        let message = "覆盖的是第 \(WeekSpec.format(Set(ov.weeks))) 周。"
            + (ov.restored == nil
                ? "\n删除后这门课彻底消失。"
                : "\n删除后那一格恢复成原来的课。")
        let dialog = ConfirmDialogController(request: .init(
            title: "删除临时覆盖？",
            message: message,
            items: [ov.asCourse()],
            confirmTitle: "删除",
            severity: .destructive))
        guard dialog.run() == .confirm else { return }
        deleteOverrideConfirmed(day: day, block: block)
    }

    /// 自动化测试用：撤销一条覆盖（跳过确认窗）。
    func testDeleteOverride(day: Int, block: Int, confirmed: Bool) {
        guard confirmed else { return }
        deleteOverrideConfirmed(day: day, block: block)
    }

    /// 撤销覆盖的真正动作（确认之后）。
    private func deleteOverrideConfirmed(day: Int, block: Int) {
        let result = WeekOverrideLogic.removeOverride(day: day, block: block,
                                                       from: overrides, courses: courses)
        do {
            try repository?.save(result.courses)
            try repository?.saveOverrides(result.overrides)
            courses = result.courses
            overrides = result.overrides
            onCoursesChanged?()
        } catch {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "删除失败",
                message: error.localizedDescription,
                confirmTitle: "好",
                showsCancel: false))
        }
    }

    // MARK: - 详情

    /// 展示课程详情。
    ///
    /// 上层给了 `onShowDetail` 就交给上层（B 模式用网页浮层），
    /// 否则弹原生详情窗口（A 模式用这个）。
    func showDetail(course: Course) {
        if let onShowDetail {
            onShowDetail(course)
            return
        }
        presentNativeDetail(course)
    }

    /// 原生详情窗口。
    func presentNativeDetail(_ course: Course) {
        let view = CourseDetailView(course: course)
        // 内容视图铺满窗口 → 顶部不留透明带：红绿灯落在 HUD 材质上，
        // 四个圆角一致（否则上直角、下圆角，边框看着是坏的）。
        let win = HUDWindow.make(title: course.name,
                                 size: NSSize(width: 400, height: 278),
                                 miniaturizable: false)
        HUDWindow.installContent(in: win, root: view)
        detailWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - 删除

    private func deleteSession(courseID: String, slot: ScheduleMenuBuilder.Slot) {
        // 删的是命中格子里、命中课程的那一条
        guard let target = courses.first(where: {
            $0.courseID == courseID && $0.day == slot.day && $0.block == slot.block
        }) else { return }
        let total = CourseEdit.sessionCount(courseID: courseID, courses: courses)
        let isLast = total <= 1

        // 删除单节 → 危险样式（红色主操作 + 默认焦点给「取消」）。
        let outcome = AlertDialogController.show(.init(
            severity: .destructive,
            title: isLast ? "这是「\(target.name)」最后一节课" : "删除这一节课？",
            message: "\(Schedule.dayNames[max(0, min(6, target.day - 1))]) 第\(target.block * 2 + 1)-\(target.block * 2 + 2)节　\(target.name)"
                + (isLast ? "\n\n删除后整门课将消失，笔记以后会保留。" : ""),
            confirmTitle: "删除",
            cancelTitle: "取消"))
        guard case .confirmed = outcome else { return }

        let updated = CourseEdit.deleteSession(courseID: courseID, day: target.day, block: target.block, courses: courses)
        persist(updated)
    }

    private func deleteCourse(courseID: String) {
        guard let c = courses.first(where: { $0.courseID == courseID }) else { return }
        let count = CourseEdit.sessionCount(courseID: courseID, courses: courses)

        // 原来这里是**两道**系统确认框（先问一次，再「再确认一次」）。
        // 合成一个危险确认：说明保留（含「不可撤销」），主操作用红色，
        // 默认焦点给「取消」，Return 不会直接删掉整门课。
        let outcome = AlertDialogController.show(.init(
            severity: .destructive,
            title: "删除整门课程「\(c.name)」？",
            message: "会删掉 \(count) 个上课时间记录，此操作不可撤销。\n"
                + "笔记会保留（变成孤立笔记）。",
            // 红色按钮就叫「删除」（2026-11-09 用户要求）——
            // 标题已经说清「删除整门课程」，按钮上再重复一遍只会显得啰嗦。
            confirmTitle: "删除",
            cancelTitle: "取消"))
        guard case .confirmed = outcome else { return }

        let updated = CourseEdit.deleteCourse(courseID: courseID, courses: courses)
        persist(updated)
    }

    private func persist(_ updated: [Course]) {
        do {
            try repository?.save(updated)
            courses = updated
            onCoursesChanged?()
        } catch {
            AlertDialogController.show(.init(
                severity: .warning,
                title: "保存失败",
                message: error.localizedDescription,
                confirmTitle: "好",
                showsCancel: false))
        }
    }
}

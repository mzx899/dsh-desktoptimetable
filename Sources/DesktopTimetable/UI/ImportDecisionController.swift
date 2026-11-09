import AppKit

/// 「应用」的结果 —— 差异页据此决定关不关窗。
///
/// 以前 `onApply` 是 `Void`：差异页在**保存之前**就 `orderOut`，
/// 写盘失败时用户看着窗口关掉、以为成功了，逐条选择也全丢了。
enum ImportApplyOutcome: Equatable {
    /// 写盘成功。
    case success
    /// 写盘失败：带上给用户看的原因，差异页保留。
    case failure(String)
}

/// 导入决策：已有课表时再导入，问「覆盖当前课表 / 新建一份独立课表 / 取消」。
///
/// 流程：
///   1. 解析文件 → CourseGrouper 分组
///   2. 当前没有课表，或当前课表为空 → 直接作为当前课表导入
///   3. 当前已有非空课表 → 三选一，**默认是「覆盖当前课表」**
///   4. 「新建一份独立课表」：输入名称（默认文件名去扩展名，重名自动加后缀），
///      创建新 Timetable，生成**全新 courseID**，自动切为当前课表，原课表不动
///   5. 「覆盖当前课表」：
///      · 有时间冲突 / 匹配关系不唯一 → 进差异合并页逐条决定
///      · 受保护课程在导入文件里消失 → 先逐门问「保留 / 删除」
///      · 其余情况（普通新增 / 更新，或受保护课程只是有导入新版本）→
///        按默认规则直接覆盖，不弹差异页（受保护内容默认保留当前）
///   6. 「取消」→ 什么都不写
///
/// 本期只有「新建」和「覆盖」两种结果，没有追加导入（append）。
final class ImportDecisionController: NSObject {

    /// 导入里消失的受保护课程：用户对单门课的决定。
    enum ProtectedRemovalDecision: Equatable {
        case keep
        case delete
        case cancel
    }

    /// 覆盖导入前的判断：哪些事必须让用户看见。
    ///
    /// 抽成纯数据 + `assess`，是为了让「什么时候该弹窗」能被单元测试直接锁住，
    /// 而不是只能靠肉眼点 App。
    struct Assessment {
        let diff: TimetableDiff.Result
        let defaultChoice: TimetableDiff.MergeChoice
        let conflicts: [ImportConflictLogic.Unit]
        /// 当前受保护、但导入文件里没有的课。
        let protectedRemoved: [TimetableDiff.CourseDiff]
        /// 受保护的匹配课有内容差异（默认「保留当前」，不会改到它）。
        ///
        /// 这个标记只用于诊断：默认合并不会动这门课，所以它本身不构成弹窗理由。
        /// 真正需要用户看的是「时间冲突」和「匹配关系不唯一」。
        let hasProtectedMatchedChanges: Bool
        /// 匹配关系不唯一，必须让用户确认。
        let hasAmbiguous: Bool

        /// 需要打开差异合并页。
        ///
        /// 只有两类：
        ///   · 导入内容和当前保留的课真的撞时间 → 必须逐条决定留哪边；
        ///   · 匹配关系不唯一（同名不同 code / 多组候选）→ 不猜。
        ///
        /// 普通新增 / 更新、受保护课程被导入版本「更新」（默认仍保留当前）、
        /// 课程在导入里消失（默认保留当前）都不弹页。
        var needsDiff: Bool {
            !conflicts.isEmpty || hasAmbiguous
        }

        /// 导入里消失的受保护课：无论有没有冲突，都要逐门问清楚。
        var needsProtectedRemovalPrompt: Bool {
            !protectedRemoved.isEmpty
        }
    }

    /// 三选一的结果。
    enum Decision: Equatable {
        /// 新建课表（名称）。
        case newTimetable(name: String)
        /// 覆盖当前课表。
        case overwriteCurrent
        /// 取消。
        case cancel
    }

    // MARK: - 依赖

    private let store: TimetableStore
    /// 解析 + 分组后的课程（courseID 已分配）。
    private let parsed: [Course]
    /// 导入文件的名字（用来做默认课表名）。
    private let fileName: String
    /// 当前课表（可能为空 / 不存在）。
    private var current: Timetable?

    /// 决策结果回调。
    var onDecision: ((Decision) -> Void)?

    // MARK: - 自检钩子（都可注入，测试里不弹模态框）

    /// 替换「导入里消失的保护课」的逐门询问。
    ///
    /// 参数是（课名、第几门、共几门）；`nil` = 走真的模态弹窗。
    var testProtectedRemovalDecision: ((_ name: String, _ index: Int, _ total: Int)
                                       -> ProtectedRemovalDecision)?

    /// 替换写盘动作（用来模拟写盘失败）。
    var testSaveHandler: ((Timetable) throws -> Void)?

    /// 捕获错误提示（代替弹 NSAlert）。
    var testErrorHandler: ((String) -> Void)?
    /// 差异合并页（覆盖且有冲突 / 需要确认时弹出）。
    ///
    /// `current` 是**刚 load 出来的当前课表**（不是 AppDelegate 里可能过时的副本）；
    /// `imported` 是补齐 courseID 之后的那一份 —— 与 `diff` 用的是同一个数组。
    /// `importedSemester` 是**可选**的：导入格式（教务系统 .xls / 课程 JSON 数组）
    /// 都不含开学日期和总周数，所以正常情况下是 `nil` ——
    /// 差异页不会出现「开学日期 / 总周数」两行，学期一律保留当前。
    /// 保留这个参数是为了以后真有带学期信息的导入格式时不用再改签名。
    /// `initialChoice` 带上了用户刚对「消失的保护课」做的保留 / 删除决定，
    /// 差异页不能再用默认值把它覆盖回来。
    ///
    /// `onApply` 返回写盘结果：差异页只在 `.success` 时关窗。
    var onShowDiff: ((_ current: [Course],
                      _ diff: TimetableDiff.Result,
                      _ imported: [Course],
                      _ importedSemester: SemesterConfig?,
                      _ initialChoice: TimetableDiff.MergeChoice,
                      _ onApply: @escaping ([Course], SemesterConfig) -> ImportApplyOutcome,
                      _ onCancel: @escaping () -> Void) -> Void)?

    init(store: TimetableStore,
         parsed: [Course],
         fileName: String) {
        self.store = store
        self.parsed = parsed
        self.fileName = fileName
        super.init()
    }

    // MARK: - 入口

    /// 读当前课表**和它的加载诊断**。
    ///
    /// 以前是 `store.activeID.flatMap { try? store.load($0) }` —— 诊断全丢了，
    /// 于是「文件损坏」和「课表本来就是空的」在界面上长得一模一样，
    /// 导入会直接覆盖掉用户的坏文件。
    @discardableResult
    private func loadCurrent() -> ScheduleRepository.LoadResult? {
        var loadResult: ScheduleRepository.LoadResult?
        current = store.activeID.flatMap { id in
            guard let detailed = try? store.loadDetailed(id) else { return nil }
            loadResult = detailed.result
            return detailed.timetable
        }
        return loadResult
    }

    /// 走一遍导入决策流程。
    func start() {
        let loadResult = loadCurrent()

        // 没有课表，或当前课表是空的 → 直接导入
        guard let cur = current, !cur.courses.isEmpty else {
            // **当前课表「读不出内容」和「本来就是空的」要分开**：
            // 读不出内容说明文件坏了，直接写进去等于把用户的数据覆盖掉。
            if let res = loadResult, res.error != nil {
                presentCorruptThenDecide(res)
                return
            }
            applyAsCurrentTimetable()
            return
        }

        // 三选一 → **可选择的选项行**，不再用三个系统按钮。
        // 顺序不变：覆盖当前课表（推荐）在前，新建独立课表在后，取消是底部按钮。
        let outcome = AlertDialogController.show(
            Self.decisionRequest(name: cur.name,
                                 courseCount: cur.courseCount,
                                 loadError: loadResult?.error))

        switch outcome {
        case .chosen(0):
            startOverwrite()
        case .chosen(1):
            askNameThenCreate()
        default:
            onDecision?(.cancel)
        }
    }

    /// 当前课表的数据读不出来（文件损坏）→ 先告诉用户，再让他决定。
    ///
    /// 不能默默走「空课表 → 直接导入」那条路 —— 那会把用户的原始数据覆盖掉。
    private func presentCorruptThenDecide(_ res: ScheduleRepository.LoadResult) {
        // 覆盖是**破坏性**操作 → 红色危险样式，默认焦点给「取消」，
        // Return 不会顺手覆盖掉用户的原始数据。
        let outcome = AlertDialogController.show(.init(
            severity: .destructive,
            title: "当前课表的数据读不出来",
            message: (res.error ?? "数据损坏")
                + "\n\n继续导入会**覆盖**当前课表的内容（原文件会先备份到 backups/）。"
                + "\n建议先取消，检查一下文件，或新建一份课表。",
            confirmTitle: "仍然覆盖",
            cancelTitle: "取消"))
        switch outcome {
        case .confirmed:
            applyAsCurrentTimetable()
        default:
            onDecision?(.cancel)
        }
    }

    // MARK: - 直接导入（当前课表为空 / 没有课表）

    /// 当前课表为空 → 直接写进当前课表；没有课表 → 建一份新的。
    private func applyAsCurrentTimetable() {
        let courses = freshCourseIDs(parsed)
        do {
            if let cur = current {
                // 当前课表存在但是空的 → 直接写进去
                var t = cur
                t.courses = courses
                try store.save(t)
                try store.setActive(t.id)
            } else {
                let t = try store.create(name: defaultName(), subtitle: "",
                                         courses: courses)
                try store.setActive(t.id)
            }
            onDecision?(.overwriteCurrent)
        } catch {
            presentError("导入失败：\(error.localizedDescription)")
            // 失败也要收尾：否则 AppDelegate 一直持着这次的 `importDecision`，
            // 下一次导入会被「上一次导入还没结束」拦住。
            onDecision?(.cancel)
        }
    }

    // MARK: - 新建课表

    private func askNameThenCreate() {
        // 输入新表名 → 复用 `TimetableNameDialog`（自建 HUD 输入窗）。
        let result = TimetableNameDialog.run(
            title: "新建一份独立课表",
            message: "导入结果会作为一份新课表保存，当前课表不受影响。",
            name: defaultName(),
            subtitle: "",
            confirmTitle: "创建",
            showsSubtitle: false)

        guard let result else {
            onDecision?(.cancel)
            return
        }
        var name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = defaultName() }
        name = uniqueName(name)

        let courses = freshCourseIDs(parsed)
        do {
            let t = try store.create(name: name, subtitle: "", courses: courses)
            try store.setActive(t.id)
            onDecision?(.newTimetable(name: name))
        } catch {
            presentError("新建课表失败：\(error.localizedDescription)")
            // 同样要收尾（见 applyAsCurrentTimetable 里的注释）
            onDecision?(.cancel)
        }
    }

    /// 默认课表名：文件名去掉扩展名。
    private func defaultName() -> String {
        let base = (fileName as NSString).deletingPathExtension
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "导入的课表" : trimmed
    }

    /// 重名自动加后缀（统一规则在 `TimetableStore.uniqueName`）。
    func uniqueName(_ name: String) -> String {
        store.uniqueName(name)
    }

    /// 新课表用**全新 courseID**（不复用旧课的 ID）。
    private func freshCourseIDs(_ courses: [Course]) -> [Course] {
        var out: [Course] = []
        var map: [String: String] = [:]
        for c in courses {
            let oldID = c.courseID
            let newID: String
            if let existing = map[oldID] {
                newID = existing
            } else {
                newID = UUID().uuidString
                map[oldID] = newID
            }
            var r = c
            r.courseID = newID
            out.append(r)
        }
        return out
    }

    // MARK: - 「已有课表」三选一的文案

    /// 「当前已经有课表了」这张弹窗的请求（**唯一真源**）。
    ///
    /// 抽出来是为了两件事：
    ///   1. `--shot-alert-dialog x import` 出图和真机用**同一份文案**，不会各写一套；
    ///   2. 文案要能被单独审阅。
    ///
    /// 文案原则（2026-11-09 用户反馈「这种警告的文字叙述太多了，删减一点，
    /// 让它变得更简约美观」）：
    ///   · 标题说**发生了什么**，正文只说**现在有多少门课**；
    ///   · 两个选项的 `detail` 各一句话，**不要**再把同一段说明抄一遍到正文里
    ///     （以前正文有一段「· 覆盖…（推荐）：… / · 新建… / · 取消…」的三行清单，
    ///      和下面两张选项卡的 `detail` 完全重复，读起来又长又乱）。
    ///
    /// 顺序不变：覆盖当前课表（推荐）在前，新建独立课表在后，取消是底部按钮。
    static func decisionRequest(name: String,
                                courseCount: Int,
                                loadError: String?) -> AlertDialogRequest {
        // 部分记录读不出来时，课程数是「能读到的」，不是文件里实际有多少。
        // 必须说清楚：否则用户会以为当前课表只有这么几门课，
        // 覆盖之后才发现坏记录已经被替换掉了（原文件虽有备份，但不该靠用户猜）。
        let message: String
        if let loadError {
            message = "「\(name)」能读到 \(courseCount) 门课，但加载时有问题：\n"
                + loadError + "\n\n覆盖前会自动备份原文件。"
        } else {
            message = "「\(name)」里已有 \(courseCount) 门课。"
        }
        return AlertDialogRequest(
            severity: loadError == nil ? .info : .warning,
            title: "当前已经有课表了",
            message: message,
            options: [
                AlertDialogOption(
                    title: "覆盖当前课表",
                    detail: "用导入结果更新当前课表，冲突时再问你",
                    accessibilityLabel: "覆盖当前课表，用导入结果更新当前课表"),
                AlertDialogOption(
                    title: "新建一份独立课表…",
                    detail: "另存一份，当前课表不动",
                    accessibilityLabel: "新建一份独立课表，保留当前课表，导入结果另存一份"),
            ],
            showsConfirm: false,
            showsCancel: true)
    }

    // MARK: - 覆盖当前课表

    /// 覆盖当前课表，但**只在需要注意时打扰用户**。
    ///
    /// 判断顺序：
    ///   1. 导入里少了受保护的课 → 先逐门问保留还是删除（无论有没有冲突）；
    ///   2. 有时间冲突 / 匹配关系不唯一 → 差异合并页逐条决定；
    ///   3. 其余情况（包括导入内容和当前完全一样）→ 直接按默认规则覆盖，不弹窗。
    ///
    /// 以前只要不是完全一样就弹差异页；用户点「覆盖」后看到一页密密麻麻的差异，
    /// 很容易直接关掉。现在普通的新增 / 更新不再打扰，真正有风险的才停下来问。
    ///
    /// 不是 `private` 是为了让自检能跳过三选一弹窗、**走同一条分支**；
    /// 生产路径只有 `start()` 里那一处调用。
    func startOverwrite() {
        // `start()` 会先把当前课表 load 进来；自检直接调这个方法时还没 load 过。
        if current == nil { loadCurrent() }
        guard let cur = current else {
            applyAsCurrentTimetable()
            return
        }

        // ---- 5.1 统一数据源 ----
        // 导入结果的 courseID：先把空 courseID 补齐，**同一个数组**同时用于
        // compare、传给差异页、传给 merge。以前 compare 用的是补过的数组、
        // `onShowDiff` 传的是原始 `parsed`，两边可能不是同一组 ID ——
        // 差异页按 A 算出的选择作用到 B 上，冲突检测和合并结果就对不上。
        let imported = parsed.map { c -> Course in
            var r = c
            if r.courseID.isEmpty { r.courseID = UUID().uuidString }
            // 导入进来的记录一律是「导入来源、没被用户改过」。
            // （解析器本来就给这个默认值，这里显式写一遍，避免以后改默认值时漏掉。）
            r.origin = .imported
            r.userModified = false
            return r
        }

        let initial = Self.assess(current: cur.courses,
                                  imported: imported,
                                  currentSemester: cur.semester)

        // 导入里少了受保护的课 → 逐门问清楚，绝不替用户决定。
        //
        // **先问再决定要不要弹差异页**：用户选「删除」后，原本由这门课
        // 引起的冲突会消失，这时就不该再打开一页冲突。
        var choice = initial.defaultChoice
        if initial.needsProtectedRemovalPrompt {
            guard let resolved = resolveProtectedRemovals(initial.protectedRemoved,
                                                          startingFrom: choice) else {
                onDecision?(.cancel)
                return
            }
            choice = resolved
        }

        // 用户可能删掉了保护课 → 用最终选择重新算一次冲突。
        let final = Self.assess(current: cur.courses,
                                imported: imported,
                                currentSemester: cur.semester,
                                choice: choice)

        // 有冲突 / 需要确认 → 差异合并页（用户在这里逐条决定）。
        // 把刚才对「消失的保护课」的选择带进去，避免差异页又按默认值把它保留回来。
        if final.needsDiff {
            presentDiffWindow(cur: cur, imported: imported,
                              diff: final.diff, initialChoice: choice)
            return
        }

        // 没有需要注意的事 → 直接覆盖。写盘结果必须接住（见 `applyAutomatically`）。
        applyAutomatically(cur: cur, imported: imported,
                           diff: final.diff, choice: choice)
    }

    /// 算出「这次覆盖需不需要弹窗」以及默认合并选择。
    ///
    /// `importedSemester` 固定是 `nil`：导入格式（教务系统 .xls / 课程 JSON 数组）
    /// 只描述课程，没有开学日期和总周数。以前拿 `cur.semester` 跟自己比，
    /// 学期差异恒为 false，是自比较死代码。
    ///
    /// - Parameter choice: 用户在逐门确认「消失的保护课」之后的选择；
    ///   传 `nil` 时用默认合并选择（用于第一次判断）。
    static func assess(current: [Course], imported: [Course],
                       currentSemester: SemesterConfig,
                       choice: TimetableDiff.MergeChoice? = nil) -> Assessment {
        let diff = TimetableDiff.compare(current: current,
                                         imported: imported,
                                         currentSemester: currentSemester,
                                         importedSemester: nil)
        let choice = choice ?? TimetableDiff.defaultMergeChoice(for: diff)
        let conflicts = ImportConflictLogic.detect(current: current,
                                                   result: diff,
                                                   choice: choice)
        let protectedRemoved = diff.removed.filter { d in
            d.currentSessions.contains(where: { $0.isProtected })
        }
        let hasProtectedMatchedChanges = diff.matched.contains { d in
            d.hasDifference && d.currentSessions.contains(where: { $0.isProtected })
        }
        return Assessment(diff: diff,
                          defaultChoice: choice,
                          conflicts: conflicts,
                          protectedRemoved: protectedRemoved,
                          hasProtectedMatchedChanges: hasProtectedMatchedChanges,
                          hasAmbiguous: !diff.ambiguous.isEmpty)
    }

    /// 逐门询问「导入里没有这门受保护的课，要留还是删？」。
    ///
    /// - Returns: 用户全部决定后的选择；用户在任意一门上取消 → `nil`。
    private func resolveProtectedRemovals(_ removals: [TimetableDiff.CourseDiff],
                                          startingFrom initial: TimetableDiff.MergeChoice)
        -> TimetableDiff.MergeChoice? {
        var choice = initial
        for (index, d) in removals.enumerated() {
            let decision: ProtectedRemovalDecision
            if let hook = testProtectedRemovalDecision {
                decision = hook(d.name, index, removals.count)
            } else {
                decision = promptProtectedRemoval(d, index: index, total: removals.count)
            }
            switch decision {
            case .keep:
                choice.courses[d.courseID] = .keepCurrent
            case .delete:
                choice.courses[d.courseID] = .delete
            case .cancel:
                return nil
            }
        }
        return choice
    }

    private func promptProtectedRemoval(_ d: TimetableDiff.CourseDiff,
                                        index: Int, total: Int) -> ProtectedRemovalDecision {
        let source = d.currentSessions.first(where: { $0.isProtected })?.originLabel
            ?? "受保护课程"
        // 课程卡片：取当前课表里这门课的一条记录（受保护的那条优先）。
        let session = d.currentSessions.first(where: { $0.isProtected })
            ?? d.currentSessions.first
        var rows: [AlertDialogRow] = []
        if let session {
            rows.append(.courseSummary(session, badge: "受保护"))
        }
        // 三个决定：保留（默认，Return）/ 删除（红色危险）/ 取消导入（次要，Esc）。
        //
        // 顺序按「取消在左、主操作在右」的统一规则：
        //   取消导入（次要）→ 删除（红色危险）→ 保留（主操作）
        //
        // 「保留」是主操作（Return）：它是**不改数据**的那条路，
        // 危险的是「删除」，所以红色给删除，Return 给保留。
        let request = AlertDialogRequest(
            severity: .warning,
            title: "导入文件里没有「\(d.name)」",
            message: "这门课是「\(source)」，覆盖导入不会自动删掉它。",
            rows: rows,
            // 计数条：始终显示（「第 i 门 / 共 n 门」）。
            counter: "第 \(index + 1) 门 / 共 \(total) 门",
            // 警告图标是琥珀的，但「保留」是安全的默认操作 ——
            // 按 macOS 惯例（黄图标 + 蓝默认按钮），主按钮用蓝色，
            // 免得两个按钮都看着像在报警。
            primaryColor: DialogStyle.color(.question),
            buttons: [
                AlertDialogButton(role: .cancel, title: "取消导入",
                                  accessibilityLabel: "取消导入，当前课表完全不动"),
                AlertDialogButton(role: .destructive, title: "删除",
                                  accessibilityLabel: "删除这门课，这次覆盖会移除它"),
                AlertDialogButton(role: .primary, title: "保留",
                                  accessibilityLabel: "保留这门课，继续导入，这门课留在当前课表里"),
            ])
        let outcome = AlertDialogController.show(request)
        switch outcome {
        case .confirmed:
            // 「保留」是主操作。
            return .keep
        case .destructive:
            return .delete
        default:
            return .cancel
        }
    }

    private func presentDiffWindow(cur: Timetable, imported: [Course],
                                   diff: TimetableDiff.Result,
                                   initialChoice: TimetableDiff.MergeChoice) {
        // 导入文件没有学期信息 → 传 nil，差异页不会出现学期两行，学期保留当前。
        onShowDiff?(cur.courses, diff, imported, nil, initialChoice,
                    { [weak self] courses, semester in
                        guard let self else {
                            // 控制器已经不在了 = 上层没持有它（历史 bug）。给差异页一个
                            // 明确的失败结果，让它弹「保存失败」而不是静默关窗。
                            assertionFailure("ImportDecisionController 在应用时已经释放：上层必须强持有它")
                            return .failure("导入流程已经结束（内部状态已释放），请重新导入")
                        }
                        return self.overwrite(cur: cur, courses: courses, semester: semester)
                    }, { [weak self] in
                        self?.onDecision?(.cancel)
                    })
    }

    /// 没有需要用户决定的事 → 按默认选择合并并写盘。
    ///
    /// 失败时一定要 `onDecision(.cancel)` 收尾：否则 `importDecision` 一直挂在
    /// AppDelegate 上，下一次导入会被「上一次导入还没结束」拦住。
    private func applyAutomatically(cur: Timetable, imported: [Course],
                                    diff: TimetableDiff.Result,
                                    choice: TimetableDiff.MergeChoice) {
        let plan = ImportConflictLogic.plan(current: cur.courses,
                                            imported: imported,
                                            result: diff,
                                            choice: choice)
        guard plan.canApply else {
            presentError("导入内容无法应用：\(plan.blocker ?? "未知原因")")
            onDecision?(.cancel)
            return
        }

        // 写盘结果**必须接住**：以前这里写的是 `_ = overwrite(...)`，
        // 失败被直接丢掉 —— 不弹「保存失败」、不调 `onDecision`，流程卡死。
        switch overwrite(cur: cur, courses: plan.courses, semester: plan.semester) {
        case .success:
            break
        case .failure(let reason):
            presentError(reason)
            onDecision?(.cancel)
        }
    }

    /// 覆盖写盘（写盘前自动备份由 TimetableStore 负责）。
    ///
    /// 返回结果而不是自己弹框：失败时差异页必须留在原地（保留用户的逐条选择）。
    @discardableResult
    private func overwrite(cur: Timetable, courses: [Course],
                           semester: SemesterConfig) -> ImportApplyOutcome {
        do {
            var t = cur
            t.courses = courses
            t.semester = semester
            if let hook = testSaveHandler {
                try hook(t)
            } else {
                try store.save(t)
            }
            try store.setActive(t.id)
            onDecision?(.overwriteCurrent)
            return .success
        } catch {
            return .failure("覆盖失败：\(error.localizedDescription)")
        }
    }

    /// 只负责把错误告诉用户。
    ///
    /// **不在这里调 `onDecision(.cancel)`**：所有调用点自己会收尾。
    /// 以前这里也调一次，调用点又调一次 —— 生产路径上同一次失败会收到两次 cancel。
    private func presentError(_ message: String) {
        if let hook = testErrorHandler {
            hook(message)
            return
        }
        AlertDialogController.show(.init(
            severity: .warning,
            title: "导入出错",
            message: message,
            confirmTitle: "好",
            showsCancel: false))
    }
}

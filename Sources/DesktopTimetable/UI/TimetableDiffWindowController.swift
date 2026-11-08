import AppKit

/// 差异合并页（独立窗口）。
///
/// 覆盖当前课表时，如果当前课表和导入结果有差异，就到这里逐项选
/// 「保留当前 / 用导入」。
///
/// 设计要点：
///   · 独立窗口，不是一行 NSAlert —— 差异可能十几条，塞不进 alert。
///   · 默认选择按「防误删」原则：已有课程默认保留当前，导入新增默认用导入，
///     导入消失默认保留当前，学期字段默认保留当前。
///   · 底部「取消」绝不写盘。
///   · 点「应用」前再次校验（day/block 合法、weeks 非空且在 1...maxWeek、冲突检测）。
final class TimetableDiffWindowController: NSObject, NSWindowDelegate {

    // MARK: - 结果

    /// 用户点「应用」时回调（合并后的课程 + 学期）。
    ///
    /// **返回值决定窗口关不关**：只有写盘成功才 `orderOut`；
    /// 失败时返回 `.failure(原因)`，窗口留在原地让用户重试 ——
    /// 以前是「先关窗再保存」，保存失败时用户连差异页都丢了。
    var onApply: ((_ courses: [Course], _ semester: SemesterConfig) -> ImportApplyOutcome)?
    /// 用户点「取消」（或点了红叉）。
    var onCancel: (() -> Void)?
    /// 流程真的结束了（应用成功 / 取消 / 关窗）—— 上层用它清空强引用。
    var onFinished: (() -> Void)?

    // MARK: - 数据

    private let current: [Course]
    private let imported: [Course]
    private let diff: TimetableDiff.Result
    private var choice: TimetableDiff.MergeChoice
    /// 导入学期（导入文件不含学期信息时为 nil —— 见 `TimetableDiff.Result.importedSemester`）。
    private let importedSemester: SemesterConfig?
    /// 当前选择算出来的合并计划（含冲突、阻塞原因）。每次 `refresh()` 重算。
    private(set) var plan = ImportConflictLogic.Plan()

    /// 差异行（课程级 + 上课时间级）。
    private struct Row {
        let diff: TimetableDiff.CourseDiff
        let kind: Kind
        enum Kind { case matched, added, removed, ambiguous }
    }
    private var rows: [Row] = []

    // MARK: - UI

    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var stack: NSStackView!
    private var summaryLabel: NSTextField!
    private var bulkBar: NSStackView!
    private var applyBtn: NSButton!
    /// 应用按钮不能点时的原因（有未决定的冲突 / 会丢保护课 / 数据不合法）。
    private var blockerLabel: NSTextField!

    init(current: [Course],
         imported: [Course],
         diff: TimetableDiff.Result,
         importedSemester: SemesterConfig?,
         initialChoice: TimetableDiff.MergeChoice? = nil) {
        self.current = current
        self.imported = imported
        self.diff = diff
        self.importedSemester = importedSemester
        // 导入决策控制器可能已经逐门问过「消失的保护课」；
        // 直接把那些选择带进来，别在差异页里又按默认值改回「保留当前」。
        self.choice = initialChoice ?? TimetableDiff.defaultMergeChoice(for: diff)
        super.init()
        buildRows()
    }

    private func buildRows() {
        rows = []
        for d in diff.matched where d.hasDifference { rows.append(Row(diff: d, kind: .matched)) }
        for d in diff.added { rows.append(Row(diff: d, kind: .added)) }
        for d in diff.removed { rows.append(Row(diff: d, kind: .removed)) }
    }

    // MARK: - 展示

    func show() {
        if window == nil { buildWindow() }
        refresh()
        // 差异页必须**拿到 key** —— 否则「应用」按钮点不动
        // （用户报的就是这个：覆盖导入时点「应用」没反应）。
        //
        // 激活是异步的，而且 accessory app 抢前台不一定一次成功，
        // 所以这里要重试到真的拿到 key 为止。
        activateAndTakeKey()
    }

    /// 激活 app 并让差异页拿到 key window。
    ///
    /// 跟设置面板那边同一个道理：
    ///  - 激活是异步的，`NSApp.activate` 之后要等事件循环转一圈；
    ///  - app 没真正激活时 `makeKeyAndOrderFront` 拿不到 key；
    ///  - accessory app 抢前台不一定一次成功（实测 8 次里失败 2 次）。
    ///
    /// 所以重试到真的拿到 key 为止 —— 否则「应用」按钮会像「点不动」。
    ///
    /// ⚠️ 重试**必须在窗口已经关掉之后停下来**：
    /// 每次重试都会调 `makeKeyAndOrderFront` —— 差异页被关掉之后，
    /// 还在排队的重试会**把它重新弹出来**。用户看到的就是「我点了应用，
    /// 窗口关了，过一秒又自己冒出来」。所以这里用 `activationToken` 计数，
    /// 关窗时 +1，作废所有在途的重试。
    private var activationToken = 0

    private func activateAndTakeKey(budget: TimeInterval = 10) {
        guard let w = window else { return }
        activationToken += 1
        let token = activationToken
        // 真正的重试逻辑在 WindowActivation.swift —— 设置面板和差异页共用一份。
        activateWindowAndTakeKey(w, token: token, currentToken: { [weak self] in
            self?.activationToken ?? token
        }, budget: budget)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "合并课表差异"
        w.delegate = self
        w.isReleasedWhenClosed = false
        // 与设置面板同层：这两个窗是从设置面板里点出来的，必须压在面板上面
        w.level = .floating
        w.minSize = NSSize(width: 640, height: 460)
        // 摆在**课表窗口当前中心**（以前是屏幕正中间，课表拖走后弹窗离得很远）
        HUDWindow.centerOnScreen(w)
        window = w

        let root = NSView(frame: w.contentView!.bounds)
        w.contentView = root

        // ---- 顶部摘要 ----
        summaryLabel = NSTextField(labelWithString: diff.summary)
        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.textColor = NSColor.labelColor
        root.addSubview(summaryLabel)

        // ---- 批量操作 ----
        bulkBar = NSStackView()
        bulkBar.orientation = .horizontal
        bulkBar.spacing = 8
        root.addSubview(bulkBar)

        let keepAll = NSButton(title: "全部保留当前", target: self, action: #selector(keepAllTapped))
        let useAll = NSButton(title: "全部用导入", target: self, action: #selector(useAllTapped))
        let keepBothAll = NSButton(title: "全部两边都留", target: self, action: #selector(keepBothAllTapped))
        bulkBar.addArrangedSubview(keepAll)
        bulkBar.addArrangedSubview(useAll)
        bulkBar.addArrangedSubview(keepBothAll)

        // ---- 差异列表 ----
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        scrollView.documentView = stack

        // ---- 底部按钮 ----
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        root.addSubview(footer)

        // 应用按钮不能点时的原因（有未决定的冲突 / 会丢保护课）
        blockerLabel = NSTextField(labelWithString: "")
        blockerLabel.font = .systemFont(ofSize: 11)
        blockerLabel.textColor = NSColor.systemOrange
        blockerLabel.lineBreakMode = .byTruncatingTail
        blockerLabel.maximumNumberOfLines = 1
        root.addSubview(blockerLabel)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        let apply = NSButton(title: "应用", target: self, action: #selector(applyTapped))
        apply.keyEquivalent = "\r"
        applyBtn = apply
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(cancelBtn)
        footer.addArrangedSubview(apply)

        // ---- 布局 ----
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        bulkBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        blockerLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            summaryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            summaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            bulkBar.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 12),
            bulkBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: bulkBar.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: blockerLabel.topAnchor, constant: -8),

            blockerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            blockerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            blockerLabel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    /// 重建差异列表（每次选择变化后刷新受影响的行）。
    private func refresh() {
        guard let stack else { return }
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }

        // ---- 学期两行 ----
        // 导入文件不含学期信息时 `diff.importedSemester` 是 nil，
        // 这两行不会出现（没有可比的东西就别显示）。
        if let imp = diff.importedSemester, diff.semesterStartChanged {
            stack.addArrangedSubview(makeSemesterRow(
                title: "开学日期",
                currentText: Self.dateText(diff.currentSemester.start),
                importedText: Self.dateText(imp.start),
                current: choice.semesterStart == .keepCurrent,
                setCurrent: { self.choice.semesterStart = .keepCurrent; self.refresh() },
                setImported: { self.choice.semesterStart = .useImported; self.refresh() }))
        }
        if let imp = diff.importedSemester, diff.semesterMaxWeekChanged {
            stack.addArrangedSubview(makeSemesterRow(
                title: "总周数",
                currentText: "\(diff.currentSemester.maxWeek)",
                importedText: "\(imp.maxWeek)",
                current: choice.semesterMaxWeek == .keepCurrent,
                setCurrent: { self.choice.semesterMaxWeek = .keepCurrent; self.refresh() },
                setImported: { self.choice.semesterMaxWeek = .useImported; self.refresh() }))
        }

        // ---- 需要确认的 ----
        if !diff.ambiguous.isEmpty {
            let warn = NSTextField(labelWithString:
                "以下课程匹配到多组或课名相同但代码不同，需要你确认（默认「保留当前」）：")
            warn.font = .systemFont(ofSize: 12)
            warn.textColor = NSColor.systemOrange
            stack.addArrangedSubview(warn)
            for d in diff.ambiguous {
                stack.addArrangedSubview(makeCourseRow(d, kind: .ambiguous))
            }
        }

        // ---- 课程差异 ----
        for row in rows {
            stack.addArrangedSubview(makeCourseRow(row.diff, kind: row.kind))
        }

        // ---- 时间冲突（导入的课 vs 你保留的课）----
        // 计算计划放在显示之前：冲突列表、摘要、能否应用都来自同一份计划，
        // 避免「界面说没冲突、实际合并出冲突」。
        plan = ImportConflictLogic.plan(current: current, imported: imported,
                                        result: diff, choice: choice)

        if !plan.conflicts.isEmpty {
            let head = NSTextField(labelWithString:
                "时间冲突 —— 逐条决定留哪一个（不选不能应用）：")
            head.font = .systemFont(ofSize: 12, weight: .semibold)
            head.textColor = NSColor.systemOrange
            stack.addArrangedSubview(head)
            for unit in plan.conflicts {
                stack.addArrangedSubview(makeConflictRow(unit))
            }
        }

        summaryLabel.stringValue = plan.summary
        let canApply = plan.canApply
        applyBtn?.isEnabled = canApply
        blockerLabel.stringValue = plan.blocker ?? ""
        blockerLabel.isHidden = (plan.blocker == nil)
    }

    /// 一条冲突：导入的课 / 你的课 / 三个单选项。
    private func makeConflictRow(_ unit: ImportConflictLogic.Unit) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3

        let title = NSTextField(labelWithString:
            "「\(unit.importedName)」与「\(unit.currentName)」在同一时间")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        container.addArrangedSubview(title)

        container.addArrangedSubview(makeValueLabel(
            "导入的课：", text: "\(unit.importedName) · \(unit.timeText)"))
        container.addArrangedSubview(makeValueLabel(
            "你的课：", text: "\(unit.currentName)（\(unit.currentOriginLabel)）· \(unit.timeText)"))

        // 周次说明（每个时段一行）
        for slot in unit.slots {
            container.addArrangedSubview(makeValueLabel("周次：", text: slot.weeksText))
        }

        // 说明按钮作用在**哪几周**上 —— 界面已经写了「重叠 1-8」，
        // 如果行为是「整条上课时间删掉」，用户会以为 9-16 周也没了。
        // 现在行为就是按周让开，所以把这句话写出来，别让用户猜。
        let hint = NSTextField(labelWithString: "「保留当前 / 用导入」只调整上面标出的重叠周次，其余周次不动")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        container.addArrangedSubview(hint)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let picked = choice.resolution(for: unit.id)
        for res in [TimetableDiff.ConflictResolution.keepCurrent,
                    .useImported, .keepBoth] {
            buttons.addArrangedSubview(makeChoiceButton(res.label, selected: picked == res) {
                self.choice.conflicts[unit.id] = res
                self.refresh()
            })
        }
        container.addArrangedSubview(buttons)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        // 先入容器再激活约束（顺序反了会抛 no common ancestor，见 makeCourseRow 里的注释）
        container.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    // MARK: - 行构造

    /// 学期差异行：「保留当前 / 用导入」两个按钮。
    private func makeSemesterRow(title: String, currentText: String, importedText: String,
                                 current: Bool,
                                 setCurrent: @escaping () -> Void,
                                 setImported: @escaping () -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline

        let label = NSTextField(labelWithString: "\(title)：")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(label)

        let curLabel = NSTextField(labelWithString: "当前 \(currentText)")
        curLabel.textColor = NSColor.secondaryLabelColor
        row.addArrangedSubview(curLabel)

        let impLabel = NSTextField(labelWithString: "导入 \(importedText)")
        impLabel.textColor = NSColor.secondaryLabelColor
        row.addArrangedSubview(impLabel)

        row.addArrangedSubview(makeChoiceButton("保留当前", selected: current, action: setCurrent))
        row.addArrangedSubview(makeChoiceButton("用导入", selected: !current, action: setImported))
        return row
    }

    /// 课程差异行。
    private func makeCourseRow(_ d: TimetableDiff.CourseDiff,
                               kind: Row.Kind) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        // ---- 课名 + 来源 ----
        let name = NSTextField(labelWithString: d.name.isEmpty ? "（未命名）" : d.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        container.addArrangedSubview(name)

        // 来源标签：这一行讲的是**当前课表**里那门课，所以取当前侧记录的来源。
        // 「导入 / 你新增 / 你修改过 / 旧数据（来源未知）」—— 用户一眼看出哪门课是自己的。
        if let cur = d.currentSessions.first {
            let origin = NSTextField(labelWithString: "来源：" + cur.originLabel)
            origin.font = .systemFont(ofSize: 11)
            origin.textColor = cur.isProtected ? NSColor.systemOrange : NSColor.secondaryLabelColor
            container.addArrangedSubview(origin)

            // 受保护的课：说清楚「用导入」到底授权了什么。
            //
            // 用户点「用导入」= **这一次**用导入的内容；
            // 但「这门课是我加的 / 我改过的」这个标记**留着** ——
            // 下次导入它仍然是受保护的课，默认还是「保留当前」，要覆盖得再点一次。
            // 不说清楚的话，用户会以为点了「用导入」就等于「以后都归导入管」。
            if cur.isProtected {
                let hint = NSTextField(labelWithString: "选「用导入」只影响这一次；这门课仍受保护，下次导入会再问你一次")
                hint.font = .systemFont(ofSize: 11)
                hint.textColor = .secondaryLabelColor
                container.addArrangedSubview(hint)
            }
        }

        // ---- 当前 / 导入 两行 ----
        switch kind {
        case .matched, .ambiguous:
            container.addArrangedSubview(makeValueLabel("当前：", text: Self.describe(d.currentSessions)))
            container.addArrangedSubview(makeValueLabel("导入：", text: Self.describe(d.importedSessions)))
        case .added:
            container.addArrangedSubview(makeValueLabel("导入新增：", text: Self.describe(d.importedSessions)))
        case .removed:
            container.addArrangedSubview(makeValueLabel("当前有、导入里没有：", text: Self.describe(d.currentSessions)))
        }

        // ---- 选择按钮 ----
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        switch kind {
        case .matched:
            let cur = choice.choice(for: d.courseID) == .keepCurrent
            buttons.addArrangedSubview(makeChoiceButton("保留当前", selected: cur) {
                self.choice.courses[d.courseID] = .keepCurrent; self.refresh()
            })
            buttons.addArrangedSubview(makeChoiceButton("用导入", selected: !cur) {
                self.choice.courses[d.courseID] = .useImported; self.refresh()
            })
        case .ambiguous:
            // 「需要确认」的课：默认保留当前，也可以换成导入版本，或明确删掉。
            //
            // 以前这一行用的是 `.matched` 的两个按钮，但 `merge` 根本不读 ambiguous ——
            // 「用导入」是空操作；而这门课同时还出现在「当前有、导入里没有」那一栏里，
            // 用户在那里选「删除」就会**整门课消失**（旧的删了，新的没进来）。
            // 现在 ambiguous 有自己的 courseID（当前候选的），三个选项都有明确归属。
            let c = choice.choice(for: d.courseID)
            buttons.addArrangedSubview(makeChoiceButton("保留当前", selected: c == .keepCurrent) {
                self.choice.courses[d.courseID] = .keepCurrent; self.refresh()
            })
            buttons.addArrangedSubview(makeChoiceButton("用导入", selected: c == .useImported) {
                self.choice.courses[d.courseID] = .useImported; self.refresh()
            })
            buttons.addArrangedSubview(makeChoiceButton("删除", selected: c == .delete) {
                self.choice.courses[d.courseID] = .delete; self.refresh()
            })
        case .added:
            let useIt = choice.choice(for: d.courseID) == .useImported
            buttons.addArrangedSubview(makeChoiceButton("用导入", selected: useIt) {
                self.choice.courses[d.courseID] = .useImported; self.refresh()
            })
            buttons.addArrangedSubview(makeChoiceButton("跳过", selected: !useIt) {
                self.choice.courses[d.courseID] = .skip; self.refresh()
            })
        case .removed:
            let keep = choice.choice(for: d.courseID) == .keepCurrent
            buttons.addArrangedSubview(makeChoiceButton("保留当前", selected: keep) {
                self.choice.courses[d.courseID] = .keepCurrent; self.refresh()
            })
            buttons.addArrangedSubview(makeChoiceButton("删除", selected: !keep) {
                self.choice.courses[d.courseID] = .delete; self.refresh()
            })
        }
        container.addArrangedSubview(buttons)

        // ---- 分隔线 ----
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        // 顺序不能反：先 addArrangedSubview 再激活约束。
        // 反过来的话两个视图还没有共同祖先，AppKit 直接抛
        // 「Unable to activate constraint ... no common ancestor」——
        // 差异页一打开就崩，而且只在真的进差异页时才炸。
        container.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        return container
    }

    private func makeValueLabel(_ prefix: String, text: String) -> NSTextField {
        let f = NSTextField(labelWithString: prefix + text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 3
        return f
    }

    /// 「保留当前 / 用导入」这类二选一按钮（用 radio 表现）。
    ///
    /// 回调存在 `choiceActions` 表里，按钮用 tag 取。
    private var choiceActions: [Int: () -> Void] = [:]
    private var nextChoiceTag = 1

    private func makeChoiceButton(_ title: String, selected: Bool,
                                  action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(choiceTapped(_:)))
        b.setButtonType(.radio)
        b.state = selected ? .on : .off
        let tag = nextChoiceTag
        nextChoiceTag += 1
        b.tag = tag
        choiceActions[tag] = action
        return b
    }

    @objc private func choiceTapped(_ sender: NSButton) {
        guard let action = choiceActions[sender.tag] else { return }
        action()
    }

    // MARK: - 动作

    @objc private func keepAllTapped() {
        for d in diff.matched { choice.courses[d.courseID] = .keepCurrent }
        for d in diff.added { choice.courses[d.courseID] = .skip }
        for d in diff.removed { choice.courses[d.courseID] = .keepCurrent }
        // 「需要确认」的课也归到「保留当前」——
        // 以前这两类（ambiguous / removed）都能把课弄丢，现在每个都有明确归属。
        for d in diff.ambiguous { choice.courses[d.courseID] = .keepCurrent }
        choice.semesterStart = .keepCurrent
        choice.semesterMaxWeek = .keepCurrent
        // 冲突也一起归到「保留当前」（只由用户点击触发，打开页面时不自动套用）。
        for unit in plan.conflicts { choice.conflicts[unit.id] = .keepCurrent }
        refresh()
    }

    @objc private func useAllTapped() {
        for d in diff.matched { choice.courses[d.courseID] = .useImported }
        for d in diff.added { choice.courses[d.courseID] = .useImported }
        for d in diff.removed { choice.courses[d.courseID] = .delete }
        // ambiguous 也必须包含在「全用导入」里，否则这批课会被 `removed` 的删除选中吞掉，
        // 而导入版本又没进来 → 整门课消失。
        for d in diff.ambiguous { choice.courses[d.courseID] = .useImported }
        choice.semesterStart = .useImported
        choice.semesterMaxWeek = .useImported
        for unit in plan.conflicts { choice.conflicts[unit.id] = .useImported }
        refresh()
    }

    /// 全部两边都留：只解决冲突，不动课程级选择。
    @objc private func keepBothAllTapped() {
        for unit in plan.conflicts { choice.conflicts[unit.id] = .keepBoth }
        refresh()
    }

    @objc private func cancelTapped() {
        finish(apply: false)
    }

    /// 关窗的唯一出口：先让上层决定是否写盘，成功才关。
    ///
    /// `withExtendedLifetime` 是必须的：`onFinished` 里上层会把自己对这个控制器的
    /// 强引用清掉，而这里/`applyTapped`/`windowShouldClose` 还在 self 上跑 ——
    /// 不显式续命就会在回调返回途中被释放（AppKit 的 target 是 unowned 的）。
    private func finish(apply: Bool) {
        // 作废在途的激活重试 —— 否则重试会把刚关掉的差异页**重新弹出来**。
        activationToken += 1
        withExtendedLifetime(self) {
            window.orderOut(nil)
            if !apply { onCancel?() }
            choiceActions.removeAll()
            onFinished?()
        }
    }

    @objc private func applyTapped() {
        // 兜底：界面上按钮已置灰，但 ⌘↩ / 键盘回车仍可能触发 action。
        guard plan.canApply else {
            if let reason = plan.blocker { presentInvalid(reason) }
            return
        }

        // 保存结果决定关不关窗。
        //
        // 以前是「先 orderOut 再 onApply」—— 写盘失败时用户手里只剩一个关掉的窗口，
        // 差异页里逐条选择全丢。现在失败会弹原因并保留页面，可以直接改完重试。
        let outcome = onApply?(plan.courses, plan.semester)
            ?? .failure("导入流程已经结束（回调被释放），请重新导入")

        switch outcome {
        case .success:
            finish(apply: true)
        case .failure(let reason):
            presentSaveFailed(reason)
        }
    }

    private func presentInvalid(_ message: String) {
        AlertDialogController.show(.init(
            severity: .warning,
            title: "数据不合法，无法应用",
            message: message,
            confirmTitle: "好",
            showsCancel: false))
    }

    private func presentSaveFailed(_ message: String) {
        AlertDialogController.show(.init(
            severity: .warning,
            title: "保存失败",
            message: message + "\n\n差异页没有关闭，可以改完再点「应用」。",
            confirmTitle: "好",
            showsCancel: false))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 用户点红叉 = 取消（不写盘），走同一条收尾路径
        withExtendedLifetime(self) {
            onCancel?()
            choiceActions.removeAll()
            onFinished?()
        }
        return true
    }

    // MARK: - 自检钩子

    var testIsVisible: Bool { window?.isVisible ?? false }
    var testWindow: NSWindow? { window }
    var testPlan: ImportConflictLogic.Plan { plan }
    var testApplyEnabled: Bool { applyBtn?.isEnabled ?? false }
    var testBlockerText: String { blockerLabel?.stringValue ?? "" }
    var testOriginLabels: [String] { rows.compactMap { $0.diff.currentSessions.first?.originLabel } }
    var testSummary: String { summaryLabel?.stringValue ?? "" }
    var testConflictCount: Int { plan.conflicts.count }
    var testUnresolvedCount: Int { plan.unresolved.count }

    /// 自检用：替用户点一个冲突选项。
    func testResolve(conflictID: String, _ resolution: TimetableDiff.ConflictResolution) {
        choice.conflicts[conflictID] = resolution
        refresh()
    }

    /// 自检用：点「应用」（走和真按钮完全相同的代码路径）。
    func testApply() { applyTapped() }

    /// 自检用：点「取消」。
    func testCancel() { cancelTapped() }

    /// 自检用：真点一下「应用」按钮（走真实事件分发，不是直接调 action）。
    ///
    /// 直接调 `applyTapped()` 只能证明「回调连着」，证明不了「用户点得到」——
    /// 而用户报的现象正是「点了没反应」。所以这里构造真的鼠标按下/抬起事件，
    /// 送进窗口让 AppKit 做命中测试，验证点击真的落到了按钮上。
    ///
    /// - Returns: 点击是否被按钮接收（按钮从不可点变成可点状态 / action 被触发）。
    @discardableResult
    func testRealClickApply() -> Bool {
        guard let btn = applyBtn, let win = window else { return false }
        let point = btn.convert(btn.bounds.origin, to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                            modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: win.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                          modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil,
                                          eventNumber: 2, clickCount: 1, pressure: 0)
        else { return false }
        win.sendEvent(down)
        win.sendEvent(up)
        return true
    }

    // MARK: - 文案

    /// 把一组上课时间描述成一行文字。
    static func describe(_ sessions: [Course]) -> String {
        if sessions.isEmpty { return "—" }
        return sessions.map { s in
            let day = Schedule.dayNames[max(0, min(6, s.day - 1))]
            let times = "\(s.block * 2 + 1)-\(s.block * 2 + 2)节"
            var parts = ["\(day) \(times)"]
            if !s.teacher.isEmpty { parts.append("教师 \(s.teacher)") }
            if !s.loc.isEmpty { parts.append("地点 \(s.loc)") }
            parts.append("周次 \(s.weeksLabel.isEmpty ? s.weeks.map(String.init).joined(separator: ",") : s.weeksLabel)")
            return parts.joined(separator: "；")
        }.joined(separator: " / ")
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

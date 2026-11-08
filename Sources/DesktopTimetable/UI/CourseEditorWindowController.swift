import AppKit

/// 右键编辑器的窗口控制器。
///
/// 普通可激活窗口（不是桌面卡片里的网页输入框）：
/// 打开时 `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront`，
/// 这样 Cmd+C / Cmd+V / Cmd+Z 走标准文本编辑链路。
///
/// 字段分两组：
///   · 课程级：课名（必填）、课程代码（可空）—— 固定在上方，不随滚动走；
///   · 上课时间级：每个「时段 N」一张卡片（星期 / 节次 / 教师 / 地点 / 周次），
///     放在中间的滚动区里，可以复制、删除。
///
/// 保存时统一走 `onSubmitBatch`：所有时段一次校验、一次写盘。
/// `onSubmit` 只留给「编辑单周临时覆盖」那条老路径。
final class CourseEditorWindowController: NSObject, NSWindowDelegate {

    /// 编辑器的用途。
    enum Mode: Equatable {
        /// 新增一门课。
        case create
        /// 编辑课程（课程级字段同步到同 courseID 的所有记录）。
        case edit(courseID: String, day: Int, block: Int)
        /// 添加一个上课时间（课程级字段只读，新增一条记录，复用 courseID）。
        case addSession(courseID: String)
        /// 编辑一条**单周临时覆盖**（星期节次锁定 —— 换格子请删掉重加）。
        case editOverride
    }

    /// 单时段提交（临时覆盖用）。
    var onSubmit: ((CourseDraft) -> Void)?
    /// 多时段提交（新增 / 编辑 / 添加上课时间用）。
    var onSubmitBatch: ((CourseEditBatch) -> Void)?
    /// 编辑已有课程时，删掉最后一个时段 = 删掉整门课；返回是否删成功。
    var onDeleteAll: (() -> Bool)?
    /// 取消。
    var onCancel: (() -> Void)?

    private let mode: Mode
    private let maxWeek: Int
    private let initialCourseDraft: CourseDraft
    private let initialSessions: [CourseSessionDraft]
    private var primaryIndex: Int
    private var window: NSWindow!

    /// 关掉编辑器（保存成功后调用）。
    func close() {
        window?.close()
    }

    /// 自检用：编辑器窗口（用来验它的位置是不是以课表中心为锚点）。
    var testWindow: NSWindow? { window }

    // 课程级
    private var nameField: NSTextField!
    private var codeField: NSTextField!
    /// 课程级颜色选择器（「临时覆盖」模式没有这一行）。
    private var colorPicker: CourseColorPickerView?
    private var courseSection: NSStackView!
    // 时段
    private var slotViews: [CourseSessionSlotView] = []
    /// 用户在表单里明确删掉的旧时段（保存时从磁盘上删掉）。
    private var deletedIdentities: [CourseSessionIdentity] = []
    private var contentStack: NSStackView!
    private var scrollView: NSScrollView!
    // 底部
    private var errorLabel: NSTextField!
    private var saveButton: NSButton!

    private var didConfigure = false
    private var didCancel = false

    private static let panelWidth: CGFloat = 460
    private static let panelHeight: CGFloat = 520
    private static let scrollerGutter: CGFloat = 16

    // MARK: - 构造

    /// 多时段初始化器。
    ///
    /// - Parameters:
    ///   - courseDraft: 课程级字段（课名 / 代码）。时段字段以 `sessions` 为准。
    ///   - sessions: 要显示的全部时段；`original == nil` 表示新时段。
    ///   - primary: 用户点中的那条记录，决定 `currentDraft()` 返回哪一段。
    init(mode: Mode,
         courseDraft: CourseDraft,
         sessions: [CourseSessionDraft],
         primary: CourseSessionIdentity?,
         maxWeek: Int) {
        self.mode = mode
        self.maxWeek = maxWeek
        self.initialCourseDraft = courseDraft
        let list = sessions.isEmpty
            ? [CourseSessionDraft(original: nil, draft: courseDraft)]
            : sessions
        self.initialSessions = list
        if let primary,
           let i = list.firstIndex(where: { $0.original == primary }) {
            self.primaryIndex = i
        } else {
            self.primaryIndex = 0
        }
        super.init()
    }

    /// 旧版单时段初始化器。保留给 `--show-editor`、布局测试和临时覆盖编辑器。
    convenience init(mode: Mode, draft: CourseDraft, maxWeek: Int) {
        let original: CourseSessionIdentity?
        switch mode {
        case .edit(let courseID, let day, let block):
            original = CourseSessionIdentity(courseID: courseID, day: day, block: block)
        case .create, .addSession, .editOverride:
            original = nil
        }
        self.init(mode: mode,
                  courseDraft: draft,
                  sessions: [CourseSessionDraft(original: original, draft: draft)],
                  primary: original,
                  maxWeek: maxWeek)
    }

    // MARK: - 显示

    func show() {
        if window == nil { buildWindow() }
        configureIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nameField)
    }

    private var showsSlotActions: Bool {
        if case .editOverride = mode { return false }
        return true
    }

    /// 颜色行：新增 / 编辑 / 添加上课时间都显示；临时覆盖不显示
    /// （覆盖的颜色跟着原课走，保存时保留原值）。
    private var showsColorRow: Bool {
        if case .editOverride = mode { return false }
        return true
    }

    /// 要不要把新时段标成「新增」。
    ///
    /// 编辑 / 添加上课时间时本来就有旧记录，新加的那行必须一眼能认出来；
    /// 新增课程时每一行都是新的，全标反而是噪音；临时覆盖不涉及增删。
    private var marksNewSlots: Bool {
        switch mode {
        case .edit, .addSession: return true
        case .create, .editOverride: return false
        }
    }

    private var locksDayBlock: Bool {
        if case .editOverride = mode { return true }
        return false
    }

    private func buildWindow() {
        window = HUDWindow.make(title: titleText,
                                size: NSSize(width: Self.panelWidth, height: Self.panelHeight))
        window.delegate = self

        let root = HUDWindow.installContent(in: window, root: NSView())
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            root.heightAnchor.constraint(equalToConstant: Self.panelHeight),
        ])

        // 标题：避开左上角红绿灯。
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        // ---- 课程级（固定在上方）----
        courseSection = EditorFormStyle.makeSection(title: "课程")
        nameField = EditorFormStyle.makeField(placeholder: "例如：数据结构")
        codeField = EditorFormStyle.makeField(placeholder: "可空，例如：CS201")
        let nameRow = EditorFormStyle.makeRow(key: "课名", field: nameField, required: true)
        let codeRow = EditorFormStyle.makeRow(key: "代码", field: codeField, required: false)
        courseSection.addArrangedSubview(nameRow)
        courseSection.addArrangedSubview(codeRow)

        // 颜色行（课程级）：新增 / 编辑 / 添加上课时间都有，「临时覆盖」没有。
        var colorRow: NSView? = nil
        if showsColorRow {
            let picker = CourseColorPickerView()
            picker.setSelected(initialCourseDraft.colorHex)
            // 和别的输入框一致：一改动就清掉上次的错误提示。
            picker.onChange = { [weak self] in self?.clearError() }
            colorPicker = picker
            let row = EditorFormStyle.makeRow(key: "颜色", field: picker, required: false)
            colorRow = row
            courseSection.addArrangedSubview(row)
        }

        root.addSubview(courseSection)
        var courseConstraints: [NSLayoutConstraint] = [
            courseSection.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            courseSection.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            nameRow.widthAnchor.constraint(equalTo: courseSection.widthAnchor),
            codeRow.widthAnchor.constraint(equalTo: courseSection.widthAnchor),
        ]
        if let colorRow {
            courseConstraints.append(colorRow.widthAnchor.constraint(equalTo: courseSection.widthAnchor))
        }
        NSLayoutConstraint.activate(courseConstraints)

        // ---- 中间：时段滚动区 ----
        let scroll = NSScrollView()
        scrollView = scroll
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let stack = NSStackView()
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        // ---- 底部：错误提示 + 按钮（固定，不滚）----
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.textColor = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        saveButton = save

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        // .fill + 低抱紧度空隙：取消/保存贴右边，和参考图一致。
        buttons.distribution = .fill
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [errorLabel, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            courseSection.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: courseSection.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            // overlay 滚动条浮在内容上：文档视图窄一条沟，滚动条不压字段。
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -Self.scrollerGutter),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            errorLabel.widthAnchor.constraint(equalTo: footer.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: footer.widthAnchor),
        ])
    }

    private var titleText: String {
        switch mode {
        case .create: return "新增课程"
        case .edit: return "编辑课程"
        case .addSession: return "添加上课时间（末尾新增一行）"
        case .editOverride: return "编辑临时覆盖"
        }
    }

    // MARK: - 初始值

    private func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        nameField.stringValue = initialCourseDraft.name
        codeField.stringValue = initialCourseDraft.code

        // 添加上课时间：课程级字段只读（沿用已有课程）
        if case .addSession = mode {
            nameField.isEditable = false
            codeField.isEditable = false
            nameField.textColor = .secondaryLabelColor
            codeField.textColor = .secondaryLabelColor
        }

        for session in initialSessions {
            addSlot(configuredWith: session.draft, identity: session.original, at: slotViews.count)
        }
        primaryIndex = min(max(0, primaryIndex), max(0, slotViews.count - 1))
        renumber()
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
        scrollView?.documentView?.layoutSubtreeIfNeeded()

        // 添加上课时间：新加的那行在最后，直接滚过去让它露出来。
        // 已有时间多的时候，不滚的话用户只会看到原来的几行，
        // 很容易以为「什么都没加」，点保存才发现多了一节课。
        if case .addSession = mode, let last = slotViews.last {
            last.scrollToVisible(last.bounds)
        }
    }

    // MARK: - 测试用

    /// 测试用：编辑器窗口是否已成为 key window、首响应是不是课名输入框。
    var isKeyAndFocused: Bool {
        guard let window else { return false }
        return window.isKeyWindow && isNameFieldFocused
    }

    /// 测试用：首响应是不是课名输入框（不看 key 状态）。
    var hasNameFieldFocus: Bool { isNameFieldFocused }

    /// 测试用：编辑器窗口的详细状态（排查焦点问题）。
    var testWindowState: String {
        guard let window else { return "no-window" }
        let resp = window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        return "visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) "
            + "responder=\(resp) appActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)"
    }

    /// 测试用：只建窗口、不显示，量布局用。
    func testPrepareLayout() {
        if window == nil { buildWindow() }
        configureIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
        scrollView?.documentView?.layoutSubtreeIfNeeded()
    }

    /// 测试用：保存按钮在内容坐标系里的位置（判断有没有被挤出窗口）。
    var testSaveButtonFrame: NSRect? {
        guard let content = window?.contentView else { return nil }
        return saveButton.convert(saveButton.bounds, to: content)
    }

    /// 测试用：内容区域的高度。
    var testContentHeight: CGFloat {
        window?.contentView?.bounds.height ?? 0
    }

    /// 测试用：时段区域撑起来的高度（Auto Layout 算出来的）。
    var testRequiredHeight: CGFloat {
        contentStack?.fittingSize.height ?? 0
    }

    /// 测试用：时段数量。
    var testSlotCount: Int { slotViews.count }

    /// 测试用：每个时段的标题。
    var testSlotTitles: [String] { slotViews.map(\.indexTitle) }

    /// 测试用：每个时段对应的旧记录（nil = 新时段）。
    var testSlotIdentities: [CourseSessionIdentity?] { slotViews.map(\.identity) }

    /// 测试用：每个时段是否显示「复制 / 删除」。
    var testSlotActionsVisible: [Bool] { slotViews.map(\.actionsVisible) }

    /// 测试用：每个时段是不是被标成了「新增」。
    var testSlotMarkedNew: [Bool] { slotViews.map(\.isMarkedNew) }

    /// 测试用：最后一个时段现在是否在滚动区可视范围内。
    var testLastSlotVisible: Bool {
        guard let last = slotViews.last, let scroll = scrollView else { return false }
        let rect = last.convert(last.bounds, to: scroll.contentView)
        return scroll.contentView.bounds.intersects(rect)
    }

    /// 测试用：滚动区文档高度。
    var testDocumentHeight: CGFloat {
        scrollView?.documentView?.frame.height ?? 0
    }

    /// 测试用：滚动区可视高度。
    var testViewportHeight: CGFloat {
        scrollView?.contentView.bounds.height ?? 0
    }

    /// 测试用：内容是否超过可视区域（需要滚动）。
    var testScrolls: Bool {
        testDocumentHeight > testViewportHeight + 0.5
    }

    /// 测试用：最后一个时段的删除确认。设了这个就不再弹真确认窗。
    var testConfirmLastSlotDelete: (() -> Bool)?

    /// 测试用：点某一段的「复制」。
    func testCopySlot(at index: Int) {
        copySlot(at: index)
    }

    /// 测试用：点某一段的「删除」。
    func testDeleteSlot(at index: Int) {
        deleteSlot(at: index)
    }

    /// 测试用：直接改某一段的字段。
    func testSetSlot(at index: Int, day: Int, block: Int,
                     teacher: String, loc: String, weeks: [Int]) {
        guard slotViews.indices.contains(index) else { return }
        slotViews[index].testSet(day: day, block: block,
                                 teacher: teacher, loc: loc, weeks: weeks)
    }

    /// 测试用：当前表单对应的批量提交内容。
    var testBatch: CourseEditBatch { currentBatch() }

    // MARK: - 测试钩子（颜色）

    /// 颜色行在不在（「临时覆盖」模式应该没有）。
    var testColorRowVisible: Bool { colorPicker != nil }

    /// 颜色选择器本身。
    var testColorPicker: CourseColorPickerView? { colorPicker }

    /// 颜色行的宽度（应该等于课程级区域的宽度，不能撑破窗口）。
    var testColorRowWidth: CGFloat {
        guard let picker = colorPicker else { return 0 }
        picker.layoutSubtreeIfNeeded()
        return picker.bounds.width
    }

    /// 点某个颜色选项（0 = 自动）。
    func testSelectColorOption(at index: Int) {
        colorPicker?.testSelectOption(at: index)
    }

    /// 测试用：首响应是不是这个课名输入框（或它的 field editor）。
    var isNameFieldFocused: Bool {
        guard let window else { return false }
        if window.firstResponder === nameField { return true }
        // AppKit 会把 NSTextField 的焦点交给它内部的 NSTextView（field editor）
        if let tv = window.firstResponder as? NSTextView, tv.delegate === nameField {
            return true
        }
        return false
    }

    /// 测试用：模拟输入（走 NSTextField 的正常编辑链路）。
    func testSetName(_ text: String) {
        nameField.stringValue = text
    }

    /// 测试用：点「保存」。
    func testSave() {
        saveTapped()
    }

    // MARK: - 收集

    private func currentCourseName() -> String { nameField?.stringValue ?? initialCourseDraft.name }
    private func currentCourseCode() -> String { codeField?.stringValue ?? initialCourseDraft.code }

    /// 当前草稿（主时段）。LiveTestHarness 和旧测试靠它核对预填。
    ///
    /// 颜色是**课程级**字段，不属于任何单个时段卡 —— 统一在最后补上，
    /// 免得「复制时段」「切主时段」把颜色带走或带丢。
    func currentDraft() -> CourseDraft {
        let name = currentCourseName()
        let code = currentCourseCode()
        var d: CourseDraft
        if slotViews.indices.contains(primaryIndex) {
            d = slotViews[primaryIndex].currentDraft(courseName: name, code: code)
        } else if let first = slotViews.first {
            d = first.currentDraft(courseName: name, code: code)
        } else {
            d = initialCourseDraft
            d.name = name
            d.code = code
        }
        d.colorHex = selectedColorHex()
        return d
    }

    /// 当前表单的批量内容。
    func currentBatch() -> CourseEditBatch {
        let name = currentCourseName()
        let code = currentCourseCode()
        return CourseEditBatch(name: name,
                               code: code,
                               colorHex: selectedColorHex(),
                               sessions: slotViews.map {
                                   $0.sessionDraft(courseName: name, code: code)
                               },
                               deleted: deletedIdentities)
    }

    /// 课程级颜色：有选择器就读它，没有（「临时覆盖」模式）就沿用原值。
    /// 读不到颜色不该让保存失败 —— 退回 `nil`（自动）。
    private func selectedColorHex() -> String? {
        guard let colorPicker else { return initialCourseDraft.colorHex }
        return colorPicker.selectedHex
    }

    /// 显示一条错误提示（不关窗）。
    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func clearError() {
        guard errorLabel != nil, !errorLabel.isHidden else { return }
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - 复制 / 删除

    private func addSlot(configuredWith draft: CourseDraft,
                         identity: CourseSessionIdentity?,
                         at index: Int) {
        let slot = CourseSessionSlotView(maxWeek: maxWeek,
                                         showsActions: showsSlotActions,
                                         locksDayBlock: locksDayBlock)
        slot.configure(with: draft, identity: identity)
        wire(slot)
        slotViews.insert(slot, at: index)
        contentStack.insertArrangedSubview(slot, at: index)
        slot.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        slot.setIndex(index + 1)
        // 有旧记录的编辑器里，新加的行用绿色徽标 + 描边标出来。
        slot.setMarkedNew(marksNewSlots && identity == nil)
    }

    private func wire(_ slot: CourseSessionSlotView) {
        slot.onCopy = { [weak self, weak slot] in
            guard let self, let slot,
                  let i = self.slotViews.firstIndex(where: { $0 === slot }) else { return }
            self.copySlot(at: i)
        }
        slot.onDelete = { [weak self, weak slot] in
            guard let self, let slot,
                  let i = self.slotViews.firstIndex(where: { $0 === slot }) else { return }
            self.deleteSlot(at: i)
        }
        slot.onChange = { [weak self] in self?.clearError() }
    }

    private func copySlot(at index: Int) {
        guard slotViews.indices.contains(index) else { return }
        let source = slotViews[index]
        let draft = source.currentDraft(courseName: currentCourseName(),
                                        code: currentCourseCode())
        addSlot(configuredWith: draft, identity: nil, at: index + 1)
        if index < primaryIndex { primaryIndex += 1 }
        renumber()
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
        if slotViews.indices.contains(index + 1) {
            let newSlot = slotViews[index + 1]
            newSlot.scrollToVisible(newSlot.bounds)
        }
    }

    private func deleteSlot(at index: Int) {
        guard slotViews.indices.contains(index) else { return }

        // 只剩一个：先确认。编辑已有课程 = 删整门课；新增/添加 = 放弃本次编辑。
        if slotViews.count == 1 {
            guard confirmLastSlotDelete() else { return }
            if case .edit = mode, let onDeleteAll {
                _ = onDeleteAll()
                return
            }
            notifyCancel()
            window.close()
            return
        }

        let slot = slotViews[index]
        if let id = slot.identity {
            deletedIdentities.append(id)
        }
        slotViews.remove(at: index)
        contentStack.removeArrangedSubview(slot)
        slot.removeFromSuperview()

        if index < primaryIndex {
            primaryIndex -= 1
        } else if index == primaryIndex {
            primaryIndex = min(index, slotViews.count - 1)
        }
        primaryIndex = min(max(0, primaryIndex), slotViews.count - 1)
        renumber()
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
    }

    private func renumber() {
        for (i, slot) in slotViews.enumerated() {
            slot.setIndex(i + 1)
        }
    }

    private func confirmLastSlotDelete() -> Bool {
        if let testConfirmLastSlotDelete { return testConfirmLastSlotDelete() }

        let isEditingCourse: Bool
        if case .edit = mode { isEditingCourse = true } else { isEditingCourse = false }
        let name = currentCourseName().trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if isEditingCourse {
            message = "「\(name.isEmpty ? "这门课" : name)」只剩这一个上课时间。"
                + "\n删除后整门课会从课表里消失。"
        } else {
            message = "这是当前编辑里唯一的上课时间。"
                + "\n继续会放弃这次编辑，不保存任何内容。"
        }
        let dialog = ConfirmDialogController(request: .init(
            title: "删除最后一个上课时间？",
            message: message,
            confirmTitle: "删除",
            severity: .destructive))
        return dialog.run() == .confirm
    }

    // MARK: - 按钮

    @objc private func cancelTapped() {
        notifyCancel()
        window.close()
    }

    @objc private func saveTapped() {
        if let onSubmitBatch {
            onSubmitBatch(currentBatch())
        } else {
            onSubmit?(currentDraft())
        }
    }

    private func notifyCancel() {
        guard !didCancel else { return }
        didCancel = true
        onCancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        notifyCancel()
        return true
    }
}

import AppKit

// MARK: - 表单样式

/// 课程编辑器里共用的小控件样式（字段、行、分段标题、inline 按钮）。
///
/// 行宽不再写死 350：编辑器里多个时段各自占满滚动区宽度，
/// 由调用方给「行」加宽度约束，字段自己拉伸。
enum EditorFormStyle {

    static let keyWidth: CGFloat = 52
    static let rowSpacing: CGFloat = 10

    static func makeSection(title: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func makeField(placeholder: String) -> NSTextField {
        let f = NSTextField(string: "")
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 13)
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.drawsBackground = true
        f.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
        f.textColor = .white
        f.translatesAutoresizingMaskIntoConstraints = false
        f.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return f
    }

    /// 「键 + 控件」一行。控件拉伸填满剩余宽度；行自身宽度由调用方约束。
    static func makeRow(key: String, field: NSView, required: Bool) -> NSView {
        let k = NSTextField(labelWithString: key + (required ? " *" : ""))
        k.font = .systemFont(ofSize: 12)
        k.textColor = .secondaryLabelColor
        k.translatesAutoresizingMaskIntoConstraints = false
        k.widthAnchor.constraint(equalToConstant: keyWidth).isActive = true
        k.alignment = .right

        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let row = NSStackView(views: [k, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func makeInlineButton(title: String,
                                 tint: NSColor,
                                 target: AnyObject?,
                                 action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = .systemFont(ofSize: 11)
        b.contentTintColor = tint
        b.setButtonType(.momentaryPushIn)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

// MARK: - 一个时段

/// 编辑器里的一个「时段 N」卡片。
///
/// 负责这一行时段自己的五个字段（星期 / 节次 / 教师 / 地点 / 周次）和
/// 右上角的「复制 / 删除」。课程名 / 代码是课程级字段，不在这里。
final class CourseSessionSlotView: NSView, NSTextFieldDelegate {

    /// 点「复制」：调用方在下面插入一个一样的时段。
    var onCopy: (() -> Void)?
    /// 点「删除」：调用方决定直接删还是先确认。
    var onDelete: (() -> Void)?
    /// 任一字段变了（用来清掉编辑器里的旧错误提示）。
    var onChange: (() -> Void)?

    /// 这个时段对应的旧记录；nil = 新时段（新增 / 复制 / 添加）。
    private(set) var identity: CourseSessionIdentity?

    /// 这一行是不是「还没保存的新增时段」。
    ///
    /// 只有本来就有旧记录的编辑器才会标（编辑 / 添加上课时间）。
    /// 新增课程时每一行都是新的，全标「新增」反而是噪音，所以不标。
    private(set) var isMarkedNew = false

    private let maxWeek: Int
    private let showsActions: Bool
    private let locksDayBlock: Bool

    private let titleLabel = NSTextField(labelWithString: "")
    private let newBadgeLabel = NSTextField(labelWithString: "新增")
    private lazy var newBadge: NSView = makeNewBadge()
    private lazy var copyButton = EditorFormStyle.makeInlineButton(
        title: "复制", tint: .secondaryLabelColor, target: self, action: #selector(copyTapped))
    private lazy var deleteButton = EditorFormStyle.makeInlineButton(
        title: "删除", tint: .systemRed, target: self, action: #selector(deleteTapped))

    private let dayPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let blockPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let teacherField = EditorFormStyle.makeField(placeholder: "可空")
    private let locField = EditorFormStyle.makeField(placeholder: "可空")
    private let weekPicker = WeekRangePicker()
    private let weeksPreview = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    init(maxWeek: Int, showsActions: Bool, locksDayBlock: Bool) {
        self.maxWeek = maxWeek
        self.showsActions = showsActions
        self.locksDayBlock = locksDayBlock
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    // MARK: - 对外

    var actionsVisible: Bool { !copyButton.isHidden }
    var indexTitle: String { titleLabel.stringValue }

    /// 标记/取消「新增时段」的视觉提示：绿色「新增」徽标 + 绿色描边 + 淡绿底。
    ///
    /// 以前新加的一行和已有行完全一样，保存后多了一节课都不容易发现。
    func setMarkedNew(_ marked: Bool) {
        isMarkedNew = marked
        newBadge.isHidden = !marked
        layer?.borderWidth = marked ? 1 : 0
        layer?.borderColor = marked
            ? TimetablePalette.UI.green.withAlphaComponent(0.45).cgColor
            : nil
        layer?.backgroundColor = (marked
            ? TimetablePalette.UI.green.withAlphaComponent(0.07)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.045)).cgColor
    }

    func setIndex(_ index: Int) {
        titleLabel.stringValue = "时段 \(index)"
    }

    func configure(with draft: CourseDraft, identity: CourseSessionIdentity?) {
        self.identity = identity
        if let item = dayPop.item(at: draft.day - 1) {
            dayPop.select(item)
        }
        if Course.blockRange.contains(draft.block), draft.block < blockPop.numberOfItems {
            blockPop.selectItem(at: draft.block)
        }
        teacherField.stringValue = draft.teacher
        locField.stringValue = draft.loc
        weekPicker.weeks = draft.weeks
        updateWeeksPreview()
    }

    func sessionDraft(courseName: String, code: String) -> CourseSessionDraft {
        CourseSessionDraft(original: identity,
                           draft: currentDraft(courseName: courseName, code: code))
    }

    func currentDraft(courseName: String, code: String) -> CourseDraft {
        var d = CourseDraft()
        d.name = courseName
        d.code = code
        d.teacher = teacherField.stringValue
        d.loc = locField.stringValue
        d.day = dayPop.selectedItem?.tag ?? 1
        d.block = blockPop.selectedItem?.tag ?? 0
        d.weeks = weekPicker.weeks
        return d
    }

    // MARK: - 测试钩子

    func testSet(day: Int, block: Int, teacher: String, loc: String, weeks: [Int]) {
        if let item = dayPop.item(at: day - 1) { dayPop.select(item) }
        if Course.blockRange.contains(block), block < blockPop.numberOfItems {
            blockPop.selectItem(at: block)
        }
        teacherField.stringValue = teacher
        locField.stringValue = loc
        weekPicker.weeks = weeks
        updateWeeksPreview()
    }

    // MARK: - 构建

    /// 圆角「新增」小徽标：绿色文字 + 低透明度绿底。
    private func makeNewBadge() -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = TimetablePalette.UI.green
            .withAlphaComponent(0.16).cgColor
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        newBadgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        newBadgeLabel.textColor = TimetablePalette.UI.green
        newBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(newBadgeLabel)
        NSLayoutConstraint.activate([
            newBadgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            newBadgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            newBadgeLabel.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            newBadgeLabel.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
        ])
        return badge
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.045).cgColor
        layer?.cornerRadius = 9

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        for (i, d) in Schedule.dayNames.enumerated() {
            dayPop.addItem(withTitle: d)
            dayPop.lastItem?.tag = i + 1
        }
        for b in 0...TimetableState.maxBlock {
            blockPop.addItem(withTitle: "\(Schedule.timeRange(block: b))（第 \(b * 2 + 1)–\(b * 2 + 2) 节）")
            blockPop.lastItem?.tag = b
        }
        dayPop.target = self
        dayPop.action = #selector(fieldChanged)
        blockPop.target = self
        blockPop.action = #selector(fieldChanged)
        dayPop.isEnabled = !locksDayBlock
        blockPop.isEnabled = !locksDayBlock

        teacherField.delegate = self
        locField.delegate = self

        weekPicker.maxWeek = maxWeek
        weekPicker.onChange = { [weak self] in
            self?.updateWeeksPreview()
            self?.onChange?()
        }

        weeksPreview.font = .systemFont(ofSize: 11)
        weeksPreview.textColor = .secondaryLabelColor
        weeksPreview.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true

        newBadge.isHidden = true

        let header = NSStackView(views: [titleLabel, newBadge, spacer, copyButton, deleteButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        // .fill：弹性空隙吃掉多余宽度，复制/删除才会贴在卡片最右边。
        header.distribution = .fill
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isHidden = !showsActions
        deleteButton.isHidden = !showsActions

        let weeksRow = EditorFormStyle.makeRow(key: "周次", field: weekPicker, required: true)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(EditorFormStyle.makeRow(key: "星期", field: dayPop, required: false))
        contentStack.addArrangedSubview(EditorFormStyle.makeRow(key: "节次", field: blockPop, required: false))
        contentStack.addArrangedSubview(EditorFormStyle.makeRow(key: "教师", field: teacherField, required: false))
        contentStack.addArrangedSubview(EditorFormStyle.makeRow(key: "地点", field: locField, required: false))
        contentStack.addArrangedSubview(weeksRow)
        contentStack.addArrangedSubview(weeksPreview)

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for view in contentStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    // MARK: - 动作

    @objc private func copyTapped() { onCopy?() }
    @objc private func deleteTapped() { onDelete?() }
    @objc private func fieldChanged() { onChange?() }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    // MARK: - 周次预览

    private func updateWeeksPreview() {
        let weeks = weekPicker.weeks
        if weeks.isEmpty {
            weeksPreview.stringValue = "请选择周次"
            weeksPreview.textColor = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
            return
        }
        if let over = weeks.filter({ $0 > maxWeek || $0 < 1 }).min() {
            weeksPreview.stringValue = "周次 \(over) 超出学期总周数（最多 \(maxWeek) 周）"
            weeksPreview.textColor = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
            return
        }
        weeksPreview.stringValue = CourseEdit.weeksPreview(weeks)
        weeksPreview.textColor = .secondaryLabelColor
    }
}

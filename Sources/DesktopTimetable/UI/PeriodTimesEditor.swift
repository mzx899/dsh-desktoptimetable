import AppKit

/// 「课程时间自定义」列表：10 节课的起止时间，内置滚动、就地编辑。
///
/// 只允许改**钟点**，节数固定 10 节 —— 网格行数 / 导入解析 / 提醒排程
/// 都绑定这个数量，增删节次会连带改版式，不能在这里做。
///
/// 输入方式是「时 / 分」两个小框：中间的冒号是固定标签，**不用输入**。
/// 每行四格：开始时时、开始分、结束时时、结束分。
///
/// 编辑规则：
///   · 时填 `8`、分填 `5` → 失焦后自动补成 `08:05`；分留空按 `00` 处理；
///   · 格式非法、开始不早于结束、与前后节次重叠 → 响一声并恢复原值；
///   · 合法修改立刻通过 `onCommit` 交给设置面板写盘。
final class PeriodTimesEditor: NSView, NSTextFieldDelegate {

    /// 合法修改后的整份作息（10 项）。
    var onCommit: (([PeriodTime]) -> Void)?

    /// 当前作息。从外部赋值会重建列表（保存后同步 / 恢复默认）。
    var times: [PeriodTime] {
        get { list }
        set {
            list = PeriodSettings.sanitize(newValue)
            rebuild()
        }
    }

    private var list: [PeriodTime] = PeriodSettings.defaults
    /// 注意：这里是**普通** NSScrollView，不是 `WheelForwardingScrollView`。
    /// 用户明确要的是「内置滚动窗口」—— 鼠标停在列表上时滚轮应该滚列表本身，
    /// 而不是把外层面板推走。滚到列表尽头后，AppKit 会照常把余下的滚轮
    /// 交给外层面板（嵌套滚动默认行为）。
    private let scroll = NSScrollView()
    private let document = PreviewDocumentView()
    private var rows: [PeriodTimeRowView] = []

    private static let rowHeight: CGFloat = 26
    private static let rowSpacing: CGFloat = 4
    /// 右边留一条沟给 overlay 滚动条（滚动条浮在内容上，不占位）。
    private static let gutter: CGFloat = 16

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        document.autoresizingMask = [.width]
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 行

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = list.enumerated().map { index, time in
            let row = PeriodTimeRowView(index: index, time: time, delegate: self)
            document.addSubview(row)
            return row
        }
        needsLayout = true
        layoutRows()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        let width = max(document.bounds.width - Self.gutter, 0)
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowSpacing
        }
        document.frame.size.height = max(y - Self.rowSpacing, 0)
    }

    // MARK: - 编辑

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let index = rows.firstIndex(where: { $0.contains(field) }) else { return }
        let row = rows[index]

        // 焦点在**同一行的四个输入框**之间移动（点一下 / Tab）时先不提交：
        // 改作息通常要同时动开始和结束，中间那一步几乎必然「开始晚于旧结束」，
        // 一提交就会被判非法、把刚输入的字弹回去。等离开这一行再一起校验。
        let movement = (obj.userInfo?["NSTextMovement"] as? Int)
            .flatMap(NSTextMovement.init(rawValue:))
        if movement != .return,
           let next = currentEditingField(),
           row.contains(next) {
            return
        }
        commit(row: index)
    }

    /// 当前正在编辑的输入框（字段编辑器的 delegate 就是 NSTextField 本身）。
    private func currentEditingField() -> NSTextField? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        return tv.delegate as? NSTextField
    }

    private func commit(row index: Int) {
        let row = rows[index]
        guard let start = row.startText, let end = row.endText else {
            NSSound.beep()
            syncFields()
            return
        }
        var candidate = list
        candidate[index] = PeriodTime(start: start, end: end)
        guard PeriodSettings.isValid(candidate) else {
            // 开始不早于结束 / 和上一节重叠 —— 一律拒绝，不能写出一份倒序作息。
            NSSound.beep()
            syncFields()
            return
        }
        list = candidate
        syncFields()
        onCommit?(list)
    }

    private func syncFields() {
        for (index, row) in rows.enumerated() where index < list.count {
            row.setText(start: list[index].start, end: list[index].end)
        }
    }

    // MARK: - 自检（`--verify-panel-sections` 用）

    /// 自检用：这个列表自己的滚动视图。
    var scrollViewForTest: NSScrollView { scroll }
    /// 自检用：按「编辑第 row 行、然后失焦」的路径提交一行（不经过键盘）。
    /// - Returns: 是否通过校验并触发了 `onCommit`。
    @discardableResult
    func commitForTest(row index: Int, start: String, end: String) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let before = list
        rows[index].setText(start: start, end: end)
        commit(row: index)
        return list != before
    }
    /// 列表行数（应恒为 10）。
    var rowCount: Int { rows.count }
    /// 滚动可视高度。
    var visibleHeight: CGFloat { scroll.bounds.height }
    /// 全部行撑开的文档高度。
    var contentHeight: CGFloat { document.frame.height }
    /// 内容是否真的超出可视区 —— 「内置滚动窗口」的必要条件。
    var isContentScrollable: Bool { contentHeight > visibleHeight + 0.5 }
    /// 第一行的当前文本（默认作息校验用），形如 `("08:00", "08:45")`。
    var firstRowTexts: (start: String, end: String)? {
        guard let row = rows.first, let s = row.startText, let e = row.endText else { return nil }
        return (s, e)
    }
    /// 自检用：第一行拆出的输入框数量 —— 「时 / 分」两个框 × 开始 / 结束 = 4。
    var firstRowFieldCount: Int { rows.first?.allFields.count ?? 0 }
    /// 自检用：第一行四个框的内容，顺序 `[开始时, 开始分, 结束时, 结束分]`。
    var firstRowFieldValues: [String] { rows.first?.allFields.map { $0.stringValue } ?? [] }
}

// MARK: - 一行

/// 一节：`第 N 节  [时] : [分] – [时] : [分]`。
private final class PeriodTimeRowView: NSView {

    let indexLabel = NSTextField(labelWithString: "")
    let startHour = PeriodTimeFieldBox()
    let startMinute = PeriodTimeFieldBox()
    let endHour = PeriodTimeFieldBox()
    let endMinute = PeriodTimeFieldBox()

    /// 这一行的四个输入框（失焦判断 / 焦点在同一行内移动时用）。
    var allFields: [NSTextField] {
        [startHour.field, startMinute.field, endHour.field, endMinute.field]
    }

    func contains(_ field: NSTextField) -> Bool {
        allFields.contains { $0 === field }
    }

    /// 开始时间 `HH:mm`；格式非法 → nil。分留空按 `00` 处理。
    var startText: String? { combined(startHour.field, startMinute.field) }
    var endText: String? { combined(endHour.field, endMinute.field) }

    init(index: Int, time: PeriodTime, delegate: NSTextFieldDelegate?) {
        super.init(frame: .zero)

        indexLabel.stringValue = "第 \(index + 1) 节"
        indexLabel.font = .systemFont(ofSize: 11.5)
        indexLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        indexLabel.alignment = .right

        let start = PeriodTimeRowView.split(time.start)
        let end = PeriodTimeRowView.split(time.end)
        configure(startHour.field, text: start.hour, placeholder: "HH", delegate: delegate)
        configure(startMinute.field, text: start.minute, placeholder: "MM", delegate: delegate)
        configure(endHour.field, text: end.hour, placeholder: "HH", delegate: delegate)
        configure(endMinute.field, text: end.minute, placeholder: "MM", delegate: delegate)

        let startColon = colonLabel()
        let endColon = colonLabel()
        let dash = NSTextField(labelWithString: "–")
        dash.font = .systemFont(ofSize: 12)
        dash.textColor = NSColor.white.withAlphaComponent(0.45)
        dash.alignment = .center

        let views: [NSView] = [
            indexLabel, startHour, startColon, startMinute, dash,
            endHour, endColon, endMinute,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 58),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            startHour.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 10),
            startHour.widthAnchor.constraint(equalToConstant: 32),
            startHour.heightAnchor.constraint(equalToConstant: 22),
            startHour.centerYAnchor.constraint(equalTo: centerYAnchor),

            startColon.leadingAnchor.constraint(equalTo: startHour.trailingAnchor, constant: 3),
            startColon.widthAnchor.constraint(equalToConstant: 6),
            startColon.centerYAnchor.constraint(equalTo: centerYAnchor),

            startMinute.leadingAnchor.constraint(equalTo: startColon.trailingAnchor, constant: 3),
            startMinute.widthAnchor.constraint(equalToConstant: 32),
            startMinute.heightAnchor.constraint(equalToConstant: 22),
            startMinute.centerYAnchor.constraint(equalTo: centerYAnchor),

            dash.leadingAnchor.constraint(equalTo: startMinute.trailingAnchor, constant: 6),
            dash.widthAnchor.constraint(equalToConstant: 12),
            dash.centerYAnchor.constraint(equalTo: centerYAnchor),

            endHour.leadingAnchor.constraint(equalTo: dash.trailingAnchor, constant: 6),
            endHour.widthAnchor.constraint(equalToConstant: 32),
            endHour.heightAnchor.constraint(equalToConstant: 22),
            endHour.centerYAnchor.constraint(equalTo: centerYAnchor),

            endColon.leadingAnchor.constraint(equalTo: endHour.trailingAnchor, constant: 3),
            endColon.widthAnchor.constraint(equalToConstant: 6),
            endColon.centerYAnchor.constraint(equalTo: centerYAnchor),

            endMinute.leadingAnchor.constraint(equalTo: endColon.trailingAnchor, constant: 3),
            endMinute.widthAnchor.constraint(equalToConstant: 32),
            endMinute.heightAnchor.constraint(equalToConstant: 22),
            endMinute.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 把 `HH:mm` 拆进四个框（供外部赋值 / 自检用）。
    func setText(start: String, end: String) {
        let s = PeriodTimeRowView.split(start)
        startHour.field.stringValue = s.hour
        startMinute.field.stringValue = s.minute
        let e = PeriodTimeRowView.split(end)
        endHour.field.stringValue = e.hour
        endMinute.field.stringValue = e.minute
    }

    private func combined(_ hour: NSTextField, _ minute: NSTextField) -> String? {
        let h = hour.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var m = minute.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if m.isEmpty { m = "00" }
        return PeriodSettings.normalizeTime("\(h):\(m)")
    }

    private func configure(_ field: NSTextField, text: String,
                           placeholder: String, delegate: NSTextFieldDelegate?) {
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textColor = NSColor.white.withAlphaComponent(0.92)
        field.alignment = .center
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = delegate
    }

    private func colonLabel() -> NSTextField {
        let colon = NSTextField(labelWithString: ":")
        colon.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        colon.textColor = NSColor.white.withAlphaComponent(0.45)
        colon.alignment = .center
        return colon
    }

    /// `"07:55"` / `"7：5"` → `("7", "5")`；没有冒号时整串当时。
    private static func split(_ text: String) -> (hour: String, minute: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (normalized, "")
    }
}

// MARK: - 垂直居中

/// 圆角输入框：背景画在容器上，文字输入框只占**行高**、居中放在容器里。
///
/// 直接把 `NSTextField` 做成 22pt 高的背景框时，单行数字会被系统排在偏上的
/// 位置（行高按上伸部 + 下伸部算，而数字只有 cap height），看着不居中；
/// 去改 cell 的 `drawingRect` 在 layer 缓存渲染下也不生效。把背景和文字拆开，
/// 文字框只留 15pt 高并居中，数字就正好落在框的正中，编辑时光标也保持一致。
private final class PeriodTimeFieldBox: NSView {

    let field = NSTextField()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 6

        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.heightAnchor.constraint(equalToConstant: 15),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 点在框的上下留白上也应该开始编辑，而不是没反应。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}

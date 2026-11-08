import AppKit

/// 数字输入框：可以用上下方向键增减（也可以直接打字）。
///
/// **注意**：文本框正在编辑时，键盘事件是发给 field editor（NSTextView）的，
/// 不是发给 NSTextField 本身 —— 所以在 `keyDown` 里拦 ↑↓ 是**拦不到的**。
/// 真正能拦到的是 field editor 的命令（`moveUp:` / `moveDown:`），
/// 由 `WeekRangePicker` 作为 delegate 在 `doCommandBy` 里处理。
final class WeekNumberField: NSTextField {
    /// 上下键回调（+1 / -1）。留空则上下键走默认行为（移动光标）。
    var onArrow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        // 不是编辑状态（没有 field editor）时，事件确实会到这里 —— 顺手也处理掉。
        switch event.keyCode {
        case 125: onArrow?(1); return    // ↑
        case 126: onArrow?(-1); return   // ↓
        default: break
        }
        super.keyDown(with: event)
    }
}

/// 周次选择器：左边一个数字 = 起始周，右边一个数字 = 结束周，
/// **上下方向键增减**（也可以用步进器点，或者直接打字）。
///
/// 为什么不用纯文本框：
///   · 「1-15」这种写法要靠手打，容易打错（`l-15`），也不知道当前值是什么；
///   · 用户要的是「上下选」，不是「打字」。
///
/// 周次**不连续**的课程（教务表里很常见：`1-3,5-6(单)`）用区间表达不了 ——
/// 这时自动切到「自定义」模式，保留原来的写法，**一个字都不丢**。
/// 区间模式下若用户自己调出「不连续」的写法，也切到自定义模式。
final class WeekRangePicker: NSView, NSTextFieldDelegate {

    // MARK: 对外接口

    /// 学期总周数（上限）。
    var maxWeek: Int = 16 {
        didSet {
            startStepper.maxValue = Double(max(1, maxWeek))
            endStepper.maxValue = Double(max(1, maxWeek))
            applyToFields()
        }
    }

    /// 当前周次。赋值时会自动决定「区间模式」还是「自定义模式」。
    var weeks: [Int] = [] {
        didSet { if !isSyncing { applyToFields() } }
    }

    /// 值变了（保存前刷新预览用）。
    var onChange: (() -> Void)?

    /// 当前是不是「自定义写法」模式。
    private(set) var isCustomMode = false

    /// 测试用：区间模式下的（起始周, 结束周）；自定义模式下返回 nil。
    var testRange: (start: Int, end: Int)? {
        guard !isCustomMode else { return nil }
        return (Int(startField.stringValue) ?? 0, Int(endField.stringValue) ?? 0)
    }

    /// 测试用：自定义模式下的写法文本。
    var testCustomText: String? {
        isCustomMode ? customField.stringValue : nil
    }

    /// 测试用：模拟用户把起始周输入框清空（打字打到一半）。
    ///
    /// 清空后**不能**被立刻改写成数字 —— 否则用户永远没法重输。
    func testSimulateClearStartField() {
        startField.stringValue = ""
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                          object: startField))
    }

    /// 测试用：模拟点一下**结束周**步进器的向上箭头。
    ///
    /// 走的是真实路径：步进器自己先加 1，再发 action 改数字框。
    func testSimulateEndStepperUp() {
        endStepper.doubleValue = min(endStepper.maxValue, endStepper.doubleValue + 1)
        endStepperChanged()
    }

    /// 测试用：模拟点一下**结束周**步进器的向下箭头。
    func testSimulateEndStepperDown() {
        endStepper.doubleValue = max(endStepper.minValue, endStepper.doubleValue - 1)
        endStepperChanged()
    }

    /// 测试用：起始周输入框现在显示的文字。
    var testStartFieldText: String { startField.stringValue }

    // MARK: 视图

    private let startField = WeekNumberField()
    private let endField = WeekNumberField()
    private let startStepper = NSStepper()
    private let endStepper = NSStepper()
    private let customField = NSTextField()
    private let customToggle = NSButton(title: "自定义…", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")

    /// 自定义模式下的原始写法（不连续周次时原样保留）。
    private var customText: String = ""
    /// 赋值同步时不要触发回调。
    private var isSyncing = false

    private static let numberWidth: CGFloat = 46

    // MARK: - 构造

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 24))

        for f in [startField, endField] {
            f.font = .systemFont(ofSize: 13)
            f.alignment = .right
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        startField.placeholderString = "起"
        endField.placeholderString = "止"

        for s in [startStepper, endStepper] {
            s.minValue = 1
            s.maxValue = Double(maxWeek)
            s.increment = 1
            s.valueWraps = false
            s.translatesAutoresizingMaskIntoConstraints = false
        }

        customField.font = .systemFont(ofSize: 13)
        customField.placeholderString = "例如 1-16 或 1-3,5-6(单)"
        customField.delegate = self
        customField.translatesAutoresizingMaskIntoConstraints = false
        customField.isHidden = true

        customToggle.bezelStyle = .inline
        customToggle.isBordered = false
        customToggle.font = .systemFont(ofSize: 11)
        customToggle.contentTintColor = NSColor.secondaryLabelColor
        customToggle.translatesAutoresizingMaskIntoConstraints = false
        customToggle.setButtonType(.momentaryPushIn)
        customToggle.target = self
        customToggle.action = #selector(toggleCustom)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.isHidden = true

        let startRow = NSStackView(views: [startField, startStepper])
        startRow.orientation = .horizontal
        startRow.spacing = 2
        let endRow = NSStackView(views: [endField, endStepper])
        endRow.orientation = .horizontal
        endRow.spacing = 2

        let dash = NSTextField(labelWithString: "–")
        dash.textColor = .secondaryLabelColor
        dash.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [startRow, dash, endRow, customToggle])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, customField, hintLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            startField.widthAnchor.constraint(equalToConstant: Self.numberWidth),
            endField.widthAnchor.constraint(equalToConstant: Self.numberWidth),
            customField.widthAnchor.constraint(equalToConstant: 200),
        ])

        startStepper.target = self
        startStepper.action = #selector(startStepperChanged)
        endStepper.target = self
        endStepper.action = #selector(endStepperChanged)
        startField.onArrow = { [weak self] d in self?.stepStart(by: d) }
        endField.onArrow = { [weak self] d in self?.stepEnd(by: d) }

        applyToFields()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    // MARK: - 值 → 界面

    /// 把 `weeks` 落到界面控件上（决定区间 / 自定义模式）。
    private func applyToFields() {
        isSyncing = true
        defer { isSyncing = false }

        let list = weeks.sorted()
        // 空 / 连续区间 → 区间模式；不连续 → 自定义模式（保留原写法）
        let contiguous = isContiguous(list)
        isCustomMode = !contiguous

        if contiguous {
            let start = list.first ?? 1
            let end = list.last ?? start
            startField.stringValue = String(start)
            endField.stringValue = String(end)
            // 步进器必须跟着数字框走！
            // 不同步的话，步进器还停在初始值（1），用户看到的是「15」，
            // 点一下向上的箭头，步进器从 1 加到 2，数字框就被改成 2 了 ——
            // 表现就是「15 周一点上箭头就变成第 2 周」。
            startStepper.integerValue = start
            endStepper.integerValue = end
            startField.isEnabled = true
            endField.isEnabled = true
            startStepper.isEnabled = true
            endStepper.isEnabled = true
            customField.isHidden = true
            hintLabel.stringValue = ""
            hintLabel.isHidden = true
        } else {
            if customText.isEmpty { customText = CourseEdit.formatWeeks(list) }
            customField.stringValue = customText
            startField.isEnabled = false
            endField.isEnabled = false
            startStepper.isEnabled = false
            endStepper.isEnabled = false
            customField.isHidden = false
            hintLabel.stringValue = "周次不连续，已保留原来的写法"
            hintLabel.isHidden = false
        }
        startStepper.maxValue = Double(max(1, maxWeek))
        endStepper.maxValue = Double(max(1, maxWeek))
    }

    /// `[1,2,3]` 连续；`[1,2,4]` 不连续；空数组算连续。
    private func isContiguous(_ list: [Int]) -> Bool {
        guard list.count > 1 else { return true }
        for i in 1..<list.count where list[i] != list[i - 1] + 1 { return false }
        return true
    }

    // MARK: - 界面 → 值

    /// 读当前界面上的值。
    private func currentValue() -> [Int] {
        if isCustomMode {
            return CourseEdit.parseWeeks(customField.stringValue)
        }
        let s = Int(startField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        let e = Int(endField.stringValue.trimmingCharacters(in: .whitespaces)) ?? s
        let lo = max(1, min(s, e))
        let hi = max(lo, max(s, e))
        return Array(lo...hi)
    }

    /// 界面变化后把值写回 `weeks`。
    ///
    /// 注意：这里**不能**触发 `applyToFields()` —— 那样会把用户正在编辑的框
    /// 立刻改写回去（清空重输就变成了改不动的死循环）。
    private func commit() {
        isSyncing = true
        weeks = currentValue()
        isSyncing = false
        onChange?()
    }

    /// 一边的数字超过另一边时，把另一边跟着推上去（但不碰正在编辑的那个框）。
    private func syncOtherField(from field: NSTextField) {
        guard let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = max(1, min(maxWeek, v))
        // 自己那个步进器也要跟着走（不然点箭头会从旧值开始加）
        if field === startField {
            startStepper.integerValue = clamped
            if (Int(endField.stringValue) ?? clamped) < clamped {
                endField.stringValue = String(clamped)
                endStepper.integerValue = clamped
            }
        } else {
            endStepper.integerValue = clamped
            if (Int(startField.stringValue) ?? clamped) > clamped {
                startField.stringValue = String(clamped)
                startStepper.integerValue = clamped
            }
        }
    }

    // MARK: - 步进

    @objc private func startStepperChanged() {
        let v = max(1, min(maxWeek, startStepper.integerValue))
        startField.stringValue = String(v)
        if (Int(endField.stringValue) ?? v) < v { endField.stringValue = String(v) }
        commit()
    }

    @objc private func endStepperChanged() {
        var v = max(1, min(maxWeek, endStepper.integerValue))
        if let s = Int(startField.stringValue), v < s { v = s }
        endField.stringValue = String(v)
        commit()
    }

    /// 起始周 ±1（上下键 / 步进器）。
    func stepStart(by delta: Int) {
        let cur = Int(startField.stringValue) ?? 1
        let v = max(1, min(maxWeek, cur + delta))
        startField.stringValue = String(v)
        if (Int(endField.stringValue) ?? v) < v { endField.stringValue = String(v) }
        startStepper.integerValue = v
        commit()
    }

    /// 结束周 ±1（上下键 / 步进器）。
    func stepEnd(by delta: Int) {
        let cur = Int(endField.stringValue) ?? 1
        var v = max(1, min(maxWeek, cur + delta))
        if let s = Int(startField.stringValue), v < s { v = s }
        endField.stringValue = String(v)
        endStepper.integerValue = v
        commit()
    }

    @objc private func toggleCustom() {
        if isCustomMode {
            // 从自定义回到区间：能解析成连续区间就转，否则留在自定义
            let parsed = CourseEdit.parseWeeks(customField.stringValue)
            if isContiguous(parsed.sorted()), !parsed.isEmpty {
                isCustomMode = false
                customText = ""
                weeks = parsed
                applyToFields()
                onChange?()
            }
        } else {
            isCustomMode = true
            customText = CourseEdit.formatWeeks(weeks.sorted())
            customField.stringValue = customText
            customField.isHidden = false
            startField.isEnabled = false
            endField.isEnabled = false
            startStepper.isEnabled = false
            endStepper.isEnabled = false
            hintLabel.stringValue = "自定义周次写法"
            hintLabel.isHidden = false
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        // 上下方向键：field editor 的命令（编辑状态下键盘事件发给的是它）
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if control === startField { stepStart(by: 1) } else { stepEnd(by: 1) }
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if control === startField { stepStart(by: -1) } else { stepEnd(by: -1) }
            return true
        }
        if control === customField {
            customText = customField.stringValue
            let parsed = CourseEdit.parseWeeks(customField.stringValue)
            isSyncing = true
            weeks = parsed
            isSyncing = false
            onChange?()
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === startField || field === endField {
            // 只有能解析成数字时才更新值 —— 半截输入（空串、"1"）不能打断打字
            if Int(field.stringValue.trimmingCharacters(in: .whitespaces)) != nil {
                syncOtherField(from: field)
                commit()
            } else {
                onChange?()
            }
        } else if field === customField {
            customText = customField.stringValue
            let parsed = CourseEdit.parseWeeks(customField.stringValue)
            isSyncing = true
            weeks = parsed
            isSyncing = false
            onChange?()
        }
    }

    /// 结束编辑：把两个数字夹回合法范围。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        guard field === startField || field === endField else { return }
        let lo = max(1, min(maxWeek, Int(startField.stringValue) ?? 1))
        let hi = max(lo, min(maxWeek, Int(endField.stringValue) ?? lo))
        startField.stringValue = String(lo)
        endField.stringValue = String(hi)
        startStepper.integerValue = lo
        endStepper.integerValue = hi
        commit()
    }
}

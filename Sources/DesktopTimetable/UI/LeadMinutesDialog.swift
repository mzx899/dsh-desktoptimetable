import AppKit

/// 「自定义提前提醒分钟数」的输入框（自建 HUD 面板，不用系统 `NSAlert`）。
///
/// 为什么不用 `NSAlert`：系统弹窗的位置、按钮顺序、样式跟这个 app 的 HUD 面板
/// 完全不是一个调子（本项目的弹窗一律自建，见 `UI/HUDWindow.swift`）。
/// 取值范围 `0...60` —— 跟 `ReminderSettings.clampLead` 一致。
final class LeadMinutesDialog: NSObject, NSWindowDelegate {

    /// 弹一个输入框。
    /// - Parameter current: 当前生效的分钟数（预填，用户可直接改）。
    /// - Returns: 确认 → 分钟数（0...60）；取消 → nil。
    static func run(current: Int) -> Int? {
        LeadMinutesDialog().present(current: current)
    }

    // MARK: - 状态

    private var window: NSWindow?
    private var field: NSTextField!
    private var errorLabel: NSTextField!
    private var result: Int?

    // MARK: - 显示

    private func present(current: Int) -> Int? {
        // 宽度按说明文字**单行放得下**来定：380 时那句话会折行，
        // 第二行只剩一个「分钟）」孤零零地挂着，很难看。
        // 实测 12.5pt 下这句话要 347pt，内容区留够 372pt 就不会折行。
        let width: CGFloat = 420
        let contentWidth = width - 48
        let message = "输入提前多少分钟提醒上课（0 表示上课时提醒，最多 60 分钟）"

        // 高度按内容算（别留一截空白）
        let titleHeight: CGFloat = 22
        let fieldHeight: CGFloat = 24
        let errorHeight: CGFloat = 16
        let buttonHeight: CGFloat = 31
        let gap: CGFloat = 12
        let probe = NSTextField(wrappingLabelWithString: message)
        probe.font = .systemFont(ofSize: 12.5)
        let messageHeight = ceil(probe.sizeThatFits(
            NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
        let height = 36 + titleHeight + gap + messageHeight + gap + fieldHeight
            + gap + errorHeight + gap + buttonHeight + 20

        let w = HUDWindow.make(title: "自定义提前提醒",
                               size: NSSize(width: width, height: height),
                               miniaturizable: false)
        w.delegate = self
        // 深色外观：HUD 材质在浅色系统下是「浅底黑字」，压白底上看不清。
        w.appearance = NSAppearance(named: .darkAqua)

        let root = HUDWindow.installContent(in: w, root: NSView())
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            root.heightAnchor.constraint(equalToConstant: height),
        ])
        HUDWindow.installDarkBackdrop(in: w, below: root)

        // ---- 标题（与统一弹窗一致：15.5pt semibold 居中）----
        let titleLabel = NSTextField(labelWithString: "自定义提前提醒")
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityLabel("自定义提前提醒")

        // ---- 说明（居中）----
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 12.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityLabel(message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- 输入框 ----
        field = NSTextField(string: "\(current)")
        field.placeholderString = "分钟"
        field.font = .systemFont(ofSize: 13)
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true

        let unitLabel = NSTextField(labelWithString: "分钟")
        unitLabel.font = .systemFont(ofSize: 12.5)
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.translatesAutoresizingMaskIntoConstraints = false

        let fieldRow = NSStackView(views: [field, unitLabel])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        fieldRow.alignment = .centerY
        fieldRow.translatesAutoresizingMaskIntoConstraints = false

        // ---- 错误提示（平时空着，出错时才显示字）----
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.textColor = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.95)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- 按钮（统一弹窗样式：取消在左，主操作在右）----
        let cancel = DialogButton(style: .secondary, title: "取消",
                                  target: self, action: #selector(cancelTapped))
        // Esc 始终取消。
        cancel.keyEquivalent = "\u{1b}"
        let confirm = DialogButton(style: .primary(color: DialogStyle.color(.info)),
                                   title: "确定",
                                   target: self, action: #selector(confirmTapped))
        confirm.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(buttons)

        let stack = NSStackView(views: [titleLabel, messageLabel, fieldRow,
                                        errorLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        // 约束顺序：**先加进层级，再激活约束**（反过来会抛 NSException）。
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fieldRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.heightAnchor.constraint(equalToConstant: errorHeight),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),

            buttons.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: buttonRow.leadingAnchor),
        ])

        window = w
        NSApp.activate(ignoringOtherApps: true)
        // accessory App 光靠 NSApp.activate 抢不到前台 —— 显式激活整组窗口。
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
        // 装完内容再居中一次：窗口尺寸可能在布局后被调整过。
        HUDWindow.centerOnScreen(w)
        w.makeKeyAndOrderFront(nil)
        // `NSApp.runModal(for:)` 不会自己把窗口摆到前面 —— 先 order front
        // （跟 ConfirmDialogController 同一个理由：设置面板也在 .floating 层）。
        w.orderFrontRegardless()
        // 光标落在输入框里，可以马上改数字。
        w.makeFirstResponder(field)
        NSApp.runModal(for: w)

        let value = result
        result = nil
        window = nil
        return value
    }

    // MARK: - 按钮

    @objc private func confirmTapped() {
        guard let minutes = LeadMinutesChoice.parseMinutes(field.stringValue) else {
            // 输入不合法：留在弹窗里报错，不静默吞掉。
            errorLabel.stringValue = "请输入 \(ReminderSettings.minLeadMinutes)–\(ReminderSettings.maxLeadMinutes) 之间的整数"
            return
        }
        result = minutes
        finish()
    }

    @objc private func cancelTapped() {
        result = nil
        finish()
    }

    private func finish() {
        guard let w = window else { return }
        w.close()
        NSApp.stopModal(withCode: .OK)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 点标题栏的关闭按钮 = 取消
        result = nil
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

import AppKit

/// 「已完成的提醒事项」的确认弹窗。
///
/// 单条删除复用通用 `AlertDialogController`（红色危险语气、默认焦点在「取消」）；
/// 「全部删除」需要一个**输入确认词**的输入框，系统弹窗 / 通用弹窗都没有这个能力，
/// 所以这里按同一套 HUD 版式单独写一个（不另起视觉风格）。
enum CompletedReminderDialogs {

    /// 单条删除的轻量确认（标题带上待办名）。
    static func confirmDelete(_ item: CompletedReminder) -> Bool {
        let outcome = AlertDialogController.show(.init(
            severity: .destructive,
            title: CompletedReminderPolicy.deleteOneTitle(title: item.title),
            message: CompletedReminderPolicy.deleteOneMessage,
            confirmTitle: "删除",
            cancelTitle: "取消"))
        // 默认两按钮组合：主操作是红色确认按钮 → `.confirmed`。
        switch outcome {
        case .confirmed, .destructive:
            return true
        case .cancelled, .chosen:
            return false
        }
    }

    /// 全部删除：二次确认；≥50 条要求输入「删除」。
    ///
    /// - Parameter count：调用方**重新统计**后的数量（不是列表里的旧数量）。
    static func confirmDeleteAll(count: Int) -> Bool {
        DeleteAllCompletedDialog(count: count).run()
    }
}

/// 「删除全部已完成事项？」确认框。
///
/// 版式照抄 `AlertDialogController`：同一个 HUD 材质、图标 / 标题 / 说明 /
/// 按钮竖排、120ms 淡入、Esc = 取消。
final class DeleteAllCompletedDialog: NSObject, NSWindowDelegate {

    private let count: Int
    private let requiresPhrase: Bool

    private var window: NSWindow?
    private var phraseField: NSTextField?
    private var confirmButton: DialogButton?
    private var confirmed = false

    private enum Metrics {
        static let width: CGFloat = DialogStyle.width
        static let pad: CGFloat = 24
        static let contentWidth: CGFloat = width - pad * 2
        static let iconSize: CGFloat = 38
        static let iconRadius: CGFloat = 10
        static let topPad: CGFloat = 18
        static let gapAfterIcon: CGFloat = 12
        static let titleHeight: CGFloat = 22
        static let gapAfterTitle: CGFloat = 8
        static let gapBeforeButtons: CGFloat = 16
        static let buttonHeight: CGFloat = 31
        static let bottomPad: CGFloat = 18
        static let fieldHeight: CGFloat = 24
        static let hintHeight: CGFloat = 15
    }

    init(count: Int) {
        self.count = max(0, count)
        self.requiresPhrase = CompletedReminderPolicy.needsTypedConfirmation(count: max(0, count))
        super.init()
    }

    /// 自检 / 出图用：只建窗、不弹。
    static func buildWindowForTest(count: Int) -> NSWindow {
        DeleteAllCompletedDialog(count: count).buildWindow()
    }

    /// 输入确认词是否放行（纯函数，单测用）。
    static func phraseGate(count: Int, text: String) -> Bool {
        guard CompletedReminderPolicy.needsTypedConfirmation(count: count) else { return true }
        return CompletedReminderPolicy.typedConfirmationMatches(text)
    }

    // MARK: - 显示

    func run() -> Bool {
        let w = buildWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        fadeIn(w)
        NSApp.runModal(for: w)
        let result = confirmed
        confirmed = false
        window = nil
        return result
    }

    private func fadeIn(_ w: NSWindow) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.alphaValue = 1
            return
        }
        w.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 1
        }
    }

    // MARK: - 建窗

    private func buildWindow() -> NSWindow {
        let width = Metrics.width
        let contentWidth = Metrics.contentWidth
        let message = CompletedReminderPolicy.deleteAllMessage(count: count)
        let messageHeight = Self.messageHeight(message, width: contentWidth)
        let hint = "共 \(count) 条，数量较多，请在这里输入「\(CompletedReminderPolicy.typedConfirmationWord)」两个字确认。"
        let hintHeight = requiresPhrase ? Self.messageHeight(hint, width: contentWidth) : 0

        var height = Metrics.topPad + Metrics.iconSize + Metrics.gapAfterIcon
            + Metrics.titleHeight + Metrics.gapAfterTitle + messageHeight
        if requiresPhrase {
            height += 6 + hintHeight + 6 + Metrics.fieldHeight
        }
        height += Metrics.gapBeforeButtons + Metrics.buttonHeight + Metrics.bottomPad

        let w = HUDWindow.make(title: CompletedReminderPolicy.deleteAllTitle,
                               size: NSSize(width: width, height: height),
                               miniaturizable: false)
        w.delegate = self
        w.appearance = NSAppearance(named: .darkAqua)

        let root = HUDWindow.installContent(in: w, root: NSView())
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            root.heightAnchor.constraint(equalToConstant: height),
        ])
        HUDWindow.installDarkBackdrop(in: w, below: root)

        // ---- 图标 ----
        let iconBadge = NSView()
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = Metrics.iconRadius
        iconBadge.layer?.backgroundColor = DialogStyle.color(.destructive)
            .withAlphaComponent(0.18).cgColor
        iconBadge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: DialogStyle.symbolName(.destructive),
                             accessibilityDescription: "删除全部已完成事项")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentTintColor = DialogStyle.color(.destructive)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(icon)

        // ---- 标题 ----
        let title = NSTextField(labelWithString: CompletedReminderPolicy.deleteAllTitle)
        title.font = .systemFont(ofSize: 15.5, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityLabel(CompletedReminderPolicy.deleteAllTitle)

        // ---- 说明 ----
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 12.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityLabel(message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.alignment = .center
        messageLabel.attributedStringValue = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])

        // ---- 输入确认词（≥50 条才有）----
        var phraseViews: [NSView] = []
        if requiresPhrase {
            let hintLabel = NSTextField(wrappingLabelWithString: hint)
            hintLabel.font = .systemFont(ofSize: 11)
            hintLabel.textColor = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.95)
            hintLabel.alignment = .center
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            let hintPara = NSMutableParagraphStyle()
            hintPara.lineSpacing = 2
            hintPara.alignment = .center
            hintLabel.attributedStringValue = NSAttributedString(
                string: hint,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.95),
                    .paragraphStyle: hintPara,
                ])

            let field = NSTextField(string: "")
            field.placeholderString = CompletedReminderPolicy.typedConfirmationWord
            field.font = .systemFont(ofSize: 13)
            field.alignment = .center
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setAccessibilityLabel("输入「\(CompletedReminderPolicy.typedConfirmationWord)」确认")
            phraseField = field

            phraseViews = [hintLabel, field]
        }

        // ---- 按钮：取消在左，红色的「全部删除」在右（不绑 Return）----
        let cancel = DialogButton(style: .secondary, title: "取消",
                                  target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let destructive = DialogButton(
            style: .primary(color: DialogStyle.color(.destructive)),
            title: "全部删除",
            target: self, action: #selector(confirmTapped))
        destructive.isEnabled = !requiresPhrase
        destructive.alphaValue = requiresPhrase ? 0.45 : 1
        confirmButton = destructive
        let buttons = NSStackView(views: [cancel, destructive])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(buttons)

        var views: [NSView] = [title, messageLabel]
        views.append(contentsOf: phraseViews)
        views.append(buttonRow)
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(Metrics.gapAfterTitle, after: title)
        column.setCustomSpacing(6, after: messageLabel)
        if requiresPhrase, let field = phraseField {
            column.setCustomSpacing(6, after: phraseViews[0])
            column.setCustomSpacing(Metrics.gapBeforeButtons, after: field)
        } else {
            column.setCustomSpacing(Metrics.gapBeforeButtons, after: messageLabel)
        }

        root.addSubview(iconBadge)
        root.addSubview(column)

        NSLayoutConstraint.activate([
            iconBadge.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.topPad),
            iconBadge.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconBadge.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),

            column.topAnchor.constraint(equalTo: iconBadge.bottomAnchor,
                                        constant: Metrics.gapAfterIcon),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.pad),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.pad),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                           constant: -Metrics.bottomPad),

            title.heightAnchor.constraint(equalToConstant: Metrics.titleHeight),
            messageLabel.widthAnchor.constraint(equalToConstant: contentWidth),

            buttons.centerXAnchor.constraint(equalTo: buttonRow.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
            buttonRow.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        if let field = phraseField {
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(equalTo: column.widthAnchor),
                field.heightAnchor.constraint(equalToConstant: Metrics.fieldHeight),
            ])
        }

        // 默认焦点给「取消」——危险操作，Return 不删东西。
        w.makeFirstResponder(cancel)
        HUDWindow.centerOnScreen(w)
        return w
    }

    /// 说明文字高度（和 `AlertDialogController.messageHeight` 同一套算法）。
    private static func messageHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: para],
            context: nil)
        return ceil(rect.height)
    }

    // MARK: - 动作

    @objc private func confirmTapped() {
        if requiresPhrase, let field = phraseField,
           !CompletedReminderPolicy.typedConfirmationMatches(field.stringValue) {
            return
        }
        confirmed = true
        finish()
    }

    @objc private func cancelTapped() {
        confirmed = false
        finish()
    }

    private func finish() {
        guard let w = window else { return }
        w.close()
        NSApp.stopModal(withCode: .OK)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmed = false
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

extension DeleteAllCompletedDialog: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard requiresPhrase, let field = phraseField else { return }
        let matches = CompletedReminderPolicy.typedConfirmationMatches(field.stringValue)
        confirmButton?.isEnabled = matches
        confirmButton?.alphaValue = matches ? 1 : 0.45
    }
}

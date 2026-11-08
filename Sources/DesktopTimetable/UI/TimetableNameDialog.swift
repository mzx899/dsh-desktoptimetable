import AppKit

/// 新建 / 重命名课表的小窗口（自建 HUD 面板，不用系统 `NSAlert`）。
///
/// 为什么不用 `NSAlert`：
///   · `NSAlert` 的 accessoryView 是系统样式，跟这个 app 的 HUD 面板不是一个调子；
///   · `NSAlert` 的按钮顺序（取消在左、确认在右）和文案全靠各写各的；
///   · 弹窗位置在左下角（`NSAlert` 自己定位置），不居中。
///
/// 版式跟 `AlertDialogController` 对齐（居中标题 + 说明 + 按钮行），
/// 只是多了输入框。
///
/// 用法：`TimetableNameDialog.run(title:message:name:subtitle:confirmTitle:)`
/// → 取消返回 `nil`，确认返回输入的 `Result`。
final class TimetableNameDialog: NSObject, NSWindowDelegate {

    /// 输入结果。
    struct Result {
        var name: String
        var subtitle: String
    }

    /// 弹一个输入框。
    ///
    /// - Parameters:
    ///   - title：窗口标题（也是主标题）。
    ///   - message：标题下面的一行说明。
    ///   - name：课表名称的初值。
    ///   - subtitle：副标题的初值。
    ///   - confirmTitle：确认按钮的标题（「创建」/「保存」）。
    ///   - showsSubtitle：是否显示副标题输入框（只有名称时传 false）。
    /// - Returns: 取消返回 `nil`。
    static func run(title: String,
                    message: String,
                    name: String,
                    subtitle: String,
                    confirmTitle: String,
                    showsSubtitle: Bool = true) -> Result? {
        let dialog = TimetableNameDialog()
        return dialog.present(title: title, message: message,
                              name: name, subtitle: subtitle,
                              confirmTitle: confirmTitle,
                              showsSubtitle: showsSubtitle)
    }

    // MARK: - 状态

    private var window: NSWindow?
    private var nameField: NSTextField!
    private var subtitleField: NSTextField!
    private var confirmed = false

    // MARK: - 显示

    private func present(title: String, message: String,
                         name: String, subtitle: String,
                         confirmTitle: String,
                         showsSubtitle: Bool) -> Result? {
        let width: CGFloat = 440
        let contentWidth = width - 48

        // 高度按内容算（别留一截空白）：图标 / 标题 / 说明 / 输入框 / 按钮
        let iconSize: CGFloat = 38
        let titleHeight: CGFloat = 22
        let fieldHeight: CGFloat = 24
        let buttonHeight: CGFloat = 31
        let gap: CGFloat = 12
        let messageHeight = ceil(NSTextField(wrappingLabelWithString: message).sizeThatFits(
            NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
        let fieldCount = showsSubtitle ? 2 : 1
        let height = 18 + iconSize + gap + titleHeight + gap + messageHeight + gap
            + CGFloat(fieldCount) * fieldHeight + CGFloat(fieldCount - 1) * gap
            + gap + buttonHeight + 18

        let w = HUDWindow.make(title: title, size: NSSize(width: width, height: height),
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

        // ---- 图标（顶部正中：浅色圆角底 + SF Symbol）----
        let iconBadge = NSView()
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 10
        iconBadge.layer?.backgroundColor = DialogStyle.color(.info)
            .withAlphaComponent(0.18).cgColor
        iconBadge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: DialogStyle.symbolName(.info),
                             accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentTintColor = DialogStyle.color(.info)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(icon)

        // ---- 标题 ----
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityLabel(title)

        // ---- 说明 ----
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 12.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityLabel(message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        // 行距 +3：NSTextField 没有 paragraphStyle，只能靠富文本设。
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

        // ---- 输入框 ----
        nameField = NSTextField(string: name)
        nameField.placeholderString = "课表名称"
        nameField.font = .systemFont(ofSize: 13)
        nameField.setAccessibilityLabel("课表名称")
        nameField.translatesAutoresizingMaskIntoConstraints = false

        subtitleField = NSTextField(string: subtitle)
        subtitleField.placeholderString = "副标题（可空）"
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.setAccessibilityLabel("课表副标题")
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        // ---- 按钮（取消在左，主操作在右）----
        let cancel = DialogButton(style: .secondary, title: "取消",
                                  target: self, action: #selector(cancelTapped))
        // Esc 始终取消。
        cancel.keyEquivalent = "\u{1b}"
        let confirm = DialogButton(style: .primary(color: DialogStyle.color(.info)),
                                   title: confirmTitle,
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

        var stackViews: [NSView] = [titleLabel, messageLabel, nameField]
        if showsSubtitle { stackViews.append(subtitleField) }
        stackViews.append(buttonRow)
        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        // 图标单独放：要在窗口正中，不能跟着 stack 的左对齐走。
        root.addSubview(iconBadge)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: iconBadge.bottomAnchor, constant: gap),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: buttonHeight),

            // 按钮行整体居中：取消在左、主操作在右。
            buttons.centerXAnchor.constraint(equalTo: buttonRow.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

            iconBadge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            iconBadge.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: iconSize),
            iconBadge.heightAnchor.constraint(equalToConstant: iconSize),
            icon.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),
        ])
        if showsSubtitle {
            NSLayoutConstraint.activate([
                subtitleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }

        window = w
        NSApp.activate(ignoringOtherApps: true)
        // 装完内容再居中一次：窗口尺寸可能在布局后被调整过。
        HUDWindow.centerOnScreen(w)
        w.makeKeyAndOrderFront(nil)
        // 光标直接落在名称框里，可以马上改字。
        w.makeFirstResponder(nameField)
        NSApp.runModal(for: w)

        guard confirmed else {
            window = nil
            return nil
        }
        let result = Result(name: nameField.stringValue, subtitle: subtitleField.stringValue)
        window = nil
        return result
    }

    // MARK: - 按钮

    @objc private func confirmTapped() {
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
        // 点标题栏的关闭按钮 = 取消
        confirmed = false
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

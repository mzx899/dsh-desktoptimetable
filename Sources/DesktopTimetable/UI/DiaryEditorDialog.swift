import AppKit

/// 新建 / 修改日记的小窗口（自建 HUD 面板，和 `TimetableNameDialog` 同一套版式）。
///
/// 三个字段：标题（可空）、时间（可空，`HH:mm`）、正文（多行）。
/// 设置面板「日记」板块的「新建 / 编辑」都用它。
final class DiaryEditorDialog: NSObject, NSWindowDelegate {

    struct Result {
        var title: String
        var time: String
        var body: String
    }

    /// 弹一个编辑框。`entry` 为 nil 表示新建。
    static func run(title: String,
                    entry: DiaryEntry?,
                    confirmTitle: String) -> Result? {
        DiaryEditorDialog().present(title: title, entry: entry, confirmTitle: confirmTitle)
    }

    private var window: NSWindow?
    private var titleField: NSTextField!
    private var timeField: NSTextField!
    private var bodyView: NSTextView!
    private var confirmed = false

    private func present(title: String, entry: DiaryEntry?, confirmTitle: String) -> Result? {
        let width: CGFloat = 460
        let fieldHeight: CGFloat = 24
        let bodyHeight: CGFloat = 132
        let buttonHeight: CGFloat = 31
        let gap: CGFloat = 10
        // 图标 / 标题 / （时间 + 标题）行 / 正文 / 按钮
        let height = 18 + 38 + 12 + 22 + 12 + fieldHeight + gap + bodyHeight + gap
            + buttonHeight + 18

        let w = HUDWindow.make(title: title, size: NSSize(width: width, height: height),
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
        iconBadge.layer?.cornerRadius = 10
        iconBadge.layer?.backgroundColor = DialogStyle.color(.info).withAlphaComponent(0.18).cgColor
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: title)
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

        // ---- 标题输入 + 时间 ----
        titleField = NSTextField(string: entry?.title ?? "")
        titleField.placeholderString = "标题（可空）"
        titleField.font = .systemFont(ofSize: 12.5)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        timeField = NSTextField(string: entry?.time ?? "")
        timeField.placeholderString = "时间"
        timeField.alignment = .center
        timeField.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        timeField.translatesAutoresizingMaskIntoConstraints = false

        // ---- 正文 ----
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bodyView = NSTextView()
        bodyView.string = entry?.body ?? ""
        bodyView.font = .systemFont(ofSize: 12.5)
        bodyView.textColor = .white
        bodyView.drawsBackground = false
        bodyView.isRichText = false
        bodyView.allowsUndo = true
        bodyView.textContainerInset = NSSize(width: 6, height: 6)
        bodyView.isVerticallyResizable = true
        bodyView.autoresizingMask = [.width]
        scroll.documentView = bodyView
        let bodyBox = NSView()
        bodyBox.wantsLayer = true
        bodyBox.layer?.cornerRadius = 8
        bodyBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        bodyBox.layer?.borderWidth = 1
        bodyBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        bodyBox.translatesAutoresizingMaskIntoConstraints = false
        bodyBox.addSubview(scroll)

        // ---- 按钮 ----
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        let confirm = NSButton(title: confirmTitle, target: self, action: #selector(confirmTapped))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // 输入框是 `NSTextField!`（隐式解包），放进数组会变成 `[NSView?]` —— compactMap 一下。
        let fieldViews: [NSView] = [iconBadge, titleLabel, titleField, timeField, bodyBox, buttons]
            .compactMap { $0 }
        for v in fieldViews {
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            iconBadge.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            iconBadge.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 38),
            iconBadge.heightAnchor.constraint(equalToConstant: 38),
            icon.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: iconBadge.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            titleField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleField.heightAnchor.constraint(equalToConstant: fieldHeight),

            timeField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            timeField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            timeField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            timeField.widthAnchor.constraint(equalToConstant: 64),
            timeField.heightAnchor.constraint(equalToConstant: fieldHeight),

            bodyBox.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: gap),
            bodyBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bodyBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            bodyBox.heightAnchor.constraint(equalToConstant: bodyHeight),
            scroll.topAnchor.constraint(equalTo: bodyBox.topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: -2),
            scroll.leadingAnchor.constraint(equalTo: bodyBox.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: bodyBox.trailingAnchor, constant: -2),

            buttons.topAnchor.constraint(equalTo: bodyBox.bottomAnchor, constant: gap),
            buttons.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            buttons.heightAnchor.constraint(equalToConstant: buttonHeight),
        ])

        window = w
        HUDWindow.centerOnScreen(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(titleField)
        NSApp.runModal(for: w)
        return confirmed
            ? Result(title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     time: Self.normalizeTime(timeField.stringValue),
                     body: bodyView.string.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
    }

    /// 时间归一化：只收数字，`2030` / `20:30` / `9` → `HH:mm`；空 = 不写时间。
    static func normalizeTime(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber }
        guard !digits.isEmpty else { return "" }
        var d = digits
        if d.count == 1 { d = "0" + d }
        if d.count == 2 { return d + ":00" }
        if d.count == 3 { d = "0" + d }
        d = String(d.prefix(4))
        var h = Int(d.prefix(2)) ?? 0
        var m = Int(d.suffix(2)) ?? 0
        if h < 0 || h > 23 { h = 0 }
        if m < 0 || m > 59 { m = 0 }
        return String(format: "%02d:%02d", h, m)
    }

    @objc private func confirmTapped() {
        confirmed = true
        NSApp.stopModal()
        window?.orderOut(nil)
    }

    @objc private func cancelTapped() {
        confirmed = false
        NSApp.stopModal()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}

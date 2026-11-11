import AppKit

/// 新建 / 修改日记的小窗口（自建 HUD 面板，和 `TimetableNameDialog` 同一套版式）。
///
/// 三个字段：标题（可空）、时间（可空，`HH:mm`）、正文（多行）。
/// 设置面板「日记」板块的「新建 / 编辑」都用它。
final class DiaryEditorDialog: NSObject, NSWindowDelegate {

    struct Result {
        var title: String
        /// 这篇日记属于哪一天（`yyyy-MM-dd`）—— **可改**（2026-11-11 用户要求）。
        var date: String
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
    /// 时间拆成「时 / 分」两个小框（2026-11-10 用户要求：给引导，不然不知道怎么填）。
    private var hourField: NSTextField!
    private var minuteField: NSTextField!
    /// 日期输入（`yyyy-MM-dd`）。空 / 非法时沿用原来的日期。
    private var dateField: NSTextField!
    private var bodyView: NSTextView!
    private var confirmed = false

    /// 自检 / 出图用：**只建窗、不弹**（返回窗口让调用方检查或截图）。
    static func buildWindowForTest(title: String, entry: DiaryEntry? = nil,
                                  confirmTitle: String = "保存") -> NSWindow {
        DiaryEditorDialog().build(title: title, entry: entry, confirmTitle: confirmTitle)
    }

    private func present(title: String, entry: DiaryEntry?, confirmTitle: String) -> Result? {
        let w = build(title: title, entry: entry, confirmTitle: confirmTitle)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: w)
        return confirmed
            ? Result(title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     date: Self.normalizeDate(dateField.stringValue,
                                              fallback: entry?.date ?? DiaryStore.dateKey(Date())),
                     time: Self.normalizeTime(hourField.stringValue + ":" + minuteField.stringValue),
                     body: bodyView.string.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
    }

    /// 建窗 + 装内容（不弹）。`present` 和出图都走这里。
    private func build(title: String, entry: DiaryEntry?, confirmTitle: String) -> NSWindow {
        let width: CGFloat = 460
        let fieldHeight: CGFloat = 24
        let bodyHeight: CGFloat = 132
        let buttonHeight: CGFloat = 31
        let gap: CGFloat = 10
        // 图标 / 标题 / （时间 + 标题）行 / 正文 / 按钮
        // +16 = 时间下面那行引导文字。
        // +34 = 日期那一行（2026-11-11）。
        let height = 18 + 38 + 12 + 22 + 12 + fieldHeight + 14 + 16 + 34 + gap + bodyHeight + gap
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

        // ⚠️ **时 / 分两个框**（2026-11-10）：用户反馈「日记这个时间给引导，不然不知道怎么填写」。
        // 一个框里要用户自己想到「20:30」并打对冒号，门槛太高；拆开 + 占位 20 / 30
        // 一眼就知道该填什么，回车也能直接保存。
        let existing = (entry?.time ?? "").split(separator: ":")
        hourField = NSTextField(string: existing.count == 2 ? String(existing[0]) : "")
        hourField.placeholderString = "20"
        hourField.alignment = .center
        hourField.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        hourField.translatesAutoresizingMaskIntoConstraints = false
        hourField.toolTip = "小时（0–23）"

        minuteField = NSTextField(string: existing.count == 2 ? String(existing[1]) : "")
        minuteField.placeholderString = "30"
        minuteField.alignment = .center
        minuteField.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        minuteField.translatesAutoresizingMaskIntoConstraints = false
        minuteField.toolTip = "分钟（0–59）"

        let colon = NSTextField(labelWithString: ":")
        colon.font = .systemFont(ofSize: 12.5)
        colon.textColor = NSColor.white.withAlphaComponent(0.6)
        colon.translatesAutoresizingMaskIntoConstraints = false

        // ---- 日期（可改，2026-11-11 用户要求）----
        let dateLabel = NSTextField(labelWithString: "日期")
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false

        dateField = NSTextField(string: entry?.date ?? DiaryStore.dateKey(Date()))
        dateField.placeholderString = "2026-11-11"
        dateField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dateField.translatesAutoresizingMaskIntoConstraints = false
        dateField.toolTip = "这篇日记算在哪一天（yyyy-MM-dd）"

        let dateHint = NSTextField(labelWithString: "改这里就能把这天写的日记挪到别的日期")
        dateHint.font = .systemFont(ofSize: 10.5)
        dateHint.textColor = NSColor.white.withAlphaComponent(0.38)
        dateHint.translatesAutoresizingMaskIntoConstraints = false

        // 时间下面的引导：说清「可空」和「日期不需要填」。
        let timeHint = NSTextField(labelWithString: "时间可空：填「时」和「分」（如 20:30）")
        timeHint.font = .systemFont(ofSize: 10.5)
        timeHint.textColor = NSColor.white.withAlphaComponent(0.45)
        timeHint.lineBreakMode = .byTruncatingTail
        timeHint.translatesAutoresizingMaskIntoConstraints = false

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
        let fieldViews: [NSView] = [iconBadge, titleLabel, titleField,
                                    hourField, colon, minuteField, timeHint,
                                    dateLabel, dateField, dateHint,
                                    bodyBox, buttons].compactMap { $0 }
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

            minuteField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            minuteField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            minuteField.widthAnchor.constraint(equalToConstant: 34),
            minuteField.heightAnchor.constraint(equalToConstant: fieldHeight),

            colon.trailingAnchor.constraint(equalTo: minuteField.leadingAnchor, constant: -2),
            colon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),

            hourField.trailingAnchor.constraint(equalTo: colon.leadingAnchor, constant: -2),
            hourField.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            hourField.widthAnchor.constraint(equalToConstant: 34),
            hourField.heightAnchor.constraint(equalToConstant: fieldHeight),
            hourField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor,
                                               constant: 8),

            timeHint.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            timeHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            timeHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            dateLabel.topAnchor.constraint(equalTo: timeHint.bottomAnchor, constant: 10),
            dateLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            dateField.leadingAnchor.constraint(equalTo: dateLabel.trailingAnchor, constant: 8),
            dateField.centerYAnchor.constraint(equalTo: dateLabel.centerYAnchor),
            dateField.widthAnchor.constraint(equalToConstant: 110),
            dateField.heightAnchor.constraint(equalToConstant: 22),

            dateHint.leadingAnchor.constraint(equalTo: dateField.trailingAnchor, constant: 10),
            dateHint.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            dateHint.centerYAnchor.constraint(equalTo: dateField.centerYAnchor),

            bodyBox.topAnchor.constraint(equalTo: dateField.bottomAnchor, constant: 14),
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
        w.makeFirstResponder(titleField)
        return w
    }

    /// 日期归一化：只收数字，`2026-11-11` / `2026/11/11` / `20261111` → `yyyy-MM-dd`。
    ///
    /// 非法（位数不对、月 / 日越界）→ 用 `fallback`（原来的日期），**绝不写一个坏日期**。
    static func normalizeDate(_ raw: String, fallback: String) -> String {
        let digits = raw.filter { $0.isNumber }
        guard digits.count == 8,
              let y = Int(digits.prefix(4)),
              let m = Int(digits.dropFirst(4).prefix(2)),
              let d = Int(digits.suffix(2)),
              (1970...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else {
            return fallback
        }
        return String(format: "%04d-%02d-%02d", y, m, d)
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

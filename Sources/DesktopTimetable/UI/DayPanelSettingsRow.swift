import AppKit

/// 「日历与提醒事项接入」那一行。
///
/// 版式：
///   日历与提醒事项接入                    [开关]
///   已接入 · 覆盖层会显示当天的课程、提醒事项和日历日程
///                                  [去系统设置授权]   ← 仅「开了但没授权」时出现
///
/// 开关用 `NSButton(checkboxWithTitle:)` —— 和设置面板里
/// 「开机自启」「上课提醒」用的是同一个控件，样式自动统一。
///
/// 状态行单独一行（不压到开关那一行下面去）——
/// 和 `SliderRow` 的副标题一个道理：文字一长就会挤到右边控件上。
final class DayPanelToggleRow: NSView {

    /// 用户拨动了开关（参数 = 拨动后的目标值）。
    var onToggle: ((Bool) -> Void)?
    /// 用户点了「去系统设置授权」。
    var onOpenSystemSettings: (() -> Void)?

    /// 开关。
    let toggle = NSButton(checkboxWithTitle: "日历与提醒事项接入",
                          target: nil, action: nil)
    /// 状态行。
    let statusLabel = NSTextField(labelWithString: "")
    /// 「去系统设置授权」按钮（按状态显示 / 隐藏）。
    let authorizeButton = NSButton(title: "去系统设置授权",
                                   target: nil, action: nil)

    /// 当前开关是开是关。
    var isOn: Bool { toggle.state == .on }

    /// 程序化设值时置位：此时不往外发回调。
    ///
    /// 和 `SliderRow.suppressCallback` 同一个理由 ——
    /// AppKit 偶尔会在控件首次布局时补发一次 action，
    /// 那一发会把用户的设置悄悄改掉。
    private var suppressCallback = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        toggle.font = .systemFont(ofSize: 12.5)
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        authorizeButton.bezelStyle = .rounded
        authorizeButton.controlSize = .small
        authorizeButton.font = .systemFont(ofSize: 11.5)
        authorizeButton.target = self
        authorizeButton.action = #selector(openSettingsTapped)
        authorizeButton.translatesAutoresizingMaskIntoConstraints = false
        // 默认隐藏 —— 只有「开了但没授权」才显示（见 `DayPanelAuthState.showsAuthorizationButton`）。
        authorizeButton.isHidden = true

        addSubview(toggle)
        addSubview(statusLabel)
        addSubview(authorizeButton)

        NSLayoutConstraint.activate([
            toggle.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            authorizeButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            authorizeButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            authorizeButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 灌入状态。
    func update(enabled: Bool, authState: DayPanelAuthState) {
        suppressCallback = true
        toggle.state = enabled ? .on : .off
        suppressCallback = false

        let desc = DayPanelAuthState.describe(authState)
        statusLabel.stringValue = "\(desc.text) · \(desc.detail)"
        statusLabel.textColor = DayPanelAuthState.statusColor(authState)

        authorizeButton.isHidden = !DayPanelAuthState.showsAuthorizationButton(authState)
        // 没授权时开关依然可点 —— 用户可能想先关掉它。
        toggle.isEnabled = true
    }

    @objc private func toggleChanged() {
        guard !suppressCallback else { return }
        onToggle?(toggle.state == .on)
    }

    @objc private func openSettingsTapped() {
        onOpenSystemSettings?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 「提醒事项清单」那一行。
///
/// 版式：
///   提醒事项清单                                    桌面课表  ›
///
/// 整行都是点击区（不是只有右边那一小块）——
/// 设置面板里的「板块砖」也是这么做的：点哪儿都能中。
///
/// 用 `NSButton` 当底（自带 hover / 按下状态和键盘可达性），
/// 内容全是子视图 —— 和 `SectionTile` 一个路子。
final class DayPanelListRow: NSButton {

    /// 用户点了这一行（该弹清单选择器了）。
    var onTap: (() -> Void)?

    /// 标题。
    let titleLabel = NSTextField(labelWithString: "提醒事项清单")
    /// 当前清单名（右边那个）。
    let valueLabel = NSTextField(labelWithString: "")
    /// 右边的小箭头（提示「可点开」）。
    private let chevron = NSImageView()

    /// 当前显示的清单名。
    var displayedListName: String { valueLabel.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // 按钮本身是「透明」的：内容都放在子视图里。
        isBordered = false
        focusRingType = .none
        isTransparent = true
        // title 只用来给辅助功能一个名字，画面上不显示。
        title = "提醒事项清单"
        setAccessibilityLabel("提醒事项清单")

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 12.5)
        valueLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        // 单色符号 —— 和设置面板首页的图标一个规矩（不引彩色资源）。
        let image = NSImage(systemSymbolName: "chevron.right",
                            accessibilityDescription: "选择清单")
        image?.isTemplate = true
        chevron.image = image
        chevron.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),

            valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
        ])

        target = self
        action = #selector(tapped)
    }

    /// 命中测试：整行都算点在行上（文字和箭头也算）。
    ///
    /// 不这么写的话点文字会停在 `NSTextField` 上，按钮的 action 不触发
    /// （用户看到的「点了没反应」）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        // ⚠️ point 是**父视图坐标系**；必须转换到本地再判断 bounds，
        // 否则行不在父视图原点时点击会被判成「点在外面」。
        guard let parent = superview else { return super.hitTest(point) }
        let local = convert(point, from: parent)
        return bounds.contains(local) ? self : nil
    }

    /// 灌入当前清单名（空串时显示默认名「桌面课表」）。
    func update(listName: String) {
        let name = listName.trimmingCharacters(in: .whitespacesAndNewlines)
        valueLabel.stringValue = name.isEmpty ? DayPanelListRow.defaultListName : name
        valueLabel.setAccessibilityLabel("当前清单：\(valueLabel.stringValue)")
        setAccessibilityLabel("提醒事项清单，当前清单：\(valueLabel.stringValue)")
        toolTip = valueLabel.stringValue
    }

    /// 默认清单名（规格 Q8：默认新建「桌面课表」）。
    static let defaultListName = "桌面课表"

    @objc private func tapped() {
        onTap?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 提醒事项**清单选择**弹窗。
///
/// 为什么不用 `AlertDialogController`：
///   · 它的 `options` 是「**点了就选中并关闭**」的选项行 ——
///     正好符合「选一个清单」的语义，其实可以用；
///   · 但它没有「列表末尾加一行『新建清单』」的能力，
///     而新建清单是规格里明确要求的入口；
///   · 它每行是**固定高度的小卡片**（`AlertDialogOption`），
///     而清单列表可能很长、需要滚动 + 需要「当前选中」标记。
///
/// 所以这里自己写一个**列表选择**弹窗，但**版式完全照抄** `AlertDialogController`：
/// 同一个 HUD 材质、同一个深色底、同样的图标 / 标题 / 说明 / 按钮竖排、
/// 同样的 120ms 淡入、同样的 Esc = 取消。
///
/// 落点用 `HUDWindow.centerOnScreen` —— 它已经是「以课表位置为锚点」的那套
/// （见 `WindowAnchor`），所以弹窗会出现在课表旁边，而不是屏幕正中。
///
/// 用法：
/// ```swift
/// let outcome = DayPanelListPicker.show(lists: ["桌面课表", "购物"], current: "桌面课表")
/// ```
/// 返回 `.selected(String)` / `.create(String)` / `.cancelled`。
enum DayPanelListPicker {

    /// 弹窗结果。
    enum Outcome {
        /// 选中了某个清单（参数是清单名）。
        case selected(String)
        /// 要新建一个清单（参数是新清单名；名字为空表示用户放弃了）。
        case create(String)
        /// 取消（Esc / 关窗）。
        case cancelled
    }

    /// 弹一次清单选择器。
    ///
    /// - Parameters:
    ///   - lists：候选清单名。
    ///   - current：当前选中的清单名（会在这一项旁边打「✓」标记）。
    /// - Returns: 用户的选择。
    @discardableResult
    static func show(lists: [String], current: String?) -> Outcome {
        let dialog = DayPanelListPickerController(lists: lists, current: current)
        return dialog.run()
    }

    /// 自检用：**只建窗口、不弹**（返回窗口让调用方检查它的位置和内容）。
    ///
    /// 和 `AlertDialogController.makeWindowForTest` 一个用法：
    /// 弹窗位置由 `HUDWindow.centerOnScreen` 决定 —— 也就是「以课表位置为锚点」那套。
    static func buildWindowForTest(lists: [String], current: String?) -> NSWindow {
        DayPanelListPickerController(lists: lists, current: current).buildWindowForTest()
    }
}

/// 清单选择弹窗的控制器（**私有**实现，`DayPanelListPicker` 是对外的门面）。
private final class DayPanelListPickerController: NSObject, NSWindowDelegate {

    private let lists: [String]
    private let current: String?
    private var window: NSWindow?
    private var outcome: DayPanelListPicker.Outcome = .cancelled
    /// 选中清单之后要关窗：一次点击只结算一次结果。
    private var finished = false

    init(lists: [String], current: String?) {
        self.lists = lists
        self.current = current
        super.init()
    }

    // MARK: - 版式常量（照抄 AlertDialogController.Metrics）

    enum Metrics {
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
        static let rowHeight: CGFloat = 30
        static let rowGap: CGFloat = 4
        static let cardRadius: CGFloat = 9
        static let cardPad: CGFloat = 9
        /// 列表区最多露这么高（超出就滚动）。
        static let scrollBodyMax: CGFloat = 260
    }

    // MARK: - 显示

    func run() -> DayPanelListPicker.Outcome {
        let w = buildWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        fadeIn(w)
        NSApp.runModal(for: w)
        let result = outcome
        outcome = .cancelled
        window = nil
        return result
    }

    /// 120ms 淡入；系统开了「减弱动态效果」就直接显示。
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

    /// 自检用：只建窗、不弹。
    func buildWindowForTest() -> NSWindow {
        buildWindow()
    }

    private func buildWindow() -> NSWindow {
        let width = Metrics.width
        let contentWidth = Metrics.contentWidth

        // 行数：清单 + 一行「新建清单」。
        let rowCount = lists.count + 1
        let listHeight = CGFloat(lists.count) * Metrics.rowHeight
            + CGFloat(max(0, lists.count - 1)) * Metrics.rowGap
            + Metrics.cardPad * 2 + 2
        let createHeight = Metrics.rowHeight
        let bodyNatural = listHeight + Metrics.rowGap + createHeight

        let screen = NSScreen.main ?? NSScreen.screens.first
        let maxHeight = (screen?.visibleFrame.height ?? 900) * DialogStyle.maxHeightRatio

        var fixedHeight = Metrics.topPad + Metrics.iconSize + Metrics.gapAfterIcon
            + Metrics.titleHeight + Metrics.gapAfterTitle
            + Metrics.gapBeforeButtons + Metrics.buttonHeight + Metrics.bottomPad
        // 说明文字（副标题）的高度。
        let messageText = "选择要写入待办的提醒事项清单"
        fixedHeight += messageHeight(messageText) + 6

        var bodyHeight = bodyNatural
        var scrolls = false
        if fixedHeight + bodyNatural > maxHeight {
            bodyHeight = max(120, maxHeight - fixedHeight)
            scrolls = true
        } else if rowCount > DialogStyle.maxVisibleRows {
            bodyHeight = min(bodyNatural, Metrics.scrollBodyMax)
            scrolls = true
        }
        let windowHeight = fixedHeight + bodyHeight

        let w = HUDWindow.make(title: "选择提醒事项清单",
                               size: NSSize(width: width, height: windowHeight),
                               miniaturizable: false)
        w.delegate = self
        // 深色外观：HUD 材质在浅色系统下是「浅底黑字」，压白底上看不清。
        w.appearance = NSAppearance(named: .darkAqua)

        let root = HUDWindow.installContent(in: w, root: NSView())
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            root.heightAnchor.constraint(equalToConstant: windowHeight),
        ])
        HUDWindow.installDarkBackdrop(in: w, below: root)

        // ---- 图标（顶部正中）----
        let iconBadge = NSView()
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = Metrics.iconRadius
        iconBadge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        iconBadge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checklist",
                             accessibilityDescription: "选择清单")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(icon)

        // ---- 标题 ----
        let title = NSTextField(labelWithString: "选择提醒事项清单")
        title.font = .systemFont(ofSize: 15.5, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityLabel("选择提醒事项清单")

        // ---- 说明 ----
        let message = NSTextField(wrappingLabelWithString: messageText)
        message.font = .systemFont(ofSize: 12.5)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.setAccessibilityLabel(messageText)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.alignment = .center
        message.attributedStringValue = NSAttributedString(
            string: messageText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])
        message.translatesAutoresizingMaskIntoConstraints = false

        // ---- 正文（清单列表 + 新建清单）----
        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .centerX
        bodyStack.spacing = Metrics.rowGap
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let listCard = makeListCard(width: contentWidth)
        bodyStack.addArrangedSubview(listCard)

        let createRow = makeCreateRow(width: contentWidth)
        bodyStack.addArrangedSubview(createRow)

        let bodyContainer: NSView
        if scrolls {
            bodyContainer = makeScrollView(body: bodyStack,
                                           width: contentWidth,
                                           height: bodyHeight)
            NSLayoutConstraint.activate([
                bodyStack.heightAnchor.constraint(equalToConstant: bodyNatural),
            ])
        } else {
            bodyContainer = bodyStack
        }
        NSLayoutConstraint.activate([
            bodyContainer.widthAnchor.constraint(equalToConstant: contentWidth),
            bodyContainer.heightAnchor.constraint(equalToConstant: bodyHeight),
        ])

        // ---- 按钮行（取消在左）----
        let cancel = DialogButton(style: .secondary, title: "取消",
                                  target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let buttonStack = NSStackView(views: [cancel])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(buttonStack)

        // ---- 竖排一列（图标 → 标题 → 说明 → 正文 → 按钮）----
        let column = NSStackView(views: [iconBadge, title, message, bodyContainer, buttonRow])
        column.orientation = .vertical
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(Metrics.gapAfterIcon, after: iconBadge)
        column.setCustomSpacing(Metrics.gapAfterTitle, after: title)
        column.setCustomSpacing(6, after: message)
        column.setCustomSpacing(Metrics.gapBeforeButtons, after: bodyContainer)
        root.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.topPad),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.widthAnchor.constraint(equalToConstant: contentWidth),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,
                                           constant: -Metrics.bottomPad),

            iconBadge.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconBadge.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            icon.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),

            title.heightAnchor.constraint(equalToConstant: Metrics.titleHeight),

            buttonStack.centerXAnchor.constraint(equalTo: buttonRow.centerXAnchor),
            buttonStack.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: Metrics.buttonHeight),
        ])

        w.makeFirstResponder(cancel)

        // 装完内容再居中一次：窗口尺寸可能在布局后被调整过。
        //
        // `HUDWindow.centerOnScreen` 走的是 `WindowAnchor` ——
        // 也就是「以课表位置为锚点」那套，不是屏幕正中。
        HUDWindow.centerOnScreen(w)
        return w
    }

    /// 说明文字的高度（12.5pt，行距 +3）—— 和 `AlertDialogController.messageHeight` 一样。
    private func messageHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.alignment = .center
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: DialogStyle.messageMaxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: para],
            context: nil)
        return ceil(rect.height)
    }

    /// 清单列表卡片（一个圆角卡片，里面每行一个清单）。
    private func makeListCard(width: CGFloat) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.cardRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, name) in lists.enumerated() {
            let row = DayPanelListPickerRow(title: name,
                                            isCurrent: name == current)
            row.tag = index
            row.target = self
            row.action = #selector(listRowTapped(_:))
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // 一个清单都没有时给一行占位说明，别让卡片塌成一条缝。
        if lists.isEmpty {
            let empty = makeLabel("系统里还没有提醒事项清单", size: 11.5,
                                  color: NSColor.white.withAlphaComponent(0.45))
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
            empty.heightAnchor.constraint(equalToConstant: Metrics.rowHeight).isActive = true
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.cardPad),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.cardPad),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.cardPad),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Metrics.cardPad),
            stack.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -Metrics.cardPad * 2),
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: listCardHeight()),
        ])
        return card
    }

    private func listCardHeight() -> CGFloat {
        let count = max(1, lists.count)
        return CGFloat(count) * Metrics.rowHeight
            + CGFloat(max(0, count - 1)) * Metrics.rowGap
            + Metrics.cardPad * 2 + 2
    }

    /// 「新建清单」那一行（列表下方，独立的可点行）。
    private func makeCreateRow(width: CGFloat) -> NSView {
        let row = DayPanelListPickerRow(title: "新建清单…", isCurrent: false, isCreate: true)
        row.target = self
        row.action = #selector(createTapped)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: width),
            row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
        ])
        return row
    }

    /// 把正文塞进滚动视图。
    ///
    /// 文档视图不能上下都钉在 clip view 上 —— 那样内容永远不滚。
    private func makeScrollView(body: NSView, width: CGFloat, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = body
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: height),
            body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            body.widthAnchor.constraint(equalToConstant: width),
        ])
        return scroll
    }

    // MARK: - 动作

    @objc private func listRowTapped(_ sender: NSButton) {
        guard !finished, sender.tag >= 0, sender.tag < lists.count else { return }
        finish(.selected(lists[sender.tag]))
    }

    @objc private func createTapped() {
        guard !finished else { return }
        // 新建清单需要输入名字 —— 这里**不**自己弹输入框，
        // 交给主控（它要真的去 EventKit 建清单，并且已经有
        // `TimetableNameDialog` 那样的输入弹窗可以复用）。
        finish(.create(""))
    }

    @objc private func cancelTapped() {
        finish(.cancelled)
    }

    private func finish(_ result: DayPanelListPicker.Outcome) {
        guard !finished else { return }
        finished = true
        outcome = result
        guard let w = window else { return }
        w.close()
        NSApp.stopModal(withCode: .OK)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        outcome = .cancelled
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

/// 清单选择弹窗里的一行（可点的清单名 + 「当前选中」标记）。
final class DayPanelListPickerRow: NSButton {

    /// 这一行是不是「当前选中」的清单。
    let isCurrent: Bool
    /// 这一行是不是「新建清单」。
    let isCreate: Bool

    private var hovered = false

    init(title: String, isCurrent: Bool, isCreate: Bool = false) {
        self.isCurrent = isCurrent
        self.isCreate = isCreate
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.wantsLayer = true
        self.isTransparent = true
        self.focusRingType = .none
        self.setAccessibilityRole(.button)
        self.setAccessibilityLabel(isCurrent ? "\(title)，当前选中" : title)
        self.toolTip = title

        // 「当前选中」标记：右边一个 ✓。
        //
        // 用「✓」符号而不是高亮底色 —— 高亮底色跟 hover 底色会撞，
        // 两种状态叠在一起就分不清了。
        if isCurrent {
            let mark = NSImage(systemSymbolName: "checkmark",
                               accessibilityDescription: "当前选中")
            mark?.isTemplate = true
            let icon = NSImageView()
            icon.image = mark
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            icon.contentTintColor = NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 12),
                icon.heightAnchor.constraint(equalToConstant: 12),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(hovered ? 0.10 : 0.045).setFill()
        path.fill()

        let textWidth = bounds.width - 46
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5,
                                    weight: isCurrent ? .semibold : .regular),
            .foregroundColor: isCreate
                ? NSColor.white.withAlphaComponent(0.72)
                : (isCurrent ? NSColor.white : NSColor.white.withAlphaComponent(0.82)),
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        let size = text.size()
        let textRect = NSRect(x: 12, y: (bounds.height - size.height) / 2,
                              width: textWidth, height: size.height)
        if size.width > textWidth {
            (title as NSString).draw(in: textRect, withAttributes: attrs)
        } else {
            text.draw(at: NSPoint(x: 12, y: textRect.minY))
        }

        }
}

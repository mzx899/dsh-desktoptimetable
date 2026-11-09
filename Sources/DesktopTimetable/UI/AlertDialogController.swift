import AppKit

/// 通用弹窗（自建 HUD 窗口，不用系统 `NSAlert`）。
///
/// 全 app 的弹窗以前各写各的：系统 `NSAlert`、自建确认窗、输入窗各一种样式，
/// 按钮顺序、图标、语义色全不一致。这里抽一个统一的：
///
///   · 版式竖排居中：图标 → 标题 → 说明 → （列表卡片 / 选项行）→ 按钮行；
///   · 四级语义色（info / warning / destructive / question，见 `DialogStyle`）；
///   · 按钮行居中，**取消在左、主操作在右**（三按钮时顺序由 `buttons` 决定）；
///   · Esc 始终取消；非危险操作 Return = 主操作；危险操作默认焦点给「取消」，
///     Return 不绑定删除动作；
///   · 内容太长时列表区滚动，窗口高度不超过屏幕可见区的 80%；
///   · 120ms 淡入，尊重「减弱动态效果」。
///
/// 用法：`AlertDialogController.show(request)` → `AlertDialogOutcome`。
enum AlertDialogOutcome {
    /// 主操作。
    case confirmed
    /// 取消（按钮 / Esc / 关窗）。
    case cancelled
    /// 危险按钮（红色那个）。
    case destructive
    /// 选了第 N 个选项（`request.options` 的下标）。
    case chosen(Int)
}

/// 弹窗列表里的一行。
///
/// 两种来源：
///   · `.course` —— 课程（圆点用课程自己的颜色，文字自动拼成
///     「课名 · 星期 时间 · 教师 · 周次」）；
///   · `.line` —— 普通文本行（可选带一个颜色圆点）。
enum AlertDialogRow {
    case course(Course)
    case courseSummary(Course, badge: String?)
    case line(String, NSColor?)
}

/// 底部的一个按钮（显式指定时用；不指定就沿用老的 confirm / cancel 组合）。
struct AlertDialogButton {
    var role: DialogButtonRole
    var title: String
    /// VoiceOver 读法（默认用按钮文案）。
    var accessibilityLabel: String?

    init(role: DialogButtonRole, title: String, accessibilityLabel: String? = nil) {
        self.role = role
        self.title = title
        self.accessibilityLabel = accessibilityLabel
    }
}

/// 弹窗里的一个可选项（选项行 / 卡片）。
struct AlertDialogOption {
    /// 主文案。
    var title: String
    /// 副文案（可选，第二行）。
    var detail: String?
    /// VoiceOver 读法（默认拼成「title，detail」）。
    var accessibilityLabel: String?

    init(title: String, detail: String? = nil, accessibilityLabel: String? = nil) {
        self.title = title
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
    }

    /// VoiceOver 读法。
    var spokenText: String {
        accessibilityLabel ?? [title, detail].compactMap { $0 }.joined(separator: "，")
    }

    /// 说明文字的字号。
    static let detailFont = NSFont.systemFont(ofSize: 11.5)
    /// 标题的字号。
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// 说明文字最多折几行（再多就截断 —— 选项行是固定高度的小卡片）。
    static let maxDetailLines = 2
    /// 一行说明文字的行高。
    static let detailLineHeight: CGFloat = 15

    /// 说明文字在给定宽度下的高度（0 = 没有说明）。
    ///
    /// 宽度不够时折行，最多 `maxDetailLines` 行。
    func detailHeight(width: CGFloat) -> CGFloat {
        guard let detail, !detail.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let rect = (detail as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: AlertDialogOption.detailFont, .paragraphStyle: para],
            context: nil)
        let lines = min(AlertDialogOption.maxDetailLines,
                        max(1, Int(ceil(rect.height / AlertDialogOption.detailLineHeight))))
        return CGFloat(lines) * AlertDialogOption.detailLineHeight
    }
}

/// 一次弹窗的内容。
struct AlertDialogRequest {
    /// 语气（决定图标 / 主色 / 键盘默认焦点）。
    var severity: DialogSeverity = .info
    /// 标题。
    var title: String
    /// 说明文字。
    var message: String
    /// 列表行（课程卡片 / 普通文本行）。
    var rows: [AlertDialogRow] = []
    /// 可选项列表（点击即选中并关闭）。
    var options: [AlertDialogOption] = []
    /// 主操作按钮文案。
    var confirmTitle: String = "确认"
    /// 取消按钮文案。
    var cancelTitle: String = "取消"
    /// 是否显示主操作按钮。
    var showsConfirm: Bool = true
    /// 是否显示取消按钮。
    var showsCancel: Bool = true
    /// 顶部计数条（如「第 2 门 / 共 5 门」）。`nil` = 不显示。
    var counter: String? = nil
    /// 主操作按钮的填充色。
    ///
    /// `nil` = 用语义色（`severity` 决定）。给了就覆盖 ——
    /// 比如「琥珀警告图标 + 蓝色主按钮」这种 macOS 惯例
    /// （警告图标用黄色，默认按钮用蓝色，别让主操作看起来也像在报警）。
    var primaryColor: NSColor? = nil
    /// 显式指定的按钮行（三个以上按钮时用）。
    ///
    /// `nil` = 沿用 `confirmTitle` / `cancelTitle` 那套两按钮组合。
    /// 给了就**完全按这里来**（顺序、角色、文案），`showsConfirm` /
    /// `showsCancel` 不再起作用。
    var buttons: [AlertDialogButton]? = nil

    init(severity: DialogSeverity = .info,
         title: String,
         message: String,
         rows: [AlertDialogRow] = [],
         items: [Course] = [],
         options: [AlertDialogOption] = [],
         confirmTitle: String = "确认",
         cancelTitle: String = "取消",
         showsConfirm: Bool = true,
         showsCancel: Bool = true,
         counter: String? = nil,
         primaryColor: NSColor? = nil,
         buttons: [AlertDialogButton]? = nil) {
        self.severity = severity
        self.title = title
        self.message = message
        self.rows = rows + items.map { AlertDialogRow.course($0) }
        self.options = options
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.showsConfirm = showsConfirm
        self.showsCancel = showsCancel
        self.counter = counter
        self.primaryColor = primaryColor
        self.buttons = buttons
    }
}

/// 通用弹窗的控制器。
final class AlertDialogController: NSObject, NSWindowDelegate {

    /// 弹一次窗，等用户选完。
    @discardableResult
    static func show(_ request: AlertDialogRequest) -> AlertDialogOutcome {
        AlertDialogController(request: request).run()
    }

    /// 自检用：**只建窗口、不弹**（返回窗口让调用方检查它的位置）。
    ///
    /// 窗口位置由 `HUDWindow.make` 决定 —— 也就是「以课表中心为锚点」那套。
    static func makeWindowForTest(_ request: AlertDialogRequest) -> NSWindow {
        AlertDialogController(request: request).buildWindow()
    }

    private let request: AlertDialogRequest
    private var window: NSWindow?
    /// 用户的选择（关窗 / Esc → `.cancelled`）。
    private var outcome: AlertDialogOutcome = .cancelled
    /// 自定义按钮行里的危险按钮（红色那个）。
    private var destructiveButton: DialogButton?

    init(request: AlertDialogRequest) {
        self.request = request
        super.init()
    }

    // MARK: - 显示

    private func run() -> AlertDialogOutcome {
        let w = buildWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        // accessory App 光靠 `NSApp.activate` 抢不到前台 —— 显式激活整组窗口。
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

    // MARK: - 布局常量

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
        static let cardRadius: CGFloat = 9
        static let cardPad: CGFloat = 11
        static let rowHeight: CGFloat = 20
        static let rowGap: CGFloat = 6
        static let optionHeight: CGFloat = 46
        static let optionGap: CGFloat = 8
        static let bodySpacing: CGFloat = 14
        /// 列表区滚动时最多露这么多内容高度。
        static let scrollBodyMax: CGFloat = 260
    }

    // MARK: - 高度计算（确定性，不用试布局）

    /// 说明文字的高度（12.5pt，行距 +3）。
    static func messageHeight(_ text: String) -> CGFloat {
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

    private static func cardHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * Metrics.rowHeight
            + CGFloat(count - 1) * Metrics.rowGap
            + Metrics.cardPad * 2 + 2
    }

    private static func optionsHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * Metrics.optionHeight
            + CGFloat(count - 1) * Metrics.optionGap
    }

    /// 选项区的高度（按每个选项的实际折行数算）。
    ///
    /// 必须跟 `makeOptions` 里的算法一致 —— 否则窗口高度和内容对不上。
    private func optionsNaturalHeight(width: CGFloat) -> CGFloat {
        guard !request.options.isEmpty else { return 0 }
        var h: CGFloat = 0
        for option in request.options {
            let detailH = option.detailHeight(width: width - 24)
            h += 9 + 17 + (detailH > 0 ? detailH + 4 : 0) + 9
        }
        return h + Metrics.optionGap * CGFloat(request.options.count - 1)
    }

    /// 正文（说明 + 卡片 + 选项行）自然高度。
    private var bodyNaturalHeight: CGFloat {
        var h = Self.messageHeight(request.message)
        if !request.rows.isEmpty { h += Metrics.bodySpacing + Self.cardHeight(count: request.rows.count) }
        if !request.options.isEmpty {
            h += Metrics.bodySpacing + optionsNaturalHeight(width: Metrics.contentWidth)
        }
        return h
    }

    /// 计数条的高度（顶部「第 i 门 / 共 n 门」那一条）。
    static let counterHeight: CGFloat = 18

    /// 除正文以外那部分的固定高度。
    private var fixedHeight: CGFloat {
        var h = Metrics.topPad + Metrics.iconSize + Metrics.gapAfterIcon
            + Metrics.titleHeight + Metrics.gapAfterTitle
            + Metrics.gapBeforeButtons + Metrics.buttonHeight + Metrics.bottomPad
        if request.counter != nil { h += Self.counterHeight + 6 }
        return h
    }

    // MARK: - 建窗

    private func buildWindow() -> NSWindow {
        let width = Metrics.width
        let contentWidth = Metrics.contentWidth
        let severityColor = DialogStyle.color(request.severity)

        // ---- 先定高度：正文撑起来，但不许超过屏幕可见区的 80% ----
        let screen = NSScreen.main ?? NSScreen.screens.first
        let maxHeight = (screen?.visibleFrame.height ?? 900) * DialogStyle.maxHeightRatio
        let natural = bodyNaturalHeight
        var scrolls = DialogStyle.needsScroll(itemCount: request.rows.count,
                                             messageLength: request.message.count)
        var bodyHeight = natural
        if fixedHeight + natural > maxHeight {
            bodyHeight = max(120, maxHeight - fixedHeight)
            scrolls = true
        } else if scrolls {
            bodyHeight = min(natural, Metrics.scrollBodyMax)
        }
        let windowHeight = fixedHeight + bodyHeight

        let w = HUDWindow.make(title: request.title,
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

        // ---- 计数条（顶部正中：「第 i 门 / 共 n 门」）----
        var counterView: NSView? = nil
        if let counter = request.counter {
            let label = NSTextField(labelWithString: counter)
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.62)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityLabel(counter)

            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 9
            pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor, constant: -10),
                pill.heightAnchor.constraint(equalToConstant: Self.counterHeight),
            ])
            counterView = pill
        }

        // ---- 图标（顶部正中：浅色圆角底 + SF Symbol）----
        let iconBadge = NSView()
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = Metrics.iconRadius
        iconBadge.layer?.backgroundColor = severityColor.withAlphaComponent(0.18).cgColor
        iconBadge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: DialogStyle.symbolName(request.severity),
                             accessibilityDescription: request.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentTintColor = severityColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(icon)

        // ---- 标题 ----
        let title = NSTextField(labelWithString: request.title)
        title.font = .systemFont(ofSize: 15.5, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityLabel(request.title)

        // ---- 说明 ----
        let message = NSTextField(wrappingLabelWithString: request.message)
        message.font = .systemFont(ofSize: 12.5)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.setAccessibilityLabel(request.message)
        // 行距 +3：`NSTextField` 没有 `paragraphStyle` 属性，
        // 只能靠「带段落样式的富文本」设进去。
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.alignment = .center
        message.attributedStringValue = NSAttributedString(
            string: request.message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])
        message.translatesAutoresizingMaskIntoConstraints = false

        // ---- 正文容器 ----
        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .centerX
        bodyStack.spacing = Metrics.bodySpacing
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(message)
        if !request.rows.isEmpty {
            bodyStack.addArrangedSubview(makeCard(width: contentWidth))
        }
        if !request.options.isEmpty {
            bodyStack.addArrangedSubview(makeOptions(width: contentWidth))
        }

        let bodyContainer: NSView
        if scrolls {
            bodyContainer = makeScrollView(body: bodyStack,
                                          width: contentWidth,
                                          height: bodyHeight)
            // 文档视图的高度 = 内容自然高度（不钉在 clip view 上），
            // 这样超出视口的部分才真的能滚。
            NSLayoutConstraint.activate([
                bodyStack.heightAnchor.constraint(equalToConstant: natural),
            ])
        } else {
            bodyContainer = bodyStack
        }
        NSLayoutConstraint.activate([
            bodyContainer.widthAnchor.constraint(equalToConstant: contentWidth),
            bodyContainer.heightAnchor.constraint(equalToConstant: bodyHeight),
        ])

        // ---- 按钮行（取消在左，主操作在右）----
        //
        // 显式给了 `buttons` 就按它来（三按钮场景）；没给就走老的
        // confirm / cancel 组合。
        var buttons: [NSView] = []
        var cancelButton: DialogButton?
        var primaryButton: DialogButton?

        if let specs = request.buttons {
            for spec in specs {
                let style: DialogButton.Style
                switch spec.role {
                case .cancel:
                    style = .secondary
                case .destructive:
                    style = .primary(color: DialogStyle.color(.destructive))
                case .primary:
                    style = .primary(color: request.primaryColor ?? severityColor)
                }
                let b = DialogButton(style: style, title: spec.title,
                                     target: self, action: #selector(buttonTapped(_:)))
                b.tag = spec.role.tagValue
                b.setAccessibilityLabel(spec.accessibilityLabel ?? spec.title)
                switch spec.role {
                case .cancel:
                    // Esc 始终取消。
                    b.keyEquivalent = "\u{1b}"
                    cancelButton = b
                case .destructive:
                    // 危险按钮**不绑 Return** —— 免得回车顺手删掉东西。
                    destructiveButton = b
                case .primary:
                    // 危险操作（severity = .destructive）：Return 不绑定主操作，
                    // 免得回车顺手把东西删掉。
                    if DialogStyle.returnTriggersPrimary(
                        isDestructive: DialogStyle.isDestructive(request.severity)) {
                        b.keyEquivalent = "\r"
                    }
                    primaryButton = b
                }
                buttons.append(b)
            }
        } else {
            let cancel = DialogButton(style: .secondary, title: request.cancelTitle,
                                      target: self, action: #selector(cancelTapped))
            // Esc 始终取消。
            cancel.keyEquivalent = "\u{1b}"
            if request.showsCancel { buttons.append(cancel); cancelButton = cancel }

            let confirm = DialogButton(style: .primary(color: request.primaryColor ?? severityColor),
                                       title: request.confirmTitle,
                                       target: self, action: #selector(confirmTapped))
            // 危险操作：Return 不绑定删除动作（默认焦点给「取消」）。
            if DialogStyle.returnTriggersPrimary(
                isDestructive: DialogStyle.isDestructive(request.severity)) {
                confirm.keyEquivalent = "\r"
            }
            if request.showsConfirm { buttons.append(confirm); primaryButton = confirm }
        }

        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setAccessibilityLabel("按钮")

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(buttonStack)

        // ---- 竖排一列（计数条 → 图标 → 标题 → 正文 → 按钮）----
        var columnViews: [NSView] = []
        if let counterView { columnViews.append(counterView) }
        columnViews.append(contentsOf: [iconBadge, title, bodyContainer, buttonRow])
        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        if let counterView {
            column.setCustomSpacing(6, after: counterView)
        }
        column.setCustomSpacing(Metrics.gapAfterIcon, after: iconBadge)
        column.setCustomSpacing(Metrics.gapAfterTitle, after: title)
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

        // 默认焦点：
        //   · 危险操作（severity = .destructive）→ 给「取消」，Return 不删东西；
        //   · 其余 → 给主操作。
        //
        // 注意：三按钮里**主操作本身是安全的那条**时（比如「保留」是主操作、
        // 「删除」只是旁边一个红色按钮），焦点给主操作是对的 ——
        // Return 走的是安全分支，危险按钮不绑 Return。
        let focusTarget: NSView? = {
            let role = DialogStyle.defaultFocus(
                isDestructive: DialogStyle.isDestructive(request.severity))
            if role == .cancel {
                if let c = cancelButton { return c }
                if let d = destructiveButton { return d }
                return primaryButton
            }
            if let p = primaryButton { return p }
            return cancelButton ?? destructiveButton
        }()
        if let focusTarget {
            w.makeFirstResponder(focusTarget)
        }

        // 装完内容再居中一次：窗口尺寸可能在布局后被调整过。
        HUDWindow.centerOnScreen(w)
        return w
    }

    /// 把正文塞进滚动视图。
    ///
    /// **文档视图不能上下都钉在 clip view 上** —— 那样文档高度 = 视口高度，
    /// 内容永远不滚，超出部分直接被裁掉。正确做法：只钉左右 + 顶部 + 宽度，
    /// 高度由内容自己算，clip view 负责滚动。
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

    // MARK: - 列表卡片 / 选项行

    /// 列表卡片：内部左对齐，每条带圆点。
    private func makeCard(width: CGFloat) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.cardRadius
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: request.rows.map { Self.row(for: $0) })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.cardPad),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.cardPad),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.cardPad),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Metrics.cardPad),
            stack.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -Metrics.cardPad * 2),
            card.widthAnchor.constraint(equalToConstant: width),
            card.heightAnchor.constraint(equalToConstant: Self.cardHeight(count: request.rows.count)),
        ])
        return card
    }

    /// 一行：圆点 + 文字。
    private static func row(for entry: AlertDialogRow) -> NSView {
        let text: NSAttributedString
        let color: NSColor?
        var spoken: String

        switch entry {
        case .course(let c):
            let day = Schedule.dayNames[max(0, min(6, c.day - 1))]
            let time = Schedule.timeRange(block: c.block)
            let attr = NSMutableAttributedString(
                string: c.name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ])
            var tail = "  ·  \(day) \(time)"
            if !c.teacher.isEmpty { tail += " · \(c.teacher)" }
            tail += " · \(c.weeksLabel) 周"
            attr.append(NSAttributedString(
                string: tail,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            text = attr
            color = TimetablePalette.accent(for: c)
            spoken = [c.name, day, time, c.teacher, "\(c.weeksLabel) 周"]
                .filter { !$0.isEmpty }
                .joined(separator: "，")
        case .courseSummary(let c, let badge):
            // 课名 + 教师 · 地点 · 周次（不显示星期时间 —— 这是整门课的概览）
            let attr = NSMutableAttributedString(
                string: c.name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ])
            var tail = ""
            if !c.teacher.isEmpty { tail += "  ·  \(c.teacher)" }
            if !c.loc.isEmpty { tail += "  ·  \(c.loc)" }
            tail += "  ·  \(c.weeksLabel) 周"
            attr.append(NSAttributedString(
                string: tail,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            text = attr
            color = TimetablePalette.accent(for: c)
            var parts = [c.name, c.teacher, c.loc, "\(c.weeksLabel) 周"]
            if let badge { parts.append(badge) }
            spoken = parts.filter { !$0.isEmpty }.joined(separator: "，")
        case .line(let line, let dotColor):
            text = NSAttributedString(string: line, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.labelColor,
            ])
            color = dotColor
            spoken = line
        }

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (color ?? NSColor.white.withAlphaComponent(0.5)).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = text
        field.translatesAutoresizingMaskIntoConstraints = false
        // VoiceOver：整条读成一句话，不是一串孤立数字。
        field.setAccessibilityLabel(spoken)

        var rowViews: [NSView] = [dot, field]
        if case .courseSummary(_, let badge) = entry, let badge, !badge.isEmpty {
            rowViews.append(DialogBadgeView(text: badge))
        }
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
        ])
        return row
    }

    /// 选项行（点击即选中）。
    private func makeOptions(width: CGFloat) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.optionGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        var heights: [CGFloat] = []
        for (index, option) in request.options.enumerated() {
            let row = DialogOptionRow(option: option)
            row.target = self
            row.action = #selector(optionTapped(_:))
            row.tag = index
            // 行高按说明文字实际折行数算 —— 说明太长就折行，不会溢出卡片。
            let detailH = option.detailHeight(width: width - 24)
            let h = 9 + 17 + (detailH > 0 ? detailH + 4 : 0) + 9
            row.optionHeight = h
            heights.append(h)
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: h).isActive = true
            // ⚠️ 宽度必须**钉死成整行内容宽**（2026-11-09 修）。
            //
            // 以前只给了 stack 的宽度、`alignment = .leading`，而 `DialogOptionRow`
            // 是 `NSButton` —— 它的宽度取**标题文字的自然宽度**，
            // 于是卡片比内容区窄一截、还左对齐：右边留白明显比左边多
            // （用户：「为什么不处于窗口的中间位置，明显是右边留白更多，左边少」）。
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let total = heights.reduce(0, +) + Metrics.optionGap * CGFloat(max(0, heights.count - 1))
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: width),
            stack.heightAnchor.constraint(equalToConstant: total),
        ])
        return stack
    }

    // MARK: - 按钮

    @objc private func confirmTapped() {
        outcome = .confirmed
        finish()
    }

    @objc private func cancelTapped() {
        outcome = .cancelled
        finish()
    }

    /// 自定义按钮行里点了某个按钮。
    @objc private func buttonTapped(_ sender: NSButton) {
        switch sender.tag {
        case DialogButtonRole.cancel.tagValue:
            outcome = .cancelled
        case DialogButtonRole.destructive.tagValue:
            outcome = .destructive
        default:
            outcome = .confirmed
        }
        finish()
    }

    @objc private func optionTapped(_ sender: NSButton) {
        outcome = .chosen(sender.tag)
        finish()
    }

    private func finish() {
        guard let w = window else { return }
        w.close()
        NSApp.stopModal(withCode: .OK)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 点标题栏的关闭按钮 = 取消
        outcome = .cancelled
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

// MARK: - 自绘按钮

/// 弹窗底部按钮：语义色填充 + 白字 / 白色 12% 底的次要按钮。
final class DialogButton: NSButton {

    enum Style {
        /// 主操作：语义色填充 + 白字。
        case primary(color: NSColor)
        /// 次要：白色 12% 底。
        case secondary
    }

    private let style: Style
    private var focused = false

    init(style: Style, title: String, target: AnyObject?, action: Selector) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        // 关掉系统焦点环：按钮在 draw(_:) 里已经自己画了一圈白色焦点环。
        // 否则主按钮既绑了 Return 又被设成第一响应者，AppKit 会再叠一圈
        // 蓝色 focus ring，看起来像蓝色边框夹着黄色按钮。
        self.focusRingType = .none
        self.setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(size.width, 72), height: 31)
    }

    override func becomeFirstResponder() -> Bool {
        focused = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        switch style {
        case .primary(let color):
            (isHighlighted ? color.withAlphaComponent(0.75) : color).setFill()
        case .secondary:
            let color = NSColor.white.withAlphaComponent(0.12)
            (isHighlighted ? color.withAlphaComponent(0.2) : color).setFill()
        }
        path.fill()

        // 焦点环（Tab 走一圈要看得见）
        if focused {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                    xRadius: 5, yRadius: 5)
            NSColor.white.withAlphaComponent(0.85).setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }
}

/// 课程行右边的小徽标（如「受保护」）。
///
/// 琥珀色描边 + 淡底，跟 app 里「来源标签」的配色一致。
final class DialogBadgeView: NSView {

    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ])
        return NSSize(width: ceil(size.width) + 12, height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5)
        NSColor(srgbRed: 0.96, green: 0.65, blue: 0.19, alpha: 0.16).setFill()
        path.fill()
        NSColor(srgbRed: 0.96, green: 0.65, blue: 0.19, alpha: 0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.36, alpha: 1),
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                           y: (bounds.height - size.height) / 2))
    }
}

/// 弹窗里的选项行（可点击的卡片）。
final class DialogOptionRow: NSButton {

    private let option: AlertDialogOption
    private var hovered = false
    /// 行高（由外部按说明文字的折行数算好传进来）。
    var optionHeight: CGFloat = 46

    init(option: AlertDialogOption) {
        self.option = option
        super.init(frame: .zero)
        self.title = option.title
        self.isBordered = false
        self.wantsLayer = true
        self.setAccessibilityLabel(option.spokenText)
        self.setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: optionHeight)
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
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(hovered ? 0.12 : 0.06).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textWidth = bounds.width - 24
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: AlertDialogOption.titleFont,
            .foregroundColor: NSColor.white,
        ]
        let titleText = NSAttributedString(string: option.title, attributes: titleAttrs)
        let titleSize = titleText.size()
        // 标题太长就截断（加省略号），不能顶出卡片。
        let titleRect = NSRect(x: 12, y: bounds.height - 9 - titleSize.height,
                               width: textWidth, height: titleSize.height)
        if titleSize.width > textWidth {
            (option.title as NSString).draw(
                in: titleRect,
                withAttributes: titleAttrs)
        } else {
            titleText.draw(at: NSPoint(x: 12, y: titleRect.minY))
        }

        guard let detail = option.detail, !detail.isEmpty else { return }
        let detailH = option.detailHeight(width: textWidth)
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: AlertDialogOption.detailFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        var attrs = detailAttrs
        attrs[.paragraphStyle] = para
        let detailRect = NSRect(x: 12, y: 9, width: textWidth, height: detailH)
        // 超过 2 行就截断（尾部加省略号）—— 说明再长也不能溢出卡片。
        (detail as NSString).draw(with: detailRect,
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: attrs)
    }
}

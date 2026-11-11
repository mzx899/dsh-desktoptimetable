import AppKit

/// 「地区」选择器 —— 设置里点「地区」那一行弹出来的城市列表。
///
/// 造型和清单选择器（`DayPanelListPicker`）一致：同一个 HUD 材质、同一个深色底、
/// 同样的 120ms 淡入、同样的 Esc = 取消；区别只是上面多一个**搜索框**。
///
/// 列表结构（用户 2026-11-10 要求）：
///   · 最上面「热门城市」；
///   · 其余按**拼音首字母** A–Z 分段；
///   · 搜索框里输入中文 / 拼音都能过滤（输入时不再分段，只留命中的城市）。
enum CityPickerDialog {

    /// 弹一次选择器。
    ///
    /// - Parameter current: 当前选中的地区（会在列表里打「✓」）。
    /// - Returns: 选中的城市名；取消 / 关窗 → nil。
    static func show(current: String?) -> String? {
        CityPickerController(current: current).run()
    }

    /// 自检用：**只建窗口、不弹**（返回窗口让调用方检查内容 / 位置）。
    static func buildWindowForTest(current: String? = nil,
                                   query: String = "") -> NSWindow {
        let c = CityPickerController(current: current, query: query)
        return c.buildWindowForTest()
    }

    /// 自检用：在视图树里找某个城市那一行（返回 `NSView`，不暴露私有类型）。
    static func findRowForTest(in view: NSView, city: String) -> NSView? {
        let c = CityPickerController(current: nil, query: "")
        return c.findRow(in: view, city: city)
    }

    /// 自检用：建窗 + 对某个城市**模拟一次单击 / 双击**，返回（当前高亮, 已确认的地区）。
    ///
    /// 单击应该是「只高亮、不确认」；双击才是「确认」（2026-11-10 用户要求）。
    static func simulateClickForTest(city: String,
                                     doubleClick: Bool) -> (highlighted: String?, confirmed: String?) {
        let c = CityPickerController(current: nil, query: "")
        let w = c.buildWindowForTest()
        guard let content = w.contentView,
              let row = c.findRow(in: content, city: city) else {
            return (nil, nil)
        }
        let count = doubleClick ? 2 : 1
        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil,
                                      eventNumber: 0, clickCount: count, pressure: 1) {
            row.mouseDown(with: e)
        }
        return (c.highlightedCity, c.confirmedCity)
    }
}

/// 选择器的私有实现。
private final class CityPickerController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {

    private let current: String?
    private var window: NSWindow?
    private var result: String?
    private var finished = false

    /// 列表容器（重建时整块换掉）。
    private var listStack: NSStackView?
    private var scrollView: NSScrollView?
    /// 搜索框（自检要读它）。
    private(set) var searchField: NSSearchField?
    /// 当前列表里显示的城市（按显示顺序，自检用）。
    private(set) var visibleCities: [String] = []
    /// 列表里的城市行（按显示顺序；只更新高亮，不重建列表）。
    private var rows: [CityPickerRow] = []
    /// 当前**高亮**的城市（单击选中；双击才确认关窗）。
    private(set) var highlightedCity: String?
    /// 已经**确认**的地区（双击之后才有；自检用）。
    private(set) var confirmedCity: String?
    /// 当前列表的分段标题（自检用）。
    private(set) var visibleSections: [String] = []

    private enum Metrics {
        static let width: CGFloat = 380
        static let pad: CGFloat = 20
        static let contentWidth: CGFloat = width - pad * 2
        static let rowHeight: CGFloat = 26
        static let sectionHeight: CGFloat = 20
        static let searchHeight: CGFloat = 26
        static let maxHeight: CGFloat = 560
    }

    /// 打开时搜索框里预填的内容（出图 / 自检用；正常打开是空）。
    private let initialQuery: String

    init(current: String?, query: String = "") {
        self.current = current
        self.initialQuery = query
        super.init()
    }

    // MARK: - 弹出

    func run() -> String? {
        let w = buildWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)?
            .activate(options: [.activateAllWindows])
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                w.animator().alphaValue = 1
            }
        }
        NSApp.runModal(for: w)
        let out = result
        result = nil
        window = nil
        return out
    }

    func buildWindowForTest() -> NSWindow { buildWindow() }

    /// 自检用：当前列表里的城市 / 分段标题 / 搜索框文字。
    var testSnapshot: (cities: [String], sections: [String], query: String) {
        (visibleCities, visibleSections, searchField?.stringValue ?? "")
    }

    // MARK: - 建窗

    private func buildWindow() -> NSWindow {
        let w = HUDWindow.make(title: "选择地区",
                               size: NSSize(width: Metrics.width, height: Metrics.maxHeight),
                               miniaturizable: false)
        w.delegate = self
        w.appearance = NSAppearance(named: .darkAqua)

        let root = HUDWindow.installContent(in: w, root: NSView())
        HUDWindow.installDarkBackdrop(in: w, below: root)

        // ---- 标题 ----
        let title = NSTextField(labelWithString: "选择地区")
        title.font = .systemFont(ofSize: 15.5, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "天气按这里选的地区取数（后台程序拿不到系统定位）")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)
        hint.translatesAutoresizingMaskIntoConstraints = false

        // ---- 搜索框 ----
        let search = NSSearchField()
        search.placeholderString = "搜索城市 / 拼音"
        search.font = .systemFont(ofSize: 12.5)
        search.delegate = self
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        searchField = search

        // ---- 列表（滚动）----
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scrollView = scroll

        // ---- 底部：取消 ----
        let cancel = DialogButton(style: .secondary, title: "取消",
                                  target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(hint)
        root.addSubview(search)
        root.addSubview(scroll)
        root.addSubview(cancel)

        NSLayoutConstraint.activate([
            // ⚠️ 这里是 `fullSizeContentView` —— 左上角那三个红绿灯是**压在内容上**的。
            // 以前是 18pt，标题正好和红绿灯撞在一起（用户截图反馈）。留出 34pt。
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.pad),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.pad),

            search.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.pad),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.pad),
            search.heightAnchor.constraint(equalToConstant: Metrics.searchHeight),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.pad),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.pad),
            scroll.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -12),

            cancel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 118),
            cancel.heightAnchor.constraint(equalToConstant: 30),
        ])

        search.stringValue = initialQuery
        rebuildList(query: initialQuery, in: scroll)
        HUDWindow.centerOnScreen(w)
        w.makeFirstResponder(search)
        return w
    }

    // MARK: - 列表

    private func rebuildList(query: String, in scroll: NSScrollView? = nil) {
        let target = scroll ?? scrollView
        guard let scrollView = target else { return }
        let sections = WeatherCityCatalog.sections(matching: query)

        visibleCities = sections.flatMap(\.cities)
        visibleSections = sections.map(\.title)
        rows = []

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        if sections.isEmpty {
            let empty = NSTextField(labelWithString: "没有匹配的城市，换个名字试试")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor.white.withAlphaComponent(0.5)
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
            empty.heightAnchor.constraint(equalToConstant: Metrics.rowHeight).isActive = true
        }

        // 搜索时**只列名称**（2026-11-10 用户要求）：不分「热门城市」/ A–Z 段，
        // 免得一屏里大半是分组标题。
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for section in sections {
            if !searching {
                let header = NSTextField(labelWithString: section.title)
                header.font = .systemFont(ofSize: 10.5, weight: .semibold)
                header.textColor = NSColor.white.withAlphaComponent(0.40)
                header.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(header)
                header.heightAnchor.constraint(equalToConstant: Metrics.sectionHeight).isActive = true
            }

            for city in section.cities {
                let highlighted = (city == (highlightedCity ?? current))
                let row = CityPickerRow(city: city, isCurrent: highlighted)
                // 单击 = 选中（高亮那一条）；**双击** = 确认并关窗（用户 2026-11-10 要求）。
                row.onSelect = { [weak self] city in
                    self?.highlight(city)
                }
                row.onConfirm = { [weak self] city in
                    self?.confirm(city)
                }
                stack.addArrangedSubview(row)
                rows.append(row)
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight).isActive = true
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        // ⚠️ **右边给滚动条留 14pt**（2026-11-10 用户反馈：高亮那一条被滚动条压住一角）。
        // NSScrollView 的 scroller 是 overlay 的，压在内容上；列表铺满整宽时，
        // 最后十几像素就被它盖住了。这里把内容收窄一点。
        // 用户反馈「还是有点压住」→ 从 14 加到 22。
        let scrollerGutter: CGFloat = 22
        let container = FlippedContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                            constant: -scrollerGutter),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Metrics.contentWidth),
        ])

        scrollView.documentView = container
        container.layoutSubtreeIfNeeded()
        listStack = stack
    }

    /// 自检用：在视图树里按城市名找那一行。
    func findRow(in view: NSView, city: String) -> CityPickerRow? {
        for sub in view.subviews {
            if let row = sub as? CityPickerRow, row.city == city { return row }
            if let hit = findRow(in: sub, city: city) { return hit }
        }
        return nil
    }

    // MARK: - 事件

    func controlTextDidChange(_ obj: Notification) {
        rebuildList(query: searchField?.stringValue ?? "")
    }

    /// 单击：只把这一条**高亮**（不关窗）。
    private func highlight(_ city: String) {
        guard !finished else { return }
        highlightedCity = city
        for row in rows { row.setChosen(row.city == city) }
    }

    /// 双击：确认这一个地区并关窗。
    private func confirm(_ city: String) {
        guard !finished else { return }
        finished = true
        highlightedCity = city
        result = city
        confirmedCity = city
        close()
    }

    @objc private func cancelTapped() {
        guard !finished else { return }
        finished = true
        result = nil
        close()
    }

    private func close() {
        guard let w = window else { return }
        NSApp.stopModal(withCode: .OK)
        w.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { result = nil; finished = true }
        NSApp.stopModal(withCode: .OK)
    }
}

/// 列表容器：`isFlipped = true`，这样内容从**顶部**开始排（否则会贴在底部）。
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// 列表里的一行城市：**单击选中（高亮）**、**双击确认**（2026-11-10 用户要求）。
///
/// 为什么不用 NSButton 的 target/action：那套要等 `mouseUp`，而且窗口不在前台 /
/// 列表在滚动视图里时第一下只点亮不算数 —— 用户看到的就是「点了没反应」。
/// 这里自己处理 `mouseDown`，按 `clickCount` 区分单击 / 双击。
private final class CityPickerRow: NSView {

    let city: String
    /// 单击：选中这一条（只高亮，不关窗）。
    var onSelect: ((String) -> Void)?
    /// 双击：确认这一个地区（关窗）。
    var onConfirm: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var chosen: Bool

    init(city: String, isCurrent: Bool) {
        self.city = city
        self.chosen = isCurrent
        super.init(frame: .zero)
        wantsLayer = true
        // 左右圆角要**一样**、都不要出现明显直角（用户 2026-11-10 反馈）：
        // 半径 6 在窄行里几乎看不出来，右端还会被滚动条那一侧显得像直角。
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        label.stringValue = city
        label.font = .systemFont(ofSize: 12.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已选地区")
        check.contentTintColor = NSColor.systemTeal
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -6),

            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
        ])

        setAccessibilityLabel(city)
        applyChosenStyle()
    }

    /// 高亮状态（单击选中 / 当前地区）。
    func setChosen(_ value: Bool) {
        guard chosen != value else { return }
        chosen = value
        applyChosenStyle()
    }

    private func applyChosenStyle() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(chosen ? 0.12 : 0.0).cgColor
        layer?.borderWidth = chosen ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(chosen ? 0.18 : 0).cgColor
        label.textColor = NSColor.white.withAlphaComponent(chosen ? 0.98 : 0.78)
        check.isHidden = !chosen
    }

    /// 窗口没成为 key 时第一次点击也要算数。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 整行接管命中（子视图会吃掉点击）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onConfirm?(city)
        } else {
            onSelect?(city)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

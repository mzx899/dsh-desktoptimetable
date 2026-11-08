import AppKit

/// 「日期覆盖层」卡片里的**第三行：已完成的提醒事项**。
///
/// 版式（和卡片里其他行同一套）：
/// ```
/// 已完成的提醒事项                                    ⌄
/// 查看、恢复或删除已完成的提醒事项
///
///   [ 搜索标题… ]                      [ 所有清单 ⌄ ]
///   已删除 12 条 / 失败原因…
///   ┌──────────────────────────────────────────────┐
///   │ 买牛奶                    清单 · 完成 … · 到期 … │
///   │                            [恢复] [删除]        │
///   └──────────────────────────────────────────────┘
///   …（最多 260pt，内部滚动）
///   共 37 条                    [加载更多] [全部删除…]
/// ```
///
/// 这一层是**纯 UI**：不读 EventKit、不碰设置，只把 `ViewModel` 画出来，
/// 用户操作以闭包回调给 `SettingsWindowController`。
final class CompletedRemindersRow: NSView {

    /// 入口的可用状态。
    enum Access: Equatable {
        /// 接入开关关着。
        case disabled
        /// 接入开着，但提醒事项还没授权。
        case needsAuthorization
        /// 可以用。
        case ready
    }

    /// 清单筛选下拉框里的一项（`identifier == nil` 表示「所有清单」）。
    struct ListOption: Equatable {
        var identifier: String
        var title: String
    }

    /// 一次渲染需要的全部状态。
    struct ViewModel {
        var access: Access = .disabled
        var isExpanded = false
        var isLoading = false
        var isLoaded = false
        var loadError: String?
        var items: [CompletedReminder] = []
        var hasMore = false
        var totalCompleted = 0
        var matchingCount = 0
        var lists: [ListOption] = []
        var selectedListIdentifier: String?
        var searchText = ""
        var busy = false
        var progressText: String?
        /// 操作结果（「已删除 N 条」/ 失败原因）。
        var notice: String?
        var noticeIsError = false
    }

    /// 自检用的一行文字快照。
    struct ItemProbe {
        var title: String
        var listTitle: String
        /// 界面上**真正显示**的副文案（清单 · 完成时间 · 到期时间）。
        var detailText: String
        var completionText: String
        var dueText: String
        var restoreEnabled: Bool
        var recurringNoteVisible: Bool
    }

    // MARK: - 公开回调

    /// 用户点了这一行 / 再点一次收起（参数 = 目标展开状态）。
    var onToggleExpanded: ((Bool) -> Void)?
    /// 读取失败后点「重试」。
    var onRetry: (() -> Void)?
    /// 未授权时点「去系统设置」。
    var onOpenSystemSettings: (() -> Void)?
    /// 搜索词变化（主控做防抖）。
    var onSearchChange: ((String) -> Void)?
    /// 清单筛选变化（`nil` = 所有清单）。
    var onListFilterChange: ((String?) -> Void)?
    /// 底部「加载更多」。
    var onLoadMore: (() -> Void)?
    /// 单条「恢复」。
    var onRestore: ((CompletedReminder) -> Void)?
    /// 单条「删除」。
    var onDelete: ((CompletedReminder) -> Void)?
    /// 底部「全部删除…」。
    var onDeleteAll: (() -> Void)?

    // MARK: - 视觉常量

    /// 列表区最大高度（规格建议 240–280pt）。
    static let listMaxHeight: CGFloat = 260
    /// 列表区最小高度（空状态 / 加载中不塌成一条缝）。
    static let listMinHeight: CGFloat = 56
    /// 每次异步追加渲染多少行（避免一次 200 行卡主线程）。
    private static let renderBatchSize = 25

    // MARK: - 子视图

    private let header = HeaderButton()
    private let titleLabel = NSTextField(labelWithString: "已完成的提醒事项")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let authorizeButton = NSButton(title: "去系统设置", target: nil, action: nil)

    private let bodyStack = NSStackView()
    private let toolbar = NSView()
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let stateRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let stateLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let docView = FlippedView()
    private let rowsStack = NSStackView()
    private let footer = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let loadMoreButton = NSButton(title: "加载更多", target: nil, action: nil)
    private let deleteAllButton = NSButton(title: "全部删除…", target: nil, action: nil)

    /// 收起态的行高（header 底边 = row 底边）。
    private var collapsedBottom: NSLayoutConstraint!
    /// 展开态的行高（bodyStack 底边 = row 底边）。
    private var expandedBottom: NSLayoutConstraint!

    private var viewModel = ViewModel()
    /// 已经渲染出来的条目（判断「只是追加」还是「要重建」）。
    private var renderedItems: [CompletedReminder] = []
    private var itemViews: [CompletedReminderItemView] = []
    /// 异步分批渲染的代号 —— 重建时旧批次直接丢掉。
    private var renderGeneration = 0
    /// 已经排到第几条（异步批次之间防止重复追加）。
    private var renderCursor = 0
    /// 是否已经有一个批次在路上。
    private var renderPending = false
    /// 下拉框当前对应关系（标题 ↔ 清单标识）。
    private var popupListIdentifiers: [String] = []
    private var listsSignature = ""

    // MARK: - 初始化

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        buildHeader()
        buildBody()
        collapsedBottom.isActive = true
        expandedBottom.isActive = false
        applyAccess()
        applyExpansion()
        applyState()
        applyFooter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 公开更新入口

    /// 灌入完整状态（展开 / 加载 / 列表 / 搜索 / 筛选 / 进度）。
    func update(_ viewModel: ViewModel) {
        self.viewModel = viewModel
        applyAccess()
        applyExpansion()
        applyToolbar()
        applyState()
        applyItems()
        applyFooter()
    }

    /// 只更新入口可用状态（卡片 `update(...)` 里用，避免和完整更新打架）。
    func updateAccess(_ access: Access) {
        guard viewModel.access != access else { return }
        viewModel.access = access
        applyAccess()
        applyExpansion()
    }

    // MARK: - 建视图

    private func buildHeader() {
        header.isBordered = false
        header.focusRingType = .none
        header.isTransparent = true
        header.title = "已完成的提醒事项"
        header.target = self
        header.action = #selector(headerTapped)
        header.setAccessibilityLabel("已完成的提醒事项")
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.38)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(subtitleLabel)

        chevron.image = NSImage(systemSymbolName: "chevron.down",
                                accessibilityDescription: "展开")
        chevron.image?.isTemplate = true
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(chevron)

        // 「去系统设置」是 header 的**兄弟**，不是它的子视图 ——
        // header 的 hitTest 会吃掉整块区域，按钮放里面就点不中了。
        authorizeButton.bezelStyle = .rounded
        authorizeButton.controlSize = .small
        authorizeButton.font = .systemFont(ofSize: 11)
        authorizeButton.target = self
        authorizeButton.action = #selector(openSystemSettings)
        authorizeButton.isHidden = true
        authorizeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(authorizeButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 3),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            chevron.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            subtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor,
                                                     constant: -8),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),

            authorizeButton.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            authorizeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    private func buildBody() {
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyStack)

        // ---- 搜索 / 清单筛选 ----
        searchField.placeholderString = "搜索标题"
        searchField.font = .systemFont(ofSize: 12)
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(searchField)

        filterPopup.font = .systemFont(ofSize: 11.5)
        filterPopup.controlSize = .small
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.addItem(withTitle: "所有清单")
        toolbar.addSubview(filterPopup)

        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // ---- 操作结果 / 失败说明 ----
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isHidden = true
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- 加载中 / 空状态 / 读取失败 ----
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 11.5)
        stateLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        stateLabel.lineBreakMode = .byWordWrapping
        stateLabel.maximumNumberOfLines = 2
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.font = .systemFont(ofSize: 11)
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 8
        stateRow.addArrangedSubview(spinner)
        stateRow.addArrangedSubview(stateLabel)
        stateRow.addArrangedSubview(retryButton)
        stateRow.isHidden = true
        stateRow.translatesAutoresizingMaskIntoConstraints = false

        // ---- 列表（限高、内部滚动）----
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = docView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.isHidden = true

        docView.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(rowsStack)

        // ---- 底部：数量 / 加载更多 / 全部删除 ----
        countLabel.font = .systemFont(ofSize: 10.5)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(countLabel)

        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.controlSize = .small
        loadMoreButton.font = .systemFont(ofSize: 11)
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreTapped)
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(loadMoreButton)

        deleteAllButton.bezelStyle = .rounded
        deleteAllButton.controlSize = .small
        deleteAllButton.target = self
        deleteAllButton.action = #selector(deleteAllTapped)
        deleteAllButton.attributedTitle = NSAttributedString(
            string: "全部删除…",
            attributes: [
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.88),
                .font: NSFont.systemFont(ofSize: 11),
            ])
        deleteAllButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(deleteAllButton)

        footer.translatesAutoresizingMaskIntoConstraints = false

        bodyStack.addArrangedSubview(toolbar)
        bodyStack.addArrangedSubview(noticeLabel)
        bodyStack.addArrangedSubview(stateRow)
        bodyStack.addArrangedSubview(scroll)
        bodyStack.addArrangedSubview(footer)
        bodyStack.isHidden = true

        NSLayoutConstraint.activate([
            bodyStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            searchField.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            searchField.topAnchor.constraint(greaterThanOrEqualTo: toolbar.topAnchor),
            searchField.bottomAnchor.constraint(lessThanOrEqualTo: toolbar.bottomAnchor),
            filterPopup.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            filterPopup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            filterPopup.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.trailingAnchor,
                                                 constant: 8),
            filterPopup.widthAnchor.constraint(equalToConstant: 172),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            noticeLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),

            stateRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),

            scroll.heightAnchor.constraint(equalToConstant: Self.listMaxHeight),
            docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: docView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),

            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            countLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: loadMoreButton.leadingAnchor,
                                                 constant: -8),
            deleteAllButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            deleteAllButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            loadMoreButton.trailingAnchor.constraint(equalTo: deleteAllButton.leadingAnchor,
                                                     constant: -8),
            loadMoreButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        // 每一块都要撑满 body 宽度（NSStackView 的 alignment 不会自动拉宽）。
        for view in [toolbar, noticeLabel, stateRow, scroll, footer] {
            view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }

        collapsedBottom = header.bottomAnchor.constraint(equalTo: bottomAnchor)
        expandedBottom = bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor)
    }

    // MARK: - 状态应用

    private func applyAccess() {
        let ready = viewModel.access == .ready
        let titleColor = ready ? NSColor.white.withAlphaComponent(0.85)
                               : NSColor.white.withAlphaComponent(0.38)
        titleLabel.textColor = titleColor
        header.isEnabled = ready
        // 置灰时不能让人看出来「可以点」。
        chevron.contentTintColor = ready
            ? NSColor.white.withAlphaComponent(0.45)
            : NSColor.white.withAlphaComponent(0.22)

        switch viewModel.access {
        case .ready:
            subtitleLabel.stringValue = "查看、恢复或删除已完成的提醒事项"
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.38)
            authorizeButton.isHidden = true
        case .needsAuthorization:
            // 副标题带「未授权」，行内再给一个小号入口（不主动弹权限框）。
            subtitleLabel.stringValue = "未授权 · 开启接入并获得提醒事项权限后可查看"
            subtitleLabel.textColor = NSColor(srgbRed: 0.95, green: 0.72,
                                              blue: 0.30, alpha: 0.9)
            authorizeButton.isHidden = false
        case .disabled:
            subtitleLabel.stringValue = "开启接入并获得提醒事项权限后可查看"
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.38)
            authorizeButton.isHidden = true
        }
        subtitleLabel.setAccessibilityLabel(subtitleLabel.stringValue)
        header.setAccessibilityLabel("已完成的提醒事项，\(subtitleLabel.stringValue)")
    }

    private func applyExpansion() {
        let expanded = viewModel.access == .ready && viewModel.isExpanded
        bodyStack.isHidden = !expanded
        if expanded {
            collapsedBottom.isActive = false
            expandedBottom.isActive = true
        } else {
            expandedBottom.isActive = false
            collapsedBottom.isActive = true
        }
        let symbol = expanded ? "chevron.up" : "chevron.down"
        chevron.image = NSImage(systemSymbolName: symbol,
                                accessibilityDescription: expanded ? "收起" : "展开")
        chevron.image?.isTemplate = true
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = viewModel.access == .ready
            ? NSColor.white.withAlphaComponent(0.45)
            : NSColor.white.withAlphaComponent(0.22)
    }

    private func applyToolbar() {
        if searchField.stringValue != viewModel.searchText,
           window?.firstResponder !== searchField.currentEditor() {
            searchField.stringValue = viewModel.searchText
        }

        let signature = viewModel.lists.map { "\($0.identifier)\u{1F}\($0.title)" }.joined(separator: "\u{1E}")
        if signature != listsSignature {
            listsSignature = signature
            let current = viewModel.selectedListIdentifier
            filterPopup.removeAllItems()
            filterPopup.addItem(withTitle: "所有清单")
            popupListIdentifiers = []
            for list in viewModel.lists {
                filterPopup.addItem(withTitle: list.title)
                popupListIdentifiers.append(list.identifier)
            }
            if let current, let index = popupListIdentifiers.firstIndex(of: current) {
                filterPopup.selectItem(at: index + 1)
            } else {
                filterPopup.selectItem(at: 0)
            }
        } else if let current = viewModel.selectedListIdentifier,
                  let index = popupListIdentifiers.firstIndex(of: current) {
            filterPopup.selectItem(at: index + 1)
        } else {
            filterPopup.selectItem(at: 0)
        }
    }

    private func applyState() {
        let items = viewModel.items
        let hasItems = !items.isEmpty

        if let notice = viewModel.notice, !notice.isEmpty {
            noticeLabel.isHidden = false
            noticeLabel.stringValue = notice
            noticeLabel.textColor = viewModel.noticeIsError
                ? NSColor(srgbRed: 0.98, green: 0.52, blue: 0.48, alpha: 0.95)
                : NSColor(srgbRed: 0.36, green: 0.85, blue: 0.62, alpha: 0.95)
        } else {
            noticeLabel.isHidden = true
            noticeLabel.stringValue = ""
        }

        if viewModel.isLoading {
            stateRow.isHidden = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
            stateLabel.stringValue = "正在读取…"
            stateLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            retryButton.isHidden = true
            scroll.isHidden = true
        } else if let error = viewModel.loadError, !error.isEmpty {
            stateRow.isHidden = false
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            stateLabel.stringValue = "读取失败：\(error)"
            stateLabel.textColor = NSColor(srgbRed: 0.98, green: 0.52, blue: 0.48, alpha: 0.95)
            retryButton.isHidden = false
            scroll.isHidden = true
        } else if hasItems {
            stateRow.isHidden = true
            spinner.stopAnimation(nil)
            scroll.isHidden = false
        } else if viewModel.isLoaded {
            stateRow.isHidden = false
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            let filtered = !viewModel.searchText.isEmpty
                || (viewModel.selectedListIdentifier?.isEmpty == false)
            stateLabel.stringValue = filtered
                ? "没有匹配的已完成提醒事项"
                : "没有已完成的提醒事项"
            stateLabel.textColor = NSColor.white.withAlphaComponent(0.45)
            retryButton.isHidden = true
            scroll.isHidden = true
        } else {
            // idle：还没开始读（正常情况下展开后会立刻进入 loading）。
            stateRow.isHidden = true
            spinner.stopAnimation(nil)
            scroll.isHidden = true
        }
        if stateRow.isHidden {
            spinner.stopAnimation(nil)
        }
    }

    private func applyFooter() {
        let busy = viewModel.busy
        let hasItems = !viewModel.items.isEmpty
        let total = viewModel.totalCompleted

        if let progress = viewModel.progressText, !progress.isEmpty {
            countLabel.stringValue = progress
            countLabel.textColor = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.9)
        } else {
            countLabel.textColor = NSColor.white.withAlphaComponent(0.42)
            if viewModel.matchingCount != total {
                countLabel.stringValue = "匹配 \(viewModel.matchingCount) / 共 \(total) 条"
            } else if viewModel.items.count < viewModel.matchingCount {
                countLabel.stringValue = "共 \(total) 条 · 显示 \(viewModel.items.count) 条"
            } else {
                countLabel.stringValue = "共 \(total) 条"
            }
        }

        loadMoreButton.isHidden = !viewModel.hasMore
        loadMoreButton.isEnabled = !busy
        // 列表为空时隐藏「全部删除…」；有数据但按钮忙时只禁用。
        deleteAllButton.isHidden = total == 0
        deleteAllButton.isEnabled = !busy && total > 0
        footer.isHidden = total == 0 && !hasItems && viewModel.progressText == nil
    }

    // MARK: - 列表渲染（异步分批）

    private func applyItems() {
        let items = viewModel.items
        let newIDs = items.map { $0.identifier }
        let renderedIDs = renderedItems.map { $0.identifier }
        if newIDs == renderedIDs {
            for view in itemViews { view.setBusy(viewModel.busy) }
            return
        }
        // 只在末尾追加（「加载更多」）→ 不重建已有行，避免闪。
        // 还有批次在路上时先不动，等它追平后自己会再调一次。
        if !renderPending,
           newIDs.count > renderedIDs.count,
           Array(newIDs.prefix(renderedIDs.count)) == renderedIDs {
            appendChunk(items, from: renderedIDs.count, generation: renderGeneration)
            return
        }
        if renderPending && newIDs.count > renderedIDs.count,
           Array(newIDs.prefix(renderedIDs.count)) == renderedIDs {
            return
        }
        rebuild(items)
    }

    private func rebuild(_ items: [CompletedReminder]) {
        renderGeneration += 1
        let generation = renderGeneration
        renderCursor = 0
        renderPending = false
        for view in itemViews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        itemViews = []
        renderedItems = []
        appendChunk(items, from: 0, generation: generation)
    }

    private func appendChunk(_ items: [CompletedReminder],
                             from start: Int,
                             generation: Int) {
        guard generation == renderGeneration else { return }
        guard !renderPending else { return }
        guard start < items.count else { return }
        renderPending = true
        let end = min(start + Self.renderBatchSize, items.count)
        for item in items[start..<end] {
            let row = CompletedReminderItemView(item: item)
            row.onRestore = { [weak self] in self?.onRestore?(item) }
            row.onDelete = { [weak self] in self?.onDelete?(item) }
            row.setBusy(viewModel.busy)
            rowsStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            itemViews.append(row)
            renderedItems.append(item)
        }
        renderCursor = end
        if end < items.count {
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.renderGeneration else { return }
                self.renderPending = false
                self.appendChunk(items, from: end, generation: generation)
            }
        } else {
            renderPending = false
            // 渲染期间 viewModel 又变长了（点了「加载更多」）→ 接着追平。
            if !renderPending && viewModel.items.count != renderedItems.count {
                applyItems()
            }
        }
    }

    // MARK: - 动作

    @objc private func headerTapped() {
        // 未授权 / 关闭 → 不展开，也**不弹系统权限框**。
        guard viewModel.access == .ready else { return }
        onToggleExpanded?(!viewModel.isExpanded)
    }

    @objc private func openSystemSettings() {
        onOpenSystemSettings?()
    }

    @objc private func retryTapped() {
        onRetry?()
    }

    @objc private func searchSubmitted() {
        onSearchChange?(searchField.stringValue)
    }

    @objc private func filterChanged() {
        let index = filterPopup.indexOfSelectedItem
        if index <= 0 {
            onListFilterChange?(nil)
        } else if index - 1 < popupListIdentifiers.count {
            onListFilterChange?(popupListIdentifiers[index - 1])
        }
    }

    @objc private func loadMoreTapped() {
        onLoadMore?()
    }

    @objc private func deleteAllTapped() {
        onDeleteAll?()
    }

    // MARK: - 自检探针

    var testIsExpanded: Bool { viewModel.access == .ready && viewModel.isExpanded }
    var testAccess: Access { viewModel.access }
    var testSubtitleText: String { subtitleLabel.stringValue }
    var testIsLoading: Bool { viewModel.isLoading }
    var testStateText: String { stateLabel.stringValue }
    var testNoticeText: String { noticeLabel.stringValue }
    var testSearchText: String { searchField.stringValue }
    var testRenderedCount: Int { itemViews.count }
    var testDeleteAllVisible: Bool { !deleteAllButton.isHidden }
    var testDeleteAllEnabled: Bool { deleteAllButton.isEnabled }
    var testLoadMoreVisible: Bool { !loadMoreButton.isHidden }
    var testListHeight: CGFloat { Self.listMaxHeight }
    var testItemProbes: [ItemProbe] { itemViews.map { $0.testProbe } }
    /// 自检用：列表内部滚动视图（`--verify-wheel-routing` 要按类型分类）。
    var listScrollViewForTest: NSScrollView { scroll }
    /// 自检用：真实点击要落到这两个控件上。
    var testHeaderView: NSView { header }
    var testDeleteAllButton: NSButton { deleteAllButton }
    /// 自检用：列表内容是不是真的超出了可见高度（内部滚动生效）。
    var testListScrollable: Bool {
        let documentHeight = scroll.documentView?.frame.height ?? 0
        return documentHeight > scroll.contentView.bounds.height + 1
    }

    /// 自检用：模拟点这一行（走和真实点击同一条路径）。
    func testToggle() {
        headerTapped()
    }
}

// MARK: - 搜索框代理

extension CompletedRemindersRow: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        onSearchChange?(searchField.stringValue)
    }
}

// MARK: - 行标题按钮

/// header 的点击区：整块都算点在行上（文字 / 箭头也算）。
private final class HeaderButton: NSButton {
    /// 整行都算点在按钮上（标题 / 副标题 / 箭头也算）。
    ///
    /// ⚠️ `hitTest(_:)` 收到的 point 是**父视图坐标系**，不是自己的 bounds；
    /// 展开后 header 在 row 里的 y 会变成 334（非翻转坐标系），
    /// 直接 `bounds.contains(point)` 会判成「点在外面」→ 按钮永远收不到点击
    ///（用户反馈「只能张开不能收缩」就是这个）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return super.hitTest(point) }
        let local = convert(point, from: parent)
        return bounds.contains(local) ? self : nil
    }
}

// MARK: - 一条已完成事项

/// 列表里的一行：标题、清单、完成时间、到期时间，以及「恢复 / 删除」。
private final class CompletedReminderItemView: NSView {

    private let item: CompletedReminder
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "恢复", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let recurringNote = NSTextField(labelWithString: CompletedReminderPolicy.recurringRestoreNote)

    var onRestore: (() -> Void)?
    var onDelete: (() -> Void)?

    init(item: CompletedReminder) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor

        titleLabel.stringValue = item.title.isEmpty ? "（无标题）" : item.title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.86)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityLabel(item.title)

        detailLabel.stringValue = item.subtitleText
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.toolTip = item.subtitleText
        detailLabel.setAccessibilityLabel(item.subtitleText)

        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.font = .systemFont(ofSize: 11)
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        // 重复提醒：第一版**禁用**恢复（不静默恢复）。
        restoreButton.isEnabled = CompletedReminderPolicy.restoreBlockedReason(
            isRecurring: item.isRecurring) == nil
        if item.isRecurring {
            restoreButton.toolTip = CompletedReminderPolicy.recurringRestoreReason
        }
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.attributedTitle = NSAttributedString(
            string: "删除",
            attributes: [
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.9),
                .font: NSFont.systemFont(ofSize: 11),
            ])
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        recurringNote.font = .systemFont(ofSize: 9.5)
        recurringNote.textColor = NSColor.white.withAlphaComponent(0.35)
        recurringNote.alignment = .right
        recurringNote.isHidden = !item.isRecurring
        recurringNote.toolTip = CompletedReminderPolicy.recurringRestoreReason
        recurringNote.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [restoreButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let buttonColumn = NSStackView(views: [buttons, recurringNote])
        buttonColumn.orientation = .vertical
        buttonColumn.alignment = .trailing
        buttonColumn.spacing = 2
        buttonColumn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(buttonColumn)

        NSLayoutConstraint.activate([
            buttonColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            buttonColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonColumn.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                  constant: 8),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonColumn.leadingAnchor,
                                                 constant: -8),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonColumn.leadingAnchor,
                                                  constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setBusy(_ busy: Bool) {
        restoreButton.isEnabled = !busy && !item.isRecurring
        deleteButton.isEnabled = !busy
    }

    @objc private func restoreTapped() {
        onRestore?()
    }

    @objc private func deleteTapped() {
        onDelete?()
    }

    var testProbe: CompletedRemindersRow.ItemProbe {
        CompletedRemindersRow.ItemProbe(title: titleLabel.stringValue,
                                        listTitle: item.listDisplayName,
                                        detailText: detailLabel.stringValue,
                                        completionText: item.completionText,
                                        dueText: item.dueText,
                                        restoreEnabled: restoreButton.isEnabled,
                                        recurringNoteVisible: !recurringNote.isHidden)
    }
}

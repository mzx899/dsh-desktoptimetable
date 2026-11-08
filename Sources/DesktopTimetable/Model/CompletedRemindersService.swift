import Foundation

/// 「已完成的提醒事项」的**读取 / 筛选 / 分页 / 写回**状态机。
///
/// 为什么单独一层（而不是塞进 `DayPanelController`）：
///   · 这里全是「已完成列表」自己的状态（加载中 / 失败 / 搜索 / 清单筛选 / 分页），
///     和日期覆盖层的当前天内容无关；
///   · 控制器只负责把写回结果转成「日期面板 / 红点」的联动事实，
///     两边职责不混；
///   · 自检可以只注入 fake store 直接验这一层。
///
/// ## 取消
///
/// EventKit 的 `fetchReminders` **没法真正取消** —— 所以「取消」用
/// 项目里一贯的**令牌**做法：收起时把 `loadGeneration` 加一，
/// 迟到的回包发现代号对不上就整轮丢掉（不写状态、不触发 UI 更新）。
final class CompletedRemindersService {

    /// 加载状态。
    enum LoadState: Equatable {
        /// 收起 / 还没读过。
        case idle
        /// 正在读取（显示「正在读取…」）。
        case loading
        /// 读完了（可能是空列表）。
        case loaded
        /// 读取失败（显示失败原因 + 重试）。
        case failed(String)
    }

    private let store: EventKitStoreProtocol

    /// 当前加载状态。
    private(set) var state: LoadState = .idle

    /// **全部**已完成项（已按完成时间倒序）；搜索 / 筛选在它上面做。
    private(set) var allItems: [CompletedReminder] = []

    /// 过滤后的结果（已排序）。
    private(set) var filtered: [CompletedReminder] = []

    /// 当前搜索词（原样保存，输入框要回显）。
    private(set) var searchText = ""

    /// 当前清单筛选（`nil` = 所有清单）。
    private(set) var listFilterIdentifier: String?

    /// 当前渲染上限（首屏 200，之后每次「加载更多」+200）。
    private(set) var visibleCount = CompletedReminderPolicy.pageSize

    /// 批量删除是否在进行（界面要禁用按钮、显示进度）。
    private(set) var busy = false

    /// 批量删除进度（已处理, 总数）。
    private(set) var progress: (done: Int, total: Int)?

    /// 操作结果文案（「已删除 N 条」/ 部分失败说明）。
    private(set) var statusMessage: String?

    /// 状态变化回调（设置面板据此重绘这一行）。
    var onChange: (() -> Void)?

    /// `load()` 的代号（收起 / 重读 → 旧回包作废）。
    private var loadGeneration = 0
    /// 过滤（可能异步）的代号（连续输入 → 旧结果作废）。
    private var queryGeneration = 0

    init(store: EventKitStoreProtocol) {
        self.store = store
    }

    // MARK: - 派生数据

    /// 全部清单（从已完成项里汇总）。
    var lists: [CompletedReminderList] {
        CompletedReminderQuery.lists(in: allItems)
    }

    /// 全部已完成项数量（跨清单，不受搜索 / 筛选影响）。
    var totalCompleted: Int { allItems.count }

    /// 当前过滤后的数量。
    var matchingCount: Int { filtered.count }

    /// 当前应该渲染的条目（前 `visibleCount` 条）。
    var pageItems: [CompletedReminder] {
        Array(filtered.prefix(visibleCount))
    }

    /// 还有没渲染的匹配项吗。
    var hasMore: Bool { filtered.count > visibleCount }

    // MARK: - 读取

    /// 收起 / 关闭入口：作废在途读取，清空状态（下次展开重新读）。
    func reset() {
        loadGeneration += 1
        queryGeneration += 1
        state = .idle
        allItems = []
        filtered = []
        searchText = ""
        listFilterIdentifier = nil
        visibleCount = CompletedReminderPolicy.pageSize
        busy = false
        progress = nil
        statusMessage = nil
        onChange?()
    }

    /// 展开入口：重新读一遍所有清单里的已完成项。
    func load() {
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        statusMessage = nil
        onChange?()
        store.completedReminders { [weak self] result in
            guard let self, generation == self.loadGeneration else { return }
            switch result {
            case .success(let items):
                self.allItems = CompletedReminderQuery.sorted(items)
                self.pruneFilterIfMissing()
                self.visibleCount = CompletedReminderPolicy.pageSize
                self.recompute(notify: false)
                self.state = .loaded
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
            self.onChange?()
        }
    }

    /// 失败后点「重试」。
    func retry() {
        load()
    }

    /// 删除前**重新统计**一次数量（不经过缓存，避免拿旧数量误导用户）。
    func countCompleted(completion: @escaping (Result<Int, Error>) -> Void) {
        store.completedReminders { result in
            switch result {
            case .success(let items):
                completion(.success(items.count))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - 搜索 / 筛选 / 分页

    /// 改搜索词（大小写不敏感，按标题）。
    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        visibleCount = CompletedReminderPolicy.pageSize
        statusMessage = nil
        recompute()
    }

    /// 改清单筛选（`nil` / 空串 = 所有清单）。
    func setListFilter(_ identifier: String?) {
        let normalized = (identifier?.isEmpty == false) ? identifier : nil
        guard normalized != listFilterIdentifier else { return }
        listFilterIdentifier = normalized
        visibleCount = CompletedReminderPolicy.pageSize
        statusMessage = nil
        recompute()
    }

    /// 底部「加载更多」：多渲染一页。
    func loadMore() {
        guard hasMore else { return }
        visibleCount += CompletedReminderPolicy.pageSize
        onChange?()
    }

    /// 清掉操作结果文案（例如用户开始新的搜索）。
    func clearStatus() {
        guard statusMessage != nil else { return }
        statusMessage = nil
        onChange?()
    }

    // MARK: - 写回

    /// 恢复一条为未完成。
    ///
    /// 只在系统写回**成功之后**才从缓存里移除 —— 失败时列表保持原样。
    func restore(_ item: CompletedReminder,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        store.restoreReminder(item.identifier,
                              in: item.listIdentifier) { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.removeFromCache([item.identifier])
                self.statusMessage = "已恢复「\(item.title)」"
                self.onChange?()
            }
            completion(result)
        }
    }

    /// 永久删除一条。
    func delete(_ item: CompletedReminder,
                completion: @escaping (Result<Void, Error>) -> Void) {
        store.deleteCompletedReminder(item.identifier,
                                      in: item.listIdentifier) { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.removeFromCache([item.identifier])
                self.statusMessage = "已删除「\(item.title)」"
                self.onChange?()
            }
            completion(result)
        }
    }

    /// 删除**所有清单**里的所有已完成项（不受当前搜索 / 筛选影响）。
    func deleteAll(completion: @escaping (CompletedRemindersDeleteResult) -> Void) {
        guard !busy else {
            completion(.failure(CompletedRemindersError.underlying("上一次删除还没完成"),
                                total: allItems.count))
            return
        }
        busy = true
        progress = (0, allItems.count)
        onChange?()
        store.deleteAllCompletedReminders(progress: { [weak self] done, total in
            guard let self else { return }
            self.progress = (done, total)
            self.onChange?()
        }, completion: { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.progress = nil
            self.statusMessage = result.summaryText
            let deleted = Set(result.deletedIdentifiers)
            if !deleted.isEmpty {
                self.allItems.removeAll { deleted.contains($0.identifier) }
            }
            self.pruneFilterIfMissing()
            self.recompute(notify: false)
            self.onChange?()
            completion(result)
        })
    }

    // MARK: - 内部

    /// 从缓存移除（写回成功后）。
    private func removeFromCache(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let removed = Set(identifiers)
        allItems.removeAll { removed.contains($0.identifier) }
        pruneFilterIfMissing()
        recompute(notify: false)
    }

    /// 当前筛选的清单已经没有已完成项了（例如刚恢复 / 删除完最后一条）→
    /// 自动退回「所有清单」，避免列表永远是空的、用户还以为没数据。
    private func pruneFilterIfMissing() {
        guard let filter = listFilterIdentifier, !filter.isEmpty else { return }
        if !allItems.contains(where: { $0.listIdentifier == filter }) {
            listFilterIdentifier = nil
        }
    }

    /// 重新计算过滤结果。
    ///
    /// ⚠️ 数据量大时放到后台线程过滤，再回主线程替换 ——
    /// 「查询和渲染都必须异步，不阻塞主线程」（规格二.5）。
    private func recompute(notify: Bool = true) {
        queryGeneration += 1
        let token = queryGeneration
        let snapshot = allItems
        let search = searchText
        let list = listFilterIdentifier
        // 小数据量同步算（避免一次没必要的派发）；超过 300 条走后台。
        if snapshot.count <= 300 {
            filtered = CompletedReminderQuery.filter(snapshot,
                                                     search: search,
                                                     listIdentifier: list)
            if notify { onChange?() }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CompletedReminderQuery.filter(snapshot,
                                                       search: search,
                                                       listIdentifier: list)
            DispatchQueue.main.async {
                guard let self, token == self.queryGeneration else { return }
                self.filtered = result
                if notify { self.onChange?() }
            }
        }
    }
}

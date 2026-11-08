import Foundation

/// 一条**已完成**的提醒事项（「设置 → 提醒 → 已完成的提醒事项」用）。
///
/// 和 `DayPanelTodo` 分开：日期覆盖层里只关心「某一天、未完成」，
/// 这里要跨全部清单、按完成时间倒序，还要带清单名给用户看数据来源。
struct CompletedReminder: Equatable {
    /// `EKReminder.calendarItemIdentifier`。
    var identifier: String
    /// 标题。
    var title: String
    /// 所属清单（`EKCalendar.calendarIdentifier`）。
    var listIdentifier: String
    /// 所属清单的标题（显示用）。
    var listTitle: String
    /// 完成时间（EventKit 里可能为空 —— 老数据 / 被别的程序改过）。
    var completionDate: Date?
    /// 到期时间（可能没有 —— 提醒事项允许「无到期时间」）。
    var dueDate: Date?
    /// 是不是重复提醒（`recurrenceRules` 非空）。
    ///
    /// ⚠️ 第一版**禁用**重复提醒的「恢复」：恢复可能和系统已生成的
    /// 下一次实例冲突（可能出现两个实例）。只允许删除，并在按钮旁说明。
    var isRecurring: Bool
}

extension CompletedReminder {

    /// 显示用的时间格式：`yyyy-MM-dd HH:mm`（规格要求）。
    static let displayTimeFormat = "yyyy-MM-dd HH:mm"

    /// 线程说明：只在主线程（列表渲染 / 自检）里用，不做并发访问。
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = displayTimeFormat
        return f
    }()

    /// `Date?` → `yyyy-MM-dd HH:mm`；`nil` / 空 → 空串。
    static func timeText(_ date: Date?) -> String {
        guard let date else { return "" }
        return displayFormatter.string(from: date)
    }

    /// 完成时间文案（没有时显示「完成时间未知」——绝不能拿空串冒充时间）。
    var completionText: String {
        let text = Self.timeText(completionDate)
        return text.isEmpty ? "完成时间未知" : text
    }

    /// 到期时间文案（没有到期时间时按规格显示「无到期时间」）。
    var dueText: String {
        let text = Self.timeText(dueDate)
        return text.isEmpty ? "无到期时间" : text
    }

    /// 清单显示名（清单标题为空时给一个明确占位，不显示空白）。
    var listDisplayName: String {
        let name = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名清单" : name
    }

    /// 列表里一行副文案：清单 · 完成时间 · 到期时间。
    var subtitleText: String {
        "\(listDisplayName) · 完成 \(completionText) · 到期 \(dueText)"
    }
}

/// 「按清单筛选」下拉框里的一项。
struct CompletedReminderList: Equatable {
    var identifier: String
    var title: String
}

/// 已完成提醒事项的**查询**（搜索 / 清单筛选 / 排序 / 清单汇总）。
///
/// 纯函数，方便单测；真实取数在 `EventKitStore.completedReminders`。
enum CompletedReminderQuery {

    /// 搜索词归一化（去首尾空白；大小写 / 变音不敏感靠 `range` 的选项）。
    static func normalizeSearch(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一条记录是否匹配搜索词与清单筛选。
    ///
    /// - Parameters:
    ///   - search：按**标题**搜索（空串 = 不过滤）。
    ///   - listIdentifier：`nil` / 空串 = 所有清单。
    static func matches(_ reminder: CompletedReminder,
                        search: String,
                        listIdentifier: String?) -> Bool {
        let keyword = normalizeSearch(search)
        if !keyword.isEmpty {
            let range = reminder.title.range(of: keyword,
                                             options: [.caseInsensitive, .diacriticInsensitive])
            if range == nil { return false }
        }
        if let listIdentifier, !listIdentifier.isEmpty,
           reminder.listIdentifier != listIdentifier {
            return false
        }
        return true
    }

    /// 过滤 + 排序（完成时间倒序）。
    static func filter(_ items: [CompletedReminder],
                       search: String,
                       listIdentifier: String?) -> [CompletedReminder] {
        sorted(items.filter { matches($0, search: search, listIdentifier: listIdentifier) })
    }

    /// 完成时间倒序；没有完成时间的排最后；同一时刻按标题 / id 稳定排序。
    static func sorted(_ items: [CompletedReminder]) -> [CompletedReminder] {
        items.sorted { lhs, rhs in
            switch (lhs.completionDate, rhs.completionDate) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.identifier < rhs.identifier
        }
    }

    /// 从已完成项里汇总出清单列表（去重、按标题排序）。
    ///
    /// 清单标识为空的条目仍然会显示在「所有清单」里，只是没法单独筛选。
    static func lists(in items: [CompletedReminder]) -> [CompletedReminderList] {
        var seen: Set<String> = []
        var out: [CompletedReminderList] = []
        for item in items {
            guard !item.listIdentifier.isEmpty, !seen.contains(item.listIdentifier) else {
                continue
            }
            seen.insert(item.listIdentifier)
            out.append(CompletedReminderList(identifier: item.listIdentifier,
                                             title: item.listDisplayName))
        }
        return out.sorted {
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.identifier < $1.identifier
        }
    }
}

/// 分页 / 确认策略（纯逻辑，自检和单测都直接用它）。
enum CompletedReminderPolicy {

    /// 首屏最多渲染多少条（规格：200）。
    static let pageSize = 200

    /// 达到多少条时「全部删除」还要用户输入「删除」两个字。
    static let typedConfirmationThreshold = 50

    /// 需要用户手动输入的确认词。
    static let typedConfirmationWord = "删除"

    /// 全部删除的确认标题。
    static let deleteAllTitle = "删除全部已完成事项？"

    /// 全部删除的确认正文（数量由调用方**重新统计**后传进来）。
    static func deleteAllMessage(count: Int) -> String {
        "将永久删除所有清单中 \(count) 条已完成提醒事项，此操作无法撤销。"
    }

    /// 是否要求输入确认词（≥50 条）。
    static func needsTypedConfirmation(count: Int) -> Bool {
        count >= typedConfirmationThreshold
    }

    /// 用户输入的确认词是否完全匹配（去首尾空白，必须正好是「删除」）。
    static func typedConfirmationMatches(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == typedConfirmationWord
    }

    /// 「删除某一条」的确认标题（规格：标题带上待办名）。
    static func deleteOneTitle(title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "删除这条已完成提醒事项？" : "删除「\(trimmed)」？"
    }

    /// 「删除某一条」的确认正文。
    static let deleteOneMessage = "这条已完成的提醒事项将被永久删除，此操作无法撤销。"

    /// 重复提醒为什么不能恢复（完整说明，给 tooltip / 提示用）。
    static let recurringRestoreReason =
        "这是重复提醒，恢复后可能和系统已生成的下一次实例冲突；第一版只允许删除。"

    /// 重复提醒为什么不能恢复（按钮旁边的短说明）。
    static let recurringRestoreNote = "重复提醒不支持恢复"

    /// 某一条能不能恢复：`nil` = 可以；否则是不允许的原因。
    static func restoreBlockedReason(isRecurring: Bool) -> String? {
        isRecurring ? recurringRestoreReason : nil
    }
}

/// 「已完成的提醒事项」读写的错误。
enum CompletedRemindersError: LocalizedError, Equatable {
    /// 接入开关关着。
    case disabled
    /// 还没拿到提醒事项权限。
    case notAuthorized
    /// 重复提醒不允许恢复（第一版）。
    case recurringRestoreUnsupported
    /// EventKit 里找不到这条（可能已被别的程序删掉）。
    case reminderNotFound
    /// EventKit 抛出的真实错误。
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "「日历与提醒事项接入」还没打开"
        case .notAuthorized:
            return "还没有获得提醒事项权限，先去系统设置里允许访问提醒事项"
        case .recurringRestoreUnsupported:
            return CompletedReminderPolicy.recurringRestoreReason
        case .reminderNotFound:
            return "系统里找不到这条提醒事项（可能已经被删掉了）"
        case .underlying(let message):
            return message
        }
    }
}

/// 批量删除的结果（**必须如实**区分成功与失败，不能报「全部成功」）。
struct CompletedRemindersDeleteResult: Equatable {
    /// 成功删除的条数。
    var deleted: Int
    /// 删除失败的条数。
    var failed: Int
    /// 成功删除的 id（日期面板用它做「刚删除」事实，避免旧快照复活）。
    var deletedIdentifiers: [String]
    /// 删除失败的 id。
    var failedIdentifiers: [String]
    /// 附加说明（例如 EventKit 的 commit 失败原因）。
    var message: String?

    /// 界面上显示的一句话结果。
    var summaryText: String {
        let detail = (message?.isEmpty == false) ? "（\(message!)）" : ""
        if deleted == 0 && failed == 0 {
            return message?.isEmpty == false ? message! : "没有需要删除的已完成事项"
        }
        if failed == 0 {
            return "已删除 \(deleted) 条"
        }
        if deleted == 0 {
            return "删除失败：\(failed) 条未能删除\(detail)"
        }
        return "已删除 \(deleted) 条，\(failed) 条失败\(detail)"
    }

    /// 构造一个「一条都没删掉」的失败结果。
    static func failure(_ error: Error, total: Int = 0) -> CompletedRemindersDeleteResult {
        CompletedRemindersDeleteResult(deleted: 0,
                                       failed: max(0, total),
                                       deletedIdentifiers: [],
                                       failedIdentifiers: [],
                                       message: error.localizedDescription)
    }
}

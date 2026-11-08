import Foundation

/// 「提前提醒」下拉框的选项模型（纯逻辑，可单测）。
///
/// 下拉框的结构**固定**：
///   · 候选值（`ReminderSettings.leadOptions`：上课时提醒 / 提前 5、10、15、20、30 分钟）；
///   · 当前生效的分钟数**不在**候选里时（比如用户自己填了 12），在候选后面
///     额外插一项「提前 12 分钟（自定义）」并选中它 —— 用户一眼看得出当前
///     提前几分钟，不会以为「设置丢了」；
///   · **最后一项永远是「自定义…」** —— 选它弹输入框，让用户自己填分钟数。
///
/// 存盘只存**一个整数**（`settings.json` 的 `reminder.leadMinutes`），
/// 「是不是自定义值」不另存字段 —— 由「在不在候选里」推出来，所以老配置
/// 不用迁移，改一下 UI 就支持任意分钟数。
enum LeadMinutesChoice {

    /// 固定候选（分钟数）。
    static let presetOptions = ReminderSettings.leadOptions

    /// 最后一项的标题：选它弹输入框，让用户自己填分钟数。
    static let customEntryTitle = "自定义…"

    /// 候选值在下拉框里的标题。
    static func title(for minutes: Int) -> String {
        minutes == 0 ? "上课时提醒" : "提前 \(minutes) 分钟"
    }

    /// 「自定义值」那一项的标题（当前生效值不在候选里时才有这一项）。
    static func customValueTitle(for minutes: Int) -> String {
        "提前 \(minutes) 分钟（自定义）"
    }

    /// 标题 → 分钟数（解析不了返回 nil）。
    static func parseTitle(_ title: String) -> Int? {
        if title.contains("上课时") { return 0 }
        let digits = title.filter { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 解析输入框里的分钟数：必须是 `0...60` 的整数，其余返回 nil。
    ///
    /// 范围跟 `ReminderSettings.clampLead` 一致 —— 两处必须同口径，
    /// 否则用户能填出一个存盘时被夹掉的数。
    static func parseMinutes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed) else { return nil }
        guard value >= ReminderSettings.minLeadMinutes,
              value <= ReminderSettings.maxLeadMinutes else { return nil }
        return value
    }

    /// 下拉框的条目内容。
    struct PopupItems: Equatable {
        /// 全部条目的标题（最后一项恒为「自定义…」）。
        var titles: [String]
        /// 与 `titles` 一一对应的分钟数；最后一项是 nil（它是「打开输入框」的入口，不是分钟数）。
        var minutes: [Int?]
        /// 「自定义…」入口的下标。
        var customEntryIndex: Int
        /// 当前生效的分钟数应该选中哪一项。
        var selectedIndex: Int
    }

    /// 按当前生效的分钟数算出下拉框应该长什么样。
    ///
    /// 纯函数 —— 下拉框重建、选中态、条目解析全走它，UI 只负责照着画。
    static func popupItems(currentMinutes: Int) -> PopupItems {
        var titles: [String] = []
        var minutes: [Int?] = []
        for m in presetOptions {
            titles.append(title(for: m))
            minutes.append(m)
        }
        // 当前值不是候选 → 单独列一项，用户才知道「现在提前 12 分钟」。
        if !presetOptions.contains(currentMinutes) {
            titles.append(customValueTitle(for: currentMinutes))
            minutes.append(currentMinutes)
        }
        // 「自定义…」永远是最后一项。
        titles.append(customEntryTitle)
        minutes.append(nil)
        let customEntryIndex = titles.count - 1
        let selectedIndex = minutes.firstIndex { $0 == currentMinutes } ?? customEntryIndex
        return PopupItems(titles: titles,
                          minutes: minutes,
                          customEntryIndex: customEntryIndex,
                          selectedIndex: selectedIndex)
    }
}

import Foundation

/// 「日期覆盖层」里的**一条待办**（来自系统提醒事项）。
///
/// 只保留覆盖层要显示的字段 —— 覆盖层窄（单列宽），放不下太多东西。
struct DayPanelTodo: Equatable {
    /// 提醒事项的标题。
    var title: String
    /// 到期时间（当天零点的 `HH:mm`，没有具体时间时为空）。
    var due: String
    /// 是否已完成。
    var done: Bool
    /// 到期时刻（当天零点的分钟数）；没有具体时间时是 nil。
    ///
    /// 排序用这个，**不要**用显示用的 `due` 字符串 ——
    /// 字符串比是字典序（「20:00」排在「9:00」前面），和实际时刻对不上。
    /// 网页那边按同一套规则排，两边不一致的话下标会指错。
    var dueMinutes: Int?

    /// 「几点几分」—— 优先用 `dueMinutes`，没有就从 `due` 字符串解析。
    ///
    /// ⚠️ 只给**自检的 fake** 用 —— 真实实现里到期时刻是从 EventKit 直接读的。
    func minutesOfDay() -> Int? {
        if let m = dueMinutes { return m }
        let parts = due.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]), let mm = Int(parts[1]) else { return nil }
        return h * 60 + mm
    }

    /// 系统里的提醒事项 id（写回时用它定位那一条）。
    ///
    /// EventKit **没有**公开的「按 id 取回提醒事项」接口，
    /// 所以这里存 `calendarItemIdentifier` + 清单标识，
    /// 写回时靠「列出全部 → 按 id 匹配」来定位。
    var identifier: String
    /// 所属清单的标识（`EKCalendar.calendarIdentifier`）。
    var calendarIdentifier: String
}

/// 今天这一列的待办摘要（2026-11-10）：
/// 「今天 N 条待处理 · 逾期 M 条」。
struct DayPanelTodoDigest: Equatable {
    /// 今天还没处理的条数。
    var today: Int = 0
    /// 今天**之前**（逾期）还没处理的条数。
    var overdue: Int = 0

    var isEmpty: Bool { today == 0 && overdue == 0 }
}

/// 「日期覆盖层」里的一条**日记**。
///
/// 日记**不属于**提醒事项 / 系统日历：它存在本 app 自己的
/// `<数据目录>/diary.json` 里（见 `Model/DiaryStore.swift`），
/// 删除 / 修改只影响这份文件，不会碰用户的提醒事项。
struct DayPanelDiary: Equatable {
    /// 稳定标识（网页发 `diaryUpdate` / `diaryDelete` 时带回来）。
    var id: String
    /// 标题（可以空 → 列表里显示「（未命名）」）。
    var title: String
    /// 正文（可多行）。
    var body: String
    /// `HH:mm`；空串 = 没写具体时间。
    var time: String

    var jsonObject: [String: Any] {
        ["id": id, "title": title, "body": body, "time": time]
    }
}

/// 「日期覆盖层」里的**一条日程**（来自系统日历）。
struct DayPanelEvent: Equatable {
    var title: String
    /// 开始时间（`HH:mm`）。
    var start: String
    var end: String
    var identifier: String
    var calendarIdentifier: String
}

/// 某一天的**汇总标记** —— 驱动课表表头上的红点 / 橙点。
///
/// 只记「有没有」，不记数量 —— 表头只有 4px 的点，画不出数字。
struct DayPanelFlags: Equatable {
    /// 有待办（红点）。
    var hasTodo: Bool = false
    /// 有日程（橙点）。
    var hasEvent: Bool = false
    /// 当天有日记（绿点）。
    ///
    /// 日记是本 app 自己的数据（`diary.json`），**不依赖 EventKit 权限** ——
    /// 所以即使提醒事项未接入 / 授权被拒，绿点照样要显示。
    var hasDiary: Bool = false

    static let none = DayPanelFlags()
}

/// 一整天的覆盖层内容。
struct DayPanelContent: Equatable {
    /// 第几天（1=周一 … 7=周日）。
    var day: Int = 1
    /// 待办事项。
    var todos: [DayPanelTodo] = []
    /// 日程。
    var events: [DayPanelEvent] = []
    /// 日记（**第三块内容**，和待办 / 日程并列；存在 app 自己的 diary.json 里）。
    var diary: [DayPanelDiary] = []
    /// 这一列是不是「今天」（只有今天才显示待办摘要）。
    var isToday: Bool = false
    /// 今天 / 逾期的未处理条数（nil = 还没算出来 / 不是今天）。
    var todoDigest: DayPanelTodoDigest? = nil
    /// 节日 / 节气信息（由农历模块提供）。
    var festival: DayPanelFestival = DayPanelFestival()
    /// 待办 / 日程是否**已经向 EventKit 查完并合并**（2026-11 加）。
    ///
    /// ⚠️ 为什么需要显式标记：`loadContent` 会**先同步推一份**
    /// 「只有节日、待办 / 日程为空」的中间态（让今日详情立刻显示），
    /// 再异步查 EventKit 推全量。网页不能把「空列表」当成
    /// 「数据已经到齐」—— 否则中间态或竞态丢包时，面板会一直显示空，
    /// 而且因为「看起来有数据」不再补发请求。
    ///
    /// 只有异步回包合并完成后才置 true（见 `DayPanelController.loadContent`）。
    var ready: Bool = false

    /// 这一天有没有任何内容（没有待办也没有日程）。
    var isEmpty: Bool { todos.isEmpty && events.isEmpty }
}

/// 「今日详情」那一栏的内容：农历日期 + 节气 + 节日 + 天气 + 宜忌。
struct DayPanelFestival: Equatable {
    /// 农历日期（如「农历九月初七」）。
    var lunar: String = ""
    /// 二十四节气（如「寒露」）。
    var solarTerm: String = ""
    /// 公历 / 农历节日（可能多个）。
    var festivals: [String] = []
    /// 天气（**可选** —— 没有城市 / 请求失败时是 nil，网页要整行隐藏）。
    var weather: DayPanelWeather? = nil
    /// 宜（简化建除黄历；拿不到时是空串，网页要整行隐藏）。
    var yi: String = ""
    /// 忌（简化建除黄历；拿不到时是空串，网页要整行隐藏）。
    var ji: String = ""

    /// 这一栏有没有内容。
    var isEmpty: Bool { lunar.isEmpty && solarTerm.isEmpty && festivals.isEmpty
        && weather == nil && yi.isEmpty && ji.isEmpty }
}

/// 「今日详情」里的天气。
///
/// ⚠️ **拿不到就整个是 nil** —— 网页会**隐藏整行**。
/// 绝不能出现「0°」或任何假数据。
struct DayPanelWeather: Equatable {
    /// 天气现象（中文，如「晴」「多云」「小雨」）。
    var text: String = ""
    /// 当前温度（摄氏度）。
    var temperature: Double? = nil
    /// 当天最低温。
    var min: Double? = nil
    /// 当天最高温。
    var max: Double? = nil

    /// 有没有任何可显示的内容（描述和温度都没有 → 整行隐藏）。
    var isEmpty: Bool {
        text.isEmpty && temperature == nil && min == nil && max == nil
    }
}

// MARK: - JSON（给网页层用）

extension DayPanelContent {

    /// 「今日详情」那一块的 JSON（**可复用**）。
    ///
    /// 单独抽出来是因为 2026-11 要把**7 天各自的详情**一起推给网页
    /// （`dayFestivals`）—— 每一份都用同一个格式，不能各写一遍。
    static func festivalJSON(_ festival: DayPanelFestival) -> [String: Any] {
        [
            "lunar": festival.lunar,
            "term": festival.solarTerm,
            "festivals": festival.festivals,
            // 天气是**可选**字段：没有城市 / 请求失败时整个键是 null，
            // 网页收到 null 就**隐藏整行**（绝不显示假数据）。
            "weather": festival.weather.map { w -> [String: Any] in
                var d: [String: Any] = ["text": w.text]
                if let t = w.temperature { d["temperature"] = t }
                if let m = w.min { d["min"] = m }
                if let m = w.max { d["max"] = m }
                return d
            } as Any? ?? NSNull(),
            // 宜 / 忌：空串 = 拿不到（网页隐藏这一行）。
            "yi": festival.yi,
            "ji": festival.ji,
        ]
    }

    /// 转成推给网页的 JSON 字典。
    ///
    /// 字段名**必须**和 `docs/日期覆盖层-规格.md` 第八章的契约一致 ——
    /// 网页层按契约读，字段名改了网页就崩。
    var jsonObject: [String: Any] {
        [
            "day": day,
            "todos": todos.map { todo in
                [
                    "title": todo.title,
                    "due": todo.due,
                    "done": todo.done,
                    "identifier": todo.identifier,
                    "calendarIdentifier": todo.calendarIdentifier,
                ] as [String: Any]
            },
            "events": events.map { event in
                [
                    "title": event.title,
                    "start": event.start,
                    "end": event.end,
                    "identifier": event.identifier,
                    "calendarIdentifier": event.calendarIdentifier,
                ] as [String: Any]
            },
            "diary": diary.map(\.jsonObject),
            "isToday": isToday,
            "todoDigest": todoDigest.map { ["today": $0.today, "overdue": $0.overdue] }
                ?? NSNull(),
            "festival": DayPanelContent.festivalJSON(festival),
            // 待办 / 日程是否已查完（网页判断「要不要补发请求」用）。
            "ready": ready,
        ]
    }
}

extension DayPanelFlags {

    /// 转成推给网页的 JSON 字典（键是「周几」的字符串）。
    static func jsonObject(_ flags: [Int: DayPanelFlags]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (day, f) in flags {
            out["\(day)"] = ["todo": f.hasTodo, "event": f.hasEvent,
                          "diary": f.hasDiary]
        }
        return out
    }
}

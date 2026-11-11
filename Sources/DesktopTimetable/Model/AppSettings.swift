import Foundation

/// 应用的**分组设置**。
///
/// 为什么分组：设置项越来越多（外观 / 提醒 / 笔记 / 桌宠……），
/// 平铺在一个字典里迟早出现「谁覆盖谁」的问题。分组后每组独立演进。
///
/// 存储位置（重要）：
///   · `appearance` → `config.json`（**只有外观**）——
///     旧版 app 也会读写的文件，旧版一保存就会整份覆盖，
///     所以新设置**不许**写进去，否则会被旧版抹掉。
///   · `reminder` / `notes` / `pet` / `dayPanel` → `settings.json`（新版专用），
///     旧版 app 根本不认识这个文件。
struct AppSettings: Equatable {

    /// 外观设置（现有 5 项）。
    var appearance: AppearanceSettings
    /// 上课提醒。
    var reminder: ReminderSettings
    /// 课程时间（10 节课的起止钟点）。
    var periods: PeriodSettings
    /// 笔记（本期只预留结构，不实现功能）。
    var notes: NoteSettings
    /// 桌宠（本期只预留结构，不实现功能）。
    var pet: PetSettings
    /// 日期覆盖层（接入系统日历 / 提醒事项）。
    var dayPanel: DayPanelSettings

    init(appearance: AppearanceSettings = AppearanceSettings(),
         reminder: ReminderSettings = ReminderSettings(),
         periods: PeriodSettings = PeriodSettings(),
         notes: NoteSettings = NoteSettings(),
         pet: PetSettings = PetSettings(),
         dayPanel: DayPanelSettings = DayPanelSettings()) {
        self.appearance = appearance
        self.reminder = reminder
        self.periods = periods
        self.notes = notes
        self.pet = pet
        self.dayPanel = dayPanel
    }

    /// 全部默认值。
    static let `default` = AppSettings()
}

// MARK: - 外观

/// 外观设置（`config.json` 里的那 6 项）。
struct AppearanceSettings: Equatable {
    var fadeInSec: Double = 0.8
    var fadeOutSec: Double = 6.0
    var minOpacity: Double = 0.22
    var maxOpacity: Double = 1.0
    var panelOpacity: Double = 0.5
    /// 课表卡片大小（等比缩放系数）。1.0 = 原始尺寸。
    var cardScale: Double = 1.0

    init(fadeInSec: Double = 0.8, fadeOutSec: Double = 6.0,
         minOpacity: Double = 0.22, maxOpacity: Double = 1.0,
         panelOpacity: Double = 0.5, cardScale: Double = 1.0) {
        self.fadeInSec = fadeInSec
        self.fadeOutSec = fadeOutSec
        self.minOpacity = minOpacity
        self.maxOpacity = maxOpacity
        self.panelOpacity = panelOpacity
        self.cardScale = cardScale
    }

    /// 从 `config.json` 的字典读（缺项用默认值）。
    init(dictionary: [String: Double]) {
        fadeInSec = dictionary["fadeInSec"] ?? 0.8
        fadeOutSec = dictionary["fadeOutSec"] ?? 6.0
        minOpacity = dictionary["minOpacity"] ?? 0.22
        maxOpacity = dictionary["maxOpacity"] ?? 1.0
        panelOpacity = dictionary["panelOpacity"] ?? 0.5
        // 老配置没有这一项 → 1.0（原始尺寸）。
        cardScale = dictionary["cardScale"] ?? 1.0
    }

    /// 写回 `config.json` 的字典。
    var dictionary: [String: Double] {
        ["fadeInSec": fadeInSec, "fadeOutSec": fadeOutSec,
         "minOpacity": minOpacity, "maxOpacity": maxOpacity,
         "panelOpacity": panelOpacity, "cardScale": cardScale]
    }

    /// 转成旧版卡片用的 `AppearanceConfig`。
    var asAppearanceConfig: AppearanceConfig {
        AppearanceConfig(dictionary)
    }
}

// MARK: - JSON 取值的严格类型

/// 从 JSON 字典里取值的**严格类型**helper。
///
/// 为什么需要严格：`JSONSerialization` 把 JSON 的 `true` 和 `1` 都变成 `NSNumber`，
/// 于是 `obj["enabled"] as? Bool` 对 `1` 也成立（返回 true），
/// `obj["leadMinutes"] as? Int` 对 `true` 也成立（返回 1）。
/// 结果就是「类型非法回退默认值」这条约定在这两个字段上是假的 ——
/// 别人手写一个 `{"enabled": 1}` 就能把提醒打开。
///
/// 判定办法：JSON 的布尔是 `__NSCFBoolean`（CFBoolean 类型），
/// 数字是 `__NSCFNumber`。用 `CFGetTypeID` 区分。
enum StrictJSONValue {

    /// 取**真正的** Bool（只有 JSON 的 `true` / `false` 算）。
    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber else { return nil }
        guard CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// 取**真正的** Int（JSON 的 `true`、`1.0`、`1.5`、`"3"` 都不算）。
    static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        // 布尔先排除掉（它也是 NSNumber，objCType 也是 "c"）。
        guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        // 浮点 / 小数不算整数（JSON 的 `1.0` 的 objCType 是 "d"）。
        guard integerObjCTypes.contains(String(cString: n.objCType)) else { return nil }
        return n.intValue
    }

    /// 取**真正的** Double（JSON 的 `true` / `"3"` 都不算）。
    ///
    /// 布尔先排除掉（它也是 NSNumber）。
    static func double(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// `NSNumber` 里表示**整数**的 objCType 集合。
    ///
    /// JSONSerialization 解析出来的整数是 "q"（long long），小数是 "d"。
    /// `1.0` 在 JSON 里是浮点，不该被当成整数读（那会让 `leadMinutes: 1.0`
    /// 悄悄变成 1 分钟，而写出去时又变成 1 —— 类型在两个方向上都不一致）。
    private static let integerObjCTypes: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
}

// MARK: - 提醒

/// 上课提醒设置。
struct ReminderSettings: Equatable {
    /// 是否开启上课提醒。
    var enabled: Bool = false
    /// 提前多少分钟提醒（0...60）。
    var leadMinutes: Int = 10

    static let minLeadMinutes = 0
    static let maxLeadMinutes = 60
    /// 下拉框里的候选值。
    static let leadOptions: [Int] = [0, 5, 10, 15, 20, 30]

    init(enabled: Bool = false, leadMinutes: Int = 10) {
        self.enabled = enabled
        self.leadMinutes = ReminderSettings.clampLead(leadMinutes)
    }

    /// 把提前分钟数夹回合法范围。
    static func clampLead(_ n: Int) -> Int {
        min(max(n, minLeadMinutes), maxLeadMinutes)
    }

    /// 从 `settings.json` 的字典读（缺字段 / 类型非法都退回默认值）。
    init(json obj: [String: Any]) {
        // 只接受**真正的** Bool / Int：JSON 的 `1` 不能当 enabled，
        // JSON 的 `true` 不能当 leadMinutes。
        if let b = StrictJSONValue.bool(obj["enabled"]) {
            enabled = b
        }
        if let i = StrictJSONValue.int(obj["leadMinutes"]) {
            leadMinutes = ReminderSettings.clampLead(i)
        }
    }

    /// 写进 `settings.json` 的字典。
    var jsonObject: [String: Any] {
        ["enabled": enabled, "leadMinutes": leadMinutes]
    }
}

// MARK: - 预留分组

/// 笔记设置（本期只预留结构）。
struct NoteSettings: Equatable {
    /// 是否启用笔记。功能本身本期不实现。
    var enabled: Bool = false

    init(enabled: Bool = false) { self.enabled = enabled }

    init(json obj: [String: Any]) {
        if let b = StrictJSONValue.bool(obj["enabled"]) { enabled = b }
    }

    var jsonObject: [String: Any] { ["enabled": enabled] }
}

/// 桌宠设置（本期只预留结构）。
struct PetSettings: Equatable {
    /// 是否启用桌宠。功能本身本期不实现。
    var enabled: Bool = false

    init(enabled: Bool = false) { self.enabled = enabled }

    init(json obj: [String: Any]) {
        if let b = StrictJSONValue.bool(obj["enabled"]) { enabled = b }
    }

    var jsonObject: [String: Any] { ["enabled": enabled] }
}

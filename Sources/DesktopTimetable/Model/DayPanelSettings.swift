import Foundation

/// 「日期覆盖层」的接入设置（存进 `settings.json` 的 `dayPanel` 分组）。
///
/// 格式：
/// ```json
/// "dayPanel": {
///   "enabled": false,
///   "listIdentifier": "",
///   "listTitle": "桌面课表",
///   "weatherEnabled": false
/// }
/// ```
struct DayPanelSettings: Equatable {

    /// 是否接入系统日历 / 提醒事项。
    ///
    /// 默认**关** —— 接入要申请系统权限，是敏感操作，
    /// 让用户在设置里自己开。没开的时候覆盖层只显示当天课程，
    /// 不影响主功能。
    var enabled: Bool = false

    /// 写提醒事项时用哪个清单（`EKCalendar.calendarIdentifier`）。
    ///
    /// 空串 = 还没选 → 第一次写入时自动建一个「桌面课表」清单。
    var listIdentifier: String = ""

    /// 清单的显示名（存下来是为了设置面板能显示，不用每次去问系统）。
    var listTitle: String = "桌面课表"

    /// 是否在「今日详情」里显示天气。
    ///
    /// 默认**关** —— 天气要申请**定位权限**并**联网**，
    /// 两样都是敏感操作，必须让用户自己开。
    ///
    /// 开着但拿不到位置 / 网络失败 → 网页**隐藏整行**，
    /// 绝不显示假数据。
    var weatherEnabled: Bool = false

    init(enabled: Bool = false,
         listIdentifier: String = "",
         listTitle: String = "桌面课表",
         weatherEnabled: Bool = false) {
        self.enabled = enabled
        self.listIdentifier = listIdentifier
        self.listTitle = listTitle
        self.weatherEnabled = weatherEnabled
    }

    /// 从 `settings.json` 的字典读（缺字段 / 类型非法都退回默认值）。
    init(json obj: [String: Any]) {
        if let b = StrictJSONValue.bool(obj["enabled"]) { enabled = b }
        if let s = obj["listIdentifier"] as? String { listIdentifier = s }
        if let s = obj["listTitle"] as? String, !s.isEmpty { listTitle = s }
        if let b = StrictJSONValue.bool(obj["weatherEnabled"]) { weatherEnabled = b }
    }

    /// 写进 `settings.json` 的字典。
    var jsonObject: [String: Any] {
        ["enabled": enabled,
         "listIdentifier": listIdentifier,
         "listTitle": listTitle,
         "weatherEnabled": weatherEnabled]
    }

    /// 默认清单名（第一次写入时自动建这个）。
    static let defaultListTitle = "桌面课表"
}

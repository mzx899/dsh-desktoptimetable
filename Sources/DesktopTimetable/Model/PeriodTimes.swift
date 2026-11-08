import Foundation

/// 一节课的开始 / 结束时间（24 小时制 `HH:mm`）。
///
/// 课表网格固定 10 节（5 个 block），这里只允许改**钟点**，不允许增删节次 ——
/// 节数同时被 CSS 行数、`Course.blockRange`、导入解析、提醒排程引用，
/// 不是改一个数组就能安全变化的。
struct PeriodTime: Equatable {
    var start: String
    var end: String

    init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    /// 当天零点起的分钟数；时间非法 → nil。
    var startMinutes: Int? { PeriodSettings.minutes(start) }
    var endMinutes: Int? { PeriodSettings.minutes(end) }
}

/// 作息时间设置（存进 `settings.json` 的 `periods` 分组）。
///
/// 文件格式：
/// ```json
/// "periods": {
///   "items": [
///     { "start": "08:00", "end": "08:45" },
///     ... 共 10 项
///   ]
/// }
/// ```
struct PeriodSettings: Equatable {

    /// 节次数量 —— 与网格行数 / CSS 的 `repeat(10, …)` 绑定。
    static let count = 10

    /// 内置默认作息（原来的写死值）。
    static let defaults: [PeriodTime] = [
        PeriodTime(start: "08:00", end: "08:45"),
        PeriodTime(start: "08:50", end: "09:35"),
        PeriodTime(start: "10:05", end: "10:50"),
        PeriodTime(start: "10:55", end: "11:40"),
        PeriodTime(start: "14:00", end: "14:45"),
        PeriodTime(start: "14:50", end: "15:35"),
        PeriodTime(start: "16:05", end: "16:50"),
        PeriodTime(start: "16:55", end: "17:40"),
        PeriodTime(start: "18:40", end: "19:25"),
        PeriodTime(start: "19:30", end: "20:15"),
    ]

    /// 10 节课的起止时间。
    private(set) var times: [PeriodTime]

    init(times: [PeriodTime] = PeriodSettings.defaults) {
        self.times = PeriodSettings.sanitize(times)
    }

    /// 换一份作息。非法配置会被清洗成默认值，保证 `times` 永远可直接使用。
    mutating func setTimes(_ new: [PeriodTime]) {
        times = PeriodSettings.sanitize(new)
    }

    /// 从 `settings.json` 的字典读；缺失 / 损坏 → 默认作息。
    init(json obj: [String: Any]) {
        var parsed: [PeriodTime] = []
        if let items = obj["items"] as? [[String: Any]] {
            for item in items {
                guard let s = item["start"] as? String,
                      let e = item["end"] as? String,
                      let ns = PeriodSettings.normalizeTime(s),
                      let ne = PeriodSettings.normalizeTime(e) else {
                    self.times = PeriodSettings.defaults
                    return
                }
                parsed.append(PeriodTime(start: ns, end: ne))
            }
        }
        self.times = PeriodSettings.sanitize(parsed)
    }

    /// 写进 `settings.json` 的字典。
    var jsonObject: [String: Any] {
        ["items": times.map { ["start": $0.start, "end": $0.end] }]
    }

    /// 是否正好 10 节、每节格式合法、开始早于结束、且前后不重叠。
    ///
    /// 顺序必须**从早到晚**：提醒排程、状态条「下一节」都按节次顺序取，
    /// 时间倒序会让「下一节」永远算错。
    static func isValid(_ times: [PeriodTime]) -> Bool {
        guard times.count == count else { return false }
        var previousEnd = -1
        for t in times {
            guard let s = t.startMinutes, let e = t.endMinutes, s < e else { return false }
            guard s >= previousEnd else { return false }
            previousEnd = e
        }
        return true
    }

    /// 非法配置整份退回默认值 —— 宁可显示内置作息，也不要半套坏时间。
    static func sanitize(_ times: [PeriodTime]) -> [PeriodTime] {
        guard times.count == count else { return defaults }
        let normalized = times.compactMap { t -> PeriodTime? in
            guard let s = normalizeTime(t.start), let e = normalizeTime(t.end) else { return nil }
            return PeriodTime(start: s, end: e)
        }
        guard normalized.count == count, isValid(normalized) else { return defaults }
        return normalized
    }

    /// `"8:5"` / `"08:05"` / 中文冒号 → `"08:05"`；非法 → nil。
    static func normalizeTime(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[0].count <= 2, parts[1].count <= 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isNumber } }),
              let h = Int(parts[0]), let m = Int(parts[1]),
              h >= 0, h <= 23, m >= 0, m <= 59 else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// `"08:05"` → 485；非法 → nil。
    static func minutes(_ hhmm: String) -> Int? {
        guard let normalized = normalizeTime(hhmm) else { return nil }
        let parts = normalized.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

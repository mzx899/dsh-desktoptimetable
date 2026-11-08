import Foundation

/// 宽松字段解析：`day` / `block` / `weeks` 的多种写法统一到一套内部表示。
///
/// 导入（JSON）、磁盘解码（schedule_data.json）共用这里的规则，
/// 避免「导入认得中文星期、读盘不认」这类两套逻辑。
enum FieldParse {

    // MARK: - 星期

    private static let weekdayShort = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private static let weekdayLong = ["星期一", "星期二", "星期三", "星期四",
                                      "星期五", "星期六", "星期日"]
    /// 「星期日」在 Calendar 里是 1，单独处理。
    private static let sundayFirst = ["星期日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// `day`：1...7 / "周四" / "星期四" / "周四上午"（取前缀）。
    /// 解析不出来返回 nil（调用方负责给出可读错误）。
    static func day(_ value: Any?) -> Int? {
        if let n = value as? Int { return (1...7).contains(n) ? n : nil }
        if let n = value as? NSNumber { return (1...7).contains(n.intValue) ? n.intValue : nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if let n = Int(t) { return (1...7).contains(n) ? n : nil }
            if let i = weekdayShort.firstIndex(of: t) { return i + 1 }
            if let i = weekdayLong.firstIndex(of: t) { return i + 1 }
            if let i = sundayFirst.firstIndex(of: t) { return i == 0 ? 7 : i }
            // 「周四上午」这类带后缀的写法：按前缀再试一次。
            for name in weekdayShort + weekdayLong {
                if t.hasPrefix(name) { return day(name) }
            }
        }
        return nil
    }

    /// 解码用：Int / String 两种形态分别尝试。
    static func day(int: Int?, string: String?) -> Int? {
        if let n = int { return (1...7).contains(n) ? n : nil }
        if let s = string { return day(s) }
        return nil
    }

    // MARK: - 节次

    /// `block`：0...4 / "第5-6节" / "第5节"
    ///
    /// 合法范围取 `Course.blockRange`（与网格行数、ImportPlanner 一致）。
    static func block(_ value: Any?) -> Int? {
        if let n = value as? Int { return Course.blockRange.contains(n) ? n : nil }
        if let n = value as? NSNumber { return Course.blockRange.contains(n.intValue) ? n.intValue : nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if let n = Int(t) { return Course.blockRange.contains(n) ? n : nil }
            if let n = firstSectionNumber(t) {
                let b = (n - 1) / 2
                return Course.blockRange.contains(b) ? b : nil
            }
        }
        return nil
    }

    static func block(int: Int?, string: String?) -> Int? {
        if let n = int { return Course.blockRange.contains(n) ? n : nil }
        if let s = string { return block(s) }
        return nil
    }

    private static func firstSectionNumber(_ text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"第\s*(\d+)"#) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    // MARK: - 周次

    /// `weeks`：数组 [1,2,3] / 字符串 "1-3,5-6(单)" / 字符串数组。
    ///
    /// 返回 nil 表示「写法不认得」；返回空数组表示「明确写了没有周次」。
    static func weeks(_ value: Any?) -> [Int]? {
        if value == nil { return nil }
        if let arr = value as? [Int] { return arr }
        if let arr = value as? [NSNumber] { return arr.map { $0.intValue } }
        if let arr = value as? [String] {
            var res = Set<Int>()
            for s in arr { res.formUnion(WeekSpec.expand(s)) }
            return res.sorted()
        }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return [] }        // 明确写了「没有周次」
            let expanded = WeekSpec.expand(t).sorted()
            // 非空字符串却解析不出任何周次 = 写法不认
            return expanded.isEmpty ? nil : expanded
        }
        if let n = value as? NSNumber { return [n.intValue] }
        return nil
    }
}

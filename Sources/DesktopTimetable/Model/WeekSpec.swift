import Foundation

/// 周次字符串的解析与格式化。
enum WeekSpec {
    /// "1-3,5-6,8-15" / "1-3,5-6(单)" → 周次集合。
    ///
    /// 支持 `,` `，` 分隔、`-` `~` 区间、`单` `双` 奇偶过滤。
    static func expand(_ s: String) -> Set<Int> {
        var res = Set<Int>()
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return res }

        for partRaw in trimmed.components(separatedBy: CharacterSet(charactersIn: ",，")) {
            let part = partRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }

            let odd = part.contains("单")
            let even = part.contains("双")
            let ns = part as NSString

            if let m = firstMatch(#"(\d+)\s*[-~]\s*(\d+)"#, in: ns),
               let a = Int(ns.substring(with: m.range(at: 1))),
               let b = Int(ns.substring(with: m.range(at: 2))) {
                for w in a...b where passes(w, odd: odd, even: even) { res.insert(w) }
                continue
            }
            if let m = firstMatch(#"^(\d+)$"#, in: ns),
               let w = Int(ns.substring(with: m.range(at: 1))) {
                if passes(w, odd: odd, even: even) { res.insert(w) }
            }
        }
        return res
    }

    /// {1,2,3,5,6} → "1-3,5-6"
    static func format(_ weeks: Set<Int>) -> String {
        let sorted = weeks.sorted()
        guard !sorted.isEmpty else { return "" }
        var out: [String] = []
        var start = sorted[0], prev = sorted[0]
        for w in sorted.dropFirst() {
            if w == prev + 1 { prev = w; continue }
            out.append(prev > start ? "\(start)-\(prev)" : "\(start)")
            start = w; prev = w
        }
        out.append(prev > start ? "\(start)-\(prev)" : "\(start)")
        return out.joined(separator: ",")
    }

    private static func passes(_ w: Int, odd: Bool, even: Bool) -> Bool {
        if odd && w % 2 == 0 { return false }
        if even && w % 2 == 1 { return false }
        return true
    }

    private static func firstMatch(_ pattern: String, in ns: NSString) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))
    }
}

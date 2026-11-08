import Foundation

/// 把宽松格式的 JSON 课程数组归一化成 `Course`。
///
/// 这里只负责「把文件里的文本变成结构化记录」，**不决定课程身份** —— 身份由
/// `CourseGrouper` 在导入流程里统一分配。
enum JSONCourseNormalizer {

    enum NormalizeError: LocalizedError {
        case empty
        case missingName(index: Int)
        case invalidDay(index: Int, name: String)
        case invalidBlock(index: Int, name: String)
        case notAnArray

        var errorDescription: String? {
            switch self {
            case .empty: return "课程数组是空的"
            case .missingName(let i): return "第 \(i) 条缺少 name（课程名）"
            case .invalidDay(let i, let n):
                return "第 \(i) 条「\(n)」的 day 无效（应为 1–7 或 周一…周日）"
            case .invalidBlock(let i, let n):
                return "第 \(i) 条「\(n)」的 block 无效（应为 0–\(Course.blockRange.upperBound) 或 第1节…第\(Course.blockRange.upperBound * 2 + 2)节）"
            case .notAnArray: return "JSON 顶层不是课程数组"
            }
        }
    }

    /// 归一化。同一 `(day, block, name)` 合并周次与教师（同一格里的重复文本）。
    static func normalize(_ items: [[String: Any]]) throws -> [Course] {
        guard !items.isEmpty else { throw NormalizeError.empty }

        struct Acc {
            var day = 1, block = 0
            var name = "", code = ""
            var teachers: [String] = [], locs: [String] = []
            var weeks = Set<Int>()
            /// 课程颜色（`#rrggbb`）。文件里给了 `color` / `colorHex` 就顺手读，
            /// 读不到 / 非法就忽略 —— 颜色不是导入的必需字段，绝不能因此报错。
            var colorHex: String? = nil
        }

        var acc: [String: Acc] = [:]
        for (idx, item) in items.enumerated() {
            let n = idx + 1
            guard let name = (item["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { throw NormalizeError.missingName(index: n) }
            guard let day = FieldParse.day(item["day"]) else {
                throw NormalizeError.invalidDay(index: n, name: name)
            }
            guard let block = FieldParse.block(item["block"]) else {
                throw NormalizeError.invalidBlock(index: n, name: name)
            }

            let key = "\(day)-\(block)-\(name)"
            var a = acc[key] ?? Acc()
            a.day = day; a.block = block; a.name = name
            if let c = item["code"] as? String, !c.isEmpty { a.code = c }
            if let t = item["teacher"] as? String, !t.isEmpty {
                for p in t.components(separatedBy: "/") where !p.isEmpty && !a.teachers.contains(p) {
                    a.teachers.append(p)
                }
            }
            if let l = item["loc"] as? String, !l.isEmpty, !a.locs.contains(l) { a.locs.append(l) }
            if let ws = FieldParse.weeks(item["weeks"]) {
                a.weeks.formUnion(ws)
            }
            // 颜色是可选字段：给了合法值就用（同组取第一个合法值），没给就算了。
            if a.colorHex == nil,
               let raw = (item["colorHex"] as? String) ?? (item["color"] as? String) {
                a.colorHex = ColorHex.normalized(raw)
            }
            acc[key] = a
        }

        return acc.values
            .sorted { ($0.day, $0.block, $0.name) < ($1.day, $1.block, $1.name) }
            .map { a in
                Course(
                    day: a.day,
                    block: a.block,
                    name: a.name,
                    teacher: a.teachers.joined(separator: "/"),
                    loc: a.locs.joined(separator: " / "),
                    code: a.code,
                    weeksLabel: WeekSpec.format(a.weeks),
                    weeks: a.weeks.sorted(),
                    colorHex: a.colorHex
                )
            }
    }

    /// 从任意 JSON 数据归一化（顶层必须是数组）。
    static func normalize(data: Data) throws -> [Course] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let arr = obj as? [[String: Any]] else { throw NormalizeError.notAnArray }
        return try normalize(arr)
    }
}

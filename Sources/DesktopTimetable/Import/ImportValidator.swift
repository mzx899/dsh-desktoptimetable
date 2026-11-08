import Foundation

/// 导入数据的**校验与补全**（写盘之前的最后一道关）。
///
/// 以前 GUI 导入走的是 `ScheduleImporter.groupedCourses(at:)` ——
/// 只解析 + 分组，**什么都不校验**：
///   · day / block / weeks 都不检查（`block == 5` 的课能写进文件，卡片上永远看不见）；
///   · 空 weeks 不补全（显示成「全部周次」，和别的课对不上）；
///   · anomalies 只 `NSLog` 一句，用户看不到。
/// 而命令行 / 预览走的是 `ImportPlanner.plan`，它有校验 —— **两套标准**。
///
/// 现在把校验 + 补全单独抽出来，两条路径共用同一份实现：
/// `ImportPlanner.plan` 调它，GUI 导入也调它。
enum ImportValidator {

    /// 校验 + 补全的结果。
    struct Result {
        /// 处理后的上课时间记录（周次已补全、标签已刷新）。
        var courses: [Course] = []
        /// 数据异常提示（同名不同 code 之类）。
        var anomalies: [String] = []
        /// 周次为空、被补成「全学期」的课程名（要给用户看）。
        var filledWeekCourses: [String] = []
        /// 本次使用的学期周数。
        var maxWeek: Int = 16
    }

    /// 校验失败。
    enum ValidationError: LocalizedError {
        case invalidDay(name: String, day: Int)
        case invalidBlock(name: String, day: Int, block: Int)
        case weekOutOfRange(name: String, week: Int, maxWeek: Int)
        case invalidWeek(name: String, week: Int)

        var errorDescription: String? {
            switch self {
            case .invalidDay(let n, let d):
                return "「\(n)」的星期无效：\(d)（应为 1–7）"
            case .invalidBlock(let n, let d, _):
                let lastPeriod = Course.blockRange.upperBound * 2 + 2
                return "「\(n)」的上课时间无效：第 \(d) 天，节次超出课表范围（课表只有第 1–\(lastPeriod) 节）"
            case .weekOutOfRange(let n, let w, let m):
                return "「\(n)」的周次超出学期范围：第 \(w) 周（学期共 \(m) 周）"
            case .invalidWeek(let n, let w):
                return "「\(n)」的周次无效：第 \(w) 周（周次从第 1 周开始）"
            }
        }
    }

    /// 校验并补全。
    ///
    /// 规则：
    /// - `day` 必须在 1–7；
    /// - `block` 必须在 `Course.blockRange`（0–4，与 10 节网格一致）；
    /// - `weeks` 为空 → 补成 `1...maxWeek`（和加载时的处理一致）；
    /// - `weeks` 超出 `maxWeek` → 报错（不静默截断）。
    ///
    /// - Parameters:
    ///   - parsed: 解析器给出的上课时间记录。
    ///   - maxWeek: 学期总周数。
    static func normalize(parsed: [Course], maxWeek: Int) throws -> Result {
        let weeks = max(maxWeek, 1)
        var result = Result()
        result.maxWeek = weeks

        var out = parsed
        for i in out.indices {
            let c = out[i]
            guard c.day >= 1, c.day <= 7 else {
                throw ValidationError.invalidDay(name: c.name, day: c.day)
            }
            guard Course.blockRange.contains(c.block) else {
                throw ValidationError.invalidBlock(name: c.name, day: c.day, block: c.block)
            }
            if out[i].weeks.isEmpty {
                // 周次为空 → 按全学期处理（和加载时的行为一致）
                out[i].weeks = Array(1...weeks)
                if !result.filledWeekCourses.contains(c.name) {
                    result.filledWeekCourses.append(c.name)
                }
            } else {
                // **周次下界**：0 或负数是非法数据。
                // `FieldParse.weeks` 放行 `[0]`，而 `Course` 解码时又拒收它 ——
                // 结果是这种记录能写进文件、下次启动却**读不出来**，
                // 课程在用户眼皮底下消失。这里必须在写盘前拦住。
                if let w = out[i].weeks.min(), w < 1 {
                    throw ValidationError.invalidWeek(name: c.name, week: w)
                }
                if let w = out[i].weeks.max(), w > weeks {
                    throw ValidationError.weekOutOfRange(name: c.name, week: w, maxWeek: weeks)
                }
            }
            out[i].refreshWeeksLabel()
        }

        result.courses = out
        // 异常（同名不同 code 之类）由 CourseGrouper 统一收集
        result.anomalies = CourseGrouper.group(out).anomalies
        return result
    }

    /// 给用户看的提示文案（异常 + 周次补全）。
    ///
    /// 没有要提示的东西时返回 nil —— 调用方不该弹一个空窗。
    static func warningText(for result: Result) -> String? {
        var lines: [String] = []
        if !result.filledWeekCourses.isEmpty {
            let names = result.filledWeekCourses.prefix(5).joined(separator: "、")
            let more = result.filledWeekCourses.count > 5
                ? " 等 \(result.filledWeekCourses.count) 门课" : ""
            lines.append("以下课程没有写周次，已按第 1–\(result.maxWeek) 周（全学期）处理：\(names)\(more)")
        }
        if !result.anomalies.isEmpty {
            lines.append("发现 \(result.anomalies.count) 处数据异常：")
            for a in result.anomalies.prefix(5) { lines.append("· \(a)") }
            if result.anomalies.count > 5 {
                lines.append("· …等 \(result.anomalies.count) 处")
            }
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

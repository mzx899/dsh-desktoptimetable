import Foundation

/// 课表导入的统一入口：按文件内容自动识别 `.xls`（HTML 表格）/ `.json`。
///
/// 解析器只负责产出「上课时间记录」；课程身份（courseID）由
/// `CourseGrouper` + `ImportPlanner` 统一决定。
enum ScheduleImporter {

    enum ImportError: LocalizedError {
        case readFailed(String)
        case unsupportedFormat
        case empty

        var errorDescription: String? {
            switch self {
            case .readFailed(let m): return "无法读取文件：\(m)"
            case .unsupportedFormat: return "不认识的课表格式（支持教务系统导出的 .xls 或课程 JSON 数组）"
            case .empty: return "文件里没有课程"
            }
        }
    }

    /// 解析结果。
    struct Result {
        /// 解析出的上课时间记录（还没有 courseID）。
        var records: [Course]
        var format: Format
        /// 解析阶段发现的问题（要展示给用户，不能只写日志）。
        ///
        /// 例如教务系统表格里的第 11–12 节 —— 课表网格只有 10 节，
        /// 那部分数据进不来，必须让用户知道哪门课少了一部分。
        var notices: [String] = []
    }

    enum Format: String {
        case xls = "教务系统课表（.xls）"
        case json = "JSON 课表"
    }

    // MARK: -

    /// 只解析，不分组、不写盘。
    static func parse(at url: URL) throws -> Result {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.readFailed(error.localizedDescription)
        }
        guard !data.isEmpty else { throw ImportError.empty }

        let records: [Course]
        let format: Format
        var notices: [String] = []
        if looksLikeHTML(data) {
            let parsed = try XlsScheduleParser.parseWithNotices(at: url)
            records = parsed.courses
            notices = parsed.notices
            format = .xls
        } else {
            records = try JSONCourseNormalizer.normalize(data: data)
            format = .json
        }
        guard !records.isEmpty else { throw ImportError.empty }
        return Result(records: records, format: format, notices: notices)
    }

    /// 解析并分组，得到带 courseID 的课程列表。
    ///
    /// 分组只走 `CourseGrouper` 这一条实现（和迁移共用）。
    static func groupedCourses(at url: URL) throws -> [Course] {
        let result = try parse(at: url)
        let (courses, _) = CourseGrouper.assignCourseIDs(result.records)
        return courses
    }

    /// 解析 + 分组 + 匹配已有课程 → 导入计划（**写盘之前**给用户预览）。
    static func plan(at url: URL, existing: [Course], maxWeek: Int) throws -> (ImportPlanner.Plan, Format) {
        let result = try parse(at: url)
        let plan = try ImportPlanner.plan(parsed: result.records, existing: existing, maxWeek: maxWeek)
        return (plan, result.format)
    }

    /// 内容嗅探：HTML 表格 → .xls；否则按 JSON 处理。
    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(data: data.prefix(4096), encoding: .utf8)
            ?? String(data: data.prefix(4096), encoding: .isoLatin1)
            ?? ""
        let lower = head.lowercased()
        return lower.contains("<table") || lower.contains("<html") || lower.contains("<!doctype html")
    }

    /// 找出同一 (day, block) 上的不同课程（保留旧接口，内部走新的冲突检测）。
    static func detectConflicts(_ courses: [Course]) -> [Conflict] {
        detectConflictsNew(courses).map { c in
            Conflict(day: c.day, block: c.block, names: c.names)
        }
    }

    /// 同一时间格出现两门不同课程（桌面每格只放得下一门）。
    struct Conflict: Equatable {
        var day: Int
        var block: Int
        var names: [String]
    }

    /// 新版冲突检测（含 courseID 与周次交集判定）。
    static func detectConflictsNew(_ courses: [Course]) -> [ScheduleConflicts.Conflict] {
        ScheduleConflicts.detect(courses)
    }
}

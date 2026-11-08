import Foundation

/// 教务系统导出的 `.xls`（其实是 HTML 表格）解析器。
///
/// 关键点：这张表用 `rowspan` / `colspan` 合并单元格（连堂课会 `rs=2`）。
/// 必须先把表格还原成「真实网格」再按列取星期，否则合并行里 td 变少，
/// 后面的列整体左移一格，课程就落到错误的星期上。
enum XlsScheduleParser {

    enum ParseError: LocalizedError {
        case tableNotFound
        case malformedTable(String)
        case parseFailed(String)
        case emptyTable
        case noCourses

        var errorDescription: String? {
            switch self {
            case .tableNotFound:
                return "这个文件里找不到课表表格（manualArrangeCourseTable）"
            case .malformedTable(let m): return "课表表格结构异常：\(m)"
            case .parseFailed(let m): return "课表表格解析失败：\(m)"
            case .emptyTable: return "课表表格是空的"
            case .noCourses: return "课表表格里没有解析出课程"
            }
        }
    }

    private static let sectionNames = [
        "第一节", "第二节", "第三节", "第四节", "第五节", "第六节",
        "第七节", "第八节", "第九节", "第十节", "第十一节", "第十二节",
    ]
    private static let weekdayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

    // MARK: - 入口

    /// 解析结果：课程 + 需要告诉用户的事。
    struct Result {
        var courses: [Course] = []
        /// 解析过程中发现、但不影响主体数据的问题（要展示给用户，不能只写日志）。
        var notices: [String] = []
    }

    /// 解析（只取课程）。
    static func parse(at url: URL) throws -> [Course] {
        try parseWithNotices(at: url).courses
    }

    /// 解析（课程 + 提示）。
    static func parseWithNotices(at url: URL) throws -> Result {
        let text = try readText(at: url)
        let fragment = try extractTableFragment(text)
        let cells = try parseXML(fragment)
        let grid = buildGrid(cells)
        return try extractCourses(rows: cells, grid: grid)
    }

    /// 也接受已经读进内存的 HTML 字符串（测试用）。
    static func parse(html: String) throws -> [Course] {
        try parseWithNotices(html: html).courses
    }

    /// 也接受已经读进内存的 HTML 字符串（课程 + 提示）。
    static func parseWithNotices(html: String) throws -> Result {
        let fragment = try extractTableFragment(html)
        let cells = try parseXML(fragment)
        let grid = buildGrid(cells)
        return try extractCourses(rows: cells, grid: grid)
    }

    // MARK: - 取表格片段

    static func extractTableFragment(_ text: String) throws -> String {
        guard let idRange = text.range(of: "manualArrangeCourseTable") else {
            throw ParseError.tableNotFound
        }
        let before = text[text.startIndex..<idRange.lowerBound]
        guard let tblStart = before.range(of: "<table", options: .backwards) else {
            throw ParseError.malformedTable("起始标签缺失")
        }
        guard let tblEnd = text.range(of: "</table>", range: idRange.upperBound..<text.endIndex) else {
            throw ParseError.malformedTable("结束标签缺失")
        }
        return sanitize(String(text[tblStart.lowerBound..<tblEnd.upperBound]))
    }

    /// HTML → 合法 XML。
    static func sanitize(_ fragment: String) -> String {
        var frag = fragment.replacingOccurrences(of: "&nbsp;", with: "&#160;")
        // `<br>` 可能带属性（`<br style="mso-data-placement: same-cell">`），
        // 正则必须把属性也算进去，否则标签补不闭合、XMLParser 直接报错。
        // 模板里的 `$1` 是标签名；不能用 `$0`（那是整个匹配，会拼出 `<<br>/>`）。
        frag = replaceVoidTags(frag, names: ["br"])
        frag = replaceVoidTags(frag, names: ["hr", "img", "meta", "link", "input", "col"])
        return frag
    }

    private static func replaceVoidTags(_ html: String, names: [String]) -> String {
        let pattern = "<(" + names.joined(separator: "|") + ")(\\s[^>]*)?/?>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        return re.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: "<$1/>"
        )
    }

    // MARK: - XML 解析

    struct Cell {
        var text = ""
        var rowSpan = 1
        var colSpan = 1
    }

    /// 收集表格里每个单元格的文本与合并跨度。
    final class TableDelegate: NSObject, XMLParserDelegate {
        var rows: [[Cell]] = []
        private var curRow: [Cell] = []
        private var curCell: Cell?
        private var inCell = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let e = elementName.lowercased()
            if e == "td" || e == "th" {
                if inCell { curCell?.text += "\n"; return }
                let rs = max(1, Int(attributeDict["rowspan"] ?? "1") ?? 1)
                let cs = max(1, Int(attributeDict["colspan"] ?? "1") ?? 1)
                curCell = Cell(text: "", rowSpan: rs, colSpan: cs)
                inCell = true
            } else if e == "br" {
                if inCell { curCell?.text += "\n" }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCell { curCell?.text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let e = elementName.lowercased()
            if e == "td" || e == "th" {
                if let c = curCell { curRow.append(c) }
                curCell = nil
                inCell = false
            } else if e == "tr" {
                rows.append(curRow)
                curRow = []
            }
        }
    }

    static func parseXML(_ fragment: String) throws -> [[Cell]] {
        let parser = XMLParser(data: Data(fragment.utf8))
        let delegate = TableDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.parseFailed(parser.parserError?.localizedDescription ?? "未知错误")
        }
        guard !delegate.rows.isEmpty else { throw ParseError.emptyTable }
        return delegate.rows
    }

    // MARK: - 网格还原

    /// 把 `<table>` 片段还原成「(行, 列) → 文本」的网格，正确处理 rowspan/colspan。
    static func buildGrid(_ rows: [[Cell]]) -> [String: String] {
        var grid = [String: String]()
        var occupied = Set<String>()
        func key(_ r: Int, _ c: Int) -> String { "\(r),\(c)" }

        for (ri, row) in rows.enumerated() {
            var ci = 0
            for cell in row {
                while occupied.contains(key(ri, ci)) { ci += 1 }
                for dr in 0..<cell.rowSpan {
                    for dc in 0..<cell.colSpan {
                        grid[key(ri + dr, ci + dc)] = cell.text
                        occupied.insert(key(ri + dr, ci + dc))
                    }
                }
                ci += cell.colSpan
            }
        }
        return grid
    }

    // MARK: - 取课程

    private struct Acc {
        var day = 1, block = 0
        var name = "", code = ""
        var teachers: [String] = [], locs: [String] = []
        var weeks = Set<Int>()
    }

    static func extractCourses(rows: [[Cell]], grid: [String: String]) throws -> Result {
        var result = Result()
        // 表头：第一个单元格含「周次」的那行，第 1...7 列是星期一...星期日
        var colToDay: [Int: Int] = [:]
        for ri in rows.indices {
            let head = (grid["\(ri),0"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.contains("周次") else { continue }
            for ci in 1...7 {
                let t = (grid["\(ri),\(ci)"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let idx = weekdayNames.firstIndex(of: t) { colToDay[ci] = idx + 1 }
            }
            break
        }
        if colToDay.isEmpty {
            for ci in 1...7 { colToDay[ci] = ci }
        }

        // 教务系统的表格是 **12 节**，而课表网格只有 10 节（block 0…4）。
        //
        // 以前第 11–12 节的行也会被解析成 `block = 5` 写进文件 ——
        // 结果是那条记录**读不出来**（`Course` 解码时 block 越界），
        // 课程在下次启动时**静默消失**，而用户从头到尾没收到任何提示。
        // 现在：超网格的行**跳过**，并明确告诉用户哪门课没进来。
        var skippedCourses: [String] = []
        let lastBlock = Course.blockRange.upperBound

        var acc: [String: Acc] = [:]
        for ri in rows.indices {
            let label = (grid["\(ri),0"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let secIdx = sectionNames.firstIndex(of: label) else { continue }
            let block = secIdx / 2          // 每 2 节一个 block
            if block > lastBlock {
                // 超出网格 → 记下来，不进数据
                for (ci, _) in colToDay {
                    guard let cell = grid["\(ri),\(ci)"] else { continue }
                    for e in CellTextParser.parse(cell) where !e.name.isEmpty {
                        if !skippedCourses.contains(e.name) { skippedCourses.append(e.name) }
                    }
                }
                continue
            }
            for (ci, day) in colToDay {
                guard let cell = grid["\(ri),\(ci)"] else { continue }
                for e in CellTextParser.parse(cell) {
                    let key = "\(day)-\(block)-\(e.name)"
                    var a = acc[key] ?? Acc()
                    a.day = day; a.block = block
                    if a.name.isEmpty { a.name = e.name; a.code = e.code }
                    a.weeks.formUnion(e.weeks)
                    if !e.teacher.isEmpty && !a.teachers.contains(e.teacher) { a.teachers.append(e.teacher) }
                    if !e.loc.isEmpty && !a.locs.contains(e.loc) { a.locs.append(e.loc) }
                    acc[key] = a
                }
            }
        }

        var out: [Course] = []
        for a in acc.values.sorted(by: { ($0.day, $0.block, $0.name) < ($1.day, $1.block, $1.name) }) {
            out.append(Course(
                day: a.day,
                block: a.block,
                name: a.name,
                teacher: a.teachers.joined(separator: "/"),
                loc: a.locs.joined(separator: " / "),
                code: a.code,
                weeksLabel: WeekSpec.format(a.weeks),
                weeks: a.weeks.sorted()
            ))
        }
        guard !out.isEmpty else { throw ParseError.noCourses }
        result.courses = out
        if !skippedCourses.isEmpty {
            let names = skippedCourses.prefix(5).joined(separator: "、")
            let more = skippedCourses.count > 5 ? " 等 \(skippedCourses.count) 门课" : ""
            result.notices.append("以下课程有上课时间在第 11–12 节，课表只有 10 节，那部分没有导入：\(names)\(more)")
        }
        return result
    }

    // MARK: -

    private static func readText(at url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        // 有些导出的 .xls 是 UTF-16
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf16) { return s }
        throw ParseError.malformedTable("无法按文本读取该文件")
    }
}

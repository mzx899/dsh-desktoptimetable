import Foundation

/// 从单元格文本里抽出来的课程条目（还没落到具体星期）。
struct RawEntry: Equatable {
    var name: String = ""
    var code: String = ""
    var teacher: String = ""
    var weeksRaw: String = ""
    var loc: String = ""

    var weeks: Set<Int> { WeekSpec.expand(weeksRaw) }
    var weeksLabel: String { WeekSpec.format(weeks) }
}

/// 单元格文本 → 课程条目。
///
/// 每门课三行：
/// ```
/// 数据结构 (3030112015.02)
/// (宋欣)
/// (1-14  工学馆506(学校本部))
/// ```
enum CellTextParser {
    static func parse(_ text: String) -> [RawEntry] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [RawEntry] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.hasSuffix(")"), let open = line.lastIndex(of: "("), open > line.startIndex else {
                i += 1; continue
            }
            let code = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            let codeOK = !code.isEmpty && code.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
            }
            guard codeOK else { i += 1; continue }
            let name = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { i += 1; continue }

            var e = RawEntry()
            e.name = name
            e.code = code

            var j = i + 1
            if j < lines.count, lines[j].hasPrefix("(") {
                let l = lines[j]
                e.teacher = (l.hasSuffix(")") ? String(l.dropFirst().dropLast()) : String(l.dropFirst()))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                j += 1
            }
            if j < lines.count, lines[j].hasPrefix("(") {
                let l = lines[j]
                let inner = (l.hasSuffix(")") ? String(l.dropFirst().dropLast()) : String(l.dropFirst()))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = inner.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count >= 2 {
                    e.weeksRaw = String(parts[0])
                    // 原表里「(1-14␣␣工学馆506)」有两个空格，切开后还要去掉前导空白
                    e.loc = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if parts.count == 1 {
                    e.weeksRaw = String(parts[0])
                }
                j += 1
            }
            out.append(e)
            i = j
        }
        return out
    }
}

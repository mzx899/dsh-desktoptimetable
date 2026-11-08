import Foundation

/// 课程分组：**纯函数**，迁移和导入共用同一套逻辑（禁止两套实现）。
///
/// 分组键规则：
///   1. `code` 非空 → 规范化后的 `code`；
///   2. `code` 为空 → 规范化后的课名；
///   3. 同一个 `code` 对应多个不同课名 → 改用 `code + name` 复合键，并报告数据异常。
///
/// 规范化：trim、折叠空白、全角/半角统一；**匹配时大小写不敏感**；
/// 显示永远保留原文（不删括号、不删后缀）。
enum CourseGrouper {

    /// 一个分组（= 一门课）。
    struct Group {
        /// 分组键（规范化之后）。
        var key: String
        /// 显示用课名（原文）。
        var name: String
        /// 显示用课程代码（原文）。
        var code: String
        /// 组内的上课时间记录。
        var records: [Course]
    }

    /// 带原始下标的分组（内部用，保证结果顺序与输入一致）。
    struct IndexedGroup {
        var key: String
        var name: String
        var code: String
        /// (原始下标, 记录)
        var records: [(index: Int, course: Course)]
    }

    /// 分组结果 + 数据异常提示。
    struct Result {
        var groups: [Group] = []
        /// 数据异常提示（同名不同 code、同 code 不同名等）。
        var anomalies: [String] = []
        /// 带原始下标的分组（内部用）。
        var indexedGroups: [IndexedGroup] = []
    }

    // MARK: - 规范化

    /// 规范化文本：trim、折叠空白、全角→半角。保留大小写与原文用字。
    static func normalize(_ s: String) -> String {
        let folded = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        let parts = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// 匹配用的键：在规范化的基础上再折叠大小写。
    static func matchKey(_ s: String) -> String {
        normalize(s).lowercased()
    }

    // MARK: - 分组

    /// 按规则把上课时间记录分组成课程。
    static func group(_ courses: [Course]) -> Result {
        let indexed = groupIndexed(courses.enumerated().map { (index: $0.offset, course: $0.element) })
        var result = Result()
        result.anomalies = indexed.anomalies
        result.indexedGroups = indexed.indexedGroups
        for g in indexed.indexedGroups {
            result.groups.append(Group(key: g.key, name: g.name, code: g.code,
                                       records: g.records.map { $0.course }))
        }
        return result
    }

    /// 分组（内部实现，保留原始下标）。
    static func groupIndexed(_ items: [(index: Int, course: Course)]) -> Result {
        var result = Result()
        guard !items.isEmpty else { return result }

        // 先算出每条记录的「基础键」和显示用的名字/代码。
        struct Entry {
            var index: Int
            var baseKey: String
            var nameKey: String
            /// 显示用课名（原文，不做全角/半角转换）
            var name: String
            /// 显示用代码（原文）
            var code: String
            var course: Course
        }
        var entries: [Entry] = []
        entries.reserveCapacity(items.count)

        // code → 该 code 下出现过的课名集合（规范化后）
        var namesByCode: [String: Set<String>] = [:]

        for item in items {
            let c = item.course
            let code = normalize(c.code)
            let codeKey = matchKey(c.code)
            let nameKey = matchKey(c.name)
            if !code.isEmpty {
                namesByCode[codeKey, default: []].insert(nameKey)
            }
            let baseKey = code.isEmpty ? "name:" + nameKey : "code:" + codeKey
            entries.append(Entry(index: item.index, baseKey: baseKey, nameKey: nameKey,
                                name: c.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                code: c.code.trimmingCharacters(in: .whitespacesAndNewlines),
                                course: c))
        }

        // 同一个 code 对应多个不同课名 → 用 code+name 复合键。
        var buckets: [String: [Entry]] = [:]
        var bucketOrder: [String] = []
        for e in entries {
            var key = e.baseKey
            if e.baseKey.hasPrefix("code:"),
               let names = namesByCode[String(e.baseKey.dropFirst(5))],
               names.count > 1 {
                key = "code+name:" + String(e.baseKey.dropFirst(5)) + "|" + e.nameKey
            }
            if buckets[key] == nil { bucketOrder.append(key) }
            buckets[key, default: []].append(e)
        }

        // code 为空、但课名唯一对应某个带 code 的分组时 → 并入那个分组。
        // （课名对不上任何带 code 的分组时，这些记录自成一分组。）
        var codedGroupsByName: [String: [String]] = [:]   // nameKey → 带 code 的分组键
        for key in bucketOrder where !key.hasPrefix("name:") {
            for e in buckets[key] ?? [] {
                codedGroupsByName[e.nameKey, default: []].append(key)
            }
        }

        var merged: [String: [Entry]] = [:]
        var mergedOrder: [String] = []
        for key in bucketOrder {
            for e in buckets[key] ?? [] {
                var target = key
                if e.baseKey.hasPrefix("name:") {
                    let nameKey = String(e.baseKey.dropFirst(5))
                    let candidates = codedGroupsByName[nameKey] ?? []
                    if candidates.count == 1 {
                        target = candidates[0]
                    }
                }
                if merged[target] == nil { mergedOrder.append(target) }
                merged[target, default: []].append(e)
            }
        }

        var indexedGroups: [IndexedGroup] = []
        for key in mergedOrder {
            let items = merged[key] ?? []
            guard let first = items.first else { continue }
            indexedGroups.append(IndexedGroup(key: key,
                                              name: first.name,
                                              code: first.code,
                                              records: items.map { (index: $0.index, course: $0.course) }))
        }

        // 异常提示：同 code 不同名
        for (codeKey, names) in namesByCode where names.count > 1 {
            let display = items.first { matchKey($0.course.code) == codeKey }?.course
            result.anomalies.append(
                "课程代码「\(display?.code ?? codeKey)」对应了 \(names.count) 个不同课名，已按「代码+课名」拆成多门课")
        }
        // 异常提示：同名不同 code
        var codesByName: [String: Set<String>] = [:]
        for item in items where !normalize(item.course.code).isEmpty {
            codesByName[matchKey(item.course.name), default: []].insert(matchKey(item.course.code))
        }
        for (nameKey, codes) in codesByName where codes.count > 1 {
            let display = items.first { matchKey($0.course.name) == nameKey }?.course
            result.anomalies.append(
                "课程「\(display?.name ?? nameKey)」有 \(codes.count) 个不同的课程代码，已按代码拆成多门课")
        }
        result.anomalies.sort()
        result.indexedGroups = indexedGroups
        return result
    }

    // MARK: - courseID 分配

    /// 分组 + 分配 courseID。
    ///
    /// - 已有 courseID 的记录**原样保留**；
    /// - 同组里既有带 ID 的记录又有不带的 → 不带的继承组里那个 ID；
    /// - 组里一个 ID 都没有 → 生成一个新的 UUID；
    /// - 组里出现多个不同 ID → 视为数据异常，各自带 ID 的原样保留，不带的另发新 ID。
    ///
    /// 幂等：所有记录都带上 ID 之后，再跑一次不会改变任何 ID。
    static func assignCourseIDs(_ courses: [Course]) -> (courses: [Course], anomalies: [String]) {
        // 用「带下标」的分组，结果按原始顺序返回：
        // 不打乱用户已有的记录顺序，否则每次加载都会因为顺序变化而重复写盘。
        let grouped = groupIndexed(courses.enumerated().map { (index: $0.offset, course: $0.element) })
        var out: [Course?] = [Course?](repeating: nil, count: courses.count)

        for g in grouped.indexedGroups {
            var existingIDs: [String] = []
            for rec in g.records where !rec.course.courseID.isEmpty {
                if !existingIDs.contains(rec.course.courseID) { existingIDs.append(rec.course.courseID) }
            }
            var inheritedID: String?
            if existingIDs.count == 1 {
                inheritedID = existingIDs[0]
            } else if existingIDs.count > 1 {
                // 同组多个 ID：异常，带 ID 的保留，不带的另发
                inheritedID = nil
            }
            var newID = inheritedID
            for rec in g.records {
                var r = rec.course
                if r.courseID.isEmpty {
                    if newID == nil {
                        newID = UUID().uuidString
                    }
                    r.courseID = newID ?? UUID().uuidString
                }
                out[rec.index] = r
            }
        }
        let ordered = out.compactMap { $0 }

        var anomalies = grouped.anomalies
        // 同组多 ID 的异常补上
        for g in grouped.indexedGroups {
            var ids: [String] = []
            for rec in g.records where !rec.course.courseID.isEmpty {
                if !ids.contains(rec.course.courseID) { ids.append(rec.course.courseID) }
            }
            if ids.count > 1 {
                anomalies.append("课程「\(g.name)」的 \(ids.count) 条记录带有不同的 courseID，已原样保留")
            }
        }
        anomalies.sort()
        return (ordered, anomalies)
    }

    /// 已经带 courseID 的数据里，一共有多少门课。
    static func courseIDCount(_ courses: [Course]) -> Int {
        Set(courses.map { $0.courseID }.filter { !$0.isEmpty }).count
    }
}

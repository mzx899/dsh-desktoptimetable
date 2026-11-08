import Foundation

/// 导入计划：**在写盘之前**算清楚「会发生什么」。
///
/// 流程：解析 → 分组（CourseGrouper）→ 与已有课程匹配 → 写入 courseID → 校验 → 预览。
/// 解析器只负责把文件变成「上课时间记录」，**不决定课程身份**。
enum ImportPlanner {

    /// 一门课在导入结果里的状态。
    enum MatchKind: Equatable {
        /// 匹配到已有课程 → 复用旧 courseID。
        case reused(courseID: String)
        /// 全新课程 → 新 UUID。
        case created
        /// 匹配不唯一 → 需要用户在预览里选「合并到已有课程」或「新建」。
        case ambiguous(candidates: [String])
    }

    /// 一门课（= 一个 courseID）的导入结果。
    struct PlanCourse {
        var courseID: String
        var name: String
        var code: String
        /// 该门课的上课时间记录。
        var records: [Course]
        var match: MatchKind
    }

    /// 整个导入计划。
    struct Plan {
        var courses: [PlanCourse] = []
        /// 解析出多少条上课时间记录。
        var recordCount = 0
        /// 匹配到已有课程的课程数。
        var reusedCount = 0
        /// 新建的课程数。
        var createdCount = 0
        /// 会被移除的旧课程（courseID + 课名）。
        var removedCourses: [(courseID: String, name: String)] = []
        /// 冲突格。
        var conflicts: [ScheduleConflicts.Conflict] = []
        /// 同一门课同一格的重复。
        var duplicates: [ScheduleConflicts.Duplicate] = []
        /// 需要用户决定的课程（匹配不唯一）。
        var ambiguous: [PlanCourse] = []
        /// 数据异常提示。
        var anomalies: [String] = []
        /// 周次为空、被补成「全学期」的课程名（界面上要显示给用户看）。
        var filledWeekCourses: [String] = []

        /// 预览摘要（给用户看的文案）。
        var summary: String {
            var s = "识别出 \(courses.count) 门课 / \(recordCount) 个上课时间\n"
            s += "匹配已有课程 \(reusedCount) 门 · 新增 \(createdCount) 门\n"
            s += "将从课表移除 \(removedCourses.count) 门未匹配的课程\n"
            s += conflicts.isEmpty ? "没有冲突\n" : "有 \(conflicts.count) 个时间格存在冲突\n"
            if !ambiguous.isEmpty {
                s += "有 \(ambiguous.count) 门课匹配不唯一，需要你选择合并还是新建\n"
            }
            if !filledWeekCourses.isEmpty {
                s += "有 \(filledWeekCourses.count) 门课没写周次，已按全学期处理\n"
            }
            if !anomalies.isEmpty {
                s += "有 \(anomalies.count) 处数据异常\n"
            }
            return s
        }
    }

    /// 校验失败。真正的定义在 `ImportValidator`（GUI 导入和命令行共用同一份）。
    typealias PlannerError = ImportValidator.ValidationError

    // MARK: - 计划

    /// 根据解析结果和已有课程，算出导入计划。
    ///
    /// - Parameters:
    ///   - parsed: 解析器给出的上课时间记录（还没有 courseID）。
    ///   - existing: 课表里已有的课程（带 courseID）。
    ///   - maxWeek: 学期总周数（用于校验周次）。
    static func plan(parsed source: [Course], existing: [Course], maxWeek: Int) throws -> Plan {
        var result = Plan()
        var parsed = source
        result.recordCount = parsed.count

        // ---- 校验 + 补全（和 GUI 导入共用同一份实现）----
        //
        // 以前这段校验写在这里，GUI 导入却绕开了它 —— 两套标准。
        // 现在统一走 `ImportValidator`：day / block 越界直接报错，
        // 空 weeks 补成全学期（并记录下来，界面上要显示给用户看）。
        let normalized = try ImportValidator.normalize(parsed: parsed, maxWeek: maxWeek)
        parsed = normalized.courses
        result.filledWeekCourses = normalized.filledWeekCourses

        // ---- 分组（唯一入口）----
        let grouped = CourseGrouper.group(parsed)
        result.anomalies = grouped.anomalies

        // ---- 与已有课程匹配 ----
        // 已有课程按 courseID 归拢：courseID → (课名, 代码)
        var existingByID: [String: (name: String, code: String)] = [:]
        for c in existing where !c.courseID.isEmpty {
            if existingByID[c.courseID] == nil {
                existingByID[c.courseID] = (c.name, c.code)
            }
        }
        // 按规范化 code 找已有课程
        var existingByCode: [String: [String]] = [:]
        for (id, info) in existingByID where !CourseGrouper.matchKey(info.code).isEmpty {
            existingByCode[CourseGrouper.matchKey(info.code), default: []].append(id)
        }
        // 按规范化课名找已有课程
        var existingByName: [String: [String]] = [:]
        for (id, info) in existingByID {
            existingByName[CourseGrouper.matchKey(info.name), default: []].append(id)
        }

        // ---- 逐组决定 courseID ----
        var usedIDs = Set<String>()
        for g in grouped.groups {
            let codeKey = CourseGrouper.matchKey(g.code)
            let nameKey = CourseGrouper.matchKey(g.name)

            var candidates: [String] = []
            if !codeKey.isEmpty {
                candidates = existingByCode[codeKey] ?? []
            } else {
                candidates = existingByName[nameKey] ?? []
            }

            var match: MatchKind
            var courseID: String
            if candidates.count == 1 {
                courseID = candidates[0]
                match = .reused(courseID: courseID)
                result.reusedCount += 1
            } else if candidates.count > 1 {
                // 不猜：交给用户在预览里选
                courseID = UUID().uuidString
                match = .ambiguous(candidates: candidates)
                result.ambiguous.append(
                    PlanCourse(courseID: courseID, name: g.name, code: g.code,
                               records: g.records, match: match))
            } else {
                // 课名相同但 code 不同 → 不猜，交给用户
                let sameName = existingByName[nameKey] ?? []
                let differentCode = sameName.filter { id in
                    guard let info = existingByID[id] else { return false }
                    return CourseGrouper.matchKey(info.code) != codeKey
                }
                if !codeKey.isEmpty && !differentCode.isEmpty {
                    courseID = UUID().uuidString
                    match = .ambiguous(candidates: differentCode)
                    result.ambiguous.append(
                        PlanCourse(courseID: courseID, name: g.name, code: g.code,
                                   records: g.records, match: match))
                } else {
                    courseID = UUID().uuidString
                    match = .created
                    result.createdCount += 1
                }
            }
            usedIDs.insert(courseID)

            var records = g.records
            for i in records.indices {
                records[i].courseID = courseID
                records[i].refreshWeeksLabel()
            }
            result.courses.append(PlanCourse(courseID: courseID, name: g.name, code: g.code,
                                             records: records, match: match))
        }

        // ---- 移除未匹配的旧课程 ----
        // 歧义候选（旧课可能被合并进来）**不算**「确定移除」，
        // 交给 finalizeRemoved 在用户决定之后按最终 courseID 重算。
        var pending = Set<String>()
        for pc in result.ambiguous {
            if case .ambiguous(let cs) = pc.match { pending.formUnion(cs) }
        }
        for (id, info) in existingByID where !usedIDs.contains(id) && !pending.contains(id) {
            result.removedCourses.append((courseID: id, name: info.name))
        }
        result.removedCourses.sort { $0.name < $1.name }

        // ---- 冲突 / 重复 ----
        let allRecords = result.courses.flatMap { $0.records }
        result.conflicts = ScheduleConflicts.detect(allRecords)
        result.duplicates = ScheduleConflicts.duplicates(allRecords)

        return result
    }

    /// 把计划落成最终的课程数组（替换导入）。
    static func materialize(_ plan: Plan) -> [Course] {
        plan.courses.flatMap { $0.records }
            .sorted { ($0.day, $0.block, $0.name) < ($1.day, $1.block, $1.name) }
    }

    /// 用户在预览里处理完「匹配不唯一」的课程后，按最终 courseID 重算「将被移除的旧课程」。
    ///
    /// 合并到已有课程后，那门旧课不再被移除 —— 必须重算，否则预览文案说谎。
    ///
    /// - Parameters:
    ///   - plan: 原计划（`removedCourses` 里可能含「待决定」的旧课）。
    ///   - existing: 导入前的旧课程。
    static func finalizeRemoved(plan: Plan, existing: [Course]) -> Plan {
        var updated = plan
        let kept = Set(updated.courses.map { $0.courseID })
        var removed: [(courseID: String, name: String)] = []
        var seen = Set<String>()
        for c in existing where !c.courseID.isEmpty {
            guard !kept.contains(c.courseID) else { continue }
            if seen.contains(c.courseID) { continue }
            seen.insert(c.courseID)
            removed.append((courseID: c.courseID, name: c.name))
        }
        removed.sort { $0.name < $1.name }
        updated.removedCourses = removed
        return updated
    }

    /// 幂等性检查：重复导入同一份文件 → 课程数、courseID 都不变。
    static func isIdempotent(_ before: [Course], _ after: [Course]) -> Bool {
        guard before.count == after.count else { return false }
        let beforeIDs = Set(before.map { "\($0.courseID)-\($0.day)-\($0.block)" })
        let afterIDs = Set(after.map { "\($0.courseID)-\($0.day)-\($0.block)" })
        return beforeIDs == afterIDs
    }
}

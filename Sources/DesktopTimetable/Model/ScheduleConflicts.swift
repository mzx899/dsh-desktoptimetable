import Foundation

/// 冲突检测。
///
/// 规则（产品定义）：
///   · **冲突**：不同 courseID、同一 day+block、weeks 有交集。
///   · **重复上课时间**：同一 courseID、同一 day+block 出现两条记录 → 拒绝保存。
///   · 单双周交替（weeks 无交集）→ **不算**冲突。
enum ScheduleConflicts {

    /// 一个冲突格。
    struct Conflict: Equatable {
        var day: Int
        var block: Int
        /// 参与冲突的课程（按 courseID 去重）。
        var courses: [Course]

        var names: [String] { courses.map { $0.name }.sorted() }
        var timeText: String {
            "\(Schedule.dayNames[max(0, min(6, day - 1))]) 第\(block * 2 + 1)-\(block * 2 + 2)节"
        }
    }

    /// 同一门课同一格重复（同一 courseID + day + block）。
    struct Duplicate: Equatable {
        var courseID: String
        var day: Int
        var block: Int
        var name: String

        var timeText: String {
            "\(Schedule.dayNames[max(0, min(6, day - 1))]) 第\(block * 2 + 1)-\(block * 2 + 2)节"
        }
    }

    /// 两个周次集合是否有交集。
    static func weeksOverlap(_ a: [Int], _ b: [Int]) -> Bool {
        let sa = Set(a), sb = Set(b)
        return !sa.isDisjoint(with: sb)
    }

    /// 找出所有冲突格（不同 courseID，同 day+block，周次有交集）。
    static func detect(_ courses: [Course]) -> [Conflict] {
        var bySlot: [String: [Course]] = [:]
        var slotInfo: [String: (day: Int, block: Int)] = [:]
        for c in courses {
            let key = "\(c.day)-\(c.block)"
            bySlot[key, default: []].append(c)
            slotInfo[key] = (c.day, c.block)
        }

        var out: [Conflict] = []
        for (key, list) in bySlot {
            // 同一 courseID 在同一格的重复不算「冲突」，由 duplicates() 单独报
            // 身份键：有 courseID 用它；没有则退回课名（老数据 / 未迁移）
            var byID: [String: Course] = [:]
            for c in list {
                let k = c.courseID.isEmpty ? "#name:" + c.name : c.courseID
                if byID[k] == nil { byID[k] = c }
            }
            let unique = Array(byID.values)
            guard unique.count > 1 else { continue }
            var involved: [Course] = []
            for i in 0..<unique.count {
                for j in (i + 1)..<unique.count where weeksOverlap(unique[i].weeks, unique[j].weeks) {
                    if !involved.contains(unique[i]) { involved.append(unique[i]) }
                    if !involved.contains(unique[j]) { involved.append(unique[j]) }
                }
            }
            guard involved.count > 1 else { continue }
            let info = slotInfo[key] ?? (1, 0)
            out.append(Conflict(day: info.0, block: info.1,
                               courses: involved.sorted { $0.name < $1.name }))
        }
        return out.sorted { ($0.day, $0.block) < ($1.day, $1.block) }
    }

    /// 同一门课同一格的重复记录。
    static func duplicates(_ courses: [Course]) -> [Duplicate] {
        var seen: [String: Course] = [:]
        var out: [Duplicate] = []
        for c in courses where !c.courseID.isEmpty {
            let key = "\(c.courseID)-\(c.day)-\(c.block)"
            if seen[key] != nil {
                out.append(Duplicate(courseID: c.courseID, day: c.day, block: c.block, name: c.name))
            } else {
                seen[key] = c
            }
        }
        return out
    }

    /// `course` 与 `others` 中任意一条是否冲突。
    /// `ignoreCourseID` 用来排除「和自己比」。
    static func conflicts(for course: Course, in others: [Course]) -> [Conflict] {
        detect(others.filter { $0.courseID != course.courseID || course.courseID.isEmpty }
            + [course])
            .filter { c in c.courses.contains { $0.courseID == course.courseID } }
    }
}

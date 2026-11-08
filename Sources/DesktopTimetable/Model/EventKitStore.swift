import Foundation
import EventKit

/// 「日历 / 提醒事项」的接入层。
///
/// 存在的理由和项目里其他「系统 API 封装」一样：
/// **自动化模式（自检 / 测试）绝对不能碰用户的真实日历和提醒事项**。
/// 所以这里把 EventKit 包在一个协议后面，单测注入 fake。
///
/// 实测结论（2026-11-01，这台机器）：
///   · ad-hoc 签名的 app **能**拿到提醒事项的完全访问权限；
///   · 能读到 iCloud 同步的提醒事项清单（和清单里的条目）；
///   · 能写入、能读回。
///   但前提是**用 LaunchServices 正常启动**（`open -n`）——
///   从别的进程直接 fork 出来的子进程会被 TCC 归因到父进程，
///   拿不到授权（实测日志：`responsible={com.deepseek.dsh}`）。
///   这也是为什么真实 app 必须由用户（或 LaunchServices）启动。
protocol EventKitStoreProtocol: AnyObject {
    /// 提醒事项的授权状态。
    var reminderAuthorization: EKAuthorizationStatus { get }
    /// 日历的授权状态。
    var eventAuthorization: EKAuthorizationStatus { get }
    /// 请求提醒事项的完全访问权限。
    func requestReminderAccess(completion: @escaping (Bool) -> Void)
    /// 请求日历的完全访问权限。
    func requestEventAccess(completion: @escaping (Bool) -> Void)
    /// 提醒事项清单（标题 + 标识 + 是否可写）。
    func reminderLists() -> [EventKitListInfo]
    /// 某一天的提醒事项。
    func reminders(on date: Date, completion: @escaping ([DayPanelTodo]) -> Void)
    /// 某一天的日程。
    func events(on date: Date, completion: @escaping ([DayPanelEvent]) -> Void)
    /// 标记一条提醒事项的完成状态。
    func setReminder(_ identifier: String, in calendarIdentifier: String,
                     done: Bool, completion: @escaping (Bool) -> Void)
    /// 修改一条提醒事项的标题和到期时间（完成状态、清单归属都不变）。
    func updateReminder(_ identifier: String, in calendarIdentifier: String,
                        title: String, due: Date,
                        completion: @escaping (Bool) -> Void)
    /// 新建一个提醒事项清单。
    func createReminderList(titled title: String) -> EventKitListInfo?
    /// 新建一条提醒事项。
    ///
    /// completion 的第二个参数是**新条目的 identifier**（失败时是空串）——
    /// 有了它，调用方可以在 EventKit「写后读旧快照」时**先把这条显示出来**，
    /// 等取数追上再无缝换成真实数据（用户反馈「回车后偶尔不立刻出现」）。
    func addReminder(title: String, due: Date, in calendarIdentifier: String,
                     completion: @escaping (Bool, String) -> Void)
    /// 删除一条提醒事项。
    func deleteReminder(_ identifier: String, in calendarIdentifier: String,
                        completion: @escaping (Bool) -> Void)

    // MARK: - 已完成提醒事项（跨清单）

    /// 读取**所有清单**里的已完成提醒事项。
    ///
    /// 实现必须用 EventKit 的 **completionDate 谓词**
    ///（`predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)`），
    /// 不能把全部提醒事项拉回来再在内存里过滤 —— 那会把用户的未完成项也读一遍。
    ///
    /// 排序（完成时间倒序）由调用方做，接口只保证「已完成」。
    func completedReminders(completion: @escaping (Result<[CompletedReminder], Error>) -> Void)

    /// 把一条已完成提醒事项**恢复为未完成**。
    ///
    /// 到期时间保持原样；`completionDate` 必须清掉
    ///（EventKit 在 `isCompleted = false` 时不接受残留的完成时间）。
    func restoreReminder(_ identifier: String, in calendarIdentifier: String,
                         completion: @escaping (Result<Void, Error>) -> Void)

    /// 永久删除一条已完成提醒事项。
    func deleteCompletedReminder(_ identifier: String, in calendarIdentifier: String,
                                 completion: @escaping (Result<Void, Error>) -> Void)

    /// **批量删除所有清单里的已完成项**。
    ///
    /// 必须逐条 `remove(_:commit: false)`，最后统一 `commit()` 一次 ——
    /// 不能每条单独提交（性能和事件风暴都不对）。
    /// 结果要和实际一致：成功 / 失败数量、以及成功后要标记的 id。
    func deleteAllCompletedReminders(
        progress: ((Int, Int) -> Void)?,
        completion: @escaping (CompletedRemindersDeleteResult) -> Void)
}

/// 一个提醒事项 / 日历清单的**描述**（跨层传递用，不带 EventKit 对象）。
struct EventKitListInfo: Equatable {
    /// 清单标题（显示用）。
    var title: String
    /// `EKCalendar.calendarIdentifier`。
    var identifier: String
    /// 是否可写。
    var isWritable: Bool
}

/// 真实的 EventKit 封装。
///
/// 线程模型：EventKit 的取数接口（`fetchReminders`）是**异步**的，
/// 回调不一定在主线程 —— 所以对外的 completion 都切回主线程，
/// 调用方（AppDelegate → 网页 push）可以直接碰 UI。
final class EventKitStore: EventKitStoreProtocol {

    /// 真实的 EventKit 存储。
    ///
    /// ⚠️ `EKEventStore` 在**非 bundle 进程**里创建会抛 OC 异常 ——
    /// 所以这里用 `lazy`，而且自动化模式根本不碰这个类。
    private lazy var store = EKEventStore()

    /// 授权状态（提醒事项）。
    var reminderAuthorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// 授权状态（日历）。
    var eventAuthorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - 授权

    func requestReminderAccess(completion: @escaping (Bool) -> Void) {
        // 系统弹框期间课表不要淡出（用户点「允许」时鼠标必然离开卡片）。
        // 系统**已经授权**时不会再弹框，这里多记一笔也无害：回调立刻把它销掉。
        PermissionPromptWatch.begin("提醒事项")
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                PermissionPromptWatch.end("提醒事项")
                completion(granted)
            }
        }
    }

    func requestEventAccess(completion: @escaping (Bool) -> Void) {
        PermissionPromptWatch.begin("日历")
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                PermissionPromptWatch.end("日历")
                completion(granted)
            }
        }
    }

    // MARK: - 清单

    func reminderLists() -> [EventKitListInfo] {
        store.calendars(for: .reminder).map {
            EventKitListInfo(title: $0.title,
                             identifier: $0.calendarIdentifier,
                             isWritable: $0.allowsContentModifications)
        }
    }

    /// 新建一个提醒事项清单。
    ///
    /// EventKit 没有「读不到就自动建」的接口 —— 建清单得用
    /// `EKCalendar(for: .reminder, eventStore:)` + `saveCalendar(_:commit:)`，
    /// 而且**新建的清单默认在本地**，不会自动进 iCloud 同步。
    ///
    /// - Returns: 建成的清单（失败返回 nil）。
    func createReminderList(titled title: String) -> EventKitListInfo? {
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = title
        do {
            try store.saveCalendar(cal, commit: true)
            return EventKitListInfo(title: cal.title,
                                     identifier: cal.calendarIdentifier,
                                     isWritable: cal.allowsContentModifications)
        } catch {
            NSLog("[DesktopTimetable] 新建提醒事项清单失败：%@", error.localizedDescription)
            return nil
        }
    }

    /// 按标识找一个可写的清单。
    private func writableList(_ identifier: String) -> EKCalendar? {
        store.calendars(for: .reminder).first {
            $0.calendarIdentifier == identifier && $0.allowsContentModifications
        }
    }

    // MARK: - 取数

    func reminders(on date: Date, completion: @escaping ([DayPanelTodo]) -> Void) {
        let cal = Self.gregorian
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            completion([])
            return
        }
        let lists = store.calendars(for: .reminder)
        guard !lists.isEmpty else {
            completion([])
            return
        }
        let predicate = store.predicateForReminders(in: lists)
        store.fetchReminders(matching: predicate) { fetched in
            let todos = (fetched ?? []).compactMap { reminder -> DayPanelTodo? in
                guard let due = reminder.dueDateComponents?.date else { return nil }
                guard due >= start && due < end else { return nil }
                return DayPanelTodo(
                    title: reminder.title ?? "",
                    due: Self.timeText(due),
                    done: reminder.isCompleted,
                    dueMinutes: Self.minutesOfDay(due),
                    identifier: reminder.calendarItemIdentifier,
                    calendarIdentifier: reminder.calendar?.calendarIdentifier ?? "")
            }
            // 按到期时间排，没到期的排后面。
            //
            // ⚠️ 必须按**实际的到期时刻**排，不能按显示用的 `due` 字符串 ——
            // 「20:00」和「9:00」按字符串比是「20:00」在前，但按时刻比是 9 点在前。
            // 网页那边也是按同一套规则排的（见 Timetable.js 的 dpTodoSection），
            // 两边必须一致，否则网页传的下标会指到另一条待办上。
            let sorted = todos.sorted { lhs, rhs in
                let l = lhs.dueMinutes ?? Int.max
                let r = rhs.dueMinutes ?? Int.max
                if l != r { return l < r }
                // 同一时刻 → 按标题排，保证顺序稳定（不然每次读回来顺序都可能变）
                return lhs.title < rhs.title
            }
            DispatchQueue.main.async { completion(sorted) }
        }
    }

    func events(on date: Date, completion: @escaping ([DayPanelEvent]) -> Void) {
        let cal = Self.gregorian
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            completion([])
            return
        }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else {
            completion([])
            return
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let fetched = store.events(matching: predicate)
        let list = fetched.map { event in
            DayPanelEvent(
                title: event.title ?? "",
                start: Self.timeText(event.startDate),
                end: Self.timeText(event.endDate),
                identifier: event.eventIdentifier ?? "",
                calendarIdentifier: event.calendar?.calendarIdentifier ?? "")
        }.sorted { $0.start < $1.start }
        DispatchQueue.main.async { completion(list) }
    }

    // MARK: - 写

    func setReminder(_ identifier: String, in calendarIdentifier: String,
                     done: Bool, completion: @escaping (Bool) -> Void) {
        findReminder(identifier, in: calendarIdentifier) { [weak self] target in
            guard let self else { completion(false); return }
            guard let target else {
                // ⚠️ 以前这里是**静默失败**——用户看到的是「点了没用」。
                // 找不到就大声记日志，方便 `log show` 定位。
                DiagLog.info("标记提醒事项失败：找不到 id=\(identifier)（清单=\(calendarIdentifier.isEmpty ? "(空)" : calendarIdentifier)）")
                completion(false)
                return
            }
            target.isCompleted = done
            if done { target.completionDate = Date() } else { target.completionDate = nil }
            do {
                try self.store.save(target, commit: true)
                DiagLog.info("提醒事项保存成功 id=\(identifier) done=\(done)")
            } catch {
                DiagLog.info("标记提醒事项完成失败：\(error.localizedDescription)")
                NSLog("[DesktopTimetable] 标记提醒事项完成失败：%@", error.localizedDescription)
                completion(false)
                return
            }
            // 写回后**稍后再读一遍**确认真的落盘了（只记日志，不改行为）。
            // 用户反馈「点了完成当时没了，换周回来又出现」——需要日志区分
            // 是「压根没写进去」还是「写了但后来读回不一致」。
            self.verifyCompletion(target.calendarItemIdentifier,
                                  calendarIdentifier: target.calendar?.calendarIdentifier
                                      ?? calendarIdentifier,
                                  expected: done)
            completion(true)
        }
    }

    func updateReminder(_ identifier: String, in calendarIdentifier: String,
                        title: String, due: Date,
                        completion: @escaping (Bool) -> Void) {
        findReminder(identifier, in: calendarIdentifier) { [weak self] target in
            guard let self else { completion(false); return }
            guard let target else {
                DiagLog.info("修改提醒事项失败：找不到 id=\(identifier)（清单=\(calendarIdentifier.isEmpty ? "(空)" : calendarIdentifier)）")
                completion(false)
                return
            }
            target.title = title
            // 只改标题 + 到期时间：isCompleted / completionDate / calendar 都不动。
            target.dueDateComponents = Self.gregorian.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            do {
                try self.store.save(target, commit: true)
                DiagLog.info("修改提醒事项成功 id=\(identifier) 标题=«\(title)» 到期=\(Self.timeText(due))")
                self.verifyUpdate(identifier,
                                  calendarIdentifier: target.calendar?.calendarIdentifier
                                      ?? calendarIdentifier,
                                  title: title, due: due)
                completion(true)
            } catch {
                DiagLog.info("修改提醒事项失败：\(error.localizedDescription)")
                NSLog("[DesktopTimetable] 修改提醒事项失败：%@", error.localizedDescription)
                completion(false)
            }
        }
    }

    func addReminder(title: String, due: Date, in calendarIdentifier: String,
                     completion: @escaping (Bool, String) -> Void) {
        guard let list = writableList(calendarIdentifier) else {
            completion(false, "")
            return
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        reminder.dueDateComponents = Self.gregorian.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due)
        do {
            try store.save(reminder, commit: true)
            let identifier = reminder.calendarItemIdentifier
            DiagLog.info("新建提醒事项成功 «\(title)» id=\(identifier)")
            completion(true, identifier)
        } catch {
            DiagLog.info("新建提醒事项失败：\(error.localizedDescription)")
            NSLog("[DesktopTimetable] 新建提醒事项失败：%@", error.localizedDescription)
            completion(false, "")
        }
    }

    func deleteReminder(_ identifier: String, in calendarIdentifier: String,
                        completion: @escaping (Bool) -> Void) {
        findReminder(identifier, in: calendarIdentifier) { [weak self] target in
            guard let self else { completion(false); return }
            guard let target else {
                NSLog("[DesktopTimetable] 删除提醒事项失败：找不到 id=%@", identifier)
                completion(false)
                return
            }
            do {
                try self.store.remove(target, commit: true)
                completion(true)
            } catch {
                NSLog("[DesktopTimetable] 删除提醒事项失败：%@", error.localizedDescription)
                completion(false)
            }
        }
    }

    // MARK: - 已完成提醒事项（跨清单）

    /// 读取所有清单里的已完成项。
    ///
    /// ⚠️ 用 **completionDate 谓词**（`predicateForCompletedReminders`）——
    /// 不把全部提醒事项拉回来再过滤，那会把用户的未完成项也读一遍。
    func completedReminders(completion: @escaping (Result<[CompletedReminder], Error>) -> Void) {
        guard reminderAuthorization == .fullAccess else {
            completion(.failure(CompletedRemindersError.notAuthorized))
            return
        }
        let lists = store.calendars(for: .reminder)
        guard !lists.isEmpty else {
            DispatchQueue.main.async { completion(.success([])) }
            return
        }
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: nil, ending: nil, calendars: lists)
        store.fetchReminders(matching: predicate) { fetched in
            let items = (fetched ?? []).filter { $0.isCompleted }.map { reminder in
                CompletedReminder(
                    identifier: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "",
                    listIdentifier: reminder.calendar?.calendarIdentifier ?? "",
                    listTitle: reminder.calendar?.title ?? "",
                    completionDate: reminder.completionDate,
                    // 到期时间可能为空（提醒事项允许「无到期时间」）。
                    dueDate: reminder.dueDateComponents?.date,
                    // `recurrenceRules` 是 `EKCalendarItem` 上的数组，空数组 = 不重复。
                    isRecurring: reminder.recurrenceRules?.isEmpty == false)
            }
            DispatchQueue.main.async { completion(.success(items)) }
        }
    }

    /// 恢复一条已完成项为未完成：到期时间保持原样，完成时间清空。
    func restoreReminder(_ identifier: String, in calendarIdentifier: String,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard reminderAuthorization == .fullAccess else {
            completion(.failure(CompletedRemindersError.notAuthorized))
            return
        }
        findReminder(identifier, in: calendarIdentifier) { [weak self] target in
            guard let self else { return }
            guard let target else {
                DiagLog.info("恢复已完成提醒事项失败：找不到 id=\(identifier)")
                completion(.failure(CompletedRemindersError.reminderNotFound))
                return
            }
            target.isCompleted = false
            // ⚠️ EventKit 在未完成状态不接受残留的 completionDate。
            target.completionDate = nil
            // 到期时间（`dueDateComponents`）**一个字都不动**。
            do {
                try self.store.save(target, commit: true)
                DiagLog.info("恢复已完成提醒事项成功 id=\(identifier)")
                self.verifyCompletion(target.calendarItemIdentifier,
                                      calendarIdentifier: target.calendar?.calendarIdentifier
                                          ?? calendarIdentifier,
                                      expected: false)
                completion(.success(()))
            } catch {
                DiagLog.info("恢复已完成提醒事项失败：\(error.localizedDescription)")
                completion(.failure(CompletedRemindersError.underlying(error.localizedDescription)))
            }
        }
    }

    /// 永久删除一条已完成项。
    func deleteCompletedReminder(_ identifier: String, in calendarIdentifier: String,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard reminderAuthorization == .fullAccess else {
            completion(.failure(CompletedRemindersError.notAuthorized))
            return
        }
        findReminder(identifier, in: calendarIdentifier) { [weak self] target in
            guard let self else { return }
            guard let target else {
                DiagLog.info("删除已完成提醒事项失败：找不到 id=\(identifier)")
                completion(.failure(CompletedRemindersError.reminderNotFound))
                return
            }
            do {
                try self.store.remove(target, commit: true)
                DiagLog.info("删除已完成提醒事项成功 id=\(identifier)")
                completion(.success(()))
            } catch {
                DiagLog.info("删除已完成提醒事项失败：\(error.localizedDescription)")
                completion(.failure(CompletedRemindersError.underlying(error.localizedDescription)))
            }
        }
    }

    /// 批量删除所有清单里的已完成项：逐条 `remove(commit: false)`，最后统一 `commit()`。
    ///
    /// ⚠️ **commit 失败等于一条都没删成** —— `remove(commit: false)` 的改动
    /// 不会落盘。这时候结果必须报 `deleted: 0`，不能拿「remove 没抛错」当成功。
    func deleteAllCompletedReminders(
        progress: ((Int, Int) -> Void)?,
        completion: @escaping (CompletedRemindersDeleteResult) -> Void) {
        guard reminderAuthorization == .fullAccess else {
            completion(.failure(CompletedRemindersError.notAuthorized))
            return
        }
        let lists = store.calendars(for: .reminder)
        guard !lists.isEmpty else {
            DispatchQueue.main.async {
                completion(CompletedRemindersDeleteResult(deleted: 0, failed: 0,
                                                          deletedIdentifiers: [],
                                                          failedIdentifiers: [],
                                                          message: nil))
            }
            return
        }
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: nil, ending: nil, calendars: lists)
        store.fetchReminders(matching: predicate) { [weak self] fetched in
            guard let self else { return }
            let targets = (fetched ?? []).filter { $0.isCompleted }
            guard !targets.isEmpty else {
                DispatchQueue.main.async {
                    completion(CompletedRemindersDeleteResult(deleted: 0, failed: 0,
                                                              deletedIdentifiers: [],
                                                              failedIdentifiers: [],
                                                              message: nil))
                }
                return
            }

            var deletedIdentifiers: [String] = []
            var failedIdentifiers: [String] = []
            var lastError: String?
            for (index, reminder) in targets.enumerated() {
                let identifier = reminder.calendarItemIdentifier
                do {
                    try self.store.remove(reminder, commit: false)
                    deletedIdentifiers.append(identifier)
                } catch {
                    failedIdentifiers.append(identifier)
                    lastError = error.localizedDescription
                    DiagLog.info("批量删除已完成项失败 id=\(identifier)：\(error.localizedDescription)")
                }
                // 进度切回主线程（UI 要更新；回调本身可能在任意队列）。
                if let progress {
                    DispatchQueue.main.async {
                        progress(index + 1, targets.count)
                    }
                }
            }

            // 一条都没 remove 成功 → 没有可提交的，直接如实返回失败。
            guard !deletedIdentifiers.isEmpty else {
                let result = CompletedRemindersDeleteResult(
                    deleted: 0, failed: failedIdentifiers.count,
                    deletedIdentifiers: [], failedIdentifiers: failedIdentifiers,
                    message: lastError)
                DispatchQueue.main.async { completion(result) }
                return
            }

            do {
                try self.store.commit()
                DiagLog.info("批量删除已完成项成功 \(deletedIdentifiers.count) 条，失败 \(failedIdentifiers.count) 条")
                let result = CompletedRemindersDeleteResult(
                    deleted: deletedIdentifiers.count,
                    failed: failedIdentifiers.count,
                    deletedIdentifiers: deletedIdentifiers,
                    failedIdentifiers: failedIdentifiers,
                    message: failedIdentifiers.isEmpty ? nil : (lastError ?? "部分条目删除失败"))
                DispatchQueue.main.async { completion(result) }
            } catch {
                // commit 失败：前面 remove(commit:false) 的改动不会落盘。
                // ⚠️ 必须 `reset()` 丢掉这些**挂起**的删除 —— 否则下一次
                // 任何 save/commit 都可能把它们一起提交（静默删掉用户数据）。
                self.store.reset()
                DiagLog.info("批量删除已完成项提交失败：\(error.localizedDescription)")
                let result = CompletedRemindersDeleteResult(
                    deleted: 0,
                    failed: targets.count,
                    deletedIdentifiers: [],
                    failedIdentifiers: targets.map { $0.calendarItemIdentifier },
                    message: "提交更改失败：\(error.localizedDescription)")
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// 按 id 找到那条提醒事项（**异步**）。
    ///
    /// EventKit **没有**公开的「按 id 直接取」接口，
    /// 只能列出全部再匹配 —— 提醒事项数量不大（实测几十条），够用。
    ///
    /// ⚠️ **绝对不能在主线程用信号量等 `fetchReminders` 的回调**（2026-11 修）。
    ///
    /// Apple 没有承诺这个回调跑在哪个队列上 —— 如果它被投递到主队列，
    /// 主线程一堵（`sem.wait`），回调就永远来不了，只能等 5 秒超时。
    /// 超时后「找不到提醒事项」→ 完成操作**静默失败** →
    /// 网页只是乐观地把条目藏起来 → 等重新取数（换周回来）就又冒出来
    /// （用户反馈「点完消失了，换周回来又有了」）。
    ///
    /// 现在整条链路纯异步，回调统一切回主线程再交给调用方。
    private func findReminder(_ identifier: String,
                              in calendarIdentifier: String,
                              completion: @escaping (EKReminder?) -> Void) {
        let lists = store.calendars(for: .reminder)
        guard !lists.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let predicate = store.predicateForReminders(in: lists)
        store.fetchReminders(matching: predicate) { reminders in
            let found = (reminders ?? []).first { reminder in
                guard reminder.calendarItemIdentifier == identifier else { return false }
                // 清单标识为空（老数据 / 读不到清单）时只按 id 匹配 ——
                // 否则会因为一个空串**永远匹配不到**。
                if calendarIdentifier.isEmpty { return true }
                return reminder.calendar?.calendarIdentifier == calendarIdentifier
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// 修改写回后过一会儿再读一遍，确认标题 / 到期时间真的落盘了。
    ///
    /// 只记日志，不影响调用方 —— 和 `verifyCompletion` 一样是给
    /// 「写后读旧快照」问题留证据用的。
    private func verifyUpdate(_ identifier: String,
                              calendarIdentifier: String,
                              title: String,
                              due: Date) {
        let expectedTime = Self.timeText(due)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.findReminder(identifier, in: calendarIdentifier) { reminder in
                guard let reminder else {
                    DiagLog.info("⚠️ 修改校验：写回后找不到 id=\(identifier)")
                    return
                }
                let actualTitle = reminder.title ?? ""
                let actualTime = reminder.dueDateComponents?.date.map(Self.timeText) ?? ""
                if actualTitle != title || actualTime != expectedTime {
                    DiagLog.info("⚠️ 修改校验：id=\(identifier) 期望 «\(title)» \(expectedTime) 实际 «\(actualTitle)» \(actualTime)")
                } else {
                    DiagLog.info("修改校验通过 id=\(identifier) «\(title)» \(expectedTime)")
                }
            }
        }
    }

    /// 写回后过一会儿再读一遍，确认完成状态**真的落盘了**。
    ///
    /// 只记日志，不影响调用方的结果 —— 这是给「点完消失、换周又出现」
    /// 这类问题留证据用的（`log show --predicate 'process == "DesktopTimetable"'`）。
    private func verifyCompletion(_ identifier: String,
                                  calendarIdentifier: String,
                                  expected: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.findReminder(identifier, in: calendarIdentifier) { reminder in
                guard let reminder else {
                    DiagLog.info("⚠️ 完成状态校验：写回后找不到 id=\(identifier)")
                    return
                }
                if reminder.isCompleted != expected {
                    DiagLog.info("⚠️ 完成状态校验：id=\(identifier) 期望 done=\(expected) 实际 done=\(reminder.isCompleted)")
                } else {
                    DiagLog.info("完成状态校验通过 id=\(identifier) done=\(expected)")
                }
            }
        }
    }

    // MARK: - 工具

    /// 统一用公历 + 当前时区 —— 提醒事项的到期时间就是当地时间。
    static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    /// `Date` → 当天零点的分钟数（0...1439）。
    static func minutesOfDay(_ date: Date) -> Int {
        let comps = gregorian.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// `Date` → `HH:mm`。
    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

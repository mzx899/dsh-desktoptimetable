import AppKit
import Foundation
import UserNotifications

/// 系统通知中心的**抽象**（协议注入）。
///
/// 存在的唯一理由：**测试绝不能碰真实系统 API**。
/// 单测注入 `FakeNotificationCenter`，线上注入真实的 `UNUserNotificationCenter`。
protocol UserNotificationCenterProtocol: AnyObject {
    /// 请求授权。
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping (Bool, Error?) -> Void)
    /// 当前授权状态。
    ///
    /// 故意只暴露 `UNAuthorizationStatus` 而不是 `UNNotificationSettings` ——
    /// `UNNotificationSettings` 没有公开初始化方法，测试里造不出来，
    /// 那样就只能拿真实系统对象来测，测试也就不能隔离了。
    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void)
    /// 加一条待发通知（同 id 覆盖）。
    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?)
    /// 取本应用已排的待发通知。
    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void)
    /// 删掉指定 id 的待发通知。
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

/// 真实系统通知中心的适配层（把 UNUserNotificationCenter 套进协议里）。
final class SystemNotificationCenter: UserNotificationCenterProtocol {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping (Bool, Error?) -> Void) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?) {
        center.add(request, withCompletionHandler: withCompletionHandler)
    }

    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void) {
        center.getPendingNotificationRequests(completionHandler: completionHandler)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// 上课提醒的**系统调度器**。
///
/// 职责：
///   · 首次打开提醒开关时请求 `.alert + .sound` 授权；
///   · 把 `ClassReminderPlanner` 算出来的计划交给系统排程；
///   · 重排时**先加后删**（不先 `removeAllPending`，避免中间空窗）；
///   · 关闭提醒 / 删除课表 / 空课表 → 清空本应用的待发通知；
///   · 启动时清理遗留的 `dt.test.*` 测试通知。
///
/// 系统调度的不重复触发（repeats: false）与时区处理都在 `ClassReminderPlanner` 里定好，
/// 这里只负责搬运。
final class ClassReminderScheduler {

    /// 通知 id 前缀（本应用自己的通知都在这个前缀下）。
    static let idPrefix = ClassReminderPlanner.idPrefix

    /// 注入的通知中心（测试用 fake；线上传 nil）。
    private let injectedCenter: UserNotificationCenterProtocol?
    /// 真实通知中心**懒创建**。
    ///
    /// `UNUserNotificationCenter.current()` 在没有 app bundle 的进程里
    /// （命令行自检 / 测试运行器）会直接抛 Objective-C 异常把进程干掉。
    /// 所以只有真的要用的时候才去拿它 —— 自动化模式下永远不会走到这一步。
    private lazy var center: UserNotificationCenterProtocol = injectedCenter ?? SystemNotificationCenter()
    /// 自动化模式（自检 / 导入 / 离屏渲染 / 测试）下**绝不**请求权限、绝不发真通知。
    private let isAutomation: Bool

    /// 上次重排用的指纹 —— 指纹没变就跳过（别每 10 秒删了重排）。
    private var lastFingerprint: String?

    init(center: UserNotificationCenterProtocol? = nil,
         isAutomation: Bool = AutomationMode.isCurrentProcessAutomation) {
        self.injectedCenter = center
        self.isAutomation = isAutomation
    }

    /// 自动化模式下不请求权限、不发通知。
    var automationBlocked: Bool { isAutomation }

    // MARK: - 权限

    /// 是否已经拿到通知授权。
    func isAuthorized(_ completion: @escaping (Bool) -> Void) {
        guard !isAutomation else { completion(false); return }
        center.authorizationStatus { status in
            completion(status == .authorized || status == .provisional)
        }
    }

    /// 当前授权状态的文字（给设置面板显示）。
    func authorizationDescription(_ completion: @escaping (String) -> Void) {
        authorizationState { _, text in completion(text) }
    }

    /// 授权状态**和**文案（一次回调拿全）。
    ///
    /// 分成两次异步查询（一次问布尔、一次问文案）会出现「状态已经变了、
    /// 文案还是旧的」的中间态 —— 面板上会闪一下。这里一次问完。
    func authorizationState(_ completion: @escaping (Bool, String) -> Void) {
        guard !isAutomation else {
            completion(false, "自动化模式下不请求通知权限")
            return
        }
        center.authorizationStatus { status in
            let authorized = (status == .authorized || status == .provisional)
            let text: String
            switch status {
            case .authorized: text = "已允许通知"
            case .provisional: text = "已允许通知（安静模式）"
            case .denied: text = "系统通知未授权"
            case .notDetermined: text = "尚未请求通知权限"
            case .ephemeral: text = "已允许通知（临时）"
            @unknown default: text = "通知授权状态未知"
            }
            completion(authorized, text)
        }
    }

    /// 请求授权（`.alert + .sound`）。
    ///
    /// 请求权限前先激活 app —— 否则系统弹窗会出现在后台，用户根本没看见。
    /// 弹窗期间还要「钉住」课表（`PermissionPromptWatch`）：用户点「允许」时
    /// 鼠标会离开卡片，不钉的话课表会淡到 `minOpacity`（用户设 0 = 整个消失）。
    func requestAuthorization(_ completion: @escaping (Bool, Error?) -> Void) {
        guard !isAutomation else { completion(false, nil); return }
        NSApp.activate(ignoringOtherApps: true)
        PermissionPromptWatch.begin("通知")
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async { PermissionPromptWatch.end("通知") }
            completion(granted, error)
        }
    }

    /// 只在「系统还没问过」的时候请求授权。
    ///
    /// 已拒绝时**不要反复弹系统框** —— 那是骚扰，而且用户已经表过态了。
    /// 设置面板会显示「系统通知未授权」并给一个「去设置」的入口。
    func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard !isAutomation else { completion(false); return }
        center.authorizationStatus { [weak self] status in
            guard let self else { completion(false); return }
            switch status {
            case .notDetermined:
                self.requestAuthorization { granted, _ in completion(granted) }
            case .authorized, .provisional, .ephemeral:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// 打开系统的通知设置页。
    func openSystemNotificationSettings() {
        guard !isAutomation else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 排程

    /// 重新排程：把 `plans` 排进系统，并删掉不再需要的旧通知。
    ///
    /// 顺序很重要：**先 add（同 id 覆盖），再删多余的**。
    /// 先 `removeAllPending` 会出现一个「一条通知都没有」的窗口期，
    /// 用户可能要等下一轮才收到提醒。
    ///
    /// - Parameters:
    ///   - plans: 要排的通知。
    ///   - fingerprint: 本次的指纹（课表 id + 课程 + 覆盖 + 学期 + 开关 + 提前分钟 + 日期）。
    ///   - completion: 排完的回调（参数：成功排了多少条）。
    func reschedule(plans: [ReminderPlan],
                    fingerprint: String,
                    completion: ((Int) -> Void)? = nil) {
        guard !isAutomation else { completion?(0); return }

        // 指纹没变 → 不重排（避免每次 refreshCard 都删了重排）。
        if let last = lastFingerprint, last == fingerprint {
            completion?(plans.count)
            return
        }

        let targetIDs = Set(plans.map { $0.id })
        for plan in plans {
            add(plan)
        }
        // 删掉本应用前缀下、但这次不需要的待发通知。
        center.getPendingNotificationRequests { [center] requests in
            let stale = requests
                .map { $0.identifier }
                .filter { id in
                    id.hasPrefix(Self.idPrefix) && !targetIDs.contains(id)
                }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            self.lastFingerprint = fingerprint
            completion?(plans.count)
        }
    }

    /// 排一条通知（同 id 会覆盖旧的）。
    private func add(_ plan: ReminderPlan) {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.sound = .default
        // 触发器用「墙上时间 + Asia/Shanghai」，不重复。
        let components = ClassReminderPlanner.dateComponents(for: plan.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: plan.id, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }

    /// 清空本应用的待发通知（关闭提醒 / 删除课表 / 空课表）。
    func clearAll(completion: (() -> Void)? = nil) {
        guard !isAutomation else { completion?(); return }
        lastFingerprint = nil
        center.getPendingNotificationRequests { [center] requests in
            let ids = requests
                .map { $0.identifier }
                .filter { $0.hasPrefix(Self.idPrefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
            completion?()
        }
    }

    /// 清理遗留的测试通知（`dt.test.*`）。
    ///
    /// 启动时调一次：上次点「发送测试提醒」后 app 被杀掉，
    /// 那条 5 秒后的通知还挂在系统里，会莫名其妙弹出来。
    func cleanupTestNotifications(completion: (() -> Void)? = nil) {
        guard !isAutomation else { completion?(); return }
        center.getPendingNotificationRequests { [center] requests in
            let ids = requests
                .map { $0.identifier }
                .filter { $0.hasPrefix(ClassReminderPlanner.testIDPrefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
            completion?()
        }
    }

    /// 发一条测试提醒（5 秒后响）。
    ///
    /// 不进正式规划，不影响课表。
    func sendTestReminder(completion: ((Error?) -> Void)? = nil) {
        guard !isAutomation else { completion?(nil); return }
        center.authorizationStatus { [center] status in
            guard status == .authorized || status == .provisional else {
                completion?(NSError(domain: "DesktopTimetable.reminder", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "系统通知未授权"]))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "测试提醒"
            content.body = "这是一条测试提醒，不影响真实课表。"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let id = "\(ClassReminderPlanner.testIDPrefix)\(Int(Date().timeIntervalSince1970))"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: completion)
        }
    }

    /// 本应用当前已排的通知 id（手工验收 / 排障用）。
    func pendingIDs(_ completion: @escaping ([String]) -> Void) {
        guard !isAutomation else { completion([]); return }
        center.getPendingNotificationRequests { requests in
            completion(requests.map { $0.identifier }
                .filter { $0.hasPrefix(Self.idPrefix) || $0.hasPrefix(ClassReminderPlanner.testIDPrefix) }
                .sorted())
        }
    }

    /// 计划的指纹（课表 id + 课程 + 覆盖 + 学期 + 开关 + 提前分钟 + 日期）。
    ///
    /// 指纹没变 = 数据没变 = 不需要重排。
    static func fingerprint(timetableID: String,
                            courses: [Course],
                            overrides: [WeekOverride],
                            semesterStart: Date,
                            maxWeek: Int,
                            enabled: Bool,
                            leadMinutes: Int,
                            now: Date) -> String {
        let cal = WeekMath.calendar
        let day = cal.startOfDay(for: now)
        // 指纹必须覆盖**通知正文里出现的每一个字段**。
        // 正文 = 课名 · 时间 · 地点（没地点才用教师）—— 见 `ClassReminderPlanner.bodyText`。
        // 以前只签了 courseID/day/block/weeks/name：**只改地点或教师时指纹不变**，
        // 重排被跳过 → 已经排好的通知正文还是旧地点。
        let courseSig = courses
            .map { "\($0.courseID)|\($0.day)|\($0.block)|\($0.weeks.sorted().map(String.init).joined(separator: ","))|\($0.name)|\($0.loc)|\($0.teacher)" }
            .joined(separator: ";")
        // 覆盖课同理：它的 name / loc / teacher 也会进正文。
        let overrideSig = overrides
            .map { "\($0.courseID)|\($0.day)|\($0.block)|\($0.weeks.sorted().map(String.init).joined(separator: ","))|\($0.name)|\($0.loc)|\($0.teacher)" }
            .joined(separator: ";")
        let startDay = cal.startOfDay(for: semesterStart)
        return "\(timetableID)|\(courseSig)|\(overrideSig)|\(startDay.timeIntervalSince1970)|\(maxWeek)|\(enabled)|\(leadMinutes)|\(day.timeIntervalSince1970)"
    }
}

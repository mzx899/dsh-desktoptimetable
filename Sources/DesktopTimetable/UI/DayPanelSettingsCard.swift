import AppKit
import CoreLocation

/// 「日期覆盖层」接入系统日历 / 提醒事项的**授权状态**。
///
/// 为什么要自己定义一套（而不是直接用 `EKAuthorizationStatus`）：
///   · 系统的 `EKAuthorizationStatus` 只有「日历」和「提醒事项」两套，
///     而这里要表达的是**两者合起来**在设置面板上的呈现；
///   · 系统的状态是异步查的，中间还有「还没查到」这一态，
///     直接映射到 `EKAuthorizationStatus` 会**没有位置放**「未知」；
///   · 单元测试可以自己造出每一种状态，不需要真的去问系统要权限。
///
/// 状态一律**以系统为准**，不往设置文件里存 bool ——
/// 用户可以在「系统设置 → 隐私与安全性」里随时改授权，
/// 存下来的 bool 迟早和系统不一致。
enum DayPanelAuthState: Equatable {
    /// 已开启接入，且已获得日历 / 提醒事项授权（一切正常）。
    case authorized
    /// 已开启接入，但**没有**授权 —— 覆盖层只显示当天课程。
    ///
    /// 这一态必须单独存在：把「没授权」当成「没开启」的话，
    /// 用户会以为是自己没打开开关，其实差的是系统授权，
    /// 提示会完全指错方向。
    case notAuthorized
    /// 未开启接入（用户关掉了开关，或默认值就是关）。
    case disabled
    /// 状态**还没读到**（查询在路上 / 出错了）。
    ///
    /// 这一态**不能闪**：面板刚打开时状态是未知的，
    /// 如果按「未授权」渲染，开关会先变成灰的再变亮 —— 闪一下。
    /// 所以未知时界面**保持上一次的样子**，不做任何预判。
    case unknown

    /// 界面上显示的一行状态说明（**纯函数**，方便单测）。
    ///
    /// - Returns: `(状态文案, 详细说明)`。
    static func describe(_ state: DayPanelAuthState) -> (text: String, detail: String) {
        switch state {
        case .authorized:
            return ("已接入",
                    "覆盖层会显示当天的课程、提醒事项和日历日程")
        case .notAuthorized:
            return ("未授权",
                    "还没有获得系统权限，覆盖层目前只显示当天的课程。"
                    + "请在「系统设置 → 隐私与安全性」里允许桌面课表访问日历和提醒事项")
        case .disabled:
            return ("未开启",
                    "开启后，点课表表头的日期会弹出当天的课程、提醒事项和日历日程")
        case .unknown:
            return ("正在检查…", "正在读取系统授权状态")
        }
    }

    /// 是不是**已经接上了系统数据**（只有 `.authorized` 算接上了）。
    var isFullyAuthorized: Bool { self == .authorized }

    /// 「去系统设置授权」按钮该不该显示。
    ///
    /// 只在「开了开关但没授权」时显示：这一态是用户**唯一能自己解决**的
    /// （去系统设置点一下允许），给个入口；其他态给按钮都没意义。
    static func showsAuthorizationButton(_ state: DayPanelAuthState) -> Bool {
        state == .notAuthorized
    }

    /// 状态行该用什么颜色（**纯函数**）。
    ///
    /// · 未授权 → 琥珀色（要用户去处理，但还不是错误）；
    /// · 未知 → 灰（不该预判）；
    /// · 其余 → 常规灰白。
    static func statusColor(_ state: DayPanelAuthState) -> NSColor {
        switch state {
        case .notAuthorized:
            return NSColor(srgbRed: 0.95, green: 0.72, blue: 0.30, alpha: 0.95)
        case .authorized, .disabled, .unknown:
            return NSColor.white.withAlphaComponent(0.42)
        }
    }
}

/// 「日期覆盖层」设置卡片。
///
/// 这是一个**纯 UI 组件**：自己不读磁盘、不问系统、不写任何设置。
/// 所有状态都由主控（`SettingsWindowController`）通过 `update(...)` 灌进来，
/// 所有用户操作都以闭包回调出去 —— 这样接线的人和做界面的人可以并行干活。
///
/// 版式沿用 `SettingsCard`：卡片 → 行 → 行内「标题 + 副标题 + 右侧控件」。
/// 四行分别是：
///   1. **日历与提醒事项接入** —— 一个开关 + 状态行 + 「去授权」按钮；
///   2. **提醒事项清单** —— 显示当前清单名，点一下弹出清单选择；
///   3. **已完成的提醒事项** —— 默认收起，点开在卡片内展开列表；
///   4. **显示天气** —— 天气开关 + 定位授权状态。
///
/// 用法：
/// ```swift
/// let card = DayPanelSettingsCard()
/// card.onToggleEnabled = { enabled in ... }
/// card.onSelectList = { ... }
/// card.onCreateList = { name in ... }
/// card.update(enabled: true, authState: .notAuthorized, listName: "桌面课表",
///             completedAccess: .needsAuthorization)
/// ```
final class DayPanelSettingsCard: NSView {

    // MARK: - 公开回调

    /// 用户拨动了「日历与提醒事项接入」开关。
    ///
    /// 参数是**拨动之后**的目标值（不是当前值）。
    var onToggleEnabled: ((Bool) -> Void)?

    /// 用户点了「提醒事项清单」这一行 → 应该弹出清单选择器。
    ///
    /// 弹窗由主控负责（要读 EventKit 的真实清单列表，本组件拿不到），
    /// 选中之后主控再调 `update(...)` 把新清单名灌回来。
    var onSelectList: (() -> Void)?

    /// 用户在清单选择器里点了「新建清单」，参数是新清单的名字。
    var onCreateList: ((String) -> Void)?

    /// 用户点了「去系统设置授权」。
    ///
    /// 单开一个回调而不是复用 `onToggleEnabled` ——
    /// 主控要做的不是改设置，而是把「系统设置」面板打开
    /// （`x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars`），
    /// 顺便**重新查一次**授权状态。
    var onOpenAuthorization: (() -> Void)?

    // MARK: - 子视图

    /// 开关行（第一行）。
    private let enableRow = DayPanelToggleRow()
    /// 清单行（第二行）。
    private let listRow = DayPanelListRow()
    /// 已完成提醒事项行（第三行，默认收起）。
    let completedRowView = CompletedRemindersRow()
    /// 卡片标题。
    static let cardTitle = "日期覆盖层"

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // 卡片本体就是一张 `SettingsCard` —— 直接复用它的底色、圆角、边框和行距，
        // 不自己重造一套（重造就会出现「这张卡片跟别的卡片不是一家的」）。
        let card = SettingsCard(title: Self.cardTitle)
        card.translatesAutoresizingMaskIntoConstraints = false

        enableRow.onToggle = { [weak self] isOn in
            self?.onToggleEnabled?(isOn)
        }
        enableRow.onOpenSystemSettings = { [weak self] in
            self?.onOpenAuthorization?()
        }

        listRow.onTap = { [weak self] in
            self?.onSelectList?()
        }

        card.addRow(enableRow)
        card.addRow(listRow)
        // 顺序：接入 → 清单 → 已完成的提醒事项。
        // ⚠️ 天气**不在这张卡里**了（2026-11-10 用户要求单独一个板块），
        // 见 `WeatherSettingsCard`。
        card.addRow(completedRowView)

        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 灌入当前状态。
    ///
    /// - Parameters:
    ///   - enabled：「日历与提醒事项接入」开关当前是开是关。
    ///   - authState：授权状态。
    ///   - listName：当前选中的提醒事项清单名（为空串时显示默认名）。
    ///   - weatherEnabled：要不要显示天气。
    ///   - locationAuthStatus：定位授权状态（`nil` = 还没问过）。
    func update(enabled: Bool,
                authState: DayPanelAuthState,
                listName: String,
                completedAccess: CompletedRemindersRow.Access = .disabled) {
        enableRow.update(enabled: enabled, authState: authState)
        listRow.update(listName: listName)
        completedRowView.updateAccess(completedAccess)
    }

    /// 开关当前是开是关（自检用）。
    var isEnabled: Bool { enableRow.isOn }

    /// 当前显示的清单名（自检用）。
    var displayedListName: String { listRow.displayedListName }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

import AppKit
import CoreLocation

/// 「天气」设置行（日期覆盖层卡片里的第三行）。
///
/// ## 用户选的方案是 B：系统定位（CoreLocation）
///
/// 所以这一行**不是**一个「填城市名」的输入框 —— 城市由系统定位决定。
/// 这一行做的是：
///   · 一个开关：要不要显示天气；
///   · 一个状态说明：定位授权是什么状态；
///   · 一个「去系统设置授权」按钮（没授权时才出现）。
///
/// ## 为什么不给「手填城市」的输入框
///
/// 用户明确选了系统定位。手填城市作为**降级**方案也留了口子
/// （`DayPanelSettings.weatherCity`），但那是给「用户不想开定位权限」时用的，
/// 本轮先不暴露在界面上 —— 等用户提出「我不授权定位」时再接上。
///
/// ## 隐私
///
/// 位置只发给 Open-Meteo 查天气；**不做 IP 推断**，不把 IP 发给任何第三方。
final class DayPanelWeatherRow: NSView {

    // MARK: - 公开回调

    /// 用户拨动了「显示天气」开关（参数 = 拨动之后的目标值）。
    var onToggleWeather: ((Bool) -> Void)?

    /// 用户点了「去系统设置授权」。
    var onOpenLocationSettings: (() -> Void)?

    // MARK: - 子视图

    private let toggle = NSSwitch()
    private let titleLabel = NSTextField(labelWithString: "显示天气")
    private let statusLabel = NSTextField(labelWithString: "")
    private let authorizeButton = NSButton(title: "去授权", target: nil, action: nil)

    /// 开关当前是开是关。
    var isOn: Bool { toggle.state == .on }

    /// 当前显示的状态说明（自检用）。
    var displayedStatus: String { statusLabel.stringValue }

    /// 「去授权」按钮现在该显示吗（自检用）。
    var showsAuthorizeButton: Bool { !authorizeButton.isHidden }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        authorizeButton.target = self
        authorizeButton.action = #selector(openSettings)
        authorizeButton.bezelStyle = .rounded
        authorizeButton.controlSize = .small
        authorizeButton.font = .systemFont(ofSize: 11)
        authorizeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(authorizeButton)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: authorizeButton.leadingAnchor, constant: -8),
            // ⚠️ 必须把底边钉住，否则这一行没有「高度定义」——
            // 作为卡片最后一行时会被压成 0pt，状态文字和开关画到卡片外面
            //（2026-11-05 加「已完成的提醒事项」时暴露：天气行被裁掉一半）。
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            authorizeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            authorizeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -2),
        ])
    }

    /// 灌入当前状态。
    ///
    /// - Parameters:
    ///   - enabled：要不要显示天气。
    ///   - authStatus：定位授权状态（`nil` = 还没问过）。
    func update(enabled: Bool, authStatus: CLAuthorizationStatus?) {
        toggle.state = enabled ? .on : .off
        let (text, needsButton) = Self.describe(enabled: enabled, authStatus: authStatus)
        statusLabel.stringValue = text
        authorizeButton.isHidden = !needsButton
    }

    /// 状态文案（**纯函数**，方便单测）。
    static func describe(enabled: Bool, authStatus: CLAuthorizationStatus?) -> (text: String, needsButton: Bool) {
        guard enabled else {
            return ("关闭时不显示天气。", false)
        }
        switch authStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return ("按你的位置显示当天的天气（只用于查询天气）。", false)
        case .denied:
            return ("系统没有授予定位权限，封面层不会显示天气。", true)
        case .restricted:
            return ("系统限制了定位，封面层不会显示天气。", true)
        case .notDetermined:
            return ("需要一次定位授权才能显示天气。", true)
        case nil:
            return ("正在检查定位权限…", false)
        @unknown default:
            return ("定位权限状态未知。", false)
        }
    }

    @objc private func toggled() {
        onToggleWeather?(toggle.state == .on)
    }

    @objc private func openSettings() {
        onOpenLocationSettings?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

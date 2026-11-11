import AppKit
import CoreLocation

/// 设置 →「提醒」里的**天气卡片**（2026-11-10 拆出来的独立板块）。
///
/// 用户原话：「在设置里面也把天气和提醒待办事项分开，做成下面独立一个天气板块」。
///
/// 以前「显示天气 / 地区」这两行塞在「日期覆盖层」卡片里（接入、清单、已完成的提醒事项
/// 后面），既挤又不好找。现在单独一张「天气」卡片，放在日期覆盖层卡片下面：
/// ```
/// 天气
///   显示天气                      [开关]
///   按「秦皇岛」显示天气（不需要定位权限）。
///   地区              秦皇岛  ›
/// ```
final class WeatherSettingsCard: NSView {

    // MARK: - 公开回调

    /// 用户拨动了「显示天气」开关。
    var onToggleWeather: ((Bool) -> Void)?

    /// 用户点了「地区」那一行（该弹城市选择器）。
    var onPickWeatherCity: (() -> Void)?

    // MARK: - 子视图

    /// 卡片标题（自检 / 文档用）。
    static let cardTitle = "天气"

    private let weatherRow = DayPanelWeatherRow()

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        let card = SettingsCard(title: Self.cardTitle)
        card.translatesAutoresizingMaskIntoConstraints = false

        weatherRow.onToggleWeather = { [weak self] isOn in
            self?.onToggleWeather?(isOn)
        }
        weatherRow.onPickCity = { [weak self] in
            self?.onPickWeatherCity?()
        }
        card.addRow(weatherRow)

        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 灌入当前状态。
    func update(weatherEnabled: Bool,
                locationAuthStatus: CLAuthorizationStatus? = nil,
                weatherCity: String = "") {
        weatherRow.update(enabled: weatherEnabled,
                          authStatus: locationAuthStatus,
                          city: weatherCity)
    }

    /// 天气开关当前是开是关（自检用）。
    var isWeatherEnabled: Bool { weatherRow.isOn }

    /// 天气行当前的状态文案（自检用）。
    var displayedWeatherStatus: String { weatherRow.displayedStatus }

    /// 天气行还有没有「去授权」按钮（2026-11-10 起没有：ad-hoc 签名下定位拿不到）。
    var showsWeatherAuthorizeButton: Bool { false }

    /// 当前地区（自检用）。
    var displayedWeatherCity: String { weatherRow.cityText }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

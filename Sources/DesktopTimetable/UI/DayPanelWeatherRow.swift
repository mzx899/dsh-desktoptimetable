import AppKit
import CoreLocation

/// 「天气」设置行（日期覆盖层卡片里的第四行）。
///
/// 布局（2026-11-10 改）：
/// ```
/// 显示天气                       [开关]
/// 按「秦皇岛」显示天气（不需要定位权限）。
/// 地区                秦皇岛  ›      ← 整行可点，弹城市选择器
/// ```
///
/// ## 为什么是「选」而不是「填」
///
/// 手打城市名容易打错（「秦皇岛」打成「秦皇島」就查不到 → 面板只会显示「暂无数据」，
/// 用户看不出是自己打错了）。现在点这一行弹 `CityPickerDialog`：
/// 热门城市 + 拼音首字母排序 + 搜索框。
///
/// ## 为什么没有「去授权」按钮了
///
/// 本机实测（2026-11-10）：ad-hoc 签名的 app 请求定位，系统 **2 秒内直接 denied、
/// 零弹框**。引导用户去点一个永远不会生效的授权按钮，比不引导更糟。
final class DayPanelWeatherRow: NSView {

    // MARK: - 公开回调

    /// 用户拨动了「显示天气」开关（参数 = 拨动之后的目标值）。
    var onToggleWeather: ((Bool) -> Void)?

    /// 用户点了「地区」那一行 → 该弹城市选择器了。
    var onPickCity: (() -> Void)?

    // MARK: - 子视图

    private let toggle = NSSwitch()
    private let titleLabel = NSTextField(labelWithString: "显示天气")
    private let statusLabel = NSTextField(labelWithString: "")
    private let regionRow = WeatherRegionRow()

    /// 开关当前是开是关。
    var isOn: Bool { toggle.state == .on }

    /// 当前显示的状态说明（自检用）。
    var displayedStatus: String { statusLabel.stringValue }

    /// 当前选中的地区（自检用）。
    var cityText: String { regionRow.value }

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

        regionRow.onTap = { [weak self] in self?.onPickCity?() }
        regionRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(toggle)
        addSubview(regionRow)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -2),

            // 地区行：整行的底边就是这一行的底边（状态文字不再单独钉底，
            // 否则两条约束会打架，把地区那一行挤出卡片 —— 2026-11-10 修）。
            regionRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            regionRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            regionRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            regionRow.heightAnchor.constraint(equalToConstant: 24),
            regionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    /// 灌入当前状态。
    func update(enabled: Bool, authStatus: CLAuthorizationStatus?, city: String = "") {
        toggle.state = enabled ? .on : .off
        statusLabel.stringValue = Self.describe(enabled: enabled, authStatus: authStatus,
                                                city: city).text
        regionRow.value = city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 状态文案（**纯函数**，方便单测）。
    static func describe(enabled: Bool, authStatus: CLAuthorizationStatus?,
                         city: String = "") -> (text: String, needsButton: Bool) {
        guard enabled else {
            return ("关闭时不显示天气。", false)
        }
        // ⚠️ **地区是唯一可靠的取数入口**（2026-11-10 实测结论）：
        // `make app` 是 ad-hoc 签名，macOS 对 ad-hoc 签名的 app **静默拒绝**
        // 定位（`requestWhenInUseAuthorization()` 2 秒内直接 denied、无弹框），
        // 所以这里不再引导「去授权」，直接让用户选地区。
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return ("按「\(trimmed)」显示天气（不需要定位权限）。", false)
        }
        return ("还没选地区：日期覆盖层会提示「请在设置里选择地区」。", false)
    }

    @objc private func toggled() {
        onToggleWeather?(toggle.state == .on)
    }

    /// 设置地区（自检 / 外部灌值）。
    func setCity(_ name: String) {
        regionRow.value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 「地区」那一行：左边标题、右边当前地区 + 箭头，**整行可点**。
///
/// 和 `DayPanelListRow`（提醒事项清单）保持同一套观感。
private final class WeatherRegionRow: NSButton {

    var onTap: (() -> Void)?

    /// 当前地区（空串 = 还没选）。
    var value: String = "" {
        didSet { valueLabel.stringValue = value.isEmpty ? "未选择" : value }
    }

    private let titleLabel = NSTextField(labelWithString: "地区")
    private let valueLabel = NSTextField(labelWithString: "未选择")
    private let chevron = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        isTransparent = true
        focusRingType = .none
        title = "地区"
        setAccessibilityLabel("地区")

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: "选择地区")
        chevron.image?.isTemplate = true
        chevron.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 9),

            valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -5),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                constant: 8),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
        super.mouseDown(with: event)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

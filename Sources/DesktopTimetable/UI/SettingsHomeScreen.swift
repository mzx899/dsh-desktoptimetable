import AppKit

/// 设置面板的**板块**。
///
/// 面板从「一整页长列表」改成「板块首页 → 分类设置页」两级结构后，
/// 一个板块 = 首页上的一个按钮 + 一个分类设置页。
///
/// 加新功能的步骤：**加一个 case → 在首页加一个按钮 → 把卡片挂到对应 section**。
enum SettingsSection: String, CaseIterable {
    case appearance
    case timetable
    case reminder
    case system

    /// 首页按钮上显示的名字。
    var title: String {
        switch self {
        case .appearance: return "外观"
        case .timetable:  return "课表"
        case .reminder:   return "提醒"
        case .system:     return "系统"
        }
    }

    /// 首页按钮上的图标（SF Symbols 名）。
    ///
    /// 全部是**单色（template）**符号 —— 不带颜色、不带渐变，
    /// 靠 `isTemplate` + 统一 tint 染成浅灰白。
    var symbolName: String {
        switch self {
        case .appearance: return "paintbrush"
        case .timetable:  return "calendar"
        case .reminder:   return "bell"
        case .system:     return "gearshape"
        }
    }

    /// 分类设置页顶部的标题。
    var pageTitle: String {
        switch self {
        case .appearance: return "外观"
        case .timetable:  return "课表"
        case .reminder:   return "提醒"
        case .system:     return "系统"
        }
    }
}

/// 设置面板的**首页**：只放 4 个板块按钮（外观 / 课表 / 提醒 / 系统）。
///
/// 收起态下窗口是个小长条，这里就是它全部的内容 —— 不显示任何具体设置项。
///
/// 版式：**大图标在上、名称在下**，四个板块等宽铺满一排
/// （和系统控制中心那一套「图标 + 文字」的观感一致，但要更饱满）：
/// - 图标用 `NSImage(systemSymbolName:)`，`isTemplate = true`，统一染成浅灰白
///   （**不用 emoji、不用彩色资源** —— 彩色图标会和深色毛玻璃打架）；
/// - 每个按钮是一块半透明圆角「砖」，hover / 按下时高亮；
/// - **按钮的点击区域 = 整块砖**（不是只有图标那一小块），
///   所以点哪儿都能中。
final class SettingsHomeScreen: NSView {

    /// 点某个板块（首页 → 分类页）。
    var onSelect: ((SettingsSection) -> Void)?

    /// 板块按钮（自检用：首页有几个按钮、分别是什么）。
    private(set) var buttons: [SectionTile] = []

    /// 一排板块砖。
    private let row = NonHitStackView()

    /// 每块砖的宽度（点）。
    ///
    /// 固定宽度 —— 不跟着窗口拉伸（收起态的宽度是固定的）。
    /// 四块砖 + 间距正好铺满 580 宽的面板。
    static let tileWidth: CGFloat = 128
    /// 砖之间��间距。
    static let tileSpacing: CGFloat = 14
    /// 砖的高度（点）。
    static let tileHeight: CGFloat = 84
    /// 四个砖 + 间距的总宽度（点）。
    static var rowWidth: CGFloat {
        CGFloat(SettingsSection.allCases.count) * tileWidth
            + CGFloat(SettingsSection.allCases.count - 1) * tileSpacing
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Self.tileSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // ⚠️ **stack 自己不能吃掉命中测试**（见 NonHitStackView 的说明）。

        for section in SettingsSection.allCases {
            let tile = SectionTile(section: section)
            tile.onTap = { [weak self] section in
                self?.onSelect?(section)
            }
            buttons.append(tile)
            row.addArrangedSubview(tile)
        }

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            // ⚠️ 首页视图**自己**也要有尺寸 ——
            // 它是透明的，但 frame 为 0 时命中测试会整个失败
            // （bounds.contains 永远为 false → 点哪儿都点不到砖块）。
            widthAnchor.constraint(equalToConstant: Self.rowWidth),
            heightAnchor.constraint(equalToConstant: Self.tileHeight),
        ])
        // 每块砖**等宽等高**（stack 的 distribution 不一定均分，显式钉死）。
        //
        // ⚠️ 宽度和高度都要钉在**砖自己**身上 ——
        // 只钉 stack 的高度不管用：arrangedSubview 还是会按自己的
        // intrinsic size 排（NSButton 的固有高度只有 18pt），
        // 结果就是「看着是一排小字，点击区也只有一条」。
        for tile in row.arrangedSubviews {
            tile.widthAnchor.constraint(equalToConstant: Self.tileWidth).isActive = true
            tile.heightAnchor.constraint(equalToConstant: Self.tileHeight).isActive = true
        }
    }

    /// 自检用：首页按钮的标题（按顺序）。
    var sectionTitles: [String] {
        buttons.map { $0.section.title }
    }

    /// 自检用：首页按钮的图标是不是纯色（template）。
    ///
    /// 模板图标的 `isTemplate == true` —— AppKit 渲染时会按 tint 染色，
    /// 也就是**单色**。这里同时确认图标确实存在（不是空白的方块）。
    var allIconsAreMonochrome: Bool {
        buttons.allSatisfy { $0.iconIsMonochrome }
    }

    /// 自检用：首页是不是有 4 个板块按钮、名字对不对。
    var sectionTitlesMatch: Bool {
        sectionTitles == SettingsSection.allCases.map(\.title)
    }

    /// 自检用：每块砖的**点击区域**是不是整块砖（不能只有图标那一小块）。
    ///
    /// 点不中是最容易犯也最难发现的毛病 ——
    /// 视觉上按钮很大，但实际只有中间一小块能点。
    func allTilesAreFullyClickable() -> Bool {
        buttons.allSatisfy { tile in
            guard let image = tile.iconView, let text = tile.textView else { return false }
            let tileFrame = tile.bounds
            // 图标和文字都要**完整落在**砖的边界内。
            //
            // ⚠️ 用 `tile.convert(sub.bounds, from: sub)` 换算 ——
            // 直接拿 `sub.bounds` 会因为坐标系不同而算偏。
            for sub in [image, text] {
                let f = tile.convert(sub.bounds, from: sub)
                guard tileFrame.contains(f) else { return false }
            }
            return true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// **只把命中转发给子视图**的横排栈。
///
/// 为什么需要它：NSStackView 会把 arrangedSubview 排在一块「看不见但存在」的
/// 背景上 —— 命中测试时它**先接住**点击，于是点砖块其实是点在 stack 上，
/// 按钮的 action 根本不触发（用户看到的「点了没反应」）。
///
/// 这里让 stack 只做「转发」：命中到哪块砖就返回哪块砖，
/// 空白处返回 nil（不吞点击）。
final class NonHitStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        for sub in arrangedSubviews {
            let local = convert(point, to: sub)
            if let hit = sub.hitTest(local) {
                return hit
            }
        }
        return nil
    }
}

/// **不参与命中测试**的装饰视图（图标 / 文字）。
///
/// 砖块上的图标和文字只是装饰 —— 命中测试要能「穿透」它们落到砖块上，
/// 否则点图标时事件停在 NSImageView，按钮收不到（用户看到的「点了没反应」）。
class NonHitView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 不参与命中测试的图标视图。
final class NonHitImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 不参与命中测试的**文字**。
///
/// ⚠️ 不要继承 `NSTextField` —— 它的 cell 会画一个**黑色圆角底**
/// （看着像按钮上的高亮块），样式很难去掉；
/// 无参 `NSTextField()` 更是可编辑输入框，会画成黑条 + 闪烁光标。
///
/// 这里包一个真正的只读标签（`NSTextField(labelWithString:)`），
/// 自己只负责「不参与命中测试」。
final class NonHitText: NSView {
    /// 里面的只读标签（自检用）。
    let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 首页上的一块「板块砖」。
///
/// 用 `NSButton` 做底（自带 hover / 按下的状态和键盘可达性），
/// 但**图标和文字是自绘的子视图**（图标在上、文字在下），
/// 而不是 `NSButton` 的 image + title —— 后者只能横排，
/// 而且「图标在上文字在下」这种版式得自己做。
///
/// 整个砖都是按钮（`NSButton` 的 frame = 砖的大小），
/// 所以点哪儿都能中。
final class SectionTile: NSButton {

    /// 点这块砖 → 展开对应板块。
    var onTap: ((SettingsSection) -> Void)?

    /// 这块砖属于哪个板块。
    let section: SettingsSection

    /// 图标视图（自检用）。
    private(set) var iconView: NSImageView?
    /// 文字视图（自检用）—— 里面那个真正的只读标签。
    private(set) var titleLabel: NSTextField?
    /// 包着文字的容器视图（自检用：算「文字有没有超出砖」要用它）。
    private(set) var textView: NonHitText?

    /// 图标尺寸（点）。
    private static let iconSize: CGFloat = 30
    /// 图标和文字之间的间距（点）。
    private static let iconTextGap: CGFloat = 9

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)

        wantsLayer = true
        // 砖的底色（半透明白，压在毛玻璃上）。
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        // 按钮本身是「透明」的：内容都放在子视图里。
        isBordered = false
        focusRingType = .none
        // 自绘子视图 → 按钮自己别再画任何东西。
        isTransparent = true
        // title 只用来**给辅助功能（VoiceOver / AX）一个名字**，
        // 画面上不显示（isTransparent = true 不画标题）。
        // 不设的话这块砖在 AX 树里是个「无名按钮」——
        // 既不好用 VoiceOver，自动化测试也认不出它。
        title = section.title
        setAccessibilityLabel(section.title)

        // ---- 图标 ----
        let image = NSImage(systemSymbolName: section.symbolName,
                            accessibilityDescription: section.title)
        image?.isTemplate = true
        let icon = NonHitImageView()
        icon.image = image
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.88)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        addSubview(icon)
        iconView = icon

        // ---- 名称 ----
        let text = NonHitText(text: section.title)
        text.label.font = .systemFont(ofSize: 12.5, weight: .medium)
        text.label.textColor = NSColor.white.withAlphaComponent(0.82)
        text.label.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        titleLabel = text.label
        textView = text

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Self.iconTextGap / 2 - Self.iconSize / 2 + 2),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),

            text.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: Self.iconTextGap),
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            text.heightAnchor.constraint(equalToConstant: 17),
        ])

        // 整个砖都是点击区。
        target = self
        action = #selector(tapped)

    }

    /// 命中测试：砖块范围内一律算点在砖上（图标/文字也算）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    /// 鼠标移进砖里 → 用 tracking area（比 hover 可靠，
    /// 不用窗口先收到 mouseMoved 事件）。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
    }

    @objc private func tapped() {
        onTap?(section)
    }

    /// 自检用：图标是不是纯色（template）。
    var iconIsMonochrome: Bool {
        guard let image = iconView?.image else { return false }
        return image.isTemplate
    }

    /// hover 高亮（鼠标进砖里 → 底色亮一点）。
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        }
    }

    /// 移出 → 恢复。
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

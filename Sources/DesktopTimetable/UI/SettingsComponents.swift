import AppKit

/// 设置面板的共用组件。
///
/// 这一节直接从旧版「课表设置」程序（`课表设置.app`）搬过来，
/// 版式、间距、颜色、圆角全部保持原样 —— 新 App 的设置面板
/// 要和旧版看起来一模一样，就不能重画，只能照抄。

/// 上下翻转的容器视图（y=0 在顶部），文档视图按自上而下排版更直观。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// ---------- 配色 ----------
// 旧版是全局 let，搬进 App 后收进枚举，避免污染全局命名空间。
enum SettingsStyle {
    static let accent = NSColor(red: 79.0 / 255.0, green: 140.0 / 255.0, blue: 1.0, alpha: 1)
    static let accent2 = NSColor(red: 165.0 / 255.0, green: 119.0 / 255.0, blue: 1.0, alpha: 1)
}

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}

func monoLabel(_ text: String, size: CGFloat = 12, color: NSColor = .white) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
    l.textColor = color
    l.alignment = .right
    return l
}

func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(hi, max(lo, v))
}

// ---------- 卡片容器 ----------
final class SettingsCard: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let content = NSStackView()

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.45)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(content)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
        ])
    }

    // 添加一行并让它撑满卡片内容宽度。
    // NSStackView 的 alignment 不会把子视图拉宽，必须显式约束，
    // 否则里面含弹性宽度的控件（滑杆）会塌成最小宽度。
    func addRow(_ v: NSView) {
        content.addArrangedSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// ---------- 滑杆行 ----------
// 版式：
//   标题                      [◀] ——— 滑杆 ——— [▶]   3.0 s
//   副标题（独占一行，不再压到滑杆轨道上）
//
// 之前副标题和滑杆在同一行，副标题一长（加了「0.1–6.0 s」范围说明后）
// 就压到轨道上，看着很挤。改成两行后互不干扰。

/// 能报告「拖动开始 / 结束」的滑杆。
///
/// `NSSlider` 本身没有「拖动结束」的信号 ——
/// `action` 每帧都发（`isContinuous = true`），
/// 分不清「用户还在拖」和「拖完了」。
///
/// 需要「拖动中实时预览、松手才写盘」时（缩放课表卡片）就要这个区分。
final class DragAwareSlider: NSSlider {
    /// 鼠标按下（开始拖动）。
    var onMouseDown: (() -> Void)?
    /// 鼠标松开（结束拖动）。
    var onMouseUp: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
        // ⚠️ **必须在这里报「松开」**，而不是在 `mouseUp` 里 ——
        // `NSSlider` 的 `mouseDown` 内部会**吞掉**后续的 mouseUp
        // （它在 tracking area 里自己处理拖动），
        // 所以重写 `mouseUp` 根本不会被调用。
        onMouseUp?()
    }
}

final class SliderRow: NSView {
    let slider = DragAwareSlider()
    let valueLabel = NSTextField(labelWithString: "")
    var onChange: ((Double) -> Void)?

    /// 用户**开始拖动**滑杆（按下那一刻）。
    ///
    /// 用于「拖动中只做实时预览、不写盘」这类需求 ——
    /// 缩放卡片时每帧都写盘太浪费，松手写一次就够。
    var onDragBegin: (() -> Void)?
    /// 用户**结束拖动**滑杆（松手那一刻）。
    ///
    /// 与 `onChange` 的区别：`onChange` 每帧都发，`onDragEnd` 只在松手时发一次。
    var onDragEnd: ((Double) -> Void)?

    private var format: (Double) -> String = { _ in "" }
    private var step: Double = 0
    private var decimals: Int = 1
    /// 副标题（范围说明）。缩放卡片这一行要按「当前屏幕放得下多大」动态改文案。
    private let subLabel = NSTextField(labelWithString: "")
    /// 程序化改值时置位：此时 action 回调不往外发。
    /// AppKit 偶尔会在控件首次布局时补发一次 action，
    /// 那一发会把用户的配置悄悄改掉（表现就是「什么都没动，值却变了」）。
    private var suppressCallback = false
    /// 用户是否正在拖动滑杆（用于区分「拖动结束」和「普通改值」）。
    private var isDragging = false
    /// **中点在正中间的映射**（2026-11-10）。
    ///
    /// 面板不透明度是「20% ~ 100%」，线性映射时 50% 的滑块会落在 37.5% 处 ——
    /// 用户看到的是「明明写着 50%，滑块却在偏左」。这里把它做成**分段线性**：
    /// 20% → 0、**50% → 正中**、100% → 1，两边各占半条轨道。
    private var midpoint: Double?
    private var lo: Double = 0
    private var hi: Double = 1

    init(title: String,
         subtitle: String,
         min lo: Double,
         max hi: Double,
         value: Double,
         step: Double = 0,
         decimals: Int = 1,
         midpoint: Double? = nil,
         format: @escaping (Double) -> String) {
        super.init(frame: .zero)
        wantsLayer = true

        self.step = step
        self.decimals = decimals
        self.format = format

        let titleLabel = makeLabel(title, size: 12.5, weight: .medium,
                                   color: NSColor.white.withAlphaComponent(0.85))
        subLabel.attributedStringValue = NSAttributedString(
            string: subtitle,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                .font: NSFont.systemFont(ofSize: 10.5),
            ])

        self.lo = lo
        self.hi = hi
        self.midpoint = midpoint
        // 有中点映射时，滑杆本身跑 0…1（位置），值由 `valueFromPosition` 换算。
        slider.minValue = midpoint == nil ? lo : 0
        slider.maxValue = midpoint == nil ? hi : 1
        slider.doubleValue = positionFromValue(value)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        // 拖动开始 / 结束（用于「拖动中实时预览、松手才写盘」）。
        slider.onMouseDown = { [weak self] in
            guard let self else { return }
            self.isDragging = true
            self.onDragBegin?()
        }
        slider.onMouseUp = { [weak self] in
            guard let self, self.isDragging else { return }
            self.isDragging = false
            self.onDragEnd?(self.valueFromPosition(self.slider.doubleValue))
        }

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = SettingsStyle.accent
        valueLabel.alignment = .right
        valueLabel.stringValue = format(value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.lineBreakMode = .byTruncatingTail

        addSubview(titleLabel)
        addSubview(subLabel)
        addSubview(slider)
        addSubview(valueLabel)

        let decBtn = makeStepButton("◀", #selector(stepDown))
        let incBtn = makeStepButton("▶", #selector(stepUp))
        addSubview(decBtn)
        addSubview(incBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 120),

            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            subLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            subLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            subLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            decBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 132),
            decBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            decBtn.widthAnchor.constraint(equalToConstant: 22),
            decBtn.heightAnchor.constraint(equalToConstant: 18),

            slider.leadingAnchor.constraint(equalTo: decBtn.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            incBtn.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            incBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            incBtn.widthAnchor.constraint(equalToConstant: 22),
            incBtn.heightAnchor.constraint(equalToConstant: 18),

            // 数值标签靠右、按内容自然宽度；用 >= 让弹性滑杆吸收剩余空间，
            // 写死宽度会和字体的固有宽度打架（会溢出卡片 2px）。
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: incBtn.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    /// 滑杆位置（0…1）→ 真实值（**纯函数**，方便单测）。
    ///
    /// `midpoint == nil` 时就是线性（位置即值）。
    static func value(fromPosition p: Double, lo: Double, hi: Double,
                      midpoint: Double?) -> Double {
        guard let mid = midpoint else { return p }
        if p <= 0.5 {
            return mid == lo ? lo : lo + (mid - lo) * (p / 0.5)
        }
        return mid + (hi - mid) * ((p - 0.5) / 0.5)
    }

    /// 真实值 → 滑杆位置（0…1）。
    static func position(fromValue v: Double, lo: Double, hi: Double,
                         midpoint: Double?) -> Double {
        guard let mid = midpoint else { return v }
        if v <= mid {
            return mid == lo ? 0 : 0.5 * (v - lo) / (mid - lo)
        }
        return hi == mid ? 1 : 0.5 + 0.5 * (v - mid) / (hi - mid)
    }

    private func valueFromPosition(_ p: Double) -> Double {
        Self.value(fromPosition: p, lo: lo, hi: hi, midpoint: midpoint)
    }

    private func positionFromValue(_ v: Double) -> Double {
        Self.position(fromValue: v, lo: lo, hi: hi, midpoint: midpoint)
    }

    // 小的圆形步进按钮（◀ / ▶），点一次走一个 step
    private func makeStepButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        b.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
            ]
        )
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    // 把「当前值」先对齐到 step 网格，再加/减一个 step。
    // 必须先对齐再加减：配置里可能是 3.044（滑杆拖出来的），
    // 界面上显示 3.0，用户点 ▶ 期望看到 3.1，而不是 3.3。
    private func commit(direction: Double) {
        guard step > 0 else { return }
        let factor = pow(10.0, Double(decimals))
        let base = (valueFromPosition(slider.doubleValue) * factor).rounded() / factor
        let next = ((base + direction * step) * factor).rounded() / factor
        let clamped = clamp(next, lo, hi)
        slider.doubleValue = positionFromValue(clamped)
        valueLabel.stringValue = format(clamped)
        onChange?(clamped)
        // 点 ◀/▶ 不是拖动 —— 但对「拖动中不写盘」的需求来说，
        // 这一步算一次「结束」，该写盘就写盘。
        if !isDragging {
            onDragEnd?(clamped)
        }
    }

    @objc private func sliderMoved() {
        let v = valueFromPosition(slider.doubleValue)
        valueLabel.stringValue = format(v)
        if suppressCallback { return }
        onChange?(v)
    }

    @objc private func stepDown() { commit(direction: -1) }
    @objc private func stepUp() { commit(direction: 1) }

    /// 程序化设值（不触发 onChange）
    func setValue(_ v: Double) {
        suppressCallback = true
        slider.doubleValue = positionFromValue(v)
        valueLabel.stringValue = format(v)
        suppressCallback = false
    }

    /// 改滑杆的上限（不触发 onChange）。
    ///
    /// 用于「上限依环境而定」的项：课表大小最多能放到多大取决于当前屏幕，
    /// 写死 115% 的话，滑杆顶部一段是「拖了也不动」的死区 ——
    /// 用户会感觉拖不动 / 卡住，而且显示的百分比和实际大小对不上。
    func setMaxValue(_ v: Double) {
        hi = max(v, lo)
        if midpoint == nil {
            slider.maxValue = hi
        }
        if value > hi { setValue(hi) }
    }

    /// 改副标题文案（范围说明）。
    func setSubtitle(_ text: String) {
        subLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                .font: NSFont.systemFont(ofSize: 10.5),
            ])
    }

    /// 当前值
    var value: Double {
        get { valueFromPosition(slider.doubleValue) }
        set { setValue(newValue) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

import AppKit

/// 设置 →「日记」板块里的一行：`日期 · 时间 · 标题`，点一下选中。
///
/// 单独一个视图（而不是 NSButton）是因为要做「选中高亮」——
/// 系统按钮的选中态在暗色 HUD 上很丑，这里自己画一块圆角底。
final class DiaryRowView: NSView {

    private let entry: DiaryEntry
    private let selected: Bool
    var onSelect: (() -> Void)?
    /// **双击**一行（2026-11-10 用户要求：双击直接打开这篇日记的编辑窗口）。
    var onDoubleClick: (() -> Void)?

    init(entry: DiaryEntry, selected: Bool) {
        self.entry = entry
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.white
            .withAlphaComponent(selected ? 0.12 : 0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white
            .withAlphaComponent(selected ? 0.22 : 0.07).cgColor

        let date = NSTextField(labelWithString: entry.date)
        date.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        date.textColor = NSColor.white.withAlphaComponent(0.45)
        date.translatesAutoresizingMaskIntoConstraints = false

        let time = NSTextField(labelWithString: entry.time.isEmpty ? "——" : entry.time)
        time.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        time.textColor = NSColor(srgbRed: 0.96, green: 0.76, blue: 0.42, alpha: 1)
        time.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: entry.title.isEmpty ? "（未命名）" : entry.title)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        for v in [date, time, title] { addSubview(v) }
        NSLayoutConstraint.activate([
            date.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            date.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.leadingAnchor.constraint(equalTo: date.trailingAnchor, constant: 8),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 窗口没成为 key 时第一次点击也要算数（否则用户会觉得「要点两下」）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            // 双击：先按「选中」处理（视觉上先选中），再打开编辑窗口。
            onSelect?()
            onDoubleClick?()
            return
        }
        onSelect?()
    }
}

/// 设置面板里给滚动列表用的**翻转**容器（原点在左上）。
///
/// `NSScrollView` 的 document view 不翻转的话，内容高于视口时会整体跑到视口上方
/// （合并差异页就踩过这个坑，2026-11-09）。
final class FlippedStackDocument: NSView {
    override var isFlipped: Bool { true }
}

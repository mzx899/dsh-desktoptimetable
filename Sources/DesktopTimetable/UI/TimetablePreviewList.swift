import AppKit

/// 课表预览列表（自绘行 · 可滚动 · 可点选）。
///
/// 为什么不用 `NSTableView`：
///   这台机器只装了 Command Line Tools，AppKit 的 swiftmodule 是**裁剪版**，
///   `usesViewBasedTableView` 这类 API 根本不存在 —— 表格只能用 cell 模式，
///   没法给「当前课表」单独上色。自己画行反而更可控，也更好看。
///
/// 用法：
/// ```swift
/// let list = TimetablePreviewList()
/// list.items = [...]          // 刷新内容
/// list.selectedID = id        // 高亮
/// list.onSelect = { id in }   // 点选回调
/// ```
final class TimetablePreviewList: NSView {

    /// 一份课表。
    struct Item {
        var id: String
        var name: String
        var subtitle: String
        var updated: String
        /// 当前正在用的那份。
        var isActive: Bool
    }

    /// 列表内容。
    var items: [Item] = [] {
        didSet { rebuild() }
    }

    /// 选中的那份（高亮）。
    var selectedID: String? {
        didSet { updateSelection() }
    }

    /// 点选回调。
    var onSelect: ((String) -> Void)?

    // MARK: - 常量

    private static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 2
    /// 右边留一条沟给 overlay 滚动条（macOS 的滚动条浮在内容之上，不占位）。
    private static let gutter: CGFloat = 16

    // MARK: - 子视图

    /// 内层滚动视图：滚轮转交给外层面板（见 `WheelForwardingScrollView`）。
    /// 内层内容仍然可以用右边的滚动条拖着看。
    private let scroll = WheelForwardingScrollView()
    private let document = PreviewDocumentView()
    private var rows: [TimetablePreviewRow] = []

    // MARK: - 初始化

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // 宽度跟着裁剪区走（滚动条浮上来时宽度不变，高度由我们自己算）
        document.autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 内容

    private func rebuild() {
        for row in rows { row.removeFromSuperview() }
        rows.removeAll()
        for item in items {
            let row = TimetablePreviewRow(item: item)
            row.onClick = { [weak self] in
                self?.selectedID = item.id
                self?.onSelect?(item.id)
            }
            document.addSubview(row)
            rows.append(row)
        }
        updateSelection()
        needsLayout = true
        layoutRows()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    /// 手动摆行 —— 行的 frame 自己算（NSStackView 会跟它自己的宽度约束打架）。
    private func layoutRows() {
        let w = max(document.bounds.width - Self.gutter, 0)
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: w, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowSpacing
        }
        document.frame.size.height = max(y - Self.rowSpacing, 0)
    }

    private func updateSelection() {
        for row in rows {
            row.isChosen = (row.item.id == selectedID)
        }
    }
}

/// 顶左原点的容器（行从上往下摆，符合直觉）。
final class PreviewDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 预览列表里的一行。
final class TimetablePreviewRow: NSView {

    let item: TimetablePreviewList.Item
    var onClick: (() -> Void)?

    /// 是不是当前选中的行（高亮）。
    var isChosen = false {
        didSet { updateAppearance() }
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    init(item: TimetablePreviewList.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        nameLabel.stringValue = item.isActive ? "✓ \(item.name)" : item.name
        nameLabel.font = .systemFont(ofSize: 12, weight: item.isActive ? .semibold : .regular)
        nameLabel.textColor = item.isActive
            ? .controlAccentColor
            : NSColor.white.withAlphaComponent(0.88)
        nameLabel.lineBreakMode = .byTruncatingTail

        subLabel.stringValue = item.subtitle
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        subLabel.lineBreakMode = .byTruncatingTail

        dateLabel.stringValue = item.updated
        dateLabel.font = .systemFont(ofSize: 10.5)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        dateLabel.alignment = .right

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [nameLabel, subLabel, spacer, dateLabel])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.heightAnchor.constraint(equalToConstant: 16),
            subLabel.heightAnchor.constraint(equalToConstant: 15),
            dateLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isChosen
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }
}

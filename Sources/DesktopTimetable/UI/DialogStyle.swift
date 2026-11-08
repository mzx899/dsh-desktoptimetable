import AppKit

/// 弹窗的语义分级。
///
/// 全 app 的弹窗只有四种语气：说明 / 警告 / 危险 / 提问。
/// 分级决定**图标**、**主色**和**键盘默认焦点**（危险操作的 Return 不能直接删东西）。
enum DialogSeverity {
    /// 普通说明（蓝色）。
    case info
    /// 警告（琥珀色）。
    case warning
    /// 危险操作（红色）：删除、覆盖、不可撤销。
    case destructive
    /// 提问（蓝色）。
    case question
}

/// 底部按钮的角色。顺序固定：**取消在左，主操作在右**。
enum DialogButtonRole {
    /// 次要（白色 12% 底），Esc。
    case cancel
    /// 危险（红色填充），**不绑 Return** —— 免得回车顺手删东西。
    case destructive
    /// 主操作（语义色填充），Return。
    case primary

    /// 给 `NSButton.tag` 用的编号（`buttonTapped` 靠它分辨是哪个按钮）。
    var tagValue: Int {
        switch self {
        case .cancel: return 0
        case .destructive: return 1
        case .primary: return 2
        }
    }
}

/// 弹窗的纯逻辑规则 —— 不碰窗口，单元测试可以直接查。
///
/// 视图层（`AlertDialog`）只负责把这些规则画出来；
/// 规则本身放在这里，测试不用弹窗就能验证。
enum DialogStyle {

    // MARK: - 版式常量

    /// 说明文字的最大宽度。
    static let messageMaxWidth: CGFloat = 350
    /// 列表超过这么多行就滚动。
    static let maxVisibleRows: Int = 5
    /// 说明文字超过这么多字就滚动（和行数一起判断）。
    static let maxMessageLength: Int = 420
    /// 弹窗宽度范围。
    static let minWidth: CGFloat = 400
    static let maxWidth: CGFloat = 460
    /// 弹窗宽度（统一值，落在上面的范围内）。
    static let width: CGFloat = 440
    /// 窗口高度最多占屏幕可见区的比例。
    static let maxHeightRatio: CGFloat = 0.8

    // MARK: - 语义色 / 图标

    /// 语义色的十六进制（唯一真源，测试直接比字符串）。
    static func hex(_ severity: DialogSeverity) -> String {
        switch severity {
        case .info, .question:
            return "#4f8cff"
        case .warning:
            return "#f5a524"
        case .destructive:
            return "#ef5f5b"
        }
    }

    /// 语义色的 SF Symbol。
    static func symbolName(_ severity: DialogSeverity) -> String {
        switch severity {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .destructive:
            return "exclamationmark.octagon.fill"
        case .question:
            return "questionmark.circle.fill"
        }
    }

    /// 语义色。
    static func color(_ severity: DialogSeverity) -> NSColor {
        TimetablePalette.color(hex: hex(severity))
    }

    /// 这个分级是不是危险操作。
    static func isDestructive(_ severity: DialogSeverity) -> Bool {
        severity == .destructive
    }

    // MARK: - 按钮

    /// 底部按钮顺序：取消在左，主操作在右。
    static func buttonOrder(hasCancel: Bool, hasPrimary: Bool) -> [DialogButtonRole] {
        var out: [DialogButtonRole] = []
        if hasCancel { out.append(.cancel) }
        if hasPrimary { out.append(.primary) }
        return out
    }

    /// 默认焦点落在哪个按钮上。
    ///
    /// 危险操作默认焦点给「取消」—— Return 不该顺手把课表删了。
    static func defaultFocus(isDestructive: Bool) -> DialogButtonRole {
        isDestructive ? .cancel : .primary
    }

    /// Return 键是否绑定主操作（危险操作不绑定）。
    static func returnTriggersPrimary(isDestructive: Bool) -> Bool {
        !isDestructive
    }

    // MARK: - 滚动

    /// 列表 / 说明是否需要滚动。
    static func needsScroll(itemCount: Int, messageLength: Int) -> Bool {
        itemCount > maxVisibleRows || messageLength > maxMessageLength
    }
}

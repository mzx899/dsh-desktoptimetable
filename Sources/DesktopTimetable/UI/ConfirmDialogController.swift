import AppKit

/// 通用确认窗 —— 现在是 `AlertDialogController` 的**兼容入口**。
///
/// 真正的实现全在 `AlertDialogController`（统一版式 / 语义色 / 键盘 / 滚动）。
/// 这里保留原来的 `Request` / `Choice` 接口，老调用点不用重写：
///
/// 用法：`ConfirmDialogController(request:).run()` → `.confirm` / `.cancel`。
final class ConfirmDialogController: NSObject {

    /// 用户的选择。
    enum Choice: Equatable {
        case confirm
        case cancel
    }

    /// 一次确认的内容。
    struct Request {
        /// 标题。
        var title: String
        /// 正文（可多行）。
        var message: String
        /// 冲突的课（逐条列出）。
        var items: [Course] = []
        /// 确认按钮的标题。
        var confirmTitle: String = "确认"
        /// 取消按钮的标题。
        var cancelTitle: String = "取消"
        /// 警示样式（黄色标题）。
        var isWarning: Bool = true
        /// 语义分级。`nil` = 按 `isWarning` 推导（true → warning，false → info）。
        ///
        /// 危险操作（删除 / 覆盖）传 `.destructive`：默认焦点给「取消」，
        /// Return 不绑定删除动作。
        var severity: DialogSeverity? = nil
        /// 取消按钮的快捷键（默认无；`"\u{1b}"` = Esc）。
        ///
        /// **保留只是为了兼容老调用点**：统一弹窗里 Esc 始终取消，
        /// 这个字段不再影响实际按键行为。
        var cancelKeyEquivalent: String? = nil

        init(title: String, message: String, items: [Course] = [],
             confirmTitle: String = "确认", cancelTitle: String = "取消",
             isWarning: Bool = true, cancelKeyEquivalent: String? = nil,
             severity: DialogSeverity? = nil) {
            self.title = title
            self.message = message
            self.items = items
            self.confirmTitle = confirmTitle
            self.cancelTitle = cancelTitle
            self.isWarning = isWarning
            self.cancelKeyEquivalent = cancelKeyEquivalent
            self.severity = severity
        }

        /// 实际使用的语义分级。
        var resolvedSeverity: DialogSeverity {
            severity ?? (isWarning ? .warning : .info)
        }
    }

    private let request: Request

    init(request: Request) {
        self.request = request
        super.init()
    }

    /// 弹出确认窗，等用户选完。
    @discardableResult
    func run() -> Choice {
        let outcome = AlertDialogController.show(.init(
            severity: request.resolvedSeverity,
            title: request.title,
            message: request.message,
            items: request.items,
            confirmTitle: request.confirmTitle,
            cancelTitle: request.cancelTitle,
            showsConfirm: true,
            showsCancel: true))
        if case .confirmed = outcome { return .confirm }
        return .cancel
    }
}

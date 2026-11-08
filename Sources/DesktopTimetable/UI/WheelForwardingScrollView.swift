import AppKit

/// 内层滚动视图：滚轮事件一律转交给**外层**滚动视图。
///
/// 为什么需要它：
///   设置面板整体是一个大滚动视图，里头又嵌了几个小的
///   （课表预览列表、课程预览表格）。AppKit 默认的嵌套滚动是
///   「内层先滚、滚到头了才交给外层」—— 鼠标停在内层区域时，
///   外层面板就推不动了，内层自己先滑走。
///
///   这里把行为反过来：**滚轮永远控制外层面板**，
///   内层内容只能用右边的滚动条（拖条）自己拖着看。
///   内层的滚动条保持原样，拖动依然有效。
///
/// 找不到外层滚动视图时（这个视图不在别的滚动视图里），
/// 退回 AppKit 默认行为，自己滚。
final class WheelForwardingScrollView: NSScrollView {

    /// 自检用：转交给外层的次数。
    private(set) var forwardedWheelCount = 0

    /// 真正该滚的外层滚动视图（`enclosingScrollView` 向上找）。
    /// `nil` 表示没有外层 —— 此时按默认行为自己滚。
    var outerScrollView: NSScrollView? { enclosingScrollView }

    override func scrollWheel(with event: NSEvent) {
        guard let outer = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        forwardedWheelCount += 1
        outer.scrollWheel(with: event)
    }
}

import AppKit

/// 「课表卡片大小」的取值策略。
///
/// 设计口径（2026-11-06 与用户确认）：
///   · **整体等比缩放** —— 宽高同一个系数，不做宽高独立。
///     宽高独立等于重做版式（CSS 里 268 处 px 写死），代价 1~1.5 天。
///   · **缩放锚点是「卡片中心」** —— 缩放前后卡片中心在屏幕上的位置不变，
///     课表原地胀大 / 缩小。这样所有「以课表中心为锚点」的弹窗
///     （设置面板、课程编辑器、确认框）都不用重新摆位。
///   · **上限按屏幕算** —— 卡片比屏幕可见区还高时会被裁掉，
///     所以每个屏幕能放到多大要现算，不能写死。
///
/// 全部是纯计算，可以单测。
enum CardScalePolicy {

    // MARK: - 取值范围

    /// 滑块的最小值（70%）。
    ///
    /// 太小会让课表上的字读不清 —— 100% 时正文 10.5px，70% 折算到屏幕上
    /// 约 7.4px，Mac 的「最小可读」大致在这个量级。
    static let minScale: Double = 0.70

    /// 滑块的最大值（115%）。
    ///
    /// ⚠️ 这是**滑块的固定上限**，不是「实际能放到的最大」——
    /// 实际上限还要按当前屏幕算（见 `maxScale(for:)`），
    /// 两者的较小值才是最终生效值。
    ///
    /// 之所以固定成 115% 而不是跟着屏幕变：滑块的 `maxValue` 一旦随
    /// 屏幕/位置动态变化，用户拖动时会看到轨道长度突变、手感很差。
    /// 固定上限 + 超出时按屏幕夹紧，手感稳定，行为也可预期。
    static let maxScale: Double = 1.15

    /// 滑块的步进（1%）。
    static let step: Double = 0.01

    /// 缩放时卡片与屏幕可见区之间至少留的间隙（pt）。
    ///
    /// 留一点边，课表才不会贴着屏幕边缘、投影也被切掉。
    static let screenMargin: CGFloat = 24

    // MARK: - 夹取

    /// 把任意值夹进滑块允许的范围（`minScale...maxScale`）。
    static func clamp(_ value: Double) -> Double {
        min(max(value, minScale), maxScale)
    }

    /// 把任意值夹进「滑块范围 ∩ 当前屏幕放得下的范围」。
    ///
    /// - Parameters:
    ///   - value: 用户给的值。
    ///   - visibleSize: 当前屏幕的**可见区**尺寸（pt）。
    ///   - cardSize: 当前课表卡片的尺寸（pt，未缩放）。
    static func clamp(_ value: Double, visibleSize: CGSize, cardSize: CGSize) -> Double {
        let screenUpper = maxScale(for: visibleSize, cardSize: cardSize)
        // 屏幕放得下的上限可能**比滑块下限还小**（很小的屏）——
        // 那时不能按上限夹（会把值夹到下限之上，反而放不下），
        // 必须取「下限」这个更保守的值。
        let upper = max(minScale, min(maxScale, screenUpper))
        return min(max(value, minScale), upper)
    }

    // MARK: - 屏幕上限

    /// 当前屏幕最多能放到多大（等比）。
    ///
    /// 公式：`min((可见高 − 边距) / 卡片高, (可见宽 − 边距) / 卡片宽, 1.15)`
    ///
    /// ⚠️ **卡片尺寸不能写死** —— 卡片高度随「时间段数量」变
    /// （`TimetableLayout.cardHeight` 从 `Schedule.periods.count` 推出来），
    /// 用户改过作息之后高度就不是 782 了。写死会让上限算错。
    ///
    /// - Parameters:
    ///   - visibleSize: 屏幕可见区尺寸（pt）。
    ///   - cardSize: 未缩放的卡片尺寸（pt）。
    static func maxScale(for visibleSize: CGSize, cardSize: CGSize) -> Double {
        guard cardSize.width > 0, cardSize.height > 0 else { return maxScale }
        let byHeight = (visibleSize.height - screenMargin) / cardSize.height
        let byWidth = (visibleSize.width - screenMargin) / cardSize.width
        return min(maxScale, min(byHeight, byWidth))
    }

    /// 当前屏幕最多能放到多大（用当前的卡片尺寸）。
    static func maxScale(for visibleSize: CGSize) -> Double {
        maxScale(for: visibleSize, cardSize: TimetableLayout.baseCardSize)
    }

    /// 当前屏幕最多能放到多大（用当前主屏 / 课表所在屏的可见区）。
    static func currentMaxScale(screen: NSScreen? = nil) -> Double {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return maxScale(for: vf.size)
    }

    // MARK: - 文案

    /// 滑块上显示的百分比文案（`100%`）。
    static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    /// 超出屏幕上限时的提示（没超返回 nil）。
    ///
    /// 例如「已按当前屏幕上限调整为 119%」。
    static func limitNotice(requested: Double, actual: Double) -> String? {
        guard requested - actual > 0.001 else { return nil }
        return "已按当前屏幕上限调整为 \(percentText(actual))"
    }
}

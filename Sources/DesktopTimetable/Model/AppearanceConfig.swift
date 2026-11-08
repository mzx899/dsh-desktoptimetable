import Foundation

/// 桌面卡片的外观参数。
struct AppearanceConfig: Equatable {
    /// 变实（鼠标移入）秒数
    var fadeInSec: Double = 0.8
    /// 变虚（鼠标移开）秒数
    var fadeOutSec: Double = 6.0
    /// 静置不透明度：0 = 全透明，1 = 不虚化
    var minOpacity: Double = 0.22
    /// 悬停不透明度：0 = 看不见，1 = 完全清晰
    var maxOpacity: Double = 1.0
    /// 「课表设置」面板自身的不透明度：1 = 不透明，0.2 = 近乎全透明。
    /// 只影响设置窗口，不影响桌面上的课表卡片。
    var panelOpacity: Double = 1.0
    /// 课表卡片的大小（等比缩放系数）：1.0 = 原始尺寸。
    /// 范围 0.70–1.15（滑块上限），实际还要按屏幕可见区夹一次。
    var cardScale: Double = 1.0

    /// 从存储的字典读，缺失项用默认值。
    init(_ dict: [String: Double]) {
        fadeInSec  = dict["fadeInSec"] ?? 0.8
        fadeOutSec = dict["fadeOutSec"] ?? 6.0
        minOpacity = dict["minOpacity"] ?? 0.22
        maxOpacity = dict["maxOpacity"] ?? 1.0
        panelOpacity = dict["panelOpacity"] ?? 1.0
        // 老配置没有这一项 → 默认 1.0（原始尺寸），自动兼容。
        cardScale = dict["cardScale"] ?? 1.0
    }

    var dictionary: [String: Double] {
        ["fadeInSec": fadeInSec, "fadeOutSec": fadeOutSec,
         "minOpacity": minOpacity, "maxOpacity": maxOpacity,
         "panelOpacity": panelOpacity, "cardScale": cardScale]
    }
}

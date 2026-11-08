import AppKit

/// 课表配色。
///
/// 颜色来源只有一个：**`ColorHex`**（颜色值的唯一真源）。
/// 这里只负责把解析好的颜色变成 `NSColor`。
///
/// 优先级（和 `ColorHex.resolvedHex` 一致）：
///   1. 课程自己的显式色（`course.colorHex`）；
///   2. 按课名查表（自动模式）；
///   3. 中性灰。
///
/// 原来的 9 门课默认配色一个都没改，只是表挪到了 `ColorHex.byName`。
enum TimetablePalette {

    /// 课程的强调色。
    static func accent(for course: Course) -> NSColor {
        color(hex: ColorHex.resolvedHex(for: course))
    }

    /// 课程格子的底色（强调色的低透明度版本）。
    static func fill(for course: Course, alpha: Double = 0.20) -> NSColor {
        accent(for: course).withAlphaComponent(alpha)
    }

    /// 十六进制颜色 → `NSColor`。非法值 → 中性灰。
    static func color(hex: String) -> NSColor {
        guard let c = ColorHex.rgb(hex) else {
            return NSColor(srgbRed: 139 / 255, green: 147 / 255, blue: 167 / 255, alpha: 1)
        }
        return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
    }

    /// 界面的通用色。
    enum UI {
        static let text = NSColor(srgbRed: 238 / 255, green: 241 / 255, blue: 247 / 255, alpha: 1)
        static let accent = NSColor(srgbRed: 79 / 255, green: 140 / 255, blue: 1, alpha: 1)
        static let accent2 = NSColor(srgbRed: 165 / 255, green: 119 / 255, blue: 1, alpha: 1)
        static let green = NSColor(srgbRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)

        /// 半透明前景色：白色 + 指定透明度。
        static func fg(_ alpha: Double) -> NSColor {
            NSColor(srgbRed: 238 / 255, green: 241 / 255, blue: 247 / 255, alpha: alpha)
        }

        /// 玻璃卡片底色。
        static let cardBackground = NSColor(srgbRed: 18 / 255, green: 20 / 255, blue: 26 / 255, alpha: 0.66)
        static let cardBorder = NSColor.white.withAlphaComponent(0.10)
    }
}

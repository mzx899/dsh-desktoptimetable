import Foundation

/// 颜色值的**唯一解析入口**（原生与网页共用）。
///
/// 课程的颜色有两种：
///   · **显式色** —— 用户在编辑器里挑的预设色或自定义色，存成 `#rrggbb`；
///   · **自动色** —— 没挑过时按课名查表（`TimetablePalette`），改名会跟着变。
///
/// 显式色写在课程记录里（`Course.colorHex`），`nil` = 自动。
/// 这里的解析规则是**唯一真源** —— 原生画卡片、网页画格子、
/// 写盘前规范化，全走这一个地方，避免两边各写一套规则。
enum ColorHex {

    // MARK: - 预设色

    /// 预设色（界面里的显示顺序）。
    ///
    /// 预设只是快捷入口；编辑器最右的「自定义」会打开系统色池，
    /// 选中的任意颜色同样存成 `#rrggbb`，不局限于这张表。
    static let presets: [(name: String, hex: String)] = [
        ("蓝",     "#4f8cff"),
        ("紫",     "#a577ff"),
        ("青",     "#2ec4b6"),
        ("橙黄",   "#f5a524"),
        ("粉",     "#f2569b"),
        ("绿",     "#93c05b"),
        ("红",     "#ef5f5b"),
        ("天蓝",   "#35b9e6"),
        ("橙",     "#ff8a3d"),
        ("蓝紫",   "#7c8cff"),
        ("翠绿",   "#4cc38a"),
        ("淡紫",   "#d98cf2"),
    ]

    /// 预设色的十六进制列表（编辑器色块按这个顺序排）。
    static var presetHexes: [String] { presets.map { $0.hex } }

    // MARK: - 按课名的自动色

    /// 按课名分配的默认颜色（**自动模式**用）。
    ///
    /// 原生侧的「自动色」唯一真源。网页侧不再拿自己的 `PALETTE` 当主来源 ——
    /// 原生会把**解析好的颜色**推给网页，两边不会各算各的。
    static let byName: [String: String] = [
        "数据结构": "#4f8cff",
        "业务需求建模": "#a577ff",
        "计算机网络基础": "#2ec4b6",
        "系统测试与质量管理": "#f5a524",
        "学术语言与研究方法（中级）": "#f2569b",
        "军事理论": "#93c05b",
        "马克思主义基本原理": "#ef5f5b",
        "形势与政策（三）": "#35b9e6",
        "体育(三)篮球": "#ff8a3d",
    ]

    /// 课名不在表里时的中性色。
    static let fallbackHex = "#8b93a7"

    /// 解析一门课最终用的颜色。
    ///
    /// 优先级：**显式色 > 按课名 > 中性灰**。
    ///
    /// - 显式色非法 → 静默回落到按课名（渲染时不能因为一个坏值就画不出来）。
    /// - 显式色优先于自动色 → 改名不会改变显式色；只有「自动」模式改名才跟着变。
    static func resolvedHex(name: String, colorHex: String?) -> String {
        if let explicit = normalized(colorHex) { return explicit }
        return byName[name] ?? fallbackHex
    }

    /// 解析一门课最终用的颜色（按 `Course` 取名字和显式色）。
    static func resolvedHex(for course: Course) -> String {
        resolvedHex(name: course.name, colorHex: course.colorHex)
    }

    // MARK: - 解析

    /// 规范化一个颜色值。
    ///
    /// 接受 `"#4F8CFF"` / `"4f8cff"` / `" #4f8cff "` → `"#4f8cff"`。
    /// 拒绝 3 位（`#fff`）、8 位（带 alpha）、非法字符、空串 → `nil`。
    ///
    /// **非法值返回 nil 而不是抛错** —— 颜色是「课程设置」，
    /// 一条坏颜色绝不能让整张课表读不出来。
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 else { return nil }
        guard s.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + s
    }

    /// 颜色值是否合法（能规范化出来）。
    static func isValid(_ raw: String?) -> Bool {
        normalized(raw) != nil
    }

    /// RGB 分解（0–255）。非法值 → `nil`。
    static func rgb(_ value: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex = normalized(value) else { return nil }
        let chars = Array(hex.dropFirst())
        func part(_ s: ArraySlice<Character>) -> Double? {
            var v = 0.0
            for ch in s {
                guard let d = ch.hexDigitValue else { return nil }
                v = v * 16 + Double(d)
            }
            return v
        }
        guard let r = part(chars[0..<2]),
              let g = part(chars[2..<4]),
              let b = part(chars[4..<6]) else { return nil }
        return (r, g, b)
    }
}

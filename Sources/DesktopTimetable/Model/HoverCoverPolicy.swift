import AppKit

/// 「指针这一点有没有被**别的 App 的窗口**挡住」的判定口径。
///
/// ## 为什么需要单独一条策略（2026-11-05 修「开 app 课表不出来」）
///
/// 课表窗口在**普通窗口（0）之下、桌面窗口（≈ -2147483623）之上**：
///
/// ```
/// level = -1
/// ```
///
/// 而 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` 回答的是
/// 「这一点上**最会吃鼠标**的窗口是谁」。指针停在空桌面上时，它给出的是
/// 访达的桌面窗口 / 壁纸窗口 —— **层级比课表还低，根本挡不住课表**。
///
/// 旧代码把「不是我们的窗口」一律当成「被别的 App 盖住了」：
///
/// ```swift
/// let covered = topNumber != 0 && !isOwnWindow(topNumber)   // ⚠️ 桌面窗口也算
/// ```
///
/// 于是在空桌面上永远判成「被遮挡」→ 课表停在 `minOpacity`（22%），
/// 用户看到的就是「点了 app 课表不出来、指针放在上面也不浮出来」。
///
/// 正确口径只有一条：**层级比课表高的窗口才挡得住课表**。
/// 同层不算（挡不住），更低更不算（桌面 / 壁纸 / 桌面图标都在我们下面）。
enum HoverCoverPolicy {

    /// 别的窗口的层级高出我们，才算遮挡。
    ///
    /// - Parameters:
    ///   - otherLayer: 那个窗口的 `kCGWindowLayer`；`nil` = 查不到。
    ///   - ourLevel: 课表窗口的层级。
    /// - Returns: 是否真的挡住课表。
    ///
    /// ⚠️ 查不到层级时**不当作遮挡**：宁可让课表亮着，
    /// 也不要再出现「永远不亮」——这是这次要修的 bug 本身。
    static func covers(otherLayer: Int?, ourLevel: Int) -> Bool {
        guard let otherLayer else { return false }
        return otherLayer > ourLevel
    }

    /// 某个窗口号在窗口服务器里的层级（`kCGWindowLayer`）。
    ///
    /// 只查这一个窗口：`CGWindowListCopyWindowInfo` 带
    /// `.optionIncludingWindow` 时，`relativeToWindow` 指定的窗口会被包含进
    /// 返回列表（其余是空列表或屏幕上的窗口，按窗口号过滤即可）。
    ///
    /// - Returns: 层级；窗口号非法 / 窗口已消失 / 查不到时返回 `nil`。
    static func layer(ofWindowNumber number: Int) -> Int? {
        guard number != 0 else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                    CGWindowID(number)) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let n = info[kCGWindowNumber as String] as? Int, n == number else { continue }
            return info[kCGWindowLayer as String] as? Int
        }
        return nil
    }

    /// 课表窗口自己的层级：**普通窗口（0）之下、桌面窗口（≈ -2147483623）之上**。
    ///
    /// ⚠️ 曾经放在「桌面图标之上 1 层」（-2147483602），但那个层级**低于任何
    /// 全屏窗口**：课表会被整块盖住、连点都点不到，后来改成了 `-1`。
    ///
    /// `DesktopWindow` 的默认值和 `AppDelegate` 的最终设置都用这一个数，
    /// 自检也用同一个 —— 「桌面窗口必须比课表低」这条断言才不是纸上推演。
    static var cardWindowLevel: Int { -1 }

    /// 屏幕上所有窗口的层级（自检用）。
    ///
    /// 用来证明「桌面 / 壁纸窗口在课表下面」不是纸上推演 ——
    /// 真机上一个 GUI 会话里必然存在这些窗口。
    static func onScreenWindowLayers() -> [Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0[kCGWindowLayer as String] as? Int }
    }
}

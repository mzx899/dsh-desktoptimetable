import AppKit

/// 课表图钉状态：**固定与否** + **窗口位置**。
///
/// 这两项都要跨启动保留，所以单独存一个文件（`window_state.json`），
/// 不混进 `settings.json`：
///   · `settings.json` 是「用户设置」，由设置面板负责读写；
///   · `window_state.json` 是「窗口状态」，由 AppDelegate 单独负责。
/// 两边互不覆盖 —— 设置面板保存时不会把窗口位置冲掉。
///
/// 存储位置：`Application Support/DesktopTimetable/window_state.json`。
struct TimetablePinState: Equatable {

    /// 是否已固定（图钉为实心）。
    var pinned: Bool = false

    /// 课表窗口在**屏幕坐标系**里的原点（左下角）。
    ///
    /// nil = 还没记过位置 → 启动时用默认位置。
    var origin: NSPoint? = nil

    init(pinned: Bool = false, origin: NSPoint? = nil) {
        self.pinned = pinned
        self.origin = origin
    }

    /// 全部默认值（首次启动）。
    static let `default` = TimetablePinState()
}

// MARK: - 读写

/// 图钉状态 / 窗口位置的持久化层。
///
/// 单独一个文件、单独的类，和 `SettingsStore` 完全不搭界 ——
/// 设置面板写 `settings.json` 时**不会**碰到这里，
/// 这里写 `window_state.json` 时也**不会**碰用户的课表数据。
final class TimetablePinStore {

    /// 状态文件所在目录。
    let directory: URL

    init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
    }

    /// 状态文件。
    var file: URL { directory.appendingPathComponent("window_state.json") }

    /// 读状态。文件不存在 / 损坏 → 全部默认值（**不是**错误）。
    func load() -> TimetablePinState {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TimetablePinState.default
        }
        var state = TimetablePinState.default
        // 布尔必须用「严格的 Bool」读：`JSONSerialization` 把 `true` 和 `1`
        // 都变成 NSNumber，`as? Bool` 对 `1` 也成立 ——
        // 别人手写一个 `{"pinned": 1}` 就能把课表锁死在屏幕上。
        if let b = StrictJSONValue.bool(obj["pinned"]) { state.pinned = b }
        if let x = StrictJSONValue.double(obj["x"]), let y = StrictJSONValue.double(obj["y"]),
           x.isFinite, y.isFinite {
            state.origin = NSPoint(x: x, y: y)
        }
        return state
    }

    /// 写状态（原子写）。
    func save(_ state: TimetablePinState) {
        // 建的是**自己的**目录，不是 `AppPaths.supportDirectory` ——
        // 测试会把这个 store 指到临时目录，用错目录就写不回自己读的那个文件。
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        var obj: [String: Any] = ["pinned": state.pinned]
        if let o = state.origin {
            obj["x"] = Double(o.x)
            obj["y"] = Double(o.y)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("[DesktopTimetable] 图钉状态写盘失败：%@", error.localizedDescription)
        }
    }
}

// MARK: - 纯计算（可单测）

extension TimetablePinState {

    /// 把窗口原点**夹回屏幕可见区**，保证窗口至少完整可见。
    ///
    /// 规则：
    ///   · 窗口比可见区还大时 —— 以可见区**左上角**为准（尽量让它落在屏幕里）；
    ///   · 否则把原点夹进 `[vf.minX, vf.maxX - width]` × `[vf.minY, vf.maxY - height]`。
    ///
    /// 这一步是「拖动时不能把课表拖出屏幕」的唯一实现，
    /// 也是「弹窗按课表位置算完之后要夹回屏幕内」用的同一套算法。
    static func clampOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        let maxX = visibleFrame.maxX - size.width
        let maxY = visibleFrame.maxY - size.height
        // 窗口比屏幕还宽 / 高：夹到左上角（至少左上角在屏幕里）。
        let x = maxX < visibleFrame.minX ? visibleFrame.minX
                                         : min(max(origin.x, visibleFrame.minX), maxX)
        let y = maxY < visibleFrame.minY ? visibleFrame.minY
                                         : min(max(origin.y, visibleFrame.minY), maxY)
        return NSPoint(x: x, y: y)
    }

    /// 找出「某块屏幕」—— 按点落在哪块屏判断。
    ///
    /// 多显示器时用**课表所在的那块屏**：先看窗口中心，
    /// 中心不在任何屏上（比如窗口被拖到两块屏之间的缝里）就退回主屏。
    static func screen(forPoint point: NSPoint) -> NSScreen? {
        if let s = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return s }
        if let s = NSScreen.screens.first(where: { $0.visibleFrame.contains(point) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

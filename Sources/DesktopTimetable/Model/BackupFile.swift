import Foundation

/// 备份文件的命名与落盘（课程 / 学期 / 整份课表共用一套）。
///
/// 以前每个存储各写一份 `yyyyMMdd-HHmmss` 的时间戳，**精确到秒**，有两个问题：
///
/// 1. **同一秒连续保存两次 → 文件名重名** → `copyItem` 抛「文件已存在」→ 备份被跳过，
///    而数据照写不误。用户以为有备份，实际没有（数据还是能救回来，但只有一份）。
/// 2. **时区不统一**：`ScheduleStore` 固定 `Asia/Shanghai`，`TimetableStore` 用系统默认时区，
///    同一台机器改过时区就会产生两套命名，排序也乱了。
///
/// 现在统一走这里：时间戳精确到**毫秒** + 固定时区，并且再加一道「重名就加序号」的保险，
/// 保证「同一秒连续保存两次 → 两份备份」这条一定成立。
enum BackupFile {

    /// 备份时间戳（`Asia/Shanghai`，精确到毫秒）。
    ///
    /// 固定时区而不是用系统默认：备份名要在任何机器、任何时区设置下都能按字典序排出时间先后。
    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }

    /// 把 `source` 复制成 `dir/<prefix><stamp><suffix>`。
    ///
    /// 重名时依次尝试 `<prefix><stamp>-2<suffix>`、`<prefix><stamp>-3<suffix>`……
    /// （毫秒时间戳理论上已经不会撞，但系统时钟回拨、或者同一毫秒内的两次保存仍可能撞上，
    /// 不能靠概率。）
    ///
    /// - Returns: 实际写出的文件 URL；失败返回 nil（调用方决定要不要提示用户）。
    @discardableResult
    static func copy(source: URL,
                     into dir: URL,
                     prefix: String,
                     suffix: String,
                     stamp: String = BackupFile.stamp()) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var target = dir.appendingPathComponent("\(prefix)\(stamp)\(suffix)")
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(prefix)\(stamp)-\(n)\(suffix)")
                n += 1
                if n > 1000 { return nil }
            }
            try fm.copyItem(at: source, to: target)
            return target
        } catch {
            NSLog("[DesktopTimetable] 备份失败（%@）：%@", source.lastPathComponent,
                  error.localizedDescription)
            return nil
        }
    }
}

import Foundation

/// 登录项服务状态（与系统 `SMAppServiceStatus` 一一对应，但**可以自己构造**）。
///
/// 为什么要自己定义一套：系统的 `SMAppServiceStatus` 造不出来
/// （没有公开的构造方式），没法在单测里喂各种状态给映射逻辑。
/// 这里用一个小枚举承接系统状态，映射函数就能被完整测到。
enum LoginItemServiceStatus: Equatable {
    /// 已注册并启用。
    case enabled
    /// 未注册。
    case notRegistered
    /// 已注册但等用户在系统设置里批准。
    case requiresApproval
    /// 系统**找不到**这个登录项（app 不在 /Applications，或被位置/签名限制挡住）。
    case notFound
    /// 系统返回了本 app 还不认识的状态。
    case unknown
}

/// 登录项（开机自启）的**状态**。
///
/// 状态以**系统**为准，不往设置文件里存 bool ——
/// 存下来的 bool 会和系统真实状态不一致（用户可以在系统设置里手动关掉）。
enum LoginItemState: Equatable {
    /// 已注册并启用。
    case enabled
    /// 未注册（关闭）。
    case notRegistered
    /// 已注册，但系统等用户批准（「设置 → 通用 → 登录项」里还没允许）。
    case requiresApproval
    /// macOS 12 —— 不支持 `SMAppService`。
    case unsupportedOS
    /// 出错了（真实错误信息要给用户看）。
    case failed(String)

    /// 开关是不是打开的（只有 `.enabled` 算开）。
    var isOn: Bool { self == .enabled }

    /// 界面上显示的一行状态说明。
    ///
    /// **纯函数**，方便单测（系统 API 在测试里是碰不得的）。
    static func describe(_ state: LoginItemState) -> (text: String, detail: String) {
        switch state {
        case .enabled:
            return ("已开启", "登录时自动启动桌面课表")
        case .notRegistered:
            return ("未开启", "开启后，登录 macOS 时会自动启动桌面课表")
        case .requiresApproval:
            return ("等待系统允许",
                    "系统已经记录了这项，但还需要你在「系统设置 → 通用 → 登录项」里允许它")
        case .unsupportedOS:
            return ("不可用", "登录自启需要 macOS 13 或更高版本")
        case .failed(let message):
            return ("开启失败", message)
        }
    }

    /// 「去系统设置允许」按钮该不该显示。
    static func showsApprovalButton(_ state: LoginItemState) -> Bool {
        state == .requiresApproval
    }

    /// 系统状态 → 界面状态（**纯函数**，可单测）。
    ///
    /// `.notFound` 和未知状态**不能**当成「未注册」——
    /// 那样界面会显示「未开启」，用户以为没开，其实系统根本找不到这个 app 的登录项
    /// （常见原因：app 不在 /Applications，或被系统的「位置/签名」限制挡住）。
    /// 这两种情况都映射成 `.failed`（带真实说明），开关回到真实状态（关），
    /// 状态行显示真实错误。
    static func fromServiceStatus(_ status: LoginItemServiceStatus) -> LoginItemState {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .failed("系统找不到这个登录项：应用可能不在「应用程序」文件夹里，"
                           + "或被系统的位置 / 签名限制挡住。")
        case .unknown:
            return .failed("系统返回了未知的登录项状态，无法确认是否已开启。")
        }
    }
}

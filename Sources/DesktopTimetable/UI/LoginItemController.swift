import AppKit

#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// 登录自启（开机自动启动）的控制器。
///
/// - macOS 13+：`SMAppService.mainApp`；
/// - macOS 12：**不支持** —— 开关置灰并说明「需要 macOS 13 或更高版本」。
///   **不用 LaunchAgent / 废弃 API 偷偷顶替**：那两套都有各自的问题
///   （LaunchAgent 要写 plist 到 ~/Library/LaunchAgents，路径一改就失效；
///   废弃 API 在新系统上随时可能被移除），而且用户看不到也管不了。
///
/// 状态一律**以系统为准**，不往设置文件里存 bool ——
/// 用户可以在「系统设置 → 通用 → 登录项」里手动关掉它，
/// 存下来的 bool 迟早和系统不一致。
final class LoginItemController {

    /// macOS 12 上不可用。
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// 登录项状态的**抽象**（测试注入 fake，测试绝不碰真实系统 API）。
    protocol Backend {
        /// 当前状态。
        func currentState() -> LoginItemState
        /// 注册（开启）。失败抛错。
        func register() throws
        /// 注销（关闭）。失败抛错。
        func unregister() throws
    }

    /// 真实后端：`SMAppService.mainApp`。
    final class SystemBackend: Backend {
        func currentState() -> LoginItemState {
            guard LoginItemController.isSupported else { return .unsupportedOS }
            #if canImport(ServiceManagement)
            if #available(macOS 13.0, *) {
                // 状态映射交给 `LoginItemState.fromServiceStatus`（纯函数，可单测）。
                // 以前这里是 `default: return .notRegistered` ——
                // 系统的 `.notFound`（app 不在 /Applications、被位置限制挡住）
                // 和任何未知状态都被静默当成「未注册」，界面显示「未开启」，
                // 用户完全看不出「其实是出问题了」。
                switch SMAppService.mainApp.status {
                case .enabled: return LoginItemState.fromServiceStatus(.enabled)
                case .notRegistered: return LoginItemState.fromServiceStatus(.notRegistered)
                case .requiresApproval: return LoginItemState.fromServiceStatus(.requiresApproval)
                case .notFound: return LoginItemState.fromServiceStatus(.notFound)
                default: return LoginItemState.fromServiceStatus(.unknown)
                }
            }
            #endif
            return .unsupportedOS
        }

        func register() throws {
            guard LoginItemController.isSupported else {
                throw NSError(domain: "DesktopTimetable.loginitem", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "登录自启需要 macOS 13 或更高版本"])
            }
            #if canImport(ServiceManagement)
            if #available(macOS 13.0, *) {
                try SMAppService.mainApp.register()
                return
            }
            #endif
            throw NSError(domain: "DesktopTimetable.loginitem", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "登录自启需要 macOS 13 或更高版本"])
        }

        func unregister() throws {
            guard LoginItemController.isSupported else {
                throw NSError(domain: "DesktopTimetable.loginitem", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "登录自启需要 macOS 13 或更高版本"])
            }
            #if canImport(ServiceManagement)
            if #available(macOS 13.0, *) {
                try SMAppService.mainApp.unregister()
                return
            }
            #endif
            throw NSError(domain: "DesktopTimetable.loginitem", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "登录自启需要 macOS 13 或更高版本"])
        }
    }

    private let backend: Backend
    /// 自动化模式（自检 / 导入 / 离屏渲染 / 测试）下**绝不**注册登录项。
    private let isAutomation: Bool

    init(backend: Backend = SystemBackend(),
         isAutomation: Bool = AutomationMode.isCurrentProcessAutomation) {
        self.backend = backend
        self.isAutomation = isAutomation
    }

    /// 当前状态。
    ///
    /// 自动化模式下**永远**返回 `.unsupportedOS` —— 测试里不能真的注册登录项，
    /// 也不能留下指向 `build/` 的失效登录项。
    func currentState() -> LoginItemState {
        if isAutomation { return .unsupportedOS }
        return backend.currentState()
    }

    /// 切换登录自启。
    ///
    /// 失败**必须让用户看见** —— 不能假装成功。
    /// - Returns: 切换之后的真实状态。
    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemState {
        guard !isAutomation else { return .unsupportedOS }
        guard LoginItemController.isSupported else { return .unsupportedOS }
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
        } catch {
            return .failed(error.localizedDescription)
        }
        return backend.currentState()
    }

    /// 打开「系统设置 → 通用 → 登录项」。
    func openSystemSettings() {
        guard !isAutomation else { return }
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        #endif
        // macOS 12 没有这个 API，退到「登录项」设置面板的通用 URL。
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

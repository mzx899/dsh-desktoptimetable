import AppKit
import WebKit

/// 渲染模式选择：网页直接上屏（模式 B）还是快照贴图（模式 A）。
///
/// 默认走**模式 B**（网页直接上屏，零 takeSnapshot）—— 见下方 WebCardRenderer
/// 顶部关于「桌面层能不能上屏」的实测记录。
///
/// 环境变量：
///   · `DT_SNAPSHOT=1` —— 强制回到快照管线（回退开关，出问题时用）
///   · `DT_LIVE=1`     —— 显式指定模式 B（已经是默认，留着方便做 A/B 对照）
enum RenderMode {
    /// true = 模式 B（网页直接上屏）；false = 模式 A（快照管线）
    static let live: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["DT_SNAPSHOT"] == "1" { return false }
        if env["DT_LIVE"] == "1" { return true }
        return true    // 默认：模式 B
    }()
}

/// 卡片渲染器：用系统 WebKit 加载 App 内置的网页界面（Resources/Timetable.html）。
///
/// 网页层只做展示：
///   · 原生 → 网页：`window.ttUpdate(json)` 推入状态快照
///   · 网页 → 原生：`window.webkit.messageHandlers.tt` 传回用户意图
/// 课程数据、周次、设置等状态一律以原生为准，网页不保存业务状态。
///
/// 关于「网页能不能直接上屏」的实测记录（别再照着旧结论改代码）：
///
/// 旧结论「WKWebView 在桌面层窗口里不会上屏」是**错的**，来源是当年只用
/// `takeSnapshot` 取像素来验证（截屏和快照都没输出 → 误判成「画面是空的」）。
///
/// 现在的实测结论：
///   · level −2147483603 … −2147483500（真正的「桌面图标层」）：确实不渲染。
///   · level −1（普通窗口之下、桌面之上）：**WKWebView 可以正常上屏**。
///     模式 B（DT_LIVE=1）就是这么做的，已验证：零 takeSnapshot，
///     启动到渐显 ~300ms（快照管线 ~800ms），RSS 73MB（快照管线 202MB）。
///
/// 桌面层唯一真正的限制不是「渲染不出来」，而是**遮挡**：
/// layer −1 在所有普通窗口之下，被别的 App 盖住时点击会落到上层 App。
/// 这跟快照方案完全一样，不是 WebView 独有的问题。
///
/// 两套方案互斥，由 `liveMode`（环境变量 DT_LIVE）切换：
///   · 快照管线（默认）：WKWebView 渲染 → takeSnapshot → 桌面层窗口贴图
///   · 模式 B：WKWebView 自己上屏，原生卡片隐藏
final class WebCardRenderer: NSObject {

    /// 实验模式 B：网页直接上屏（DT_LIVE=1），不再取快照。
    ///
    /// 与快照管线互斥：liveMode 为真时 snapshot() 全部变成空操作，
    /// 网页由 WKWebView 自己上屏显示。
    let liveMode: Bool

    /// 实验模式 B：网页 didFinish 之后回调（原生侧用来渐显窗口）。
    var onLiveReady: (() -> Void)?

    /// 实验模式 B：网页没能加载出来时回调，参数是失败原因。
    /// 原生侧收到后会把原生卡片放出来顶替网页（避免亮一个空白窗口）。
    var onLiveFailed: ((String) -> Void)?

    /// 实验模式 B：网页里 `.card` 的实际矩形（CSS px，原点在网页左上角）。
    /// 原生毛玻璃层不能按 `TimetableLayout.cardRect` 铺：CSS 卡片的实际高度
    /// 比它小几个点，按 cardRect 铺会从卡片底部露出一条矩形灰边。
    var onLiveCardFrame: ((NSRect) -> Void)?

    /// 被跳过的快照次数（确认 DT_LIVE 下没有任何 takeSnapshot 调用）
    private(set) var skippedSnapshotCount = 0
    /// 实际调用 takeSnapshot 的次数（A 模式用；B 模式永远是 0）。
    private(set) var realSnapshotCount = 0

    /// 自动化测试用。
    var testRealSnapshotCount: Int { realSnapshotCount }
    var testSkippedSnapshotCount: Int { skippedSnapshotCount }

    /// 自动化测试用：在网页里跑一段 JS，拿回 JSON 字符串。
    func evaluateForTest(_ js: String, completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript(js) { result, error in
            if let error {
                NSLog("[DesktopTimetable] evaluateJavaScript 失败：%@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }

    /// 模式 B 下网页加载失败的原因（nil = 没失败）。
    /// loadPage() 是在 init 里调用的，那时原生还没来得及挂 onLiveFailed，
    /// 所以「资源文件不存在」这种情况只能靠这个属性告诉原生侧。
    private(set) var liveLoadError: String?

    /// 调试用的悬停状态探测定时器
    private var hoverProbeTimer: Timer?
    /// 调试用的**时钟 / 状态条**探测定时器（`DT_CLOCK_PROBE=1`）。
    ///
    /// 排查「卡片顶部的时间不实时」这类问题时用它：每隔几秒把网页里的
    /// 时钟、状态条文字打出来，能一眼看出网页的定时器有没有在跑。
    private var clockProbeTimer: Timer?

    /// 网页发来的用户意图：("week", -1) / ("toggleAllWeeks", nil) / ("openSettings", nil) / ("weekCurrent", nil)
    var onIntent: ((String, Any?) -> Void)?

    /// 快照完成回调（图片尺寸 = 视图尺寸 × 屏幕缩放）
    var onSnapshot: ((NSImage?) -> Void)?

    /// 悬停命中元素发生变化时回调（只在变化时触发，避免频繁快照）
    var onHoverChanged: (() -> Void)?

    private var lastHoverKey = ""

    /// 网页里当前是否还挂着上一次同步过去的 `.tt-hover`。
    /// 指针在卡片外移动时 `syncLiveHover` 每帧都会来清一遍，靠它去重。
    private var liveHoverForwarded = false

    let webView: WKWebView
    /// 脚本消息代理（WKUserContentController 强引用它，必须持有）
    private var messageHandler: ScriptMessageProxy?
    /// 保留 controller 以便销毁时摘掉处理器
    private var userContentController: WKUserContentController?

    private var ready = false
    private var pendingState: String?
    private var snapshotInFlight = false
    /// 已有快照在拍时又来了新请求 —— 记下来，等这一张拍完再补拍。
    /// （原来直接丢弃，导致点击后网页变了但屏幕没更新，看起来就是「点了没反应」）
    private var snapshotPending = false

    init(frame: NSRect) {
        liveMode = RenderMode.live
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // 必须在创建 webView **之前**注册脚本消息处理器：
        // WKWebView 初始化时会把 configuration 复制一份，
        // 事后再往 `webView.configuration.userContentController` 加处理器
        // 等于注册在没人引用的副本上，网页里 `window.webkit.messageHandlers.tt`
        // 根本不存在，点齿轮时 JS 抛异常，设置窗口就永远开不出来。
        //
        // 代理不能用 self 当构造参数（super.init 之前拿不到 self），
        // 所以先建一个空代理挂进 config，init 完成后再把真正的处理逻辑接上。
        let msg = ScriptMessageProxy()
        config.userContentController.add(msg, name: "tt")
        messageHandler = msg
        userContentController = config.userContentController

        // 实验模式 B：往页面注入一个标记，网页据此知道「自己直接上屏」。
        // 必须在创建 webView 之前加（configuration 会被复制一份）。
        if liveMode {
            // DT_LIVE_PROBE=1 时额外注入一个调试标记，网页据此挂事件探针。
            let probe = ProcessInfo.processInfo.environment["DT_LIVE_PROBE"] == "1"
            let src = probe ? "window.__TT_LIVE = true; window.__TT_LIVE_PROBE = true;"
                            : "window.__TT_LIVE = true;"
            let flag = WKUserScript(source: src,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: true)
            config.userContentController.addUserScript(flag)
        }

        webView = WKWebView(frame: frame, configuration: config)
        super.init()
        msg.handler = { [weak self] message in
            self?.handle(message)
        }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")   // 页面背景透明
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        if ProcessInfo.processInfo.environment["DT_NOWEB"] == nil { loadPage() }
    }

    deinit {
        userContentController?.removeScriptMessageHandler(forName: "tt")
    }

    // MARK: - 加载

    /// 实验用：完全不加载网页
    func skipPageLoad() { ready = true }

    /// 页面是否就绪（就绪了才能做命中测试 / 转发事件）。
    var isReady: Bool { ready }

    private func loadPage() {
        guard let url = Bundle.main.url(forResource: "Timetable", withExtension: "html") else {
            NSLog("[DesktopTimetable] 找不到 Resources/Timetable.html，回退到原生绘制")
            if liveMode {
                // 模式 B：没有网页就没有画面，必须通知原生放原生卡片出来
                liveLoadError = "找不到 Resources/Timetable.html"
                onLiveFailed?(liveLoadError!)
            }
            return
        }
        let dir = url.deletingLastPathComponent()
        // 新页面里没有任何 `.tt-hover`，去重状态要跟着归零。
        liveHoverForwarded = false
        webView.loadFileURL(url, allowingReadAccessTo: dir)
        NSLog("[DesktopTimetable] 加载页面：%@", url.path)
    }

    // MARK: - 状态

    /// 把状态推给网页（JSON 字符串）。
    func update(stateJSON: String) {
        guard ready else { pendingState = stateJSON; return }
        // ⚠️ 用 `callAsyncJavaScript` 把 JSON 当**参数**传进去，而不是拼进脚本文本。
        //
        // 以前是 `evaluateJavaScript("window.ttUpdate(<json>)")` —— 实测在
        // 状态推了两次之后，WebKit 会「报成功但根本不执行」（网页里
        // `ttUpdate` 的调用计数不涨），换成带参数的调用后稳定。
        webView.callAsyncJavaScript("window.ttUpdate(json)",
                                    arguments: ["json": stateJSON],
                                    in: nil,
                                    in: .page) { [weak self] result in
            if case .failure(let error) = result {
                NSLog("[DesktopTimetable] 推状态失败：%@", error.localizedDescription)
            }
            self?.reportLiveCardFrame()
        }
    }

    /// 让网页**立刻**刷新一次顶部时钟 / 日期 / 状态条（不等它自己的定时器）。
    ///
    /// ⚠️ **为什么需要**（2026-11-11 修「刚打开显示屏时，时间晚了 1 分钟、
    /// 也没显示『正在上课』」）：
    /// 网页靠 `setInterval(updateLiveTexts, 10000)` 自己走表。
    /// 但**显示器睡着时 WebKit 会挂起页面的定时器** —— 醒来后那个
    /// `setInterval` 要等下一个 10 秒档才恢复，中途这段时间里
    /// 卡片顶部的时钟 / 状态条是**睡着前那一帧的旧值**。
    /// 用户「刚打开显示屏」看到的就是那个旧值（时间落后、正在上课没显示）。
    ///
    /// 这里在唤醒时主动叫醒它一次 —— 纯显示刷新，不重建 DOM。
    func tickClockNow() {
        guard ready else { return }
        webView.evaluateJavaScript("if (window.__ttUpdateClock) window.__ttUpdateClock();")
    }

    /// 实验模式 B：网页里 `.card` 的**布局矩形**（CSS px，原点在网页左上角，
    /// 不含缩放），最近一次量到的值。
    ///
    /// 缩放时毛玻璃层要跟着卡片走，但**不能每帧都去网页里量一次**
    /// （跨进程 JS 往返是拖动卡顿的主要来源之一）。
    /// 这里把「卡片在网页版式里的矩形」缓存下来，缩放时原生自己乘系数即可：
    ///   `视觉矩形 = 布局矩形 × viewScale`
    private(set) var lastCardLayoutRect: NSRect?

    /// 最近一次写到网页里的 body translate（CSS px）与它的坐标系。
    ///
    /// `cssPoint` 要把「视觉坐标」还原成「页面坐标」，必须先减掉这段平移，
    /// 否则点击会整体偏 (74, 61.5) pt（点箭头点到卡片上）。
    ///   · `bodyTranslateIsPreZoom = true`（pageZoom 档）：视觉 = (页面 + translate) × 缩放
    ///   · `false`（transform 档）：视觉 = 页面 × 缩放 + translate
    private var bodyTranslate: (CGFloat, CGFloat) = (0, 0)
    private var bodyTranslateIsPreZoom = true

    /// 按当前缩放算出毛玻璃层应该在**容器坐标系**（左下原点）里的矩形。
    ///
    /// - Parameter containerHeight: 容器（窗口 contentView）当前高度（view pt）。
    /// - Returns: 没有量到过网页矩形时返回 nil。
    func cardFrameForCurrentScale(containerHeight: CGFloat) -> NSRect? {
        guard let r = lastCardLayoutRect else { return nil }
        let s = viewScale
        return NSRect(x: r.minX * s,
                      y: containerHeight - r.maxY * s,
                      width: r.width * s,
                      height: r.height * s)
    }

    /// 按当前缩放算出**网页卡片中心**在容器坐标系里的位置。
    ///
    /// 缩放锚点要用它，而不是原生 `TimetableLayout.cardRect` 的中心 ——
    /// 原生矩形是按整数点取整的（窗口尺寸只能整数），它的中心会随缩放
    /// 在 ±0.5pt 内跳；网页卡片是严格按 `scale` 连续的，
    /// 拿整数的原生中心当锚点，用户会看到卡片在拖动缩放时轻微抖动。
    func cardCenterInWindow(containerHeight: CGFloat) -> NSPoint? {
        guard let r = lastCardLayoutRect else { return nil }
        let s = viewScale
        return NSPoint(x: r.midX * s,
                       y: containerHeight - r.midY * s)
    }

    /// 量出 `.card` 的实际矩形并回调原生。
    ///
    /// 每次推完状态量一次：卡片高度在「本周/非本周」等状态下可能变化，
    /// 毛玻璃必须跟着卡片走，不能留下底部那条裸玻璃边。
    ///
    /// ⚠️ **缩放后必须再量一次**（2026-11 加）：
    /// 缩放不会推状态（状态没变），但毛玻璃层的尺寸**依赖网页里的 `.card` 矩形**——
    /// 不重新量的话，玻璃层还停留在旧尺寸上，
    /// 表现是「卡片缩小后毛玻璃还是大的 / 放大后毛玻璃短了一截，
    /// 底部课程格子露在玻璃外面」。
    func reportLiveCardFrameNow() {
        reportLiveCardFrame()
    }

    private func reportLiveCardFrame() {
        guard liveMode, onLiveCardFrame != nil else { return }
        let js = """
        (function () {
          var el = document.querySelector('.card');
          if (!el) return '';
          var r = el.getBoundingClientRect();
          return JSON.stringify([r.x, r.y, r.width, r.height]);
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self,
                  let raw = value as? String,
                  let data = raw.data(using: .utf8),
                  let rect = try? JSONSerialization.jsonObject(with: data) as? [Double],
                  rect.count == 4 else { return }
            // `getBoundingClientRect` 在两种缩放方式下的语义**不一样**：
            //   · pageZoom 档位：返回 CSS px（版式坐标），乘 viewScale 才是 view 点；
            //   · CSS transform 档位：返回的已经是乘过 transform 的视觉坐标。
            let toView = self.rectScale
            let viewRect = NSRect(x: rect[0] * toView, y: rect[1] * toView,
                                  width: rect[2] * toView, height: rect[3] * toView)
            // 缓存「布局矩形」：与缩放无关，原生缩放时直接乘系数。
            let layoutDivisor = self.usesPageZoom ? 1.0 : self.viewScale
            self.lastCardLayoutRect = NSRect(x: rect[0] / layoutDivisor,
                                             y: rect[1] / layoutDivisor,
                                             width: rect[2] / layoutDivisor,
                                             height: rect[3] / layoutDivisor)
            self.onLiveCardFrame?(viewRect)
        }
    }

    // MARK: - 快照

    /// 把当前页面渲成图片。
    ///
    /// 桌面层窗口里的 WKWebView 拍一张要几百毫秒，这期间再来请求不能丢 ——
    /// 丢了就等于「点击后画面不更新」。所以这里合并请求：
    /// 正在拍就记一个 pending，拍完再补拍一张。
    func snapshot(completion: ((NSImage?) -> Void)? = nil) {
        // 实验模式 B：网页直接上屏，一个快照都不许拍。
        if liveMode {
            skippedSnapshotCount += 1
            NSLog("[TT-LIVE] 跳过 takeSnapshot（模式 B 直接上屏），累计跳过 %d 次",
                  skippedSnapshotCount)
            completion?(nil)
            return
        }
        guard ready else {
            if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                NSLog("[DesktopTimetable] 快照跳过：页面还没就绪")
            }
            completion?(nil)
            return
        }
        if snapshotInFlight {
            snapshotPending = true
            completion?(nil)
            return
        }
        snapshotInFlight = true
        realSnapshotCount += 1
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        cfg.afterScreenUpdates = true
        webView.takeSnapshot(with: cfg) { [weak self] image, error in
            guard let self else { return }
            self.snapshotInFlight = false
            if let error, ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                NSLog("[DesktopTimetable] 快照失败：\(error.localizedDescription)")
            }
            self.onSnapshot?(image)
            completion?(image)
            // 拍的过程中来的请求，补拍一张最新的
            if self.snapshotPending {
                self.snapshotPending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.snapshot()
                }
            }
        }
    }

    // MARK: - 事件转发

    /// 当前的**视觉缩放系数**（0.7–1.15，1.0 = 原始尺寸）。
    ///
    /// ⚠️ 实际是怎么缩的见 `applyScale(_:)` —— 两个档位用两种手段，
    /// 但「1 个布局 CSS px 在屏幕上占多少个 view 点」永远等于它。
    private(set) var viewScale: CGFloat = 1.0

    /// 缩小档位是否用 CSS `transform` 而不是 `pageZoom`。
    ///
    /// **为什么必须分开**（2026-11 实测）：
    /// `WKWebView.pageZoom < 1` 时 WebKit 会把**小字号**按「最小逻辑字号 9pt」
    /// 撑大 —— 实测 0.7 档 `.wkdate` 9.5px 变成 12.86px、顶栏从 55 变成 63.3，
    /// 整张卡片因此变高 9.5px（比例已经不是等比了）。
    ///
    /// 缩小档位改用 `body { transform: scale(s) }`：不重排版式，
    /// 小字号严格按比例缩、卡片高度严格 ×s。
    ///
    /// 放大档（≥ 100%）用 `pageZoom`：那一侧没有最小字号限制，文字最清晰。
    private var usesPageZoom: Bool { viewScale >= 1.0 }

    /// 网页 CSS px 在屏幕上占多少 view 点（**view 坐标 → 网页坐标要除以它**）。
    ///
    /// - pageZoom 档位：= `viewScale`（CSS 视口 = 窗口 / pageZoom）；
    /// - transform 档位：= 1（视口就是窗口，layout 坐标已由 CSS 缩放视觉化）。
    var pageZoomFactor: CGFloat { usesPageZoom ? viewScale : 1.0 }

    /// `getBoundingClientRect()` 量出来的数字 × 它 = **view 点**。
    ///
    /// - pageZoom 档位：= `viewScale`（返回 CSS px）；
    /// - transform 档位：= 1（返回值已经乘过 transform）。
    var rectScale: CGFloat { usesPageZoom ? viewScale : 1.0 }

    /// 网页里卡片在**版式坐标**里的高度（CSS px，与缩放无关）。
    static let webCardCSSHeight: CGFloat = 773
    /// 折叠时收掉的版式高度（CSS px）：网格 10 行 + 间距。
    static let collapseBodyCSSHeight: CGFloat = 600

    /// 当前折叠进度（0 = 展开，1 = 收起）。
    ///
    /// AppDelegate 每动画帧调 `setCollapse(_:)` 写进来；
    /// 只用来算「当前卡片中心」，不参与缩放档位。
    private(set) var collapseProgress: CGFloat = 0

    /// 把折叠进度写进网页（`window.ttSetCollapse(p)`）。
    ///
    /// 网页侧只改网格裁切容器的高度 + 一个 CSS 变量（body 行淡出），
    /// 原生侧的毛玻璃 / 穿透 / 悬停由 AppDelegate 用同一个 p 算 —— 两边同步。
    func setCollapse(_ progress: CGFloat) {
        collapseProgress = max(0, min(1, progress))
        guard ready else { return }
        webView.evaluateJavaScript("window.ttSetCollapse(\(collapseProgress));",
                                   completionHandler: nil)
    }

    /// 当前**窗口内容区高度**（view pt）。
    ///
    /// `cssPoint` 翻 y 要用它，不能用 `webView.bounds.height`：
    /// 缩小档位 webView 的 frame 是版式尺寸（962），而窗口是 962×scale。
    private(set) var viewportHeight: CGFloat = 0

    /// 原生层（`AppDelegate.webHost`）每次重排窗口后告诉网页层新的视口高度。
    func setViewportHeight(_ h: CGFloat) {
        viewportHeight = h
    }

    /// 页面还没就绪时先记住缩放值，`didFinish` 之后再套上去。
    private var pendingScale: CGFloat?

    /// 设置缩放（整体等比）。
    ///
    /// 口径：
    ///   · **≥ 100%** → `pageZoom`。实测语义（`docs/spike-pagezoom-结论.md`）：
    ///     CSS 视口 = 窗口 / pageZoom，1 CSS px = pageZoom 个 view 点，
    ///     版式完全不变 —— 文字按真实分辨率排版，最清晰。
    ///   · **< 100%** → `body { transform: scale(s) }`。
    ///     `pageZoom` 在缩小档位会触发 WebKit 的「最小逻辑字号 9pt」，
    ///     小字被撑大、卡片变高（比例破掉）；transform 不重排版式，
    ///     卡片尺寸严格 ×s。
    ///
    /// 无论哪个档位，`webView.frame` 都要铺满缩放后的窗口
    /// （见 `AppDelegate.performCardScale`）。
    func applyScale(_ scale: CGFloat) {
        let s = max(0.1, scale)
        viewScale = s
        guard ready else { pendingScale = s; return }
        applyScaleToPage()
    }

    /// **拖动中的一帧**：强制用 CSS transform 缩放（pageZoom = 1），
    /// 并在网页真正应用之后回调原生。
    ///
    /// ⚠️ 为什么拖动期间不直接 `applyScale`（2026-11 第二次修抖动）：
    /// `pageZoom` / CSS transform 都是跨进程异步的，而窗口尺寸 / 位置是
    /// 主线程同步改的 —— 先改窗口、后改网页时，可见卡片会按
    /// 「574 × Δscale」跳一下（快速拖动时 Δscale 大，跳得很明显）。
    /// 现在原生等**网页应用完**这一帧的缩放，再在同一个回调里对齐窗口：
    /// 窗口和网页永远对应同一个 scale，卡片中心不会因为异步而错位。
    ///
    /// 缩小档位本来就用 CSS transform；放大档位拖动期间也先用 transform
    /// （由合成器放大，略软），松手时 `applyScale` 再切回 pageZoom（清晰）。
    /// - Parameters:
    ///   - scale: 视觉缩放。
    ///   - translateX/Y: 亚像素补偿（见 `AppDelegate.applyNextDragFrame` 的推导）。
    ///     窗口位置只能落在整点上，卡片中心想严丝合缝地钉在锚点上，
    ///     就必须把「窗口取整后的零头」用 transform 的 translate 补回去。
    func applyDragScale(_ scale: CGFloat,
                        translateX: CGFloat,
                        translateY: CGFloat,
                        completion: @escaping () -> Void) {
        let s = max(0.1, scale)
        viewScale = s
        bodyTranslate = (translateX, translateY)
        bodyTranslateIsPreZoom = false
        guard ready else { pendingScale = s; completion(); return }
        webView.pageZoom = 1
        let js = """
        document.body.style.transform = 'translate(\(translateX)px, \(translateY)px) scale(\(s))';
        document.body.style.transformOrigin = '0 0';
        window.__ttGeomScale = 1;
        """
        // 回调必须**一定会来**（否则 App 侧会一直以为这一帧还在飞）。
        // WebKit 偶尔会在窗口/视口刚变化时把回调拖很久 —— 这里记错误，
        // 超时兜底由 AppDelegate 的 watchdog 负责重发。
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("[TT-SCALE] 应用拖动缩放失败：%@", error.localizedDescription)
            }
            completion()
        }
    }

    /// 松手收尾：把「拖动用的 transform 缩放」换成正式档位，
    /// 并**保持卡片在窗口里的可见中心不变**。
    ///
    /// ⚠️ 为什么必须收尾（2026-11 修「放大后整张课表发糊」）：
    /// 拖动帧为了和窗口同步，用的是 `body { transform: scale }` ——
    /// 合成器把已经画好的位图放大，字是糊的。停在那个状态时
    /// `viewScale` 却已经是 1.12（`usesPageZoom` 按它判断成「走 pageZoom」），
    /// 于是 `rectScale` / 玻璃 / 命中换算全都会**多乘一个缩放系数**，
    /// 松手后卡片中心和玻璃直接偏几十磅。
    ///
    /// 所以松手一帧要做两件事：
    ///   1. ≥100% 用 `pageZoom`（文字按目标尺寸重新排版，清晰）；
    ///   2. translate 按**当前可见中心**算，而不是画布中心 ——
    ///      拖动帧把卡片摆在「窗口中心 = 卡片中心」的位置，松手时按
    ///      画布中心重摆会丢掉亚像素零头、还会让卡片跳一下。
    ///
    /// - Parameters:
    ///   - scale: 目标视觉缩放。
    ///   - center: 卡片中心在**容器坐标系**（左下原点）里的位置。
    func applyScale(_ scale: CGFloat, keepingCardCenter center: NSPoint) {
        let s = max(0.1, scale)
        viewScale = s
        guard ready else { pendingScale = s; return }
        let h = viewportHeight > 0 ? viewportHeight : webView.bounds.height
        let cssCenter = cardCenterInPage
        if usesPageZoom {
            webView.pageZoom = s
            // pageZoom 下：视觉坐标 = pageZoom × (translate + CSS 坐标)。
            let tx = center.x / s - cssCenter.x
            // 网页坐标 y 向下：容器里的中心先翻成「距顶部」再除缩放。
            let ty = (h - center.y) / s - cssCenter.y
            bodyTranslate = (tx, ty)
            bodyTranslateIsPreZoom = true
            webView.evaluateJavaScript("""
            document.body.style.transform = 'translate(\(tx)px, \(ty)px)';
            document.body.style.transformOrigin = '0 0';
            window.__ttGeomScale = 1;
            """, completionHandler: nil)
        } else {
            webView.pageZoom = 1
            // transform 档：视觉坐标 = translate + scale × CSS 坐标。
            let tx = center.x - cssCenter.x * s
            let ty = (h - center.y) - cssCenter.y * s
            bodyTranslate = (tx, ty)
            bodyTranslateIsPreZoom = false
            webView.evaluateJavaScript("""
            document.body.style.transform = 'translate(\(tx)px, \(ty)px) scale(\(s))';
            document.body.style.transformOrigin = '0 0';
            window.__ttGeomScale = \(s);
            """, completionHandler: nil)
        }
    }

    /// 网页里 `.card` 的**展开态**中心（CSS px，原点在页面左上角）。
    ///
    /// `.ttwrap` 的版式是 `padding: 90px` + 卡片 968×773，
    /// 所以中心 = (90 + 484, 90 + 386.5) = (574, 476.5)。
    ///
    /// ⚠️ 常驻画布的「居中 translate」必须一直用这个**展开态**中心：
    /// 折叠时卡片顶边要保持不动，而顶边 = translate + 90 ——
    /// 用展开中心算 translate，卡片变矮时顶边就不会动（从底部收上去）。
    static let expandedCardCenterInPage = NSPoint(x: 574, y: 476.5)

    /// 当前卡片在网页版式里的中心（CSS px，原点在页面左上角）。
    ///
    /// 折叠时卡片高度变小、顶边不动（页面 y = 90），中心跟着上移：
    /// 展开 476.5 → 收起 `90 + 173/2 = 176.5`。
    /// 拖动帧 / 松手对位要按**当前**中心算，否则折叠态下卡片会被摆低一截。
    var cardCenterInPage: NSPoint {
        let cssHeight = Self.webCardCSSHeight - Self.collapseBodyCSSHeight * collapseProgress
        return NSPoint(x: 574, y: 90 + cssHeight / 2)
    }

    /// 真正把缩放写进网页（`applyScale` 的后端；页面就绪后才能调）。
    private func applyScaleToPage() {
        let s = viewScale
        let (tx, ty) = canvasCenterTranslate(scale: s)
        bodyTranslate = (tx, ty)
        bodyTranslateIsPreZoom = usesPageZoom
        if usesPageZoom {
            webView.pageZoom = s
            // 常驻画布：页面原点在画布左上角，卡片必须用 translate 摆到画布中心。
            // pageZoom 下 translate 是 CSS px，视觉位移 = pageZoom × translate。
            webView.evaluateJavaScript("""
            document.body.style.transform = 'translate(\(tx)px, \(ty)px)';
            document.body.style.transformOrigin = '0 0';
            window.__ttGeomScale = 1;
            """, completionHandler: nil)
        } else {
            webView.pageZoom = 1
            // 纯视觉缩放：版式尺寸 / 字体大小一个都不改；
            // translate 负责「把卡片放到画布中心」，scale 负责缩放。
            webView.evaluateJavaScript("""
            document.body.style.transform = 'translate(\(tx)px, \(ty)px) scale(\(s))';
            document.body.style.transformOrigin = '0 0';
            window.__ttGeomScale = \(s);
            """, completionHandler: nil)
        }
    }

    /// 让网页卡片中心落在 webView（常驻画布）中心所需的 translate。
    ///
    /// 网页里的卡片是固定写在 `left:90, top:90, width:968, height:773` 上的
    /// （`.ttwrap` 的版式），所以卡片中心 = (574, 476.5) CSS px。
    /// - pageZoom 档：translate 是 CSS px，目标视觉中心 = webView 中心；
    /// - CSS transform 档：translate 和 scale 同属 body，视觉 = translate + scale×css。
    func canvasCenterTranslate(scale s: CGFloat) -> (CGFloat, CGFloat) {
        let W = webView.bounds.width
        let H = webView.bounds.height
        guard W > 0, H > 0 else { return (0, 0) }
        let cx = W / 2
        let cy = H / 2
        // 用**展开态**中心：折叠时卡片顶边保持不动（见 expandedCardCenterInPage）。
        let css = Self.expandedCardCenterInPage
        if usesPageZoom || s >= 1.0 {
            return (cx / s - css.x, cy / s - css.y)
        }
        return (cx - css.x * s, cy - css.y * s)
    }

    /// 把 AppKit 坐标（y 向上，原点左下）转成网页坐标（y 向下，原点左上）。
    ///
    /// 这一步不做的话，点击会垂直镜像：点到「周三下午」实际会命中「周一上午」。
    /// 卡片视图和 WKWebView 都挂在同一个 container 上、原点重合，
    /// 所以只需要翻转 y。
    ///
    /// ⚠️ **y 的翻转要用「窗口」高度**（`viewportHeight`），不能用 `webView.bounds.height`：
    /// 缩小档位 webView 的 frame 是版式尺寸（962），窗口却是 962×scale。
    ///
    /// 不除就会点偏（点到隔壁那一格）；用错高度则整列纵向偏移。
    private func cssPoint(_ point: NSPoint) -> NSPoint {
        let s = pageZoomFactor
        let h = viewportHeight > 0 ? viewportHeight : webView.bounds.height
        return NSPoint(x: point.x / s,
                       y: (h - point.y) / s)
    }

    /// 自检用：把窗口坐标换算成网页坐标（验命中换算用）。
    func testCSSPoint(_ point: NSPoint) -> NSPoint {
        cssPoint(point)
    }

    /// 自检用：当前视觉缩放系数。
    var testViewScale: CGFloat { viewScale }

    /// 自检用：`getBoundingClientRect()` 数字 → view 点 的倍率。
    var testRectScale: CGFloat { rectScale }

    /// 自检用：最近一次 body translate 与坐标系（见 `bodyTranslate`）。
    var testBodyTranslate: (CGFloat, CGFloat) { bodyTranslate }
    var testBodyTranslateIsPreZoom: Bool { bodyTranslateIsPreZoom }

    /// 自检用：当前是不是 pageZoom 档位（≥ 100%）。
    var testUsesPageZoom: Bool { usesPageZoom }

    /// A 模式的命中测试：问网页「这个点命中了哪个格子」。
    ///
    /// A 模式屏幕上贴的就是网页快照，命中必须以网页 DOM 为准。
    /// 原生另算一套几何（TimetableLayout）和网页实际布局差了 7px，
    /// 会点出「屏幕上这节课、菜单却是隔壁那节」的问题。
    ///
    /// 返回 (day, block, courseID)。
    func hitTestInWeb(at point: NSPoint, completion: @escaping (Int?, Int?, String?) -> Void) {
        let css = cssPoint(point)
        let js = """
        (function () {
          if (!window.ttHitTest) return null;
          return window.ttHitTest(\(css.x), \(css.y));
        })();
        """
        webView.evaluateJavaScript(js) { value, _ in
            guard let dict = value as? [String: Any] else {
                completion(nil, nil, nil)
                return
            }
            let day = (dict["day"] as? NSNumber)?.intValue
            let block = (dict["block"] as? NSNumber)?.intValue
            let cid = dict["courseID"] as? String
            completion(day, block, (cid?.isEmpty ?? true) ? nil : cid)
        }
    }

    /// 转发一次点击：命中哪个元素就点哪个元素。
    func forwardClick(at point: NSPoint) {
        let point = cssPoint(point)
        let js = """
        (function () {
          var el = document.elementFromPoint(\(point.x), \(point.y));
          if (!el) return 'none:@\(point.x),\(point.y)';
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: \(point.x), clientY: \(point.y) };
          ['pointerover','mouseover','mousemove'].forEach(function (t) {
            el.dispatchEvent(new MouseEvent(t, opts));
          });
          // 不能用 el.click()：命中元素可能是 SVG 路径（齿轮的图标），
          // SVGElement 没有 click 方法，一调就抛 TypeError，
          // 事件根本到不了按钮自己身上。统一用 dispatchEvent 派发。
          el.dispatchEvent(new MouseEvent('click', opts));
          return (el.className || el.tagName) + '|' + (el.textContent || '').slice(0, 12);
        })();
        """
        webView.evaluateJavaScript(js) { value, error in
            if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                NSLog("[DesktopTimetable] 转发点击 -> %@ err=%@", String(describing: value),
                      error.map { "\($0.localizedDescription) | \($0)" } ?? "nil")
            }
        }
    }

    /// 把图钉的两张图（空心 / 实心，PNG base64）注入网页。
    ///
    /// 视觉由网页画（和标题同一个 DOM），原生那边只留透明点击热区 ——
    /// 这样缩放时图钉和标题走同一条流水线，不会差一帧。
    func setPinImages(hollow: String, solid: String) {
        pinImages = (hollow, solid)
        pushPinImages()
    }

    /// 同步「固定状态」给网页里的图钉（换空心 / 实心）。
    func setPinned(_ pinned: Bool) {
        pinPinnedState = pinned
        pushPinState()
    }

    /// 图钉两态图片（页面还没就绪时先记住，`didFinish` 再注入）。
    private var pinImages: (hollow: String, solid: String)?
    private var pinPinnedState = false

    private func pushPinImages() {
        guard ready, let imgs = pinImages else { return }
        webView.evaluateJavaScript(
            "if (window.ttSetPinImages) window.ttSetPinImages('\(imgs.hollow)', '\(imgs.solid)');",
            completionHandler: nil)
    }

    private func pushPinState() {
        guard ready else { return }
        webView.evaluateJavaScript(
            "if (window.ttSetPinned) window.ttSetPinned(\(pinPinnedState));",
            completionHandler: nil)
    }

    /// 转发一次**右键**（`contextmenu`）。
    ///
    /// 交互层盖在 webView 上，右键先被它接走 → 这里合成一个
    /// `contextmenu` 事件派发到命中元素上（网页里是捕获阶段监听，
    /// 待办 → 弹原生菜单；课程格 → 课程右键菜单）。
    func forwardContextMenu(at point: NSPoint) {
        let p = cssPoint(point)
        let js = """
        (function () {
          var el = document.elementFromPoint(\(p.x), \(p.y));
          if (!el) return 'none';
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: \(p.x), clientY: \(p.y), button: 2, buttons: 2 };
          el.dispatchEvent(new MouseEvent('contextmenu', opts));
          return (el.className || el.tagName);
        })();
        """
        webView.evaluateJavaScript(js) { value, error in
            if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                NSLog("[DesktopTimetable] 转发右键 -> %@ err=%@", String(describing: value),
                      error.map { "\($0.localizedDescription)" } ?? "nil")
            }
        }
    }

    /// 让网页展开某门课的详情浮层（B 模式的「查看详情」用）。
    func selectCourse(day: Int, block: Int, courseID: String) {
        let js = "window.ttSelectCourse ? window.ttSelectCourse(\(day), \(block), '\(courseID)') : false;"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 转发一次悬停（只影响 :hover 样式，不触发点击）。
    /// 命中元素变了才通知原生重拍快照 —— 鼠标移动本身不会引起重绘。
    func forwardHover(at point: NSPoint) {
        let point = cssPoint(point)
        let js = """
        (function () {
          var el = document.elementFromPoint(\(point.x), \(point.y));
          if (!el) return '';
          ['pointerover','mouseover','mousemove'].forEach(function (t) {
            el.dispatchEvent(new MouseEvent(t, { bubbles: true, clientX: \(point.x), clientY: \(point.y) }));
          });
          var idx = el.dataset && el.dataset.ci ? el.dataset.ci : '';
          return (el.className || el.tagName) + '#' + idx;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self else { return }
            let key = (value as? String) ?? ""
            guard key != self.lastHoverKey else { return }
            self.lastHoverKey = key
            self.onHoverChanged?()
        }
    }

    // MARK: - 实验模式 B：悬停同步

    /// 把指针位置（窗口坐标）同步给网页（实验性方案）。
    ///
    /// 桌面层窗口不是 key window，网页收不到 mouseMoved，
    /// CSS 的 :hover 伪类不会触发。这里改成由原生主动把位置送进去，
    /// 网页侧用 `.tt-hover` 类模拟悬停态。
    func forwardLiveHover(at windowPoint: NSPoint) {
        liveHoverForwarded = true
        let p = cssPoint(windowPoint)
        let js = "if (window.ttLiveHover) window.ttLiveHover(\(p.x), \(p.y));"
        webView.evaluateJavaScript(js) { _, error in
            guard let error else { return }
            if ProcessInfo.processInfo.environment["DT_DEBUG_INPUT"] != nil {
                NSLog("[TT-LIVE] 悬停同步失败：%@", error.localizedDescription)
            }
        }
    }

    /// 指针移出卡片：清掉网页里的悬停态。
    ///
    /// ⚠️ 只在**上次确实同步过悬停**时才发 JS：全局鼠标监控在指针位于
    /// 卡片外时也会每帧调到这里，以前每次都无条件 evaluateJavaScript，
    /// 等于鼠标在桌面任何地方移动都在往 WebContent 发跨进程消息 ——
    /// 实测这是主进程空转 CPU 的一部分。网页里本来就没挂 `.tt-hover`
    /// 的话，这条消息不做任何事，直接跳过。
    func clearLiveHover() {
        guard liveHoverForwarded else { return }
        liveHoverForwarded = false
        webView.evaluateJavaScript("if (window.ttLiveHoverClear) window.ttLiveHoverClear();")
    }

    // MARK: - 文本输入（网页里的 <input>）

    /// 网页里的输入框有没有正在编辑。
    ///
    /// ⚠️ 桌面层窗口是 **`.nonactivatingPanel`**（`DesktopWindow` 的 styleMask），
    /// 这种窗口**永远拿不到 key**，于是 WKWebView 也就**永远拿不到键盘焦点** ——
    /// 网页里的 `<input>` 能显示、能点开，但**打不进字**。
    ///
    /// 解决办法：输入框获得焦点时，网页发 `textInputFocus` 给原生；
    /// 原生临时把 App 激活、把窗口变成 key（`canBecomeKey` 打开），
    /// 键盘输入就能进网页了。输入结束（失焦 / 回车 / Esc）再还原。
    private(set) var textInputActive = false

    /// 文本输入模式变化时回调（原生用它切窗口的 key 能力 / 激活 App）。
    var onTextInputModeChanged: ((Bool) -> Void)?

    /// 网页请求进入 / 退出文本输入模式。
    func setTextInputMode(_ active: Bool) {
        guard active != textInputActive else { return }
        textInputActive = active
        onTextInputModeChanged?(active)
    }

    /// 自检用：现在是不是「文本输入模式」（网页里的输入框正在编辑）。
    var testTextInputActive: Bool { textInputActive }

    /// 调试用（DT_LIVE_PROBE=1）：把网页里关键元素的位置量出来并打日志，
    /// 方便外部脚本按坐标点击。
    ///
    /// ⚠️ 报的是 **view 点**（矩形 × `rectScale`）——
    /// 外部脚本要用它发真实的鼠标事件，事件坐标是 view 坐标系的。
    /// `rectScale` 在 pageZoom 档位 = 缩放系数，在 transform 档位 = 1
    /// （`getBoundingClientRect` 已经返回视觉坐标）。
    func probeElements() {
        let js = """
        (function () {
          var S = \(self.rectScale);
          function r(sel) {
            var el = document.querySelector(sel);
            if (!el) return sel + '=null';
            var b = el.getBoundingClientRect();
            return sel + '=' + [b.left * S, b.top * S, b.width * S, b.height * S].map(function (v) {
              return Math.round(v);
            }).join(',');
          }
          var out = [r('.setbtn'), r('.arrow'), r('.wkchip'), r('.nowbtn'),
                     r('.card'), r('.top'), r('.brand'), r('.ttl')].join(' | ');
          // 所有课程格：真实鼠标测试时要挑「屏幕上没被别的窗口盖住」的那一格
          var cs = document.querySelectorAll('.course');
          var list = [];
          for (var i = 0; i < cs.length; i++) {
            var b = cs[i].getBoundingClientRect();
            list.push(i + ':' + Math.round(b.left * S) + ',' + Math.round(b.top * S));
          }
          out += ' | courses=' + list.join(' ');
          out += ' | win=' + window.innerWidth + 'x' + window.innerHeight;
          out += ' | scale=' + S;
          return out;
        })();
        """
        webView.evaluateJavaScript(js) { value, error in
            NSLog("[TT-LIVE-PROBE] %@ err=%@", String(describing: value),
                  error.map { $0.localizedDescription } ?? "nil")
        }
    }

    /// 调试用（DT_CLOCK_PROBE=1）：每隔几秒把网页里的时钟 / 状态条文字打出来，
    /// 用来确认「网页自己走表」的定时器到底有没有在跑。
    func startClockProbe() {
        let js = """
        (function () {
          var tn = document.querySelector('.clock .tnum');
          var st = document.querySelector('.status .stxt');
          var sm = document.querySelector('.status .smeta');
          return 'clock=' + (tn ? tn.textContent.trim() : 'null')
            + ' | stxt=' + (st ? st.textContent.trim() : 'null')
            + ' | smeta=' + (sm ? sm.textContent.trim() : 'null')
            + ' | timer=' + (window.__ttClockTimer === true)
            + ' | bootErr=' + (window.__ttBootError || 'none')
            + ' | hidden=' + document.hidden
            + ' | vis=' + document.visibilityState
            + ' | now=' + new Date().toTimeString().slice(0,5);
        })();
        """
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.webView.evaluateJavaScript(js) { value, _ in
                NSLog("[TT-CLOCK-PROBE] %@", String(describing: value))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockProbeTimer = timer
    }

    /// 调试用（DT_LIVE_PROBE=1）：定期把网页的悬停状态打出来，
    /// 用来确认真实鼠标移动时网页到底收到了什么。
    func startHoverProbe() {
        let js = """
        (function () {
          var cs = document.querySelectorAll(':hover');
          var names = [];
          for (var i = 0; i < cs.length; i++) names.push(cs[i].className || cs[i].tagName);
          var tt = document.querySelectorAll('.tt-hover');
          var ttn = [];
          for (var j = 0; j < tt.length; j++) ttn.push(tt[j].className);
          var ovl = document.querySelector('.ovl');
          var sel = !!(window.ttHasSelection && window.ttHasSelection());
          var at = document.elementFromPoint(window.innerWidth/2, 40);
          var log = (window.__ttEventLog || []).slice(-6).join(' ; ');
          return ':hover=[' + names.join(',') + '] tt-hover=[' + ttn.join(',') + ']'
            + ' sel=' + sel + ' ovl=' + (ovl ? 'yes' : 'no')
            + ' topAt=' + (at ? (at.className || at.tagName) : 'null')
            + ' EV[' + log + ']';
        })();
        """
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.webView.evaluateJavaScript(js) { value, _ in
                NSLog("[TT-LIVE-HOVER] %@", String(describing: value))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverProbeTimer = timer
    }

    /// 网页里有没有展开着详情面板。
    func hasSelection(completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("window.ttHasSelection ? window.ttHasSelection() : false") { value, _ in
            completion((value as? Bool) ?? false)
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebCardRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        NSLog("[DesktopTimetable] 网页加载完成")
        // 启动时配置里存过缩放（≠100%）：applyScale 那时页面还没就绪，
        // 先记在 pendingScale 里，这里补上（顺序在推状态之前）。
        if pendingScale != nil {
            pendingScale = nil
            applyScaleToPage()
        }
        // 图钉图片 / 固定状态：页面就绪后才能注入（这里补一次）。
        pushPinImages()
        pushPinState()
        if let pendingState {
            self.pendingState = nil
            update(stateJSON: pendingState)
        }
        if liveMode {
            // 模式 B：不等快照，直接通知原生「网页可以上屏了」
            onLiveReady?()
            // 调试用：把关键元素的位置量出来，方便脚本点击
            if ProcessInfo.processInfo.environment["DT_LIVE_PROBE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.probeElements()
                    self?.startHoverProbe()
                }
            }
            if ProcessInfo.processInfo.environment["DT_CLOCK_PROBE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startClockProbe()
                }
            }
            return
        }
        // 页面就绪后立刻取一帧
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.snapshot()
        }
    }

    // MARK: - 加载失败（模式 B 兜底用）

    /// 模式 B 下网页加载失败：通知原生把原生卡片放出来顶替，
    /// 否则 1.5s 兜底会把一个空白窗口直接亮出来。
    private func reportLiveFailure(_ reason: String) {
        guard liveMode else { return }
        guard liveLoadError == nil else { return }   // 已经报过一次就别重复报
        liveLoadError = reason
        NSLog("[TT-LIVE] 网页加载失败：%@", reason)
        onLiveFailed?(reason)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLiveFailure("无法开始加载：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLiveFailure("加载中断：\(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reportLiveFailure("网页内容进程崩溃")
    }
}

// MARK: - 网页 → 原生

extension WebCardRenderer {
    /// 网页发来的意图（由代理转发到这里）
    fileprivate func handle(_ message: WKScriptMessage) {
        guard message.name == "tt",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        // ⚠️ **不要在消息回调里同步回推状态**（2026-11-08 修「点箭头不刷新」）。
        //
        // 网页的点击处理是**同步**发出 `post()` 的；`post` → 消息回调 →
        // `handleWebIntent` → `refreshCard()` → `callAsyncJavaScript("ttUpdate")`。
        // 这条链是在网页**自己的点击回调栈里**重入的 —— 实测 WebKit 会接受
        // 这次调用（不报错）但**不执行**：网页里 `ttUpdate` 的调用计数不涨，
        // 表头 / 卡片停在旧周次，要等下一次别的推送才补上。
        //
        // 让意图晚一拍（`DispatchQueue.main.async`）再处理，回调栈已经退出，
        // 推送就能正常执行。
        let payload = body["payload"]
        DispatchQueue.main.async { [weak self] in
            self?.onIntent?(action, payload)
        }
    }
}

/// WKUserContentController 会强引用 handler，这里用闭包中转打断循环引用。
///
/// 构造时不需要 target（那时 `self` 还没初始化完），
/// 所以先建空代理挂进 configuration，init 之后再把 `handler` 接上。
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var handler: ((WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        handler?(message)
    }
}

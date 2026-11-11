import AppKit
import Foundation
import CoreLocation

/// 「今日详情」里的**天气**数据来源。
///
/// 用协议解耦（和 `DayPanelFestivalProvider` 一个思路）：
///   · 真实实现 `OpenMeteoWeatherProvider` —— CoreLocation 取位置 + Open-Meteo 取天气；
///   · 自检用 `FakeWeatherProvider` —— **绝不联网**。
///
/// ## 隐私
///
/// 用户选的方案是 **B：系统定位（CoreLocation）**：
///   · 需要系统授权（`NSLocationUsageDescription`，Info.plist 里已加）；
///   · 位置**只发给 Open-Meteo**（用来查天气），不发给别的；
///   · **不做 IP 推断** —— 不把 IP 发给任何第三方。
///
/// 拿不到位置 / 用户拒绝授权 / 网络失败 → 返回 nil。
/// 网页在「显示天气」开着时显示「暂无数据」，绝不显示假数据。
protocol DayPanelWeatherProvider: AnyObject {
    /// 某个位置的天气。
    ///
    /// 返回 nil = 没有天气（网页隐藏整行）。
    func weather(for coordinate: CLLocationCoordinate2D) -> DayPanelWeather?

    /// 请求一次位置更新（可能需要用户授权）。
    ///
    /// 实现方决定怎么做（CoreLocation 是异步的）。
    func requestCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void)

    /// 按**城市名**查坐标（Open-Meteo 的地名搜索，**不需要定位权限**）。
    ///
    /// 这是定位的降级方案 —— 后台程序弹不出定位授权框时，用户手填城市就能用。
    ///
    /// - Parameter completion: 查到 → 坐标；查不到 → nil。
    func resolveCity(_ name: String, completion: @escaping (CLLocationCoordinate2D?) -> Void)

    /// 取「**按天**」的天气预报（键 = `2026-11-10` 这种日期）。
    ///
    /// ⚠️ 为什么要按天（2026-11）：面板有 7 列，每一列是**不同的日子**。
    /// 只取「今天的天气」贴到所有列上，点周三显示的也是今天的温度。
    ///
    /// 返回空字典 = 没有数据（网页显示「暂无数据」）。
    func fetchForecast(completion: @escaping ([String: DayPanelWeather]) -> Void)

    /// 按**指定坐标**取按天预报（城市查出来的坐标走这条）。
    func fetchForecast(at coordinate: CLLocationCoordinate2D,
                       completion: @escaping ([String: DayPanelWeather]) -> Void)
}

// MARK: - Open-Meteo

/// 真实的天气提供方：**CoreLocation + Open-Meteo**。
///
/// ## 为什么是 Open-Meteo
///
///   · **不需要 API key** —— 不用注册、不用填表、不用管配额；
///   · 免费、无需信用卡；
///   · 只查一次当前位置的天气，不需要把用户的日程 / 课表发过去。
///
/// 请求形如：
/// ```
/// https://api.open-meteo.com/v1/forecast?latitude=39.9&longitude=116.4
///     &current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min
///     &timezone=auto
/// ```
///
/// ## 降级策略
///
///   · **超时 5 秒**（`URLSession` 的 `timeoutIntervalForRequest`）；
///   · **30 分钟内存缓存（按本地日期分键）** —— 打开一次覆盖层不该反复请求，
///     但过了 12 点一定重新取新的一天；
///   · 任何一步失败 → 返回 nil → 网页显示「暂无数据」（**不显示 0°**）。
///
/// ## ⚠️ 自动化模式
///
/// 自检**绝不真发网络请求** —— `DayPanelController` 在自动化模式下
/// 会注入 `FakeWeatherProvider`，这个类根本不会被调用。
final class OpenMeteoWeatherProvider: NSObject, DayPanelWeatherProvider {

    /// 缓存的天气结果（键 = 本地日期 + "纬度,经度" 的两位小数）。
    ///
    /// ⚠️ **键里必须带日期**（2026-11 加）：Open-Meteo 的 `daily[0]` 是
    /// **请求那一天**的天气。缓存只按经纬度存的话，23:55 取到的「今天」
    /// 在 00:05 还会命中 30 分钟缓存 → 过 12 点后仍然显示**昨天**的
    /// 最低 / 最高温（用户要求「每天过 12 点就更新」）。
    private var cache: [String: DayPanelWeather] = [:]
    /// 缓存的时间戳（和 `cache` 同一个键）。
    private var cacheDates: [String: Date] = [:]
    /// **按天**的预报缓存（键同上，值 = 日期 → 天气）。
    private var forecastCache: [String: [String: DayPanelWeather]] = [:]
    /// 预报缓存的时间戳。
    private var forecastCacheDates: [String: Date] = [:]

    /// 缓存有效期：30 分钟。
    private static let cacheTTL: TimeInterval = 30 * 60

    /// 请求超时：5 秒。
    private static let requestTimeout: TimeInterval = 5

    private let session: URLSession
    private let locationManager: CLLocationManager?

    /// 位置管理器要挂在对象上（否则会被立刻释放，delegate 回调就没了）。
    private var pendingCompletions: [(CLLocationCoordinate2D?) -> Void] = []
    /// 定位请求是不是在飞（去重：同时只发一次 `requestLocation()`）。
    private var locationRequestInFlight = false
    /// 授权请求是不是在飞（**与定位请求是两个独立标志**）。
    ///
    /// ⚠️ 以前共用一个标志 → 授权通过后 `startLocationRequestIfNeeded` 判
    /// 「已在飞」就 return，**定位请求永远发不出去**（用户反馈：同意授权了还是没天气）。
    private var authorizationInFlight = false
    /// 定位请求的兜底超时句柄。
    private var locationTimeout: DispatchWorkItem?
    /// 定位请求的兜底超时秒数。
    ///
    /// ⚠️ **30 秒**（不是 10 秒）：这里同时兜底「等系统授权框」和「等定位回调」。
    /// 授权框是给人看的 —— 10 秒太短，人还没点完就被判成「拿不到位置」，
    /// 于是授权通过了、天气还是没有（用户反馈：「不是同意了吗，为什么找不到天气」）。
    private static let locationTimeoutSeconds: TimeInterval = 30

    /// 授权状态（`nil` = 还没问过）。
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// 是否允许真的请求系统定位。
    ///
    /// 2026-11-11：用户要求天气只走「设置里手动选地区」，
    /// 任何路径都不要再弹「想使用你当前的位置」授权框。
    /// 只有诊断探针（`DT_WEATHER_PROBE=1`）才允许真的定位。
    private static var allowsSystemLocation: Bool {
        ProcessInfo.processInfo.environment["DT_WEATHER_PROBE"] == "1"
    }

    override init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.requestTimeout * 2
        session = URLSession(configuration: cfg)
        // 自动化模式**不建**位置管理器 —— 免得自检时冒出系统授权弹窗。
        if AutomationMode.isCurrentProcessAutomation {
            locationManager = nil
        } else {
            locationManager = CLLocationManager()
        }
        super.init()
        locationManager?.delegate = self
        locationManager?.desiredAccuracy = kCLLocationAccuracyKilometer
        if let m = locationManager {
            authorizationStatus = m.authorizationStatus
        }
    }

    /// 天气（带缓存）。
    func weather(for coordinate: CLLocationCoordinate2D) -> DayPanelWeather? {
        let key = Self.cacheKey(coordinate)
        if let hit = cache[key],
           let when = cacheDates[key],
           Date().timeIntervalSince(when) < Self.cacheTTL {
            return hit
        }
        // ⚠️ **同步调用里不能等网络** —— 这里直接返回缓存（没有就是 nil）。
        //
        // 网络请求是异步的：真正的流程是
        // 「取位置 → 请求 Open-Meteo → 回调里 pushState」。
        // 同步入口只用于「已经有缓存 / 只是想知道能不能拿到」。
        return cache[key]
    }

    /// 异步取一次天气（取位置 → 请求 → 回调）。
    func fetchWeather(completion: @escaping (DayPanelWeather?) -> Void) {
        // ⚠️ **先看缓存，再去要位置**（2026-11 修「每次都重新定位」）。
        //
        // 以前每次 `fetchWeather` 都先 `requestCurrentLocation` ——
        // 指针扫 7 列就触发 7 次定位 + 7 次网络请求。
        // 现在：有缓存坐标就直接用它判缓存，缓存没命中才真的去定位。
        if let m = locationManager,
           let cached = m.location?.coordinate {
            let key = Self.cacheKey(cached)
            if let hit = self.cache[key],
               let when = self.cacheDates[key],
               Date().timeIntervalSince(when) < Self.cacheTTL {
                completion(hit)
                return
            }
        }
        requestCurrentLocation { [weak self] coord in
            guard let self, let coord else {
                DiagLog.info("天气：fetchWeather 没拿到坐标")
                completion(nil)
                return
            }
            let key = Self.cacheKey(coord)
            if let hit = self.cache[key],
               let when = self.cacheDates[key],
               Date().timeIntervalSince(when) < Self.cacheTTL {
                DiagLog.info("天气：fetchWeather 命中缓存 \(key)")
                completion(hit)
                return
            }
            DiagLog.info("天气：fetchWeather 发网络请求 \(key)")
            self.fetchRemote(coord) { result in
                DiagLog.info("天气：fetchWeather 网络回包 \(String(describing: result?.text))")
                if let result {
                    self.cache = self.cache.filter { $0.key.hasPrefix(Self.dayPrefix()) }
                    self.cache[key] = result
                    self.cacheDates = self.cacheDates.filter { $0.key.hasPrefix(Self.dayPrefix()) }
                    self.cacheDates[key] = Date()
                }
                completion(result)
            }
        }
    }

    /// 请求一次位置。
    ///
    /// ⚠️ **去重 + 超时兜底**（2026-11 修「授权给了、坐标拿到了，天气还是没有」）：
    ///
    ///   · 跟随模式下指针扫过 7 列 → 以前会 append 7 个待完成回调、
    ///     还可能重复弹授权框；现在**同时只发一次**定位请求，
    ///     后来的人挂到同一个队列上；
    ///   · `requestLocation()` 可能永远不回调（后台 App 常见）→
    ///     没有兜底的话 `pendingCompletions` 永远挂着、天气永远不来。
    ///     现在加 **10 秒超时**，超时后按「拿不到位置」收尾。
    func requestCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        // ⚠️ **默认不请求系统定位**（2026-11-11 用户要求）。
        //
        // 用户原话：「我在设置里面打开了显示天气的选项，还是会跳出来
        // 桌面课表想使用你当前的位置的请求授权的窗口」。
        // 天气只用「设置里手动选地区」的坐标，任何路径都不该再弹定位授权框。
        // 只有诊断探针（`DT_WEATHER_PROBE=1`）才允许真的定位。
        guard Self.allowsSystemLocation else {
            DiagLog.info("天气：不请求系统定位（天气只用手填地区）")
            completion(nil)
            return
        }
        guard let m = locationManager else {
            // 自动化模式：直接给 nil（不碰系统）。
            DiagLog.info("天气：自动化模式，不请求位置")
            completion(nil)
            return
        }
        let status = m.authorizationStatus
        authorizationStatus = status
        DiagLog.info("天气：requestCurrentLocation 授权状态=\(status.rawValue) 已有缓存坐标=\(m.location != nil) 在飞=\(locationRequestInFlight)")
        switch status {
        case .denied, .restricted:
            // 用户拒绝过 → 不要反复弹窗，直接放弃（面板显示「暂无数据」）。
            completion(nil)
            return
        case .authorizedAlways, .authorizedWhenInUse:
            if let loc = m.location {
                // ⚠️ **已有缓存坐标就直接用**（2026-11）——
                // 以前也走 requestLocation()，每次都白等一次回调。
                completion(loc.coordinate)
                return
            }
            // 已有权限但还没有位置 → 起一次更新（**只发一次**）。
            pendingCompletions.append(completion)
            startLocationRequestIfNeeded(m)
            return
        case .notDetermined:
            // 第一次：先要授权（系统弹窗），授权回调里再取位置。
            // 系统框期间课表不要淡出（用户点「允许」时鼠标必然离开卡片）。
            pendingCompletions.append(completion)
            if !authorizationInFlight {
                authorizationInFlight = true
                PermissionPromptWatch.begin("定位")
                // ⚠️ **必须先切到前台再请求授权**（2026-11 修「授权框不弹」）。
                //
                // 这个 app 是 `LSUIElement` 后台程序 —— macOS 对后台程序调
                // `requestWhenInUseAuthorization()` **经常不弹框**，
                // 请求就一直挂着（授权状态卡在 notDetermined），
                // 表现就是「天气永远拿不到」（用户反馈：同意定位了还是没天气）。
                //
                // 项目里对日历 / 提醒事项已经有同样的处理
                // （见 `DayPanelController.requestAccess`）：切成 `.regular` +
                // 激活 → 请求 → 回调里切回 `.accessory`。
                requestLocationAuthorization(m)
            }
            scheduleLocationTimeout()
            return
        @unknown default:
            completion(nil)
            return
        }
    }

    /// 请求定位授权（**先切前台**，否则系统框不弹）。
    private func requestLocationAuthorization(_ m: CLLocationManager) {
        let automated = AutomationMode.isCurrentProcessAutomation
        // `activationPolicy` 是**方法**不是属性。
        let wasRegular = NSApp.activationPolicy() == .regular
        if !automated && !wasRegular { NSApp.setActivationPolicy(.regular) }
        if !automated { NSApp.activate(ignoringOtherApps: true) }
        m.requestWhenInUseAuthorization()
    }

    /// 授权结束（拿到结果）→ 把 app 切回后台（`LSUIElement`）。
    private func restoreBackgroundPolicy() {
        guard !AutomationMode.isCurrentProcessAutomation else { return }
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 发起一次定位请求（**同一时刻只发一次**）。
    private func startLocationRequestIfNeeded(_ m: CLLocationManager) {
        guard !locationRequestInFlight else {
            scheduleLocationTimeout()
            return
        }
        locationRequestInFlight = true
        DiagLog.info("天气：已授权，发起 requestLocation()")
        m.requestLocation()
        scheduleLocationTimeout()
    }

    /// 定位请求的兜底超时（10 秒）。
    ///
    /// ⚠️ **必须有**：后台 App 的 `requestLocation()` 经常**永远不回调**
    /// （用户拒绝了精确位置、定位服务被别的 App 占用等）。
    /// 没有兜底 → `pendingCompletions` 永远挂着 → 天气永远停在「暂无数据」。
    private func scheduleLocationTimeout() {
        locationTimeout?.cancel()
        locationTimeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.pendingCompletions.isEmpty else { return }
            DiagLog.info("天气：定位超时（\(Int(Self.locationTimeoutSeconds)) 秒），按拿不到位置收尾")
            // ⚠️ **不清 `authorizationInFlight`** —— 授权框可能还在屏幕上，
            // 用户点「允许」后还要接着走 `requestLocation()`。
            self.finishLocationRequest(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.locationTimeoutSeconds,
                                       execute: locationTimeout!)
    }

    /// 定位请求结束 → 分发给所有等着的人。
    private func finishLocationRequest(_ coord: CLLocationCoordinate2D?) {
        locationTimeout?.cancel()
        locationTimeout = nil
        locationRequestInFlight = false
        let pending = pendingCompletions
        pendingCompletions = []
        for c in pending { c(coord) }
    }

    /// 按城市名查坐标（Open-Meteo geocoding API）。
    ///
    /// `https://geocoding-api.open-meteo.com/v1/search?name=秦皇岛&count=1&language=zh`
    ///
    /// ⚠️ **不要直接取第一条**（2026-11-10 实测踩到）：
    /// 「宜昌」查出来第一条是**台湾**的宜昌（23.97, 121.58）——
    /// 面板显示的是 20° / 雾，而湖北宜昌（中国天气网）是 9 ~ 16°。
    /// 现在：优先取**中国**的结果（人口多的优先）；一条中国结果都没有，
    /// 再拿「名字 + 市」重查一次（「宜昌市」能查到湖北那个）。
    func resolveCity(_ name: String, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(nil)
            return
        }
        geocode(trimmed) { [weak self] results in
            if let coord = Self.pickChineseResult(results) {
                completion(coord)
                return
            }
            // 兜底：带「市」再查一次（不少地名在库里只存了「XX市」）。
            guard let self, !trimmed.hasSuffix("市") else {
                completion(nil)
                return
            }
            self.geocode(trimmed + "市") { results2 in
                completion(Self.pickChineseResult(results2))
            }
        }
    }

    /// 真正发一次地名搜索。
    private func geocode(_ name: String,
                         completion: @escaping ([[String: Any]]) -> Void) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else {
            completion([])
            return
        }
        session.dataTask(with: url) { data, _, error in
            guard error == nil, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else {
                completion([])
                return
            }
            completion(results)
        }.resume()
    }

    /// 从地名搜索结果里挑一个**中国**的（人口多的优先）。
    ///
    /// 纯函数，方便单测：喂进「台湾宜昌 + 湖北宜昌」这种列表，必须选湖北的那个。
    static func pickChineseResult(_ results: [[String: Any]]) -> CLLocationCoordinate2D? {
        // ⚠️ 港澳台也要认（2026-11-10）：地名库给它们的 country 是
        // 「香港 / 澳门 / 台湾」，country_code 是 HK / MO / TW，
        // 只认「中国」会把这三条筛掉 → 选了永远没数据。
        let chinese = results.filter { item in
            let country = (item["country"] as? String) ?? ""
            let code = ((item["country_code"] as? String) ?? "").uppercased()
            if ["CN", "HK", "MO", "TW"].contains(code) { return true }
            return ["中国", "中國", "香港", "澳门", "澳門", "台湾", "臺灣"]
                .contains(where: { country.contains($0) })
        }
        guard !chinese.isEmpty else { return nil }
        let sorted = chinese.sorted { a, b in
            (a["population"] as? Int ?? 0) > (b["population"] as? Int ?? 0)
        }
        guard let best = sorted.first,
              let lat = best["latitude"] as? Double,
              let lon = best["longitude"] as? Double else { return nil }
        let cityName = (best["name"] as? String) ?? ""
        DiagLog.info("天气：地名「\(cityName)」→ \(lat), \(lon)")
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 取按天的预报（一周）。
    func fetchForecast(completion: @escaping ([String: DayPanelWeather]) -> Void) {
        // 已有缓存坐标就直接用；没有才去定位。
        let cached = locationManager?.location?.coordinate
        if let c = cached {
            fetchForecast(at: c, completion: completion)
            return
        }
        requestCurrentLocation { [weak self] coord in
            guard let self, let coord else {
                completion([:])
                return
            }
            self.fetchForecast(at: coord, completion: completion)
        }
    }

    /// 按**指定坐标**取按天预报（城市查出来的坐标也走这里）。
    func fetchForecast(at coord: CLLocationCoordinate2D,
                       completion: @escaping ([String: DayPanelWeather]) -> Void) {
        let useCoord: (CLLocationCoordinate2D) -> Void = { [weak self] coord in
            guard let self else {
                completion([:])
                return
            }
            let key = Self.cacheKey(coord)
            if let hit = self.forecastCache[key],
               let when = self.forecastCacheDates[key],
               Date().timeIntervalSince(when) < Self.cacheTTL {
                DiagLog.info("天气：fetchForecast 命中缓存（\(hit.count) 天）")
                completion(hit)
                return
            }
            self.fetchRemoteForecast(coord) { result in
                if !result.isEmpty {
                    self.forecastCache = self.forecastCache.filter { $0.key.hasPrefix(Self.dayPrefix()) }
                    self.forecastCache[key] = result
                    self.forecastCacheDates = self.forecastCacheDates.filter { $0.key.hasPrefix(Self.dayPrefix()) }
                    self.forecastCacheDates[key] = Date()
                }
                completion(result)
            }
        }
        useCoord(coord)
    }

    /// 真发一次网络请求（按天预报）。
    private func fetchRemoteForecast(_ coord: CLLocationCoordinate2D,
                                     completion: @escaping ([String: DayPanelWeather]) -> Void) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coord.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coord.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            // ⚠️ **多带几个模型**（2026-11-10）：日最低 / 最高温取它们的中位数。
            // 单个模型在中国的沿海城市能偏 5°（详见 `modelList` 的说明）。
            URLQueryItem(name: "models", value: Self.modelList),
            // ⚠️ **把窗口撑到「前 7 天 + 后 16 天」**（2026-11-10）：
            // 面板 7 列是「本周一到周日」，只取「今天起 7 天」的话，今天之前的列
            // 全落在窗口外 → 一换列就「暂无数据」（用户反馈「移动到别的列天气就没了」）。
            // Open-Meteo 实测 `past_days=7&forecast_days=16` 能返回 23 天。
            URLQueryItem(name: "past_days", value: Self.pastDays),
            URLQueryItem(name: "forecast_days", value: Self.forecastDays),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url else {
            completion([:])
            return
        }
        session.dataTask(with: url) { data, _, error in
            if error != nil {
                completion([:])
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion([:])
                return
            }
            let forecast = Self.parseForecast(obj)
            DiagLog.info("天气：拿到预报 \(forecast.count) 天")
            completion(forecast)
        }.resume()
    }

    /// 真发一次网络请求（单点，今天）。
    private func fetchRemote(_ coord: CLLocationCoordinate2D,
                             completion: @escaping (DayPanelWeather?) -> Void) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coord.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coord.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            // ⚠️ **要 `weather_code` 和 `time`**（2026-11 修「温度不对 / 天气串天」）：
            //   · `time`  = 每一天的日期，用来把预报对齐到面板那一列的真实日期；
            //   · `weather_code` = 每天的天气现象（以前只有 current 的，所以别的天没现象）。
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "models", value: Self.modelList),
            // ⚠️ **把窗口撑到「前 7 天 + 后 16 天」**（2026-11-10）：
            // 面板 7 列是「本周一到周日」，只取「今天起 7 天」的话，今天之前的列
            // 全落在窗口外 → 一换列就「暂无数据」（用户反馈「移动到别的列天气就没了」）。
            // Open-Meteo 实测 `past_days=7&forecast_days=16` 能返回 23 天。
            URLQueryItem(name: "past_days", value: Self.pastDays),
            URLQueryItem(name: "forecast_days", value: Self.forecastDays),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url else {
            completion(nil)
            return
        }
        session.dataTask(with: url) { data, _, error in
            if error != nil {
                completion(nil)
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(nil)
                return
            }
            completion(Self.parse(obj))
        }.resume()
    }

    /// 解析 Open-Meteo 的响应。
    ///
    /// ⚠️ **任何一个字段缺失都只是「那一项没有」**，
    /// 不是整份数据作废 —— 但如果描述和温度都没有 → 返回 nil（整行隐藏）。
    static func parse(_ obj: [String: Any]) -> DayPanelWeather? {
        let forecast = parseForecast(obj)
        if let today = forecast[Self.todayKey()] { return today }
        return forecast.values.first
    }

    /// 请求里带的模型列表。
    ///
    /// ⚠️ **为什么要一次带多个模型**（2026-11-10）：
    /// 单个数值模型在中国沿海 / 山区城市能偏到离谱。实测秦皇岛 2026-11-10：
    /// `best_match` 给「-5 ~ 6°」，而中国天气网和苹果天气都是「-1 ~ 11°」——
    /// 差 5°。同一时刻 ECMWF 给 -3~8、GFS -1~10、UKMO -2~13。
    /// 三个全球模型取中位数后是「-2 ~ 10°」，误差回到 1° 内。
    ///
    /// `best_match` 仍留在列表里，是为了让 `current`（当前温度）继续用它 ——
    /// 实测它的「现在温度」和 met.no / wttr.in 一致（1.8° vs 1.0° / 2.0°）。
    static let modelList = "best_match,ecmwf_ifs025,gfs_seamless,ukmo_seamless"

    /// 参与「每日最低 / 最高温」取中位数的模型。
    ///
    /// `best_match` **不参与**：它正是实测里偏得最多的那个（-5/6），
    /// 而且它内部会按地区换源，做中位数时会把整体拽偏。
    static let ensembleModels = ["ecmwf_ifs025", "gfs_seamless", "ukmo_seamless"]

    /// 往前取几天（覆盖「本周已经过去的那几列」）。Open-Meteo 上限 92 天。
    static let pastDays = "7"
    /// 往后取几天（覆盖下一周）。免费额度下 16 天是上限。
    static let forecastDays = "16"


    /// 中位数（偶数个取中间两个的平均）。空数组 → nil。
    ///
    /// 用中位数而不是平均值：三个模型里偶尔会有一个明显跑飞
    /// （实测北京 GFS 的最低温给 5.6°，实际 0°），中位数能把它挡掉。
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 某一天某一项温度：先按模型取中位数，取不到再退回**不带后缀**的那份。
    ///
    /// - Parameters:
    ///   - field: `temperature_2m_min` / `temperature_2m_max`。
    ///   - index: 第几天（和 `daily.time` 同一个下标）。
    ///   - fallback: 请求没带 `models` 时的普通数组（老响应 / 自检假数据）。
    static func dailyValue(_ daily: [String: Any], field: String, at index: Int,
                           fallback: [Double]) -> Double? {
        var values: [Double] = []
        for model in ensembleModels {
            guard let arr = daily["\(field)_\(model)"] as? [Double],
                  index < arr.count else { continue }
            values.append(arr[index])
        }
        if let m = median(values) { return m }
        return index < fallback.count ? fallback[index] : nil
    }

    /// 解析成「**按天**」的预报（键 = `2026-11-10` 这种日期）。
    ///
    /// ⚠️ **必须按天**（2026-11 修「温度不对 / 天气一直显示在别的天上」）：
    /// 以前只取 `daily[0]`（= 请求那天的），然后贴到面板**任意一列**——
    /// 于是点周三显示的也是今天的温度。
    ///
    /// - Returns: 日期 → 天气。空字典 = 没有可用数据。
    static func parseForecast(_ obj: [String: Any]) -> [String: DayPanelWeather] {
        var out: [String: DayPanelWeather] = [:]

        // ---- current：今天的现象 + 当前温度 ----
        var currentTemp: Double? = nil
        var currentText: String = ""
        if let current = obj["current"] as? [String: Any] {
            if let t = current["temperature_2m"] as? Double {
                currentTemp = t
            } else if let t = current["temperature_2m"] as? Int {
                currentTemp = Double(t)
            }
            if let code = current["weather_code"] as? Int {
                currentText = weatherText(code)
            }
        }

        // ---- daily：每一天的现象 + 最高 / 最低 ----
        guard let daily = obj["daily"] as? [String: Any] else {
            if !currentText.isEmpty || currentTemp != nil {
                var w = DayPanelWeather()
                w.text = currentText
                w.temperature = currentTemp
                w.min = currentTemp
                w.max = currentTemp
                out[todayKey()] = w
            }
            return out
        }
        let times = (daily["time"] as? [String]) ?? []
        // 不带后缀的那份：**只在请求没带 `models` 时才有**（老响应 / 自检假数据），
        // 作为多模型缺失时的兜底。
        let maxArr = (daily["temperature_2m_max"] as? [Double]) ?? []
        let minArr = (daily["temperature_2m_min"] as? [Double]) ?? []
        // 现象取 `best_match` 的：它和 `current` 同源，前后天不会自相矛盾。
        let codeArr = (daily["weather_code_best_match"] as? [Int])
            ?? (daily["weather_code"] as? [Int])
            ?? []

        for (i, day) in times.enumerated() {
            var w = DayPanelWeather()
            // 日最低 / 最高：三模型取中位数（见 `dailyValue` 的说明）。
            if let v = Self.dailyValue(daily, field: "temperature_2m_max", at: i, fallback: maxArr) {
                w.max = v
            }
            if let v = Self.dailyValue(daily, field: "temperature_2m_min", at: i, fallback: minArr) {
                w.min = v
            }
            if i < codeArr.count { w.text = weatherText(codeArr[i]) }
            // 「今天」那一天的当前温度 → 也作为最低 / 最高（当天以当前值为准更贴近体感）。
            if day == todayKey(), let t = currentTemp {
                w.temperature = t
                if w.text.isEmpty { w.text = currentText }
            }
            if !w.isEmpty { out[day] = w }
        }
        return out
    }

    /// 今天的日期键（`2026-11-10`）—— 与 Open-Meteo `daily.time` 同格式。
    static func todayKey(on date: Date = Date(),
                         calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// WMO 天气码 → 中文描述 + 简单图形。
    ///
    /// WMO code（Open-Meteo 用的就是这套）：
    ///   0 晴 / 1 大致晴 / 2 局部多云 / 3 阴
    ///   45,48 雾 / 51,53,55 毛毛雨 / 56,57 冻毛毛雨
    ///   61,63,65 雨 / 66,67 冻雨 / 71,73,75 雪 / 77 雪粒
    ///   80,81,82 阵雨 / 85,86 阵雪 / 95 雷阵雨 / 96,99 雷阵雨伴冰雹
    static func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "大部晴朗"
        case 2: return "局部多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "雪粒"
        case 80: return "阵雨"
        case 81: return "强阵雨"
        case 82: return "暴雨"
        case 85: return "阵雪"
        case 86: return "强阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷阵雨伴冰雹"
        default: return "多云"
        }
    }

    /// 本地日期前缀（`2026-11-10|`）。
    ///
    /// ⚠️ 缓存键带日期 = **过了 12 点一定重新取**（哪怕距上次请求不到 30 分钟）。
    /// 用户要求：「每天过 12 点了就更新」。
    static func dayPrefix(on date: Date = Date(),
                          calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d|",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 缓存键（本地日期 + 经纬度保留两位小数 ≈ 1km 精度）。
    ///
    /// 拆成 `static` 是为了能单测「跨天一定换键」——
    /// 不换键的话，00:05 会继续用 23:55 缓存的「昨天」天气。
    static func cacheKey(_ c: CLLocationCoordinate2D,
                         on date: Date = Date(),
                         calendar: Calendar = .current) -> String {
        dayPrefix(on: date, calendar: calendar)
            + String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }
}

// MARK: - CLLocationManagerDelegate

extension OpenMeteoWeatherProvider: CLLocationManagerDelegate {

    /// 新 API（macOS 11+）。**必须同时实现**：系统在新 SDK 上可能只回调这个，
    /// 只写旧的 `didChangeAuthorization` 的话，用户点完「允许」永远等不到位置。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange(manager.authorizationStatus, manager: manager)
    }

    /// 旧 API（macOS 10.12–10.15）；保留给老系统。
    func locationManager(_ manager: CLLocationManager,
                         didChangeAuthorization status: CLAuthorizationStatus) {
        handleAuthorizationChange(status, manager: manager)
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus,
                                           manager: CLLocationManager) {
        authorizationStatus = status
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            // 用户已经在系统框里点过「允许」→ 解除「课表别淡出」的保持。
            PermissionPromptWatch.end("定位")
            // ⚠️ 只有**真的有人在等位置**时才 requestLocation ——
            // 设置 delegate 时系统会立刻回调一次当前授权状态，
            // 那时 pendingCompletions 是空的；无条件请求会平白定位一次。
            authorizationInFlight = false
            // 授权框走完了 → 把 app 切回后台（它是 `LSUIElement`）。
            restoreBackgroundPolicy()
            if !pendingCompletions.isEmpty {
                // ⚠️ 这里**必须真的发起** `requestLocation()`（2026-11 修「授权给了、
                // 坐标拿到了，天气还是没有」）。
                //
                // 以前 `locationRequestInFlight` 被 notDetermined 分支占着，
                // 这里判 `!locationRequestInFlight` 就**直接 return** ——
                // 授权通过了，却从来没发过定位请求，坐标永远不来。
                // 现在授权在飞与定位在飞是**两个独立标志**。
                startLocationRequestIfNeeded(manager)
            }
        case .denied, .restricted:
            PermissionPromptWatch.end("定位")
            authorizationInFlight = false
            restoreBackgroundPolicy()
            finishLocationRequest(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        DiagLog.info("天气：拿到坐标 \(String(describing: coord))")
        finishLocationRequest(coord)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DiagLog.info("天气：定位失败 \(error.localizedDescription)")
        finishLocationRequest(nil)
    }
}

// MARK: - 自检用的假实现

/// 自检用的**假**天气提供方 —— 永远不联网、不碰定位。
///
/// 返回固定的一份天气，让自检能验证「天气行怎么渲染」，
/// 而不产生任何真实的网络请求或系统权限弹窗。
final class FakeWeatherProvider: DayPanelWeatherProvider {

    /// 要返回的天气（nil = 没有天气 → 网页隐藏整行）。
    var stub: DayPanelWeather?

    /// 被调用了几次（自检断言「自动化模式不该真发请求」时用）。
    private(set) var requestCount = 0

    init(stub: DayPanelWeather? = nil) {
        self.stub = stub
    }

    func weather(for coordinate: CLLocationCoordinate2D) -> DayPanelWeather? { stub }

    func requestCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        requestCount += 1
        // 给一个固定坐标（上海），让测试可复现。
        completion(CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737))
    }

    /// 按天预报（自检用）。
    ///
    /// - Parameter forecast: 日期键 → 天气。nil = 「没有数据」。
    ///   默认给「今天」一份（测试里 baseMonday 是固定的周一，需要时用 `forecastByDay` 覆盖）。
    var forecast: [String: DayPanelWeather]? = nil

    /// 城市查询返回的坐标（自检用；nil = 查不到）。
    var cityCoordinate: CLLocationCoordinate2D? = CLLocationCoordinate2D(latitude: 39.9354, longitude: 119.6005)

    /// 地名查询次数（自检用）。
    ///
    /// ⚠️ 不并进 `forecastRequestCount`：那一个是「真的取了一次预报」的次数，
    /// 把地名查询也算进去会让「扫多列只发一次请求」这类断言失准（2026-11-11）。
    private(set) var resolveCityCount = 0

    func resolveCity(_ name: String, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        resolveCityCount += 1
        completion(cityCoordinate)
    }

    /// 预报请求次数（自检断言「换天 / 重新开开关 → 重新取」用）。
    private(set) var forecastRequestCount = 0

    func fetchForecast(completion: @escaping ([String: DayPanelWeather]) -> Void) {
        forecastRequestCount += 1
        completion(stubForecast())
    }

    func fetchForecast(at coordinate: CLLocationCoordinate2D,
                       completion: @escaping ([String: DayPanelWeather]) -> Void) {
        forecastRequestCount += 1
        completion(stubForecast())
    }

    /// 假数据：有 `forecast` 用它，否则给「今天」一份。
    private func stubForecast() -> [String: DayPanelWeather] {
        if let f = forecast { return f }
        if let stub { return [OpenMeteoWeatherProvider.todayKey(): stub] }
        return [:]
    }
}

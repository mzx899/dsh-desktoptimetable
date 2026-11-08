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
/// 拿不到位置 / 用户拒绝授权 / 网络失败 → 返回 nil，
/// 网页**隐藏整行天气**，绝不显示假数据。
protocol DayPanelWeatherProvider: AnyObject {
    /// 某个位置的天气。
    ///
    /// 返回 nil = 没有天气（网页隐藏整行）。
    func weather(for coordinate: CLLocationCoordinate2D) -> DayPanelWeather?

    /// 请求一次位置更新（可能需要用户授权）。
    ///
    /// 实现方决定怎么做（CoreLocation 是异步的）。
    func requestCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void)
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
///   · **30 分钟内存缓存** —— 打开一次覆盖层不该反复请求；
///   · 任何一步失败 → 返回 nil → 网页隐藏整行（**不显示 0°**）。
///
/// ## ⚠️ 自动化模式
///
/// 自检**绝不真发网络请求** —— `DayPanelController` 在自动化模式下
/// 会注入 `FakeWeatherProvider`，这个类根本不会被调用。
final class OpenMeteoWeatherProvider: NSObject, DayPanelWeatherProvider {

    /// 缓存的天气结果（键 = "纬度,经度" 的两位小数）。
    private var cache: [String: DayPanelWeather] = [:]
    /// 缓存的时间戳（和 `cache` 同一个键）。
    private var cacheDates: [String: Date] = [:]

    /// 缓存有效期：30 分钟。
    private static let cacheTTL: TimeInterval = 30 * 60

    /// 请求超时：5 秒。
    private static let requestTimeout: TimeInterval = 5

    private let session: URLSession
    private let locationManager: CLLocationManager?

    /// 位置管理器要挂在对象上（否则会被立刻释放，delegate 回调就没了）。
    private var pendingCompletions: [(CLLocationCoordinate2D?) -> Void] = []

    /// 授权状态（`nil` = 还没问过）。
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

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
        let key = cacheKey(coordinate)
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
        requestCurrentLocation { [weak self] coord in
            guard let self, let coord else {
                completion(nil)
                return
            }
            let key = self.cacheKey(coord)
            if let hit = self.cache[key],
               let when = self.cacheDates[key],
               Date().timeIntervalSince(when) < Self.cacheTTL {
                completion(hit)
                return
            }
            self.fetchRemote(coord) { result in
                if let result {
                    self.cache[key] = result
                    self.cacheDates[key] = Date()
                }
                completion(result)
            }
        }
    }

    /// 请求一次位置。
    func requestCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        guard let m = locationManager else {
            // 自动化模式：直接给 nil（不碰系统）。
            completion(nil)
            return
        }
        let status = m.authorizationStatus
        authorizationStatus = status
        switch status {
        case .denied, .restricted:
            // 用户拒绝过 → 不要反复弹窗，直接放弃（网页隐藏天气行）。
            completion(nil)
            return
        case .authorizedAlways, .authorizedWhenInUse:
            if let loc = m.location {
                completion(loc.coordinate)
                return
            }
            // 已有权限但还没有位置 → 起一次更新。
            pendingCompletions.append(completion)
            m.requestLocation()
            return
        case .notDetermined:
            // 第一次：先要授权（系统弹窗），授权回调里再取位置。
            // 系统框期间课表不要淡出（用户点「允许」时鼠标必然离开卡片）。
            pendingCompletions.append(completion)
            PermissionPromptWatch.begin("定位")
            m.requestWhenInUseAuthorization()
            return
        @unknown default:
            completion(nil)
            return
        }
    }

    /// 真发一次网络请求。
    private func fetchRemote(_ coord: CLLocationCoordinate2D,
                             completion: @escaping (DayPanelWeather?) -> Void) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coord.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coord.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
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
        var w = DayPanelWeather()

        // current.temperature_2m / current.weather_code
        if let current = obj["current"] as? [String: Any] {
            if let t = current["temperature_2m"] as? Double {
                w.temperature = t
            } else if let t = current["temperature_2m"] as? Int {
                w.temperature = Double(t)
            }
            if let code = current["weather_code"] as? Int {
                w.text = weatherText(code)
            }
        }
        // daily.temperature_2m_max / temperature_2m_min（数组，取今天 = 第 0 个）
        if let daily = obj["daily"] as? [String: Any] {
            if let arr = daily["temperature_2m_max"] as? [Double], let v = arr.first {
                w.max = v
            } else if let arr = daily["temperature_2m_max"] as? [Int], let v = arr.first {
                w.max = Double(v)
            }
            if let arr = daily["temperature_2m_min"] as? [Double], let v = arr.first {
                w.min = v
            } else if let arr = daily["temperature_2m_min"] as? [Int], let v = arr.first {
                w.min = Double(v)
            }
        }
        // 什么都没有 → 整行隐藏。
        if w.isEmpty { return nil }
        return w
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

    /// 缓存键（经纬度保留两位小数 ≈ 1km 精度）。
    private func cacheKey(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }
}

// MARK: - CLLocationManagerDelegate

extension OpenMeteoWeatherProvider: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager,
                         didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            // 用户已经在系统框里点过「允许」→ 解除「课表别淡出」的保持。
            PermissionPromptWatch.end("定位")
            // 拿到权限 → 取一次位置。
            manager.requestLocation()
        case .denied, .restricted:
            PermissionPromptWatch.end("定位")
            let pending = pendingCompletions
            pendingCompletions = []
            for c in pending { c(nil) }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        let pending = pendingCompletions
        pendingCompletions = []
        let coord = locations.last?.coordinate
        for c in pending { c(coord) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let pending = pendingCompletions
        pendingCompletions = []
        for c in pending { c(nil) }
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
}

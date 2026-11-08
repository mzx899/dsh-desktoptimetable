import Foundation
import CoreLocation

/// 「今日详情」那一栏的数据来源的**工厂**。
///
/// 存在的理由：农历 / 节气 / 节日模块是独立实现的（单独一个 agent 做的），
/// 但 AppDelegate 不能直接依赖它 —— 那样两个模块就绑死了，
/// 万一农历模块有问题，整个 app 都编译不过。
///
/// 所以这里用「工厂」把依赖藏起来：编译期不引用农历模块的具体类型，
/// 运行时才通过 `#if canImport` / 反射式的可选路径接上。
///
/// 现在农历模块已经就位（`LunarCalendar` / `SolarTerms` / `FestivalCalendar`），
/// 所以直接用它；`EmptyFestivalProvider` 只是兜底（模块不可用时）。
enum DayPanelFestivalProviderFactory {

    /// 造一个「节日 / 节气」提供方。
    ///
    /// `weatherProvider` 可以注入 —— 自检就注入 `FakeWeatherProvider`，
    /// **绝不真发网络请求 / 不碰定位**。
    static func make(weatherProvider: DayPanelWeatherProvider? = nil) -> DayPanelFestivalProvider {
        LunarFestivalProvider(weatherProvider: weatherProvider)
    }
}

/// 用农历模块算节日 / 节气（+ 宜忌 + 天气）。
struct LunarFestivalProvider: DayPanelFestivalProvider {

    /// 天气提供方（nil = 不取天气）。
    private let weatherProvider: DayPanelWeatherProvider?

    init(weatherProvider: DayPanelWeatherProvider? = nil) {
        self.weatherProvider = weatherProvider
    }

    func festival(on date: Date) -> DayPanelFestival {
        var result = DayPanelFestival()
        // 农历日期
        if let lunar = LunarCalendar.lunar(from: date) {
            let month = LunarCalendar.monthName(lunar.month, isLeap: lunar.isLeapMonth)
            let day = LunarCalendar.dayName(lunar.day)
            result.lunar = "农历\(month)\(day)"
        }
        // 节气（`terms(on:)` 返回这一天的**所有**节气 ——
        // 个别年份同一天有两个节气，取第一个即可）
        if let term = SolarTerms.terms(on: date).first {
            result.solarTerm = term
        }
        // 节日（公历 + 农历）
        result.festivals = FestivalCalendar.festivals(on: date)
        // 宜 / 忌（**简化的建除黄历**，离线算）。
        //
        // ⚠️ 这不是权威老黄历，只是一个氛围提示（见 AlmanacCalendar 的说明）。
        // 拿不到 → 保持空串 → 网页隐藏这一行。
        if let almanac = AlmanacCalendar.briefAlmanac(on: date) {
            result.yi = almanac.yi
            result.ji = almanac.ji
        }
        // 天气：**同步这里拿不到**（网络是异步的）——
        // 真正的天气由 `DayPanelController` 异步取到后单独填进来。
        return result
    }
}

import Foundation

/// **简化的建除黄历**（离线，不联网）。
///
/// ## ⚠️ 这不是权威老黄历
///
/// 真正的黄历（通书 / 择日）要考虑：
///   · 二十八宿、二十九宿的吉凶；
///   · 三合 / 三会 / 六合 / 三刑 / 六害 / 六破 的生肖关系；
///   · 建除十二神**叠加**在月建、日干支、时柱上的完整推演；
///   · 各地「忌日」「月厌」「黑道日」等流派差异。
///
/// 本模块**只**做最基础的一层：**按建除十二神给出固定的宜 / 忌条目**。
/// 它是一个**氛围提示**，不是择日依据 —— 代码和文档都写明这一点。
///
/// ## 建除十二神的排法
///
/// 建除十二神按**日支**循环排，一天一个神：
///
/// ```
/// 建 除 满 平 定 执 破 危 成 收 开 闭
/// ```
///
/// 各神对应地支（**子日建、除丑、满寅、平卯、定辰、执巳、破午、危未、成申、收酉、开戌、闭亥**）
/// —— 这是「**正建**」流派，即每值一神顺次轮转，是最通用的一种排法。
/// （另有「反建」流派，从午日起排；本模块不用它。）
///
/// ## 与月建的关系
///
/// 传统上「建」的落点跟随**月建**（正月建寅、二月建卯……），
/// 同一天是「建」还是「除」由日支与月建共同决定 —— 各家算法不一。
///
/// 本模块采用**最简单、也最可复现**的一版：**只按日支循环**，
/// 即上表的「子建、除丑、满寅……」。
///
/// 这么做的理由：
///   · **完全确定、可测** —— 同一天永远给同样的结果，能写单元测试；
///   · **不需要节气 / 月建推演** —— 月建要靠节气定，边界上容易差一天；
///   · 用户看到的只是「宜 / 忌」两行氛围文字，不承担择日职责。
///
/// ## 拿不到数据时
///
/// `almanac(on:)` 在日期超出农历表范围（1900-01-31 – 2100-12-31）时返回 nil，
/// **调用方必须隐藏这一行** —— 绝不编造。
enum AlmanacCalendar {

    // MARK: - 十二神

    /// 建除十二神（按日支循环，**正建**流派）。
    ///
    /// 下标 = 地支序号（0 = 子 … 11 = 亥）。
    static let twelveGods: [String] = [
        "建", "除", "满", "平", "定", "执",
        "破", "危", "成", "收", "开", "闭"
    ]

    /// 某一天是十二神里的哪一个。
    ///
    /// `branchIndex` 是日支序号（`LunarCalendar.dayGanzhiIndices` 给的）。
    static func god(branchIndex: Int) -> String? {
        guard (0..<12).contains(branchIndex) else { return nil }
        return twelveGods[branchIndex]
    }

    // MARK: - 宜 / 忌

    /// 某个十二神对应的宜 / 忌条目。
    ///
    /// 这些条目取的是建除十二神的**通行含义**（民间择日里对该神的概括），
    /// 不是某一本具体通书的原文 —— 各书措辞略有出入，这里统一取一套说法。
    ///
    /// 顺序是「宜在前、忌在后」，各一到两条。
    static func entries(forGod god: String) -> (yi: [String], ji: [String])? {
        switch god {
        case "建": return (["出行", "订盟"], ["动土", "开仓"])
        case "除": return (["除服", "疗病"], ["出行", "嫁娶"])
        case "满": return (["祭祀", "祈福"], ["服药", "求医"])
        case "平": return (["修饰垣墙", "平治道涂"], ["开渠", "穿井"])
        case "定": return (["嫁娶", "立约"], ["诉讼", "出行"])
        case "执": return (["造屋", "收购"], ["开仓", "掘井"])
        case "破": return (["破屋", "坏垣"], ["嫁娶", "开市"])
        case "危": return (["安床", "祭祀"], ["登高", "行船"])
        case "成": return (["开市", "入学"], ["诉讼", "争执"])
        case "收": return (["纳财", "进人口"], ["开仓", "安葬"])
        case "开": return (["开市", "动土"], ["安葬", "破土"])
        case "闭": return (["筑堤", "埋穴"], ["开市", "出行"])
        default: return nil
        }
    }

    // MARK: - 对外接口

    /// 某一天的宜 / 忌。
    ///
    /// 返回值里的 `god` 是十二神的名字（显示成「建除」那一行的小标题）。
    ///
    /// 超出支持范围 / 算不出来时返回 nil —— **调用方要隐藏这一行**。
    static func almanac(on date: Date) -> Almanac? {
        guard let idx = LunarCalendar.dayGanzhiIndices(date) else { return nil }
        guard let god = god(branchIndex: idx.branch) else { return nil }
        guard let e = entries(forGod: god) else { return nil }
        return Almanac(god: god,
                       yi: e.yi.joined(separator: "、"),
                       ji: e.ji.joined(separator: "、"))
    }

    /// 某一天宜 / 忌的**简短版**（各取第一条）—— 覆盖层里显示的是这个。
    ///
    /// 窄态列宽只有约 119pt，「宜：出行、订盟」太长了会挤成两行，
    /// 所以这里只取第一条。
    static func briefAlmanac(on date: Date) -> Almanac? {
        guard let idx = LunarCalendar.dayGanzhiIndices(date) else { return nil }
        guard let god = god(branchIndex: idx.branch) else { return nil }
        guard let e = entries(forGod: god) else { return nil }
        return Almanac(god: god,
                       yi: e.yi.first ?? "",
                       ji: e.ji.first ?? "")
    }
}

/// 一天的宜 / 忌。
struct Almanac: Equatable {
    /// 十二神的名字（「建」「除」……）。
    var god: String = ""
    /// 宜（简短版：一条）。
    var yi: String = ""
    /// 忌（简短版：一条）。
    var ji: String = ""

    /// 有没有内容。
    var isEmpty: Bool { yi.isEmpty && ji.isEmpty }
}

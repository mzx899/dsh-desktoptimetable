import Foundation

/// 天气用的**城市目录**（设置里「地区」选择器的数据源）。
///
/// 为什么要有它：
///   · 后台程序在 ad-hoc 签名下拿不到系统定位（见 `OpenMeteoWeatherProvider`），
///     地区是唯一的取数入口；
///   · 让用户手打城市名容易打错（「秦皇岛」打成「秦皇島」就查不到），
///     给一份**热门城市 + 首字母排序**的列表，点一下就选好。
///
/// 拼音首字母用 `CFStringTransform` 现算，**不写死**一张「城市 → 字母」的表 ——
/// 手写表迟早会和城市名对不上，而且加一个城市就要改两处。
enum WeatherCityCatalog {

    /// 热门城市（选择器最上面那一段，按这个顺序显示）。
    ///
    /// 顺序按「用的人多」排，不按拼音 —— 这一段就是给人**快手点**用的。
    static let hot: [String] = [
        "北京", "上海", "广州", "深圳", "杭州", "成都", "重庆", "武汉",
        "西安", "南京", "天津", "苏州", "青岛", "厦门", "长沙", "郑州",
        "沈阳", "大连", "哈尔滨", "昆明",
    ]

    /// 除热门城市外的全部候选（去重后按拼音首字母分组）。
    static let others: [String] = [
        // 河北
        "石家庄", "秦皇岛", "唐山", "保定", "邯郸", "廊坊", "沧州", "邢台",
        "张家口", "承德", "衡水",
        // 山西 / 内蒙古
        "太原", "大同", "临汾", "运城", "呼和浩特", "包头", "鄂尔多斯",
        // 东北
        "长春", "吉林", "齐齐哈尔", "大庆", "鞍山", "抚顺",
        // 江苏 / 浙江
        "无锡", "常州", "扬州", "徐州", "南通", "连云港", "淮安", "盐城",
        "镇江", "泰州", "宿迁", "宁波", "温州", "绍兴", "湖州", "嘉兴",
        "金华", "台州", "丽水", "舟山",
        // 安徽 / 福建 / 江西
        "合肥", "芜湖", "蚌埠", "安庆", "福州", "泉州", "莆田", "三明",
        "漳州", "龙岩", "南昌", "九江", "赣州", "上饶",
        // 山东
        "济南", "烟台", "潍坊", "淄博", "枣庄", "东营", "济宁", "泰安",
        "威海", "日照", "临沂", "德州", "聊城", "滨州", "菏泽",
        // 河南
        "洛阳", "开封", "平顶山", "安阳", "新乡", "焦作", "许昌", "南阳",
        "商丘", "信阳", "周口",
        // 湖北 / 湖南
        "宜昌", "黄石", "十堰", "襄阳", "荆州", "孝感", "株洲", "岳阳",
        "常德", "张家界", "益阳", "郴州",
        // 广东 / 广西 / 海南
        "珠海", "佛山", "东莞", "中山", "惠州", "韶关", "汕头", "江门",
        "湛江", "茂名", "肇庆", "梅州", "清远", "揭阳", "南宁", "桂林",
        "柳州", "北海", "玉林", "海口", "三亚",
        // 西南 / 西北
        "绵阳", "贵阳", "遵义", "曲靖", "丽江", "大理", "拉萨", "宝鸡",
        "咸阳", "延安", "榆林", "兰州", "天水", "西宁", "银川", "石嘴山",
        "乌鲁木齐", "喀什", "石河子",
        // 港澳台
        "香港", "澳门", "台北",
    ]

    /// **内置坐标兜底表**（2026-11-10 自查结果）。
    ///
    /// 这几个城市在 Open-Meteo 的地名库里**根本搜不到**（连「名字 + 市」也没有）：
    /// 运城 / 连云港 / 宿迁 / 湖州 / 许昌 / 商丘 / 益阳 / 石嘴山。
    /// 另有港澳台三条：地名库给的国家是「香港 / 澳门 / 台湾」，会被「只认中国」筛掉。
    ///
    /// 与其让用户选了城市却永远「暂无数据」，不如把这几个坐标写死在这里 ——
    /// 城市级天气对 ±0.05° 完全不敏感，写死是最稳的。
    static let knownCoordinates: [String: (lat: Double, lon: Double)] = [
        "运城": (35.0265, 111.0037),
        "连云港": (34.5967, 119.2216),
        "宿迁": (33.9631, 118.2753),
        "湖州": (30.8703, 120.0933),
        "许昌": (34.0357, 113.8523),
        "商丘": (34.4143, 115.6563),
        "益阳": (28.5539, 112.3552),
        "石嘴山": (38.9840, 106.3840),
        "香港": (22.3193, 114.1694),
        "澳门": (22.1987, 113.5439),
        "台北": (25.0330, 121.5654),
    ]

    /// 城市 → 坐标（内置表里有就直接用，不再查地名服务）。
    static func coordinate(for city: String) -> (lat: Double, lon: Double)? {
        knownCoordinates[city.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// 选择器里的一段（`title` = 「热门城市」或某个字母）。
    struct Section: Equatable {
        let title: String
        let cities: [String]
    }

    /// 全部候选（热门 + 其它，去重保序）。
    static var allCities: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in hot + others where seen.insert(c).inserted { out.append(c) }
        return out
    }

    /// 汉字的拼音（小写、去声调）。`CFStringTransform` 是系统自带的能力。
    static func pinyin(_ text: String) -> String {
        let m = NSMutableString(string: text) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return (m as String).lowercased()
    }

    /// 连写的拼音（去掉音节之间的空格）—— 搜索用。
    ///
    /// `CFStringTransform` 给的拼音是 `qin huang dao`（带空格），
    /// 用户输入 `qinhuang` 时直接 `contains` 是不命中的。
    static func compactPinyin(_ text: String) -> String {
        pinyin(text).replacingOccurrences(of: " ", with: "")
    }

    /// 城市名的拼音首字母（A–Z；拿不到就给 `#`）。
    static func initial(of city: String) -> String {
        guard let first = pinyin(city).first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// 按查询词过滤并分段。
    ///
    /// - 查询为空 → 「热门城市」+ 其余按首字母 A–Z；
    /// - 查询非空 → 只留匹配的城市（中文名包含 / 拼音包含），**不再分段、不显示热门组**，
    ///   因为这时用户是在找具体某个城市，堆一堆分组只会更难扫。
    static func sections(matching query: String) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            var out: [Section] = []
            if !hot.isEmpty { out.append(Section(title: "热门城市", cities: hot)) }
            // 其余按首字母分组（热门城市不再重复出现）。
            let rest = others.filter { !hot.contains($0) }
            var groups: [String: [String]] = [:]
            for city in rest {
                groups[initial(of: city), default: []].append(city)
            }
            for key in groups.keys.sorted() {
                out.append(Section(title: key, cities: groups[key]!.sorted()))
            }
            return out
        }

        let lowered = q.lowercased()
        let compact = lowered.replacingOccurrences(of: " ", with: "")
        let hits = allCities.filter { city in
            city.contains(q) || compactPinyin(city).contains(compact)
        }
        // 命中的城市仍按首字母分段，方便扫。
        var groups: [String: [String]] = [:]
        for city in hits { groups[initial(of: city), default: []].append(city) }
        return groups.keys.sorted().map {
            Section(title: $0, cities: groups[$0]!.sorted())
        }
    }

    /// 匹配到的城市总数（自检 / 空状态提示用）。
    static func matchCount(matching query: String) -> Int {
        sections(matching: query).reduce(0) { $0 + $1.cities.count }
    }
}

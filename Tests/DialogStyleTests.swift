import AppKit
import Foundation

/// 统一弹窗（`DialogStyle` / `AlertDialogRequest`）的纯逻辑测试。
///
/// 只测**规则**，不弹窗 —— `runModal` 不能进测试（会挂住测试进程）。
/// 覆盖：语义色 / 图标映射、按钮顺序、危险操作的默认焦点与 Return 绑定、
/// 滚动分支判定、请求体（列表 / 选项 / 文案）的装配规则。
enum DialogStyleTests {

    static func run() {
        suite("统一弹窗：语义分级") { testSeverity() }
        suite("统一弹窗：按钮顺序与焦点") { testButtons() }
        suite("统一弹窗：滚动分支") { testScroll() }
        suite("统一弹窗：请求装配") { testRequest() }
        suite("统一弹窗：逐门保护课确认窗") { testProtectedRemovalDialog() }
    }

    // MARK: - 语义分级 → 图标 / 颜色

    private static func testSeverity() {
        // 四级语义色（唯一真源是十六进制字符串）。
        expectEqual(DialogStyle.hex(.info), "#4f8cff", "info 用蓝色")
        expectEqual(DialogStyle.hex(.warning), "#f5a524", "warning 用琥珀色")
        expectEqual(DialogStyle.hex(.destructive), "#ef5f5b", "destructive 用红色")
        expectEqual(DialogStyle.hex(.question), "#4f8cff", "question 用蓝色")

        // 图标。
        expectEqual(DialogStyle.symbolName(.info), "info.circle.fill", "info 图标")
        expectEqual(DialogStyle.symbolName(.warning), "exclamationmark.triangle.fill", "warning 图标")
        expectEqual(DialogStyle.symbolName(.destructive), "exclamationmark.octagon.fill", "destructive 图标")
        expectEqual(DialogStyle.symbolName(.question), "questionmark.circle.fill", "question 图标")

        // 只有 destructive 算危险操作。
        expect(DialogStyle.isDestructive(.destructive), "destructive 是危险操作")
        expect(!DialogStyle.isDestructive(.warning), "warning 不是危险操作")
        expect(!DialogStyle.isDestructive(.info), "info 不是危险操作")
        expect(!DialogStyle.isDestructive(.question), "question 不是危险操作")

        // 语义色真的能转成 NSColor（hex 解析没写错）。
        let red = DialogStyle.color(.destructive)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        red.getRed(&r, green: &g, blue: &b, alpha: &a)
        expect(r > 0.8 && g < 0.45 && b < 0.45, "destructive 颜色偏红")

        // 版式常量：宽度必须落在 400–460，高度上限是屏幕的 80%。
        expect(DialogStyle.width >= 400 && DialogStyle.width <= 460,
               "弹窗宽度落在 400–460 之间（实际 \(Int(DialogStyle.width))）")
        expectEqual(DialogStyle.maxHeightRatio, 0.8, "窗口高度不超过屏幕可见区的 80%")
        expect(DialogStyle.messageMaxWidth >= 340 && DialogStyle.messageMaxWidth <= 360,
               "说明文字最大宽度落在 340–360 之间")
    }

    // MARK: - 按钮顺序 / 默认焦点 / Return

    private static func testButtons() {
        // 顺序固定：取消在左，主操作在右。
        expectEqual(DialogStyle.buttonOrder(hasCancel: true, hasPrimary: true),
                    [.cancel, .primary], "取消在左、主操作在右")
        expectEqual(DialogStyle.buttonOrder(hasCancel: true, hasPrimary: false),
                    [.cancel], "只有取消按钮")
        expectEqual(DialogStyle.buttonOrder(hasCancel: false, hasPrimary: true),
                    [.primary], "只有主操作按钮")
        expectEqual(DialogStyle.buttonOrder(hasCancel: false, hasPrimary: false),
                    [], "没有按钮")

        // 危险操作：默认焦点给「取消」，Return 不绑定主操作。
        expectEqual(DialogStyle.defaultFocus(isDestructive: true), .cancel,
                    "危险操作默认焦点给取消")
        expectEqual(DialogStyle.defaultFocus(isDestructive: false), .primary,
                    "非危险操作默认焦点给主操作")
        expect(!DialogStyle.returnTriggersPrimary(isDestructive: true),
               "危险操作 Return 不触发主操作（不能顺手删掉东西）")
        expect(DialogStyle.returnTriggersPrimary(isDestructive: false),
               "非危险操作 Return = 主操作")

        // 自绘按钮自己画白色焦点环，必须关掉系统蓝环 ——
        // 否则主按钮既是第一响应者又绑了 Return，会叠出两圈焦点环。
        let selfDrawn = DialogButton(style: .primary(color: DialogStyle.color(.warning)),
                                     title: "退出", target: nil,
                                     action: #selector(NSApplication.terminate(_:)))
        expectEqual(selfDrawn.focusRingType, .none, "自绘按钮关闭系统焦点环")
    }

    // MARK: - 滚动分支

    private static func testScroll() {
        // 5 行以内不滚。
        expect(!DialogStyle.needsScroll(itemCount: 0, messageLength: 0), "空内容不滚")
        expect(!DialogStyle.needsScroll(itemCount: 5, messageLength: 100), "5 行不滚")
        // 超过 5 行要滚。
        expect(DialogStyle.needsScroll(itemCount: 6, messageLength: 10), "6 行要滚")
        expect(DialogStyle.needsScroll(itemCount: 30, messageLength: 10), "30 行要滚")
        // 说明过长要滚（长文本单独出现时）。
        expect(DialogStyle.needsScroll(itemCount: 1, messageLength: 421), "说明 421 字要滚")
        expect(!DialogStyle.needsScroll(itemCount: 1, messageLength: 420), "说明 420 字不滚")
        // 行数 + 字数一起判断（任一超了就滚）。
        expect(DialogStyle.needsScroll(itemCount: 8, messageLength: 500), "行多字多要滚")
    }

    // MARK: - 请求装配

    private static func testRequest() {
        // 课程列表 → 课程行（顺序保持）。
        let c1 = Course(day: 1, block: 0, name: "高等数学", teacher: "李雷",
                        loc: "教三-201", courseID: "M1", weeksLabel: "1-3", weeks: [1, 2, 3])
        let c2 = Course(day: 2, block: 1, name: "大学英语", teacher: "韩梅梅",
                        loc: "外语-102", courseID: "E1", weeksLabel: "1-2", weeks: [1, 2])
        let req = AlertDialogRequest(title: "冲突", message: "两门课撞了",
                                     items: [c1, c2])
        expectEqual(req.rows.count, 2, "items 转成 2 行")
        expect(req.rows.count == 2, "行数对得上")
        if case .course(let c) = req.rows[0] {
            expectEqual(c.name, "高等数学", "第一行是高等数学")
        } else {
            expect(false, "第一行应该是课程")
        }
        if case .course(let c) = req.rows[1] {
            expectEqual(c.name, "大学英语", "第二行是大学英语")
        } else {
            expect(false, "第二行应该是课程")
        }

        // 选项行：文案 + VoiceOver 读法。
        let opt = AlertDialogOption(title: "合并到「高等数学」",
                                     detail: "并入已有的这门课")
        expectEqual(opt.spokenText, "合并到「高等数学」，并入已有的这门课",
                    "选项的 VoiceOver 读法是「标题，副文案」")
        let opt2 = AlertDialogOption(title: "新建课程",
                                     detail: nil,
                                     accessibilityLabel: "新建课程，作为一门新课加入课表")
        expectEqual(opt2.spokenText, "新建课程，作为一门新课加入课表",
                    "显式给的 accessibilityLabel 优先")

        // 按钮可见性开关。
        let onlyOne = AlertDialogRequest(title: "提示", message: "好了",
                                         showsConfirm: false, showsCancel: true)
        expect(!onlyOne.showsConfirm, "showsConfirm = false 时不显示主操作")
        expect(onlyOne.showsCancel, "showsCancel = true 时显示取消")

        // 默认文案：主操作 / 取消。
        let def = AlertDialogRequest(title: "提示", message: "好了")
        expectEqual(def.confirmTitle, "确认", "主操作默认文案")
        expectEqual(def.cancelTitle, "取消", "取消默认文案")
        expectEqual(def.severity, .info, "默认是 info 分级")
    }

    // MARK: - 逐门保护课确认窗

    /// 「导入文件里没有『课名』」那个窗：
    /// 顶部计数条、警告图标、三按钮（保留 / 删除 / 取消导入）。
    private static func testProtectedRemovalDialog() {
        let course = Course(day: 1, block: 0, name: "数据结构", teacher: "李雷",
                            loc: "教三-201", courseID: "M1", weeksLabel: "1-8",
                            weeks: [1, 2, 3, 4, 5, 6, 7, 8])
        let req = AlertDialogRequest(
            severity: .warning,
            title: "导入文件里没有「数据结构」",
            message: "这门课是「你新增」，覆盖导入不会自动删掉它。",
            rows: [.courseSummary(course, badge: "受保护")],
            counter: "第 2 门 / 共 3 门",
            primaryColor: DialogStyle.color(.question),
            buttons: [
                AlertDialogButton(role: .cancel, title: "取消导入"),
                AlertDialogButton(role: .destructive, title: "删除"),
                AlertDialogButton(role: .primary, title: "保留"),
            ])

        // 计数条。
        expectEqual(req.counter ?? "", "第 2 门 / 共 3 门", "顶部显示「第 i 门 / 共 n 门」")

        // 警告图标（琥珀），主按钮用蓝色（macOS 惯例：黄图标 + 蓝默认按钮）。
        expectEqual(req.severity, .warning, "这个窗用 warning 分级（警告图标）")
        expectEqual(DialogStyle.symbolName(req.severity), "exclamationmark.triangle.fill",
                    "警告图标是三角感叹号")

        // 课程卡片行带徽标。
        expectEqual(req.rows.count, 1, "一张课程卡片")
        if case .courseSummary(let c, let badge) = req.rows[0] {
            expectEqual(c.name, "数据结构", "卡片上的课名")
            expectEqual(badge ?? "", "受保护", "卡片上标「受保护」")
        } else {
            expect(false, "卡片行应该是 courseSummary")
        }

        // 三个按钮，顺序：取消导入 → 删除 → 保留。
        expectEqual(req.buttons?.count ?? 0, 3, "三个按钮")
        expectEqual(req.buttons?.map { $0.role } ?? [],
                    [.cancel, .destructive, .primary],
                    "按钮顺序：取消导入、删除、保留")
        expectEqual(req.buttons?.map { $0.title } ?? [],
                    ["取消导入", "删除", "保留"],
                    "按钮文案")

        // 危险按钮不绑 Return；主操作（保留）绑 Return。
        // → 默认焦点给主操作，Return 走安全的那条路。
        expectEqual(DialogStyle.defaultFocus(isDestructive: false), .primary,
                    "这个窗不是 destructive 分级，焦点给主操作（保留）")
        expect(DialogStyle.returnTriggersPrimary(isDestructive: false),
               "Return 触发主操作（保留），不是删除")

        // 按钮角色的编号不能重复（`buttonTapped` 靠 tag 分辨）。
        let tags = [DialogButtonRole.cancel, .destructive, .primary].map { $0.tagValue }
        expectEqual(Set(tags).count, 3, "三个按钮角色的 tag 互不相同")

        // 危险按钮的编号 ≠ 主操作 / 取消的编号。
        expect(DialogButtonRole.destructive.tagValue != DialogButtonRole.primary.tagValue,
               "危险按钮的 tag 不跟主操作撞")
        expect(DialogButtonRole.destructive.tagValue != DialogButtonRole.cancel.tagValue,
               "危险按钮的 tag 不跟取消撞")
    }
}

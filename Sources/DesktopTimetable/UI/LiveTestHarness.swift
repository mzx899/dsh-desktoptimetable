import AppKit

/// 实验模式 B 的自动化交互测试台（仅 DT_LIVE_TEST=1 时启用）。
///
/// 桌面层窗口是 accessory + nonactivatingPanel：
///   · 不在 cua-driver 的可点击窗口列表里（AX 不可见）；
///   · 合成 CGEvent 又需要 Accessibility 权限。
/// 所以这里改成**在 App 进程内部**造 NSEvent，走真实的 NSApp.sendEvent 路径 ———
/// 命中测试、acceptsFirstMouse、非 key 窗口的第一次点击，全都是系统真实判定。
///
/// 注意：全程 async/await，**不能**用 DispatchSemaphore.wait —— 那会堵死主线程，
/// evaluateJavaScript 的回调（跑在主线程）永远进不来，直接死锁。
enum LiveTestHarness {

    struct Result {
        var name: String
        var pass: Bool
        var detail: String
    }

    /// 测试结果落到文件。
    ///
    /// NSLog 走统一日志，`open` 启动的进程日志不一定能在 `log show` 里捞到；
    /// 写文件最可靠，也方便自动化脚本读。
    static func writeResults(_ results: [Result], mode: String) {
        let lines = results.map { r in
            "\(r.pass ? "PASS" : "FAIL")\t\(mode)\t\(r.name)\t\(r.detail)"
        }
        let header = "== \(mode) =="
        let body = (lines.isEmpty ? ["(无)"] : lines).joined(separator: "\n")
        let text = header + "\n" + body + "\n"
        let path = "/tmp/tt_live_results.txt"
        var acc = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        acc += text + "\n"
        try? acc.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 跑完一轮就退出 App —— 自动化跑测试时用。
    ///
    /// 没有这个的话 App 会一直挂在事件循环里，调用方只能靠外部 kill，
    /// 既拿不到干净的退出码，也容易把 GUI 进程留在后台。
    ///
    /// 用 `DT_LIVE_EXIT=1` 打开。
    static func exitAfterTests() {
        guard ProcessInfo.processInfo.environment["DT_LIVE_EXIT"] != nil else { return }
        // 稍等一下，让 writeResults 把文件落盘。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// live 测试会不会碰到用户真实数据？
    ///
    /// **会** —— 阶段 3 之后，App 启动时会把旧版 `schedule_data.json` 迁移成
    /// 第一份课表（写入 `timetables/<uuid>/`）。也就是说，光是启动 app 就已经
    /// 动了真实数据目录。
    ///
    /// live 测试本来只读不写（编辑器测试明确不保存），但「启动即迁移」这一步
    /// 是写操作。所以**没有设 `DT_DATA_DIR` 时直接拒绝跑 live 测试** ——
    /// **额外要求 `DT_LIVE_TEST` 的值是 "1"**：早先有人用 `launchctl setenv DT_LIVE_TEST 1`
    /// 跑 live 测试，忘了清，这个变量就**留在 launchd 全局环境**里了 ——
    /// 于是之后所有通过 Finder/`open` 启动的 app 都带着它，全都在 35ms 内 `exit(2)` 静默死掉，
    /// 表现是「双击没反应」。所以：
    ///   · 只认 `DT_LIVE_TEST=1`，其他值一律当成「没开 live 测试」；
    ///   · live 测试脚本用完必须 `launchctl unsetenv DT_LIVE_TEST` 收尾。
    ///
    /// **所有地方都走这个入口**，不要各自去读环境变量 —— 值判断不一致会让
    /// 「护栏拦下了」和「harness 却跑起来了」同时发生。
    static var isLiveTestEnabled: Bool {
        ProcessInfo.processInfo.environment["DT_LIVE_TEST"] == "1"
    }

    /// 宁可报错，也别在用户真实课表上留下副作用。
    ///
    /// 返回 nil 表示可以跑；返回原因表示不能跑。
    static func liveTestDataGuard() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard isLiveTestEnabled else { return nil }
        // **空字符串不等于已设置。** launchd 的全局环境里可能残留 `DT_DATA_DIR=`
        // （`launchctl getenv` 对「未设置」和「设为空」都返回空串），
        // 而 `env["X"] != nil` 对空串同样成立 —— 那样护栏就被绕过了，
        // app 会带着空路径去跑，然后在真实数据目录上留下副作用。
        if let dir = env["DT_DATA_DIR"], !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }
        return "live 测试需要设 DT_DATA_DIR 指向临时目录 —— 不设的话 app 启动就会把"
            + "真实课表迁移成 timetables/<uuid>/，会在用户数据上留下副作用。"
    }

    /// 跑一轮完整测试，结果写进日志。
    static func run(app: AppDelegate, renderer: WebCardRenderer, window: NSWindow) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var results: [Result] = []

            // **先看有没有课可测。**
            //
            // 空课表启动（比如 DT_DATA_DIR 指到一个空目录）的话，网页只渲染出
            // 70 个空格子、0 门课，于是「点击课程格」「悬停课程格」「右键出课程菜单」
            // 「查看详情」「编辑器窗口」这一批会集体 FAIL —— 那是「没东西可点」，
            // 不是代码坏了。必须在这里就说清楚，别让人以为测出了 5 个 bug。
            let courseCount = app.testCourses.count
            if courseCount == 0 {
                NSLog("[TT-TEST] 当前课表是空的（0 门课），live 测试无法进行")
                NSLog("[TT-TEST] 如果这是意外：检查 DT_DATA_DIR 指向的目录里有没有 schedule_data.json")
                let results = [Result(name: "课表非空", pass: false,
                                      detail: "当前课表 0 门课 —— 测试环境没数据，不是功能故障")]
                writeResults(results, mode: "B")
                exitAfterTests()
                return
            }
            NSLog("[TT-TEST] 当前课表 %d 门课，开始测试", courseCount)

            let wasActive = NSApp.isActive
            NSLog("[TT-TEST] 前置：app.isActive=%@ window.isKeyWindow=%@ window.isMainWindow=%@",
                  wasActive ? "true" : "false",
                  window.isKeyWindow ? "true" : "false",
                  window.isMainWindow ? "true" : "false")

            // 顺序很重要：齿轮会 openSettings() → NSApp.activate()，会污染焦点状态，
            // 所以齿轮放最后跑。
            // 坐标一律从 DOM 现取（centerOf），不写死像素 —— 标题文案一变布局就挪位。
            let arrowNext = await centerOf(selector: ".arrow:not(.dis)", renderer: renderer)
            let arrowPoint = arrowNext ?? NSPoint(x: 503, y: 129)

            results.append(await testClick(renderer: renderer, window: window,
                                          cssPoint: NSPoint(x: 232, y: 309),
                                          name: "点击课程单元格",
                                          js: "!!(window.ttHasSelection && window.ttHasSelection())",
                                          check: { ($0 as? Bool) == true }))

            // 焦点：点课程格时（不开新窗口）App 绝不能变成 active
            results.append(await testFocusNoSteal(renderer: renderer, window: window,
                                                  cssPoint: NSPoint(x: 232, y: 309)))

            results.append(await testHover(renderer: renderer, window: window,
                                          cssPoint: NSPoint(x: 232, y: 309),
                                          name: "悬停课程格"))

            // 实验性兜底：原生主动把指针位置送进网页 → .tt-hover 类
            results.append(await testLiveHoverSync(renderer: renderer, window: window,
                                                  cssPoint: NSPoint(x: 232, y: 309)))

            results.append(await testRightClick(renderer: renderer, window: window,
                                               cssPoint: NSPoint(x: 232, y: 309),
                                               name: "右键"))

            results.append(await testRightClickMenu(app: app, renderer: renderer, window: window,
                                                    cssPoint: NSPoint(x: 232, y: 309),
                                                    name: "右键 → 原生菜单"))

            results.append(await testEmptySlotMenu(app: app, renderer: renderer, window: window))

            results.append(await testDetailOverlay(app: app, renderer: renderer, window: window))

            results.append(await testHitConsistency(app: app, renderer: renderer, window: window))

            results.append(await testGeometryParity(app: app, renderer: renderer, window: window))

            results.append(await testEditorWindow(app: app))

            results.append(testPassthrough(window: window, name: "四角点击穿透"))

            // 箭头用例放这里（而不是开头）：点箭头会**真的**翻周，
            // 而上面几条用的是写死坐标 (232, 309)，翻周后那个格子可能就没课了。
            // 放最后就不会污染它们。
            results.append(await testClick(renderer: renderer, window: window,
                                          cssPoint: arrowPoint,
                                          name: "点击下一周箭头",
                                          js: "window.__ttTestWeekDelta || 0",
                                          check: { (($0 as? Int) ?? 0) != 0 }))
            // 上一条只证明「JS 收到了点击」，不证明画面真的变了。
            results.append(await testWeekArrowFeedback(renderer: renderer, window: window))

            // 齿轮放最后
            let gearPoint = await centerOf(selector: ".setbtn", renderer: renderer)
                ?? NSPoint(x: 1022, y: 129)
            results.append(await testClick(renderer: renderer, window: window,
                                          cssPoint: gearPoint,
                                          name: "点击齿轮（打开设置）",
                                          js: "!!(window.__ttTestSettingsOpened)",
                                          check: { ($0 as? Bool) == true }))
            app.closeSettingsForTest()

            for r in results {
                NSLog("[TT-TEST] %@ %@ — %@", r.pass ? "PASS" : "FAIL", r.name, r.detail)
            }
            let failed = results.filter { !$0.pass }.count
            NSLog("[TT-TEST] 合计 %d 项，失败 %d 项", results.count, failed)
            writeResults(results, mode: "B")
            exitAfterTests()
        }
    }

    /// 编辑器窗口测试：打开后必须是 key window、首响应在课名输入框（Cmd+C/V/Z 才可用）。
    ///
    /// **不保存**：live 测试跑的是用户真实课表，改名会污染真实数据。
    /// 写盘链路由单元测试在临时目录里覆盖（见 Tests 的「右键编辑 · 写盘链路」）。
    @MainActor
    private static func testEditorWindow(app: AppDelegate) async -> Result {
        guard let course = app.testCourses.first else {
            return Result(name: "编辑器窗口", pass: false, detail: "没有课程可编辑")
        }
        guard let editor = app.testOpenEditor(courseID: course.courseID) else {
            return Result(name: "编辑器窗口", pass: false, detail: "编辑器没打开")
        }
        await sleep(900)

        // **先量编辑器自己的状态，再动对照组。**
        //
        // 顺序很重要：打开设置面板会把 key 窗口抢走，关掉设置面板也**不会**把
        // key 还给编辑器（AppKit 只把 key 给下一个能接手的窗口，没有"归还"这回事）。
        // 所以如果先开对照组再回头量编辑器，量到的必然是 key=false ——
        // 那是测量顺序造成的假象，不是编辑器的问题。
        //
        // 反过来，对照组仍然能告诉我们「这个环境到底能不能拿到 key」：
        // 它是在编辑器已经量完之后才打开的，量的是「设置面板自己能不能拿 key」。
        let keyOK = editor.isKeyAndFocused
        let focusOK = editor.hasNameFieldFocus
        let draft = editor.currentDraft()
        // 预填必须和这条记录**完全一致**（课名 / 星期 / 节次 / 周次）——
        // 周次尤其关键：以前打开的是同一门课的第一个上课时间，周次会变成别的。
        let filled = draft.name == course.name && draft.day == course.day
            && draft.block == course.block && draft.weeks == course.weeks
        let state = editor.testWindowState

        // 对照组：设置面板用的是同一套激活逻辑（makeKeyAndOrderFront + NSApp.activate）。
        // 它在终端启动的环境下能不能拿到 key，决定了 key=false 是环境问题还是编辑器问题。
        app.testOpenSettings()
        await sleep(700)
        let settingsKey = NSApp.keyWindow?.isKeyWindow ?? false
        let settingsVisible = NSApp.windows.first { $0.identifier?.rawValue == "settings" }?.isVisible
        app.testCloseSettings()

        editor.close()

        // 判定要分清两种「拿不到焦点」：
        //
        //   A. 环境限制：从终端拉起的 app 拿不到前台，**任何**窗口都成不了 key
        //      （对照组设置面板同样 key=no）。这时候编辑器的 focus=no 不是 bug。
        //   B. 真 bug：设置面板能拿 key，编辑器拿不到 —— 编辑器的激活逻辑有问题。
        //
        // 只看编辑器自己分不出来，所以必须看对照组：
        //   · 对照组也 key=no → 环境限制（focusOK 往往为 false），记为通过 + 注明
        //   · 对照组 key=ok  但 focus=no → 真 bug，判失败
        //
        // 预填（filled）无论哪种情况都必须成立 —— 那是纯逻辑，不受焦点影响。
        let envLimited = !settingsKey
        let pass: Bool
        if focusOK {
            pass = filled
        } else if envLimited {
            // 环境限制下 focus 拿不到是预期的；但预填错了仍然是真问题。
            pass = filled
        } else {
            pass = false
        }

        let note = envLimited && !focusOK
            ? "（终端启动环境拿不到前台，对照组设置面板同样 key=no —— 焦点项按环境限制处理）"
            : ""
        return Result(name: "编辑器窗口", pass: pass,
                      detail: "key窗口=\(keyOK ? "ok" : "no") 输入框有焦点=\(focusOK ? "ok" : "no") "
                        + "预填=\(filled ? "ok" : "no") [\(state)] "
                        + "对照组设置面板 key=\(settingsKey ? "ok" : "no") visible=\(settingsVisible == true)"
                        + note)
    }

    /// A 模式（快照管线）下的右键链路测试。
    ///
    /// A 模式网页不直接上屏，右键落在原生卡片上：
    ///   原生 rightMouseDown → 问网页 DOM 命中 → 弹原生菜单。
    static func runSnapshotMode(app: AppDelegate, renderer: WebCardRenderer, window: NSWindow) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            var results: [Result] = []

            results.append(await testRightClickMenu(app: app, renderer: renderer, window: window,
                                                    cssPoint: NSPoint(x: 232, y: 309),
                                                    name: "A 模式右键 → 原生菜单"))

            results.append(await testHitConsistency(app: app, renderer: renderer, window: window))

            for r in results {
                NSLog("[TT-TEST] %@ %@ — %@", r.pass ? "PASS" : "FAIL", r.name, r.detail)
            }
            let failed = results.filter { !$0.pass }.count
            NSLog("[TT-TEST] A 模式合计 %d 项，失败 %d 项", results.count, failed)
            writeResults(results, mode: "A")
            exitAfterTests()
        }
    }


    /// 右键空白格 → 菜单应该是「新增课程… / 学期设置… / 导入课表…」。
    @MainActor
    private static func testEmptySlotMenu(app: AppDelegate, renderer: WebCardRenderer,
                                          window: NSWindow) async -> Result {
        // 找一个真正空的格子（网页 DOM 里没有 .course 的 .cell）
        let js = """
        (function () {
          var cells = document.querySelectorAll('.cell[data-day]');
          for (var i = 0; i < cells.length; i++) {
            var c = cells[i];
            if (!c.classList.contains('course')) {
              var r = c.getBoundingClientRect();
              return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2,
                                      day: parseInt(c.dataset.day,10),
                                      block: parseInt(c.dataset.block,10)});
            }
          }
          return "";
        })();
        """
        let raw = await evalJS(renderer, js)
        guard let s = raw as? String, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = obj["x"] as? Double, let y = obj["y"] as? Double else {
            return Result(name: "右键空白格 → 菜单", pass: false, detail: "找不到空格")
        }

        app.testLastMenuTitles = []
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: x, y: h - y)
        send(.rightMouseDown, at: windowPoint, window: window)
        send(.rightMouseUp, at: windowPoint, window: window)
        await sleep(900)

        let titles = app.testLastMenuTitles
        let want = ["新增课程", "学期设置", "导入课表"]
        let missing = want.filter { w in !titles.contains { $0.contains(w) } }
        let diag = await webStateDiagnostic(renderer)
        return Result(name: "右键空白格 → 菜单", pass: missing.isEmpty,
                      detail: "菜单项=\(titles.joined(separator: " / "))"
                        + (missing.isEmpty ? "" : " 缺少=\(missing)") + diag)
    }

    /// 右键课程 → 「查看详情」要在网页上打开浮层（B 模式）。
    @MainActor
    private static func testDetailOverlay(app: AppDelegate, renderer: WebCardRenderer,
                                          window: NSWindow) async -> Result {
        let js = """
        (function () {
          window.ttCloseSelection && window.ttCloseSelection();
          var c = document.querySelector('.cell.course[data-cid]');
          if (!c) return "no-course";
          var r = c.getBoundingClientRect();
          return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2});
        })();
        """
        let raw = await evalJS(renderer, js)
        guard let s = raw as? String, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = obj["x"] as? Double, let y = obj["y"] as? Double else {
            return Result(name: "查看详情 → 网页浮层", pass: false, detail: "取不到课程格")
        }

        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: x, y: h - y)
        send(.rightMouseDown, at: windowPoint, window: window)
        send(.rightMouseUp, at: windowPoint, window: window)
        await sleep(900)

        // 菜单弹出后，模拟选中「查看详情」
        app.testSelectMenuItem(0)
        await sleep(900)

        let shown = await evalJS(renderer, "!!(window.ttHasSelection && window.ttHasSelection())")
        // 详情浮层是盖住整张卡片的遮罩，不关掉的话后面的点击全被它吃掉
        _ = await evalJS(renderer, "window.ttCloseSelection && window.ttCloseSelection()")
        await sleep(300)
        return Result(name: "查看详情 → 网页浮层", pass: (shown as? Bool) == true,
                      detail: "浮层打开=\((shown as? Bool) == true ? "ok" : "no，\(String(describing: shown))")")
    }

    /// 按 CSS 选择器取元素的中心点（CSS 坐标）。
    ///
    /// 硬编码像素坐标太脆 —— 标题文案一改，布局就挪位，
    /// 测试会莫名其妙地 FAIL。这里直接问 DOM 要位置。
    @MainActor
    private static func centerOf(selector: String, renderer: WebCardRenderer) async -> NSPoint? {
        let js = """
        (function () {
          var el = document.querySelector('\(selector)');
          if (!el) return "";
          var r = el.getBoundingClientRect();
          return JSON.stringify({x: r.x + r.width/2, y: r.y + r.height/2});
        })();
        """
        let raw = await evalJS(renderer, js)
        guard let s = raw as? String, !s.isEmpty, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
        return NSPoint(x: x, y: y)
    }

    // MARK: - 工具


    private static func sleep(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    /// 执行一段 JS 并取回结果（主线程 await，不阻塞 run loop）
    @MainActor
    private static func evalJS(_ renderer: WebCardRenderer, _ js: String) async -> Any? {
        await withCheckedContinuation { cont in
            renderer.webView.evaluateJavaScript(js) { value, error in
                if let error {
                    NSLog("[TT-TEST] JS 出错：%@", error.localizedDescription)
                }
                cont.resume(returning: error == nil ? value : nil)
            }
        }
    }

    /// 派发一次真实的 NSApp 事件（走系统的命中测试 / acceptsFirstMouse 判定）
    @MainActor
    private static func send(_ type: NSEvent.EventType, at windowPoint: NSPoint,
                             window: NSWindow, clickCount: Int = 1) {
        guard let ev = NSEvent.mouseEvent(with: type,
                                           location: windowPoint,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber,
                                           context: nil,
                                           eventNumber: 0,
                                           clickCount: clickCount,
                                           pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1) else { return }
        NSApp.sendEvent(ev)
    }

    /// 先给网页装上探针（记录意图/选中/右键），再点
    @MainActor
    private static func installProbes(_ renderer: WebCardRenderer) async {
        let js = """
        if (!window.__ttTestInstalled) {
          window.__ttTestInstalled = true;
          var __origPost = window.webkit.messageHandlers.tt.postMessage.bind(window.webkit.messageHandlers.tt);
          window.webkit.messageHandlers.tt.postMessage = function (msg) {
            if (msg && msg.action === 'openSettings') window.__ttTestSettingsOpened = true;
            if (msg && msg.action === 'week') window.__ttTestWeekDelta = (window.__ttTestWeekDelta || 0) + (msg.payload || 0);
            if (msg && msg.action === 'contextmenu') window.__ttTestContextMenu = true;
            if (msg && msg.action === 'select') window.__ttTestSelected = true;
            return __origPost(msg);
          };
        }
        window.__ttTestSettingsOpened = false;
        window.__ttTestWeekDelta = 0;
        window.__ttTestContextMenu = false;
        window.__ttTestSelected = false;
        """
        _ = await evalJS(renderer, js)
    }

    @MainActor
    private static func testClick(renderer: WebCardRenderer, window: NSWindow,
                                  cssPoint: NSPoint, name: String,
                                  js: String, check: @escaping (Any?) -> Bool) async -> Result {
        await installProbes(renderer)
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: cssPoint.x, y: h - cssPoint.y)
        let hit = window.contentView!.hitTest(windowPoint)
        let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"
        NSLog("[TT-TEST] %@：命中视图=%@", name, hitName)

        let activeBefore = NSApp.isActive
        send(.leftMouseDown, at: windowPoint, window: window)
        send(.leftMouseUp, at: windowPoint, window: window)
        await sleep(700)
        let activeAfter = NSApp.isActive

        let value = await evalJS(renderer, js)
        let pass = check(value)
        return Result(name: name, pass: pass,
                      detail: "命中=\(hitName) 探针=\(String(describing: value)) "
                            + "焦点 \(activeBefore ? "active" : "inactive")→\(activeAfter ? "active" : "inactive")")
    }

    /// 点箭头之后，**周次胶囊上的文字必须真的变**。
    ///
    /// 为什么要这条：旧用例只探「JS 收到点击」（`__ttTestWeekDelta`）。
    /// 曾经有个 bug 就是在这里漏过去的 —— 原生推给网页的 `viewWeek` 是字符串 `"9"`，
    /// 网页判 `typeof === 'number'` 永远 false，于是原生改了周次重推、网页照样显示
    /// 「全部周次」，而 `__ttTestWeekDelta` 照样加 1，用例 PASS。
    /// 用户看到的是「按下去没反应」。
    ///
    /// **测完必须把周次点回去。** 后面的用例用的是写死坐标 `(232, 309)`，
    /// 那是「第 N 周」里某个有课的格子；多翻一周它可能就变成空格子，
    /// 于是「悬停课程格」之类的用例会莫名其妙 Failure —— 那是本用例留下的副作用。
    @MainActor
    private static func testWeekArrowFeedback(renderer: WebCardRenderer, window: NSWindow) async -> Result {
        let chipJS = "document.querySelector('.wkchip') ? document.querySelector('.wkchip').textContent : ''"

        func clickArrow(_ which: String) async -> Bool {
            let js = "(function(){var a=document.querySelectorAll('.arrow:not(.dis)');"
                + "if(!a.length) return '';"
                + "var el=\(which); if(!el) return '';"
                + "var r=el.getBoundingClientRect();"
                + "return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2});})()"
            guard let raw = await evalJS(renderer, js) as? String, !raw.isEmpty,
                  let d = raw.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let x = o["x"] as? Double, let y = o["y"] as? Double else { return false }
            let h = window.contentView!.bounds.height
            let wp = NSPoint(x: x, y: h - y)
            send(.leftMouseDown, at: wp, window: window)
            send(.leftMouseUp, at: wp, window: window)
            await sleep(700)
            return true
        }

        let before = (await evalJS(renderer, chipJS) as? String) ?? ""
        // 点「上一周」
        let clicked = await clickArrow("a[0]")
        let after = (await evalJS(renderer, chipJS) as? String) ?? ""
        // 点回来，别给后面的用例留下「周次被改过」的状态
        if clicked { _ = await clickArrow("a[a.length-1]") }
        let restored = (await evalJS(renderer, chipJS) as? String) ?? ""

        let moved = !before.isEmpty && before != after
        let back = restored == before
        return Result(name: "箭头 → 周次文字真的变了",
                      pass: moved && back,
                      detail: "点击前='\(before)' 点击后='\(after)' 点回来='\(restored)'"
                            + (back ? "" : "（没能恢复原周次，后续用例可能受影响）"))
    }

    @MainActor
    private static func testHover(renderer: WebCardRenderer, window: NSWindow,
                                  cssPoint: NSPoint, name: String) async -> Result {
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: cssPoint.x, y: h - cssPoint.y)
        send(.mouseMoved, at: windowPoint, window: window)
        await sleep(600)

        let js = """
        (function () {
          var cs = document.querySelectorAll(':hover');
          var names = [];
          for (var i = 0; i < cs.length; i++) names.push(cs[i].className || cs[i].tagName);
          var tt = document.querySelector('.tt-hover');
          return ':hover=' + cs.length + '[' + names.join(',') + '] tt-hover=' + (tt ? (tt.className||tt.tagName) : 'none');
        })();
        """
        let info = String(describing: await evalJS(renderer, js) ?? "n/a")
        // :hover 生效，或者原生同步的 .tt-hover 生效，都算悬停可用
        let pass = !(info.contains(":hover=0[") && info.contains("tt-hover=none"))
        return Result(name: name, pass: pass, detail: info)
    }

    @MainActor
    private static func testRightClick(renderer: WebCardRenderer, window: NSWindow,
                                       cssPoint: NSPoint, name: String) async -> Result {
        await installProbes(renderer)
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: cssPoint.x, y: h - cssPoint.y)
        send(.rightMouseDown, at: windowPoint, window: window)
        send(.rightMouseUp, at: windowPoint, window: window)
        await sleep(700)

        let value = await evalJS(renderer, "window.__ttTestContextMenu || false")
        let pass = (value as? Bool) == true
        return Result(name: name, pass: pass, detail: "网页收到右键=\(String(describing: value))")
    }

    /// 几何偏差观测（不作为通过条件）。
    ///
    /// 原生 TimetableLayout 算出来的格子矩形和网页实际布局有 ~7px 偏差
    /// （原生卡片高 782、网页卡片高 775）。
    /// 正因为有这个偏差，A 模式的右键命中改成问网页 DOM（见 AppDelegate.showNativeMenu），
    /// 原生几何只当网页不可用时的兜底。
    /// 这个测试只把偏差量记下来，方便以后对齐两套布局。
    @MainActor
    private static func testGeometryParity(app: AppDelegate, renderer: WebCardRenderer,
                                           window: NSWindow) async -> Result {
        let js = """
        (function () {
          var out = [];
          document.querySelectorAll('.cell.course[data-day]').forEach(function (c) {
            var r = c.getBoundingClientRect();
            out.push({
              x: r.x, y: r.y, w: r.width, h: r.height,
              day: parseInt(c.dataset.day, 10),
              block: parseInt(c.dataset.block, 10)
            });
          });
          return JSON.stringify(out);
        })();
        """
        let raw = await evalJS(renderer, js)
        guard let rawStr = raw as? String, let data = rawStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !arr.isEmpty else {
            return Result(name: "原生/网页几何偏差（观测）", pass: true, detail: "取不到网页格子")
        }

        let h = window.contentView!.bounds.height
        var worst = 0.0
        var checked = 0
        for item in arr {
            guard let wx = item["x"] as? Double, let wy = item["y"] as? Double,
                  let ww = item["w"] as? Double, let wh = item["h"] as? Double,
                  let day = item["day"] as? Int, let block = item["block"] as? Int else { continue }
            // 网页矩形（从上往下） → 原生矩形（从下往上）
            let webRect = NSRect(x: wx, y: h - wy - wh, width: ww, height: wh)
            let nativeRect = TimetableLayout.courseRect(block: block, day: day)
            let d = max(abs(webRect.minX - nativeRect.minX),
                        max(abs(webRect.minY - nativeRect.minY),
                            max(abs(webRect.width - nativeRect.width),
                                abs(webRect.height - nativeRect.height))))
            checked += 1
            worst = max(worst, d)
        }
        return Result(name: "原生/网页几何偏差（观测）", pass: true,
                      detail: "抽样 \(checked) 个格子，最大偏差 \(String(format: "%.1f", worst))px"
                        + "（A 模式命中以网页 DOM 为准，此项仅供观测）")
    }

    /// 一致性测试：原生命中测试（TimetableLayout 网格几何）
    /// 必须与网页 DOM 命中测试（.cell 的 dataset）在同一批点上给出同一个 day/block。
    ///
    /// A 模式用原生命中、B 模式用网页命中，两者必须一致，
    /// 否则「同一个格子右键」在两种模式下会弹出不同的菜单。
    @MainActor
    private static func testHitConsistency(app: AppDelegate, renderer: WebCardRenderer,
                                           window: NSWindow) async -> Result {
        // 挑几个网页里真实存在的格子：周一~周三的几门课
        let webPoints = """
        (function () {
          var out = [];
          document.querySelectorAll('.cell[data-day]').forEach(function (c) {
            var r = c.getBoundingClientRect();
            if (out.length < 12) {
              out.push({
                x: Math.round(r.x + r.width / 2),
                y: Math.round(r.y + r.height / 2),
                day: parseInt(c.dataset.day, 10),
                block: parseInt(c.dataset.block, 10)
              });
            }
          });
          return JSON.stringify(out);
        })();
        """
        let raw = await evalJS(renderer, webPoints)
        guard let rawStr = raw as? String, let data = rawStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !arr.isEmpty else {
            return Result(name: "原生/网页命中一致", pass: false, detail: "取不到网页格子")
        }

        let h = window.contentView!.bounds.height
        var mismatches: [String] = []
        for item in arr {
            guard let cx = item["x"] as? Double, let cy = item["y"] as? Double,
                  let wday = item["day"] as? Int, let wblock = item["block"] as? Int else { continue }
            // 网页坐标（从上往下） → 视图坐标（从下往上）
            let viewPoint = NSPoint(x: cx, y: h - cy)
            guard let hit = app.testSlotHit(at: viewPoint) else {
                mismatches.append("(\(Int(cx)),\(Int(cy))) 原生没命中，网页=day\(wday)/block\(wblock)")
                continue
            }
            if hit.day != wday || hit.block != wblock {
                mismatches.append("(\(Int(cx)),\(Int(cy))) 原生=day\(hit.day)/block\(hit.block) 网页=day\(wday)/block\(wblock)")
            }
        }
        return Result(name: "原生/网页命中一致", pass: mismatches.isEmpty,
                      detail: mismatches.isEmpty
                        ? "抽样 \(arr.count) 个格子全部一致"
                        : "不一致 \(mismatches.count) 处：\(mismatches.prefix(4).joined(separator: "; "))")
    }

    /// 右键 → 原生弹出右键菜单（验证网页 → 原生的 contextmenu 链路）。
    @MainActor
    private static func testRightClickMenu(app: AppDelegate, renderer: WebCardRenderer, window: NSWindow,
                                           cssPoint: NSPoint, name: String) async -> Result {
        app.testLastMenuTitles = []
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: cssPoint.x, y: h - cssPoint.y)
        send(.rightMouseDown, at: windowPoint, window: window)
        send(.rightMouseUp, at: windowPoint, window: window)
        await sleep(900)

        let titles = app.testLastMenuTitles
        let pass = !titles.isEmpty
        let diag = await webStateDiagnostic(renderer)
        return Result(name: name, pass: pass,
                      detail: "菜单项=\(titles.joined(separator: " / "))" + diag)
    }

    /// 网页到底渲染出来没有？
    ///
    /// 右键菜单为空有两种完全不同的原因：
    ///   1. 状态没推过去 → 网页里一个格子都没有 → 右键命中的是空白 → 没有菜单项；
    ///   2. 菜单逻辑坏了 → 网页有格子、有命中，但菜单没弹出来。
    ///
    /// 这两种的修法完全相反（1 是数据推送问题，2 是菜单代码问题），
    /// 光看「菜单项=」分不出来。所以失败时必须把网页状态一起报出来。
    @MainActor
    private static func webStateDiagnostic(_ renderer: WebCardRenderer) async -> String {
        let cells = await evalJS(renderer, "document.querySelectorAll('.cell').length") ?? "?"
        let courses = await evalJS(renderer, "document.querySelectorAll('.cell.course').length") ?? "?"
        let titles = await evalJS(renderer, "document.querySelectorAll('.ttl').length") ?? "?"
        return " [网页格子=\(cells) 课程块=\(courses) 标题元素=\(titles)]"
    }

    /// 焦点测试：点课程格（不会开新窗口）时，App 绝不能变成 active。
    /// 注意不能拿「点齿轮」来测 —— 齿轮会 openSettings()，那是**故意**要激活的。
    @MainActor
    private static func testFocusNoSteal(renderer: WebCardRenderer, window: NSWindow,
                                         cssPoint: NSPoint) async -> Result {
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: cssPoint.x, y: h - cssPoint.y)
        let before = NSApp.isActive
        send(.leftMouseDown, at: windowPoint, window: window)
        send(.leftMouseUp, at: windowPoint, window: window)
        await sleep(700)
        let after = NSApp.isActive
        let keyAfter = window.isKeyWindow
        return Result(name: "不抢焦点（点课程格后 App 仍未激活）",
                      pass: !before && !after,
                      detail: "app.isActive \(before ? "active" : "inactive")→\(after ? "active" : "inactive")"
                            + "，window.isKeyWindow=\(keyAfter)")
    }

    /// 实验性兜底方案：原生把指针位置算好后送进网页（window.ttLiveHover）。
    /// 这条路径**不依赖** webView 收到 mouseMoved —— 是非 key 窗口下的保险。
    @MainActor
    private static func testLiveHoverSync(renderer: WebCardRenderer, window: NSWindow,
                                          cssPoint: NSPoint) async -> Result {
        // 先清掉所有悬停态
        renderer.clearLiveHover()
        await sleep(200)
        let before = String(describing: await evalJS(renderer,
            "document.querySelectorAll('.tt-hover').length") ?? "?")

        // 走原生的坐标换算 + 派发路径
        let h = window.contentView!.bounds.height
        let windowPoint = NSPoint(x: cssPoint.x, y: h - cssPoint.y)
        renderer.forwardLiveHover(at: windowPoint)
        await sleep(400)

        let after = String(describing: await evalJS(renderer, """
        (function () {
          var els = document.querySelectorAll('.tt-hover');
          var names = [];
          for (var i = 0; i < els.length; i++) names.push(els[i].className);
          return els.length + '[' + names.join(',') + ']';
        })();
        """) ?? "?")

        let count = Int(after.prefix(while: { $0.isNumber })) ?? 0
        let pass = count > 0
        return Result(name: "悬停兜底（原生同步 → .tt-hover 类）",
                      pass: pass,
                      detail: "同步前 .tt-hover 数量=\(before)，同步后=\(after)")
    }

    private static func testPassthrough(window: NSWindow, name: String) -> Result {
        let b = window.contentView!.bounds
        let corners: [(String, NSPoint)] = [
            ("左上", NSPoint(x: 5, y: b.height - 5)),
            ("右上", NSPoint(x: b.width - 5, y: b.height - 5)),
            ("左下", NSPoint(x: 5, y: 5)),
            ("右下", NSPoint(x: b.width - 5, y: 5)),
        ]
        var detail: [String] = []
        var allNil = true
        for (label, p) in corners {
            let hit = window.contentView!.hitTest(p)
            if hit != nil { allNil = false }
            detail.append("\(label)=\(hit == nil ? "nil(穿透)" : String(describing: type(of: hit!)))")
        }
        return Result(name: name, pass: allNil, detail: detail.joined(separator: " "))
    }
}

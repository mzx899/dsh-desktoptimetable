# 更新日志 · Changelog

## [未发布]

### 弹窗文案精简：导入决策不再把同一段说明写两遍；删除整门课程的按钮改叫「删除」

用户原话（2026-11-09 晚，附「当前已经有课表了」截图）：

> 「你这种警告的文字叙述太多了，删减一点，让它变得更简约美观，
> 包括点击删除整门课的时候，红色的按键不要叫删除整门课，就叫删除」

#### 现象

- 导入时「当前已经有课表了」那张弹窗：正文先列了三行清单
  （`· 覆盖当前课表（推荐）：…`、`· 新建一份独立课表：…`、`· 取消：…`），
  **下面两张选项卡又把同样的话各写了一遍** → 同一段说明读两遍，弹窗又高又密；
- 「删除整门课程」确认框正文里「N 条上课时间记录将被删除」说了两遍，
  红色按钮还重复写着「删除整门课程」（标题里已经有这五个字）。

#### 修复

- `UI/ImportDecisionController.swift`：新增 **`decisionRequest(name:courseCount:loadError:)`**
  作为**唯一真源** —— 正文只说「「我的课表」里已有 10 门课。」，
  两张选项卡的说明各一句：
  - 覆盖：`用导入结果更新当前课表，冲突时再问你`
  - 新建：`另存一份，当前课表不动`

  读文件出错那种情况保留下三件事（读不到全部 → 能读到几门 → 覆盖前自动备份）。
- `UI/ScheduleEditorController.swift`：整门课程删除的正文压成两行
  （`会删掉 N 个上课时间记录，此操作不可撤销。` / `笔记会保留（变成孤立笔记）。`），
  **红色按钮 `删除整门课程` → `删除`**（标题 `删除整门课程「X」？` 不变，语义没丢）。
- `main.swift` 的 `--shot-alert-dialog` 增加 `import` / `import-error` 两种出图，
  直接调用 `decisionRequest` —— 出图和真机**同一份文案**，不会各写一套。

#### 自检

- 出图：`--shot-alert-dialog x import` / `x import-error` / `x course`
  （真机 `screencapture -l` 抓窗口）：导入弹窗从「正文清单 + 卡片说明」的重复，
  变成「一行说明 + 两张卡片」；删除整门课程的按钮显示「删除」；
- `make test`：**2057 项断言全过**；
- `--verify-import-flow`：通过（覆盖导入 / 逐条冲突 / 写盘 / 焦点恢复）。

### 导入决策的选项卡改成铺满内容区（左右留白对称）

用户原话（2026-11-09 晚）：

> 「这个的覆盖当前课表和新建一份独立的课表，为什么不处于窗口的中间位置，
> 明显是右边留白更多，左边少」

#### 根因

`AlertDialogController.makeOptions` 只给 **stack** 定了宽度（内容宽 392pt），
`alignment = .leading`；而 `DialogOptionRow` 是 `NSButton` —— 它的宽度取
**标题文字的自然宽度**，于是卡片比内容区窄一截、还靠左：
实测卡片左边缘 49pt、右边缘 686pt（窗口 880/2=440 点宽），右边多出约 70pt 空白。

#### 修复

给每一行加 `row.widthAnchor.constraint(equalToConstant: width)` ——
选项卡铺满内容宽，左右留白对称（实测左 49 / 右 51 像素，误差来自 1pt 描边）。

#### 自检

- `--shot-alert-dialog x import`：卡片左右留白对称
  （`docs/archive/shots-1.4.8/导入决策-选项卡居中.png`）；
- `make test`：**2057 项断言全过**；`--verify-import-flow`：通过。

### 设置 → 课表 →「课表数据」两个按钮：加符号、去省略号、等宽

用户原话（2026-11-09 晚，附截图）：

> 「这个导入课表和在访谈中显示，在他们俩之前加点符号，就是每个之前加一个符号，
> 然后导入课表，最后把省略号给去掉，并把这两个的框变得一样长」

#### 现象

「导入课表…」和「在访达中显示」是两颗普通 `NSButton`：**没有图标**、
「导入课表」带省略号、两颗按钮各自按文字自然宽度收缩（一个宽一个窄）。

#### 修复（`UI/SettingsWindowController.swift`）

- 改用 `makeIconButton`（「课表」卡片那排「新建 / 重命名 / 删除 / 管理」同款）：
  导入课表 = `square.and.arrow.down`，在访达中显示 = `folder`；
- 标题 `导入课表…` → **`导入课表`**（这里是直接动作，不是「还要问一句」）；
- 两颗按钮宽度都钉成 `126pt` —— 不再各按文字宽收缩。

#### 自检

- **新增 `--verify-data-buttons`**（只读界面，不触发导入 / 不打开访达）：
  实测 `导入=「导入课表」图标=true 宽=126 可用=true`、`访达=「在访达中显示」图标=true 宽=126`；
- `--shot-settings <png> timetable-data` 出新截图
  （`DT_SHOT_SCREEN=1` 时走 `screencapture -l` 真机抓图；离屏渲染看不到材质，整体发灰）；
- `make test`：**2062 项断言全过**。

### 导入冲突那个大列表窗口：以前**整页空白**，现在能看见列表了

用户原话（2026-11-09 晚）：

> 「那个在导入课表时检测到有冲突，然后弹出来的一大页的，就是一个大窗口显示的
> 全部有冲突的列表。那个窗口你能不能调出来」

#### 现象 / 根因

为了把窗口调出来核对外观，先加了 `--shot-import-diff`（走
`AppDelegate.testStartOverwriteImport` 的**真实接线**，假数据造在 `DT_DATA_DIR`）。
抓图发现：窗口只有顶部摘要 / 批量按钮 / 底部「取消 / 应用」，**中间列表一片空白**。

探针实测：列表里 **8 行都在**（`fittingSize = 338.5 × 745`），
但承载它们的 `documentView` frame 是 **(0, 0, 0, 0)** ——
`scrollView.documentView = stack` 之后没有任何约束 / frame 设置，
`NSStackView` 自己不会撑开，于是整块列表没有可视区域。

#### 修复（`UI/TimetableDiffWindowController.swift`）

- document view 换成一个**翻转**的容器（`FlippedDocumentView`，`isFlipped = true`），
  把 `stack` 四边钉在它上面，并让容器宽度跟随 `scrollView.contentView`；
- 不翻转的话，`NSScrollView` 以左下角为原点，内容高于视口会整体跑到视口上方
  （实测 `frame.y = -274`，同样是空白）。

#### 自检

- **新增 `--shot-import-diff`**（`DT_DATA_DIR` + `DT_ALERT_SHOT`，
  可选 `DT_SHOT_SCROLL=bottom` 滚到冲突段）：
  修复后 `列表：行数=8 frame=(0,0,739,745)`，出图可见「高等数学 / 大学英语 / 物理 /
  体育 / 军事理论 / 自习 + 时间冲突」全部条目；
- `--verify-import-flow`：✅ 通过（摘要 / 阻塞原因 / 逐条决定 / 写盘 / 焦点）；
- `make test`：**2065 项断言全过**。

### 「合并课表差异」窗口：玻璃底 + 边缘假光，列表铺满宽度并改成卡片

用户原话（2026-11-09 晚）：

> 「一二可以按你说的改，并且这个黑色的和现在不搭。我之前把其他的窗口不是都要你
> 改成了有假光的那风格吗，你可以按照相同的风格，把这个背景进行优化，
> 然后其他的按你说的来」

（「一二」= ① 每行铺满可用宽度 ② 每门课一块玻璃卡片、冲突段琥珀强调）

#### 修复（`UI/TimetableDiffWindowController.swift`）

- **窗口背景**：不再用默认的纯黑 `NSWindow`，改成
  `HUDWindow.make`（标题栏透明 + 内容铺满 + 浮动层）+
  `installContent`（材质 + 边缘假光）+ `installDarkBackdrop`（上浅下深的渐变玻璃底）——
  和确认框 / 设置面板同一套；
  摘要行下移 `trafficLightBand + 18`，避开浮在内容上的红绿灯；
- **列表铺满**：每行包进卡片，卡片宽度 = 列表宽度（以前内容列只有 338pt，
  窗口 780pt，右边一大片空）；
- **卡片化**：白 4.5% 玻璃底 + 1pt 描边 + 圆角 10；时间冲突那张用琥珀色描边；
  行尾分隔线去掉（卡片本身就是边界）。

#### 顺带修的出图链路

- `--shot-import-diff` 的 `DT_SHOT_SCROLL=bottom` 之前找不到滚动视图 ——
  换成 HUD 玻璃底之后 scroll view 在 root 里、不是 `contentView` 的直接子视图；
  改成递归查找，并在布局完成后再滚（文档高度是布局后才有的）。

#### 自检

- 出图：`docs/archive/shots-1.4.8/合并课表差异-玻璃卡片.png`、
  `...-冲突段.png`、`...-桌面实拍.png`（窗口里 6 门课 + 琥珀冲突卡都可见）；
- `--verify-import-flow`：✅ 通过；`make test`：**2065 项断言全过**。

### 版本

待用户拍板。

## [1.4.7] - 2026-11-09

### 弹窗换外观：深色玻璃底 + 一圈边缘假光

用户原话（2026-11-09 晚，附两张对比图）：

> 「弹出来的这种警告窗口，就是像第一张这样的，把它的外观变成像第二张一样，
> 就是在边缘处打点假光，然后整个的颜色不要那么的深，稍微有一点点毛玻璃质感」

#### 现象

「删除这一节课？」这类确认框是一块**近实心的深色板**：底色 `α 0.82` 单色、
四周只有窗口自己裁出来的圆角、没有任何边缘光 —— 压在深色桌面 / 课表上像贴了一张黑纸。

#### 根因

- `HUDWindow.installDarkBackdrop` 往毛玻璃材质上压了一层 **`α 0.82` 单色**，
  材质几乎被压死（毛玻璃质感出不来），而且顶部和底部一个颜色（没有厚度感）；
- 窗口完全没有**边缘光**：既没有描边，也没有内高光，暗背景上就看不出「玻璃边」。

#### 修复（`UI/HUDWindow.swift`，全 app 弹窗共享）

1. **`HUDGlassBackdropView`（新）**：底色改成**上浅下深的竖向渐变**
   （`α 0.86` 深蓝灰，顶 `0.12/0.14/0.20` → 底 `0.06/0.08/0.12`），
   顶部再叠一层很淡的白色渐变（`α 0.055 → 0`）—— 就是「光从上面来」；
2. **`HUDGlassRimView`（新）**：一圈 1.2pt 的描边，颜色**上亮下暗**
   （白 `α 0.45 → 0.26 → 0.14`），用 `CAGradientLayer` + `CAShapeLayer` 描边遮罩实现；
   `hitTest` 返回 `nil`，只是光、不吃点击；
3. `installContent` 统一挂上这一层光 → 确认框 / 课程编辑器 / 课程详情 /
   命名框 / 提前提醒框 / 已完成提醒事项的删除框，**全部**跟着变。

⚠️ 两个踩过的坑（都在代码注释里）：
- `draw(_:)` + `destinationOut` 挖圆环**在这套层级里会被擦掉**（出图只剩一条顶边带）；
- 直接 `addSublayer` 不设 `frame` 的渐变是**零尺寸、画不出来**（第一版就是白板）。

#### 自检

- **新增 `--shot-alert-dialog`**：真机抓图 —— `AlertDialogController.makeWindowForTest`
  建窗 → `orderFrontRegardless` → `/usr/sbin/screencapture -x -o -l<windowNumber>`
  （⚠️ `displayIgnoringOpacity` / `cacheDisplay` 抓出来都是**白板**：
  底色 / 假光都在 layer 上，而且毛玻璃要和窗口背后的桌面合成）；
- 截图结论（`/tmp/final1.png`「删除这一节课？」、`/tmp/final2.png`「删除整门课程…」）：
  底色上浅下深、四周一圈亮边（顶边最亮）、正文对比度正常；
  实测像素：内部 `(39,43,53)`、左边 `(99,100,108)`、顶边 `(170,171,176)`、底边 `(57,60,68)`；
- `make test`：**2057 项断言全过**；
- 相关自检全过：`--verify-completed-reminders`、`--verify-import-flow`、
  `--verify-day-panel-click`、`--verify-typing`。

### 版本

**1.4.7** —— 补丁版，**bundle id 不变**（仍为 `com.desktoptimetable.app.v120`）：
日历 / 提醒事项的授权、登录项、通知身份全部延续，不用重新登记。
构建已归档到 `版本迭代/DesktopTimetable-1.4.7.app`。

## [1.4.6] - 2026-11-09

### 时间输入：标题 / 时 / 分框之间来回点不再断键盘，上面的待办也不会消失

用户原话（2026-11-09 下午）：

> 「现在时间输入还是有问题，输入也不够连贯，输入时间时上面的待办事项就没了」

#### 现象

- 在「添加待办」里点「时」框 / 「分」框时，**键盘会断**（接着打字没反应、输入法不弹）；
- 输入时间的过程中，面板里**上面的待办事项整块消失**。

#### 根因（产品侧三条）

1. **时 / 分框的点击冒泡到「添加待办」那张卡** —— 卡片把它当成「点标签 = 重新打开输入框」，
   `renderPanel` 整树重画 → 待办卡片被换掉（看起来消失）、输入框被摘下来再挂回去（失焦）
   → `textInputBlur` → 原生退出文本输入模式 → 键盘断。
2. **时框 → 分框必然会先触发时框的 `onblur`**，以前那里无条件 `post('textInputBlur')`
   → 原生立刻收键盘 → 分框打不了字（焦点其实还在表单里）。
3. **「时间非法」的就地校验用了错误的选择器**：写的是 `.dpinput`，而添加态表单根是
   `.dpaddform` → 「用户还在表单里」这个判断**永远不成立** → 一切换框就弹红字 / 重绘。

#### 修复（产品侧）

- `Resources/Timetable.js` `ensureTimePart()`：时 / 分框的 `onclick` 先 `stopPropagation()`，
  不再冒泡到卡片；`onblur` 改成**晚一拍判断焦点还在不在同一个表单里**
  （`focusStillInside(root, input)`），在就**不发** `textInputBlur`；
- `scheduleTimeBlurValidation()` 的表单选择器改成 `.dpaddform`（添加态）/ `.dpedit`（编辑态）。

#### 修复（自检侧两条 —— 这两条是这轮真正卡住的地方）

1. **「取消」用例插队 → 假红。** `--verify-todo-focus` 里 `timeChecksDone = true`
   写在了 `step(0.7) { … }` 的**块外**：`step` 只是排期，块还没跑标志就翻了 →
   「取消」用例 0.2s 后就点下去把输入区收起来 → 0.7s 后分框断言读到的已经是
   「取消之后」的状态（`focus=other` / `adding=false` / 文本输入模式已退出）。
   表现是稳定的两条红：
   `❌ 点进「分」框之后原生退出了文本输入模式`、`❌ 点「分」框之后焦点没落在分框上（实际=other）`。
   → 标志挪进 `step(0.7)` 块末尾（时间用例真的跑完才置位）。
2. **「上面的待办不能消失」这条断言是空转的。** 临时数据目录里 `dayPanel.enabled` 默认
   false、假 EventKit 也返回 0 条待办 → 「0 → 0 没变」恒真 = 没验。
   → `EmptyEventKitStore` 增加 `seededTodos`；`buildDayPanelController` 在
   `focusVerificationMode` + `DT_FOCUS_REPORT` 时**只在内存里**打开面板开关（不写盘）
   并塞一条假待办「自检待办（不能消失）20:00」；断言增加两条：
   ① 必须真的看到 ≥1 条待办（否则报「断言会空转」）；② 时间输入前后待办卡片的**文字内容**必须一致。

#### 自检

- `--verify-todo-focus`（真机，经 LaunchServices `open -n` 启动）连跑 **3 次：3/3 通过**；
  报告里 `输入时间之前 → 点完「时」框 → 点完「分」框` 三处都是 `"todos": 1`，
  焦点依次是 `add-hour` / `1`（标题框）/ `add-minute`，原生侧 `textInputActive=true`、
  `firstResponderReady=true` 全程成立。
- 回归有效性（上一段记录）：同一份代码在修 `timeChecksDone` 之前连跑 4 次**都是那两条红**。
- `make test`：**2057 项断言全过**。
- 相关自检全过：`--verify-day-panel`、`--verify-day-panel-click`、`--verify-typing`、`--verify-hover`。

### 版本

**1.4.6** —— 补丁版，**bundle id 不变**（仍为 `com.desktoptimetable.app.v120`）：
日历 / 提醒事项的授权、登录项、通知身份全部延续，不用重新登记。
构建已归档到 `版本迭代/DesktopTimetable-1.4.6.app`。

## [1.4.5] - 2026-11-09

### 添加待办：输入框能聚焦了，「取消」一次就生效

用户原话（2026-11-09）：

> 「现在输入日历点击了添加待办事项的时候输入框出现了但是这时候输入键盘无法聚焦，
> 而且第一次点击取消了之后再次打开添加待办事项取消要点击两次，应该还是聚焦的问题，查清楚」

#### 现象

- 点「＋ 添加待办」→ 输入框出来了，**但键盘进不去**（打不了字，输入法也不弹）；
- 取消一次之后**再打开**输入框，「取消」要点**两下**才收得回去；
- 第一次（刚启动 app 之后）打开时反而是好的 —— 差别在「app 是不是已经 active」。

#### 根因（两条，互相叠加）

**根因一（原生）：退出输入模式时 `resignKey()` 把 app 留在「active 但没有 key window」的状态。**

AppKit 的规矩：`.nonactivatingPanel` 窗口**只有跟着 app 的「激活过程」才能拿到 key**。

- 第一次打开时 app 还是 inactive → `NSApp.activate` 触发激活过程 → `makeKey()` 成功
  （实测 `attempt=0 appActive=false isKey=false` → `attempt=1 appActive=true isKey=true`）；
- 退出输入模式时 `DesktopWindow.setTextInputMode(false)` 调 `resignKey()` →
  app 变成「**active 但没有 key window**」（accessory app 退出输入模式不会 deactivate）；
- 于是第二次打开时 `makeKey()` 被 AppKit **直接拒绝**，12 次重试全是
  `appActive=true isKey=false` → WKWebView 拿不到 first responder → **键盘进不去**；
- 而且那 4 秒的重试每次都 `NSApp.activate` + `activateAllWindows` + `makeKey`，
  窗口被反复摆到前面 → **用户的点击被吃掉**（「取消要点两次」）。

**根因二（网页）：「添加待办」那张卡每次重绘都重建，共享的 input 元素被搬走。**

`dpTodoSection` 每次都 `h('div', { class: 'dpaddform' }, input)` 拼一个新表单 ——
`h()` 会把 `input`（**跨重绘复用的那个元素**）从旧表单里**摘走**挂到新表单上：

- 元素在 DOM 里被「摘下来再挂回去」→ **失焦** → `onblur` → `post('textInputBlur')`
  → 原生退出文本输入模式 → **键盘断掉**；
- 原生一退出输入模式就要重新抢 key（重试 4 秒）→ 又是「点击被吃掉」。

两条合起来，正好对上用户报的两个现象。

#### 修复

**原生（`UI/DesktopWindow.swift`）**

- `setTextInputMode(false)`：窗口**是 key 的时候不交出 key**，只把 first responder 收回来
  （`if !isKeyWindow { resignKey() }`）。app 一直有 key window，下一次 `makeKey()` 照样认
  —— 实测第二次打开 `attempt=0` 就 `isKey=true`（以前 12 次全失败）。
- `takeKeyForTextInput` 的诊断日志改成**只在 `DT_DEBUG_INPUT=1` 时**写（以前每次都写统一日志）。

**网页（`Resources/Timetable.js`）**

- 新增 `ensureAddForm()`：「添加待办」的表单 DOM **建一次就留着**，重绘时只更新值，
  **一个元素都不动**；
- 新增 `updateAddCard()`：「添加待办」那张卡也是**稳定节点**，同时装**两种形态**
  （收起态 `.dpadd` / 展开态 `.dpaddform`），来回切换只改 `display`；
- `syncCards()`：`add` 这张卡现在可以正常复用了（以前被排除在外，就是因为它每次都重建）；
- 新增 `window.ttAddFormVisible()`：**判「添加态开着没有」要看可见性**，
  不能只看元素在不在（输入框现在是稳定元素，收起时只是被 `display:none` 藏起来）。

**自检侧的连带修正**（判据从「元素在不在」改成「可见不可见」）

- `--verify-day-panel`、`--verify-day-panel-click` 里几处
  `!!document.querySelector('.dpaddform')` 改成 `window.ttAddFormVisible()`。

#### 自检

- **新增 `--verify-todo-focus`**（**真机**，经 LaunchServices `open -n` 启动）：
  走**和用户完全一样**的链路（真实鼠标事件 → `CardInteractionView` → `forwardClick`
  → 网页 DOM → `textInputFocus/Blur` → 原生拿 key + webView 拿 first responder），
  验四件事：
  1. 点「＋ 添加待办」之后输入框出现**且自己拿到焦点**；
  2. 窗口是 key window、webView 是 first responder（键盘能进网页的**前提**）；
  3. 点「取消」**一次**就收起；
  4. **重新打开**再点「取消」，**仍然一次**收起，且第二次打开时窗口**又**拿到 key。
  - 连跑 3 次：**3/3 通过**；
  - **回归有效性**：把原生修复临时去掉 → 连跑 2 次**都是红的**
    （`❌ 退出输入模式后 app 处于「active 但没有 key window」`、
    `❌ 第二次打开时桌面窗口没拿到 key window`）；
    把网页侧「每次重建表单」临时还原 → 也变红。
- `make test`：**2057 项断言全过**。
- 相关自检全过：`--verify-day-panel`、`--verify-day-panel-click`、`--verify-typing`、
  `--verify-hover`、`--verify-card-scale`、`--verify-collapse`、`--verify-week-arrow`、
  `--verify-pin-flow`。
- 截图（`--shot-day-panel ... todoedit`）：添加态（标题框 + `20 : 00` + 取消）和
  编辑态（标题 + `21 : 30` + 保存 / 取消 + 收起的「＋ 添加待办」）都正常。

> `--verify-panel-animation` 在这台机器上一直是红的（归档的 1.4.4 也一样红）——
> 无头环境下合成器不推进动画，属**既有环境限制**，与本轮无关。

### 版本

**1.4.5** —— 补丁版，**bundle id 不变**（仍为 `com.desktoptimetable.app.v120`）：
日历 / 提醒事项的授权、登录项、通知身份全部延续，不用重新登记。
构建已归档到 `版本迭代/DesktopTimetable-1.4.5.app`。

## [1.4.4] - 2026-11-08

### 折叠之后点日期，日历和待办直接弹出来（不再先把课表展开）

用户原话：「继续实现我那个收缩课表之后，点击日历依然可以弹出来日历和待办事项的那个功能」。

#### 现象

- 折叠成一条之后点表头日期：课表先「唰」地展开，再开面板 —— 视线被甩一下；
- 更早的实现里，折叠态点日期根本没反应（面板被 `.gridwrap` 裁掉了）。

#### 根因

- 网页 `onHeaderPick` 里写死了「折叠态 → 先 `post('toggleCollapse')` 展开，
  展开完原生再开面板」；
- 面板元素挂在 `.grid` 里，而折叠是靠 `.gridwrap { overflow: hidden }` +
  让容器高度变成 38px 实现的 —— 面板如果留在里面，会被裁得只剩表头那一条；
- 原生 `TimetableLayout.headerRect` 只有展开态的算法（表头底边 = 网格底边 + 数据区高），
  折叠态算出来跑到卡片外面去了，悬停 / 点击的「面板那一列」也跟着错。

#### 修复

- `onHeaderPick`：删掉折叠态那条「先展开」的分支，点日期一律
  `post('datePanelOpen')` + `openPanel(day)`。
- 面板**换宿主**：折叠态挂到 `.card`（`panelHost()`），展开态还是 `.grid`；
  `applyCollapse()` 在跨过一半时把元素搬一次家并重新定位。
- `positionPanel()` 改成「宿主矩形 / 表头格矩形相减」算位置和宽度，
  宿主是 grid 还是 card 都成立（pageZoom / transform 只差一个倍率）。
- `.card.collapsed { overflow: visible }`：折叠时才允许面板伸出卡片；
  `applyCollapse()` 同时给卡片加 `collapsed` 类。
- 原生：`headerRect` 折叠态改成「贴着卡片底部」（`cardRect.minY + paddingBottom`），
  `dayPanelRect` 折叠态按**满列高**往下伸；`animateCollapse` 不再顺手
  `closeDayPanel()`（折叠时面板跟着落地，不再消失）。
- `render()` 末尾补一次 `applyCollapse()`：新 DOM 默认是展开模板，
  不补的话原生一推状态卡片会先弹开再收回去。

#### 自检

- 新增自检入口 `--verify-collapse-panel`（原来只有代码没有进套件）：
  - 折叠态点第 3 列：`折叠进度=1.0`（**保持折叠**）、`open=true day=3`；
  - 面板矩形 `{{422,169.5},{118.6,600}}`，顶边 = 表头底边 `769.5`（±2）；
  - 网页面板：`opacity=1`（关掉过渡量终态）、`visibility=visible`、
    父节点是 `ttcard`、卡片 `overflow=visible` 且带 `collapsed` 类；
  - 换到第 5 列：面板横向跟着走；展开后仍开着。
- `--verify-collapse` 第 6 步改成新语义：折叠态点表头**不再展开**。
- `make test` **2052 项断言全过**；13 个 `--verify-*` 全过。
- 截图（折叠 + 第 3 列面板开着）：课表保持一条，日历/待办面板从周三那列下面垂出来。

## [1.4.3] - 2026-11-08

### 日期覆盖层 / 弹窗锚点 / 启动缩放与位置：AppDelegate 重建后的接线补齐

用户原话：「继续修复代码」——接上一轮（11-07 深夜 AppDelegate 源码事故）的
重建工作，把重建时整块丢掉的接线补回来。

#### 现象

- 点表头日期什么都不发生：日期覆盖层打不开，待办不能加 / 勾 / 改 / 删，
  右键菜单也不弹；`--verify-day-panel-click` 报「换列推送 0 次」。
- 在系统「提醒事项」里改完，课表面板不重新取数（缓存永远是旧的）。
- 右键待办时整个课表淡到 22%，菜单关掉才慢慢回来。
- 设置面板 / 确认框落在**屏幕正中**，而不是课表中心。
- 重启后课表大小回到 100%、位置回到默认；点顶栏箭头第一次没反应；
  折叠状态点表头先展开、但不打开那一列的日期覆盖层。
- 折叠 → 在设置面板里放大 → 展开：整张卡片跑到画布上方被裁掉。

#### 根因

- **日期覆盖层控制器根本没建**：`dayPanel` 只在重建后的 `buildDesktopWindow`
  里声明，从来没有实例化。网页发来的 `datePanel*` / `todo*` 意图全被
  `dayPanel?.handle(...)` 静默吞掉；`onStateChange` 也就永远不会推状态。
- **`WindowAnchor.provider` 只写在 `applicationDidFinishLaunching`**：
  自检走的是 `prepareForRendering`，而窗口构建里的那段接线在重建时丢了，
  于是锚点退回默认值（屏幕中心）。
- **启动时不恢复缩放、也不恢复窗口位置**：`appearance.cardScale` 读到了却没用，
  `restoreWindowState()` 定义了却没人调。更隐蔽的是：网页侧的
  「画布居中 translate」只在 `applyScale` 里写 —— 启动没调它，网页卡片就停在
  版式位置 (90,90)，比原生玻璃 / 命中矩形偏 (74, 61.5)pt，
  画布上沿那 23pt 里的箭头**落在命中矩形之外**，点下去直接穿透到桌面。
- **意图回调重入**：网页 `post()` 是同步调起的，`WKScriptMessageHandler`
  → `handleWebIntent` → `refreshCard` → `callAsyncJavaScript` 这条链
  在网页自己的点击回调栈里重入。WebKit 接受这次调用（不报错）但**不执行**，
  `ttUpdate` 调用计数不涨 —— 表现就是「第一次点箭头周次不变，再点一次才生效」。
- **折叠态缩放的拖动帧按展开高度（773）算卡片矩形**：玻璃 / 穿透 / 松手落点
  全都当成展开卡片，折叠 → 缩放 → 展开时顶边被算错 600pt，展开后卡片被画布裁。
- **面板开着缩放松手时用「画布居中」的矩形当卡片当前位置**：实际卡片停在
  拖动帧的锚点上（可能贴边夹过），两者差几磅 → 松手瞬间窗口被平白挪 6pt；
  「放到最大」路径还会把卡片推到屏幕外。

#### 修复

- `buildDesktopWindow` 里补齐启动接线：
  `performCardScale(appearance.cardScale)` → `restoreWindowState()` →
  `buildDayPanelController()` → `installWindowAnchor()`。
- 新增 `buildDayPanelController()`：建 `DayPanelController`，接上
  `onStateChange`（合并进完整状态推送）、`onAuthorizationChange`（刷新设置行）、
  `onTodoAddResult` / `onTodoUpdateResult`（把结果回报网页），
  并把控制器交给设置面板。
- 新增 `syncDayPanelWeek()`：翻周 / 切「全部周次」时同步覆盖层的周一。
- 新增 `installWindowAnchor()`：锚点按**当前卡片矩形**中心算，窗口建好就接上。
- 菜单桥接：`MenuPresenter.onMenuVisibilityChanged` → 网页 `ttDayPanelMenuOpen`，
  并在关闭时给 6 秒宽限期；`updateHover` 里把「菜单开着 / 宽限期内」也算成
  「保持可见」，同时把覆盖层那一列的矩形同步给 `LiveContainerView.panelRect`。
- `WebCardRenderer.handle(_:)`：意图处理改成 `DispatchQueue.main.async`，
  退出网页的调用栈再回推状态（并补注释说明为什么不能同步）。
- `applyNextDragFrame`：折叠态用**折叠后的版式高度**、锚点锁**顶边**
  （1.4.1 的约定），窗口跟随时重算的 `ty` 同步改成顶边口径。
- `commitCardScale`（面板开着那条路）：把拖动帧落地的 `dragCardRect` 写回
  `TimetableLayout.cardRectOverride`，夹屏用它的中心，不再用画布居中矩形。

#### 自检

- `make test`：**2046 项断言全过**。
- 11 个 `--verify-*` 全过：card-scale / scale-panel / scale-drag-edge / hover /
  day-panel / day-panel-click / pin-flow / settings-card / switch-refresh /
  week-arrow / collapse。
- 关键数字：
  - `--verify-week-arrow`：100% / 113% / 折叠态三种状态点击后 `ttUpdate` 都执行
    （调用计数 1 → 3 → 5），周次依次 `本周 → 第 2 周 → 本周 → 第 2 周 → 第 3 周`；
  - `--verify-scale-panel`：松手中心 `{756,522} → {756,522}`（不再跳 6pt）；
  - `--verify-collapse`：折叠态点表头 → 展开 + `open=true day=3`；
    折叠→缩放→展开后卡片在画布内、屏内（`{{116,97.8},{1084,865}}`）；
  - `--verify-pin-flow`：设置面板 / 确认框都落在课表中心。
- 临时目录里预置 `cardScale=1.10` 启动：`缩放=1.1`（重启恢复生效）。
- 截图：网页层卡片 1.0 出图居中、四周投影对称；设置 → 外观页正常
  （卡片大小 100%，范围 70%–113%）。

### 设置里拖动「卡片大小」滑杆，桌面课表不动

用户原话：「放大缩小还没恢复吧」。

#### 根因

- `SettingsWindowController.onCardScaleChange` 这个回调**只有声明、没有赋值**：
  拖滑杆时滑杆自己的数字会变、配置也会写，但没有任何人通知桌面课表重排 ——
  `AppDelegate.applyCardScale` 一次都没被调用过，课表纹丝不动。
- 上一轮的 `--verify-scale-panel` 直接调缩放引擎（`testApplyCardScaleDragFrame`
  → `testCommitCardScale`），**绕过了滑杆这条真实路径**，所以没测出来。

#### 修复

- `buildSettingsController()` 里接上：
  `onCardScaleChange = { value, persist in applyCardScale(value, persist:) }`
  —— 拖动中实时预览（不写盘），松手落到最终档并写盘。
- 新增自检 `--verify-slider-scale`（已登记进 `AutomationMode.automationFlags`）：
  从 `updateCardScale`（滑杆 onChange / onDragEnd 的入口）一路验到
  原生缩放、网页缩放、布局缩放、写盘、关面板后保持。

#### 自检

- `--verify-slider-scale`：通过
  - 拖到 110%：原生 / 网页 / 布局三者都是 `1.1`，且 `usesPageZoom=true`；
  - 拖回 90%：三者都是 `0.9`，且走 CSS transform（`usesPageZoom=false`）；
  - 写盘：临时目录 `config.json` 的 `cardScale=0.900`；
  - 关面板后：缩放仍是 `0.9`，玻璃高 `695.7`（≈773×0.9）。

### 放大过程中卡片出界，要等松手才「一下跳进屏幕」

用户原话：「放大时就要判定是不是会超出界面，不要最后松开拖动杆才一下把课表
拖进界面内，就像 1.4.2 一样」。

#### 根因

- 拖动帧里**窗口基本不动**，只把卡片在**画布**里挪；窗口只在卡片超出画布时
  平移一下（保住「不被 webView 裁」）。但常驻画布只比最大档卡片大 ~208pt，
  卡片贴着屏幕边放大时需要的位移很快超过这点余量 —— 卡片就只能露在屏幕外，
  等到松手 `commitCardScale` 才一次性把窗口挪进来（用户看到的那一下「跳」）。
- 顺带查出两个连带问题：
  - 缩放锚点**松手不释放**（`cardScaleAnchorCenter`），于是「缩放 → 把课表拖走
    → 再缩放」会被拽回上一轮的老位置；以前这条自检测的是**窗口中心**，
    刚好蒙对，所以一直没暴露。
  - `webCardCenterInWindow()` 直接返回「容器中心」，假设卡片永远摆在画布正中；
    卡片被拖走 / 面板里缩放过之后这个假设就不成立了。

#### 修复

- `applyNextDragFrame`：**每一帧**按「卡片中心 = 夹过的锚点」反推窗口原点
  （`desiredOrigin = anchor − 画布里卡片的标准中心`），让卡片在窗口里始终落在
  画布标准位置（展开居中 / 折叠顶边对齐）。窗口原点只落整点，小数零头由
  translate 补，卡片中心仍严格等于锚点 —— 放大过程中一旦要出界，窗口当帧就让位。
- `commitCardScale` 两条路径结束都**释放锚点**（`cardScaleAnchorCenter/Top = nil`）。
- `applyNextDragFrame` 在锚点没锁时按**当前卡片中心**兜底（不再拿 `(0,0)` 夹屏）。
- `webCardCenterInWindow()` 改成返回 `TimetableLayout.cardRect` 的中心
  （可见卡片矩形，同步算，不吃网页旧缓存）。

#### 自检

- `--verify-slider-scale` 新增「贴边放大」段（先 70% 拖到左下角 → 面板里一路拖到
  112%，**每一帧**测卡片屏幕矩形）：
  - 拖动中最大越界 **0.0pt**（修复前会一路露在屏幕外）；
  - 松手前后卡片矩形差 < 1pt（不再「跳进来」）；
  - 松手后完整落在可见区（`{{0,53},{1512,896}}`）内。
- `--verify-scale-panel`：`松手瞬间中心 {756,516} → {756,516}`、
  `缩放→拖走→再缩放 876,485 → 876,485`（不再拽回旧锚点）。
- `make test`：**2051 项断言全过**；12 个 `--verify-*` 全过。

### 缩放的时候左上角图钉和课表不同步

用户原话：「左上角图钉和课表在缩放的时候出现了不同步的情况」。

#### 根因

- 原生 chrome（毛玻璃 / 图钉 / 穿透矩形）是**发命令的同一刻**就摆到目标位置，
  而网页的缩放是 `evaluateJavaScript` 跨进程异步应用的；
- 上一条改动之后，拖动帧里**窗口也在逐帧移动**：窗口一挪，窗口里的网页层
  （含卡片）立刻跟着挪，网页的 transform 却要晚一拍才补上 —— 于是卡片
  先「冲过头」再回来，而图钉/玻璃已经站在目标位置，看起来就是「图钉飘在外面」。
- 静态位置本身是对的（`--verify-slider-scale` 实测：图钉与标题文本右边缘的间距
  `8.97pt`，理论值 `8.96pt`；纵向差 `0.09pt`），问题只在「哪一帧摆」。

#### 修复

- `applyNextDragFrame`：把 `dragCardRect` / `TimetableLayout.cardRectOverride` /
  `updateDragChrome(...)` 挪进 `applyDragScale` 的**回调**里 ——
  网页真的应用完这一帧，chrome 才跟着摆；窗口先挪的那一下，chrome 留在原位置
  随窗口一起平移，和「还没补上 transform 的卡片」仍然对得上。
- 0.12s watchdog 那条兜底路径也补一次 `applyChrome()`，避免回调永远不来时
  chrome 停在上一帧。
- `--verify-slider-scale` 新增「图钉对齐」断言（贴边放大到 112% 后）：
  量网页里标题文本的真实右边缘，比对原生图钉的左边 / 中线 / 卡片顶边距。

#### 自检

- `--verify-slider-scale`：通过
  - 图钉间距 `8.97`（理论 `8.96`）、纵向差 `0.09pt`；
  - 图钉中心到卡片顶边 `36×缩放`（±2.5pt）。
- `make test`：**2051 项断言全过**；12 个 `--verify-*` 全过。
- 截图：缩放 1.0 / 1.085 两档窗口图，图钉都紧贴标题右侧、与标题同一条水平线。

### 图钉还是闪、并且跟不上左边的标题（图钉视觉搬进网页层）

用户原话：「现在还是会出现这个图钉图标闪的情况，和跟着左边的字儿移动不同步的情况」。

#### 根因

- 图钉是**原生控件**，卡片和标题是 **WKWebView 里画的** —— 两条流水线、两个进程。
  缩放拖动时网页的 `transform` 走 `evaluateJavaScript` 异步应用，原生那一层
  无论怎么等回调，都只能「尽量接近」，不可能逐帧对齐（上一轮把 chrome 挪进
  回调只是把误差从「一整个 eval 往返」压到「一帧」）。
- 顺带：`PushPinButton.draw` 每帧都用 `NSImage(systemSymbolName:)` +
  `withSymbolConfiguration` 重新生成图标 —— 缩放时每帧一次，掉帧后看起来就是「闪」。

#### 修复

- **视觉搬进网页**：标题行改成 `flex`（文字 + `<img class="ttlpin">`），
  图钉和标题在同一个 DOM、同一个 `transform` 里，缩放 / 移动天然逐帧同步；
  两态图片仍用同一套 SF Symbol —— 原生渲染成 2x PNG（data URI）注入网页，
  长相和原来的图钉完全一致（`PushPinButton.pngDataURI`）。
- 原生 `PushPinButton` 保留为**透明点击热区**（`drawsInWeb = true`，不绘制），
  位置仍按卡片矩形 + 标题宽度算，自检的矩形 / 点击路径不变；
  网页里的 `<img>` 也挂了 `onclick → post('pinToggle')` 作为兜底。
- 状态同步：状态快照里带 `pinned`，网页 `ttUpdate` 据此换空心 / 实心；
  点热区 / 菜单 / 恢复记忆都走 `ttSetPinned`。
- 原生图钉顺手改成「只按空心/实心缓存图标 + 图层化」，自检出图不再每帧重造 symbol。

#### 自检

- `--verify-slider-scale`：新增**网页图钉**的对齐断言（贴边放大到 112% 后）：
  - 图钉左边缘 − 标题文字右边缘 = **8.96pt**（理论 `8×1.12 = 8.96`）；
  - 图钉宽 **19.03pt**（理论 `17×1.12 = 19.04`）；
  - 图钉与标题的中线纵向差 **0.00pt**。
- `--verify-pin-flow`：固定 / 解锁 / 点击热区 / 位置记忆全过。
- `make test`：**2051 项断言全过**；12 个 `--verify-*` 全过。
- 出图：1.0 / 1.13 / 固定态三张网页层截图，图钉都紧贴标题右侧、随缩放等比变大。

### 图钉点不动（视觉搬进网页后，点击还被原生热区截走）

用户原话：「现在的图钉点不动，布局和图片一样」。

#### 根因

- 上一轮把图钉**视觉**搬进网页，但原生 `PushPinButton` 仍留在交互层最上面当热区：
  固定态下 `CardInteractionView.hitTest` 先返回这个**看不见的按钮**，
  点击就被它吃掉了；而它和网页里那张图的坐标不是同一条链路算的（原生用
  `NSFont` 量标题宽度，网页用 flex 布局），一旦有偏差，用户点的就是「看得见的图
  旁边那块空气」——表现为「点不动」。

#### 修复

- `CardInteractionView.hitTest`：图钉那块区域**一律让出去**（返回 nil），
  点击直接落到网页里的 `<img class="ttlpin">`，由它 `post('pinToggle')` 回来切状态。
  「看到的位置 = 能点的位置」，不再依赖两边几何对齐。
- 网页 `pinToggle` 带上目标状态（`{ pinned: !pinPinned }`），原生按 payload 设置，
  不会和网页显示状态打架。
- 自检同步：`--verify-pin-flow` 与单元测试「图钉 · 固定后拖不动」改成断言
  「固定态 / 未固定态下图钉区域都**不**被交互层接管」，并用
  `testClickWebPin()`（真点网页那张图）验能解锁 / 再锁回。

#### 自检

- `--verify-pin-flow`：通过（固定 / 解锁 / 点网页图钉 / 位置记忆 / 弹窗锚点）。
- `make test`：**2052 项断言全过**；12 个 `--verify-*` 全过。
- 图钉几何不变：标题右边缘 → 图钉左边缘 `8.00pt`（100%）、`8.96pt`（112%），
  和标题同一条水平线。

### 图钉比原来宽了一点（网页里被拉成了正方形）

用户原话：「现在的图钉标识还是有点儿宽，把它和原来一样做窄一点儿」（附新旧对比图）。

#### 根因

- 搬到网页后按 `width:17px; height:17px` 展示，正好把 SF Symbol 的图标**横向拉宽**：
  原生画法是「17pt 高 + 按原始比例缩放进框里」（符号画布 21×23，实际约 15.5×17），
  网页写死宽高就变成了 17×17（≈ +10% 宽），看起来比原来的胖一圈。

#### 修复

- `.ttlpin` 改成 `height: 17px; width: auto`（高度跟缩放，宽度按原始比例）。
- 自检同步：`--verify-slider-scale` 的网页图钉断言从「宽 = 17×缩放」改成
  「高 = 17×缩放、宽明显小于 17×缩放（原始比例）」。

#### 自检

- 100%：图钉 14.8×17（原来 17×17）；112%：16.55×19.03（高 = 17×1.12 ✓）。
- `make test`：**2052 项断言全过**；12 个 `--verify-*` 全过。
- 出图（网页层 1.0）：图钉细长形，和的旧版观感一致。

### 折叠态面板显示不全 / 鼠标移上去就消失

用户原话：「折叠状态点击了表头之后，日历显示不全，而且移动到日历的那一部分之后，
日历就直接消失了……桌面上没有显示日历的地方不是算在课表内」。

#### 根因

- **显示不全**：网页 `body` 的高度 = 卡片高度 + 上下 90px 留白。折叠后卡片只有 173，
  `body` 就只剩 353px 高，而 `body { overflow: hidden }` —— 面板从 306 往下伸到 900+
  的部分**全被裁掉**，只剩最上面一两个卡片可见。
- **移上去就消失**：原生 `syncLiveHover()` 只把 `TimetableLayout.cardRect` 当「在课表上」。
  面板伸出卡片之后，指针一进面板就在 cardRect 之外 → 它给网页发 `clearLiveHover()`，
  网页当成「指针离开课表」→ 把面板淡出。

#### 修复

- `Timetable.html`：给 `body` 加 `min-height: 100vh`（视口下限）。卡片位置不变，
  只是让「伸到卡片下面」的面板有地方画；超出视口的部分照旧看不到。
- `AppDelegate.syncLiveHover()`：判定改成 `cardRect ∪ dayPanelRect`，
  和 `updateHover()` 同一口径（面板那一列算课表内，桌面空白处不算）。
- 自检新增两条断言（`--verify-collapse-panel`）：
  「指针停在面板上时网页里的面板不能被收掉（open / show 都还在）」，
  以及 hover 恢复时按**当前**面板矩形取中心（面板会跟着真实指针换列）。

### 鼠标进到日历那一列，整个课表还是会淡出（原生几何和网页的真实位置对不上）

用户原话：「鼠标移动到显示日历的那一列之后，整个课表又会消失……只移动到那一列的时候，
要被判定在课表区域内」。

#### 根因

- 悬停 / 点击穿透问的是**原生**的 `TimetableLayout.dayPanelRect(day:)` —— 那套几何
  是按「展开时的网格」算的（`gridOrigin` + 列宽），折叠 / 缩放 / 面板换了宿主之后
  和网页里真实画出来的位置差一截（实测 x 差 74pt = body translate 的量）。
- 差出去的那条缝里，`updateHover` 判成「指针不在课表上」→ 整张卡片淡到 22%。

#### 修复

- **网页把面板的真实矩形报给原生**：`positionPanel()` 末尾
  `post('panelRect', {l,t,w,h,day,open:true})`（`getBoundingClientRect()` 原值，
  transform 档已是视觉 px、pageZoom 档由原生再乘倍率）；关闭时补一条 `open:false`。
- 原生新增 `webPanelRect` / `handleWebPanelRect`：换算成窗口坐标
  （x×倍率、y = 窗口高 − (top+height)×倍率），`dayPanelRectInWindow` **优先用它**，
  没报过才退回 `TimetableLayout` 的老几何。
- `panelRect` 属于「几何回报」而不是用户意图 —— `post()` 里不再让它覆盖
  `__ttLastPost`（否则自检里「最后发的意图」全被它顶掉，`--verify-day-panel` 直接红）。

#### 自检

- 新增/沿用 `--verify-collapse-panel` 的断言：指针在面板上 → `hovering=true`、
  面板 `open/show` 都还在；指针在面板右侧的桌面空白处 → `hovering=false`。
- 诊断实测（探针坐标）：卡片上 `hovering=true`、面板中心 `hovering=true`、
  面板右侧 60pt 处 `hovering=false`。
- `--verify-collapse-panel`：通过（面板 `opacity=1`、`body` 高 1076、面板四个卡片
  （待办 / 添加待办 / 日历行程 / 今日详情）全部可见）。
- 出图对比：折叠态面板现在和展开态内容一致，从周三那列下面垂出来。
- `make test` **2052 项断言全过**；13 个 `--verify-*` 全过。

### 设置里点「接入日历与提醒事项」，系统授权框不弹 / 状态一直「正在读取」

用户原话：「日历与待办事项的权利正在读取。然后我现在的提醒事项输入不了，是因为
没有授权吗？……点击了接入待办事项之类的权利之后，在设置里面并没有弹出来窗口」。

#### 根因

- `DayPanelController` 是在 `buildDesktopWindow()` 里建的，那句
  `settingsController?.dayPanelController = controller` 执行时**设置面板还没建**
  （`buildSettingsController()` 后跑）—— 等于空操作。
- 于是设置里那个「日历与提醒事项接入」开关：配置改了、界面刷新了，但
  `dayPanelController?.requestAccess()` 是 **nil 调用** —— 系统授权框永远不出来；
  状态行也没有控制器可问，只能一直显示「正在读取」。没授权 → 提醒事项写不进去。

#### 修复

- `buildSettingsController()` 里补一次注入：
  `settingsController.dayPanelController = dayPanel` + `refreshDayPanelRows()`
  （控制器的 `didSet` 会顺手绑好「已完成提醒事项」服务）。
- 自检加断言（`--verify-slider-scale` 打开设置面板时）：
  `delegate.testSettingsHasDayPanel` 必须为 true —— 防止再断。

#### 自检

- `--verify-slider-scale`：通过（含新断言）。
- `make test` **2052 项断言全过**；13 个 `--verify-*` 全过。

### 「＋添加待办」能点开输入框，但一个字都打不进去

用户原话：「现在添加待办事项还是无法输入」。

#### 根因

- 桌面层窗口是 `.nonactivatingPanel`，**永远拿不到 key window** → WKWebView 收不到键盘。
  项目里本来就有一条解法：网页输入框聚焦时发 `textInputFocus` → 原生把窗口
  **临时**切成「能成为 key + first responder 交给 webView」（`DesktopWindow.setTextInputMode`），
  失焦 / 回车 / Esc 再还原。
- 重建 AppDelegate 时**这条线整段丢了**：`handleWebIntent` 里没有
  `textInputFocus` / `textInputBlur` 分支，`renderer.onTextInputModeChanged`
  也从来没赋值、`window.textInputTarget` 也没设 —— 输入框能点开、光标在闪，
  但按键全落到别的 App 上。

#### 修复

- `handleWebIntent`：`textInputFocus` → `webRenderer?.setTextInputMode(true)`，
  `textInputBlur` → `false`。
- 建窗口时接上：`window.textInputTarget = renderer.webView`；
  `renderer.onTextInputModeChanged = { (window as? DesktopWindow)?.setTextInputMode($0) }`。
- 自检加断言（`--verify-day-panel-click`）：真实点「＋ 添加待办」之后
  `testTextInputActive == true` —— 只验「输入框出现了」不够，必须验「进了文本输入模式」。

#### 自检

- `--verify-day-panel-click`：通过（日志 `添加待办后的文本输入模式=true`）。
- `make test` **2052 项断言全过**；13 个 `--verify-*` 全过。

### 取消添加待办要按两下 Esc（按一下就该取消）

用户原话：「现在要按两下取消添加才能取消……我要的是按一下就取消，按两下是个 bug」。

#### 根因

- 输入框的 Esc 只挂在 `<input>` 自己的 `onkeydown` 上。可进入文本输入模式后
  （窗口变 key、键盘交给 WKWebView），**第一下 Esc 有可能根本到不了 DOM**：
  AppKit 会先走取消链路（`NSWindow.cancelOperation`），DOM 收不到 `keydown`；
  用中文输入法时第一下 Esc 还会被输入法拿去「取消组词」。
- 也就是说：第一下被 AppKit / 输入法接走，第二下才轮到网页 —— 于是「要按两下」。

#### 修复

- 网页新增 **Esc 的统一出口** `window.ttCancelEditing()`（清添加态 / 取消编辑），
  并挂一个**文档级** `keydown` 兜底（焦点不在输入框时也能取消）；
  输入法组词中（`e.isComposing` / keyCode 229）时**不拦**，让输入法先取消组词。
- 原生 `DesktopWindow.cancelOperation(_:)`：文本输入模式下直接把 Esc 转给
  `ttCancelEditing()` —— 把「被 AppKit 吃掉的 Esc」这条路径也补上。
- 自检（`--verify-day-panel-click` 末尾）：打开「＋添加待办」→ 调一次
  `ttCancelEditing()` → 断言输入框收起、`handled == true`、退出文本输入模式。

#### 再修（同一天晚上）：第二次打开输入框时，第一下 Esc 还是被吃掉

用户原话：「点一下可以取消，但再次点击新建提醒事项就需要点击两次」。

- 根因：窗口每次重新变成 key 时，**第一下按键会被 AppKit / WebKit 建立输入上下文吃掉**
  （到不了 DOM 的 `keydown`）—— 第二次打开输入框正好踩这个点。
- 修复：文本输入期间在**原生**装一个 `addLocalMonitorForEvents(.keyDown)`（responder
  派发之前就能看到事件）：Esc 直接调网页的 `ttCancelEditing()` 并吞掉；
  退出输入模式时卸掉监视器。
- 自检：`--verify-day-panel-click` 断言「输入时监视器=true、取消后=false」。

#### 再修（第二次）：一次性 eval 也被吞，改走状态推送

用户：「现在还是不行」。排查发现原生监视器里**同步/异步的一次性 `evaluateJavaScript`
在事件派发栈里都会被 WebKit 吞掉**（和之前「点箭头不刷新」同一个坑），
所以监视器虽然拦到了 Esc，网页却没收到取消指令。

- 现在 Esc 不再发一次性脚本：给状态快照加一个 `cancelCompose` 令牌
  （每次 Esc +1），`refreshCard()` 推给网页，网页在 `ttUpdate` 里看到号码变了
  就调 `ttCancelEditing()`。这条通道是每轮都在跑、验证过的。
- `DesktopWindow.cancelOperation` 改成发 `.ttCancelEditingRequested` 通知，
  和监视器共用同一条链路。
- 自检改成**走产品路径**：`delegate.testRequestCancelEditing()`（发那条通知）
  → 断言输入框收起、退出文本输入模式、卸掉 Esc 监视器。

#### 自检

- 日志：`Esc 取消：取消前有输入框=1 处理=nil 取消后=0`，`文本输入模式=false`。
- `make test` **2052 项断言全过**；13 个 `--verify-*` 全过。
- 顺带修：图钉自检改成**重试派发**（`evaluateJavaScript` 偶发被 WebKit 丢掉，
  不是产品问题），pin-flow 连跑 3 次稳定通过。

### 待办右键菜单没反应（修改… / 删除 / 取消）

用户原话：「右键删除恢复取消是不是还没有恢复」。

#### 根因

- 网页右键会 `post('todoMenu', …)`；可原生 `handleWebIntent` 里
  `action.hasPrefix("todo")` 这条**把 `todoMenu` 也当成日期覆盖层的意图**，
  直接交给 `DayPanelController.handle(...)` —— 控制器不认这个动作，
  `default: break`，于是菜单永远不弹（修改… / 删除 / 取消全都点不到）。
- 顺带查出：交互层（盖在 WKWebView 上做拖动 / 图钉）**只转发了左键**，
  右键被它吃掉，网页连 `contextmenu` 都收不到 —— 以前是靠原生自己算命中弹菜单，
  改成「菜单在网页里判断」之后这条线就断了。

#### 修复

- `handleWebIntent`：`todoMenu` 先截走交给 `handleTodoMenuIntent`（弹 NSMenu），
  不再落进 `todo*` → DayPanelController 的分支。
- `CardInteractionView`：补 `rightMouseDown` → `onRightClick`（**推到下一个 runloop**，
  避免「事件派发栈里发起 eval 被吞」）；`WebCardRenderer.forwardContextMenu(at:)`
  合成 `contextmenu` 事件派发给命中元素（和左键 `forwardClick` 同一套）。
- 自检（`--verify-day-panel-click`）：**真实右键**待办卡片 → 断言弹出
  「修改… / 删除 / 取消」三项。

#### 自检

- 日志：`右键结果：menu=["修改…", "删除", "取消"] 网页最后意图=datePanelOpen`。
- `make test` **2052 项断言全过**；15 个 `--verify-*` 全过
  （含 `--verify-completed-reminders`（恢复 / 删除 / 批量）、`--verify-typing`（真按键输入））。

### 时间框点了打不进字；键盘 ←/→ 不能切换「时 / 分」

用户原话：「时间输入不进去点击之后输入结果什么都没有，并加上点击左右移动键能切换
到小时和分钟」（左右移动键 = 键盘方向键，不要图形按钮）。

#### 根因

- 时间框是真的 `<input>`，但卡片上的点击是原生**合成**转发的
  （`dispatchEvent(new MouseEvent('click'))`）—— 合成点击**不会自动给输入框焦点**，
  所以点上去没有光标、打字全丢。
- 键盘只处理了 ↑↓（加减）和 Tab（跳格），没有 ←/→。

#### 修复

- `ensureTimePart` 的 `<input>` 加 `onclick`：显式 `focus()` + `select()`（打字直接
  覆盖两位数字），并 `post('textInputFocus')` 进入文本输入模式。
- `onkeydown` 加 ←（`ArrowLeft` → 时）/ →（`ArrowRight` → 分）；
  `focusTimePart` 聚焦时也顺手 `select()`。

#### 自检

- `--verify-typing`（**真按键**）新增一段：点击时框 → 断言聚焦 → 打 `0`/`8` → 自动跳到
  分框 → 打 `3`/`0` → 断言 `08` / `30`；再断言 → 焦点到分框、← 回到时框：
  ```
  [诊断] 点击「时」框：{"found":true,"focused":true}
  [诊断] 输入 08:30 后：{"hour":"08","minute":"30","active":"add-hour"}
  [诊断] 时框按 → 后焦点：add-minute
  [诊断] 分框按 ← 后焦点：add-hour
  ```

### 课表上的时间一直对不上（只有点一下 / 切周才更新）

用户原话：「课表显示时间和现在的时间一直对不上，只有再次点击或者切换周之后时间才会更新」。

#### 根因

- 网页启动时脚本尾部会调一次 `render()`，再 `setInterval(updateLiveTexts, 10000)`
  装时钟。可那一次 `render()` 里**第一行就解引用 `S.viewWeek`**，而这时状态还没到
  （`S` 是 undefined）→ 抛 `TypeError` → **后面装定时器那段被一起中断**。
- 于是时钟只在「原生推状态」时顺带更新（点一下 / 切周），10 秒定时器从来没装上。

#### 修复

- `render()` 开头先判空再解引用（`if (!S) return;` 提到前面）。
- 脚本尾部包 try/catch：启动阶段真抛了也**不连累定时器**，并把错误记到
  `window.__ttBootError` 方便排查。

#### 自检

- `--verify-web-render`（之前一直是红的）：`时钟就地刷新：01:24（期望 01:24）`、
  `window.__ttClockTimer` 已装上 → **通过**。

### 时间填错之后的红字提示，取消添加也一直挂着

用户原话：「我输入错误之后就一直出现这个，取消了添加待办还在」（附图：红框
「时间请用 00:00–23:59」）。

#### 根因

- `closeTodoCompose()`（Esc / 取消 / 提交成功共用）只清了标题和时间的值，
  **没清 `DP.addError`** —— 于是「时间填错 → 取消」之后红色提示还在；
  而且提示只在「下一次成功提交」时才被清掉。
- 排版：`.dpadderr` 写了 `line-break: anywhere`，在 118pt 宽的列里把
  「00:00–23:59」断成「00:00–2 / 3:59」。

#### 修复

- `closeTodoCompose()` 里清 `DP.addError`（打开输入框时本来就会清）。
- 新增 `clearAddError()`：用户一开始打标题 / 改时间就把提示摘掉（只摘 DOM
  节点、不整块重绘，保住焦点和输入法）。
- `.dpadderr` 改 `word-break: keep-all; line-break: normal`，只会在空格处换行。

#### 自检

- `--verify-day-panel-click` 新增：填非法时间 → 断言出现提示（`err=1`）→
  取消 → 断言提示消失（`err=0`）、输入框收起：
  ```
  [诊断] 填入非法时间 99：["ok": 1, "err": 1, "text": 时间请用 00:00–23:59]
  [诊断] 取消添加后：["adding": 0, "err": 0]
  ```
- `make test` **2052 项断言全过**；16 个 `--verify-*` 全过。

#### 版本

- **1.4.4（补丁版）** —— 折叠态点日期直接弹面板（交互行为修正）；
  按用户要求只更新版本、**不推送 git**；bundle id 仍为 `com.desktoptimetable.app.v120`。

#### 清理

- 去掉本轮排查用的临时诊断（`[TT-PUSH]` 日志、`DT_DIAG_CLICK` 打印）。
  保留网页里的 `__ttUpdateCalls` / `__ttUpdateWeeks` 计数 —— 它们只读、
  不参与逻辑，是「原生推了但网页没执行」这类回归的唯一观测点。

#### 版本

- **1.4.3（补丁版）** —— 修 1.4.2 重建过程中丢掉的接线，行为回到 1.4.2 的约定；
  bundle id 仍为 `com.desktoptimetable.app.v120`，数据和授权全部互通。

## [1.4.2] - 2026-11-07

### 折叠之后切周 / 加课 / 删课不刷新（网页「正在关闭」标记卡死）

用户原话：「加了折叠功能之后，我在课表里调上一周或者下一周就无法调动，
包括我加了一节课和删除一节课，它上面也没有显示，过很久之后才会逐渐显示」。

#### 根因

- 网页的日期覆盖层关闭时，`closePanel()` 会先置 `DP.closing = true`，
  再调 `runCloseAnimation()` 播 400ms 收起动画，动画收尾才把它清掉。
- 但 `runCloseAnimation()` 第一行是 `if (!DP.el) return;` —— **没有面板可收**
  （最常见的情况：本来就没打开面板）时直接返回，**`DP.closing` 永远是 true**。
- `ttUpdate` 里「整树重画」的条件是 `tableChanged && !DP.closing`
  —— 标记卡死后，**所有切周 / 加课 / 删课的状态推送都只走轻量路径**（只更新表头小点），
  卡片上的周次、课程格全都不动；要等下一次面板开合（或别的路径）碰巧把它复位，
  才会一次性补上（用户看到的「过很久才逐渐显示」）。
- 折叠功能每次收起都会无条件 `closeDayPanel()` → 每次折叠都把标记钉死一次，
  所以这个老坑是折叠功能暴露出来的（拖动课表也会调 `closeDayPanel()`，同理）。

#### 修复

- `runCloseAnimation()` 在没有面板元素时**立刻把 `DP.closing / DP.closingDay` 复位**，
  再返回；不会再把「正在关闭」永久留在 true。
- 新增自检 `--verify-week-arrow`：**真实点击**顶栏箭头（合成 NSEvent →
  CardInteractionView → 网页 `elementFromPoint` → `post('week')` →
  原生 `shiftViewWeek` → 推状态 → 重画），在 100% 展开 / 113% 展开 /
  折叠态三种状态下各点一次，断言周次文字在 0.8s 内变化。

#### 自检

- `--verify-week-arrow`：通过
  - 100% 展开：`本周 → 第 2 周`；再点上一周 `→ 本周`；
  - 113% 展开（pageZoom 档位）：`本周 → 第 2 周`；
  - 折叠态：`第 2 周 → 第 3 周`（修复前这一步不刷新）。
- `make test`：**2041 项断言全过**；其余 10 个 `--verify-*` 全过。

### 折叠按钮太小 / 换成折线样式

用户原话：「这个折叠键太小了，我希望把它做的就是那种折线型的」。

#### 修改

- 按钮视觉尺寸 18 → **22pt**（圆角 7pt），仍然用负 margin 把**占位高度**压回
  15px —— 状态条不会长高 1px、整张卡片不会变高（自检仍按 773 / 173 对）。
- 图标改成 CSS 画的**折线**（只留方块右边 / 下边两条边，转 45° = `⌄`，
  收起时转 -135° = `⌃`），线宽 1.6px、圆头，和设置面板的返回箭头同一套观感；
  不再依赖字体里的 `▾` / `▴` 字形。
- 截图确认：展开态「自由安排 ⌄」、折叠态「自由安排 ⌃」，两档都清晰可辨。

#### 版本

- **1.4.2（补丁版）** —— 修 1.4.1 的刷新卡死 + 折叠按钮样式；
  bundle id 仍为 `com.desktoptimetable.app.v120`，数据和授权全部互通。

## [1.4.1] - 2026-11-07

### 折叠态缩放后展开，课表下半部分被画布裁掉

用户原话：「缩放之后移动结果下半部分显示不出了」（附图：展开的课表底边被切掉，
下面直接是壁纸）。

#### 根因

- 折叠态缩放原来沿用「**卡片中心**」当锚点：173pt 的折叠条会围着中心缩放，
  被摆到**画布中间**（画布只比最大档展开卡片大一圈）。
- 展开时按「顶边不动、往下长」—— 从画布中间往下长 600pt，
  底部就超出画布（webView）被裁掉（实测超出 229pt）。
- 连带修：首次启动的默认位置一直按「卡片贴在 90pt 留白角」算，
  而常驻画布下卡片是**居中**的 → 卡片顶边被顶出屏幕上沿 61.5pt。

#### 修复

- 折叠态缩放改成锁「**卡片顶边**」：窗口按「卡片顶边 = 屏幕上的锚点」摆，
  页面 translate 仍是「展开态顶边」那套 —— 卡片在画布里**始终顶边对齐**，
  展开时底部不会再超出画布。
- 展开收尾加一道保护：展开后卡片若超出屏幕（折叠条贴着屏幕底），
  把窗口夹回可见区（只有放不下时才动，正常情况顶边仍然不动）。
- `DesktopWindow.moveToDefaultPosition` 改成按 `cardRect.minX/minY` 换算
  （卡片在画布里居中），首次启动不再把卡片顶出屏幕上沿。
- 自检补一条：**折叠 → 面板里缩放到 112% → 关面板 → 展开**，
  卡片必须完整落在画布和屏幕内。

#### 自检

- `--verify-collapse`：折叠→面板缩放到 112%→展开后卡片
  `(106, 106.6, 1084, 864.5)` 完整在画布 `1296×1076` 内、
  屏幕 `(0, 53.6, 1084, 864.5)` 完整可见（修复前底部到 -229）。
- `make test` 2036；其余 8 个 `--verify-*` 全过。

#### 版本

- **1.4.1（补丁版）** —— 修 1.4.0 的折叠 / 缩放交互；
  bundle id 仍为 `com.desktoptimetable.app.v120`，数据和授权全部互通。

## [1.4.0] - 2026-11-07

### 课表折叠 / 展开（只留顶栏 + 状态条 + 表头）

用户原话：
- 「下一阶段想实现课表的折叠功能，就是只有日期和表头，然后课表什么的都被收起来」
- 「在课表的某个位置有那种折叠的一个按键，在月份的右边这里放一个行不行，
  按一下之后，课表就被折叠或被展开。但是，有那种过程动画」

#### 需求口径（与用户确认）

- **按钮位置**：状态条最右侧（「自由安排」右边），不是真的挤进 58pt 的月份格；
- **折叠后保留**：顶栏 + 状态条 + 表头（100% 档约 173pt）；
- **收起方向**：卡片**顶边不动**，从底部收上去；
- **不落盘**：重启默认展开（不做折叠状态持久化）。

#### 实现

- **网页**（`Resources/Timetable.js` / `Timetable.css`）：
  - 网格外面套一层 `.gridwrap { overflow: hidden }`，折叠时容器高度
    `638 → 38`（只留表头）；表头以下的 `.tcell` / `.cell` 按 `--tt-collapse` 淡出。
    只裁剪、**不动网格内部几何** —— 表头 / 日期列的坐标和命中一个都不变。
  - 状态条右侧加 18pt 折叠按钮（`.collapsebtn`，▾ 展开 / ▴ 收起），
    点击 `post('toggleCollapse')`；折叠态点表头 → 先展开并带上 `day`，
    展开完原生再打开那一列的日期覆盖层。
  - `window.ttSetCollapse(p)` 由原生每帧调用；`render()` 重建 DOM 后自动补回折叠高度
    （否则原生一推状态，卡片就自己弹开）。
- **原生**（`TimetableLayout` / `AppDelegate` / `WebCardRenderer`）：
  - `TimetableLayout.collapse`（0…1）+ `collapseBodyHeight = 600`；
    `cardHeight` 随折叠变矮，`baseCardHeight` 仍是**展开态** ——
    缩放上限 / 常驻画布都按展开档算，窗口不用动（不闪、不被裁）。
  - 卡片矩形：x 居中、**顶边 = 展开时的顶边**，高度按进度插值。
  - `animateCollapse`：0.30s、60fps、ease-out cubic；每帧同时写
    网页 `ttSetCollapse` 和原生玻璃 / 点击穿透 / 图钉 / 悬停区域。
  - 折叠态缩放：`WebCardRenderer.cardCenterInPage` 跟随折叠（中心上移），
    拖动帧 / 松手对位按当前中心算，否则折叠卡片会被摆低一截。
  - 调试出图：`DT_COLLAPSE=1`（启动后自动收起）、
    `--shot-web-card out.png 1.0 collapse`。

#### 自检

- 新增 `--verify-collapse`（通过）：
  - 点按钮收起：顶边 / 左边不动，宽度不变，高度 **773 → 173**；
  - 网页卡片 **173×968 = 玻璃 173**；网格容器高 38；正文透明度 0；
  - 点击穿透 = 折叠矩形；窗口 frame 不动；
  - 展开 0.10s 时高度 **598**（有过渡，不是瞬切），展开后回到 773；
  - 原生推状态重建 DOM 后仍保持 173；
  - 折叠态拖到屏幕左边 `x=0`；折叠态缩放到 1.10 高度 189.94、完整在画布内；
  - 折叠态点表头 → 先展开，再打开 day=3 的覆盖层。
- `make test`：**2036 项断言全过**；`--verify-card-scale` / `--verify-scale-panel` /
  `--verify-scale-drag-edge` / `--verify-hover` / `--verify-day-panel` /
  `--verify-day-panel-click` / `--verify-pin-flow` / `--verify-settings-card` 全过。
- 截图：折叠态窗口（顶栏 + 状态条 + 表头、毛玻璃、圆角、按钮 ▴）、
  展开态按钮 ▾、折叠态网页层 1:1。

#### 坑（以后改这里先看）

- **按钮不能把状态条撑高**：状态条内容高 15px，按钮视觉 18px 但用
  `margin: -2px 0` 把占位压回 14px；否则整张卡片会高 1px，
  `TimetableLayout` 的公式 / 夹屏 / 自检（773）全部对不上。
- 折叠按钮也要登记进 `HOVERABLE` + 写一份 `.tt-hover` 规则
  （模式 B 收不到真 hover）。
- `.gridwrap` 的 `overflow: hidden` 会把日期覆盖层一起裁掉 ——
  所以折叠前必须 `closeDayPanel()`，折叠态点表头走「先展开再开」。

#### 版本

- **1.4.0（次版本）** —— 新增折叠 / 展开功能；bundle id 仍为
  `com.desktoptimetable.app.v120`（课表数据、日历 / 提醒事项授权、登录项全部延续）。

## [1.3.3] - 2026-11-07

### 放到最大时右边被削（卡片偏出画布，被 webView 裁）

用户原话：「放到最大，怎么右边被削了」

#### 根因

- 面板开着缩放时，窗口是**钉死不动**的，卡片靠网页 translate 挪到
  屏幕上被夹过的锚点。
- 画布（窗口）只比最大档卡片宽 `2×90×scale ≈ 208pt`。卡片一被夹到画布
  一侧 —— 例如先缩到 70% 把课表贴到屏幕左边、再在面板里放到最大，
  中心会被夹着推开 207pt —— 卡片右边就超出 `webView` 边界，
  被 WebKit 直接裁掉（原生毛玻璃还在，看起来就是「右边一条没了」）。
- 这个偏差还会**留在画布一侧**：之后拖窗口也不会自愈，重启按居中还原才消失。

#### 修复

- 缩放帧里窗口**跟着卡片中心走**（取整到整点），translate 只补窗口原点
  取整剩下的亚像素零头（≤0.5pt）：卡片永远落在画布正中，不可能被裁；
  窗口服务器截断小数带来的抖动仍然由 translate 补着，不会抖。
- 文档/注释同步：现在的口径是「**窗口尺寸不变、位置跟着卡片中心走**」，
  不再是「窗口位置全程不动」。

#### 自检

- `--verify-scale-panel` 新增「放到最大不能裁」：
  70% 贴屏幕左边 → 面板里拖到最大 → 卡片在窗口坐标
  `(102, 102, 1092, 872)`（画布 1296×1076，右边 1194 < 1296），
  网页实际矩形右 1193.96 / 底 972.25，都在 `webView` 内；
  屏幕上 `x≈0..1092`、`y≈53..925` 完整可见。
- 真实窗口截图：113% 卡片四边完整、左右留白对称（修复前右边被切掉 55pt）。
- 其余 `--verify-*` 与 `make test` 2031 全过。

#### 版本

- **1.3.3（补丁版）** —— 修 1.3.2 里「放到最大会被画布裁」的回归；
  bundle id 仍为 `com.desktoptimetable.app.v120`，数据和授权全部互通。

## [1.3.2] - 2026-11-07

### 放大后课表发糊 / 玻璃错位（松手没把「位图放大」收尾成 pageZoom）

用户原话：
- 「继续修复课表放大的问题」
- 「放大缩小之后不能够拖动到边缘的问题」

#### 根因

- 在设置面板里拖「课表大小」时，**拖动帧**为了和窗口同步，走的是
  `body { transform: scale(s) }` —— 合成器把已经画好的位图放大，
  文字本来就比 `pageZoom` 糊（这是拖动预览的取舍）。
- 但**松手时没有收尾**：`commitCardScale` 在「面板开着」的分支里把最终值
  又走了一遍拖动帧，从来没有切回 `pageZoom`。于是：
  - ≥100% 档整张课表一直停在位图放大，字发糊，**直到重启才恢复**；
  - 更糟的是 `WebCardRenderer.usesPageZoom` 是按 `viewScale` 判断的，
    松手后 `viewScale = 1.12`、`rectScale` 也变成 1.12，而网页实际还是
    transform（`getBoundingClientRect` 返回的已经是视觉坐标）——
    毛玻璃 / 卡片中心 / 命中换算全都多乘一个 1.12。
    实测：松手瞬间卡片中心跳 **65.7pt**，玻璃比卡片大 1.12 倍。
- 原生侧 `TimetableLayout.cardRectOverride`（卡片在窗口坐标系里的矩形）
  在松手后没有跟着换：它还留着拖动帧按**旧窗口原点**算出来的矩形。
  之后拖动夹屏（`DesktopWindow.move`）按这个过期矩形算 ——
  卡片「离屏幕边还有一百多磅就拖不动」；放大档甚至被顶出屏幕
  （112% 时卡片底部整条在屏幕外，卡片顶部顶到屏幕上方）。

#### 修复

- 新增 `WebCardRenderer.applyScale(_:keepingCardCenter:)`：松手把拖动用的
  `transform` 收尾成正式档位（≥100% 用 `pageZoom`），translate 按**当前可见
  中心**算 —— 不重排窗口、不把卡片摆回画布中心，所以不闪也不跳。
- `TimetableLayout.apply(scale:)` 加结构性护栏：**缩放一变就作废
  `cardRectOverride`**（过期矩形再也不会被拿去夹屏）；
  `performCardScale` / `finishCardScaleInCanvas` 在重排后写入新的
  「968×773×scale」矩形（网页实测尺寸，和网页严丝合缝）。
- 关闭设置面板后的位置保存改成「**卡片**位置」口径：存的是
  「卡片居中时窗口原点该在哪」，重启后按居中值还原不会平移
  （之前卡片被夹在画布一侧时会差一百多磅）。
- 自检：新增 `--verify-scale-drag-edge`（四档 × 四方向 + 真实用户路径
  「面板里放大 → 关面板 → 拖到边缘」）；`--verify-scale-panel` 增加
  `pageZoom` / 中心不跳 / 玻璃不跳的断言；新增 `--shot-web-card` 网页层出图口
  （`--shot-card-scale` 只能截到原生层）。

#### 自检

- `make test`：**2031 项断言全部通过**（新增 8 项，含两个新开关的自动化登记）。
- `--verify-scale-drag-edge`：通过
  - 70% / 85% / 100% / 112% 四档，卡片贴边误差 ≤ **0.8pt**
    （如 112% 左上：`x=0.002`、上边 `948.99` vs 可见区 `949`；
    右下：右边 `1511.8`、下边 `52.45` vs `53`）；
  - 贴边时卡片**完整可见**（不越出可见区 2pt）；
  - 真实用户路径（面板拖到 112% → 松手 → 关面板 → 拖到左上/右下）：
    左上 `(-0.08, 83.12)`、右下 `(427.92, 53.12)`，两边都贴到屏幕边缘。
- `--verify-scale-panel`：通过
  - 放大松手：`usesPageZoom=true`、`pageZoom=1.12`（不再是 transform 位图放大）；
  - 松手前/后卡片中心 `(830, 516.12)` → `(830, 516.12)`（Δ 0.00pt）；
  - 毛玻璃随网页实测只修正 1.37pt（之前是 65.7pt 级别的错位）；
  - 关闭面板后仍走 `pageZoom`，中心不跳。
- `--verify-card-scale` / `--verify-hover` / `--verify-day-panel` /
  `--verify-day-panel-click` / `--verify-pin-flow` / `--verify-settings-card` /
  `--verify-panel-sections`（含出图）全部通过。
- 截图确认：`--shot-web-card 1.12` 的网页层 1:1 裁切（时间列 / 星期 / 日期文字
  清晰、无裁切）；设置 → 外观页（「卡片大小」行 70%–113% 正常）。

### 追加：缩放 → 把课表拖到别处 → 再缩放，卡片会跳

用户没直接报，是上面两条的同一片代码里挖出来的：

#### 根因

- 缩放锚点 `cardScaleAnchorCenter` 在拖动开始时锁一次，但**面板开着时松手
  从不清空** → 用户先缩放过一次、再把课表拖到别处、然后接着缩放，
  还会按**上一次**的锚点摆，卡片被拽回老位置。
- `dragPageTopLeft`（拖动帧算 translate 用的「页面原点」）只在
  `enterDragWindow` 里取一次；面板开着时窗口不动，但用户可以把课表拖走，
  下一轮缩放沿用旧原点 → 卡片多平移一次拖动的距离（实测 +120pt）。
- `webCardCenterInWindow()` 一律返回窗口中心；面板开着时卡片可能被夹在
  画布偏一侧，窗口中心 ≠ 卡片中心 → 锚点取错，再缩放会被夹回画布中心
  （实测 62pt）。

#### 修复

- 面板开着时松手：`finishCardScaleInCanvas` 之后清空 `cardScaleAnchorCenter`。
- 新一轮缩放开始时 `dragWindowActive = false`，让 `enterDragWindow`
  重新取当前窗口原点 / 画布尺寸。
- `webCardCenterInWindow()` 优先用 `TimetableLayout.cardRectOverride`
  （可见卡片矩形），没有覆盖值才退回窗口中心。
- `--verify-scale-panel` 增加「缩放 → 拖走 → 再缩放」断言。

#### 自检

- 缩放后中心 `(830, 516.12)` → 拖动后 `(950, 485.12)` →
  再缩放 `(950, 485.12)`（Δ 0.00pt）；关面板仍 `(950, 485.12)`。
- `make test` 2031 通过；其余 `--verify-*` 全过。

#### 版本

- **1.3.2（补丁版）** —— 修 1.3.1 暴露的缩放边角问题（放大发糊 / 拖不到边 /
  缩放后跳回旧锚点）；bundle id 仍为 `com.desktoptimetable.app.v120`，
  数据和授权全部互通。

## [1.3.1] - 2026-11-07

### 常驻画布：缩放 / 松手 / 关闭面板不再换窗口（结构性修复）

用户原话：
- 「放大到 112% 时边缘只剩毛玻璃，课表内容不显示」
- 「松手后卡片和设置面板错位，有时候还闪一下」
- 「点课表内部、设置消失时会闪一下」

#### 根因

- 拖动/缩放时临时进入「大画布」，松手或关设置面板时又恢复「普通窗口」；
- 窗口尺寸/原点是同步改的，网页 transform 是异步的 —— 切换那一帧对不上，就闪；
- 临时画布里的 webView 从「页面原点」开始铺，卡片放大贴边、被夹回屏幕后
  可能跑到 webView 的 frame 之外，WKWebView 把超出部分裁掉，原生毛玻璃还在
  → 边缘只剩毛玻璃；
- 原生卡片高度按盒模型算 782，浏览器实测 `.card` 是 773，上下各多出 4.5×s
  的毛玻璃带。

#### 修复

- **窗口改成常驻画布**：窗口永远 = 当前屏幕最大档卡片 + 四周留白；
  卡片在画布里居中；缩放只改网页 `translate+scale`/pageZoom，
  窗口尺寸和位置全程不动；
- 启动时把 webView 同步成画布尺寸，页面原点固定在画布左上角，
  卡片用 translate 摆到画布中心 → 卡片贴边也不会被 webView 裁；
- 原生卡片高度按浏览器实测减 9×s（scale=1 时 773），和网页严格对齐；
- 关闭设置面板不再恢复普通窗口；图钉/位置保存仍按窗口原点，
  自检的拖动起点/保存位置按常驻画布口径修正；
- 拖动帧 watchdog（0.12s）与松手强制重发保留。

#### 自检

- `make test`：**2023 项断言全部通过**；
- `--verify-card-scale`：98→102% 中心 Δ = **0.00pt**；
  贴左上/右下放大到 112%：屏内 = true、窗内 = true；30 帧 2.75ms / 6.83ms；
- `--verify-scale-panel`：拖动中/松手后窗口都是 `1296×1076`（不变），
  关闭面板后卡片中心差 < 3pt；
- `--verify-hover` / `--verify-day-panel` / `--verify-day-panel-click` /
  `--verify-pin-flow` / `--verify-settings-card` / `--verify-panel-sections`
  全部通过；
- 设置面板 → 外观 实截图确认（外观页、卡片大小行、版本号行正常）。

### 1.3.1 追加：图钉跑出卡片 / 缩小后贴不到屏幕边缘

用户原话：「缩小之后有时候左上角的图钉直接不在课表框内了」
+「不是最大尺寸的时候，课表移动不到桌面边缘，中间隔着距离就移动不了了」。

#### 根因

- 图钉是原生控件，启动时按**旧窗口**的卡片矩形摆；窗口改成常驻画布后卡片
  已经居中，图钉却还停在旧窗口左上角（截图里图钉在桌面上、离卡片很远）。
- 常驻画布窗口比屏幕大（1296×1076 vs 1512×896）。AppKit 默认的
  `constrainFrameRect` 会把窗口框往屏幕里顶，导致卡片永远贴不到屏幕边、
  中间固定隔着一段画布留白（约 150pt）。

#### 修复

- `syncWebViewToCanvas()` 里同步重摆图钉（按画布里的卡片矩形）；
- `DesktopWindow` 覆盖 `constrainFrameRect` 原样返回 —— 窗口框可以出一部分
  屏幕，卡片仍由 `move(to:)` 按可见区夹住，所以既能贴边、又不会跑出屏幕。

#### 自检

- `--verify-pin-flow` 通过（图钉在卡片内、真事件拖动 120×60、写盘位置一致）；
- `--verify-card-scale` / `--verify-scale-panel` / `--verify-hover` /
  `--verify-day-panel` / `--verify-day-panel-click` / `--verify-settings-card` /
  `--verify-panel-sections` 全过；`make test` 2023 全过。

#### 版本

- **1.3.1（补丁版）** —— 修 1.3.0 缩放功能的边角问题；
  bundle id 仍为 `com.desktoptimetable.app.v120`，数据互通。

## [1.3.0] - 2026-11-06

这一版加一个**新功能**：课表卡片的大小可以在设置面板里用滑块调。

用户原话：「做滑块拖动改变大小就像设置里面的其他一样工程量」
+「A，在谈一下大小改变中心选择的问题」+「实时变化」

### 需求与口径（与用户确认）

- **滑块**，和设置面板里其它外观项（变实秒数 / 变虚秒数 / 不透明度…）同一套写法。
- **整体等比缩放** —— 宽高同一个系数。不做宽高独立：那等于把 CSS 里
  268 处写死的 px 全部变量化，代价 1~1.5 天。
- **缩放锚点 = 卡片中心** —— 缩放前后卡片中心在屏幕上的位置不变，
  课表原地胀大 / 缩小。
  这么定的理由：所有后续窗口（设置面板、课程编辑器、确认框）都以
  **课表中心**为锚点（`WindowAnchor.provider` → `DesktopWindow.cardCenterOnScreen`），
  中心飘了就意味着**正在打开的设置面板会相对课表错位**。
- **拖动中实时变化**，**松手才写盘**（每帧写盘太浪费）。
- 滑块范围 **70%–115%**，但**实际生效值还要按当前屏幕可见区夹一次**
  （卡片比屏幕高时会被裁掉）。超限时给一句提示，不静默改值。

### 前置 · Spike（`docs/spike-pagezoom-结论.md`）

先用独立程序（不改项目源码）实测 `WKWebView.pageZoom` 的坐标语义，
确认这条路可行才动手：

| 事实 | 值 |
|---|---|
| CSS 视口宽度 | **恒为 1148**（`body` 写死的宽度，不随 `pageZoom` 变） |
| CSS 版式尺寸 | **完全不变**（`.hcell` 恒为 118.86 CSS px） |
| 1 个 CSS px 在屏幕上占 | **恰好 `scale` 个 view 点** |
| 原生 view → CSS 换算 | **`css = view ÷ scale`** ✅ 两档实测命中正确 |

结论：**`Timetable.css` 一处都不用改** —— 这是最大的好消息。

### 修复 · Fixed

- **新增 `Model/CardScalePolicy.swift`** —— 取值策略（纯函数，可单测）：
  滑块范围、`clamp`、按屏幕算的 `maxScale`、超限提示文案。
- **新增 `UI/TimetableLayout` 的缩放参数化**：
  - `apply(scale:)` + 全部派生尺寸按 `scale` 等比放大
    （74 处调用点**零改动**）；
  - ⚠️ **投影留白也跟着缩放** —— 不缩的话「窗口中心 = 卡片中心」不成立，
    「保持卡片中心不动」这条保证会破；
  - ⚠️ **尺寸取整** —— 窗口尺寸只能是整数点，不取整的话
    「算出来的卡片位置」和「窗口里实际的」差零点几，
    缩放几次之后卡片中心会漂一两磅。
- **新增 `AppDelegate.applyCardScale(_:persist:)`**：
  - **保持卡片中心不动**：先改尺寸 → 量出实际卡片中心 → 算出偏差 → 平移回去。
    ⚠️ 不能「算目标原点 → `setFrameOrigin`」：课表窗口比屏幕可见区还高
    （962 > 896，四周还留 90pt 投影），系统会把 y 顶上去
    （实测请求 20 → 实际 0）。
  - **16ms 节流**（拖动中每帧都来，不节流会卡）。
  - **按新卡片尺寸重新夹屏**（顺序不能换：先缩放再夹）。
- **网页层缩放**（`WebCardRenderer`）：
  - `applyPageZoom(_:)` 设 `webView.pageZoom`；
  - ⚠️ **`cssPoint` 要先 ÷ scale 再翻 y** —— `pageZoom ≠ 1` 时
    CSS px 与 view 点不再 1:1，不除就会「点日期点不中 / 悬停错列」；
  - ⚠️ **`reportLiveCardFrame` 要把 CSS 矩形乘 scale** ——
    `getBoundingClientRect` 返回 CSS px，原生那边当 view 点用，
    不乘的话毛玻璃层会小一圈 / 大一圈。
- **设置面板新增「课表大小」卡片**（`SliderRow`，和其它 5 行同一套写法）：
  - 标题「卡片大小」，副标题「缩放桌面上的课表 · 范围 70%–<当前屏幕上限>」
    （第二轮改成按屏幕算，见下；以前固定写 115%）；
  - **拖动中实时预览、松手才写盘** —— 为此给 `SliderRow` 加了
    `onDragBegin` / `onDragEnd`（`NSSlider` 本身没有「拖动结束」的信号，
    `isContinuous = true` 时 `action` 每帧都发）。
- **老配置自动兼容**：`config.json` 里没有 `cardScale` → 读成 `1.0`。

### 途中修掉的三个坑

1. **`cardHeight` 被缩放两次** —— 里面调了已经乘过 `scale` 的 `gridHeight`，
   外层又乘一次，1.15 时高度算成 1009（应为 899）。
2. **写盘写的是旧值** —— `saveAppearance(appSettings.appearance)` 写的是
   `appSettings.appearance`，只改 `config`（当前生效的快照）的话写出去的仍是旧值。
3. **毛玻璃层尺寸没跟着缩放** —— 缩放不推状态（状态没变），
   `reportLiveCardFrame` 不会被触发，玻璃层停在旧尺寸。
   现在缩放后会重新量一次。

### 自检 · Verification

- `make test`：**2018 项断言全部通过**（1.2.7 是 1938 项，新增 80 项）。
- 新增 `--verify-card-scale`（自检进程，不碰用户真实数据）：
  - 四个档位（70% / 85% / 100% / 115%）的卡片与窗口尺寸正确；
  - **卡片中心在缩放前后不动**（≤ 0.5pt，窗口位置会被系统吸附到半像素）；
  - 缩放后按新卡片尺寸夹屏，卡片仍完整落在可见区里；
  - **网页层的坐标换算**：`cssPoint` 能把 view 坐标还原回同一个 CSS 坐标，
    且点第 3 列的课程格命中第 3 列；
  - **网页卡片与原生卡片重合**（宽度严丝合缝；高度容差 12pt —— 见下）；
  - 缩放值写盘 → 读回来一致；老配置（缺 `cardScale`）读成 1.0。
- 回归自检全部通过：`--verify-hover` / `--verify-day-panel` /
  `--verify-day-panel-click` / `--verify-pin-flow` / `--verify-settings-card` /
  `--verify-web-render` / `--verify-snapshot-mode`。
- **真机截图确认**：
  - 设置面板「外观」页 —— 「课表大小」卡片与其它行版式一致；
  - 四个档位的桌面卡片 —— 整张课表等比缩放，版式 / 文字 / 图标比例关系不变。
- **零副作用验证**：scale=1.0 时与 1.2.7 的出图**逐像素完全一致**
  （最大差异 0.0）。

### 第二轮修（实机反馈）· 比例 + 拖动流畅度（2026-11-06 下午）

用户试了滑块后反馈：「目前缩放还存在比例问题，拖动缩放不够流畅」。

#### 根因 · Root cause

1. **毛玻璃层用了建窗时的旧高度**：`onLiveCardFrame` 闭包捕获了
   `webHeight`（建窗时 962），缩放后窗口变高、网页矩形也变大，
   翻 y 却还用旧值 —— 1.15 档玻璃整体下移 **144pt**，
   卡片上半截没玻璃、下半截多出一块（截图里非常明显）。
2. **点击穿透区域没跟着缩放**：`LiveContainerView.passthroughRect` 只在建窗时
   设过一次；放大后卡片右/上一条边点不动，缩小后卡片外的空白又挡住桌面。
3. **`pageZoom < 1` 会触发 WebKit 的「最小逻辑字号 9pt」**（实测）：
   0.7 档 `.wkdate` 9.5px 被撑到 **12.86px**、顶栏 55 → 63.3px、
   整张卡片 773 → **782.5px**（+1.2%），比例已经不是等比了；
   卡片变高 → 出现滚动条 → 又吃掉 24px 版式宽度。
4. **滚动条**：`body` 固定 1148px，缩放后视口可能只有 1147（pageZoom）
   或 804（transform），WebKit 会加滚动条 —— 卡片右边的投影留白里
   露出一条灰条，还让版式重排。
5. **拖动卡顿**：每帧都在做重活 —— 推整份状态 JSON 给网页、跨进程量
   `.card` 矩形、重算悬停、窗口摆两次；同时设置面板每帧把被屏幕夹住的
   值写回滑杆（上限 115%，这块屏实际只能到 111.5%）——
   滑杆和鼠标抢位置，手感「粘、拖不动」，百分比也和实际大小对不上。

#### 修复 · Fixed

- **网页层分两档缩放**（`WebCardRenderer`）：
  - **≥ 100%**：`pageZoom`（这一侧没有最小字号限制，文字按真实分辨率排版，最清晰）；
  - **< 100%**：`pageZoom = 1` + `body { transform: scale(s) }`（纯视觉缩放，
    版式一个像素都不改，小字严格按比例缩；不再触发 9pt 下限）。
  - 两个坐标系数分开：`pageZoomFactor`（view → 网页坐标要除它）与
    `rectScale`（`getBoundingClientRect` × 它 = view 点）；
    `cssPoint` 的 y 翻转改用**当前窗口高度**（不再用网页版式高度）。
  - `Timetable.js` 的 `gridGeom` / `columnGeom` 按 `window.__ttGeomScale`
    把视觉矩形还原成版式 px —— 日期覆盖层在缩小档位仍贴在正确的列上。
  - `html, body { overflow: hidden }`：锁死滚动条（覆盖层自己滚）。
- **毛玻璃层**：回调用**当前容器高度**翻 y；拖动中按缓存的「网页布局矩形 ×
  新系数」就地更新（不跨进程）；圆角随缩放（`cardRadiusScaled`）。
- **点击穿透区域**：`passthroughRect` 每次缩放都同步成 `TimetableLayout.cardRect`。
- **图钉跟着缩放**：尺寸 / 间距 / 标题宽度 / SF Symbol 点号全部 ×scale
  （以前卡片缩到 70% 时图钉还是原尺寸，比例会变大）。
- **滑杆上限 = 当前屏幕放得下的最大值**（这块屏约 112%），副标题显示真实范围；
  拖动中**不再把值写回滑杆**，只在松手时回填一次。
- **拖动路径减负**：每帧只做「窗口重排 + 网页缩放 + 玻璃/图钉/穿透区域」；
  状态推送、网页矩形复量、悬停重算、写盘全部挪到松手时做一次。
  卡片中心的「量了再修」保留在每帧（多一次窗口往返，实测仍远低于帧预算），
  避免松手瞬间跳一下。
- **修掉拖动时的轻微抖动**（用户追加反馈「放大缩小时课表有轻微抖动」）：
  - 根因：锚点用的是原生 `cardRect` 的中心 —— 它按整数点取整，
    中心随缩放 ±0.5pt 跳；而且每帧都重新读「当前中心」再取整，
    形成「目标自己也在跳」的反馈。实测可见的**网页卡片中心**
    在 70% → 100% 拖动中漂移 **2.05pt**。
  - 修复：拖动开始时**锁一次锚点**（屏幕坐标），全程用同一个；
    锚点取**网页卡片中心**（`WebCardRenderer.cardCenterInWindow`，
    随 scale 连续变化），窗口定位和「量了再修」都按它算；松手释放。
    原生矩形只用于命中 / 穿透，不再参与锚点。
  - 结果：网页卡片中心漂移 **2.05pt → 0.64~0.74pt**
    （剩下的是窗口位置吸附到半像素带来的 1 个物理像素，肉眼不可见）。
- **快速拖动时的抖动 + 设置里的版本号**（用户追加：「拖动比较快的时候，抖动还是很明显」/
  「在课表设置的系统里面，最下面加上当前的版本号」）：
  - 根因 1：窗口尺寸 / 位置是**主线程同步**改的，网页缩放（`pageZoom` / CSS transform）
    是**跨进程异步**的。先改窗口、后改网页时，可见卡片会按 `574 × Δscale` 跳一下 ——
    拖得越快 Δscale 越大，抖动越明显。
  - 根因 2：拖动被 16ms 定时器节流到约 60fps；在 120Hz 屏幕上快速拖动会「一顿一顿」。
  - 修复：拖动帧**串行化** —— 先用 `WebCardRenderer.applyDragScale` 把这一帧的缩放
    写进网页，**等它应用完**再在同一个回调里对齐窗口 / 视图 / 玻璃；
    期间又来的拖动值只保留最新一份（不堆消息）。拖动期间统一用 CSS transform
    （松手时 `applyScale` 再切回 pageZoom，恢复清晰）。
  - 去掉 16ms 节流：拖动更新率跟着事件走（最高 120Hz），不再被钉在 60fps。
  - 设置 → 系统 最下面新增版本号「桌面课表 · 版本 x.y.z」，
    从 `Bundle.main` 的 `Info.plist` 读（不在代码里写死）。
- **100% 附近「整个画面抖一下」**（用户追加：「99~100 / 100~101，
  连续拖动到这儿的时候整个课表会抖一下」）：
  - 根因：窗口服务器会把 `setFrameOrigin` 的小数**截断到整点**
    （独立实测：300.37→300、301.5→301、302→302），而卡片中心要随 scale
    连续移动。每帧移动窗口，中心就会被取整带得 ±0.5~1pt 跳；
    实测 98→102% 时，100% 这一步的中心跳了 **1.00pt**（邻居都是 0）。
  - 修复：拖动期间改用**固定窗口**，卡片位置由 `translate(...) scale(s)` 决定——
    translate 可以落在任意小数上，不再受窗口取整影响。
    玻璃 / 图钉 / 点击穿透区域按 translate 之后的卡片矩形同步。
  - 过渡问题（用户两次截图）：① 按「窗口中心」放大到最大档时，卡片相对窗口
    的位置变了，网页 transform 还没到 → 点下滑杆瞬间错位再弹回；
    ② 改成「沿用当前窗口」后，从低档位往上拖、卡片快超出窗口时会再放大一次
    （82% 附近又错位一下）。
    **最终做法：进入拖动时把窗口一次放大到最大档，但保持窗口「左上角」不动。**
    网页内容是从左上角往下排的，左上角不动 → 卡片在屏幕上一点不挪，
    多出来的透明区域落在右下；整个拖动期间窗口不再变化。
  - 用户又反馈：**放大到 110% 时卡片被屏幕切掉**（左边一列没了）。
    根因：① 缩放只保「中心不动」，卡片大到边缘时一半在屏幕外；
    ② 拖动窗口只在卡片附近，卡片被夹回屏幕后可能跑到**窗口边界之外**被裁。
    修复：① 每一档按当前卡片尺寸把中心**夹进屏幕可见区**；
    ② 拖动窗口换成「屏幕可见区四周各扩 200pt」的**画布**，
    webView 在窗口里**偏移**、保持页面原点不动 —— 卡片不动，也不会被窗口裁。
  - 验证：从屏幕左上 / 右下贴边开始拖动放大到 110%，
    卡片同时满足「屏内 = true / 窗内 = true」；98→102% 中心 Δ 仍为 0.00pt。
  - 用户又反馈：**每次拖动松手都会闪一下，设置面板有时也跟着移动**。
    根因：松手时要把「拖动画布」缩回正常窗口、网页 transform 从
    `translate+scale` 切回 `scale` —— 窗口是同步改的、网页是异步的，
    中间一帧就不一致（闪）；面板重对齐（#alignToCardCenter）本身也是一个可见位移。
  - 修复：**设置面板开着时，松手保留拖动画布**——窗口尺寸/位置、网页页面原点
    全都不动，只把最终 scale 写进网页（没有窗口/原点切换，就没有那一帧）；
    面板不再自动移动。等**设置面板关闭**时再一次性恢复成正常窗口
    （那一下被面板收走遮住），并把卡片中心作为锚点，避免关闭时跳位。
    `saveWindowState` 在画布阶段也会跳过（画布原点不是课表位置）。
  - 用户再反馈：**有时候移动滑块后课表突然「对不齐」**（截图：滑块/状态 93%，
    但卡片明显还是 100% 的大小）。按截图量：设置面板 580pt = 810px（比例 1.397），
    卡片 1365px ÷ 1.397 ≈ 977pt ≈ 968×1.0，**不是 93% 应有的 900pt**。
    说明不是位置夹屏的问题，而是**网页还停在上一档**。
  - 根因：拖动时每个缩放值都要等上一帧的
    `evaluateJavaScript` 回调（`dragScaleInFlight`）才发下一帧。拖动开始时
    画布会改 webView 尺寸/视口，第一帧（恰好是当前档的「空操作」）的 JS 回调
    偶尔会被 WebKit 拖住/丢掉；之后滑块的所有值都只进 `pending`、永远不落地，
    卡片就停在拖动开始那一档（100%），松手时也被 `if !dragScaleInFlight` 挡住。
    这也解释了「有时候」——取决于那一次 WebKit 的回调时延。
  - 修复：① 每帧加 **0.12s 兜底定时器**，超时强制重发 pending；
    ② 松手时**强制重发最终值**（作废在途帧、直接发最终 scale，不再等回调）；
    ③ `applyDragScale` 记录 JS 错误，便于下次定位。
  - 验证：`--verify-scale-panel` 新增「连续快速拖动 40 步（8ms/步）→ 松手」，
    实测网页最终 `transform = translate(...) scale(0.95)`、卡片宽 **919.6pt**
    （理论 968×0.95 = 919.6）；松手窗口不变、关闭面板中心差 < 0.5pt。

#### 自检（第二轮）· Verification

- `make test`：**2023 项断言全部通过**。
- `--verify-card-scale` 新增断言（四个档位全跑）：
  - **网页卡片严格等比**：高宽比与 100% 基准的偏差 < 0.5%
    （实测 70% / 85% / 100% 都是 0.000%，111.5% 是 0.139%）；
  - **小字号不再被撑大**：`.wkdate` 在四个档位都保持 9.5px；
  - **毛玻璃层与网页卡片逐点重合**（≤1.5pt，四个档位实测 0.0）；
  - **点击穿透区域 = 缩放后的卡片矩形**（≤0.5pt）；
  - **拖动冒烟（真实拖动路径，固定大窗口 + translate）**：30 帧（70% → 100%）
    每帧平均 **2.64ms / 最大 6.13ms**；
    **可见的网页卡片中心**全程漂移 **0.00pt**；
    98% → 102% 边界逐步检查（含 100%）中心 Δ 均为 **0.00pt**。
- 新增 `--verify-scale-panel`（设置面板开着时的缩放路径）：
  面板开着 → 拖动进入大画布（1912×1296）→ **松手窗口/原点完全不变**
  （所以不会闪）→ 关闭面板后恢复正常窗口、卡片中心不跳（±2pt）。
- 回归：`--verify-hover` / `--verify-day-panel` / `--verify-day-panel-click` /
  `--verify-pin-flow` / `--verify-settings-card` / `--verify-panel-sections`
  / `--verify-web-render` / `--verify-snapshot-mode` 全部通过；
  `--verify-day-panel` 在配置 `cardScale=0.7` 下也通过（覆盖层几何还原正确）。
- **真机截图**（`screencapture -l` 抓真实窗口，鼠标移入后拍）：
  - 70% / 111.5%：无滚动条、无玻璃错位带，卡片整体等比、图钉比例正常；
  - 70% 点表头打开日期覆盖层：定位在正确列、宽度=一列、渐变尾巴到底；
  - 70% 悬停齿轮：网页内 `.tt-hover` 高亮正常（命中换算正确）；
  - A 模式（`DT_SNAPSHOT=1`）70% 与 B 模式观感一致；
  - 设置 → 系统 底部显示「桌面课表 · 版本 1.3.0」
    （`--shot-settings /tmp/sys.png system` 出图确认）。

### 已知差异 · Known difference

- **原生卡片高度 782 vs 网页实际 773**（差 9px）——
  这是 1.2.7 就有的固有差异（代码里早记过「原生另算一套几何和网页实际布局差了 7px」）：
  原生高度是**公式算**的，网页高度是**内容撑**的。
  - **不影响命中**：B 模式（默认）下点课程 / 点表头走
    `forwardClick` → 网页自己的 `elementFromPoint`，全程用网页坐标；
  - **但会按比例放大**（1.15 时差 11px），所以自检里高度容差给到 12pt，
    宽度仍然严丝合缝（宽度决定「点的是哪一列」）。

### 版本 · Version

- 功能新增 → **1.3.0**（bundle id 不变 `com.desktoptimetable.app.v120`），
  用户确认按次版本发布（2026-11-06）；
- 构建归档 `版本迭代/DesktopTimetable-1.3.0.app`；1.2.7 及更早归档保留；
- `Makefile` / `Resources/Info.plist` / `README.md` 已同步为 1.3.0；
- 根目录既有 `.app` 未覆盖，未执行 `make install`。

## [1.2.7] - 2026-11-06

这一版修 1.2.5 引入的一个副作用：**鼠标移到课表外面，课表不淡出了**。

用户原话：「为什么修改完成或者是点击了取消之后，鼠标移动到课表外面，课表没有消失了。」

### 根因 · Root cause

1.2.5 为了「点权限弹框时课表别消失」，加了 `PermissionPromptWatch`：弹框期间
强制 `inside = true`（课表亮着），拿到授权回调才 `end`。

问题出在**回调不一定来**（`DayPanelController` 的注释里早就写过这个坑）：

- 日历 + 提醒事项是**并行**请求的；
- macOS 有时只弹**一个**框，另一个请求就**永远不回调**；
- 那一笔 `begin` 等不到自己的 `end` → 保持状态一直挂着 →
  课表被钉在可见状态，指针移到哪都不淡出（旧上限 120 秒，用户会以为「坏了」）。

### 修复 · Fixed

- **每个原因各自兜底超时**（`PermissionPromptWatch`）：`begin` 时排一个
  `DispatchWorkItem`，到点自动销掉这一笔并通知「退出保持」，
  不再依赖回调一定会来。
- **上限从 120 秒收到 10 秒**：与 `DayPanelController.requestAccess` 的
  「10 秒没回调就不再等」保持一致。正常点「允许」在 1~2 秒内，
  拿不到回调时最多亮 10 秒就回落。
- **请求超时时一并收尾**：`DayPanelController` 的 10 秒兜底里加
  `PermissionPromptWatch.endAll()` —— 那一刻本来就不再等系统回应了。
- **超时也要立刻重算亮度**：解除保持时回调 `onStateChanged(false)` →
  `updateHover(force:)`，不用等下一次鼠标移动或 10 秒巡检。
- **顺手收严一处判定**：`topNumber == 自己的卡片窗口` 不再直接算「在卡片上」，
  改走「卡片矩形 + 迟滞」。窗口比卡片大 90pt（投影留白），
  这条分支之前会把整圈留白算成悬停。
- **迟滞从 14pt 收到 8pt**：卡片边缘外一点点就淡出，不再出现
  「明明已经移出卡片、课表还亮着」这种边界内的观感问题（迟滞只防抖，不需要这么大）。

### 自检 · Verification

- `make test`：全部通过（**1938 项断言**）。新增：
  - 兜底超时真的会销掉那一笔（0.05 秒保持 + 跑 RunLoop 验证定时器这条路）；
  - 超时解除时 `activeReasons` 清空、并通知一次「退出保持」。
- `--verify-hover` 新增「投影留白」用例：指针在卡片外、但在
  **课表窗口内**（窗口服务器会报「我们自己」）时，课表必须淡下去。
- `--verify-hover` / `--verify-day-panel` / `--verify-day-panel-click` /
  `--verify-pin-flow` / `--verify-settings-card` / `--verify-panel-sections`：通过。

### 版本 · Version

- 版本号 **1.2.7**（1.2.6 的补丁版）；**bundle id 不变**
  （`com.desktoptimetable.app.v120`）。
- 构建归档到 `版本迭代/DesktopTimetable-1.2.7.app`；
  `1.2.6` 归档保留为历史版本，根目录既有 `.app` 未覆盖。

## [1.2.6] - 2026-11-05

这一版修**「正在输入待办时，鼠标滑到别的列，正在输入的那一列就没了」**。

用户原话：「当修改某一列的待办事项和点击了添加待办事项之后，
要是鼠标不小心移动到别的列了之后，原本要输入的那一列还是会显示，
就是把它固定着，以免鼠标误滑动。」

根因：日期覆盖层是**跟随指针**的（点开一列之后，指针移到别的列就换列）。
换列会 `openPanel(day)` 重建整块内容 → 正在输入的 `<input>` 被销毁，
打了一半的标题 / 时间直接丢。之前只处理了「鼠标离开卡片」（`DP.adding` /
`DP.editingTodoKey` 时不收面板），**没处理「指针在卡片内换列」**。

### 修复 · Fixed

- **输入期间把面板锁在当前列**：`Resources/Timetable.js` 的 `onPointerMove`
  在 `DP.adding || DP.editingTodoKey` 时直接返回，不再按指针位置换列；
  `DP.hoverDay` 也钉在当前列，状态不会自相矛盾。
- 覆盖两种输入态：
  - 点了「＋ 添加待办」、输入框展开时；
  - 右键待办 →「修改…」进入卡片内编辑态时。
- **锁的是「移动」，不是「点击」**：点别的列表头仍然是主动换列
  （明确意图，会放弃正在输入的内容）；Esc / 回车提交后 `adding` / `editingTodoKey`
  归零，跟随立刻恢复。
- 指针滑出卡片时的「不收起」沿用 1.2.2 的行为，两者一起构成完整的输入保护。

### 自检 · Verification

- `--verify-day-panel` 新增 `4c-13d-2`：用真实 DOM 事件驱动 `onPointerMove`，
  分四步验：
  1）编辑态下指针移到第 2 列 → 面板仍停在第 3 列、编辑态没被重置、
  已经打进去的标题还是「原标题」；
  2）Esc 取消编辑后再移到第 2 列 → 这次必须**真的换到第 2 列**（证明确实解锁了）；
  3）添加态下指针移到第 6 列 → 面板仍停在第 3 列、输入框还在；
  4）Esc 取消添加后再移到第 6 列 → 必须换到第 6 列。
- `make test`：全部通过（**1934 项断言**；本轮只改网页层，断言数不变）。
- `--verify-day-panel` / `--verify-day-panel-click` / `--verify-hover` /
  `--verify-pin-flow` / `--verify-settings-card` / `--verify-panel-sections`：通过。

### 版本 · Version

- 版本号 **1.2.6**（1.2.5 的补丁版）；**bundle id 不变**
  （`com.desktoptimetable.app.v120`）。
- 构建归档到 `版本迭代/DesktopTimetable-1.2.6.app`；
  `1.2.5` 归档保留为历史版本，根目录既有 `.app` 未覆盖。

## [1.2.5] - 2026-11-05

这一版修**「点系统权限弹框的时候课表会淡掉 / 整个消失」**。

用户原话：「每一次弹出来天气的访问权和日历提醒事项的访问权的时候，
鼠标移动到那个访问权的窗口之上，课表就会淡出来。用户肯定是希望点访问权的时候，课表还在。」

根因不是判定错，而是**弹框期间的判定前提不成立**：

- 日历 / 提醒事项 / 定位 / 通知的授权框都是**系统进程**弹的窗口：
  层级比课表高（落在系统弹框那一档，远高于课表的 `-1`），位置常在屏幕中间；
- 用户把鼠标移过去点「允许 / 不允许」时，
  指针既离开了卡片矩形、那个点还被层级更高的弹框占着 → 两条件都指向「没悬停」；
- `minOpacity = 0` 时「淡出」等于**整张课表彻底消失**，用户点了权限就看不到课表了。

### 修复 · Fixed

- **新增 `Model/PermissionPromptWatch.swift`**：一个「系统权限弹框还开着」的记账器。
  弹框之前 `begin("定位")` / `begin("日历")` / `begin("提醒事项")` / `begin("通知")`，
  拿到授权回调之后 `end(...)`；按原因分别记账，**全部结束才解除**（日历 + 提醒事项
  是并行弹的，只回一个不能解除）。
- **弹框期间课表一律保持可见**：`AppDelegate.updateHover` 里在菜单宽限期之后
  再短路一次 `inside = true`，不受指针位置和层级遮挡影响。
- **立刻生效，不等鼠标**：`PermissionPromptWatch.onStateChanged` 接到
  `updateHover(force: true)`，弹框一出现 / 一关掉都马上重算亮度。
- **不会无限期亮着**：默认保持 120 秒（用户一直不点弹框也会自己解除；
  1.2.7 起收到 10 秒并加了逐项兜底超时）。
- 接入点：
  - `EventKitStore.requestReminderAccess` / `requestEventAccess`（日历 / 提醒事项）；
  - `OpenMeteoWeatherProvider.requestCurrentLocation` 的 `.notDetermined` 分支 +
    `didChangeAuthorization`（定位 / 天气）；
  - `ClassReminderScheduler.requestAuthorization`（通知）。

### 自检 · Verification

- `--verify-hover` 新增三段：
  1）弹框一出现、不喂任何假输入，课表必须**立刻亮着**（验 `onStateChanged` 接线）；
  2）弹框期间指针在弹框上（不在卡片里、还被更高层窗口占着）→ 必须保持可见；
  3）`end()` 之后恢复原判定（指针离开就淡下去）。
- 新增单测 `PermissionPromptWatch · 权限弹框期间不淡出`：并行两框只回一个不解除、
  超时自动解除、`endAll` 兜底、进入 / 退出各通知一次。
- `make test`：全部通过（**1934 项断言**）。
- `--verify-hover` / `--verify-day-panel` / `--verify-day-panel-click` /
  `--verify-pin-flow` / `--verify-settings-card` / `--verify-panel-sections`：通过。
- 所有自检跑在 `DT_DATA_DIR` 临时目录，**不触发真实 TCC 权限框**（fake store / 自动化模式）。

### 版本 · Version

- 版本号 **1.2.5**（1.2.4 的补丁版）；**bundle id 不变**
  （`com.desktoptimetable.app.v120`）。
- 构建归档到 `版本迭代/DesktopTimetable-1.2.5.app`；
  `1.2.4` 归档保留为历史版本，根目录既有 `.app` 未覆盖。

## [1.2.4] - 2026-11-05

这一版修**「点了 App，课表很久不出来；指针明明在课表上也不浮起来」**。
根因不是加载慢，而是「亮不亮」的判定把**桌面窗口**当成了遮挡：

- 课表窗口在**普通窗口之下、桌面窗口之上**（level `-1`）；
- 指针停在桌面上时，窗口服务器（`windowNumber(at:)`）给出的不是别人的窗口，
  而是**访达的桌面图标窗口 / 桌面窗口**，层级比课表**还低**；
- 旧判定是「不是我们的窗口 = 被别的 App 盖住」→ 桌面窗口也算 →
  课表永远停在 `minOpacity`（用户设的是 `0`，即完全透明），看起来就是「没出来」；
- 用户得「点好几下 + 等很久」才恢复。
- 实测补充（`DT_HOVER_DIAG=1`）：`windowNumber(at:)` 报回来的窗口随「课表当前是否
  可见」变 —— `alpha = 0` 时给的是**访达的桌面图标窗口**（层级 `-2147483603`，比课表低），
  `alpha = 0.22` 且指针压在别的 App 窗口上时给的是**那个 App 的窗口**（层级 `0`），
  `alpha = 1` 指针下面是课表时给的是**我们自己的窗口**（层级 `-1`）。
  旧判定把第一种也算成遮挡 → 课表永不亮；现在的层级判断三种情况都对。

### 修复 · Fixed

- **遮挡判定改成按层级比较**（新 `HoverCoverPolicy`）：
  只有**层级比课表高**的窗口才算遮挡；同层不算，更低更不算；
  查不到层级时也不当作遮挡（宁可亮着，也不要再「永远不亮」）。
- **课表层级只留一份**（`HoverCoverPolicy.cardWindowLevel` = `-1`）：
  `DesktopWindow` 的初始值和 `AppDelegate` 的最终设置都用它，
  避免「判定用一个数、窗口用另一个数」。
- **启动时先亮一下**：渐显前按当前指针位置重算一次 hover，先渐到 100%
  让用户明确看到课表出来了，0.9s 后再落回常态（移上去就实、没移就虚）。
- **每 10 秒重算一次 hover**：鼠标不动时收不到 `mouseMoved`，
  别的窗口移开 / 关掉后状态原本永远不刷新 —— 现在会自己纠正。
- 删掉上一轮遗留的 `[TT-ALPHA]` 诊断日志（每 0.3s 打一行，只在定位问题时用）；
  换成按需开启的 `DT_HOVER_DIAG=1`（打印指针 / 窗口号 / 层级 / 遮挡 / inside / alpha）。

### 自检 · Verification

- 新增 `--verify-hover`：把「指针位置 / 窗口服务器的答案」喂进真实的
  `updateHover`（层级比较 → `inside` → `hovering` 全走生产代码），覆盖
  1）窗口服务器报桌面图标窗口 / 桌面窗口 → 课表必须亮（旧代码在这里挂）；
  2）报出更高层窗口（安全网）→ 必须淡下去；3）指针在卡片上必须亮；
  4）被盖住后回到卡片必须能亮回来；5）指针离开必须淡下去；
  6）真机窗口列表里确实存在比课表低的窗口。
- 真机 `DT_HOVER_DIAG=1` 实测记录：`alpha=0` → `top=34451`（访达桌面图标窗口，
  层级 `-2147483603`）→ `covered=0 inside=1 hovering=1`；`alpha=1` →
  `top=40325`（自己，层级 `-1`）。修复前的判定在这两种情况下都会 `covered=1`。
- `make test`：全部通过（**1924 项断言**，新增 `HoverCoverPolicy · 遮挡判定`）。
- `--verify-hover` / `--verify-day-panel` / `--verify-day-panel-click` /
  `--verify-pin-flow` / `--verify-settings-card` / `--verify-panel-sections`：通过。
- 所有自检都跑在 `DT_DATA_DIR` 临时目录，未碰真实课表 / 设置 / 通知。

### 版本 · Version

- 版本号 **1.2.4**（1.2.3 的补丁版）；**bundle id 不变**
  （`com.desktoptimetable.app.v120`）。
- 构建归档到 `版本迭代/DesktopTimetable-1.2.4.app`；
  `1.2.3` 归档保留为历史版本，根目录既有 `.app` 未覆盖。

## [1.2.3] - 2026-11-05

这一版修一个 1.2.2 的交互问题：**「已完成的提醒事项」展开后，再点这一行收不回去**
（只能张开不能收缩）。「全部删除…」本身正常，回归里也补了它的真实点击。

### 修复 · Fixed

- **展开后点标题行收不起来**：
  - 根因：`HeaderButton.hitTest(_:)` 收到的 point 是**父视图坐标系**，
    代码却直接拿它和 `bounds` 比。收起时 header 在行内 y=0，碰巧能点中；
    展开后行变高、header 移到 y=334（非翻转坐标系），
    命中测试判定「点在按钮外」→ 点击落到整行、按钮收不到 action。
  - 修法：先把 point 从父视图坐标转换到本地，再判断 `bounds`；
    整行（标题 / 副标题 / chevron）仍然都能点。
  - 同样修了「提醒事项清单」行（`DayPanelListRow`）里同款的坐标系错误。
- **补真实点击回归**（不是直接调 action）：
  - 点标题行 → 收起；
  - 再点标题行 → 重新展开；
  - 点「全部删除…」→ 确认流程真的被触发。
  自检里会打印命中视图，点不中时能直接看到命中了谁。

### 自检 · Verification

- `make test`：全部通过（1906 项断言）。
- `--verify-completed-reminders`：通过（含上述 3 个真实点击）。
- `--verify-panel-sections` / `--verify-settings-card` / `--verify-day-panel` /
  `--verify-day-panel-click` / `--verify-wheel-routing` / `--verify-typing`：通过。

### 版本 · Version

- 版本号 **1.2.3**（1.2.2 的补丁版）；**bundle id 不变**
  （`com.desktoptimetable.app.v120`）。
- 构建归档到 `版本迭代/DesktopTimetable-1.2.3.app`；
  `1.2.2` 归档保留为历史版本（含该交互问题），根目录现有 `.app` 未覆盖。

## [1.2.2] - 2026-11-05

这一版把「已完成」从隐藏数据变成了可管理的列表：
设置 → 提醒 →「日期覆盖层」卡片里新增第三行「已完成的提醒事项」，
可以查看全部清单里的已完成项、按标题搜索、按清单筛选、恢复为未完成、
删除单条，或一次性删除所有清单里的已完成项。

### 已完成的提醒事项（日期覆盖层卡片第三行）

#### 新增 · Added

- **「日期覆盖层」卡片新增第三行「已完成的提醒事项」**，顺序固定在
  「提醒事项清单」和「显示天气」之间：
  - 默认**收起**，右边是 chevron，**不显示数量、不读取 EventKit**；
  - 副标题：「查看、恢复或删除已完成的提醒事项」。
- **点击这一行 → 就在卡片内部就地展开**（不新开窗口、不跳独立页）：
  行标题不变，chevron 变向上；列表出现在这一行下方；再点一次收起，
  并作废尚未完成的异步读取（迟到回包直接丢弃，不写 UI）。
- **展开后卡片变高，由设置页现有滚动容器负责滚动**，不改设置窗口尺寸。
- **列表**：
  - 跨**所有提醒事项清单**读取已完成项，每一行都显示所属清单名；
  - 按完成时间倒序（最近完成的在前，没有完成时间的排最后）；
  - 按标题搜索（大小写不敏感）+ 按清单筛选（所有清单 / 单个清单）；
  - 列表最高 260pt，超出后**内部滚动**，不把设置页顶长；
  - 首屏最多 200 条，底部「加载更多」每次追加 200 条；
  - 查询与渲染都异步：EventKit 读取异步，列表每批 25 行追加渲染，
    数据量大时不阻塞主线程；
  - 空状态「没有已完成的提醒事项」（筛选无结果时「没有匹配的已完成提醒事项」）；
  - 加载中「正在读取…」；读取失败显示原因 +「重试」，**不拿空状态冒充成功**。
- **每条已完成项**显示：标题、所属清单、完成时间（`yyyy-MM-dd HH:mm`）、
  到期时间（没有时显示「无到期时间」）。
- **恢复**：把提醒事项改回未完成（`isCompleted = false`、清空
  `completionDate`，**到期时间保持原样**）。
  - 成功后从列表消失；
  - 如果到期日就是日期面板正打开的那一天，面板会重新出现这条待办；
  - 表头红点重新计算；面板没打开时也会更新红点；
  - 复用 `refreshAll` / `loadContent(resetImmediately: false)` / `dayPanelRevision`，
    **不整块清空重建**，不闪「读取中…」。
- **删除单条**：弹一次轻量确认（标题带待办名），确认后永久删除；
  成功后从列表移除，日期面板同步刷新。
- **写回失败**：不先从列表移除，在界面上显示失败原因；条目还在，
  可以再点一次重试。
- **重复提醒（`hasRecurrenceRules`）第一版禁用「恢复」**，只允许删除，
  按钮旁直接写「重复提醒不支持恢复」并带完整原因 tooltip ——
  不静默恢复（避免和系统已生成的下一次实例冲突）。
- **「全部删除…」**：
  - 范围是**所有清单**的所有已完成项，不受当前搜索 / 筛选影响；
  - 列表为空时隐藏按钮；
  - 二次确认：标题「删除全部已完成事项？」，正文写明**重新统计后**的数量，
    默认按钮是「取消」，破坏性按钮「全部删除」红色；
  - 数量 ≥50 条时还要求输入「删除」两个字才能提交；
  - 批量删除逐条 `remove(commit: false)`，最后**统一 `commit()` 一次**；
  - 删除过程中显示进度并禁用按钮，防止连点；
  - 完成后清空已删项并显示「已删除 N 条」；部分失败如实报
    「已删除 X 条，Y 条失败」，**不报「全部成功」**。
- **接入关闭 / 未授权**：这一行仍显示但置灰、不可展开，副标题
  「开启接入并获得提醒事项权限后可查看」；未授权时副标题带「未授权」
  并给一个小号「去系统设置」按钮，**点击不会弹系统权限框**。

#### 数据层 · Data

- `EventKitStoreProtocol` / `EventKitStore` 新增：
  - `completedReminders`：用 EventKit 的 **completionDate 谓词**
    （`predicateForCompletedReminders(withCompletionDateStarting:ending:calendars:)`）
    读取所有清单的已完成项，**不把全部提醒事项拉回来再过滤**；
    字段含 identifier / title / listIdentifier / listTitle / completionDate /
    dueDate / isRecurring；
  - `restoreReminder`：恢复为未完成；
  - `deleteCompletedReminder`：删除单条；
  - `deleteAllCompletedReminders`：批量删除，返回成功 / 失败数量与被删 id。
- **不新增任何 TCC 权限类型**，沿用现有日历 / 提醒事项 FullAccess。
- 批量删除 `commit()` 失败时会 `EKEventStore.reset()` 丢弃挂起的删除，
  避免下一次写入意外把它们一起提交。
- 自动化模式继续注入 `FakeEventKitStore` / `EmptyEventKitStore`，
  绝不请求真实 TCC、绝不碰用户真实提醒事项。

#### 修复 · Fixed

- **「显示天气」行没有底边约束，高度被算成 0pt**：作为卡片最后一行时
  状态文字和开关画到卡片外面（新加的第三行让这个问题暴露出来）。
  现在把状态行底边钉住，天气行有真实高度。
- 日期面板的「刚完成 / 刚删除」事实表会挡住恢复后的条目：恢复成功时
  一并清掉 `recentlyCompleted` / `recentlyDeleted`，删除成功时写入
  `recentlyDeleted`，避免 EventKit 旧快照让条目「复活」一下。

#### 自检 · Verification

- 新增 `--verify-completed-reminders`（已登记到
  `AutomationMode.automationFlags`）：收起不读取、跨清单 + 清单名、
  搜索 / 筛选、恢复后列表少一条且日期面板重新出现 + 红点更新、
  单条删除、全部删除只删已完成项、部分失败数量如实、commit 失败不报成功、
  重复提醒禁用恢复、接入关闭 / 未授权禁用、收起取消在途读取、
  首屏 200 条 + 加载更多 + 内部滚动；全部使用 `FakeEventKitStore`。
- `Tests/main.swift` 新增纯逻辑单测：查询 / 排序 / 清单汇总、
  时间文案、全部删除确认策略（≥50 输入「删除」）、批量结果文案。
- `--shot-settings` 新增 `completed-collapsed` / `completed` / `empty` /
  `delete-all`（`typed` 为 ≥50 条输入态）出图参数；截图统一按深色外观渲染。
- `make test`：全部通过（1906 项断言）。

#### 版本 · Version

- 版本号 **1.2.2**（1.2.1 的补丁版）；**bundle id 不变**
  （`com.desktoptimetable.app.v120`），日历 / 提醒事项 / 定位授权、
  登录项和通知身份全部延续。
- 构建归档到 `版本迭代/DesktopTimetable-1.2.2.app`；根目录现有
  `.app` 未覆盖。

## [1.2.1] - 2026-11-04

这一版把日期覆盖层里的**待办**补齐了：右键不再直接删除，改成弹菜单
（修改… / 删除 / 取消）；「修改…」在待办卡片里就地把标题和到期时间改掉；
添加待办也能填到期时间了。

### 待办右键菜单 + 卡片内修改

#### 新增 · Added

- **右键待办弹原生菜单**：菜单是系统 `NSMenu`，三项 ——
  **修改… / 删除 / 取消**，和课程右键菜单同一套弹法。
  - ⚠️ 为什么用原生菜单而不是网页里画：日期面板会滚动、有裁剪和渐隐，
    网页菜单很容易被裁掉；原生菜单还能自然处理「点空白关闭 / Esc 关闭」。
  - **右键不再直接删除** —— 只有在菜单里点「删除」才会删。
- **「修改…」在待办卡片里就地编辑**（不新开窗口）：
  - 标题 + 到期时间（时 / 分两个小框），
  - **自动聚焦标题**，**回车保存**、**Esc 取消**，
  - 标题为空不允许保存；时间必须是 `00:00–23:59`，非法时就地提示、不提交；
  - 原生推状态导致面板重绘时，**复用同一个输入元素**，不打断正在输入的内容
    （沿用「添加待办」输入框的复用方式）。
- **添加待办能填到期时间**：输入区改成两行 ——
  `[ 待办内容 ]` / `[ 时 ] : [ 分 ]  [取消]`。
  - ⚠️ 右下角那个按钮是「**取消**」，不是「添加」：
    填好内容时它该说的是「放弃这次输入」；添加态以前**根本没有取消按钮**
    （填错了想反悔只能按 Esc，很多人不知道）。
  - 「取消」= 关掉表单 + **清空**已填的标题 / 时间（和 Esc 一致）；
    提交靠**回车**（标题框、时间框里回车都能提交）。
  - 编辑态那边是「保存 / 取消」，两个表单的按钮语义统一了。
  - 时间留空 = 当天 `00:00`（和以前的默认行为一致）；
  - 只收数字，失焦自动补零（`9` → `09`），时填满两位自动跳到分；
  - 窄列（约 119pt）下也是两行，不挤成一行。

#### 调整 · Changed

- **删除待办走菜单**：菜单选择即确认，**不再弹二次确认框**；
  沿用现有的淡出动画（和「点圆圈完成」同一套）。
- **到期时间 00:00 就显示「00:00」**，不显示成「全天」。
- **修改后的标题 / 时间写回系统「提醒事项」**；完成状态、清单归属都不变。
- 日历日程（系统日历里的事件）**不提供**修改 / 删除 —— 只处理提醒事项。
- 非当天的列（翻周后点开的那一天）同样支持这些操作。

#### 修复 · Fixed

- **点「删除 / 修改」时整个日历闪一下，严重时看着像「课表莫名消失了」**：
  这是**两条独立的链**，真机截图确认过：
  - **链一（覆盖层被收走）**：右键菜单是用一个临时的 `NSPanel`
    （level .floating）当宿主的 —— 菜单一弹出**指针就离开卡片**，
    原生于是判定「指针离开了课表」，网页把日期覆盖层收走了。
    修法：原生在弹菜单前通知网页「菜单开着」，菜单关闭后自动恢复；
    这期间覆盖层**不收、也不跟指针换列**。
  - **链二（课表卡片自己淡出 —— 这才是「闪一下」的主因）**：
    日期覆盖层在课表的**最后一列**（最靠右），菜单**往右弹**会伸出
    卡片右边缘约 60pt。菜单一关，宿主面板消失 → 指针停在**卡片矩形之外**
    → 原生判定「指针离开了课表」→ **整个课表 6 秒淡到 22%**
    （深色玻璃 + 深色壁纸 = 看着像没了）。
    修法三道一起上：
    1. 菜单**往左弹**（落在卡片内；用户点菜单项时鼠标必然移到指针左侧，
       也就是卡片内）；
    2. 菜单**开着**时宿主面板是本 App 的窗口 → 课表不淡出；
    3. 菜单关掉后给 **3 秒宽限期**：这段时间里不因「指针在卡片外」而淡出
       （兜住「开菜单后按 Esc、鼠标没动」这种路径）。
  - 课程右键菜单从 1.0.x 起就有同样的机制，但课表卡片本身不响应
    「指针离开」，所以看不出来 —— 只有日期覆盖层会跟着收走。
- **在表头往下滑，日历面板会「突然出现 → 消失 → 渐渐出现」**：
  用户实测：「点击了日历，移到了日历上方，日历收进去了，
  然后从顶上往下滑到日历头部」——「他应该是要显示，但不是要这么闪一下」。
  - **原因一**：指针移到**表头上方**（顶栏 / 状态条那一带）时，
    `dayAtPoint()` 返回 null → 面板被收走 —— 可那个位置**还在课表卡片里**。
    现在：横向落在当前那一列的范围里就算「还是这一列」，面板不动。
  - **原因二（真正的「闪一下」）**：收起动画只摘了 `.closing`，**`.show`
    还留在元素上** → 再次打开时 `wasShown` 一直为 true →
    「重新加 `.show`、刷新 `DP.openedAt`」那一段被整个跳过 →
    **揭开动画根本没重新开始**，clip-path 卡在裁掉的状态；
    兜底定时器（`openedAt` 还是旧值）于是判定「动画没跑」→
    加上 `.dpnoplay`（= 全露）→ **面板瞬间整个出现**（「突然出现」），
    之后兜底类被摘掉 → 揭开动画重播 → **「渐渐出现」**。
    - 现在：收走过之后重新打开会**重新播一遍入场动画**；
    - 兜底定时器**每次打开都取消上一次**（它从来没被取消过，
      上一次留下的那一个会把正在播的动画打断）。
- **点「修改…」后面板先消失、之后又出现而且内容不对**：
  菜单期间覆盖层被收走（`DP.open` 已是 false）→ 选「修改…」时
  编辑入口**静默失败**；鼠标移回又按指针位置**开错列**。
  现在菜单开着时记住原来那一列，选「修改…」会把那一列带回来并进入编辑态。
- **写回成功后晚到的旧快照会把界面改回去**：
  EventKit 的 `save` 成功 ≠ 紧接着的取数就是新数据。
  现在以「写回结果」为事实，在取数追上之前用新值盖住旧快照
  （和「刚完成 / 刚删除」那两张事实表同一套机制），30 秒兜底。
- **修改失败会静默**：现在网页会回滚乐观改掉的值，并把失败原因显示出来。

#### 版本 · Version

- 版本号 `1.2.0` → **`1.2.1`**；**bundle id 不变**
  （仍是 `com.desktoptimetable.app.v120`）—— 这是补丁版，
  日历 / 提醒事项授权、登录项、通知身份全部延续，不用重新登记。
- 构建归档为 `版本迭代/DesktopTimetable-1.2.1.app`；1.2.0 的构建继续保留。

#### 测试 · Tests

- `make test` **1860** 项断言全部通过（新增「待办时间解析」一组）。
- `--verify-day-panel` 新增：添加态右下角是「取消」（点了不提交、关掉表单、
  清空已填内容）；待办右键只发 `todoMenu`（不直接删）、
  编辑态预填 / 自动聚焦 / 空标题与非法时间不提交、取消后原内容不变、
  保存后乐观显示并发出 `todoUpdate`、添加态两行不溢出、
  留空时间 = `00:00`、非法时间不提交；以及原生侧
  「写回参数正确 + 写后读旧快照不回滚 + 非当天列也能改」。
- `--verify-day-panel-click` 新增：原生菜单三项、选「修改…」进编辑态并预填、
  选「删除」才发 `todoDelete`；以及「弹菜单前通知网页、菜单关闭后恢复」
  这一对通知必须成对出现。
- `--verify-day-panel` 新增：指针移到**表头上方**（还在课表里）时面板**不该被收走**；
  收走之后再打开必须**重新播入场动画**（不能带上兜底类 → 那就是「突然出现」）；
  菜单开着时覆盖层**不能被收走、也不能跟指针换列**；
  面板已被收走时选「修改…」仍要能进入编辑态并回到原来那一列；
  菜单开着 / 关掉的标志要成对切换。
- `--verify-day-panel-click` 新增：**菜单开着时课表必须保持亮着**（主修复）；
  菜单**不能伸出卡片右边缘**；菜单关掉后要有一段不淡出课表的宽限期。
- 出图核对：`--shot-day-panel <out> todoedit` 给出「添加态 / 编辑态」两张
  真实 WKWebView 截图。
- 空闲 CPU 实测：主进程 ≈0.0%、WebContent ≈0.3%，与 1.2.0 持平
  （这次没有新增任何无限动画）。

## [1.2.0] - 2026-11-04

这一版给课表加了**日期覆盖层**：点表头的某一天，就在那一列展开一个面板，
显示当天的课程、系统提醒事项（可直接勾选 / 添加 / 删除）、系统日历日程，
以及农历、节气、节日、天气和宜忌。同时修掉了表头闪烁、周几与日期没对齐、
系统提醒事项改完课表面板不更新等几处问题。

完整需求、实现与验证摘要见
[`docs/archive/2026-11-04-1.2.0-对话存档.md`](docs/archive/2026-11-04-1.2.0-对话存档.md)。

### 日期覆盖层

#### 新增 · Added

- **点表头日期打开覆盖层**：面板只覆盖**那一列**（表头不被遮住），
  顶部实心、尾部渐变淡出；点开后进入跟随模式 —— 鼠标移到哪一列，
  面板就跟到哪一列；**再点同一列的日期**关闭并退出跟随模式；
  拖动课表时强制收起。
- **表头标记**：蓝点 = 今天，红点 = 当天有待办，橙点 = 当天有日历日程
  （红 / 橙可同时出现）；正在查看的那一列有蓝色渐变 + 外发光高亮。
- **逐条玻璃卡片**：每条待办、每条日程、今日详情各自一张卡，
  「＋ 添加待办」是虚线幽灵卡；没数据时显示「今日无待办 / 今日无日程」。
  内容装不下时**在面板内滚动**，不截断条目、不显示「还有 N 条」。
- **待办可写**：单击圆圈标记完成、右键删除、点「添加待办」展开内联输入框；
  写回系统「提醒事项」App，目标清单可在设置里选（默认新建「桌面课表」）。
- **日历日程**：读取当天的系统日历事件（起止时间）。
- **今日详情**：农历、节气、节日；**天气**（系统定位 + Open-Meteo，
  设置里默认关）；**宜 / 忌**（按建除十二神的离线简化黄历，只作氛围提示，
  不是权威择日依据）。拿不到任何一项就隐藏对应行，**绝不显示假数据**。
- **设置面板「日期覆盖层」卡片**：日历与提醒事项接入开关（默认**关**）、
  提醒事项清单选择、显示天气开关（默认**关**）。没开接入时覆盖层只显示当天课程。
- **网页输入框可用**：输入框聚焦时原生把窗口**临时**变成 key window，
  失焦 / 回车 / Esc 还原 —— 桌面层窗口平时不能成为 key，否则网页里打不了字。

#### 调整 · Changed

- **只保留一列宽这一种形态**：原来的「双击撑开」宽态已删 ——
  它会盖住旁边的列、底边硬切过课程格，而卡片化 + 面板内滚动之后也没多显示什么。
- **动画**：打开 600ms `clip-path` 自上而下揭开，收起 400ms 收拢；
  覆盖层元素跨 `render()` **复用**，换列 / 原生推状态都不重播入场动画。

#### 修复 · Fixed

- **先闪「今日无待办」再跳成真实内容**：数据没查完时显示「读取中…」，
  不再先给一个错误结论。
- **添加待办失败完全静默**：现在会把失败原因显示在面板里。
- **鼠标快速移进卡片时点不动**：窗口的 `ignoresMouseEvents` 改为
  **每次按当前指针位置重算**，不再只在状态变化时更新（那一下会穿透到桌面）。
- **「添加待办」的输入竖线一直闪**：原生每推一次状态就重绘面板，
  输入框以前每次新建，焦点和输入内容全丢；现在跨重绘复用同一个输入元素，
  保留焦点、光标与选区。
- **连续点「添加待办」会卡住权限框**：同一个 app 的 TCC 框不能连着弹，
  第二个请求往往一直不回调；现在权限请求加锁，只发第一轮。
- **勾完 / 删完的待办又「复活」**：EventKit 写回成功后的第一次取数可能是旧快照，
  现在以「写回成功」为事实，在取数追上之前过滤掉该条（30 秒兜底）。
- **翻周时红点 / 内容串到上一周**：异步取数晚到的旧结果会覆盖新周；
  `refreshAll` / `loadContent` 都加令牌，只接受最新一轮。
- **在系统「提醒事项」里勾完，红点没了但课表面板里条目还在**：
  面板关着时原生只重算标记、网页按天缓存却留着旧列表。
  新增 `dayPanelRevision` 版本号，外部数据一变就作废网页缓存并重新取数。
- **课表右上角的时钟 / 状态条停在半小时前**：它们原来只在整树重绘时计算；
  原生每分钟推一次状态，但数据没变时走轻量路径、不重画顶部，
  于是时间冻在上一次真正重绘的时刻（翻周 / 改设置才跳一下）。
  现在网页自己每 10 秒**就地刷新**时钟、日期和状态条
  （「正在上课 / 下一节」也按时切换），跨天时自动重绘表头以移动「今天」标记。
- **表头「一暗一亮」闪烁**（点击日期 / 点完成时）：原生推送的 JSON 数据没变，
  但 Swift `JSONSerialization` 的键顺序每次不同，网页用 `JSON.stringify`
  算指纹就误判成「数据变了」→ 整棵树重建 → `.sel` 落到新节点上、200ms 颜色过渡重播。
  改成**键序无关**的稳定指纹，表头节点跨推送复用。
- **周几文字和日期数字没对齐**：蓝点原先只在「今天」那一列渲染，
  左右两个点的间距也不对称，导致各列文字中心偏移。现在两个点都保留占位
  （不显示时只 `visibility: hidden`），间距统一 3px。
- **日期覆盖层收不回去 / 瀑布渐隐有接缝 / 输入的竖线闪** 等实现细节一并修复，
  详见归档文档。

#### 性能 · Performance

- **空闲耗电**：状态条上的呼吸圈原来是一条无限的 `box-shadow` 动画，
  它会让 WebKit **每帧**重绘整张卡片、重新提交 layer tree —— 实测空闲时
  WebContent ≈10%、主进程 ≈5%（占一个 CPU 核心的比例）。现在拆成两个伪元素：
  `::before` 负责放大 + 淡出的圆盘，`::after` 是圆点本身；动画只改
  `transform` / `opacity`，交给合成器插值，外观不变。实测空闲降到
  WebContent ≈0.15%、主进程 ≈0.6%。
- **指针悬停同步**：指针在卡片外移动时，原生不再每帧向网页发
  `evaluateJavaScript` 去清悬停态（加去重，只有上次确实同步过才发一次）。

#### 版本 · Version

- 版本号 `1.1.5` → **`1.2.0`**，按小版本惯例换 bundle id：
  `com.desktoptimetable.app.v110` → **`com.desktoptimetable.app.v120`**，
  可以和 1.1.5 并存。数据目录不变（`~/Library/Application Support/DesktopTimetable`），
  课表数据互通。
- 换 bundle id 后，日历 / 提醒事项 / 定位授权、登录项和通知身份要重新登记一次
  （本来就因为是 ad-hoc 签名，每次重建都需要重新授权）。
- 构建归档为 `版本迭代/DesktopTimetable-1.2.0.app`；`1.1.x` 系列的构建继续保留。

#### 测试 · Tests

- `make test` **1839** 项断言全部通过。
- `--verify-day-panel`：农历 / 锚点 / 状态机 / EventKit / 自动化护栏，
  全程 fake store，不触发真实系统权限框。
- `--verify-day-panel-click`：真实 WKWebView 点击（添加待办 / 圆圈完成），
  并回归检查原生推送不能重建表头节点、周几与日期中心对齐、
  系统数据变化后确实向网页重发 `datePanelOpen`。
- `--verify-web-render` 新增时钟检查：把时钟文字改成 `00:00`，
  调一次网页自己的就地刷新，必须对回当前时间；并确认定时器已装上。
- `--verify-web-render` 另加呼吸圈省电回归：动画必须挂在伪元素上、尺寸 21×21、
  `.pulse` 本身没有 `box-shadow`，防止以后又改回逐帧重绘。
- 所有自检都用 `DT_DATA_DIR` 指向临时目录，不碰真实课表。

## [1.1.5] - 2026-11-01

这一版把桌面课表从「固定位置 + 一条长设置列表」变成可以随手摆、按板块找设置，
并且每节课的钟点也能自己改。累积三块改动：

- **课表图钉**：拖动 / 固定桌面课表，后续窗口跟着课表当前中心走；
- **设置面板两级结构**：板块首页 → 分类设置页；
- **课程时间自定义**：课表板块新增内置滚动列表，10 节课的起止时间可改；
  时间输入拆成「时 / 分」两个框，数字在框内垂直居中。

完整需求、实现与验证摘要见
[`docs/archive/2026-11-01-1.1.5-对话存档.md`](docs/archive/2026-11-01-1.1.5-对话存档.md)。

### 课表图钉固定 + 弹窗跟着课表走

桌面课表以前是「钉死在固定位置」的，而且所有弹窗一律居中到**屏幕正中**。
现在课表左上角多了一个大头针：可以拖着课表到处跑，拖完把它固定住；
之后弹出的所有窗口都以**课表当前中心**为锚点出现。

#### 新增 · Added

- **图钉按钮**：课表卡片**左上角**（和「我的课表」标题同一行）一个大头针，
  两种状态一眼可分：
  - **空心轮廓（白色）** = 未固定 —— 课表可以拖动；
  - **实心（黑色）** = 已固定 —— 位置锁住，拖不动（图钉本身仍可点）。

  图标是两张独立资源图（`Resources/pushpin-outline.png` / `pushpin-solid.png`），
  都当 **template image** 用，染色后随系统深浅色自适应。
  刻意做成**两张形状不同的图**而不是同一张染两种色 ——
  只有染色的图标缩到 17pt 时看不出固定没固定。
  网页那边给顶栏留了一条 30px 的左槽（`Timetable.css` 的 `.top`），
  原生卡片用 `TimetableLayout.topBarPinGutter` 算同样的偏移，两边对得上，
  图钉不会压住标题文字。
- **拖动课表**：`CardInteractionView` 盖在画面之上，负责拖动与图钉；
  **没拖动的点击会原样转交回画面层**，所以点课程、点齿轮、翻周次全都照旧生效。
- **位置记忆**：图钉状态 + 窗口位置写在 `window_state.json`（单独一个文件，
  和 `settings.json` 互不覆盖），**重启 App 后原样恢复**；首次启动用默认位置。
- **弹窗以课表为锚点**（`WindowAnchor`）：设置面板及其收起 / 展开态、
  课程编辑器、确认 / 提示对话框、导入相关窗口……**全部**以课表当前中心为准，
  不再一律居中到屏幕正中。多显示器时以**课表所在的那块屏**为准；
  超出可见区的窗口会被夹回屏幕内。
- **自检**：`--verify-pin-flow` 覆盖拖动、固定、位置记忆、弹窗锚点整条链路；
  `--render-pin` 出图钉两态对照图。

#### 修复 · Fixed

- **拖动和鼠标不同步**（用户实测反馈）：算「鼠标屏幕坐标」时用了**当前**窗口原点，
  而窗口在拖动过程中自己也在动 —— 每来一个拖动事件，窗口已经移动的距离就被
  **再算一遍**，位移越滚越大（鼠标只挪 120pt、窗口却跑了 212pt）。
  两处一起改：交互层记住**拖动开始时**的窗口原点做基准换算；
  并且回调报的是**绝对目标原点**而不是增量（增量加到「当前原点」上会重复计算）。
- **拖动时课表能整个跑出屏幕**：夹回时夹的是**窗口框**，而窗口框四周留了
  90pt 投影留白、比屏幕还高 —— 课表永远会被顶到屏幕上沿，「完整可见」也做不到。
  改成夹**卡片**（用户真正看到的那一块）：卡片至少完整落在可见区里。
- **图钉和标题挤在一起**：图钉原先压住了标题文字。
  网页顶栏让出 30px 左槽、原生卡片用同一个常量，图钉和「我的课表」平行对齐。

### 设置窗口改成「板块首页 → 分类设置页」两级结构

设置面板不再是一条要滚到底的长列表：打开时是个小长条，只放四个板块按钮；
点一个板块，窗口原地平滑扩张成那个板块的设置页；点「返回」再收缩回长条。

#### 新增 · Added

- **板块首页（收起态）**：打开设置时窗口是 580×132 的小长条，
  居中在**鼠标所在那块屏的正中间**（不是贴着鼠标）。
  长条里只有四个板块按钮：**外观 / 课表 / 提醒 / 系统**，
  一个具体设置项都不显示。
- **板块按钮的图标是纯色 SF Symbols**（`paintbrush` / `calendar` / `bell` / `gearshape`），
  `isTemplate = true` + 统一 tint 染成浅灰白 ——
  **不用 emoji、不用彩色资源**（彩色图标和深色毛玻璃打架）。
  沿用面板既有的 `NSVisualEffectView(.hudWindow, .behindWindow)` 毛玻璃、
  圆角、无硬边框，和桌面卡片是同一个调子。
- **分类设置页（展开态）**：点板块后窗口原地扩张成 580×700，
  顶部是「‹ 返回 + 板块名」，下面就是该板块原来的卡片（控件一个没改）。
  内容比屏幕高时**页面内部滚动**，窗口本身不会伸出屏幕可用区。
- **加新功能的路子**：加一个 `SettingsSection` case → 首页自动多一个按钮 →
  把卡片挂到对应板块的栈上。卡片控件和业务逻辑一行不用动。

#### 改动 · Changed

- **板块内容映射**（只搬家，控件逻辑、默认值、写盘逻辑全没动）：
  - 外观：渐变动画、最终不透明度、设置面板
  - 课表：当前课表选择/预览/应用、课表、学期、课表数据、课程预览
  - 提醒：提醒与启动（开机自启、上课提醒、提前分钟、通知权限）
  - 系统：退出应用
- **动画**：扩张 / 收缩都是 0.28s 的 ease-out，
  **以屏幕中心为锚点对称进行**（实测逐帧采样：窗口中心全程不动，偏差 ≤ 1pt）。
  内容切换用交叉淡化，避免布局跳变和闪烁。
- **每次打开都回到收起态** —— 关掉再开是首页，不记住上次停在哪个板块。

#### 修复 · Fixed

- **点板块按钮「没反应」**（用户实测反馈）：首页的板块按钮用 `NSStackView` 排列，
  而 `NSStackView` 会在 arrangedSubview 底下垫一层「看不见但存在」的背景 ——
  **命中测试时它先接住点击**，于是点砖块其实是点在 stack 上，
  按钮的 action 根本不触发。表现就是「按钮看得见、点了没反应」。
  - 修法：横排栈换成 `NonHitStackView`（只把命中**转发**给子视图，不自己接）；
  - 图标 / 文字换成不参与命中测试的视图（`NonHitImageView` / `NonHitText`）——
    不然命中会停在图片或文字上，砖块照样收不到；
  - 首页视图自己也要有尺寸：frame 为 0 时 `bounds.contains` 恒为 false，
    命中测试会整个失败（点哪儿都点不到）。
  - 新增 `--verify-panel-click` 自检：**派发真实的鼠标事件**（走系统的命中测试）
    点四个板块按钮，验它们都能展开。
    （AXPress 验不了这个 —— 它直接调 action，绕过了命中测试。）
- **首页的标题压到砖块上**：「课表设置」那行字和板块砖**垂直居中**撞在一起。
  现在标题上移、砖块固定在标题下方，收起态高度 132 → 152。
- **多屏时展开可能跳屏**：扩张动画原先按「鼠标所在的屏」算目标位置，
  动画期间鼠标一旦移到另一块屏上，面板就会**瞬移过去**。
  现在按「面板自己所在的那块屏」算 —— 打开时选好屏，之后不再变。

#### 调整 · Changed

- **板块按钮改成「图标在上、名称在下」的方块**：每块 128×84 的半透明圆角砖，
  大号单色 SF Symbol（22pt）+ 名称，四个板块等宽铺满一排。
  砖块整体都是点击区（不是只有图标那一小块），鼠标移上去会高亮。
  收起态窗口相应加高到 152。
- **「返回」挪到红绿灯正下方，和板块名同一条水平线**：
  红绿灯（y≈13…32）/「‹ 返回」+ 板块名（y≈38…60）从上到下连成一片，
  不再是「返回」和板块名并排、跟标题带脱节的样子。
- **窗口高度按内容自适应**：展开时先量当前板块的卡片总高，
  少就变小（系统板块只有「退出应用」一张卡 → 215 高），
  多就最多 580×700（课表板块），超出的部分**在页面内部滚动**，
  不把窗口撑得更高。宽度不变（还是 580）。
- **顶部标题带和内容区接上了**：内容区的上边距跟着标题带的高度走，
  第一张卡片不再钻到标题底下去（看着像被裁掉一截）。

#### 修复 · Fixed（第二轮）

- **收缩时变成「一条黑线往下移」**（用户截图反馈）：
  `.titled` 窗口即使标题透明，macOS 26 仍会在标题栏那条带上画一条**水平分隔线**。
  窗口一缩放，那条线**留在原地不动**，看着就像一条黑线在往下跑。
  现在设 `titlebarSeparatorStyle = .none` —— 面板是自绘的毛玻璃 + 圆角，
  不需要系统那条线。去掉之后收缩就是**毛玻璃面板自己平滑地缩**。
- **收缩时红绿灯飘在窗口外面**（用户截图反馈）：
  macOS 的系统交通灯**不参与窗口的 frame 动画** ——
  `animator().setFrame()` 把窗口缩小了，它们却停在原地。
  去掉标题栏分隔线之后这个问题一并消失（交通灯重新跟着标题栏走）。

- **收缩动画中间态两套内容叠在一起**（用户截图反馈）：
  以前点「返回」是「一边交叉淡出分类页、一边收缩窗口」——
  `animator().alphaValue` 是**异步插值**，0.28s 的缩放跑完了淡出还没结束，
  中间态就变成「收起态的砖块 + 展开态的卡片」叠在一起，
  连红绿灯都被盖住了。
  现在**内容同步换**（瞬时切到收起态），只动画窗口尺寸 ——
  中间态就是一个正在变小的小长条，干净连贯。
- **内容一屏显示得下，右边却杵着根滚动条**（用户反馈）：
  滚动条改成**按需显示** —— 内容高度 <= 视口高度就藏起来。
  - 实现上不能直接改 `verticalScroller.isHidden`：NSScrollView 每次布局
    都会**自己**把滚动条显示回来 —— 改用 `AutoHideScrollView` 子类，
    在它布局**之后**再藏一次。
  - 判断「装不装得下」要用**当前可见板块**的内容高度 ——
    四个板块共用一个文档视图，它的高度是所有板块里最高的那个，
    用它判断的话「系统」板块明明装得下也会被算成「要滚动」。
  - 现在：外观 / 提醒 / 系统（装得下）→ 无滚动条；课表（超出）→ 有滚动条。

- **「返回」按钮跑到窗口外面**（用户反馈「返回键被裁掉」）：
  - `NSButton` 在 macOS 26 上内部是 SwiftUI 宿主视图（`_NSCoreHostingView`），
    自带一条高度几百点的内部约束；放进「四边钉死」的容器里会被撑变形。
    现在「返回」改成**自绘**按钮（`HeaderBackButton`），尺寸完全由我们说了算。
  - 另外 `addSubview` 会**重置** `translatesAutoresizingMaskIntoConstraints` ——
    必须在 `addSubview` **之后**再关一次，否则约束根本不生效
    （症状就是按钮被拉成半个窗口高）。
  - 自绘按钮补上辅助功能（`accessibilityRole = .button` + `accessibilityPerformPress`）——
    否则 VoiceOver 不念、自动化也按不动。
- **「返回」按钮被 `NSStackView` 抢走命中**：现在返回键和板块名各自直接挂在
  `root` 上（不能塞进同一个栈 —— 栈会重新设置父视图，约束就跨层级了）。



#### 测试 · Tests

- 新增 `--verify-panel-sections` 自检：收起态尺寸、四个板块按钮、图标是纯色、
  展开/收缩后仍然居中、窗口不超出屏幕、**板块内容映射正确**、
  **卡片一张都没丢（9 张）**、反复切换尺寸不漂移。
- 新增 `--verify-panel-animation` 自检：逐帧采样窗口 frame，
  验尺寸是连续插值的（没有跳变）且**中心全程不动**。
- 新增纯函数断言：`SettingsSection`（板块定义 / 图标名合法 / 不重复）、
  `SettingsHomeScreen`（4 个按钮 / 图标是 template / 统一 tint）、
  `HUDWindow.centeredOrigin`（居中算法，含**第二块屏 / 第三块屏**的坐标）。
- `make test` 断言数 1404 → **1452**；`make verify` 全绿。



### 课程时间自定义

设置面板「课表」板块 →「课程预览」下面新增一张「课程时间自定义」卡片：
10 节课的起止时间都能改，改完立即影响桌面时间列、课程块时间、状态条倒计时和上课提醒。

#### 新增 · Added

- **课程时间自定义卡片**：放在「课程预览」正下方，固定高度、**内置滚动窗口**，
  鼠标停在列表上滚轮滚列表本身；滚到尽头之后才把余下滚轮交给外层面板。
- **10 行就地编辑**：每行「第 N 节」，时间拆成 **时 / 分两个输入框**，
  中间的冒号是固定标签，**不用输入**；点进框里直接敲数字。
  开始和结束之间用短横线分隔，每行四个小框（开始时 / 开始分 / 结束时 / 结束分）。
- **自动补零**：`8` + `5` → `08:05`；分留空按 `00` 处理，失焦后统一显示两位数；
  中文冒号、单数字都能识别。
- **校验**：格式非法、开始不早于结束、与相邻节次重叠 → 响一声并恢复原值，不写盘。
- **一键恢复默认**：卡片右上角「恢复默认」。
- **立即生效**：合法修改写进 `settings.json` 的 `periods` 分组，
  同时应用到 `Schedule.periods`（时间范围 / 课程块 / 状态条 / 提醒排程），
  并把新作息推给网页时间列，不需要重启。
- **打开时同步**：设置面板每次打开都从当前设置读取作息，外部改过也不会显示旧值。

#### 调整 · Changed

- **输入从「一个 HH:mm 框」改成「时 / 分两个框」**：冒号只做显示，
  不再需要用户输入；小时 / 分钟各自补零，输错的概率更低。
- **数字在框内垂直居中**：圆角背景和文字输入框分开绘制 ——
  背景保持 22pt 高，文字框只占 15pt 行高并居中。
  实测数字中心与框中心对齐（之前系统默认排版会偏上约 1.5pt）。
- **版本号 `1.1.3` → `1.1.5`**（`Makefile`、`Info.plist` 的显示名 /
  `CFBundleShortVersionString` / `CFBundleVersion` 全部对齐，bundle id 不变），
  构建归档为 `版本迭代/DesktopTimetable-1.1.5.app`。

#### 测试 · Tests

- `make test` 断言数 1452 → **1578**，新增 `PeriodSettings` 默认值 / 规范化 / 校验、
  `settings.json` 往返、`Schedule.applyPeriodTimes` 驱动时间列与网页。
- 新增 `--verify-period-save`：编辑 → 写盘 → `Schedule` 立即生效，
  非法输入回滚，结束恢复默认。
- `--verify-panel-sections` 检查卡片顺序、10 行、内置滚动、第一行四个框的内容；
  `--verify-wheel-routing` 允许作息列表自己滚、其余内层滚动继续转发给外层面板；
  `--verify-web-render` 对照 `Schedule.periods` 检查网页时间列。

## [1.1.3] - 2026-10-26

上课提醒的提前量可以自己填了；「在访达中显示」不再被设置面板压住。

### 新增 · Added

- **「提前提醒」下拉框最后一项是「自定义…」**：选它弹一个输入框，
  填 `0`–`60` 的任意整数都行 —— 以前只有 0 / 5 / 10 / 15 / 20 / 30 六个候选，
  想提前 12 分钟或 45 分钟只能改配置文件。
  - 弹窗是自建的 HUD 面板（不是系统 `NSAlert`），跟本项目其它弹窗一个调子；
    输入不合法（超范围 / 不是整数）当场提示「请输入 0–60 之间的整数」，不静默吞掉。
  - 填的值**不是候选时**，下拉框里会多列一项「提前 12 分钟（自定义）」并选中它
    —— 用户一眼看得出现在提前几分钟，不会以为「设置丢了」。
  - **存盘只写一个整数**（`settings.json` 的 `reminder.leadMinutes`）：
    「是不是自定义值」不另存字段，由「在不在候选里」推出来。
    所以老配置不用迁移，改一下 UI 就支持任意分钟数。
  - 取消输入时，下拉框恢复原样（刚才那一下选中「自定义…」不算数）。

### 修复 · Fixed

- **「在访达中显示」打开的访达窗口被设置面板整个盖住**：设置面板是 `.floating`
  浮层，访达窗口是普通层，而 macOS 里**层级高的永远排在前面，跨 App 也不例外**
  —— 访达窗口起来时面板还停在浮层，于是大半窗口压在面板底下，用户点了按钮
  什么也看不见。现在点「在访达中显示」时面板先**让路**（降到普通层 + `orderOut`
  收起），访达窗口上前；用户切回本 App 或重新打开设置时再把面板摆回 `.floating`。
  （实测 z 序探针：修复前访达被压住，修复后访达在面板之上。）

### 测试 · Tests

- 新增 `--verify-lead-custom` 自检（`make verify` 增加一项）：验下拉框最后一项恒为
  「自定义…」、当前值不是候选时多列出「提前 N 分钟（自定义）」并选中它、
  选「自定义…」→ 弹输入框 → 填 45 → 确定 → 真的存盘 45 且列表同步。
- 新增纯函数断言（`LeadMinutesChoice`）：下拉框结构（候选 + 自定义值 + 「自定义…」）、
  标题 ↔ 分钟数的双向对应、输入解析的边界（0 / 60 合法，61 / 负数 / 小数 / 空 → nil）。
- 顺手修掉 `Makefile` 里两处 `verify` 配方的续行写法错误：
  续行里的 `@echo` 会被 `/bin/sh` 当成命令（`@echo: command not found`），
  导致 `make verify` 直接报错退出。

## [1.1.2] - 2026-10-26

导入弹窗只在需要注意时出现；默认覆盖当前课表。

### 新增 · Added

- **「提前提醒」下拉框最后一项是「自定义…」**：选它弹一个输入框，
  填 `0`–`60` 的任意整数都行 —— 以前只有 0 / 5 / 10 / 15 / 20 / 30 六个候选，
  想提前 12 分钟或 45 分钟只能改配置文件。
  - 弹窗是自建的 HUD 面板（不是系统 `NSAlert`），跟本项目其它弹窗一个调子；
    输入不合法（超范围 / 不是整数）当场提示「请输入 0–60 之间的整数」，不静默吞掉。
  - 填的值**不是候选时**，下拉框里会多列一项「提前 12 分钟（自定义）」并选中它
    —— 用户一眼看得出现在提前几分钟，不会以为「设置丢了」。
  - **存盘只写一个整数**（`settings.json` 的 `reminder.leadMinutes`）：
    「是不是自定义值」不另存字段，由「在不在候选里」推出来。
    所以老配置不用迁移，改一下 UI 就支持任意分钟数。
  - 取消输入时，下拉框恢复原样（刚才那一下选中「自定义…」不算数）。

### 变更 · Changed

- **导入三选一默认改为「覆盖当前课表」**，按钮顺序改为
  「覆盖当前课表 / 新建一份独立课表… / 取消」。
  以前「新建课表」在第一颗：用户想覆盖却顺手回车，会悄悄多出一张独立课表，
  当前课表根本没动，看起来像「导入没生效」。
- **覆盖导入不再一律弹差异页**：只有检测到**时间冲突**或**匹配关系不唯一**时才打开
  差异合并页；普通新增 / 更新、受保护课程只是有导入新版本（默认保留当前）、
  未受保护课程在导入里消失（默认保留当前），都直接按默认规则应用。
- **导入里少了受保护课程（你新增 / 改过 / 旧数据）时逐门询问「保留 / 删除」**，
  不再只在差异页里默认「保留当前」了事。先问缺失的保护课，再根据最终选择重算冲突：
  如果用户选了删除、冲突随之消失，就直接继续，不再多弹一页。
- 对缺失保护课做出的「保留 / 删除」选择会原样带进差异页
  （`TimetableDiffWindowController(initialChoice:)`），不会被差异页的默认值改回去。
- 版本号 `1.1.1` → `1.1.2`（`Makefile`、`Info.plist` 的 `CFBundleShortVersionString` /
  `CFBundleVersion` / 显示名全部对齐）。补丁版沿用 1.1.0 的 bundle id，
  升级后设置、登录项与通知身份保持连续。

### 修复 · Fixed

- **缺失的受保护课没有被明确询问**：真实数据里「工程职场实习」（周日、旧数据来源）
  在新导入文件里不存在，覆盖导入时只会出现在差异页底部、默认「保留当前」——
  用户很容易以为「根本没检测到」。现在导入流程会单独弹出：
  「导入文件里没有「工程职场实习」… 要保留这门课吗？」（保留 / 删除 / 取消导入）。
- **`presentError` 重复收尾**：它自己调一次 `onDecision(.cancel)`，调用点又调一次。
  现在只负责提示，收尾统一由调用点处理。

### 测试 · Tests

- 新增 `--verify-finder-reveal` 自检：验「在访达中显示」的三步顺序
  （先让路 → 再选文件 → 最后显式激活访达）、让路后层级确实是普通层且面板
  确实收起、恢复后确实回到浮层、恢复函数幂等。
- 新增纯函数断言：`FinderRevealPolicy` 的层级取值（浮层 > 普通层）与
  `FinderRevealCoordinator` 的步骤顺序 —— 顺序错了肉眼看不出来，只能靠断言盯着。
- 新增「什么时候该弹窗」纯函数断言：普通更新不弹、保护课缺失单独问、
  时间冲突弹差异页、受保护的普通更新不弹。
- 新增端到端断言：无冲突直接覆盖不调用差异页；缺失保护课选保留 / 删除 / 取消；
  删除保护课后冲突消失则直接继续；有冲突时仍打开差异页并沿用刚才的选择。
- `--verify-import-flow` / `--verify-focus-flow` 注入缺失保护课的测试决策，
  并断言自检里真的问到了「自习」。
- 用真实课表的临时副本复现：`工程职场实习` 会触发逐门确认，选「保留」后
  不弹差异页，课程仍在当前课表里。

## [1.1.1] - 2026-10-25

覆盖导入不再静默覆盖 / 静默删课。

### 新增 · Added

- **课程来源** `CourseOrigin`（`imported` / `manual` / `unknown`）+ `Course.userModified`：
  旧数据缺字段一律解码成 `unknown` / `false`（当受保护处理，不因字段缺失失败）。
  「受保护」= 用户新增 / 用户改过 / 旧数据；默认值永远不动它们。
  展示文案：导入 / 你新增 / 你修改过 / 旧数据（来源未知）。
- **导入时间冲突检测** `ImportConflictLogic`（纯函数）：导入课与「会保留的当前课」
  同天同节次且周次有交集 → 一条冲突单元（同一对课程的所有重叠时段合并成一条，id 稳定）。
  逐条选「保留当前 / 用导入 / 两边都留」，**不给默认值**，没决定完「应用」置灰并说明原因。
- 差异页显示每门当前课程的来源；新增「时间冲突」区域与「全部两边都留」批量按钮；
  顶部摘要改为「X 门将更新；Y 门将新增；Z 门你新增/修改的课受影响；N 处冲突待决定」。
- 防丢课安全网：合并结果里少了受保护课程、又找不到对应的显式选择 → 拒绝应用并报出课名。
- `--verify-import-flow` 自检（`make verify` 增加一项）：走真实接线起导入 → 差异页 →
  逐条冲突 → 应用 → 断言真的写盘、窗口关闭、流程清空、设置面板拿回可见 / 可成 key 状态。
- `--verify-focus-flow` 真机焦点自检（`make verify` 增加一项）：**经 LaunchServices 启动**
  （`open -n`）并跑在**真正的 `NSApplication` 事件循环**里 ——
  从终端直接起的进程永远拿不到激活权（`isActive` 恒为 false），
  那种断言是「永远为真的假断言」。它验：app 能当 active app → 覆盖导入 →
  **真点**「应用」按钮 → 差异页关掉后设置面板拿回 key window →
  面板数据换成新课表 → **真实按键**能被面板接住。

### 变更 · Changed

- 版本号 `1.1.0` → `1.1.1`（`Makefile`、`Info.plist` 的 `CFBundleShortVersionString` /
  `CFBundleVersion` / 显示名全部对齐）。补丁版沿用 1.1.0 的 bundle id，
  升级后设置、登录项与通知身份保持连续。

### 修复 · Fixed

- **`--verify-import-flow` 没登记进 `AutomationMode.automationFlags`**：
  那次自检以**非自动化模式**运行 → 自动化护栏失效 →
  `refreshReminderSchedule()` 不再提前返回 → `clearAll()` 打到了
  **同一 bundle id 的真实系统通知中心**，会清掉已排好的上课提醒。
  已登记，并补了回归测试：扫源码里所有 `--verify-*`，逐个断言都在 `automationFlags` 里。
- **「需要确认」的课选「删除」后仍被当成「保留当前」** → 产生幽灵冲突：
  `detect()` 用 `choice != .useImported` 判断保留，而 `.delete` 也满足这个条件，
  于是明明删掉的课还留在当前侧参与冲突检测 → 用户选了删除还要再处理一个不存在的冲突，
  再选「保留当前」消掉它反而会删掉本该导入的课。
  现在按类别分别判断（`retainedCurrentIDs()`，与 `merge` 语义对齐）：
  `matched` 只认 `.keepCurrent`；`ambiguous` 认 `.keepCurrent` / `.skip`；`removed` 认 `!= .delete`。
- **「完全一样」的覆盖分支把写盘失败静默吞掉**：`isIdentical` 分支丢弃了 `overwrite()`
  的返回值 → 不弹「保存失败」、不调 `onDecision` → `importDecision` 不会被清空 →
  下一次导入被「上一次导入还没结束」拦住。现在接住返回值，
  失败时提示并走 `onDecision(.cancel)` 收尾（`applyAsCurrentTimetable` /
  `applyAsNewTimetable` 的写盘失败同样补上了收尾）。
- **设置面板「看得见但点不动」**：根因是**在 app 还没真正激活时**调
  `makeKeyAndOrderFront` —— 窗口会显示，但拿不到 key，点击和键盘都进不去。
  激活是异步的，而且 accessory（LSUIElement）app 抢前台**不一定一次成功**
  （实测 8 次里失败 2 次）。现在统一走 `activateAndTakeKey()`：
  反复激活 + 抢 key，直到真的拿到 key 为止（设置面板与差异页共用）。
- 差异页关闭后设置面板的数据没刷新：焦点对了但列表还是旧的，用户会误判成「导入没生效」。

- **覆盖导入点「应用」只关窗、不保存、不刷新**：`ImportDecisionController` 以前是
  `performImport()` 里的局部变量，`start()` 一返回就被释放，`[weak self]` 全部静默失效。
  现在由 `AppDelegate` 强持有，并在流程收尾时清空；同一时间只允许一个导入流程。
- 差异页以前在**保存之前**就关窗：写盘失败会丢掉用户的逐条选择。
  现在 `onApply` 返回成功 / 失败，只有写盘成功才关窗，失败保留页面并说明原因。
- 差异页关闭后设置面板「按钮都不响应」：关窗时显式 `restoreFocus()`
  （重读数据 + 回到最前 + 拿回 key），设置面板的 Esc 监视器只在它自己是 key window 时生效
  （以前差异页聚焦时按 Esc 会误关背后的设置面板）。
- 差异页每行末尾的分隔线在加入视图层级**之前**就激活了宽度约束，AppKit 抛
  「no common ancestor」直接崩 —— 进入差异页即闪退，已修正为先加视图再激活约束。
- 差异页与合并用的不是同一组数组（`compare` 用补过 `courseID` 的、页面拿原始的），
  现在统一成同一份，`current` 也用刚 load 出来的课表而不是 AppDelegate 的旧副本。

- **部分周次重叠改成「按周让开」**（原来是整条上课时间删掉）：
  界面上写的是「重叠 1-8 周」，行为却是把导入课整条删掉 —— 导入课 1-16 周、
  重叠只有 1-8 周时，9-16 周也跟着一起没了。现在只让开**重叠的那几周**：
  「保留当前」→ 导入侧让开重叠周次，没冲突的周次照旧导入；
  「用导入」→ 当前侧让开重叠周次，这门课其他周次保留。
  让完之后一条上课时间一周不剩 → 整条去掉。
  差异页加了一行说明：「保留当前 / 用导入」只调整上面标出的重叠周次，其余周次不动。
- **显式选「用导入」不再解除保护**：用户点「用导入」= 授权**这一次**用导入的内容；
  「这门课是我加的 / 我改过的」这个事实**保留**（`originAfterImport()`）。
  以前合并后来源被重置成 `imported` / `userModified = false`，
  下次导入这堂课就成了「不保护的导入课」，默认**静默覆盖** ——
  用户当初那一次点击并没有授权「以后都归导入管」。
  本来就不受保护的导入课（上次导入的原样）用导入之后**仍然不受保护**，
  不会制造额外噪音。差异页对受保护的课加了一行说明。
- 覆盖导入的默认选择改成来源感知：未受保护的匹配课默认「用导入」（覆盖语义），
  受保护的默认「保留当前」；导入新增默认用导入，导入消失 / 学期字段默认保留。
- 不再用「合并后有时间冲突 / 仍然保存」的全局警告绕过逐条冲突；残留冲突只允许
  用户显式「两边都留」。

### 修复 · Fixed（本轮补充）

- **关掉的窗口会自己弹回来**：激活重试（`activateAndTakeKey`）每次重试都调
  `makeKeyAndOrderFront` —— 窗口被关掉之后，**还在排队的重试会把它重新弹出来**。
  用户看到的就是「我点了应用，窗口关了，过一秒又自己冒出来」。
  根因是上一轮为了修「面板点不动」加的退避重试（总时长约 5.1 秒）没有失效机制。
  现在两边（设置面板 / 差异页）都用 `activationToken` 作废在途重试：
  关窗时 +1，在途的重试发现令牌变了就自己停。
- **`make verify` 吞掉了覆盖导入自检的失败**：`--verify-import-flow` 那一步的退出码
  没人检查 —— 自检报出「问题：…」但 `make verify` 照样返回 0。
  现在这一步的退出码会被检查，不通过就让 `make verify` 失败。
- 自检等待方式：差异页关掉后焦点飞回设置面板是**异步**的，
  以前死等固定 1.5 秒 —— 抢前台慢的时候会误报「面板没拿回 key」。
  改成「等到面板真的拿到 key 为止」，跟打开面板那一步同一套路。
  差异页关窗 / 取消后也等满 2.5 秒，确保「窗口不会再自己冒出来」是一条真断言。
- **重试预算比等待预算小 → 激活半路断掉**：把窗口提到前台的退避重试写死成
  「8 次尝试」（约 5.1 秒），而自检等 key 的 deadline 是 8 秒 ——
  重试链可能先死掉，剩下 2.9 秒**没人再激活**，于是偶发报「面板不是 key window」。
  现在两边都用**时间预算**（激活 10 秒 / 等待 12 秒），不再用固定次数。
- **激活重试逻辑抽成一份共用函数**（`UI/WindowActivation.swift`）：设置面板和差异页
  之前各写一份，迟早会漂移。现在共用，终止条件三个：
  拿到 key / 调用方作废（token 变了）/ **窗口曾经摆到前面、现在又不见了**
  —— 最后这条让「关掉的窗口被重试弹回来」在**结构上**不可能发生。
- **面板被隐藏时，`restoreFocus()` 以前什么都不做**：它的开头是
  `guard let w = window, w.isVisible else { return }` ——
  面板一旦处于「不可见」状态，**数据不刷新、窗口不摆出来、key 不拿回来**三件事全跳过。
  用户看到的是「导入成功了，列表还是老的」+「按钮点了没反应」。
  隐蔽之处：`onDecision` 里还有一条独立的 `reload()` 路径，数据照样会更新 ——
  「数据刷新了」这个断言**假通过**，只剩焦点那条报错，看着像偶发的焦点问题。
  现在区分「被关掉」和「只是被隐藏」：被关掉（用户主动关的）不硬拽回来；
  只是被隐藏 → 摆出来再激活。
  「被关掉」用显式标志（`panelClosed`）判断，不靠 `NSApp.windows`（不是公开契约）。
  自检新增「面板被隐藏」场景：藏起来 → 调 `restoreFocus()` → 断言摆出来了 + key 拿回来了。

## [1.1.0] - 2026-10-25

统一设置层 + M2（登录自启 / 上课提醒）。

### 新增 · Added

- **上课提醒**（系统 `UserNotifications`，零第三方依赖）：
  - 纯逻辑规划器 `ClassReminderPlanner`（不 import UserNotifications，可完整单测）；
  - 从今天起 **14 天**滚动排程，只排 1…`effectiveMaxWeek` 周内、本周生效、还没开始的课；
  - 复用 `TimetableState.displayCourses(for:)` 语义：覆盖生效的周只提醒覆盖课，其他周仍提醒原课；
  - 同一格多门冲突课合并成一条通知，课名用「 / 」连接；
  - 稳定通知 id `dt.class.<yyyyMMdd>.<day>.<block>`，同一天重算覆盖旧通知，不会越排越多；
  - 系统上限 64、本应用硬上限 **60** 条，超出保留最早 60 条并记录 `droppedCount`；
  - `UNCalendarNotificationTrigger` 的 `DateComponents` 显式带 `Asia/Shanghai`，不重复触发；
  - 启动 / 导入 / 编辑 / 覆盖 / 切换课表 / 改学期 / 改设置 / 跨天 / 唤醒 / 回到前台时重排，
    指纹去重（课表 id + 课程 + 覆盖 + 学期 + 开关 + 提前量 + 日期）；
  - 先加后删（不 `removeAllPending`），避免中间空窗；
  - 退出 app **不**清空待发通知，系统继续投递；启动时清理遗留的 `dt.test.*` 测试通知；
  - 前台也显示横幅 / 声音（`UNUserNotificationCenterDelegate`）。
- **登录自启**：macOS 13+ 用 `SMAppService.mainApp`；状态以系统为准
  （`.enabled` / `.notRegistered` / `.requiresApproval`），`requiresApproval` 时可一键打开
  「系统设置 → 通用 → 登录项」。macOS 12 开关置灰并说明需要 13+。
- **统一设置层** `SettingsStore` + `AppSettings`：
  - `config.json` **只放外观**，新设置独立 `settings.json`（`schemaVersion: 1`）；
  - 分组模型：`appearance` / `reminder`（本期实现）/ `notes` / `pet`（只预留结构）；
  - 缺字段、类型非法、文件损坏一律退回默认值并记录诊断，不影响课表加载；损坏文件先备份；
  - 写入原子化，且「读-改-写」保留未知字段；提供 `update {}` 只改调用方负责的字段。
- 设置面板新增「提醒与启动」卡片：开机自启、上课提醒、提前提醒下拉、
  权限 / 登录项状态行、「发送测试提醒」与「打开通知设置」按钮。
- `--verify-reminder-plan` 自检 + `make verify` 增加对应一项（第 9 项）。

### 变更 · Changed

- `ScheduleStore.saveConfig([String: Double])` 签名不变，但内部改成
  **读旧文件 → 合并新键 → 原子写回**，任何旧调用路径都不再整份覆盖、不会误删未知字段。
- 设置面板的所有写盘统一走 `SettingsStore`，UI 里不再自己拼字典写文件。
- 版本号 `1.0.1` → `1.1.0`（Makefile、`Info.plist` 的 `CFBundleShortVersionString` /
  `CFBundleVersion` / 显示名全部对齐）。

### 修复 · Fixed

1. **改开学日期后不刷新**：保存成功后没触发刷新回调，卡片还是旧学期。
   现在成功才调 `onChange()`（`SemesterCommitResult` 区分 `.saved` / `.unchanged` / `.failed`），
   失败时界面日期保持原值，不假装保存成功。
2. **提醒指纹漏字段**：只改**地点**或**教师**时指纹不变 → 重排被跳过 →
   已经排好的通知正文还是旧地点。指纹现在覆盖 `courseID / day / block / weeks / name / loc / teacher`
   （覆盖课同理）。
3. **测试提醒按钮状态不准**：未授权时按钮没有可靠置灰，且要分两次查授权状态。
   现在一次回调拿全（`authorizationState` → 授权 + 文案），决策抽成纯函数
   `testReminderAvailability`；状态行仍显示「系统通知未授权」，
   「打开通知设置」按钮**始终保留**（没入口用户就没法去开权限）。
4. **损坏的 `settings.json` 被直接覆盖**：备份函数只有测试在调，生产保存路径从不调 ——
   坏文件被新内容覆盖后用户既没得看也没得恢复。现在写盘前先备份
   （`settings-corrupt-<时间戳>.json`），正常文件不产生备份。
5. **登录项状态把「找不到」当成「未开启」**：`SMAppService` 的 `.notFound`
   （app 不在 /Applications，或被位置 / 签名限制挡住）和未知状态都被静默映射成
   「未开启」，用户完全看不出其实出问题了。现在映射抽成纯函数
   `LoginItemState.fromServiceStatus`，这两种情况都映射成 `.failed`（带真实原因）。
6. **README 与实际渲染路径不符**：文档没写清默认走哪条路。现在明确
   **默认模式 B（网页直接上屏）**，`DT_SNAPSHOT=1` 才回退到快照管线。
7. **`settings.json` 的数字 / 布尔混用**：JSON 的 `1` 能当 `enabled`、
   `true` 能当 `leadMinutes`、`1.0` 能悄悄变成 1 分钟。现在只接受真正的
   Bool / Int（`CFGetTypeID` + `objCType` 判定），类型非法一律退回默认值。
8. **设置读取失败没有诊断输出**：只在内存里记着。现在同时写一条 `NSLog`，
   排障时能在 Console / 统一日志里看到。
9. **手工验收缺少可用入口**：补 `--notifications-status`（只读授权状态和待发通知）
   与 `--login-item-selftest`（在真实 app bundle 里注册 → 读回 → 立刻注销），
   两个都**不**算自动化模式（它们就是要真的碰系统），README 写明用法。

上述每一条都配了回归测试（`make test` 断言数 708 → 781）。

### 安全 · Safety

- 自动化模式（`--verify-*`、`--render-card`、`--import`、`--dump-layout`、测试运行器）
  **不请求通知权限、不注册登录项、不发真实通知**。

## [1.0.1] - 2026-10-24

阶段 3：多课表 + 导入重构 + 单周临时覆盖 + 右键编辑。

### 新增 · Added

- **多课表**：新建 / 切换 / 重命名 / 删除；索引 `timetables/index.json`，
  每份课表独立目录；删除前备份整个目录，删最后一份进入空课表状态。
- **导入三选一**：新建课表 / 覆盖当前课表 / 取消；覆盖前先比差异，
  有差异进「差异合并页」逐项选择（保留当前 / 用导入），不会静默覆盖。
- **单周临时覆盖**（`week_overrides.json`）：只影响声明的周次，其他周仍显示原课；
  原记录存 `restored` 便于撤销；「全部周次」视图忽略覆盖；卡片上有「覆」标记；
  真冲突与非本周课两道串行确认。
- **右键编辑**：新增课程 / 查看编辑课程 / 添加上课时间 / 删除单次 / 删除整门课，
  保存前校验 + 冲突检测。
- **课程身份 `courseID`** 与 `CourseGrouper` 分组：同一门课多个上课时间共用一个身份，
  重复导入幂等。
- 学期配置 `start + maxWeek`（1–30，默认 16），`effectiveMaxWeek = max(配置值, 数据最大周次)`。
- 状态条规则：只有「本周」显示实时上下课倒计时，其他周与「全部周次」只显示周总结。
- 数据安全：原子写、导入 / 覆盖 / 删除备份、损坏文件降级提示。

### 变更 · Changed

- 卡片标题 / 副标题改为读当前课表的 `name` / `subtitle`，代码里不再硬编码个人姓名。
- 渲染默认改为 **B 模式**（网页直接上屏，0 次 `takeSnapshot`），A 模式仅作回退。

## [0.1.0] - 2026-10-22

首个可用的里程碑（M1）。

### 新增 · Added

- 桌面层卡片窗口（`CGWindowLevelForKey(.desktopIconWindow) + 1`），
  鼠标靠近渐显、移开渐隐，动画时长与不透明度可在设置里调。
- 自绘课表卡片：表头（星期 + 日期）、时间轴、课程格、状态条（当前/下一节课）。
- 点击课程弹出详情（教师、地点、周次、时间）。
- 设置面板：开学日期、导入课表、渐隐渐显参数、课程预览。
- 导入教务系统导出的 `.xls`（HTML 表格），支持 `rowspan` 合并单元格。
- 导入宽松格式的课程 JSON（中文星期、`第N节`、字符串周次）。
- 命令行模式：`DesktopTimetable --import <文件>`、`--help`、`--dump-layout`。
- 从旧版目录 `~/.config/timetable/` 自动迁移数据。
- 自带测试运行器（不依赖 XCTest）：`make test`。

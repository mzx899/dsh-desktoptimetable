# 对话存档 · 2026-11-08 · AppDelegate 源码事故与重建（已完成）

## 1. 事故

- 2026-11-07 深夜，一条 Python 补丁脚本写错（`s = ... if ... else None`），
  先把 `Sources/DesktopTimetable/App/AppDelegate.swift` 清空、再写入失败 → 文件 0 字节。
- 全盘无可用副本：
  - git 最后一次提交 11-01（2029 行）；
  - hermes 缓存 10-24（1350 行）、Claude 文件历史 10-23；
  - 归档 `.app` 只有二进制；
  - 时间机器未配置、无 APFS 本地快照、iCloud 未同步该项目；
  - 对话记录只能逐字还原约七成且是碎片（函数头缺失 / 被裁剪的片段混入）。
- 结论：**源码不可原样恢复，只能重写**。

## 2. 重建方案

- 骨架：11-01 的 git 版 `AppDelegate.swift`（2029 行，结构完整）。
- 往上补 1.3.x–1.4.2 的功能层：
  - 缩放：`applyCardScale` / `performCardScale` / `commitCardScale` /
    `applyNextDragFrame` / `enterDragWindow` / `lockScaleAnchor` /
    `updateDragChrome` / `currentWebCardCenterOnScreen` /
    `updateGlassFrameForCurrentScale` / `restoreAfterSettingsClose`；
  - 折叠：`toggleCollapse` / `animateCollapse` / `applyCollapseFrame` / `finishCollapse`；
  - 待办菜单：`todoMenuEdit/Delete/Cancel` / `applyTodoMenuAction` / `handleTodoMenuIntent`；
  - 常驻画布：`buildDesktopWindow` 里 `TimetableLayout.configureCanvas(maxCurrentScale)`；
  - 自检钩子：`testCardIsLit` / `testCollapseProgress` / `testGlassFrame` /
    `testUpdateHover` / `testToggleCollapse` / `testApplyCardScale*` / `testCommitCardScale` 等。
- 网页层恢复成 1.4.2 原版（`版本迭代/DesktopTimetable-1.4.2.app/Contents/Resources`）。

## 3. 第一轮（上午）结果

- `make app` 0 错误、`make test` 2046 全过、11 个 `--verify-*` **6 绿 / 5 红**。
- 当时卡在「原生 → 网页 eval 报成功但不执行」，怀疑是通道问题。

## 4. 第二轮（本轮）结果：11 绿 / 0 红

### 4.1 五个失败自检的根因（都不是 eval 通道坏了）

1. **`--verify-week-arrow`**：只有第一次点击（100% 档）失败。
   - 启动时没有调 `applyScale` → 网页里的卡片停在版式位置 (90,90)，
     没有「画布居中 translate」(74, 61.5)；
   - 原生 `LiveContainerView.passthroughRect` 已经是居中矩形 (164,151.5,968,773)；
   - 画布上沿那 23pt 里的箭头**落在命中矩形之外** → 点击穿透到桌面，什么都不发。
   - 113% / 折叠态之前都做过一次缩放，translate 有了，所以那两步能过。
2. **`--verify-day-panel-click`**：`dayPanel` 从来没被创建。
   `datePanelOpen` / `todo*` 全被 `dayPanel?.handle` 吞掉；`onStateChange` 不推状态，
   所以「换列推送 0 次」「系统数据变化后网页不重新要数据」。
3. **`--verify-collapse`**：`finishCollapse` 里的 `dayPanel?.handle` 同样因为它为 nil 而失效；
   另一条「折叠 → 缩放 → 展开」失败是因为拖动帧一直按展开高度（773）算卡片矩形。
4. **`--verify-pin-flow`**：`WindowAnchor.provider` 只写在 `applicationDidFinishLaunching`，
   自检走 `prepareForRendering`，锚点退回默认值（屏幕中心）。
5. **`--verify-scale-panel`**：面板开着松手时用「画布居中」的 `TimetableLayout.cardRect`
   当卡片当前位置，而卡片实际停在拖动帧锚点上 → 窗口被平白挪 6pt；
   「放到最大贴左」还会把卡片推到屏幕外。

另外查清 eval 事件的真相：网页 `post()` 同步调起 `WKScriptMessageHandler`，
在**网页自己的点击回调栈里**重入 `callAsyncJavaScript` —— WebKit 接受但不执行
（`ttUpdate` 计数不涨）。推迟到下一个 runloop 再处理就正常了。

### 4.2 改动

- `AppDelegate.buildDesktopWindow` 补齐启动接线：
  `performCardScale(appearance.cardScale)` → `restoreWindowState()` →
  `buildDayPanelController()` → `installWindowAnchor()`。
- 新增 `buildDayPanelController()` / `syncDayPanelWeek()` / `installWindowAnchor()`。
- 菜单桥接：`MenuPresenter.onMenuVisibilityChanged` → `ttDayPanelMenuOpen` +
  6 秒宽限期；`updateHover` 里把「菜单开着 / 宽限期内」算作保持可见；
  覆盖层矩形同步给 `LiveContainerView.panelRect`。
- `WebCardRenderer.handle(_:)`：意图处理 `DispatchQueue.main.async`。
- `applyNextDragFrame`：折叠态用折叠高度、锁顶边（1.4.1 约定）。
- `commitCardScale`（面板开着）：`dragCardRect` 写回 `cardRectOverride`，夹屏用它。

### 4.3 验证

- `make test`：2051 项断言全过。
- 12 个 `--verify-*` 全过（见 CHANGELOG `[1.4.3]` 的具体数字）。
- 补记七：Git 推送链路搭好 —— 项目里建了 `推送仓库/`（rsync 导出的源码副本，
  141 个文件 / 4.3MB），`git init -b code` + `remote origin` 指向
  `https://github.com/mzx899/dsh-desktoptimetable.git`，并把 push refspec 锁成
  `code:code`（`main` 永远不会被动）；本地已 rebase 到远端 `origin/code` 之上，
  下次推送是快进、不需要 force。**按新约定：补丁版不推**。
  后记：用户要求「这次是源码缺失后第一次补上，先推上去」→ 已推 `code`：
  `c9e48e1..ecb4573`（随后补一条文档提交 `0b7f5f7`），`main` 仍为 `c9e48e1` 未动；
  HTTPS 无写权限，远端已切 SSH；从 GitHub 克隆验证 `make app` + `make test` 2052 全过。
- 补记六：用户说「图钉比原来宽」——网页里写死 `17×17` 把符号拉成了正方形；
  改成 `height:17px; width:auto`（原比例，100% 实测 14.8×17）。
- 补记五：用户说「图钉点不动」——视觉搬进网页后，原生 `PushPinButton` 还留在
  交互层最上面当热区，`hitTest` 先返回它，点击就被吃掉了。改成图钉区域一律
  `return nil`（让给网页里的 `.ttlpin`），点击才落到看得见的那张图上；
  自检同步改成断言「图钉区域不被交互层接管」+ `testClickWebPin()`。
- 补记四：用户说「图钉还是闪、跟不上左边的标题」——
  根因是**架构性的**：图钉是原生控件、标题在 WKWebView 里，两条流水线跨进程，
  再怎么等回调也只能差一帧。最终把**视觉搬进网页**（`.ttlpin` 和标题同一个
  flex 行 / transform），原生 `PushPinButton` 只留透明热区；图钉图片由原生把
  SF Symbol 渲染成 2x PNG data URI 注入。实测间距 8.96pt（理论 8.96）、
  宽 19.03（理论 19.04）、纵向差 0.00。
- 补记三：用户发现「缩放时左上角图钉和课表不同步」——
  原生 chrome 在发命令的同一刻就摆到目标位置，而网页 transform 是跨进程异步的；
  窗口逐帧移动后，card 会先冲过头再回来，图钉/玻璃已经站在目标 → 看起来「飘在外面」。
  修法：chrome 挪进 `applyDragScale` 的回调里摆（watchdog 兜底也补一次）。
  静态对齐用 `--verify-slider-scale` 的「图钉间距 / 纵向差」断言锁住（8.97 vs 8.96）。
- 补记二：用户发现「放大时卡片会出界，松手才一下跳进屏幕」——
  拖动帧原来只保证「不被画布裁」，没保证「留在屏幕可见区」，而且窗口基本不动。
  改成**每一帧**按「卡片中心 = 夹过的锚点」反推窗口原点；同时补上两个连带问题
  （缩放锚点松手不释放、`webCardCenterInWindow` 返回容器中心）。
  自检里加了「贴边放大，每一帧量卡片屏幕矩形」的断言（最大越界 0.0pt）。
- 补记：用户回头报「放大缩小还没恢复」——
  `SettingsWindowController.onCardScaleChange` 只有声明没有赋值，
  滑杆拖动不会通知课表重排。已在 `buildSettingsController` 接上，
  并新增 `--verify-slider-scale`（走真实滑杆入口，验放大 / 缩小 / 写盘 / 关面板保持）。
- 临时目录预置 `cardScale=1.10` 启动 → `缩放=1.1`，重启恢复生效。
- 出图：网页层卡片 1.0 居中、投影对称；设置 → 外观页正常。

### 4.4 版本

- 收尾定为 **1.4.3（补丁版）**：bundle id 不变（`com.desktoptimetable.app.v120`），
  构建归档到 `版本迭代/DesktopTimetable-1.4.3.app`。

### 4.5 清理

- 去掉 `[TT-PUSH]` 日志与 `DT_DIAG_CLICK` 打印；
- 保留网页 `__ttUpdateCalls` / `__ttUpdateWeeks`（只读计数，用来抓「推了不执行」回归）。

## 5. 备份与使用

- 重建前备份：`/tmp/dt-src-backup-2127/`（Sources + Resources + 草稿）。
- `build/DesktopTimetable.app` 现在是 **1.4.3** 的完整构建；
  归档版是 `版本迭代/DesktopTimetable-1.4.3.app`。
- 根目录 `DesktopTimetable-1.1.3.app`、课表数据、设置均未改动；
  未 commit、未 `make install`。
